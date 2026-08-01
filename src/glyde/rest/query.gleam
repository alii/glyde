//// Query parameters, built so an absent one has no spelling. A `Param` can
//// only be made here, so a `rest.query` call cannot be handed a hand-rolled
//// pair that skipped the rules: these emit a parameter only when there is a
//// value, and `0` is a value.
////
//// `to_string` is the other end of the same story: it is how a `Param`
//// reaches the wire, so the whole answer to what a query looks like is in
//// this module.
////
//// Also what a hand-rolled call needs, for an endpoint glyde does not wrap:
////
//// ```gleam
//// let call =
////   rest.get(
////     [seg.lit("guilds"), seg.guild(guild), seg.lit("audit-logs")],
////     rest.Decoded(my_decoder),
////   )
////   |> rest.query(query.opt("limit", Some(50), query.number))
////
//// let submit = limiter.Submit(limiter.Ticket(1), rest.route(call))
//// ```

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import glyde/id.{type Id}
import glyde/internal/url

/// One key and one value, already encoded the way Discord reads it. Opaque so
/// that every parameter on a call came through the constructors below.
pub opaque type Param {
  Param(key: String, value: String)
}

/// The query string these parameters make, both halves percent-encoded, with
/// no leading `?`. `None` for an empty list, because a bare `?` on the end of
/// a URL is a common bug.
pub fn to_string(params: List(Param)) -> Option(String) {
  case params {
    [] -> None
    _ ->
      params
      |> list.map(fn(param) {
        url.percent_encode(param.key) <> "=" <> url.percent_encode(param.value)
      })
      |> string.join("&")
      |> Some
  }
}

/// One parameter. `None` produces no pair at all.
pub fn opt(
  key: String,
  value: Option(a),
  with encode: fn(a) -> String,
) -> List(Param) {
  case value {
    None -> []
    Some(value) -> [Param(key, encode(value))]
  }
}

/// One parameter, always sent, for a flag whose value is the point.
pub fn one(key: String, value: String) -> List(Param) {
  [Param(key, value)]
}

/// An array parameter as repeated keys, `?id=1&id=2`, which is Discord's
/// documented default. An empty list emits nothing.
pub fn repeat(
  key: String,
  values: List(a),
  with encode: fn(a) -> String,
) -> List(Param) {
  list.map(values, fn(value) { Param(key, encode(value)) })
}

/// An array parameter joined with commas, which Discord asks for on three
/// parameters only, `include_roles` on `GET /guilds/{id}/prune` among them.
/// An empty list emits nothing.
pub fn comma(
  key: String,
  values: List(a),
  with encode: fn(a) -> String,
) -> List(Param) {
  case values {
    [] -> []
    _ -> [Param(key, list.map(values, encode) |> string.join(","))]
  }
}

pub fn number(value: Int) -> String {
  int.to_string(value)
}

/// Discord accepts `True`, `true` and `1`. glyde always writes `true`.
pub fn flag(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}

pub fn snowflake(value: Id(kind)) -> String {
  id.to_string(value)
}

/// A value that is already the text Discord wants: a search term, an ISO-8601
/// timestamp. `to_string` does the percent-encoding.
pub fn text(value: String) -> String {
  value
}
