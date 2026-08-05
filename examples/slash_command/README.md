# slash_command

A Discord bot with a `/hello` slash command. The whole thing is
`src/slash_command.gleam`.

## Run it

```sh
export DISCORD_TOKEN=...
gleam run
```

Slash commands need no privileged intents and no message content, so the
intent set is empty.

The bot registers `/hello` on READY. Discord upserts by name, so running it
twice does not create a duplicate. A global command can take up to an hour to
appear in a client the first time; register it against a guild instead for an
instant turnaround while developing.

## The three second deadline

An interaction must be answered within three seconds or Discord drops it and
the callback route answers 404. `interaction.respond` is that first answer.
When the reply takes longer to build, `interaction.defer` first to show the
"thinking..." indicator and buy fifteen minutes, then finish with
`interaction.edit_response`:

```gleam
let _ = api.execute(api, interaction.defer(it))
let answer = something_slow()
let _ =
  api.execute(api, interaction.edit_response(it, message.Edit(
    ..message.new_edit(mentions.none()),
    content: Present(answer),
  )))
```
