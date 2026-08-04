import booklet.{type Booklet}
import gleam/bit_array
import gleam/dynamic/decode
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleeunit
import glyde
import glyde/embed
import glyde/event
import glyde/field.{Present}
import glyde/id
import glyde/intents
import glyde/mentions
import glyde/message
import glyde/status
import glyde/testing/frames
import glyde/transport

pub fn main() -> Nil {
  gleeunit.main()
}

/// One thing the bot did.
type Step {
  Dialled(url: String)
  /// Opcode only, never the frame: IDENTIFY holds the token.
  Wrote(op: Int)
  /// A write the socket would not take.
  Refused(op: Int)
  Dropped
  /// `at` is the scripted clock, so a test can see a wait happen.
  Posted(path: String, at: Int)
  Saw(what: String)
  /// A dispatch glyde models that its own decoder would not take.
  Undecodable(name: String)
}

/// The whole runtime with no socket and no clock. Two messages, not one, so
/// the counter has to survive between events.
pub fn a_scripted_session_test() {
  let log = booklet.new([])

  glyde.new(
    token: frames.token,
    state: 0,
    intents: intents.new([intents.Guilds, intents.GuildMessages]),
  )
  |> glyde.with_transport(scripted(log))
  |> glyde.on_status(fn(_) { Nil })
  |> glyde.on_ready(fn(pongs, ready) {
    did(log, Saw("ready as " <> id.to_string(ready.me.user.id)))
    glyde.continue(pongs)
  })
  |> glyde.on_message(fn(pongs, msg) {
    did(log, Saw("message " <> msg.content))
    use _ <- glyde.try(message.reply(msg, message.text("pong!")), or: pongs)
    glyde.continue(pongs + 1)
  })
  // A second listener is handed what the first left, not the turn's start.
  |> glyde.on_message(fn(pongs, _message) {
    did(log, Saw("tally " <> int.to_string(pongs)))
    glyde.continue(pongs)
  })
  |> glyde.run

  assert list.reverse(booklet.get(log))
    == [
      Dialled("wss://gateway.discord.gg/?v=10&encoding=json"),
      // Op 2 is IDENTIFY.
      Wrote(2),
      Saw("ready as 1000000000000000000"),
      Saw("message !ping"),
      Posted(messages_path, at: 0),
      Saw("tally 1"),
      Saw("message !ping"),
      Posted(messages_path, at: 0),
      Saw("tally 2"),
    ]
}

const messages_path: String = "/api/v10/channels/1000000000000000002/messages"

/// `reply` takes a whole `Draft`, so an embed built in the handler has
/// to reach the wire along with the reference `reply` adds.
pub fn a_reply_carries_its_embed_to_the_wire_test() {
  let log = booklet.new([])
  let bodies = booklet.new([])
  let card = embed.new() |> embed.title("pong") |> embed.color(0x5865F2)

  glyde.new(
    token: frames.token,
    state: Nil,
    intents: intents.new([intents.GuildMessages]),
  )
  |> glyde.with_transport(recording(log, bodies))
  |> glyde.on_status(fn(_) { Nil })
  |> glyde.on_message(fn(state, msg) {
    let post = message.reply(msg, message.text("hi") |> message.embed(card))
    use _ <- glyde.try(post, or: state)
    glyde.continue(state)
  })
  |> glyde.run

  let assert [first, ..] = list.reverse(booklet.get(bodies))
  assert first
    == "{\"content\":\"hi\",\"embeds\":[{\"title\":\"pong\",\"color\":5793266}],"
    <> "\"message_reference\":{\"type\":0,\"message_id\":\"1000000000000000001\","
    <> "\"fail_if_not_exists\":true}}"
}

/// `scripted`, keeping every request body as text.
fn recording(
  log: Booklet(List(Step)),
  bodies: Booklet(List(String)),
) -> transport.Transport {
  let base = scripted(log)
  transport.Transport(..base, request: fn(built: Request(BitArray)) {
    let assert Ok(text) = bit_array.to_string(built.body)
    booklet.update(bodies, fn(seen) { [text, ..seen] })
    base.request(built)
  })
}

/// `call` hands the answer to the rest of the handler, so what Discord said can
/// go into the state it continues with. The listener after it sees that state,
/// which is the only way from out here to watch the answer travel.
pub fn a_call_answers_into_the_state_test() {
  let log = booklet.new([])

  glyde.new(
    token: frames.token,
    state: "nothing posted",
    intents: intents.new([intents.Guilds, intents.GuildMessages]),
  )
  |> glyde.with_transport(scripted(log))
  |> glyde.on_status(fn(_) { Nil })
  |> glyde.on_message(fn(last, msg) {
    let post = message.send(msg.channel_id, message.text("pong!"))
    use answer <- glyde.attempt(post)
    case answer {
      Ok(posted) -> glyde.continue(id.to_string(posted.id))
      Error(_) -> glyde.continue(last)
    }
  })
  |> glyde.on_message(fn(last, _message) {
    did(log, Saw("posted " <> last))
    glyde.continue(last)
  })
  |> glyde.run

  assert list.contains(booklet.get(log), Saw("posted 1000000000000000004"))
}

/// A 429 is the limiter's to deal with, not the handler's: the loop waits out
/// the `retry-after` and sends again, and the handler only hears the answer
/// that stuck.
pub fn a_429_is_waited_out_and_retried_test() {
  let log = booklet.new([])
  let tries = booklet.new(0)

  glyde.new(
    token: frames.token,
    state: Nil,
    intents: intents.new([intents.GuildMessages]),
  )
  |> glyde.with_transport(
    timed(log, [#(0, [create("1", channel_a)]), #(60_000, [fatal()])], fn(_) {
      case bump(tries) {
        1 -> too_fast("2", global: False)
        _ -> created()
      }
    }),
  )
  |> glyde.on_status(fn(_) { Nil })
  |> glyde.on_message(fn(state, msg) {
    use answer <- glyde.attempt(pong(msg))
    did(log, Saw(heard(msg, answer)))
    glyde.continue(state)
  })
  |> glyde.run

  assert traffic(log)
    == [Posted(path_a, at: 0), Posted(path_a, at: 2000), Saw("1: ok")]
}

/// A global 429 stops every route, not just the one that earned it. The first
/// call's wait is past the cap, so it is failed rather than sat through; the
/// second, to another channel six seconds later, is inside the cap and waits
/// for the freeze to lift.
pub fn a_global_429_holds_every_route_test() {
  let log = booklet.new([])
  let tries = booklet.new(0)

  glyde.new(
    token: frames.token,
    state: Nil,
    intents: intents.new([intents.GuildMessages]),
  )
  |> glyde.with_transport(
    timed(
      log,
      [
        #(0, [create("1", channel_a)]),
        #(6000, [create("2", channel_b)]),
        #(60_000, [fatal()]),
      ],
      fn(_) {
        case bump(tries) {
          1 -> too_fast("15", global: True)
          _ -> created()
        }
      },
    ),
  )
  |> glyde.on_status(fn(_) { Nil })
  |> glyde.on_message(fn(state, msg) {
    use answer <- glyde.attempt(pong(msg))
    did(log, Saw(heard(msg, answer)))
    glyde.continue(state)
  })
  |> glyde.run

  assert traffic(log)
    == [
      Posted(path_a, at: 0),
      Saw("1: would block for 15000"),
      Posted(path_b, at: 15_000),
      Saw("2: ok"),
    ]
}

/// One handler at a time, each to its end. The second message lands while the
/// first handler is waiting out a 429; it is read off the socket then, but its
/// handler runs only once the first has continued, and from the state the
/// first left.
pub fn handlers_do_not_interleave_test() {
  let log = booklet.new([])
  let tries = booklet.new(0)

  glyde.new(
    token: frames.token,
    state: 0,
    intents: intents.new([intents.GuildMessages]),
  )
  |> glyde.with_transport(
    timed(
      log,
      [
        #(0, [create("1", channel_a)]),
        #(1000, [create("2", channel_a)]),
        #(60_000, [fatal()]),
      ],
      fn(_) {
        case bump(tries) {
          1 -> too_fast("3", global: False)
          _ -> created()
        }
      },
    ),
  )
  |> glyde.on_status(fn(_) { Nil })
  |> glyde.on_message(fn(handled, msg) {
    did(log, Saw(msg.content <> " sees " <> int.to_string(handled)))
    use _ <- glyde.attempt(pong(msg))
    glyde.continue(handled + 1)
  })
  |> glyde.run

  assert traffic(log)
    == [
      Saw("1 sees 0"),
      Posted(path_a, at: 0),
      Posted(path_a, at: 3000),
      Saw("2 sees 1"),
      Posted(path_a, at: 3000),
    ]
}

/// `when` runs `then` on true and `continue(or)` on false, so a bot can gate
/// the rest of a handler without a `case`.
pub fn when_guards_the_rest_of_a_handler_test() {
  let log = booklet.new([])

  glyde.new(
    token: frames.token,
    state: 0,
    intents: intents.new([intents.GuildMessages]),
  )
  |> glyde.with_transport(scripted(log))
  |> glyde.on_status(fn(_) { Nil })
  |> glyde.on_message(fn(pongs, msg) {
    use <- glyde.when(msg.content == "!ping", or: pongs)
    did(log, Saw("guarded " <> msg.content))
    glyde.continue(pongs + 1)
  })
  |> glyde.on_message(fn(pongs, _) {
    did(log, Saw("tally " <> int.to_string(pongs)))
    glyde.continue(pongs)
  })
  |> glyde.run

  // Both scripted messages are "!ping", so both pass the guard.
  let steps = booklet.get(log)
  assert list.contains(steps, Saw("guarded !ping"))
  assert list.contains(steps, Saw("tally 2"))
}

/// `try` unwraps a good answer and falls back to `or` on a bad one.
pub fn try_falls_back_on_failure_and_unwraps_on_success_test() {
  let log = booklet.new([])
  let tries = booklet.new(0)

  glyde.new(
    token: frames.token,
    state: "start",
    intents: intents.new([intents.GuildMessages]),
  )
  |> glyde.with_transport(
    timed(
      log,
      [
        #(0, [create("1", channel_a)]),
        #(500, [create("2", channel_a)]),
        #(60_000, [fatal()]),
      ],
      fn(_) {
        // Every attempt at the first message is a 429; the second is fine.
        // Three 429s exhausts `max_attempts`, so `try` sees the failure.
        case bump(tries) {
          1 | 2 | 3 -> too_fast("1", global: False)
          _ -> created()
        }
      },
    ),
  )
  |> glyde.on_status(fn(_) { Nil })
  |> glyde.on_message(fn(state, msg) {
    use posted <- glyde.try(pong(msg), or: state)
    glyde.continue("posted " <> id.to_string(posted.id))
  })
  |> glyde.on_message(fn(state, msg) {
    did(log, Saw(msg.content <> " leaves " <> state))
    glyde.continue(state)
  })
  |> glyde.run

  let steps = booklet.get(log)
  // First message: three 429s then a fallback, so state stays "start".
  assert list.contains(steps, Saw("1 leaves start"))
  // Second: 200, so `try` unwraps into `then`.
  assert list.contains(steps, Saw("2 leaves posted 1000000000000000004"))
}

/// A reply then an edit of the same message, chained through `try`. The second
/// call is built from the first's answer, so the id has to travel.
pub fn a_reply_then_an_edit_chain_through_try_test() {
  let log = booklet.new([])
  let paths = booklet.new([])

  let recording = fn() {
    let base = scripted(log)
    transport.Transport(..base, request: fn(built: Request(BitArray)) {
      booklet.update(paths, fn(seen) { [built.path, ..seen] })
      base.request(built)
    })
  }

  glyde.new(
    token: frames.token,
    state: Nil,
    intents: intents.new([intents.GuildMessages]),
  )
  |> glyde.with_transport(recording())
  |> glyde.on_status(fn(_) { Nil })
  |> glyde.on_message(fn(state, msg) {
    use posted <- glyde.try(message.reply(msg, message.text("v1")), or: state)
    let change =
      message.Edit(..message.new_edit(mentions.none()), content: Present("v2"))
    use _ <- glyde.try(message.edit(posted, change), or: state)
    glyde.continue(state)
  })
  |> glyde.run

  // Per scripted message: one POST then one PATCH to the message it returned.
  let seen = list.reverse(booklet.get(paths))
  assert list.contains(seen, messages_path)
  assert list.contains(seen, messages_path <> "/1000000000000000004")
}

/// The wait for a permit happens on the socket, so a heartbeat that comes due
/// in the middle of it still goes out. Beating every second across a five
/// second wait, at least one has to land between the two attempts.
pub fn the_heart_beats_through_a_limiter_wait_test() {
  let log = booklet.new([])
  let tries = booklet.new(0)

  glyde.new(
    token: frames.token,
    state: Nil,
    intents: intents.new([intents.GuildMessages]),
  )
  |> glyde.with_transport(
    timed_beating(
      log,
      1000,
      [#(0, [create("1", channel_a)]), #(20_000, [fatal()])],
      fn(_) {
        case bump(tries) {
          1 -> too_fast("5", global: False)
          _ -> created()
        }
      },
    ),
  )
  |> glyde.on_status(fn(_) { Nil })
  |> glyde.on_message(fn(state, msg) {
    use _ <- glyde.attempt(pong(msg))
    glyde.continue(state)
  })
  |> glyde.run

  // Op 1 is a heartbeat.
  let between =
    list.reverse(booklet.get(log))
    |> list.drop_while(fn(step) { step != Posted(path_a, at: 0) })
    |> list.drop(1)
    |> list.take_while(fn(step) { step != Posted(path_a, at: 5000) })
  assert list.contains(booklet.get(log), Posted(path_a, at: 5000))
  assert list.contains(between, Wrote(1))
}

const channel_a: String = "1000000000000000002"

const path_a: String = "/api/v10/channels/1000000000000000002/messages"

const channel_b: String = "1000000000000000009"

const path_b: String = "/api/v10/channels/1000000000000000009/messages"

fn pong(msg: glyde.Message) -> glyde.Call(glyde.Message) {
  message.send(msg.channel_id, message.text("pong!"))
}

fn heard(
  message: glyde.Message,
  answer: Result(a, status.CallFailure),
) -> String {
  message.content
  <> ": "
  <> case answer {
    Ok(_) -> "ok"
    Error(status.WouldBlock(wait_ms:)) ->
      "would block for " <> int.to_string(wait_ms)
    Error(_) -> "failed"
  }
}

/// The REST calls and what the handlers saw, oldest first. Heartbeats land
/// where the jitter puts them, so they are left out of an exact comparison.
fn traffic(log: Booklet(List(Step))) -> List(Step) {
  list.reverse(booklet.get(log))
  |> list.filter(fn(step) {
    case step {
      Posted(..) | Saw(_) -> True
      _ -> False
    }
  })
}

fn bump(counter: Booklet(Int)) -> Int {
  booklet.update(counter, fn(count) { count + 1 })
  booklet.get(counter)
}

fn create(id: String, channel: String) -> transport.Event {
  transport.TextMessage(frames.dispatch(
    "MESSAGE_CREATE",
    2,
    json.object([
      #("id", json.string("100000000000000000" <> id)),
      #("channel_id", json.string(channel)),
      #("author", json.object([#("id", json.string("1000000000000000003"))])),
      #("content", json.string(id)),
    ]),
  ))
}

/// 4004, which glyde reads as fatal, so the loop stops instead of redialling.
fn fatal() -> transport.Event {
  transport.Closed(4004, "Authentication failed")
}

fn created() -> Response(BitArray) {
  response.set_body(response.new(200), <<
    "{\"id\":\"1000000000000000004\",\"channel_id\":\"1000000000000000002\",\"author\":{\"id\":\"1000000000000000003\"}}":utf8,
  >>)
}

/// Discord's 429, header and body both, the way `glyde/rest/headers` reads it.
fn too_fast(seconds: String, global global: Bool) -> Response(BitArray) {
  let scope = case global {
    True -> "global"
    False -> "user"
  }
  response.new(429)
  |> response.set_header("retry-after", seconds)
  |> response.set_header("x-ratelimit-scope", scope)
  |> response.set_body(
    json.object([
      #("message", json.string("You are being rate limited.")),
      #("retry_after", json.int(result_or_zero(int.parse(seconds)))),
      #("global", json.bool(global)),
    ])
    |> json.to_string
    |> to_bits,
  )
}

fn result_or_zero(parsed: Result(Int, Nil)) -> Int {
  case parsed {
    Ok(value) -> value
    Error(_) -> 0
  }
}

fn to_bits(text: String) -> BitArray {
  <<text:utf8>>
}

/// A transport against a scripted clock. Batches are due at a time: a turn
/// hands over the next one if it falls inside the timeout, and otherwise moves
/// the clock on by the timeout and comes back empty, which is what a real read
/// timing out looks like. Heartbeats are acked on the turn after they go out.
fn timed(
  log: Booklet(List(Step)),
  script: List(#(Int, List(transport.Event))),
  answer: fn(Request(BitArray)) -> Response(BitArray),
) -> transport.Transport {
  timed_beating(log, 41_250, script, answer)
}

fn timed_beating(
  log: Booklet(List(Step)),
  interval: Int,
  script: List(#(Int, List(transport.Event))),
  answer: fn(Request(BitArray)) -> Response(BitArray),
) -> transport.Transport {
  let clock = booklet.new(0)
  let owed = booklet.new(0)
  let opening = [
    #(0, [transport.Opened]),
    #(0, [transport.TextMessage(frames.hello(interval))]),
    #(0, [
      transport.TextMessage(frames.ready(
        1,
        "timed-session",
        "gateway-us-east1-b.discord.gg",
      )),
    ]),
  ]

  transport.Transport(
    open: fn(url) {
      did(log, Dialled(url))
      live(log, clock, owed, list.append(opening, script))
    },
    request: fn(built) {
      did(log, Posted(built.path, at: booklet.get(clock)))
      Ok(answer(built))
    },
    now: fn() { booklet.get(clock) },
    idle: fn(in_ms) { booklet.set(clock, booklet.get(clock) + in_ms) },
  )
}

fn live(
  log: Booklet(List(Step)),
  clock: Booklet(Int),
  owed: Booklet(Int),
  remaining: List(#(Int, List(transport.Event))),
) -> transport.Socket {
  transport.Socket(
    send: fn(text) {
      let op = opcode(text)
      did(log, Wrote(op))
      case op {
        1 -> booklet.set(owed, booklet.get(owed) + 1)
        _ -> Nil
      }
      True
    },
    close: fn(_) { Nil },
    drop: fn() { Nil },
    turn: fn(in_ms) {
      let now = booklet.get(clock)
      case booklet.get(owed) > 0, remaining {
        True, _ -> {
          booklet.set(owed, 0)
          #(live(log, clock, owed, remaining), [
            transport.TextMessage(frames.ack()),
          ])
        }
        False, [] -> #(live(log, clock, owed, []), [fatal()])
        False, [#(at, batch), ..rest] if at <= now + in_ms -> {
          booklet.set(clock, int.max(now, at))
          #(live(log, clock, owed, rest), batch)
        }
        False, _ -> {
          booklet.set(clock, now + in_ms)
          #(live(log, clock, owed, remaining), [])
        }
      }
    },
  )
}

/// A write that comes back `False` is a socket that has already gone. The
/// runtime has to turn that into the close itself: waiting for the read side to
/// notice costs a whole read timeout, and a heartbeat every 41 seconds means
/// the session is gone by then.
pub fn a_refused_write_becomes_a_close_test() {
  let log = booklet.new([])

  glyde.new(
    token: frames.token,
    state: Nil,
    intents: intents.new([intents.Guilds]),
  )
  |> glyde.with_transport(refusing(log))
  |> glyde.on_status(fn(_) { Nil })
  |> glyde.run

  assert list.reverse(booklet.get(log))
    == [
      Dialled("wss://gateway.discord.gg/?v=10&encoding=json"),
      // Op 2 is IDENTIFY, and this socket will not take it.
      Refused(2),
      // The shard heard the close and abandoned the socket, without the read
      // side ever reporting anything.
      Dropped,
      Dialled("wss://gateway.discord.gg/?v=10&encoding=json"),
    ]
}

/// A modelled event whose payload no longer fits is the schema-drift signal,
/// and the runtime is the only place it can be heard: the listeners get the
/// same `Raw` an unmodelled name would give, so nothing else can tell.
pub fn schema_drift_reaches_the_status_handler_test() {
  let log = booklet.new([])

  glyde.new(
    token: frames.token,
    state: Nil,
    intents: intents.new([intents.GuildMessages]),
  )
  |> glyde.with_transport(drifted(log))
  |> glyde.on_status(fn(status) {
    case status {
      status.Undecodable(name:, errors:) -> {
        assert errors != []
        did(log, Undecodable(name))
      }
      _ -> Nil
    }
  })
  |> glyde.on_event(fn(state, seen) {
    case seen {
      event.Raw(name:, data: _) -> did(log, Saw("raw " <> name))
      _ -> Nil
    }
    glyde.continue(state)
  })
  |> glyde.run

  let steps = booklet.get(log)
  assert list.contains(steps, Undecodable("MESSAGE_CREATE"))
  assert list.contains(steps, Saw("raw MESSAGE_CREATE"))
}

/// A socket with something to say on every read must not starve the clock.
/// Discord closes a shard that stops heartbeating, so a guild loud enough that
/// no read ever comes back empty used to take the session down with it.
pub fn timers_fire_while_frames_keep_arriving_test() {
  let log = booklet.new([])

  glyde.new(
    token: frames.token,
    state: Nil,
    intents: intents.new([intents.Guilds]),
  )
  |> glyde.with_transport(busy(log))
  |> glyde.on_status(fn(_) { Nil })
  |> glyde.run

  // Op 1 is a heartbeat, and not one read in this run came back empty.
  assert list.contains(booklet.get(log), Wrote(1))
}

/// A socket that always has something to say, and a clock that only moves when
/// it is read from. 25 seconds a turn: under the 30s handshake budget, and past
/// the jittered first heartbeat within two turns of READY.
fn busy(log: Booklet(List(Step))) -> transport.Transport {
  let clock = booklet.new(0)

  transport.Transport(
    open: fn(url) {
      did(log, Dialled(url))
      ticking(log, clock, [
        [transport.Opened],
        [transport.TextMessage(hello())],
        [
          transport.TextMessage(frames.ready(
            1,
            "busy-session",
            "gateway-us-east1-b.discord.gg",
          )),
        ],
        // The ack rides along with the chatter, so the second heartbeat is
        // never the one that finds the connection a zombie.
        chatter(2),
        chatter(3),
        [transport.Closed(4004, "Authentication failed")],
      ])
    },
    request: fn(_) { panic as "this bot never calls REST" },
    now: fn() { booklet.get(clock) },
    idle: fn(in_ms) { booklet.set(clock, booklet.get(clock) + in_ms) },
  )
}

fn chatter(seq: Int) -> List(transport.Event) {
  [
    transport.TextMessage(frames.dispatch("MESSAGE_CREATE", seq, ping("1"))),
    transport.TextMessage(frames.ack()),
  ]
}

fn ticking(
  log: Booklet(List(Step)),
  clock: Booklet(Int),
  remaining: List(List(transport.Event)),
) -> transport.Socket {
  transport.Socket(
    send: fn(text) {
      did(log, Wrote(opcode(text)))
      True
    },
    close: fn(_) { Nil },
    drop: fn() { Nil },
    turn: fn(_) {
      booklet.set(clock, booklet.get(clock) + 25_000)
      case remaining {
        [] -> #(ticking(log, clock, []), [
          transport.Closed(4004, "script ran out"),
        ])
        [next, ..rest] -> #(ticking(log, clock, rest), next)
      }
    },
  )
}

/// A MESSAGE_CREATE with no `id` and no `author`, which is what a Discord
/// change to the message object would look like from here.
fn drifted(log: Booklet(List(Step))) -> transport.Transport {
  transport.Transport(
    open: fn(url) {
      did(log, Dialled(url))
      socket(log, [
        [transport.Opened],
        [transport.TextMessage(hello())],
        [
          transport.TextMessage(frames.ready(
            1,
            "drifted-session",
            "gateway-us-east1-b.discord.gg",
          )),
        ],
        [
          transport.TextMessage(frames.dispatch(
            "MESSAGE_CREATE",
            2,
            json.object([#("channel_id", json.string("1000000000000000002"))]),
          )),
        ],
        [transport.Closed(4004, "Authentication failed")],
      ])
    },
    request: fn(_) { panic as "this bot never calls REST" },
    now: fn() { 0 },
    idle: fn(_) { Nil },
  )
}

/// What Discord says, one turn at a time. Every ending is a 4004, which glyde
/// reads as fatal, so a script that runs out stops the loop instead of spinning.
fn script() -> List(List(transport.Event)) {
  [
    [transport.Opened],
    [transport.TextMessage(frames.hello(41_250))],
    [
      transport.TextMessage(frames.ready(
        1,
        "scripted-session",
        "gateway-us-east1-b.discord.gg",
      )),
    ],
    [transport.TextMessage(frames.dispatch("MESSAGE_CREATE", 2, ping("1")))],
    [transport.TextMessage(frames.dispatch("MESSAGE_CREATE", 3, ping("5")))],
    [transport.Closed(4004, "Authentication failed")],
  ]
}

fn ping(id: String) -> json.Json {
  json.object([
    #("id", json.string("100000000000000000" <> id)),
    #("channel_id", json.string("1000000000000000002")),
    #("author", json.object([#("id", json.string("1000000000000000003"))])),
    #("content", json.string("!ping")),
  ])
}

fn scripted(log: Booklet(List(Step))) -> transport.Transport {
  transport.Transport(
    open: fn(url) {
      did(log, Dialled(url))
      socket(log, script())
    },
    request: fn(built) {
      did(log, Posted(built.path, at: 0))
      Ok(created())
    },
    // A clock that never moves. The only timer that comes due is the dial
    // armed at zero.
    now: fn() { 0 },
    idle: fn(_) { Nil },
  )
}

fn socket(
  log: Booklet(List(Step)),
  remaining: List(List(transport.Event)),
) -> transport.Socket {
  transport.Socket(
    send: fn(text) {
      did(log, Wrote(opcode(text)))
      True
    },
    close: fn(_) { Nil },
    drop: fn() { Nil },
    turn: fn(_) {
      case remaining {
        [] -> #(socket(log, []), [transport.Closed(4004, "script ran out")])
        [next, ..rest] -> #(socket(log, rest), next)
      }
    },
  )
}

/// Two dials: one socket that refuses the write, then one that only has to end
/// the run. The clock moves when the loop waits for the reconnect, so the
/// second dial happens without a real timer.
fn refusing(log: Booklet(List(Step))) -> transport.Transport {
  let clock = booklet.new(0)
  let dials = booklet.new(0)

  transport.Transport(
    open: fn(url) {
      did(log, Dialled(url))
      booklet.set(dials, booklet.get(dials) + 1)
      case booklet.get(dials) {
        1 -> deaf(log, [[transport.Opened], [transport.TextMessage(hello())]])
        _ ->
          socket(log, [
            [transport.Opened],
            [transport.Closed(4004, "Authentication failed")],
          ])
      }
    },
    request: fn(_) { panic as "this bot never calls REST" },
    now: fn() { booklet.get(clock) },
    idle: fn(in_ms) { booklet.set(clock, booklet.get(clock) + in_ms) },
  )
}

fn hello() -> String {
  frames.hello(41_250)
}

/// Takes the dial, then refuses every write: a peer that went away between the
/// last read and the next write.
fn deaf(
  log: Booklet(List(Step)),
  remaining: List(List(transport.Event)),
) -> transport.Socket {
  transport.Socket(
    send: fn(text) {
      did(log, Refused(opcode(text)))
      False
    },
    close: fn(_) { Nil },
    drop: fn() { did(log, Dropped) },
    turn: fn(_) {
      case remaining {
        [] -> #(deaf(log, []), [transport.Closed(1006, "")])
        [next, ..rest] -> #(deaf(log, rest), next)
      }
    },
  )
}

fn opcode(text: String) -> Int {
  case json.parse(text, decode.at(["op"], decode.int)) {
    Ok(op) -> op
    Error(_) -> -1
  }
}

fn did(log: Booklet(List(Step)), step: Step) -> Nil {
  booklet.set(log, [step, ..booklet.get(log)])
}
