//// The `{op, s, t, d}` envelope, in both directions.
////
//// Structure is strict, content is lenient: a frame needs an opcode and a
//// dispatch needs a sequence and a name. Anything else Discord sends is read
//// or ignored, never fatal.

import gleam/bool
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import glyde/gateway/presence.{type Presence}
import glyde/intents.{type Intents}
import glyde/wire

/// Discord sends 41250 today. The bounds are ours: an unclamped 0 would arm a
/// zero delay repeating timer, and nothing above ten minutes is a heartbeat.
const min_heartbeat_interval_ms: Int = 1000

const max_heartbeat_interval_ms: Int = 600_000

/// Discord's rule, not ours: IDENTIFY's `large_threshold` is 50 to 250.
const min_large_threshold: Int = 50

const max_large_threshold: Int = 250

/// Discord's gateway opcode table, both directions. The numbers are theirs, 5
/// was removed and is not here, and the names carry an `Op` prefix because
/// `Inbound` already spells four of them.
pub type Opcode {
  OpDispatch
  OpHeartbeat
  OpIdentify
  OpPresenceUpdate
  OpVoiceStateUpdate
  OpResume
  OpReconnect
  OpRequestGuildMembers
  OpInvalidSession
  OpHello
  OpHeartbeatAck
}

pub fn opcode_to_int(op: Opcode) -> Int {
  case op {
    OpDispatch -> 0
    OpHeartbeat -> 1
    OpIdentify -> 2
    OpPresenceUpdate -> 3
    OpVoiceStateUpdate -> 4
    OpResume -> 6
    OpReconnect -> 7
    OpRequestGuildMembers -> 8
    OpInvalidSession -> 9
    OpHello -> 10
    OpHeartbeatAck -> 11
  }
}

/// The inverse of `opcode_to_int`. `None` for 5 and for anything Discord adds
/// after this table was written.
pub fn opcode_from_int(value: Int) -> Option(Opcode) {
  case value {
    0 -> Some(OpDispatch)
    1 -> Some(OpHeartbeat)
    2 -> Some(OpIdentify)
    3 -> Some(OpPresenceUpdate)
    4 -> Some(OpVoiceStateUpdate)
    6 -> Some(OpResume)
    7 -> Some(OpReconnect)
    8 -> Some(OpRequestGuildMembers)
    9 -> Some(OpInvalidSession)
    10 -> Some(OpHello)
    11 -> Some(OpHeartbeatAck)
    _ -> None
  }
}

pub type Inbound {
  /// op 0. `seq` and `name` exist exactly when the opcode is 0.
  Dispatch(seq: Int, name: String, data: Dynamic)
  /// op 1. Discord wants a heartbeat right now.
  HeartbeatRequest
  /// op 7.
  Reconnect
  /// op 9. `d` is whether the session may still be resumed.
  InvalidSession(resumable: Bool)
  /// op 10.
  Hello(interval: HeartbeatInterval)
  /// op 11.
  HeartbeatAck
  /// A well formed frame with an opcode glyde does not model. Discord adding
  /// one must not kill a session.
  UnknownOp(op: Int)
  /// Not a frame we can read at all.
  Undecodable(reason: Unreadable)
}

/// Why a frame could not be read. A value, not a sentence: the caller decides
/// how to say it, and a test can assert which one it got.
pub type Unreadable {
  /// JSON, but not an `{"op": n, ...}` envelope. Covers a top level that is
  /// not an object, an `op` that is not a number, and no `op` at all.
  BadEnvelope
  NotJson
  DispatchWithoutSequence
  DispatchWithoutName
  HelloIntervalUnreadable
}

/// Each line has to be true of everything its variant covers: `BadEnvelope`
/// also catches a non-object top level and an `op` spelled as a string, and a
/// heartbeat_interval can be present and still not be a whole number.
pub fn describe_unreadable(why: Unreadable) -> String {
  case why {
    NotJson -> "not JSON"
    BadEnvelope -> "not an {op, s, t, d} envelope"
    DispatchWithoutSequence -> "dispatch with no sequence number"
    DispatchWithoutName -> "dispatch with no event name"
    HelloIntervalUnreadable ->
      "hello whose heartbeat_interval could not be read"
  }
}

/// HELLO's `heartbeat_interval`, already inside [1000, 600_000]. Opaque and
/// built nowhere but `parse`: an interval of 0 read straight off the wire would
/// arm a repeating timer with no delay, so there is no way to write one.
pub opaque type HeartbeatInterval {
  HeartbeatInterval(ms: Int)
}

pub fn heartbeat_interval_ms(interval: HeartbeatInterval) -> Int {
  interval.ms
}

/// Total: never returns an error. HELLO's interval is clamped on the way
/// through, so every `HeartbeatInterval` that comes out is armable.
pub fn parse(text: String) -> Inbound {
  case json.parse(text, decoder()) {
    Ok(inbound) -> inbound
    // `op` is the decoder's one required field, so anything that fails it is
    // JSON we could not find an envelope in. Which field the decoder blamed
    // is not worth carrying: nothing downstream can act on it.
    Error(json.UnableToDecode(_)) -> Undecodable(BadEnvelope)
    Error(_) -> Undecodable(NotJson)
  }
}

fn decoder() -> Decoder(Inbound) {
  use op <- decode.field("op", wire.integer())
  // `s` and `t` arrive as explicit nulls or not at all; only op 0 needs them.
  use seq <- wire.soft_field("s", wire.integer())
  use name <- wire.soft_field("t", decode.string)
  // `d` is an object, a bare bool, a null or nothing, so it stays `Dynamic`.
  use data <- decode.optional_field("d", dynamic.nil(), decode.dynamic)
  decode.success(classify(op, seq, name, data))
}

fn classify(
  op: Int,
  seq: Option(Int),
  name: Option(String),
  data: Dynamic,
) -> Inbound {
  case opcode_from_int(op) {
    Some(OpDispatch) ->
      case seq, name {
        Some(seq), Some(name) -> Dispatch(seq:, name:, data:)
        None, _ -> Undecodable(DispatchWithoutSequence)
        _, None -> Undecodable(DispatchWithoutName)
      }
    Some(OpHeartbeat) -> HeartbeatRequest
    Some(OpReconnect) -> Reconnect
    Some(OpInvalidSession) -> InvalidSession(resumable: resumable(data))
    Some(OpHello) ->
      case decode.run(data, hello_decoder()) {
        Ok(interval) ->
          Hello(
            HeartbeatInterval(int.clamp(
              interval,
              min: min_heartbeat_interval_ms,
              max: max_heartbeat_interval_ms,
            )),
          )
        Error(_) -> Undecodable(HelloIntervalUnreadable)
      }
    Some(OpHeartbeatAck) -> HeartbeatAck
    // The send-only opcodes are as unmodelled coming this way as one Discord
    // has not invented yet, and neither may kill a session.
    Some(OpIdentify)
    | Some(OpPresenceUpdate)
    | Some(OpVoiceStateUpdate)
    | Some(OpResume)
    | Some(OpRequestGuildMembers)
    | None -> UnknownOp(op:)
  }
}

fn hello_decoder() -> Decoder(Int) {
  use interval <- decode.field("heartbeat_interval", wire.integer())
  decode.success(interval)
}

/// op 9's `d` is a bare boolean. Unreadable reads as not resumable: guessing
/// resumable loops on op 9, guessing the other way costs one IDENTIFY.
fn resumable(data: Dynamic) -> Bool {
  case decode.run(data, decode.bool) {
    Ok(resumable) -> resumable
    Error(_) -> False
  }
}

/// One shard's place in the fleet, sent as `[index, count]`. Opaque because
/// `index` is 0-based and must be below `count`: `sharding` is the only thing
/// that can make one, so a fleet the gateway would answer with close 4010
/// cannot be built at all. Labelled and not a pair, because swapping the two
/// is also 4010 and takes a restart to spot.
pub opaque type Sharding {
  Sharding(index: Int, count: Int)
}

/// Why a fleet was refused. Both are configuration mistakes that no reconnect
/// fixes, so they are caught before a shard exists.
pub type ShardingError {
  /// A fleet has at least one shard in it.
  EmptyFleet(count: Int)
  /// `index` is 0-based, so shard 16 of 16 is not a shard.
  IndexOutOfRange(index: Int, count: Int)
}

/// `sharding(index: 0, count: 1)` is an unsharded bot, which Discord reads as
/// sending no shard array at all.
pub fn sharding(
  index index: Int,
  count count: Int,
) -> Result(Sharding, ShardingError) {
  use <- bool.guard(when: count < 1, return: Error(EmptyFleet(count:)))
  use <- bool.guard(
    when: index < 0 || index >= count,
    return: Error(IndexOutOfRange(index:, count:)),
  )
  Ok(Sharding(index:, count:))
}

/// The one fleet that needs no checking, and the default a bot connects with.
pub fn unsharded() -> Sharding {
  Sharding(index: 0, count: 1)
}

/// This shard's 0-based place in the fleet.
pub fn shard_index(sharding: Sharding) -> Int {
  sharding.index
}

/// How many shards the fleet has.
pub fn shard_count(sharding: Sharding) -> Int {
  sharding.count
}

/// Guild size above which Discord sends an offline member list. Opaque so the
/// clamp happens once, where the value is made, rather than again wherever it
/// is written.
pub opaque type LargeThreshold {
  LargeThreshold(value: Int)
}

/// Clamped rather than refused: a value outside Discord's range is a number
/// to correct, not a connection to fail.
pub fn large_threshold(value: Int) -> LargeThreshold {
  LargeThreshold(int.clamp(
    value,
    min: min_large_threshold,
    max: max_large_threshold,
  ))
}

pub fn large_threshold_value(threshold: LargeThreshold) -> Int {
  threshold.value
}

/// IDENTIFY's `properties` object. Analytics only; Discord acts on none of
/// them. The `$os` spelling is deprecated, so these go out unprefixed.
pub type Properties {
  Properties(os: String, browser: String, device: String)
}

/// Everything IDENTIFY puts on the wire.
pub type Identity {
  Identity(
    token: String,
    intents: Intents,
    properties: Properties,
    /// Asks for per-payload zlib. Not the `compress=` query parameter, which
    /// asks for transport compression; Discord will not do both.
    compress: Bool,
    large_threshold: LargeThreshold,
    shard: Sharding,
    /// What the bot looks like the moment it connects. Op 3 sends the same
    /// object once it is live.
    presence: Option(Presence),
  )
}

pub fn identify(identity: Identity) -> Outbound {
  let fields = [
    #("token", json.string(identity.token)),
    #(
      "properties",
      json.object([
        #("os", json.string(identity.properties.os)),
        #("browser", json.string(identity.properties.browser)),
        #("device", json.string(identity.properties.device)),
      ]),
    ),
    #("compress", json.bool(identity.compress)),
    #(
      "large_threshold",
      json.int(large_threshold_value(identity.large_threshold)),
    ),
    #(
      "shard",
      json.preprocessed_array([
        json.int(identity.shard.index),
        json.int(identity.shard.count),
      ]),
    ),
    #("intents", intents.to_json(identity.intents)),
  ]
  // Discord answers `"presence": null` with close 4002, so the key is omitted.
  let fields = case identity.presence {
    Some(shown) -> list.append(fields, [#("presence", presence.to_json(shown))])
    None -> fields
  }
  outbound(OpIdentify, json.object(fields))
}

pub fn resume(
  token token: String,
  session_id session_id: String,
  seq seq: Int,
) -> Outbound {
  outbound(
    OpResume,
    json.object([
      #("token", json.string(token)),
      #("session_id", json.string(session_id)),
      // `seq`, not `s`. Sending `s` reads as a missing sequence and earns 4007.
      #("seq", json.int(seq)),
    ]),
  )
}

/// `None` before this session has seen a dispatch: Discord wants a literal
/// `null`, and a 0 asks for a replay from the start and earns an op 9.
pub fn heartbeat(seq: Option(Int)) -> Outbound {
  outbound(OpHeartbeat, json.nullable(seq, json.int))
}

/// A serialised payload and the opcode that built it. The opcode travels with
/// the text so nothing downstream has to read it back out of the JSON, and
/// `text` is the only thing that goes on the socket: IDENTIFY carries the
/// token, and a log line is the easiest place to leak one.
pub type Outbound {
  Outbound(op: Opcode, text: String)
}

/// One gateway payload, serialised. `s` and `t` are receive only, so an
/// outbound frame is `op` and `d`. Every frame glyde sends is built here,
/// including the ones `glyde/gateway/command` encodes.
pub fn outbound(op: Opcode, data: Json) -> Outbound {
  Outbound(
    op:,
    text: json.to_string(
      json.object([#("op", json.int(opcode_to_int(op))), #("d", data)]),
    ),
  )
}
