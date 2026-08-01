import gleam/json
import gleam/list
import gleam/option.{None, Some}
import glyde/gateway/frame
import glyde/gateway/ready
import glyde/id
import glyde/internal/url

fn host(text: String) -> url.Host {
  let assert Ok(host) = url.host_of(text)
  host
}

/// A READY captured from live Discord, with only `_trace` trimmed. Ten of
/// these keys are undocumented.
fn captured_ready() -> String {
  json.to_string(
    json.object([
      #("v", json.int(10)),
      #("user_settings", json.object([])),
      #(
        "user",
        json.object([
          #("verified", json.bool(True)),
          #("username", json.string("Joe Armstrong")),
          #("primary_guild", json.null()),
          #("mfa_enabled", json.bool(False)),
          #("id", json.string("1529362398568517793")),
          #("global_name", json.null()),
          #("flags", json.int(0)),
          #("email", json.null()),
          #("discriminator", json.string("6927")),
          #("clan", json.null()),
          #("bot", json.bool(True)),
          #("avatar", json.null()),
        ]),
      ),
      #("session_type", json.string("normal")),
      #("session_id", json.string("9d1c7b6a5e4f3021")),
      #(
        "resume_gateway_url",
        json.string("wss://gateway-us-east1-b.discord.gg"),
      ),
      #("relationships", json.preprocessed_array([])),
      #("private_channels", json.preprocessed_array([])),
      #("presences", json.preprocessed_array([])),
      #(
        "guilds",
        json.preprocessed_array([
          json.object([
            #("unavailable", json.bool(True)),
            #("id", json.string("1529362272861032448")),
          ]),
        ]),
      ),
      #("guild_join_requests", json.preprocessed_array([])),
      #(
        "geo_ordered_rtc_regions",
        json.preprocessed_array([
          json.string("london"),
          json.string("rotterdam"),
        ]),
      ),
      #("game_relationships", json.preprocessed_array([])),
      #("auth", json.object([])),
      #(
        "application",
        json.object([
          #("id", json.string("1529362398568517793")),
          #("flags_new", json.string("0")),
          #("flags", json.int(0)),
        ]),
      ),
      #(
        "_trace",
        json.preprocessed_array([
          json.string(
            "[\"gateway-prd-arm-us-east1-b-s2q2\",{\"micros\":115219}]",
          ),
        ]),
      ),
    ]),
  )
}

/// Through `frame.parse`, because `d` is the `Dynamic` no literal can be
/// written for.
fn ready_of(body: String) -> Result(ready.ReadyPayload, ready.ReadyRejected) {
  let assert frame.Dispatch(data:, ..) =
    frame.parse("{\"t\":\"READY\",\"s\":1,\"op\":0,\"d\":" <> body <> "}")
  ready.read(data)
}

pub fn ready_decodes_a_captured_payload_test() {
  assert ready_of(captured_ready())
    == Ok(ready.ReadyPayload(
      session_id: "9d1c7b6a5e4f3021",
      resume_host: Some(host("gateway-us-east1-b.discord.gg")),
      user: id.from_string("1529362398568517793"),
      guild_count: 1,
    ))
}

/// READY is the only carrier of `session_id` and `resume_gateway_url`, and
/// losing it costs one IDENTIFY out of 1000 a day.
pub fn ready_needs_only_three_fields_test() {
  assert ready_of(
      "{\"session_id\":\"abc\",\"resume_gateway_url\":\"wss://h.discord.gg\","
      <> "\"user\":{\"id\":\"7\"}}",
    )
    == Ok(ready.ReadyPayload(
      session_id: "abc",
      resume_host: Some(host("h.discord.gg")),
      user: id.from_string("7"),
      guild_count: 0,
    ))
}

/// A guild count is worth less than the session it would take down with it.
pub fn ready_survives_an_unreadable_guild_list_test() {
  let table = ["\"guilds\":[],", "\"guilds\":\"lots\",", "\"guilds\":null,", ""]
  list.each(table, fn(guilds) {
    let body =
      "{"
      <> guilds
      <> "\"session_id\":\"abc\",\"resume_gateway_url\":\"wss://h.discord.gg\","
      <> "\"user\":{\"id\":\"7\"}}"
    let assert Ok(payload) = ready_of(body)
    assert payload.guild_count == 0
  })
}

/// A resume host is a hint about which node to come back to. Losing it costs
/// nothing; rejecting the READY over it would cost the session and an
/// IDENTIFY out of the 1000 a day.
pub fn a_resume_url_with_no_host_still_reads_test() {
  let table = ["wss://", "", "/nowhere", "wss://wss://h.discord.gg"]
  list.each(table, fn(resume_url) {
    let assert Ok(payload) =
      ready_of(
        "{\"session_id\":\"abc\",\"resume_gateway_url\":\""
        <> resume_url
        <> "\",\"user\":{\"id\":\"7\"}}",
      )
    assert payload.resume_host == None
    assert payload.session_id == "abc"
  })
}

/// Which fields were missing decides what the shard says about it, so the
/// reason is a value rather than a sentence.
pub fn ready_failures_test() {
  let table = [
    #("{}", ready.MissingReadyFields),
    #(
      "{\"resume_gateway_url\":\"wss://h.discord.gg\",\"user\":{\"id\":\"7\"}}",
      ready.MissingReadyFields,
    ),
    #(
      "{\"session_id\":\"abc\",\"user\":{\"id\":\"7\"}}",
      ready.MissingReadyFields,
    ),
    #(
      "{\"session_id\":\"abc\",\"resume_gateway_url\":\"wss://h.discord.gg\"}",
      ready.MissingReadyFields,
    ),
    #(
      "{\"session_id\":\"abc\",\"resume_gateway_url\":\"wss://h.discord.gg\","
        <> "\"user\":{}}",
      ready.MissingReadyFields,
    ),
    // A snowflake is a String on the wire, and a JSON number is not one.
    #(
      "{\"session_id\":\"abc\",\"resume_gateway_url\":\"wss://h.discord.gg\","
        <> "\"user\":{\"id\":1529362398568517793}}",
      ready.MissingReadyFields,
    ),
  ]
  list.each(table, fn(row) {
    let #(body, expected) = row
    assert ready_of(body) == Error(expected)
  })
}

/// `session_id` is an opaque string, not a snowflake.
pub fn session_id_is_not_a_snowflake_test() {
  let assert Ok(payload) =
    ready_of(
      "{\"session_id\":\"0f6a-NOT_A_NUMBER\","
      <> "\"resume_gateway_url\":\"wss://h.discord.gg\",\"user\":{\"id\":\"7\"}}",
    )
  assert payload.session_id == "0f6a-NOT_A_NUMBER"
}
