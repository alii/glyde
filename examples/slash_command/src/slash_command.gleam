//// A Discord bot with a `/hello` slash command.

import envoy
import gleam/io
import gleam/option.{Some}
import glyde
import glyde/application_command as command
import glyde/intents
import glyde/interaction
import glyde/message

pub fn main() -> Nil {
  let assert Ok(token) = envoy.get("DISCORD_TOKEN")

  glyde.new(token:, intents: intents.none())
  |> glyde.on_ready(fn(api, ready) {
    io.println("logged in as " <> ready.me.user.username)
    // Register `/hello`. Discord upserts by name, so this is safe on every
    // boot. A global command can take up to an hour to appear the first time.
    case ready.application {
      Some(app) -> {
        let hello =
          command.new_chat_input(name: "hello", description: "say hello")
        let _ =
          command.create_global_command(api, app.id, command.global(hello))
        Nil
      }
      _ -> Nil
    }
  })
  |> glyde.on_interaction(fn(api, it) {
    // The first response is due within three seconds. `defer` first if the
    // reply takes longer to build, then finish with `edit_response`.
    case it.data {
      interaction.CommandData(name: "hello", ..) -> {
        let who = case interaction.invoking_user(it) {
          Some(user) -> user.username
          _ -> "there"
        }
        let _ =
          interaction.respond(api, it, message.text("hello " <> who <> "!"))
        Nil
      }
      _ -> Nil
    }
  })
  |> glyde.run
}
