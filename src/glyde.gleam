//// glyde is a sans-IO Discord library that brings its own IO. `glyde/gateway`
//// is the protocol state machine; this module is the supervision tree already
//// wired to it, so a bot is the handlers and nothing else.
////
//// ```gleam
//// import gleam/bool
//// import gleam/erlang/process
//// import gleam/otp/static_supervisor as supervisor
//// import glyde
//// import glyde/intents
//// import glyde/message
////
//// pub fn main() -> Nil {
////   let bot =
////     glyde.new(token:, intents: intents.new([intents.GuildMessages]))
////     |> glyde.on_message(fn(api, msg) {
////       use <- bool.guard(msg.content != "!ping", Nil)
////       let _ = message.reply(api, msg, message.text("pong!"))
////       Nil
////     })
////
////   let assert Ok(_) =
////     supervisor.new(supervisor.OneForOne)
////     |> supervisor.add(glyde.supervised(bot))
////     |> supervisor.start
////
////   process.sleep_forever()
//// }
//// ```
////
//// Each event is handed to a fresh process under a supervisor, so a slow or
//// crashing handler never holds up the next one. An endpoint call blocks that
//// one process on the rate limiter and the network; the shard keeps reading.
////
//// `glyde/client` is the layer below, for driving the machine yourself.

import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/result
import glyde/api
import glyde/event
import glyde/gateway
import glyde/id
import glyde/intents.{type Intents}
import glyde/interaction
import glyde/internal/limiter_actor
import glyde/internal/runtime
import glyde/internal/version
import glyde/message
import glyde/ready
import glyde/rest
import glyde/status
import glyde/token
import glyde/transport
import glyde/transport/erlang as erlang_transport

/// The Discord API version glyde speaks, for both the gateway and REST.
pub const api_version: Int = version.number

// The types a handler meets, so the common case needs one import.

pub type Api =
  api.Api

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

pub type Status =
  status.Status

pub type Call(a) =
  rest.Call(a)

pub type CallFailure =
  api.CallFailure

pub type Failure =
  rest.Failure

/// The platform half: a socket, an HTTP client and a clock.
pub type Transport =
  transport.Transport

/// A bot before it starts. Opaque and a value: every builder gives back a new
/// one.
pub opaque type Bot {
  Bot(
    gateway: gateway.Config,
    rest: rest.Config,
    listeners: List(fn(Api, Event) -> Nil),
    status: fn(Status) -> Nil,
    transport: Transport,
    names: Names,
  )
}

/// The names glyde's own processes register under. They belong to the bot
/// value rather than to a start, so every start of the same bot — including
/// a supervisor restarting it — lands on the same three.
type Names {
  Names(
    limiter: process.Name(limiter_actor.Message),
    handlers: process.Name(factory.Message(runtime.Job, Nil)),
    shard: process.Name(runtime.Message),
  )
}

/// One shard, no compression, a real socket, and a line on stderr when
/// something goes wrong.
///
/// Build a bot once, at startup, and keep the value. This mints the three
/// process names its tree registers under, and `process.new_name` creates an
/// atom that is never collected — so a `new` per start would fill the atom
/// table and take the VM down with it. Holding the names on the bot is what
/// makes `supervised` safe to restart forever.
pub fn new(token secret: String, intents intents: Intents) -> Bot {
  Bot(
    gateway: gateway.config(token: token.new(secret), intents:),
    rest: rest.config(rest.bot(secret)),
    listeners: [],
    status: status.printing,
    transport: erlang_transport.default(),
    names: Names(
      limiter: process.new_name("glyde_limiter"),
      handlers: process.new_name("glyde_handlers"),
      shard: process.new_name("glyde_shard"),
    ),
  )
}

/// Every MESSAGE_CREATE. Add as many as you like; each runs in the same
/// handler process for that event, in the order added.
pub fn on_message(bot: Bot, handler: fn(Api, Message) -> a) -> Bot {
  use api, event <- on_event(bot)
  case event {
    event.MessageCreate(message:) -> {
      handler(api, message)
      Nil
    }
    _ -> Nil
  }
}

/// READY, which carries the bot's own user and the guilds it is in. Sent again
/// after every fresh identify, so this is not once per process.
pub fn on_ready(bot: Bot, handler: fn(Api, Ready) -> a) -> Bot {
  use api, event <- on_event(bot)
  case event {
    event.ReadyEvent(ready) -> {
      handler(api, ready)
      Nil
    }
    _ -> Nil
  }
}

/// Every INTERACTION_CREATE: slash commands, buttons, autocomplete.
pub fn on_interaction(bot: Bot, handler: fn(Api, Interaction) -> a) -> Bot {
  use api, event <- on_event(bot)
  case event {
    event.InteractionCreate(interaction:) -> {
      handler(api, interaction)
      Nil
    }
    _ -> Nil
  }
}

/// Every dispatch, decoded. One glyde does not model arrives as `event.Raw`
/// with Discord's payload untouched.
pub fn on_event(bot: Bot, handler: fn(Api, Event) -> a) -> Bot {
  let listen = fn(api, event) {
    handler(api, event)
    Nil
  }
  Bot(..bot, listeners: list.append(bot.listeners, [listen]))
}

/// Watch the runtime: dials, reconnects, halts, failed sends, diagnostics.
/// Runs on the shard process (or the limiter for `Paced`), not a handler
/// process, so keep it cheap.
pub fn on_status(bot: Bot, handler: fn(Status) -> a) -> Bot {
  Bot(..bot, status: fn(it) {
    handler(it)
    Nil
  })
}

/// Run over a socket, a clock and an HTTP client of your own. The rate limiter
/// sits around `request`, so yours is paced without knowing it.
pub fn with_transport(bot: Bot, transport: Transport) -> Bot {
  Bot(..bot, transport:)
}

/// A child specification, for putting glyde under a supervision tree of your
/// own. Restarting is safe: the names live on the bot, so the tree comes back
/// on the same ones.
///
/// ```gleam
/// supervisor.new(supervisor.OneForOne)
/// |> supervisor.add(glyde.supervised(bot))
/// |> supervisor.start
/// ```
pub fn supervised(
  bot: Bot,
) -> supervision.ChildSpecification(supervisor.Supervisor) {
  supervision.supervisor(fn() { supervisor.start(tree(bot)) })
}

/// Build the supervision tree and start it. Returns the top supervisor's pid,
/// so the caller can monitor it. Nothing here blocks, so a `main` that has
/// nothing else to do wants `process.sleep_forever()` after it.
///
/// Prefer `supervised` when there is a tree of your own to hang this under,
/// which is what makes a dead bot come back.
///
/// One bot is one tree: starting the same bot twice over fails the second
/// time, because its names are already registered to the first.
///
/// A bad token or a disallowed intent stops the shard for good rather than
/// reconnecting. Nothing restarts it, and nothing exits on your behalf: watch
/// `status.Halted` through `on_status` if the program should come down with
/// it.
pub fn start(bot: Bot) -> Result(Pid, actor.StartError) {
  supervisor.start(tree(bot))
  |> result.map(fn(started) { started.pid })
}

fn tree(bot: Bot) -> supervisor.Builder {
  let handle =
    api.new(
      process.named_subject(bot.names.limiter),
      bot.rest,
      bot.transport.request,
    )
  let listeners = bot.listeners
  let deliver = fn(event: Event) -> runtime.Job {
    fn() { list.each(listeners, fn(listen) { listen(handle, event) }) }
  }
  let report = bot.status

  let limiter =
    supervision.worker(fn() {
      limiter_actor.start(bot.names.limiter, bot.transport.now, fn(notice) {
        report(status.Paced(notice))
      })
    })

  let handlers =
    factory.worker_child(handler_child)
    |> factory.restart_strategy(supervision.Temporary)
    |> factory.named(bot.names.handlers)
    |> factory.supervised

  let shard =
    supervision.worker(fn() {
      runtime.start(
        bot.names.shard,
        bot.gateway,
        bot.transport,
        bot.names.handlers,
        deliver,
        report,
      )
    })
    |> supervision.restart(supervision.Transient)

  supervisor.new(supervisor.OneForOne)
  |> supervisor.add(limiter)
  |> supervisor.add(handlers)
  |> supervisor.add(shard)
}

/// Linked to the factory supervisor, so a handler that crashes is logged by
/// OTP and restarted never.
fn handler_child(job: runtime.Job) -> actor.StartResult(Nil) {
  let pid = process.spawn(job)
  Ok(actor.Started(pid:, data: Nil))
}
