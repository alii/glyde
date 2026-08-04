//// The conformance suite an adapter has to pass before anyone should trust it.
////
//// A `Scenario` scripts what the socket and the clock do, and the expectation
//// is the exact list of acts the adapter should have produced, in order.
////
//// ```gleam
//// import glyde/testing/adapter
////
//// let failures =
////   adapter.run_all(my_adapter)
////   |> list.filter(adapter.failed)
////
//// list.each(failures, fn(report) { io.println(adapter.describe(report)) })
//// ```
////
//// ## What an adapter has to provide
////
//// Three functions, in an `Adapter`: build a bot from a `Setup`, feed it one
//// `Input`, and hand back the `World` its transport wrote into.
////
//// The scripted world never opens anything. `Setup.transport` is already wired
//// to record, and an adapter under test passes it through untouched.
////
//// ## Why the expectations are opcodes and not payloads
////
//// IDENTIFY carries the bot token, and a suite whose expected values contain a
//// token is a suite nobody can paste into an issue.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import glyde/client
import glyde/gateway.{
  type Conn, type Deadline, type Event, type Input, type Shard, type Stamp,
  type Timer,
}
import glyde/gateway/command.{type Command}
import glyde/gateway/frame
import glyde/gateway/presence
import glyde/intents
import glyde/testing
import glyde/testing/frames

/// The seed every scenario runs with. The expected `Armed` values below are
/// jittered from it, so an adapter does not get to choose.
pub const seed: Int = 7

/// The config every scenario runs against. Defaults throughout, so a delay in
/// an expectation traces back to `gateway.config`.
pub fn config() -> gateway.Config {
  gateway.config(
    token: frames.token,
    intents: intents.new([intents.Guilds, intents.GuildMessages]),
  )
}

/// One thing the adapter was asked to do. Coarser than `gateway.Output`: what
/// has to match between adapters is the sequence and the numbers, not bytes.
pub type Act {
  /// A socket was opened to `wss://<host><path>`.
  Dialled(host: String, path: String)
  /// A text frame went out, named by the opcode it was built with. The body
  /// is never recorded: only IDENTIFY's would be worth reading, and it holds
  /// the token.
  Wrote(op: Sent)
  /// A close frame with this code, socket still to report back.
  Shut(code: Int)
  /// The socket was abandoned with no close frame.
  Dropped
  Armed(timer: Timer, in_ms: Int)
  Disarmed(timer: Timer)
  /// A dispatch, or an event with nothing worth carrying, reached the host.
  Emitted(event: String)
  /// Its own act because the delay is the interesting part of it.
  Reconnecting(in_ms: Int, resuming: Bool)
  /// Its own act because "the host asked to stop" and "Discord refused with
  /// 4004 and no reconnect is coming" are different endings.
  Halted(reason: gateway.Halt)
}

/// The opcode of a frame the adapter sent. Named rather than numbered, and
/// prefixed so the constructors do not collide with `gateway.Heartbeat`.
pub type Sent {
  /// Op 1.
  SentHeartbeat
  /// Op 2.
  SentIdentify
  /// Op 3.
  SentPresence
  /// Op 6.
  SentResume
  /// An opcode no scenario expects by name, op 4 and op 8 among them.
  SentOther(op: Int)
}

fn sent(op: frame.Opcode) -> Sent {
  case op {
    frame.OpHeartbeat -> SentHeartbeat
    frame.OpIdentify -> SentIdentify
    frame.OpPresenceUpdate -> SentPresence
    frame.OpResume -> SentResume
    other -> SentOther(op: frame.opcode_to_int(other))
  }
}

/// What the scripted socket and clock have seen the adapter do. The adapter
/// threads it as its own state, where a real transport writes to a socket.
pub type World {
  World(
    /// Newest first while running. `acts` reverses it.
    log: List(Act),
    /// The connection the adapter was handed by the last `open`.
    socket: Option(Conn),
    /// The connection whose close the adapter asked for and which has not
    /// reported back yet. `ShutConfirmed` is the report.
    closing: Option(#(Conn, Int)),
    /// Every timer the adapter has armed and not yet fired.
    pending: List(Arming),
  )
}

/// One `ArmTimer` as the scripted world sees it. A delay and not an instant:
/// the world has no clock, and `Waits` is what turns one into the other.
pub type Arming {
  Arming(timer: Timer, in_ms: Int, stamp: Stamp)
}

/// An empty world: nothing dialled, nothing armed, nothing recorded.
pub fn blank() -> World {
  World(log: [], socket: None, closing: None, pending: [])
}

/// Everything the adapter did, oldest first.
pub fn acts(world: World) -> List(Act) {
  list.reverse(world.log)
}

/// Record that an event reached the host: the one part of the trace a transport
/// cannot see. `over_client` shows the one line it takes.
pub fn saw(world: World, event: Event) -> World {
  case event {
    gateway.Reconnecting(in_ms:, resuming:, why: _) ->
      did(world, Reconnecting(in_ms:, resuming:))
    gateway.Halted(reason:) -> did(world, Halted(reason:))
    _ -> did(world, Emitted(event_name(event)))
  }
}

/// The name an `Emitted` act carries. A dispatch is named by its Discord
/// event name, so a scenario's expectation reads `Emitted("MESSAGE_CREATE")`.
/// `Reconnecting` and `Halted` never reach it: they have acts of their own,
/// because what they carry is the point of them.
pub fn event_name(event: Event) -> String {
  case event {
    gateway.Ready(..) -> "Ready"
    gateway.Resumed -> "Resumed"
    gateway.Dispatch(name:, seq: _, data: _) -> name
    gateway.Reconnecting(..) -> "Reconnecting"
    gateway.Halted(..) -> "Halted"
  }
}

/// The transport a scenario runs the adapter against. Opens nothing, writes
/// nothing, waits for nothing.
pub fn recorder() -> client.Transport(World) {
  client.Transport(
    open: fn(world, conn, host, path) {
      World(..did(world, Dialled(host:, path:)), socket: Some(conn))
    },
    // The opcode only: the body of an IDENTIFY carries the token.
    send: fn(world, payload: frame.Outbound) {
      did(world, Wrote(sent(payload.op)))
    },
    // The socket stays open: a runtime reports a close it asked for the same
    // way it reports one the peer sent.
    close: fn(world, code) {
      let closing = option.map(world.socket, fn(conn) { #(conn, code) })
      World(..did(world, Shut(code)), closing:)
    },
    drop: fn(world) {
      World(..did(world, Dropped), socket: None, closing: None)
    },
    arm: fn(world, timer, in_ms, stamp) {
      World(..did(world, Armed(timer:, in_ms:)), pending: [
        Arming(timer:, in_ms:, stamp:),
        ..drop_timer(world.pending, timer)
      ])
    },
    cancel: fn(world, timer) {
      World(
        ..did(world, Disarmed(timer)),
        pending: drop_timer(world.pending, timer),
      )
    },
  )
}

/// A recorder for an adapter whose transport threads more than the world. Say
/// how to read the world out of the carrier and how to put it back.
///
/// ```gleam
/// adapter.recorder_in(
///   read: fn(app: App) { app.user },
///   write: fn(app, world) { App(..app, user: world) },
/// )
/// ```
pub fn recorder_in(
  read read: fn(carrier) -> World,
  write write: fn(carrier, World) -> carrier,
) -> client.Transport(carrier) {
  let inner = recorder()
  let over = fn(carrier, step) { write(carrier, step(read(carrier))) }
  client.Transport(
    open: fn(carrier, conn, host, path) {
      over(carrier, inner.open(_, conn, host, path))
    },
    send: fn(carrier, text) { over(carrier, inner.send(_, text)) },
    close: fn(carrier, code) { over(carrier, inner.close(_, code)) },
    drop: fn(carrier) { over(carrier, inner.drop) },
    arm: fn(carrier, timer, in_ms, stamp) {
      over(carrier, inner.arm(_, timer, in_ms, stamp))
    },
    cancel: fn(carrier, timer) { over(carrier, inner.cancel(_, timer)) },
  )
}

fn did(world: World, act: Act) -> World {
  World(..world, log: [act, ..world.log])
}

fn drop_timer(pending: List(Arming), timer: Timer) -> List(Arming) {
  list.filter(pending, fn(arming) { arming.timer != timer })
}

/// One thing the world does to the adapter. Every scenario begins started, and
/// a beat naming a socket means the one the adapter last opened.
pub type Beat {
  /// The socket finished its upgrade.
  Connects
  /// The socket never came up. `gateway.Refused` carries a status the shard
  /// reads; `gateway.Unreachable` is a dial that never got an answer.
  Refuses(failure: gateway.DialFailure)
  /// A text frame arrived. `glyde/testing/frames` builds them.
  Delivers(payload: String)
  /// The peer closed. `None` is a transport that died with no close frame.
  PeerShuts(code: Option(Int))
  /// The close the adapter asked for, reported back on the socket that was
  /// closed. Answering with the wrong connection disables the staleness guard.
  ShutConfirmed
  /// Time passes. Every timer due inside the window fires, soonest first, at
  /// the instant it was due.
  Waits(ms: Int)
  /// A firing that lost the race with its own cancellation: the right timer,
  /// a stamp from an older arming. It must change nothing.
  StaleFire(timer: Timer)
  /// The host asks to send a gateway command from outside a handler.
  HostSends(command: Command)
  /// The host asks the bot to shut down.
  HostStops
}

/// A command the host asks for from inside its event handler, the moment the
/// triggering event is delivered.
///
/// Queued, its `Wrote` lands after the batch; run inline, inside it.
pub type Reentry {
  Reentry(on: Trigger, send: Command)
}

/// Which event a `Reentry` waits for. A constructor and not a name, so a hook
/// cannot quietly never fire because the scenario wrote "READY" where the core
/// says `Ready`.
pub type Trigger {
  OnReady
  OnResumed
  /// By the Discord event name `gateway.Dispatch` carries.
  OnDispatch(name: String)
  OnReconnecting
  OnHalted
}

/// Whether this event is the one the trigger waits for. An adapter that builds
/// its own bot matches its re-entrancy hook with this, as `over_client` does.
pub fn triggered(trigger: Trigger, event: Event) -> Bool {
  case trigger, event {
    OnReady, gateway.Ready(..) -> True
    OnResumed, gateway.Resumed -> True
    OnDispatch(name:), gateway.Dispatch(name: arrived, ..) -> name == arrived
    OnReconnecting, gateway.Reconnecting(..) -> True
    OnHalted, gateway.Halted(..) -> True
    _, _ -> False
  }
}

/// A script, and what the adapter should have done by the end of it.
pub type Scenario {
  Scenario(
    name: String,
    /// What breaks if this one fails, in one sentence. Printed by `describe`.
    why: String,
    beats: List(Beat),
    /// Every act, in order, including the ones the implicit start produces.
    expect: List(Act),
    reentrant: Option(Reentry),
  )
}

/// Everything an adapter needs to build the bot under test.
pub type Setup {
  Setup(
    shard: Shard,
    world: World,
    transport: client.Transport(World),
    reentrant: Option(Reentry),
  )
}

/// The adapter under test, as the three things the harness needs of it. A loop
/// that cannot take a given transport one input at a time cannot be tested.
pub type Adapter(bot) {
  Adapter(
    /// Build a bot on this shard, wired to this transport. Do not start it:
    /// the harness feeds `gateway.Start` so its acts are part of the trace.
    start: fn(Setup) -> bot,
    /// Deliver one input and perform everything it produces.
    feed: fn(bot, Input) -> bot,
    /// The state the transport has been writing into.
    world: fn(bot) -> World,
  )
}

/// The `Adapter` for a bot driven by `glyde/client`, and the shape to copy.
pub fn over_client() -> Adapter(client.Bot(World)) {
  Adapter(
    start: fn(setup: Setup) {
      client.from_shard(
        shard: setup.shard,
        state: setup.world,
        transport: setup.transport,
      )
      |> client.on_event(fn(world, event) {
        let next = client.keep(saw(world, event))
        case setup.reentrant {
          Some(Reentry(on:, send:)) ->
            case triggered(on, event) {
              True -> client.sending(next, send)
              False -> next
            }
          None -> next
        }
      })
    },
    feed: client.feed,
    world: client.state,
  )
}

/// The session a resuming scenario is handed by its scripted READY.
const session_id: String = "sc3n4r10"

const resume_host: String = "gateway-us-east1-b.discord.gg"

/// Discord's real interval is around 41250ms and varies per connection. A
/// round number here keeps the arithmetic in the expectations readable.
const interval_ms: Int = 45_000

const gateway_host: String = "gateway.discord.gg"

/// The version, the encoding and nothing else: the config asks for no
/// compression, so `Open` carries no `&compress=`.
const gateway_path: String = "/?v=10&encoding=json"

/// Every scenario, in the order `run_all` runs them.
pub fn scenarios() -> List(Scenario) {
  [
    self_close_echo(),
    reentrant_handler(),
    lost_arm_timer(),
    stale_fire(),
    peer_close_resumes(),
  ]
}

/// What `Start` and the first dial always produce: the timer table cleared,
/// the dial armed at zero, then the handshake watchdog.
fn through_dial() -> List(Act) {
  [
    Disarmed(gateway.Heartbeat),
    Disarmed(gateway.Handshake),
    Disarmed(gateway.Commands),
    Armed(gateway.Reconnect, 0),
    Dialled(host: gateway_host, path: gateway_path),
    Armed(gateway.Handshake, 30_000),
  ]
}

/// Through HELLO, IDENTIFY and READY on the first connection.
fn through_ready() -> List(Act) {
  list.append(through_dial(), [
    Disarmed(gateway.Handshake),
    // The first beat is jittered, so reproducing this number means the adapter
    // threaded the shard's own generator.
    Armed(gateway.Heartbeat, 9614),
    Wrote(SentIdentify),
    // Re-armed once IDENTIFY is out, so a long wait for an identify slot does
    // not eat the budget for READY.
    Armed(gateway.Handshake, 30_000),
    Disarmed(gateway.Handshake),
    Disarmed(gateway.Reconnect),
    Disarmed(gateway.Commands),
    Emitted("Ready"),
    // READY reaches the host twice: once projected to the four fields the
    // protocol needs, once whole.
    Emitted("READY"),
  ])
}

/// 1. The shard closed the socket itself. The runtime says so. The shard must
/// accept its own close and reconnect exactly once.
fn self_close_echo() -> Scenario {
  Scenario(
    name: "self-close echo",
    why: "an adapter that answers its own close with the connection the shard "
      <> "has moved on to, rather than the one the socket was opened with, "
      <> "kills the reconnect it just started and every flap then costs two",
    beats: [
      Waits(0),
      Connects,
      Delivers(frames.hello(interval_ms)),
      Delivers(frames.ready(1, session_id, resume_host)),
      // Two heartbeats and no ack between them: the second finds the
      // connection a zombie and closes it with 4000, which keeps the session.
      Waits(10_000),
      Waits(45_000),
      // The ladder's first rung, so a new socket is in flight.
      Waits(1000),
      // The close is reported only now, when a made-up connection would match
      // the socket that is currently connecting.
      ShutConfirmed,
      Waits(1000),
    ],
    // The echo landed on a finished connection and produced nothing. An adapter
    // answering with the live one would have torn the second dial down.
    expect: list.append(through_ready(), [
      Wrote(SentHeartbeat),
      Armed(gateway.Heartbeat, 45_000),
      // No ack came back, so the second deadline finds a zombie. 4000 keeps
      // the session, unlike 1000.
      Shut(4000),
      Disarmed(gateway.Heartbeat),
      Disarmed(gateway.Handshake),
      Disarmed(gateway.Commands),
      Armed(gateway.Reconnect, 577),
      Reconnecting(in_ms: 577, resuming: True),
      // The session survived, so the next dial goes to the resume host READY
      // named rather than back to the front door.
      Dialled(host: resume_host, path: gateway_path),
      Armed(gateway.Handshake, 30_000),
    ]),
    reentrant: None,
  )
}

/// 2. A handler that asks to send a command from inside the batch that
/// delivered the event to it.
fn reentrant_handler() -> Scenario {
  Scenario(
    name: "handler re-enters",
    why: "a command sent from inside a handler must go out after the batch "
      <> "that carried the event, not halfway through it against a shard "
      <> "that has already moved on",
    beats: [
      Waits(0),
      Connects,
      Delivers(frames.hello(interval_ms)),
      Delivers(frames.ready(1, session_id, resume_host)),
    ],
    expect: list.append(through_ready(), [
      // Op 3, and it lands after both READY acts rather than between them.
      Wrote(SentPresence),
      Armed(gateway.Commands, 60_000),
    ]),
    reentrant: Some(Reentry(
      on: OnReady,
      send: command.UpdatePresence(presence.new(presence.Online)),
    )),
  )
}

/// 3. The dial happens when a zero-delay `Reconnect` fires, and only then.
fn lost_arm_timer() -> Scenario {
  Scenario(
    name: "lost ArmTimer",
    why: "the first dial is armed at 0ms, so an adapter whose timer wrapper "
      <> "treats a zero delay as nothing to do never connects at all",
    beats: [Waits(0)],
    expect: through_dial(),
    reentrant: None,
  )
}

/// 4. A firing that lost the race with its own cancellation.
fn stale_fire() -> Scenario {
  Scenario(
    name: "stale fire",
    why: "an adapter that invents a stamp instead of echoing the one it was "
      <> "armed with turns every late firing into a real one",
    beats: [
      Waits(0),
      Connects,
      Delivers(frames.hello(interval_ms)),
      Delivers(frames.ready(1, session_id, resume_host)),
      StaleFire(gateway.Heartbeat),
      StaleFire(gateway.Handshake),
    ],
    // Both firings changed nothing, so the trace stops at READY.
    expect: through_ready(),
    reentrant: None,
  )
}

/// 5. The peer closed with a resumable code, so the next connection resumes
/// rather than spending an identify.
fn peer_close_resumes() -> Scenario {
  Scenario(
    name: "peer close resumes",
    why: "a session that survives the socket must come back as op 6, because "
      <> "Discord allows 1000 identifies a day and resumes are unmetered",
    beats: [
      Waits(0),
      Connects,
      Delivers(frames.hello(interval_ms)),
      Delivers(frames.ready(1, session_id, resume_host)),
      PeerShuts(Some(4000)),
      Waits(2000),
      Connects,
      Delivers(frames.hello(interval_ms)),
      Delivers(frames.resumed(2)),
    ],
    expect: list.append(through_ready(), [
      // The peer had already closed, so there is nothing to write a close
      // frame into.
      Dropped,
      Disarmed(gateway.Heartbeat),
      Disarmed(gateway.Handshake),
      Disarmed(gateway.Commands),
      Armed(gateway.Reconnect, 577),
      Reconnecting(in_ms: 577, resuming: True),
      Dialled(host: resume_host, path: gateway_path),
      Armed(gateway.Handshake, 30_000),
      // Op 6, not op 2.
      Wrote(SentResume),
      Armed(gateway.Heartbeat, 16_405),
      Armed(gateway.Handshake, 30_000),
      Disarmed(gateway.Handshake),
      Disarmed(gateway.Reconnect),
      Disarmed(gateway.Commands),
      Emitted("Resumed"),
      Emitted("RESUMED"),
    ]),
    reentrant: None,
  )
}

/// How a scenario went.
pub type Report {
  Report(name: String, why: String, verdict: Verdict)
}

pub type Verdict {
  Passed
  /// The traces agree up to `at` and disagree there. `expected` and `got` are
  /// `None` when one trace ran out.
  Diverged(
    at: Int,
    expected: Option(Act),
    got: Option(Act),
    trace: List(Act),
    wanted: List(Act),
  )
  /// A wait fired `testing.max_firings` timers and time had not reached the end
  /// of the beat. The run stopped there, so the trace is the one the spin left.
  Stalled(trace: List(Act))
  /// Beat `at` asked for something the world could not do: a socket that was
  /// never opened, or a close nobody was waiting on. The trace was still the
  /// start of `wanted` when it happened, so either the beat is out of order or
  /// the adapter never produced the act it needed. Which of the two it is
  /// cannot be read off the trace, so neither is asserted. The run stopped
  /// there rather than scoring the beats that did play.
  Unplayable(at: Int, beat: Beat, trace: List(Act), wanted: List(Act))
}

pub fn passed(report: Report) -> Bool {
  report.verdict == Passed
}

pub fn failed(report: Report) -> Bool {
  report.verdict != Passed
}

/// Run every scenario. The order is `scenarios()`, so a run is comparable
/// between adapters line by line.
pub fn run_all(adapter: Adapter(bot)) -> List(Report) {
  list.map(scenarios(), run(_, adapter))
}

/// Run one.
pub fn run(scenario: Scenario, adapter: Adapter(bot)) -> Report {
  let setup =
    Setup(
      shard: gateway.new(config: config(), seed: seed),
      world: blank(),
      transport: recorder(),
      reentrant: scenario.reentrant,
    )

  let started =
    Trial(bot: adapter.start(setup), now_ms: 0, deadlines: [], dated_to: 0)
    |> deliver(adapter, _, gateway.Start)

  // The first beat that does not finish ends the run: every later beat would
  // be scored against a world the script never actually reached.
  let played =
    list.index_fold(scenario.beats, Ok(started), fn(so_far, beat, at) {
      use trial <- result.try(so_far)
      play(adapter, trial, beat, at, scenario.expect)
    })

  let verdict = case played {
    Error(failure) -> failure
    Ok(trial) -> compare(acts(adapter.world(trial.bot)), scenario.expect)
  }
  Report(name: scenario.name, why: scenario.why, verdict:)
}

/// A one-line summary, and the two traces side by side when they disagree.
pub fn describe(report: Report) -> String {
  case report.verdict {
    Passed -> "ok   " <> report.name
    Stalled(trace:) ->
      "STALL "
      <> report.name
      <> "\n  "
      <> report.why
      <> "\n  the clock kept firing timers and never reached the end.\n"
      <> render("got", trace)
    Unplayable(at:, beat:, trace:, wanted:) ->
      "BLOCKED "
      <> report.name
      <> "\n  "
      <> report.why
      <> "\n  beat "
      <> int.to_string(at)
      <> ": "
      <> string.inspect(beat)
      <> " had nothing to act on and never ran.\n  The trace is still the "
      <> "start of what was expected, so either the beat is out of order or "
      <> "the adapter never produced the act it needed.\n"
      <> render("wanted", wanted)
      <> render("got", trace)
    Diverged(at:, expected:, got:, trace:, wanted:) ->
      "FAIL "
      <> report.name
      <> "\n  "
      <> report.why
      <> "\n  act "
      <> int.to_string(at)
      <> ": wanted "
      <> render_one(expected)
      <> ", got "
      <> render_one(got)
      <> "\n"
      <> render("wanted", wanted)
      <> render("got", trace)
  }
}

fn render(label: String, acts: List(Act)) -> String {
  list.index_map(acts, fn(act, index) {
    "  " <> label <> " " <> int.to_string(index) <> ": " <> string.inspect(act)
  })
  |> list.append([""])
  |> string.join("\n")
}

fn render_one(act: Option(Act)) -> String {
  case act {
    Some(act) -> string.inspect(act)
    None -> "nothing"
  }
}

fn compare(got: List(Act), wanted: List(Act)) -> Verdict {
  case first_difference(got, wanted, 0) {
    None -> Passed
    Some(#(at, expected, actual)) ->
      Diverged(at:, expected:, got: actual, trace: got, wanted:)
  }
}

fn first_difference(
  got: List(Act),
  wanted: List(Act),
  at: Int,
) -> Option(#(Int, Option(Act), Option(Act))) {
  case got, wanted {
    [], [] -> None
    [g, ..gs], [w, ..ws] if g == w -> first_difference(gs, ws, at + 1)
    _, _ ->
      Some(#(
        at,
        list.first(wanted) |> option.from_result,
        list.first(got) |> option.from_result,
      ))
  }
}

type Trial(bot) {
  Trial(
    bot: bot,
    now_ms: Int,
    /// Soonest first. `at` is on this trial's clock, which only `Waits` moves.
    deadlines: List(Deadline),
    /// The highest stamp already given a deadline. Stamps only go up, so this
    /// separates a fresh arming from one the clock has dealt with.
    dated_to: Int,
  )
}

/// Beat number `at` against the world the beats before it left. `Error` is a
/// beat that never finished: one the world had nothing to play against, or a
/// wait the adapter spun the clock out of. `wanted` is the scenario's
/// expectation, which is the only thing that says whether a beat with nothing
/// to act on found the script wrong or the adapter already off it.
fn play(
  adapter: Adapter(bot),
  trial: Trial(bot),
  beat: Beat,
  at: Int,
  wanted: List(Act),
) -> Result(Trial(bot), Verdict) {
  let world = adapter.world(trial.bot)
  case beat {
    Connects ->
      with_socket(adapter, trial, world, at:, beat:, wanted:, input: fn(conn) {
        gateway.Opened(conn)
      })

    Refuses(failure:) ->
      with_socket(adapter, trial, world, at:, beat:, wanted:, input: fn(conn) {
        gateway.OpenFailed(conn, failure)
      })

    Delivers(payload:) ->
      with_socket(adapter, trial, world, at:, beat:, wanted:, input: fn(conn) {
        gateway.Frame(conn, payload)
      })

    PeerShuts(code:) ->
      with_socket(adapter, trial, world, at:, beat:, wanted:, input: fn(conn) {
        gateway.Closed(conn, code)
      })

    ShutConfirmed ->
      case world.closing {
        None -> Error(unplayable(world, at, beat, wanted))
        Some(#(conn, code)) ->
          Ok(deliver(adapter, trial, gateway.Closed(conn, Some(code))))
      }

    // One budget for a scripted clock, shared with `testing.advance`.
    Waits(ms:) ->
      wait(adapter, trial, trial.now_ms + int.max(0, ms), testing.max_firings)

    // Stamps only go up, so one below every stamp ever issued is a firing from
    // an arming that no longer exists.
    StaleFire(timer:) ->
      Ok(deliver(adapter, trial, gateway.Fired(timer, gateway.Stamp(-1))))

    HostSends(command:) -> Ok(deliver(adapter, trial, gateway.Command(command)))

    HostStops -> Ok(deliver(adapter, trial, gateway.Stop))
  }
}

/// A beat with nothing to act on, told apart from an adapter that had already
/// stopped matching the expectation. The single likeliest adapter bug, wiring
/// its own transport rather than passing `Setup.transport` through, never
/// records a dial and so blocks the first beat of the first scenario. Calling
/// that a bad script sends the author after a script they cannot edit.
fn unplayable(world: World, at: Int, beat: Beat, wanted: List(Act)) -> Verdict {
  let trace = acts(world)
  case on_script(trace, wanted) {
    True -> Unplayable(at:, beat:, trace:, wanted:)
    False -> compare(trace, wanted)
  }
}

/// Whether the trace so far is the start of what was expected. A trace that
/// has only run short is still on script: the acts it is missing may be ones
/// the beats after this one were going to produce.
fn on_script(trace: List(Act), wanted: List(Act)) -> Bool {
  case first_difference(trace, wanted, 0) {
    None -> True
    Some(#(_, _, extra)) -> extra == None
  }
}

fn with_socket(
  adapter: Adapter(bot),
  trial: Trial(bot),
  world: World,
  at at: Int,
  beat beat: Beat,
  wanted wanted: List(Act),
  input input: fn(Conn) -> Input,
) -> Result(Trial(bot), Verdict) {
  case world.socket {
    None -> Error(unplayable(world, at, beat, wanted))
    Some(conn) -> Ok(deliver(adapter, trial, input(conn)))
  }
}

/// One input, then reconcile the clock with whatever the adapter armed. The
/// world records armings, not live timers, so a stamp is only dated once.
fn deliver(
  adapter: Adapter(bot),
  trial: Trial(bot),
  input: Input,
) -> Trial(bot) {
  let bot = adapter.feed(trial.bot, input)
  let pending = adapter.world(bot).pending

  let fresh =
    pending
    |> list.filter(fn(arming) { stamp_of(arming) > trial.dated_to })
    |> list.map(fn(arming) {
      gateway.Deadline(
        timer: arming.timer,
        at: trial.now_ms + arming.in_ms,
        stamp: arming.stamp,
      )
    })
    |> list.reverse

  let kept =
    list.filter(trial.deadlines, fn(deadline) {
      list.any(pending, fn(arming) { arming.stamp == deadline.stamp })
    })

  Trial(
    ..trial,
    bot:,
    deadlines: list.sort(list.append(kept, fresh), fn(one, other) {
      int.compare(one.at, other.at)
    }),
    dated_to: list.fold(pending, trial.dated_to, fn(high, arming) {
      int.max(high, stamp_of(arming))
    }),
  )
}

fn stamp_of(arming: Arming) -> Int {
  let gateway.Stamp(value) = arming.stamp
  value
}

/// `Error(Stalled)` once the budget is gone with a deadline still due, which is
/// an adapter re-arming a zero delay. The wait never reached its end, so the
/// beats after it have nothing left to play against.
fn wait(
  adapter: Adapter(bot),
  trial: Trial(bot),
  until_ms: Int,
  fuel: Int,
) -> Result(Trial(bot), Verdict) {
  case trial.deadlines {
    [] -> Ok(Trial(..trial, now_ms: until_ms))
    [gateway.Deadline(timer:, at:, stamp:), ..rest] ->
      case at <= until_ms, fuel > 0 {
        False, _ -> Ok(Trial(..trial, now_ms: until_ms))
        True, False -> Error(Stalled(trace: acts(adapter.world(trial.bot))))
        True, True ->
          // Spent before it is delivered, so a shard that re-arms on fire
          // replaces nothing and one that does not is left with nothing.
          Trial(..trial, now_ms: at, deadlines: rest)
          |> deliver(adapter, _, gateway.Fired(timer, stamp))
          |> wait(adapter, _, until_ms, fuel - 1)
      }
  }
}
