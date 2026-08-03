import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import glyde/event
import glyde/id

fn payload(text: String) -> Dynamic {
  let assert Ok(value) = json.parse(text, decode.dynamic)
  value
}

fn decoded(name: String, text: String) -> event.Event {
  event.decode(name, payload(text))
}

/// Which of the guild lifecycle constructors a value is.
fn arrival(value: event.Event) -> String {
  case value {
    event.GuildCreateAvailable(_) -> "GuildCreateAvailable"
    event.GuildCreateUnavailable(_) -> "GuildCreateUnavailable"
    event.GuildUnavailable(_) -> "GuildUnavailable"
    event.GuildRemoved(_) -> "GuildRemoved"
    _ -> "neither"
  }
}

const a_user = "{\"id\":\"70\",\"username\":\"ada\"}"

const a_guild = "{\"id\":\"10\",\"name\":\"home\",\"owner_id\":\"70\"}"

/// GUILD_CREATE reads the value of `unavailable`: absent and false both mean
/// the guild is up.
pub fn guild_create_discriminates_on_the_value_test() {
  let rows = [
    #("{\"id\":\"10\",\"unavailable\":true}", "GuildCreateUnavailable"),
    #(
      "{\"id\":\"10\",\"owner_id\":\"70\",\"unavailable\":false}",
      "GuildCreateAvailable",
    ),
    #(a_guild, "GuildCreateAvailable"),
  ]
  list.each(rows, fn(row) {
    let #(body, expected) = row
    assert arrival(decoded("GUILD_CREATE", body)) == expected
  })

  // The stub carries the id and nothing else.
  assert decoded("GUILD_CREATE", "{\"id\":\"10\",\"unavailable\":true}")
    == event.GuildCreateUnavailable(id: id.from_string("10"))
}

/// GUILD_DELETE reads the presence of `unavailable`, the opposite rule, so
/// false is still an outage.
pub fn guild_delete_discriminates_on_key_presence_test() {
  let rows = [
    #("{\"id\":\"10\",\"unavailable\":true}", "GuildUnavailable"),
    #("{\"id\":\"10\",\"unavailable\":false}", "GuildUnavailable"),
    #("{\"id\":\"10\",\"unavailable\":null}", "GuildUnavailable"),
    #("{\"id\":\"10\"}", "GuildRemoved"),
  ]
  list.each(rows, fn(row) {
    let #(body, expected) = row
    assert arrival(decoded("GUILD_DELETE", body)) == expected
  })
}

/// Reading GUILD_DELETE's key the way GUILD_CREATE reads its value reports the
/// bot as kicked during every Discord incident.
pub fn the_two_guild_rules_disagree_on_the_same_payload_test() {
  let both = "{\"id\":\"10\",\"owner_id\":\"70\",\"unavailable\":false}"

  assert arrival(decoded("GUILD_CREATE", both)) == "GuildCreateAvailable"
  assert decoded("GUILD_DELETE", both)
    == event.GuildUnavailable(id: id.from_string("10"))
}

/// GUILD_MEMBER_UPDATE omits `deaf`, `mute` and `flags` despite the reference
/// page marking them required.
pub fn guild_member_update_is_a_partial_test() {
  let changed =
    "{\"guild_id\":\"10\",\"user\":"
    <> a_user
    <> ",\"roles\":[],\"nick\":\"new\"}"
  let assert event.GuildMemberUpdate(guild_id:, member:) =
    decoded("GUILD_MEMBER_UPDATE", changed)

  assert guild_id == id.from_string("10")
  assert member.nick == Some("new")
  assert member.deaf == None
  assert member.mute == None
  // Not `Some(0)`: a cache merging this must not clear the member's flags.
  assert member.flags == None
}

/// GUILD_EMOJIS_UPDATE is a full replacement, so an empty array is how the
/// last emoji being deleted arrives.
pub fn guild_emojis_update_replaces_the_whole_set_test() {
  let assert event.GuildEmojisUpdate(_, emojis) =
    decoded("GUILD_EMOJIS_UPDATE", "{\"guild_id\":\"10\",\"emojis\":[]}")
  assert emojis == []

  let assert event.GuildEmojisUpdate(guild_id, two) =
    decoded(
      "GUILD_EMOJIS_UPDATE",
      "{\"guild_id\":\"10\",\"emojis\":[{\"id\":\"90\",\"name\":\"a\"},{\"id\":\"91\",\"name\":\"b\"}]}",
    )
  assert guild_id == id.from_string("10")
  assert list.length(two) == 2
}

/// The emoji list replaces the guild's whole set, so an unreadable payload
/// must not reach a cache as an empty one.
pub fn guild_emojis_update_refuses_a_missing_list_test() {
  let unreadable = [
    "{\"guild_id\":\"10\"}",
    "{\"guild_id\":\"10\",\"emojis\":null}",
  ]
  list.each(unreadable, fn(body) {
    let assert event.Malformed(errors:) =
      event.dispatch("GUILD_EMOJIS_UPDATE", payload(body)).outcome
    assert errors != []
    let assert event.Raw(..) =
      event.decode("GUILD_EMOJIS_UPDATE", payload(body))
  })

  // The real "the last emoji is gone" signal is an array, and it still lands.
  assert decoded("GUILD_EMOJIS_UPDATE", "{\"guild_id\":\"10\",\"emojis\":[]}")
    == event.GuildEmojisUpdate(guild_id: id.from_string("10"), emojis: [])
}

/// `not_found` echoes back whatever the request sent, so a JSON number can
/// turn up. It stays a String, like every id in glyde.
pub fn members_chunk_not_found_survives_a_json_number_test() {
  let assert event.GuildMembersChunk(chunk) =
    decoded(
      "GUILD_MEMBERS_CHUNK",
      "{\"guild_id\":\"10\",\"members\":[],\"chunk_index\":1,\"chunk_count\":3,\"not_found\":[\"77\",41],\"nonce\":\"abc\"}",
    )

  assert chunk.not_found == ["77", "41"]
  assert chunk.chunk_index == 1
  assert chunk.chunk_count == 3
  assert chunk.nonce == Some("abc")
}

/// A real snowflake is 17 to 19 digits, past the ceiling `wire.integer` puts
/// on a whole number, so this field cannot go through that helper.
pub fn members_chunk_not_found_takes_a_full_width_number_test() {
  let assert event.GuildMembersChunk(chunk) =
    decoded(
      "GUILD_MEMBERS_CHUNK",
      "{\"guild_id\":\"10\",\"members\":[],\"chunk_index\":0,\"chunk_count\":1,\"not_found\":[123456789012345678]}",
    )

  assert chunk.not_found == ["123456789012345678"]
}

/// Discord drops a nonce over 32 bytes silently, so the chunk comes back
/// without one and the payload still has to decode.
pub fn members_chunk_without_a_nonce_decodes_test() {
  let assert event.GuildMembersChunk(chunk) =
    decoded(
      "GUILD_MEMBERS_CHUNK",
      "{\"guild_id\":\"10\",\"members\":[],\"chunk_index\":0,\"chunk_count\":1}",
    )

  assert chunk.nonce == None
  assert chunk.not_found == []
}

/// `members` is what the chunk is for. Reading a missing key as an empty list
/// loses members with nothing to say anything went wrong, and the requester
/// counts chunks to know when it is done.
pub fn members_chunk_without_members_is_malformed_test() {
  let data =
    payload("{\"guild_id\":\"10\",\"chunk_index\":0,\"chunk_count\":1}")
  let assert event.Malformed(errors:) =
    event.dispatch("GUILD_MEMBERS_CHUNK", data).outcome
  assert errors != []
}

/// `2` and `2.0` are the same count and `2.5` is not a count at all.
pub fn members_chunk_counts_take_either_number_form_test() {
  let as_floats =
    "{\"guild_id\":\"10\",\"members\":[],\"chunk_index\":0.0,\"chunk_count\":2.0}"
  let assert event.GuildMembersChunk(parts) =
    decoded("GUILD_MEMBERS_CHUNK", as_floats)
  assert parts.chunk_index == 0
  assert parts.chunk_count == 2

  let fractional =
    "{\"guild_id\":\"10\",\"members\":[],\"chunk_index\":0,\"chunk_count\":2.5}"
  let assert event.Raw(..) = decoded("GUILD_MEMBERS_CHUNK", fractional)
}
