//// Discord's rate limiter, as a pure state machine.
////
//// `now_ms` is an argument, not a timer, and must be monotonic. Deadlines are
//// absolute, so `Tick` is idempotent and a `Wake` that is early, late,
//// duplicated or lost costs latency and never liveness.
////
//// ```gleam
//// let submit = limiter.Submit(limiter.Ticket(1), rest.route(call))
//// let #(state, out) = limiter.step(state, now_ms: now, input: submit)
//// // out is [Send(Ticket(1))]: send it, then hand the answer back.
////
//// let outcome = headers.to_limiter_outcome(headers.outcome(status, hs, body))
//// let answer = limiter.Settled(limiter.Ticket(1), outcome)
//// let #(state, out) = limiter.step(state, now_ms: later, input: answer)
//// ```

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
import glyde/rest/route.{type Route}

/// Caller-minted and transparent: the caller has to correlate a permit with
/// its own work anyway, so it owns the id.
pub type Ticket {
  Ticket(Int)
}

pub type Input {
  Submit(ticket: Ticket, route: Route)

  /// A 429'd call being retried. Goes to the front of the pending list, so a
  /// retry does not reorder the caller's writes behind calls queued after it.
  Retry(ticket: Ticket, route: Route)

  Settled(ticket: Ticket, outcome: Outcome)

  /// A permitted call abandoned with no response. A probing bucket has no
  /// deadline, so without this a dropped probe strands its route forever.
  Abandoned(ticket: Ticket)

  /// Re-evaluate. Idempotent and always safe.
  Tick
}

/// What one response taught the limiter. `glyde/rest/headers` turns a real
/// response into one of these, so the machine itself never reads a header.
pub type Outcome {
  /// A response carrying the usual `x-ratelimit-*` counters.
  Learned(counters: Counters)

  Throttled(retry_after_ms: Int, scope: Scope, bucket: Option(String))

  /// 401 or 403.
  Rejected(status: Int)

  /// Anything else, including transport failure. Frees the bucket and teaches
  /// the limiter nothing.
  Opaque
}

/// What one response said about a bucket. `None` means the counter did not
/// arrive, so the field it names keeps whatever it already held.
pub type Counters {
  Counters(
    /// Names the bucket several routes share. Absence does not invalidate the
    /// counters beside it.
    bucket: Option(String),
    limit: Option(Int),
    remaining: Option(Int),
    reset_after_ms: Option(Int),
  )
}

/// Whose fault the 429 was.
pub type Scope {
  UserScope

  /// Somebody else's traffic on a resource we share. Discord does not count
  /// these against the invalid-request budget, and neither do we.
  SharedScope

  GlobalScope
}

pub type Output {
  Send(ticket: Ticket)

  /// Do not send. The caller fails this ticket.
  Refuse(ticket: Ticket, why: Refusal)

  /// Call `step(_, Tick)` again in about this long. A latency optimisation,
  /// not a liveness requirement.
  Wake(in_ms: Int)

  Note(notice: Notice)
}

pub type Refusal {
  /// The invalid-request budget is spent. Sending would risk a Cloudflare ban
  /// on the whole IP, which takes down every bot sharing it.
  InvalidBudgetSpent

  /// More than `max_pending` calls already waiting.
  Backlogged

  /// This ticket is already queued or already out. Accepting it would drop
  /// the first record of the two, leaking the bucket slot it holds.
  DuplicateTicket
}

pub type Notice {
  BucketLearned(route_key: String, bucket: String)
  GloballyFrozen(for_ms: Int)
  InvalidBudgetLow(remaining: Int)
  SharedThrottle(bucket: String, for_ms: Int)
}

pub type Limits {
  Limits(
    /// Requests per second across all buckets. Discord documents 50.
    global_per_second: Int,
    /// 401/403/429 tolerated per ten minutes before glyde stops sending.
    /// Discord bans at 10_000; the default leaves headroom.
    invalid_budget: Int,
    max_pending: Int,
  )
}

pub opaque type Limiter {
  Limiter(
    limits: Limits,
    /// Provisional route key to real bucket hash, from `x-ratelimit-bucket`.
    hashes: Dict(String, String),
    buckets: Dict(String, Bucket),
    /// Oldest first, keyed by route and re-resolved to a bucket on every pump,
    /// so learning a hash is a lookup and not a migration.
    pending: List(Pending),
    inflight: Dict(Int, Inflight),
    global: Global,
    invalid: Invalid,
  )
}

type Pending {
  Pending(ticket: Ticket, route: Route)
}

/// What one permitted call is holding.
type Inflight {
  /// An unbound route is in no bucket and exempt from the global limit, so a
  /// permit on one holds nothing to give back.
  Unbounded

  /// One bucket slot and one global token. The two keys are pinned at send
  /// time and never recomputed: a `DELETE`'s age band can move between
  /// sending and settling. `bucket` is the key the slot was taken in, which is
  /// the provisional one until a response names a hash.
  Counted(route_key: String, major_key: String, bucket: String)
}

type Bucket {
  Bucket(
    /// What Discord last reported, never decremented locally.
    remaining: Remaining,
    /// Absolute, from `reset-after` plus our own `now`.
    reset_at_ms: Int,
    /// Calls permitted since that report, settled or not, which is what every
    /// reader takes off `remaining`. Not `in_flight`: a 5xx, a 403 and a
    /// counter-less 200 all free the slot while teaching no new count, and the
    /// unit they spent is gone whatever came back.
    spent_since_report: Int,
    /// An Int, not a Bool: two routes can turn out to share one bucket with a
    /// request outstanding on each.
    in_flight: Int,
    /// A sublimit parked this bucket, leaving `remaining` and `reset_at_ms`
    /// intact.
    parked_until_ms: Int,
  )
}

type Remaining {
  /// Nothing has come back yet: one probe goes, everything else waits for its
  /// response. `Known(0)` at `reset_at_ms: 0` would let the cold burst through.
  Unknown
  Known(Int)
}

type Global {
  Ready

  /// Tokens spent in the one second window ending at `until_ms`. Refundable
  /// by `Abandoned`.
  Spent(used: Int, until_ms: Int)

  /// Discord sent a global 429. Never refundable: a refund re-opens the gate
  /// inside a global rate limit, and the next stop is an IP ban.
  Frozen(until_ms: Int)
}

type Invalid {
  Invalid(count: Int, window_ends_at_ms: Int)
}

/// Whether a pending call can go, and if not, when to look again. `Blocked`
/// has no deadline: it is waiting on a response, not on a clock.
type Readiness {
  ReadyNow
  ReadyAt(ms: Int)
  Blocked
}

/// Discord's global limit is per second.
const global_window_ms: Int = 1000

/// Discord counts invalid requests in ten minute windows.
const invalid_window_ms: Int = 600_000

pub fn defaults() -> Limits {
  Limits(global_per_second: 50, invalid_budget: 9000, max_pending: 512)
}

pub fn new(limits: Limits) -> Limiter {
  Limiter(
    limits:,
    hashes: dict.new(),
    buckets: dict.new(),
    pending: [],
    inflight: dict.new(),
    global: Ready,
    invalid: Invalid(count: 0, window_ends_at_ms: 0),
  )
}

/// Feed one input, get the state and everything the caller should do. Output
/// order: what the input caused, then permits oldest first, then one `Wake`.
pub fn step(
  limiter: Limiter,
  now_ms now_ms: Int,
  input input: Input,
) -> #(Limiter, List(Output)) {
  let #(limiter, caused) = apply(limiter, now_ms, input)
  let #(limiter, sent) = pump(limiter, now_ms)
  // Retention is the machine's job, not the caller's: an idle limiter asks for
  // no `Wake`, so a caller that only ever ticks when asked never prunes.
  let limiter = prune(limiter, now_ms)
  let woken = case wake_after(limiter, now_ms) {
    Some(in_ms) -> [Wake(in_ms)]
    None -> []
  }
  #(limiter, list.flatten([caused, sent, woken]))
}

/// When the limiter next does something useful, in ms from `now_ms`. `None`
/// means idle, so there is nothing to schedule.
pub fn wake_after(limiter: Limiter, now_ms now_ms: Int) -> Option(Int) {
  limiter.pending
  |> list.filter_map(fn(entry) {
    case readiness(limiter, now_ms, entry.route) {
      ReadyNow -> Ok(now_ms)
      ReadyAt(at) -> Ok(at)
      // Waiting on a probe's response, which no timer brings closer.
      Blocked -> Error(Nil)
    }
  })
  |> list.reduce(int.min)
  |> option.from_result
  |> option.map(fn(at) { int.max(at - now_ms, 0) })
}

fn apply(
  limiter: Limiter,
  now_ms: Int,
  input: Input,
) -> #(Limiter, List(Output)) {
  case input {
    Submit(ticket:, route:) -> enqueue(limiter, ticket, route, False)
    Retry(ticket:, route:) -> enqueue(limiter, ticket, route, True)
    Settled(ticket:, outcome:) -> settle(limiter, now_ms, ticket, outcome)
    Abandoned(ticket:) -> #(abandon(limiter, ticket), [])
    Tick -> #(limiter, [])
  }
}

/// Admission only. Whether a queued call may actually go out is `pump`'s
/// decision, taken again on every step.
fn enqueue(
  limiter: Limiter,
  ticket: Ticket,
  on: Route,
  front: Bool,
) -> #(Limiter, List(Output)) {
  let Ticket(id) = ticket
  case
    dict.has_key(limiter.inflight, id)
    || list.any(limiter.pending, fn(entry) { entry.ticket == ticket }),
    list.length(limiter.pending) >= limiter.limits.max_pending
  {
    True, _ -> #(limiter, [Refuse(ticket, DuplicateTicket)])
    _, True -> #(limiter, [Refuse(ticket, Backlogged)])
    _, _ -> {
      let entry = Pending(ticket:, route: on)
      let pending = case front {
        True -> [entry, ..limiter.pending]
        False -> list.append(limiter.pending, [entry])
      }
      #(Limiter(..limiter, pending:), [])
    }
  }
}

fn settle(
  limiter: Limiter,
  now_ms: Int,
  ticket: Ticket,
  outcome: Outcome,
) -> #(Limiter, List(Output)) {
  let Ticket(id) = ticket
  case dict.get(limiter.inflight, id) {
    // A ticket we never permitted, or one already settled: nothing to undo,
    // and crashing over it would lose every queued call.
    Error(_) -> #(limiter, [])
    Ok(entry) -> {
      let limiter =
        Limiter(..limiter, inflight: dict.delete(limiter.inflight, id))
        |> release(entry)
      case outcome {
        Learned(counters) -> learn(limiter, now_ms, entry, counters)
        Throttled(retry_after_ms:, scope:, bucket:) ->
          throttle(limiter, now_ms, entry, retry_after_ms, scope, bucket)
        Rejected(_) -> count_invalid(limiter, now_ms)
        // Not a cancellation: the request went out, so its global token stays
        // spent.
        Opaque -> #(limiter, [])
      }
    }
  }
}

/// Give the bucket its slot back. Neither the global token nor the bucket's
/// quota unit is refunded: the request went out, whatever came back, and only
/// a fresh count from Discord clears `spent_since_report`.
fn release(limiter: Limiter, entry: Inflight) -> Limiter {
  case entry {
    Unbounded -> limiter
    Counted(bucket:, ..) ->
      update_bucket(limiter, bucket, fn(bucket) {
        Bucket(..bucket, in_flight: int.max(bucket.in_flight - 1, 0))
      })
  }
}

fn abandon(limiter: Limiter, ticket: Ticket) -> Limiter {
  let Ticket(id) = ticket
  case dict.get(limiter.inflight, id) {
    Ok(entry) ->
      Limiter(
        ..limiter,
        inflight: dict.delete(limiter.inflight, id),
        global: case entry {
          Counted(..) -> refund(limiter.global)
          Unbounded -> limiter.global
        },
      )
      |> release(entry)

    // Not sent yet, so the caller is cancelling a queued call.
    Error(_) ->
      Limiter(
        ..limiter,
        pending: list.filter(limiter.pending, fn(entry) {
          entry.ticket != ticket
        }),
      )
  }
}

fn learn(
  limiter: Limiter,
  now_ms: Int,
  entry: Inflight,
  counters: Counters,
) -> #(Limiter, List(Output)) {
  case entry {
    // An unbound route is in no bucket, so its counters are not ours to keep.
    Unbounded -> #(limiter, [])
    Counted(route_key:, major_key:, bucket:) -> {
      let #(limiter, notes) = case counters.bucket {
        Some(hash) -> remember(limiter, route_key, hash)
        // Discord omits the hash from responses that still carry counters.
        // Keep them: the provisional key names a bucket too.
        None -> #(limiter, [])
      }
      let key = settled_key(limiter, route_key, major_key, bucket)
      let limiter =
        update_bucket(limiter, key, settled_bucket(_, now_ms, counters))
      #(limiter, notes)
    }
  }
}

/// The bucket a settling call's counters belong to: the keys it was sent
/// under, paired with whatever hash is known for them now. A hash this very
/// response taught counts, which is how a bucket first gets its real name.
fn settled_key(
  limiter: Limiter,
  route_key: String,
  major_key: String,
  sent_under: String,
) -> String {
  case dict.get(limiter.hashes, route_key) {
    Ok(hash) -> hash <> " " <> major_key
    Error(_) -> sent_under
  }
}

/// Responses arrive out of order, so keep the later deadline. Moving a known
/// bucket's reset back sends into a limit Discord has already closed.
fn settled_reset(bucket: Bucket, now_ms: Int, counters: Counters) -> Int {
  case counters.reset_after_ms {
    Some(ms) -> int.max(bucket.reset_at_ms, now_ms + ms)
    None -> bucket.reset_at_ms
  }
}

/// Fold one response's counters in. The count and the spend it clears are
/// decided together, so a response cannot move one without the other.
fn settled_bucket(bucket: Bucket, now_ms: Int, counters: Counters) -> Bucket {
  let #(remaining, spent_since_report) =
    settled_counts(bucket, now_ms, counters)
  Bucket(
    ..bucket,
    remaining:,
    spent_since_report:,
    reset_at_ms: settled_reset(bucket, now_ms, counters),
  )
}

/// `remaining` may only fall inside a window: two responses from one window
/// arrive in either order, and the older one's count is stale. A rolled window
/// takes the reported value as it stands.
///
/// A reported count supersedes what we have been counting locally, except for
/// the calls still out, which Discord had not seen when it wrote the number. A
/// response carrying no count supersedes nothing, so its spend stands.
fn settled_counts(
  bucket: Bucket,
  now_ms: Int,
  counters: Counters,
) -> #(Remaining, Int) {
  // Discord uses a limit of zero to say the bucket is done until it resets.
  case counters.limit == Some(0), counters.remaining {
    True, _ -> #(Known(0), bucket.in_flight)
    False, None -> #(bucket.remaining, bucket.spent_since_report)
    False, Some(reported) -> #(
      case bucket.remaining, now_ms >= bucket.reset_at_ms {
        Unknown, _ -> Known(reported)
        Known(_), True -> Known(reported)
        Known(held), False -> Known(int.min(reported, held))
      },
      bucket.in_flight,
    )
  }
}

fn throttle(
  limiter: Limiter,
  now_ms: Int,
  entry: Inflight,
  retry_after_ms: Int,
  scope: Scope,
  bucket: Option(String),
) -> #(Limiter, List(Output)) {
  // Discord does not count somebody else's limit against our budget.
  let #(limiter, budget_notes) = case scope {
    SharedScope -> #(limiter, [])
    _ -> count_invalid(limiter, now_ms)
  }

  let #(limiter, learned_notes) = case bucket, entry {
    Some(hash), Counted(route_key:, ..) -> remember(limiter, route_key, hash)
    _, _ -> #(limiter, [])
  }

  let #(limiter, notes) = case scope {
    // The route bucket is untouched: a global 429 says nothing about that
    // route's own quota.
    GlobalScope -> #(
      Limiter(
        ..limiter,
        global: freeze_until(limiter.global, now_ms + retry_after_ms),
      ),
      [Note(GloballyFrozen(retry_after_ms))],
    )

    SharedScope -> #(park(limiter, now_ms, entry, retry_after_ms), [
      Note(SharedThrottle(
        bucket: option.unwrap(bucket, ""),
        for_ms: retry_after_ms,
      )),
    ])

    UserScope -> #(user_throttle(limiter, now_ms, entry, retry_after_ms), [])
  }

  #(limiter, list.flatten([budget_notes, learned_notes, notes]))
}

/// Deadlines only ever move outwards. A second global 429 with a shorter wait
/// must not re-open the gate the first one closed, so this is the only place
/// a `Frozen` is built.
fn freeze_until(global: Global, at_ms: Int) -> Global {
  case global {
    Frozen(until_ms) -> Frozen(int.max(until_ms, at_ms))
    Ready | Spent(..) -> Frozen(at_ms)
  }
}

/// A 429 on a bucket that still believed it had room is a sublimit, not
/// exhaustion, so park it rather than stall every other call on it.
fn user_throttle(
  limiter: Limiter,
  now_ms: Int,
  entry: Inflight,
  retry_after_ms: Int,
) -> Limiter {
  case entry {
    Unbounded -> limiter
    Counted(route_key:, major_key:, bucket:) -> {
      let key = settled_key(limiter, route_key, major_key, bucket)
      case spare_quota(bucket_at(limiter, key)) > 0 {
        True -> park(limiter, now_ms, entry, retry_after_ms)
        False ->
          update_bucket(limiter, key, fn(bucket) {
            Bucket(
              ..bucket,
              remaining: Known(0),
              reset_at_ms: int.max(bucket.reset_at_ms, now_ms + retry_after_ms),
            )
          })
      }
    }
  }
}

/// What Discord's last report leaves over once every call permitted since is
/// taken off it, including the one that just 429'd: releasing its slot does not
/// clear its spend. An unprobed bucket reported nothing, so it has nothing to
/// spare.
fn spare_quota(bucket: Bucket) -> Int {
  case bucket.remaining {
    Unknown -> 0
    Known(left) -> int.max(left - bucket.spent_since_report, 0)
  }
}

/// Hold the bucket without writing to its counters, so the quota Discord
/// reported survives.
fn park(
  limiter: Limiter,
  now_ms: Int,
  entry: Inflight,
  for_ms: Int,
) -> Limiter {
  case entry {
    Unbounded -> limiter
    Counted(route_key:, major_key:, bucket:) ->
      update_bucket(
        limiter,
        settled_key(limiter, route_key, major_key, bucket),
        fn(bucket) {
          Bucket(
            ..bucket,
            parked_until_ms: int.max(bucket.parked_until_ms, now_ms + for_ms),
          )
        },
      )
  }
}

/// File the hash against the route that earned it. A hash can change between
/// responses, which is Discord alternating sublimits, not an error.
fn remember(
  limiter: Limiter,
  route_key: String,
  hash: String,
) -> #(Limiter, List(Output)) {
  let changed = dict.get(limiter.hashes, route_key) != Ok(hash)
  let limiter =
    Limiter(..limiter, hashes: dict.insert(limiter.hashes, route_key, hash))
  case changed {
    True -> #(limiter, [Note(BucketLearned(route_key:, bucket: hash))])
    False -> #(limiter, [])
  }
}

/// 401, 403 and a 429 of our own making all spend from the budget that ends in
/// a Cloudflare ban of the whole IP.
fn count_invalid(limiter: Limiter, now_ms: Int) -> #(Limiter, List(Output)) {
  let Invalid(count:, window_ends_at_ms:) = limiter.invalid
  let invalid = case now_ms >= window_ends_at_ms {
    True -> Invalid(count: 1, window_ends_at_ms: now_ms + invalid_window_ms)
    False -> Invalid(count: count + 1, window_ends_at_ms:)
  }
  let before = budget_left(limiter, now_ms)
  let after = int.max(limiter.limits.invalid_budget - invalid.count, 0)
  // Once per crossing: a warning that repeats nine hundred times is unread.
  let mark = limiter.limits.invalid_budget / 10
  let notes = case after <= mark && before > mark {
    True -> [Note(InvalidBudgetLow(after))]
    False -> []
  }
  #(Limiter(..limiter, invalid:), notes)
}

fn budget_left(limiter: Limiter, now_ms: Int) -> Int {
  let Invalid(count:, window_ends_at_ms:) = limiter.invalid
  case now_ms >= window_ends_at_ms {
    True -> limiter.limits.invalid_budget
    False -> int.max(limiter.limits.invalid_budget - count, 0)
  }
}

fn spent_budget(limiter: Limiter, now_ms: Int) -> Bool {
  budget_left(limiter, now_ms) == 0
}

/// Walk the queue oldest first, stepping over what a bucket will not allow, so
/// one stalled bucket cannot starve the others. FIFO holds inside each bucket.
fn pump(limiter: Limiter, now_ms: Int) -> #(Limiter, List(Output)) {
  case spent_budget(limiter, now_ms) {
    // A queued call is traffic too, and the budget exists to stop traffic.
    True -> #(
      Limiter(..limiter, pending: []),
      list.map(limiter.pending, fn(entry) {
        Refuse(entry.ticket, InvalidBudgetSpent)
      }),
    )
    False -> walk(limiter, now_ms, limiter.pending, [], [])
  }
}

fn walk(
  limiter: Limiter,
  now_ms: Int,
  queue: List(Pending),
  waiting: List(Pending),
  sent: List(Output),
) -> #(Limiter, List(Output)) {
  case queue {
    [] -> #(
      Limiter(..limiter, pending: list.reverse(waiting)),
      list.reverse(sent),
    )
    [entry, ..rest] ->
      case readiness(limiter, now_ms, entry.route) {
        ReadyNow ->
          walk(commit(limiter, now_ms, entry), now_ms, rest, waiting, [
            Send(entry.ticket),
            ..sent
          ])
        ReadyAt(_) | Blocked ->
          walk(limiter, now_ms, rest, [entry, ..waiting], sent)
      }
  }
}

/// Account for a permit: one quota unit, one bucket slot, one global token, and
/// a record of the slot so `Settled` and `Abandoned` can hand it back. The
/// quota unit is not theirs to hand back, only Discord's next count is.
fn commit(limiter: Limiter, now_ms: Int, entry: Pending) -> Limiter {
  let Ticket(id) = entry.ticket
  case route.unbound(entry.route) {
    True ->
      Limiter(..limiter, inflight: dict.insert(limiter.inflight, id, Unbounded))

    False -> {
      let key = bucket_key(limiter, entry.route, now_ms)
      let limiter =
        update_bucket(limiter, key, fn(bucket) {
          Bucket(
            ..bucket,
            spent_since_report: bucket.spent_since_report + 1,
            in_flight: bucket.in_flight + 1,
          )
        })

      Limiter(
        ..limiter,
        global: spend_global(limiter.global, now_ms),
        inflight: dict.insert(
          limiter.inflight,
          id,
          Counted(
            route_key: route.route_key(entry.route, now_ms),
            major_key: route.major_key(entry.route),
            bucket: key,
          ),
        ),
      )
    }
  }
}

/// Anchored to the first spend after a refill, not to a wall-clock second.
fn spend_global(global: Global, now_ms: Int) -> Global {
  case global {
    Spent(used:, until_ms:) if now_ms < until_ms ->
      Spent(used: used + 1, until_ms:)
    _ -> Spent(used: 1, until_ms: now_ms + global_window_ms)
  }
}

fn refund(global: Global) -> Global {
  case global {
    Spent(used:, until_ms:) -> Spent(used: int.max(used - 1, 0), until_ms:)
    // Refunding inside a global 429 re-opens the gate Discord just closed.
    Ready | Frozen(_) -> global
  }
}

fn readiness(limiter: Limiter, now_ms: Int, on: Route) -> Readiness {
  later(
    bucket_readiness(limiter, now_ms, on),
    global_readiness(limiter, now_ms, on),
  )
}

fn bucket_readiness(limiter: Limiter, now_ms: Int, on: Route) -> Readiness {
  case route.unbound(on) {
    True -> ReadyNow
    False -> allows(bucket_at(limiter, bucket_key(limiter, on, now_ms)), now_ms)
  }
}

fn allows(bucket: Bucket, now_ms: Int) -> Readiness {
  let parked = case now_ms < bucket.parked_until_ms {
    True -> ReadyAt(bucket.parked_until_ms)
    False -> ReadyNow
  }
  let quota = case bucket.remaining, now_ms >= bucket.reset_at_ms {
    // One probe goes; no deadline releases the rest, only its response.
    Unknown, _ | Known(_), True ->
      case bucket.in_flight {
        0 -> ReadyNow
        _ -> Blocked
      }
    Known(_), False ->
      case spare_quota(bucket) > 0 {
        True -> ReadyNow
        False -> ReadyAt(bucket.reset_at_ms)
      }
  }
  later(parked, quota)
}

/// Discord exempts an interaction callback from the global limit, so our own
/// 50 per second must not hold one back. A `scope=global` 429 still does.
fn global_readiness(limiter: Limiter, now_ms: Int, on: Route) -> Readiness {
  case limiter.global {
    Frozen(until_ms) if now_ms < until_ms -> ReadyAt(until_ms)
    _ ->
      case route.unbound(on), limiter.global {
        True, _ -> ReadyNow
        False, Spent(used:, until_ms:)
          if used >= limiter.limits.global_per_second && now_ms < until_ms
        -> ReadyAt(until_ms)
        False, _ -> ReadyNow
      }
  }
}

fn later(one: Readiness, other: Readiness) -> Readiness {
  case one, other {
    Blocked, _ | _, Blocked -> Blocked
    ReadyAt(one), ReadyAt(other) -> ReadyAt(int.max(one, other))
    ReadyAt(at), ReadyNow | ReadyNow, ReadyAt(at) -> ReadyAt(at)
    ReadyNow, ReadyNow -> ReadyNow
  }
}

/// The real bucket is Discord's hash paired with the major parameter. Until a
/// response names a hash, `route.key` stands in.
fn bucket_key(limiter: Limiter, on: Route, now_ms: Int) -> String {
  case dict.get(limiter.hashes, route.route_key(on, now_ms)) {
    Ok(hash) -> hash <> " " <> route.major_key(on)
    Error(_) -> route.key(on, now_ms)
  }
}

fn bucket_at(limiter: Limiter, key: String) -> Bucket {
  case dict.get(limiter.buckets, key) {
    Ok(bucket) -> bucket
    Error(_) ->
      Bucket(
        remaining: Unknown,
        reset_at_ms: 0,
        spent_since_report: 0,
        in_flight: 0,
        parked_until_ms: 0,
      )
  }
}

fn update_bucket(
  limiter: Limiter,
  key: String,
  change: fn(Bucket) -> Bucket,
) -> Limiter {
  Limiter(
    ..limiter,
    buckets: dict.insert(limiter.buckets, key, change(bucket_at(limiter, key))),
  )
}

/// Drop buckets nobody is waiting on. One with a live deadline stays, because
/// forgetting it means the next call starts optimistic and 429s at once.
fn prune(limiter: Limiter, now_ms: Int) -> Limiter {
  let wanted =
    limiter.pending
    |> list.map(fn(entry) { bucket_key(limiter, entry.route, now_ms) })
    |> set.from_list

  let buckets =
    dict.filter(limiter.buckets, fn(key, bucket) {
      bucket.in_flight > 0
      || now_ms < bucket.reset_at_ms
      || now_ms < bucket.parked_until_ms
      || set.contains(wanted, key)
    })

  Limiter(..limiter, buckets:)
}
