//// Guild roles.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import glyde/flags.{type Flags}
import glyde/id
import glyde/permissions
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
// `payload/role` builds a `RoleColors` with no `Role` around it.
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
