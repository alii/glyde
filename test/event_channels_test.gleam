import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import glyde/event
import glyde/id
import glyde/model/channel

fn payload(text: String) -> Dynamic {
  let assert Ok(value) = json.parse(text, decode.dynamic)
  value
}

fn decoded(name: String, text: String) -> event.Event {
  event.decode(name, payload(text))
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

/// An unknown thread type must not take the event with it.
pub fn an_unknown_thread_type_still_decodes_test() {
  let future =
    "{\"id\":\"40\",\"guild_id\":\"10\",\"parent_id\":\"20\",\"type\":99}"
  let assert event.ThreadDelete(type_:, ..) = decoded("THREAD_DELETE", future)
  assert type_ == channel.UnknownChannelType(99)
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
