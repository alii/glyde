//// A Discord bot that answers "!ping" with "pong!", counting as it goes.

import envoy
import gleam/int
import gleam/io
import glyde
import glyde/intents
import glyde/message

pub fn main() -> Nil {
  use token <- glyde.require_token(envoy.get("DISCORD_TOKEN"))

  glyde.new(
    token:,
    state: 0,
    intents: intents.new([
      intents.Guilds,
      intents.GuildMessages,
      intents.MessageContent,
    ]),
  )
  |> glyde.on_ready(fn(pongs, ready) {
    io.println("logged in as " <> ready.me.user.username)
    glyde.continue(pongs)
  })
  |> glyde.on_message(fn(pongs, msg) {
    use <- glyde.when(msg.content == "!ping", or: pongs)
    let pong = message.text("pong! #" <> int.to_string(pongs + 1))
    use _ <- glyde.try(message.reply(msg, pong), or: pongs)
    glyde.continue(pongs + 1)
  })
  |> glyde.run
}
