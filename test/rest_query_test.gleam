//// Query parameters: absence has no spelling, zero is a value, and an array
//// repeats its key, which is why a query is a list and not a dict.
////
//// `Param` is opaque, so these constructors are the only way to reach
//// `rest.query`: a hand-rolled pair does not typecheck.

import gleam/dynamic/decode
import gleam/list
import gleam/option.{None, Some}
import glyde/id
import glyde/rest
import glyde/rest/query
import glyde/rest/seg

fn config() -> rest.Config {
  rest.config(rest.bot("MTk4NjIyNDgzNDcxOTI1MjQ4.s3cret"))
}

/// Renders through the same path a real call takes, so this asserts bytes.
fn rendered(params: List(query.Param)) -> String {
  let call =
    rest.get([seg.lit("gateway")], rest.Decoded(decode.success(Nil)))
    |> rest.query(params)

  case rest.request(config(), call).query {
    None -> ""
    Some(text) -> "?" <> text
  }
}

pub fn nothing_produces_no_question_mark_test() {
  assert rendered([]) == ""
  assert rendered(query.opt("limit", None, query.number)) == ""
}

/// Building the string is this module's job, so it can be asserted without a
/// call to hang it on. `None` and not `Some("")`, which would put a bare `?`
/// on the end of the URL.
pub fn to_string_stands_alone_test() {
  assert query.to_string([]) == None
  assert query.to_string(query.one("query", query.text("a&b=c")))
    == Some("query=a%26b%3Dc")
}

/// Keys are encoded as well as values.
pub fn a_key_is_encoded_too_test() {
  assert query.to_string(query.one("a b", query.text("c"))) == Some("a%20b=c")
}

pub fn an_absent_parameter_is_omitted_test() {
  let params =
    list.flatten([
      query.opt("limit", Some(50), query.number),
      query.opt("before", None, query.snowflake),
    ])

  assert rendered(params) == "?limit=50"
}

/// Discord reads `limit=0` as a real limit.
pub fn zero_is_a_value_test() {
  assert rendered(query.opt("limit", Some(0), query.number)) == "?limit=0"
}

/// Discord accepts `True`, `true` and `1`; glyde pins one spelling.
pub fn booleans_are_lowercase_words_test() {
  assert rendered(query.one("wait", query.flag(True))) == "?wait=true"
  assert rendered(query.one("wait", query.flag(False))) == "?wait=false"
}

pub fn a_snowflake_is_its_digits_test() {
  let user: id.UserId = id.from_string("80351110224678912")
  assert rendered(query.opt("after", Some(user), query.snowflake))
    == "?after=80351110224678912"
}

/// Timestamps stay the ISO-8601 strings Discord sends, so the colons are
/// percent-encoded on the way out.
pub fn a_timestamp_travels_as_text_test() {
  let params = query.opt("before", Some("2021-04-20T20:40:30.000Z"), query.text)

  assert rendered(params) == "?before=2021-04-20T20%3A40%3A30.000Z"
}

/// Values are percent-encoded and the first pair carries no leading `&`.
pub fn values_are_encoded_test() {
  assert rendered(query.one("query", query.text("a&b=c"))) == "?query=a%26b%3Dc"
}

/// Discord's documented default for an array: repeated keys.
pub fn an_array_repeats_its_key_test() {
  let params = query.repeat("id", ["123", "456"], query.text)
  assert rendered(params) == "?id=123&id=456"
}

/// Two Discord parameters want one comma-joined value instead of repeats.
pub fn a_comma_array_is_one_pair_test() {
  let params = query.comma("include_roles", ["123", "456"], query.text)
  assert rendered(params) == "?include_roles=123%2C456"
}

/// An empty array is absence, not an empty value.
pub fn an_empty_array_emits_nothing_test() {
  assert rendered(query.repeat("id", [], query.text)) == ""
  assert rendered(query.comma("include_roles", [], query.text)) == ""
}

pub fn parameters_keep_their_order_test() {
  let params =
    list.flatten([
      query.one("wait", query.flag(True)),
      query.opt(
        "thread_id",
        Some(id.from_string("670094564427005956")),
        query.snowflake,
      ),
      query.opt("limit", Some(2), query.number),
    ])

  assert rendered(params) == "?wait=true&thread_id=670094564427005956&limit=2"
}
