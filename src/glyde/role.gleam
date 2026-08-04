//// Guild roles.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import glyde/field.{type Field, Absent, Null, Present}
import glyde/flags.{type Flags}
import glyde/id
import glyde/permissions.{type Permissions}

import glyde/rest/body.{type Body}
import glyde/rest/image.{type ImageData}
import glyde/wire

pub type Role {
  Role(
    /// The @everyone role carries the guild's own id.
    id: id.RoleId,
    name: String,
    /// The one colour field. Discord still sends the deprecated `color`, and
    /// the decoder reads it only to fill this in when `colors` is missing, so
    /// there is no second number here to disagree with.
    colors: RoleColors,
    /// Listed separately in the member sidebar.
    hoist: Bool,
    /// Absent without the ROLE_ICONS feature, null on a role with no icon.
    icon: Option(String),
    unicode_emoji: Option(String),
    /// Ties are broken by id.
    position: Int,
    /// Guild-wide. The `permissions` on members and channels are not.
    permissions: permissions.Permissions,
    /// Owned by an integration, so it cannot be assigned or deleted.
    managed: Bool,
    mentionable: Bool,
    /// Absent on an ordinary role.
    tags: Option(RoleTags),
    flags: RoleFlags,
  )
}

/// The three shapes Discord accepts. Anything else is a 400, so three
/// numbers that can disagree would be three ways to get one. `Gradient` and
/// `Holographic` need the ENHANCED_ROLE_COLORS feature.
pub type RoleColors {
  Solid(primary: Int)
  Gradient(primary: Int, secondary: Int)
  /// Discord accepts one holographic triple and no other, so this carries no
  /// numbers: `role_colors_to_json` writes them.
  Holographic
}

// Discord's one holographic triple, from its own role-colours reference.
const holographic_primary: Int = 11_127_295

const holographic_secondary: Int = 16_759_788

const holographic_tertiary: Int = 16_761_760

/// The three booleans are a present null for true and no key for false, so
/// they are decoded by presence and not by value.
pub type RoleTags {
  RoleTags(
    /// Set on the managed role that belongs to a bot.
    bot_id: Option(id.UserId),
    integration_id: Option(id.IntegrationId),
    subscription_listing_id: Option(id.SubscriptionListingId),
    /// The guild's booster role.
    premium_subscriber: Bool,
    available_for_purchase: Bool,
    guild_connections: Bool,
  )
}

pub type RoleFlags =
  Flags(RoleFlag)

pub type RoleFlag {
  /// The role can be picked in an onboarding prompt.
  InPrompt
}

fn role_flag_bit(flag: RoleFlag) -> Int {
  case flag {
    InPrompt -> 1
  }
}

pub fn has_flag(bits: RoleFlags, flag: RoleFlag) -> Bool {
  flags.has_bit(bits, role_flag_bit(flag))
}

// The colours are the whole answer, so this takes them rather than a `Role`:
// The body builders below builds a `RoleColors` with no `Role` around it.
pub fn is_gradient(colors: RoleColors) -> Bool {
  case colors {
    Solid(..) -> False
    Gradient(..) | Holographic -> True
  }
}

pub fn decoder() -> Decoder(Role) {
  use id <- decode.field("id", id.decoder())
  use name <- wire.string_field("name", "")
  // The deprecated `color`, read only as the fallback below. A present
  // `"colors": null` has to reach that fallback too, which is why this is an
  // Option and not a default argument.
  use deprecated_color <- wire.int_field("color", 0)
  use colors <- wire.opt_field("colors", role_colors_decoder())
  use hoist <- wire.flag_field("hoist", False)
  use icon <- wire.opt_field("icon", decode.string)
  use unicode_emoji <- wire.opt_field("unicode_emoji", decode.string)
  use position <- wire.int_field("position", 0)
  use permissions <- decode.field("permissions", permissions.decoder())
  use managed <- wire.flag_field("managed", False)
  use mentionable <- wire.flag_field("mentionable", False)
  use tags <- wire.opt_field("tags", role_tags_decoder())
  use flag_bits <- wire.int_field("flags", 0)
  decode.success(Role(
    id:,
    name:,
    colors: option.unwrap(colors, Solid(primary: deprecated_color)),
    hoist:,
    icon:,
    unicode_emoji:,
    position:,
    permissions:,
    managed:,
    mentionable:,
    tags:,
    flags: flags.from_int(flag_bits),
  ))
}

pub fn role_colors_decoder() -> Decoder(RoleColors) {
  use primary <- wire.int_field("primary_color", 0)
  use secondary <- wire.opt_field("secondary_color", wire.integer())
  use tertiary <- wire.opt_field("tertiary_color", wire.integer())
  decode.success(case secondary, tertiary {
    Some(secondary), Some(tertiary)
      if primary == holographic_primary
      && secondary == holographic_secondary
      && tertiary == holographic_tertiary
    -> Holographic
    // Discord sends no other triple, so one that is not it keeps the two
    // colours this type can hold.
    Some(secondary), _ -> Gradient(primary:, secondary:)
    // A tertiary with no secondary is not a shape Discord sends.
    None, _ -> Solid(primary:)
  })
}

pub fn role_tags_decoder() -> Decoder(RoleTags) {
  use bot_id <- wire.opt_field("bot_id", id.decoder())
  use integration_id <- wire.opt_field("integration_id", id.decoder())
  use subscription_listing_id <- wire.opt_field(
    "subscription_listing_id",
    id.decoder(),
  )
  use premium_subscriber <- wire.present_field("premium_subscriber")
  use available_for_purchase <- wire.present_field("available_for_purchase")
  use guild_connections <- wire.present_field("guild_connections")
  decode.success(RoleTags(
    bot_id:,
    integration_id:,
    subscription_listing_id:,
    premium_subscriber:,
    available_for_purchase:,
    guild_connections:,
  ))
}

/// Every key, every time: a null clears a colour, and omitting the key keeps
/// whatever the role already has.
pub fn role_colors_to_json(colors: RoleColors) -> Json {
  let #(primary, secondary, tertiary) = case colors {
    Solid(primary:) -> #(primary, None, None)
    Gradient(primary:, secondary:) -> #(primary, Some(secondary), None)
    Holographic -> #(
      holographic_primary,
      Some(holographic_secondary),
      Some(holographic_tertiary),
    )
  }
  json.object([
    #("primary_color", json.int(primary)),
    #("secondary_color", json.nullable(secondary, json.int)),
    #("tertiary_color", json.nullable(tertiary, json.int)),
  ])
}

pub fn role_tags_to_json(tags: RoleTags) -> Json {
  wire.object([
    #("bot_id", wire.opt(tags.bot_id) |> wire.put(id.to_json)),
    #("integration_id", wire.opt(tags.integration_id) |> wire.put(id.to_json)),
    #(
      "subscription_listing_id",
      wire.opt(tags.subscription_listing_id) |> wire.put(id.to_json),
    ),
    #("premium_subscriber", wire.null_flag(tags.premium_subscriber)),
    #("available_for_purchase", wire.null_flag(tags.available_for_purchase)),
    #("guild_connections", wire.null_flag(tags.guild_connections)),
  ])
}

// -- Bodies for /guilds/{g}/roles --------------------------------------------

/// Discord takes the role's colour two ways and reads only one of them, so
/// stating it twice is a body that contradicts itself. One value, one key.
pub type RoleColor {
  /// The deprecated `color` integer, and still the only colour a guild
  /// without ENHANCED_ROLE_COLORS can set.
  LegacyColor(Int)

  /// The `colors` object that supersedes it.
  Colors(RoleColors)
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
    Some(Colors(colors)) -> [#("colors", Present(role_colors_to_json(colors)))]
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
