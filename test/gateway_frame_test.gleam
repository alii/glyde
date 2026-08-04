import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import glyde/gateway/frame
import glyde/gateway/identify
import glyde/gateway/presence
import glyde/intents
import glyde/token

/// Every inbound frame as one comparable line. `Dispatch` holds a `Dynamic` no
/// literal can be written for, so it is tested separately.
fn summary(inbound: frame.Inbound) -> String {
  case inbound {
    frame.Dispatch(seq:, name:, ..) ->
      "dispatch " <> int.to_string(seq) <> " " <> name
    frame.HeartbeatRequest -> "heartbeat request"
    frame.Reconnect -> "reconnect"
    frame.InvalidSession(resumable: True) -> "invalid session, resumable"
    frame.InvalidSession(resumable: False) -> "invalid session, gone"
    frame.Hello(interval) ->
      "hello " <> int.to_string(frame.heartbeat_interval_ms(interval))
    frame.HeartbeatAck -> "heartbeat ack"
    frame.UnknownOp(op:) -> "unknown op " <> int.to_string(op)
    frame.Undecodable(reason:) -> "undecodable: " <> unreadable(reason)
  }
}

fn unreadable(reason: frame.Unreadable) -> String {
  case reason {
    frame.BadEnvelope -> "bad envelope"
    frame.NotJson -> "not JSON"
    frame.DispatchWithoutSequence -> "dispatch with no sequence number"
    frame.DispatchWithoutName -> "dispatch with no event name"
    // Not "no heartbeat_interval": the key can be there and hold 1.5.
    frame.HelloIntervalUnreadable ->
      "hello with an unreadable heartbeat_interval"
  }
}

/// One row per opcode, plus every way a frame can be unreadable. The first
/// four rows were captured from live Discord.
fn frames() -> List(#(String, String)) {
  [
    #(
      "{\"t\":null,\"s\":null,\"op\":10,\"d\":{\"heartbeat_interval\":41250,"
        <> "\"_trace\":[\"[\\\"gateway-prd-arm-us-east1-b-s2q2\\\"]\"]}}",
      "hello 41250",
    ),
    #("{\"t\":null,\"s\":null,\"op\":11,\"d\":null}", "heartbeat ack"),
    #("{\"t\":null,\"s\":null,\"op\":9,\"d\":false}", "invalid session, gone"),
    #(
      "{\"op\":0,\"s\":2,\"t\":\"GUILD_CREATE\",\"d\":{\"id\":\"1\"}}",
      "dispatch 2 GUILD_CREATE",
    ),

    // The documented shapes. op 11 omits `d` entirely, op 1 sends a bare int,
    // op 7 and op 9 send a bare null and a bare bool.
    #("{\"op\":11}", "heartbeat ack"),
    #("{\"op\":1,\"d\":251}", "heartbeat request"),
    #("{\"op\":1,\"d\":null}", "heartbeat request"),
    #("{\"op\":1}", "heartbeat request"),
    #("{\"op\":7,\"d\":null}", "reconnect"),
    #("{\"op\":9,\"d\":true}", "invalid session, resumable"),
    #("{\"op\":10,\"d\":{\"heartbeat_interval\":45000}}", "hello 45000"),
    #("{\"op\":0,\"s\":42,\"t\":\"READY\",\"d\":{}}", "dispatch 42 READY"),

    // The opcode space is sparse: 5 does not exist, and Discord adds more.
    #("{\"op\":5}", "unknown op 5"),
    #("{\"op\":31,\"d\":{\"guild_ids\":[]}}", "unknown op 31"),
    #("{\"op\":43,\"d\":{}}", "unknown op 43"),
    #("{\"op\":99,\"d\":{}}", "unknown op 99"),
    #("{\"op\":-1}", "unknown op -1"),

    // The send-only opcodes are in the table but never arrive, so a gateway
    // that echoed one back reads the same as an opcode we do not know.
    #("{\"op\":2,\"d\":{}}", "unknown op 2"),
    #("{\"op\":6,\"d\":{}}", "unknown op 6"),
    #("{\"op\":8,\"d\":{}}", "unknown op 8"),

    // A dispatch with no sequence leaves every later heartbeat carrying a
    // stale one, which comes back as close 4007 much later.
    #("{\"op\":0,\"d\":{}}", "undecodable: dispatch with no sequence number"),
    #(
      "{\"op\":0,\"s\":null,\"t\":\"READY\",\"d\":{}}",
      "undecodable: dispatch with no sequence number",
    ),
    #(
      "{\"op\":0,\"s\":\"42\",\"t\":\"READY\",\"d\":{}}",
      "undecodable: dispatch with no sequence number",
    ),
    #("{\"op\":0,\"s\":7,\"d\":{}}", "undecodable: dispatch with no event name"),
    #(
      "{\"op\":0,\"s\":7,\"t\":null,\"d\":{}}",
      "undecodable: dispatch with no event name",
    ),
    #(
      "{\"op\":10,\"d\":{}}",
      "undecodable: hello with an unreadable heartbeat_interval",
    ),
    #(
      "{\"op\":10,\"d\":null}",
      "undecodable: hello with an unreadable heartbeat_interval",
    ),
    #("{\"op\":10}", "undecodable: hello with an unreadable heartbeat_interval"),

    // JSON with no envelope in it. Not all of these are a missing `op`: two
    // are not objects at all and one spells the opcode as a string, so the
    // reason has to be the one thing true of every row.
    #("{\"d\":{},\"s\":1}", "undecodable: bad envelope"),
    #("{\"op\":\"10\"}", "undecodable: bad envelope"),
    #("{}", "undecodable: bad envelope"),
    #("[1,2,3]", "undecodable: bad envelope"),
    #("5", "undecodable: bad envelope"),
    #("null", "undecodable: bad envelope"),
    #("not json", "undecodable: not JSON"),
    #("", "undecodable: not JSON"),
    #("{\"op\":11", "undecodable: not JSON"),
    #("1006 going away", "undecodable: not JSON"),
  ]
}

pub fn parse_table_test() {
  list.each(frames(), fn(row) {
    let #(text, expected) = row
    assert summary(frame.parse(text)) == expected
  })
}

/// An unparseable frame must not become a dispatch, which would read
/// downstream as a real event.
pub fn nothing_is_ever_fabricated_test() {
  list.each(frames(), fn(row) {
    let #(text, expected) = row
    let dispatched = case frame.parse(text) {
      frame.Dispatch(..) -> True
      _ -> False
    }
    assert dispatched == string.starts_with(expected, "dispatch ")
  })
}

/// The raw `d` survives, so an unknown event is still usable by the host.
pub fn dispatch_keeps_its_payload_test() {
  let assert frame.Dispatch(seq:, name:, data:) =
    frame.parse("{\"op\":0,\"s\":7,\"t\":\"NEW_THING\",\"d\":{\"a\":1}}")
  assert seq == 7
  assert name == "NEW_THING"
  assert decode.run(data, decode.at(["a"], decode.int)) == Ok(1)
}

/// Scanning the raw JSON for `"op":` breaks on a message that quotes one.
pub fn message_content_cannot_forge_an_opcode_test() {
  let assert frame.Dispatch(seq:, name:, data:) =
    frame.parse(
      "{\"op\":0,\"s\":1,\"t\":\"MESSAGE_CREATE\","
      <> "\"d\":{\"content\":\"\\\"op\\\":9\"}}",
    )
  assert seq == 1
  assert name == "MESSAGE_CREATE"
  assert decode.run(data, decode.at(["content"], decode.string))
    == Ok("\"op\":9")
}

/// Discord adds undocumented fields at any time.
pub fn unknown_keys_are_ignored_test() {
  assert frame.parse("{\"op\":11,\"_trace\":[\"x\"],\"future\":1}")
    == frame.HeartbeatAck
  assert frame.parse("{\"op\":9,\"d\":true,\"why\":\"because\"}")
    == frame.InvalidSession(resumable: True)
}

/// Guessing resumable on an unreadable `d` earns another op 9 and loops at
/// one connection setup per turn. Guessing the other way costs one IDENTIFY.
pub fn invalid_session_defaults_to_gone_test() {
  let table = [
    "{\"op\":9,\"d\":false}", "{\"op\":9,\"d\":null}", "{\"op\":9}",
    "{\"op\":9,\"d\":0}", "{\"op\":9,\"d\":\"true\"}", "{\"op\":9,\"d\":{}}",
  ]
  list.each(table, fn(text) {
    assert frame.parse(text) == frame.InvalidSession(resumable: False)
  })
  assert frame.parse("{\"op\":9,\"d\":true}")
    == frame.InvalidSession(resumable: True)
}

/// A zero interval would arm a repeating timer with no delay, and an interval
/// past ten minutes is past every timer a shard arms.
pub fn heartbeat_interval_is_clamped_test() {
  let table = [
    #("0", 1000),
    #("1", 1000),
    #("999", 1000),
    #("-41250", 1000),
    #("1000", 1000),
    #("41250", 41_250),
    #("45000", 45_000),
    #("600000", 600_000),
    #("600001", 600_000),
    #("99999999", 600_000),
  ]
  list.each(table, fn(row) {
    let #(literal, expected) = row
    let text = "{\"op\":10,\"d\":{\"heartbeat_interval\":" <> literal <> "}}"
    let assert frame.Hello(interval) = frame.parse(text)
    assert frame.heartbeat_interval_ms(interval) == expected
  })
}

/// Discord writes the interval as `45000` and as `45000.0`.
pub fn heartbeat_interval_accepts_a_whole_float_test() {
  let whole = ["41250.0", "4.125e4"]
  list.each(whole, fn(literal) {
    let text = "{\"op\":10,\"d\":{\"heartbeat_interval\":" <> literal <> "}}"
    let assert frame.Hello(interval) = frame.parse(text)
    assert frame.heartbeat_interval_ms(interval) == 41_250
  })
  assert frame.parse("{\"op\":10,\"d\":{\"heartbeat_interval\":1.5}}")
    == frame.Undecodable(frame.HelloIntervalUnreadable)
}

fn identity() -> identify.Identity {
  identify.Identity(
    token: token.new("a.b.c"),
    intents: intents.new([intents.Guilds, intents.GuildMessages]),
    properties: identify.Properties(
      os: "erlang",
      browser: "glyde",
      device: "glyde",
    ),
    large_threshold: identify.large_threshold(50),
    shard: identify.unsharded(),
    presence: None,
  )
}

pub fn identify_test() {
  assert frame.outbound_text(identify.identify(identity()))
    == "{\"op\":2,\"d\":{\"token\":\"a.b.c\",\"properties\":{\"os\":\"erlang\","
    <> "\"browser\":\"glyde\",\"device\":\"glyde\"},\"compress\":false,"
    <> "\"large_threshold\":50,\"shard\":[0,1],\"intents\":513}}"
}

/// The presence object is the same shape op 3 sends, through the same encoder.
pub fn identify_carries_a_presence_test() {
  let shown =
    presence.Presence(status: presence.Idle(None), activities: [], afk: True)
  let payload =
    frame.outbound_text(identify.identify(
      identify.Identity(..identity(), presence: Some(shown)),
    ))
  assert string.contains(
    payload,
    "\"presence\":{\"since\":null,\"activities\":[],\"status\":\"idle\","
      <> "\"afk\":true}",
  )
}

/// Discord reads `"presence": null` as malformed and answers with close 4002.
pub fn identify_omits_an_unset_presence_test() {
  let payload = frame.outbound_text(identify.identify(identity()))
  assert string.contains(payload, "presence") == False
  assert string.contains(payload, "null") == False
}

/// `intents` has no default, so dropping a zero produces an IDENTIFY the
/// gateway refuses.
pub fn identify_sends_zero_intents_test() {
  let payload =
    frame.outbound_text(identify.identify(
      identify.Identity(..identity(), intents: intents.none()),
    ))
  assert string.contains(payload, "\"intents\":0")
}

/// The `$os` spelling is deprecated, and all three properties are required.
pub fn identify_properties_are_unprefixed_test() {
  let payload = frame.outbound_text(identify.identify(identity()))
  assert string.contains(payload, "$") == False
  assert string.contains(
    payload,
    "\"properties\":{\"os\":\"erlang\",\"browser\":\"glyde\","
      <> "\"device\":\"glyde\"}",
  )
}

/// Two ints in an array, index first. The wrong shape, or the two the wrong
/// way round, is close 4010, which is fatal.
pub fn identify_shard_is_a_two_element_array_test() {
  let assert Ok(fleet) = identify.sharding(index: 2, count: 4)
  let payload =
    frame.outbound_text(identify.identify(
      identify.Identity(..identity(), shard: fleet),
    ))
  assert string.contains(payload, "\"shard\":[2,4]")
}

/// A fleet the gateway would answer with close 4010 cannot be built, so no
/// IDENTIFY can carry one.
pub fn a_shard_outside_its_fleet_cannot_be_built_test() {
  let assert Ok(_) = identify.sharding(index: 0, count: 1)
  let assert Ok(_) = identify.sharding(index: 15, count: 16)

  assert identify.sharding(index: 16, count: 16)
    == Error(identify.IndexOutOfRange(index: 16, count: 16))
  assert identify.sharding(index: -1, count: 16)
    == Error(identify.IndexOutOfRange(index: -1, count: 16))
  assert identify.sharding(index: 0, count: 0)
    == Error(identify.EmptyFleet(count: 0))

  assert identify.shard_index(identify.unsharded()) == 0
  assert identify.shard_count(identify.unsharded()) == 1
}

/// Discord's legal range is 50 to 250, and outside it IDENTIFY is refused.
/// Clamped where the value is built, so nothing downstream can hold one that
/// is out of range.
pub fn large_threshold_is_clamped_test() {
  let table = [#(0, 50), #(49, 50), #(50, 50), #(250, 250), #(251, 250)]
  list.each(table, fn(row) {
    let #(configured, expected) = row
    let threshold = identify.large_threshold(configured)
    assert identify.large_threshold_value(threshold) == expected

    let payload =
      frame.outbound_text(identify.identify(
        identify.Identity(..identity(), large_threshold: threshold),
      ))
    assert string.contains(
      payload,
      "\"large_threshold\":" <> int.to_string(expected),
    )
  })
}

/// The field is `seq`: sending `s` reads as a missing sequence and comes back
/// as close 4007.
pub fn resume_test() {
  let payload =
    frame.outbound_text(frame.resume(
      token: token.new("a.b.c"),
      session_id: "abc",
      seq: 1337,
    ))
  assert payload
    == "{\"op\":6,\"d\":{\"token\":\"a.b.c\",\"session_id\":\"abc\","
    <> "\"seq\":1337}}"
  assert inner_keys_of(payload) == ["seq", "session_id", "token"]
}

/// Sequence 0 is legal, so "none yet" is null. Sending 0 earns an op 9.
pub fn heartbeat_test() {
  let table = [
    #(None, "{\"op\":1,\"d\":null}"),
    #(Some(0), "{\"op\":1,\"d\":0}"),
    #(Some(251), "{\"op\":1,\"d\":251}"),
  ]
  list.each(table, fn(row) {
    let #(seq, expected) = row
    assert frame.outbound_text(frame.heartbeat(seq)) == expected
  })
}

fn keys_of(payload: String) -> List(String) {
  let assert Ok(fields) =
    json.parse(payload, decode.dict(decode.string, decode.dynamic))
  fields |> dict.keys |> list.sort(string.compare)
}

fn inner_keys_of(payload: String) -> List(String) {
  let assert Ok(fields) =
    json.parse(
      payload,
      decode.at(["d"], decode.dict(decode.string, decode.dynamic)),
    )
  fields |> dict.keys |> list.sort(string.compare)
}

/// `s` and `t` are receive only, and the `op` on the wire is the one the
/// frame says it is: the two come from the same table, so nothing downstream
/// has to read the opcode back out of the text.
pub fn outbound_frames_carry_only_op_and_d_test() {
  let payloads = [
    identify.identify(identity()),
    frame.resume(token: token.new("a.b.c"), session_id: "abc", seq: 1337),
    frame.heartbeat(None),
    frame.heartbeat(Some(7)),
  ]
  list.each(payloads, fn(payload) {
    assert keys_of(frame.outbound_text(payload)) == ["d", "op"]
    let assert Ok(written) =
      json.parse(frame.outbound_text(payload), decode.at(["op"], decode.int))
    assert written == frame.send_op_to_int(frame.outbound_op(payload))
  })
}

/// Discord's numbers, and the two directions agree. A send side that spelled
/// one of these differently from the receive side would be a session that
/// dies on a frame nobody can explain.
pub fn opcode_table_test() {
  let table = [
    #(frame.OpDispatch, 0),
    #(frame.OpHeartbeat, 1),
    #(frame.OpIdentify, 2),
    #(frame.OpPresenceUpdate, 3),
    #(frame.OpVoiceStateUpdate, 4),
    #(frame.OpResume, 6),
    #(frame.OpReconnect, 7),
    #(frame.OpRequestGuildMembers, 8),
    #(frame.OpInvalidSession, 9),
    #(frame.OpHello, 10),
    #(frame.OpHeartbeatAck, 11),
  ]
  list.each(table, fn(row) {
    let #(op, number) = row
    assert frame.opcode_to_int(op) == number
    assert frame.opcode_from_int(number) == Some(op)
  })

  // 5 was Voice Server Ping and Discord removed it.
  assert frame.opcode_from_int(5) == None
  assert frame.opcode_from_int(12) == None
  assert frame.opcode_from_int(-1) == None
}
