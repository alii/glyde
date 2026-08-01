import gleam/json
import gleam/option.{Some}
import glyde/field.{Null, Present}
import glyde/model/role as model
import glyde/payload/role
import glyde/permissions
import glyde/rest/body
import glyde/rest/image

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
      color: Some(role.Colors(model.Gradient(primary: 1, secondary: 2))),
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
        color: Some(role.Colors(model.Solid(primary: 3_447_003))),
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
