import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import glyde/rng

/// Bound 1 leaves exactly one legal answer, so this is a bare advance.
fn advance(generator: rng.Rng) -> rng.Rng {
  let #(next, _) = rng.below(generator, 1)
  next
}

fn advance_times(generator: rng.Rng, n: Int) -> rng.Rng {
  case n <= 0 {
    True -> generator
    False -> advance_times(advance(generator), n - 1)
  }
}

fn state_of(generator: rng.Rng) -> Int {
  let assert Some(state) = rng.state(generator)
  state
}

/// `n` draws, threading the generator through the way the core does.
fn take(
  generator: rng.Rng,
  n: Int,
  draw: fn(rng.Rng) -> #(rng.Rng, a),
) -> List(a) {
  take_loop(generator, n, draw, [])
}

fn take_loop(
  generator: rng.Rng,
  n: Int,
  draw: fn(rng.Rng) -> #(rng.Rng, a),
  acc: List(a),
) -> List(a) {
  case n <= 0 {
    True -> list.reverse(acc)
    False -> {
      let #(next, value) = draw(generator)
      take_loop(next, n - 1, draw, [value, ..acc])
    }
  }
}

fn states(generator: rng.Rng, n: Int) -> List(Int) {
  take(generator, n, fn(g) {
    let next = advance(g)
    #(next, state_of(next))
  })
}

/// The published MINSTD sequence from seed 1.
pub fn minstd_sequence_from_seed_1_test() {
  assert states(rng.at(1), 8)
    == [
      48_271, 182_605_794, 1_291_394_886, 1_914_720_637, 2_078_669_041,
      407_355_683, 1_105_902_161, 854_716_505,
    ]
}

/// MINSTD's published check value: from state 1, the 10_000th state is
/// 399_268_537. The first few terms would not catch a bit lost mid-cycle.
pub fn minstd_check_value_at_10_000_test() {
  assert state_of(advance_times(rng.at(1), 10_000)) == 399_268_537
}

/// 0 is the fixed point, so leaving 1..2^31-2 would end the cycle.
pub fn the_cycle_never_leaves_the_legal_range_test() {
  let seen = states(rng.at(7), 5000)
  assert list.all(seen, fn(state) { state >= 1 && state <= 2_147_483_646 })
}

/// A draw is near proportional to the state, so a fleet seeded 1, 2, 3 would
/// jitter a millisecond apart out of 41 seconds and stay a herd.
pub fn consecutive_seeds_spread_across_the_range_test() {
  let jitters =
    list.map([1, 2, 3, 4, 5, 6, 7, 8], fn(n) {
      let #(_, u) = rng.unit(rng.seed(n))
      float.truncate(41_250.0 *. u)
    })

  assert list.length(list.unique(jitters)) == 8

  // Spread over most of the interval, not clustered at one end.
  let assert Ok(highest) = list.reduce(jitters, int.max)
  let assert Ok(lowest) = list.reduce(jitters, int.min)
  assert highest - lowest > 20_000
}

/// 0 is the generator's fixed point, so no seed may produce it.
pub fn awkward_seeds_are_folded_into_range_test() {
  let awkward = [
    0, -1, -2_147_483_646, 2_147_483_647, 2_147_483_648, 4_294_967_294,
    1_000_000_000_000,
  ]
  list.each(awkward, fn(n) {
    let state = state_of(rng.seed(n))
    assert state >= 1
    assert state <= 2_147_483_646
  })
}

/// State 0 repeats forever, so every reconnect would jitter alike, and a
/// negative state draws negative jitter. `at` folds both onto the cycle, so
/// neither is nameable.
pub fn at_cannot_name_an_illegal_state_test() {
  let illegal = [0, -1, -48_271, -2_147_483_646]
  list.each(illegal, fn(n) {
    let generator = rng.at(n)
    let state = state_of(generator)
    assert state >= 1
    assert state <= 2_147_483_646
    assert advance(generator) != generator
  })
}

/// Inside the cycle `at` changes nothing, so a table test can name a state.
pub fn at_is_the_identity_on_the_cycle_test() {
  list.each([1, 2, 7, 48_271, 1_000_000_123, 2_147_483_646], fn(n) {
    assert rng.state(rng.at(n)) == Some(n)
  })
}

/// A fixed generator has no place on the cycle, so no state to report.
pub fn a_fixed_generator_has_no_state_test() {
  assert rng.state(rng.fixed(0)) == None
}

/// Two shards started a millisecond apart start in different places.
pub fn a_reduced_millisecond_clock_lands_on_the_cycle_test() {
  let reduced = 1_763_000_000_123 % 2_000_000_000
  assert reduced == 1_000_000_123

  // Pinned to the arithmetic: a range check would pass on a wrong multiply.
  assert rng.seed(reduced) == advance_times(rng.at(1_000_000_123), 2)

  assert rng.seed(reduced) != rng.seed(reduced + 1)
}

/// Adapters are told to reduce a clock before seeding, and a nanosecond one
/// still has to fold to a legal state.
pub fn a_seed_past_2_53_is_still_a_legal_state_test() {
  let nanoseconds = 1_763_000_000_123 * 1_000_000
  let state = state_of(rng.seed(nanoseconds))
  assert state >= 1
  assert state <= 2_147_483_646
}

/// Two shards seeded alike jitter alike, which is why the seed is a required
/// argument at `gateway.new`.
pub fn the_same_seed_gives_the_same_stream_test() {
  let draw = fn(g) { rng.below(g, 41_250) }
  assert take(rng.seed(99), 20, draw) == take(rng.seed(99), 20, draw)
}

pub fn a_different_seed_gives_a_different_stream_test() {
  let draw = fn(g) { rng.below(g, 41_250) }
  assert take(rng.seed(1), 20, draw) != take(rng.seed(2), 20, draw)
}

/// One step each, so a jitter site can change shape without shifting every
/// later draw.
pub fn every_draw_advances_one_step_test() {
  let #(after_below, _) = rng.below(rng.at(1), 100)
  let #(after_between, _) = rng.between(rng.at(1), low: 10, high: 100)
  let #(after_unit, _) = rng.unit(rng.at(1))

  assert after_below == rng.at(48_271)
  assert after_between == after_below
  assert after_unit == after_below
}

pub fn below_stays_inside_its_bound_test() {
  list.each([1, 2, 7, 1000, 41_250, 2_147_483_646], fn(bound) {
    let values = take(rng.seed(3), 300, fn(g) { rng.below(g, bound) })
    assert list.all(values, fn(v) { v >= 0 && v < bound })
  })
}

/// An off-by-one that never draws `bound - 1` passes a range check.
pub fn below_covers_its_whole_range_test() {
  let values = take(rng.seed(1), 200, fn(g) { rng.below(g, 6) })
  assert list.sort(list.unique(values), int.compare) == [0, 1, 2, 3, 4, 5]
}

/// The backoff ladder hands `below` a `capped / 2` that can be 0, and a state
/// machine may not panic.
pub fn below_a_non_positive_bound_yields_zero_test() {
  list.each([0, -1, -41_250], fn(bound) {
    let #(next, value) = rng.below(rng.at(1), bound)
    assert value == 0
    // The draw still happened, so the stream does not depend on the bound.
    assert next == rng.at(48_271)
  })
}

/// Discord asks for a wait of 1 to 5 seconds before re-identifying after an
/// INVALID_SESSION, which is `between(1000, 5001)` in milliseconds.
pub fn between_stays_inside_the_op_9_window_test() {
  let values =
    take(rng.seed(1), 2000, fn(g) { rng.between(g, low: 1000, high: 5001) })
  assert list.all(values, fn(v) { v >= 1000 && v <= 5000 })
  assert list.contains(values, 1000)
  assert list.contains(values, 5000)
}

pub fn between_an_empty_range_yields_low_test() {
  let #(_, same) = rng.between(rng.seed(1), low: 5, high: 5)
  assert same == 5

  let #(_, backwards) = rng.between(rng.seed(1), low: 5, high: 1)
  assert backwards == 5

  let #(_, negative) = rng.between(rng.seed(1), low: -20, high: -20)
  assert negative == -20
}

pub fn between_handles_a_negative_low_test() {
  let values =
    take(rng.seed(4), 300, fn(g) { rng.between(g, low: -100, high: 100) })
  assert list.all(values, fn(v) { v >= -100 && v < 100 })
}

pub fn unit_stays_in_the_half_open_interval_test() {
  let values = take(rng.seed(1), 500, fn(g) { rng.unit(g) })
  assert list.all(values, fn(u) { u >=. 0.0 && u <. 1.0 })
}

/// The scale is the modulus, not 2^31 and not the state's own maximum.
pub fn unit_divides_by_the_modulus_test() {
  let #(_, first) = rng.unit(rng.at(1))
  assert first == 48_271.0 /. 2_147_483_647.0
}

/// Discord's rule for the first heartbeat: wait `heartbeat_interval * jitter`
/// with jitter in [0, 1), so the delay never reaches a full interval.
pub fn the_discord_jitter_formula_stays_inside_one_interval_test() {
  let interval_ms = 41_250
  let delays =
    take(rng.seed(1), 500, fn(g) {
      let #(next, u) = rng.unit(g)
      #(next, float.truncate(int.to_float(interval_ms) *. u))
    })
  assert list.all(delays, fn(d) { d >= 0 && d < interval_ms })
}

/// A `fixed` value is billionths of the range: 0 pins the low end,
/// 500_000_000 the middle, 999_999_999 the high end.
pub fn fixed_pins_a_fraction_of_the_range_test() {
  let table = [
    #(0, 0, 41_250, 0),
    #(250_000_000, 0, 41_250, 10_312),
    #(500_000_000, 0, 41_250, 20_625),
    // 70% of 41_250 is exactly 28_875. Scaling through a float rounds it
    // down to 28_874.
    #(700_000_000, 0, 41_250, 28_875),
    #(999_999_999, 0, 41_250, 41_249),
    #(0, 1000, 5001, 1000),
    #(500_000_000, 1000, 5001, 3000),
    #(999_999_999, 1000, 5001, 5000),
    // Out of range in both directions, and an empty range.
    #(-5, 0, 100, 0),
    #(2_000_000_000, 0, 100, 99),
    #(7, 5, 5, 5),
  ]
  list.each(table, fn(row) {
    let #(value, low, high, expected) = row
    let #(generator, drawn) = rng.between(rng.fixed(value), low:, high:)
    assert drawn == expected
    assert generator == rng.fixed(value)
  })
}

pub fn fixed_pins_below_the_same_way_test() {
  let #(_, low) = rng.below(rng.fixed(0), 41_250)
  assert low == 0

  let #(_, half) = rng.below(rng.fixed(500_000_000), 41_250)
  assert half == 20_625

  let #(_, high) = rng.below(rng.fixed(999_999_999), 41_250)
  assert high == 41_249

  let #(_, empty) = rng.below(rng.fixed(999_999_999), 0)
  assert empty == 0
}

/// One `fixed` value is one fraction whichever draw reads it. A `draw` that
/// clamped the raw value instead would pin the middle of the unit interval
/// and the bottom of any range wider than the value.
pub fn fixed_reads_the_same_fraction_in_both_paths_test() {
  let generator = rng.fixed(500_000_000)

  let #(_, u) = rng.unit(generator)
  assert u == 0.5

  let #(_, drawn) = rng.between(generator, low: 0, high: 41_250)
  assert drawn == 41_250 * 500_000_000 / 1_000_000_000
}

pub fn fixed_pins_the_unit_interval_test() {
  let #(generator, low) = rng.unit(rng.fixed(0))
  assert low == 0.0
  assert generator == rng.fixed(0)

  let #(_, high) = rng.unit(rng.fixed(999_999_999))
  assert high == 0.999999999
  assert high <. 1.0

  let #(_, clamped) = rng.unit(rng.fixed(-1))
  assert clamped == 0.0
}

/// A fixed generator does not advance, so a whole-state assertion can name
/// the generator the test put there.
pub fn fixed_never_advances_test() {
  let generator = rng.fixed(500_000_000)
  let values = take(generator, 5, fn(g) { rng.below(g, 41_250) })
  assert values == [20_625, 20_625, 20_625, 20_625, 20_625]
  assert advance_times(generator, 5) == generator
}
