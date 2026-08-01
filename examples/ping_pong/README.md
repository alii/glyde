# ping_pong

A Discord bot that answers `!ping` with `pong!` and counts how many it has
sent. The whole thing is `src/ping_pong.gleam`.

## Run it

```sh
export DISCORD_TOKEN=...
gleam run
```

The app needs the **Message Content** intent, which is privileged and off by
default. Turn it on under *Bot* in the
[developer portal](https://discord.com/developers/applications), or Discord
closes with 4014 and glyde halts rather than reconnecting, with
`enable the privileged intents in the developer portal` as the reason.

With no `DISCORD_TOKEN` set it panics in `main` with `glyde: no bot token, so
there is nothing to connect to`.

## What it prints

Two lines. glyde prints `glyde: connecting to gateway.discord.gg` to stderr when
it dials, and this example's `on_ready` prints `logged in as <your bot>` to
stdout. The replies go to Discord and not the terminal, and the count lives in
the loop, so a restart starts it at one again.

A token Discord will not accept:

```
$ DISCORD_TOKEN=not.a.real.token gleam run
glyde: connecting to gateway.discord.gg
glyde: halted: check the bot token (shard 0 of 1)
```

Close 4004 is fatal, so `run` returns and the process exits instead of spending
the bot's identify budget retrying.

`glyde.on_status` replaces that printer and sees what it drops, the frames going
out and the core's diagnostics:

```gleam
|> glyde.on_status(fn(status) { io.println(glyde.describe(status)) })
```
