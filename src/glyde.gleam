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
////   use token <- glyde.require_token(envoy.get("DISCORD_TOKEN"))
////
////   glyde.new(token:, state: 0, intents: intents.new([
////     intents.Guilds, intents.GuildMessages, intents.MessageContent,
////   ]))
////   |> glyde.on_message(fn(pongs, msg) {
////     use <- glyde.when(msg.content == "!ping", or: pongs)
////     use _ <- glyde.try(message.reply(msg, message.text("pong!")), or: pongs)
////     glyde.continue(pongs + 1)
////   })
////   |> glyde.run
//// }
//// ```
////
//// A handler is given the bot's state and says what happens next: usually
//// `continue` with the new one, since Gleam has no mutable cell to close over.
//// `try` and `attempt` describe a request and carry on once the loop has made
//// it, so a handler never blocks on the network itself. `when` guards the rest
//// of the handler behind a condition. Handlers run in the order they were
//// added, each seeing what the one before left. Nothing to remember passes
//// `Nil`.
////
//// `glyde/client` is the layer below, for driving the machine yourself.

import gleam/http/request
import gleam/io
import gleam/list
import gleam/result
import gleam/string
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
import glyde/rest/body
import glyde/status
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

pub type CallFailure =
  status.CallFailure

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
  // A reader over what only the bot knows, so `attempt` can build the request
  // without a `Bot` in the handler's hands.
  Next(run: fn(Env) -> runtime.Step(state))
}

type Env {
  Env(rest: rest.Config, status: fn(status.Status) -> Nil)
}

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

/// Make a call and hand `then` the answer if it worked, or `continue(fallback)`
/// if it did not. The failure is dropped, so use `attempt` where the reason
/// matters.
///
/// ```gleam
/// use posted <- glyde.try(message.reply(msg, message.text("hi")), or: pongs)
/// ```
pub fn try(
  call: Call(a),
  or fallback: state,
  then next: fn(a) -> Next(state),
) -> Next(state) {
  use answer <- attempt(call)
  case answer {
    Ok(value) -> next(value)
    Error(_) -> continue(fallback)
  }
}

/// Make a call and hand `then` the whole `Result`, so what Discord said or why
/// it did not can go into the state you continue with. The last argument, so
/// `use` fits:
///
/// ```gleam
/// use answer <- glyde.attempt(guild.get(guild_id))
/// ```
pub fn attempt(
  call: Call(a),
  then: fn(Result(a, CallFailure)) -> Next(state),
) -> Next(state) {
  Next(fn(env: Env) {
    let built = rest.request(env.rest, call)
    let built = request.set_body(built, body.to_bits(built.body))
    runtime.Perform(request: built, route: rest.route(call), resume: fn(answer) {
      lower(then(answered(call, answer)), env)
    })
  })
}

fn lower(next: Next(state), env: Env) -> runtime.Step(state) {
  next.run(env)
}

fn answered(call: Call(a), answer: runtime.Answer) -> Result(a, CallFailure) {
  case answer {
    Ok(response) ->
      rest.response(
        call,
        status: response.status,
        headers: response.headers,
        body: response.body,
      )
      |> result.map_error(status.Refused)
    // The loop never builds a `Refused`: it has no decoder to be refused by.
    Error(unsent) -> Error(unsent)
  }
}

/// Connect, and keep connected until the bot halts. Blocks: the loop is this
/// process, and `main` returning takes the VM with it.
pub fn run(bot: Bot(state)) -> Nil {
  let env = Env(rest: bot.rest, status: bot.status)
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
