import gleam/json
import gleam/list
import gleam/option.{None, Some}
import glyde/field.{Null, Present}
import glyde/flags
import glyde/id
import glyde/permissions
import glyde/rest/body
import glyde/rest/image
import glyde/role

fn parse(text: String) -> Result(role.Role, json.DecodeError) {
  json.parse(text, role.decoder())
}

pub fn decodes_a_role_test() {
  let assert Ok(moderator) =
    parse(
      "{\"id\":\"41771983423143936\",\"name\":\"Moderator\",\"color\":3447003,\"hoist\":true,\"icon\":null,\"unicode_emoji\":null,\"position\":2,\"permissions\":\"66321471\",\"managed\":false,\"mentionable\":true,\"flags\":0}",
    )
  assert id.to_string(moderator.id) == "41771983423143936"
  assert moderator.name == "Moderator"
  assert moderator.colors == role.Solid(3_447_003)
  assert moderator.hoist == True
  assert moderator.icon == None
  assert moderator.position == 2
  assert permissions.to_string(moderator.permissions) == "66321471"
  assert moderator.managed == False
  assert moderator.mentionable == True
  assert moderator.tags == None
  assert flags.to_int(moderator.flags) == 0
}

/// A payload with no `colors` object still has to report the role's colour,
/// which lives in the deprecated `color`.
pub fn colors_falls_back_to_the_deprecated_color_test() {
  let assert Ok(old) =
    parse("{\"id\":\"1\",\"color\":3447003,\"permissions\":\"0\"}")
  assert old.colors == role.Solid(3_447_003)
  assert role.is_gradient(old.colors) == False
}

/// A present null is not a missing key, and it has to reach the same
/// fallback: `"colors": null` used to fail the whole role.
pub fn a_null_colors_object_falls_back_too_test() {
  let assert Ok(nulled) =
    parse(
      "{\"id\":\"1\",\"color\":3447003,\"permissions\":\"0\",\"colors\":null}",
    )
  assert nulled.colors == role.Solid(3_447_003)
}

pub fn colors_wins_when_it_is_sent_test() {
  let assert Ok(gradient) =
    parse(
      "{\"id\":\"1\",\"color\":3447003,\"permissions\":\"0\",\"colors\":{\"primary_color\":11127295,\"secondary_color\":16759788,\"tertiary_color\":16761760}}",
    )
  assert gradient.colors == role.Holographic
  assert role.is_gradient(gradient.colors) == True
}

/// `Holographic` is Discord's one triple and carries no numbers, so a triple
/// that is not it decodes as the two colours the type can hold.
pub fn an_off_spec_triple_is_not_holographic_test() {
  let assert Ok(odd) =
    parse(
      "{\"id\":\"1\",\"permissions\":\"0\",\"colors\":{\"primary_color\":1,\"secondary_color\":2,\"tertiary_color\":3}}",
    )
  assert odd.colors == role.Gradient(primary: 1, secondary: 2)
}

/// A secondary with no tertiary is a two-stop gradient, not a holograph.
pub fn a_two_stop_gradient_decodes_test() {
  let assert Ok(two) =
    parse(
      "{\"id\":\"1\",\"permissions\":\"0\",\"colors\":{\"primary_color\":1,\"secondary_color\":2}}",
    )
  assert two.colors == role.Gradient(primary: 1, secondary: 2)
  assert role.is_gradient(two.colors) == True
}

pub fn a_plain_colors_object_is_not_a_gradient_test() {
  let assert Ok(flat) =
    parse(
      "{\"id\":\"1\",\"permissions\":\"0\",\"colors\":{\"primary_color\":16711680,\"secondary_color\":null,\"tertiary_color\":null}}",
    )
  assert flat.colors == role.Solid(primary: 16_711_680)
  assert role.is_gradient(flat.colors) == False
}

/// A role is worth nothing without its permissions.
pub fn permissions_are_required_test() {
  let assert Error(_) = parse("{\"id\":\"1\",\"name\":\"x\"}")
  let assert Error(_) = parse("{\"id\":\"1\",\"permissions\":null}")
  let assert Error(_) = parse("{\"id\":\"1\",\"permissions\":66321471}")
}

pub fn requires_an_id_test() {
  let assert Error(_) = parse("{\"name\":\"x\",\"permissions\":\"0\"}")
}

/// Discord omits `flags` on older role payloads.
pub fn flags_default_to_zero_test() {
  let assert Ok(plain) = parse("{\"id\":\"1\",\"permissions\":\"0\"}")
  assert flags.to_int(plain.flags) == 0
  assert role.has_flag(plain.flags, role.InPrompt) == False

  let assert Ok(prompted) =
    parse("{\"id\":\"1\",\"permissions\":\"0\",\"flags\":1}")
  assert role.has_flag(prompted.flags, role.InPrompt) == True
}

pub fn unknown_flag_bits_survive_test() {
  let assert Ok(future) =
    parse("{\"id\":\"1\",\"permissions\":\"0\",\"flags\":9}")
  assert flags.to_int(future.flags) == 9
  assert role.has_flag(future.flags, role.InPrompt) == True
}

/// Discord sends the key with a null value to mean true and omits it to mean
/// false.
pub fn role_tags_read_a_present_null_as_true_test() {
  let assert Ok(booster) =
    parse(
      "{\"id\":\"1\",\"permissions\":\"0\",\"tags\":{\"premium_subscriber\":null}}",
    )
  let assert Some(tags) = booster.tags
  assert tags.premium_subscriber == True
  assert tags.available_for_purchase == False
  assert tags.guild_connections == False
}

pub fn role_tags_read_an_absent_key_as_false_test() {
  let assert Ok(ordinary) =
    parse("{\"id\":\"1\",\"permissions\":\"0\",\"tags\":{}}")
  let assert Some(tags) = ordinary.tags
  assert tags.premium_subscriber == False
  assert tags.available_for_purchase == False
  assert tags.guild_connections == False
  assert tags.bot_id == None
}

/// Presence is the signal, not the value.
pub fn role_tags_read_any_value_as_true_test() {
  let assert Ok(odd) =
    parse(
      "{\"id\":\"1\",\"permissions\":\"0\",\"tags\":{\"guild_connections\":false}}",
    )
  let assert Some(tags) = odd.tags
  assert tags.guild_connections == True
}

pub fn role_tags_carry_their_ids_test() {
  let assert Ok(managed) =
    parse(
      "{\"id\":\"1\",\"permissions\":\"0\",\"managed\":true,\"tags\":{\"bot_id\":\"80351110224678912\",\"integration_id\":\"41771983423143937\",\"subscription_listing_id\":\"1088658128371765299\",\"available_for_purchase\":null}}",
    )
  let assert Some(tags) = managed.tags
  assert option.map(tags.bot_id, id.to_string) == Some("80351110224678912")
  assert option.map(tags.integration_id, id.to_string)
    == Some("41771983423143937")
  assert option.map(tags.subscription_listing_id, id.to_string)
    == Some("1088658128371765299")
  assert tags.available_for_purchase == True
  assert tags.premium_subscriber == False
}

/// True is a present null, false is no key at all.
pub fn role_tags_to_json_writes_a_null_for_true_test() {
  let booster =
    role.RoleTags(
      bot_id: None,
      integration_id: None,
      subscription_listing_id: None,
      premium_subscriber: True,
      available_for_purchase: False,
      guild_connections: False,
    )
  assert json.to_string(role.role_tags_to_json(booster))
    == "{\"premium_subscriber\":null}"
}

pub fn role_tags_to_json_omits_every_false_test() {
  let nothing =
    role.RoleTags(
      bot_id: None,
      integration_id: None,
      subscription_listing_id: None,
      premium_subscriber: False,
      available_for_purchase: False,
      guild_connections: False,
    )
  assert json.to_string(role.role_tags_to_json(nothing)) == "{}"
}

pub fn role_tags_to_json_writes_the_ids_it_has_test() {
  let managed =
    role.RoleTags(
      bot_id: Some(id.from_string("80351110224678912")),
      integration_id: None,
      subscription_listing_id: None,
      premium_subscriber: False,
      available_for_purchase: True,
      guild_connections: True,
    )
  assert json.to_string(role.role_tags_to_json(managed))
    == "{\"bot_id\":\"80351110224678912\",\"available_for_purchase\":null,\"guild_connections\":null}"
}

pub fn role_tags_round_trip_test() {
  let cases = [
    #(True, False, False),
    #(False, True, False),
    #(False, False, True),
    #(True, True, True),
    #(False, False, False),
  ]
  list.each(cases, fn(row) {
    let #(premium, purchase, connections) = row
    let tags =
      role.RoleTags(
        bot_id: None,
        integration_id: None,
        subscription_listing_id: None,
        premium_subscriber: premium,
        available_for_purchase: purchase,
        guild_connections: connections,
      )
    let text =
      "{\"id\":\"1\",\"permissions\":\"0\",\"tags\":"
      <> json.to_string(role.role_tags_to_json(tags))
      <> "}"
    let assert Ok(decoded) = parse(text)
    assert decoded.tags == Some(tags)
  })
}

/// A null means no secondary colour; omitting the key means keep it.
pub fn role_colors_to_json_writes_every_key_test() {
  assert json.to_string(role.role_colors_to_json(role.Solid(16_711_680)))
    == "{\"primary_color\":16711680,\"secondary_color\":null,\"tertiary_color\":null}"

  assert json.to_string(role.role_colors_to_json(role.Gradient(1, 2)))
    == "{\"primary_color\":1,\"secondary_color\":2,\"tertiary_color\":null}"

  assert json.to_string(role.role_colors_to_json(role.Holographic))
    == "{\"primary_color\":11127295,\"secondary_color\":16759788,\"tertiary_color\":16761760}"
}

/// `Holographic` carries no numbers, so the encoder writes the triple and the
/// decoder recognises it. This is what stops those two drifting apart.
pub fn holographic_round_trips_test() {
  let text =
    "{\"id\":\"1\",\"permissions\":\"0\",\"colors\":"
    <> json.to_string(role.role_colors_to_json(role.Holographic))
    <> "}"
  let assert Ok(decoded) = parse(text)
  assert decoded.colors == role.Holographic
}

/// The @everyone role carries the guild's own id.
pub fn the_everyone_role_shares_the_guild_id_test() {
  let assert Ok(everyone) =
    parse(
      "{\"id\":\"41771983423143937\",\"name\":\"@everyone\",\"permissions\":\"104324673\",\"position\":0}",
    )
  let guild: id.GuildId = id.from_string("41771983423143937")
  assert id.to_string(everyone.id) == id.to_string(guild)
}

pub fn icon_tolerates_absent_and_null_test() {
  let cases = [
    "{\"id\":\"1\",\"permissions\":\"0\"}",
    "{\"id\":\"1\",\"permissions\":\"0\",\"icon\":null}",
  ]
  list.each(cases, fn(text) {
    let assert Ok(plain) = parse(text)
    assert plain.icon == None
    assert plain.unicode_emoji == None
  })

  let assert Ok(decorated) =
    parse(
      "{\"id\":\"1\",\"permissions\":\"0\",\"icon\":\"ffff\",\"unicode_emoji\":\"\u{1F525}\"}",
    )
  assert decorated.icon == Some("ffff")
  assert decorated.unicode_emoji == Some("\u{1F525}")
}

pub fn a_whole_position_written_as_a_float_decodes_test() {
  let assert Ok(second) =
    parse("{\"id\":\"1\",\"permissions\":\"0\",\"position\":2.0}")
  assert second.position == 2
}

/// The eight-byte PNG signature, which is what `image.from_bytes` reads the
/// mime off.
fn png() -> image.ImageData {
  let assert Ok(data) =
    image.from_bytes(<<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>)
  data
}

/// What these tests pin is the JSON document the body carries.
fn payload_json(sent: body.Body) -> String {
  let assert body.Form(payload:, files: _) = sent
  json.to_string(json.object(payload))
}

fn created(value: role.CreateRole) -> String {
  payload_json(role.create_role_body(value))
}

fn edited(value: role.EditRole) -> String {
  payload_json(role.edit_role_body(value))
}

/// Discord fills in its own defaults, so an empty body is legal.
pub fn an_empty_create_is_an_empty_object_test() {
  assert created(role.create_role()) == "{}"
}

pub fn a_create_writes_only_what_was_set_test() {
  let body =
    role.CreateRole(
      ..role.create_role(),
      name: Some("Moderator"),
      hoist: Some(True),
      mentionable: Some(False),
    )

  assert created(body)
    == "{\"name\":\"Moderator\",\"hoist\":true,\"mentionable\":false}"
}

pub fn role_permissions_go_out_as_a_decimal_string_test() {
  let body =
    role.CreateRole(
      ..role.create_role(),
      permissions: Some(
        permissions.new([
          permissions.KickMembers,
          permissions.BanMembers,
        ]),
      ),
    )

  assert created(body) == "{\"permissions\":\"6\"}"
}

pub fn a_gradient_role_carries_its_colours_test() {
  let body =
    role.CreateRole(
      ..role.create_role(),
      color: Some(role.Colors(role.Gradient(primary: 1, secondary: 2))),
    )

  assert created(body)
    == "{\"colors\":{\"primary_color\":1,\"secondary_color\":2,"
    <> "\"tertiary_color\":null}}"
}

/// The deprecated `color` and the `colors` object are two ways to say the
/// same thing, so the type only lets a body say it once.
pub fn a_colour_is_stated_once_test() {
  assert created(
      role.CreateRole(
        ..role.create_role(),
        color: Some(role.LegacyColor(3_447_003)),
      ),
    )
    == "{\"color\":3447003}"

  assert created(
      role.CreateRole(
        ..role.create_role(),
        color: Some(role.Colors(role.Solid(primary: 3_447_003))),
      ),
    )
    == "{\"colors\":{\"primary_color\":3447003,\"secondary_color\":null,"
    <> "\"tertiary_color\":null}}"
}

pub fn an_empty_edit_is_an_empty_object_test() {
  assert edited(role.edit_role()) == "{}"
}

/// A null name or a null permissions is a 400, so only the badge takes a
/// `Field` and the illegal call does not typecheck. Clearing it means
/// clearing whichever of the two keys the role was wearing.
pub fn only_the_badge_can_be_cleared_test() {
  assert edited(role.EditRole(..role.edit_role(), badge: Null))
    == "{\"icon\":null,\"unicode_emoji\":null}"
}

/// A role wears one badge, so setting either key nulls the other rather than
/// leaving whatever the role was already wearing.
pub fn an_edit_can_set_the_emoji_test() {
  let body =
    role.EditRole(..role.edit_role(), badge: Present(role.RoleEmoji("🛡")))

  assert edited(body) == "{\"icon\":null,\"unicode_emoji\":\"🛡\"}"

  let icon =
    role.EditRole(..role.edit_role(), badge: Present(role.RoleIcon(png())))

  assert edited(icon)
    == "{\"icon\":\"data:image/png;base64,iVBORw0KGgo=\","
    <> "\"unicode_emoji\":null}"
}

/// A new role wears nothing, so there is no sibling key to clear.
pub fn a_create_writes_only_the_badge_it_sets_test() {
  assert created(
      role.CreateRole(..role.create_role(), badge: Some(role.RoleEmoji("🛡"))),
    )
    == "{\"unicode_emoji\":\"🛡\"}"

  assert created(
      role.CreateRole(..role.create_role(), badge: Some(role.RoleIcon(png()))),
    )
    == "{\"icon\":\"data:image/png;base64,iVBORw0KGgo=\"}"
}

pub fn an_edit_renames_without_touching_anything_else_test() {
  let body = role.EditRole(..role.edit_role(), name: Some("Helper"))

  assert edited(body) == "{\"name\":\"Helper\"}"
}
