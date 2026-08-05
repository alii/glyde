# glyde

A Discord library for Gleam

Glyde is currently pre-1.0.0 release, so please try it out but be wary of papercuts.

```sh
gleam add glyde
```

Here's an example bot that answers `!ping`:

```gleam
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
```

That is `examples/ping_pong`, whole file.

Each event is handed to a fresh process under a supervisor, so a slow or
crashing handler never holds up the next one. An endpoint call blocks that one
process on the rate limiter and the network; the shard keeps reading.

## The runtime

`run` starts a small OTP tree: a rate-limiter actor, a factory supervisor for
handler processes, and a shard actor holding the socket. The shard actor loops
one turn at a time: find the timer due soonest, wait that long on the socket,
feed the core whatever came back, spawn a handler process for each dispatch.

`glyde/transport` is the platform half, four functions wide: open a socket, send
an HTTP request, read the clock, wait. `glyde.with_transport` swaps it, so the
same bot runs over a proxy, a recording double, or a script with no network at
all. `test/glyde_test.gleam` drives a whole session that way.

Below the shard actor is `glyde/client`. Give it six functions, open, send,
close, drop, arm a timer and cancel one, and it runs the state machine's outputs
against them. That is where sharding, compression and a fleet's shared identify
queue live.

## The core does no IO

`gateway.step(shard, input)` is total and returns the next shard plus the
outputs to perform, so a protocol rule is a row in a table with no socket to
fake and no clock to hold still:

```gleam
pub fn hello_queues_for_an_identify_slot_test() {
  let shard = greeting()
  let Step(shard: after, outputs:) = frame(shard, hello())
  assert outputs
    == [
      CancelTimer(gateway.Handshake),
      ArmTimer(gateway.Heartbeat, 0, Stamp(7)),
      RequestIdentifySlot(Conn(5)),
      Note(gateway.AwaitingIdentifySlot),
    ]
  assert phase(after)
    == Queued(Beat(interval_ms: interval, unacked: 0, quiet: False))
}
```

## A REST call is a value

`rest.request(config, call)` hands you a `gleam_http` request. Send it with
whatever client you already have, then give the answer back to the call it came
from, which carries the decoder for that endpoint.

```gleam
let call =
  message.send(
    channel_id,
    message.text("shipped")
      |> message.embed(embed.new() |> embed.title("v0.1.0")),
  )

let request = rest.request(rest.config(rest.bot(token)), call)
// send it however you like, then:
let posted = rest.response(call, status:, headers:, body:)
```

`rest.route(call)` gives that call's rate-limit identity without building a
request at all, which is what `glyde/rest/limiter` schedules on. The limiter is
a state machine too: it says when to send and what a 429 means, it does not
sleep and it does not retry behind your back.

80 endpoints, covering channels and messages, guilds, members, roles, threads,
application commands, interactions, webhooks and users. Each noun is one
module: `glyde/message` holds the received type, the `Draft` and `Edit`
builders, and every endpoint that acts on a message. `message.to_body` writes
the `attachments` cross-reference for any file on the draft, which a
hand-written JSON object silently does not. Ids are tagged by what they
identify, so the two snowflakes in `/channels/{channel_id}/messages/{message_id}`
cannot be swapped.

## What is not in it

**No voice.** `UpdateVoiceState` is there because it is a gateway command, but
there is no voice gateway, no UDP and no audio.

**No cache.** Nothing holds on to a guild, a channel or a member. Events arrive
decoded and go wherever you put them.

**No processes.** Not in the core and not in the runtime: the loop is one
tail-recursive function. That also means no fleet. A fleet wants a supervisor, a
process per shard and one `glyde/identify_queue` for the whole bot; glyde ships
the state machines for that, not the wiring.
