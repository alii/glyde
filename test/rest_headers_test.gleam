import gleam/list
import gleam/option.{None, Some}
import glyde/rest/headers
import glyde/rest/limiter

/// Every spelling Discord and the proxies in front of it send. `"2"` and
/// `"2.5"` both have to parse or a real backoff is lost.
fn seconds_table() -> List(#(String, Result(Int, Nil))) {
  [
    #("2", Ok(2000)),
    #("2.5", Ok(2500)),
    #("0", Ok(0)),
    #("0.0", Ok(0)),
    #("65", Ok(65_000)),
    // From Discord's own 429 example: the header is the body rounded up.
    #("64.57", Ok(64_570)),
    #("1336.57", Ok(1_336_570)),
    #(".5", Ok(500)),
    #("5.", Ok(5000)),
    #(" 2 ", Ok(2000)),
    // Past the third decimal is a fraction of a millisecond, and we round up.
    #("1.0005", Ok(1001)),
    #("1.9999", Ok(2000)),
    #("0.1", Ok(100)),
    // Already expired, not an error.
    #("-1", Ok(0)),
    #("-0.5", Ok(0)),
    #("", Error(Nil)),
    #("-", Error(Nil)),
    #("potato", Error(Nil)),
    // Past 2^53 - 1 milliseconds the two targets stop agreeing on the number
    // and no host can arm a timer for it, so it is worth as little as "potato".
    #("99999999999999999", Error(Nil)),
    #("1.2x", Error(Nil)),
    #("1.2.3", Error(Nil)),
  ]
}

pub fn seconds_to_ms_table_test() {
  list.each(seconds_table(), fn(row) {
    let #(raw, expected) = row
    assert headers.seconds_to_ms(raw) == expected
  })
}

/// A float would make this 101 and never 100.
pub fn tenth_of_a_second_is_exact_test() {
  assert headers.seconds_to_ms("0.1") == Ok(100)
  assert headers.seconds_to_ms("0.3") == Ok(300)
  assert headers.seconds_to_ms("0.7") == Ok(700)
}

fn full_headers() -> List(#(String, String)) {
  [
    #("x-ratelimit-bucket", "abcd1234"),
    #("x-ratelimit-limit", "5"),
    #("x-ratelimit-remaining", "4"),
    #("x-ratelimit-reset-after", "1.5"),
  ]
}

pub fn learns_from_a_normal_response_test() {
  assert headers.outcome(200, full_headers(), "")
    == headers.Learned(limiter.Counters(
      bucket: Some("abcd1234"),
      limit: Some(5),
      remaining: Some(4),
      reset_after_ms: Some(1500),
    ))
}

/// Adapters disagree about which case they hand a header over in.
pub fn header_names_fold_test() {
  let shouted =
    list.map(full_headers(), fn(pair) {
      let #(name, value) = pair
      #(uppercase(name), value)
    })
  assert headers.outcome(200, shouted, "")
    == headers.outcome(200, full_headers(), "")
}

fn uppercase(name: String) -> String {
  case name {
    "x-ratelimit-bucket" -> "X-RateLimit-Bucket"
    "x-ratelimit-limit" -> "X-RATELIMIT-LIMIT"
    "x-ratelimit-remaining" -> "X-RateLimit-Remaining"
    "x-ratelimit-reset-after" -> "X-RateLimit-Reset-After"
    other -> other
  }
}

/// The absolute header is wrong by however far our clock has drifted.
pub fn absolute_reset_is_never_read_test() {
  assert headers.outcome(
      200,
      [
        #("x-ratelimit-bucket", "abcd1234"),
        #("x-ratelimit-reset", "0"),
        #("x-ratelimit-reset-after", "5"),
      ],
      "",
    )
    == headers.Learned(limiter.Counters(
      bucket: Some("abcd1234"),
      limit: None,
      remaining: None,
      reset_after_ms: Some(5000),
    ))
}

/// A header Discord did not send is absent, not a default: a fabricated value
/// gets written over a bucket Discord had already closed.
pub fn missing_counters_stay_absent_test() {
  assert headers.outcome(200, [#("x-ratelimit-bucket", "h")], "")
    == headers.Learned(limiter.Counters(
      bucket: Some("h"),
      limit: None,
      remaining: None,
      reset_after_ms: None,
    ))
}

/// An unparseable counter is worth as much as an absent one.
pub fn malformed_counters_fall_back_test() {
  assert headers.outcome(
      200,
      [
        #("x-ratelimit-bucket", "h"),
        #("x-ratelimit-limit", "potato"),
        #("x-ratelimit-remaining", "-"),
        #("x-ratelimit-reset-after", ""),
      ],
      "",
    )
    == headers.Learned(limiter.Counters(
      bucket: Some("h"),
      limit: None,
      remaining: None,
      reset_after_ms: None,
    ))
}

/// A counter past 2^53 - 1 counts as absent: no host can arm a timer for it.
pub fn oversized_counters_are_absent_test() {
  assert headers.outcome(
      200,
      [
        #("x-ratelimit-bucket", "h"),
        #("x-ratelimit-limit", "99999999999999999"),
        #("x-ratelimit-remaining", "99999999999999999"),
      ],
      "",
    )
    == headers.Learned(limiter.Counters(
      bucket: Some("h"),
      limit: None,
      remaining: None,
      reset_after_ms: None,
    ))
}

pub fn negative_remaining_clamps_test() {
  let outcome =
    headers.outcome(
      200,
      [#("x-ratelimit-bucket", "h"), #("x-ratelimit-remaining", "-3")],
      "",
    )
  assert outcome
    == headers.Learned(limiter.Counters(
      bucket: Some("h"),
      limit: None,
      remaining: Some(0),
      reset_after_ms: None,
    ))
}

/// The hash is compared, never inspected, and an empty one is still a hash.
pub fn bucket_hash_round_trips_test() {
  assert headers.outcome(200, [#("x-ratelimit-bucket", "")], "")
    == headers.Learned(limiter.Counters(
      bucket: Some(""),
      limit: None,
      remaining: None,
      reset_after_ms: None,
    ))
}

/// Permissive defaults would throw away a known bucket's deadline.
pub fn no_rate_limit_headers_teaches_nothing_test() {
  assert headers.outcome(200, [], "") == headers.Opaque
  assert headers.outcome(200, [#("content-type", "application/json")], "")
    == headers.Opaque
  assert headers.outcome(500, [], "") == headers.Opaque
}

/// The bucket hash names which bucket the counters belong to; it is not
/// permission to read them.
pub fn counters_are_learned_without_a_bucket_hash_test() {
  assert headers.outcome(
      200,
      [#("x-ratelimit-remaining", "0"), #("x-ratelimit-reset-after", "30")],
      "",
    )
    == headers.Learned(limiter.Counters(
      bucket: None,
      limit: None,
      remaining: Some(0),
      reset_after_ms: Some(30_000),
    ))
}

pub fn counters_are_read_independently_test() {
  assert headers.outcome(
      200,
      [
        #("x-ratelimit-limit", "5"),
        #("x-ratelimit-remaining", "potato"),
        #("x-ratelimit-reset-after", "1.5"),
      ],
      "",
    )
    == headers.Learned(limiter.Counters(
      bucket: None,
      limit: Some(5),
      remaining: None,
      reset_after_ms: Some(1500),
    ))
}

/// A 5xx is not a rate limit and still carries counters worth keeping.
pub fn any_status_with_counters_teaches_test() {
  let expected =
    headers.Learned(limiter.Counters(
      bucket: Some("h"),
      limit: None,
      remaining: None,
      reset_after_ms: None,
    ))
  assert headers.outcome(204, [#("x-ratelimit-bucket", "h")], "") == expected
  assert headers.outcome(404, [#("x-ratelimit-bucket", "h")], "") == expected
  assert headers.outcome(500, [#("x-ratelimit-bucket", "h")], "") == expected
}

pub fn rejections_are_their_own_outcome_test() {
  assert headers.outcome(401, full_headers(), "")
    == headers.Rejected(headers.Unauthorized)
  assert headers.outcome(403, full_headers(), "")
    == headers.Rejected(headers.Forbidden)
}

/// The three scopes have different effects, so each is read, not inferred.
fn scope_table() -> List(#(List(#(String, String)), headers.Outcome)) {
  [
    #(
      [
        #("retry-after", "65"),
        #("x-ratelimit-scope", "user"),
        #("x-ratelimit-bucket", "h"),
      ],
      headers.Throttled(65_000, limiter.UserScope, Some("h")),
    ),
    #(
      [
        #("retry-after", "1337"),
        #("x-ratelimit-scope", "shared"),
        #("x-ratelimit-bucket", "h"),
        #("x-ratelimit-reset-after", "64.57"),
      ],
      headers.Throttled(1_337_000, limiter.SharedScope, Some("h")),
    ),
    #(
      [
        #("retry-after", "65"),
        #("x-ratelimit-scope", "global"),
        #("x-ratelimit-global", "true"),
      ],
      headers.Throttled(65_000, limiter.GlobalScope, None),
    ),
    // No scope header, so the body's global flag as Discord mirrors it.
    #(
      [#("retry-after", "65"), #("x-ratelimit-global", "true")],
      headers.Throttled(65_000, limiter.GlobalScope, None),
    ),
    // No scope, but bucket headers present: our own route's limit.
    #(
      [#("retry-after", "1.5"), #("x-ratelimit-bucket", "h")],
      headers.Throttled(1500, limiter.UserScope, Some("h")),
    ),
    // A scope value nobody has documented tells us as little as none at all.
    #(
      [
        #("retry-after", "2"),
        #("x-ratelimit-scope", "moon"),
        #("x-ratelimit-bucket", "h"),
      ],
      headers.Throttled(2000, limiter.UserScope, Some("h")),
    ),
    // Nothing from Discord at all: a block in front of it stops everything.
    #(
      [#("retry-after", "65")],
      headers.Throttled(65_000, limiter.GlobalScope, None),
    ),
    #(
      [],
      headers.Throttled(headers.fallback_retry_ms, limiter.GlobalScope, None),
    ),
  ]
}

pub fn throttle_scope_table_test() {
  list.each(scope_table(), fn(row) {
    let #(sent, expected) = row
    assert headers.outcome(429, sent, "") == expected
  })
}

/// The body's `global` flag is Discord's other way of saying the same thing,
/// so a scope name this build does not know must not talk over it.
pub fn the_body_flag_answers_for_an_unnamed_scope_test() {
  let body =
    "{\"message\":\"rate limited\",\"retry_after\":1.5,\"global\":true}"

  assert headers.outcome(429, [#("x-ratelimit-scope", "moon")], body)
    == headers.Throttled(1500, limiter.GlobalScope, None)

  // A name we do know still wins: Discord said which rule it applied.
  assert headers.outcome(429, [#("x-ratelimit-scope", "user")], body)
    == headers.Throttled(1500, limiter.UserScope, None)
}

/// A body in Discord's rate-limit shape proves Discord answered, which rules
/// out the block in front of it that a bare 429 otherwise reads as.
pub fn a_discord_body_rules_out_a_block_test() {
  assert headers.outcome(429, [], "{\"retry_after\":1.5,\"global\":false}")
    == headers.Throttled(1500, limiter.UserScope, None)

  assert headers.outcome(429, [], "")
    == headers.Throttled(headers.fallback_retry_ms, limiter.GlobalScope, None)
}

/// The scope header is readable on its own, unresolved, so a value Discord has
/// not documented survives as sent instead of becoming an answer.
pub fn the_scope_header_is_readable_unresolved_test() {
  let read = fn(raw) { headers.scope_header([#("X-RateLimit-Scope", raw)]) }

  assert read("user") == headers.Named(limiter.UserScope)
  assert read("shared") == headers.Named(limiter.SharedScope)
  assert read("global") == headers.Named(limiter.GlobalScope)
  assert read("moon") == headers.Unnamed("moon")
  assert headers.scope_header([]) == headers.Missing
}

/// On a 429 the bucket headers are stale: Discord's own example pairs a
/// `reset-after` of 64.57 with a `retry_after` of 1336.57.
pub fn reset_after_is_never_a_429_wait_test() {
  let scopes = ["user", "shared", "global"]

  list.each(scopes, fn(scope) {
    let outcome =
      headers.outcome(
        429,
        [
          #("x-ratelimit-scope", scope),
          #("x-ratelimit-bucket", "h"),
          #("x-ratelimit-reset-after", "64.57"),
        ],
        "",
      )
    let assert headers.Throttled(retry_after_ms:, ..) = outcome
    assert #(scope, retry_after_ms) == #(scope, headers.fallback_retry_ms)
  })
}

/// Discord sends the header as whole seconds rounded up, but a proxy in
/// between may not.
pub fn fractional_retry_after_test() {
  assert headers.outcome(
      429,
      [
        #("retry-after", "1.5"),
        #("x-ratelimit-scope", "user"),
        #("x-ratelimit-bucket", "h"),
      ],
      "",
    )
    == headers.Throttled(1500, limiter.UserScope, Some("h"))
}

/// Where the header and the body disagree the longer one wins: under-waiting a
/// 429 spends the budget that ends in a Cloudflare ban.
fn retry_after_body_table() -> List(#(String, String, Int)) {
  [
    // Discord's own 429 example, header and body together.
    #(
      "65",
      "{\"message\":\"You are being rate limited.\",\"retry_after\":64.57,\"global\":false}",
      65_000,
    ),
    // A body that outlasts its header wins.
    #("65", "{\"retry_after\":70}", 70_000),
    // A body alone is still a delay.
    #("", "{\"retry_after\":2.5}", 2500),
    // JSON has one number type and Discord writes a whole value plainly.
    #("", "{\"retry_after\":2}", 2000),
    // A Cloudflare block page leaves only the header.
    #("65", "<html><title>error</title></html>", 65_000),
    // Neither, so our own number rather than a retry with no delay at all.
    #("", "", headers.fallback_retry_ms),
    #("", "{\"message\":\"nope\"}", headers.fallback_retry_ms),
  ]
}

pub fn retry_after_is_the_longer_of_header_and_body_test() {
  list.each(retry_after_body_table(), fn(row) {
    let #(header, body, want) = row
    let sent = case header {
      "" -> [#("x-ratelimit-scope", "user"), #("x-ratelimit-bucket", "h")]
      _ -> [
        #("retry-after", header),
        #("x-ratelimit-scope", "user"),
        #("x-ratelimit-bucket", "h"),
      ]
    }
    let assert headers.Throttled(retry_after_ms:, ..) =
      headers.outcome(429, sent, body)
    assert #(header, body, retry_after_ms) == #(header, body, want)
  })
}

/// A `retry_after` past what a millisecond count holds exactly counts as
/// absent, and the header stands.
pub fn an_unreadably_large_body_retry_after_falls_back_test() {
  let assert headers.Throttled(retry_after_ms:, ..) =
    headers.outcome(
      429,
      [#("retry-after", "65"), #("x-ratelimit-bucket", "h")],
      "{\"retry_after\":1.0e16}",
    )
  assert retry_after_ms == 65_000
}

pub fn body_retry_after_is_exact_test() {
  let table = [
    #("{\"retry_after\":0.1}", 100),
    #("{\"retry_after\":64.57}", 64_570),
    #("{\"retry_after\":1336.57}", 1_336_570),
    #("{\"retry_after\":0.0}", 0),
    // Rounds up like the header does: waking early costs a 429.
    #("{\"retry_after\":1.0001}", 1001),
    // Already expired, not a negative wait.
    #("{\"retry_after\":-1.5}", 0),
    // A sliver of a millisecond is one millisecond, and 0 stays 0.
    #("{\"retry_after\":0.00001}", 1),
    #("{\"retry_after\":0}", 0),
  ]

  list.each(table, fn(row) {
    let #(body, want) = row
    let assert headers.Throttled(retry_after_ms:, ..) =
      headers.outcome(429, [#("x-ratelimit-bucket", "h")], body)
    assert #(body, retry_after_ms) == #(body, want)
  })
}
