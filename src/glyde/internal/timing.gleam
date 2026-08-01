//// The monotonic clock. Zeroed at VM start, so it counts up from 0 and only
//// differences are ever read.

import gleam/dynamic.{type Dynamic}
import gleam/int

/// Milliseconds on a clock that only goes forwards.
pub fn now() -> Int {
  // `monotonic_time` starts deeply negative on the BEAM, so a `0` literal
  // would read as "in the future". Zero it at VM start.
  monotonic_time(Millisecond)
  - convert_time_unit(system_info(StartTime), Native, Millisecond)
}

/// `timer:sleep` is `receive after`, so nothing is spawned.
pub fn sleep(in_ms: Int) -> Nil {
  // `receive after` raises on a negative timeout, so the clamp belongs next to
  // the mechanism that needs it rather than in every deadline that feeds it.
  let _ = timer_sleep(int.max(0, in_ms))
  Nil
}

/// A nullary constructor is the atom of its own name, so `monotonic_time/1`
/// gets its argument without an FFI file.
type TimeUnit {
  Millisecond

  /// The VM's own unit, which `system_info(start_time)` answers in.
  Native
}

/// The atom `start_time`, for `erlang:system_info/1`.
type SystemInfo {
  StartTime
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: TimeUnit) -> Int

/// The monotonic time the VM started at, in native units.
@external(erlang, "erlang", "system_info")
fn system_info(item: SystemInfo) -> Int

@external(erlang, "erlang", "convert_time_unit")
fn convert_time_unit(value: Int, from: TimeUnit, to: TimeUnit) -> Int

/// Returns the atom `ok`, which no Gleam type names. `Dynamic` and a `let _`,
/// the same as the other discarded FFI returns.
@external(erlang, "timer", "sleep")
fn timer_sleep(in_ms: Int) -> Dynamic
