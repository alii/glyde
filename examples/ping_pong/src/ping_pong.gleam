//// A Discord bot that answers "!ping" with "pong!", counting as it goes.

import envoy
import gleam/bool
import gleam/int
import gleam/io
import glyde
import glyde/intents

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
  |> glyde.on_ready(fn(_bot, pongs, ready) {
    io.println("logged in as " <> ready.me.user.username)
    pongs
  })
  |> glyde.on_message(fn(bot, pongs, message) {
    use <- bool.guard(message.content != "!ping", pongs)
    let pongs = pongs + 1
    glyde.reply(bot, message, "pong! #" <> int.to_string(pongs))
    pongs
  })
  |> glyde.run
}
