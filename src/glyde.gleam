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
import gleam/result
import gleam/string
import glyde/api/channel
import glyde/event
import glyde/gateway
import glyde/gateway/frame
import glyde/id
import glyde/intents.{type Intents}
import glyde/internal/decode_error
import glyde/internal/runtime
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
  runtime.run(
    config: bot.gateway,
    transport: bot.transport,
    state: bot.state,
    // Threaded, not broadcast: each listener sees what the last returned.
    deliver: fn(state, event) {
      list.fold(bot.listeners, state, fn(state, listen) {
        listen(bot, state, event)
      })
    },
    report: fn(report) { bot.status(heard(report)) },
  )
}

/// The loop's reports, by the names a host reads them under.
fn heard(report: runtime.Report) -> Status {
  case report {
    runtime.Connecting(host:) -> Connecting(host:)
    runtime.Reconnecting(in_ms:, resuming:, why:) ->
      Reconnecting(in_ms:, resuming:, why:)
    runtime.Halted(reason:) -> Halted(reason:)
    runtime.Sent(op:) -> Sent(op:)
    runtime.Undecodable(name:, errors:) -> Undecodable(name:, errors:)
    runtime.Noted(notice) -> Note(notice)
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
