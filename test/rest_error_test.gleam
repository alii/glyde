import gleam/dynamic/decode
import gleam/http.{type Header}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import glyde/rest/error.{FieldError, Index, Key}
import glyde/rest/headers
import glyde/rest/limiter.{GlobalScope, SharedScope, UserScope}

fn read(status: Int, headers: List(Header), body: String) -> error.ApiError {
  error.from_response(status:, headers:, body:)
}

fn fields_of(body: String) -> List(error.FieldError) {
  let assert error.Discord(fields:, ..) = read(400, [], body)
  fields
}

// Four real error bodies, verbatim.

/// `_errors` at the root complains about the request, not a field.
pub fn root_errors_test() {
  let body =
    "{\"code\":50035,\"message\":\"Invalid Form Body\",\"errors\":{\"_errors\":[{\"code\":\"APPLICATION_COMMAND_TOO_LARGE\",\"message\":\"Command exceeds maximum size (8000)\"}]}}"

  let assert error.Discord(status:, code:, message:, fields:, raw:) =
    read(400, [], body)

  assert status == 400
  assert code == error.invalid_form_body
  assert message == "Invalid Form Body"
  assert raw == body
  assert fields
    == [
      FieldError(
        path: [],
        code: "APPLICATION_COMMAND_TOO_LARGE",
        message: "Command exceeds maximum size (8000)",
      ),
    ]
}

pub fn one_field_test() {
  let body =
    "{\"code\":50035,\"message\":\"Invalid Form Body\",\"errors\":{\"access_token\":{\"_errors\":[{\"code\":\"BASE_TYPE_REQUIRED\",\"message\":\"This field is required\"}]}}}"

  assert fields_of(body)
    == [
      FieldError(
        path: [Key("access_token")],
        code: "BASE_TYPE_REQUIRED",
        message: "This field is required",
      ),
    ]
}

/// Discord writes an array index as an object key.
pub fn array_index_as_key_test() {
  let body =
    "{\"code\":50035,\"message\":\"Invalid Form Body\",\"errors\":{\"activities\":{\"0\":{\"platform\":{\"_errors\":[{\"code\":\"BASE_TYPE_CHOICES\",\"message\":\"Value must be one of ('desktop', 'android', 'ios').\"}]},\"type\":{\"_errors\":[{\"code\":\"BASE_TYPE_CHOICES\",\"message\":\"Value must be one of (0, 1, 2, 3, 4, 5).\"}]}}}}}"

  let found = fields_of(body)

  assert found
    == [
      FieldError(
        path: [Key("activities"), Index(0), Key("platform")],
        code: "BASE_TYPE_CHOICES",
        message: "Value must be one of ('desktop', 'android', 'ios').",
      ),
      FieldError(
        path: [Key("activities"), Index(0), Key("type")],
        code: "BASE_TYPE_CHOICES",
        message: "Value must be one of (0, 1, 2, 3, 4, 5).",
      ),
    ]

  let assert [first, ..] = found
  assert error.path_to_string(first.path) == "activities[0].platform"
}

pub fn nested_object_path_test() {
  let body =
    "{\"code\":50035,\"message\":\"Invalid Form Body\",\"errors\":{\"data\":{\"components\":{\"_errors\":[{\"code\":\"BASE_TYPE_MAX_LENGTH\",\"message\":\"Must be 5 or fewer in length.\"}]}}}}"

  assert fields_of(body)
    == [
      FieldError(
        path: [Key("data"), Key("components")],
        code: "BASE_TYPE_MAX_LENGTH",
        message: "Must be 5 or fewer in length.",
      ),
    ]
}

/// A path mixing object keys and an array index.
pub fn deep_mixed_path_test() {
  let body =
    "{\"code\":50035,\"message\":\"Invalid Form Body\",\"errors\":{\"embed\":{\"fields\":{\"0\":{\"value\":{\"_errors\":[{\"code\":\"BASE_TYPE_REQUIRED\",\"message\":\"This field is required\"}]}}}}}}"

  let assert [only] = fields_of(body)

  assert only.path == [Key("embed"), Key("fields"), Index(0), Key("value")]
  assert error.path_to_string(only.path) == "embed.fields[0].value"
}

/// `_errors` is never a path step, so nesting groups does not grow the path.
pub fn nested_groups_test() {
  let body =
    "{\"code\":50035,\"message\":\"Invalid Form Body\",\"errors\":{\"form_fields\":{\"label\":{\"_errors\":[{\"_errors\":[{\"code\":\"BASE_TYPE_REQUIRED\",\"message\":\"This field is required\"}]}]}}}}"

  assert fields_of(body)
    == [
      FieldError(
        path: [Key("form_fields"), Key("label")],
        code: "BASE_TYPE_REQUIRED",
        message: "This field is required",
      ),
    ]
}

/// A leaf that is a bare string carries no code.
pub fn bare_string_leaf_test() {
  let body =
    "{\"code\":50035,\"message\":\"Invalid Form Body\",\"errors\":{\"name\":\"too short\"}}"

  assert fields_of(body)
    == [FieldError(path: [Key("name")], code: "", message: "too short")]
}

/// A field whose value is an array is indexed rather than dropped.
pub fn array_valued_field_test() {
  let body =
    "{\"code\":50035,\"message\":\"Invalid Form Body\",\"errors\":{\"tags\":[\"too many\",{\"code\":\"X\",\"message\":\"y\"}]}}"

  assert fields_of(body)
    == [
      FieldError(path: [Key("tags"), Index(0)], code: "", message: "too many"),
      FieldError(path: [Key("tags"), Index(1)], code: "X", message: "y"),
    ]
}

/// An `errors` that is not an object must not take the decode down.
pub fn errors_is_not_an_object_test() {
  let numeric =
    "{\"code\":50035,\"message\":\"Invalid Form Body\",\"errors\":12}"
  let null =
    "{\"code\":50035,\"message\":\"Invalid Form Body\",\"errors\":null}"
  let empty = "{\"code\":50035,\"message\":\"Invalid Form Body\",\"errors\":{}}"

  assert fields_of(numeric) == []
  assert fields_of(null) == []
  assert fields_of(empty) == []
}

pub fn no_errors_key_test() {
  assert fields_of("{\"code\":10008,\"message\":\"Unknown Message\"}") == []
}

/// The object underneath has no meaningful key order, so glyde sorts by path.
pub fn fields_come_out_sorted_by_path_test() {
  let body =
    "{\"code\":50035,\"message\":\"Invalid Form Body\",\"errors\":{\"zeta\":\"z\",\"alpha\":\"a\"}}"

  assert fields_of(body)
    == [
      FieldError(path: [Key("alpha")], code: "", message: "a"),
      FieldError(path: [Key("zeta")], code: "", message: "z"),
    ]
}

/// Indices sort as numbers: as strings, "10" would come before "2".
pub fn indices_sort_numerically_test() {
  let body =
    "{\"code\":50035,\"message\":\"Invalid Form Body\",\"errors\":{\"items\":{\"10\":\"ten\",\"2\":\"two\"}}}"

  assert fields_of(body)
    == [
      FieldError(path: [Key("items"), Index(2)], code: "", message: "two"),
      FieldError(path: [Key("items"), Index(10)], code: "", message: "ten"),
    ]
}

fn path_table() -> List(#(List(error.PathSegment), String)) {
  [
    #([], ""),
    #([Key("username")], "username"),
    #([Index(0)], "[0]"),
    #([Key("embeds"), Index(0), Key("description")], "embeds[0].description"),
    #([Key("a"), Key("b"), Key("c")], "a.b.c"),
    #([Index(1), Index(2)], "[1][2]"),
    // A key that only looks like a number keeps its meaning.
    #([Key("007")], "007"),
  ]
}

pub fn path_to_string_table_test() {
  list.each(path_table(), fn(row) {
    let #(path, expected) = row
    assert error.path_to_string(path) == expected
  })
}

/// A 401 with `code: 0` is one rejected call. A 401 with any other code means
/// Discord is refusing the token itself.
pub fn unauthorized_body_test() {
  let body = "{\"message\":\"401: Unauthorized\",\"code\":0}"
  let assert error.Discord(status:, code:, message:, fields:, ..) =
    read(401, [], body)

  assert status == 401
  assert code == error.general_error
  assert message == "401: Unauthorized"
  assert fields == []
  assert error.is_token_fatal(read(401, [], body)) == False
}

fn token_fatal_table() -> List(#(Int, Int, Bool)) {
  [
    #(401, 0, False),
    #(401, 50_014, True),
    #(401, 40_001, True),
    // Any code at all on a 401 that is not the catch-all.
    #(401, 20_012, True),
    #(403, 50_014, True),
    #(403, 10_012, True),
    #(403, 50_013, False),
    #(400, 50_035, False),
    #(404, 10_008, False),
    // The credential in the path, not the client's. `glyde/webhook` sends
    // no `Authorization` header at all, so a bot that stopped here would be
    // stopping over somebody else's dead token.
    #(401, 50_027, False),
    #(401, 10_015, False),
    #(404, 10_062, False),
  ]
}

pub fn token_fatal_table_test() {
  list.each(token_fatal_table(), fn(row) {
    let #(status, code, expected) = row
    let body = "{\"code\":" <> int_to_string(code) <> ",\"message\":\"nope\"}"

    assert #(status, code, error.is_token_fatal(read(status, [], body)))
      == #(status, code, expected)
  })
}

fn path_token_table() -> List(#(Int, Bool)) {
  [
    #(50_027, True),
    #(10_015, True),
    #(10_062, True),
    #(50_014, False),
    #(40_001, False),
    #(50_013, False),
    #(0, False),
  ]
}

/// The other half of the pair: a webhook or interaction token is gone, which
/// `is_token_fatal` deliberately answers False for.
pub fn path_token_dead_table_test() {
  list.each(path_token_table(), fn(row) {
    let #(code, expected) = row
    let body = "{\"code\":" <> int_to_string(code) <> ",\"message\":\"nope\"}"

    assert #(code, error.is_path_token_dead(read(401, [], body)))
      == #(code, expected)
  })

  // Only a Discord body carries a code, so the other shapes are never this.
  assert error.is_path_token_dead(read(401, [], "not json")) == False
}

fn class_table() -> List(#(error.ErrorCode, error.CodeClass)) {
  [
    #(error.invalid_authentication_token, error.TokenFatal),
    #(error.invalid_webhook_token, error.PathTokenDead),
    #(error.unknown_interaction, error.PathTokenDead),
    #(error.missing_permissions, error.Forbidden),
    #(error.unknown_message, error.Gone),
    #(error.slowmode_rate_limit, error.ResourceRateLimited),
    #(error.api_resource_overloaded, error.Transient),
    // Filed under a "Transient" heading once, and never retryable.
    #(error.invalid_form_body, error.BadRequest),
    #(error.too_old_to_bulk_delete, error.BadRequest),
    #(error.automod_blocked, error.Moderation),
    // The catch-all says nothing, and neither does a code we do not name.
    #(error.general_error, error.UnknownClass),
    #(error.code_from_int(999_999), error.UnknownClass),
  ]
}

pub fn classify_table_test() {
  list.each(class_table(), fn(row) {
    let #(code, expected) = row
    assert #(error.code_to_int(code), error.classify(code))
      == #(error.code_to_int(code), expected)
  })
}

/// `ErrorCode` is an open set of ints, so a constant added without a row in
/// the class table cannot be a compile error. It classifies as `UnknownClass`
/// instead, which on a 401 reads as the client's own token being dead. The
/// catch-all is the one code that says nothing on purpose.
pub fn every_named_code_has_a_class_test() {
  list.each(code_table(), fn(row) {
    let #(code, value) = row
    case code == error.general_error {
      True -> Nil
      False -> {
        assert #(value, error.classify(code)) != #(value, error.UnknownClass)
      }
    }
  })
}

fn int_to_string(value: Int) -> String {
  json.to_string(json.int(value))
}

pub fn rate_limited_test() {
  let body =
    "{\"message\":\"You are being rate limited.\",\"retry_after\":64.57,\"global\":false}"
  let headers = [
    #("x-ratelimit-scope", "user"),
    #("x-ratelimit-bucket", "80c17d2f203122d936070c88c8d10f33"),
  ]

  assert read(429, headers, body)
    == error.RateLimited(
      status: 429,
      limit: error.RateLimit(
        retry_after: 64.57,
        scope: UserScope,
        code: None,
        bucket: Some("80c17d2f203122d936070c88c8d10f33"),
      ),
    )
}

/// Discord drops the fractional part when it is zero, so `retry_after` arrives
/// as `2` as well as `2.5`.
pub fn whole_second_retry_after_test() {
  let body = "{\"message\":\"rate limited\",\"retry_after\":2,\"global\":false}"
  let assert error.RateLimited(limit:, ..) = read(429, [], body)

  assert limit.retry_after == 2.0
  assert error.retry_advice(read(429, [], body)) == error.RetryAfter(2.0)
}

/// A global 429 carries no rate-limit headers, so the body's flag is all there
/// is to read.
pub fn global_rate_limit_test() {
  let body =
    "{\"message\":\"You are being rate limited.\",\"retry_after\":0.75,\"global\":true}"
  let assert error.RateLimited(limit:, ..) = read(429, [], body)

  assert limit.scope == GlobalScope
  assert error.is_global(limit) == True
  assert limit.bucket == None
}

/// A resource limit such as slowmode is not the route's bucket.
pub fn resource_rate_limit_test() {
  let body =
    "{\"message\":\"slow down\",\"retry_after\":5.0,\"global\":false,\"code\":20016}"
  let assert error.RateLimited(limit:, ..) = read(429, [], body)

  assert limit.code == Some(error.slowmode_rate_limit)
}

/// A sublimit 429 has a `code` and no `retry_after`, so it reads as an ordinary
/// error and still spends from the per-IP invalid-request budget.
pub fn sublimit_429_test() {
  let body =
    "{\"code\":20029,\"message\":\"The write action you are performing on the server has hit the write rate limit\"}"
  let subject = read(429, [], body)

  let assert error.Discord(status:, code:, ..) = subject
  assert status == 429
  assert code == error.guild_write_rate_limit
  assert error.counts_as_invalid_request(subject) == True
  // No interval came back, so the caller has to back off on its own.
  assert error.retry_advice(subject) == error.RetryWithBackoff
}

fn scope_table() -> List(#(String, headers.Scope)) {
  [
    #("user", UserScope),
    #("shared", SharedScope),
    #("global", GlobalScope),
    // A value this build does not name resolves like an absent header, and
    // this body has no bucket beside it and no `global` flag.
    #("something-new", UserScope),
  ]
}

pub fn scope_table_test() {
  let body = "{\"message\":\"rate limited\",\"retry_after\":1.5}"

  list.each(scope_table(), fn(row) {
    let #(raw, expected) = row
    let assert error.RateLimited(limit:, ..) =
      read(429, [#("X-RateLimit-Scope", raw)], body)

    assert #(raw, limit.scope) == #(raw, expected)
  })
}

/// Discord adding a scope name must not switch the body's `global` flag off:
/// a caller that pauses everything on `is_global` has to pause.
pub fn an_unnamed_scope_still_reads_the_global_flag_test() {
  let body =
    "{\"message\":\"rate limited\",\"retry_after\":1.5,\"global\":true}"
  let assert error.RateLimited(limit:, ..) =
    read(429, [#("x-ratelimit-scope", "something-new")], body)

  assert limit.scope == GlobalScope
  assert error.is_global(limit) == True
}

/// The header reader and the error reader run one ladder, so no response can
/// be a route limit to one and a global limit to the other.
fn agreement_table() -> List(#(List(#(String, String)), String)) {
  let plain = "{\"message\":\"rate limited\",\"retry_after\":1.5}"
  let global =
    "{\"message\":\"rate limited\",\"retry_after\":1.5,\"global\":true}"
  [
    #([#("x-ratelimit-scope", "user"), #("x-ratelimit-bucket", "h")], plain),
    #([#("x-ratelimit-scope", "shared"), #("x-ratelimit-bucket", "h")], plain),
    #([#("x-ratelimit-scope", "global")], global),
    // A name neither reader knows leaves the flag and the headers to answer.
    #([#("x-ratelimit-scope", "moon")], global),
    #([#("x-ratelimit-scope", "moon"), #("x-ratelimit-bucket", "h")], plain),
    // Discord's own mirror of the flag, which only the header reader saw.
    #([#("x-ratelimit-global", "true")], plain),
    #([], global),
    #([#("x-ratelimit-bucket", "h")], plain),
  ]
}

pub fn both_readers_resolve_a_429_the_same_way_test() {
  list.each(agreement_table(), fn(row) {
    let #(sent, body) = row
    let assert error.RateLimited(limit:, ..) = read(429, sent, body)
    let assert limiter.Throttled(scope:, ..) = headers.outcome(429, sent, body)

    assert #(sent, limit.scope) == #(sent, scope)
  })
}

/// A 429 whose body is not Discord's shape is a Cloudflare ban, and retrying
/// makes it longer.
pub fn cloudflare_ban_test() {
  let subject = read(429, [#("content-type", "text/html")], "error code: 1015")

  assert subject
    == error.Opaque(
      status: 429,
      content_type: Some("text/html"),
      body: "error code: 1015",
    )
  assert error.retry_advice(subject) == error.DoNotRetry
  assert error.counts_as_invalid_request(subject) == True
}

pub fn oauth_body_test() {
  let body =
    "{\"error\":\"invalid_request\",\"error_description\":\"Invalid \\\"code\\\" in request.\"}"

  assert read(400, [], body)
    == error.OAuth(
      status: 400,
      error: error.InvalidRequest,
      description: Some("Invalid \"code\" in request."),
    )
}

pub fn oauth_body_without_description_test() {
  assert read(400, [], "{\"error\":\"invalid_grant\"}")
    == error.OAuth(status: 400, error: error.InvalidGrant, description: None)
}

/// A name RFC 6749 does not define still arrives as a value, and still says
/// nothing about the client's own credentials.
pub fn an_unknown_oauth_error_keeps_its_name_test() {
  let subject = read(400, [], "{\"error\":\"slow_down\"}")

  assert subject
    == error.OAuth(
      status: 400,
      error: error.UnknownOAuthError("slow_down"),
      description: None,
    )
  assert error.is_token_fatal(subject) == False
}

/// `invalid_client` and `invalid_grant` refuse the credentials, not the call,
/// so retrying with the same ones is the loop this answer exists to stop.
pub fn oauth_credential_failures_are_token_fatal_test() {
  let fatal = ["invalid_client", "invalid_grant"]
  list.each(fatal, fn(name) {
    assert error.is_token_fatal(read(400, [], "{\"error\":\"" <> name <> "\"}"))
  })

  let survivable = ["invalid_request", "unsupported_grant_type"]
  list.each(survivable, fn(name) {
    assert !error.is_token_fatal(read(400, [], "{\"error\":\"" <> name <> "\"}"))
  })
}

fn opaque_table() -> List(#(String, Int, String, String)) {
  [
    #("empty body", 502, "", "text/html"),
    #("an html gateway page", 502, "<html>502 Bad Gateway</html>", "text/html"),
    #("a bare string", 500, "something went wrong", "text/plain"),
    // Valid JSON, but none of the shapes we know.
    #("json we do not recognise", 400, "{\"detail\":\"nope\"}", ""),
    #("a json array", 400, "[1,2,3]", ""),
  ]
}

pub fn opaque_table_test() {
  list.each(opaque_table(), fn(row) {
    let #(name, status, body, content_type) = row
    let headers = case content_type {
      "" -> []
      _ -> [#("content-type", content_type)]
    }
    let expected_type = case content_type {
      "" -> None
      _ -> Some(content_type)
    }

    assert #(name, read(status, headers, body))
      == #(name, error.Opaque(status:, content_type: expected_type, body:))
  })
}

fn retry_table() -> List(#(Int, Int, error.Retry)) {
  [
    #(400, 50_035, error.DoNotRetry),
    #(403, 50_013, error.DoNotRetry),
    #(404, 10_008, error.DoNotRetry),
    #(400, 110_000, error.RetryWithBackoff),
    #(503, 130_000, error.RetryWithBackoff),
    #(400, 530_006, error.RetryWithBackoff),
    #(400, 40_004, error.RetryWithBackoff),
    #(400, 40_006, error.RetryWithBackoff),
    // A 5xx carrying a Discord body is still a 5xx.
    #(500, 0, error.RetryWithBackoff),
    // A sublimit 429 decodes as an ordinary error with no interval.
    #(429, 20_016, error.RetryWithBackoff),
  ]
}

pub fn retry_advice_table_test() {
  list.each(retry_table(), fn(row) {
    let #(status, code, expected) = row
    let body = "{\"code\":" <> int_to_string(code) <> ",\"message\":\"nope\"}"

    assert #(status, code, error.retry_advice(read(status, [], body)))
      == #(status, code, expected)
  })
}

pub fn opaque_5xx_retries_test() {
  let subject = read(502, [#("content-type", "text/html")], "<html>502</html>")

  assert error.retry_advice(subject) == error.RetryWithBackoff
  assert error.counts_as_invalid_request(subject) == False
}

/// The invalid-request budget is per IP and ends in a Cloudflare ban.
pub fn invalid_request_budget_test() {
  let denied = "{\"code\":50013,\"message\":\"Missing Permissions\"}"
  let limited = "{\"message\":\"rate limited\",\"retry_after\":1.0}"

  assert error.counts_as_invalid_request(read(403, [], denied)) == True
  assert error.counts_as_invalid_request(read(401, [], denied)) == True
  assert error.counts_as_invalid_request(read(404, [], denied)) == False
  assert error.counts_as_invalid_request(read(429, [], limited)) == True

  // Somebody else's traffic on a shared resource is not held against us.
  let shared = read(429, [#("x-ratelimit-scope", "shared")], limited)
  assert error.counts_as_invalid_request(shared) == False
}

/// The stdlib decode error names a path and never the value, so keep the body.
pub fn malformed_test() {
  let raw = "{\"id\":123}"
  let assert Error(failure) = json.parse(raw, error_decoder())
  let subject = error.Malformed(error.DecodeFailure(error: failure, raw:))

  assert error.retry_advice(subject) == error.DoNotRetry
  assert error.counts_as_invalid_request(subject) == False
  assert error.is_token_fatal(subject) == False

  let error.Malformed(error.DecodeFailure(raw: kept, ..)) = subject
  assert kept == raw
}

fn error_decoder() -> decode.Decoder(String) {
  decode.at(["id"], decode.string)
}

fn code_table() -> List(#(error.ErrorCode, Int)) {
  [
    #(error.general_error, 0),
    #(error.unknown_channel, 10_003),
    #(error.unknown_message, 10_008),
    #(error.unknown_token, 10_012),
    #(error.unknown_webhook, 10_015),
    #(error.unknown_interaction, 10_062),
    #(error.slowmode_rate_limit, 20_016),
    #(error.max_old_message_edits, 30_046),
    #(error.unauthorized, 40_001),
    #(error.messages_temporarily_disabled, 40_004),
    #(error.interaction_already_acknowledged, 40_060),
    #(error.resource_rate_limited, 40_062),
    #(error.cloudflare_blocked, 40_333),
    #(error.missing_access, 50_001),
    #(error.missing_permissions, 50_013),
    #(error.invalid_authentication_token, 50_014),
    #(error.invalid_form_body, 50_035),
    #(error.invalid_api_version, 50_041),
    #(error.invalid_json, 50_109),
    #(error.no_mutual_guilds, 50_278),
    #(error.two_factor_required, 60_003),
    #(error.reaction_blocked, 90_001),
    #(error.index_not_available, 110_000),
    #(error.api_resource_overloaded, 130_000),
    #(error.automod_blocked, 200_000),
    #(error.harmful_link_blocked, 240_000),
    #(error.unique_username_failed, 530_006),
  ]
}

pub fn code_table_test() {
  list.each(code_table(), fn(row) {
    let #(code, value) = row
    assert error.code_to_int(code) == value
    assert error.code_from_int(value) == code
  })
}

/// Discord adds error codes continuously.
pub fn unknown_code_test() {
  let body = "{\"code\":999999,\"message\":\"Brand new failure\"}"
  let assert error.Discord(code:, ..) = read(400, [], body)

  assert code == error.code_from_int(999_999)
  assert error.code_to_int(code) == 999_999
}

/// The code is optional in practice even though the docs say otherwise.
pub fn missing_code_test() {
  let assert error.Discord(code:, message:, ..) =
    read(400, [], "{\"message\":\"no code here\"}")

  assert code == error.general_error
  assert message == "no code here"
}

/// An adapter hands over whatever casing the server sent.
pub fn header_case_test() {
  let body = "{\"message\":\"rate limited\",\"retry_after\":1.0}"
  let assert error.RateLimited(limit:, ..) =
    read(429, [#("X-RateLimit-Bucket", "abc")], body)

  assert limit.bucket == Some("abc")
}

/// `describe` is the only rendering of a failure the library ships, so a host
/// logging one never has to walk the six variants itself.
pub fn describe_reads_every_variant_test() {
  let said = fn(status, headers, body) {
    error.describe(read(status, headers, body))
  }

  assert said(403, [], "{\"code\":50013,\"message\":\"Missing Permissions\"}")
    == "Discord said no (403, code 50013): Missing Permissions"

  assert said(
      429,
      [],
      "{\"message\":\"slow down\",\"retry_after\":1.5,\"global\":true}",
    )
    == "rate limited, retry in 1500ms (global)"

  assert said(
      400,
      [],
      "{\"error\":\"invalid_grant\",\"error_description\":\"bad code\"}",
    )
    == "OAuth refused: invalid_grant, bad code"

  // A Cloudflare ban page: a status and nothing readable behind it.
  assert said(429, [], "<html>go away</html>") == "unreadable 429 from Discord"

  assert error.describe(error.not_text(status: 502, headers: [], bytes: 12))
    == "a 502 from Discord of 12 bytes that were not text"
}
