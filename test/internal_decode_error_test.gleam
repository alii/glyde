import gleam/dynamic/decode
import glyde/internal/decode_error

/// The first decode error is the one worth reading, path and all.
pub fn describe_names_the_field_test() {
  assert decode_error.describe([
      decode.DecodeError(expected: "String", found: "Int", path: ["user", "id"]),
      decode.DecodeError(expected: "Message", found: "Nil", path: []),
    ])
    == "expected String, found Int at user.id"

  assert decode_error.describe([]) == "it was not the shape we expected"
}

/// A top level mismatch has no path to name, so the sentence stops early.
pub fn describe_omits_an_empty_path_test() {
  assert decode_error.describe([
      decode.DecodeError(expected: "Dict", found: "List", path: []),
    ])
    == "expected Dict, found List"
}
