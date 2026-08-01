//// One line for what a `gleam/dynamic/decode` run complained about.
////
//// Stdlib only, and here rather than on either caller: a gateway dispatch
//// that would not fit and a REST body that would not decode say the same
//// thing, and the REST layer should not have to import the gateway to say it.

import gleam/dynamic/decode
import gleam/string

/// The first error is the one worth reading; the rest are it seen from
/// further up.
pub fn describe(errors: List(decode.DecodeError)) -> String {
  case errors {
    [] -> "it was not the shape we expected"
    [decode.DecodeError(expected:, found:, path:), ..] ->
      "expected "
      <> expected
      <> ", found "
      <> found
      <> case path {
        [] -> ""
        path -> " at " <> string.join(path, ".")
      }
  }
}
