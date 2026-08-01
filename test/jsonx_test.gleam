import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import glyde/field
import glyde/wire

// Writing

pub fn an_empty_object_test() {
  assert json.to_string(wire.object([])) == "{}"
}

/// A null tells Discord to clear a field, so a PATCH that nulls what it was
/// not given empties the topic too.
pub fn absent_keys_are_omitted_not_nulled_test() {
  let body =
    wire.object([
      #("name", field.Present(json.string("general"))),
      #("topic", field.Absent),
      #("parent_id", field.Absent),
    ])

  assert json.to_string(body) == "{\"name\":\"general\"}"
}

/// `parent_id: null` moves the channel out of its category.
pub fn null_keys_are_written_test() {
  let body =
    wire.object([
      #("name", field.Absent),
      #("parent_id", field.Null),
    ])

  assert json.to_string(body) == "{\"parent_id\":null}"
}

pub fn every_field_absent_gives_an_empty_object_test() {
  let body = wire.object([#("a", field.Absent), #("b", field.Absent)])

  assert json.to_string(body) == "{}"
}

pub fn keys_keep_the_order_they_were_written_in_test() {
  let body =
    wire.object([
      #("content", field.Present(json.string("hi"))),
      #("tts", field.Present(json.bool(False))),
      #("nonce", field.Absent),
      #("flags", field.Present(json.int(4))),
    ])

  assert json.to_string(body)
    == "{\"content\":\"hi\",\"tts\":false,\"flags\":4}"
}

pub fn put_encodes_only_a_present_value_test() {
  let assert field.Present(encoded) = wire.put(field.Present("hi"), json.string)
  assert json.to_string(encoded) == "\"hi\""

  assert wire.put(field.Null, json.string) == field.Null
  assert wire.put(field.Absent, json.string) == field.Absent
}

/// The three states a caller can be in, and the three bodies they produce.
pub fn the_patch_trichotomy_end_to_end_test() {
  let rows = [
    #(field.Absent, "{}"),
    #(field.Null, "{\"parent_id\":null}"),
    #(field.Present("123"), "{\"parent_id\":\"123\"}"),
  ]

  list.each(rows, fn(row) {
    let #(parent_id, expected) = row
    let body = wire.object([#("parent_id", wire.put(parent_id, json.string))])
    assert json.to_string(body) == expected
  })
}

/// `None` means omit, not clear.
pub fn an_option_omits_rather_than_clears_test() {
  let body =
    wire.object([
      #("nick", wire.put(field.from_option(None), json.string)),
      #("topic", wire.put(field.from_option(Some("hi")), json.string)),
    ])

  assert json.to_string(body) == "{\"topic\":\"hi\"}"
}

/// `json.object` writes both copies of a repeated key and reports no error, so
/// every encoder here builds from one ordered list.
pub fn a_repeated_key_is_written_twice_test() {
  let encoded =
    json.to_string(
      json.object([
        #("b", json.int(1)),
        #("a", json.int(2)),
        #("b", json.int(3)),
      ]),
    )

  assert encoded == "{\"b\":1,\"a\":2,\"b\":3}"
}

// Reading

fn number(literal: String) -> Result(Float, json.DecodeError) {
  json.parse("{\"v\":" <> literal <> "}", decode.at(["v"], wire.number()))
}

fn integer(literal: String) -> Result(Int, json.DecodeError) {
  json.parse("{\"v\":" <> literal <> "}", decode.at(["v"], wire.integer()))
}

/// A bare `decode.float` refuses the integer form, so a Float field fails the
/// first time Discord writes a whole number.
pub fn a_bare_float_decoder_refuses_a_json_integer_test() {
  let assert Error(_) = json.parse("{\"v\":1}", decode.at(["v"], decode.float))
}

/// Discord documents `retry_after` as fractional seconds and sends `30` when
/// the value is whole. Both forms have to reach the same Float.
pub fn number_takes_a_json_number_either_way_it_was_written_test() {
  let rows = [
    #("2", 2.0),
    #("2.0", 2.0),
    #("2.5", 2.5),
    #("0", 0.0),
    #("-1", -1.0),
    #("-1.25", -1.25),
    #("30", 30.0),
  ]

  list.each(rows, fn(row) {
    let #(literal, expected) = row
    assert number(literal) == Ok(expected)
  })
}

pub fn number_refuses_anything_that_is_not_a_number_test() {
  list.each(["\"2\"", "true", "null", "[]", "{}"], fn(literal) {
    let assert Error(_) = number(literal)
  })
}

/// A bare `decode.int` refuses `2.0`, and Discord writes a whole number either
/// way.
pub fn integer_takes_a_whole_number_either_way_it_was_written_test() {
  let rows = [
    #("2", 2),
    #("2.0", 2),
    #("0", 0),
    #("-3", -3),
    #("-3.0", -3),
    #("41250", 41_250),
    #("1000000", 1_000_000),
  ]

  list.each(rows, fn(row) {
    let #(literal, expected) = row
    assert integer(literal) == Ok(expected)
  })
}

/// Silently taking 2 from `2.5` is a value nobody sent.
pub fn integer_refuses_a_fraction_test() {
  list.each(["2.5", "-2.5", "0.1", "\"2\"", "true", "null"], fn(literal) {
    let assert Error(_) = integer(literal)
  })
}

/// An exponent that lands on a whole number is an integer, and one that does
/// not is not.
pub fn integer_takes_exponent_notation_for_a_whole_number_test() {
  assert integer("4.125e4") == Ok(41_250)
  let assert Error(_) = integer("4.12505e4")
}

/// OTP 27 stopped calling `-0.0` equal to `0.0`, so both decoders have to land
/// on plain zero or a downstream comparison forks.
pub fn negative_zero_folds_to_zero_test() {
  assert integer("-0.0") == Ok(0)
  assert number("-0.0") == Ok(0.0)
  assert number("-0.0") == number("0.0")
}

/// A duplicate key resolves to the first value, silently. A proxy or anything
/// concatenating JSON can produce one.
pub fn a_duplicate_key_resolves_to_the_first_value_test() {
  assert json.parse("{\"v\":1,\"v\":2}", decode.at(["v"], decode.int)) == Ok(1)
}

/// A sequence number or heartbeat interval past 2^53 is nothing Discord sends,
/// and refusing it keeps an absurd number out of a timer.
pub fn integer_refuses_a_value_past_2_53_test() {
  let assert Error(_) = integer("1.0e20")
  let assert Error(_) = integer("100000000000000000000")

  // A number inside the range still decodes, in either form.
  assert integer("2.0") == Ok(2)
}

/// One ceiling, not one per decoder: a Float past 2^53 lost its low digits
/// before it reached us, so `number` stops where `integer` does.
pub fn number_refuses_a_value_past_2_53_test() {
  let assert Error(_) = number("1.0e20")
  let assert Error(_) = number("-1.0e20")
  let assert Error(_) = number("100000000000000000000")

  assert number("9007199254740991") == Ok(9_007_199_254_740_991.0)
  assert number("30.5") == Ok(30.5)
}

/// The write side of `number`. A whole value goes out without a decimal point
/// so the same seconds always produce the same bytes.
pub fn number_json_writes_a_whole_value_as_an_integer_test() {
  let rows = [
    #(3.0, "3"),
    #(0.0, "0"),
    #(-0.0, "0"),
    #(3.5, "3.5"),
    #(-2.0, "-2"),
    #(1.0e20, "1.0e20"),
  ]

  list.each(rows, fn(row) {
    let #(value, expected) = row
    assert json.to_string(wire.number_json(value)) == expected
  })
}
