//// What the runtime under `glyde.run` reports that is not a Discord event, and
//// the words for it. `glyde.on_status` hands you a `Status`; `describe` is the
//// whole line the default prints, and the smaller functions are its pieces
//// for a handler that formats the rest itself.
////
//// The values a status carries have their words where they live:
//// `gateway.describe_halt`, `gateway.describe_why`, `gateway.describe`,
//// `transport.describe`, `error.describe`. This module owns the one nobody
//// else does, the limiter's notices.

import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/option.{None, Some}
import glyde/gateway
import glyde/gateway/frame
import glyde/internal/decode_error
import glyde/rest/limiter

/// Everything the runtime does that is not a Discord event. Every variant
/// carries the value, never a rendering: `describe` is the only way back.
pub type Status {
  Connecting(host: String)
  /// The connection is gone and a redial is armed. `why` is what ended it, so
  /// a host printing this says more than "the bot is flapping".
  Reconnecting(in_ms: Int, resuming: Bool, why: gateway.Why)
  Halted(reason: gateway.Halt)
  /// A frame went out, by opcode. Never the body: IDENTIFY carries the token.
  Sent(op: frame.SendOp)
  /// A dispatch glyde models whose `d` no longer fits its decoder: a glyde bug
  /// or a Discord schema change. The listeners saw it as `event.Raw`.
  Undecodable(name: String, errors: List(decode.DecodeError))
  /// A diagnostic from the core: a zombie connection, a dropped command, a
  /// frame that would not decode.
  Note(gateway.Notice)
  /// A diagnostic from the rate limiter: a bucket learned, a global freeze,
  /// the invalid-request budget running low.
  Paced(limiter.Notice)
}

/// The default `on_status`, on stderr. `Sent`, `Note`, `Paced` and
/// `Undecodable` are for somebody who went looking, so they are dropped here.
pub fn printing(status: Status) -> Nil {
  case status {
    // `Undecodable` fires once per dispatch, so a schema change to a busy
    // event is a write per event on the loop that owes Discord a heartbeat.
    Sent(_) | Note(_) | Paced(_) | Undecodable(..) -> Nil
    _ -> io.println_error("glyde: " <> describe(status))
  }
}

/// One line per status, for a host that just wants to print them.
pub fn describe(status: Status) -> String {
  case status {
    Connecting(host:) -> "connecting to " <> host
    Reconnecting(in_ms:, resuming:, why:) ->
      "reconnecting in "
      <> int.to_string(in_ms)
      <> "ms, "
      <> case resuming {
        True -> "resuming"
        False -> "fresh identify"
      }
      <> ": "
      <> gateway.describe_why(why)
    Halted(reason:) -> "halted: " <> gateway.describe_halt(reason)
    Sent(op:) -> "sent op " <> int.to_string(frame.send_op_to_int(op))
    Undecodable(name:, errors:) ->
      "could not decode " <> name <> ": " <> decode_error.describe(errors)
    Note(notice) -> "note: " <> gateway.describe(notice)
    Paced(notice) -> "rate limit: " <> describe_pacing(notice)
  }
}

/// The limiter is stdlib only and has no words of its own, so they live here.
pub fn describe_pacing(notice: limiter.Notice) -> String {
  case notice {
    limiter.BucketLearned(route_key:, bucket:) ->
      route_key <> " is bucket " <> bucket
    limiter.GloballyFrozen(for_ms:) ->
      "global limit, nothing goes for " <> int.to_string(for_ms) <> "ms"
    limiter.InvalidBudgetLow(remaining:) ->
      int.to_string(remaining) <> " invalid requests left before a ban"
    limiter.SharedThrottle(bucket:, for_ms:) ->
      case bucket {
        Some(b) ->
          "bucket "
          <> b
          <> " is busy with someone else for "
          <> int.to_string(for_ms)
          <> "ms"
        None ->
          "a shared bucket is busy with someone else for "
          <> int.to_string(for_ms)
          <> "ms"
      }
  }
}
