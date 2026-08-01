//// The REST limiter's rules, written from Discord's rate-limit documentation
//// rather than from the implementation.

import gleam/http
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import glyde/rest/headers.{Learned, Opaque, Rejected, Throttled}
import glyde/rest/limiter.{
  Counters, GlobalScope, Send, SharedScope, Submit, Ticket, UserScope,
}
import glyde/rest/route
import glyde/rest/seg

// Discord documents `retry_after` as fractional seconds and then sends a bare
// integer when the value is whole.

/// Both spellings of a two second wait reach 2000 ms.
pub fn retry_after_accepts_int_and_float_test() {
  assert headers.seconds_to_ms("2") == Ok(2000)
  assert headers.seconds_to_ms("2.5") == Ok(2500)
  assert headers.seconds_to_ms("2.0") == Ok(2000)
}

/// The arithmetic is on the decimal text rather than a float, so no value is
/// off by one.
pub fn fractional_seconds_are_exact_test() {
  let table = [
    #("0.1", 100),
    #("0.01", 10),
    #("0.001", 1),
    #("64.57", 64_570),
    #("1336.57", 1_336_570),
    #("0.75", 750),
    #(".5", 500),
  ]

  list.each(table, fn(row) {
    let #(raw, want) = row
    assert #(raw, headers.seconds_to_ms(raw)) == #(raw, Ok(want))
  })
}

/// Rounding is up: waking early costs a 429, waking late costs a millisecond.
pub fn sub_millisecond_precision_rounds_up_test() {
  assert headers.seconds_to_ms("0.0001") == Ok(1)
  assert headers.seconds_to_ms("1.0005") == Ok(1001)
}

/// A negative delay is a deadline already passed, not an error.
pub fn a_negative_delay_clamps_to_zero_test() {
  assert headers.seconds_to_ms("-1") == Ok(0)
  assert headers.seconds_to_ms("-0.5") == Ok(0)
}

// Never fail a request because a rate-limit header was absent or malformed.

/// A fractional `Retry-After` beside a junk `Remaining` produces a usable
/// outcome, not a failure.
pub fn malformed_headers_never_fail_a_request_test() {
  let out =
    headers.outcome(
      429,
      [
        #("retry-after", "0.75"),
        #("x-ratelimit-remaining", "-"),
        #("x-ratelimit-bucket", "abc"),
      ],
      "",
    )

  let assert Throttled(retry_after_ms:, ..) = out
  assert retry_after_ms == 750
}

/// Garbage in any header leaves the reading total and silent.
pub fn garbage_headers_are_tolerated_test() {
  let junk = [
    #("x-ratelimit-remaining", "potato"),
    #("x-ratelimit-reset-after", ""),
    #("x-ratelimit-limit", "NaN"),
    #("retry-after", "soon"),
    #("x-ratelimit-scope", "sideways"),
  ]

  // Each status must classify without raising.
  list.each([200, 204, 400, 401, 403, 404, 429, 500, 502], fn(status) {
    case headers.outcome(status, junk, "") {
      Learned(_) | Throttled(..) | Rejected(_) | Opaque -> Nil
    }
  })
}

/// A zero wait would retry straight into the same limit.
pub fn an_unparseable_retry_after_never_becomes_zero_test() {
  let assert Throttled(retry_after_ms:, ..) =
    headers.outcome(
      429,
      [#("retry-after", "soon"), #("x-ratelimit-bucket", "b")],
      "",
    )

  assert retry_after_ms > 0
  assert retry_after_ms == headers.fallback_retry_ms
}

/// An adapter hands over whatever casing the server sent.
pub fn header_lookup_is_case_insensitive_test() {
  let lower =
    headers.outcome(
      200,
      [
        #("x-ratelimit-bucket", "abc"),
        #("x-ratelimit-limit", "5"),
        #("x-ratelimit-remaining", "4"),
        #("x-ratelimit-reset-after", "3"),
      ],
      "",
    )
  let mixed =
    headers.outcome(
      200,
      [
        #("X-RateLimit-Bucket", "abc"),
        #("X-RateLimit-Limit", "5"),
        #("X-RateLimit-Remaining", "4"),
        #("X-RateLimit-Reset-After", "3"),
      ],
      "",
    )
  let shouty =
    headers.outcome(
      200,
      [
        #("X-RATELIMIT-BUCKET", "abc"),
        #("X-RATELIMIT-LIMIT", "5"),
        #("X-RATELIMIT-REMAINING", "4"),
        #("X-RATELIMIT-RESET-AFTER", "3"),
      ],
      "",
    )

  assert lower == mixed
  assert lower == shouty
  assert lower
    == Learned(Counters(
      bucket: Some("abc"),
      limit: Some(5),
      remaining: Some(4),
      reset_after_ms: Some(3000),
    ))
}

// A shared 429 belongs to somebody else's traffic and must not poison our
// bucket or our invalid-request budget.

/// Each scope Discord documents is recognised.
pub fn scope_is_read_from_the_header_test() {
  let table = [
    #("user", UserScope),
    #("shared", SharedScope),
    #("global", GlobalScope),
  ]

  list.each(table, fn(row) {
    let #(raw, want) = row
    let assert Throttled(scope:, ..) =
      headers.outcome(
        429,
        [
          #("x-ratelimit-scope", raw),
          #("x-ratelimit-bucket", "b"),
          #("retry-after", "1"),
        ],
        "",
      )
    assert #(raw, scope) == #(raw, want)
  })
}

/// Discord's shared-scope example: header and body agree at ~1337 seconds
/// while `reset-after` describes a healthy bucket 22 minutes earlier.
pub fn the_documented_shared_example_waits_on_retry_after_test() {
  let assert Throttled(retry_after_ms:, scope:, ..) =
    headers.outcome(
      429,
      [
        #("retry-after", "1337"),
        #("x-ratelimit-scope", "shared"),
        #("x-ratelimit-bucket", "abcd1234"),
        #("x-ratelimit-reset-after", "64.57"),
      ],
      "",
    )

  assert scope == SharedScope
  assert retry_after_ms == 1_337_000
}

/// A global 429 carries none of the bucket headers at all.
pub fn a_global_429_carries_no_bucket_headers_test() {
  let assert Throttled(retry_after_ms:, scope:, bucket:) =
    headers.outcome(
      429,
      [
        #("retry-after", "2"),
        #("x-ratelimit-global", "true"),
        #("x-ratelimit-scope", "global"),
      ],
      "",
    )

  assert scope == GlobalScope
  assert bucket == None
  assert retry_after_ms == 2000
}

/// A 429 with none of Discord's rate-limit headers is a Cloudflare block, and
/// calling it a user limit sends every other bucket into the ban.
pub fn a_headerless_429_is_not_a_user_limit_test() {
  let assert Throttled(scope:, ..) = headers.outcome(429, [], "")

  assert scope == GlobalScope
}

/// 401 and 403 spend the budget that ends in an IP-wide ban.
pub fn status_401_and_403_are_reported_as_rejections_test() {
  assert headers.outcome(401, [], "") == Rejected(headers.Unauthorized)
  assert headers.outcome(403, [], "") == Rejected(headers.Forbidden)
}

/// Counting a 404 would exhaust the budget on ordinary missing-resource
/// traffic.
pub fn a_404_is_not_a_rejection_test() {
  case headers.outcome(404, [], "") {
    Rejected(_) -> panic as "404 must not count as an invalid request"
    _ -> Nil
  }
}

/// Nothing is known about a never-seen route, so nothing gates it.
pub fn a_cold_route_sends_immediately_test() {
  let #(_, out) =
    limiter.step(
      limiter.new(limiter.defaults()),
      now_ms: 0,
      input: Submit(Ticket(1), messages("111111111111111111")),
    )

  assert list.contains(out, Send(Ticket(1)))
}

/// Until Discord answers there is no way to know the bucket allows two.
pub fn a_cold_route_probes_with_exactly_one_request_test() {
  let route = messages("111111111111111111")
  let state = limiter.new(limiter.defaults())
  let #(state, first) =
    limiter.step(state, now_ms: 0, input: Submit(Ticket(1), route))
  let #(_, second) =
    limiter.step(state, now_ms: 0, input: Submit(Ticket(2), route))

  assert list.contains(first, Send(Ticket(1)))
  assert !list.contains(second, Send(Ticket(2)))
}

/// The limit belongs to the endpoint shape, and the token appears nowhere in
/// it.
pub fn the_bucket_route_string_holds_no_webhook_token_test() {
  let token = "SUPERSECRETWEBHOOKTOKEN"
  let one =
    seg.from_path(
      http.Post,
      "/webhooks/111111111111111111/" <> token,
      route.NoSublimit,
    )
  let two =
    seg.from_path(
      http.Post,
      "/webhooks/111111111111111111/BBB",
      route.NoSublimit,
    )

  assert route.route_key(one, now_ms: 0) == route.route_key(two, now_ms: 0)
  assert !string.contains(does: route.route_key(one, now_ms: 0), contain: token)
}

/// Discord makes `webhook_id + webhook_token` the major parameter, so two
/// tokens are two separate limits.
pub fn the_major_parameter_separates_two_tokens_test() {
  let one =
    seg.from_path(
      http.Post,
      "/webhooks/111111111111111111/AAA",
      route.NoSublimit,
    )
  let two =
    seg.from_path(
      http.Post,
      "/webhooks/111111111111111111/BBB",
      route.NoSublimit,
    )

  assert route.major_key(one) != route.major_key(two)
}

/// The route key ignores the query string and distinguishes the method.
pub fn route_keys_ignore_query_and_split_on_method_test() {
  let plain =
    seg.from_path(http.Get, "/channels/111/messages", route.NoSublimit)
  let queried =
    seg.from_path(http.Get, "/channels/111/messages?limit=50", route.NoSublimit)
  let posted =
    seg.from_path(http.Post, "/channels/111/messages", route.NoSublimit)

  assert route.key(plain, now_ms: 0) == route.key(queried, now_ms: 0)
  assert route.key(plain, now_ms: 0) != route.key(posted, now_ms: 0)
}

/// Distinct top-level resources must not collide, and the major parameter
/// must separate two channels while a query string does not.
pub fn cold_start_keys_partition_correctly_test() {
  let keys =
    list.map(
      [
        seg.from_path(http.Get, "/users/@me", route.NoSublimit),
        seg.from_path(http.Post, "/applications/111/commands", route.NoSublimit),
        seg.from_path(http.Get, "/invites/abc", route.NoSublimit),
        seg.from_path(http.Post, "/channels/111/messages", route.NoSublimit),
        seg.from_path(http.Post, "/channels/222/messages", route.NoSublimit),
      ],
      route.key(_, now_ms: 0),
    )

  assert list.length(list.unique(keys)) == 5
}

// Learning is never gated on `x-ratelimit-bucket`: Discord calls the whole
// `x-ratelimit-*` family optional and its own global-429 example carries none.

/// A response with counters and no bucket hash still teaches both.
pub fn learning_is_not_gated_on_the_bucket_header_test() {
  let out =
    headers.outcome(
      200,
      [#("x-ratelimit-remaining", "0"), #("x-ratelimit-reset-after", "30")],
      "",
    )

  case out {
    Learned(rate) -> {
      assert rate.remaining == Some(0)
      assert rate.reset_after_ms == Some(30_000)
    }
    _ ->
      panic as "remaining and reset-after must be learned without a bucket header"
  }
}

/// A default would make an invented value indistinguishable from one Discord
/// sent.
pub fn absent_counters_are_absent_not_defaults_test() {
  assert headers.outcome(200, [#("x-ratelimit-bucket", "h")], "")
    == Learned(Counters(
      bucket: Some("h"),
      limit: None,
      remaining: None,
      reset_after_ms: None,
    ))
}

/// With no readable counter there is nothing to write over what was known.
pub fn a_response_with_no_counters_teaches_nothing_test() {
  assert headers.outcome(200, [], "") == Opaque
  assert headers.outcome(
      200,
      [#("x-ratelimit-limit", "potato"), #("x-ratelimit-reset-after", "")],
      "",
    )
    == Opaque
}

/// A response with no bucket hash still closes the bucket, so the next call
/// waits instead of walking into the limit it was just told about.
pub fn a_bucket_less_response_still_gates_the_next_call_test() {
  let on = messages("111111111111111111")
  let #(state, _) =
    limiter.step(
      limiter.new(limiter.defaults()),
      now_ms: 0,
      input: Submit(Ticket(1), on),
    )
  let #(state, _) =
    limiter.step(
      state,
      now_ms: 0,
      input: limiter.Settled(
        Ticket(1),
        headers.to_limiter_outcome(headers.outcome(
          200,
          [#("x-ratelimit-remaining", "0"), #("x-ratelimit-reset-after", "30")],
          "",
        )),
      ),
    )

  let #(_, out) = limiter.step(state, now_ms: 1, input: Submit(Ticket(2), on))
  assert !list.contains(out, Send(Ticket(2)))
  assert list.contains(out, limiter.Wake(29_999))
}

/// A later response carrying the hash and no counters must leave the count and
/// the deadline where they stood rather than hand the quota back.
pub fn a_counter_less_response_does_not_reopen_a_closed_bucket_test() {
  let on = messages("111111111111111111")
  let settled = fn(state, at, ticket, sent) {
    let #(state, _) =
      limiter.step(
        state,
        now_ms: at,
        input: limiter.Settled(
          ticket,
          headers.to_limiter_outcome(headers.outcome(200, sent, "")),
        ),
      )
    state
  }
  let submitted = fn(state, at, ticket) {
    let #(state, _) = limiter.step(state, now_ms: at, input: Submit(ticket, on))
    state
  }

  // A healthy bucket with two calls out at once, so the second response lands
  // on a bucket the first has already closed.
  let state = submitted(limiter.new(limiter.defaults()), 0, Ticket(1))
  let state =
    settled(state, 0, Ticket(1), [
      #("x-ratelimit-bucket", "h"),
      #("x-ratelimit-limit", "5"),
      #("x-ratelimit-remaining", "5"),
      #("x-ratelimit-reset-after", "30"),
    ])
  let state = submitted(state, 1, Ticket(2))
  let state = submitted(state, 1, Ticket(3))
  let state =
    settled(state, 2, Ticket(2), [
      #("x-ratelimit-bucket", "h"),
      #("x-ratelimit-remaining", "0"),
      #("x-ratelimit-reset-after", "30"),
    ])
  let state = settled(state, 3, Ticket(3), [#("x-ratelimit-bucket", "h")])

  let #(_, out) = limiter.step(state, now_ms: 4, input: Submit(Ticket(4), on))
  assert !list.contains(out, Send(Ticket(4)))
  assert list.contains(out, limiter.Wake(29_998))
}

// On a 429 the wait is the longer of the body's `retry_after` and the
// `Retry-After` header, and never `x-ratelimit-reset-after`.

/// With no other source the module's own fallback stands.
pub fn reset_after_is_never_a_429_wait_test() {
  let assert Throttled(retry_after_ms:, ..) =
    headers.outcome(
      429,
      [
        #("x-ratelimit-bucket", "b"),
        #("x-ratelimit-scope", "user"),
        #("x-ratelimit-reset-after", "64.57"),
      ],
      "",
    )

  assert retry_after_ms != 64_570
  assert retry_after_ms == headers.fallback_retry_ms
}

/// The header is the body rounded up, so the longer of the two is safe either
/// way.
pub fn the_429_wait_is_the_longer_of_body_and_header_test() {
  let table = [
    #("65", "{\"retry_after\":64.57}", 65_000),
    #("65", "{\"retry_after\":70}", 70_000),
    #("65", "<html>a block page, not Discord</html>", 65_000),
  ]

  list.each(table, fn(row) {
    let #(header, body, want) = row
    let assert Throttled(retry_after_ms:, ..) =
      headers.outcome(
        429,
        [#("retry-after", header), #("x-ratelimit-bucket", "b")],
        body,
      )
    assert #(header, body, retry_after_ms) == #(header, body, want)
  })
}

/// The body alone carries the true wait, and the `reset-after` beside it is
/// twenty two minutes short.
pub fn the_body_alone_still_carries_the_wait_test() {
  let assert Throttled(retry_after_ms:, scope:, ..) =
    headers.outcome(
      429,
      [
        #("x-ratelimit-scope", "shared"),
        #("x-ratelimit-bucket", "abcd1234"),
        #("x-ratelimit-reset-after", "64.57"),
      ],
      "{\"message\":\"The resource is being rate limited.\",\"retry_after\":1336.57,\"global\":false}",
    )

  assert scope == SharedScope
  assert retry_after_ms == 1_336_570
}

fn messages(channel: String) -> route.Route {
  seg.from_path(
    http.Post,
    "/channels/" <> channel <> "/messages",
    route.NoSublimit,
  )
}
