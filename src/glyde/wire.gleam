//// Decoding and encoding helpers for Discord's JSON.
////
//// Discord tells an absent key apart from a null one, writes the same numeric
//// field as `2` or `2.0`, and adds enum values without warning. Every model
//// needs the same handling for all three.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import glyde/field

/// Absent, null, or set. On a PATCH those are different instructions: absent
/// leaves the field alone, null clears it.
pub type Field(a) =
  field.Field(a)

pub fn absent() -> Field(a) {
  field.Absent
}

pub fn null() -> Field(a) {
  field.Null
}

pub fn present(value: a) -> Field(a) {
  field.Present(value)
}

/// `None` becomes absent. Use `nullable` when it should clear the field.
pub fn opt(value: Option(a)) -> Field(a) {
  field.from_option(value)
}

/// `None` becomes null, for a PATCH that clears the field.
pub fn nullable(value: Option(a)) -> Field(a) {
  case value {
    Some(v) -> field.Present(v)
    None -> field.Null
  }
}

/// Empty becomes absent: Discord reads `[]` as "clear this" on several
/// endpoints.
pub fn opt_list(values: List(a)) -> Field(List(a)) {
  case values {
    [] -> field.Absent
    _ -> field.Present(values)
  }
}

/// Build an object, leaving absent keys out entirely. An unset key has to
/// vanish rather than become `null`: Discord reads a `null` as "clear this",
/// so writing one for every untouched field wipes half the record on a PATCH.
pub fn object(entries: List(#(String, Field(Json)))) -> Json {
  json.object(list.filter_map(entries, resolve))
}

/// `object` one step short of a document, for `rest/body.Form`, which writes
/// the `attachments` array into the entries before encoding them.
pub fn entries(entries: List(#(String, Field(Json)))) -> List(#(String, Json)) {
  list.filter_map(entries, resolve)
}

fn resolve(entry: #(String, Field(Json))) -> Result(#(String, Json), Nil) {
  let #(key, value) = entry
  case value {
    field.Absent -> Error(Nil)
    field.Null -> Ok(#(key, json.null()))
    field.Present(encoded) -> Ok(#(key, encoded))
  }
}

/// `Absent` and `Null` pass through, so `encode` never runs on them.
pub fn put(value: Field(a), with encode: fn(a) -> Json) -> Field(Json) {
  field.map(value, encode)
}

pub fn put_list(
  values: Field(List(a)),
  with encode: fn(a) -> Json,
) -> Field(Json) {
  field.map(values, fn(items) { json.array(items, encode) })
}

/// A number Discord may write with or without a decimal point: `retry_after`
/// is documented as fractional seconds and then sent as `30` when it is whole.
/// `decode.float` refuses one form and `decode.int` the other.
pub fn number() -> Decoder(Float) {
  decode.one_of(decode.float, or: [decode.map(decode.int, int.to_float)])
  |> decode.map(fold_negative_zero)
  |> decode.then(exact_float)
}

/// A number Discord documents as whole. Accepts `2` and `2.0`, rejects `2.5`.
/// Anything that can exceed `max_exact` is a String, see `glyde/id`.
pub fn integer() -> Decoder(Int) {
  decode.one_of(decode.int, or: [decode.then(decode.float, whole)])
  |> decode.then(exact)
}

/// The write side of `number`: a whole Float goes out as `3`, not `3.0`.
/// Discord reads either, and picking one keeps a request body byte-exact.
pub fn number_json(value: Float) -> Json {
  case float.floor(value) == value && within_exact(value) {
    True -> json.int(float.round(value))
    False -> json.float(value)
  }
}

/// OTP 27 does not call `-0.0` equal to `0.0`. Adding zero folds it, and is
/// exact for every other value.
fn fold_negative_zero(value: Float) -> Float {
  value +. 0.0
}

/// Our ceiling on a number, 2^53 - 1. Every field decoded as a whole one is a
/// sequence, an interval, an opcode or a bitfield, so wider is malformed, and
/// a Float wider than this has already lost its low digits.
const max_exact: Int = 9_007_199_254_740_991

/// The one gate on magnitude, after `one_of` so it covers both branches.
fn exact(value: Int) -> Decoder(Int) {
  case value <= max_exact && value >= -max_exact {
    True -> decode.success(value)
    False -> decode.failure(0, "Int within 2^53")
  }
}

fn exact_float(value: Float) -> Decoder(Float) {
  case within_exact(value) {
    True -> decode.success(value)
    False -> decode.failure(0.0, "Float within 2^53")
  }
}

fn within_exact(value: Float) -> Bool {
  float.absolute_value(value) <=. int.to_float(max_exact)
}

/// Whole, checked with `floor` rather than a round trip, so `-0.0` is never
/// compared against `0.0`, which OTP 27 calls unequal. `exact` takes the
/// magnitude from here.
fn whole(value: Float) -> Decoder(Int) {
  case float.floor(value) == value {
    True -> decode.success(float.round(value))
    False -> decode.failure(0, "Int")
  }
}

/// A field that may be missing, or present and null. Both give `None`.
pub fn opt_field(
  name: String,
  inner: Decoder(a),
  next: fn(Option(a)) -> Decoder(b),
) -> Decoder(b) {
  decode.optional_field(name, None, decode.optional(inner), next)
}

/// Required, and null is a value: absent fails, null gives `None`. For a key
/// whose null says something, `VoiceState.channel_id` (the user left) and
/// `VoiceServerUpdate.endpoint` (the voice server went away). `opt_field`
/// there would forge that signal out of a payload that never sent the key.
pub fn nullable_field(
  name: String,
  inner: Decoder(a),
  next: fn(Option(a)) -> Decoder(b),
) -> Decoder(b) {
  decode.field(name, decode.optional(inner), next)
}

/// Anything that does not decode gives `default`, so one field Discord changed
/// the shape of cannot lose the whole payload.
pub fn lenient(inner: Decoder(a), default: a) -> Decoder(a) {
  decode.one_of(inner, or: [decode.success(default)])
}

/// Absent, null, or the wrong shape all give `None`. `opt_field` for a field
/// whose shape is worth failing on, this for one that is not.
pub fn soft_field(
  name: String,
  inner: Decoder(a),
  next: fn(Option(a)) -> Decoder(b),
) -> Decoder(b) {
  decode.optional_field(name, None, lenient(decode.optional(inner), None), next)
}

/// The shape behind `list_field`, `flag_field`, `int_field` and `string_field`:
/// a missing key and a null one both land on `default`. Public because a model
/// needing it for its own type would otherwise write a copy, and the copies
/// drift on which of absent and null they cover.
pub fn defaulted_field(
  name: String,
  inner: Decoder(a),
  default: a,
  next: fn(a) -> Decoder(b),
) -> Decoder(b) {
  decode.optional_field(
    name,
    default,
    decode.optional(inner) |> decode.map(option.unwrap(_, default)),
    next,
  )
}

/// Missing or null gives `[]`. Discord omits `embeds` rather than sending
/// `[]`, and sends `"roles": null` on some partial objects.
pub fn list_field(
  name: String,
  inner: Decoder(a),
  next: fn(List(a)) -> Decoder(b),
) -> Decoder(b) {
  defaulted_field(name, decode.list(inner), [], next)
}

/// Missing or null gives an empty dict, so there is no `Option` to unwrap
/// before a `dict.get`.
pub fn dict_field(
  name: String,
  key: Decoder(k),
  value: Decoder(v),
  next: fn(Dict(k, v)) -> Decoder(b),
) -> Decoder(b) {
  defaulted_field(name, decode.dict(key, value), dict.new(), next)
}

/// A boolean that may be missing or null, with a default. Discord omits most
/// false flags, and a few default to true.
pub fn flag_field(
  name: String,
  default: Bool,
  next: fn(Bool) -> Decoder(a),
) -> Decoder(a) {
  defaulted_field(name, decode.bool, default, next)
}

/// All three states mean something. On `Message.referenced_message`, absent
/// means Discord never looked and null means the message was deleted.
pub fn tri_field(
  name: String,
  inner: Decoder(a),
  next: fn(Field(a)) -> Decoder(b),
) -> Decoder(b) {
  decode.optional_field(
    name,
    field.Absent,
    decode.optional(inner) |> decode.map(to_field),
    next,
  )
}

fn to_field(value: Option(a)) -> Field(a) {
  case value {
    Some(v) -> field.Present(v)
    None -> field.Null
  }
}

/// Whether a key is there at all. Discord marks some booleans,
/// `RoleTags.premium_subscriber` among them, by writing a null.
pub fn present_field(name: String, next: fn(Bool) -> Decoder(a)) -> Decoder(a) {
  decode.optional_field(
    name,
    False,
    decode.optional(decode.dynamic) |> decode.map(fn(_) { True }),
    next,
  )
}

/// The encoding side of `present_field`: true writes a null, false leaves the
/// key out.
pub fn null_flag(value: Bool) -> Field(Json) {
  case value {
    True -> field.Null
    False -> field.Absent
  }
}

/// The encoding side of `flag_field`: true writes the key, false leaves it
/// out. Discord defaults every one of these to false, and reads an explicit
/// `null` as an instruction rather than a default.
pub fn flag(value: Bool) -> Field(Json) {
  case value {
    True -> field.Present(json.bool(True))
    False -> field.Absent
  }
}

/// A whole number that may be missing or null, with a default.
pub fn int_field(
  name: String,
  default: Int,
  next: fn(Int) -> Decoder(a),
) -> Decoder(a) {
  defaulted_field(name, integer(), default, next)
}

/// A string that may be missing or null, with a default.
pub fn string_field(
  name: String,
  default: String,
  next: fn(String) -> Decoder(a),
) -> Decoder(a) {
  defaulted_field(name, decode.string, default, next)
}

/// Keep the raw payload beside the decoded value, so a field glyde does not
/// model is one `decode.at` away.
pub fn raw(next: fn(Dynamic) -> Decoder(a)) -> Decoder(a) {
  decode.then(decode.dynamic, next)
}

/// Decode an enum Discord may extend, keeping the raw value for one glyde has
/// not seen. Failing would turn a new channel type into a dropped event.
pub fn enum_with_fallback(
  known: fn(Int) -> Option(a),
  unknown: fn(Int) -> a,
) -> Decoder(a) {
  integer()
  |> decode.map(fn(value) {
    case known(value) {
      Some(variant) -> variant
      None -> unknown(value)
    }
  })
}

/// The string form of the same thing, for enums Discord keys by name.
pub fn string_enum_with_fallback(
  known: fn(String) -> Option(a),
  unknown: fn(String) -> a,
) -> Decoder(a) {
  decode.string
  |> decode.map(fn(value) {
    case known(value) {
      Some(variant) -> variant
      None -> unknown(value)
    }
  })
}

/// For flags Discord sends as a JSON number. Permission bitfields arrive as
/// strings and belong in `glyde/permissions`.
pub fn has_bit(flags: Int, bit: Int) -> Bool {
  int.bitwise_and(flags, bit) != 0
}

pub fn bits_to_list(flags: Int, table: List(#(a, Int))) -> List(a) {
  table
  |> list.filter(fn(entry) { has_bit(flags, entry.1) })
  |> list.map(fn(entry) { entry.0 })
}

pub fn list_to_bits(values: List(a), table: List(#(a, Int))) -> Int {
  table
  |> list.filter(fn(entry) { list.contains(values, entry.0) })
  |> list.fold(0, fn(acc, entry) { int.bitwise_or(acc, entry.1) })
}
