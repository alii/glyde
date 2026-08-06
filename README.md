# glyde

A Discord library for Gleam.

Glyde is currently pre-1.0.0 release, so please try it out but be wary of papercuts.

```sh
gleam add glyde
```

Here's an example bot that answers `!ping`:

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

Add your web server, your database pool and anything else to that same
supervisor. The one rule is the comment above `bot`: build it once and hold the
value. Calling `glyde.new` again on every restart leaks memory the VM never
gives back.

`glyde.start` is the same thing without a supervisor above it. It hands you a
pid and nothing restarts the bot, so it is really only for tests and for
poking around.

Intents are what Discord will send you. `MessageContent` and the two members
ones have to be turned on in your app's settings page first, or the connection
gets closed as soon as it opens.

The handlers you can add:

|                  |                                                           |
| ---------------- | --------------------------------------------------------- |
| `on_message`     | someone posted a message                                  |
| `on_interaction` | a slash command, a button, autocomplete                   |
| `on_ready`       | connected, and here is who you are                        |
| `on_event`       | everything, if you want to match on it yourself           |
| `on_status`      | the library itself: connecting, reconnecting, rate limits |

Each event runs in its own process, so one slow or crashing handler does not
hold up the next message.

## Watching what it does

By default glyde prints connects, reconnects and fatal errors to stderr. Swap
that for your own logging with `on_status`:

```gleam
import glyde/status

|> glyde.on_status(fn(it) { log(status.describe(it)) })
```

You get told when the connection drops and why, when it is coming back, and
when Discord is rate limiting you. `Halted` means it is not coming back: a bad
token, or intents you have not enabled.

## Calling the API

Every handler is given an `api`. Pass it to any of the endpoint functions.

```gleam
|> glyde.on_message(fn(api, msg) {
  case message.reply(api, msg, message.text("hi")) {
    Ok(sent) -> io.println("sent as " <> id.to_string(sent.id))
    Error(_) -> io.println_error("could not reply")
  }
})
```

Calls come back as a `Result`. An error is one of three things: Discord said no,
nothing answered at all, or the rate limiter refused to send it.
`api.describe_failure` turns any of them into a line you can log. Rate limits
are waited out for you, so you do not need to retry on a 429.

There are around 80 endpoints, one module per thing: `glyde/message`,
`glyde/channel`, `glyde/guild`, `glyde/member`, `glyde/role`, `glyde/user`,
`glyde/webhook`, `glyde/application_command`, `glyde/interaction`. Each one
holds the type, the builders and the endpoints for that thing.

IDs are typed by what they point at, so you cannot pass a channel ID where a
message ID goes.

## Slash commands

Register them once you are connected. Discord replaces by name, so running this
on every boot is fine.

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

You have three seconds to respond. If your answer takes longer than that, call
`interaction.defer` first and `interaction.edit_response` when you are done.

New global commands can take up to an hour to show up the first time. Guild
commands appear immediately, which is nicer while you are developing.

The full version is in `examples/slash_command`.

## Testing

`glyde.with_transport` replaces the socket, the HTTP client and the clock, so
you can run a whole session with no network. `glyde/testing` has the pieces for
writing one. `test/glyde_test.gleam` is a working example.

The protocol underneath is a plain function from state and input to state and
outputs, in `glyde/gateway`. If you want to drive the connection yourself
rather than use the supervision tree above, `glyde/client` is that layer, and
`glyde/rest` builds requests as values you can send with any HTTP client.

## Not included

**Voice.** No audio yet.

**Caching.** Nothing is kept in memory. Events arrive decoded and it is up to
you where they go.

**Sharding.** One connection per bot. That is good for a few thousand guilds.
The state machines for a bigger fleet are in the library, but the wiring is not.
