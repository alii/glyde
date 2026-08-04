//// A Discord bot that answers "!ping" with "pong!", counting as it goes.

import envoy
import gleam/bool
import gleam/int
import gleam/io
import glyde
import glyde/draft
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
  |> glyde.on_ready(fn(pongs, ready) {
    io.println("logged in as " <> ready.me.user.username)
    glyde.continue(pongs)
  })
  |> glyde.on_message(fn(pongs, message) {
    use <- bool.guard(message.content != "!ping", glyde.continue(pongs))
    let pong = draft.text("pong! #" <> int.to_string(pongs + 1))
    use _ <- glyde.reply(message, pong)
    glyde.continue(pongs + 1)
  })
  |> glyde.run
}
