//// The Discord gateway protocol as a pure state machine.
////
//// No sockets, no timers, no clock, no randomness, no logging, no processes.
//// `step` is a total function of `(Shard, Input)` returning the `Output`s the
//// caller must perform, whose results come back as the next `Input`s.
////
//// The adapter contract:
////
//// 1. Perform every output of a batch, in the order given, before feeding the
////    next input.
//// 2. `ArmTimer` replaces any timer already armed under the same `Timer`;
////    `CancelTimer` on an unarmed timer is a no-op; deliver `Fired` with the
////    exact `Stamp` you were given.
//// 3. Store the `Conn` from `Open` and hand that value back on every socket
////    input. Never synthesise one.
//// 4. Commit the new `Shard` before performing the batch, and queue any input
////    produced during performance rather than re-entering `step`.
//// 5. A send that fails is reported as `Closed(conn, None)`. Never throw out
////    of an effect fold.
//// 6. Seed the shard from something below 2^31 and different per shard.

import gleam/bool
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import glyde/gateway/backoff
import glyde/gateway/close
import glyde/gateway/command.{type Command}
import glyde/gateway/frame.{type Outbound}
import glyde/gateway/identify
import glyde/gateway/presence.{type Presence}
import glyde/gateway/ready
import glyde/gateway/reassembly
import glyde/id.{type Id}
import glyde/intents.{type Intents}
import glyde/token

// The two imports here that are not the gateway's own, both dependency-free:
// a constant module, so the REST half and this one cannot drift apart, and the
// host type, so the thing a shard dials is not a bare `String`.
import glyde/internal/host
import glyde/internal/version
import glyde/rng.{type Rng}

/// Identifies one connection attempt. Socket inputs must carry it back, so the
/// echo of a close we asked for is dropped, not read as a fresh failure.
pub type Conn {
  Conn(Int)
}

/// Identifies one arming of one timer, and one inflate request. A cancel cannot
/// recall a delivered message, so a stale fire is recognised when it lands.
pub type Stamp {
  Stamp(Int)
}

/// The current stamp for each stampable thing, and the counter they come from.
/// A record and not a `Dict`: a new timer is a compile error at every site.
pub type Stamps {
  Stamps(
    next: Int,
    conn: Conn,
    heartbeat: Stamp,
    handshake: Stamp,
    reconnect: Stamp,
    commands: Stamp,
  )
}

/// Somewhere to dial: a bare host, no scheme and no path. Every URL Discord
/// hands out has a scheme, so the two are different types and a `wss://…`
/// cannot reach a slot that dials.
pub type Host =
  host.Host

/// The host of a gateway URL, scheme and path and query dropped. `Error(Nil)`
/// when there is nothing in it to dial.
pub fn host_of(url from: String) -> Result(Host, Nil) {
  host.host_of(from)
}

/// For a log line or a URL an adapter is building. The core hands out `Host`
/// everywhere else, so this is the one direction that needs asking for.
pub fn host_to_string(host: Host) -> String {
  host.to_string(host)
}

/// Discord's front door, and what `config` fills `Config.host` with. `GET
/// /gateway/bot` may name another one; a RESUME goes to the host READY named.
pub fn default_host() -> Host {
  host.discord_gateway
}

/// Everything that does not change over a shard's life. `config/2` defaults
/// all but the token and intents, so the long tail is a record update:
///
/// ```gleam
/// let assert Ok(sharding) = gateway.sharding(index: 3, count: 16)
/// Config(..gateway.config(token:, intents:), sharding:)
/// ```
pub type Config {
  Config(
    token: token.Token,
    intents: Intents,
    sharding: Sharding,
    /// Sent in IDENTIFY. Analytics only; Discord does not act on it.
    properties: Properties,
    /// The host to dial when there is no resume host.
    host: Host,
    /// Gateway API version. A missing `v` routes to version 6, where intents
    /// are optional, so this is always sent.
    api_version: Int,
    /// Transport compression. `NoCompression` unless the adapter you are using
    /// documents support; see `Output.Inflate`.
    compression: Compression,
    /// Presence to send in IDENTIFY. `None` means online with no activity.
    presence: Option(Presence),
    /// Guild size above which Discord sends an offline member list. 50 is
    /// Discord's default, and `large_threshold` clamps to the legal range.
    large_threshold: LargeThreshold,
    tuning: Tuning,
  )
}

// The four values IDENTIFY carries live in `glyde/gateway/identify`, next to
// the encoder that writes them: the wire type is the one that knows what
// Discord accepts, so a range is checked once, where the value is made, and
// nothing downstream can hold one that is out of it. Re-exported here because
// a host configures a shard through this module alone.

pub type Sharding =
  identify.Sharding

pub type ShardingError =
  identify.ShardingError

pub type Properties =
  identify.Properties

pub type LargeThreshold =
  identify.LargeThreshold

/// `sharding(index: 0, count: 1)` is an unsharded bot, which Discord reads as
/// sending no shard array at all. `index` is 0-based and must be below
/// `count`, so a fleet the gateway would answer with close 4010 is refused
/// here rather than at the handshake.
pub fn sharding(
  index index: Int,
  count count: Int,
) -> Result(Sharding, ShardingError) {
  identify.sharding(index:, count:)
}

/// This shard's 0-based place in the fleet.
pub fn shard_index(sharding: Sharding) -> Int {
  identify.shard_index(sharding)
}

/// How many shards the fleet has.
pub fn shard_count(sharding: Sharding) -> Int {
  identify.shard_count(sharding)
}

/// Fills `Config.properties`. Discord logs these and acts on none of them.
pub fn properties(
  os os: String,
  browser browser: String,
  device device: String,
) -> Properties {
  identify.Properties(os:, browser:, device:)
}

/// Discord's rule, not ours: `large_threshold` is 50 to 250, and a value
/// outside it is clamped here rather than at the handshake.
pub fn large_threshold(value: Int) -> LargeThreshold {
  identify.large_threshold(value)
}

/// The number `Config.large_threshold` holds, after the clamp.
pub fn large_threshold_value(threshold: LargeThreshold) -> Int {
  identify.large_threshold_value(threshold)
}

pub type Compression {
  /// One WebSocket text frame is one gateway payload. The only mode glyde's
  /// own adapters implement.
  NoCompression
  /// `compress=zlib-stream`. Binary frames, payloads terminated by
  /// `00 00 FF FF`. The adapter owns the inflate context; the core frames.
  ZlibStream
}

/// Every number that is a glyde policy choice rather than a Discord rule.
pub type Tuning {
  Tuning(
    /// No READY or RESUMED this long after the dial and the handshake is
    /// wedged. Does not run while waiting for an identify slot.
    handshake_timeout_ms: Int,
    backoff_base_ms: Int,
    /// Ceiling on the reconnect ladder when the next connection will RESUME.
    /// Only downtime is at stake there, because a RESUME is unmetered.
    backoff_max_ms: Int,
    /// Ceiling on the ladder when the next connection must IDENTIFY. Discord
    /// allows 1000 a day and the penalty is a token reset: half jitter spends
    /// `86_400_000 / (0.75 * cap)` a day, so stay above 115_200. No timer is
    /// armed for longer than ten minutes, so a ceiling past that is ten
    /// minutes.
    identify_backoff_max_ms: Int,
    /// Connection attempts in a row that never reach READY or RESUMED before
    /// the shard halts instead of redialling. Our choice, not Discord's: below
    /// 1 is 1, and the ladder cannot count past 32.
    no_progress_limit: Int,
    /// Consecutive heartbeats with no op 11 before the connection is a zombie.
    /// Discord's rule is one, and anything below 1 is treated as 1.
    missed_ack_limit: Int,
    /// Outbound commands per 60s window. Discord's hard limit is 120 and
    /// exceeding it is close 4008; the gap is heartbeat headroom.
    command_limit: Int,
    /// Commands buffered while the window is closed or the shard is not live.
    /// Past this, the oldest is dropped with a `Notice`. Below 0 is 0.
    command_queue_max: Int,
    /// Hard cap on the bytes held between messages, so a gateway that stops
    /// sending the sync-flush suffix cannot grow the buffer forever. A payload
    /// that is complete when it arrives is delivered whatever its size.
    max_payload_bytes: Int,
  )
}

/// The mandatory fields, with everything else defaulted.
pub fn config(token token: token.Token, intents intents: Intents) -> Config {
  Config(
    token:,
    intents:,
    sharding: identify.unsharded(),
    properties: properties(os: "glyde", browser: "glyde", device: "glyde"),
    host: default_host(),
    api_version: version.number,
    compression: NoCompression,
    presence: None,
    large_threshold: large_threshold(50),
    tuning: Tuning(
      handshake_timeout_ms: 30_000,
      backoff_base_ms: 1000,
      backoff_max_ms: 64_000,
      identify_backoff_max_ms: 1_024_000,
      // Identifies only, so around an hour at the ceiling above: a Discord
      // outage resumes past it and a broken shard still stops. Our choice.
      no_progress_limit: 20,
      missed_ack_limit: 1,
      command_limit: 110,
      command_queue_max: 64,
      max_payload_bytes: 33_554_432,
    ),
  )
}

/// One shard's complete protocol state. Opaque so every `Shard` has passed
/// through `new` or `resuming`, which is the only place `normalise` runs.
pub opaque type Shard {
  Shard(
    config: Config,
    phase: Phase,
    /// Consecutive failed connection attempts. Reset to 0 by READY or RESUMED
    /// and by nothing else, so an accept-then-close loop still backs off.
    attempts: Int,
    stamps: Stamps,
    /// Commands the host asked to send that have not gone out. Outlives a
    /// connection, unlike the budget.
    pending: List(Command),
    /// Reassembly for a compressed transport. Empty under `NoCompression`.
    inbound: Inbound,
    rng: Rng,
  )
}

/// Where the shard is in the connection lifecycle, carrying exactly the data
/// that exists at that point.
pub type Phase {
  /// Nothing has started; `Start` is the only input that does anything.
  /// `intent` is `Identify` from `new` and `Resume` from `resuming`.
  Idle(intent: Intent)

  /// No socket, `Reconnect` armed. `intent` is what the next connection does
  /// when HELLO arrives. Initial connect, backoff and both pauses land here.
  Waiting(intent: Intent)

  /// `Open` emitted, awaiting `Opened` or `OpenFailed`. The handshake watchdog
  /// covers this window, so a transport hung in TLS cannot wedge the shard.
  Dialing(intent: Intent)

  /// Socket up, awaiting HELLO (op 10). Watchdog still armed.
  Greeting(intent: Intent)

  /// HELLO seen, waiting for an IDENTIFY slot. No `Intent`, because a RESUME
  /// never queues. The handshake watchdog is cancelled here: at
  /// `max_concurrency: 1` the sixteenth shard waits 75 seconds for a slot.
  Queued(beat: Beat)

  /// IDENTIFY is on the wire, awaiting READY. There is no session and provably
  /// no sequence number.
  Identifying(beat: Beat)

  /// RESUME is on the wire. Replayed dispatches arrive before `RESUMED`,
  /// advance `session.seq`, and each re-arms the handshake watchdog.
  Resuming(beat: Beat, session: Session)

  /// READY or RESUMED has landed.
  Live(beat: Beat, session: Session, budget: Budget)

  /// Terminal. A close code no reconnect can fix.
  Dead(reason: close.Reason)

  /// Terminal. The host asked to stop.
  Stopped

  /// Terminal. The IDENTIFY this config builds is over Discord's 4096-byte
  /// payload limit, so no connection can get past the handshake.
  Unusable(bytes: Int)

  /// Terminal. `attempts` connections in a row ended before READY, which is a
  /// shard that is broken rather than one that is unlucky.
  Exhausted(attempts: Int)
}

/// What the next connection will do when HELLO arrives.
pub type Intent {
  Identify
  Resume(session: Session)
}

/// Everything a RESUME needs. `resume_host` is the node READY named, or the
/// configured host when READY named none.
pub type Session {
  Session(id: String, resume_host: Host, seq: Int)
}

/// Heartbeat bookkeeping. Exists from HELLO onwards, so it lives in the phase.
pub type Beat {
  Beat(
    /// From HELLO. Inside [1000, 600_000], because the only thing that reaches
    /// this field is a `frame.HeartbeatInterval`, which cannot hold anything
    /// else.
    interval_ms: Int,
    /// Heartbeats sent since the last op 11. Reset by op 11 only: counting
    /// dispatch traffic stops zombie detection on the busiest connections.
    unacked: Int,
    /// True when no frame of any kind has arrived since the last heartbeat.
    /// Reported in `Notice.Zombie` and never consulted by the verdict.
    quiet: Bool,
  )
}

/// The outbound command window: Discord allows 120 events per 60 seconds per
/// connection and answers a flood with close 4008. Fresh on every reconnect.
pub type Budget {
  Budget(spent: Int, capacity: Int)
}

/// Why an inflate could not be answered with a payload. Neither is survivable
/// inside a connection: the next payload would be read against a codec context
/// that no longer matches the stream.
pub type InflateFailure {
  /// The inflate itself failed. `detail` is the host's own message, for a log
  /// and nothing else.
  ContextDesynchronised(detail: String)
  /// The host has no inflate context to answer with. A transport that
  /// negotiated compression with nothing to inflate with.
  NoInflateContext
}

/// Reassembly for a compressed transport.
pub type Inbound {
  Inbound(
    /// Bytes on this connection that are not yet a complete payload. Only
    /// `intake` writes it: a reset replaces the whole record instead.
    buffer: BitArray,
    /// The stamp of the outstanding inflate request, if any. At most one is in
    /// flight: two completing out of order would apply sequences backwards.
    inflating: Option(Stamp),
    /// Complete payloads that arrived while an inflate was outstanding, oldest
    /// first. Holding them in `buffer` would glue two payloads into one.
    pending: List(BitArray),
  )
}

/// The four timers the protocol needs. All are one-shot and re-armed on fire,
/// so a leaked repeater is unrepresentable.
pub type Timer {
  /// Send the next heartbeat, or notice the connection is a zombie.
  Heartbeat
  /// The connection has taken too long to reach READY or RESUMED.
  Handshake
  /// Dial again.
  Reconnect
  /// The 60-second command window rolled over.
  Commands
}

/// One armed timer, as an adapter has to hold it. `at` is an instant on the
/// adapter's own clock, not the delay `ArmTimer` gave: the core has no clock,
/// so only the adapter can say when "in 45 seconds" falls.
pub type Deadline {
  Deadline(timer: Timer, at: Int, stamp: Stamp)
}

/// Forget every arming of `timer`. `ArmTimer` replaces rather than adds, so an
/// adapter runs this before recording a new one, and again on `CancelTimer`.
pub fn disarm(deadlines: List(Deadline), timer: Timer) -> List(Deadline) {
  list.filter(deadlines, fn(deadline) { deadline.timer != timer })
}

/// The nearest instant across the armed timers, or `None` when nothing is
/// waiting. An adapter turns this into how long its receive may block.
pub fn soonest(deadlines: List(Deadline)) -> Option(Int) {
  list.fold(deadlines, None, fn(best, deadline) {
    case best {
      Some(at) if at <= deadline.at -> best
      _ -> Some(deadline.at)
    }
  })
}

/// Why a WebSocket upgrade never came up. Discord answers a dead token with
/// 401 and a bot dialling too often with 429, and the two need different
/// answers, so the status travels rather than being flattened into prose.
pub type DialFailure {
  /// The server answered the upgrade with a status other than 101.
  Refused(status: Int, detail: String)

  /// No answer to read a status from: DNS, TLS, a refused port, a socket that
  /// died mid-upgrade, or a transport that cannot see the response.
  Unreachable(detail: String)
}

/// Everything that can happen to a shard. Every field is plain data, so an
/// input log is a data file and replay is a fold.
pub type Input {
  /// Begin. A no-op unless the phase is `Idle`.
  Start

  /// The transport established the WebSocket, upgrade complete.
  Opened(conn: Conn)

  /// The transport could not establish it. Also the right input for a socket
  /// that died before the upgrade finished.
  OpenFailed(conn: Conn, failure: DialFailure)

  /// A text frame arrived, carrying exactly one complete gateway payload.
  /// Under `NoCompression` this is the only frame input.
  Frame(conn: Conn, text: String)

  /// One whole binary WebSocket message under a compressed transport, with any
  /// continuation frames already joined into it. It is part of a payload or the
  /// end of one, never several: a payload ends on a message boundary, and the
  /// core buffers until one does.
  Bytes(conn: Conn, data: BitArray)

  /// The answer to an `Output.Inflate`. Either failure ends the connection.
  Inflated(conn: Conn, stamp: Stamp, result: Result(String, InflateFailure))

  /// The socket closed. `None` means the transport died with no close frame.
  /// A transport that synthesises 1006 for that case is saying the same thing.
  Closed(conn: Conn, code: Option(Int))

  /// A timer fired. `stamp` must be the value from the `ArmTimer` that armed
  /// it; a mismatch means the firing is stale and is dropped.
  Fired(timer: Timer, stamp: Stamp)

  /// The identify queue granted this connection a slot.
  IdentifySlotGranted(conn: Conn)

  /// The host wants to send a gateway command.
  Command(command: Command)

  /// Close cleanly and stop. Terminal.
  Stop
}

/// What the caller must do. Perform them in order and perform all of them.
pub type Output {
  /// Open a WebSocket to `wss://<host><path>`, spelling the host with
  /// `host_to_string`. `path` already carries `?v=`, `&encoding=json` and
  /// `&compress=`; the adapter must not modify it.
  Open(conn: Conn, host: Host, path: String)

  /// Send `frame.outbound_text(frame)` as a text frame. Fire and forget: an
  /// adapter whose send fails reports `Closed(conn, None)` and never throws.
  /// `frame.outbound_op` rides along for logging, so nothing has to parse the
  /// payload back.
  Send(frame: Outbound)

  /// Send a close frame with this code, then tear the socket down. Only 1000,
  /// which invalidates the session, or 4000, which keeps it resumable.
  Close(code: close.SendCode)

  /// Abandon the transport with no close frame: the peer already closed, or
  /// nothing was ever connected.
  Drop

  /// Arm `timer` to fire in `in_ms`, replacing any timer already armed under
  /// the same name, then deliver `Fired(timer, stamp)` with this exact stamp.
  /// `in_ms` is always in [0, 600_000].
  ArmTimer(timer: Timer, in_ms: Int, stamp: Stamp)

  /// Cancel `timer`. Cancelling an unarmed timer is a no-op, and cancellation
  /// need not be atomic: the core tolerates a `Fired` that arrives anyway.
  CancelTimer(timer: Timer)

  /// Ask the identify queue for a slot for this connection.
  RequestIdentifySlot(conn: Conn)

  /// Tell the identify queue this connection no longer needs its slot.
  /// Idempotent; releasing a slot that was never granted is a no-op.
  ReleaseIdentifySlot(conn: Conn)

  /// Inflate exactly one complete compressed payload and answer with
  /// `Inflated(conn, stamp, _)`. At most one is ever outstanding.
  Inflate(conn: Conn, stamp: Stamp, bytes: BitArray)

  /// Discard the inflate context for `conn` and start a fresh one. Emitted
  /// alongside every `Open`: zlib state does not carry across connections.
  ResetInflater(conn: Conn)

  /// A protocol event for the host application.
  Emit(event: Event)

  /// Diagnostics, never protocol-significant.
  Note(notice: Notice)
}

pub type Event {
  Ready(
    session_id: String,
    user: Id(id.User),
    resume_host: Host,
    /// How many guilds READY listed. The guilds themselves arrive as
    /// GUILD_CREATE dispatches after it.
    guild_count: Int,
  )
  Resumed
  /// A dispatch, undecoded; `glyde/event` is the optional typed layer. READY
  /// and RESUMED arrive here too, after `Ready` and `Resumed`.
  Dispatch(name: String, seq: Int, data: Dynamic)
  /// The connection is gone and a reconnect is armed.
  Reconnecting(in_ms: Int, resuming: Bool, why: Why)
  /// Terminal.
  Halted(reason: Halt)
}

pub type Why {
  DialFailed(failure: DialFailure)
  PeerClosed(code: Option(Int))
  ZombieConnection
  /// The handshake watchdog expired with nothing to show for it.
  HandshakeStalled
  /// Discord answered the handshake and the answer could not be read. Nothing
  /// stalled: the accompanying `UndecodableFrame` says what was wrong with it.
  HandshakeUnreadable
  ServerRequested
  SessionInvalidated
  TransportCorrupt
}

pub type Halt {
  /// Discord refused for a reason no reconnect can fix. `shard` is what this
  /// shard identified with, which 4010 and 4011 need to be actionable.
  Fatal(reason: close.Reason, shard: Sharding)
  Requested
  /// The IDENTIFY this config builds is `bytes` long, over Discord's 4096-byte
  /// payload limit. A presence or a token to shrink, not a connection to retry.
  IdentifyTooLarge(bytes: Int)
  /// `attempts` connections in a row ended before READY, and the next one
  /// would identify. The shard stopped rather than keep spending from the
  /// identify budget on a failing dial. A resume loop never trips this.
  NoProgress(attempts: Int)
}

pub type Notice {
  /// An input that did not apply. Typed, so the negative paths are assertable.
  Ignored(what: Ignored)
  /// The zombie detector fired. `unacked` is how many heartbeats went
  /// unacknowledged; `quiet` is whether anything at all was arriving.
  Zombie(unacked: Int, quiet: Bool)
  /// Sitting in `Queued`. At `max_concurrency: 1` a large fleet spends real
  /// time here.
  AwaitingIdentifySlot
  /// Discord sent op 9. `resumable` is the `d` field.
  InvalidSession(resumable: Bool)
  /// An op 11 with no heartbeat outstanding: the gateway is acknowledging
  /// beats we did not send.
  SpuriousAck
  /// A frame we could not decode, or an opcode we do not model. The connection
  /// is fine; the frame is not.
  UndecodableFrame(reason: Undecodable)
  /// Repeated dial failures against the session's resume host; falling back to
  /// the configured one. A bad resume host must not wedge a shard.
  ResumeHostRejected(host: Host)
  /// `depth` is the size of the pending queue after the change.
  CommandQueued(depth: Int)
  CommandDropped(depth: Int)
  /// An outbound payload was over Discord's 4096-byte limit and was not sent.
  /// Sending it earns close 4002, which reads as "we sent malformed JSON".
  PayloadTooLarge(bytes: Int)
  /// The reassembly buffer went past `max_payload_bytes` with no complete
  /// payload in it.
  BufferOverflow(bytes: Int)
  InflateFailed(why: InflateFailure)
}

/// The two ways a connection's bytes stop being trustworthy. Its own type and
/// not a `Notice`, because only these two tear the connection down.
type Corruption {
  BufferFull(bytes: Int)
  InflateBroke(why: InflateFailure)
}

/// Everything that can arrive on a healthy socket and still be unusable. A
/// value and not a sentence, so a host can match on one and a test can assert
/// which it got.
pub type Undecodable {
  /// The envelope reader could not read the frame. Carried as `frame`'s own
  /// value rather than restated here: a second copy of these names is a second
  /// thing that has to stay true.
  FrameUnreadable(why: frame.Unreadable)
  /// A well formed frame carrying an opcode glyde does not model. Discord
  /// adding one must not kill a session.
  UnknownOpcode(op: Int)
  /// READY arrived without the three fields a session needs.
  ReadyIncomplete(why: ready.ReadyRejected)
  /// READY's `resume_gateway_url` had no host in it. The session is kept and
  /// the next RESUME goes to the configured host: a missing hint is not worth
  /// one of the 1000 identifies a day.
  ReadyWithoutResumeHost
  /// A binary frame with no transport compression negotiated. Nothing can be
  /// done with the bytes, and dropping them silently looks like a quiet
  /// gateway.
  BinaryFrameWithoutCompression
}

pub type Ignored {
  /// From a connection this shard has abandoned.
  StaleConn(Conn)
  /// From an arming this shard has superseded.
  StaleTimer(Timer)
  /// An inflate answer whose stamp is not the outstanding request: an adapter
  /// answering one twice, or echoing a stamp we never issued. A reset clears
  /// the request, so an answer it superseded lands as `OutOfPhase`.
  StaleInflate(Stamp)
  /// Meaningful input, wrong phase: a duplicate HELLO, a `Start` while
  /// already running, an inflate answer nobody asked for.
  OutOfPhase
  /// The shard has halted. Nothing will change that.
  Terminal
}

/// One line per diagnostic, for a host that just wants to log them. Every
/// variant carries its values too, so acting on one never means parsing this.
pub fn describe(notice: Notice) -> String {
  case notice {
    Ignored(what:) -> "ignored an input, " <> describe_ignored(what)
    Zombie(unacked:, quiet:) ->
      "zombie connection, "
      <> int.to_string(unacked)
      <> " unacknowledged heartbeat(s)"
      <> case quiet {
        True -> " and nothing arriving"
        False -> ""
      }
    AwaitingIdentifySlot -> "waiting for an identify slot"
    InvalidSession(resumable:) ->
      "invalid session, "
      <> case resumable {
        True -> "resumable"
        False -> "not resumable"
      }
    SpuriousAck -> "acknowledged a heartbeat we did not send"
    UndecodableFrame(reason:) ->
      "undecodable frame: " <> describe_undecodable(reason)
    ResumeHostRejected(host:) ->
      "resume host " <> host_to_string(host) <> " keeps refusing, falling back"
    CommandQueued(depth:) -> "command queued, depth " <> int.to_string(depth)
    CommandDropped(depth:) -> "command dropped, depth " <> int.to_string(depth)
    PayloadTooLarge(bytes:) ->
      "payload of " <> int.to_string(bytes) <> " bytes is over the limit"
    BufferOverflow(bytes:) ->
      "reassembly buffer full at " <> int.to_string(bytes) <> " bytes"
    InflateFailed(why:) ->
      "inflate failed: "
      <> case why {
        ContextDesynchronised(detail:) -> detail
        NoInflateContext -> "no inflate context"
      }
  }
}

/// Why the shard stopped, and for a fatal close what to do about it.
pub fn describe_halt(reason: Halt) -> String {
  case reason {
    Requested -> "asked to stop"
    IdentifyTooLarge(bytes:) ->
      "the identify this config builds is "
      <> int.to_string(bytes)
      <> " bytes, over Discord's 4096"
    NoProgress(attempts:) ->
      "gave up after "
      <> int.to_string(attempts)
      <> " connection attempts that never reached READY"
    Fatal(reason:, shard:) ->
      close.remedy(reason)
      <> " (shard "
      <> int.to_string(shard_index(shard))
      <> " of "
      <> int.to_string(shard_count(shard))
      <> ")"
  }
}

/// Why the connection ended and a reconnect is armed. A host printing a
/// reconnect without this says a bot is flapping and never says what is
/// wrong with it.
pub fn describe_why(why: Why) -> String {
  case why {
    DialFailed(failure: Refused(status:, detail:)) ->
      "the upgrade was refused with " <> int.to_string(status) <> ": " <> detail
    DialFailed(failure: Unreachable(detail:)) -> "the dial failed: " <> detail
    PeerClosed(code: Some(code)) ->
      "the peer closed with "
      <> int.to_string(code)
      <> ", "
      <> close.describe(close.parse(code))
    PeerClosed(code: None) -> "the connection went with no close code"
    ZombieConnection -> "the connection stopped acknowledging heartbeats"
    HandshakeStalled -> "the handshake did not finish in time"
    HandshakeUnreadable -> "the handshake answer could not be read"
    ServerRequested -> "Discord asked for a reconnect"
    SessionInvalidated -> "the session was invalidated"
    TransportCorrupt -> "the connection's bytes stopped making sense"
  }
}

pub fn describe_timer(timer: Timer) -> String {
  case timer {
    Heartbeat -> "heartbeat timer"
    Handshake -> "handshake timer"
    Reconnect -> "reconnect timer"
    Commands -> "command window timer"
  }
}

fn describe_ignored(what: Ignored) -> String {
  case what {
    StaleConn(Conn(n)) -> "from abandoned connection " <> int.to_string(n)
    StaleTimer(timer) -> "from a superseded " <> describe_timer(timer)
    StaleInflate(Stamp(n)) ->
      "inflate answer " <> int.to_string(n) <> " is not the outstanding request"
    OutOfPhase -> "wrong phase for it"
    Terminal -> "the shard is finished"
  }
}

fn describe_undecodable(reason: Undecodable) -> String {
  case reason {
    FrameUnreadable(why:) -> frame.describe_unreadable(why)
    UnknownOpcode(op:) -> "unknown opcode " <> int.to_string(op)
    ReadyIncomplete(why:) -> ready.describe_rejected(why)
    ReadyWithoutResumeHost ->
      "ready's resume_gateway_url has no host, resuming on the configured one"
    BinaryFrameWithoutCompression -> "binary frame with no compression"
  }
}

/// Discord's ceiling for outbound events per connection per minute. Exceeding
/// it is close 4008, and repeat offenders lose their API access.
const gateway_command_limit: Int = 120

const command_window_ms: Int = 60_000

/// Discord closes a connection that sends a payload larger than this with
/// 4002.
const max_command_bytes: Int = 4096

/// `erlang:send_after` raises above 2^31, so every delay is clamped. Ten
/// minutes is longer than any protocol wait.
const max_timer_ms: Int = 600_000

/// A floor on the backoff ladder after an INVALID_SESSION. Five seconds, not
/// one: `max_concurrency` counts identify requests per five seconds.
const invalid_session_floor_ms: Int = 5000

const invalid_session_jitter_ms: Int = 1500

/// Consecutive failures against a session's own resume host before falling
/// back to the configured one. Our choice, not Discord's.
const resume_host_failures: Int = 3

/// The result of one step.
pub type Step {
  Step(shard: Shard, outputs: List(Output))
}

/// A fresh shard in `Idle` with nothing armed. Feed it `Start`. Keep `seed`
/// below 2^31 and different per shard, or shards jitter in lockstep.
pub fn new(config config: Config, seed seed: Int) -> Shard {
  Shard(
    config: normalise(config),
    phase: Idle(Identify),
    attempts: 0,
    stamps: Stamps(
      next: 1,
      conn: Conn(0),
      heartbeat: Stamp(0),
      handshake: Stamp(0),
      reconnect: Stamp(0),
      commands: Stamp(0),
    ),
    pending: [],
    inbound: Inbound(buffer: <<>>, inflating: None, pending: []),
    rng: rng.seed(seed),
  )
}

/// A shard that will RESUME instead of IDENTIFY on its first connection, for a
/// host that persisted a session across a process restart.
pub fn resuming(
  config config: Config,
  seed seed: Int,
  session session: Session,
) -> Shard {
  let shard = new(config:, seed:)
  Shard(..shard, phase: Idle(Resume(session)))
}

/// A shard whose jitter starts again from `seed`, everything else untouched.
/// Same rule as `new`: below 2^31, and different for every shard of a fleet.
pub fn reseed(shard shard: Shard, seed seed: Int) -> Shard {
  Shard(..shard, rng: rng.seed(seed))
}

/// The tuning numbers, floored once at the door so nothing downstream has to
/// wonder. Everything else `Config` bounds is bounded by the type that holds
/// it: `sharding` refuses a fleet rather than inventing one, and
/// `large_threshold` clamps where the value is made.
fn normalise(config: Config) -> Config {
  let tuning = config.tuning
  Config(
    ..config,
    tuning: Tuning(
      ..tuning,
      missed_ack_limit: int.max(1, tuning.missed_ack_limit),
      command_queue_max: int.max(0, tuning.command_queue_max),
    ),
  )
}

/// The session, if there is one to resume with, including while disconnected.
/// Persist this across a process restart and hand it to `resuming`.
pub fn session(shard: Shard) -> Option(Session) {
  case shard.phase {
    Idle(Resume(session))
    | Waiting(Resume(session))
    | Dialing(Resume(session))
    | Greeting(Resume(session))
    | Resuming(_, session)
    | Live(_, session, _) -> Some(session)
    _ -> None
  }
}

/// The connection the shard will hear from.
pub fn conn(shard: Shard) -> Conn {
  shard.stamps.conn
}

/// True once the shard has halted, however it got there. An adapter's loop
/// exits here.
pub fn is_terminal(shard: Shard) -> Bool {
  case shard.phase {
    Dead(_) | Stopped | Unusable(_) | Exhausted(_) -> True
    _ -> False
  }
}

pub fn phase(shard: Shard) -> Phase {
  shard.phase
}

pub fn shard_config(shard: Shard) -> Config {
  shard.config
}

@internal
pub fn attempts(shard: Shard) -> Int {
  shard.attempts
}

@internal
pub fn stamps(shard: Shard) -> Stamps {
  shard.stamps
}

@internal
pub fn pending(shard: Shard) -> List(Command) {
  shard.pending
}

@internal
pub fn inbound(shard: Shard) -> Inbound {
  shard.inbound
}

@internal
pub fn shard_rng(shard: Shard) -> Rng {
  shard.rng
}

pub fn with_compression(shard: Shard, compression: Compression) -> Shard {
  Shard(..shard, config: Config(..shard.config, compression:))
}

@internal
pub fn with_rng(shard: Shard, rng: Rng) -> Shard {
  Shard(..shard, rng:)
}

/// Place the shard at `phase`. For a test that would otherwise drive many
/// steps to reach it. Never touches `config`, so `normalise` still holds.
@internal
pub fn with_phase(shard: Shard, phase: Phase) -> Shard {
  Shard(..shard, phase:)
}

@internal
pub fn with_attempts(shard: Shard, attempts: Int) -> Shard {
  Shard(..shard, attempts:)
}

@internal
pub fn with_pending(shard: Shard, pending: List(Command)) -> Shard {
  Shard(..shard, pending:)
}

@internal
pub fn with_inbound(shard: Shard, inbound: Inbound) -> Shard {
  Shard(..shard, inbound:)
}

/// Advance the machine by one input. One that does not apply produces a single
/// `Note(Ignored(_))`; the same pair always yields the same `Step`.
pub fn step(shard: Shard, input: Input) -> Step {
  use <- bool.guard(
    when: is_terminal(shard),
    return: Step(shard, [Note(Ignored(Terminal))]),
  )

  let current = shard.stamps.conn
  case input {
    // Released rather than dropped: it frees the slot a few seconds sooner.
    IdentifySlotGranted(c) if c != current ->
      Step(shard, [ReleaseIdentifySlot(c), Note(Ignored(StaleConn(c)))])

    // A report from a socket this shard has given up on.
    Opened(c)
      | OpenFailed(c, _)
      | Frame(c, _)
      | Bytes(c, _)
      | Inflated(c, _, _)
      | Closed(c, _)
      if c != current
    -> ignore(shard, StaleConn(c))

    // A timer firing that lost the race against its own cancellation.
    Fired(timer, stamp) ->
      case stamp == current_stamp(shard, timer) {
        True -> on_fired(shard, timer)
        False -> ignore(shard, StaleTimer(timer))
      }

    Start -> on_start(shard)
    Opened(_) -> on_opened(shard)
    OpenFailed(_, failure) -> on_open_failed(shard, failure)
    Frame(_, text) -> on_payload(shard, text)
    Bytes(_, data) -> on_bytes(shard, data)
    Inflated(_, stamp, result) -> on_inflated(shard, stamp, result)
    Closed(_, code) -> on_closed(shard, code)
    IdentifySlotGranted(_) -> on_slot(shard)
    Command(wanted) -> on_command(shard, wanted)
    Stop -> on_stop(shard)
  }
}

fn current_stamp(shard: Shard, timer: Timer) -> Stamp {
  case timer {
    Heartbeat -> shard.stamps.heartbeat
    Handshake -> shard.stamps.handshake
    Reconnect -> shard.stamps.reconnect
    Commands -> shard.stamps.commands
  }
}

/// A complete description of one transition. Every field is required, so a new
/// resource to release is a compile error at every construction site.
type Move {
  Move(
    phase: Phase,
    transport: Transport,
    plan: Plan,
    emit: List(Event),
    note: List(Notice),
  )
}

type Transport {
  /// Leave the socket alone and write `send` on it. The only transport that
  /// carries frames: a transition that tears the socket down has nothing left
  /// to write to, so "close it and then send" cannot be spelled.
  Hold(send: List(Outbound))
  /// Dial. Bumps `Conn`, emits `ResetInflater` and `Open`.
  Dial(host: Host)
  /// Send a close frame and tear down. Bumps `Conn`. The intent picks the
  /// code, so a close that keeps the session cannot go out as one that ends it.
  Shut(intent: close.Intent)
  /// Abandon with no close frame: the peer already closed, or there was never
  /// a socket. Bumps `Conn`.
  Abandon
}

/// The fate of every externally-held resource across one transition.
type Plan {
  Plan(
    heartbeat: Timing,
    handshake: Timing,
    reconnect: Timing,
    commands: Timing,
    slot: SlotPlan,
    inflater: InflaterPlan,
  )
}

/// `Keep` is a constructor and not a default, so "the heartbeat survives
/// `Queued` to `Identifying`" is a written decision rather than an omission.
type Timing {
  Arm(in_ms: Int)
  Cancel
  Keep
}

type SlotPlan {
  Request
  Release
  Untouched
}

type InflaterPlan {
  /// Throw away the adapter's context and our buffer with it.
  Reset
  Preserve
  /// Hand one complete compressed payload to the adapter.
  Feed(payload: BitArray)
}

/// The one place a phase changes, and the only writer of `phase` and `stamps`.
/// Outputs come out in one order: stop writing to the old socket, release what
/// this transition gives up, take what it needs, then emit host events last.
fn enter(shard: Shard, move: Move) -> Step {
  let Move(phase:, transport:, plan:, emit:, note:) = move
  let previous = shard.stamps.conn

  let #(stamps, conn) = case transport {
    Hold(_) -> #(shard.stamps, previous)
    _ -> {
      let #(stamps, n) = tick(shard.stamps)
      #(Stamps(..stamps, conn: Conn(n)), Conn(n))
    }
  }

  let closing = case transport {
    Hold(_) | Dial(_) -> []
    Shut(intent) -> [Close(close.code(intent))]
    Abandon -> [Drop]
  }

  let #(stamps, cancels, arms) = schedule(stamps, plan)

  let releasing = case plan.slot {
    Release -> [ReleaseIdentifySlot(previous)]
    Request | Untouched -> []
  }

  // The reset belongs to the new socket when dialling, the old one otherwise.
  let reset_target = case transport {
    Dial(_) -> conn
    _ -> previous
  }
  let #(stamps, inbound, codec) = case plan.inflater {
    Preserve -> #(stamps, shard.inbound, [])
    // The queue belongs to the codec context, so it goes with it.
    Reset -> #(stamps, Inbound(buffer: <<>>, inflating: None, pending: []), [
      ResetInflater(reset_target),
    ])
    Feed(payload) -> {
      let #(stamps, n) = tick(stamps)
      // Only the request in flight is recorded. The payload came from
      // `intake` or from `pending`, and neither is what `buffer` holds now.
      #(stamps, Inbound(..shard.inbound, inflating: Some(Stamp(n))), [
        Inflate(conn, Stamp(n), payload),
      ])
    }
  }

  let opening = case transport {
    Dial(host) -> [Open(conn, host, path(shard.config))]
    _ -> []
  }

  // Every frame that gets here is either fixed-size or was measured where it
  // was built: `on_command` for a host command, `identify` for the handshake.
  let sends = case transport {
    Hold(send) -> list.map(send, Send)
    Dial(_) | Shut(_) | Abandon -> []
  }

  let requesting = case plan.slot {
    Request -> [RequestIdentifySlot(conn)]
    Release | Untouched -> []
  }

  Step(
    Shard(..shard, phase:, stamps:, inbound:),
    list.flatten([
      closing,
      cancels,
      releasing,
      codec,
      opening,
      sends,
      arms,
      requesting,
      list.map(note, Note),
      list.map(emit, Emit),
    ]),
  )
}

fn tick(stamps: Stamps) -> #(Stamps, Int) {
  #(Stamps(..stamps, next: stamps.next + 1), stamps.next)
}

/// Cancellations first, in field order, then armings, in field order.
fn schedule(
  stamps: Stamps,
  plan: Plan,
) -> #(Stamps, List(Output), List(Output)) {
  let #(stamps, heartbeat_off, heartbeat_on) =
    reschedule(stamps, Heartbeat, plan.heartbeat)
  let #(stamps, handshake_off, handshake_on) =
    reschedule(stamps, Handshake, plan.handshake)
  let #(stamps, reconnect_off, reconnect_on) =
    reschedule(stamps, Reconnect, plan.reconnect)
  let #(stamps, commands_off, commands_on) =
    reschedule(stamps, Commands, plan.commands)
  #(
    stamps,
    list.flatten([heartbeat_off, handshake_off, reconnect_off, commands_off]),
    list.flatten([heartbeat_on, handshake_on, reconnect_on, commands_on]),
  )
}

fn reschedule(
  stamps: Stamps,
  timer: Timer,
  timing: Timing,
) -> #(Stamps, List(Output), List(Output)) {
  case timing {
    Keep -> #(stamps, [], [])
    Cancel -> {
      let #(stamps, n) = tick(stamps)
      #(restamp(stamps, timer, Stamp(n)), [CancelTimer(timer)], [])
    }
    Arm(in_ms) -> {
      let #(stamps, n) = tick(stamps)
      #(restamp(stamps, timer, Stamp(n)), [], [
        ArmTimer(timer, int.clamp(in_ms, min: 0, max: max_timer_ms), Stamp(n)),
      ])
    }
  }
}

fn restamp(stamps: Stamps, timer: Timer, stamp: Stamp) -> Stamps {
  case timer {
    Heartbeat -> Stamps(..stamps, heartbeat: stamp)
    Handshake -> Stamps(..stamps, handshake: stamp)
    Reconnect -> Stamps(..stamps, reconnect: stamp)
    Commands -> Stamps(..stamps, commands: stamp)
  }
}

/// A frame Discord would answer with close 4002 never reaches a `Move`: the
/// two places that build one from host data measure it here first, and the
/// byte count comes back so the caller can say how big it was.
fn measured(payload: Outbound) -> Result(Outbound, Int) {
  let size = string.byte_size(frame.outbound_text(payload))
  case size > max_command_bytes {
    True -> Error(size)
    False -> Ok(payload)
  }
}

/// Reused verbatim on a resume. Compression is negotiated per connection, so a
/// resume that omits `compress` gets plaintext whatever the last one used.
fn path(config: Config) -> String {
  let base = "/?v=" <> int.to_string(config.api_version) <> "&encoding=json"
  case config.compression {
    NoCompression -> base
    ZlibStream -> base <> "&compress=zlib-stream"
  }
}

fn ignore(shard: Shard, what: Ignored) -> Step {
  Step(shard, [Note(Ignored(what))])
}

fn note(shard: Shard, notices: List(Notice)) -> Step {
  Step(shard, list.map(notices, Note))
}

fn hold() -> Plan {
  Plan(
    heartbeat: Keep,
    handshake: Keep,
    reconnect: Keep,
    commands: Keep,
    slot: Untouched,
    inflater: Preserve,
  )
}

/// A transition that writes nothing to the socket, emits nothing and notes
/// nothing. Only the phase and the plan ever differ at its call sites.
fn quiet(shard: Shard, phase: Phase, plan: Plan) -> Step {
  enter(shard, Move(phase:, transport: Hold([]), plan:, emit: [], note: []))
}

/// Every recoverable failure ends here: bump the ladder, draw a delay, release
/// what the connection held, arm the reconnect.
fn retreat(
  shard: Shard,
  intent intent: Intent,
  transport transport: Transport,
  why why: Why,
  floor floor: Int,
  inflater inflater: InflaterPlan,
  note notices: List(Notice),
) -> Step {
  let tuning = shard.config.tuning
  let attempts = backoff.bump(shard.attempts)
  let shard = Shard(..shard, attempts:)

  let resuming = case intent {
    Resume(_) -> True
    Identify -> False
  }

  // A shard that identifies and fails before READY over and over is broken,
  // not unlucky, and every fresh identify comes out of a budget of 1000 a day.
  // A resume spends nothing from that budget, so a long outage keeps retrying.
  use <- bool.lazy_guard(
    when: !resuming
      && backoff.exhausted(attempts, limit: tuning.no_progress_limit),
    return: fn() { no_progress(shard, transport: transport, note: notices) },
  )

  // The ceiling follows what the next attempt will send: a resume costs only
  // downtime, an identify comes out of a budget of 1000 a day.
  let ceiling = case resuming {
    True -> tuning.backoff_max_ms
    False -> tuning.identify_backoff_max_ms
  }
  // Drawn against the largest timer that can be armed, so the delay reported
  // to the host is the delay the adapter waits.
  let max = int.min(ceiling, max_timer_ms)
  let #(generator, drawn) =
    backoff.delay(shard.rng, attempts:, base: tuning.backoff_base_ms, max:)
  // The floor can be over that cap on its own, so it is clamped too: arming
  // one delay and reporting another is the bug this avoids.
  let in_ms = int.min(int.max(drawn, floor), max_timer_ms)
  enter(
    Shard(..shard, rng: generator),
    Move(
      phase: Waiting(intent),
      transport:,
      plan: Plan(
        heartbeat: Cancel,
        handshake: Cancel,
        reconnect: Arm(in_ms),
        commands: Cancel,
        slot: Release,
        inflater:,
      ),
      emit: [Reconnecting(in_ms:, resuming:, why:)],
      note: notices,
    ),
  )
}

/// The one terminal transition. There is no next connection, so every timer is
/// cancelled, the identify slot goes back and the inflater is dropped.
fn halt(
  shard: Shard,
  transport transport: Transport,
  reason reason: Halt,
  note notices: List(Notice),
) -> Step {
  let phase = case reason {
    Fatal(reason:, ..) -> Dead(reason)
    Requested -> Stopped
    IdentifyTooLarge(bytes:) -> Unusable(bytes)
    NoProgress(attempts:) -> Exhausted(attempts)
  }
  enter(
    shard,
    Move(
      phase:,
      transport:,
      plan: Plan(
        heartbeat: Cancel,
        handshake: Cancel,
        reconnect: Cancel,
        commands: Cancel,
        slot: Release,
        inflater: Reset,
      ),
      emit: [Halted(reason)],
      note: notices,
    ),
  )
}

/// Terminal, and where `retreat` ends when the ladder has run out. The close
/// goes out as 1000, because there is no next connection to keep a session for.
fn no_progress(
  shard: Shard,
  transport transport: Transport,
  note notices: List(Notice),
) -> Step {
  let transport = case transport {
    Shut(_) -> Shut(close.Terminal)
    Hold(_) | Dial(_) | Abandon -> transport
  }
  halt(shard, transport:, reason: NoProgress(shard.attempts), note: notices)
}

/// What the next connection should do, given where this one died. A phase that
/// holds a session resumes; anything else identifies.
fn resume_or_fresh(phase: Phase) -> Intent {
  case phase {
    Idle(intent) | Waiting(intent) | Dialing(intent) | Greeting(intent) ->
      intent
    Resuming(_, session) | Live(_, session, _) -> Resume(session)
    Queued(_)
    | Identifying(_)
    | Dead(_)
    | Stopped
    | Unusable(_)
    | Exhausted(_) -> Identify
  }
}

/// What a close of ours means for the session, read off what the next
/// connection will do. Both send 4000; only a resume keeps the session.
fn closing_intent(intent: Intent) -> close.Intent {
  case intent {
    Identify -> close.FreshIdentify
    Resume(_) -> close.Reconnect
  }
}

/// True once there is a socket the peer could be talking on.
fn connected(phase: Phase) -> Bool {
  case phase {
    Greeting(_) | Queued(_) | Identifying(_) | Resuming(_, _) | Live(_, _, _) ->
      True
    _ -> False
  }
}

/// True from the dial until the teardown: a dial in flight is a socket the
/// transport can still report on.
fn has_socket(phase: Phase) -> Bool {
  case phase {
    Dialing(_) -> True
    other -> connected(other)
  }
}

/// A close frame goes out on a socket that exists; a dial in flight is just
/// abandoned.
fn tear_down(phase: Phase, intent: close.Intent) -> Transport {
  case connected(phase), has_socket(phase) {
    True, _ -> Shut(intent)
    False, True -> Abandon
    False, False -> Hold([])
  }
}

/// A phase that beats: the `Beat` it carries, the sequence number a heartbeat
/// from it quotes, and the way to put a changed beat back. The one place that
/// enumerates them, so a new phase holding a `Beat` is a compile error here
/// and nowhere else.
fn with_beat(
  phase: Phase,
) -> Result(#(Beat, Option(Int), fn(Beat) -> Phase), Nil) {
  case phase {
    // No dispatch can have arrived yet, which Discord wants as a literal null.
    Queued(beat) -> Ok(#(beat, None, fn(beat) { Queued(beat) }))
    Identifying(beat) -> Ok(#(beat, None, fn(beat) { Identifying(beat) }))
    Resuming(beat, session) ->
      Ok(#(beat, Some(session.seq), fn(beat) { Resuming(beat, session) }))
    Live(beat, session, budget) ->
      Ok(#(beat, Some(session.seq), fn(beat) { Live(beat, session, budget) }))
    Idle(_)
    | Waiting(_)
    | Dialing(_)
    | Greeting(_)
    | Dead(_)
    | Stopped
    | Unusable(_)
    | Exhausted(_) -> Error(Nil)
  }
}

/// Liveness bookkeeping for any inbound frame, an un-inflated chunk included.
/// Writes inside the current phase, so it does not go through `enter`.
fn awake(shard: Shard) -> Shard {
  case with_beat(shard.phase) {
    Error(Nil) -> shard
    Ok(#(beat, _, rebuild)) ->
      Shard(..shard, phase: rebuild(Beat(..beat, quiet: False)))
  }
}

fn on_start(shard: Shard) -> Step {
  case shard.phase {
    Idle(intent) ->
      quiet(
        shard,
        Waiting(intent),
        Plan(
          heartbeat: Cancel,
          handshake: Cancel,
          reconnect: Arm(0),
          commands: Cancel,
          slot: Untouched,
          inflater: Preserve,
        ),
      )
    _ -> ignore(shard, OutOfPhase)
  }
}

/// The handshake watchdog is armed at the dial and not at socket-open, so one
/// budget covers a hung connect, a silent socket and a HELLO with no READY.
fn dial(shard: Shard, intent: Intent) -> Step {
  let #(intent, notices) = resolve_host(shard, intent)
  enter(
    shard,
    Move(
      phase: Dialing(intent),
      transport: Dial(host_for(shard.config, intent)),
      plan: Plan(
        heartbeat: Keep,
        handshake: Arm(shard.config.tuning.handshake_timeout_ms),
        reconnect: Keep,
        commands: Keep,
        slot: Untouched,
        inflater: Reset,
      ),
      emit: [],
      note: notices,
    ),
  )
}

fn host_for(config: Config, intent: Intent) -> Host {
  case intent {
    Identify -> config.host
    Resume(session) -> session.resume_host
  }
}

/// Discord hands out a per-session gateway node and that node can go away. The
/// session survives the switch: a RESUME against the configured host works.
fn resolve_host(shard: Shard, intent: Intent) -> #(Intent, List(Notice)) {
  case intent {
    Identify -> #(intent, [])
    Resume(session) -> {
      let exhausted =
        shard.attempts >= resume_host_failures
        && session.resume_host != shard.config.host
      case exhausted {
        False -> #(intent, [])
        True -> #(Resume(Session(..session, resume_host: shard.config.host)), [
          ResumeHostRejected(session.resume_host),
        ])
      }
    }
  }
}

fn on_opened(shard: Shard) -> Step {
  case shard.phase {
    Dialing(intent) -> quiet(shard, Greeting(intent), hold())
    _ -> ignore(shard, OutOfPhase)
  }
}

/// The upgrade carries no token, so no refusal status here can prove one is
/// dead: a bad token is close 4004, after the handshake. Every refusal retries.
fn on_open_failed(shard: Shard, failure: DialFailure) -> Step {
  case shard.phase, failure {
    Dialing(intent), _ ->
      retreat(
        shard,
        intent:,
        transport: Abandon,
        why: DialFailed(failure),
        floor: redial_floor(shard.config.tuning, failure),
        inflater: Preserve,
        note: [],
      )

    _, _ -> ignore(shard, OutOfPhase)
  }
}

/// A 429 on the upgrade is Discord saying the dials are too close together, so
/// the next one waits, as it does for close 4008.
fn redial_floor(tuning: Tuning, failure: DialFailure) -> Int {
  case failure {
    Refused(status: 429, ..) -> tuning.backoff_max_ms / 2
    Refused(..) | Unreachable(..) -> 0
  }
}

fn on_closed(shard: Shard, code: Option(Int)) -> Step {
  // A close with no socket is an adapter reporting twice. Acting on it would
  // advance the ladder again for one disconnection.
  use <- bool.guard(
    when: !has_socket(shard.phase),
    return: ignore(shard, OutOfPhase),
  )

  // The peer closed, so there is no socket left to write to, and every
  // recoverable close keeps the inflater. Only the intent, the floor and the
  // notices differ.
  let peer_retreat = fn(shard, intent, floor, notices) {
    retreat(
      shard,
      intent:,
      transport: Abandon,
      why: PeerClosed(code),
      floor:,
      inflater: Preserve,
      note: notices,
    )
  }

  case close.from_gateway(code) {
    close.Fatal(reason) -> die(shard, reason)

    close.ReconnectFresh -> peer_retreat(shard, Identify, 0, [])

    close.ReconnectResume ->
      peer_retreat(shard, resume_or_fresh(shard.phase), 0, [])

    // We flooded the command budget. The session survives, but redialling with
    // no wait earns the next one and the backlog must not go straight out.
    close.ReconnectThrottled -> {
      let floor = shard.config.tuning.backoff_max_ms / 2
      let #(shard, notices) = case shard.pending {
        [_, ..] -> #(Shard(..shard, pending: []), [CommandDropped(0)])
        [] -> #(shard, [])
      }
      peer_retreat(shard, resume_or_fresh(shard.phase), floor, notices)
    }
  }
}

fn die(shard: Shard, reason: close.Reason) -> Step {
  halt(
    shard,
    transport: Abandon,
    reason: Fatal(reason, shard.config.sharding),
    note: [],
  )
}

fn on_stop(shard: Shard) -> Step {
  halt(
    shard,
    transport: tear_down(shard.phase, close.Terminal),
    reason: Requested,
    note: [],
  )
}

fn on_fired(shard: Shard, timer: Timer) -> Step {
  case timer, shard.phase {
    Reconnect, Waiting(intent) -> dial(shard, intent)

    Handshake, Dialing(intent) -> stalled(shard, intent)
    Handshake, Greeting(intent) -> stalled(shard, intent)
    Handshake, Identifying(_) -> stalled(shard, Identify)
    // The watchdog expiring is not evidence the session is gone, and RESUME is
    // unmetered while IDENTIFY comes out of a budget of 1000 a day.
    Handshake, Resuming(_, session) -> stalled(shard, Resume(session))

    // Every phase that carries a beat beats, and carries the sequence number
    // its heartbeat quotes.
    Heartbeat, phase ->
      case with_beat(phase) {
        Error(Nil) -> ignore(shard, OutOfPhase)
        Ok(#(beat, seq, rebuild)) ->
          beat_now(shard, beat, seq, resume_or_fresh(phase), rebuild)
      }

    Commands, Live(beat, session, budget) ->
      roll_window(shard, beat, session, budget)

    _, _ -> ignore(shard, OutOfPhase)
  }
}

fn stalled(shard: Shard, intent: Intent) -> Step {
  retreat(
    shard,
    intent:,
    transport: tear_down(shard.phase, closing_intent(intent)),
    why: HandshakeStalled,
    floor: 0,
    inflater: Preserve,
    note: [],
  )
}

/// The zombie check runs before the beat, so a dead socket gets no more writes.
fn beat_now(
  shard: Shard,
  beat: Beat,
  seq: Option(Int),
  intent: Intent,
  rebuild: fn(Beat) -> Phase,
) -> Step {
  case beat.unacked >= shard.config.tuning.missed_ack_limit {
    True ->
      retreat(
        shard,
        intent:,
        transport: Shut(closing_intent(intent)),
        why: ZombieConnection,
        floor: 0,
        inflater: Preserve,
        note: [Zombie(unacked: beat.unacked, quiet: beat.quiet)],
      )
    False ->
      enter(
        shard,
        Move(
          phase: rebuild(Beat(..beat, unacked: beat.unacked + 1, quiet: True)),
          transport: Hold([frame.heartbeat(seq)]),
          plan: Plan(..hold(), heartbeat: Arm(beat.interval_ms)),
          emit: [],
          note: [],
        ),
      )
  }
}

fn roll_window(
  shard: Shard,
  beat: Beat,
  session: Session,
  budget: Budget,
) -> Step {
  let #(sends, pending, budget) =
    drain(shard.pending, Budget(..budget, spent: 0))
  enter(
    Shard(..shard, pending:),
    Move(
      phase: Live(beat, session, budget),
      transport: Hold(sends),
      plan: Plan(..hold(), commands: window(budget)),
      emit: [],
      note: [],
    ),
  )
}

/// A window that spent nothing needs no rollover, so an idle shard holds no
/// timer at all.
fn window(budget: Budget) -> Timing {
  case budget.spent > 0 {
    True -> Arm(command_window_ms)
    False -> Cancel
  }
}

/// The window opens on the first send in it and is left alone afterwards:
/// re-arming per send would slide the rollover forward forever.
fn opened(budget: Budget) -> Timing {
  case budget.spent == 0 {
    True -> Arm(command_window_ms)
    False -> Keep
  }
}

fn on_payload(shard: Shard, text: String) -> Step {
  let shard = awake(shard)
  case frame.parse(text) {
    frame.Hello(interval) -> on_hello(shard, interval)
    frame.HeartbeatAck -> on_ack(shard)
    frame.HeartbeatRequest -> on_beat_request(shard)
    frame.Reconnect -> on_server_reconnect(shard)
    frame.InvalidSession(resumable) -> on_invalid_session(shard, resumable)
    frame.Dispatch(seq:, name:, data:) -> on_dispatch(shard, seq, name, data)

    // Neither is a reason to close: the JSON parser holds no state across
    // frames, and a handshake that never decodes is caught by the watchdog.
    frame.UnknownOp(op) -> note(shard, [UndecodableFrame(UnknownOpcode(op))])
    frame.Undecodable(reason) ->
      note(shard, [UndecodableFrame(FrameUnreadable(reason))])
  }
}

/// The interval belongs to the socket, not the session, so every HELLO is
/// re-read, including one on a connection about to resume onto another node.
fn on_hello(shard: Shard, interval: frame.HeartbeatInterval) -> Step {
  case shard.phase {
    Greeting(intent) -> {
      let #(shard, beat, first) = greeted(shard, interval)
      let #(phase, send, handshake, slot, notices) = case intent {
        // The handshake timer is cancelled, not kept: the wait for a slot is
        // unbounded.
        Identify -> #(Queued(beat), [], Cancel, Request, [AwaitingIdentifySlot])

        Resume(session) -> #(
          Resuming(beat, session),
          [
            frame.resume(
              token: shard.config.token,
              session_id: session.id,
              seq: session.seq,
            ),
          ],
          Arm(shard.config.tuning.handshake_timeout_ms),
          Untouched,
          [],
        )
      }
      enter(
        shard,
        Move(
          phase:,
          transport: Hold(send),
          plan: Plan(
            heartbeat: Arm(first),
            handshake:,
            reconnect: Keep,
            commands: Keep,
            slot:,
            inflater: Preserve,
          ),
          emit: [],
          note: notices,
        ),
      )
    }

    // Answering a second HELLO with a second IDENTIFY earns close 4005.
    _ -> ignore(shard, OutOfPhase)
  }
}

/// Fresh liveness state and the `interval * jitter` first beat Discord asks
/// for. Drawn in the branches that use it, so an ignored HELLO draws nothing.
fn greeted(
  shard: Shard,
  interval: frame.HeartbeatInterval,
) -> #(Shard, Beat, Int) {
  let interval_ms = frame.heartbeat_interval_ms(interval)
  let #(generator, first) = rng.below(shard.rng, interval_ms)
  #(
    Shard(..shard, rng: generator),
    Beat(interval_ms:, unacked: 0, quiet: False),
    first,
  )
}

fn on_ack(shard: Shard) -> Step {
  case with_beat(shard.phase) {
    Error(Nil) -> ignore(shard, OutOfPhase)
    Ok(#(beat, _, rebuild)) ->
      enter(
        shard,
        Move(
          phase: rebuild(Beat(..beat, unacked: 0)),
          transport: Hold([]),
          plan: hold(),
          emit: [],
          // An ack for a beat we never sent completes nothing. Worth seeing.
          note: case beat.unacked > 0 {
            True -> []
            False -> [SpuriousAck]
          },
        ),
      )
  }
}

/// Answer op 1 at once, without touching the liveness flag or rescheduling the
/// periodic beat: an op 1 just before a tick would look like a zombie.
fn on_beat_request(shard: Shard) -> Step {
  case beating(shard.phase) {
    Error(_) -> ignore(shard, OutOfPhase)
    Ok(seq) ->
      enter(
        shard,
        Move(
          phase: shard.phase,
          transport: Hold([frame.heartbeat(seq)]),
          plan: hold(),
          emit: [],
          note: [],
        ),
      )
  }
}

/// The sequence a heartbeat carries, and whether this phase beats at all.
/// `Ok(None)` is "no dispatch yet", which Discord wants as a literal null.
fn beating(phase: Phase) -> Result(Option(Int), Nil) {
  case with_beat(phase) {
    Ok(#(_, seq, _)) -> Ok(seq)
    Error(Nil) -> Error(Nil)
  }
}

/// op 7 is accepted at any point, HELLO not required, and acted on at once:
/// waiting for Discord's own close turns it into an unexplained disconnect.
fn on_server_reconnect(shard: Shard) -> Step {
  case connected(shard.phase) {
    False -> ignore(shard, OutOfPhase)
    True -> {
      let intent = resume_or_fresh(shard.phase)
      retreat(
        shard,
        intent:,
        transport: Shut(closing_intent(intent)),
        why: ServerRequested,
        floor: 0,
        inflater: Preserve,
        note: [],
      )
    }
  }
}

/// op 9 closes the socket and reconnects; it never re-sends a handshake on the
/// open one. `d: true` with no session held is `d: false`.
fn on_invalid_session(shard: Shard, resumable: Bool) -> Step {
  case connected(shard.phase) {
    False -> ignore(shard, OutOfPhase)
    True -> {
      let intent = case resumable, session_of(shard.phase) {
        True, Some(session) -> Resume(session)
        _, _ -> Identify
      }
      let #(generator, jitter) = rng.below(shard.rng, invalid_session_jitter_ms)
      retreat(
        Shard(..shard, rng: generator),
        intent:,
        transport: Shut(closing_intent(intent)),
        why: SessionInvalidated,
        floor: invalid_session_floor_ms + jitter,
        inflater: Preserve,
        note: [InvalidSession(resumable)],
      )
    }
  }
}

fn session_of(phase: Phase) -> Option(Session) {
  case phase {
    Resuming(_, session) | Live(_, session, _) -> Some(session)
    _ -> None
  }
}

fn on_dispatch(shard: Shard, seq: Int, name: String, data: Dynamic) -> Step {
  case shard.phase, name {
    Identifying(beat), "READY" -> on_ready(shard, beat, seq, data)
    // A READY on a resuming connection replaces the session wholesale.
    Resuming(beat, _), "READY" -> on_ready(shard, beat, seq, data)
    Resuming(beat, session), "RESUMED" ->
      on_resumed(shard, beat, session, seq, data)

    // Replay. Each one is evidence the handshake is working, so the watchdog
    // starts again rather than expiring part-way through a long backlog.
    Resuming(beat, session), _ ->
      enter(
        shard,
        Move(
          phase: Resuming(beat, advance(session, seq)),
          transport: Hold([]),
          plan: Plan(
            ..hold(),
            handshake: Arm(shard.config.tuning.handshake_timeout_ms),
          ),
          emit: [Dispatch(name:, seq:, data:)],
          note: [],
        ),
      )

    Live(beat, session, budget), _ ->
      enter(
        shard,
        Move(
          phase: Live(beat, advance(session, seq), budget),
          transport: Hold([]),
          plan: hold(),
          emit: [Dispatch(name:, seq:, data:)],
          note: [],
        ),
      )

    // A dispatch before the handshake finished has no session to advance, and
    // dropping it would lose an event Discord will not send again.
    Greeting(_), _ | Queued(_), _ | Identifying(_), _ ->
      Step(shard, [Emit(Dispatch(name:, seq:, data:))])

    _, _ -> ignore(shard, OutOfPhase)
  }
}

/// Never lower the frontier. A resume replays in order, so a lower sequence
/// means the host's store raced, not that time went backwards.
fn advance(session: Session, seq: Int) -> Session {
  Session(..session, seq: int.max(session.seq, seq))
}

fn on_ready(shard: Shard, beat: Beat, seq: Int, data: Dynamic) -> Step {
  case ready.read(data) {
    // Identify again rather than sit half-initialised until the watchdog fires.
    Error(why) ->
      retreat(
        shard,
        intent: Identify,
        transport: Shut(closing_intent(Identify)),
        why: HandshakeUnreadable,
        floor: 0,
        inflater: Preserve,
        note: [UndecodableFrame(ReadyIncomplete(why))],
      )

    Ok(payload) -> {
      // The resume host is a hint, not a session: a READY without one still
      // resumes, against the host this shard was configured with.
      let #(resume_host, notices) = case payload.resume_host {
        Some(host) -> #(host, [])
        None -> #(shard.config.host, [
          UndecodableFrame(ReadyWithoutResumeHost),
        ])
      }
      go_live(
        shard,
        beat,
        Session(id: payload.session_id, resume_host:, seq:),
        Release,
        [
          Ready(
            session_id: payload.session_id,
            user: payload.user,
            resume_host:,
            guild_count: payload.guild_count,
          ),
          Dispatch(name: "READY", seq:, data:),
        ],
        notices,
      )
    }
  }
}

fn on_resumed(
  shard: Shard,
  beat: Beat,
  session: Session,
  seq: Int,
  data: Dynamic,
) -> Step {
  go_live(
    shard,
    beat,
    advance(session, seq),
    Untouched,
    [Resumed, Dispatch(name: "RESUMED", seq:, data:)],
    [],
  )
}

/// READY and RESUMED are the only two things that mean "connected", and the
/// only two that reset the ladder.
fn go_live(
  shard: Shard,
  beat: Beat,
  session: Session,
  slot: SlotPlan,
  emit: List(Event),
  note: List(Notice),
) -> Step {
  let budget = Budget(spent: 0, capacity: capacity(shard.config, beat))
  let #(sends, pending, budget) = drain(shard.pending, budget)
  enter(
    Shard(..shard, attempts: 0, pending:),
    Move(
      phase: Live(beat, session, budget),
      transport: Hold(sends),
      plan: Plan(
        heartbeat: Keep,
        handshake: Cancel,
        reconnect: Cancel,
        commands: window(budget),
        slot:,
        inflater: Preserve,
      ),
      emit:,
      note:,
    ),
  )
}

/// Commands share Discord's 120-per-60s budget with heartbeats. The headroom
/// follows the advertised interval, so a very short one cannot squeeze it out.
fn capacity(config: Config, beat: Beat) -> Int {
  let per_window = case beat.interval_ms > 0 {
    True -> { command_window_ms + beat.interval_ms - 1 } / beat.interval_ms
    False -> gateway_command_limit
  }
  // One over the beats the interval implies, for a server-requested op 1.
  let reserve = int.clamp(per_window + 1, min: 2, max: 20)
  int.min(config.tuning.command_limit, gateway_command_limit - reserve)
}

fn on_command(shard: Shard, wanted: Command) -> Step {
  // Before the budget, so a command Discord would answer with 4002 spends
  // nothing and never reaches the queue.
  use payload <- unwrap_or_else(measured(command.encode(wanted)), fn(size) {
    Step(shard, [Note(PayloadTooLarge(size))])
  })

  case shard.phase {
    Live(beat, session, budget) ->
      case budget.spent < budget.capacity {
        True ->
          enter(
            shard,
            Move(
              phase: Live(
                beat,
                session,
                Budget(..budget, spent: budget.spent + 1),
              ),
              transport: Hold([payload]),
              plan: Plan(..hold(), commands: opened(budget)),
              emit: [],
              note: [],
            ),
          )
        False -> queue(shard, wanted)
      }
    // A command sent before RESUMED lands earns close 4003, which destroys the
    // session the resume was for.
    _ -> queue(shard, wanted)
  }
}

fn queue(shard: Shard, wanted: Command) -> Step {
  let limit = shard.config.tuning.command_queue_max
  let depth = list.length(shard.pending)
  case limit {
    0 -> Step(shard, [Note(CommandDropped(0))])
    _ ->
      case depth >= limit {
        True -> {
          let pending = list.append(list.drop(shard.pending, 1), [wanted])
          Step(Shard(..shard, pending:), [
            Note(CommandDropped(list.length(pending))),
          ])
        }
        False -> {
          let pending = list.append(shard.pending, [wanted])
          Step(Shard(..shard, pending:), [
            Note(CommandQueued(list.length(pending))),
          ])
        }
      }
  }
}

/// As many queued commands as the window has room for, in the order asked.
fn drain(
  pending: List(Command),
  budget: Budget,
) -> #(List(Outbound), List(Command), Budget) {
  case pending {
    [] -> #([], [], budget)
    [next, ..rest] ->
      case budget.spent < budget.capacity {
        False -> #([], pending, budget)
        True -> {
          let #(sends, left, budget) =
            drain(rest, Budget(..budget, spent: budget.spent + 1))
          #([command.encode(next), ..sends], left, budget)
        }
      }
  }
}

fn on_slot(shard: Shard) -> Step {
  case shard.phase {
    Queued(beat) -> {
      // No reconnect makes an oversized IDENTIFY smaller, and a connection
      // that cannot identify is a connection that cannot do anything.
      use payload <- unwrap_or_else(identify(shard.config), fn(bytes) {
        unusable(shard, bytes)
      })
      enter(
        shard,
        Move(
          phase: Identifying(beat),
          transport: Hold([payload]),
          plan: Plan(
            ..hold(),
            handshake: Arm(shard.config.tuning.handshake_timeout_ms),
          ),
          emit: [],
          note: [],
        ),
      )
    }
    // Still our connection, but past wanting a slot. Hand it back.
    _ ->
      enter(
        shard,
        Move(
          phase: shard.phase,
          transport: Hold([]),
          plan: Plan(..hold(), slot: Release),
          emit: [],
          note: [Ignored(OutOfPhase)],
        ),
      )
  }
}

/// The frame, or how many bytes it came to. Measured here because this is the
/// one frame built wholly from `Config`: too large is a fault in the config,
/// not a connection that went wrong.
fn identify(config: Config) -> Result(Outbound, Int) {
  measured(
    identify.identify(identify.Identity(
      token: config.token,
      intents: config.intents,
      properties: config.properties,
      large_threshold: config.large_threshold,
      shard: config.sharding,
      presence: config.presence,
    )),
  )
}

/// Terminal, and not a retreat: the shard is holding a slot and a socket it
/// will never identify on, so both go back and the host is told why.
fn unusable(shard: Shard, bytes: Int) -> Step {
  halt(
    shard,
    transport: tear_down(shard.phase, close.Terminal),
    reason: IdentifyTooLarge(bytes),
    note: [],
  )
}

fn on_bytes(shard: Shard, data: BitArray) -> Step {
  let shard = awake(shard)
  case connected(shard.phase) {
    False -> ignore(shard, OutOfPhase)
    True -> intake(shard, data)
  }
}

fn intake(shard: Shard, message: BitArray) -> Step {
  case shard.config.compression {
    // Reported, not dropped: dropping them looks healthy and delivers nothing.
    NoCompression ->
      note(shard, [UndecodableFrame(BinaryFrameWithoutCompression)])

    ZlibStream ->
      case
        reassembly.feed(
          shard.inbound.buffer,
          message:,
          max_bytes: shard.config.tuning.max_payload_bytes,
        )
      {
        // The buffer goes with the connection, which `corrupt` tears down.
        reassembly.Overflow(bytes) -> corrupt(shard, BufferFull(bytes))

        // The one write of `buffer`, by the one function that fills it.
        reassembly.Partial(buffer) ->
          Step(Shard(..shard, inbound: Inbound(..shard.inbound, buffer:)), [])

        reassembly.Payload(bytes) -> {
          let shard =
            Shard(
              ..shard,
              inbound: Inbound(..shard.inbound, buffer: reassembly.empty),
            )
          case shard.inbound.inflating {
            // One at a time: two completing out of order would apply sequence
            // numbers backwards.
            Some(_) ->
              Step(
                Shard(
                  ..shard,
                  inbound: Inbound(
                    ..shard.inbound,
                    pending: list.append(shard.inbound.pending, [bytes]),
                  ),
                ),
                [],
              )
            None -> feed(shard, bytes)
          }
        }
      }
  }
}

fn feed(shard: Shard, payload: BitArray) -> Step {
  quiet(shard, shard.phase, Plan(..hold(), inflater: Feed(payload)))
}

fn on_inflated(
  shard: Shard,
  stamp: Stamp,
  result: Result(String, InflateFailure),
) {
  case shard.inbound.inflating {
    // Nobody asked for one, so there is no request this could be late for.
    None -> ignore(shard, OutOfPhase)
    // The answer to a request a reset threw away. Applying it would put a
    // payload from the old codec context into the new connection.
    Some(outstanding) if outstanding != stamp ->
      ignore(shard, StaleInflate(stamp))
    Some(_) -> {
      let shard =
        Shard(..shard, inbound: Inbound(..shard.inbound, inflating: None))
      case result {
        // A poisoned context cannot be recovered inside a connection: every
        // later payload errors while the socket stays up and looks healthy.
        Error(why) -> corrupt(shard, InflateBroke(why))
        Ok(text) -> chain(on_payload(shard, text))
      }
    }
  }
}

/// A payload that completed while another was inflating starts now. Only
/// `pending` is drained: bytes left in `buffer` are always partial.
fn chain(step: Step) -> Step {
  let Step(shard:, outputs:) = step
  let idle = shard.inbound.inflating == None && connected(shard.phase)

  let next = case idle, shard.inbound.pending {
    True, [head, ..rest] -> Ok(#(head, rest))
    _, _ -> Error(Nil)
  }
  use #(payload, rest) <- unwrap_or_else(next, fn(_) { step })

  let shard = Shard(..shard, inbound: Inbound(..shard.inbound, pending: rest))
  let Step(shard:, outputs: more) = feed(shard, payload)
  // Host events stay last, so a re-entrant handler runs after every effect.
  let #(events, effects) =
    list.partition(outputs, fn(output) {
      case output {
        Emit(_) -> True
        _ -> False
      }
    })
  Step(shard, list.flatten([effects, more, events]))
}

/// `use`-shaped: carry on with the value, or hand the reason to `otherwise`.
fn unwrap_or_else(
  result: Result(a, e),
  otherwise: fn(e) -> b,
  next: fn(a) -> b,
) -> b {
  case result {
    Ok(value) -> next(value)
    Error(reason) -> otherwise(reason)
  }
}

fn corrupt(shard: Shard, why: Corruption) -> Step {
  let intent = resume_or_fresh(shard.phase)
  let note = case why {
    BufferFull(bytes:) -> BufferOverflow(bytes:)
    InflateBroke(why:) -> InflateFailed(why:)
  }
  retreat(
    shard,
    intent:,
    transport: tear_down(shard.phase, closing_intent(intent)),
    why: TransportCorrupt,
    floor: 0,
    inflater: Reset,
    note: [note],
  )
}
