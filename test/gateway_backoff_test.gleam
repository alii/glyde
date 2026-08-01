import gleam/list
import glyde/gateway/backoff
import glyde/rng

/// glyde's defaults. Discord's guidance is a base of a second or so.
const base = 1000

const max = 64_000

fn floor_of(attempts: Int) -> Int {
  let #(_, delay) = backoff.delay(rng.fixed(0), attempts:, base:, max:)
  delay
}

fn ceiling_of(attempts: Int) -> Int {
  let #(_, delay) =
    backoff.delay(rng.fixed(999_999_999), attempts:, base:, max:)
  delay
}

/// `n` consecutive delays at one attempt number.
fn draws(seed: Int, attempts: Int, n: Int) -> List(Int) {
  draws_loop(rng.seed(seed), attempts, n, [])
}

fn draws_loop(
  generator: rng.Rng,
  attempts: Int,
  n: Int,
  acc: List(Int),
) -> List(Int) {
  case n <= 0 {
    True -> list.reverse(acc)
    False -> {
      let #(next, delay) = backoff.delay(generator, attempts:, base:, max:)
      draws_loop(next, attempts, n - 1, [delay, ..acc])
    }
  }
}

// The ladder

/// One row per rung, with the jitter pinned to the bottom of its window so
/// each row is exactly `capped / 2`.
pub fn the_ladder_doubles_then_saturates_test() {
  let table = [
    #(1, 500),
    #(2, 1000),
    #(3, 2000),
    #(4, 4000),
    #(5, 8000),
    #(6, 16_000),
    #(7, 32_000),
    // The ceiling bites here and never lets go.
    #(8, 32_000),
    #(9, 32_000),
    #(16, 32_000),
    #(17, 32_000),
    #(32, 32_000),
  ]
  list.each(table, fn(row) {
    let #(attempts, expected) = row
    assert floor_of(attempts) == expected
  })
}

/// Not yet failed means the bottom rung, not a negative exponent.
pub fn attempts_below_one_sit_on_the_first_rung_test() {
  assert floor_of(0) == floor_of(1)
  assert floor_of(-1) == floor_of(1)
  assert floor_of(-5000) == floor_of(1)
}

/// The wait covers the top half of the window, so it never collapses to
/// nothing and never reaches the ceiling.
pub fn the_window_is_the_top_half_of_the_ceiling_test() {
  let table = [#(1, 500, 999), #(4, 4000, 7999), #(7, 32_000, 63_999)]
  list.each(table, fn(row) {
    let #(attempts, low, high) = row
    assert floor_of(attempts) == low
    assert ceiling_of(attempts) == high
  })
}

/// A `fixed` generator is a fraction of the jitter window, so half of one
/// sits halfway between the floor and the ceiling.
pub fn a_half_fixed_generator_lands_mid_window_test() {
  let #(_, delay) =
    backoff.delay(rng.fixed(500_000_000), attempts: 7, base:, max:)
  assert delay == 48_000
  assert floor_of(7) == 32_000
  assert ceiling_of(7) == 63_999
}

pub fn every_draw_lands_inside_its_window_test() {
  list.each([1, 3, 5, 7, 9, 40], fn(attempts) {
    let low = floor_of(attempts)
    let delays = draws(11, attempts, 200)
    assert list.all(delays, fn(d) { d >= low && d < low * 2 })
  })
}

/// Two shards that dropped together must not come back together.
pub fn different_seeds_reconnect_at_different_times_test() {
  assert draws(1, 7, 20) != draws(2, 7, 20)
  assert draws(1, 7, 20) == draws(1, 7, 20)
}

// Saturation

/// `2 ^ 4999` is a bignum, so a ladder that shifts before it clamps spends
/// real time building a number it throws away.
pub fn a_huge_attempt_count_saturates_test() {
  assert backoff.delay(rng.at(1), attempts: 5000, base:, max:)
    == #(rng.at(48_271), 48_271)

  assert floor_of(5000) == 32_000
  assert ceiling_of(5000) == 63_999
}

/// A shard down for a week waits as long as one down for an hour.
pub fn saturation_is_flat_past_the_clamp_test() {
  let far = [17, 32, 100, 5000, 1_000_000, 2_000_000_000]
  list.each(far, fn(attempts) {
    assert backoff.delay(rng.seed(1), attempts:, base:, max:)
      == backoff.delay(rng.seed(1), attempts: 17, base:, max:)
  })
}

// The attempt counter

pub fn bump_stops_at_the_cap_test() {
  assert backoff.bump(0) == 1
  assert backoff.bump(1) == 2
  assert backoff.bump(30) == 31
  assert backoff.bump(31) == backoff.attempt_cap
  assert backoff.bump(backoff.attempt_cap) == backoff.attempt_cap
  assert backoff.bump(1_000_000) == backoff.attempt_cap
}

/// The ladder has already saturated well below the cap. Lowered under the
/// exponent clamp it would quietly stop climbing.
pub fn the_counter_cap_sits_above_the_ladder_test() {
  assert floor_of(backoff.attempt_cap) == floor_of(17)
}

pub fn exhausted_reads_the_limit_test() {
  assert !backoff.exhausted(3, limit: 4)
  assert backoff.exhausted(4, limit: 4)
  assert backoff.exhausted(5, limit: 4)
}

/// `bump` saturates, so a limit past the cap is a shard that never stops. It
/// is clamped rather than left as a way to switch the halt off by accident.
pub fn exhausted_clamps_a_limit_the_counter_cannot_reach_test() {
  assert backoff.exhausted(backoff.attempt_cap, limit: 1_000_000)
  assert !backoff.exhausted(backoff.attempt_cap - 1, limit: 1_000_000)

  // And below 1 is 1, so the first failure is the last.
  assert backoff.exhausted(1, limit: 0)
  assert !backoff.exhausted(0, limit: 0)
}

// Tuning a caller can get wrong

/// A ceiling of nothing is a wait of nothing, on every rung. A state machine
/// may not panic and a caller may not be handed a negative delay to arm.
pub fn degenerate_tuning_yields_zero_test() {
  let table = [
    #(0, 64_000),
    #(1000, 0),
    #(0, 0),
    #(1, 1),
    #(-1000, 64_000),
    #(1000, -5),
    #(-1000, -5),
  ]
  list.each(table, fn(row) {
    let #(base_ms, max_ms) = row
    list.each([1, 7, 5000], fn(attempts) {
      let #(_, delay) =
        backoff.delay(rng.seed(1), attempts:, base: base_ms, max: max_ms)
      assert delay == 0
    })
  })
}

/// The ladder must not climb through a cap it was told to respect.
pub fn a_ceiling_below_the_base_still_holds_test() {
  let #(_, delay) =
    backoff.delay(rng.fixed(0), attempts: 9, base: 5000, max: 2000)
  assert delay == 1000
}

// Determinism

/// One draw per call whatever the tuning, so the stream position depends on
/// the reconnect count and never on the config.
pub fn one_call_is_one_draw_test() {
  let after = rng.at(48_271)
  let table = [#(1, 1000, 64_000), #(5000, 1000, 64_000), #(3, 0, 0)]
  list.each(table, fn(row) {
    let #(attempts, base_ms, max_ms) = row
    let #(generator, _) =
      backoff.delay(rng.at(1), attempts:, base: base_ms, max: max_ms)
    assert generator == after
  })
}

/// A fixed generator does not advance, so a conformance test can assert a
/// whole shard.
pub fn a_fixed_generator_comes_back_unchanged_test() {
  let #(generator, _) = backoff.delay(rng.fixed(0), attempts: 4, base:, max:)
  assert generator == rng.fixed(0)
}
