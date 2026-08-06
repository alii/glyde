# glyde

A Discord library for Gleam.

Glyde is currently pre-1.0.0 release, so please try it out but be wary of papercuts.

```sh
gleam add glyde
```

Here's a bot that answers `!ping`:

```gleam
import envoy
import gleam/bool
import gleam/erlang/process
import gleam/io
import gleam/otp/static_supervisor as supervisor
import glyde
import glyde/intents
import glyde/message

pub fn main() -> Nil {
  let assert Ok(token) = envoy.get("DISCORD_TOKEN")

  let bot =
    glyde.new(
      token:,
      intents: intents.new([
        intents.Guilds,
        intents.GuildMessages,
        intents.MessageContent,
      ]),
    )
    |> glyde.on_ready(fn(_api, ready) {
      io.println("logged in as " <> ready.me.user.username)
    })
    |> glyde.on_message(fn(api, msg) {
      use <- bool.guard(msg.content != "!ping", Nil)
      let _ = message.reply(api, msg, message.text("pong!"))
      Nil
    })

  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(glyde.supervised(bot))
    |> supervisor.start

  process.sleep_forever()
}
```

Run it with `DISCORD_TOKEN=... gleam run`.

The bot value is built once and reused. `glyde.new` registers process names as
atoms, which are never garbage collected, so building a new bot on every
restart will exhaust the atom table.

Everything else your app runs goes in the same supervisor.

`glyde.start` starts the same tree without a supervisor above it and returns a
pid.

Intents control which events Discord sends. `MessageContent` and the two
member intents have to be enabled on your app's settings page, or the gateway
closes the connection immediately.

Handlers:

| handler          | fires on                                       |
| ---------------- | ---------------------------------------------- |
| `on_message`     | someone posted a message                       |
| `on_interaction` | a slash command, a button, autocomplete        |
| `on_ready`       | connected, with the bot's own user and guilds  |
| `on_event`       | every dispatch, decoded, to match on yourself  |
| `on_status`      | glyde itself: connects, reconnects, rate limits |

Each event runs in its own process, so a slow or crashing handler does not
delay the next one.

## Keeping state

Handlers run in a fresh process each time, so there is nowhere to keep a
counter. Run your own actor and have the handler close over its name:

```gleam
let pongs = process.new_name("pongs")

let bot =
  glyde.new(token:, intents:)
  |> glyde.on_message(fn(api, msg) {
    let count = actor.call(process.named_subject(pongs), 1000, Bump)
    ...
  })

supervisor.new(supervisor.OneForOne)
|> supervisor.add(counter.supervised(pongs))
|> supervisor.add(glyde.supervised(bot))
|> supervisor.start
```

It has to be a name rather than a subject, so the handlers still find the
actor after it crashes and restarts. This is the same reason glyde keeps its
own names on the bot value.

## Status

glyde writes connects, reconnects and fatal errors to stderr. Replace that
with your own logging:

```gleam
|> glyde.on_status(fn(it) { log(status.describe(it)) })
```

A status reports why a connection dropped, when the next attempt is due, and
when Discord is rate limiting you. `Halted` means the bot will not reconnect:
a bad token, or an intent that is not enabled.

## Calling the API

Every handler is given an `api`. Pass it to any endpoint function:

```gleam
|> glyde.on_message(fn(api, msg) {
  case message.reply(api, msg, message.text("hi")) {
    Ok(sent) -> io.println("sent as " <> id.to_string(sent.id))
    Error(_) -> io.println_error("could not reply")
  }
})
```

Endpoints return a `Result`. A failure is either a refusal from Discord, no
answer at all, or the rate limiter declining to send, and
`api.describe_failure` renders all of them. A 429 is waited out and retried
before it reaches you.

There are about 80 endpoints, grouped by noun: `glyde/message`,
`glyde/channel`, `glyde/guild`, `glyde/member`, `glyde/role`, `glyde/user`,
`glyde/webhook`, `glyde/application_command`, `glyde/interaction`. Each module
holds its type, its builders and its endpoints.

IDs are typed, so a `ChannelId` does not fit where a `MessageId` goes.

## Slash commands

Register them on ready. Discord upserts by name, so this is safe on every boot.

```gleam
|> glyde.on_ready(fn(api, ready) {
  let assert Some(app) = ready.application
  let hello = command.new_chat_input(name: "hello", description: "say hello")
  let _ = command.create_global_command(api, app.id, command.global(hello))
  Nil
})
|> glyde.on_interaction(fn(api, it) {
  case it.data {
    interaction.CommandData(name: "hello", ..) -> {
      let _ = interaction.respond(api, it, message.text("hello!"))
      Nil
    }
    _ -> Nil
  }
})
```

The first response is due within three seconds. If the answer takes longer to
build, call `interaction.defer` first and `interaction.edit_response` when it
is ready.

A new global command can take an hour to appear. Guild commands appear
immediately, which is more useful during development.

The full version is in `examples/slash_command`.

## Testing

`glyde.with_transport` replaces the socket, the HTTP client and the clock, so
a whole session runs with no network. `glyde/testing` has the parts and
`test/glyde_test.gleam` puts them together.

The protocol underneath is a pure function from state and input to state and
outputs, in `glyde/gateway`. `glyde/client` drives it for a caller who wants
to own the processes, and `glyde/rest` turns endpoints into request values
that any HTTP client can send.

## Not included

No voice: no audio and no UDP.

No cache. Events arrive decoded, and where they go after that is up to you.

One connection per bot, which is enough for a few thousand guilds. The state
machines for a sharded fleet are in the library, but the wiring is not.
