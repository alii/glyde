import gleam/json
import gleam/list
import gleam/option.{None, Some}
import glyde/field.{Absent, Null, Present}
import glyde/id
import glyde/payload/member
import glyde/rest/body
import glyde/rest/image

/// What these tests pin is the JSON document the body carries.
fn payload_json(sent: body.Body) -> String {
  let assert body.Form(payload:, files: _) = sent
  json.to_string(json.object(payload))
}

fn edited(value: member.EditGuildMember) -> String {
  payload_json(member.edit_guild_member_body(value))
}

pub fn an_empty_member_edit_says_nothing_test() {
  assert edited(member.edit_guild_member()) == "{}"
}

/// Null is an instruction on these three: reset the nick, disconnect from
/// voice, lift the timeout.
pub fn the_three_clearing_fields_test() {
  let base = member.edit_guild_member()

  let cases = [
    #(member.EditGuildMember(..base, nick: Null), "{\"nick\":null}"),
    #(member.EditGuildMember(..base, channel_id: Null), "{\"channel_id\":null}"),
    #(
      member.EditGuildMember(..base, communication_disabled_until: Null),
      "{\"communication_disabled_until\":null}",
    ),
  ]

  list.each(cases, fn(row) {
    let #(body, expected) = row
    assert edited(body) == expected
  })
}

pub fn setting_the_same_three_fields_test() {
  let body =
    member.EditGuildMember(
      ..member.edit_guild_member(),
      nick: Present("Mod"),
      channel_id: Present(id.from_string("9")),
      communication_disabled_until: Present("2024-01-01T00:00:00.000Z"),
    )

  assert edited(body)
    == "{\"nick\":\"Mod\",\"channel_id\":\"9\","
    <> "\"communication_disabled_until\":\"2024-01-01T00:00:00.000Z\"}"
}

/// Roles is the complete set after the edit, so an empty list strips them all.
pub fn roles_replace_the_whole_set_test() {
  let base = member.edit_guild_member()

  assert edited(
      member.EditGuildMember(
        ..base,
        roles: Some([id.from_string("1"), id.from_string("2")]),
      ),
    )
    == "{\"roles\":[\"1\",\"2\"]}"

  assert edited(member.EditGuildMember(..base, roles: Some([])))
    == "{\"roles\":[]}"

  assert edited(member.EditGuildMember(..base, roles: None)) == "{}"
}

pub fn voice_state_is_two_plain_booleans_test() {
  let body =
    member.EditGuildMember(
      ..member.edit_guild_member(),
      mute: Some(True),
      deaf: Some(False),
    )

  assert edited(body) == "{\"mute\":true,\"deaf\":false}"
}

/// BYPASSES_VERIFICATION is 1 << 2, and the only member flag Discord lets an
/// edit set. Clearing it writes the whole field as 0.
pub fn the_bypass_flag_is_the_whole_flags_field_test() {
  let base = member.edit_guild_member()

  assert edited(
      member.EditGuildMember(..base, bypasses_verification: Some(True)),
    )
    == "{\"flags\":4}"

  assert edited(
      member.EditGuildMember(..base, bypasses_verification: Some(False)),
    )
    == "{\"flags\":0}"

  assert edited(member.EditGuildMember(..base, bypasses_verification: None))
    == "{}"
}

pub fn an_absent_field_is_never_written_test() {
  let body = member.EditGuildMember(..member.edit_guild_member(), nick: Absent)

  assert edited(body) == "{}"
}

pub fn an_empty_current_member_edit_says_nothing_test() {
  assert payload_json(
      member.edit_current_member_body(member.edit_current_member()),
    )
    == "{}"
}

pub fn the_current_member_can_clear_all_four_test() {
  let body =
    member.EditCurrentMember(nick: Null, avatar: Null, banner: Null, bio: Null)

  assert payload_json(member.edit_current_member_body(body))
    == "{\"nick\":null,\"avatar\":null,\"banner\":null,\"bio\":null}"
}

/// The field takes bytes, not the hash `model/member` decodes: they are the
/// same string type on the wire and opposite things. The mime comes off the
/// signature in the bytes, so these are real PNG and GIF headers.
pub fn an_avatar_is_a_data_uri_test() {
  let assert Ok(avatar) =
    image.from_bytes(<<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>)
  let assert Ok(banner) =
    image.from_bytes(<<0x47, 0x49, 0x46, 0x38, 0x39, 0x61>>)

  let body =
    member.EditCurrentMember(
      ..member.edit_current_member(),
      avatar: Present(avatar),
      banner: Present(banner),
    )

  assert payload_json(member.edit_current_member_body(body))
    == "{\"avatar\":\"data:image/png;base64,iVBORw0KGgo=\","
    <> "\"banner\":\"data:image/gif;base64,R0lGODlh\"}"
}

pub fn a_ban_can_delete_nothing_test() {
  assert payload_json(
      member.create_ban_body(member.CreateBan(delete_message_seconds: None)),
    )
    == "{}"
}

pub fn a_ban_can_sweep_a_week_of_messages_test() {
  assert payload_json(
      member.create_ban_body(
        member.CreateBan(delete_message_seconds: Some(604_800)),
      ),
    )
    == "{\"delete_message_seconds\":604800}"
}

/// The three bodies this module exists to build, each carrying no files.
pub fn every_payload_reaches_its_endpoint_test() {
  let edit =
    member.EditGuildMember(..member.edit_guild_member(), nick: Present("Mod"))
  assert member.edit_guild_member_body(edit)
    == body.json([#("nick", json.string("Mod"))])

  let current =
    member.EditCurrentMember(..member.edit_current_member(), bio: Null)
  assert member.edit_current_member_body(current)
    == body.json([#("bio", json.null())])

  let ban = member.CreateBan(delete_message_seconds: Some(60))
  assert member.create_ban_body(ban)
    == body.json([#("delete_message_seconds", json.int(60))])
}
