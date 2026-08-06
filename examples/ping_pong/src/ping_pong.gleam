//// A Discord bot that answers "!ping" with "pong!".

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
