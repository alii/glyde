//// A whole connection with no network. The transport keeps only what a real
//// adapter holds: the `Conn` it was handed and the stamps of its timers.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import glyde/client
import glyde/gateway
import glyde/gateway/command
import glyde/gateway/frame
import glyde/gateway/presence
import glyde/id
import glyde/intents
import glyde/rng

/// One thing the driver asked the outside world to do. Timer stamps live in
/// `Fake.timers`, so firing one goes through the value the adapter was given.
type Call {
  Dialled(conn: gateway.Conn, host: String, path: String)
  Sent(op: frame.Opcode, text: String)
  Shut(code: Int)
  Dropped
  Armed(timer: gateway.Timer, in_ms: Int)
  Cancelled(timer: gateway.Timer)
  SlotWanted(conn: gateway.Conn)
  SlotFreed(conn: gateway.Conn)
  Inflating(bytes: BitArray)
  ContextReset(conn: gateway.Conn)
  Saw(event: gateway.Event)
  Noted(notice: gateway.Notice)
}

type Fake {
  Fake(
    /// Newest first.
    log: List(Call),
    /// The handles a real adapter would be holding: the socket it opened, the
    /// timers it has outstanding, and the inflate it has been asked for.
    conn: Option(gateway.Conn),
    timers: List(#(gateway.Timer, gateway.Stamp)),
    inflate: Option(#(gateway.Conn, gateway.Stamp)),
  )
}

fn nothing() -> Fake {
  Fake(log: [], conn: None, timers: [], inflate: None)
}

fn did(fake: Fake, call: Call) -> Fake {
  Fake(..fake, log: [call, ..fake.log])
}

fn recording() -> client.Transport(Fake) {
  client.Transport(
    open: fn(fake, conn, host, path) {
      Fake(..did(fake, Dialled(conn, host, path)), conn: Some(conn))
    },
    send: fn(fake, payload: frame.Outbound) {
      did(fake, Sent(op: payload.op, text: payload.text))
    },
    close: fn(fake, code) { did(fake, Shut(code)) },
    drop: fn(fake) { did(fake, Dropped) },
    // Arming replaces whatever was armed under the same name.
    arm: fn(fake, timer, in_ms, stamp) {
      let fake = did(fake, Armed(timer, in_ms))
      Fake(..fake, timers: list.key_set(fake.timers, timer, stamp))
    },
    cancel: fn(fake, timer) {
      let fake = did(fake, Cancelled(timer))
      Fake(..fake, timers: drop_key(fake.timers, timer))
    },
  )
}

fn coordinator() -> client.Slots(Fake) {
  client.Fleet(
    request: fn(fake, conn) { did(fake, SlotWanted(conn)) },
    release: fn(fake, conn) { did(fake, SlotFreed(conn)) },
  )
}

fn zlib() -> client.Inflater(Fake) {
  client.Zlib(
    inflate: fn(fake, conn, stamp, bytes) {
      Fake(..did(fake, Inflating(bytes)), inflate: Some(#(conn, stamp)))
    },
    reset: fn(fake, conn) {
      Fake(..did(fake, ContextReset(conn)), inflate: None)
    },
  )
}

fn drop_key(pairs: List(#(k, v)), key: k) -> List(#(k, v)) {
  list.filter(pairs, fn(pair) { pair.0 != key })
}

const interval = 41_250

const handshake_ms = 30_000

const identify = "{\"op\":2,\"d\":{\"token\":\"tok\",\"properties\":{\"os\":\"test\",\"browser\":\"glyde\",\"device\":\"glyde\"},\"compress\":false,\"large_threshold\":50,\"shard\":[0,1],\"intents\":0}}"

/// The properties are pinned so an IDENTIFY assertion can name them.
fn conf() -> gateway.Config {
  gateway.Config(
    ..gateway.config(token: "tok", intents: intents.none()),
    properties: gateway.properties(
      os: "test",
      browser: "glyde",
      device: "glyde",
    ),
  )
}

/// `rng.fixed` never advances, so every jittered delay is the bottom of its
/// range and every expected number is one you can write down.
fn around(shard: gateway.Shard) -> client.Bot(Fake) {
  client.from_shard(
    shard: gateway.Shard(..shard, rng: rng.fixed(0)),
    state: nothing(),
    transport: recording(),
  )
  |> client.on_event(fn(fake, event) { client.keep(did(fake, Saw(event))) })
  |> client.on_notice(fn(fake, notice) { did(fake, Noted(notice)) })
}

fn bot() -> client.Bot(Fake) {
  around(gateway.new(config: conf(), seed: 1))
}

fn host(text: String) -> gateway.Host {
  let assert Ok(host) = gateway.host_of(text)
  host
}

fn stored() -> gateway.Session {
  gateway.Session(id: "sess", resume_host: host("resume.discord.gg"), seq: 1337)
}

// Wire frames. `t` and `s` are explicit nulls on control frames, which is what
// the production gateway sends.

fn hello() -> String {
  "{\"t\":null,\"s\":null,\"op\":10,\"d\":{\"heartbeat_interval\":41250}}"
}

fn ready() -> String {
  "{\"op\":0,\"s\":1,\"t\":\"READY\",\"d\":{\"session_id\":\"sess\",\"resume_gateway_url\":\"wss://resume.discord.gg\",\"user\":{\"id\":\"80351110224678912\"},\"guilds\":[{},{}]}}"
}

fn dispatch(seq: Int, name: String) -> String {
  "{\"op\":0,\"s\":"
  <> int.to_string(seq)
  <> ",\"t\":\""
  <> name
  <> "\",\"d\":{\"a\":1}}"
}

/// Everything the driver did, oldest first.
fn log(bot: client.Bot(Fake)) -> List(Call) {
  list.reverse(client.state(bot).log)
}

/// Forget what has happened so far, so the next assertion is one call's worth
/// of work. The handles survive: an adapter does not forget its socket.
fn afresh(bot: client.Bot(Fake)) -> client.Bot(Fake) {
  client.update(bot, fn(fake) { Fake(..fake, log: []) })
}

/// The socket the transport was told to open, which is all an adapter has.
fn socket(bot: client.Bot(Fake)) -> gateway.Conn {
  let assert Some(conn) = client.state(bot).conn
  conn
}

/// Fire a timer with the stamp the adapter was handed when it armed it.
fn fire(bot: client.Bot(Fake), timer: gateway.Timer) -> client.Bot(Fake) {
  let assert Ok(stamp) = list.key_find(client.state(bot).timers, timer)
  client.timer_fired(bot, timer, stamp)
}

/// The timers still outstanding, named so the order is stable.
fn outstanding(bot: client.Bot(Fake)) -> List(String) {
  client.state(bot).timers
  |> list.map(fn(pair) { string.inspect(pair.0) })
  |> list.sort(string.compare)
}

/// Dispatch payloads are `Dynamic`, so they are asserted by name and sequence
/// and dropped from the structural log.
fn plain(calls: List(Call)) -> List(Call) {
  list.filter(calls, fn(call) {
    case call {
      Saw(gateway.Dispatch(_, _, _)) -> False
      _ -> True
    }
  })
}

fn dispatched(calls: List(Call)) -> List(#(String, Int)) {
  list.filter_map(calls, fn(call) {
    case call {
      Saw(gateway.Dispatch(name:, seq:, data: _)) -> Ok(#(name, seq))
      _ -> Error(Nil)
    }
  })
}

fn sent(calls: List(Call)) -> List(String) {
  list.filter_map(calls, fn(call) {
    case call {
      Sent(text:, ..) -> Ok(text)
      _ -> Error(Nil)
    }
  })
}

/// Started and dialled: the socket is up and waiting for HELLO.
fn greeting() -> client.Bot(Fake) {
  let bot = fire(client.start(bot()), gateway.Reconnect)
  client.opened(bot, socket(bot))
}

/// HELLO answered. Under the default `Solo` slots the IDENTIFY has already
/// gone out, because the driver granted the slot to itself.
fn identifying() -> client.Bot(Fake) {
  let bot = greeting()
  client.received(bot, socket(bot), hello())
}

fn live() -> client.Bot(Fake) {
  let bot = identifying()
  client.received(bot, socket(bot), ready())
}

/// The same boot with a fleet coordinator, so the slot outputs `Solo` absorbs
/// are visible at the transport.
fn fleet_greeting() -> client.Bot(Fake) {
  let bot = client.with_slots(bot(), coordinator())
  let bot = fire(client.start(bot), gateway.Reconnect)
  client.opened(bot, socket(bot))
}

/// The whole handshake as one list, with no socket anywhere.
pub fn a_whole_connection_reaches_the_transport_test() {
  let bot = client.start(bot())
  let bot = fire(bot, gateway.Reconnect)
  let bot = client.opened(bot, socket(bot))
  let bot = client.received(bot, socket(bot), hello())
  let bot = client.received(bot, socket(bot), ready())

  // `Solo` slots answer the identify request themselves and a `Plaintext`
  // inflater has no context to reset, so neither reaches the transport.
  assert plain(log(bot))
    == [
      // Start: nothing is assumed about what a hand-built shard had armed.
      Cancelled(gateway.Heartbeat),
      Cancelled(gateway.Handshake),
      Cancelled(gateway.Commands),
      Armed(gateway.Reconnect, 0),
      // The dial, one tick later.
      Dialled(gateway.Conn(5), "gateway.discord.gg", "/?v=10&encoding=json"),
      Armed(gateway.Handshake, handshake_ms),
      // HELLO: the watchdog stops, the first beat is jittered, and the slot
      // request loops straight back because these are Solo slots.
      Cancelled(gateway.Handshake),
      Armed(gateway.Heartbeat, 0),
      Noted(gateway.AwaitingIdentifySlot),
      Sent(frame.OpIdentify, identify),
      Armed(gateway.Handshake, handshake_ms),
      // READY.
      Cancelled(gateway.Handshake),
      Cancelled(gateway.Reconnect),
      Cancelled(gateway.Commands),
      Saw(gateway.Ready(
        session_id: "sess",
        user: id.from_string("80351110224678912"),
        resume_host: host("resume.discord.gg"),
        guild_count: 2,
      )),
    ]
  assert dispatched(log(bot)) == [#("READY", 1)]
  assert outstanding(bot) == ["Heartbeat"]
  assert client.is_terminal(bot) == False
}

/// `discarding` leaves an inert bot, not a crashing one, and the shard still
/// advances.
pub fn a_bot_with_no_transport_still_advances_test() {
  let bare =
    client.new(
      token: "tok",
      intents: intents.none(),
      transport: client.discarding(),
    )
  assert client.shard(client.start(bare)).phase
    == gateway.Waiting(gateway.Identify)
}

/// `new` is the short door onto the same builder.
pub fn new_is_the_default_config_test() {
  let bare =
    client.new(
      token: "tok",
      intents: intents.new([intents.Guilds]),
      transport: client.discarding(),
    )
  let config = client.shard(bare).config
  assert config.token == "tok"
  assert config.intents == intents.new([intents.Guilds])
  assert config.host == gateway.default_host()
  assert config.api_version == 10
}

/// An event reaches the handler only after every protocol effect of the same
/// batch has run, so a handler cannot see a shard mid-transition.
pub fn events_arrive_after_the_protocol_effects_test() {
  let bot = fleet_greeting()
  let bot = client.received(bot, socket(bot), hello())
  let bot = afresh(client.slot_granted(bot, socket(bot)))
  let bot = client.received(bot, socket(bot), ready())

  let before_the_event =
    list.take_while(log(bot), fn(call) {
      case call {
        Saw(_) -> False
        _ -> True
      }
    })
  assert list.contains(before_the_event, Cancelled(gateway.Handshake))
  assert list.contains(before_the_event, SlotFreed(gateway.Conn(5)))
}

/// A handler's command goes out in the same turn, after the batch that
/// produced the event.
pub fn a_handler_command_goes_out_in_the_same_turn_test() {
  let bot =
    afresh(identifying())
    |> client.on_event(fn(fake, event) {
      case event {
        gateway.Ready(_, _, _, _) ->
          client.keep(did(fake, Saw(event)))
          |> client.sending(
            command.UpdatePresence(presence.new(presence.Idle(None))),
          )
        _ -> client.keep(did(fake, Saw(event)))
      }
    })
  let bot = client.received(bot, socket(bot), ready())

  assert sent(log(bot))
    == [
      "{\"op\":3,\"d\":{\"since\":null,\"activities\":[],\"status\":\"idle\",\"afk\":false}}",
    ]
  // In this turn, and after the event that asked for it.
  let assert Ok(event_at) =
    index_of(log(bot), fn(call) {
      case call {
        Saw(gateway.Ready(_, _, _, _)) -> True
        _ -> False
      }
    })
  let assert Ok(send_at) =
    index_of(log(bot), fn(call) {
      case call {
        Sent(..) -> True
        _ -> False
      }
    })
  assert send_at > event_at
}

fn index_of(calls: List(Call), match: fn(Call) -> Bool) -> Result(Int, Nil) {
  calls
  |> list.index_map(fn(call, index) { #(call, index) })
  |> list.find_map(fn(pair) {
    case match(pair.0) {
      True -> Ok(pair.1)
      False -> Error(Nil)
    }
  })
}

/// Two commands from one handler go out in the order the handler wrote them.
pub fn handler_commands_keep_their_order_test() {
  let bot =
    afresh(identifying())
    |> client.on_event(fn(fake, event) {
      case event {
        gateway.Ready(_, _, _, _) ->
          client.keep(fake)
          |> client.sending(
            command.UpdatePresence(presence.new(presence.Online)),
          )
          |> client.sending(
            command.UpdatePresence(presence.new(presence.Invisible)),
          )
        _ -> client.keep(fake)
      }
    })
  let bot = client.received(bot, socket(bot), ready())

  assert list.map(sent(log(bot)), string.contains(_, "\"online\""))
    == [True, False]
}

/// `collecting` hands the events back without a second mode in the driver.
pub fn collecting_keeps_every_event_test() {
  let bot =
    client.from_shard(
      shard: gateway.Shard(
        ..gateway.new(config: conf(), seed: 1),
        rng: rng.fixed(0),
      ),
      state: [],
      transport: client.discarding(),
    )
    |> client.on_event(client.collecting)
  let bot = fire_bare(client.start(bot), gateway.Reconnect)
  let bot = client.opened(bot, client.conn(bot))
  let bot = client.received(bot, client.conn(bot), hello())
  let bot = client.received(bot, client.conn(bot), ready())
  let bot =
    client.received(bot, client.conn(bot), dispatch(2, "MESSAGE_CREATE"))

  assert list.map(list.reverse(client.state(bot)), name_of)
    == ["Ready", "READY", "MESSAGE_CREATE"]
}

fn name_of(event: gateway.Event) -> String {
  case event {
    gateway.Ready(_, _, _, _) -> "Ready"
    gateway.Resumed -> "Resumed"
    gateway.Dispatch(name:, seq: _, data: _) -> name
    gateway.Reconnecting(_, _, _) -> "Reconnecting"
    gateway.Halted(_) -> "Halted"
  }
}

/// A bot with no recording transport still has to fire timers, and the shard is
/// the only place its stamps exist.
fn fire_bare(bot: client.Bot(s), timer: gateway.Timer) -> client.Bot(s) {
  let stamps = client.shard(bot).stamps
  let stamp = case timer {
    gateway.Heartbeat -> stamps.heartbeat
    gateway.Handshake -> stamps.handshake
    gateway.Reconnect -> stamps.reconnect
    gateway.Commands -> stamps.commands
  }
  client.timer_fired(bot, timer, stamp)
}

/// A frame from a socket the shard has given up on changes nothing. This is the
/// guard an adapter defeats by synthesising a `Conn`, so the fake never does.
pub fn a_frame_from_an_abandoned_socket_is_ignored_test() {
  let bot = afresh(live())
  let after = client.received(bot, gateway.Conn(99), hello())

  assert log(after)
    == [Noted(gateway.Ignored(gateway.StaleConn(gateway.Conn(99))))]
  assert client.shard(after).phase == client.shard(bot).phase
}

/// A timer fire that lost the race with its own cancellation is recognised by
/// its stamp and dropped.
pub fn a_timer_fire_that_lost_its_race_is_ignored_test() {
  let bot = afresh(live())
  let after = client.timer_fired(bot, gateway.Heartbeat, gateway.Stamp(0))

  assert log(after)
    == [Noted(gateway.Ignored(gateway.StaleTimer(gateway.Heartbeat)))]
  assert client.shard(after).phase == client.shard(bot).phase
}

/// The transport reports our own close back, and that report must not start a
/// second reconnect or double the backoff ladder.
pub fn the_echo_of_our_own_close_does_not_reconnect_twice_test() {
  // Two beats with no ACK in between: the shard tears the socket down.
  let bot = fire(live(), gateway.Heartbeat)
  let bot = afresh(fire(bot, gateway.Heartbeat))

  // The transport reports the close on the socket it is still holding.
  let after = client.closed(bot, socket(bot), Some(1006))
  assert log(after)
    == [Noted(gateway.Ignored(gateway.StaleConn(gateway.Conn(5))))]
}

/// The default. Nobody to take turns with, so the driver answers its own
/// request and the IDENTIFY goes out in the same call as the HELLO.
pub fn solo_slots_identify_without_a_coordinator_test() {
  let bot = afresh(greeting())
  let bot = client.received(bot, socket(bot), hello())

  assert sent(log(bot)) == [identify]
  assert list.any(log(bot), fn(call) {
      case call {
        SlotWanted(_) -> True
        _ -> False
      }
    })
    == False
}

/// Nothing is written until the coordinator answers.
pub fn fleet_slots_wait_for_the_coordinator_test() {
  let bot = afresh(fleet_greeting())
  let bot = client.received(bot, socket(bot), hello())

  assert sent(log(bot)) == []
  assert list.contains(log(bot), SlotWanted(gateway.Conn(5)))

  let bot = client.slot_granted(afresh(bot), socket(bot))
  assert sent(log(bot)) == [identify]
}

/// READY hands the slot back, so the next shard in the fleet can go.
pub fn a_fleet_slot_comes_back_on_ready_test() {
  let bot = fleet_greeting()
  let bot = client.received(bot, socket(bot), hello())
  let bot = afresh(client.slot_granted(bot, socket(bot)))
  let bot = client.received(bot, socket(bot), ready())

  assert list.contains(log(bot), SlotFreed(gateway.Conn(5)))
}

/// A grant that arrives for a socket the shard already gave up on is handed
/// straight back, so the fleet's budget is not held by a dead connection.
pub fn a_grant_for_a_dead_socket_is_returned_test() {
  let bot = afresh(fleet_greeting())
  let bot = client.slot_granted(bot, gateway.Conn(99))

  assert log(bot)
    == [
      SlotFreed(gateway.Conn(99)),
      Noted(gateway.Ignored(gateway.StaleConn(gateway.Conn(99)))),
    ]
}

fn compressed() -> gateway.Config {
  gateway.Config(..conf(), compression: gateway.ZlibStream)
}

/// The payload terminator, so the core sees one complete payload. The fake
/// answers with whatever text the test wants.
fn one_payload() -> BitArray {
  <<"squashed":utf8, 0x00, 0x00, 0xFF, 0xFF>>
}

/// A request and a reply, so the buffering path is testable with no zlib.
pub fn an_inflater_answers_the_core_test() {
  let bot =
    around(gateway.new(config: compressed(), seed: 1))
    |> client.with_inflater(zlib())
  let bot = fire(client.start(bot), gateway.Reconnect)
  // A zlib stream carries a back-reference dictionary from one payload to the
  // next, so every connection gets a context of its own.
  assert list.contains(log(bot), ContextReset(gateway.Conn(5)))

  let bot = afresh(client.opened(bot, socket(bot)))
  let bot = client.received_bytes(bot, socket(bot), one_payload())
  assert list.contains(log(bot), Inflating(one_payload()))

  let assert Some(#(conn, stamp)) = client.state(bot).inflate
  let bot = client.inflated(bot, conn, stamp, Ok(hello()))
  assert sent(log(bot)) == [identify]
}

/// The adapter has to ask for the mode the core is expecting.
pub fn compression_shows_up_in_the_path_test() {
  let bot =
    around(gateway.new(config: compressed(), seed: 1))
    |> client.with_inflater(zlib())
  let bot = fire(client.start(bot), gateway.Reconnect)

  assert list.contains(
    log(bot),
    Dialled(
      gateway.Conn(5),
      "gateway.discord.gg",
      "/?v=10&encoding=json&compress=zlib-stream",
    ),
  )
}

/// Compression the bot cannot read is not something a builder can reach: the
/// inflater is the switch, and a config asking for `zlib-stream` with no
/// context to inflate with is turned back off rather than dialled.
pub fn compression_without_an_inflater_is_not_constructible_test() {
  let plain = around(gateway.new(config: compressed(), seed: 1))
  assert client.shard(plain).config.compression == gateway.NoCompression

  let inflating = client.with_inflater(plain, zlib())
  assert client.shard(inflating).config.compression == gateway.ZlibStream

  // And back: dropping the context drops the mode with it.
  let plain_again = client.with_inflater(inflating, client.Plaintext)
  assert client.shard(plain_again).config.compression == gateway.NoCompression
}

/// The mode the bot ends up in is the one it dials with, so a config the
/// inflater overruled cannot leave `compress=` in the path.
pub fn a_bot_with_no_inflater_dials_uncompressed_test() {
  let bot = around(gateway.new(config: compressed(), seed: 1))
  let bot = fire(client.start(bot), gateway.Reconnect)

  assert list.contains(
    log(bot),
    Dialled(gateway.Conn(5), "gateway.discord.gg", "/?v=10&encoding=json"),
  )
}

pub fn a_command_sent_while_live_goes_straight_out_test() {
  let bot = afresh(live())
  let bot =
    client.command(bot, command.UpdatePresence(presence.new(presence.Online)))

  assert sent(log(bot))
    == [
      "{\"op\":3,\"d\":{\"since\":null,\"activities\":[],\"status\":\"online\",\"afk\":false}}",
    ]
}

/// A command sent before the shard is live waits in the shard, not on the
/// floor, so a presence set during a reconnect survives it.
pub fn a_command_sent_too_early_survives_the_handshake_test() {
  let bot = afresh(greeting())
  let bot =
    client.command(
      bot,
      command.UpdatePresence(presence.new(presence.Idle(None))),
    )
  assert sent(log(bot)) == []
  assert list.contains(log(bot), Noted(gateway.CommandQueued(1)))

  let bot = afresh(client.received(bot, socket(bot), hello()))
  let bot = client.received(bot, socket(bot), ready())
  assert list.map(sent(log(bot)), string.contains(_, "\"idle\"")) == [True]
}

pub fn a_guild_member_request_is_a_command_like_any_other_test() {
  let bot = afresh(live())
  let assert Ok(limit) = command.limit(5)
  let bot =
    client.command(
      bot,
      command.RequestGuildMembers(command.ByPrefix(
        guild: id.from_string("41771983423143937"),
        prefix: "a",
        limit:,
        nonce: None,
      )),
    )

  assert sent(log(bot))
    == [
      "{\"op\":8,\"d\":{\"guild_id\":\"41771983423143937\",\"query\":\"a\",\"limit\":5}}",
    ]
}

/// 1000 ends the session on purpose. Nothing is left armed, and nothing later
/// is acted on.
pub fn stop_closes_cleanly_and_leaves_nothing_behind_test() {
  let bot = afresh(live())
  let bot = client.stop(bot)

  assert plain(log(bot))
    == [
      Shut(1000),
      Cancelled(gateway.Heartbeat),
      Cancelled(gateway.Handshake),
      Cancelled(gateway.Reconnect),
      Cancelled(gateway.Commands),
      Saw(gateway.Halted(gateway.Requested)),
    ]
  assert outstanding(bot) == []
  assert client.is_terminal(bot)
  assert client.session(bot) == None
}

pub fn a_stopped_bot_ignores_what_comes_after_test() {
  let bot = afresh(client.stop(live()))
  let after =
    client.command(bot, command.UpdatePresence(presence.new(presence.Online)))

  assert log(after) == [Noted(gateway.Ignored(gateway.Terminal))]
}

/// A persisted session boots straight into a RESUME: the session's own node,
/// op 6 rather than op 2, and no identify slot.
pub fn a_bot_built_from_a_session_resumes_test() {
  let bot = around(gateway.resuming(config: conf(), seed: 1, session: stored()))
  let bot = fire(client.start(bot), gateway.Reconnect)
  assert list.contains(
    log(bot),
    Dialled(gateway.Conn(5), "resume.discord.gg", "/?v=10&encoding=json"),
  )

  let bot = afresh(client.opened(bot, socket(bot)))
  let bot = client.received(bot, socket(bot), hello())
  assert sent(log(bot))
    == [
      "{\"op\":6,\"d\":{\"token\":\"tok\",\"session_id\":\"sess\",\"seq\":1337}}",
    ]
  assert list.any(log(bot), fn(call) {
      case call {
        SlotWanted(_) -> True
        _ -> False
      }
    })
    == False
}

/// What to persist: the value `gateway.resuming` wants back after a restart.
pub fn the_session_is_readable_for_a_restart_test() {
  assert client.session(live())
    == Some(gateway.Session(
      id: "sess",
      resume_host: host("resume.discord.gg"),
      seq: 1,
    ))
}

/// Two shards seeded the same jitter the same, which is the thundering herd the
/// jitter exists to break up. `with_seed` is how a fleet avoids it.
pub fn each_shard_can_have_its_own_jitter_test() {
  let backoff_after_a_failed_dial = fn(seed) {
    let bot =
      client.from_shard(
        shard: gateway.new(config: conf(), seed: 1),
        state: nothing(),
        transport: recording(),
      )
      |> client.with_seed(seed)
    let bot = afresh(fire(client.start(bot), gateway.Reconnect))
    let bot =
      client.open_failed(bot, socket(bot), gateway.Unreachable("refused"))
    list.filter_map(log(bot), fn(call) {
      case call {
        Armed(gateway.Reconnect, in_ms) -> Ok(in_ms)
        _ -> Error(Nil)
      }
    })
  }

  // Pinned, not just "different": a replay of a production input log has to
  // reproduce.
  assert backoff_after_a_failed_dial(1) == [886]
  assert backoff_after_a_failed_dial(2) == [625]
  assert backoff_after_a_failed_dial(7) == [614]
}

/// A raw step stops at the slot request; the driver answers it and carries on.
pub fn the_pure_core_is_still_underneath_test() {
  let bot = greeting()
  let conn = socket(bot)

  let gateway.Step(shard:, outputs:) =
    gateway.step(client.shard(bot), gateway.Frame(conn, hello()))
  assert list.contains(outputs, gateway.RequestIdentifySlot(conn))
  assert shard.phase
    == gateway.Queued(gateway.Beat(
      interval_ms: interval,
      unacked: 0,
      quiet: False,
    ))

  let driven = client.received(bot, conn, hello())
  assert client.shard(driven).phase
    == gateway.Identifying(gateway.Beat(
      interval_ms: interval,
      unacked: 0,
      quiet: False,
    ))
}

/// State that did not come from the gateway at all: a REST response, a tick of
/// your own.
pub fn update_edits_state_from_outside_a_handler_test() {
  let bot =
    client.update(bot(), fn(fake) { Fake(..fake, conn: Some(gateway.Conn(7))) })
  assert client.state(bot).conn == Some(gateway.Conn(7))
}

/// A heartbeat with no ACK before the next one is a zombie: the socket is torn
/// down and the ladder starts, and the driver performs all of it.
pub fn a_zombie_connection_is_torn_down_test() {
  let bot = fire(live(), gateway.Heartbeat)
  let bot = fire(afresh(bot), gateway.Heartbeat)

  assert list.contains(log(bot), Shut(4000))
  assert list.any(log(bot), fn(call) {
    case call {
      Saw(gateway.Reconnecting(
        in_ms: _,
        resuming: True,
        why: gateway.ZombieConnection,
      )) -> True
      _ -> False
    }
  })
  assert list.any(log(bot), fn(call) {
    case call {
      Armed(gateway.Reconnect, _) -> True
      _ -> False
    }
  })
}
