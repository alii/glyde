//// glyde is a sans-IO Discord library that brings its own IO. `glyde/gateway`
//// is the protocol state machine; this module is the socket, clock and HTTP
//// client already wired to it, so a bot is the handlers and nothing else.
////
//// ```gleam
//// import envoy
//// import gleam/int
//// import glyde
//// import glyde/intents
////
//// pub fn main() -> Nil {
////   use token <- glyde.require_token(envoy.get("DISCORD_TOKEN"))
////
////   let intents = intents.new([intents.Guilds, intents.GuildMessages])
////
////   glyde.new(token:, intents:, state: 0)
////   |> glyde.on_message(fn(bot, pongs, message) {
////     case message.content {
////       "!ping" -> {
////         glyde.reply(bot, message, "pong! #" <> int.to_string(pongs + 1))
////         pongs + 1
////       }
////       _ -> pongs
////     }
////   })
////   |> glyde.run
//// }
//// ```
////
//// A handler is given the bot's state and returns the next one, since Gleam
//// has no mutable cell to close over. Handlers run in the order they were
//// added, each seeing what the one before returned. Nothing to remember
//// passes `Nil`.
////
//// `glyde/client` is the layer below, for driving the machine yourself.

import gleam/dynamic/decode
import gleam/http/request
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import glyde/api/channel
import glyde/client
import glyde/event
import glyde/gateway
import glyde/gateway/frame
import glyde/id
import glyde/intents.{type Intents}
import glyde/internal/decode_error
import glyde/internal/version
import glyde/model/message
import glyde/model/ready
import glyde/payload/message as outgoing
import glyde/rest
import glyde/rest/body
import glyde/rest/error
import glyde/transport
import glyde/transport/erlang as erlang_transport

/// The Discord API version glyde speaks, for both the gateway and REST.
pub const api_version: Int = version.number

// The types a handler meets, so the common case needs one import.

pub type Message =
  message.Message

pub type Ready =
  ready.Ready

pub type Event =
  event.Event

pub type ChannelId =
  id.ChannelId

pub type Body =
  body.Body

pub type Call(a) =
  rest.Call(a)

pub type Failure =
  rest.Failure

/// Why a REST call did not produce an answer. The two halves are different
/// kinds of problem: Discord answered and said no, or nothing answered at all.
pub type CallFailure {
  /// Discord answered, with a non-2xx or a body its own decoder would not
  /// take. `glyde/rest/error` is where the questions about it live.
  Refused(Failure)
  /// The request never got an answer: no route to the host, a timeout, a proxy
  /// speaking something that is not HTTP.
  Unreachable(transport.Unreachable)
}

/// The platform half: a socket, an HTTP client and a clock.
pub type Transport =
  transport.Transport

/// A bot, carrying one value of your own. Opaque and a value: every builder
/// gives back a new one.
pub opaque type Bot(state) {
  Bot(
    gateway: gateway.Config,
    rest: rest.Config,
    state: state,
    /// All called for every event, in the order added, each handed the state
    /// the one before it returned.
    listeners: List(fn(Bot(state), state, Event) -> state),
    status: fn(Status) -> Nil,
    transport: Transport,
  )
}

/// Read a token, or panic. Right in `main`, where the alternative is a bot
/// that looks like it started and is closed with 4004 ten seconds later.
pub fn require_token(source: Result(String, a), next: fn(String) -> b) -> b {
  case result.map(source, string.trim) {
    Ok(token) if token != "" -> next(token)
    _ -> {
      io.println_error("glyde: no bot token, so there is nothing to connect to")
      panic as "no bot token"
    }
  }
}

/// One shard, no compression, a real socket, and a line on stderr when
/// something goes wrong. For sharding, compression or a presence at connect
/// time, build a `gateway.Config` and drive it with `glyde/client`.
pub fn new(
  token token: String,
  state state: state,
  intents intents: Intents,
) -> Bot(state) {
  Bot(
    gateway: gateway.config(token:, intents:),
    rest: rest.config(rest.bot(token)),
    state:,
    listeners: [],
    status: printing,
    transport: erlang_transport.default(),
  )
}

/// Every MESSAGE_CREATE. Add as many as you like.
pub fn on_message(
  bot: Bot(state),
  handler: fn(Bot(state), state, Message) -> state,
) -> Bot(state) {
  use bot, state, event <- on_event(bot)
  case event {
    event.MessageCreate(message:) -> handler(bot, state, message)
    _ -> state
  }
}

/// READY, which carries the bot's own user and the guilds it is in. Sent again
/// after every fresh identify, so this is not once per process.
pub fn on_ready(
  bot: Bot(state),
  handler: fn(Bot(state), state, Ready) -> state,
) -> Bot(state) {
  use bot, state, event <- on_event(bot)
  case event {
    event.ReadyEvent(ready) -> handler(bot, state, ready)
    _ -> state
  }
}

/// Every dispatch, decoded. One glyde does not model arrives as `event.Raw`
/// with Discord's payload untouched, so the `case` needs no error arm. One
/// glyde does model whose payload no longer fits arrives as `Raw` too, and the
/// decoder errors go to `on_status` as `Undecodable`.
pub fn on_event(
  bot: Bot(state),
  handler: fn(Bot(state), state, Event) -> state,
) -> Bot(state) {
  Bot(..bot, listeners: list.append(bot.listeners, [handler]))
}

/// Watch the runtime: dials, reconnects, halts, diagnostics. Replaces the
/// default, which prints the first three to stderr.
pub fn on_status(bot: Bot(state), handler: fn(Status) -> Nil) -> Bot(state) {
  Bot(..bot, status: handler)
}

/// Run over a socket, a clock and an HTTP client of your own. Anything that
/// answers `transport.Transport` works, so a test needs no network.
pub fn with_transport(bot: Bot(state), transport: Transport) -> Bot(state) {
  Bot(..bot, transport:)
}

/// Reply to a message: same channel, `message_reference` set, so Discord shows
/// it attached rather than as a bare message.
pub fn reply(bot: Bot(state), to: Message, text: String) -> Nil {
  send(bot, to.channel_id, outgoing.create_body(outgoing.reply_to(to.id, text)))
}

/// Post to a channel. Build the body with `message.create_body`: it writes
/// the `attachments` cross-reference an upload needs.
pub fn send(bot: Bot(state), channel: ChannelId, body: Body) -> Nil {
  case call(bot, channel.create_message(channel, body)) {
    Ok(_) -> Nil
    Error(failure) -> bot.status(CallFailed(failure))
  }
}

/// Any endpoint, so the whole REST builder stays reachable from a handler.
/// Blocks until Discord answers and hands the answer back, so a handler can
/// put what it got into the state it returns.
pub fn call(bot: Bot(state), call: Call(a)) -> Result(a, CallFailure) {
  let built = rest.request(bot.rest, call)
  let built = request.set_body(built, body.to_bits(built.body))

  case bot.transport.request(built) {
    Ok(response) ->
      rest.response(
        call,
        status: response.status,
        headers: response.headers,
        body: response.body,
      )
      |> result.map_error(Refused)
    Error(reason) -> Error(Unreachable(reason))
  }
}

/// Connect, and keep connected until the bot halts. Blocks: the loop is this
/// process, and `main` returning takes the VM with it.
pub fn run(bot: Bot(state)) -> Nil {
  // The core has no randomness, so the jitter seed comes from out here. A
  // fleet gives each shard a different one with `client.with_seed`.
  let shard = gateway.new(config: bot.gateway, seed: int.random(2_147_483_647))

  client.from_shard(
    shard:,
    state: Runtime(bot:, user: bot.state, dial: None, deadlines: []),
    transport: wiring(),
  )
  |> client.on_event(dispatch)
  |> client.on_notice(fn(runtime: Runtime(state), notice) {
    runtime.bot.status(Note(notice))
    runtime
  })
  |> client.start
  |> spin
}

/// What the loop threads. `deadlines` is a list and not a `Dict`: there are
/// four timers and `gleam/dict` does not iterate in a defined order.
type Runtime(state) {
  Runtime(
    bot: Bot(state),
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
          runtime.bot.transport.idle(waiting(runtime))
          spin(fire_due(bot))
        }
      }
    }
  }
}

/// How long this turn may block: the nearest deadline, or the floor.
fn waiting(runtime: Runtime(state)) -> Int {
  case soonest(runtime.deadlines) {
    Some(at) -> int.max(0, at - runtime.bot.transport.now())
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
  let now = runtime.bot.transport.now()

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
      runtime.bot.status(Connecting(host))
      Runtime(
        ..runtime,
        dial: Some(Dial(
          conn:,
          socket: runtime.bot.transport.open("wss://" <> host <> path),
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
              runtime.bot.status(Sent(payload.op))
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
      let at = runtime.bot.transport.now() + in_ms
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
          runtime.bot.status(Undecodable(name:, errors:))
          event.Raw(name:, data:)
        }
      }
      // Threaded, not broadcast: each listener sees what the last returned.
      let user =
        list.fold(runtime.bot.listeners, runtime.user, fn(user, listen) {
          listen(runtime.bot, user, decoded)
        })
      client.keep(Runtime(..runtime, user:))
    }

    gateway.Reconnecting(in_ms:, resuming:, why:) -> {
      runtime.bot.status(Reconnecting(in_ms:, resuming:, why:))
      client.keep(runtime)
    }

    gateway.Halted(reason:) -> {
      runtime.bot.status(Halted(reason:))
      client.keep(runtime)
    }

    // READY and RESUMED arrive again as dispatches, so a listener sees them
    // whole rather than through the core's projection.
    gateway.Ready(..) | gateway.Resumed -> client.keep(runtime)
  }
}

/// Everything the runtime does that is not a Discord event. Every variant
/// carries the value, never a rendering: `describe` is the only way back.
pub type Status {
  Connecting(host: String)
  /// The connection is gone and a redial is armed. `why` is what ended it, so
  /// a host printing this says more than "the bot is flapping".
  Reconnecting(in_ms: Int, resuming: Bool, why: gateway.Why)
  Halted(reason: gateway.Halt)
  /// A frame went out, by opcode. Never the body: IDENTIFY carries the token.
  Sent(op: frame.Opcode)
  /// A REST call glyde made on your behalf did not work.
  CallFailed(failure: CallFailure)
  /// A dispatch glyde models whose `d` no longer fits its decoder: a glyde bug
  /// or a Discord schema change. The listeners saw it as `event.Raw`.
  Undecodable(name: String, errors: List(decode.DecodeError))
  /// A diagnostic from the core: a zombie connection, a dropped command, a
  /// frame that would not decode.
  Note(gateway.Notice)
}

/// The default, on stderr. `Sent`, `Note` and `Undecodable` are for somebody
/// who went looking, so they are dropped here; `on_status` sees all of them.
fn printing(status: Status) -> Nil {
  case status {
    // `Undecodable` fires once per dispatch, so a schema change to a busy
    // event is a write per event on the loop that owes Discord a heartbeat.
    Sent(_) | Note(_) | Undecodable(..) -> Nil
    _ -> io.println_error("glyde: " <> describe(status))
  }
}

/// One line per status, for a host that just wants to print them. Each arm
/// hands off to the module that owns the value, so a host writing its own
/// logging can reach the same words.
pub fn describe(status: Status) -> String {
  case status {
    Connecting(host:) -> "connecting to " <> host
    Reconnecting(in_ms:, resuming:, why:) ->
      "reconnecting in "
      <> int.to_string(in_ms)
      <> "ms, "
      <> case resuming {
        True -> "resuming"
        False -> "fresh identify"
      }
      <> ": "
      <> gateway.describe_why(why)
    Halted(reason:) -> "halted: " <> gateway.describe_halt(reason)
    Sent(op:) -> "sent op " <> int.to_string(frame.opcode_to_int(op))
    CallFailed(Refused(failure)) -> "rest failed: " <> error.describe(failure)
    CallFailed(Unreachable(reason)) ->
      "rest failed: " <> transport.describe(reason)
    Undecodable(name:, errors:) ->
      "could not decode " <> name <> ": " <> decode_error.describe(errors)
    Note(notice) -> "note: " <> gateway.describe(notice)
  }
}
