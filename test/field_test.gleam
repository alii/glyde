import gleam/option.{None, Some}
import glyde/field

/// Turning `Null` into `Absent` changes "clear this" into "leave it".
pub fn map_keeps_the_three_states_apart_test() {
  let bump = fn(n) { n + 1 }
  assert field.map(field.Absent, bump) == field.Absent
  assert field.map(field.Null, bump) == field.Null
  assert field.map(field.Present(1), bump) == field.Present(2)
}

pub fn map_changes_the_type_test() {
  assert field.map(field.Present(1), fn(n) { [n] }) == field.Present([1])
}

/// `None` means nothing to send, not clear the field.
pub fn from_option_never_produces_null_test() {
  assert field.from_option(Some(7)) == field.Present(7)
  assert field.from_option(None) == field.Absent
}

pub fn is_absent_test() {
  assert field.is_absent(field.Absent)
  assert !field.is_absent(field.Null)
  assert !field.is_absent(field.Present(1))
}
