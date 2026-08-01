//// The Discord user object.
////
//// One record for everyone else's account: the wire sends the same object
//// with more or fewer keys, so every field that can go missing has a default.
//// A webhook author is the thinnest, carrying `id`, `username` and `avatar`.
////
//// The fields Discord gates on the `identify` scope live on `CurrentUser`,
//// which is the only place they are ever populated.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import glyde/flags.{type Flags}
import glyde/id
import glyde/wire

/// A Discord account: a person, a bot, or the stand-in for a webhook.
pub type User {
  User(
    id: id.UserId,
    /// `""` when the payload has no `username` key: an id and nothing else
    /// still decodes. `display_name` reads that empty string back as `None`.
    username: String,
    /// Always "0" now that Discord has dropped discriminators.
    discriminator: String,
    /// Display name. Null when the account has not set one.
    global_name: Option(String),
    /// A hash, not a URL. Null when the account uses a default avatar.
    avatar: Option(String),
    bot: Bool,
    /// The official Discord system account.
    system: Bool,
    banner: Option(String),
    /// Banner colour as 0xRRGGBB.
    accent_color: Option(Int),
    public_flags: Option(UserFlags),
    /// The JSON key is `avatar_decoration_data`.
    avatar_decoration: Option(AvatarDecoration),
  )
}

/// The animated frame some accounts wear around their avatar.
pub type AvatarDecoration {
  AvatarDecoration(asset: String, sku_id: id.SkuId)
}

/// The bot's own account, from `GET /users/@me` and `READY.user`. Discord
/// gates everything below `user` on the `identify` scope, so none of it is
/// sent for a message author, a mention or a reaction user.
pub type CurrentUser {
  CurrentUser(
    user: User,
    /// The account's own language, not a guild's.
    locale: Option(String),
    /// The full set, including the flags `public_flags` withholds.
    flags: Option(UserFlags),
    premium_type: Option(PremiumType),
    mfa_enabled: Bool,
    verified: Option(Bool),
    /// Needs the `email` OAuth2 scope. A bot token never has it.
    email: Option(String),
  )
}

pub type UserFlags =
  Flags(UserFlag)

pub type UserFlag {
  Staff
  Partner
  Hypesquad
  BugHunterLevel1
  HypesquadOnlineHouse1
  HypesquadOnlineHouse2
  HypesquadOnlineHouse3
  PremiumEarlySupporter
  TeamPseudoUser
  BugHunterLevel2
  VerifiedBot
  VerifiedDeveloper
  CertifiedModerator
  BotHttpInteractions
  ActiveDeveloper
}

/// Discord's user-flags table. Bits 4, 5, 11, 12, 13, 15, 20 and 21 are holes,
/// and 22 is the last named bit.
fn user_flag_bit(flag: UserFlag) -> Int {
  case flag {
    Staff -> 1
    Partner -> 2
    Hypesquad -> 4
    BugHunterLevel1 -> 8
    HypesquadOnlineHouse1 -> 64
    HypesquadOnlineHouse2 -> 128
    HypesquadOnlineHouse3 -> 256
    PremiumEarlySupporter -> 512
    TeamPseudoUser -> 1024
    BugHunterLevel2 -> 16_384
    VerifiedBot -> 65_536
    VerifiedDeveloper -> 131_072
    CertifiedModerator -> 262_144
    BotHttpInteractions -> 524_288
    ActiveDeveloper -> 4_194_304
  }
}

pub fn has_flag(bits: UserFlags, flag: UserFlag) -> Bool {
  flags.has_bit(bits, user_flag_bit(flag))
}

/// Which Nitro the account pays for.
pub type PremiumType {
  NoPremium
  NitroClassic
  Nitro
  NitroBasic
  UnknownPremiumType(Int)
}

pub fn premium_type_from_int(value: Int) -> PremiumType {
  case value {
    0 -> NoPremium
    1 -> NitroClassic
    2 -> Nitro
    3 -> NitroBasic
    other -> UnknownPremiumType(other)
  }
}

pub fn premium_type_to_int(value: PremiumType) -> Int {
  case value {
    NoPremium -> 0
    NitroClassic -> 1
    Nitro -> 2
    NitroBasic -> 3
    UnknownPremiumType(other) -> other
  }
}

pub fn premium_type_decoder() -> Decoder(PremiumType) {
  wire.integer() |> decode.map(premium_type_from_int)
}

pub fn premium_type_to_json(value: PremiumType) -> Json {
  json.int(premium_type_to_int(value))
}

/// Display name, then username. `None` for the empty username `decoder` puts
/// in when the key is absent, which is a payload of an id and nothing else.
pub fn display_name(account: User) -> Option(String) {
  case account.global_name {
    Some(name) -> Some(name)
    None ->
      case account.username {
        "" -> None
        name -> Some(name)
      }
  }
}

pub fn decoder() -> Decoder(User) {
  use id <- decode.field("id", id.decoder())
  use username <- wire.string_field("username", "")
  use discriminator <- wire.string_field("discriminator", "0")
  use global_name <- wire.opt_field("global_name", decode.string)
  use avatar <- wire.opt_field("avatar", decode.string)
  use bot <- wire.flag_field("bot", False)
  use system <- wire.flag_field("system", False)
  use banner <- wire.opt_field("banner", decode.string)
  use accent_color <- wire.opt_field("accent_color", wire.integer())
  use public_flags <- wire.opt_field("public_flags", flags.decoder())
  // Soft, not strict: both keys of the decoration object are required, and a
  // user rides along with nearly every event, so one change to it would
  // otherwise sink all of them.
  use avatar_decoration <- wire.soft_field(
    "avatar_decoration_data",
    avatar_decoration_decoder(),
  )
  decode.success(User(
    id:,
    username:,
    discriminator:,
    global_name:,
    avatar:,
    bot:,
    system:,
    banner:,
    accent_color:,
    public_flags:,
    avatar_decoration:,
  ))
}

pub fn avatar_decoration_decoder() -> Decoder(AvatarDecoration) {
  use asset <- decode.field("asset", decode.string)
  use sku_id <- decode.field("sku_id", id.decoder())
  decode.success(AvatarDecoration(asset:, sku_id:))
}

/// The user object is not nested: its keys sit beside these six.
pub fn current_user_decoder() -> Decoder(CurrentUser) {
  use user <- decode.then(decoder())
  use locale <- wire.opt_field("locale", decode.string)
  use user_flags <- wire.opt_field("flags", flags.decoder())
  use premium_type <- wire.opt_field("premium_type", premium_type_decoder())
  use mfa_enabled <- wire.flag_field("mfa_enabled", False)
  use verified <- wire.opt_field("verified", decode.bool)
  use email <- wire.opt_field("email", decode.string)
  decode.success(CurrentUser(
    user:,
    locale:,
    flags: user_flags,
    premium_type:,
    mfa_enabled:,
    verified:,
    email:,
  ))
}
