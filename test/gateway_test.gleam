import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import glyde/gateway.{
  type Input, type Output, type Session, type Shard, type Stamp, type Step,
  ArmTimer, Beat, Budget, CancelTimer, Close, Command, Conn, Dead, Dialing, Drop,
  Emit, Fired, Greeting, Identify, Identifying, Inflate, Inflated, Live, Note,
  Open, OpenFailed, Queued, ReleaseIdentifySlot, RequestIdentifySlot, Resume,
  Resuming, Send, Session, Stamp, Start, Step, Stop, Stopped, Waiting, attempts,
  inbound, pending, phase, shard_config, shard_rng, stamps, with_attempts,
  with_inbound, with_pending, with_phase, with_rng,
}
import glyde/gateway/close
import glyde/gateway/command
import glyde/gateway/frame as gateway_frame
import glyde/gateway/identify as gateway_identify
import glyde/gateway/presence
import glyde/gateway/ready
import glyde/gateway/reassembly
import glyde/id
import glyde/intents
import glyde/rng
import glyde/token
import glyde/websocket/sendcode

const interval = 41_250

const handshake_ms = 30_000

/// The properties are pinned so an IDENTIFY assertion can name them.
fn conf() -> gateway.Config {
  let base = gateway.config(token: token.new("tok"), intents: intents.none())
  gateway.Config(
    ..base,
    properties: gateway.properties(
      os: "test",
      browser: "glyde",
      device: "glyde",
    ),
  )
}

fn shard() -> Shard {
  gateway.new(config: conf(), seed: 1)
}

/// `Fixed` never advances, so every jitter in a test driven with it is the
/// bottom of its range and every expected delay is a number you can write down.
fn pinned(shard: Shard, value: Int) -> Shard {
  with_rng(shard, rng.fixed(value))
}

fn drive(shard: Shard, inputs: List(Input)) -> Shard {
  list.fold(inputs, shard, fn(shard, input) { gateway.step(shard, input).shard })
}

fn stamp_of(shard: Shard, timer: gateway.Timer) -> Stamp {
  case timer {
    gateway.Heartbeat -> stamps(shard).heartbeat
    gateway.Handshake -> stamps(shard).handshake
    gateway.Reconnect -> stamps(shard).reconnect
    gateway.Commands -> stamps(shard).commands
  }
}

fn fire(shard: Shard, timer: gateway.Timer) -> Step {
  gateway.step(shard, Fired(timer, stamp_of(shard, timer)))
}

fn frame(shard: Shard, text: String) -> Step {
  gateway.step(shard, gateway.Frame(gateway.conn(shard), text))
}

// Wire frames. `t` and `s` are explicit nulls on control frames, which is what
// the production gateway actually sends.

fn hello_at(interval_ms: Int) -> String {
  "{\"t\":null,\"s\":null,\"op\":10,\"d\":{\"heartbeat_interval\":"
  <> int.to_string(interval_ms)
  <> ",\"_trace\":[\"x\"]}}"
}

fn hello() -> String {
  hello_at(interval)
}

fn ready_at(seq: Int) -> String {
  "{\"op\":0,\"s\":"
  <> int.to_string(seq)
  <> ",\"t\":\"READY\",\"d\":{\"session_id\":\"sess\",\"resume_gateway_url\":\"wss://resume.discord.gg\",\"user\":{\"id\":\"80351110224678912\"},\"guilds\":[{},{}]}}"
}

fn dispatch_at(seq: Int, name: String) -> String {
  "{\"op\":0,\"s\":"
  <> int.to_string(seq)
  <> ",\"t\":\""
  <> name
  <> "\",\"d\":{\"a\":1}}"
}

fn ack() -> String {
  "{\"op\":11}"
}

fn beat_request() -> String {
  "{\"t\":null,\"s\":null,\"op\":1,\"d\":null}"
}

fn server_reconnect() -> String {
  "{\"op\":7,\"d\":null}"
}

fn invalid_session(resumable: Bool) -> String {
  case resumable {
    True -> "{\"op\":9,\"d\":true}"
    False -> "{\"op\":9,\"d\":false}"
  }
}

/// The gateway node READY pins this shard's session to, which is not the host
/// a fresh connection dials.
fn resume_host() -> gateway.Host {
  let assert Ok(host) = gateway.host_of("resume.discord.gg")
  host
}

fn stored() -> Session {
  Session(id: "sess", resume_host: resume_host(), seq: 1337)
}

/// Boot as far as the socket being up and awaiting HELLO.
fn greeting() -> Shard {
  shard()
  |> pinned(0)
  |> drive([Start])
  |> continue_to_greeting
}

fn continue_to_greeting(shard: Shard) -> Shard {
  let shard =
    drive(shard, [Fired(gateway.Reconnect, stamp_of(shard, gateway.Reconnect))])
  drive(shard, [gateway.Opened(gateway.conn(shard))])
}

fn queued() -> Shard {
  let shard = greeting()
  drive(shard, [gateway.Frame(gateway.conn(shard), hello())])
}

fn identifying() -> Shard {
  let shard = queued()
  drive(shard, [gateway.IdentifySlotGranted(gateway.conn(shard))])
}

fn live() -> Shard {
  let shard = identifying()
  drive(shard, [gateway.Frame(gateway.conn(shard), ready_at(1))])
}

/// Waiting for an identify slot with a presence too big to identify with.
fn bloated() -> Shard {
  let config =
    gateway.Config(
      ..conf(),
      presence: Some(presence.Presence(
        status: presence.Online,
        activities: [presence.Playing(string.repeat("a", 5000))],
        afk: False,
      )),
    )
  let shard =
    gateway.new(config:, seed: 1)
    |> pinned(0)
    |> drive([Start])
    |> continue_to_greeting
  drive(shard, [gateway.Frame(gateway.conn(shard), hello())])
}

/// The terminal phase a config that cannot build an IDENTIFY ends in.
fn unusable() -> Shard {
  let shard = bloated()
  drive(shard, [gateway.IdentifySlotGranted(gateway.conn(shard))])
}

/// A shard booted from a session the host persisted, sitting mid-RESUME.
fn resuming() -> Shard {
  gateway.resuming(config: conf(), seed: 1, session: stored())
  |> pinned(0)
  |> drive([Start])
  |> continue_to_greeting
  |> fn(shard) { drive(shard, [gateway.Frame(gateway.conn(shard), hello())]) }
}

// A dispatch payload is a `Dynamic`, so events carrying one are asserted by
// name and sequence rather than by value.

fn dispatched(outputs: List(Output)) -> List(#(String, Int)) {
  list.filter_map(outputs, fn(output) {
    case output {
      Emit(gateway.Dispatch(name:, seq:, data: _)) -> Ok(#(name, seq))
      _ -> Error(Nil)
    }
  })
}

fn plain(outputs: List(Output)) -> List(Output) {
  list.filter(outputs, fn(output) {
    case output {
      Emit(gateway.Dispatch(_, _, _)) -> False
      _ -> True
    }
  })
}

fn sends(outputs: List(Output)) -> List(String) {
  list.filter_map(outputs, fn(output) {
    case output {
      Send(payload) -> Ok(gateway_frame.outbound_text(payload))
      _ -> Error(Nil)
    }
  })
}

fn closes(outputs: List(Output)) -> List(Int) {
  list.filter_map(outputs, fn(output) {
    case output {
      Close(code) -> Ok(sendcode.to_int(code))
      _ -> Error(Nil)
    }
  })
}

fn reconnects(outputs: List(Output)) -> List(Int) {
  list.filter_map(outputs, fn(output) {
    case output {
      Emit(gateway.Reconnecting(in_ms:, resuming: _, why: _)) -> Ok(in_ms)
      _ -> Error(Nil)
    }
  })
}

fn whys(outputs: List(Output)) -> List(gateway.Why) {
  list.filter_map(outputs, fn(output) {
    case output {
      Emit(gateway.Reconnecting(in_ms: _, resuming: _, why:)) -> Ok(why)
      _ -> Error(Nil)
    }
  })
}

fn armed(outputs: List(Output), timer: gateway.Timer) -> List(Int) {
  list.filter_map(outputs, fn(output) {
    case output {
      ArmTimer(fired, in_ms, _) if fired == timer -> Ok(in_ms)
      _ -> Error(Nil)
    }
  })
}

/// `Start` arms an immediate dial and nothing else. The cancellations are the
/// point: a shard someone constructed by hand may have timers we did not arm.
pub fn start_arms_an_immediate_dial_test() {
  let Step(shard:, outputs:) = gateway.step(shard(), Start)
  assert outputs
    == [
      CancelTimer(gateway.Heartbeat),
      CancelTimer(gateway.Handshake),
      CancelTimer(gateway.Commands),
      ArmTimer(gateway.Reconnect, 0, Stamp(3)),
    ]
  assert phase(shard) == Waiting(Identify)
}

pub fn start_is_ignored_once_running_test() {
  let shard = drive(shard(), [Start])
  let Step(shard: after, outputs:) = gateway.step(shard, Start)
  assert outputs == [Note(gateway.Ignored(gateway.OutOfPhase))]
  assert after == shard
}

/// The watchdog is armed at the dial, so one budget covers a hung TLS connect
/// and a socket that upgrades and never says HELLO.
pub fn the_dial_bumps_the_connection_and_arms_the_watchdog_test() {
  let shard = drive(shard(), [Start])
  let Step(shard:, outputs:) = fire(shard, gateway.Reconnect)
  assert outputs
    == [
      gateway.ResetInflater(Conn(5)),
      Open(Conn(5), gateway.default_host(), "/?v=10&encoding=json"),
      ArmTimer(gateway.Handshake, handshake_ms, Stamp(6)),
    ]
  assert phase(shard) == Dialing(Identify)
  assert gateway.conn(shard) == Conn(5)
}

pub fn opening_the_socket_changes_nothing_else_test() {
  let shard = drive(shard(), [Start])
  let shard = fire(shard, gateway.Reconnect).shard
  let Step(shard: after, outputs:) =
    gateway.step(shard, gateway.Opened(gateway.conn(shard)))
  assert outputs == []
  assert phase(after) == Greeting(Identify)
  assert stamps(after) == stamps(shard)
}

/// HELLO on a fresh connection cancels the watchdog, jitters the first beat
/// and asks for an identify slot.
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

/// Discord asks for the first beat at `interval * jitter`, jitter in [0, 1).
/// Both ends of the range, so the clamp and the bound are both pinned.
pub fn the_first_heartbeat_is_jittered_across_the_interval_test() {
  let low = frame(greeting(), hello())
  assert armed(low.outputs, gateway.Heartbeat) == [0]

  let high = frame(pinned(greeting(), 999_999_999), hello())
  assert armed(high.outputs, gateway.Heartbeat) == [interval - 1]
}

/// A resume never queues, because it does not spend identify budget, and the
/// watchdog stays armed across the RESUME because a resume can wedge too.
pub fn hello_with_a_session_resumes_without_a_slot_test() {
  let shard = gateway.resuming(config: conf(), seed: 1, session: stored())
  let shard = continue_to_greeting(drive(pinned(shard, 0), [Start]))
  let Step(shard: after, outputs:) = frame(shard, hello())

  assert sends(outputs)
    == [
      "{\"op\":6,\"d\":{\"token\":\"tok\",\"session_id\":\"sess\",\"seq\":1337}}",
    ]
  assert list.contains(outputs, RequestIdentifySlot(Conn(5))) == False
  assert armed(outputs, gateway.Handshake) == [handshake_ms]
  assert phase(after)
    == Resuming(Beat(interval_ms: interval, unacked: 0, quiet: False), stored())
}

/// A resume dials the session's own gateway node, a fresh identify the
/// configured host. One value decides both.
pub fn the_dial_target_follows_the_intent_test() {
  let fresh = drive(shard(), [Start])
  let hosts = fn(shard: Shard) {
    list.filter_map(fire(shard, gateway.Reconnect).outputs, fn(output) {
      case output {
        Open(_, host, _) -> Ok(host)
        _ -> Error(Nil)
      }
    })
  }
  assert hosts(fresh) == [gateway.default_host()]

  let restored =
    drive(gateway.resuming(config: conf(), seed: 1, session: stored()), [Start])
  assert hosts(restored) == [resume_host()]
}

pub fn a_second_hello_is_ignored_test() {
  let shard = queued()
  let Step(shard: after, outputs:) = frame(shard, hello())
  assert outputs == [Note(gateway.Ignored(gateway.OutOfPhase))]
  // Not even the generator moves: an ignored input is not a state change.
  assert after == shard
}

pub fn the_slot_grant_sends_identify_test() {
  let shard = queued()
  let Step(shard: after, outputs:) =
    gateway.step(shard, gateway.IdentifySlotGranted(gateway.conn(shard)))

  assert sends(outputs)
    == [
      "{\"op\":2,\"d\":{\"token\":\"tok\",\"properties\":{\"os\":\"test\",\"browser\":\"glyde\",\"device\":\"glyde\"},\"compress\":false,\"large_threshold\":50,\"shard\":[0,1],\"intents\":0}}",
    ]
  assert armed(outputs, gateway.Handshake) == [handshake_ms]
  assert phase(after)
    == Identifying(Beat(interval_ms: interval, unacked: 0, quiet: False))
}

/// READY is the end of the handshake: the watchdog and the reconnect both stop,
/// the slot goes back, and the ladder resets.
pub fn ready_goes_live_test() {
  let shard = with_attempts(identifying(), 4)
  let Step(shard: after, outputs:) = frame(shard, ready_at(1))

  assert plain(outputs)
    == [
      CancelTimer(gateway.Handshake),
      CancelTimer(gateway.Reconnect),
      CancelTimer(gateway.Commands),
      ReleaseIdentifySlot(Conn(5)),
      Emit(gateway.Ready(
        session_id: "sess",
        user: id.from_string("80351110224678912"),
        resume_host: resume_host(),
        guild_count: 2,
      )),
    ]
  assert dispatched(outputs) == [#("READY", 1)]
  assert attempts(after) == 0
  assert phase(after)
    == Live(
      Beat(interval_ms: interval, unacked: 0, quiet: False),
      Session(id: "sess", resume_host: resume_host(), seq: 1),
      Budget(spent: 0, capacity: 110),
    )
}

/// A resume host is a hint about which node to come back to, and a RESUME
/// against the configured host works without it. Rejecting the READY would
/// throw away a live session and spend an IDENTIFY out of the 1000 a day.
pub fn a_ready_with_no_resume_host_falls_back_to_the_configured_one_test() {
  let shard = identifying()
  let Step(shard: after, outputs:) =
    frame(
      shard,
      "{\"op\":0,\"s\":1,\"t\":\"READY\",\"d\":{\"session_id\":\"sess\","
        <> "\"resume_gateway_url\":\"wss://\",\"user\":{\"id\":\"7\"},"
        <> "\"guilds\":[]}}",
    )

  assert gateway.session(after)
    == Some(Session(id: "sess", resume_host: gateway.default_host(), seq: 1))
  assert list.contains(
    outputs,
    Note(gateway.UndecodableFrame(gateway.ReadyWithoutResumeHost)),
  )
  assert closes(outputs) == []
}

/// A READY we cannot read is useless: identify again rather than sit with a
/// half-initialised session until the watchdog fires. Nothing stalled, so the
/// host is not told the watchdog expired.
pub fn an_unreadable_ready_reconnects_and_reidentifies_test() {
  let shard = identifying()
  let Step(shard: after, outputs:) =
    frame(shard, "{\"op\":0,\"s\":1,\"t\":\"READY\",\"d\":{}}")

  assert closes(outputs) == [4000]
  assert phase(after) == Waiting(Identify)
  assert gateway.session(after) == None
  assert whys(outputs) == [gateway.HandshakeUnreadable]
  assert list.any(outputs, fn(output) {
    case output {
      Note(gateway.UndecodableFrame(gateway.ReadyIncomplete(ready.MissingReadyFields(
        _,
      )))) -> True
      _ -> False
    }
  })
}

/// Connected means READY or RESUMED, never READY alone. A process that booted
/// from a persisted session never sees a READY at all.
pub fn resumed_goes_live_without_a_ready_test() {
  let shard = resuming()
  let Step(shard: after, outputs:) =
    frame(
      shard,
      "{\"op\":0,\"s\":1400,\"t\":\"RESUMED\",\"d\":{\"_trace\":[]}}",
    )

  assert list.contains(outputs, Emit(gateway.Resumed))
  assert list.contains(outputs, CancelTimer(gateway.Handshake))
  assert dispatched(outputs) == [#("RESUMED", 1400)]
  assert gateway.session(after) == Some(Session(..stored(), seq: 1400))
}

/// A replay in progress is a handshake that is working, so every replayed
/// dispatch restarts the watchdog rather than letting a long backlog expire it.
pub fn replayed_dispatches_rearm_the_watchdog_test() {
  let shard = resuming()
  let Step(shard: after, outputs:) =
    frame(shard, dispatch_at(1400, "MESSAGE_CREATE"))

  assert armed(outputs, gateway.Handshake) == [handshake_ms]
  assert dispatched(outputs) == [#("MESSAGE_CREATE", 1400)]
  assert gateway.session(after) == Some(Session(..stored(), seq: 1400))
}

/// The frontier only ever moves forward, and an event whose name we do not know
/// still advances it and still reaches the host.
pub fn the_sequence_frontier_only_rises_test() {
  let shard = live()
  let shard = frame(shard, dispatch_at(57, "SOME_FUTURE_EVENT")).shard
  assert gateway.session(shard) == Some(Session("sess", resume_host(), 57))

  let Step(shard: after, outputs:) =
    frame(shard, dispatch_at(12, "MESSAGE_CREATE"))
  assert dispatched(outputs) == [#("MESSAGE_CREATE", 12)]
  assert gateway.session(after) == Some(Session("sess", resume_host(), 57))
}

/// A control frame carries no sequence and must never move the frontier.
pub fn control_frames_never_touch_the_sequence_test() {
  let shard = live()
  let shard = frame(shard, dispatch_at(10, "MESSAGE_CREATE")).shard
  let shard = drive(shard, [])
  let shard =
    list.fold([ack(), hello(), beat_request()], shard, fn(shard, text) {
      frame(shard, text).shard
    })
  assert gateway.session(shard) == Some(Session("sess", resume_host(), 10))
}

/// Every socket-derived input carries the connection it came from, and one
/// comparison at the top of `step` kills all of them at once.
pub fn inputs_from_an_abandoned_connection_are_dropped_test() {
  let shard = live()
  let stale = Conn(99)
  let inputs = [
    gateway.Opened(stale),
    OpenFailed(stale, gateway.Unreachable("boom")),
    gateway.Frame(stale, ready_at(1)),
    gateway.Bytes(stale, <<1, 2>>),
    Inflated(stale, Stamp(1), Ok("{\"op\":11}")),
    gateway.Closed(stale, Some(4000)),
  ]
  list.each(inputs, fn(input) {
    let Step(shard: after, outputs:) = gateway.step(shard, input)
    assert outputs == [Note(gateway.Ignored(gateway.StaleConn(stale)))]
    assert after == shard
  })
}

/// A grant for a connection we have given up on is handed back rather than
/// dropped, so the bucket frees a few seconds sooner.
pub fn a_grant_for_an_abandoned_connection_is_released_test() {
  let shard = live()
  let Step(shard: after, outputs:) =
    gateway.step(shard, gateway.IdentifySlotGranted(Conn(99)))
  assert outputs
    == [
      ReleaseIdentifySlot(Conn(99)),
      Note(gateway.Ignored(gateway.StaleConn(Conn(99)))),
    ]
  assert after == shard
}

/// Cancelling a timer cannot recall a message already delivered, so the
/// cancellation retires the stamp and the late fire is recognised.
pub fn a_superseded_timer_firing_is_dropped_test() {
  let shard = greeting()
  let watchdog = stamp_of(shard, gateway.Handshake)
  // HELLO cancels the watchdog for the identify-slot wait.
  let shard = frame(shard, hello()).shard

  let Step(shard: after, outputs:) =
    gateway.step(shard, Fired(gateway.Handshake, watchdog))
  assert outputs
    == [Note(gateway.Ignored(gateway.StaleTimer(gateway.Handshake)))]
  assert after == shard
}

/// The echo of our own close frame must not reconnect a second time, double the
/// backoff, or report a second disconnect.
pub fn the_echo_of_our_own_close_is_not_a_new_failure_test() {
  let shard = live()
  let old = gateway.conn(shard)
  let torn = frame(shard, server_reconnect())
  assert closes(torn.outputs) == [4000]
  assert list.length(reconnects(torn.outputs)) == 1

  let Step(shard: after, outputs:) =
    gateway.step(torn.shard, gateway.Closed(old, Some(4000)))
  assert outputs == [Note(gateway.Ignored(gateway.StaleConn(old)))]
  assert after == torn.shard
}

/// The ordering that wedges a shard permanently: a RESUMED from the socket we
/// already abandoned, cancelling the reconnect that was already armed.
pub fn a_late_resumed_cannot_cancel_the_reconnect_test() {
  let shard = live()
  let old = gateway.conn(shard)
  let torn = frame(shard, server_reconnect()).shard

  let Step(shard: after, outputs:) =
    gateway.step(
      torn,
      gateway.Frame(old, "{\"op\":0,\"s\":9,\"t\":\"RESUMED\",\"d\":{}}"),
    )
  assert outputs == [Note(gateway.Ignored(gateway.StaleConn(old)))]
  assert phase(after) == phase(torn)
}

/// Two detectors reporting one death, in every order they can arrive in.
pub fn one_death_produces_exactly_one_reconnect_test() {
  let shard = fire(live(), gateway.Heartbeat).shard
  let old = gateway.conn(shard)
  let queued = [
    Fired(gateway.Heartbeat, stamp_of(shard, gateway.Heartbeat)),
    gateway.Closed(old, Some(1006)),
    gateway.Frame(old, ack()),
  ]

  list.each(list.permutations(queued), fn(order) {
    let #(final, seen) =
      list.fold(order, #(shard, []), fn(state, input) {
        let #(shard, seen) = state
        let Step(shard:, outputs:) = gateway.step(shard, input)
        #(shard, list.append(seen, outputs))
      })
    assert list.length(reconnects(seen)) == 1
    assert list.length(closes(seen)) <= 1
    assert attempts(final) == 1
  })
}

pub fn a_terminal_shard_absorbs_everything_test() {
  let dead = drive(live(), [gateway.Closed(Conn(5), Some(4014))])
  assert phase(dead) == Dead(close.DisallowedIntents)

  let stopped = drive(live(), [Stop])
  assert phase(stopped) == Stopped

  let inputs = [
    Start,
    Stop,
    gateway.Opened(Conn(5)),
    gateway.Frame(Conn(5), ready_at(1)),
    Fired(gateway.Heartbeat, Stamp(1)),
    Command(command.UpdatePresence(presence.new(presence.Online))),
  ]
  list.each([dead, stopped], fn(shard) {
    list.each(inputs, fn(input) {
      let Step(shard: after, outputs:) = gateway.step(shard, input)
      assert outputs == [Note(gateway.Ignored(gateway.Terminal))]
      assert after == shard
    })
  })
}

/// The beat before the first tick is vacuously acknowledged, so a fresh
/// connection can never be called a zombie on its first tick.
pub fn the_first_tick_of_a_connection_always_sends_test() {
  let shard = live()
  let Step(shard: after, outputs:) = fire(shard, gateway.Heartbeat)
  assert outputs
    == [
      Send(gateway_frame.heartbeat(Some(1))),
      ArmTimer(gateway.Heartbeat, interval, Stamp(13)),
    ]
  assert phase(after)
    == Live(
      Beat(interval_ms: interval, unacked: 1, quiet: True),
      Session("sess", resume_host(), 1),
      Budget(0, 110),
    )
}

/// Only the first beat is jittered. A test whose generator would be observable
/// proves the subsequent re-arm consumed no randomness.
pub fn later_beats_use_the_raw_interval_test() {
  let shard = pinned(live(), 999_999_999)
  let first = fire(shard, gateway.Heartbeat)
  assert armed(first.outputs, gateway.Heartbeat) == [interval]

  let acked = frame(first.shard, ack()).shard
  let second = fire(acked, gateway.Heartbeat)
  assert armed(second.outputs, gateway.Heartbeat) == [interval]
  assert shard_rng(second.shard) == shard_rng(shard)
}

/// A heartbeat with no acknowledgement is a zombie, and the close code is
/// anything but 1000 or 1001, because those would destroy the session.
pub fn an_unacknowledged_beat_is_a_zombie_test() {
  let shard = fire(live(), gateway.Heartbeat).shard
  let Step(shard: after, outputs:) = fire(shard, gateway.Heartbeat)

  assert plain(outputs)
    == [
      Close(close.code(close.Reconnect)),
      CancelTimer(gateway.Heartbeat),
      CancelTimer(gateway.Handshake),
      CancelTimer(gateway.Commands),
      ReleaseIdentifySlot(Conn(5)),
      ArmTimer(gateway.Reconnect, 500, Stamp(17)),
      Note(gateway.Zombie(unacked: 1, quiet: True)),
      Emit(gateway.Reconnecting(
        in_ms: 500,
        resuming: True,
        why: gateway.ZombieConnection,
      )),
    ]
  assert sends(outputs) == []
  // A non-1000 close keeps the session, so the reconnect is a RESUME.
  assert gateway.session(after) == Some(Session("sess", resume_host(), 1))
  assert phase(after) == Waiting(Resume(Session("sess", resume_host(), 1)))
}

/// Inbound traffic is not an acknowledgement, or a busy shard stops detecting
/// half-open connections.
pub fn dispatch_traffic_does_not_acknowledge_a_heartbeat_test() {
  let shard = fire(live(), gateway.Heartbeat).shard
  let shard =
    list.repeat(Nil, 40)
    |> list.index_fold(shard, fn(shard, _, index) {
      frame(shard, dispatch_at(index + 2, "MESSAGE_CREATE")).shard
    })

  let Step(shard: _, outputs:) = fire(shard, gateway.Heartbeat)
  assert closes(outputs) == [4000]
  // The traffic is reported, so an operator can tell a dead socket from a
  // gateway that is talking and not acknowledging.
  assert list.contains(outputs, Note(gateway.Zombie(unacked: 1, quiet: False)))
}

pub fn op_11_is_the_only_acknowledgement_test() {
  let shard = fire(live(), gateway.Heartbeat).shard
  let Step(shard: after, outputs:) = frame(shard, ack())
  assert outputs == []
  assert phase(after)
    == Live(
      Beat(interval_ms: interval, unacked: 0, quiet: False),
      Session("sess", resume_host(), 1),
      Budget(0, 110),
    )
}

/// A requested beat does not arm the liveness flag or move the schedule, or an
/// op 1 just before a tick declares a zombie on a live connection.
pub fn a_requested_beat_leaves_the_schedule_and_the_flag_alone_test() {
  let shard = live()
  let Step(shard: after, outputs:) = frame(shard, beat_request())
  assert outputs
    == [
      Send(gateway_frame.heartbeat(Some(1))),
    ]
  assert phase(after) == phase(frame(shard, ack()).shard)

  // And from an outstanding beat it still only sends.
  let waiting = fire(live(), gateway.Heartbeat).shard
  let Step(shard: _, outputs:) = frame(waiting, beat_request())
  assert closes(outputs) == []
  assert list.length(sends(outputs)) == 1
}

/// Discord wants a literal null until this session has seen a dispatch. A 0
/// asks for a replay from the beginning of time.
pub fn the_heartbeat_payload_is_null_until_a_dispatch_lands_test() {
  let Step(shard: _, outputs:) = fire(identifying(), gateway.Heartbeat)
  assert sends(outputs) == ["{\"op\":1,\"d\":null}"]

  // Sequence 0 is a legal sequence and must not read as absent.
  let zeroed = frame(identifying(), ready_at(0)).shard
  let Step(shard: _, outputs:) = fire(zeroed, gateway.Heartbeat)
  assert sends(outputs) == ["{\"op\":1,\"d\":0}"]
}

/// A connection that will resume beats with the stashed sequence from before
/// the disconnect, not from nothing.
pub fn a_resuming_connection_beats_with_the_stored_sequence_test() {
  let Step(shard: _, outputs:) = fire(resuming(), gateway.Heartbeat)
  assert sends(outputs) == ["{\"op\":1,\"d\":1337}"]
}

/// No phase suppresses a beat. A library that stops heartbeating while
/// resuming has no detector left for a resume that never completes.
pub fn heartbeats_run_through_the_whole_handshake_test() {
  list.each([queued(), identifying(), resuming()], fn(shard) {
    let Step(shard: _, outputs:) = fire(shard, gateway.Heartbeat)
    assert list.length(sends(outputs)) == 1
    assert closes(outputs) == []
  })
}

/// Liveness is per connection. An outstanding beat from a socket that died must
/// never kill the socket that replaced it.
pub fn liveness_resets_on_every_connection_test() {
  let shard = fire(live(), gateway.Heartbeat).shard
  let shard = drive(shard, [gateway.Closed(gateway.conn(shard), Some(1006))])
  let shard =
    drive(shard, [Fired(gateway.Reconnect, stamp_of(shard, gateway.Reconnect))])
  let shard = drive(shard, [gateway.Opened(gateway.conn(shard))])
  let shard =
    drive(shard, [gateway.Frame(gateway.conn(shard), hello_at(45_000))])

  assert phase(shard)
    == Resuming(
      Beat(interval_ms: 45_000, unacked: 0, quiet: False),
      Session("sess", resume_host(), 1),
    )
  let Step(shard: _, outputs:) = fire(shard, gateway.Heartbeat)
  assert closes(outputs) == []
}

/// One row per code, asserting the thing the code actually decides: whether the
/// session survives.
pub fn close_codes_decide_the_session_test() {
  let session = Session("sess", resume_host(), 1)
  let table = [
    #(None, Some(session)),
    #(Some(1000), Some(session)),
    #(Some(1001), Some(session)),
    #(Some(1006), Some(session)),
    #(Some(4000), Some(session)),
    #(Some(4001), Some(session)),
    #(Some(4002), Some(session)),
    #(Some(4003), None),
    #(Some(4005), None),
    #(Some(4007), None),
    #(Some(4008), Some(session)),
    #(Some(4009), None),
    #(Some(4099), Some(session)),
  ]
  list.each(table, fn(row) {
    let #(code, expected) = row
    let Step(shard: after, outputs:) =
      gateway.step(live(), gateway.Closed(Conn(5), code))
    assert gateway.session(after) == expected
    // The peer already closed, so we never write a close frame back.
    assert closes(outputs) == []
    assert list.contains(outputs, Drop)
    assert list.length(reconnects(outputs)) == 1
  })
}

pub fn a_fatal_close_stops_for_good_test() {
  let table = [
    #(4004, close.BadToken),
    #(4010, close.InvalidShard),
    #(4011, close.ShardingRequired),
    #(4012, close.InvalidApiVersion),
    #(4013, close.InvalidIntents),
    #(4014, close.DisallowedIntents),
  ]
  list.each(table, fn(row) {
    let #(code, reason) = row
    let Step(shard: after, outputs:) =
      gateway.step(live(), gateway.Closed(Conn(5), Some(code)))
    assert phase(after) == Dead(reason)
    assert gateway.session(after) == None
    // The shard tuple travels with the reason. "invalid shard" is not
    // actionable without knowing which shard was sent.
    assert list.contains(
      outputs,
      Emit(gateway.Halted(gateway.Fatal(reason, conf().sharding))),
    )
    assert reconnects(outputs) == []
    assert armed(outputs, gateway.Reconnect) == []
  })
}

/// 4008 says we flooded the command budget: the session survives, and the
/// backlog that caused it must not go straight back out.
pub fn a_command_flood_forces_the_top_rung_test() {
  let shard =
    drive(live(), [
      Command(command.UpdatePresence(presence.new(presence.Idle(None)))),
    ])
  let shard =
    with_pending(shard, [
      command.UpdatePresence(presence.new(presence.Idle(None))),
    ])

  let Step(shard: after, outputs:) =
    gateway.step(shard, gateway.Closed(Conn(5), Some(4008)))
  assert attempts(after) == 1
  assert pending(after) == []
  assert reconnects(outputs) == [32_000]
  assert gateway.session(after) == Some(Session("sess", resume_host(), 1))
}

/// The invariant: the code we send and the session's fate are one decision.
/// 1000 exists only for a host-requested stop.
pub fn the_close_code_and_the_session_are_one_decision_test() {
  let outstanding = fn() {
    let shard = zlib_live()
    with_inbound(
      shard,
      gateway.Inbound(buffer: <<>>, inflating: Some(Stamp(0)), pending: []),
    )
  }
  let cases = [
    #(live(), gateway.Frame(Conn(5), server_reconnect())),
    #(live(), gateway.Frame(Conn(5), invalid_session(True))),
    #(live(), gateway.Frame(Conn(5), invalid_session(False))),
    #(
      identifying(),
      gateway.Frame(Conn(5), "{\"op\":0,\"s\":1,\"t\":\"READY\",\"d\":{}}"),
    ),
    #(outstanding(), Inflated(Conn(5), Stamp(0), Error(desynced()))),
    #(
      fire(live(), gateway.Heartbeat).shard,
      Fired(
        gateway.Heartbeat,
        stamp_of(fire(live(), gateway.Heartbeat).shard, gateway.Heartbeat),
      ),
    ),
    #(live(), Stop),
  ]
  list.each(cases, fn(row) {
    let #(shard, input) = row
    let Step(shard: after, outputs:) = gateway.step(shard, input)
    case closes(outputs), gateway.session(after) {
      [1000], None -> Nil
      [4000], _ -> Nil
      [], _ -> panic as "a disconnecting input emitted no close"
      _, _ -> panic as "a close code leaked outside {1000, 4000}"
    }
  })
}

/// Act on op 7 at once. Waiting for Discord's own close means eating an
/// unexplained disconnect a few seconds later instead of a controlled one.
pub fn op_7_closes_and_resumes_test() {
  let Step(shard: after, outputs:) = frame(live(), server_reconnect())
  assert closes(outputs) == [4000]
  assert phase(after) == Waiting(Resume(Session("sess", resume_host(), 1)))
  assert list.contains(
    outputs,
    Emit(gateway.Reconnecting(
      in_ms: 500,
      resuming: True,
      why: gateway.ServerRequested,
    )),
  )
}

/// op 7 is legal before HELLO, and with no session in hand the reconnect is a
/// fresh identify.
pub fn op_7_before_hello_identifies_fresh_test() {
  let Step(shard: after, outputs:) = frame(greeting(), server_reconnect())
  assert closes(outputs) == [4000]
  assert phase(after) == Waiting(Identify)
}

/// An exhausted send budget must never delay a reconnect.
pub fn op_7_is_not_queued_behind_commands_test() {
  let spent =
    with_phase(
      live(),
      Live(
        Beat(interval_ms: interval, unacked: 0, quiet: False),
        Session("sess", resume_host(), 1),
        Budget(spent: 110, capacity: 110),
      ),
    )
  let shard =
    drive(spent, [
      Command(command.UpdatePresence(presence.new(presence.Idle(None)))),
    ])
  let Step(shard: _, outputs:) = frame(shard, server_reconnect())
  assert closes(outputs) == [4000]
  assert sends(outputs) == []
}

pub fn op_9_resumable_keeps_the_session_test() {
  let Step(shard: after, outputs:) = frame(live(), invalid_session(True))
  assert closes(outputs) == [4000]
  assert list.contains(outputs, Note(gateway.InvalidSession(resumable: True)))
  assert gateway.session(after) == Some(Session("sess", resume_host(), 1))
  // No RESUME on the socket we just closed: the next HELLO makes that call.
  assert sends(outputs) == []
}

/// The wait before a fresh identify is a floor on the ladder, not a parallel
/// path, so a bot invalidated over and over still backs off.
pub fn op_9_unresumable_identifies_after_the_mandated_wait_test() {
  let Step(shard: after, outputs:) = frame(live(), invalid_session(False))
  assert gateway.session(after) == None
  assert phase(after) == Waiting(Identify)
  assert reconnects(outputs) == [5000]

  // The floor only lifts the low rungs; a shard already deep in the ladder
  // keeps its own delay, drawn against the identify ceiling.
  let deep = with_attempts(live(), 15)
  let Step(shard: _, outputs:) = frame(deep, invalid_session(False))
  assert reconnects(outputs) == [300_000]
}

/// `d: true` with no session in hand is `d: false`.
pub fn op_9_resumable_without_a_session_identifies_test() {
  let Step(shard: after, outputs:) = frame(identifying(), invalid_session(True))
  assert phase(after) == Waiting(Identify)
  assert closes(outputs) == [4000]
}

/// A dial that never completes has no socket to close, so it is abandoned.
pub fn the_watchdog_covers_a_hung_dial_test() {
  let shard = drive(pinned(shard(), 0), [Start])
  let shard = fire(shard, gateway.Reconnect).shard
  let Step(shard: after, outputs:) = fire(shard, gateway.Handshake)

  assert list.contains(outputs, Drop)
  assert closes(outputs) == []
  assert phase(after) == Waiting(Identify)
  assert list.contains(
    outputs,
    Emit(gateway.Reconnecting(
      in_ms: 500,
      resuming: False,
      why: gateway.HandshakeStalled,
    )),
  )
}

/// A socket that upgraded and then said nothing is covered by the same budget.
pub fn the_watchdog_covers_a_silent_socket_test() {
  let Step(shard: after, outputs:) = fire(greeting(), gateway.Handshake)
  assert closes(outputs) == [4000]
  assert phase(after) == Waiting(Identify)
}

/// At `max_concurrency: 1` the sixteenth shard waits 75 seconds, so a 30
/// second watchdog would tear down a healthy socket.
pub fn the_watchdog_does_not_run_while_queued_test() {
  let shard = queued()
  let Step(shard: after, outputs:) = fire(shard, gateway.Handshake)
  assert outputs == [Note(gateway.Ignored(gateway.OutOfPhase))]
  assert after == shard
}

/// The watchdog expiring is not evidence the session is gone. RESUME is
/// unmetered; an IDENTIFY comes out of a budget of 1000 a day.
pub fn a_stalled_resume_keeps_the_session_test() {
  let Step(shard: after, outputs:) = fire(resuming(), gateway.Handshake)
  assert closes(outputs) == [4000]
  assert gateway.session(after) == Some(stored())
  assert phase(after) == Waiting(Resume(stored()))
}

/// A gateway node that has gone away must not hold a shard offline forever.
pub fn a_dead_resume_host_falls_back_to_the_configured_one_test() {
  let shard =
    gateway.resuming(config: conf(), seed: 1, session: stored())
    |> with_attempts(3)
    |> with_phase(Waiting(Resume(stored())))
  let Step(shard: after, outputs:) = fire(pinned(shard, 0), gateway.Reconnect)

  assert list.contains(outputs, Note(gateway.ResumeHostRejected(resume_host())))
  assert list.contains(
    outputs,
    Open(gateway.conn(after), gateway.default_host(), "/?v=10&encoding=json"),
  )
  // The session itself survives; only the node it was pinned to changes.
  assert gateway.session(after)
    == Some(Session(..stored(), resume_host: gateway.default_host()))
}

/// The ladder advances on any attempt that does not reach READY or RESUMED, and
/// resets on nothing else. An accept-then-close loop is the case that matters.
pub fn the_ladder_advances_on_every_failure_test() {
  let cycle = fn(shard: Shard) {
    let shard =
      drive(shard, [
        Fired(gateway.Reconnect, stamp_of(shard, gateway.Reconnect)),
      ])
    let shard = drive(shard, [gateway.Opened(gateway.conn(shard))])
    drive(shard, [gateway.Closed(gateway.conn(shard), Some(4000))])
  }
  let shard =
    list.fold(list.repeat(Nil, 5), drive(shard(), [Start]), fn(shard, _) {
      cycle(shard)
    })
  assert attempts(shard) == 5

  // And a healthy connection puts it back to zero.
  assert attempts(live()) == 0
}

/// A dial failure keeps the session and its host. Losing them would turn a
/// network blip into a spent identify.
pub fn a_dial_failure_keeps_the_session_test() {
  let shard =
    gateway.resuming(config: conf(), seed: 1, session: stored())
    |> pinned(0)
    |> drive([Start])
  let shard = fire(shard, gateway.Reconnect).shard
  let Step(shard: after, outputs:) =
    gateway.step(
      shard,
      OpenFailed(gateway.conn(shard), gateway.Unreachable("econnrefused")),
    )

  assert attempts(after) == 1
  assert gateway.session(after) == Some(stored())
  assert list.contains(
    outputs,
    Emit(gateway.Reconnecting(
      in_ms: 500,
      resuming: True,
      why: gateway.DialFailed(gateway.Unreachable("econnrefused")),
    )),
  )
}

/// The dial that a fresh shard makes, refused with `status`.
fn refused_dial(status: Int) -> Step {
  let shard = drive(pinned(shard(), 0), [Start])
  let shard = fire(shard, gateway.Reconnect).shard
  gateway.step(
    shard,
    OpenFailed(gateway.conn(shard), gateway.Refused(status, "refused")),
  )
}

/// The upgrade carries no token, so a 401 here is something in front of
/// Discord refusing, not a dead token. A dead token is close 4004.
pub fn a_401_upgrade_retries_test() {
  let Step(shard: after, outputs:) = refused_dial(401)

  assert phase(after) == Waiting(Identify)
  assert !gateway.is_terminal(after)
  assert reconnects(outputs) == [500]
}

/// 429 is Discord throttling the dial, not refusing it, so the shard waits the
/// way close 4008 makes it wait and comes back.
pub fn a_429_upgrade_waits_and_retries_test() {
  let Step(shard: after, outputs:) = refused_dial(429)

  assert phase(after) == Waiting(Identify)
  assert reconnects(outputs) == [conf().tuning.backoff_max_ms / 2]
  assert whys(outputs) == [gateway.DialFailed(gateway.Refused(429, "refused"))]
}

/// Any other refusal is a connection worth retrying, on the plain ladder.
pub fn another_refused_upgrade_retries_at_once_test() {
  let Step(shard: after, outputs:) = refused_dial(503)

  assert phase(after) == Waiting(Identify)
  assert reconnects(outputs) == [500]
}

/// One connection that comes up and dies before READY.
fn no_progress_cycle(shard: Shard) -> Step {
  let shard = continue_to_greeting(shard)
  gateway.step(shard, gateway.Closed(gateway.conn(shard), Some(4000)))
}

/// `cycles` of those on a shard that already has some history.
fn stalling_on(shard: Shard, cycles: Int) -> Shard {
  list.fold(list.repeat(Nil, cycles), shard, fn(shard, _) {
    no_progress_cycle(shard).shard
  })
}

fn stalling(config: gateway.Config, cycles: Int) -> Shard {
  stalling_on(drive(pinned(gateway.new(config:, seed: 1), 0), [Start]), cycles)
}

/// A shard that connects, fails before READY and reconnects would do that
/// forever at the ceiling, looking healthy the whole time. It stops instead.
pub fn a_shard_that_never_reaches_ready_halts_test() {
  let config =
    gateway.Config(
      ..conf(),
      tuning: gateway.Tuning(..conf().tuning, no_progress_limit: 4),
    )

  // One below the cap: still climbing the ladder, still armed to redial.
  let before = stalling(config, 3)
  assert attempts(before) == 3
  assert phase(before) == Waiting(Identify)
  assert !gateway.is_terminal(before)

  let Step(shard: after, outputs:) = no_progress_cycle(before)
  assert phase(after) == gateway.Exhausted(4)
  assert gateway.is_terminal(after)
  assert list.contains(outputs, Emit(gateway.Halted(gateway.NoProgress(4))))
  assert reconnects(outputs) == []
}

/// The shipped cap, driven the same way: a bot left alone does eventually
/// stop, and it is 20 attempts that does it.
pub fn the_default_no_progress_cap_halts_test() {
  assert !gateway.is_terminal(stalling(conf(), 19))
  assert phase(stalling(conf(), 20)) == gateway.Exhausted(20)
}

/// The counter resets on READY and not on connect, because connecting is what
/// a shard in this loop is already managing to do.
pub fn reaching_ready_resets_the_no_progress_counter_test() {
  let config =
    gateway.Config(
      ..conf(),
      tuning: gateway.Tuning(..conf().tuning, no_progress_limit: 4),
    )
  let shard = stalling(config, 3)

  // A connection that gets all the way to READY, then dies.
  let shard = continue_to_greeting(shard)
  let shard = drive(shard, [gateway.Frame(gateway.conn(shard), hello())])
  let shard = drive(shard, [gateway.IdentifySlotGranted(gateway.conn(shard))])
  let shard = drive(shard, [gateway.Frame(gateway.conn(shard), ready_at(1))])
  assert attempts(shard) == 0

  let shard = drive(shard, [gateway.Closed(gateway.conn(shard), Some(4000))])
  assert !gateway.is_terminal(stalling_on(shard, 2))
}

/// `erlang:send_after` raises above 2^31, so an unclamped delay crashes the
/// shard.
pub fn armed_delays_are_clamped_test() {
  let wild =
    gateway.Config(
      ..conf(),
      tuning: gateway.Tuning(
        ..conf().tuning,
        handshake_timeout_ms: 4_000_000_000,
        backoff_base_ms: 4_000_000_000,
        backoff_max_ms: 4_000_000_000,
        identify_backoff_max_ms: 4_000_000_000,
      ),
    )
  let shard = drive(gateway.new(config: wild, seed: 1), [Start])
  let dialing = fire(shard, gateway.Reconnect)
  assert armed(dialing.outputs, gateway.Handshake) == [600_000]

  // The ladder is drawn against the same ceiling, so the delay the host is
  // told is the delay the adapter waits: no clamp happens behind its back.
  let stalled = fire(dialing.shard, gateway.Handshake)
  assert armed(stalled.outputs, gateway.Reconnect)
    == reconnects(stalled.outputs)
  let assert [waited] = reconnects(stalled.outputs)
  assert waited >= 300_000
  assert waited <= 600_000
}

/// A 4008 floors the delay at half the resume ceiling, which is over the
/// arming cap once that ceiling is past twenty minutes. The floor is clamped
/// with everything else, or the host is told a wait the adapter will not take.
pub fn a_throttle_floor_over_the_cap_is_clamped_too_test() {
  let patient =
    gateway.Config(
      ..conf(),
      tuning: gateway.Tuning(..conf().tuning, backoff_max_ms: 2_000_000),
    )
  let shard =
    gateway.new(config: patient, seed: 1)
    |> pinned(0)
    |> drive([Start])
    |> continue_to_greeting
  let shard = drive(shard, [gateway.Frame(gateway.conn(shard), hello())])
  let shard = drive(shard, [gateway.IdentifySlotGranted(gateway.conn(shard))])
  let shard = drive(shard, [gateway.Frame(gateway.conn(shard), ready_at(1))])

  let Step(shard: _, outputs:) =
    gateway.step(shard, gateway.Closed(gateway.conn(shard), Some(4008)))
  assert reconnects(outputs) == [600_000]
  assert armed(outputs, gateway.Reconnect) == reconnects(outputs)
}

// Configuration

/// `index` is 0-based, so the last shard of a fleet of 16 is 15. Discord
/// answers a fleet it disagrees with by closing 4010, which cannot be undone.
pub fn a_shard_outside_its_fleet_cannot_be_built_test() {
  let assert Ok(_) = gateway.sharding(index: 0, count: 1)
  let assert Ok(_) = gateway.sharding(index: 15, count: 16)

  assert gateway.sharding(index: 16, count: 16)
    == Error(gateway_identify.IndexOutOfRange(index: 16, count: 16))
  assert gateway.sharding(index: -1, count: 16)
    == Error(gateway_identify.IndexOutOfRange(index: -1, count: 16))
  assert gateway.sharding(index: 0, count: 0)
    == Error(gateway_identify.EmptyFleet(count: 0))
}

pub fn a_fleet_reports_its_own_shape_test() {
  let assert Ok(fleet) = gateway.sharding(index: 3, count: 16)
  assert gateway.shard_index(fleet) == 3
  assert gateway.shard_count(fleet) == 16
}

/// Every tuning range `Config` documents is applied at `new`, so the machine
/// below it reads the numbers as they are rather than clamping them again.
pub fn new_normalises_the_ranges_config_documents_test() {
  let wild =
    gateway.Config(
      ..conf(),
      tuning: gateway.Tuning(
        ..conf().tuning,
        missed_ack_limit: 0,
        command_queue_max: -1,
      ),
    )
  let config = shard_config(gateway.new(config: wild, seed: 1))
  assert config.tuning.missed_ack_limit == 1
  assert config.tuning.command_queue_max == 0
}

/// Not at `new`, where a second clamp would be a second thing to keep true:
/// `large_threshold` is the only way to fill the field, and it clamps.
pub fn large_threshold_is_clamped_before_it_reaches_a_config_test() {
  let table = [#(5000, 250), #(1, 50), #(50, 50), #(250, 250)]
  list.each(table, fn(row) {
    let #(configured, expected) = row
    let config =
      gateway.Config(
        ..conf(),
        large_threshold: gateway.large_threshold(configured),
      )
    assert gateway.large_threshold_value(config.large_threshold) == expected
    let held = shard_config(gateway.new(config:, seed: 1)).large_threshold
    assert gateway.large_threshold_value(held) == expected
  })
}

/// An IDENTIFY over Discord's 4096 bytes is a config that cannot connect: the
/// next attempt builds the same frame. Halt, rather than drop it and loop.
pub fn an_identify_over_the_payload_limit_halts_test() {
  let shard = bloated()
  let conn = gateway.conn(shard)

  let Step(shard: after, outputs:) =
    gateway.step(shard, gateway.IdentifySlotGranted(conn))

  let assert gateway.Unusable(bytes) = phase(after)
  assert bytes > 4096
  assert gateway.is_terminal(after)
  assert sends(outputs) == []
  assert closes(outputs) == [1000]
  assert list.contains(outputs, ReleaseIdentifySlot(conn))
  assert list.contains(
    outputs,
    Emit(gateway.Halted(gateway.IdentifyTooLarge(bytes))),
  )

  // Terminal means terminal: nothing later is acted on.
  assert gateway.step(after, Start).outputs
    == [Note(gateway.Ignored(gateway.Terminal))]
}

fn set_status(status: presence.Status) -> Input {
  Command(command.UpdatePresence(presence.new(status)))
}

/// A command sent between RESUME and RESUMED earns close 4003, so one issued
/// during a reconnect waits rather than going out.
pub fn commands_wait_for_a_live_connection_test() {
  let shard = shard()
  let Step(shard: shard, outputs:) =
    gateway.step(shard, set_status(presence.Idle(None)))
  assert outputs == [Note(gateway.CommandQueued(depth: 1))]

  let shard = drive(shard, [Start])
  let shard = continue_to_greeting(shard)
  let shard = drive(shard, [gateway.Frame(gateway.conn(shard), hello())])
  let shard = drive(shard, [gateway.IdentifySlotGranted(gateway.conn(shard))])
  assert pending(shard)
    == [command.UpdatePresence(presence.new(presence.Idle(None)))]

  let Step(shard: after, outputs:) = frame(shard, ready_at(1))
  assert sends(outputs)
    == [
      "{\"op\":3,\"d\":{\"since\":null,\"activities\":[],\"status\":\"idle\",\"afk\":false}}",
    ]
  assert pending(after) == []
  assert armed(outputs, gateway.Commands) == [60_000]
}

/// The window is armed by the first send of a window and rolls over once,
/// draining whatever the last window could not fit.
pub fn the_command_window_rolls_over_test() {
  let small =
    gateway.Config(
      ..conf(),
      tuning: gateway.Tuning(..conf().tuning, command_limit: 2),
    )
  let shard = drive(gateway.new(config: small, seed: 1), [Start])
  let shard = continue_to_greeting(shard)
  let shard = drive(shard, [gateway.Frame(gateway.conn(shard), hello())])
  let shard = drive(shard, [gateway.IdentifySlotGranted(gateway.conn(shard))])
  let shard = drive(shard, [gateway.Frame(gateway.conn(shard), ready_at(1))])

  let first = gateway.step(shard, set_status(presence.Idle(None)))
  assert armed(first.outputs, gateway.Commands) == [60_000]
  let second = gateway.step(first.shard, set_status(presence.Online))
  assert armed(second.outputs, gateway.Commands) == []
  assert list.length(sends(second.outputs)) == 1

  let third = gateway.step(second.shard, set_status(presence.DoNotDisturb))
  assert sends(third.outputs) == []
  assert third.outputs == [Note(gateway.CommandQueued(depth: 1))]

  let rolled = fire(third.shard, gateway.Commands)
  assert list.length(sends(rolled.outputs)) == 1
  assert armed(rolled.outputs, gateway.Commands) == [60_000]
  assert pending(rolled.shard) == []

  // An empty window rolls over into no timer at all.
  let idle = fire(rolled.shard, gateway.Commands)
  assert list.contains(idle.outputs, CancelTimer(gateway.Commands))
}

/// Past the bound the oldest goes, because the newest presence is the one the
/// host meant.
pub fn a_full_command_queue_drops_the_oldest_test() {
  let tight =
    gateway.Config(
      ..conf(),
      tuning: gateway.Tuning(..conf().tuning, command_queue_max: 2),
    )
  let shard = gateway.new(config: tight, seed: 1)
  let shard =
    drive(shard, [set_status(presence.Idle(None)), set_status(presence.Online)])
  let Step(shard: after, outputs:) =
    gateway.step(shard, set_status(presence.Invisible))

  assert outputs == [Note(gateway.CommandDropped(depth: 2))]
  assert pending(after)
    == [
      command.UpdatePresence(presence.new(presence.Online)),
      command.UpdatePresence(presence.new(presence.Invisible)),
    ]
}

/// Discord answers a payload over 4096 bytes with close 4002, which reads as
/// "we sent malformed JSON" and sends the debugger the wrong way.
pub fn an_oversized_payload_is_never_written_test() {
  let huge = string.repeat("a", 5000)
  let shard = live()
  let Step(shard: after, outputs:) =
    gateway.step(
      shard,
      Command(
        command.UpdatePresence(presence.Presence(
          status: presence.Online,
          activities: [presence.Playing(huge)],
          afk: False,
        )),
      ),
    )
  assert sends(outputs) == []
  assert list.length(outputs) == 1
  case outputs {
    [Note(gateway.PayloadTooLarge(bytes))] -> {
      assert bytes > 4096
    }
    _ -> panic as "expected exactly one oversize notice"
  }
  // It cost nothing: not a permit, not a queue slot.
  assert after == shard
}

/// The window leaves room for the beats the advertised interval implies, so a
/// gateway asking for a beat every second cannot squeeze them out.
pub fn the_command_budget_reserves_heartbeat_headroom_test() {
  let shard = live()
  assert phase(shard)
    == Live(
      Beat(interval_ms: interval, unacked: 0, quiet: False),
      Session("sess", resume_host(), 1),
      Budget(spent: 0, capacity: 110),
    )

  let hasty = drive(identifying(), [])
  let hasty =
    with_phase(
      hasty,
      Identifying(Beat(interval_ms: 1000, unacked: 0, quiet: False)),
    )
  let Step(shard: after, outputs: _) = frame(hasty, ready_at(1))
  assert phase(after)
    == Live(
      Beat(interval_ms: 1000, unacked: 0, quiet: False),
      Session("sess", resume_host(), 1),
      Budget(spent: 0, capacity: 100),
    )
}

/// A JSON parse holds no state across frames, so there is nothing to
/// resynchronise: never close, and never advance the frontier.
pub fn undecodable_frames_never_close_the_connection_test() {
  let shard = live()
  let #(after, outputs) =
    list.repeat(Nil, 200)
    |> list.fold(#(shard, []), fn(state, _) {
      let #(shard, seen) = state
      let Step(shard:, outputs:) = frame(shard, "not json at all")
      #(shard, list.append(seen, outputs))
    })

  assert list.length(outputs) == 200
  assert closes(outputs) == []
  assert gateway.session(after) == Some(Session("sess", resume_host(), 1))
}

/// Discord adds opcodes between our releases. One must never kill a session.
pub fn an_unknown_opcode_is_noted_and_survived_test() {
  let Step(shard: after, outputs:) = frame(live(), "{\"op\":99,\"d\":{}}")
  assert outputs
    == [Note(gateway.UndecodableFrame(gateway.UnknownOpcode(op: 99)))]
  assert phase(after) == phase(live())
}

/// A payload whose own content contains `"op":` must not be mis-read, which is
/// what string-scanning the raw frame does.
pub fn payload_content_cannot_forge_an_opcode_test() {
  let Step(shard: _, outputs:) =
    frame(
      live(),
      "{\"op\":0,\"s\":1,\"t\":\"MESSAGE_CREATE\",\"d\":{\"content\":\"\\\"op\\\":9\"}}",
    )
  assert dispatched(outputs) == [#("MESSAGE_CREATE", 1)]
  assert closes(outputs) == []
}

fn zlib_conf() -> gateway.Config {
  gateway.Config(..conf(), compression: gateway.ZlibStream)
}

/// The failure a host reports when its inflate context is poisoned. The text
/// is the host's own, so nothing here reads it.
fn desynced() -> gateway.InflateFailure {
  gateway.ContextDesynchronised("desync")
}

fn zlib_live() -> Shard {
  let shard = drive(gateway.new(config: zlib_conf(), seed: 1), [Start])
  let shard = continue_to_greeting(shard)
  let shard = drive(shard, [gateway.Frame(gateway.conn(shard), hello())])
  let shard = drive(shard, [gateway.IdentifySlotGranted(gateway.conn(shard))])
  drive(shard, [gateway.Frame(gateway.conn(shard), ready_at(1))])
}

pub fn the_url_carries_the_negotiated_compression_test() {
  let shard = drive(gateway.new(config: zlib_conf(), seed: 1), [Start])
  let Step(shard: _, outputs:) = fire(shard, gateway.Reconnect)
  assert list.contains(
    outputs,
    Open(
      Conn(5),
      gateway.default_host(),
      "/?v=10&encoding=json&compress=zlib-stream",
    ),
  )
}

/// Chunks are held until the sync-flush suffix lands, and a partial chunk is
/// still proof the connection is alive.
pub fn chunks_buffer_until_the_terminator_test() {
  let shard = fire(zlib_live(), gateway.Heartbeat).shard
  let conn = gateway.conn(shard)

  let Step(shard: shard, outputs:) =
    gateway.step(shard, gateway.Bytes(conn, <<1, 2>>))
  assert outputs == []
  assert inbound(shard).buffer == <<1, 2>>

  let Step(shard: shard, outputs:) =
    gateway.step(shard, gateway.Bytes(conn, <<3, 0, 0, 0xFF, 0xFF>>))
  assert outputs == [Inflate(conn, Stamp(14), <<1, 2, 3, 0, 0, 0xFF, 0xFF>>)]
  assert inbound(shard)
    == gateway.Inbound(buffer: <<>>, inflating: Some(Stamp(14)), pending: [])

  // Buffering a chunk counts as liveness even though no payload completed.
  case phase(shard) {
    Live(beat, _, _) -> {
      assert beat.quiet == False
    }
    _ -> panic as "expected a live shard"
  }
}

pub fn an_inflated_payload_is_handled_as_a_frame_test() {
  let shard = zlib_live()
  let conn = gateway.conn(shard)
  let shard =
    gateway.step(shard, gateway.Bytes(conn, <<0, 0, 0xFF, 0xFF>>)).shard
  let assert Some(stamp) = inbound(shard).inflating

  let Step(shard: after, outputs:) =
    gateway.step(
      shard,
      Inflated(conn, stamp, Ok(dispatch_at(9, "MESSAGE_CREATE"))),
    )
  assert dispatched(outputs) == [#("MESSAGE_CREATE", 9)]
  assert gateway.session(after) == Some(Session("sess", resume_host(), 9))
}

/// A payload that completed during an inflate starts when the context frees,
/// or it waits for the next binary frame.
pub fn a_payload_queued_behind_an_inflate_is_started_next_test() {
  let shard = zlib_live()
  let conn = gateway.conn(shard)
  let shard =
    gateway.step(shard, gateway.Bytes(conn, <<1, 0, 0, 0xFF, 0xFF>>)).shard
  let assert Some(first) = inbound(shard).inflating

  let shard =
    gateway.step(shard, gateway.Bytes(conn, <<2, 0, 0, 0xFF, 0xFF>>)).shard
  // Queued, not buffered. In the buffer the next frame would append to it and
  // the two payloads would reach the inflater as one.
  assert inbound(shard)
    == gateway.Inbound(buffer: <<>>, inflating: Some(first), pending: [
      <<2, 0, 0, 0xFF, 0xFF>>,
    ])

  let Step(shard: after, outputs:) =
    gateway.step(
      shard,
      Inflated(conn, first, Ok(dispatch_at(5, "MESSAGE_CREATE"))),
    )
  // The next request goes out ahead of the host event, so a handler that
  // re-enters `step` has already seen every protocol effect of the batch.
  assert plain(outputs) == [Inflate(conn, Stamp(14), <<2, 0, 0, 0xFF, 0xFF>>)]
  assert dispatched(outputs) == [#("MESSAGE_CREATE", 5)]
  assert inbound(after).inflating == Some(Stamp(14))
}

/// A poisoned context cannot be recovered inside a connection, and the socket
/// stays up so nothing else notices.
pub fn an_inflate_failure_resets_the_context_and_resumes_test() {
  let shard = zlib_live()
  let conn = gateway.conn(shard)
  let shard =
    gateway.step(shard, gateway.Bytes(conn, <<0, 0, 0xFF, 0xFF>>)).shard
  let assert Some(stamp) = inbound(shard).inflating

  let Step(shard: after, outputs:) =
    gateway.step(shard, Inflated(conn, stamp, Error(desynced())))
  assert closes(outputs) == [4000]
  assert list.contains(outputs, Note(gateway.InflateFailed(desynced())))
  assert list.contains(outputs, gateway.ResetInflater(conn))
  assert gateway.session(after) == Some(Session("sess", resume_host(), 1))
  assert inbound(after)
    == gateway.Inbound(buffer: <<>>, inflating: None, pending: [])
}

/// A gateway that stops sending the terminator must not grow the buffer
/// forever.
pub fn an_overflowing_buffer_tears_the_connection_down_test() {
  let bounded =
    gateway.Config(
      ..zlib_conf(),
      tuning: gateway.Tuning(..zlib_conf().tuning, max_payload_bytes: 4),
    )
  let shard = drive(gateway.new(config: bounded, seed: 1), [Start])
  let shard = continue_to_greeting(shard)
  let shard = drive(shard, [gateway.Frame(gateway.conn(shard), hello())])

  let Step(shard: after, outputs:) =
    gateway.step(shard, gateway.Bytes(gateway.conn(shard), <<1, 2, 3, 4, 5>>))
  assert list.contains(outputs, Note(gateway.BufferOverflow(5)))
  assert closes(outputs) == [4000]
  assert inbound(after)
    == gateway.Inbound(buffer: <<>>, inflating: None, pending: [])
}

/// Dropping binary frames quietly loses every event the day compression goes
/// on, with the heartbeat still acknowledged.
pub fn a_binary_frame_without_compression_is_reported_test() {
  let shard = live()
  let Step(shard: after, outputs:) =
    gateway.step(shard, gateway.Bytes(gateway.conn(shard), <<1, 2, 3>>))
  assert outputs
    == [Note(gateway.UndecodableFrame(gateway.BinaryFrameWithoutCompression))]
  assert inbound(after).buffer == <<>>
}

/// A text frame is parsed as JSON whatever the negotiated compression is. The
/// frame type decides, not the config.
pub fn a_text_frame_under_compression_is_still_json_test() {
  let shard = zlib_live()
  let Step(shard: after, outputs:) =
    frame(shard, dispatch_at(4, "TYPING_START"))
  assert dispatched(outputs) == [#("TYPING_START", 4)]
  assert inbound(after)
    == gateway.Inbound(buffer: <<>>, inflating: None, pending: [])
}

/// Half a message left over from a dead connection is not decodable by the new
/// one, so the buffer goes when the context goes.
pub fn a_dial_clears_a_stranded_buffer_test() {
  let shard = zlib_live()
  let shard =
    gateway.step(shard, gateway.Bytes(gateway.conn(shard), <<1, 2>>)).shard
  let shard = drive(shard, [gateway.Closed(gateway.conn(shard), Some(1006))])
  assert inbound(shard).buffer == <<1, 2>>

  let Step(shard: after, outputs:) = fire(shard, gateway.Reconnect)
  assert inbound(after)
    == gateway.Inbound(buffer: <<>>, inflating: None, pending: [])
  assert list.contains(outputs, gateway.ResetInflater(gateway.conn(after)))
}

/// An answer nobody asked for. There is no request outstanding at all, which
/// is a different thing from an answer that lost a race.
pub fn an_inflate_answer_nobody_asked_for_is_dropped_test() {
  let shard = zlib_live()
  let Step(shard: after, outputs:) =
    gateway.step(shard, Inflated(gateway.conn(shard), Stamp(77), Ok(ack())))
  assert outputs == [Note(gateway.Ignored(gateway.OutOfPhase))]
  assert after == shard
}

/// A reset supersedes the inflate in flight, and the adapter's answer to it
/// arrives anyway. It belongs to a context that no longer exists.
pub fn an_inflate_answer_from_a_superseded_request_is_dropped_test() {
  let shard = zlib_live()
  let conn = gateway.conn(shard)
  let shard =
    gateway.step(shard, gateway.Bytes(conn, <<65, 0, 0, 255, 255>>)).shard
  let assert Some(outstanding) = inbound(shard).inflating

  let stale = Stamp(77)
  assert stale != outstanding
  let Step(shard: after, outputs:) =
    gateway.step(shard, Inflated(conn, stale, Ok(ack())))
  assert outputs == [Note(gateway.Ignored(gateway.StaleInflate(stale)))]
  assert after == shard

  // The one it did ask for still applies.
  let Step(shard: applied, outputs: _) =
    gateway.step(shard, Inflated(conn, outstanding, Ok(ack())))
  assert inbound(applied).inflating == None
}

/// 1000 is for a host that meant to stop, and it ends the session.
pub fn stop_closes_with_1000_and_releases_everything_test() {
  let Step(shard: after, outputs:) = gateway.step(live(), Stop)
  assert outputs
    == [
      Close(close.code(close.Terminal)),
      CancelTimer(gateway.Heartbeat),
      CancelTimer(gateway.Handshake),
      CancelTimer(gateway.Reconnect),
      CancelTimer(gateway.Commands),
      ReleaseIdentifySlot(Conn(5)),
      gateway.ResetInflater(Conn(5)),
      Emit(gateway.Halted(gateway.Requested)),
    ]
  assert phase(after) == Stopped
  assert gateway.session(after) == None
}

/// With no socket there is nothing to write a close frame into, and a dial in
/// flight is abandoned rather than closed.
pub fn stop_without_a_socket_writes_no_close_frame_test() {
  let idle = gateway.step(shard(), Stop)
  assert closes(idle.outputs) == []
  assert list.contains(idle.outputs, Drop) == False

  let dialing = drive(shard(), [Start])
  let dialing = fire(dialing, gateway.Reconnect).shard
  let stopped = gateway.step(dialing, Stop)
  assert closes(stopped.outputs) == []
  assert list.contains(stopped.outputs, Drop)
}

/// Totality. Every input in every phase returns, and an input that does not
/// apply says so instead of changing anything.
pub fn every_input_is_handled_in_every_phase_test() {
  let phases = [
    shard(),
    drive(shard(), [Start]),
    fire(drive(shard(), [Start]), gateway.Reconnect).shard,
    greeting(),
    queued(),
    identifying(),
    resuming(),
    live(),
    drive(live(), [gateway.Closed(Conn(5), Some(4004))]),
    drive(live(), [Stop]),
    unusable(),
    stalling(conf(), 20),
  ]
  list.each(phases, fn(shard) {
    let conn = gateway.conn(shard)
    let inputs = [
      Start,
      gateway.Opened(conn),
      OpenFailed(conn, gateway.Unreachable("boom")),
      gateway.Frame(conn, hello()),
      gateway.Frame(conn, ready_at(3)),
      gateway.Frame(conn, ack()),
      gateway.Frame(conn, beat_request()),
      gateway.Frame(conn, server_reconnect()),
      gateway.Frame(conn, invalid_session(True)),
      gateway.Frame(conn, invalid_session(False)),
      gateway.Frame(conn, dispatch_at(4, "MESSAGE_CREATE")),
      gateway.Frame(conn, "{"),
      gateway.Bytes(conn, <<0, 0, 0xFF, 0xFF>>),
      Inflated(conn, Stamp(0), Ok(ack())),
      Inflated(conn, Stamp(0), Error(gateway.NoInflateContext)),
      gateway.Closed(conn, None),
      gateway.Closed(conn, Some(4000)),
      Fired(gateway.Heartbeat, stamp_of(shard, gateway.Heartbeat)),
      Fired(gateway.Handshake, stamp_of(shard, gateway.Handshake)),
      Fired(gateway.Reconnect, stamp_of(shard, gateway.Reconnect)),
      Fired(gateway.Commands, stamp_of(shard, gateway.Commands)),
      gateway.IdentifySlotGranted(conn),
      set_status(presence.Online),
      Stop,
    ]
    list.each(inputs, fn(input) {
      let Step(shard: after, outputs:) = gateway.step(shard, input)
      // A step either changes something or says why it did not, and an input
      // it declined to act on changes nothing at all, generator included.
      let declined =
        outputs != []
        && list.all(outputs, fn(output) {
          case output {
            Note(gateway.Ignored(_)) -> True
            _ -> False
          }
        })
      case after == shard, outputs, declined {
        True, [], _ ->
          panic as { "silently did nothing: " <> string.inspect(input) }
        False, _, True ->
          panic as {
            "an ignored input changed the shard: " <> string.inspect(input)
          }
        _, _, _ -> Nil
      }
    })
  })
}

/// Purity: the same pair always produces the same step, and nothing about the
/// first call leaks into the second.
pub fn step_is_deterministic_test() {
  let shard = live()
  let input =
    gateway.Frame(gateway.conn(shard), dispatch_at(9, "MESSAGE_CREATE"))
  let first = gateway.step(shard, input)
  let second = gateway.step(shard, input)
  assert first.shard == second.shard
  assert plain(first.outputs) == plain(second.outputs)
  assert dispatched(first.outputs) == dispatched(second.outputs)
}

/// Two shards in one runtime are fully independent, and interleaving them does
/// not change either one's answers.
pub fn two_shards_do_not_interfere_test() {
  let inputs = [Start]
  let alone = drive(gateway.new(config: conf(), seed: 7), inputs)
  let other = drive(gateway.new(config: conf(), seed: 8), inputs)
  let interleaved =
    list.fold(inputs, gateway.new(config: conf(), seed: 7), fn(shard, input) {
      let _ = gateway.step(other, input)
      gateway.step(shard, input).shard
    })
  assert interleaved == alone
}

/// The reassembly buffer is the only `BitArray` in the state and the phase
/// carries no handles, so a shard is comparable and printable at every step.
pub fn a_shard_is_a_plain_value_test() {
  let shard = live()
  assert string.contains(string.inspect(shard), "Live")
  // The token is config, not session: what a host persists carries no secret.
  assert string.contains(string.inspect(gateway.session(shard)), "tok") == False
}

/// The framing helper and the machine agree about what a complete payload is.
pub fn the_terminator_is_the_reassembly_module_s_test() {
  assert reassembly.ends_with_sync(<<0, 0, 0xFF, 0xFF>>)
  assert reassembly.ends_with_sync(<<0, 0, 0xFF>>) == False
}

/// A READY on a connection that was resuming replaces the session wholesale
/// rather than merging into the old one.
pub fn a_ready_while_resuming_replaces_the_session_test() {
  let Step(shard: after, outputs:) = frame(resuming(), ready_at(1))
  assert gateway.session(after) == Some(Session("sess", resume_host(), 1))
  assert list.contains(outputs, Emit(gateway.Resumed)) == False
  assert dispatched(outputs) == [#("READY", 1)]
}

/// A dispatch that arrives before the handshake finished has no session to
/// advance, and Discord will not send it again, so it still reaches the host.
pub fn a_dispatch_before_the_handshake_is_not_dropped_test() {
  list.each([greeting(), queued(), identifying()], fn(shard) {
    let Step(shard: after, outputs:) =
      frame(shard, dispatch_at(3, "MESSAGE_CREATE"))
    assert dispatched(outputs) == [#("MESSAGE_CREATE", 3)]
    assert gateway.session(after) == None
  })
}

/// What a host persists is enough to resume with after a process restart.
pub fn a_persisted_session_round_trips_test() {
  let assert Some(saved) = gateway.session(live())

  let rebuilt =
    gateway.resuming(config: conf(), seed: 2, session: saved)
    |> pinned(0)
    |> drive([Start])
    |> continue_to_greeting
  let Step(shard: _, outputs:) = frame(rebuilt, hello())

  assert sends(outputs)
    == [
      "{\"op\":6,\"d\":{\"token\":\"tok\",\"session_id\":\"sess\",\"seq\":1}}",
    ]
  assert list.contains(outputs, RequestIdentifySlot(Conn(5))) == False
}

/// A command must not go out between RESUME and RESUMED. Discord answers one
/// sent there with close 4003, which destroys the session the resume was for.
pub fn commands_wait_for_resumed_not_for_resuming_test() {
  let shard = drive(resuming(), [set_status(presence.Idle(None))])
  assert pending(shard)
    == [command.UpdatePresence(presence.new(presence.Idle(None)))]

  let Step(shard: after, outputs:) =
    frame(shard, "{\"op\":0,\"s\":1400,\"t\":\"RESUMED\",\"d\":{}}")
  assert sends(outputs)
    == [
      "{\"op\":3,\"d\":{\"since\":null,\"activities\":[],\"status\":\"idle\",\"afk\":false}}",
    ]
  assert pending(after) == []
}

/// A connection that dies while waiting for a slot hands the slot back rather
/// than holding one it will never spend.
pub fn a_connection_that_dies_while_queued_releases_its_slot_test() {
  let shard = queued()
  let Step(shard: after, outputs:) =
    gateway.step(shard, gateway.Closed(gateway.conn(shard), Some(1006)))
  assert list.contains(outputs, ReleaseIdentifySlot(Conn(5)))
  assert phase(after) == Waiting(Identify)
}

/// Host events come last in every batch, so an adapter whose handler re-enters
/// `step` synchronously does so only after every protocol effect has run.
pub fn host_events_come_last_in_every_batch_test() {
  let conn = fn(shard: Shard) { gateway.conn(shard) }
  let script = [
    Start,
    Fired(gateway.Reconnect, Stamp(3)),
    gateway.Opened(Conn(5)),
    gateway.Frame(Conn(5), hello()),
    gateway.IdentifySlotGranted(Conn(5)),
    gateway.Frame(Conn(5), ready_at(1)),
    set_status(presence.Idle(None)),
    gateway.Frame(Conn(5), dispatch_at(2, "MESSAGE_CREATE")),
    gateway.Frame(Conn(5), server_reconnect()),
  ]
  let _ =
    list.fold(script, pinned(shard(), 0), fn(shard, input) {
      let Step(shard: after, outputs:) = gateway.step(shard, input)
      let #(effects, events) =
        list.split_while(outputs, fn(output) {
          case output {
            Emit(_) -> False
            _ -> True
          }
        })
      let stragglers =
        list.filter(events, fn(output) {
          case output {
            Emit(_) -> False
            _ -> True
          }
        })
      assert stragglers == []
      assert list.length(effects) + list.length(events) == list.length(outputs)
      let _ = conn(after)
      after
    })
  Nil
}

/// A resume costs only downtime; an identify comes out of a budget of 1000 a
/// day, so the identify ladder climbs higher: to the longest timer that can be
/// armed, where the resume ladder stops at its own 64 second ceiling.
pub fn the_ladder_caps_higher_on_the_identify_path_test() {
  let deep = fn(shard: Shard) {
    let Step(shard: _, outputs:) =
      gateway.step(
        with_attempts(shard, 15),
        gateway.Closed(Conn(5), Some(4000)),
      )
    reconnects(outputs)
  }
  // 4000 keeps the session, so this one resumes.
  assert deep(live()) == [32_000]
  // 4007 discards it, so the next attempt has to identify.
  let Step(shard: _, outputs:) =
    gateway.step(with_attempts(live(), 15), gateway.Closed(Conn(5), Some(4007)))
  assert reconnects(outputs) == [300_000]
}

/// Half jitter draws from `[cap / 2, cap)`, so the mean wait is `0.75 * cap`
/// and a shard in an identify loop stays under Discord's 1000 a day.
pub fn the_identify_ceiling_stays_inside_the_daily_budget_test() {
  let tuning = conf().tuning
  let day = 86_400_000
  let per_day = fn(cap: Int) { day / { cap * 3 / 4 } }

  assert per_day(tuning.identify_backoff_max_ms) <= 1000
  // No timer is armed for longer than ten minutes, so that, and not the
  // configured ceiling, is what an identify loop actually spends.
  assert per_day(600_000) <= 1000
  // The resume ceiling would not survive the same loop, which is why it is
  // not used on this path.
  assert per_day(tuning.backoff_max_ms) > 1000
}

/// Parking a finished payload in the chunk buffer makes the next frame append
/// to it, and the inflater gets two JSON documents glued together.
pub fn payloads_queued_behind_an_inflate_stay_separate_test() {
  let shard = fire(zlib_live(), gateway.Heartbeat).shard
  let conn = gateway.conn(shard)

  // First payload goes straight to the inflater.
  let Step(shard: shard, outputs:) =
    gateway.step(shard, gateway.Bytes(conn, <<65, 0, 0, 255, 255>>))
  assert list.any(outputs, fn(output) {
    case output {
      gateway.Inflate(_, _, bytes) -> bytes == <<65, 0, 0, 255, 255>>
      _ -> False
    }
  })

  // Second and third arrive before the reply. Neither may be merged into the
  // other.
  let Step(shard: shard, outputs: _) =
    gateway.step(shard, gateway.Bytes(conn, <<66, 0, 0, 255, 255>>))
  let Step(shard: shard, outputs: _) =
    gateway.step(shard, gateway.Bytes(conn, <<67, 0, 0, 255, 255>>))

  // The reply releases the queue one payload at a time, in arrival order.
  let Step(shard: shard, outputs:) =
    gateway.step(shard, gateway.Inflated(conn, inflate_stamp(shard), Ok("{}")))
  assert list.any(outputs, fn(output) {
    case output {
      gateway.Inflate(_, _, bytes) -> bytes == <<66, 0, 0, 255, 255>>
      _ -> False
    }
  })

  let Step(shard: _, outputs:) =
    gateway.step(shard, gateway.Inflated(conn, inflate_stamp(shard), Ok("{}")))
  assert list.any(outputs, fn(output) {
    case output {
      gateway.Inflate(_, _, bytes) -> bytes == <<67, 0, 0, 255, 255>>
      _ -> False
    }
  })
}

/// Releasing a queued payload must not take the buffer with it. The bytes in
/// there arrived after the queued one and belong to the payload still coming.
pub fn a_partial_survives_the_queued_payload_starting_test() {
  let shard = fire(zlib_live(), gateway.Heartbeat).shard
  let conn = gateway.conn(shard)

  // The first payload occupies the inflate context.
  let shard =
    gateway.step(shard, gateway.Bytes(conn, <<65, 0, 0, 255, 255>>)).shard
  let assert Some(stamp) = inbound(shard).inflating

  // The second completes behind it and queues. The third is the head of a
  // payload that has not finished arriving.
  let shard =
    gateway.step(shard, gateway.Bytes(conn, <<66, 0, 0, 255, 255>>)).shard
  let shard = gateway.step(shard, gateway.Bytes(conn, <<67, 68>>)).shard
  assert inbound(shard).buffer == <<67, 68>>

  // The reply starts the queued payload, which is not what the buffer holds.
  let Step(shard: shard, outputs:) =
    gateway.step(shard, Inflated(conn, stamp, Ok("{}")))
  assert list.any(outputs, fn(output) {
    case output {
      gateway.Inflate(_, _, bytes) -> bytes == <<66, 0, 0, 255, 255>>
      _ -> False
    }
  })
  assert inbound(shard).buffer == <<67, 68>>

  // The rest of the third arrives, and the payload is whole.
  let shard =
    gateway.step(shard, gateway.Bytes(conn, <<69, 0, 0, 255, 255>>)).shard
  assert inbound(shard).pending == [<<67, 68, 69, 0, 0, 255, 255>>]

  let assert Some(stamp) = inbound(shard).inflating
  let Step(shard: _, outputs:) =
    gateway.step(shard, Inflated(conn, stamp, Ok("{}")))
  assert list.any(outputs, fn(output) {
    case output {
      gateway.Inflate(_, _, bytes) -> bytes == <<67, 68, 69, 0, 0, 255, 255>>
      _ -> False
    }
  })
}

fn inflate_stamp(shard: Shard) -> gateway.Stamp {
  case inbound(shard).inflating {
    option.Some(stamp) -> stamp
    option.None -> gateway.Stamp(0)
  }
}

/// `00 00 FF FF` is also an empty stored deflate block, so those bytes occur
/// inside compressed data and a split terminator must not flush.
pub fn a_terminator_split_across_frames_does_not_flush_test() {
  let shard = zlib_live()
  let conn = gateway.conn(shard)

  // A real payload goes to the inflater and occupies the context.
  let shard =
    gateway.step(shard, gateway.Bytes(conn, <<9, 0, 0, 0xFF, 0xFF>>)).shard
  let assert Some(stamp) = inbound(shard).inflating

  // Then two frames whose join ends in the terminator, neither of which does.
  // The second is two bytes, too short to carry the four on its own.
  let shard = gateway.step(shard, gateway.Bytes(conn, <<1, 0, 0>>)).shard
  let shard = gateway.step(shard, gateway.Bytes(conn, <<0xFF, 0xFF>>)).shard
  assert inbound(shard).pending == []
  // The bytes held now end with the terminator even though no frame did.
  assert reassembly.ends_with_sync(inbound(shard).buffer)

  // Freeing the context must not hand that buffer over.
  let Step(shard: after, outputs:) =
    gateway.step(shard, Inflated(conn, stamp, Ok(ack())))

  assert inbound(after).inflating == None
  assert list.filter(outputs, is_inflate) == []
  assert inbound(after).buffer == <<1, 0, 0, 0xFF, 0xFF>>
}

fn is_inflate(output: gateway.Output) -> Bool {
  case output {
    gateway.Inflate(_, _, _) -> True
    _ -> False
  }
}
