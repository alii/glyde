//// The frames a scripted Discord sends, as the text a transport hands a
//// shard. Fixtures only: nothing here runs anything or judges an adapter.
////
//// `glyde/testing/adapter` scripts its scenarios out of these, and a test
//// with its own scripted socket can use them without pulling in the
//// conformance suite.
////
//// ```gleam
//// import glyde/testing/frames
////
//// let script = [frames.hello(45_000), frames.ready(1, session, host)]
//// ```

import gleam/json
import glyde/gateway/frame

/// The token every scripted bot identifies with. Not a real one, and it never
/// reaches a socket.
pub const token: String = "scripted.not.a.token"

/// The opcode these fixtures write, from the table the parser reads. A fixture
/// numbered by hand could drift from the parser and still pass.
fn op(op: frame.Opcode) -> json.Json {
  json.int(frame.opcode_to_int(op))
}

/// Op 10. `heartbeat_interval` is clamped to [1000, 600_000] by the core.
pub fn hello(interval_ms: Int) -> String {
  json.to_string(
    json.object([
      #("op", op(frame.OpHello)),
      #("d", json.object([#("heartbeat_interval", json.int(interval_ms))])),
    ]),
  )
}

/// Op 11.
pub fn ack() -> String {
  json.to_string(json.object([#("op", op(frame.OpHeartbeatAck))]))
}

/// Op 1: Discord asking for a heartbeat now rather than at the deadline.
pub fn beat_request() -> String {
  json.to_string(
    json.object([#("op", op(frame.OpHeartbeat)), #("d", json.null())]),
  )
}

/// Op 7: reconnect and resume.
pub fn server_reconnect() -> String {
  json.to_string(json.object([#("op", op(frame.OpReconnect))]))
}

/// Op 9.
pub fn invalid_session(resumable: Bool) -> String {
  json.to_string(
    json.object([
      #("op", op(frame.OpInvalidSession)),
      #("d", json.bool(resumable)),
    ]),
  )
}

/// Op 0 with `t: READY`, carrying the three keys the protocol needs.
pub fn ready(seq: Int, session_id: String, resume_host: String) -> String {
  dispatch(
    "READY",
    seq,
    json.object([
      #("session_id", json.string(session_id)),
      #("resume_gateway_url", json.string("wss://" <> resume_host)),
      #("user", json.object([#("id", json.string("1000000000000000000"))])),
      #("guilds", json.preprocessed_array([])),
    ]),
  )
}

/// Op 0 with `t: RESUMED`.
pub fn resumed(seq: Int) -> String {
  dispatch("RESUMED", seq, json.object([]))
}

/// Op 0. Any dispatch, with the payload you give it.
pub fn dispatch(name: String, seq: Int, data: json.Json) -> String {
  json.to_string(
    json.object([
      #("op", op(frame.OpDispatch)),
      #("t", json.string(name)),
      #("s", json.int(seq)),
      #("d", data),
    ]),
  )
}
