//// glyde is a sans-IO Discord library that brings its own IO. `glyde/gateway`
//// is the protocol state machine; this module is the socket, clock and HTTP
//// client already wired to it, so a bot is the handlers and nothing else.
////
//// ```gleam
//// import envoy
//// import glyde
//// import glyde/intents
//// import glyde/message
////
//// pub fn main() -> Nil {
////   let assert Ok(token) = envoy.get("DISCORD_TOKEN")
////
////   glyde.new(token:, state: 0, intents: intents.new([
////     intents.Guilds, intents.GuildMessages, intents.MessageContent,
////   ]))
////   |> glyde.on_message(fn(pongs, msg) {
////     use <- glyde.when(msg.content == "!ping", or: pongs)
////     use posted <- glyde.do(message.reply(msg, message.text("pong!")))
////     let pongs = case posted { Ok(_) -> pongs + 1 Error(_) -> pongs }
////     glyde.continue(pongs)
////   })
////   |> glyde.run
//// }
//// ```
////
//// A handler is given the bot's state and says what happens next: usually
//// `continue` with the new one, since Gleam has no mutable cell to close over.
//// `do` describes a request and carries on once the loop has made it, so a
//// handler never blocks on the network itself. `when` guards the rest
//// of the handler behind a condition. Handlers run in the order they were
//// added, each seeing what the one before left. Nothing to remember passes
//// `Nil`.
////
//// `glyde/client` is the layer below, for driving the machine yourself.

import gleam/int
import gleam/list
import gleam/result
import glyde/event
import glyde/gateway
import glyde/id
import glyde/intents.{type Intents}
import glyde/interaction
import glyde/internal/runtime
import glyde/internal/version
import glyde/message
import glyde/ready
import glyde/rest
import glyde/rest/error
import glyde/rest/limiter
import glyde/status
import glyde/token
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

pub type Interaction =
  interaction.Interaction

pub type ChannelId =
  id.ChannelId

pub type Call(a) =
  rest.Call(a)

/// Why a REST call did not produce an answer. Discord answered and said no,
/// nothing answered at all, or glyde never sent it.
pub type CallFailure {
  /// Discord answered, with a non-2xx or a body its own decoder would not
  /// take. `glyde/rest/error` is where the questions about it live. A 429 has
  /// already been waited out and retried before it arrives here.
  Refused(rest.Failure)
  /// The request never got an answer: no route to the host, a timeout, a proxy
  /// speaking something that is not HTTP.
  Unreachable(transport.Unreachable)
  /// Never sent. The rate limiter wanted it held for `wait_ms`, which is longer
  /// than a handler may keep the events queued behind it waiting, so it was
  /// failed rather than slept on. Discord is fine; try again later.
  WouldBlock(wait_ms: Int)
  /// Never sent, and waiting would not help: the limiter will not send it at
  /// all. In practice the invalid-request budget is spent.
  Withheld(limiter.Refusal)
}

pub fn describe_failure(failure: CallFailure) -> String {
  case failure {
    Refused(refusal) -> error.describe(refusal)
    Unreachable(reason) -> transport.describe(reason)
    WouldBlock(wait_ms:) ->
      "not sent, the rate limiter wants " <> int.to_string(wait_ms) <> "ms"
    Withheld(limiter.InvalidBudgetSpent) ->
      "not sent, the invalid-request budget is spent"
    Withheld(limiter.Backlogged) -> "not sent, too many calls waiting"
    Withheld(limiter.DuplicateTicket) -> "not sent, duplicate ticket"
  }
}

pub type Failure =
  rest.Failure

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
    /// the one before it left.
    listeners: List(fn(state, Event) -> Next(state)),
    status: fn(status.Status) -> Nil,
    transport: Transport,
  )
}

/// One shard, no compression, a real socket, and a line on stderr when
/// something goes wrong. For sharding, compression or a presence at connect
/// time, build a `gateway.Config` and drive it with `glyde/client`.
pub fn new(
  token secret: String,
  state state: state,
  intents intents: Intents,
) -> Bot(state) {
  Bot(
    gateway: gateway.config(token: token.new(secret), intents:),
    rest: rest.config(rest.bot(secret)),
    state:,
    listeners: [],
    status: status.printing,
    transport: erlang_transport.default(),
  )
}

/// Every MESSAGE_CREATE. Add as many as you like.
pub fn on_message(
  bot: Bot(state),
  handler: fn(state, Message) -> Next(state),
) -> Bot(state) {
  use state, event <- on_event(bot)
  case event {
    event.MessageCreate(message:) -> handler(state, message)
    _ -> continue(state)
  }
}

/// READY, which carries the bot's own user and the guilds it is in. Sent again
/// after every fresh identify, so this is not once per process.
pub fn on_ready(
  bot: Bot(state),
  handler: fn(state, Ready) -> Next(state),
) -> Bot(state) {
  use state, event <- on_event(bot)
  case event {
    event.ReadyEvent(ready) -> handler(state, ready)
    _ -> continue(state)
  }
}

/// Every INTERACTION_CREATE: slash commands, buttons, autocomplete.
pub fn on_interaction(
  bot: Bot(state),
  handler: fn(state, Interaction) -> Next(state),
) -> Bot(state) {
  use state, event <- on_event(bot)
  case event {
    event.InteractionCreate(interaction:) -> handler(state, interaction)
    _ -> continue(state)
  }
}

/// Every dispatch, decoded. One glyde does not model arrives as `event.Raw`
/// with Discord's payload untouched, so the `case` needs no error arm. One
/// glyde does model whose payload no longer fits arrives as `Raw` too, and the
/// decoder errors go to `on_status` as `Undecodable`.
pub fn on_event(
  bot: Bot(state),
  handler: fn(state, Event) -> Next(state),
) -> Bot(state) {
  Bot(..bot, listeners: list.append(bot.listeners, [handler]))
}

/// Watch the runtime: dials, reconnects, halts, failed sends, diagnostics.
/// Replaces `status.printing`, which puts the ones that matter on stderr.
/// `glyde/status` has the type and the words for it.
pub fn on_status(
  bot: Bot(state),
  handler: fn(status.Status) -> Nil,
) -> Bot(state) {
  Bot(..bot, status: handler)
}

/// Run over a socket, a clock and an HTTP client of your own. Anything that
/// answers `transport.Transport` works, so a test needs no network. The rate
/// limiter sits around `request`, so yours is paced without knowing it.
pub fn with_transport(bot: Bot(state), transport: Transport) -> Bot(state) {
  Bot(..bot, transport:)
}

/// What a handler returns: the state to carry on with, or a request to make
/// first and what to do once it is answered. A description, not an action:
/// the loop performs it, pacing it through the rate limiter and keeping the
/// gateway serviced while it waits, which a handler blocking on its own could
/// not.
pub opaque type Next(state) {
  // A reader over what only the bot knows, so `do` can build the request
  // without a `Bot` in the handler's hands.
  Next(run: fn(Env) -> runtime.Step(state))
}

type Env =
  rest.Config

/// Done with this event: here is the state for the next one.
pub fn continue(state: state) -> Next(state) {
  Next(fn(_) { runtime.Done(state) })
}

/// Run `then` only when the condition holds; otherwise `continue(fallback)`.
/// The `bool.guard` shape for a handler:
///
/// ```gleam
/// use <- glyde.when(msg.content == "!ping", or: pongs)
/// ```
pub fn when(
  cond: Bool,
  or fallback: state,
  then next: fn() -> Next(state),
) -> Next(state) {
  case cond {
    True -> next()
    False -> continue(fallback)
  }
}

/// Make a call and hand `then` the whole `Result`, so what Discord said or why
/// it did not can go into the state you continue with. The last argument, so
/// `use` fits:
///
/// ```gleam
/// use answer <- glyde.do(guild.get(guild_id, with_counts: False))
/// ```
pub fn do(
  call: Call(a),
  then: fn(Result(a, CallFailure)) -> Next(state),
) -> Next(state) {
  Next(fn(env: Env) {
    let built = rest.request_bytes(env, call)
    runtime.Perform(request: built, route: rest.route(call), resume: fn(answer) {
      call |> answered(answer) |> then() |> lower(env)
    })
  })
}

fn lower(next: Next(state), env: Env) -> runtime.Step(state) {
  next.run(env)
}

fn answered(call: Call(a), answer: runtime.Answer) -> Result(a, CallFailure) {
  case answer {
    Error(runtime.Unreachable(e)) -> Error(Unreachable(e))
    Error(runtime.WouldBlock(ms)) -> Error(WouldBlock(ms))
    Error(runtime.Withheld(r)) -> Error(Withheld(r))
    Ok(response) ->
      rest.response(
        call,
        status: response.status,
        headers: response.headers,
        body: response.body,
      )
      |> result.map_error(Refused)
  }
}

/// Connect, and keep connected until the bot halts. Blocks: the loop is this
/// process, and `main` returning takes the VM with it.
pub fn run(bot: Bot(state)) -> Nil {
  let env = bot.rest
  runtime.run(
    config: bot.gateway,
    transport: bot.transport,
    state: bot.state,
    // Threaded, not broadcast: each listener starts from the state the last
    // one finished with, requests and all.
    deliver: fn(state, event) {
      list.fold(bot.listeners, runtime.Done(state), fn(step, listen) {
        runtime.after(step, fn(state) { lower(listen(state, event), env) })
      })
    },
    report: bot.status,
  )
}
