---
name: verify
description: Build and drive glyde end to end
---

# Verifying glyde

glyde is a library with no binary, so the surface is the package boundary: a
downstream project that depends on glyde and calls its public modules. The
core is sans-IO and pure, so most behaviour can be driven without a network.

Erlang only. There is no JavaScript target, and `--target javascript` is
expected to fail.

## Network

`gleam deps download` and `gleam run` reach `repo.hex.pm`, which the sandbox
blocks. Run those with the sandbox disabled. `gleam build` and `gleam test`
work sandboxed once `manifest.toml` is populated.

## Quick check, inside the repo

```bash
gleam test
gleam format --check src test
```

That is CI, not verification. Use it as a smoke test, then go drive the
package boundary.

## Driving the package boundary

Make a throwaway consumer that depends on glyde by path. Put it under
`~/code`, never `/tmp`: Santa blocks freshly compiled binaries executed from
there.

```bash
rm -rf ~/code/glyde-consumer-check
mkdir -p ~/code/glyde-consumer-check/src
cd ~/code/glyde-consumer-check
cat > gleam.toml <<'EOF'
name = "glyde_consumer_check"
version = "1.0.0"

[dependencies]
gleam_stdlib = ">= 1.0.0 and < 2.0.0"
gleam_json = ">= 3.0.0 and < 4.0.0"
glyde = { path = "../discord_gleam" }

[dev-dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"
EOF
# write src/glyde_consumer_check.gleam exercising the public API
gleam deps download  # sandbox off
gleam run            # sandbox off
```

Delete the consumer when done.

## Probes worth running

Type-level guarantees only hold if they hold from _outside_ the package, so
probe them from the consumer and check they fail to compile:

- `id.from_int(...)` must not exist. Snowflakes are strings.
- Passing an `id.MessageId` where an `id.ChannelId` is wanted must be a type
  error.
- `intents.Intents(131072)` must be unreachable, since the constructor is
  opaque and bit 17 is unassigned.

Runtime probes that have caught real problems:

- A snowflake sent as a JSON number must be rejected. Discord sends them as
  strings, and accepting a number invites arithmetic on an opaque id.
- Close codes glyde has never seen must resume, not start a new session. Only
  the codes where Discord has said the session is gone (4003, 4005, 4007, 4009) start fresh. Identifying spends from a budget of 1000 a day, resuming
  spends nothing.
- A close code means different things by direction. A 1000 from Discord
  resumes; a 1000 we sent ended the session on purpose and must not
  reconnect. The machine never asks the classifier about a close it sent,
  because `on_closed` drops anything arriving with no socket, so the echo of
  our own shutdown must not bring the bot back up.

## Against real Discord

Set `DISCORD_TOKEN` in the environment. Never commit it, never echo it, and
keep `.env` in `.gitignore`. A token in a public repo is revoked by Discord
within minutes and has to be regenerated.
