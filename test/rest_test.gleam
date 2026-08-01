import gleam/bit_array
import gleam/dynamic/decode.{type Decoder}
import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import glyde/id
import glyde/rest
import glyde/rest/body
import glyde/rest/error
import glyde/rest/limiter.{SharedScope}
import glyde/rest/query
import glyde/rest/route
import glyde/rest/seg

const token: String = "MTk4NjIyNDgzNDcxOTI1MjQ4.s3cret"

fn config() -> rest.Config {
  rest.config(rest.bot(token))
}

fn channel() -> id.ChannelId {
  id.from_string("41771983423143937")
}

fn messages() -> List(seg.Seg) {
  [seg.lit("channels"), seg.channel(channel()), seg.lit("messages")]
}

/// `POST /channels/{channel.id}/messages`, the call every other test varies.
fn create_message() -> rest.Call(String) {
  rest.post(
    messages(),
    body.json([#("content", json.string("pong"))]),
    rest.Decoded(id_decoder()),
  )
}

fn id_decoder() -> Decoder(String) {
  decode.field("id", decode.string, decode.success)
}

fn sent(call: rest.Call(a)) -> List(#(String, String)) {
  rest.request(config(), call).headers
}

fn header(call: rest.Call(a), key: String) -> Result(String, Nil) {
  list.key_find(sent(call), key)
}

fn wire_text(call: rest.Call(a)) -> String {
  case rest.request(config(), call).body {
    body.Empty -> ""
    body.Text(text) -> text
    body.Bytes(bits) -> bit_array.to_string(bits) |> result.unwrap("")
  }
}

fn file(filename: String) -> body.File {
  body.File(filename:, content_type: "text/plain", data: <<"hi":utf8>>)
}

/// Gleam cannot concatenate constants, so `base_url` spells the host and the
/// version out a second time.
pub fn base_url_agrees_with_its_parts_test() {
  assert rest.base_url
    == "https://" <> rest.host <> "/api/v" <> int.to_string(rest.api_version)
}

/// An unversioned path routes to v6, so a bump has to be a deliberate diff.
pub fn api_version_is_pinned_test() {
  assert rest.api_version == 10
}

/// Discord may block a User-Agent that is not `DiscordBot ($url, $version)`,
/// with an error that reads like a payload problem.
pub fn user_agent_has_discords_shape_test() {
  assert string.starts_with(rest.user_agent, "DiscordBot (")
  assert string.contains(rest.user_agent, ", ")
  assert string.ends_with(rest.user_agent, ")")
}

/// Long enough that a body containing it by accident is not a thing.
pub fn boundary_is_long_test() {
  assert string.length(body.boundary_to_string(rest.boundary)) == 40
}

pub fn url_carries_the_api_version_test() {
  let request = rest.request(config(), create_message())
  assert request.scheme == http.Https
  assert request.host == "discord.com"
  assert request.port == None
  assert request.path == "/api/v10/channels/41771983423143937/messages"
  assert request.method == http.Post
}

/// The host is overridable for a proxy or a recording double.
pub fn host_and_version_are_overridable_test() {
  let request =
    rest.request(
      rest.Config(..config(), host: "localhost", api_version: 9),
      create_message(),
    )
  assert request.host == "localhost"
  assert request.path == "/api/v9/channels/41771983423143937/messages"
}

/// A bare `?` on the end of a bodyless URL is a common bug.
pub fn no_query_means_no_question_mark_test() {
  assert rest.request(config(), create_message()).query == None
}

pub fn query_is_percent_encoded_test() {
  let call = rest.query(create_message(), query.one("query", "a&b=c"))
  assert rest.request(config(), call).query == Some("query=a%26b%3Dc")
}

/// Repeated keys are how Discord reads a list, so parameters accumulate.
pub fn query_repeats_a_key_test() {
  let call =
    create_message()
    |> rest.query(query.one("id", "123"))
    |> rest.query(query.one("id", "456"))
  assert rest.request(config(), call).query == Some("id=123&id=456")
}

/// Zero is a value; absence is the caller leaving the pair out.
pub fn query_keeps_a_zero_test() {
  let call = rest.query(create_message(), query.one("limit", query.number(0)))
  assert rest.request(config(), call).query == Some("limit=0")
}

pub fn query_joins_with_ampersand_and_no_leading_one_test() {
  let call =
    rest.query(
      create_message(),
      list.flatten([query.one("a", "1"), query.one("b", "2")]),
    )
  assert rest.request(config(), call).query == Some("a=1&b=2")
}

pub fn authorization_table_test() {
  let rows = [
    #(rest.bot("abc"), Ok("Bot abc")),
    #(rest.bearer("xyz"), Ok("Bearer xyz")),
    #(rest.unauthenticated(), Error(Nil)),
  ]
  list.each(rows, fn(row) {
    let #(token, expected) = row
    let request = rest.request(rest.config(token), create_message())
    assert list.key_find(request.headers, "authorization") == expected
  })
}

/// HTTP/2 requires lowercase on the wire.
pub fn header_keys_are_lowercase_test() {
  let call = rest.reason(create_message(), "spring cleaning")
  list.each(sent(call), fn(header) {
    assert string.lowercase(header.0) == header.0
  })
}

/// Nothing in the API can blank the User-Agent or add a second one.
pub fn user_agent_is_sent_once_test() {
  let matching =
    sent(create_message())
    |> list.filter(fn(header) { header.0 == "user-agent" })
  assert matching == [#("user-agent", rest.user_agent)]
}

/// Discord accepts exactly three content types and answers a missing one with
/// error 50035, which is also what it says for a genuinely bad payload.
pub fn content_type_table_test() {
  let expect = rest.Decoded(id_decoder())
  let rows = [
    #(rest.get(messages(), expect), Error(Nil)),
    #(rest.post(messages(), body.NoBody, expect), Error(Nil)),
    #(rest.post(messages(), body.json([]), expect), Ok("application/json")),
    #(
      rest.post(messages(), body.Form(payload: [], files: []), expect),
      Ok("application/json"),
    ),
    #(
      rest.attach(rest.post(messages(), body.NoBody, expect), file("a.txt")),
      Ok(
        "multipart/form-data; boundary=\""
        <> body.boundary_to_string(rest.boundary)
        <> "\"",
      ),
    ),
  ]
  list.each(rows, fn(row) {
    let #(call, expected) = row
    assert header(call, "content-type") == expected
  })
}

pub fn reason_absent_by_default_test() {
  assert header(create_message(), "x-audit-log-reason") == Error(Nil)
}

/// An empty header value is not the way to say there is no reason.
pub fn empty_reason_is_dropped_test() {
  let call = rest.reason(create_message(), "")
  assert header(call, "x-audit-log-reason") == Error(Nil)
}

/// A header value cannot carry raw non-ASCII.
pub fn reason_percent_encodes_utf8_test() {
  let call = rest.reason(create_message(), "😄")
  assert header(call, "x-audit-log-reason") == Ok("%F0%9F%98%84")
}

pub fn reason_encodes_spaces_test() {
  let call = rest.reason(create_message(), "spring cleaning")
  assert header(call, "x-audit-log-reason") == Ok("spring%20cleaning")
}

/// A raw CR or LF in a header value splits the request in two. The reason is
/// the one header a caller's own text reaches.
pub fn reason_cannot_inject_a_header_test() {
  let call = rest.reason(create_message(), "why\r\nx-evil: 1")
  let assert Ok(value) = header(call, "x-audit-log-reason")
  assert !string.contains(value, "\r")
  assert !string.contains(value, "\n")
  assert value == "why%0D%0Ax-evil%3A%201"
}

/// An ordinary reason stays readable in the audit log.
pub fn reason_leaves_unreserved_characters_alone_test() {
  let call = rest.reason(create_message(), "abcXYZ019-._~")
  assert header(call, "x-audit-log-reason") == Ok("abcXYZ019-._~")
}

/// The reason is stored raw and encoded on the way out.
pub fn reason_is_encoded_once_test() {
  let call =
    create_message()
    |> rest.reason("a b")
    |> rest.reason("c d")
  assert header(call, "x-audit-log-reason") == Ok("c%20d")
}

/// Discord ignores a GET body and some proxies reject one outright.
pub fn get_has_no_body_test() {
  let call =
    rest.get([seg.lit("users"), seg.lit("@me")], rest.Decoded(id_decoder()))
  assert rest.request(config(), call).body == body.Empty
  assert header(call, "content-type") == Error(Nil)
}

/// `@me` is a literal, not a value, so it must not come out as `%40me`.
pub fn literals_are_not_encoded_test() {
  let call =
    rest.get([seg.lit("users"), seg.lit("@me")], rest.Decoded(id_decoder()))
  assert rest.request(config(), call).path == "/api/v10/users/@me"
}

pub fn attach_makes_the_body_multipart_test() {
  let call =
    rest.post(
      messages(),
      body.Form(payload: [#("content", json.string("pong"))], files: []),
      rest.Decoded(id_decoder()),
    )
    |> rest.attach(file("a.txt"))

  let assert Ok(content_type) = header(call, "content-type")
  assert string.starts_with(content_type, "multipart/form-data; boundary=\"")
  // The fields that were already there travel on as `payload_json`.
  let text = wire_text(call)
  assert string.contains(text, "\"content\":\"pong\"")
  assert string.contains(text, "a.txt")
}

pub fn attach_appends_test() {
  let call =
    rest.post(messages(), body.NoBody, rest.Decoded(id_decoder()))
    |> rest.attach(file("first.txt"))
    |> rest.attach(file("second.txt"))

  let text = wire_text(call)
  let assert Ok(#(before, _)) = string.split_once(text, "second.txt")
  assert string.contains(before, "first.txt")
}

/// Every body can take a file, including a plain JSON one.
pub fn attaching_to_a_plain_json_body_works_test() {
  let call = rest.attach(create_message(), file("a.txt"))

  let assert Ok(content_type) = header(call, "content-type")
  assert string.starts_with(content_type, "multipart/form-data")

  let text = wire_text(call)
  assert string.contains(text, "a.txt")
  assert string.contains(text, "files[0]")
  // The fields the call already had travel as payload_json.
  assert string.contains(text, "pong")
}

/// The template and the major parameter are the limiter's identity, and they
/// come out of the same segment list the path did.
pub fn route_carries_the_template_test() {
  let identity = rest.route(create_message())
  assert route.method(identity) == http.Post
  assert route.template(identity) == "/channels/{channel.id}/messages"
  assert route.same_major(
    route.major(identity),
    route.ChannelMajor("41771983423143937"),
  )
  assert !route.unbound(identity)
  assert route.sublimit(identity) == route.NoSublimit
}

pub fn split_bucket_names_a_sublimit_test() {
  let call = rest.split_bucket(create_message(), "name-or-topic")
  assert route.sublimit(rest.route(call)) == route.Named("name-or-topic")
}

/// The scheduling identity is available without building a request.
pub fn route_needs_no_config_test() {
  let call =
    rest.get([seg.lit("gateway"), seg.lit("bot")], rest.Decoded(id_decoder()))
  assert route.template(rest.route(call)) == "/gateway/bot"
  assert route.same_major(route.major(rest.route(call)), route.NoMajor)
}

/// An interaction callback has three seconds, so it must not queue behind
/// ordinary traffic.
pub fn an_interaction_callback_is_unbound_test() {
  let call =
    rest.post(
      [
        seg.lit("interactions"),
        seg.id(id.from_string("1234567890123456789")),
        seg.opaque_text("interaction-token"),
        seg.lit("callback"),
      ],
      body.NoBody,
      rest.NoContent(Nil),
    )
  assert route.unbound(rest.route(call))
}

fn answer(status: Int, text: String) -> Result(String, rest.Failure) {
  rest.response(create_message(), status:, headers: [], body: <<text:utf8>>)
}

fn nothing() -> rest.Call(Nil) {
  rest.delete(
    [seg.lit("channels"), seg.channel(channel())],
    rest.NoContent(Nil),
  )
}

/// 201 and 204 are everyday Discord answers.
pub fn success_is_the_whole_2xx_range_test() {
  assert answer(200, "{\"id\":\"7\"}") == Ok("7")
  assert answer(201, "{\"id\":\"7\"}") == Ok("7")
  assert answer(299, "{\"id\":\"7\"}") == Ok("7")
}

/// A 204 endpoint never runs a decoder.
pub fn no_content_skips_decoding_test() {
  assert rest.response(nothing(), status: 204, headers: [], body: <<>>)
    == Ok(Nil)
  assert rest.response(nothing(), status: 200, headers: [], body: <<
      "{\"id\":\"7\"}":utf8,
    >>)
    == Ok(Nil)
}

/// No body on a route that is supposed to return one is a real signal.
pub fn an_empty_body_on_a_decoding_call_is_malformed_test() {
  let assert Error(error.Malformed(error.DecodeFailure(raw:, ..))) =
    rest.response(create_message(), status: 204, headers: [], body: <<>>)
  assert raw == ""
}

/// Discord returns its error object on some 2xx paths, and the raw text is the
/// only way to tell a shape change from a decoder bug.
pub fn a_2xx_of_the_wrong_shape_is_malformed_test() {
  let payload = "{\"code\":50013,\"message\":\"Missing Permissions\"}"
  let assert Error(error.Malformed(error.DecodeFailure(raw:, ..))) =
    answer(200, payload)
  assert raw == payload
}

/// A call has exactly one error type.
pub fn a_non_2xx_is_classified_by_its_body_test() {
  let assert Error(error.Discord(status:, code:, message:, fields: [], ..)) =
    answer(404, "{\"code\":10003,\"message\":\"Unknown Channel\"}")
  assert status == 404
  assert error.code_to_int(code) == 10_003
  assert message == "Unknown Channel"
}

pub fn a_429_keeps_its_retry_after_test() {
  let assert Error(error.RateLimited(status: 429, limit:)) =
    rest.response(
      create_message(),
      status: 429,
      headers: [#("x-ratelimit-scope", "shared")],
      body: <<
        "{\"message\":\"You are being rate limited.\",\"retry_after\":0.47,\"global\":false}":utf8,
      >>,
    )
  assert limit.retry_after == 0.47
  assert limit.scope == SharedScope
}

/// A Cloudflare block answers in HTML. Reporting a JSON decode error would
/// bury the real cause.
pub fn an_html_body_is_opaque_test() {
  let assert Error(error.Opaque(status: 502, body:, ..)) =
    answer(502, "<html><body>bad gateway</body></html>")
  assert string.contains(body, "bad gateway")
}

/// Discord speaks UTF-8 everywhere, so this came from something in between.
/// Reading the bytes as an empty body would report them as an empty one.
pub fn a_body_that_is_not_text_says_so_test() {
  assert rest.response(
      create_message(),
      status: 500,
      headers: [#("content-type", "application/octet-stream")],
      body: <<0xFF, 0xFE>>,
    )
    == Error(error.NotText(
      status: 500,
      content_type: Some("application/octet-stream"),
      bytes: 2,
    ))
}

/// The same on a 2xx, where the alternative was a JSON decode error blaming
/// the decoder for bytes that were never text.
pub fn a_2xx_body_that_is_not_text_says_so_test() {
  assert rest.response(create_message(), status: 200, headers: [], body: <<
      0xFF,
      0xFE,
      0xFD,
    >>)
    == Error(error.NotText(status: 200, content_type: None, bytes: 3))
}

/// `string.inspect` ignores opaqueness, so the token lives behind a closure.
pub fn inspecting_a_config_does_not_leak_the_token_test() {
  let printed = string.inspect(config())
  assert !string.contains(printed, token)
  assert !string.contains(printed, "s3cret")
}

/// A `Call` holds no secret, so it can be logged, persisted or replayed.
pub fn a_call_does_not_carry_the_token_test() {
  assert !string.contains(string.inspect(create_message()), "s3cret")
}

/// The one place the token is allowed to appear.
pub fn the_token_reaches_the_authorization_header_test() {
  assert header(create_message(), "authorization") == Ok("Bot " <> token)
}
