import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import glyde/event
import glyde/id
import glyde/model/voice_state

fn payload(text: String) -> Dynamic {
  let assert Ok(value) = json.parse(text, decode.dynamic)
  value
}

fn decoded(name: String, text: String) -> event.Event {
  event.decode(name, payload(text))
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
