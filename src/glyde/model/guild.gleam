//// Guilds, called servers everywhere except the API. One record covers
//// `GET /guilds/{id}`, GUILD_CREATE and GUILD_UPDATE.
////
//// The GUILD_CREATE-only block is one `Option`, never seven. `None` is REST,
//// where the question does not apply; a `GatewayCreate` holding empty lists
//// is a gateway create with nothing visible. A cache that conflates them
//// wipes itself.
////
//// GUILD_CREATE and GUILD_DELETE read `unavailable` by opposite rules.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import glyde/flags.{type Flags}
import glyde/id
import glyde/model/channel
import glyde/model/emoji
import glyde/model/member
import glyde/model/role
import glyde/model/user
import glyde/model/voice_state
import glyde/permissions
import glyde/wire

pub type Guild {
  Guild(
    id: id.GuildId,
    name: String,
    icon: Option(String),
    /// Templates only.
    icon_hash: Option(String),
    splash: Option(String),
    /// Only guilds with the DISCOVERABLE feature have one.
    discovery_splash: Option(String),
    owner_id: id.UserId,
    afk_channel_id: Option(id.ChannelId),
    /// SECONDS.
    afk_timeout: Int,
    widget_enabled: Option(Bool),
    widget_channel_id: Option(id.ChannelId),
    verification_level: VerificationLevel,
    default_message_notifications: MessageNotificationLevel,
    explicit_content_filter: ExplicitContentFilterLevel,
    roles: List(role.Role),
    /// GUILD_EMOJIS_UPDATE sends a full replacement array, never a delta.
    emojis: List(emoji.GuildEmoji),
    /// An open set of strings, so not an enum. Use `has_feature(g.features,
    /// …)`.
    features: List(String),
    mfa_level: MfaLevel,
    /// Set when a bot created the guild.
    application_id: Option(id.ApplicationId),
    system_channel_id: Option(id.ChannelId),
    system_channel_flags: SystemChannelFlags,
    rules_channel_id: Option(id.ChannelId),
    /// Null for everything but the largest guilds.
    max_presences: Option(Int),
    max_members: Option(Int),
    vanity_url_code: Option(String),
    description: Option(String),
    banner: Option(String),
    premium_tier: PremiumTier,
    premium_subscription_count: Option(Int),
    preferred_locale: String,
    public_updates_channel_id: Option(id.ChannelId),
    max_video_channel_users: Option(Int),
    max_stage_video_channel_users: Option(Int),
    /// Only when the request asked for `with_counts`, which answers with both
    /// or neither.
    counts: Option(ApproximateCounts),
    nsfw_level: GuildNsfwLevel,
    premium_progress_bar_enabled: Bool,
    safety_alerts_channel_id: Option(id.ChannelId),
    /// Everything GUILD_CREATE adds, all of it or none of it. `None` on a
    /// REST guild and on GUILD_UPDATE.
    gateway_create: Option(GatewayCreate),
  )
}

/// Both counts or neither: `with_counts=true` answers with the pair, and no
/// request produces one without the other.
pub type ApproximateCounts {
  ApproximateCounts(members: Int, presences: Int)
}

/// The block only GUILD_CREATE sends. It arrives together, so the fields are
/// plain: there is no guild that knows its member count and not its channels.
pub type GatewayCreate {
  GatewayCreate(
    /// ISO-8601, when the bot joined.
    joined_at: String,
    large: Bool,
    member_count: Int,
    /// Partial: these voice states carry no `guild_id`.
    voice_states: List(voice_state.VoiceState),
    /// Without the GUILD_MEMBERS intent, only the bot and the users in voice.
    /// Truncated regardless above 75 000 members.
    members: List(member.GuildMember),
    channels: List(channel.Channel),
    /// Active threads the bot can see, not every thread.
    threads: List(channel.Channel),
  )
}

/// GUILD_CREATE's payload is one of these. During an outage all Discord sends
/// is the id.
pub type MaybeAvailableGuild {
  AvailableGuild(Guild)
  OfflineGuild(id.GuildId)
}

/// `GET /users/@me/guilds`, which answers with far less than a guild: no
/// `owner_id`, so `decoder()` rejects it. `owner` and `permissions` are
/// relative to the requesting user and come from nowhere else.
pub type UserGuild {
  UserGuild(
    id: id.GuildId,
    name: String,
    icon: Option(String),
    banner: Option(String),
    owner: Bool,
    /// Guild-wide: no channel overwrites folded in.
    permissions: Option(permissions.Permissions),
    /// An open set of strings, so not an enum.
    features: List(String),
    /// Only when the request asked for `with_counts`, which answers with both
    /// or neither.
    counts: Option(ApproximateCounts),
  )
}

pub type Ban {
  Ban(reason: Option(String), user: user.User)
}

pub type VerificationLevel {
  NoVerification
  LowVerification
  MediumVerification
  HighVerification
  VeryHighVerification
  UnknownVerificationLevel(Int)
}

pub type MessageNotificationLevel {
  AllMessages
  OnlyMentions
  UnknownMessageNotificationLevel(Int)
}

pub type ExplicitContentFilterLevel {
  FilterDisabled
  FilterMembersWithoutRoles
  FilterAllMembers
  UnknownExplicitContentFilterLevel(Int)
}

pub type MfaLevel {
  NoMfa
  ElevatedMfa
  UnknownMfaLevel(Int)
}

pub type GuildNsfwLevel {
  DefaultNsfwLevel
  ExplicitNsfwLevel
  SafeNsfwLevel
  AgeRestrictedNsfwLevel
  UnknownNsfwLevel(Int)
}

pub type PremiumTier {
  NoTier
  Tier1
  Tier2
  Tier3
  UnknownPremiumTier(Int)
}

pub type SystemChannelFlags =
  Flags(SystemChannelFlag)

/// All six are suppressions, so a set bit HIDES a notice rather than turning
/// one on.
pub type SystemChannelFlag {
  SuppressJoinNotifications
  SuppressPremiumSubscriptions
  SuppressGuildReminderNotifications
  SuppressJoinNotificationReplies
  SuppressRoleSubscriptionPurchaseNotifications
  SuppressRoleSubscriptionPurchaseNotificationReplies
}

/// Discord's system-channel-flags table, 1 << 0 through 1 << 5.
fn system_channel_flag_bit(flag: SystemChannelFlag) -> Int {
  case flag {
    SuppressJoinNotifications -> 1
    SuppressPremiumSubscriptions -> 2
    SuppressGuildReminderNotifications -> 4
    SuppressJoinNotificationReplies -> 8
    SuppressRoleSubscriptionPurchaseNotifications -> 16
    SuppressRoleSubscriptionPurchaseNotificationReplies -> 32
  }
}

pub fn has_flag(bits: SystemChannelFlags, flag: SystemChannelFlag) -> Bool {
  flags.has_bit(bits, system_channel_flag_bit(flag))
}

pub fn has_system_channel_flag(guild: Guild, flag: SystemChannelFlag) -> Bool {
  has_flag(guild.system_channel_flags, flag)
}

// The features a bot commonly branches on. The set is open, so compare against
// your own string for anything not here.

pub const feature_community: String = "COMMUNITY"

pub const feature_discoverable: String = "DISCOVERABLE"

pub const feature_partnered: String = "PARTNERED"

pub const feature_verified: String = "VERIFIED"

pub const feature_vanity_url: String = "VANITY_URL"

pub const feature_role_icons: String = "ROLE_ICONS"

pub const feature_enhanced_role_colors: String = "ENHANCED_ROLE_COLORS"

pub const feature_invites_disabled: String = "INVITES_DISABLED"

// The list is the whole answer, so this takes it rather than a `Guild`: a
// `UserGuild` and an interaction's partial carry the same open set.
pub fn has_feature(features: List(String), feature: String) -> Bool {
  list.contains(features, feature)
}

pub fn verification_level_from_int(value: Int) -> VerificationLevel {
  case value {
    0 -> NoVerification
    1 -> LowVerification
    2 -> MediumVerification
    3 -> HighVerification
    4 -> VeryHighVerification
    other -> UnknownVerificationLevel(other)
  }
}

pub fn verification_level_to_int(value: VerificationLevel) -> Int {
  case value {
    NoVerification -> 0
    LowVerification -> 1
    MediumVerification -> 2
    HighVerification -> 3
    VeryHighVerification -> 4
    UnknownVerificationLevel(other) -> other
  }
}

pub fn verification_level_to_json(value: VerificationLevel) -> Json {
  json.int(verification_level_to_int(value))
}

pub fn message_notification_level_from_int(
  value: Int,
) -> MessageNotificationLevel {
  case value {
    0 -> AllMessages
    1 -> OnlyMentions
    other -> UnknownMessageNotificationLevel(other)
  }
}

pub fn message_notification_level_to_int(
  value: MessageNotificationLevel,
) -> Int {
  case value {
    AllMessages -> 0
    OnlyMentions -> 1
    UnknownMessageNotificationLevel(other) -> other
  }
}

pub fn explicit_content_filter_from_int(
  value: Int,
) -> ExplicitContentFilterLevel {
  case value {
    0 -> FilterDisabled
    1 -> FilterMembersWithoutRoles
    2 -> FilterAllMembers
    other -> UnknownExplicitContentFilterLevel(other)
  }
}

pub fn explicit_content_filter_to_int(
  value: ExplicitContentFilterLevel,
) -> Int {
  case value {
    FilterDisabled -> 0
    FilterMembersWithoutRoles -> 1
    FilterAllMembers -> 2
    UnknownExplicitContentFilterLevel(other) -> other
  }
}

pub fn mfa_level_from_int(value: Int) -> MfaLevel {
  case value {
    0 -> NoMfa
    1 -> ElevatedMfa
    other -> UnknownMfaLevel(other)
  }
}

pub fn mfa_level_to_int(value: MfaLevel) -> Int {
  case value {
    NoMfa -> 0
    ElevatedMfa -> 1
    UnknownMfaLevel(other) -> other
  }
}

pub fn nsfw_level_from_int(value: Int) -> GuildNsfwLevel {
  case value {
    0 -> DefaultNsfwLevel
    1 -> ExplicitNsfwLevel
    2 -> SafeNsfwLevel
    3 -> AgeRestrictedNsfwLevel
    other -> UnknownNsfwLevel(other)
  }
}

pub fn nsfw_level_to_int(value: GuildNsfwLevel) -> Int {
  case value {
    DefaultNsfwLevel -> 0
    ExplicitNsfwLevel -> 1
    SafeNsfwLevel -> 2
    AgeRestrictedNsfwLevel -> 3
    UnknownNsfwLevel(other) -> other
  }
}

pub fn nsfw_level_to_json(value: GuildNsfwLevel) -> Json {
  json.int(nsfw_level_to_int(value))
}

pub fn premium_tier_from_int(value: Int) -> PremiumTier {
  case value {
    0 -> NoTier
    1 -> Tier1
    2 -> Tier2
    3 -> Tier3
    other -> UnknownPremiumTier(other)
  }
}

pub fn premium_tier_to_int(value: PremiumTier) -> Int {
  case value {
    NoTier -> 0
    Tier1 -> 1
    Tier2 -> 2
    Tier3 -> 3
    UnknownPremiumTier(other) -> other
  }
}

pub fn premium_tier_to_json(value: PremiumTier) -> Json {
  json.int(premium_tier_to_int(value))
}

pub fn decoder() -> Decoder(Guild) {
  use id <- decode.field("id", id.decoder())
  use name <- wire.string_field("name", "")
  use icon <- wire.opt_field("icon", decode.string)
  use icon_hash <- wire.opt_field("icon_hash", decode.string)
  use splash <- wire.opt_field("splash", decode.string)
  use discovery_splash <- wire.opt_field("discovery_splash", decode.string)
  use owner_id <- decode.field("owner_id", id.decoder())
  use afk_channel_id <- wire.opt_field("afk_channel_id", id.decoder())
  // 300 is Discord's own default for a guild that never set one.
  use afk_timeout <- wire.int_field("afk_timeout", 300)
  use widget_enabled <- wire.opt_field("widget_enabled", decode.bool)
  use widget_channel_id <- wire.opt_field("widget_channel_id", id.decoder())
  use verification_level <- enum_field(
    "verification_level",
    verification_level_from_int,
  )
  use default_message_notifications <- enum_field(
    "default_message_notifications",
    message_notification_level_from_int,
  )
  use explicit_content_filter <- enum_field(
    "explicit_content_filter",
    explicit_content_filter_from_int,
  )
  use roles <- wire.list_field("roles", role.decoder())
  use emojis <- wire.list_field("emojis", emoji.guild_emoji_decoder())
  use features <- wire.list_field("features", decode.string)
  use mfa_level <- enum_field("mfa_level", mfa_level_from_int)
  use application_id <- wire.opt_field("application_id", id.decoder())
  use system_channel_id <- wire.opt_field("system_channel_id", id.decoder())
  use system_channel_flags <- enum_field("system_channel_flags", flags.from_int)
  use rules_channel_id <- wire.opt_field("rules_channel_id", id.decoder())
  use max_presences <- wire.opt_field("max_presences", wire.integer())
  use max_members <- wire.opt_field("max_members", wire.integer())
  use vanity_url_code <- wire.opt_field("vanity_url_code", decode.string)
  use description <- wire.opt_field("description", decode.string)
  use banner <- wire.opt_field("banner", decode.string)
  use premium_tier <- enum_field("premium_tier", premium_tier_from_int)
  use premium_subscription_count <- wire.opt_field(
    "premium_subscription_count",
    wire.integer(),
  )
  use preferred_locale <- wire.string_field("preferred_locale", "en-US")
  use public_updates_channel_id <- wire.opt_field(
    "public_updates_channel_id",
    id.decoder(),
  )
  use max_video_channel_users <- wire.opt_field(
    "max_video_channel_users",
    wire.integer(),
  )
  use max_stage_video_channel_users <- wire.opt_field(
    "max_stage_video_channel_users",
    wire.integer(),
  )
  use approximate_member_count <- wire.opt_field(
    "approximate_member_count",
    wire.integer(),
  )
  use approximate_presence_count <- wire.opt_field(
    "approximate_presence_count",
    wire.integer(),
  )
  use nsfw_level <- enum_field("nsfw_level", nsfw_level_from_int)
  use premium_progress_bar_enabled <- wire.flag_field(
    "premium_progress_bar_enabled",
    False,
  )
  use safety_alerts_channel_id <- wire.opt_field(
    "safety_alerts_channel_id",
    id.decoder(),
  )
  use joined_at <- wire.opt_field("joined_at", decode.string)
  use large <- wire.opt_field("large", decode.bool)
  use member_count <- wire.opt_field("member_count", wire.integer())
  use voice_states <- wire.opt_field(
    "voice_states",
    decode.list(voice_state.decoder()),
  )
  use members <- wire.opt_field("members", decode.list(member.decoder()))
  use channels <- wire.opt_field("channels", decode.list(channel.decoder()))
  use threads <- wire.opt_field("threads", decode.list(channel.decoder()))
  decode.success(Guild(
    id:,
    name:,
    icon:,
    icon_hash:,
    splash:,
    discovery_splash:,
    owner_id:,
    afk_channel_id:,
    afk_timeout:,
    widget_enabled:,
    widget_channel_id:,
    verification_level:,
    default_message_notifications:,
    explicit_content_filter:,
    roles:,
    emojis:,
    features:,
    mfa_level:,
    application_id:,
    system_channel_id:,
    system_channel_flags:,
    rules_channel_id:,
    max_presences:,
    max_members:,
    vanity_url_code:,
    description:,
    banner:,
    premium_tier:,
    premium_subscription_count:,
    preferred_locale:,
    public_updates_channel_id:,
    max_video_channel_users:,
    max_stage_video_channel_users:,
    counts: approximate_counts(
      members: approximate_member_count,
      presences: approximate_presence_count,
    ),
    nsfw_level:,
    premium_progress_bar_enabled:,
    safety_alerts_channel_id:,
    gateway_create: gateway_create(
      joined_at:,
      large:,
      member_count:,
      voice_states:,
      members:,
      channels:,
      threads:,
    ),
  ))
}

/// Discord's numeric enums, bound at their own type rather than as seven
/// interchangeable ints waiting to be converted at the bottom of the decoder.
/// Absent or null is 0, which every one of these tables reads as its default.
fn enum_field(
  name: String,
  from_int: fn(Int) -> a,
  next: fn(a) -> Decoder(b),
) -> Decoder(b) {
  wire.int_field(name, 0, fn(value) { next(from_int(value)) })
}

fn approximate_counts(
  members members: Option(Int),
  presences presences: Option(Int),
) -> Option(ApproximateCounts) {
  case members, presences {
    Some(members), Some(presences) ->
      Some(ApproximateCounts(members:, presences:))
    _, _ -> None
  }
}

/// `joined_at` says whether this is a GUILD_CREATE: the gateway always sends
/// it and REST never does. Keying the block on it means an intent that hides
/// `members` cannot lose the block, and no `joined_at` is ever invented: the
/// field is an ISO-8601 instant, and `""` is one a caller has to fail to
/// parse.
fn gateway_create(
  joined_at joined_at: Option(String),
  large large: Option(Bool),
  member_count member_count: Option(Int),
  voice_states voice_states: Option(List(voice_state.VoiceState)),
  members members: Option(List(member.GuildMember)),
  channels channels: Option(List(channel.Channel)),
  threads threads: Option(List(channel.Channel)),
) -> Option(GatewayCreate) {
  case joined_at {
    None -> None
    Some(joined_at) ->
      Some(GatewayCreate(
        joined_at:,
        large: option.unwrap(large, False),
        member_count: option.unwrap(member_count, 0),
        voice_states: option.unwrap(voice_states, []),
        members: option.unwrap(members, []),
        channels: option.unwrap(channels, []),
        threads: option.unwrap(threads, []),
      ))
  }
}

/// GUILD_CREATE dispatches on the VALUE of `unavailable`: an available guild
/// may still carry `"unavailable": false`.
pub fn maybe_available_decoder() -> Decoder(MaybeAvailableGuild) {
  use unavailable <- wire.flag_field("unavailable", False)
  case unavailable {
    True ->
      decode.field("id", id.decoder(), fn(id) {
        decode.success(OfflineGuild(id))
      })
    False -> decode.map(decoder(), AvailableGuild)
  }
}

/// `GET /users/@me/guilds`. A partial: nine keys, and `owner_id` is not one of
/// them.
pub fn user_guild_decoder() -> Decoder(UserGuild) {
  use id <- decode.field("id", id.decoder())
  use name <- wire.string_field("name", "")
  use icon <- wire.opt_field("icon", decode.string)
  use banner <- wire.opt_field("banner", decode.string)
  use owner <- wire.flag_field("owner", False)
  use perms <- wire.opt_field("permissions", permissions.decoder())
  use features <- wire.list_field("features", decode.string)
  use approximate_member_count <- wire.opt_field(
    "approximate_member_count",
    wire.integer(),
  )
  use approximate_presence_count <- wire.opt_field(
    "approximate_presence_count",
    wire.integer(),
  )
  decode.success(UserGuild(
    id:,
    name:,
    icon:,
    banner:,
    owner:,
    permissions: perms,
    features:,
    counts: approximate_counts(
      members: approximate_member_count,
      presences: approximate_presence_count,
    ),
  ))
}

/// GUILD_DELETE's payload is one of these. A `GuildOutage` is Discord losing
/// the guild, so the cache keeps it; a `GuildGone` is the bot kicked, banned
/// or leaving, so the cache drops it.
pub type GuildDeparture {
  GuildOutage(id.GuildId)
  GuildGone(id.GuildId)
}

/// GUILD_DELETE dispatches on the KEY's PRESENCE, not its value: present is an
/// outage, absent is the bot being kicked, banned or leaving. A present `null`
/// and a present `false` are both an outage.
pub fn departure_decoder() -> Decoder(GuildDeparture) {
  use guild_id <- decode.field("id", id.decoder())
  use unavailable <- wire.present_field("unavailable")
  decode.success(case unavailable {
    True -> GuildOutage(guild_id)
    False -> GuildGone(guild_id)
  })
}

pub fn ban_decoder() -> Decoder(Ban) {
  use reason <- wire.opt_field("reason", decode.string)
  use user <- decode.field("user", user.decoder())
  decode.success(Ban(reason:, user:))
}
