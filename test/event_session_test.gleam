import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import glyde/event
import glyde/event/session
import glyde/flags
import glyde/gateway
import glyde/id

fn payload(text: String) -> Dynamic {
  let assert Ok(value) = json.parse(text, decode.dynamic)
  value
}

fn decoded(name: String, text: String) -> event.Event {
  event.decode(name, payload(text))
}

/// READY carries around a dozen undocumented keys.
pub fn ready_reads_past_the_undocumented_keys_test() {
  let live =
    "{\"v\":10,\"user\":{\"id\":\"70\",\"username\":\"ada\",\"mfa_enabled\":true},\"guilds\":[{\"id\":\"10\",\"unavailable\":true},{\"id\":\"11\",\"unavailable\":true}],\"session_id\":\"abc\",\"resume_gateway_url\":\"wss://x.discord.gg\",\"shard\":[0,2],\"application\":{\"id\":\"90\",\"flags\":8},\"_trace\":[\"gw\"],\"session_type\":\"normal\",\"geo_ordered_rtc_regions\":[\"us-east\"],\"relationships\":[],\"presences\":[],\"private_channels\":[]}"
  let assert event.ReadyEvent(ready) = decoded("READY", live)

  assert ready.version == 10
  assert ready.session_id == "abc"
  assert ready.resume_gateway_url == "wss://x.discord.gg"
  assert ready.guilds == [id.from_string("10"), id.from_string("11")]
  let assert Ok(first_of_two) = gateway.sharding(index: 0, count: 2)
  assert ready.shard == Some(first_of_two)
  assert ready.me.user.id == id.from_string("70")
  assert ready.me.mfa_enabled

  let assert Some(application) = ready.application
  assert application.id == id.from_string("90")
  assert flags.to_int(application.flags) == 8
}

/// An unsharded bot gets no `shard`, and `application` goes missing. Failing
/// on either would hand the host `event.Raw` and take its own user and guild
/// list with it, for two fields the connection does not read.
pub fn ready_is_lenient_where_it_can_afford_to_be_test() {
  let sparse =
    "{\"user\":{\"id\":\"70\"},\"session_id\":\"abc\",\"resume_gateway_url\":\"wss://x.discord.gg\",\"application\":\"nope\"}"
  let assert event.ReadyEvent(ready) = decoded("READY", sparse)

  assert ready.shard == None
  assert ready.application == None
  assert ready.guilds == []
  // Anything but 10 means the URL lost its `?v=`, so absent reports 0.
  assert ready.version == 0
}

/// A 0 here reads as "no privileged intents enabled", which is a claim an
/// application object that never sent `flags` does not support. Failing the
/// object leaves `application: None`, which says nothing.
pub fn ready_refuses_an_application_without_flags_test() {
  let no_flags =
    "{\"user\":{\"id\":\"70\"},\"session_id\":\"abc\",\"resume_gateway_url\":\"wss://x.discord.gg\",\"application\":{\"id\":\"90\"}}"
  let assert event.ReadyEvent(ready) = decoded("READY", no_flags)
  assert ready.application == None
}

/// Taking the first two of a wrong-length shard array assigns the wrong shard,
/// which shows up as missing events rather than as a failure.
pub fn ready_refuses_a_shard_array_of_the_wrong_length_test() {
  let odd =
    "{\"user\":{\"id\":\"70\"},\"session_id\":\"abc\",\"resume_gateway_url\":\"wss://x.discord.gg\",\"shard\":[0,3,9]}"
  let assert event.ReadyEvent(ready) = decoded("READY", odd)
  assert ready.shard == None
}

/// `index` is 0-based, so shard 2 of 2 is a fleet the gateway closes with
/// 4010. Reporting no shard beats reporting one that cannot exist.
pub fn ready_refuses_a_shard_out_of_its_fleet_test() {
  let outside =
    "{\"user\":{\"id\":\"70\"},\"session_id\":\"abc\",\"resume_gateway_url\":\"wss://x.discord.gg\",\"shard\":[2,2]}"
  let assert event.ReadyEvent(ready) = decoded("READY", outside)
  assert ready.shard == None
}

/// The one thing this decoder cannot paper over. The handshake reads the same
/// two fields separately, so the connection is still resumable.
pub fn ready_needs_a_session_test() {
  let data = payload("{\"v\":10,\"user\":{\"id\":\"70\"}}")
  let assert event.Malformed(errors:) = event.dispatch("READY", data).outcome
  assert errors != []
  let assert event.Raw(..) = event.decode("READY", data)
}

/// RESUMED's `d` is a routing breadcrumb the event does not carry.
pub fn resumed_ignores_its_payload_test() {
  assert decoded("RESUMED", "{\"_trace\":[\"anything\"]}") == event.ResumedEvent
  assert decoded("RESUMED", "{}") == event.ResumedEvent
}

/// `retry_after` is documented as a float and sent as a bare int when whole.
pub fn rate_limited_accepts_a_bare_int_and_a_float_test() {
  let rows = [
    #(
      "{\"opcode\":8,\"retry_after\":30,\"meta\":{\"guild_id\":\"10\"}}",
      30_000,
    ),
    #(
      "{\"opcode\":8,\"retry_after\":30.0,\"meta\":{\"guild_id\":\"10\"}}",
      30_000,
    ),
    #("{\"opcode\":8,\"retry_after\":2.5,\"meta\":{\"guild_id\":\"10\"}}", 2500),
    #("{\"opcode\":8,\"retry_after\":0,\"meta\":{\"guild_id\":\"10\"}}", 0),
  ]
  list.each(rows, fn(row) {
    let #(body, expected_ms) = row
    let assert event.RateLimitedEvent(limited) = decoded("RATE_LIMITED", body)
    assert session.retry_after_ms(limited) == expected_ms
  })
}

/// Opcode 8 is the only meta shape Discord documents, and its nonce is what
/// correlates the limit back to a REQUEST_GUILD_MEMBERS.
pub fn rate_limited_reads_the_member_request_meta_test() {
  let assert event.RateLimitedEvent(limited) =
    decoded(
      "RATE_LIMITED",
      "{\"opcode\":8,\"retry_after\":30,\"meta\":{\"guild_id\":\"10\",\"nonce\":\"abc\"}}",
    )

  assert limited.opcode == 8
  assert limited.meta
    == Some(session.MemberRequestMeta(
      guild_id: id.from_string("10"),
      nonce: Some("abc"),
    ))
}

/// A meta shape this build has no name for decodes as `None` rather than
/// failing the event.
pub fn rate_limited_tolerates_an_unmodelled_meta_test() {
  let other =
    "{\"opcode\":31,\"retry_after\":1,\"meta\":{\"guild_ids\":[\"10\"]}}"
  let assert event.RateLimitedEvent(limited) = decoded("RATE_LIMITED", other)
  assert limited.opcode == 31
  assert limited.meta == None

  // Opcode 8 with no guild_id is not a member request meta either.
  let assert event.RateLimitedEvent(headless) =
    decoded("RATE_LIMITED", "{\"opcode\":8,\"retry_after\":1}")
  assert headless.opcode == 8
  assert headless.meta == None
}

/// A host arms a timer with this, so it never comes back negative.
pub fn retry_after_ms_never_goes_below_zero_test() {
  let rows = [
    #(-30.0, 0),
    #(-2.5, 0),
    #(-0.001, 0),
    #(0.0, 0),
    // Halves round away from zero.
    #(0.0005, 1),
    #(2.5, 2500),
    #(30.0, 30_000),
  ]
  list.each(rows, fn(row) {
    let #(seconds, expected) = row
    let limited =
      session.RateLimited(opcode: 8, retry_after: seconds, meta: None)
    assert session.retry_after_ms(limited) == expected
  })
}

/// `retry_after` goes straight into a timer, so an absurd delay is capped.
pub fn retry_after_ms_clamps_an_absurd_delay_test() {
  let rows = [#(1.0e20, 9_007_199_254_740_991), #(30.0, 30_000)]
  list.each(rows, fn(row) {
    let #(seconds, expected) = row
    let limited =
      session.RateLimited(opcode: 8, retry_after: seconds, meta: None)
    assert session.retry_after_ms(limited) == expected
  })
}
