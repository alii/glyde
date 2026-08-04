//// The loop under `glyde.run`. Nothing in here is API: `glyde` names what a
//// user sees, this module does it.

import gleam/bit_array
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import glyde/client
import glyde/event.{type Event}
import glyde/gateway
import glyde/gateway/frame
import glyde/rest/headers
import glyde/rest/limiter.{type Limiter, type Ticket}
import glyde/rest/route.{type Route}
import glyde/status.{
  type CallFailure, type Status, Connecting, Halted, Note, Paced, Reconnecting,
  Sent, Undecodable, Unreachable, Withheld, WouldBlock,
}
import glyde/transport.{type Transport}

/// What a handler hands back: its new state, or a request it wants answered
/// first and what to do with the answer. The loop performs it, nobody else.
pub type Step(state) {
  Done(state)
  Perform(
    request: Request(BitArray),
    route: Route,
    resume: fn(Answer) -> Step(state),
  )
}

/// Never `Refused`: reading the body is the continuation's job, because only
/// it holds the decoder.
pub type Answer =
  Result(Response(BitArray), CallFailure)

/// Run `step` to its state, then start `next` from there. How two listeners on
/// one event are chained without the second seeing a stale state.
pub fn after(step: Step(state), next: fn(state) -> Step(state)) -> Step(state) {
  case step {
    Done(state) -> next(state)
    Perform(request:, route:, resume:) ->
      Perform(request:, route:, resume: fn(answer) {
        after(resume(answer), next)
      })
  }
}

/// Connect and loop until the shard halts. `deliver` is every listener folded
/// into one, so this module never learns what a `glyde.Bot` is.
pub fn run(
  config config: gateway.Config,
  transport transport: Transport,
  state state: state,
  deliver deliver: fn(state, Event) -> Step(state),
  report report: fn(Status) -> Nil,
) -> Nil {
  // The core has no randomness, so the jitter seed comes from out here. A
  // fleet gives each shard a different one with `client.with_seed`.
  let shard = gateway.new(config:, seed: int.random(2_147_483_647))

  client.from_shard(
    shard:,
    state: Runtime(
      transport:,
      deliver:,
      report:,
      user: state,
      inbox: [],
      limiter: limiter.new(limiter.defaults()),
      tickets: 0,
      dial: None,
      deadlines: [],
    ),
    transport: wiring(),
  )
  |> client.on_event(dispatch)
  |> client.on_notice(fn(runtime: Runtime(state), notice) {
    runtime.report(Note(notice))
    runtime
  })
  |> client.start
  |> spin
}

/// What the loop threads. `deadlines` is a list and not a `Dict`: there are
/// four timers and `gleam/dict` does not iterate in a defined order.
type Runtime(state) {
  Runtime(
    transport: Transport,
    deliver: fn(state, Event) -> Step(state),
    report: fn(Status) -> Nil,
    /// Your value, as the last listener left it.
    user: state,
    /// Dispatches decoded but not yet handled, oldest first. A handler waiting
    /// on the limiter must not have the next one run against its old state.
    inbox: List(Event),
    /// Around `transport.request`, not inside it, so a transport of your own
    /// is paced without knowing this exists.
    limiter: Limiter,
    /// The next ticket to mint. One call is out at a time, so this only has to
    /// be different from the last.
    tickets: Int,
    /// `None` between a close and the next dial. Everything about a socket
    /// lives in here, so none of it can be read when there is no socket.
    dial: Option(Dial),
    deadlines: List(gateway.Deadline),
  )
}

/// One socket and the three things that are only true while it is up.
type Dial {
  Dial(
    /// The connection this socket was opened with, never the shard's live
    /// one: answering a close with the new conn kills the dial underway.
    conn: gateway.Conn,
    socket: transport.Socket,
    /// Whether this socket ever came up. A failed dial is `OpenFailed`, a
    /// dead connection is `Closed`, and the shard treats them differently.
    opened: Bool,
    /// Set when a write came back `False`. The socket is gone already, so the
    /// loop reports the close itself rather than waiting a whole read timeout
    /// for the read side to find out.
    dead: Bool,
    /// The last `Failed` or `Refused`, because the reason arrives one event
    /// before the end that needs it. `None` until the socket says something
    /// went wrong: a close carrying its own reason is the usual ending.
    trouble: Option(gateway.DialFailure),
  )
}

/// Change the dial if there is one. No dial is not an error: a close can land
/// after the socket was already let go.
fn on_dial(
  runtime: Runtime(state),
  change: fn(Dial) -> Dial,
) -> Runtime(state) {
  Runtime(..runtime, dial: option.map(runtime.dial, change))
}

/// `on_dial` reached through a `client.Bot`, which is how the loop holds it.
fn on_socket(
  bot: client.Bot(Runtime(state)),
  change: fn(Dial) -> Dial,
) -> client.Bot(Runtime(state)) {
  client.update(bot, on_dial(_, change))
}

/// How long to wait with no timer armed. Only reachable if the shard stopped
/// asking for one, so it is a floor and not a schedule. Our number.
const nothing_due: Int = 60_000

/// Handle what is waiting, then take one turn of the socket. Every branch ends
/// in a tail call, so this runs for the life of the bot in constant space.
fn spin(bot: client.Bot(Runtime(state))) -> Nil {
  // Before the terminal check: a dispatch that arrived in the same read as a
  // fatal close is still owed its handlers.
  let bot = settle(bot)
  case client.is_terminal(bot) {
    True -> Nil
    False -> spin(once(bot, nothing_due))
  }
}

/// One turn of IO: read the socket or sit out the gap, then service the clock.
/// `within` caps the block for a caller with a deadline of its own.
fn once(
  bot: client.Bot(Runtime(state)),
  within: Int,
) -> client.Bot(Runtime(state)) {
  let runtime = client.state(bot)
  let timeout = int.min(within, waiting(runtime))

  case runtime.dial {
    // A write already said the socket is gone, so there is nothing to read.
    Some(Dial(dead: True, ..)) -> gave_up(bot)

    // The read timeout is the timer: whichever comes first wakes us.
    Some(dial) -> {
      let #(next, events) = dial.socket.turn(timeout)
      woke(bot, next, events)
    }

    None -> {
      runtime.transport.idle(timeout)
      fire_due(bot)
    }
  }
}

/// How long this turn may block: the nearest deadline, or the floor.
fn waiting(runtime: Runtime(state)) -> Int {
  case soonest(runtime.deadlines) {
    Some(at) -> int.max(0, at - runtime.transport.now())
    None -> nothing_due
  }
}

// -- Handlers ----------------------------------------------------------------

/// Run every buffered dispatch through the handlers, one at a time and each to
/// its `Done` before the next starts. Two handlers in flight would both read
/// one state and one of their updates would be lost.
fn settle(bot: client.Bot(Runtime(state))) -> client.Bot(Runtime(state)) {
  let runtime = client.state(bot)
  case runtime.inbox {
    [] -> bot
    [event, ..inbox] ->
      client.update(bot, fn(runtime) { Runtime(..runtime, inbox:) })
      |> resume(runtime.deliver(runtime.user, event))
      |> settle
  }
}

/// Interpret one handler's step until it yields a state.
fn resume(
  bot: client.Bot(Runtime(state)),
  step: Step(state),
) -> client.Bot(Runtime(state)) {
  case step {
    Done(user) -> client.update(bot, fn(runtime) { Runtime(..runtime, user:) })
    Perform(request:, route:, resume: then) -> {
      let #(bot, answer) = perform(bot, request, route, 1)
      resume(bot, then(answer))
    }
  }
}

/// Sends per `Perform`, our number. The first 429 teaches the limiter the
/// bucket so the second try is timed right; a third covers a global and a
/// route limit landing back to back. Past that, retrying only spends the
/// invalid-request budget.
const max_attempts: Int = 3

/// How long a handler may wait on the limiter before the call is failed, in
/// ms. Our number. The heart beats through the wait, so this bounds how stale
/// the events queued behind get, not the connection: 10s rides out any
/// ordinary bucket reset and fails fast on the limits Discord counts in minutes.
const longest_wait: Int = 10_000

/// One request through the limiter and the transport, retried on 429.
fn perform(
  bot: client.Bot(Runtime(state)),
  request: Request(BitArray),
  route: Route,
  attempt: Int,
) -> #(client.Bot(Runtime(state)), Answer) {
  let #(bot, ticket) = mint(bot)
  let input = case attempt {
    1 -> limiter.Submit(ticket:, route:)
    // The front of the queue, so a retry is not reordered behind newer work.
    _ -> limiter.Retry(ticket:, route:)
  }
  let give_up_at = client.state(bot).transport.now() + longest_wait
  let #(bot, verdict) = limit(bot, input, ticket)

  case admit(bot, ticket, verdict, give_up_at) {
    #(bot, Error(why)) -> #(bot, Error(why))
    #(bot, Ok(Nil)) ->
      case client.state(bot).transport.request(request) {
        // Went out or not, the slot has to come back or the route is stuck
        // behind a probe that never lands.
        Error(reason) -> {
          let #(bot, _) =
            limit(bot, limiter.Settled(ticket, limiter.Opaque), ticket)
          #(bot, Error(Unreachable(reason)))
        }
        Ok(got) -> {
          let outcome =
            headers.outcome(
              status: got.status,
              headers: got.headers,
              body: throttle_body(got),
            )
          let settled =
            limiter.Settled(ticket, headers.to_limiter_outcome(outcome))
          let #(bot, _) = limit(bot, settled, ticket)
          case got.status == 429 && attempt < max_attempts {
            True -> perform(bot, request, route, attempt + 1)
            False -> #(bot, Ok(got))
          }
        }
      }
  }
}

/// `headers.outcome` reads the body on a 429 only, so nothing else is decoded.
fn throttle_body(got: Response(BitArray)) -> String {
  case got.status {
    429 ->
      case bit_array.to_string(got.body) {
        Ok(text) -> text
        Error(_) -> ""
      }
    _ -> ""
  }
}

fn mint(
  bot: client.Bot(Runtime(state)),
) -> #(client.Bot(Runtime(state)), Ticket) {
  let number = client.state(bot).tickets
  let bot =
    client.update(bot, fn(runtime) { Runtime(..runtime, tickets: number + 1) })
  #(bot, limiter.Ticket(number))
}

/// What the limiter said about the one ticket we asked after.
type Verdict {
  Go
  Wait
  No(limiter.Refusal)
}

/// Feed the limiter one input and read its outputs. `Wake` is dropped: the wait
/// reads `wake_after` itself, so there is no timer to arm.
fn limit(
  bot: client.Bot(Runtime(state)),
  input: limiter.Input,
  ticket: Ticket,
) -> #(client.Bot(Runtime(state)), Verdict) {
  let runtime = client.state(bot)
  let #(next, outputs) =
    limiter.step(runtime.limiter, now_ms: runtime.transport.now(), input:)
  let bot =
    client.update(bot, fn(runtime) { Runtime(..runtime, limiter: next) })

  let verdict =
    list.fold(outputs, Wait, fn(verdict, output) {
      case output {
        limiter.Send(sent) if sent == ticket -> Go
        limiter.Refuse(refused, why) if refused == ticket -> No(why)
        limiter.Note(notice) -> {
          runtime.report(Paced(notice))
          verdict
        }
        _ -> verdict
      }
    })
  #(bot, verdict)
}

/// Wait for a permit by turning the socket, so heartbeats and gateway traffic
/// are serviced and dispatches pile up in the inbox rather than being lost.
/// Gives up once the limiter's deadline passes `give_up_at`.
fn admit(
  bot: client.Bot(Runtime(state)),
  ticket: Ticket,
  verdict: Verdict,
  give_up_at: Int,
) -> #(client.Bot(Runtime(state)), Result(Nil, CallFailure)) {
  case verdict {
    Go -> #(bot, Ok(Nil))
    No(why) -> #(bot, Error(Withheld(why)))
    Wait -> {
      let runtime = client.state(bot)
      let now = runtime.transport.now()
      case limiter.wake_after(runtime.limiter, now_ms: now) {
        Some(in_ms) if now + in_ms <= give_up_at -> {
          let bot = once(bot, in_ms)
          let #(bot, verdict) = limit(bot, limiter.Tick, ticket)
          admit(bot, ticket, verdict, give_up_at)
        }
        // Too long, or blocked on something no clock brings closer. Take the
        // ticket back so the next call is not queued behind a ghost.
        other -> {
          let #(bot, _) = limit(bot, limiter.Abandoned(ticket), ticket)
          #(bot, Error(WouldBlock(option.unwrap(other, longest_wait))))
        }
      }
    }
  }
}

// -- Socket ------------------------------------------------------------------

/// A write came back `False`. `glyde/client` says that comes back as a close,
/// and the `Drop` the shard answers with is what abandons the socket.
fn gave_up(bot: client.Bot(Runtime(state))) -> client.Bot(Runtime(state)) {
  case client.state(bot).dial {
    None -> bot
    Some(dial) ->
      on_socket(bot, fn(dial) { Dial(..dial, dead: False) })
      |> client.closed(dial.conn, None)
  }
}

/// A turn drains what arrived, then services the clock. Both halves, every
/// time: a busy guild that never leaves the socket quiet would otherwise never
/// let a heartbeat out, and Discord closes a shard that stops beating.
fn woke(
  bot: client.Bot(Runtime(state)),
  next: transport.Socket,
  events: List(transport.Event),
) -> client.Bot(Runtime(state)) {
  // Carry the socket the turn handed back: the old one has stale bytes.
  on_socket(bot, fn(dial) { Dial(..dial, socket: next) })
  |> list.fold(events, _, arrived)
  |> fire_due
}

/// One socket event, as whatever the shard should hear about it. With no dial
/// there is no connection to attribute it to, so there is nothing to say.
fn arrived(
  bot: client.Bot(Runtime(state)),
  event: transport.Event,
) -> client.Bot(Runtime(state)) {
  case client.state(bot).dial {
    None -> bot
    Some(dial) -> from_socket(bot, dial, event)
  }
}

fn from_socket(
  bot: client.Bot(Runtime(state)),
  dial: Dial,
  event: transport.Event,
) -> client.Bot(Runtime(state)) {
  case event {
    transport.Opened ->
      on_socket(bot, fn(dial) { Dial(..dial, opened: True) })
      |> client.opened(dial.conn)

    transport.TextMessage(text:) -> client.received(bot, dial.conn, text)

    transport.BinaryMessage(bytes:) ->
      client.received_bytes(bot, dial.conn, bytes)

    // Advisory, and never the end. Held for the close that follows, which is
    // the one the shard acts on and the one that needs the words.
    transport.Failed(reason:) ->
      on_socket(bot, fn(dial) {
        Dial(..dial, trouble: Some(gateway.Unreachable(detail: reason)))
      })

    // Held the same way, and the status is why: a 401 upgrade halts the shard
    // where a bare reason would have it redial until the token is reset.
    transport.Refused(status:, reason:) ->
      on_socket(bot, fn(dial) {
        Dial(..dial, trouble: Some(gateway.Refused(status:, detail: reason)))
      })

    transport.Closed(code:, reason:) -> {
      let bot =
        client.update(bot, fn(runtime) { Runtime(..runtime, dial: None) })
      case dial.opened {
        // The `Failed` said more than the close will, so it wins when there
        // was one. Otherwise the close's own words are all there is.
        False ->
          client.open_failed(
            bot,
            dial.conn,
            option.unwrap(dial.trouble, gateway.Unreachable(detail: reason)),
          )
        True -> client.closed(bot, dial.conn, peer_code(code))
      }
    }
  }
}

/// Fire the one timer that is due. One per turn: firing usually arms
/// something, and the next turn reads the list again.
fn fire_due(bot: client.Bot(Runtime(state))) -> client.Bot(Runtime(state)) {
  let runtime = client.state(bot)
  let now = runtime.transport.now()

  case list.find(runtime.deadlines, fn(deadline) { deadline.at <= now }) {
    Error(_) -> bot
    Ok(gateway.Deadline(timer:, at: _, stamp:)) ->
      // Off the list before the fire, not after: the fire arms it again, and
      // removing afterwards would delete the new one.
      client.update(bot, fn(runtime) {
        Runtime(..runtime, deadlines: gateway.disarm(runtime.deadlines, timer))
      })
      |> client.timer_fired(timer, stamp)
  }
}

fn soonest(deadlines: List(gateway.Deadline)) -> Option(Int) {
  list.fold(deadlines, None, fn(best, deadline) {
    case best {
      Some(at) if at <= deadline.at -> best
      _ -> Some(deadline.at)
    }
  })
}

/// RFC 6455 forbids 1005 and 1006 on the wire, so those two mean the socket
/// had no code from the peer. Every other number came from Discord.
fn peer_code(code: Int) -> Option(Int) {
  case code {
    1005 | 1006 -> None
    code -> Some(code)
  }
}

/// The six outputs of `glyde/gateway`, answered with the transport. Arming a
/// timer is a line in a list: the loop turns the nearest one into the timeout.
fn wiring() -> client.Transport(Runtime(state)) {
  client.Transport(
    open: fn(runtime: Runtime(state), conn, host, path) {
      runtime.report(Connecting(host))
      Runtime(
        ..runtime,
        dial: Some(Dial(
          conn:,
          socket: runtime.transport.open("wss://" <> host <> path),
          opened: False,
          dead: False,
          trouble: None,
        )),
      )
    },
    send: fn(runtime: Runtime(state), payload: frame.Outbound) {
      case runtime.dial {
        None -> runtime
        Some(dial) ->
          case dial.socket.send(payload.text) {
            // Told after the write, not before: `glyde/client` promises a
            // failed write comes back as a close, never as a frame that went.
            True -> {
              runtime.report(Sent(payload.op))
              runtime
            }
            // Never raise: the rest of the batch is usually the heartbeat
            // timer. The loop turns this into the close on its next turn.
            False -> on_dial(runtime, fn(dial) { Dial(..dial, dead: True) })
          }
      }
    },
    close: fn(runtime: Runtime(state), code) {
      let _ = option.map(runtime.dial, fn(dial) { dial.socket.close(code) })
      runtime
    },
    drop: fn(runtime: Runtime(state)) {
      let _ = option.map(runtime.dial, fn(dial) { dial.socket.drop() })
      Runtime(..runtime, dial: None)
    },
    arm: fn(runtime: Runtime(state), timer, in_ms, stamp) {
      let at = runtime.transport.now() + in_ms
      Runtime(..runtime, deadlines: [
        gateway.Deadline(timer:, at:, stamp:),
        ..gateway.disarm(runtime.deadlines, timer)
      ])
    },
    cancel: fn(runtime: Runtime(state), timer) {
      Runtime(..runtime, deadlines: gateway.disarm(runtime.deadlines, timer))
    },
  )
}

/// Decode and queue. The handlers run from `settle`, never from in here: this
/// is mid-batch inside `glyde/client`, and a handler that waits on the limiter
/// would be turning the socket with the shard's outputs half performed.
fn dispatch(
  runtime: Runtime(state),
  emitted: gateway.Event,
) -> client.Next(Runtime(state)) {
  case emitted {
    gateway.Dispatch(name:, seq: _, data:) -> {
      let decoded = case event.dispatch(name, data).outcome {
        event.Decoded(decoded) -> decoded
        event.Unmodelled -> event.Raw(name:, data:)
        // The only place a host hears that a modelled event stopped fitting.
        // The listeners still get the `Raw` an unmodelled name would give.
        event.Malformed(errors:) -> {
          runtime.report(Undecodable(name:, errors:))
          event.Raw(name:, data:)
        }
      }
      client.keep(
        Runtime(..runtime, inbox: list.append(runtime.inbox, [decoded])),
      )
    }

    gateway.Reconnecting(in_ms:, resuming:, why:) -> {
      runtime.report(Reconnecting(in_ms:, resuming:, why:))
      client.keep(runtime)
    }

    gateway.Halted(reason:) -> {
      runtime.report(Halted(reason:))
      client.keep(runtime)
    }

    // READY and RESUMED arrive again as dispatches, so a listener sees them
    // whole rather than through the core's projection.
    gateway.Ready(..) | gateway.Resumed -> client.keep(runtime)
  }
}
