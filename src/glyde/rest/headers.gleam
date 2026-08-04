//// Reading Discord's rate-limit headers, purely.
////
//// Deadlines come from the relative `x-ratelimit-reset-after`, never the
//// absolute `x-ratelimit-reset`, which is wrong by our clock's drift.
////
//// Every counter is an `Option`: a header that did not arrive has to stay
//// distinguishable from one that arrived as zero.

import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/http.{type Header}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import glyde/rest/limiter.{GlobalScope, SharedScope, UserScope}
import glyde/wire

/// Whose fault the 429 was, resolved. Only `resolve_scope` answers this, and
/// `glyde/rest/error` asks it through the same function, so the two cannot
/// disagree about a response. The limiter's own type, so handing a reading
/// over costs nothing.
pub type Scope =
  limiter.Scope

/// What `x-ratelimit-scope` said, before anything is made of it. Kept apart
/// from `Scope` so an unresolved reading cannot be passed off as the answer.
pub type ScopeHeader {
  Named(Scope)

  /// A value Discord has never documented, kept as sent. It names no rule we
  /// know, so on its own it decides nothing.
  Unnamed(String)

  Missing
}

/// What the 429's body added. A body in Discord's rate-limit shape proves
/// Discord answered, which rules out a block in front of it.
pub type BodyEvidence {
  RateLimitBody(global: Bool)

  /// An HTML block page, an empty body, or a caller holding only headers.
  NoBody
}

/// What one response said about a bucket, in the limiter's own shape so the
/// crossing is a hand-over and not a copy. Build it as `limiter.Counters`.
pub type RateLimit =
  limiter.Counters

/// What one response taught us.
pub type Outcome {
  /// A response carrying the usual `x-ratelimit-*` headers.
  Learned(RateLimit)

  Throttled(retry_after_ms: Int, scope: Scope, bucket: Option(String))

  /// A refusal that spends the invalid-request budget. Named and not a status,
  /// so no other status can be counted against it.
  Rejected(why: RejectedWhy)

  /// Anything else, including transport failure. Frees the bucket and teaches
  /// the limiter nothing.
  Opaque
}

/// The two statuses Discord counts against the invalid-request budget: 401 and
/// 403.
pub type RejectedWhy {
  Unauthorized
  Forbidden
}

/// Our own number, for a 429 carrying neither the `retry-after` header nor the
/// body field.
pub const fallback_retry_ms: Int = 5000

/// 2^53 - 1, the ceiling `wire.integer` puts on a decoded number. No host
/// can arm a timer past it, so a bigger number reads as unreadable.
const max_exact: Int = 9_007_199_254_740_991

const max_exact_float: Float = 9_007_199_254_740_991.0

/// Classify one response. Total: anything unparseable degrades to "learned
/// nothing". `body` is read only on a 429; pass `""` for the rest.
pub fn outcome(
  status status: Int,
  headers headers: List(Header),
  body body: String,
) -> Outcome {
  case status {
    429 -> throttled(headers, body)

    // Both count against the invalid-request budget.
    401 -> Rejected(Unauthorized)
    403 -> Rejected(Forbidden)

    _ ->
      case rate_limit(headers) {
        Some(rate) -> Learned(rate)
        None -> Opaque
      }
  }
}

/// What `limiter.Settled` takes. The limiter is a pure state machine with no
/// idea what a header is, so the crossing lives here, on the wire side.
pub fn to_limiter_outcome(outcome: Outcome) -> limiter.Outcome {
  case outcome {
    Learned(rate) -> limiter.Learned(rate)
    Throttled(retry_after_ms:, scope:, bucket:) ->
      limiter.Throttled(retry_after_ms:, scope:, bucket:)
    Rejected(why:) -> limiter.Rejected(status: rejected_status(why))
    Opaque -> limiter.Opaque
  }
}

/// The status Discord sent. The limiter only counts the refusal, so this is
/// for a host reading the outcome back.
pub fn rejected_status(why: RejectedWhy) -> Int {
  case why {
    Unauthorized -> 401
    Forbidden -> 403
  }
}

/// Seconds to milliseconds, rounding up, because waking early costs a 429.
/// Read as decimal text, so `"0.1"` is exactly 100 ms. A negative value is 0.
pub fn seconds_to_ms(raw: String) -> Result(Int, Nil) {
  let text = string.trim(raw)
  case string.starts_with(text, "-") {
    True -> string.drop_start(text, 1) |> positive_ms |> result.replace(0)
    False -> positive_ms(text)
  }
}

fn positive_ms(text: String) -> Result(Int, Nil) {
  case string.split_once(text, ".") {
    Error(_) -> {
      use seconds <- result.try(int.parse(text))
      exact(seconds * 1000)
    }
    Ok(#(whole, fraction)) -> {
      use seconds <- result.try(seconds_part(whole))
      use millis <- result.try(millis_part(fraction))
      exact(seconds * 1000 + millis)
    }
  }
}

/// A number past `max_exact` is one the two targets no longer agree about, so
/// it is worth as little as a header of "potato".
fn exact(value: Int) -> Result(Int, Nil) {
  case value <= max_exact && value >= -max_exact {
    True -> Ok(value)
    False -> Error(Nil)
  }
}

/// The part before the point, which is empty in `".5"`.
fn seconds_part(text: String) -> Result(Int, Nil) {
  case text {
    "" -> Ok(0)
    _ -> int.parse(text)
  }
}

/// The part after the point, as whole milliseconds rounded up. Anything past
/// the third digit is a fraction of a millisecond and adds one.
fn millis_part(text: String) -> Result(Int, Nil) {
  case list.all(string.to_graphemes(text), is_digit) {
    False -> Error(Nil)
    True -> {
      let millis =
        string.slice(text, at_index: 0, length: 3)
        |> string.pad_end(to: 3, with: "0")
        |> int.parse
        |> result.unwrap(0)
      case
        string.drop_start(text, 3) |> string.to_graphemes |> list.any(nonzero)
      {
        True -> Ok(millis + 1)
        False -> Ok(millis)
      }
    }
  }
}

fn is_digit(grapheme: String) -> Bool {
  case grapheme {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}

fn nonzero(grapheme: String) -> Bool {
  grapheme != "0"
}

/// `None` when no counter arrived at all, which is not the same as a bucket
/// with nothing left in it.
fn rate_limit(headers: List(Header)) -> Option(RateLimit) {
  let rate =
    limiter.Counters(
      bucket: header(headers, "x-ratelimit-bucket"),
      limit: whole_number(headers, "x-ratelimit-limit"),
      // Discord has been seen to send a negative count. Same as none left.
      remaining: whole_number(headers, "x-ratelimit-remaining")
        |> option.map(int.max(_, 0)),
      reset_after_ms: delay(headers, "x-ratelimit-reset-after"),
    )

  case rate {
    limiter.Counters(None, None, None, None) -> None
    _ -> Some(rate)
  }
}

fn throttled(headers: List(Header), body: String) -> Outcome {
  let #(said_wait, said) = read_body(body)
  Throttled(
    retry_after_ms: wait(headers, said_wait),
    scope: resolve_scope(headers, said),
    bucket: header(headers, "x-ratelimit-bucket"),
  )
}

/// The 429 body, read once: the wait it names, in milliseconds, and whether it
/// called the limit global.
fn read_body(body: String) -> #(Option(Int), BodyEvidence) {
  case json.parse(body, rate_limit_body()) {
    Ok(#(seconds, global)) -> #(millis(seconds), RateLimitBody(global:))
    // Not Discord's rate-limit shape: an HTML block page, an empty body.
    Error(_) -> #(None, NoBody)
  }
}

/// The longer of `retry-after` and the body's `retry_after`. Never
/// `x-ratelimit-reset-after`: that is the bucket's window, not this 429's wait,
/// and Discord's own shared-limit example has them 22 minutes apart.
fn wait(headers: List(Header), from_body: Option(Int)) -> Int {
  case delay(headers, "retry-after"), from_body {
    Some(from_header), Some(from_body) -> int.max(from_header, from_body)
    Some(ms), None | None, Some(ms) -> ms
    None, None -> fallback_retry_ms
  }
}

/// Whole milliseconds, rounding up like the header path: waking early costs a
/// 429. A wait past `max_exact` is one no host can arm, so it counts as absent
/// and the caller falls back.
fn millis(seconds: Float) -> Option(Int) {
  let ms = seconds *. 1000.0
  case seconds <=. 0.0, ms >. max_exact_float {
    True, _ -> Some(0)
    _, True -> None
    _, _ -> Some(float.round(float.ceiling(ms)))
  }
}

/// `global` is absent from a 429 body that names a resource limit, and Discord
/// only ever writes it as `false` there.
fn rate_limit_body() -> Decoder(#(Float, Bool)) {
  use retry_after <- decode.field("retry_after", wire.number())
  use global <- decode.optional_field("global", False, decode.bool)
  decode.success(#(retry_after, global))
}

/// What `x-ratelimit-scope` said, unresolved. `resolve_scope` is what turns it
/// into an answer.
pub fn scope_header(headers: List(Header)) -> ScopeHeader {
  case header(headers, "x-ratelimit-scope") {
    Some("user") -> Named(UserScope)
    Some("shared") -> Named(SharedScope)
    Some("global") -> Named(GlobalScope)
    Some(other) -> Unnamed(other)
    None -> Missing
  }
}

/// Whose fault a 429 was, from everything the response says. The one
/// classifier: `glyde/rest/error` resolves the same 429 through this, so no
/// response can be a route limit to one reader and a global limit to the other.
pub fn resolve_scope(headers: List(Header), body: BodyEvidence) -> Scope {
  case scope_header(headers) {
    Named(named) -> named

    // A scope we cannot name tells us as little as an absent one, so both
    // fall through to the rest of the ladder.
    Unnamed(_) | Missing ->
      case
        body,
        header(headers, "x-ratelimit-global"),
        header(headers, "x-ratelimit-bucket")
      {
        RateLimitBody(global: True), _, _ -> GlobalScope
        _, Some("true"), _ -> GlobalScope

        // Nothing from Discord at all: the 429 came from in front of it, a
        // Cloudflare block, which stops everything.
        NoBody, None, None -> GlobalScope

        _, _, _ -> UserScope
      }
  }
}

fn whole_number(headers: List(Header), name: String) -> Option(Int) {
  use raw <- option.then(header(headers, name))
  string.trim(raw)
  |> int.parse
  |> result.try(exact)
  |> option.from_result
}

fn delay(headers: List(Header), name: String) -> Option(Int) {
  use raw <- option.then(header(headers, name))
  seconds_to_ms(raw) |> option.from_result
}

/// One header by name, `None` when it did not arrive. Adapters hand names over
/// in any case, so `name` must be lowercase.
pub fn header(headers: List(Header), name: String) -> Option(String) {
  case list.find(headers, fn(pair) { string.lowercase(pair.0) == name }) {
    Ok(#(_, value)) -> Some(value)
    Error(_) -> None
  }
}
