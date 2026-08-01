//// Discord's IDENTIFY concurrency limit, as a pure state machine.
////
//// `max_concurrency` from `GET /gateway/bot` divides shards into buckets by
//// `shard_id % max_concurrency`, and one shard per bucket may IDENTIFY every
//// five seconds. Separately a bot has a daily budget of session starts, and
//// exhausting that resets the bot token. Two limits, counted apart.
////
//// RESUME never comes here: Discord meters IDENTIFY and not RESUME, so a
//// shard holding a session goes straight to the wire.
////
//// A grant is a loan. `Release` gives it back; if nobody does it lapses after
//// `hold_ms`, so a lost message costs one bucket half a minute, not forever.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

/// One IDENTIFY per bucket per five seconds, which is how Discord defines
/// `max_concurrency`. Exceeding it is what produces INVALID_SESSION.
const spacing_ms: Int = 5000

/// How long a grant counts as in flight when nobody says otherwise. Our
/// choice, matched to the handshake deadline.
const hold_ms: Int = 30_000

/// Session starts left before every grant starts saying so. Our choice. Small
/// enough that a healthy bot never sees it, large enough to still act on.
const low_water: Int = 50

pub opaque type Queue {
  Queue(remaining: Int, reset_at_ms: Int, buckets: Buckets)
}

/// One entry per rate limit key, ascending, and never empty: Discord
/// documents `max_concurrency: 0` as "no queue", never as a modulus, and
/// `shard % 0` crashes. Not a `Dict`: serving order must come from the
/// structure, not an unspecified iteration order.
///
/// `count` is `length(all)`, carried so that `rate_limit_key` does not walk
/// the list. Only `new` sets it; every other change is a record update.
type Buckets {
  Buckets(count: Int, all: List(Bucket))
}

type Bucket {
  Bucket(
    phase: Phase,
    /// Shards waiting on this key, oldest first.
    waiting: List(Int),
  )
}

/// A bucket is in exactly one of three states. `Fresh` is not `Free(0)`: a
/// monotonic clock can start negative, so no instant works as a sentinel.
type Phase {
  /// Nothing has gone through this bucket yet.
  Fresh

  /// A grant is out with this shard and nobody has answered for it.
  Holding(shard: Int, granted_at_ms: Int)

  /// Free once the clock reaches this.
  Free(free_at_ms: Int)
}

pub type Input {
  /// This shard is at the point in its handshake where the next frame it
  /// writes is IDENTIFY.
  Request(shard: Int)

  /// The shard is done with its place, however it went. Cancels a queued
  /// request and clears a grant already given.
  Release(shard: Int)

  /// Re-evaluate. Idempotent and always safe.
  Tick
}

pub type Output {
  /// Write IDENTIFY for this shard now, as the very next frame.
  Grant(shard: Int)

  /// Ask `GET /gateway/bot` again no sooner than `refresh_at_ms`, the earliest
  /// instant it could report a refilled budget, and build a new queue from the
  /// answer. The daily session budget is gone; this queue never grants again,
  /// so waiting on it buys nothing and the request is dropped, not parked.
  Deny(shard: Int, refresh_at_ms: Int)

  /// Call `step(_, Tick)` again in about this long. A latency optimisation,
  /// not a liveness requirement.
  Wake(in_ms: Int)

  Note(notice: Notice)
}

pub type Notice {
  BudgetLow(remaining: Int)

  /// `behind` counts the shards ahead of this one in its bucket. Zero means it
  /// is next and the bucket is only waiting out its clock.
  Waiting(shard: Int, behind: Int)
}

/// From `GET /gateway/bot`'s `session_start_limit`. Counts off the wire are
/// clamped, not rejected: a state machine may not crash on a peer's numbers.
/// `reset_at_ms` is not clamped. It is an instant on the caller's clock, which
/// nothing here can judge, so the denial that reads it is held to the present
/// instead.
pub fn new(
  max_concurrency max_concurrency: Int,
  remaining remaining: Int,
  reset_at_ms reset_at_ms: Int,
) -> Queue {
  let idle = Bucket(phase: Fresh, waiting: [])
  let count = int.max(max_concurrency, 1)
  Queue(
    remaining: int.max(remaining, 0),
    reset_at_ms:,
    buckets: Buckets(count:, all: list.repeat(idle, count)),
  )
}

/// A single-shard bot, still spacing IDENTIFYs five seconds apart. 1000 is
/// Discord's default daily budget and a placeholder: past 150 000 guilds the
/// real number is larger, so pass it once `GET /gateway/bot` answers.
pub fn solo() -> Queue {
  // The reset instant is read only once the budget runs out, which a
  // placeholder budget of 1000 does not do before the real one arrives.
  new(max_concurrency: 1, remaining: 1000, reset_at_ms: 0)
}

/// Which bucket a shard identifies through. Discord calls it `rate_limit_key`
/// and a bot split over several processes routes on it.
pub fn rate_limit_key(queue: Queue, shard shard: Int) -> Int {
  let buckets = queue.buckets.count
  // `%` keeps the sign of the left operand, so a negative shard needs folding.
  let raw = shard % buckets
  case raw < 0 {
    True -> raw + buckets
    False -> raw
  }
}

/// Session starts left, as this gate has counted them. Never rises: a gate
/// that refills itself hands out the thousandth IDENTIFY twice.
pub fn remaining(queue: Queue) -> Int {
  queue.remaining
}

pub fn step(
  queue: Queue,
  now_ms now_ms: Int,
  input input: Input,
) -> #(Queue, List(Output)) {
  let queue = apply(queue, input)
  let #(queue, served) = pump(queue, now_ms)
  // After the pump: a shard granted in this step is not also announced waiting.
  let waiting = case input {
    Request(shard:) -> queued_note(queue, shard)
    Release(_) | Tick -> []
  }
  let woken = case wake_after(queue, now_ms) {
    Some(in_ms) -> [Wake(in_ms)]
    None -> []
  }
  #(queue, list.flatten([served, waiting, woken]))
}

/// When the queue would next do something useful, in milliseconds from
/// `now_ms`. `None` means no shard is waiting.
pub fn wake_after(queue: Queue, now_ms now_ms: Int) -> Option(Int) {
  queue.buckets.all
  |> list.filter_map(fn(bucket) {
    case bucket.waiting {
      [] -> Error(Nil)
      [_, ..] -> Ok(option.unwrap(next_free(bucket), now_ms))
    }
  })
  |> list.reduce(int.min)
  |> option.from_result
  |> option.map(fn(at) { int.max(at - now_ms, 0) })
}

fn apply(queue: Queue, input: Input) -> Queue {
  case input {
    Request(shard:) -> enqueue(queue, shard)
    Release(shard:) -> withdraw(queue, shard)
    Tick -> queue
  }
}

fn enqueue(queue: Queue, shard: Int) -> Queue {
  use bucket <- change(queue, shard)
  // Asking again means the last grant is over. Dropping the shard's own hold
  // here stops a grant that crossed with a reconnect parking the bucket.
  let bucket = Bucket(..bucket, phase: hand_back(bucket.phase, shard))
  case list.contains(bucket.waiting, shard) {
    True -> bucket
    False -> Bucket(..bucket, waiting: list.append(bucket.waiting, [shard]))
  }
}

fn withdraw(queue: Queue, shard: Int) -> Queue {
  use bucket <- change(queue, shard)
  Bucket(
    phase: hand_back(bucket.phase, shard),
    waiting: list.filter(bucket.waiting, fn(one) { one != shard }),
  )
}

/// Ending this shard's hold early. The bucket still waits out its spacing:
/// giving a grant back does not buy back the five seconds it cost.
fn hand_back(phase: Phase, shard: Int) -> Phase {
  case phase {
    Holding(shard: held, granted_at_ms:) if held == shard ->
      Free(free_at_ms: granted_at_ms + spacing_ms)
    other -> other
  }
}

/// Buckets are served in ascending key order: Discord starts shards "by
/// bucket, in order".
fn pump(queue: Queue, now_ms: Int) -> #(Queue, List(Output)) {
  let Buckets(count:, all:) = queue.buckets
  let #(#(remaining, outputs), all) =
    list.map_fold(
      over: all,
      from: #(queue.remaining, []),
      with: fn(carried, bucket) {
        serve(carried, bucket, queue.reset_at_ms, now_ms)
      },
    )
  #(Queue(..queue, remaining:, buckets: Buckets(count:, all:)), outputs)
}

/// One bucket's turn. The pair it takes and returns is `#(budget left, outputs
/// so far)`, the accumulator `list.map_fold` carries down the rest of them.
fn serve(
  carried: #(Int, List(Output)),
  bucket: Bucket,
  reset_at_ms: Int,
  now_ms: Int,
) -> #(#(Int, List(Output)), Bucket) {
  let #(remaining, outputs) = carried
  let bucket = lapse(bucket, now_ms)
  case bucket.waiting {
    [] -> #(#(remaining, outputs), bucket)

    // The daily budget is spent, so nobody here is going anywhere. Say so
    // once each and let them go: the caller owns the retry and now knows when.
    [_, ..] if remaining <= 0 -> {
      let refresh_at_ms = int.max(reset_at_ms, now_ms + spacing_ms)
      let denied =
        list.map(bucket.waiting, fn(shard) { Deny(shard:, refresh_at_ms:) })
      #(
        #(remaining, list.append(outputs, denied)),
        Bucket(..bucket, waiting: []),
      )
    }

    [shard, ..rest] ->
      case ready(bucket.phase, now_ms) {
        False -> #(#(remaining, outputs), bucket)
        True -> {
          let left = remaining - 1
          let granted =
            Bucket(phase: Holding(shard:, granted_at_ms: now_ms), waiting: rest)
          let notes = case left <= low_water {
            True -> [Note(BudgetLow(remaining: left))]
            False -> []
          }
          #(#(left, list.append(outputs, [Grant(shard:), ..notes])), granted)
        }
      }
  }
}

/// A hold that outlived its deadline is a grant nobody is coming back for.
fn lapse(bucket: Bucket, now_ms: Int) -> Bucket {
  case bucket.phase {
    Holding(granted_at_ms:, ..) if now_ms >= granted_at_ms + hold_ms ->
      Bucket(..bucket, phase: Free(free_at_ms: granted_at_ms + spacing_ms))
    _ -> bucket
  }
}

fn ready(phase: Phase, now_ms: Int) -> Bool {
  case phase {
    Fresh -> True
    Holding(..) -> False
    Free(free_at_ms:) -> now_ms >= free_at_ms
  }
}

/// `hold_ms` is longer than `spacing_ms`, so a bucket holding a grant is not
/// free again until the hold lapses.
fn next_free(bucket: Bucket) -> Option(Int) {
  case bucket.phase {
    Fresh -> None
    Holding(granted_at_ms:, ..) -> Some(granted_at_ms + hold_ms)
    Free(free_at_ms:) -> Some(free_at_ms)
  }
}

fn queued_note(queue: Queue, shard: Int) -> List(Output) {
  let bucket = bucket_of(queue, shard)
  case position(bucket.waiting, shard, 0) {
    None -> []
    Some(behind) -> [Note(Waiting(shard:, behind:))]
  }
}

fn position(items: List(Int), wanted: Int, seen: Int) -> Option(Int) {
  case items {
    [] -> None
    [first, ..] if first == wanted -> Some(seen)
    [_, ..rest] -> position(rest, wanted, seen + 1)
  }
}

fn bucket_of(queue: Queue, shard: Int) -> Bucket {
  case list.drop(queue.buckets.all, rate_limit_key(queue, shard)) {
    [bucket, ..] -> bucket
    // `rate_limit_key` cannot leave the range, so this arm never runs.
    [] -> Bucket(phase: Fresh, waiting: [])
  }
}

fn change(queue: Queue, shard: Int, with: fn(Bucket) -> Bucket) -> Queue {
  let key = rate_limit_key(queue, shard)
  let all =
    list.index_map(queue.buckets.all, fn(bucket, index) {
      case index == key {
        True -> with(bucket)
        False -> bucket
      }
    })
  Queue(..queue, buckets: Buckets(..queue.buckets, all:))
}
