import gleam/json
import gleam/list
import gleam/option.{None, Some}
import glyde/emoji
import glyde/id

fn parse(text: String) -> Result(emoji.Emoji, json.DecodeError) {
  json.parse(text, emoji.decoder())
}

fn parse_guild(text: String) -> Result(emoji.GuildEmoji, json.DecodeError) {
  json.parse(text, emoji.guild_emoji_decoder())
}

pub fn decodes_a_unicode_partial_test() {
  let assert Ok(fire) = parse("{\"id\":null,\"name\":\"\u{1F525}\"}")
  assert fire.kind == emoji.Unicode("\u{1F525}")
  assert fire.animated == False
}

pub fn decodes_a_custom_partial_test() {
  let assert Ok(custom) =
    parse("{\"id\":\"41771983429993937\",\"name\":\"LUL\",\"animated\":true}")
  let assert emoji.Custom(id: emoji_id, name:) = custom.kind
  assert id.to_string(emoji_id) == "41771983429993937"
  assert name == Some("LUL")
  assert custom.animated == True
}

/// The guild fields sit beside the partial's, so one payload fills both.
pub fn decodes_a_full_guild_emoji_test() {
  let assert Ok(full) =
    parse_guild(
      "{\"id\":\"41771983429993937\",\"name\":\"LUL\",\"roles\":[\"41771983429993000\",\"41771983429993001\"],\"user\":{\"id\":\"1\",\"username\":\"Luigi\"},\"require_colons\":true,\"managed\":false,\"animated\":false,\"available\":true}",
    )
  assert full.emoji.kind
    == emoji.Custom(id: id.from_string("41771983429993937"), name: Some("LUL"))
  assert list.map(full.roles, id.to_string)
    == ["41771983429993000", "41771983429993001"]
  let assert Some(uploader) = full.uploader
  assert uploader.username == "Luigi"
  assert full.require_colons == True
  assert full.managed == False
}

/// An emoji goes unavailable only when the guild loses the boosts for it.
pub fn available_defaults_to_true_test() {
  let assert Ok(absent) = parse_guild("{\"id\":\"1\",\"name\":\"a\"}")
  assert absent.available == True

  let assert Ok(lost) =
    parse_guild("{\"id\":\"1\",\"name\":\"a\",\"available\":false}")
  assert lost.available == False
}

/// MESSAGE_REACTION_REMOVE_EMOJI sends a null name for a deleted custom
/// emoji. A null name only ever comes with an id, which is why it is only
/// nullable on `Custom`.
pub fn a_null_name_decodes_test() {
  let assert Ok(gone) = parse("{\"id\":\"41771983429993937\",\"name\":null}")
  assert gone.kind
    == emoji.Custom(id: id.from_string("41771983429993937"), name: None)
}

/// Neither an id nor a name is not a shape Discord sends. Reading it as an
/// empty unicode emoji keeps the payload it rode in on.
pub fn neither_an_id_nor_a_name_reads_as_unicode_test() {
  let assert Ok(nothing) = parse("{\"id\":null,\"name\":null}")
  assert nothing.kind == emoji.Unicode("")
}

pub fn a_null_roles_array_is_empty_test() {
  let assert Ok(nulled) =
    parse_guild("{\"id\":\"1\",\"name\":\"a\",\"roles\":null}")
  assert nulled.roles == []
}

/// The five guild-only fields are not on the partial, so a button emoji
/// cannot claim to be managed or to carry an uploader.
pub fn a_partial_decode_drops_the_guild_fields_test() {
  let assert Ok(partial) =
    parse(
      "{\"id\":\"1\",\"name\":\"a\",\"roles\":[\"9\"],\"managed\":true,\"available\":false}",
    )
  assert partial == emoji.custom(id.from_string("1"), "a")
}

pub fn constructors_build_the_send_side_partial_test() {
  let fire = emoji.unicode("\u{1F525}")
  assert fire.kind == emoji.Unicode("\u{1F525}")

  let lul = emoji.custom(id.from_string("41771983429993937"), "LUL")
  assert lul.kind
    == emoji.Custom(id: id.from_string("41771983429993937"), name: Some("LUL"))
  assert lul.animated == False
}

/// A null id is how Discord tells a standard emoji from a custom one.
pub fn to_json_writes_a_null_id_for_unicode_test() {
  assert json.to_string(emoji.to_json(emoji.unicode("x")))
    == "{\"id\":null,\"name\":\"x\"}"
}

pub fn to_json_omits_animated_when_false_test() {
  let lul = emoji.custom(id.from_string("123"), "LUL")
  assert json.to_string(emoji.to_json(lul))
    == "{\"id\":\"123\",\"name\":\"LUL\"}"
  assert json.to_string(emoji.to_json(emoji.Emoji(..lul, animated: True)))
    == "{\"id\":\"123\",\"name\":\"LUL\",\"animated\":true}"
}

/// Discord reads a null name as a request to clear it.
pub fn to_json_omits_a_missing_name_test() {
  let assert Ok(gone) = parse("{\"id\":\"123\",\"name\":null}")
  assert json.to_string(emoji.to_json(gone)) == "{\"id\":\"123\"}"
}

pub fn round_trips_through_json_test() {
  let assert Ok(first) =
    parse("{\"id\":\"123\",\"name\":\"LUL\",\"animated\":true}")
  let assert Ok(second) = parse(json.to_string(emoji.to_json(first)))
  assert second == first
}
