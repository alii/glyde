import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import glyde/event
import glyde/flags
import glyde/gateway
import glyde/id
import glyde/model/channel
import glyde/model/emoji
import glyde/model/message
import glyde/model/voice_state

fn payload(text: String) -> Dynamic {
  let assert Ok(value) = json.parse(text, decode.dynamic)
  value
}

fn decoded(name: String, text: String) -> event.Event {
  event.decode(name, payload(text))
}

/// The constructor an event was built with.
fn tag(value: event.Event) -> String {
  case value {
    event.ReadyEvent(_) -> "ReadyEvent"
    event.ResumedEvent -> "ResumedEvent"
    event.RateLimitedEvent(_) -> "RateLimitedEvent"
    event.GuildCreateAvailable(_) -> "GuildCreateAvailable"
    event.GuildCreateUnavailable(_) -> "GuildCreateUnavailable"
    event.GuildUpdate(_) -> "GuildUpdate"
    event.GuildUnavailable(_) -> "GuildUnavailable"
    event.GuildRemoved(_) -> "GuildRemoved"
    event.GuildMemberAdd(..) -> "GuildMemberAdd"
    event.GuildMemberRemove(..) -> "GuildMemberRemove"
    event.GuildMemberUpdate(..) -> "GuildMemberUpdate"
    event.GuildMembersChunk(_) -> "GuildMembersChunk"
    event.GuildRoleCreate(..) -> "GuildRoleCreate"
    event.GuildRoleUpdate(..) -> "GuildRoleUpdate"
    event.GuildRoleDelete(..) -> "GuildRoleDelete"
    event.GuildBanAdd(..) -> "GuildBanAdd"
    event.GuildBanRemove(..) -> "GuildBanRemove"
    event.GuildEmojisUpdate(..) -> "GuildEmojisUpdate"
    event.ChannelCreate(_) -> "ChannelCreate"
    event.ChannelUpdate(_) -> "ChannelUpdate"
    event.ChannelDelete(_) -> "ChannelDelete"
    event.ChannelPinsUpdate(..) -> "ChannelPinsUpdate"
    event.ThreadCreate(_) -> "ThreadCreate"
    event.ThreadUpdate(_) -> "ThreadUpdate"
    event.ThreadDelete(..) -> "ThreadDelete"
    event.MessageCreate(_) -> "MessageCreate"
    event.MessageUpdate(_) -> "MessageUpdate"
    event.MessageDelete(..) -> "MessageDelete"
    event.MessageDeleteBulk(..) -> "MessageDeleteBulk"
    event.MessageReactionAdd(_) -> "MessageReactionAdd"
    event.MessageReactionRemove(_) -> "MessageReactionRemove"
    event.MessageReactionRemoveAll(..) -> "MessageReactionRemoveAll"
    event.MessageReactionRemoveEmoji(..) -> "MessageReactionRemoveEmoji"
    event.InteractionCreate(_) -> "InteractionCreate"
    event.TypingStartEvent(_) -> "TypingStartEvent"
    event.UserUpdate(_) -> "UserUpdate"
    event.VoiceStateUpdate(_) -> "VoiceStateUpdate"
    event.VoiceServerUpdate(..) -> "VoiceServerUpdate"
    event.Raw(..) -> "Raw"
  }
}

const a_user = "{\"id\":\"70\",\"username\":\"ada\"}"

const a_role = "{\"id\":\"80\",\"name\":\"mod\",\"permissions\":\"8\"}"

const a_channel = "{\"id\":\"20\",\"type\":0,\"name\":\"general\"}"

const a_message = "{\"id\":\"30\",\"channel_id\":\"20\",\"author\":"
  <> a_user
  <> ",\"content\":\"hi\"}"

const a_guild = "{\"id\":\"10\",\"name\":\"home\",\"owner_id\":\"70\"}"

/// One row per wire name. Every public `Event` constructor except `Raw`
/// appears in the `tag` column.
fn dispatch_table() -> List(#(String, String, String)) {
  [
    #(
      "READY",
      "ReadyEvent",
      "{\"v\":10,\"user\":"
        <> a_user
        <> ",\"guilds\":[],\"session_id\":\"abc\",\"resume_gateway_url\":\"wss://x.discord.gg\"}",
    ),
    #("RESUMED", "ResumedEvent", "{\"_trace\":[\"gateway\"]}"),
    #(
      "RATE_LIMITED",
      "RateLimitedEvent",
      "{\"opcode\":8,\"retry_after\":30,\"meta\":{\"guild_id\":\"10\"}}",
    ),
    #("GUILD_CREATE", "GuildCreateAvailable", a_guild),
    #(
      "GUILD_CREATE",
      "GuildCreateUnavailable",
      "{\"id\":\"10\",\"unavailable\":true}",
    ),
    #("GUILD_UPDATE", "GuildUpdate", a_guild),
    #(
      "GUILD_DELETE",
      "GuildUnavailable",
      "{\"id\":\"10\",\"unavailable\":true}",
    ),
    #("GUILD_DELETE", "GuildRemoved", "{\"id\":\"10\"}"),
    #(
      "GUILD_MEMBER_ADD",
      "GuildMemberAdd",
      "{\"guild_id\":\"10\",\"user\":"
        <> a_user
        <> ",\"roles\":[],\"joined_at\":\"2024-01-01T00:00:00+00:00\",\"deaf\":false,\"mute\":false}",
    ),
    #(
      "GUILD_MEMBER_REMOVE",
      "GuildMemberRemove",
      "{\"guild_id\":\"10\",\"user\":" <> a_user <> "}",
    ),
    #(
      "GUILD_MEMBER_UPDATE",
      "GuildMemberUpdate",
      "{\"guild_id\":\"10\",\"user\":" <> a_user <> ",\"roles\":[\"80\"]}",
    ),
    #(
      "GUILD_MEMBERS_CHUNK",
      "GuildMembersChunk",
      "{\"guild_id\":\"10\",\"members\":[],\"chunk_index\":0,\"chunk_count\":1}",
    ),
    #(
      "GUILD_ROLE_CREATE",
      "GuildRoleCreate",
      "{\"guild_id\":\"10\",\"role\":" <> a_role <> "}",
    ),
    #(
      "GUILD_ROLE_UPDATE",
      "GuildRoleUpdate",
      "{\"guild_id\":\"10\",\"role\":" <> a_role <> "}",
    ),
    #(
      "GUILD_ROLE_DELETE",
      "GuildRoleDelete",
      "{\"guild_id\":\"10\",\"role_id\":\"80\"}",
    ),
    #(
      "GUILD_BAN_ADD",
      "GuildBanAdd",
      "{\"guild_id\":\"10\",\"user\":" <> a_user <> "}",
    ),
    #(
      "GUILD_BAN_REMOVE",
      "GuildBanRemove",
      "{\"guild_id\":\"10\",\"user\":" <> a_user <> "}",
    ),
    #(
      "GUILD_EMOJIS_UPDATE",
      "GuildEmojisUpdate",
      "{\"guild_id\":\"10\",\"emojis\":[{\"id\":\"90\",\"name\":\"blob\"}]}",
    ),
    #("CHANNEL_CREATE", "ChannelCreate", a_channel),
    #("CHANNEL_UPDATE", "ChannelUpdate", a_channel),
    #("CHANNEL_DELETE", "ChannelDelete", a_channel),
    #(
      "CHANNEL_PINS_UPDATE",
      "ChannelPinsUpdate",
      "{\"guild_id\":\"10\",\"channel_id\":\"20\",\"last_pin_timestamp\":\"2024-01-01T00:00:00+00:00\"}",
    ),
    #(
      "THREAD_CREATE",
      "ThreadCreate",
      "{\"id\":\"21\",\"type\":11,\"newly_created\":true}",
    ),
    #("THREAD_UPDATE", "ThreadUpdate", "{\"id\":\"21\",\"type\":11}"),
    #(
      "THREAD_DELETE",
      "ThreadDelete",
      "{\"id\":\"21\",\"guild_id\":\"10\",\"parent_id\":\"20\",\"type\":11}",
    ),
    #("MESSAGE_CREATE", "MessageCreate", a_message),
    #(
      "MESSAGE_UPDATE",
      "MessageUpdate",
      "{\"id\":\"30\",\"channel_id\":\"20\",\"embeds\":[]}",
    ),
    #(
      "MESSAGE_DELETE",
      "MessageDelete",
      "{\"id\":\"30\",\"channel_id\":\"20\",\"guild_id\":\"10\"}",
    ),
    #(
      "MESSAGE_DELETE_BULK",
      "MessageDeleteBulk",
      "{\"ids\":[\"30\",\"31\"],\"channel_id\":\"20\",\"guild_id\":\"10\"}",
    ),
    #(
      "MESSAGE_REACTION_ADD",
      "MessageReactionAdd",
      "{\"user_id\":\"70\",\"channel_id\":\"20\",\"message_id\":\"30\",\"emoji\":{\"id\":null,\"name\":\"🔥\"}}",
    ),
    #(
      "MESSAGE_REACTION_REMOVE",
      "MessageReactionRemove",
      "{\"user_id\":\"70\",\"channel_id\":\"20\",\"message_id\":\"30\",\"emoji\":{\"id\":null,\"name\":\"🔥\"}}",
    ),
    #(
      "MESSAGE_REACTION_REMOVE_ALL",
      "MessageReactionRemoveAll",
      "{\"channel_id\":\"20\",\"message_id\":\"30\"}",
    ),
    #(
      "MESSAGE_REACTION_REMOVE_EMOJI",
      "MessageReactionRemoveEmoji",
      "{\"channel_id\":\"20\",\"message_id\":\"30\",\"emoji\":{\"id\":null,\"name\":\"🔥\"}}",
    ),
    #(
      "INTERACTION_CREATE",
      "InteractionCreate",
      "{\"id\":\"40\",\"application_id\":\"50\",\"type\":2,\"token\":\"t\",\"version\":1}",
    ),
    #(
      "TYPING_START",
      "TypingStartEvent",
      "{\"channel_id\":\"20\",\"user_id\":\"70\",\"timestamp\":1700000000}",
    ),
    #("USER_UPDATE", "UserUpdate", a_user),
    #(
      "VOICE_STATE_UPDATE",
      "VoiceStateUpdate",
      "{\"guild_id\":\"10\",\"channel_id\":\"20\",\"user_id\":\"70\",\"session_id\":\"s\"}",
    ),
    #(
      "VOICE_SERVER_UPDATE",
      "VoiceServerUpdate",
      "{\"token\":\"tok\",\"guild_id\":\"10\",\"endpoint\":\"a.discord.media:443\"}",
    ),
  ]
}

/// Every modelled name reaches its own variant, and `name` maps it back.
pub fn every_dispatch_reaches_its_own_variant_test() {
  list.each(dispatch_table(), fn(row) {
    let #(wire_name, expected, body) = row
    let value = decoded(wire_name, body)
    assert tag(value) == expected
    assert event.name(value) == wire_name
    assert event.is_modelled(wire_name)
  })
}

/// The two tables have to agree, or an event reports the wrong name.
pub fn name_round_trips_for_every_modelled_dispatch_test() {
  list.each(dispatch_table(), fn(row) {
    let #(wire_name, _, body) = row
    assert event.is_modelled(event.name(decoded(wire_name, body)))
  })
}

/// A name glyde does not model is not an error, and `d` survives it intact.
pub fn an_unmodelled_name_keeps_its_payload_test() {
  let body = "{\"a\":1}"
  let value = decoded("SOME_FUTURE_EVENT", body)
  assert value == event.Raw("SOME_FUTURE_EVENT", payload(body))
  assert event.name(value) == "SOME_FUTURE_EVENT"
  assert event.is_modelled("SOME_FUTURE_EVENT") == False

  let assert event.Raw(_, data) = value
  assert decode.run(data, decode.at(["a"], decode.int)) == Ok(1)
}

/// A modelled name with a bad payload is a bug report; an unmodelled name is
/// not.
pub fn a_modelled_name_with_a_bad_payload_reports_errors_test() {
  let body = "{\"channel_id\":\"20\"}"
  let result = event.dispatch("MESSAGE_CREATE", payload(body))

  let assert event.Malformed(errors:) = result.outcome
  assert errors != []
  assert result.data == payload(body)
  assert event.decode("MESSAGE_CREATE", payload(body))
    == event.Raw("MESSAGE_CREATE", payload(body))
  assert event.is_modelled(result.name)
}

/// A caller tells drift from ignorance without a second lookup.
pub fn an_unmodelled_name_reports_no_errors_test() {
  let result = event.dispatch("SOME_FUTURE_EVENT", payload("{}"))
  assert result.outcome == event.Unmodelled
  assert event.is_modelled(result.name) == False
}

/// The raw `d` travels with every dispatch, decoded or not, so a field glyde
/// leaves out of a model is one `decode.at` away.
pub fn the_raw_payload_travels_with_a_decoded_event_test() {
  let body =
    "{\"channel_id\":\"20\",\"user_id\":\"70\",\"timestamp\":5,\"undocumented\":\"keep me\"}"
  let result = event.dispatch("TYPING_START", payload(body))

  assert tag(event.decode("TYPING_START", payload(body))) == "TypingStartEvent"
  assert decode.run(result.data, decode.at(["undocumented"], decode.string))
    == Ok("keep me")
}

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
    assert tag(decoded("GUILD_CREATE", body)) == expected
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
    assert tag(decoded("GUILD_DELETE", body)) == expected
  })
}

/// MESSAGE_UPDATE is not a Message: an embed-only edit has no author.
pub fn message_update_is_not_a_message_test() {
  let partial = "{\"id\":\"30\",\"channel_id\":\"20\",\"embeds\":[]}"

  assert tag(decoded("MESSAGE_UPDATE", partial)) == "MessageUpdate"
  assert tag(decoded("MESSAGE_CREATE", partial)) == "Raw"

  // Two names that share a payload shape still produce different events.
  assert decoded("MESSAGE_UPDATE", a_message)
    != decoded("MESSAGE_CREATE", a_message)
}

/// MESSAGE_REACTION_REMOVE lacks `member`, `message_author_id` and
/// `burst_colors`, which the add carries.
pub fn reaction_remove_is_not_a_mirror_of_reaction_add_test() {
  let body =
    "{\"user_id\":\"70\",\"channel_id\":\"20\",\"message_id\":\"30\",\"guild_id\":\"10\",\"emoji\":{\"id\":null,\"name\":\"🔥\"},\"burst\":false,\"type\":0}"

  assert decoded("MESSAGE_REACTION_REMOVE", body)
    == event.MessageReactionRemove(event.ReactionRemove(
      user_id: id.from_string("70"),
      channel_id: id.from_string("20"),
      message_id: id.from_string("30"),
      guild_id: Some(id.from_string("10")),
      emoji: emoji.unicode("🔥"),
      burst: False,
      type_: message.NormalReaction,
    ))
}

/// None of the add's three extra fields is required: a DM reaction has no
/// `member`.
pub fn reaction_add_carries_its_three_extra_fields_test() {
  let full =
    "{\"user_id\":\"70\",\"channel_id\":\"20\",\"message_id\":\"30\",\"guild_id\":\"10\",\"member\":{\"nick\":\"a\"},\"emoji\":{\"id\":null,\"name\":\"🔥\"},\"message_author_id\":\"71\",\"burst\":true,\"burst_colors\":[\"#ff0000\"],\"type\":1}"
  let assert event.MessageReactionAdd(added) =
    decoded("MESSAGE_REACTION_ADD", full)

  assert added.message_author_id == Some(id.from_string("71"))
  assert added.burst
  assert added.burst_colors == ["#ff0000"]
  assert added.type_ == message.BurstReaction
  assert option.is_some(added.member)

  let bare =
    "{\"user_id\":\"70\",\"channel_id\":\"20\",\"message_id\":\"30\",\"emoji\":{\"id\":null,\"name\":\"🔥\"}}"
  let assert event.MessageReactionAdd(dm) =
    decoded("MESSAGE_REACTION_ADD", bare)

  assert dm.member == None
  assert dm.message_author_id == None
  assert dm.guild_id == None
  assert dm.burst == False
  assert dm.burst_colors == []
  // Absent `type` is a normal reaction, not a decode failure.
  assert dm.type_ == message.NormalReaction
}

/// A `type` glyde cannot read is a burst reaction it would otherwise report
/// as a normal one, so it fails the decode rather than defaulting.
pub fn a_reaction_type_that_is_not_a_number_is_malformed_test() {
  let body =
    "{\"user_id\":\"70\",\"channel_id\":\"20\",\"message_id\":\"30\",\"emoji\":{\"name\":\"x\"},\"type\":\"burst\"}"
  let assert event.Malformed(errors:) =
    event.dispatch("MESSAGE_REACTION_ADD", payload(body)).outcome
  assert errors != []
}

/// An unknown reaction type round trips rather than sinking the event.
pub fn an_unknown_reaction_type_round_trips_test() {
  let body =
    "{\"user_id\":\"70\",\"channel_id\":\"20\",\"message_id\":\"30\",\"emoji\":{\"name\":\"x\"},\"type\":7}"
  let assert event.MessageReactionAdd(added) =
    decoded("MESSAGE_REACTION_ADD", body)

  assert added.type_ == message.UnknownReactionType(7)
  assert message.reaction_type_to_int(added.type_) == 7

  let types = [
    message.NormalReaction,
    message.BurstReaction,
    message.UnknownReactionType(7),
  ]
  list.each(types, fn(value) {
    assert message.reaction_type_from_int(message.reaction_type_to_int(value))
      == value
  })
}

/// THREAD_DELETE is four keys. The channel decoder would take it and a handler
/// reading `name` would get nothing.
pub fn thread_delete_is_a_four_key_payload_test() {
  assert decoded(
      "THREAD_DELETE",
      "{\"id\":\"21\",\"guild_id\":\"10\",\"parent_id\":\"20\",\"type\":11}",
    )
    == event.ThreadDelete(
      id: id.from_string("21"),
      guild_id: id.from_string("10"),
      parent_id: Some(id.from_string("20")),
      type_: channel.PublicThread,
    )
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

/// A null endpoint means the voice server went away: disconnect and wait.
pub fn voice_server_update_survives_a_null_endpoint_test() {
  assert decoded(
      "VOICE_SERVER_UPDATE",
      "{\"token\":\"tok\",\"guild_id\":\"10\",\"endpoint\":null}",
    )
    == event.VoiceServerUpdate(
      token: "tok",
      guild_id: id.from_string("10"),
      endpoint: None,
    )
}

/// The other half of the null: `None` means the voice server went away and the
/// host disconnects, so an absent key must not decode to it.
pub fn voice_server_update_without_an_endpoint_key_is_malformed_test() {
  let data = payload("{\"token\":\"tok\",\"guild_id\":\"10\"}")
  let assert event.Malformed(errors:) =
    event.dispatch("VOICE_SERVER_UPDATE", data).outcome
  assert errors != []
}

/// MESSAGE_DELETE_BULK is guild-only and carries a list of ids.
pub fn message_delete_bulk_carries_a_list_test() {
  assert decoded(
      "MESSAGE_DELETE_BULK",
      "{\"ids\":[\"30\",\"31\"],\"channel_id\":\"20\",\"guild_id\":\"10\"}",
    )
    == event.MessageDeleteBulk(
      ids: [id.from_string("30"), id.from_string("31")],
      channel_id: id.from_string("20"),
      guild_id: Some(id.from_string("10")),
    )
}

/// A DM message delete has no `guild_id` at all.
pub fn message_delete_in_a_dm_has_no_guild_test() {
  assert decoded("MESSAGE_DELETE", "{\"id\":\"30\",\"channel_id\":\"20\"}")
    == event.MessageDelete(
      id: id.from_string("30"),
      channel_id: id.from_string("20"),
      guild_id: None,
    )
}

/// `last_pin_timestamp` is null once the last pin goes, and absent in a DM
/// along with `guild_id`.
pub fn channel_pins_update_tolerates_a_missing_pin_test() {
  assert decoded("CHANNEL_PINS_UPDATE", "{\"channel_id\":\"20\"}")
    == event.ChannelPinsUpdate(
      guild_id: None,
      channel_id: id.from_string("20"),
      last_pin_timestamp: None,
    )

  assert decoded(
      "CHANNEL_PINS_UPDATE",
      "{\"channel_id\":\"20\",\"last_pin_timestamp\":null}",
    )
    == event.ChannelPinsUpdate(
      guild_id: None,
      channel_id: id.from_string("20"),
      last_pin_timestamp: None,
    )
}

/// TYPING_START's timestamp is UNIX SECONDS, the only one in the dispatch
/// surface that is not ISO-8601.
pub fn typing_start_timestamp_is_unix_seconds_test() {
  let assert event.TypingStartEvent(typing) =
    decoded(
      "TYPING_START",
      "{\"channel_id\":\"20\",\"guild_id\":\"10\",\"user_id\":\"70\",\"timestamp\":1700000000,\"member\":{\"nick\":\"ada\"}}",
    )

  assert typing.timestamp == 1_700_000_000
  assert typing.channel_id == id.from_string("20")
  assert typing.guild_id == Some(id.from_string("10"))
  assert option.is_some(typing.member)
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
    assert event.retry_after_ms(limited) == expected_ms
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
    == event.MemberRequestMeta(
      guild_id: id.from_string("10"),
      nonce: Some("abc"),
    )
}

/// An unreadable meta keeps the raw object rather than being guessed at.
pub fn rate_limited_keeps_an_unreadable_meta_raw_test() {
  let other =
    "{\"opcode\":31,\"retry_after\":1,\"meta\":{\"guild_ids\":[\"10\"]}}"
  let assert event.RateLimitedEvent(limited) = decoded("RATE_LIMITED", other)
  let assert event.UnknownMeta(opcode, raw) = limited.meta

  assert opcode == 31
  assert decode.run(raw, decode.at(["guild_ids"], decode.list(decode.string)))
    == Ok(["10"])

  // Opcode 8 with no guild_id is not a member request meta either.
  let assert event.RateLimitedEvent(headless) =
    decoded("RATE_LIMITED", "{\"opcode\":8,\"retry_after\":1}")
  let assert event.UnknownMeta(eight, _) = headless.meta
  assert eight == 8
}

/// RESUMED's `d` is a routing breadcrumb the event does not carry.
pub fn resumed_ignores_its_payload_test() {
  assert decoded("RESUMED", "{\"_trace\":[\"anything\"]}") == event.ResumedEvent
  assert decoded("RESUMED", "{}") == event.ResumedEvent
}

/// Without the check a `d` of `"nope"` reaches a caller as a guild.
pub fn a_payload_that_is_not_an_object_is_malformed_test() {
  let names = ["READY", "GUILD_UPDATE", "INTERACTION_CREATE"]
  list.each(names, fn(wire_name) {
    let assert event.Malformed(errors:) =
      event.dispatch(wire_name, payload("\"nope\"")).outcome
    assert errors != []
    assert tag(event.decode(wire_name, payload("\"nope\""))) == "Raw"
  })
}

/// `decode` is `dispatch` with the outcome flattened.
pub fn decode_and_dispatch_agree_test() {
  list.each(dispatch_table(), fn(row) {
    let #(wire_name, _, body) = row
    let data = payload(body)
    let assert event.Decoded(decoded) = event.dispatch(wire_name, data).outcome
    assert event.decode(wire_name, data) == decoded
  })
}

/// READY carries around a dozen undocumented keys.
pub fn ready_reads_past_the_undocumented_keys_test() {
  let live =
    "{\"v\":10,\"user\":{\"id\":\"70\",\"username\":\"ada\",\"mfa_enabled\":true},\"guilds\":[{\"id\":\"10\",\"unavailable\":true},{\"id\":\"11\",\"unavailable\":true}],\"session_id\":\"abc\",\"resume_gateway_url\":\"wss://x.discord.gg\",\"shard\":[0,2],\"application\":{\"id\":\"90\",\"flags\":8},\"_trace\":[\"gw\"],\"session_type\":\"normal\",\"geo_ordered_rtc_regions\":[\"us-east\"],\"relationships\":[],\"presences\":[],\"private_channels\":[]}"
  let assert event.ReadyEvent(session) = decoded("READY", live)

  assert session.version == 10
  assert session.session_id == "abc"
  assert session.resume_gateway_url == "wss://x.discord.gg"
  assert session.guilds == [id.from_string("10"), id.from_string("11")]
  let assert Ok(first_of_two) = gateway.sharding(index: 0, count: 2)
  assert session.shard == Some(first_of_two)
  assert session.me.user.id == id.from_string("70")
  assert session.me.mfa_enabled

  let assert Some(application) = session.application
  assert application.id == id.from_string("90")
  assert flags.to_int(application.flags) == 8
}

/// An unsharded bot gets no `shard`, and `application` goes missing. Failing
/// on either would hand the host `event.Raw` and take its own user and guild
/// list with it, for two fields the connection does not read.
pub fn ready_is_lenient_where_it_can_afford_to_be_test() {
  let sparse =
    "{\"user\":{\"id\":\"70\"},\"session_id\":\"abc\",\"resume_gateway_url\":\"wss://x.discord.gg\",\"application\":\"nope\"}"
  let assert event.ReadyEvent(session) = decoded("READY", sparse)

  assert session.shard == None
  assert session.application == None
  assert session.guilds == []
  // Anything but 10 means the URL lost its `?v=`, so absent reports 0.
  assert session.version == 0
}

/// A 0 here reads as "no privileged intents enabled", which is a claim an
/// application object that never sent `flags` does not support. Failing the
/// object leaves `application: None`, which says nothing.
pub fn ready_refuses_an_application_without_flags_test() {
  let no_flags =
    "{\"user\":{\"id\":\"70\"},\"session_id\":\"abc\",\"resume_gateway_url\":\"wss://x.discord.gg\",\"application\":{\"id\":\"90\"}}"
  let assert event.ReadyEvent(session) = decoded("READY", no_flags)
  assert session.application == None
}

/// Taking the first two of a wrong-length shard array assigns the wrong shard,
/// which shows up as missing events rather than as a failure.
pub fn ready_refuses_a_shard_array_of_the_wrong_length_test() {
  let odd =
    "{\"user\":{\"id\":\"70\"},\"session_id\":\"abc\",\"resume_gateway_url\":\"wss://x.discord.gg\",\"shard\":[0,3,9]}"
  let assert event.ReadyEvent(session) = decoded("READY", odd)
  assert session.shard == None
}

/// `index` is 0-based, so shard 2 of 2 is a fleet the gateway closes with
/// 4010. Reporting no shard beats reporting one that cannot exist.
pub fn ready_refuses_a_shard_out_of_its_fleet_test() {
  let outside =
    "{\"user\":{\"id\":\"70\"},\"session_id\":\"abc\",\"resume_gateway_url\":\"wss://x.discord.gg\",\"shard\":[2,2]}"
  let assert event.ReadyEvent(session) = decoded("READY", outside)
  assert session.shard == None
}

/// The one thing this decoder cannot paper over. The handshake reads the same
/// two fields separately, so the connection is still resumable.
pub fn ready_needs_a_session_test() {
  let data = payload("{\"v\":10,\"user\":{\"id\":\"70\"}}")
  let assert event.Malformed(errors:) = event.dispatch("READY", data).outcome
  assert errors != []
  assert tag(event.decode("READY", data)) == "Raw"
}

/// A null `channel_id` is how a user leaving voice is signalled; there is no
/// separate event.
pub fn a_voice_leave_is_a_null_channel_test() {
  let left = "{\"user_id\":\"70\",\"channel_id\":null,\"session_id\":\"vs\"}"
  let assert event.VoiceStateUpdate(state) = decoded("VOICE_STATE_UPDATE", left)

  assert state.channel_id == None
  assert voice_state.has_left(state)
  assert state.user_id == id.from_string("70")
}

/// `channel_id` is required and nullable: the null IS the leave. An absent key
/// read as `None` would report a leave from a payload that never said so.
pub fn a_voice_state_without_a_channel_key_is_malformed_test() {
  let data = payload("{\"user_id\":\"70\",\"session_id\":\"vs\"}")
  let assert event.Malformed(errors:) =
    event.dispatch("VOICE_STATE_UPDATE", data).outcome
  assert errors != []
}

/// The session id is handed to a voice stack verbatim, so a missing one is a
/// payload glyde cannot use, not an empty string it can forge.
pub fn a_voice_state_without_a_session_is_malformed_test() {
  let bodies = [
    "{\"user_id\":\"70\",\"channel_id\":\"20\"}",
    "{\"user_id\":\"70\",\"channel_id\":\"20\",\"session_id\":null}",
  ]
  list.each(bodies, fn(body) {
    let assert event.Malformed(errors:) =
      event.dispatch("VOICE_STATE_UPDATE", payload(body)).outcome
    assert errors != []
  })
}

/// The flags Discord omits are false, which is most of them.
pub fn a_voice_join_carries_the_member_test() {
  let joined =
    "{\"guild_id\":\"10\",\"channel_id\":\"20\",\"user_id\":\"70\",\"session_id\":\"vs\",\"self_mute\":true,\"member\":{\"roles\":[\"80\"]}}"
  let assert event.VoiceStateUpdate(state) =
    decoded("VOICE_STATE_UPDATE", joined)

  assert state.guild_id == Some(id.from_string("10"))
  assert voice_state.has_left(state) == False
  assert state.self_mute
  assert state.mute == False
  assert state.suppress == False
  assert option.is_some(state.member)
}

/// An unknown thread type must not take the event with it.
pub fn an_unknown_thread_type_still_decodes_test() {
  let future =
    "{\"id\":\"40\",\"guild_id\":\"10\",\"parent_id\":\"20\",\"type\":99}"
  let assert event.ThreadDelete(type_:, ..) = decoded("THREAD_DELETE", future)
  assert type_ == channel.UnknownChannelType(99)
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
  assert tag(decoded("GUILD_MEMBERS_CHUNK", fractional)) == "Raw"
}

/// Reading GUILD_DELETE's key the way GUILD_CREATE reads its value reports the
/// bot as kicked during every Discord incident.
pub fn the_two_guild_rules_disagree_on_the_same_payload_test() {
  let both = "{\"id\":\"10\",\"owner_id\":\"70\",\"unavailable\":false}"

  assert tag(decoded("GUILD_CREATE", both)) == "GuildCreateAvailable"
  assert decoded("GUILD_DELETE", both)
    == event.GuildUnavailable(id: id.from_string("10"))
}

/// A sample of the untyped dispatches. Each reaches the hatch, and `t` is
/// UPPER_SNAKE_CASE and nothing else.
pub fn the_untyped_dispatches_reach_the_hatch_test() {
  let untyped = [
    "PRESENCE_UPDATE", "THREAD_LIST_SYNC", "THREAD_MEMBERS_UPDATE",
    "GUILD_STICKERS_UPDATE", "GUILD_AUDIT_LOG_ENTRY_CREATE",
    "AUTO_MODERATION_ACTION_EXECUTION", "ENTITLEMENT_CREATE",
    "SUBSCRIPTION_UPDATE", "MESSAGE_POLL_VOTE_ADD", "SOUNDBOARD_SOUNDS",
    "CHANNEL_INFO", "VOICE_CHANNEL_STATUS_UPDATE", "WEBHOOKS_UPDATE",
    "APPLICATION_COMMAND_PERMISSIONS_UPDATE",
  ]
  list.each(untyped, fn(wire_name) {
    assert event.is_modelled(wire_name) == False
    assert tag(decoded(wire_name, "{}")) == "Raw"
    assert event.name(decoded(wire_name, "{}")) == wire_name
  })

  assert event.is_modelled("message_create") == False
  assert event.is_modelled("MESSAGE_CREATE ") == False
  assert event.is_modelled("") == False
}

/// `name` is total, so a host can log by name without a fallback branch.
pub fn name_is_total_over_the_hatch_test() {
  assert event.name(event.Raw("ANYTHING", dynamic.nil())) == "ANYTHING"
  assert event.name(event.GuildRemoved(id: id.from_string("10")))
    == "GUILD_DELETE"
  assert event.name(event.GuildCreateUnavailable(id: id.from_string("10")))
    == "GUILD_CREATE"
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
    assert tag(event.decode("GUILD_EMOJIS_UPDATE", payload(body))) == "Raw"
  })

  // The real "the last emoji is gone" signal is an array, and it still lands.
  assert decoded("GUILD_EMOJIS_UPDATE", "{\"guild_id\":\"10\",\"emojis\":[]}")
    == event.GuildEmojisUpdate(guild_id: id.from_string("10"), emojis: [])
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
      event.RateLimited(
        opcode: 8,
        retry_after: seconds,
        meta: event.UnknownMeta(opcode: 8, raw: dynamic.nil()),
      )
    assert event.retry_after_ms(limited) == expected
  })
}

/// `retry_after` goes straight into a timer, so an absurd delay is capped.
pub fn retry_after_ms_clamps_an_absurd_delay_test() {
  let rows = [#(1.0e20, 9_007_199_254_740_991), #(30.0, 30_000)]
  list.each(rows, fn(row) {
    let #(seconds, expected) = row
    let limited =
      event.RateLimited(
        opcode: 8,
        retry_after: seconds,
        meta: event.UnknownMeta(opcode: 8, raw: dynamic.nil()),
      )
    assert event.retry_after_ms(limited) == expected
  })
}
