//// What Discord says when it says no. Split by body shape, not status code:
//// the five bodies behind a non-2xx share almost no fields.
////
//// Only what one HTTP response carries. The caller does the IO, so a dead
//// socket is theirs to describe.

import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder, type Dynamic}
import gleam/float
import gleam/http.{type Header}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{type Order}
import gleam/string
import glyde/internal/decode_error
import glyde/rest/headers
import glyde/rest/limiter.{type Scope, GlobalScope, SharedScope}
import glyde/wire

/// Discord's `code` field. Open, not an enum: Discord calls its own table
/// neither exhaustive nor stable, so a closed set would reject new codes.
pub opaque type ErrorCode {
  ErrorCode(value: Int)
}

pub fn code_from_int(value: Int) -> ErrorCode {
  ErrorCode(value)
}

pub fn code_to_int(code: ErrorCode) -> Int {
  code.value
}

// What each of these means for a caller is in `classify`, and only there. A
// heading over a run of constants used to say it, and drifted.

/// Discord's catch-all: it names no class, which is why `classify` answers
/// `UnknownClass` for it. On a 401 that means this call was rejected, where
/// any other code on a 401 means the token is finished. See `is_token_fatal`.
pub const general_error = ErrorCode(0)

pub const unknown_token = ErrorCode(10_012)

pub const unauthorized = ErrorCode(40_001)

pub const verification_required = ErrorCode(40_002)

pub const invalid_authentication_token = ErrorCode(50_014)

pub const invalid_oauth2_token = ErrorCode(50_025)

pub const missing_oauth2_scope = ErrorCode(50_026)

pub const invalid_webhook_token = ErrorCode(50_027)

pub const two_factor_required = ErrorCode(60_003)

pub const invalid_client_secret = ErrorCode(530_007)

pub const explicit_content_blocked = ErrorCode(20_009)

pub const not_authorized_for_application = ErrorCode(20_012)

pub const owner_only = ErrorCode(20_018)

pub const missing_access = ErrorCode(50_001)

pub const cannot_act_on_dm = ErrorCode(50_003)

pub const cannot_message_user = ErrorCode(50_007)

pub const missing_permissions = ErrorCode(50_013)

pub const no_mutual_guilds = ErrorCode(50_278)

pub const cannot_send_sticker = ErrorCode(50_600)

pub const unknown_channel = ErrorCode(10_003)

pub const unknown_guild = ErrorCode(10_004)

pub const unknown_member = ErrorCode(10_007)

pub const unknown_message = ErrorCode(10_008)

pub const unknown_role = ErrorCode(10_011)

pub const unknown_user = ErrorCode(10_013)

pub const unknown_emoji = ErrorCode(10_014)

/// Also what a follow-up gets once the 15 minute interaction token expires.
pub const unknown_webhook = ErrorCode(10_015)

pub const unknown_ban = ErrorCode(10_026)

/// The three second deadline for the first response passed, or the token was
/// already spent. Retrying always fails.
pub const unknown_interaction = ErrorCode(10_062)

pub const interaction_send_failed = ErrorCode(40_043)

/// You already responded. Send a follow-up instead.
pub const interaction_already_acknowledged = ErrorCode(40_060)

pub const too_many_followups = ErrorCode(40_094)

pub const slowmode_rate_limit = ErrorCode(20_016)

pub const announcement_rate_limit = ErrorCode(20_022)

pub const channel_write_rate_limit = ErrorCode(20_028)

pub const guild_write_rate_limit = ErrorCode(20_029)

pub const max_old_message_edits = ErrorCode(30_046)

pub const resource_rate_limited = ErrorCode(40_062)

pub const messages_temporarily_disabled = ErrorCode(40_004)

pub const feature_temporarily_disabled = ErrorCode(40_006)

pub const index_not_available = ErrorCode(110_000)

pub const api_resource_overloaded = ErrorCode(130_000)

pub const unique_username_failed = ErrorCode(530_006)

pub const empty_message = ErrorCode(50_006)

pub const too_few_or_many_to_delete = ErrorCode(50_016)

pub const too_old_to_bulk_delete = ErrorCode(50_034)

/// The one that carries a nested `errors` object.
pub const invalid_form_body = ErrorCode(50_035)

/// glyde built a URL for an API version Discord no longer serves. Our bug.
pub const invalid_api_version = ErrorCode(50_041)

pub const file_too_large = ErrorCode(50_045)

pub const invalid_file = ErrorCode(50_046)

/// glyde sent JSON Discord could not parse. Our bug.
pub const invalid_json = ErrorCode(50_109)

pub const entity_too_large = ErrorCode(40_005)

pub const reaction_blocked = ErrorCode(90_001)

pub const automod_blocked = ErrorCode(200_000)

pub const automod_title_blocked = ErrorCode(200_001)

pub const harmful_link_blocked = ErrorCode(240_000)

/// A well formed Discord error, unlike the Cloudflare ban page, which has no
/// JSON body at all and lands in `Opaque`.
pub const cloudflare_blocked = ErrorCode(40_333)

/// What a code says about the request that produced it. `is_transient` and
/// `is_token_fatal` are questions asked of this, so a code cannot be filed
/// one way and answered another.
pub type CodeClass {
  /// The client's own token is finished: stop, do not retry.
  TokenFatal
  /// The webhook or interaction token in the URL is gone. Says nothing about
  /// the client's token, which is the whole point of keeping it apart.
  PathTokenDead
  /// Permanently wrong for this caller or this input.
  Forbidden
  /// The thing addressed is not there any more. Drop it from any cache.
  Gone
  /// Rate-limit shaped, but on a resource rather than a route bucket. Do not
  /// feed these to the limiter.
  ResourceRateLimited
  /// Discord's own wording tells you to try again.
  Transient
  /// The request has to change before it can work.
  BadRequest
  /// The content has to change, not the call.
  Moderation
  /// A code this build does not name, and `general_error`, which names no
  /// class either. Discord adds codes continuously.
  UnknownClass
}

/// Every code this build names, and what it means for the caller. The numbers
/// are the constants above, spelled out because Gleam has no constants in
/// patterns and this is asked several times per failed request.
pub fn classify(code: ErrorCode) -> CodeClass {
  case code.value {
    10_012 | 40_001 | 50_014 | 50_025 | 530_007 -> TokenFatal

    10_015 | 10_062 | 50_027 -> PathTokenDead

    // 40_333 is Cloudflare refusing the call, not Discord moderating content.
    20_009
    | 20_012
    | 20_018
    | 40_002
    | 40_333
    | 50_001
    | 50_003
    | 50_007
    | 50_013
    | 50_026
    | 50_278
    | 50_600
    | 60_003 -> Forbidden

    10_003
    | 10_004
    | 10_007
    | 10_008
    | 10_011
    | 10_013
    | 10_014
    | 10_026
    | 40_043
    | 40_060
    | 40_094 -> Gone

    20_016 | 20_022 | 20_028 | 20_029 | 30_046 | 40_062 -> ResourceRateLimited

    40_004 | 40_006 | 110_000 | 130_000 | 530_006 -> Transient

    40_005
    | 50_006
    | 50_016
    | 50_034
    | 50_035
    | 50_041
    | 50_045
    | 50_046
    | 50_109 -> BadRequest

    90_001 | 200_000 | 200_001 | 240_000 -> Moderation

    _ -> UnknownClass
  }
}

/// One step of the path into the request body Discord rejected. `Index` stays
/// apart from `Key` so the array versus object distinction survives.
pub type PathSegment {
  Key(String)
  Index(Int)
}

/// One leaf of the recursive `errors` object. `code` is an open set of strings
/// Discord has never documented, empty when the leaf was a bare string.
pub type FieldError {
  FieldError(path: List(PathSegment), code: String, message: String)
}

pub type RateLimit {
  RateLimit(
    /// Seconds, from the body. The `Retry-After` header is the same number
    /// rounded up to a whole second.
    retry_after: Float,
    /// The answer `headers.resolve_scope` gives, from the scope header, the
    /// body's `global` flag and the shape of the response. `is_global` asks
    /// the only question most callers have.
    scope: Scope,
    /// Present when the limit is on a resource, slowmode say, not a route.
    code: Option(ErrorCode),
    /// Absent on a global 429, which carries no bucket headers at all.
    bucket: Option(String),
  )
}

/// Whether the whole token is limited rather than one route.
pub fn is_global(limit: RateLimit) -> Bool {
  limit.scope == GlobalScope
}

/// A decode failure that kept the raw text, which the stdlib error drops.
/// Without it, a shape change and a wrong decoder look the same afterwards.
pub type DecodeFailure {
  DecodeFailure(error: json.DecodeError, raw: String)
}

/// The `error` an OAuth2 token endpoint answers with, from RFC 6749 section
/// 5.2. Open at the tail, like every other enum we read off the wire.
pub type OAuthError {
  /// The request is missing a parameter, or repeats one.
  InvalidRequest
  /// The client id or secret is wrong. Re-authenticating with them will not
  /// work either.
  InvalidClient
  /// The code, refresh token or grant is expired, revoked, or was issued to
  /// another client.
  InvalidGrant
  /// This client is not allowed this grant type.
  UnauthorizedClient
  /// The grant type is one the endpoint does not support.
  UnsupportedGrantType
  /// A scope was unknown, malformed, or wider than the one already granted.
  InvalidScope
  /// A name RFC 6749 does not define, kept as sent.
  UnknownOAuthError(String)
}

fn known_oauth_error(value: String) -> Option(OAuthError) {
  case value {
    "invalid_request" -> Some(InvalidRequest)
    "invalid_client" -> Some(InvalidClient)
    "invalid_grant" -> Some(InvalidGrant)
    "unauthorized_client" -> Some(UnauthorizedClient)
    "unsupported_grant_type" -> Some(UnsupportedGrantType)
    "invalid_scope" -> Some(InvalidScope)
    _ -> None
  }
}

/// The name as the endpoint spells it, which is what a log should show.
pub fn oauth_error_to_string(error: OAuthError) -> String {
  case error {
    InvalidRequest -> "invalid_request"
    InvalidClient -> "invalid_client"
    InvalidGrant -> "invalid_grant"
    UnauthorizedClient -> "unauthorized_client"
    UnsupportedGrantType -> "unsupported_grant_type"
    InvalidScope -> "invalid_scope"
    UnknownOAuthError(other) -> other
  }
}

pub type ApiError {
  /// A 4xx or 5xx carrying a Discord error object. `fields` is empty unless
  /// Discord sent a nested `errors` object, which in practice means 50035.
  Discord(
    status: Int,
    code: ErrorCode,
    message: String,
    fields: List(FieldError),
    raw: String,
  )

  /// A 429 from Discord itself. Its body has no `code` and no `errors`.
  RateLimited(status: Int, limit: RateLimit)

  /// The OAuth2 token endpoints answer in RFC 6749's shape, which shares not
  /// one field with Discord's own.
  OAuth(status: Int, error: OAuthError, description: Option(String))

  /// A non-2xx whose body was none of the above: a Cloudflare ban page, an
  /// HTML 502, an empty body. A 429 lands here when its body is not Discord's
  /// rate-limit shape, because that is a ban and retrying extends it.
  Opaque(status: Int, content_type: Option(String), body: String)

  /// The bytes were not UTF-8, so there is no text to read or parse at all.
  /// Discord answers in UTF-8 everywhere, so this came from something in
  /// between. `bytes` is the length, because the body cannot be shown.
  NotText(status: Int, content_type: Option(String), bytes: Int)

  /// A 2xx whose payload did not match the decoder.
  Malformed(DecodeFailure)
}

/// One line per failure, for a host that just wants to print it. A caller
/// acting on a 429 reads `retry_advice` off the typed value instead.
pub fn describe(error: ApiError) -> String {
  case error {
    Discord(status:, code:, message:, fields: _, raw: _) ->
      "Discord said no ("
      <> int.to_string(status)
      <> ", code "
      <> int.to_string(code_to_int(code))
      <> "): "
      <> message
    RateLimited(status: _, limit:) ->
      "rate limited, retry in "
      <> int.to_string(float.round(limit.retry_after *. 1000.0))
      <> "ms"
      <> case is_global(limit) {
        True -> " (global)"
        False -> ""
      }
    OAuth(status: _, error: name, description:) ->
      "OAuth refused: "
      <> oauth_error_to_string(name)
      <> case description {
        Some(said) -> ", " <> said
        None -> ""
      }
    Opaque(status:, content_type: _, body: _) ->
      "unreadable " <> int.to_string(status) <> " from Discord"
    NotText(status:, content_type: _, bytes:) ->
      "a "
      <> int.to_string(status)
      <> " from Discord of "
      <> int.to_string(bytes)
      <> " bytes that were not text"
    // The raw body is on the failure and not printed: some are megabytes.
    Malformed(DecodeFailure(error: why, raw: _)) -> {
      let said = case why {
        json.UnexpectedEndOfInput -> "the JSON stopped early"
        json.UnexpectedByte(byte) -> "unexpected byte " <> byte
        json.UnexpectedSequence(text) -> "unexpected " <> text
        // The same words a gateway dispatch that would not fit gets: both
        // call `decode_error.describe`.
        json.UnableToDecode(errors) -> decode_error.describe(errors)
      }
      "could not read Discord's answer: " <> said
    }
  }
}

/// For a response whose body would not become a `String`. Separate from
/// `from_response`, which classifies by what the text says.
pub fn not_text(
  status status: Int,
  headers sent: List(Header),
  bytes bytes: Int,
) -> ApiError {
  NotText(status:, content_type: headers.header(sent, "content-type"), bytes:)
}

/// Classify a non-2xx by the shape of its body.
pub fn from_response(
  status status: Int,
  headers sent: List(Header),
  body body: String,
) -> ApiError {
  let unreadable = fn() {
    Opaque(status:, content_type: headers.header(sent, "content-type"), body:)
  }

  case json.parse(body, decode.dynamic) {
    Error(_) -> unreadable()
    Ok(document) ->
      case decode.run(document, shape_decoder()) {
        Ok(RateLimitShape(retry_after:, global:, code:)) ->
          RateLimited(
            status:,
            limit: RateLimit(
              retry_after:,
              scope: headers.resolve_scope(sent, headers.RateLimitBody(global:)),
              code:,
              bucket: headers.header(sent, "x-ratelimit-bucket"),
            ),
          )

        Ok(DiscordShape(code:, message:, fields:)) ->
          Discord(status:, code: ErrorCode(code), message:, fields:, raw: body)

        Ok(OAuthShape(error:, description:)) ->
          OAuth(status:, error:, description:)

        Ok(UnknownShape) | Error(_) -> unreadable()
      }
  }
}

/// Flatten Discord's nested `errors` object into one entry per rejected field,
/// sorted by path: decoding loses the order Discord wrote the keys in.
fn field_errors(errors: Dynamic) -> List(FieldError) {
  walk(errors, [])
}

/// Render a path as `embed.fields[0].value`. The empty path is the request as
/// a whole, which Discord reports by putting `_errors` at the root.
pub fn path_to_string(path: List(PathSegment)) -> String {
  list.fold(path, "", fn(rendered, segment) {
    case segment, rendered {
      Index(index), _ -> rendered <> "[" <> int.to_string(index) <> "]"
      Key(key), "" -> key
      Key(key), _ -> rendered <> "." <> key
    }
  })
}

pub type Retry {
  DoNotRetry
  /// Wait this many seconds. The caller sleeps, because glyde has no clock.
  RetryAfter(seconds: Float)
  RetryWithBackoff
}

pub fn retry_advice(error: ApiError) -> Retry {
  case error {
    RateLimited(_, limit) -> RetryAfter(limit.retry_after)

    // A sublimit 429 carries a `code` and no `retry_after`, so it arrives
    // here: wait, but Discord has not said how long.
    Discord(status:, code:, ..) ->
      case is_transient(code) || status >= 500 || status == 429 {
        True -> RetryWithBackoff
        False -> DoNotRetry
      }

    // A 5xx here is a proxy or a gateway page. A 429 is a Cloudflare ban, and
    // retrying that one lengthens it.
    Opaque(status:, ..) | NotText(status:, ..) ->
      case status >= 500 {
        True -> RetryWithBackoff
        False -> DoNotRetry
      }

    OAuth(..) -> DoNotRetry
    Malformed(_) -> DoNotRetry
  }
}

/// Whether this counts against Discord's budget of 10,000 invalid requests per
/// 10 minutes, which ends in a Cloudflare ban of the whole IP.
pub fn counts_as_invalid_request(error: ApiError) -> Bool {
  case error {
    // Discord excludes shared-scope 429s: somebody else's traffic.
    RateLimited(_, limit) -> limit.scope != SharedScope
    Discord(status:, ..)
    | OAuth(status:, ..)
    | Opaque(status:, ..)
    | NotText(status:, ..) -> status == 401 || status == 403 || status == 429
    Malformed(_) -> False
  }
}

/// The client's own token is finished and it must stop, not retry. A 401
/// carrying any code other than 0 is Discord rejecting the token, not the
/// call, so an unnamed code on a 401 still counts.
pub fn is_token_fatal(error: ApiError) -> Bool {
  case error {
    Discord(status:, code:, ..) ->
      case classify(code) {
        TokenFatal -> True
        // A webhook or interaction token lives in the URL, not the
        // `Authorization` header. Its 401 says nothing about the client's
        // token, so sweeping it in here would stop a healthy client.
        PathTokenDead -> False
        // Spelled out so a class added later has to answer this question
        // rather than inherit the 401 guess.
        Forbidden
        | Gone
        | ResourceRateLimited
        | Transient
        | BadRequest
        | Moderation
        | UnknownClass -> status == 401 && code != general_error
      }

    // RFC 6749 section 5.2: both refuse the credentials themselves, so the
    // same client id, secret or refresh token cannot succeed later.
    OAuth(error: InvalidClient, ..) | OAuth(error: InvalidGrant, ..) -> True
    OAuth(..) -> False

    RateLimited(..) | Opaque(..) | NotText(..) | Malformed(_) -> False
  }
}

/// The webhook or interaction token in the URL is gone: deleted, rotated, or
/// spent. Fix it by getting a new one, not by re-authenticating.
pub fn is_path_token_dead(error: ApiError) -> Bool {
  case error {
    Discord(code:, ..) -> classify(code) == PathTokenDead
    _ -> False
  }
}

fn is_transient(code: ErrorCode) -> Bool {
  classify(code) == Transient
}

type Shape {
  RateLimitShape(retry_after: Float, global: Bool, code: Option(ErrorCode))
  DiscordShape(code: Int, message: String, fields: List(FieldError))
  OAuthShape(error: OAuthError, description: Option(String))
  UnknownShape
}

/// Rate limit first: a 429 body has a `message` too, so it would otherwise
/// decode as an ordinary Discord error and lose its `retry_after`.
fn shape_decoder() -> Decoder(Shape) {
  decode.one_of(rate_limit_shape(), or: [
    discord_shape(),
    oauth_shape(),
    decode.success(UnknownShape),
  ])
}

fn rate_limit_shape() -> Decoder(Shape) {
  use retry_after <- decode.field("retry_after", wire.number())
  use global <- wire.flag_field("global", False)
  use code <- wire.opt_field("code", wire.integer())
  decode.success(RateLimitShape(
    retry_after:,
    global:,
    code: option.map(code, ErrorCode),
  ))
}

fn discord_shape() -> Decoder(Shape) {
  use message <- decode.field("message", decode.string)
  use code <- wire.int_field("code", 0)
  use errors <- wire.opt_field("errors", decode.dynamic)
  let fields = case errors {
    Some(errors) -> field_errors(errors)
    None -> []
  }
  decode.success(DiscordShape(code:, message:, fields:))
}

fn oauth_shape() -> Decoder(Shape) {
  use error <- decode.field(
    "error",
    wire.string_enum_with_fallback(known_oauth_error, UnknownOAuthError),
  )
  use description <- wire.opt_field("error_description", decode.string)
  decode.success(OAuthShape(error:, description:))
}

/// The recursive shapes Discord's `errors` object takes.
type Node {
  Leaf(code: String, message: String)
  Message(String)
  Object(Dict(String, Dynamic))
  Items(List(Dynamic))
  Ignored
}

fn walk(node: Dynamic, path: List(PathSegment)) -> List(FieldError) {
  case decode.run(node, node_decoder()) {
    Ok(Leaf(code:, message:)) -> [FieldError(path:, code:, message:)]
    Ok(Message(message)) -> [FieldError(path:, code: "", message:)]
    Ok(Object(entries)) -> walk_object(entries, path)
    Ok(Items(items)) ->
      list.index_map(items, fn(item, index) {
        walk(item, list.append(path, [Index(index)]))
      })
      |> list.flatten
    Ok(Ignored) | Error(_) -> []
  }
}

fn node_decoder() -> Decoder(Node) {
  decode.one_of(leaf_decoder(), or: [
    decode.map(decode.string, Message),
    decode.map(decode.dict(decode.string, decode.dynamic), Object),
    decode.map(decode.list(decode.dynamic), Items),
    decode.success(Ignored),
  ])
}

fn leaf_decoder() -> Decoder(Node) {
  use code <- decode.field("code", decode.string)
  use message <- decode.field("message", decode.string)
  decode.success(Leaf(code:, message:))
}

fn walk_object(
  entries: Dict(String, Dynamic),
  path: List(PathSegment),
) -> List(FieldError) {
  dict.to_list(entries)
  |> list.sort(fn(one, other) { compare(segment(one.0), segment(other.0)) })
  |> list.flat_map(fn(entry) {
    let #(key, value) = entry
    case key {
      // Not a field: errors about the object holding it.
      "_errors" -> walk_group(value, path)
      _ -> walk(value, list.append(path, [segment(key)]))
    }
  })
}

fn walk_group(group: Dynamic, path: List(PathSegment)) -> List(FieldError) {
  case decode.run(group, decode.list(decode.dynamic)) {
    Ok(items) -> list.flat_map(items, walk(_, path))
    Error(_) -> walk(group, path)
  }
}

/// Discord writes array indices as object keys, so `"0"` is position 0, not a
/// field named "0". Anything that does not round trip back is a name.
fn segment(key: String) -> PathSegment {
  case int.parse(key) {
    Ok(index) if index >= 0 ->
      case int.to_string(index) == key {
        True -> Index(index)
        False -> Key(key)
      }
    _ -> Key(key)
  }
}

fn compare(one: PathSegment, other: PathSegment) -> Order {
  case one, other {
    Index(one), Index(other) -> int.compare(one, other)
    Key(one), Key(other) -> string.compare(one, other)
    Index(_), Key(_) -> order.Lt
    Key(_), Index(_) -> order.Gt
  }
}
