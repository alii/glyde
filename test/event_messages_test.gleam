import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import glyde/emoji
import glyde/event
import glyde/event/messages
import glyde/id
import glyde/message

fn payload(text: String) -> Dynamic {
  let assert Ok(value) = json.parse(text, decode.dynamic)
  value
}

fn decoded(name: String, text: String) -> event.Event {
  event.decode(name, payload(text))
}

const a_user = "{\"id\":\"70\",\"username\":\"ada\"}"

const a_message = "{\"id\":\"30\",\"channel_id\":\"20\",\"author\":"
  <> a_user
  <> ",\"content\":\"hi\"}"

/// MESSAGE_UPDATE is not a Message: an embed-only edit has no author.
pub fn message_update_is_not_a_message_test() {
  let partial = "{\"id\":\"30\",\"channel_id\":\"20\",\"embeds\":[]}"

  let assert event.MessageUpdate(_) = decoded("MESSAGE_UPDATE", partial)
  let assert event.Raw(..) = decoded("MESSAGE_CREATE", partial)

  // Two names that share a payload shape still produce different events.
  assert decoded("MESSAGE_UPDATE", a_message)
    != decoded("MESSAGE_CREATE", a_message)
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

/// MESSAGE_REACTION_REMOVE lacks `member`, `message_author_id` and
/// `burst_colors`, which the add carries.
pub fn reaction_remove_is_not_a_mirror_of_reaction_add_test() {
  let body =
    "{\"user_id\":\"70\",\"channel_id\":\"20\",\"message_id\":\"30\",\"guild_id\":\"10\",\"emoji\":{\"id\":null,\"name\":\"🔥\"},\"burst\":false,\"type\":0}"

  assert decoded("MESSAGE_REACTION_REMOVE", body)
    == event.MessageReactionRemove(messages.ReactionRemove(
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
