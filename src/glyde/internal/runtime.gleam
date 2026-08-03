//// The loop under `glyde.run`. Nothing in here is API: `glyde` names what a
//// user sees, this module does it.

import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import glyde/client
import glyde/event.{type Event}
import glyde/gateway
import glyde/gateway/frame
import glyde/transport.{type Transport}

/// What the loop saw that is not a Discord event. `glyde` turns each into its
/// own `Status`, which is where the words live.
pub type Report {
  Connecting(host: String)
  Reconnecting(in_ms: Int, resuming: Bool, why: gateway.Why)
  Halted(reason: gateway.Halt)
  Sent(op: frame.Opcode)
  Undecodable(name: String, errors: List(decode.DecodeError))
  Noted(gateway.Notice)
}

/// Connect and loop until the shard halts. `deliver` is every listener folded
/// into one, so this module never learns what a `glyde.Bot` is.
pub fn run(
  config config: gateway.Config,
  transport transport: Transport,
  state state: state,
  deliver deliver: fn(state, Event) -> state,
  report report: fn(Report) -> Nil,
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
      dial: None,
      deadlines: [],
    ),
    transport: wiring(),
  )
  |> client.on_event(dispatch)
  |> client.on_notice(fn(runtime: Runtime(state), notice) {
    runtime.report(Noted(notice))
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
    deliver: fn(state, Event) -> state,
    report: fn(Report) -> Nil,
    /// Your value, as the last listener left it.
    user: state,
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

/// One turn of the runtime. Every branch ends in a tail call, so this runs for
/// the life of the bot in constant space.
fn spin(bot: client.Bot(Runtime(state))) -> Nil {
  case client.is_terminal(bot) {
    True -> Nil
    False -> {
      let runtime = client.state(bot)

      case runtime.dial {
        // A write already said the socket is gone, so there is nothing to read.
        Some(Dial(dead: True, ..)) -> spin(gave_up(bot))

        // The read timeout is the timer: whichever comes first wakes us.
        Some(dial) -> {
          let #(next, events) = dial.socket.turn(waiting(runtime))
          spin(woke(bot, next, events))
        }

        None -> {
          runtime.transport.idle(waiting(runtime))
          spin(fire_due(bot))
        }
      }
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
            // Reported after the write, not before: `glyde/client` promises a
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
        Runtime(..runtime, user: runtime.deliver(runtime.user, decoded)),
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
