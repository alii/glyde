//// The clock every deadline in the Erlang transport is read from, and the
//// sleep that waits one out. Both have a trap the BEAM puts there.

import glyde/internal/timing

/// `erlang:monotonic_time(millisecond)` on its own is about -576,460,752,000
/// for the life of the VM, so a deadline held next to a `0` would read as long
/// past. Zeroing it at VM start is what makes the number safe to do arithmetic
/// on, which is the whole reason the timeout paths can hold a deadline.
pub fn now_counts_up_from_the_vm_starting_test() {
  assert timing.now() >= 0

  // No test run lasts an hour, so anything bigger is the raw monotonic clock
  // leaking back in rather than an uptime.
  assert timing.now() < 3_600_000
}

pub fn now_only_goes_forwards_test() {
  let first = timing.now()
  timing.sleep(20)
  let second = timing.now()

  assert second >= first
  assert second - first >= 20
}

/// A deadline that has already gone by leaves a negative wait, and `receive
/// after` raises `timeout_value` on one, which would take a whole bot down.
/// The clamp is in `sleep` so no caller has to remember it.
pub fn sleep_treats_a_wait_already_over_as_no_wait_test() {
  let before = timing.now()
  timing.sleep(0)
  timing.sleep(-1)
  timing.sleep(-576_460_752_000)

  assert timing.now() - before < 1000
}
