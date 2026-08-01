import gleam/http
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import glyde/rest/headers
import glyde/rest/limiter.{
  type Input, type Limiter, type Limits, type Output, Abandoned, Backlogged,
  BucketLearned, DuplicateTicket, GloballyFrozen, InvalidBudgetLow,
  InvalidBudgetSpent, Limits, Note, Refuse, Retry, Send, Settled, Submit, Tick,
  Ticket, Wake,
}
import glyde/rest/route.{type Route}
import glyde/rest/seg

const channel_a: String = "111111111111111111"

const channel_b: String = "222222222222222222"

const message_id: String = "333333333333333333"

/// One line of a scenario: the clock, one input, and every output allowed.
type Step {
  Step(at: Int, input: Input, expect: List(Output))
}

fn run(state: Limiter, script: List(Step)) -> #(Limiter, List(Output)) {
  list.fold(script, #(state, []), fn(carried, step) {
    let #(state, seen) = carried
    let #(next, out) = limiter.step(state, now_ms: step.at, input: step.input)
    assert out == step.expect as { "step at " <> int.to_string(step.at) }
    #(next, list.append(seen, out))
  })
}

fn sends(out: List(Output)) -> List(Output) {
  list.filter(out, fn(one) {
    case one {
      Send(_) -> True
      _ -> False
    }
  })
}

fn messages(channel: String) -> Route {
  seg.from_path(
    http.Post,
    "/channels/" <> channel <> "/messages",
    route.NoSublimit,
  )
}

fn typing(channel: String) -> Route {
  seg.from_path(
    http.Post,
    "/channels/" <> channel <> "/typing",
    route.NoSublimit,
  )
}

fn callback() -> Route {
  seg.from_path(
    http.Post,
    "/interactions/" <> message_id <> "/tok/callback",
    route.NoSublimit,
  )
}

/// Deleting a message is bucketed by how old the message is, so the route
/// carries when it was created.
fn delete_message(channel: String, created_at_ms: Int) -> Route {
  route.new(
    http.Delete,
    "/channels/"
      <> route.channel_placeholder
      <> "/messages/"
      <> route.id_placeholder,
    route.ChannelMajor(channel),
    route.Aged(created_at_ms),
  )
}

fn learned(
  bucket: String,
  remaining: Int,
  reset_after: String,
) -> limiter.Outcome {
  headers.to_limiter_outcome(headers.outcome(
    200,
    [
      #("x-ratelimit-bucket", bucket),
      #("x-ratelimit-limit", "5"),
      #("x-ratelimit-remaining", int.to_string(remaining)),
      #("x-ratelimit-reset-after", reset_after),
    ],
    "",
  ))
}

fn throttled(scope: String, bucket: String, retry: String) -> limiter.Outcome {
  headers.to_limiter_outcome(headers.outcome(
    429,
    [
      #("retry-after", retry),
      #("x-ratelimit-scope", scope),
      #("x-ratelimit-bucket", bucket),
    ],
    "",
  ))
}

fn global_429(retry: String) -> limiter.Outcome {
  headers.to_limiter_outcome(headers.outcome(
    429,
    [
      #("retry-after", retry),
      #("x-ratelimit-scope", "global"),
      #("x-ratelimit-global", "true"),
    ],
    "",
  ))
}

/// A response carrying no rate-limit headers at all.
fn bare(status: Int) -> limiter.Outcome {
  headers.to_limiter_outcome(headers.outcome(status, [], ""))
}

// Three calls on a cold route, an answer naming a hash that is already live
// and exhausted, then a global 429.
pub fn stress_three_test() {
  let warm = messages(channel_a)
  let cold = typing(channel_a)
  let elsewhere = messages(channel_b)

  let #(_, out) =
    run(limiter.new(limiter.defaults()), [
      // A live bucket for the cold route to collide with.
      Step(0, Submit(Ticket(1), warm), [Send(Ticket(1))]),
      Step(100, Settled(Ticket(1), learned("h1", 4, "10")), [
        Note(BucketLearned(route.route_key(warm, 100), "h1")),
      ]),

      // Exactly one goes: the others cannot attribute the counters coming back.
      Step(200, Submit(Ticket(2), cold), [Send(Ticket(2))]),
      Step(201, Submit(Ticket(3), cold), []),
      Step(202, Submit(Ticket(4), cold), []),

      // The answer names a hash that is already live AND has nothing left, so
      // the two waiting calls arrive into an exhausted bucket.
      Step(300, Settled(Ticket(2), learned("h1", 0, "10")), [
        Note(BucketLearned(route.route_key(cold, 300), "h1")),
        Wake(10_000),
      ]),

      // Another channel is another bucket, so a stall does not starve it.
      Step(400, Submit(Ticket(5), elsewhere), [Send(Ticket(5)), Wake(9900)]),

      // And that one comes back as a global 429.
      Step(500, Settled(Ticket(5), global_429("15")), [
        Note(GloballyFrozen(15_000)),
        Wake(15_000),
      ]),

      // The bucket reset has passed. The freeze has not. Nothing moves.
      Step(11_000, Tick, [Wake(4500)]),

      // Both have passed. The window rolled with no idea what the new quota
      // is, so one probes and the other waits for what it learns.
      Step(15_500, Tick, [Send(Ticket(3))]),
      Step(15_600, Settled(Ticket(3), learned("h1", 4, "10")), [
        Send(Ticket(4)),
      ]),
    ])

  // Every call went exactly once, in this order.
  assert sends(out)
    == [
      Send(Ticket(1)),
      Send(Ticket(2)),
      Send(Ticket(5)),
      Send(Ticket(3)),
      Send(Ticket(4)),
    ]
}

/// Sending both leaves no way to attribute the counters that come back.
pub fn cold_route_sends_one_probe_test() {
  let route = messages(channel_a)
  let #(_, out) =
    run(limiter.new(limiter.defaults()), [
      Step(0, Submit(Ticket(1), route), [Send(Ticket(1))]),
      Step(0, Submit(Ticket(2), route), []),
      Step(0, Submit(Ticket(3), route), []),
      // A probing bucket has no deadline, so only a response releases them.
      Step(1_000_000, Tick, []),
      Step(50, Settled(Ticket(1), learned("h", 5, "10")), [
        Note(BucketLearned(route.route_key(route, 50), "h")),
        Send(Ticket(2)),
        Send(Ticket(3)),
      ]),
    ])
  assert sends(out) == [Send(Ticket(1)), Send(Ticket(2)), Send(Ticket(3))]
}

/// The major parameter gives two channels independent buckets.
pub fn major_parameter_splits_the_bucket_test() {
  let #(_, _) =
    run(limiter.new(limiter.defaults()), [
      Step(0, Submit(Ticket(1), messages(channel_a)), [Send(Ticket(1))]),
      Step(10, Settled(Ticket(1), learned("h", 0, "10")), [
        Note(BucketLearned(route.route_key(messages(channel_a), 10), "h")),
      ]),
      // Same route, same learned hash, different channel: a different bucket.
      Step(20, Submit(Ticket(2), messages(channel_b)), [Send(Ticket(2))]),
      // Same channel: waits out the reset.
      Step(30, Submit(Ticket(3), messages(channel_a)), [Wake(9980)]),
    ])
}

/// Two routes reporting one hash converge on one counter.
pub fn one_hash_two_routes_share_a_counter_test() {
  let #(_, _) =
    run(limiter.new(limiter.defaults()), [
      Step(0, Submit(Ticket(1), messages(channel_a)), [Send(Ticket(1))]),
      Step(10, Settled(Ticket(1), learned("shared", 0, "10")), [
        Note(BucketLearned(route.route_key(messages(channel_a), 10), "shared")),
      ]),
      // A route that has never been sent, but its provisional bucket is its
      // own, so the first one probes.
      Step(20, Submit(Ticket(2), typing(channel_a)), [Send(Ticket(2))]),
      Step(30, Settled(Ticket(2), learned("shared", 3, "10")), [
        Note(BucketLearned(route.route_key(typing(channel_a), 30), "shared")),
      ]),
      // Now it is the same bucket, and the first route's exhaustion holds it
      // until the later of the two deadlines the two responses named.
      Step(40, Submit(Ticket(3), typing(channel_a)), [Wake(9990)]),
    ])
}

/// A route's hash alternating is Discord moving between sublimits, and the
/// first bucket's state has to survive the excursion.
pub fn hash_oscillation_keeps_the_first_counter_test() {
  let route = messages(channel_a)
  let key = route.route_key(route, 0)
  let #(_, _) =
    run(limiter.new(limiter.defaults()), [
      Step(0, Submit(Ticket(1), route), [Send(Ticket(1))]),
      Step(10, Settled(Ticket(1), learned("h1", 2, "10")), [
        Note(BucketLearned(key, "h1")),
      ]),
      Step(20, Submit(Ticket(2), route), [Send(Ticket(2))]),
      Step(30, Settled(Ticket(2), learned("h2", 9, "60")), [
        Note(BucketLearned(key, "h2")),
      ]),
      Step(40, Submit(Ticket(3), route), [Send(Ticket(3))]),
      Step(50, Settled(Ticket(3), learned("h1", 0, "10")), [
        Note(BucketLearned(key, "h1")),
      ]),
      // h1 resets at 10_050, h2 at 30_060. Waiting 9990 proves h1's own
      // deadline came back, rather than the excursion's.
      Step(60, Submit(Ticket(4), route), [Wake(9990)]),
    ])
}

fn small(
  global_per_second: Int,
  invalid_budget: Int,
  max_pending: Int,
) -> Limits {
  Limits(global_per_second:, invalid_budget:, max_pending:)
}

fn counted(total: Int) -> List(Int) {
  list.index_map(list.repeat(Nil, total), fn(_, index) { index })
}

fn nth_channel(index: Int) -> String {
  "1000000000000000" <> string.pad_start(int.to_string(index), 2, "0")
}

/// Fifty per second across every bucket, whatever any single bucket allows.
pub fn global_window_holds_the_fifty_first_test() {
  let script =
    list.map(counted(50), fn(index) {
      Step(0, Submit(Ticket(index), messages(nth_channel(index))), [
        Send(Ticket(index)),
      ])
    })
  let #(state, out) = run(limiter.new(limiter.defaults()), script)
  assert list.length(sends(out)) == 50

  let #(state, out) =
    limiter.step(
      state,
      now_ms: 0,
      input: Submit(Ticket(50), messages(channel_a)),
    )
  assert out == [Wake(1000)]

  // The window refills a second after the first spend, not the last.
  let #(_, out) = limiter.step(state, now_ms: 1000, input: Tick)
  assert out == [Send(Ticket(50))]
}

/// The window is anchored to the first spend after a refill, not to a
/// wall-clock second and not to the most recent spend.
pub fn global_window_anchors_to_the_first_spend_test() {
  let #(_, _) =
    run(limiter.new(small(2, 9000, 64)), [
      Step(0, Submit(Ticket(1), messages(channel_a)), [Send(Ticket(1))]),
      Step(900, Submit(Ticket(2), messages(channel_b)), [Send(Ticket(2))]),
      // 100 to go, not 1000: the second spend did not move the window.
      Step(900, Submit(Ticket(3), typing(channel_a)), [Wake(100)]),
    ])
}

/// An interaction callback is exempt from Discord's global limit and has three
/// seconds to be answered, so our own accounting must not hold one back.
pub fn unbound_route_bypasses_the_global_window_test() {
  let #(_, _) =
    run(limiter.new(small(1, 9000, 64)), [
      Step(0, Submit(Ticket(1), messages(channel_a)), [Send(Ticket(1))]),
      Step(0, Submit(Ticket(2), messages(channel_b)), [Wake(1000)]),
      Step(0, Submit(Ticket(3), callback()), [Send(Ticket(3)), Wake(1000)]),
      // And it does not spend a token either, so the queued call still waits
      // out the same window rather than a second one.
      Step(999, Tick, [Wake(1)]),
    ])
}

/// A `scope=global` 429 is Discord telling the whole client to stop. An
/// interaction callback is exempt from the global limit but not from that.
pub fn unbound_route_waits_out_a_global_freeze_test() {
  let #(_, _) =
    run(limiter.new(limiter.defaults()), [
      Step(0, Submit(Ticket(1), messages(channel_a)), [Send(Ticket(1))]),
      Step(10, Settled(Ticket(1), global_429("5")), [
        Note(GloballyFrozen(5000)),
      ]),
      Step(20, Submit(Ticket(2), callback()), [Wake(4990)]),
      Step(5010, Tick, [Send(Ticket(2))]),
    ])
}

/// 401, 403 and a 429 that is our own fault all spend from the budget that
/// ends in a Cloudflare ban of the whole IP.
pub fn invalid_requests_spend_the_budget_test() {
  let route = messages(channel_a)
  let key = route.route_key(route, 0)
  let #(_, _) =
    run(limiter.new(small(50, 3, 64)), [
      Step(0, Submit(Ticket(1), route), [Send(Ticket(1))]),
      Step(1, Settled(Ticket(1), bare(401)), []),
      Step(2, Submit(Ticket(2), route), [Send(Ticket(2))]),
      Step(3, Settled(Ticket(2), bare(403)), []),
      Step(4, Submit(Ticket(3), route), [Send(Ticket(3))]),
      Step(5, Settled(Ticket(3), throttled("user", "h", "1")), [
        Note(InvalidBudgetLow(0)),
        Note(BucketLearned(key, "h")),
      ]),
      // Spent. Sending anything now risks the ban.
      Step(6, Submit(Ticket(4), messages(channel_b)), [
        Refuse(Ticket(4), InvalidBudgetSpent),
      ]),
      // Ten minutes later the window has rolled and the budget is back.
      Step(600_006, Submit(Ticket(5), messages(channel_b)), [Send(Ticket(5))]),
    ])
}

/// Cloudflare's ceiling is HTTP level and per IP, so nothing is exempt.
pub fn a_spent_budget_refuses_everything_test() {
  let #(_, _) =
    run(limiter.new(small(50, 1, 64)), [
      Step(0, Submit(Ticket(1), messages(channel_a)), [Send(Ticket(1))]),
      Step(1, Settled(Ticket(1), bare(401)), [Note(InvalidBudgetLow(0))]),
      Step(2, Submit(Ticket(2), callback()), [
        Refuse(Ticket(2), InvalidBudgetSpent),
      ]),
      Step(3, Retry(Ticket(3), messages(channel_b)), [
        Refuse(Ticket(3), InvalidBudgetSpent),
      ]),
    ])
}

/// Discord does not count a shared 429 against us, because the limit belonged
/// to somebody else's traffic on a resource we happen to share.
pub fn shared_throttle_is_not_an_invalid_request_test() {
  let route = messages(channel_a)
  let key = route.route_key(route, 0)
  let #(_, _) =
    run(limiter.new(small(50, 1, 64)), [
      Step(0, Submit(Ticket(1), route), [Send(Ticket(1))]),
      Step(1, Settled(Ticket(1), throttled("shared", "h", "2")), [
        Note(BucketLearned(key, "h")),
        Note(limiter.SharedThrottle("h", 2000)),
      ]),
      // Budget untouched, so a different bucket still sends.
      Step(2, Submit(Ticket(2), messages(channel_b)), [Send(Ticket(2))]),
      // The shared limit parked the offending bucket, though.
      Step(3, Submit(Ticket(3), route), [Wake(1998)]),
    ])
}

/// Backpressure has to surface somewhere, and silence is not a plan.
pub fn backlog_is_refused_test() {
  let route = messages(channel_a)
  let #(_, _) =
    run(limiter.new(small(50, 9000, 2)), [
      Step(0, Submit(Ticket(1), route), [Send(Ticket(1))]),
      Step(0, Submit(Ticket(2), route), []),
      Step(0, Submit(Ticket(3), route), []),
      Step(0, Submit(Ticket(4), route), [Refuse(Ticket(4), Backlogged)]),
    ])
}

/// A retry is work the caller already owns, so it does not queue behind the
/// writes that were submitted after it.
pub fn retry_goes_to_the_front_test() {
  let route = messages(channel_a)
  let #(_, out) =
    run(limiter.new(limiter.defaults()), [
      Step(0, Submit(Ticket(1), route), [Send(Ticket(1))]),
      Step(1, Submit(Ticket(2), route), []),
      Step(2, Submit(Ticket(3), route), []),
      Step(3, Retry(Ticket(4), route), []),
      Step(4, Settled(Ticket(1), learned("h", 5, "10")), [
        Note(BucketLearned(route.route_key(route, 4), "h")),
        Send(Ticket(4)),
        Send(Ticket(2)),
        Send(Ticket(3)),
      ]),
    ])
  assert list.length(sends(out)) == 4
}

/// A permitted call that never came back would otherwise strand its route
/// forever, because a probing bucket has no deadline to expire.
pub fn abandoning_a_probe_releases_the_route_test() {
  let route = messages(channel_a)
  let #(_, _) =
    run(limiter.new(limiter.defaults()), [
      Step(0, Submit(Ticket(1), route), [Send(Ticket(1))]),
      Step(1, Submit(Ticket(2), route), []),
      Step(2, Abandoned(Ticket(1)), [Send(Ticket(2))]),
    ])
}

/// A call that was never sent gives its global token back.
pub fn abandoning_refunds_a_global_token_test() {
  let #(_, _) =
    run(limiter.new(small(1, 9000, 64)), [
      Step(0, Submit(Ticket(1), messages(channel_a)), [Send(Ticket(1))]),
      Step(0, Submit(Ticket(2), messages(channel_b)), [Wake(1000)]),
      Step(0, Abandoned(Ticket(1)), [Send(Ticket(2))]),
    ])
}

/// A response with nothing to teach still means the request went out, so the
/// token it spent stays spent.
pub fn an_opaque_response_does_not_refund_test() {
  let #(_, _) =
    run(limiter.new(small(1, 9000, 64)), [
      Step(0, Submit(Ticket(1), messages(channel_a)), [Send(Ticket(1))]),
      Step(1, Settled(Ticket(1), bare(502)), []),
      // The bucket is free again; the global window is not.
      Step(2, Submit(Ticket(2), messages(channel_b)), [Wake(998)]),
    ])
}

/// A queued call the caller gave up on leaves the queue.
pub fn abandoning_a_queued_call_drops_it_test() {
  let route = messages(channel_a)
  let #(_, out) =
    run(limiter.new(limiter.defaults()), [
      Step(0, Submit(Ticket(1), route), [Send(Ticket(1))]),
      Step(1, Submit(Ticket(2), route), []),
      Step(2, Abandoned(Ticket(2)), []),
      Step(3, Settled(Ticket(1), learned("h", 5, "10")), [
        Note(BucketLearned(route.route_key(route, 3), "h")),
      ]),
    ])
  assert sends(out) == [Send(Ticket(1))]
}

/// A 429 with room left is an undocumented per-resource limit, not exhaustion,
/// so poisoning the bucket would stall calls it does not apply to.
pub fn a_429_with_room_left_parks_rather_than_poisons_test() {
  let route = messages(channel_a)
  let key = route.route_key(route, 0)
  let #(_, _) =
    run(limiter.new(limiter.defaults()), [
      Step(0, Submit(Ticket(1), route), [Send(Ticket(1))]),
      Step(10, Settled(Ticket(1), learned("h", 5, "60")), [
        Note(BucketLearned(key, "h")),
      ]),
      Step(20, Submit(Ticket(2), route), [Send(Ticket(2))]),
      Step(30, Settled(Ticket(2), throttled("user", "h", "1")), []),
      // Parked for a second, not poisoned for the bucket's whole minute.
      Step(40, Submit(Ticket(3), route), [Wake(990)]),
      Step(1030, Tick, [Send(Ticket(3))]),
      // The quota Discord reported survived the excursion.
      Step(1031, Submit(Ticket(4), route), [Send(Ticket(4))]),
    ])
}

/// A 429 on a bucket that had nothing left is the ordinary case, and Discord's
/// own delay wins over whatever we thought the deadline was.
pub fn a_429_on_an_empty_bucket_extends_the_reset_test() {
  let route = messages(channel_a)
  let #(_, _) =
    run(limiter.new(limiter.defaults()), [
      Step(0, Submit(Ticket(1), route), [Send(Ticket(1))]),
      Step(10, Settled(Ticket(1), learned("h", 1, "1")), [
        Note(BucketLearned(route.route_key(route, 10), "h")),
      ]),
      Step(20, Submit(Ticket(2), route), [Send(Ticket(2))]),
      Step(30, Settled(Ticket(2), throttled("user", "h", "5")), []),
      Step(40, Submit(Ticket(3), route), [Wake(4990)]),
    ])
}

/// Discord uses a limit of zero to say the bucket is done until it resets,
/// whatever `remaining` claims.
pub fn a_limit_of_zero_is_exhaustion_test() {
  let route = messages(channel_a)
  let outcome =
    headers.to_limiter_outcome(headers.outcome(
      200,
      [
        #("x-ratelimit-bucket", "h"),
        #("x-ratelimit-limit", "0"),
        #("x-ratelimit-remaining", "5"),
        #("x-ratelimit-reset-after", "30"),
      ],
      "",
    ))
  let #(_, _) =
    run(limiter.new(limiter.defaults()), [
      Step(0, Submit(Ticket(1), route), [Send(Ticket(1))]),
      Step(10, Settled(Ticket(1), outcome), [
        Note(BucketLearned(route.route_key(route, 10), "h")),
      ]),
      Step(20, Submit(Ticket(2), route), [Wake(29_990)]),
    ])
}

/// A deadline already passed expires at once rather than being nudged forward.
pub fn a_reset_in_the_past_expires_at_once_test() {
  let route = messages(channel_a)
  let #(_, _) =
    run(limiter.new(limiter.defaults()), [
      Step(0, Submit(Ticket(1), route), [Send(Ticket(1))]),
      Step(10, Settled(Ticket(1), learned("h", 0, "0")), [
        Note(BucketLearned(route.route_key(route, 10), "h")),
      ]),
      Step(20, Submit(Ticket(2), route), [Send(Ticket(2))]),
    ])
}

/// With more than one call out, the value Discord wrote is already stale by
/// the time we read it. Letting it raise our own count means over-sending.
pub fn remaining_never_rises_inside_a_window_test() {
  let on = messages(channel_a)
  let key = route.route_key(on, 0)
  let #(_, _) =
    run(limiter.new(limiter.defaults()), [
      Step(0, Submit(Ticket(1), on), [Send(Ticket(1))]),
      Step(10, Settled(Ticket(1), learned("h", 1, "10")), [
        Note(BucketLearned(key, "h")),
      ]),
      Step(20, Submit(Ticket(2), on), [Send(Ticket(2))]),
      // One left and one out, so the next call waits on that response.
      Step(20, Submit(Ticket(3), on), [Wake(9990)]),
      // Discord now says four are left. That number was written before our
      // second call reached it, so the one we hold stands.
      Step(30, Settled(Ticket(2), learned("h", 4, "10")), [Send(Ticket(3))]),
      // One, not four.
      Step(40, Submit(Ticket(4), on), [Wake(9990)]),
    ])
}

/// `remaining` is Discord's last word and `in_flight` is what we have sent
/// since, so a bucket with five left permits five at once. Counting a send in
/// both halves would quietly halve every quota Discord grants.
pub fn a_whole_quota_goes_out_at_once_test() {
  let on = messages(channel_a)
  let #(_, out) =
    run(limiter.new(limiter.defaults()), [
      Step(0, Submit(Ticket(1), on), [Send(Ticket(1))]),
      Step(10, Settled(Ticket(1), learned("h", 5, "10")), [
        Note(BucketLearned(route.route_key(on, 10), "h")),
      ]),
      Step(20, Submit(Ticket(2), on), [Send(Ticket(2))]),
      Step(20, Submit(Ticket(3), on), [Send(Ticket(3))]),
      Step(20, Submit(Ticket(4), on), [Send(Ticket(4))]),
      Step(20, Submit(Ticket(5), on), [Send(Ticket(5))]),
      Step(20, Submit(Ticket(6), on), [Send(Ticket(6))]),
      // A sixth against a quota of five waits for the window.
      Step(20, Submit(Ticket(7), on), [Wake(9990)]),
    ])
  assert list.length(sends(out)) == 6
}

/// A 5xx teaches no counters, but the request still went out. Freeing the slot
/// without keeping its unit spent would hand the whole quota back the moment
/// the calls settle, and a Discord outage is a run of exactly these.
pub fn a_counter_less_settle_keeps_the_quota_spent_test() {
  let on = messages(channel_a)
  let #(_, out) =
    run(limiter.new(limiter.defaults()), [
      Step(0, Submit(Ticket(1), on), [Send(Ticket(1))]),
      Step(10, Settled(Ticket(1), learned("h", 5, "10")), [
        Note(BucketLearned(route.route_key(on, 10), "h")),
      ]),
      Step(20, Submit(Ticket(2), on), [Send(Ticket(2))]),
      Step(20, Submit(Ticket(3), on), [Send(Ticket(3))]),
      Step(20, Submit(Ticket(4), on), [Send(Ticket(4))]),
      Step(20, Submit(Ticket(5), on), [Send(Ticket(5))]),
      Step(20, Submit(Ticket(6), on), [Send(Ticket(6))]),
      Step(30, Settled(Ticket(2), bare(502)), []),
      Step(30, Settled(Ticket(3), bare(502)), []),
      Step(30, Settled(Ticket(4), bare(502)), []),
      Step(30, Settled(Ticket(5), bare(502)), []),
      Step(30, Settled(Ticket(6), bare(502)), []),
      // Five sent against a quota of five, so the window is done.
      Step(40, Submit(Ticket(7), on), [Wake(9970)]),
      Step(50, Submit(Ticket(8), on), [Wake(9960)]),
      // The next window probes, and its answer is what re-opens the bucket.
      Step(10_010, Tick, [Send(Ticket(7))]),
      Step(10_020, Settled(Ticket(7), learned("h", 4, "10")), [
        Send(Ticket(8)),
      ]),
    ])
  assert list.length(sends(out)) == 8
}

/// A 403 teaches no counters either, and it spends from the invalid-request
/// budget on the way out. Refunding its quota unit is how a permissions bug
/// turns into the 429s that end in a Cloudflare ban.
pub fn a_rejection_keeps_the_quota_spent_test() {
  let on = messages(channel_a)
  let #(_, _) =
    run(limiter.new(limiter.defaults()), [
      Step(0, Submit(Ticket(1), on), [Send(Ticket(1))]),
      Step(10, Settled(Ticket(1), learned("h", 1, "10")), [
        Note(BucketLearned(route.route_key(on, 10), "h")),
      ]),
      Step(20, Submit(Ticket(2), on), [Send(Ticket(2))]),
      Step(30, Settled(Ticket(2), bare(403)), []),
      Step(40, Submit(Ticket(3), on), [Wake(9970)]),
    ])
}

/// A second global 429 can only push the gate further out. Taking the newer
/// deadline would re-open one Discord has already closed.
pub fn a_shorter_global_429_does_not_shorten_the_freeze_test() {
  let #(_, _) =
    run(limiter.new(limiter.defaults()), [
      Step(0, Submit(Ticket(1), messages(channel_a)), [Send(Ticket(1))]),
      Step(0, Submit(Ticket(2), messages(channel_b)), [Send(Ticket(2))]),
      Step(10, Settled(Ticket(1), global_429("30")), [
        Note(GloballyFrozen(30_000)),
      ]),
      Step(20, Settled(Ticket(2), global_429("1")), [
        Note(GloballyFrozen(1000)),
      ]),
      // 30_010, from the first 429. The shorter wait did not replace it.
      Step(30, Submit(Ticket(3), messages(channel_a)), [Wake(29_980)]),
    ])
}

/// Ticket ids are the caller's to mint. Taking a second call under an id that
/// is already out would overwrite the record of the first, and its bucket slot
/// would never be given back.
pub fn a_duplicate_ticket_is_refused_test() {
  let on = messages(channel_a)
  let #(_, _) =
    run(limiter.new(limiter.defaults()), [
      Step(0, Submit(Ticket(1), on), [Send(Ticket(1))]),
      // Already out.
      Step(1, Submit(Ticket(1), on), [Refuse(Ticket(1), DuplicateTicket)]),
      Step(2, Submit(Ticket(2), on), []),
      // Already queued.
      Step(3, Retry(Ticket(2), on), [Refuse(Ticket(2), DuplicateTicket)]),
      // The first is still the one holding the slot, and it still releases it.
      Step(4, Settled(Ticket(1), learned("h", 5, "10")), [
        Note(BucketLearned(route.route_key(on, 4), "h")),
        Send(Ticket(2)),
      ]),
    ])
}

/// The budget stops traffic before Cloudflare bans the IP, and a call already
/// in the queue is traffic. Gating admission alone lets the backlog drain into
/// the ban.
pub fn a_spent_budget_drains_the_backlog_test() {
  let on = messages(channel_a)
  let #(_, _) =
    run(limiter.new(small(50, 1, 64)), [
      Step(0, Submit(Ticket(1), on), [Send(Ticket(1))]),
      // Queued behind the probe, so admission has already let them past.
      Step(1, Submit(Ticket(2), on), []),
      Step(2, Submit(Ticket(3), on), []),
      Step(3, Settled(Ticket(1), bare(401)), [
        Note(InvalidBudgetLow(0)),
        Refuse(Ticket(2), InvalidBudgetSpent),
        Refuse(Ticket(3), InvalidBudgetSpent),
      ]),
    ])
}

/// A message crosses an age band between the send and the answer. The counters
/// belong to the bucket the call was counted in, not to whichever one the
/// settle-time clock happens to name.
pub fn a_crossed_age_band_keeps_the_send_time_bucket_test() {
  let now = 2_000_000_000
  let sent_fresh = delete_message(channel_a, now - 1000)
  let #(_, _) =
    run(limiter.new(limiter.defaults()), [
      Step(now, Submit(Ticket(1), sent_fresh), [Send(Ticket(1))]),
      // Twenty seconds later the message is out of the under-10s band.
      Step(now + 20_000, Settled(Ticket(1), learned("del", 0, "30")), [
        Note(BucketLearned(route.route_key(sent_fresh, now), "del")),
      ]),
      // Another message that is still fresh: the bucket the first call was
      // counted in, which Discord just closed for thirty seconds.
      Step(
        now + 20_001,
        Submit(Ticket(2), delete_message(channel_a, now + 19_500)),
        [Wake(29_999)],
      ),
    ])
}

/// Deleting a message is bucketed by how old the message is, which no path can
/// express, so the limiter resolves it from `now`.
pub fn message_age_splits_the_delete_bucket_test() {
  let now = 2_000_000_000
  let path = "/channels/" <> channel_a <> "/messages/" <> message_id
  let fresh = seg.from_path(http.Delete, path, route.Aged(now - 1000))
  let ancient =
    seg.from_path(http.Delete, path, route.Aged(now - 1_300_000_000))

  let #(_, _) =
    run(limiter.new(limiter.defaults()), [
      Step(now, Submit(Ticket(1), ancient), [Send(Ticket(1))]),
      Step(now, Settled(Ticket(1), learned("old", 0, "10")), [
        Note(BucketLearned(route.route_key(ancient, now), "old")),
      ]),
      Step(now, Submit(Ticket(2), ancient), [Wake(10_000)]),
      // Same path, same channel, a message in a different age band.
      Step(now, Submit(Ticket(3), fresh), [Send(Ticket(3)), Wake(10_000)]),
    ])
}

/// N blocked buckets arming N timers is N wakeups to learn one thing.
pub fn one_wake_however_many_buckets_wait_test() {
  let frozen =
    run(limiter.new(limiter.defaults()), [
      Step(0, Submit(Ticket(1), messages(channel_a)), [Send(Ticket(1))]),
      Step(0, Settled(Ticket(1), global_429("30")), [
        Note(GloballyFrozen(30_000)),
      ]),
    ]).0

  let #(_, out) =
    list.fold(counted(5), #(frozen, []), fn(carried, index) {
      let #(state, seen) = carried
      let #(next, out) =
        limiter.step(
          state,
          now_ms: 0,
          input: Submit(Ticket(index + 10), messages(nth_channel(index))),
        )
      #(next, list.append(seen, out))
    })

  assert out == list.repeat(Wake(30_000), 5)
}

/// A response for a call the limiter never permitted has nothing to undo, and
/// crashing over one would lose every queued call.
pub fn an_unknown_ticket_settles_quietly_test() {
  let #(_, _) =
    run(limiter.new(limiter.defaults()), [
      Step(0, Settled(Ticket(9), learned("h", 5, "10")), []),
      Step(0, Abandoned(Ticket(9)), []),
      Step(0, Submit(Ticket(1), messages(channel_a)), [Send(Ticket(1))]),
    ])
}

/// A `Wake` that is early, late, duplicated or entirely lost costs latency,
/// never liveness.
pub fn ticks_are_idempotent_test() {
  let route = messages(channel_a)
  let waiting =
    run(limiter.new(limiter.defaults()), [
      Step(0, Submit(Ticket(1), route), [Send(Ticket(1))]),
      Step(10, Settled(Ticket(1), learned("h", 0, "10")), [
        Note(BucketLearned(route.route_key(route, 10), "h")),
      ]),
      Step(20, Submit(Ticket(2), route), [Wake(9990)]),
    ]).0

  let #(_, _) =
    run(waiting, [
      Step(20, Tick, [Wake(9990)]),
      Step(20, Tick, [Wake(9990)]),
      Step(20, Tick, [Wake(9990)]),
      // A late wake is still correct: the deadline is absolute.
      Step(50_000, Tick, [Send(Ticket(2))]),
    ])
}

/// Nothing pending and nothing asleep means a host has no timer to arm.
pub fn an_idle_limiter_arms_nothing_test() {
  let idle = limiter.new(limiter.defaults())
  assert limiter.wake_after(idle, now_ms: 0) == None

  let route = messages(channel_a)
  let #(sent, _) =
    limiter.step(idle, now_ms: 0, input: Submit(Ticket(1), route))
  assert limiter.wake_after(sent, now_ms: 0) == None

  let #(waiting, _) =
    limiter.step(sent, now_ms: 0, input: Submit(Ticket(2), route))
  // Waiting on a probe's response, which no timer brings closer.
  assert limiter.wake_after(waiting, now_ms: 0) == None

  let #(held, _) =
    limiter.step(
      waiting,
      now_ms: 1,
      input: Settled(Ticket(1), learned("h", 0, "10")),
    )
  assert limiter.wake_after(held, now_ms: 1) == Some(10_000)
  assert limiter.wake_after(held, now_ms: 20_000) == Some(0)
}

/// The limiter builds a bucket key by putting Discord's hash where the route
/// half of `route.key` was, so `route_key` has to stay a prefix of `key`.
pub fn route_key_is_a_prefix_of_the_full_key_test() {
  let each = [
    messages(channel_a),
    typing(channel_b),
    callback(),
    seg.from_path(http.Get, "/users/@me", route.NoSublimit),
    seg.from_path(http.Delete, "/channels/" <> channel_a, route.Named("name")),
  ]
  list.each(each, fn(one) {
    let full = route.key(one, 0)
    let head = route.route_key(one, 0)
    assert string.starts_with(full, head)
    assert string.drop_start(full, string.length(head)) != ""
  })
}
