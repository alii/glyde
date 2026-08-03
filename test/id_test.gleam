import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/order
import gleam/string
import glyde/id

pub fn round_trips_exactly_test() {
  let snowflake = "1234567890123456789"
  let channel = id.from_string(snowflake)
  assert id.to_string(channel) == snowflake
}

pub fn decodes_from_a_json_string_test() {
  let assert Ok(channel) =
    json.parse(
      "{\"id\":\"1234567890123456789\"}",
      decode.at(["id"], id.decoder()),
    )
  assert id.to_string(channel) == "1234567890123456789"
}

/// Discord sends snowflakes as strings, and a bare number cannot hold 19
/// digits exactly, so one is refused rather than silently rounded.
pub fn refuses_a_json_number_test() {
  let decoded =
    json.parse("{\"id\":1234567890123456789}", decode.at(["id"], id.decoder()))
  assert decoded != Ok(id.from_string("1234567890123456789"))
  let assert Error(_) = decoded
}

pub fn encodes_as_a_json_string_test() {
  let channel: id.ChannelId = id.from_string("41771983423143937")
  assert json.to_string(id.to_json(channel)) == "\"41771983423143937\""
}

/// Ids go straight into request paths, so user input is checked first.
pub fn parse_rejects_anything_that_is_not_a_snowflake_test() {
  let bad = [
    "", "@me", "1/../../users/@me", "12 34", "12a", "0123", "-1", "1.0", "١٢٣",
  ]
  list.each(bad, fn(text) {
    let parsed: Result(id.ChannelId, Nil) = id.parse(text)
    assert parsed == Error(Nil)
  })
}

pub fn parse_accepts_real_snowflakes_test() {
  let good = ["0", "1", "41771983423143937", "1234567890123456789"]
  list.each(good, fn(text) {
    let assert Ok(parsed) = id.parse(text)
    let parsed: id.ChannelId = parsed
    assert id.to_string(parsed) == text
  })
}

/// A snowflake is a u64, so 18446744073709551615 is the widest one. A longer
/// run of digits is not an id, and `created_at_ms` would overflow on it.
pub fn parse_rejects_digits_too_wide_to_be_a_snowflake_test() {
  let widest: Result(id.ChannelId, Nil) = id.parse("18446744073709551615")
  let assert Ok(edge) = widest
  assert id.to_string(edge) == "18446744073709551615"

  let twenty_one: Result(id.ChannelId, Nil) = id.parse("999999999999999999999")
  assert twenty_one == Error(Nil)

  // Every id `parse` accepts has a timestamp `created_at_ms` can read.
  let assert Ok(_) = id.created_at_ms(edge)
}

/// Discord hands one snowflake out under two names, an overwrite id being a
/// role id or a user id. Retagging relabels the id rather than rebuilding one
/// out of text, which is what `from_string` would look like at the call site.
pub fn retag_keeps_the_text_and_changes_the_tag_test() {
  let user: id.UserId = id.from_string("80351110224678912")
  let overwrite: id.OverwriteId = id.retag(user, to: id.overwrite)
  assert id.to_string(overwrite) == id.to_string(user)
  assert id.retag(overwrite, to: id.user) == user
}

/// The tag argument is what makes a wrong retag a type error, so it has to be
/// the thing that picks the destination, not an annotation the caller repeats.
pub fn retag_takes_its_destination_from_the_tag_test() {
  let channel: id.ChannelId = id.from_string("41771983423143937")

  // No annotation anywhere: `id.message` alone decides what comes back.
  let message = id.retag(channel, to: id.message)
  let back: id.ChannelId = id.retag(message, to: id.channel)

  assert id.to_string(message) == "41771983423143937"
  assert back == channel
}

/// Snowflakes run 15 to 19 digits, so string order is not numeric order, and
/// numeric order is what before/after pagination needs.
pub fn compare_orders_numerically_not_lexicographically_test() {
  let older: id.MessageId = id.from_string("99999999999999999")
  let newer: id.MessageId = id.from_string("100000000000000000")

  // Plain string comparison puts the older one last.
  assert string.compare(id.to_string(older), id.to_string(newer)) == order.Gt
  assert id.compare(older, newer) == order.Lt
  assert id.compare(newer, older) == order.Gt
  assert id.compare(older, older) == order.Eq
}

pub fn compare_sorts_a_list_chronologically_test() {
  let ids =
    list.map(
      ["100000000000000000", "99999999999999999", "1234567890123456789"],
      id.from_string,
    )
  let sorted: List(id.MessageId) = list.sort(ids, id.compare)
  assert list.map(sorted, id.to_string)
    == ["99999999999999999", "100000000000000000", "1234567890123456789"]
}

pub fn same_tag_compares_structurally_test() {
  let a = id.from_string("80351110224678912")
  let b = id.from_string("80351110224678912")
  let c = id.from_string("80351110224678913")
  assert a == b
  assert a != c
}

/// A snowflake carries its creation time in its high bits.
pub fn created_at_ms_test() {
  // Discord's own documented example.
  let assert Ok(at) = id.created_at_ms(id.from_string("175928847299117063"))
  assert at == 1_462_015_105_796

  // The epoch itself.
  let assert Ok(zero) = id.created_at_ms(id.from_string("0"))
  assert zero == id.discord_epoch_ms

  // A recent 19 digit id stays in range.
  let assert Ok(recent) =
    id.created_at_ms(id.from_string("1234567890123456789"))
  assert recent > id.discord_epoch_ms

  assert id.created_at_ms(id.from_string("nonsense")) == Error(Nil)

  // `from_string` does not validate, so a number too wide to be a snowflake
  // reaches here. `parse` is what keeps it out.
  assert id.created_at_ms(id.from_string("99999999999999999999999"))
    == Error(Nil)
}

/// A caller that has to answer with a number either way, such as the one
/// picking a rate limit bucket, gets its own fallback rather than a guess.
pub fn created_at_ms_or_falls_back_test() {
  let real: id.MessageId = id.from_string("175928847299117063")
  assert id.created_at_ms_or(real, default: 0) == 1_462_015_105_796

  let odd: id.MessageId = id.from_string("not-a-snowflake")
  assert id.created_at_ms_or(odd, default: id.discord_epoch_ms)
    == id.discord_epoch_ms
  assert id.created_at_ms_or(odd, default: 0) == 0
}

/// `before` and `after` pagination needs id order and timestamp order to agree.
pub fn created_at_matches_compare_test() {
  let older: id.MessageId = id.from_string("175928847299117063")
  let newer: id.MessageId = id.from_string("1234567890123456789")

  let assert Ok(a) = id.created_at_ms(older)
  let assert Ok(b) = id.created_at_ms(newer)

  assert id.compare(older, newer) == order.Lt
  assert a < b
}

pub fn decoder_takes_digit_strings_only_test() {
  let ok = fn(text) { json.parse("\"" <> text <> "\"", id.decoder()) }
  let assert Ok(_) = ok("0")
  let assert Ok(_) = ok("41771983423143937")
  // Twenty digits is the ceiling: 2^64 - 1 is that wide.
  let assert Ok(_) = ok("18446744073709551615")
  let assert Error(_) = ok("")
  let assert Error(_) = ok("123456789012345678901")
  let assert Error(_) = ok("12a")
  let assert Error(_) = ok(" 12")
  let assert Error(_) = ok("-1")
  let assert Error(_) = ok("１２")
  // A JSON number in a snowflake slot is malformed.
  let assert Error(_) = json.parse("41771983423143937", id.decoder())
}

pub fn lenient_decoder_reads_a_number_too_test() {
  let assert Ok(a) = json.parse("77", id.lenient_decoder())
  let assert Ok(b) = json.parse("\"77\"", id.lenient_decoder())
  assert id.to_string(a) == "77"
  assert a == b
  let assert Error(_) = json.parse("-1", id.lenient_decoder())
  let assert Error(_) = json.parse("\"x\"", id.lenient_decoder())
}
