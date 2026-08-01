//// How long a shard waits before its next connection attempt: exponential,
//// capped, half jitter, so the wait lands in `[ceiling / 2, ceiling)`. Full
//// jitter can draw near zero and put a shard back into the failure at once.

import gleam/int
import glyde/rng.{type Rng}

/// Where the ladder stops doubling. 2^16 on a one second base is about 18
/// hours.
const max_exponent = 16

/// Stops the failure counter growing for the length of an outage. The ladder
/// saturates long before this. Our choice, not Discord's.
pub const attempt_cap: Int = 32

pub fn bump(attempts: Int) -> Int {
  int.min(attempts + 1, attempt_cap)
}

/// Whether a shard has spent this many attempts in a row without reaching
/// READY. A limit past `attempt_cap` could never be met, so it is clamped.
pub fn exhausted(attempts: Int, limit limit: Int) -> Bool {
  attempts >= int.clamp(limit, min: 1, max: attempt_cap)
}

/// The wait before attempt number `attempts`, where 1 is the first after a
/// connection was lost. `base` and `max` are milliseconds. A wait Discord
/// mandates, as after an INVALID_SESSION, is a floor on this, not a second one.
pub fn delay(
  generator: Rng,
  attempts attempts: Int,
  base base: Int,
  max max: Int,
) -> #(Rng, Int) {
  // Nonsense tuning must not draw a negative wait and arm a timer in the past.
  let ceiling = int.max(0, int.min(base * rung(attempts - 1), max))
  let half = ceiling / 2
  let #(generator, jitter) = rng.below(generator, half)
  #(generator, half + jitter)
}

/// `2^steps`, with the ceiling built in: doubling once per recursive step
/// means an uncapped attempt count would build a huge number.
fn rung(steps: Int) -> Int {
  case int.clamp(steps, min: 0, max: max_exponent) {
    0 -> 1
    n -> 2 * rung(n - 1)
  }
}
