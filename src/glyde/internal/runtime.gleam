//// The shard actor under `glyde.start`. Holds the socket and the gateway
//// state machine, and hands each decoded dispatch to the handler supervisor
//// as its own process. Nothing in here is API.

import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import glyde/client
import glyde/event.{type Event}
import glyde/gateway
import glyde/gateway/frame
import glyde/status.{
  type Status, Connecting, Halted, Note, Reconnecting, Sent, Undecodable,
}
import glyde/transport.{type Transport}

/// The one message the shard actor sends itself. Each one is one turn of the
/// socket, so the loop is the actor mailbox and every branch tail-calls by
/// posting the next Turn.
pub type Message {
  Turn
}

/// A closure that runs every listener over one event. Built by `glyde.start`
/// so this module never learns what an `Api` looks like.
pub type Job =
  fn() -> Nil

type State {
  State(
    driver: client.Bot(Io),
    started: Bool,
    transport: Transport,
    handlers: factory.Supervisor(Job, Nil),
    deliver: fn(Event) -> Job,
    report: fn(Status) -> Nil,
    self: Subject(Message),
  )
}

pub fn start(
  name: Name(Message),
  config: gateway.Config,
  transport: Transport,
  handlers: Name(factory.Message(Job, Nil)),
  deliver: fn(Event) -> Job,
  report: fn(Status) -> Nil,
) -> actor.StartResult(Subject(Message)) {
  actor.new_with_initialiser(5000, fn(self) {
    // The core has no randomness, so the jitter seed comes from out here.
    let shard = gateway.new(config:, seed: int.random(2_147_483_647))
    let driver =
      client.from_shard(
        shard:,
        state: Io(dial: None, deadlines: [], inbox: []),
        transport: wiring(transport, report),
      )
      |> client.on_event(dispatch(report))
      |> client.on_notice(fn(io, notice) {
        report(Note(notice))
        io
      })
    // The first Turn dials, not the initialiser: a slow handshake must not
    // fail the actor's start.
    process.send(self, Turn)
    State(
      driver:,
      started: False,
      transport:,
      handlers: factory.get_by_name(handlers),
      deliver:,
      report:,
      self:,
    )
    |> actor.initialised
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.named(name)
  |> actor.start
}

/// How long to wait with no timer armed. Only reachable if the shard stopped
/// asking for one, so it is a floor and not a schedule.
const nothing_due: Int = 60_000

fn handle(state: State, _message: Message) -> actor.Next(State, Message) {
  let state = case state.started {
    True -> state
    False -> State(..state, started: True) |> drive(client.start)
  }
  // Drain what is queued before the terminal check: a dispatch that arrived
  // in the same read as a fatal close is still owed its handlers.
  let state = settle(state)
  case client.is_terminal(state.driver) {
    True -> actor.stop()
    False -> {
      let state = once(state)
      process.send(state.self, Turn)
      actor.continue(state)
    }
  }
}

/// Spawn a handler process for each queued dispatch and clear the inbox.
fn settle(state: State) -> State {
  let io = client.state(state.driver)
  list.each(io.inbox, fn(event) {
    // A handler that will not start is a bug in the tree, not in the event.
    let _ = factory.start_child(state.handlers, state.deliver(event))
    Nil
  })
  on_io(state, fn(io) { Io(..io, inbox: []) })
}

/// One turn of IO: read the socket or sit out the gap, then service the clock.
fn once(state: State) -> State {
  let io = client.state(state.driver)
  let timeout = waiting(state, io)

  case io.dial {
    // A write already said the socket is gone, so there is nothing to read.
    Some(Dial(dead: True, ..)) -> gave_up(state)

    Some(dial) -> {
      let #(next, events) = dial.socket.turn(timeout)
      woke(state, next, events)
    }

    None -> {
      state.transport.idle(timeout)
      fire_due(state)
    }
  }
}

fn waiting(state: State, io: Io) -> Int {
  case gateway.soonest(io.deadlines) {
    Some(at) -> int.max(0, at - state.transport.now())
    None -> nothing_due
  }
}

// -- Driver state ------------------------------------------------------------

type Io {
  Io(
    dial: Option(Dial),
    deadlines: List(gateway.Deadline),
    /// Dispatches decoded but not yet handed to the factory. Drained on the
    /// next Turn, once the batch that produced them has finished running.
    inbox: List(Event),
  )
}

type Dial {
  Dial(
    conn: gateway.Conn,
    socket: transport.Socket,
    phase: DialPhase,
    dead: Bool,
  )
}

type DialPhase {
  Dialing
  Live
}

fn drive(state: State, feed: fn(client.Bot(Io)) -> client.Bot(Io)) -> State {
  State(..state, driver: feed(state.driver))
}

fn on_io(state: State, change: fn(Io) -> Io) -> State {
  drive(state, client.update(_, change))
}

fn on_dial(io: Io, change: fn(Dial) -> Dial) -> Io {
  Io(..io, dial: option.map(io.dial, change))
}

fn on_socket(state: State, change: fn(Dial) -> Dial) -> State {
  on_io(state, on_dial(_, change))
}

// -- Socket ------------------------------------------------------------------

fn gave_up(state: State) -> State {
  case client.state(state.driver).dial {
    None -> state
    Some(dial) -> {
      let state = on_socket(state, fn(dial) { Dial(..dial, dead: False) })
      case dial.phase {
        Dialing ->
          drive(state, client.open_failed(
            _,
            dial.conn,
            gateway.Unreachable(detail: "write failed"),
          ))
        Live -> drive(state, client.closed(_, dial.conn, None))
      }
    }
  }
}

fn woke(
  state: State,
  next: transport.Socket,
  events: List(transport.Event),
) -> State {
  on_socket(state, fn(dial) { Dial(..dial, socket: next) })
  |> list.fold(events, _, arrived)
  |> fire_due
}

fn arrived(state: State, event: transport.Event) -> State {
  case client.state(state.driver).dial {
    None -> state
    Some(dial) -> from_socket(state, dial, event)
  }
}

fn from_socket(state: State, dial: Dial, event: transport.Event) -> State {
  case event {
    transport.Opened ->
      on_socket(state, fn(dial) { Dial(..dial, phase: Live) })
      |> drive(client.opened(_, dial.conn))

    transport.TextMessage(text:) ->
      drive(state, client.received(_, dial.conn, text))

    transport.BinaryMessage(bytes:) ->
      drive(state, client.received_bytes(_, dial.conn, bytes))

    transport.Closed(code:, reason:, cause:) -> {
      let state = on_io(state, fn(io) { Io(..io, dial: None) })
      case dial.phase {
        Dialing ->
          drive(state, client.open_failed(
            _,
            dial.conn,
            dial_failure(cause, reason),
          ))
        Live -> drive(state, client.closed(_, dial.conn, peer_code(code)))
      }
    }
  }
}

fn dial_failure(
  cause: Option(transport.CloseCause),
  reason: String,
) -> gateway.DialFailure {
  case cause {
    Some(transport.TransportFailed(detail:)) -> gateway.Unreachable(detail:)
    Some(transport.UpgradeRefused(status:, detail:)) ->
      gateway.Refused(status:, detail:)
    None -> gateway.Unreachable(detail: reason)
  }
}

fn fire_due(state: State) -> State {
  let now = state.transport.now()
  let io = client.state(state.driver)

  case list.find(io.deadlines, fn(deadline) { deadline.at <= now }) {
    Error(_) -> state
    Ok(gateway.Deadline(timer:, at: _, stamp:)) ->
      on_io(state, fn(io) {
        Io(..io, deadlines: gateway.disarm(io.deadlines, timer))
      })
      |> drive(client.timer_fired(_, timer, stamp))
  }
}

fn peer_code(code: Int) -> Option(Int) {
  case code {
    1005 | 1006 -> None
    code -> Some(code)
  }
}

fn wiring(
  transport: Transport,
  report: fn(Status) -> Nil,
) -> client.Transport(Io) {
  client.Transport(
    open: fn(io, conn, host, path) {
      let host = gateway.host_to_string(host)
      report(Connecting(host))
      Io(
        ..io,
        dial: Some(Dial(
          conn:,
          socket: transport.open("wss://" <> host <> path),
          phase: Dialing,
          dead: False,
        )),
      )
    },
    send: fn(io: Io, payload: frame.Outbound) {
      case io.dial {
        None -> io
        Some(dial) ->
          case dial.socket.send(frame.outbound_text(payload)) {
            True -> {
              report(Sent(frame.outbound_op(payload)))
              io
            }
            False -> on_dial(io, fn(dial) { Dial(..dial, dead: True) })
          }
      }
    },
    close: fn(io: Io, code) {
      let _ = option.map(io.dial, fn(dial) { dial.socket.close(code) })
      io
    },
    drop: fn(io: Io) {
      let _ = option.map(io.dial, fn(dial) { dial.socket.drop() })
      Io(..io, dial: None)
    },
    arm: fn(io: Io, timer, in_ms, stamp) {
      let at = transport.now() + in_ms
      Io(..io, deadlines: [
        gateway.Deadline(timer:, at:, stamp:),
        ..gateway.disarm(io.deadlines, timer)
      ])
    },
    cancel: fn(io: Io, timer) {
      Io(..io, deadlines: gateway.disarm(io.deadlines, timer))
    },
  )
}

/// Decode and queue. The handlers are spawned from `settle`, never from in
/// here: this is mid-batch inside `glyde/client`.
fn dispatch(
  report: fn(Status) -> Nil,
) -> fn(Io, gateway.Event) -> client.Next(Io) {
  fn(io, emitted) {
    case emitted {
      gateway.Dispatch(name:, seq: _, data:) -> {
        let decoded = case event.dispatch(name, data).outcome {
          event.Decoded(decoded) -> decoded
          event.Unmodelled -> event.Raw(name:, data:)
          event.Malformed(errors:) -> {
            report(Undecodable(name:, errors:))
            event.Raw(name:, data:)
          }
        }
        client.keep(Io(..io, inbox: list.append(io.inbox, [decoded])))
      }

      gateway.Reconnecting(in_ms:, resuming:, why:) -> {
        report(Reconnecting(in_ms:, resuming:, why:))
        client.keep(io)
      }

      gateway.Halted(reason:) -> {
        report(Halted(reason:))
        client.keep(io)
      }

      gateway.Ready(..) | gateway.Resumed -> client.keep(io)
    }
  }
}
