//// Deterministic randomness: every draw is a pure function of a
//// caller-supplied seed threaded through the state. Discord asks for a
//// jittered first heartbeat and a randomised wait before reconnecting.
////
//// Never use it for a websocket mask, a handshake nonce or a token. Knowing
//// the seed is knowing every draw.

import gleam/int
import gleam/option.{type Option, None, Some}

/// A generator: `seed` or `at` for the real one, `fixed` for a test.
///
/// Opaque because the cycle only holds for a state in [1, modulus - 1]. State
/// 0 is the fixed point, so every reconnect would draw the same jitter, and a
/// negative state draws negative jitter and arms a timer in the past.
pub opaque type Rng {
  Minstd(state: Int)
  Fixed(value: Int)
}

/// 2^31 - 1. Prime, so every state but 0 sits on the full-period cycle.
const modulus = 2_147_483_647

/// A primitive root of `modulus`, from Park and Miller's revised minimal
/// standard.
const multiplier = 48_271

/// The range `Fixed` reads its value against: every `fixed` value is a
/// fraction of this, whichever kind of draw reads it. Our choice.
const fixed_span = 1_000_000_000

/// Any `n` works, folded onto the cycle. Distinct seeds below 2^31 stay
/// distinct; `system_time_ms % 2_000_000_000` is a fine source.
pub fn seed(n: Int) -> Rng {
  Minstd(scramble(fold(n)))
}

/// Onto [1, modulus - 1]. `%` keeps the sign of the left side, so a negative
/// seed lands below the cycle and has to come back up.
fn fold(n: Int) -> Int {
  let folded = { n - 1 } % { modulus - 1 }
  case folded < 0 {
    True -> folded + modulus
    False -> folded + 1
  }
}

/// A generator on an exact cycle position, folded like `seed` but not
/// scrambled, so `at(1)` really is state 1. A shard wants `seed`; this is for
/// a test that names the sequence.
pub fn at(state: Int) -> Rng {
  Minstd(fold(state))
}

/// Where a generator sits on the cycle. `None` for `Fixed`, which has no
/// position.
pub fn state(rng: Rng) -> Option(Int) {
  case rng {
    Minstd(state) -> Some(state)
    Fixed(_) -> None
  }
}

/// A first draw is close to proportional to the state, so without this shards
/// seeded 1, 2 and 3 would jitter by 0ms, 1ms and 2ms and arrive together.
fn scramble(state: Int) -> Int {
  advance(advance(state))
}

/// A generator that never advances, reading its value as billionths of
/// whatever is asked for: `fixed(0)` pins the low end of every range,
/// `fixed(500_000_000)` the middle, `fixed(999_999_999)` the high end.
pub fn fixed(value: Int) -> Rng {
  Fixed(value)
}

/// A value in `[0, bound)`. A non-positive bound gives 0 rather than
/// crashing: a state machine may not panic.
pub fn below(rng: Rng, bound: Int) -> #(Rng, Int) {
  draw(rng, 0, bound)
}

/// A value in `[low, high)`. An empty range yields `low`.
pub fn between(rng: Rng, low low: Int, high high: Int) -> #(Rng, Int) {
  draw(rng, low, high)
}

/// A float in `[0, 1)`. Discord's heartbeat rule is `interval * jitter`.
pub fn unit(rng: Rng) -> #(Rng, Float) {
  case rng {
    Fixed(value) -> #(rng, fraction(value))
    Minstd(state) -> {
      let state = advance(state)
      #(Minstd(state), int.to_float(state) /. int.to_float(modulus))
    }
  }
}

/// What `Fixed` means everywhere: its value as a fraction of `fixed_span`,
/// in [0, 1).
fn fraction(value: Int) -> Float {
  int.to_float(int.clamp(value, 0, fixed_span - 1)) /. int.to_float(fixed_span)
}

fn draw(rng: Rng, low: Int, high: Int) -> #(Rng, Int) {
  let span = high - low
  case rng {
    // Multiply before dividing: the product is exact at any size, and
    // dividing first would floor every fraction to 0.
    Fixed(value) if span > 0 -> {
      let scaled = span * int.clamp(value, 0, fixed_span - 1) / fixed_span
      #(rng, low + scaled)
    }
    Fixed(_) -> #(rng, low)

    // Advances even on an empty range: position depends on draw count only.
    Minstd(state) -> {
      let state = advance(state)
      case span > 0 {
        True -> #(Minstd(state), low + state % span)
        False -> #(Minstd(state), low)
      }
    }
  }
}

fn advance(state: Int) -> Int {
  state * multiplier % modulus
}
