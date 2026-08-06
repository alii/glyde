import booklet.{type Booklet}
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/otp/static_supervisor as supervisor
import gleeunit
import glyde
import glyde/embed
import glyde/event
import glyde/id
import glyde/intents
import glyde/internal/timing
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
  RefusedWrite(op: Int)
  Dropped
  Posted(path: String)
  Saw(what: String)
  /// A dispatch glyde models that its own decoder would not take.
  Undecodable(name: String)
}

/// What the shard reported that a test waits on.
type Signal {
  Done
  Halted
}

/// Wait for `n` handler processes to say they finished, then for the shard to
/// halt. The shard fires `Halted` before the handlers it spawned are done, so
/// both are counted.
fn await(inbox: Subject(Signal), handlers n: Int) -> Nil {
  let assert Ok(_) = process.receive(inbox, 5000)
  case n {
    0 -> Nil
    _ -> await(inbox, n - 1)
  }
}

fn signal_halt(inbox: Subject(Signal)) -> fn(glyde.Status) -> Nil {
  fn(it) {
    case it {
      status.Halted(_) -> process.send(inbox, Halted)
      _ -> Nil
    }
  }
}

/// The whole tree with no real socket. Two messages, so two handler processes,
/// each posting a reply.
pub fn a_scripted_session_test() {
  let log = booklet.new([])
  let inbox = process.new_subject()

  let assert Ok(_) =
    glyde.new(
      token: frames.token,
      intents: intents.new([intents.Guilds, intents.GuildMessages]),
    )
    |> glyde.with_transport(scripted(log, fn(_) { created() }))
    |> glyde.on_status(signal_halt(inbox))
    |> glyde.on_ready(fn(_api, ready) {
      did(log, Saw("ready as " <> id.to_string(ready.me.user.id)))
      process.send(inbox, Done)
    })
    |> glyde.on_message(fn(api, msg) {
      did(log, Saw("message " <> msg.content))
      let assert Ok(_) = message.reply(api, msg, message.text("pong!"))
      process.send(inbox, Done)
    })
    |> glyde.start

  await(inbox, handlers: 3)

  let steps = booklet.get(log)
  assert list.contains(
    steps,
    Dialled("wss://gateway.discord.gg/?v=10&encoding=json"),
  )
  // Op 2 is IDENTIFY.
  assert list.contains(steps, Wrote(2))
  assert list.contains(steps, Saw("ready as 1000000000000000000"))
  assert list.contains(steps, Saw("message !ping"))
  assert list.count(steps, fn(s) { s == Posted(messages_path) }) == 2
}

const messages_path: String = "/api/v10/channels/1000000000000000002/messages"

/// `reply` takes a whole `Draft`, so an embed built in the handler has to
/// reach the wire along with the reference `reply` adds.
pub fn a_reply_carries_its_embed_to_the_wire_test() {
  let log = booklet.new([])
  let bodies = booklet.new([])
  let inbox = process.new_subject()
  let card = embed.new() |> embed.title("pong") |> embed.color(0x5865F2)

  let assert Ok(_) =
    glyde.new(
      token: frames.token,
      intents: intents.new([intents.GuildMessages]),
    )
    |> glyde.with_transport(recording(log, bodies))
    |> glyde.on_status(signal_halt(inbox))
    |> glyde.on_message(fn(api, msg) {
      let assert Ok(_) =
        message.reply(api, msg, message.text("hi") |> message.embed(card))
      process.send(inbox, Done)
    })
    |> glyde.start

  await(inbox, handlers: 2)

  let assert [first, ..] = list.reverse(booklet.get(bodies))
  assert first
    == "{\"content\":\"hi\",\"embeds\":[{\"title\":\"pong\",\"color\":5793266}],"
    <> "\"message_reference\":{\"type\":0,\"message_id\":\"1000000000000000001\","
    <> "\"fail_if_not_exists\":true}}"
}

/// A 429 is the limiter's to deal with, not the handler's: `call` waits it out
/// and sends again, and the handler only hears the answer that stuck.
pub fn a_429_is_waited_out_and_retried_test() {
  let log = booklet.new([])
  let tries = booklet.new(0)
  let inbox = process.new_subject()

  let assert Ok(_) =
    glyde.new(
      token: frames.token,
      intents: intents.new([intents.GuildMessages]),
    )
    |> glyde.with_transport(
      scripted(log, fn(_) {
        case bump(tries) {
          1 -> too_fast(0)
          _ -> created()
        }
      }),
    )
    |> glyde.on_status(signal_halt(inbox))
    |> glyde.on_message(fn(api, msg) {
      let assert Ok(posted) =
        message.send(api, msg.channel_id, message.text("pong!"))
      did(log, Saw("posted " <> id.to_string(posted.id)))
      process.send(inbox, Done)
    })
    |> glyde.start

  await(inbox, handlers: 2)

  let steps = booklet.get(log)
  // Two messages, first attempt 429 then a retry.
  assert list.count(steps, fn(s) { s == Posted(messages_path) }) >= 3
  assert list.contains(steps, Saw("posted 1000000000000000004"))
}

/// A modelled event whose payload no longer fits is the schema-drift signal.
/// The listeners still get `Raw`, and `on_status` hears `Undecodable`.
pub fn schema_drift_reaches_the_status_handler_test() {
  let log = booklet.new([])
  let inbox = process.new_subject()

  let assert Ok(_) =
    glyde.new(
      token: frames.token,
      intents: intents.new([intents.GuildMessages]),
    )
    |> glyde.with_transport(drifted(log))
    |> glyde.on_status(fn(it) {
      case it {
        status.Undecodable(name:, errors:) -> {
          assert errors != []
          did(log, Undecodable(name))
        }
        status.Halted(_) -> process.send(inbox, Halted)
        _ -> Nil
      }
    })
    |> glyde.on_event(fn(_api, seen) {
      case seen {
        event.Raw(name:, data: _) -> did(log, Saw("raw " <> name))
        _ -> Nil
      }
      process.send(inbox, Done)
    })
    |> glyde.start

  // READY plus one drifted MESSAGE_CREATE.
  await(inbox, handlers: 2)

  let steps = booklet.get(log)
  assert list.contains(steps, Undecodable("MESSAGE_CREATE"))
  assert list.contains(steps, Saw("raw MESSAGE_CREATE"))
}

/// A write that comes back `False` is a socket that has gone. The shard turns
/// that into a close and redials, without the read side ever reporting.
pub fn a_refused_write_becomes_a_close_test() {
  let log = booklet.new([])
  let inbox = process.new_subject()

  let assert Ok(_) =
    glyde.new(token: frames.token, intents: intents.new([intents.Guilds]))
    |> glyde.with_transport(refusing(log))
    |> glyde.on_status(signal_halt(inbox))
    |> glyde.start

  await(inbox, handlers: 0)

  let steps = list.reverse(booklet.get(log))
  assert steps
    == [
      Dialled("wss://gateway.discord.gg/?v=10&encoding=json"),
      RefusedWrite(2),
      Dropped,
      Dialled("wss://gateway.discord.gg/?v=10&encoding=json"),
    ]
}

/// A handler that crashes is a temporary child: the shard keeps reading and
/// the next event still gets its own process.
pub fn a_crashing_handler_does_not_take_the_shard_test() {
  let log = booklet.new([])
  let inbox = process.new_subject()

  let assert Ok(_) =
    glyde.new(
      token: frames.token,
      intents: intents.new([intents.GuildMessages]),
    )
    |> glyde.with_transport(scripted(log, fn(_) { created() }))
    |> glyde.on_status(signal_halt(inbox))
    |> glyde.on_message(fn(_api, msg) {
      case msg.id == first_id() {
        True -> panic as "first handler crashes"
        False -> {
          did(log, Saw("second ran"))
          process.send(inbox, Done)
        }
      }
    })
    |> glyde.start

  await(inbox, handlers: 1)
  assert list.contains(booklet.get(log), Saw("second ran"))
}

/// The same scripted session, run as a child of someone else's tree — which
/// is how anything with more than a bot in it will start glyde.
///
/// The names it registers under come off the bot value rather than out of the
/// start, so the child specification can be restarted for as long as the VM
/// lives. A tree that minted its own would burn three uncollectable atoms on
/// every restart instead.
pub fn a_supervised_session_test() {
  let log = booklet.new([])
  let inbox = process.new_subject()

  let bot =
    glyde.new(
      token: frames.token,
      intents: intents.new([intents.Guilds, intents.GuildMessages]),
    )
    |> glyde.with_transport(scripted(log, fn(_) { created() }))
    |> glyde.on_status(signal_halt(inbox))
    |> glyde.on_ready(fn(_api, _ready) { process.send(inbox, Done) })
    |> glyde.on_message(fn(_api, msg) {
      did(log, Saw("supervised saw " <> msg.content))
      process.send(inbox, Done)
    })

  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(glyde.supervised(bot))
    |> supervisor.start

  await(inbox, handlers: 3)
  assert list.contains(booklet.get(log), Saw("supervised saw !ping"))
}

fn first_id() -> id.MessageId {
  id.from_string("1000000000000000001")
}

fn bump(counter: Booklet(Int)) -> Int {
  booklet.update(counter, fn(count) { count + 1 })
  booklet.get(counter)
}

/// 4004, which glyde reads as fatal, so the shard stops instead of redialling.
fn fatal() -> transport.Event {
  transport.Closed(4004, "Authentication failed", None)
}

fn created() -> Response(BitArray) {
  response.set_body(response.new(200), <<
    "{\"id\":\"1000000000000000004\",\"channel_id\":\"1000000000000000002\",\"author\":{\"id\":\"1000000000000000003\"},\"type\":0}":utf8,
  >>)
}

/// Discord's 429, header and body both.
fn too_fast(seconds: Int) -> Response(BitArray) {
  let s = case seconds {
    0 -> "0"
    _ -> "1"
  }
  response.new(429)
  |> response.set_header("retry-after", s)
  |> response.set_header("x-ratelimit-scope", "user")
  |> response.set_body(<<
    "{\"message\":\"You are being rate limited.\",\"retry_after\":":utf8,
    s:utf8,
    ",\"global\":false}":utf8,
  >>)
}

/// Real clock, scripted socket. The limiter actor schedules with real time, so
/// a fake clock here would leave it waiting on a Tick that never lines up.
fn scripted(
  log: Booklet(List(Step)),
  answer: fn(Request(BitArray)) -> Response(BitArray),
) -> transport.Transport {
  transport.Transport(
    open: fn(url) {
      did(log, Dialled(url))
      socket(log, script())
    },
    request: fn(built) {
      did(log, Posted(built.path))
      Ok(answer(built))
    },
    now: timing.now,
    // Never reached: the script always ends in a fatal close, so the shard
    // stops before it would wait for a redial.
    idle: fn(_) { Nil },
  )
}

/// `scripted`, keeping every request body as text.
fn recording(
  log: Booklet(List(Step)),
  bodies: Booklet(List(String)),
) -> transport.Transport {
  let base = scripted(log, fn(_) { created() })
  transport.Transport(..base, request: fn(built: Request(BitArray)) {
    let assert Ok(text) = bit_array.to_string(built.body)
    booklet.update(bodies, fn(seen) { [text, ..seen] })
    base.request(built)
  })
}

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
    [fatal()],
  ]
}

fn ping(id: String) -> json.Json {
  json.object([
    #("id", json.string("100000000000000000" <> id)),
    #("channel_id", json.string("1000000000000000002")),
    #("author", json.object([#("id", json.string("1000000000000000003"))])),
    #("content", json.string("!ping")),
    #("type", json.int(0)),
  ])
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
        [] -> #(socket(log, []), [fatal()])
        [next, ..rest] -> #(socket(log, rest), next)
      }
    },
  )
}

/// A MESSAGE_CREATE with no `id` and no `author`.
fn drifted(log: Booklet(List(Step))) -> transport.Transport {
  transport.Transport(
    open: fn(url) {
      did(log, Dialled(url))
      socket(log, [
        [transport.Opened],
        [transport.TextMessage(frames.hello(41_250))],
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
        [fatal()],
      ])
    },
    request: fn(_) { panic as "this bot never calls REST" },
    now: timing.now,
    idle: fn(_) { Nil },
  )
}

/// Two dials: one that refuses the write, then one that ends the run. This bot
/// makes no REST call, so a scripted clock is fine and the redial gap costs
/// nothing.
fn refusing(log: Booklet(List(Step))) -> transport.Transport {
  let clock = booklet.new(0)
  let dials = booklet.new(0)

  transport.Transport(
    open: fn(url) {
      did(log, Dialled(url))
      case bump(dials) {
        1 ->
          deaf(log, [
            [transport.Opened],
            [transport.TextMessage(frames.hello(41_250))],
          ])
        _ -> socket(log, [[transport.Opened], [fatal()]])
      }
    },
    request: fn(_) { panic as "this bot never calls REST" },
    now: fn() { booklet.get(clock) },
    idle: fn(in_ms) { booklet.set(clock, booklet.get(clock) + in_ms) },
  )
}

fn deaf(
  log: Booklet(List(Step)),
  remaining: List(List(transport.Event)),
) -> transport.Socket {
  transport.Socket(
    send: fn(text) {
      did(log, RefusedWrite(opcode(text)))
      False
    },
    close: fn(_) { Nil },
    drop: fn() { did(log, Dropped) },
    turn: fn(_) {
      case remaining {
        [] -> #(deaf(log, []), [transport.Closed(1006, "", None)])
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
  booklet.update(log, fn(seen) { [step, ..seen] })
  Nil
}
