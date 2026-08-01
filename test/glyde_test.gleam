import booklet.{type Booklet}
import gleam/dynamic/decode
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleeunit
import glyde
import glyde/api/channel
import glyde/event
import glyde/id
import glyde/intents
import glyde/payload/message as outgoing
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
  Posted(path: String)
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
  |> glyde.on_ready(fn(_bot, pongs, ready) {
    did(log, Saw("ready as " <> id.to_string(ready.me.user.id)))
    pongs
  })
  |> glyde.on_message(fn(bot, pongs, message) {
    did(log, Saw("message " <> message.content))
    glyde.reply(bot, message, "pong!")
    pongs + 1
  })
  // A second listener is handed what the first returned, not the turn's start.
  |> glyde.on_message(fn(_bot, pongs, _message) {
    did(log, Saw("tally " <> int.to_string(pongs)))
    pongs
  })
  |> glyde.run

  assert list.reverse(booklet.get(log))
    == [
      Dialled("wss://gateway.discord.gg/?v=10&encoding=json"),
      // Op 2 is IDENTIFY.
      Wrote(2),
      Saw("ready as 1000000000000000000"),
      Saw("message !ping"),
      Posted("/api/v10/channels/1000000000000000002/messages"),
      Saw("tally 1"),
      Saw("message !ping"),
      Posted("/api/v10/channels/1000000000000000002/messages"),
      Saw("tally 2"),
    ]
}

/// `call` hands the answer back rather than into a callback, so a handler can
/// put what Discord said into the state it returns. The listener after it sees
/// that state, which is the only way from out here to watch the answer travel.
pub fn a_call_answers_into_the_state_test() {
  let log = booklet.new([])

  glyde.new(
    token: frames.token,
    state: "nothing posted",
    intents: intents.new([intents.Guilds, intents.GuildMessages]),
  )
  |> glyde.with_transport(scripted(log))
  |> glyde.on_status(fn(_) { Nil })
  |> glyde.on_message(fn(bot, last, message) {
    let post =
      channel.create_message(
        message.channel_id,
        outgoing.create_body(outgoing.text("pong!")),
      )
    case glyde.call(bot, post) {
      Ok(posted) -> id.to_string(posted.id)
      Error(_) -> last
    }
  })
  |> glyde.on_message(fn(_bot, last, _message) {
    did(log, Saw("posted " <> last))
    last
  })
  |> glyde.run

  assert list.contains(booklet.get(log), Saw("posted 1000000000000000004"))
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
      glyde.Undecodable(name:, errors:) -> {
        assert errors != []
        did(log, Undecodable(name))
      }
      _ -> Nil
    }
  })
  |> glyde.on_event(fn(_bot, state, seen) {
    case seen {
      event.Raw(name:, data: _) -> did(log, Saw("raw " <> name))
      _ -> Nil
    }
    state
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
      did(log, Posted(built.path))
      Ok(
        response.set_body(response.new(200), <<
          "{\"id\":\"1000000000000000004\",\"channel_id\":\"1000000000000000002\",\"author\":{\"id\":\"1000000000000000003\"}}":utf8,
        >>),
      )
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
