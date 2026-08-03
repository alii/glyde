import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/option.{Some}
import glyde/event
import glyde/id

fn payload(text: String) -> Dynamic {
  let assert Ok(value) = json.parse(text, decode.dynamic)
  value
}

fn decoded(name: String, text: String) -> event.Event {
  event.decode(name, payload(text))
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
