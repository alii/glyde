//// A Discord bot that answers "!ping" with "pong!".

import envoy
import gleam/bool
import gleam/io
import glyde
import glyde/intents
import glyde/message

pub fn main() -> Nil {
  let assert Ok(token) = envoy.get("DISCORD_TOKEN")

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
  |> glyde.run
}
