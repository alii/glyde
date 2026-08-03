import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import glyde/event
import glyde/id

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
