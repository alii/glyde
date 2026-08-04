//// The three states a JSON key can be in, which `Option` cannot say: the key
//// is missing, the key is `null`, or the key holds a value.
////
//// Both directions need all three. Encoding a PATCH, `parent_id: null` clears
//// a channel's category and omitting the key leaves the category alone.
//// Decoding, `wire.tri_field` builds one and `glyde/message` keeps it, so
//// "Discord never resolved this" stays apart from "it was deleted".
////
//// `Present`, not `Set`, so an unqualified import does not shadow `gleam/set`.

import gleam/option.{type Option, None, Some}

pub type Field(a) {
  Absent
  Null
  Present(a)
}

pub fn map(field: Field(a), with fun: fn(a) -> b) -> Field(b) {
  case field {
    Absent -> Absent
    Null -> Null
    Present(value) -> Present(fun(value))
  }
}

/// `None` becomes `Absent`, so this cannot spell "clear".
pub fn from_option(option: Option(a)) -> Field(a) {
  case option {
    Some(value) -> Present(value)
    None -> Absent
  }
}

/// `None` becomes `Null`, for a PATCH that clears the field.
pub fn or_null(option: Option(a)) -> Field(a) {
  case option {
    Some(value) -> Present(value)
    None -> Null
  }
}

pub fn is_absent(field: Field(a)) -> Bool {
  case field {
    Absent -> True
    Null | Present(_) -> False
  }
}
