//// Bodies for the endpoints under `/guilds/{g}/roles`.

import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import glyde/field.{type Field, Absent, Null, Present}
import glyde/model/role
import glyde/permissions.{type Permissions}
import glyde/rest/body.{type Body}
import glyde/rest/image.{type ImageData}
import glyde/wire

/// Discord takes the role's colour two ways and reads only one of them, so
/// stating it twice is a body that contradicts itself. One value, one key.
pub type RoleColor {
  /// The deprecated `color` integer, and still the only colour a guild
  /// without ENHANCED_ROLE_COLORS can set.
  LegacyColor(Int)

  /// The `colors` object that supersedes it.
  Colors(role.RoleColors)
}

/// A role wears an icon or an emoji, never both. An edit setting either one
/// writes an explicit null over the other, so the body says what it wants
/// rather than leaning on Discord to clear the loser.
pub type RoleBadge {
  /// Needs the ROLE_ICONS guild feature.
  RoleIcon(ImageData)

  RoleEmoji(String)
}

/// `POST /guilds/{g}/roles`. Every field is optional and Discord supplies
/// defaults: a role created without a name is called "new role".
pub type CreateRole {
  CreateRole(
    /// Max 100 characters.
    name: Option(String),
    permissions: Option(Permissions),
    color: Option(RoleColor),
    /// Show the role's members in their own section of the member list.
    hoist: Option(Bool),
    badge: Option(RoleBadge),
    mentionable: Option(Bool),
  )
}

pub fn create_role() -> CreateRole {
  CreateRole(
    name: None,
    permissions: None,
    color: None,
    hoist: None,
    badge: None,
    mentionable: None,
  )
}

pub fn create_role_body(payload: CreateRole) -> Body {
  body.json(role_fields(
    name: payload.name,
    perms: payload.permissions,
    color: payload.color,
    hoist: payload.hoist,
    badge: create_badge_keys(payload.badge),
    mentionable: payload.mentionable,
  ))
}

/// `PATCH /guilds/{g}/roles/{r}`. Only the badge accepts null, whatever the
/// reference page says, so only it takes a `Field`.
pub type EditRole {
  EditRole(
    name: Option(String),
    permissions: Option(Permissions),
    color: Option(RoleColor),
    hoist: Option(Bool),
    /// `Null` leaves the role with no icon and no emoji.
    badge: Field(RoleBadge),
    mentionable: Option(Bool),
  )
}

pub fn edit_role() -> EditRole {
  EditRole(
    name: None,
    permissions: None,
    color: None,
    hoist: None,
    badge: Absent,
    mentionable: None,
  )
}

pub fn edit_role_body(payload: EditRole) -> Body {
  body.json(role_fields(
    name: payload.name,
    perms: payload.permissions,
    color: payload.color,
    hoist: payload.hoist,
    badge: edit_badge_keys(payload.badge),
    mentionable: payload.mentionable,
  ))
}

/// The keys a create and an edit both write, in the order Discord's reference
/// lists them. The badge keys arrive already built: the two endpoints
/// disagree about whether setting one badge nulls the other.
///
/// Labelled, because `hoist` and `mentionable` are both `Option(Bool)` and
/// swapping them at a call site would encode silently.
fn role_fields(
  name name: Option(String),
  perms perms: Option(Permissions),
  color color: Option(RoleColor),
  hoist hoist: Option(Bool),
  badge badge: List(#(String, Field(Json))),
  mentionable mentionable: Option(Bool),
) -> List(#(String, Json)) {
  wire.entries(
    list.flatten([
      [
        #("name", wire.put(wire.opt(name), json.string)),
        #("permissions", wire.put(wire.opt(perms), permissions.to_json)),
      ],
      color_keys(color),
      [#("hoist", wire.put(wire.opt(hoist), json.bool))],
      badge,
      [#("mentionable", wire.put(wire.opt(mentionable), json.bool))],
    ]),
  )
}

/// `color` and `colors`, of which exactly one is ever written. Neither takes
/// a null: Discord has no way to say "this role has no colour".
fn color_keys(value: Option(RoleColor)) -> List(#(String, Field(Json))) {
  case value {
    None -> []
    Some(LegacyColor(rgb)) -> [#("color", Present(json.int(rgb)))]
    Some(Colors(colors)) -> [
      #("colors", Present(role.role_colors_to_json(colors))),
    ]
  }
}

/// `icon` and `unicode_emoji` on a create. A new role wears nothing yet, so
/// the key that is not being set has nothing to clear and stays off the body.
fn create_badge_keys(value: Option(RoleBadge)) -> List(#(String, Field(Json))) {
  case value {
    None -> []
    Some(RoleIcon(icon)) -> [#("icon", Present(image.to_json(icon)))]
    Some(RoleEmoji(emoji)) -> [#("unicode_emoji", Present(json.string(emoji)))]
  }
}

/// `icon` and `unicode_emoji` on an edit. Setting one nulls the other: the
/// role holds one badge, and an absent key would leave the old one in place.
/// `Null` clears both, because the badge could be either of them.
fn edit_badge_keys(value: Field(RoleBadge)) -> List(#(String, Field(Json))) {
  case value {
    Absent -> []
    Null -> [#("icon", Null), #("unicode_emoji", Null)]
    Present(RoleIcon(icon)) -> [
      #("icon", Present(image.to_json(icon))),
      #("unicode_emoji", Null),
    ]
    Present(RoleEmoji(emoji)) -> [
      #("icon", Null),
      #("unicode_emoji", Present(json.string(emoji))),
    ]
  }
}
