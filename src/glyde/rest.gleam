//// A Discord call as data. `rest.request` builds a `gleam_http`
//// `Request(Wire)`; `rest.route` gives the limiter its scheduling identity.
////
//// ```gleam
//// let config = rest.config(rest.bot(token))
////
//// let call =
////   rest.post(
////     [seg.lit("channels"), seg.channel(channel_id), seg.lit("messages")],
////     body.json([#("content", json.string("pong"))]),
////     rest.Decoded(message.decoder()),
////   )
////
//// // Send it with any HTTP client, then hand the answer back to the call.
//// let posted = rest.response(call, status, headers, bytes)
//// ```

import gleam/bit_array
import gleam/dynamic/decode.{type Decoder}
import gleam/http.{type Header, Delete, Get, Https, Patch, Post, Put}
import gleam/http/request.{type Request, Request}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import glyde/internal/percent
import glyde/internal/version
import glyde/rest/body.{type Body, type Boundary, type Wire}
import glyde/rest/error.{type ApiError}
import glyde/rest/query.{type Param}
import glyde/rest/route.{
  type Route, Aged, Named, method as route_method, with_sublimit,
} as _
import glyde/rest/seg.{type Seg}

pub const host: String = "discord.com"

/// An unversioned path routes to the deprecated v6, so this is never optional.
pub const api_version: Int = version.number

/// For a request built by hand rather than from a `Call`. Gleam cannot
/// concatenate constants, so a test pins it against `host` and `api_version`.
pub const base_url: String = "https://discord.com/api/v10"

/// Discord's required shape; without it Cloudflare answers a misleading
/// "invalid form body". Keep the version in step with `gleam.toml`.
pub const user_agent: String = "DiscordBot (https://github.com/alii/glyde, 1.0.0)"

/// Discord requires the boundary to be absent from the parts, not
/// unpredictable, and `body.encode` grows this one when a part contains it.
pub const boundary: Boundary = body.default_boundary

/// Opaque and with no `to_string`, so the token cannot reach a log line. A
/// closure, not a field, because `string.inspect` ignores opaqueness.
pub opaque type Token {
  Token(authorization: fn() -> Option(String))
}

/// A bot token, sent as `Authorization: Bot <token>`.
pub fn bot(token: String) -> Token {
  Token(fn() { Some("Bot " <> token) })
}

/// An OAuth2 access token, sent as `Authorization: Bearer <token>`.
pub fn bearer(token: String) -> Token {
  Token(fn() { Some("Bearer " <> token) })
}

/// No `Authorization` header. The webhook and interaction routes drop theirs
/// from the segments, so this is for a route glyde does not wrap.
pub fn unauthenticated() -> Token {
  Token(fn() { None })
}

pub type Config {
  Config(
    token: Token,
    /// Overridable for a proxy or a recording double.
    host: String,
    api_version: Int,
    user_agent: String,
    boundary: Boundary,
  )
}

/// The defaults. Reach any of them with a record update.
pub fn config(token: Token) -> Config {
  Config(token:, host:, api_version:, user_agent:, boundary:)
}

/// Same environment, a different credential. A second `rest.config` would
/// re-default `host`, `api_version`, `user_agent` and `boundary`, throwing
/// away the proxy host you set.
pub fn with_token(config: Config, token: Token) -> Config {
  Config(..config, token:)
}

/// One Discord call, described and inert. Parameterised by what the endpoint
/// returns. The bot token lives in `Config` and never here; a webhook or
/// interaction credential is part of the path, and `auth` says so.
pub opaque type Call(a) {
  Call(
    route: Route,
    path: String,
    query: List(Param),
    reason: Option(String),
    body: Body,
    expect: Expect(a),
    auth: Auth,
  )
}

/// Where a call's credential comes from. Derived from the segments in `build`:
/// a `seg.webhook` or `seg.credential` in the path means `InPath`, so a route
/// that carries a path secret cannot forget to drop the bot token.
type Auth {
  FromConfig
  /// The credential is already a path segment. Sending the bot token as well
  /// would make a 401 ambiguous between the two.
  InPath
}

pub type Expect(a) {
  Decoded(Decoder(a))
  /// A 204 endpoint. `a` is what to return; usually `Nil`.
  NoContent(a)
}

/// `glyde/rest/error` has the questions worth asking of one: `retry_advice`,
/// `counts_as_invalid_request`, `is_token_fatal`.
pub type Failure =
  ApiError

pub fn get(segments: List(Seg), expect: Expect(a)) -> Call(a) {
  build(Get, segments, body.NoBody, expect)
}

pub fn post(segments: List(Seg), body: Body, expect: Expect(a)) -> Call(a) {
  build(Post, segments, body, expect)
}

pub fn patch(segments: List(Seg), body: Body, expect: Expect(a)) -> Call(a) {
  build(Patch, segments, body, expect)
}

pub fn put(segments: List(Seg), body: Body, expect: Expect(a)) -> Call(a) {
  build(Put, segments, body, expect)
}

pub fn delete(segments: List(Seg), expect: Expect(a)) -> Call(a) {
  build(Delete, segments, body.NoBody, expect)
}

fn build(
  method: http.Method,
  segments: List(Seg),
  content: Body,
  expect: Expect(a),
) -> Call(a) {
  let seg.Resolved(path:, route:, in_path_auth:) = seg.resolve(method, segments)
  let auth = case in_path_auth {
    True -> InPath
    False -> FromConfig
  }
  Call(route:, path:, query: [], reason: None, body: content, expect:, auth:)
}

/// Add query parameters. They accumulate rather than replace, so a repeated
/// key produces `?id=1&id=2`, which is how Discord reads one. `query.to_string`
/// spells them out, percent-encoded, when the request is built.
///
/// Only `glyde/rest/query` can build a `Param`, so absence has no spelling
/// here either: there is nothing to hand in for a parameter you are omitting.
pub fn query(call: Call(a), params: List(Param)) -> Call(a) {
  Call(..call, query: list.append(call.query, params))
}

/// `X-Audit-Log-Reason`, percent-encoded: a line break in a header value would
/// split the request. Discord's 512 character limit is not enforced here.
pub fn reason(call: Call(a), why: String) -> Call(a) {
  case why {
    "" -> Call(..call, reason: None)
    _ -> Call(..call, reason: Some(why))
  }
}

/// Split this call into its own rate-limit bucket, for a Discord sublimit.
pub fn split_bucket(call: Call(a), name: String) -> Call(a) {
  Call(..call, route: with_sublimit(call.route, Named(name)))
}

/// Bucket a message deletion by the target's age. Discord splits these and
/// says so in no header (discord-api-docs#1295); the limiter picks the band.
pub fn age_bucket(call: Call(a), created_at_ms: Int) -> Call(a) {
  Call(..call, route: with_sublimit(call.route, Aged(created_at_ms)))
}

/// The scheduling identity. Available without building a `Request`.
pub fn route(call: Call(a)) -> Route {
  call.route
}

/// Always HTTPS, so no config field can send a token in the clear. A plain
/// HTTP double is one `request.set_scheme` away.
pub fn request(config: Config, call: Call(a)) -> Request(Wire) {
  let #(content_type, wire) = body.encode(call.body, boundary: config.boundary)
  Request(
    method: route_method(call.route),
    headers: headers_for(config, call, content_type),
    body: wire,
    scheme: Https,
    host: config.host,
    port: None,
    path: "/api/v" <> int.to_string(config.api_version) <> call.path,
    query: query.to_string(call.query),
  )
}

/// `request` with the body already flattened to bytes, for an HTTP client that
/// takes `BitArray`. Saves the caller reaching into `body.to_bits`.
pub fn request_bytes(config: Config, call: Call(a)) -> Request(BitArray) {
  request.map(request(config, call), body.to_bits)
}

/// Interpret a response with the decoder the `Call` carries. Success is the
/// whole 2xx range: 201 and 204 are everyday Discord answers.
pub fn response(
  call: Call(a),
  status status: Int,
  headers headers: List(Header),
  body body: BitArray,
) -> Result(a, Failure) {
  case status >= 200 && status < 300, call.expect {
    // A NoContent call never reads its body, so do not let one fail on it.
    True, NoContent(value) -> Ok(value)
    True, Decoded(decoder) -> {
      use text <- result.try(read_body(status, headers, body))
      json.parse(text, decoder)
      |> result.map_error(error.malformed(_, text))
    }
    False, _ -> {
      use text <- result.try(read_body(status, headers, body))
      Error(error.from_response(status:, headers:, body: text))
    }
  }
}

/// Discord answers in UTF-8 everywhere, so a body that is not text came from
/// something in between. Reading it as an empty one would report a proxy's
/// binary page as a JSON decode failure.
fn read_body(
  status: Int,
  headers: List(Header),
  body: BitArray,
) -> Result(String, Failure) {
  case bit_array.to_string(body) {
    Ok(text) -> Ok(text)
    Error(Nil) ->
      Error(error.not_text(status:, headers:, bytes: bit_array.byte_size(body)))
  }
}

fn headers_for(
  config: Config,
  call: Call(a),
  content_type: Option(String),
) -> List(Header) {
  let authorization = case call.auth {
    FromConfig -> config.token.authorization()
    InPath -> None
  }
  // Lowercase, which HTTP/2 requires on the wire.
  [
    option.map(authorization, fn(value) { #("authorization", value) }),
    Some(#("user-agent", config.user_agent)),
    option.map(content_type, fn(value) { #("content-type", value) }),
    option.map(call.reason, fn(why) {
      #("x-audit-log-reason", percent.encode(why))
    }),
  ]
  |> list.filter_map(option.to_result(_, Nil))
}
