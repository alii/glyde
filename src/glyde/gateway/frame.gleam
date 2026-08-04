//// The `{op, s, t, d}` envelope, in both directions.
////
//// Structure is strict, content is lenient: a frame needs an opcode and a
//// dispatch needs a sequence and a name. Anything else Discord sends is read
//// or ignored, never fatal.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import glyde/token
import glyde/wire

/// Discord sends 41250 today. The bounds are ours: an unclamped 0 would arm a
/// zero delay repeating timer, and nothing above ten minutes is a heartbeat.
const min_heartbeat_interval_ms: Int = 1000

const max_heartbeat_interval_ms: Int = 600_000

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

/// The six opcodes a client ever writes. `Outbound` is typed on this rather
/// than `Opcode`, so a frame carrying a receive-only op cannot be built.
pub type SendOp {
  SendHeartbeat
  SendIdentify
  SendPresenceUpdate
  SendVoiceStateUpdate
  SendResume
  SendRequestGuildMembers
}

pub fn send_op_to_int(op: SendOp) -> Int {
  case op {
    SendHeartbeat -> 1
    SendIdentify -> 2
    SendPresenceUpdate -> 3
    SendVoiceStateUpdate -> 4
    SendResume -> 6
    SendRequestGuildMembers -> 8
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

pub fn resume(
  token secret: token.Token,
  session_id session_id: String,
  seq seq: Int,
) -> Outbound {
  outbound(
    SendResume,
    json.object([
      #("token", json.string(token.reveal(secret))),
      #("session_id", json.string(session_id)),
      // `seq`, not `s`. Sending `s` reads as a missing sequence and earns 4007.
      #("seq", json.int(seq)),
    ]),
  )
}

/// `None` before this session has seen a dispatch: Discord wants a literal
/// `null`, and a 0 asks for a replay from the start and earns an op 9.
pub fn heartbeat(seq: Option(Int)) -> Outbound {
  outbound(SendHeartbeat, json.nullable(seq, json.int))
}

/// A serialised payload and the opcode that built it. Opaque so the two cannot
/// disagree: `outbound` is the only constructor, and it derives the text from
/// the opcode. `text` is the only thing that goes on the socket, and IDENTIFY
/// carries the token, so a log line is the easiest place to leak one.
pub opaque type Outbound {
  Outbound(op: SendOp, text: String)
}

/// The opcode this frame was built with. Carried so nothing downstream has to
/// read it back out of the JSON.
pub fn outbound_op(outbound: Outbound) -> SendOp {
  outbound.op
}

/// The serialised frame, and the only thing that goes on the socket.
pub fn outbound_text(outbound: Outbound) -> String {
  outbound.text
}

/// One gateway payload, serialised. `s` and `t` are receive only, so an
/// outbound frame is `op` and `d`. Every frame glyde sends is built here,
/// including the ones `glyde/gateway/command` encodes.
pub fn outbound(op: SendOp, data: Json) -> Outbound {
  Outbound(
    op:,
    text: json.to_string(
      json.object([#("op", json.int(send_op_to_int(op))), #("d", data)]),
    ),
  )
}
