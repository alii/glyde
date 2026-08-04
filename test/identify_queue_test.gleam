import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import glyde/identify_queue.{
  type Input, type Output, type Queue, BudgetLow, Deny, Grant, Note, Release,
  Request, Tick, Waiting, Wake,
}

/// One line of a scenario: the clock, one input, and every output allowed.
type Step {
  Step(at: Int, input: Input, expect: List(Output))
}

fn run(queue: Queue, script: List(Step)) -> Queue {
  list.fold(script, queue, fn(queue, step) {
    let #(next, out) =
      identify_queue.step(queue, now_ms: step.at, input: step.input)
    assert out == step.expect as { "step at " <> int.to_string(step.at) }
    next
  })
}

fn fleet(max_concurrency: Int) -> Queue {
  identify_queue.new(
    max_concurrency: max_concurrency,
    remaining: 1000,
    reset_at_ms: 0,
  )
}

/// Inclusive of both ends.
fn upto(first: Int, last: Int) -> List(Int) {
  int.range(from: last, to: first - 1, with: [], run: fn(acc, one) {
    [one, ..acc]
  })
}

pub fn rate_limit_key_test() {
  // #(max_concurrency, shard, key)
  [
    #(16, 17, 1),
    #(16, 0, 0),
    #(16, 16, 0),
    #(4, 15, 3),
    #(1, 7, 0),
    // Clamped to one bucket rather than used as a modulus.
    #(0, 5, 0),
  ]
  |> list.each(fn(row) {
    let #(max_concurrency, shard, want) = row
    let queue =
      identify_queue.new(max_concurrency:, remaining: 1, reset_at_ms: 0)
    let got = identify_queue.rate_limit_key(queue, shard:)
    assert got == want
      as {
        int.to_string(shard)
        <> " % "
        <> int.to_string(max_concurrency)
        <> " gave "
        <> int.to_string(got)
      }
  })
}

/// A key outside `0 .. max_concurrency - 1` addresses no bucket at all.
pub fn rate_limit_key_stays_in_range_test() {
  upto(1, 17)
  |> list.each(fn(buckets) {
    let queue =
      identify_queue.new(max_concurrency: buckets, remaining: 1, reset_at_ms: 0)
    upto(-5, 40)
    |> list.each(fn(shard) {
      let key = identify_queue.rate_limit_key(queue, shard:)
      assert key >= 0 && key < buckets
        as {
          "shard "
          <> int.to_string(shard)
          <> " of "
          <> int.to_string(buckets)
          <> " gave key "
          <> int.to_string(key)
        }
    })
  })
}

pub fn first_request_grants_immediately_test() {
  run(fleet(4), [
    Step(at: 0, input: Request(shard: 7), expect: [Grant(shard: 7)]),
  ])
}

pub fn spacing_holds_per_bucket_test() {
  run(fleet(1), [
    Step(at: 0, input: Request(shard: 0), expect: [Grant(shard: 0)]),
    Step(at: 0, input: Request(shard: 1), expect: [
      Note(Waiting(shard: 1, behind: 0)),
      Wake(in_ms: 30_000),
    ]),
    Step(at: 100, input: Release(shard: 0), expect: [Wake(in_ms: 4900)]),
    Step(at: 4999, input: Tick, expect: [Wake(in_ms: 1)]),
    Step(at: 5000, input: Tick, expect: [Grant(shard: 1)]),
  ])
}

/// Bucket order beats arrival order: shard 3 queued first, shard 2 goes first.
pub fn buckets_are_served_in_ascending_key_order_test() {
  run(fleet(2), [
    Step(at: 0, input: Request(shard: 0), expect: [Grant(shard: 0)]),
    Step(at: 0, input: Request(shard: 1), expect: [Grant(shard: 1)]),
    Step(at: 0, input: Release(shard: 0), expect: []),
    Step(at: 0, input: Release(shard: 1), expect: []),
    Step(at: 1000, input: Request(shard: 3), expect: [
      Note(Waiting(shard: 3, behind: 0)),
      Wake(in_ms: 4000),
    ]),
    Step(at: 1000, input: Request(shard: 2), expect: [
      Note(Waiting(shard: 2, behind: 0)),
      Wake(in_ms: 4000),
    ]),
    Step(at: 5000, input: Tick, expect: [Grant(shard: 2), Grant(shard: 3)]),
  ])
}

/// Without the release the bucket waits out the whole hold. With it, only the
/// five seconds Discord actually asks for.
pub fn release_frees_the_bucket_sooner_than_the_hold_test() {
  run(fleet(1), [
    Step(at: 0, input: Request(shard: 0), expect: [Grant(shard: 0)]),
    Step(at: 0, input: Request(shard: 1), expect: [
      Note(Waiting(shard: 1, behind: 0)),
      Wake(in_ms: 30_000),
    ]),
    Step(at: 100, input: Release(shard: 0), expect: [Wake(in_ms: 4900)]),
    Step(at: 5000, input: Tick, expect: [Grant(shard: 1)]),
  ])
}

pub fn a_lost_grant_lapses_at_the_hold_deadline_test() {
  run(fleet(1), [
    Step(at: 0, input: Request(shard: 0), expect: [Grant(shard: 0)]),
    Step(at: 0, input: Request(shard: 1), expect: [
      Note(Waiting(shard: 1, behind: 0)),
      Wake(in_ms: 30_000),
    ]),
    Step(at: 5000, input: Tick, expect: [Wake(in_ms: 25_000)]),
    Step(at: 29_999, input: Tick, expect: [Wake(in_ms: 1)]),
    Step(at: 30_000, input: Tick, expect: [Grant(shard: 1)]),
  ])
}

/// A shard asking again has given up, so its own stale hold must not block it.
pub fn re_requesting_clears_the_shards_own_hold_test() {
  run(fleet(1), [
    Step(at: 0, input: Request(shard: 0), expect: [Grant(shard: 0)]),
    Step(at: 4999, input: Request(shard: 0), expect: [
      Note(Waiting(shard: 0, behind: 0)),
      Wake(in_ms: 1),
    ]),
    Step(at: 5000, input: Tick, expect: [Grant(shard: 0)]),
  ])
}

pub fn re_requesting_does_not_jump_the_queue_test() {
  run(fleet(1), [
    Step(at: 0, input: Request(shard: 0), expect: [Grant(shard: 0)]),
    Step(at: 0, input: Request(shard: 1), expect: [
      Note(Waiting(shard: 1, behind: 0)),
      Wake(in_ms: 30_000),
    ]),
    Step(at: 5000, input: Request(shard: 0), expect: [
      Grant(shard: 1),
      Note(Waiting(shard: 0, behind: 0)),
      Wake(in_ms: 30_000),
    ]),
  ])
}

pub fn duplicate_requests_queue_once_test() {
  run(fleet(1), [
    Step(at: 0, input: Request(shard: 0), expect: [Grant(shard: 0)]),
    Step(at: 0, input: Release(shard: 0), expect: []),
    Step(at: 0, input: Request(shard: 1), expect: [
      Note(Waiting(shard: 1, behind: 0)),
      Wake(in_ms: 5000),
    ]),
    Step(at: 0, input: Request(shard: 1), expect: [
      Note(Waiting(shard: 1, behind: 0)),
      Wake(in_ms: 5000),
    ]),
    Step(at: 5000, input: Tick, expect: [Grant(shard: 1)]),
    // Nothing left, so the duplicate never became a second entry.
    Step(at: 5000, input: Tick, expect: []),
  ])
}

pub fn tick_is_idempotent_test() {
  run(fleet(2), [
    Step(at: 0, input: Request(shard: 0), expect: [Grant(shard: 0)]),
    Step(at: 0, input: Request(shard: 2), expect: [
      Note(Waiting(shard: 2, behind: 0)),
      Wake(in_ms: 30_000),
    ]),
    Step(at: 1000, input: Tick, expect: [Wake(in_ms: 29_000)]),
    Step(at: 1000, input: Tick, expect: [Wake(in_ms: 29_000)]),
  ])
}

pub fn only_a_grant_spends_the_budget_test() {
  let queue = fleet(2)
  assert identify_queue.remaining(queue) == 1000

  let #(queue, _) = identify_queue.step(queue, now_ms: 0, input: Tick)
  assert identify_queue.remaining(queue) == 1000

  let #(queue, _) =
    identify_queue.step(queue, now_ms: 0, input: Request(shard: 0))
  assert identify_queue.remaining(queue) == 999

  // A released grant is not refunded: Discord counted the IDENTIFY, and
  // stalling is recoverable where a reset token is not.
  let #(queue, _) =
    identify_queue.step(queue, now_ms: 10, input: Release(shard: 0))
  assert identify_queue.remaining(queue) == 999

  // A request cancelled before it was ever granted costs nothing at all.
  let #(queue, _) =
    identify_queue.step(queue, now_ms: 10, input: Request(shard: 2))
  let #(queue, _) =
    identify_queue.step(queue, now_ms: 20, input: Release(shard: 2))
  assert identify_queue.remaining(queue) == 999
}

pub fn a_cancelled_request_does_not_spend_the_slot_test() {
  let queue =
    run(fleet(1), [
      Step(at: 0, input: Request(shard: 0), expect: [Grant(shard: 0)]),
      Step(at: 0, input: Release(shard: 0), expect: []),
      Step(at: 0, input: Request(shard: 1), expect: [
        Note(Waiting(shard: 1, behind: 0)),
        Wake(in_ms: 5000),
      ]),
      Step(at: 0, input: Request(shard: 2), expect: [
        Note(Waiting(shard: 2, behind: 1)),
        Wake(in_ms: 5000),
      ]),
      // Shard 1 died while queued, and the tick still costs one grant.
      Step(at: 0, input: Release(shard: 1), expect: [Wake(in_ms: 5000)]),
      Step(at: 5000, input: Tick, expect: [Grant(shard: 2)]),
    ])

  assert identify_queue.remaining(queue) == 998
}

pub fn an_exhausted_budget_denies_rather_than_queues_test() {
  let queue =
    identify_queue.new(max_concurrency: 2, remaining: 1, reset_at_ms: 100_000)

  let queue =
    run(queue, [
      Step(at: 0, input: Request(shard: 0), expect: [
        Grant(shard: 0),
        Note(BudgetLow(remaining: 0)),
      ]),
      Step(at: 0, input: Request(shard: 1), expect: [
        Deny(shard: 1, refresh_at_ms: 100_000),
      ]),
      Step(at: 0, input: Request(shard: 2), expect: [
        Deny(shard: 2, refresh_at_ms: 100_000),
      ]),
      // Nothing is left parked, so no tick repeats the bad news.
      Step(at: 0, input: Tick, expect: []),
      Step(at: 50_000, input: Tick, expect: []),
    ])

  assert identify_queue.remaining(queue) == 0
}

/// A reset instant in the past sends the caller straight back for a denial.
pub fn deny_never_points_at_the_past_test() {
  run(identify_queue.new(max_concurrency: 1, remaining: 0, reset_at_ms: 10), [
    Step(at: 60_000, input: Request(shard: 0), expect: [
      Deny(shard: 0, refresh_at_ms: 65_000),
    ]),
  ])
}

pub fn budget_low_starts_at_the_low_water_mark_test() {
  run(identify_queue.new(max_concurrency: 1, remaining: 52, reset_at_ms: 0), [
    // 51 left, one above the mark.
    Step(at: 0, input: Request(shard: 0), expect: [Grant(shard: 0)]),
    Step(at: 0, input: Release(shard: 0), expect: []),
    Step(at: 5000, input: Request(shard: 1), expect: [
      Grant(shard: 1),
      Note(BudgetLow(remaining: 50)),
    ]),
  ])
}

pub fn waiting_counts_the_queue_ahead_test() {
  run(fleet(1), [
    Step(at: 0, input: Request(shard: 0), expect: [Grant(shard: 0)]),
    Step(at: 0, input: Request(shard: 1), expect: [
      Note(Waiting(shard: 1, behind: 0)),
      Wake(in_ms: 30_000),
    ]),
    Step(at: 0, input: Request(shard: 2), expect: [
      Note(Waiting(shard: 2, behind: 1)),
      Wake(in_ms: 30_000),
    ]),
    Step(at: 0, input: Request(shard: 3), expect: [
      Note(Waiting(shard: 3, behind: 2)),
      Wake(in_ms: 30_000),
    ]),
  ])
}

/// Each grant carries its own budget note; the waiting note and the wake come
/// after every bucket has been served.
pub fn outputs_are_ordered_grants_then_notices_then_wake_test() {
  run(identify_queue.new(max_concurrency: 2, remaining: 51, reset_at_ms: 0), [
    Step(at: 0, input: Request(shard: 1), expect: [
      Grant(shard: 1),
      Note(BudgetLow(remaining: 50)),
    ]),
    Step(at: 0, input: Request(shard: 3), expect: [
      Note(Waiting(shard: 3, behind: 0)),
      Wake(in_ms: 30_000),
    ]),
    Step(at: 0, input: Request(shard: 0), expect: [
      Grant(shard: 0),
      Note(BudgetLow(remaining: 49)),
      Wake(in_ms: 30_000),
    ]),
    Step(at: 0, input: Request(shard: 2), expect: [
      Note(Waiting(shard: 2, behind: 0)),
      Wake(in_ms: 30_000),
    ]),
    Step(at: 100, input: Release(shard: 1), expect: [Wake(in_ms: 4900)]),
    Step(at: 5000, input: Request(shard: 5), expect: [
      Grant(shard: 3),
      Note(BudgetLow(remaining: 48)),
      Note(Waiting(shard: 5, behind: 0)),
      Wake(in_ms: 25_000),
    ]),
  ])
}

pub fn wake_after_is_none_when_nothing_waits_test() {
  let queue = fleet(4)
  assert identify_queue.wake_after(queue, now_ms: 0) == None

  let #(queue, _) =
    identify_queue.step(queue, now_ms: 0, input: Request(shard: 0))
  assert identify_queue.wake_after(queue, now_ms: 0) == None

  let #(queue, _) =
    identify_queue.step(queue, now_ms: 0, input: Request(shard: 4))
  assert identify_queue.wake_after(queue, now_ms: 0) == Some(30_000)

  // An overdue deadline asks for zero, never for a wake in the past.
  assert identify_queue.wake_after(queue, now_ms: 40_000) == Some(0)
}

pub fn solo_still_spaces_a_reconnect_loop_test() {
  run(identify_queue.solo(), [
    Step(at: 0, input: Request(shard: 0), expect: [Grant(shard: 0)]),
    Step(at: 1000, input: Request(shard: 0), expect: [
      Note(Waiting(shard: 0, behind: 0)),
      Wake(in_ms: 4000),
    ]),
    Step(at: 4999, input: Tick, expect: [Wake(in_ms: 1)]),
    Step(at: 5000, input: Tick, expect: [Grant(shard: 0)]),
  ])
}

pub fn hostile_limits_are_clamped_test() {
  // `max_concurrency: 0` is one bucket, never a modulus.
  run(identify_queue.new(max_concurrency: 0, remaining: 1000, reset_at_ms: 0), [
    Step(at: 0, input: Request(shard: 0), expect: [Grant(shard: 0)]),
    Step(at: 0, input: Request(shard: 1), expect: [
      Note(Waiting(shard: 1, behind: 0)),
      Wake(in_ms: 30_000),
    ]),
  ])

  let queue =
    identify_queue.new(max_concurrency: 2, remaining: -5, reset_at_ms: -1)
  assert identify_queue.remaining(queue) == 0
  // The reset instant is left as given: the denial, not the field, is what is
  // held to the present.
  run(queue, [
    Step(at: 0, input: Request(shard: 0), expect: [
      Deny(shard: 0, refresh_at_ms: 5000),
    ]),
  ])
}

fn granted_keys(queue: Queue, ordering: List(Input)) -> #(Queue, List(Int)) {
  list.fold(ordering, #(queue, []), fn(acc, input) {
    let #(queue, keys) = acc
    let #(queue, out) = identify_queue.step(queue, now_ms: 0, input:)
    let granted =
      list.filter_map(out, fn(one) {
        case one {
          Grant(shard:) -> Ok(shard % 2)
          _ -> Error(Nil)
        }
      })
    #(queue, list.append(keys, granted))
  })
}

/// All 120 orders of five inputs at one instant. Which shard wins a bucket
/// depends on who asked first, and should. Which buckets get served, and how
/// much budget that costs, must not: no order may talk a bucket into a second
/// grant, and a release may land before its own request.
pub fn every_arrival_order_serves_the_same_buckets_test() {
  [
    Request(shard: 0),
    Request(shard: 2),
    Request(shard: 1),
    Release(shard: 0),
    Tick,
  ]
  |> list.permutations
  |> list.each(fn(ordering) {
    let #(queue, keys) = granted_keys(fleet(2), ordering)
    assert list.sort(keys, int.compare) == [0, 1]
    assert identify_queue.remaining(queue) == 998
  })
}

/// A fake host with a virtual clock, answering grants the way a real shard
/// would and writing down every one it was given.
type World {
  World(
    queue: Queue,
    now: Int,
    /// Inputs scheduled for a later instant.
    due: List(#(Int, Input)),
    /// Every grant, newest first, as #(instant, shard).
    grants: List(#(Int, Int)),
    denials: List(Int),
  )
}

/// Shard 3's grant is lost, which a lease-only gate never recovers from.
/// Shard 6 is closed with 4009 after IDENTIFY and reconnects.
fn reaction(shard: Int, at: Int, again: Bool) -> List(#(Int, Input)) {
  case shard, again {
    3, _ -> []
    6, False -> [
      #(at + 200, Release(shard: 6)),
      #(at + 1500, Request(shard: 6)),
    ]
    _, _ -> [#(at + 800, Release(shard:))]
  }
}

fn feed(world: World, input: Input) -> World {
  let #(queue, out) =
    identify_queue.step(world.queue, now_ms: world.now, input:)
  list.fold(out, World(..world, queue:), fn(world, one) {
    case one {
      Grant(shard:) -> {
        let again = list.any(world.grants, fn(seen) { seen.1 == shard })
        World(
          ..world,
          grants: [#(world.now, shard), ..world.grants],
          due: list.append(world.due, reaction(shard, world.now, again)),
        )
      }
      Deny(shard:, refresh_at_ms: _) ->
        World(..world, denials: [shard, ..world.denials])
      Note(_) | Wake(_) -> world
    }
  })
}

fn next_instant(world: World) -> Option(Int) {
  let from_gate =
    identify_queue.wake_after(world.queue, now_ms: world.now)
    |> option.map(fn(in_ms) { world.now + in_ms })
  let from_due =
    world.due
    |> list.map(fn(one) { one.0 })
    |> list.reduce(int.min)
    |> option.from_result
  let soonest = case from_gate, from_due {
    None, None -> None
    Some(gate), None -> Some(gate)
    None, Some(due) -> Some(due)
    Some(gate), Some(due) -> Some(int.min(gate, due))
  }
  // The clock must move, or a queue that says "now" forever hangs the driver.
  option.map(soonest, fn(at) { int.max(at, world.now + 1) })
}

fn advance(world: World, fuel: Int) -> World {
  case fuel <= 0 {
    True -> world
    False -> {
      let #(now_due, later) =
        list.partition(world.due, fn(one) { one.0 <= world.now })
      case now_due {
        [_, ..] ->
          list.fold(now_due, World(..world, due: later), fn(world, one) {
            feed(world, one.1)
          })
          |> advance(fuel - 1)
        [] -> {
          let world = feed(world, Tick)
          case next_instant(world) {
            None -> world
            Some(at) -> advance(World(..world, now: at), fuel - 1)
          }
        }
      }
    }
  }
}

fn spacing_holds(times: List(Int)) -> Bool {
  case times {
    [] | [_] -> True
    [first, second, ..rest] ->
      second - first >= 5000 && spacing_holds([second, ..rest])
  }
}

pub fn sixteen_shard_ramp_test() {
  let start = World(queue: fleet(4), now: 0, due: [], grants: [], denials: [])

  let world =
    upto(0, 15)
    |> list.fold(start, fn(world, shard) { feed(world, Request(shard:)) })
    |> advance(500)

  let grants = list.reverse(world.grants)

  // Every shard identified, and shard 6 twice after its 4009.
  let identified =
    grants
    |> list.map(fn(one) { one.1 })
    |> list.unique
    |> list.sort(int.compare)
  assert identified == upto(0, 15)
  assert list.length(grants) == 17
  assert world.denials == []

  // No bucket granted twice inside five seconds.
  upto(0, 3)
  |> list.each(fn(key) {
    let times =
      grants
      |> list.filter(fn(one) { one.1 % 4 == key })
      |> list.map(fn(one) { one.0 })
    assert spacing_holds(times) as { "bucket " <> int.to_string(key) }
  })

  // Bucket 3 pays thirty seconds for shard 3's lost grant, then rejoins the
  // beat. The other three never notice.
  assert grants
    == [
      #(0, 0),
      #(0, 1),
      #(0, 2),
      #(0, 3),
      #(5000, 4),
      #(5000, 5),
      #(5000, 6),
      #(10_000, 8),
      #(10_000, 9),
      #(10_000, 10),
      #(15_000, 12),
      #(15_000, 13),
      #(15_000, 14),
      #(20_000, 6),
      #(30_000, 7),
      #(35_000, 11),
      #(40_000, 15),
    ]
}
