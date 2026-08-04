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
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import glyde/channel
import glyde/emoji
import glyde/flags.{type Flags}
import glyde/id
import glyde/member
import glyde/permissions
import glyde/rest.{type Call}
import glyde/rest/body
import glyde/rest/query
import glyde/rest/seg
import glyde/role
import glyde/user
import glyde/voice_state
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
    verification_level: Option(VerificationLevel),
    default_message_notifications: Option(MessageNotificationLevel),
    explicit_content_filter: Option(ExplicitContentFilterLevel),
    roles: List(role.Role),
    /// GUILD_EMOJIS_UPDATE sends a full replacement array, never a delta.
    emojis: List(emoji.GuildEmoji),
    /// An open set of strings, so not an enum. Use `has_feature(g.features,
    /// …)`.
    features: List(String),
    mfa_level: Option(MfaLevel),
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
    premium_tier: Option(PremiumTier),
    premium_subscription_count: Option(Int),
    preferred_locale: String,
    public_updates_channel_id: Option(id.ChannelId),
    max_video_channel_users: Option(Int),
    max_stage_video_channel_users: Option(Int),
    /// Only when the request asked for `with_counts`, which answers with both
    /// or neither.
    counts: Option(ApproximateCounts),
    nsfw_level: Option(GuildNsfwLevel),
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
    permissions: Option(permissions.Effective),
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

// The six enum fields below are open sets on the wire. A value this build has
// no name for decodes as `None`, so a new level cannot sink a GUILD_CREATE.

pub type VerificationLevel {
  NoVerification
  LowVerification
  MediumVerification
  HighVerification
  VeryHighVerification
}

pub type MessageNotificationLevel {
  AllMessages
  OnlyMentions
}

pub type ExplicitContentFilterLevel {
  FilterDisabled
  FilterMembersWithoutRoles
  FilterAllMembers
}

pub type MfaLevel {
  NoMfa
  ElevatedMfa
}

pub type GuildNsfwLevel {
  DefaultNsfwLevel
  ExplicitNsfwLevel
  SafeNsfwLevel
  AgeRestrictedNsfwLevel
}

pub type PremiumTier {
  NoTier
  Tier1
  Tier2
  Tier3
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

pub fn verification_level_from_int(value: Int) -> Option(VerificationLevel) {
  case value {
    0 -> Some(NoVerification)
    1 -> Some(LowVerification)
    2 -> Some(MediumVerification)
    3 -> Some(HighVerification)
    4 -> Some(VeryHighVerification)
    _ -> None
  }
}

pub fn verification_level_to_int(value: VerificationLevel) -> Int {
  case value {
    NoVerification -> 0
    LowVerification -> 1
    MediumVerification -> 2
    HighVerification -> 3
    VeryHighVerification -> 4
  }
}

pub fn message_notification_level_from_int(
  value: Int,
) -> Option(MessageNotificationLevel) {
  case value {
    0 -> Some(AllMessages)
    1 -> Some(OnlyMentions)
    _ -> None
  }
}

pub fn message_notification_level_to_int(
  value: MessageNotificationLevel,
) -> Int {
  case value {
    AllMessages -> 0
    OnlyMentions -> 1
  }
}

pub fn explicit_content_filter_from_int(
  value: Int,
) -> Option(ExplicitContentFilterLevel) {
  case value {
    0 -> Some(FilterDisabled)
    1 -> Some(FilterMembersWithoutRoles)
    2 -> Some(FilterAllMembers)
    _ -> None
  }
}

pub fn explicit_content_filter_to_int(
  value: ExplicitContentFilterLevel,
) -> Int {
  case value {
    FilterDisabled -> 0
    FilterMembersWithoutRoles -> 1
    FilterAllMembers -> 2
  }
}

pub fn mfa_level_from_int(value: Int) -> Option(MfaLevel) {
  case value {
    0 -> Some(NoMfa)
    1 -> Some(ElevatedMfa)
    _ -> None
  }
}

pub fn mfa_level_to_int(value: MfaLevel) -> Int {
  case value {
    NoMfa -> 0
    ElevatedMfa -> 1
  }
}

pub fn nsfw_level_from_int(value: Int) -> Option(GuildNsfwLevel) {
  case value {
    0 -> Some(DefaultNsfwLevel)
    1 -> Some(ExplicitNsfwLevel)
    2 -> Some(SafeNsfwLevel)
    3 -> Some(AgeRestrictedNsfwLevel)
    _ -> None
  }
}

pub fn nsfw_level_to_int(value: GuildNsfwLevel) -> Int {
  case value {
    DefaultNsfwLevel -> 0
    ExplicitNsfwLevel -> 1
    SafeNsfwLevel -> 2
    AgeRestrictedNsfwLevel -> 3
  }
}

pub fn premium_tier_from_int(value: Int) -> Option(PremiumTier) {
  case value {
    0 -> Some(NoTier)
    1 -> Some(Tier1)
    2 -> Some(Tier2)
    3 -> Some(Tier3)
    _ -> None
  }
}

pub fn premium_tier_to_int(value: PremiumTier) -> Int {
  case value {
    NoTier -> 0
    Tier1 -> 1
    Tier2 -> 2
    Tier3 -> 3
  }
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
  use verification_level <- wire.known_field(
    "verification_level",
    verification_level_from_int,
  )
  use default_message_notifications <- wire.known_field(
    "default_message_notifications",
    message_notification_level_from_int,
  )
  use explicit_content_filter <- wire.known_field(
    "explicit_content_filter",
    explicit_content_filter_from_int,
  )
  use roles <- wire.list_field("roles", role.decoder())
  use emojis <- wire.list_field("emojis", emoji.guild_emoji_decoder())
  use features <- wire.list_field("features", decode.string)
  use mfa_level <- wire.known_field("mfa_level", mfa_level_from_int)
  use application_id <- wire.opt_field("application_id", id.decoder())
  use system_channel_id <- wire.opt_field("system_channel_id", id.decoder())
  use system_channel_flags <- wire.enum_field(
    "system_channel_flags",
    flags.from_int,
  )
  use rules_channel_id <- wire.opt_field("rules_channel_id", id.decoder())
  use max_presences <- wire.opt_field("max_presences", wire.integer())
  use max_members <- wire.opt_field("max_members", wire.integer())
  use vanity_url_code <- wire.opt_field("vanity_url_code", decode.string)
  use description <- wire.opt_field("description", decode.string)
  use banner <- wire.opt_field("banner", decode.string)
  use premium_tier <- wire.known_field("premium_tier", premium_tier_from_int)
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
  use nsfw_level <- wire.known_field("nsfw_level", nsfw_level_from_int)
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
  use joined_at <- option.map(joined_at)
  GatewayCreate(
    joined_at:,
    large: option.unwrap(large, False),
    member_count: option.unwrap(member_count, 0),
    voice_states: option.unwrap(voice_states, []),
    members: option.unwrap(members, []),
    channels: option.unwrap(channels, []),
    threads: option.unwrap(threads, []),
  )
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
  use perms <- wire.opt_field("permissions", permissions.effective_decoder())
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

/// `PUT /guilds/{g}/bans/{u}`.
pub type CreateBan {
  /// 0 to 604800 seconds, seven days. Deletes the user's recent messages
  /// along with the ban.
  CreateBan(delete_message_seconds: Option(Int))
}

/// A ban that leaves the user's messages where they are.
pub fn create_ban() -> CreateBan {
  CreateBan(delete_message_seconds: None)
}

pub fn create_ban_body(payload: CreateBan) -> body.Body {
  body.json(
    wire.entries([
      #(
        "delete_message_seconds",
        wire.put(wire.opt(payload.delete_message_seconds), json.int),
      ),
    ]),
  )
}

// -- Endpoints ---------------------------------------------------------------
//
// Everything here takes the guild major parameter, so two guilds get
// independent buckets for the same endpoint. The `/users/@me/guilds` routes
// live here too, since they return `UserGuild` and `GuildMember`.

/// `GET /guilds/{guild.id}`, as Get Guild. `with_counts` adds
/// `approximate_member_count` and `approximate_presence_count`.
pub fn get(guild: id.GuildId, with_counts with_counts: Bool) -> Call(Guild) {
  rest.get([seg.lit("guilds"), seg.guild(guild)], rest.Decoded(decoder()))
  |> rest.query(query.one("with_counts", with_counts, query.flag))
}

/// `GET /guilds/{guild.id}/channels`, as Get Guild Channels. Threads not
/// included.
pub fn channels(guild: id.GuildId) -> Call(List(channel.Channel)) {
  rest.get(
    [seg.lit("guilds"), seg.guild(guild), seg.lit("channels")],
    rest.Decoded(decode.list(channel.decoder())),
  )
}

/// `POST /guilds/{guild.id}/channels`, as Create Guild Channel.
pub fn create_channel(
  guild: id.GuildId,
  create: channel.CreateChannel,
) -> Call(channel.Channel) {
  rest.post(
    [seg.lit("guilds"), seg.guild(guild), seg.lit("channels")],
    channel.create_channel_body(create),
    rest.Decoded(channel.decoder()),
  )
}

/// `GET /guilds/{guild.id}/threads/active`, as List Active Guild Threads.
/// Unpaged, so the answer is an `ActiveThreads` and not a `ThreadList`.
pub fn active_threads(guild: id.GuildId) -> Call(channel.ActiveThreads) {
  rest.get(
    [seg.lit("guilds"), seg.guild(guild), seg.lit("threads"), seg.lit("active")],
    rest.Decoded(channel.active_threads_decoder()),
  )
}

/// `GET /guilds/{guild.id}/bans`, as Get Guild Bans. Discord caps `limit`
/// at 1000. Pages by user id.
pub fn bans(
  guild: id.GuildId,
  cursor cursor: Option(query.Page(id.User)),
  limit limit: Option(Int),
) -> Call(List(Ban)) {
  rest.get(bans_at(guild), rest.Decoded(decode.list(ban_decoder())))
  |> rest.query(
    list.flatten([query.page(cursor), query.opt("limit", limit, query.number)]),
  )
}

/// `GET /guilds/{guild.id}/bans/{user.id}`, as Get Guild Ban. Answers 404 when
/// the user is not banned.
pub fn ban_for(guild: id.GuildId, user: id.UserId) -> Call(Ban) {
  rest.get(ban_at(guild, user), rest.Decoded(ban_decoder()))
}

/// `PUT /guilds/{guild.id}/bans/{user.id}`, as Create Guild Ban.
pub fn ban(guild: id.GuildId, user: id.UserId, ban: CreateBan) -> Call(Nil) {
  rest.put(ban_at(guild, user), create_ban_body(ban), rest.NoContent(Nil))
}

/// `DELETE /guilds/{guild.id}/bans/{user.id}`, as Remove Guild Ban.
pub fn unban(guild: id.GuildId, user: id.UserId) -> Call(Nil) {
  rest.delete(ban_at(guild, user), rest.NoContent(Nil))
}

/// `GET /guilds/{guild.id}/members`, as List Guild Members. Without the
/// privileged GUILD_MEMBERS intent Discord answers 403, not a short list.
/// Discord caps `limit` at 1000 and defaults it to 1.
pub fn members(
  guild: id.GuildId,
  after after: Option(id.UserId),
  limit limit: Option(Int),
) -> Call(List(member.GuildMember)) {
  rest.get(members_at(guild), rest.Decoded(decode.list(member.decoder())))
  |> rest.query(
    list.flatten([
      query.opt("after", after, query.snowflake),
      query.opt("limit", limit, query.number),
    ]),
  )
}

/// `GET /guilds/{guild.id}/members/{user.id}`, as Get Guild Member.
pub fn member(guild: id.GuildId, user: id.UserId) -> Call(member.GuildMember) {
  rest.get(member_at(guild, user), rest.Decoded(member.decoder()))
}

/// `GET /guilds/{guild.id}/members/search`, as Search Guild Members. A prefix
/// match on username or nickname. Discord caps `limit` at 1000, defaults to 1.
pub fn search_members(
  guild: id.GuildId,
  query search: String,
  limit limit: Option(Int),
) -> Call(List(member.GuildMember)) {
  rest.get(
    list.append(members_at(guild), [seg.lit("search")]),
    rest.Decoded(decode.list(member.decoder())),
  )
  |> rest.query(
    list.flatten([
      query.one("query", search, query.text),
      query.opt("limit", limit, query.number),
    ]),
  )
}

/// `PATCH /guilds/{guild.id}/members/{user.id}`, as Modify Guild Member.
pub fn edit_member(
  guild: id.GuildId,
  user: id.UserId,
  edit: member.EditGuildMember,
) -> Call(member.GuildMember) {
  rest.patch(
    member_at(guild, user),
    member.edit_guild_member_body(edit),
    rest.Decoded(member.decoder()),
  )
}

/// `PATCH /guilds/{guild.id}/members/@me`, as Modify Current Member.
pub fn edit_me(
  guild: id.GuildId,
  edit: member.EditCurrentMember,
) -> Call(member.GuildMember) {
  rest.patch(
    list.append(members_at(guild), [seg.lit("@me")]),
    member.edit_current_member_body(edit),
    rest.Decoded(member.decoder()),
  )
}

/// `DELETE /guilds/{guild.id}/members/{user.id}`, as Remove Guild Member.
pub fn kick(guild: id.GuildId, user: id.UserId) -> Call(Nil) {
  rest.delete(member_at(guild, user), rest.NoContent(Nil))
}

/// `PUT /guilds/{guild.id}/members/{user.id}/roles/{role.id}`, as Add Guild
/// Member Role.
pub fn add_role(
  guild: id.GuildId,
  user: id.UserId,
  role: id.RoleId,
) -> Call(Nil) {
  rest.put(member_role_at(guild, user, role), body.NoBody, rest.NoContent(Nil))
}

/// `DELETE /guilds/{guild.id}/members/{user.id}/roles/{role.id}`, as Remove
/// Guild Member Role.
pub fn remove_role(
  guild: id.GuildId,
  user: id.UserId,
  role: id.RoleId,
) -> Call(Nil) {
  rest.delete(member_role_at(guild, user, role), rest.NoContent(Nil))
}

/// `GET /guilds/{guild.id}/roles`, as Get Guild Roles.
pub fn roles(guild: id.GuildId) -> Call(List(role.Role)) {
  rest.get(roles_at(guild), rest.Decoded(decode.list(role.decoder())))
}

/// `GET /guilds/{guild.id}/roles/{role.id}`, as Get Guild Role.
pub fn role(guild: id.GuildId, role_id: id.RoleId) -> Call(role.Role) {
  rest.get(role_at(guild, role_id), rest.Decoded(role.decoder()))
}

/// `POST /guilds/{guild.id}/roles`, as Create Guild Role.
pub fn create_role(
  guild: id.GuildId,
  create: role.CreateRole,
) -> Call(role.Role) {
  rest.post(
    roles_at(guild),
    role.create_role_body(create),
    rest.Decoded(role.decoder()),
  )
}

/// `PATCH /guilds/{guild.id}/roles/{role.id}`, as Modify Guild Role.
pub fn edit_role(
  guild: id.GuildId,
  role_id: id.RoleId,
  edit: role.EditRole,
) -> Call(role.Role) {
  rest.patch(
    role_at(guild, role_id),
    role.edit_role_body(edit),
    rest.Decoded(role.decoder()),
  )
}

/// `DELETE /guilds/{guild.id}/roles/{role.id}`, as Delete Guild Role.
pub fn delete_role(guild: id.GuildId, role_id: id.RoleId) -> Call(Nil) {
  rest.delete(role_at(guild, role_id), rest.NoContent(Nil))
}

/// `GET /users/@me/guilds`, as Get Current User Guilds. A `UserGuild` and not
/// a `Guild`: nine keys, and `owner` and `permissions` come from nowhere else.
/// Discord caps `limit` at 200 and defaults it to 200. A `/users` route, so no
/// guild major parameter. Pages by guild id.
pub fn mine(
  cursor cursor: Option(query.Page(id.Guild)),
  limit limit: Option(Int),
  with_counts with_counts: Bool,
) -> Call(List(UserGuild)) {
  rest.get(
    [seg.lit("users"), seg.lit("@me"), seg.lit("guilds")],
    rest.Decoded(decode.list(user_guild_decoder())),
  )
  |> rest.query(
    list.flatten([
      query.page(cursor),
      query.opt("limit", limit, query.number),
      query.one("with_counts", with_counts, query.flag),
    ]),
  )
}

/// `GET /users/@me/guilds/{guild.id}/member`, as Get Current User Guild
/// Member. A `/users` route, so the guild is a plain segment and every guild
/// shares one bucket.
pub fn my_member(guild: id.GuildId) -> Call(member.GuildMember) {
  rest.get(
    list.append(user_guild_at(guild), [seg.lit("member")]),
    rest.Decoded(member.decoder()),
  )
}

/// `DELETE /users/@me/guilds/{guild.id}`, as Leave Guild. Answers 204 whether
/// or not the bot was in it.
pub fn leave(guild: id.GuildId) -> Call(Nil) {
  rest.delete(user_guild_at(guild), rest.NoContent(Nil))
}

fn user_guild_at(guild: id.GuildId) -> List(seg.Seg) {
  [seg.lit("users"), seg.lit("@me"), seg.lit("guilds"), seg.id(guild)]
}

fn bans_at(guild: id.GuildId) -> List(seg.Seg) {
  [seg.lit("guilds"), seg.guild(guild), seg.lit("bans")]
}

fn ban_at(guild: id.GuildId, user: id.UserId) -> List(seg.Seg) {
  list.append(bans_at(guild), [seg.id(user)])
}

fn members_at(guild: id.GuildId) -> List(seg.Seg) {
  [seg.lit("guilds"), seg.guild(guild), seg.lit("members")]
}

fn member_at(guild: id.GuildId, user: id.UserId) -> List(seg.Seg) {
  list.append(members_at(guild), [seg.id(user)])
}

fn member_role_at(
  guild: id.GuildId,
  user: id.UserId,
  role_id: id.RoleId,
) -> List(seg.Seg) {
  list.append(member_at(guild, user), [seg.lit("roles"), seg.id(role_id)])
}

fn roles_at(guild: id.GuildId) -> List(seg.Seg) {
  [seg.lit("guilds"), seg.guild(guild), seg.lit("roles")]
}

fn role_at(guild: id.GuildId, role_id: id.RoleId) -> List(seg.Seg) {
  list.append(roles_at(guild), [seg.id(role_id)])
}
