//// Channels, threads and permission overwrites.
////
//// One flat record with a `type_`, not a sum type: twelve of the thirteen
//// types carry `name`, so a sum type would force a twelve-arm case to read it.
////
//// Only `id` and `type_` are required, so an interaction's partial channel
//// decodes through the same decoder as a full one.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option}
import glyde/flags.{type Flags}
import glyde/id
import glyde/model/member
import glyde/model/user
import glyde/permissions
import glyde/wire

/// A channel of any kind, threads included.
pub type Channel {
  Channel(
    id: id.ChannelId,
    type_: ChannelType,
    guild_id: Option(id.GuildId),
    position: Option(Int),
    permission_overwrites: Option(List(PermissionOverwrite)),
    name: Option(String),
    topic: Option(String),
    nsfw: Option(Bool),
    /// May point at a deleted message.
    last_message_id: Option(id.MessageId),
    bitrate: Option(Int),
    /// 0 means no limit.
    user_limit: Option(Int),
    /// Slowmode in SECONDS, 0 to 21600. Also gates thread creation.
    rate_limit_per_user: Option(Int),
    recipients: Option(List(user.User)),
    icon: Option(String),
    owner_id: Option(id.UserId),
    application_id: Option(id.ApplicationId),
    managed: Option(Bool),
    parent_id: Option(id.ChannelId),
    last_pin_timestamp: Option(String),
    /// Null means Discord picks the region.
    rtc_region: Option(String),
    video_quality_mode: Option(VideoQualityMode),
    /// Threads only. Excludes the initial message, and stops at 50 on threads
    /// created before 2022-07-01.
    message_count: Option(Int),
    /// Threads only. STOPS COUNTING AT 50.
    member_count: Option(Int),
    thread_metadata: Option(ThreadMetadata),
    /// The current user's membership: only `flags` and `join_timestamp`.
    member: Option(ThreadMember),
    /// MINUTES.
    default_auto_archive_duration: Option(ThreadAutoArchiveDuration),
    /// The invoking user's computed permissions, on the partial channels in an
    /// interaction's resolved data and nowhere else. The bot's own are
    /// `app_permissions` on `model/interaction.Interaction`, a key of the
    /// interaction rather than of any channel in it.
    permissions: Option(permissions.Permissions),
    /// `None` on the shapes that drop the key, an interaction's partial
    /// included. Defaulting it to 0 would let a cache merge clear flags
    /// nobody cleared, and an edit sends that back.
    flags: Option(ChannelFlags),
    /// Threads only. Unlike `message_count` this never decrements.
    total_message_sent: Option(Int),
    default_thread_rate_limit_per_user: Option(Int),
    /// THREAD_CREATE only: a new thread, not one the bot was added to.
    newly_created: Option(Bool),
  )
}

/// Live values are 0 to 5, 10 to 13, 15 and 16. 14 is hub-only, and 6 to 9
/// were withdrawn but can still turn up in cached data.
pub type ChannelType {
  GuildText
  Dm
  GuildVoice
  GroupDm
  GuildCategory
  GuildAnnouncement
  AnnouncementThread
  PublicThread
  PrivateThread
  GuildStageVoice
  GuildDirectory
  GuildForum
  GuildMedia
  UnknownChannelType(Int)
}

pub type OverwriteType {
  RoleOverwrite
  MemberOverwrite
  UnknownOverwriteType(Int)
}

pub type VideoQualityMode {
  AutoQuality
  FullQuality
  UnknownVideoQualityMode(Int)
}

/// Minute values, not an ordinal: 60, 1440, 4320, 10080.
pub type ThreadAutoArchiveDuration {
  OneHour
  OneDay
  ThreeDays
  OneWeek
  UnknownAutoArchiveDuration(Int)
}

/// `id` is a role id or a user id, and only `type_` says which. Read it
/// through `overwrite_target`.
pub type PermissionOverwrite {
  PermissionOverwrite(
    id: id.OverwriteId,
    type_: OverwriteType,
    allow: permissions.Permissions,
    deny: permissions.Permissions,
  )
}

pub type ThreadMetadata {
  ThreadMetadata(
    archived: Bool,
    /// MINUTES.
    auto_archive_duration: ThreadAutoArchiveDuration,
    /// ISO-8601, when the archive flag last changed.
    archive_timestamp: String,
    locked: Bool,
    /// Private threads only.
    invitable: Option(Bool),
    /// Only threads created after 2022-01-09.
    create_timestamp: Option(String),
  )
}

/// One user's membership of one thread. Mind the collision: `Channel.member`
/// is a `ThreadMember`, and `ThreadMember.member` is a `GuildMember`.
pub type ThreadMember {
  ThreadMember(
    /// The THREAD's id.
    id: Option(id.ChannelId),
    user_id: Option(id.UserId),
    join_timestamp: String,
    /// Notification settings. Discord names no flags for these.
    flags: Int,
    /// Only when the request asked for `with_member=true`.
    member: Option(member.GuildMember),
  )
}

/// The body of the two archived thread listings, which page. `members` holds
/// only the bot's own membership, and only of the threads it has joined.
pub type ThreadList {
  ThreadList(
    threads: List(Channel),
    members: List(ThreadMember),
    /// Another page exists before the oldest thread returned.
    has_more: Bool,
  )
}

/// The body of `GET /guilds/{id}/threads/active`, which is every active thread
/// at once. Discord sends no `has_more` here, so there is no page to ask for.
pub type ActiveThreads {
  ActiveThreads(threads: List(Channel), members: List(ThreadMember))
}

pub type ChannelFlags =
  Flags(ChannelFlag)

pub type ChannelFlag {
  /// A forum or media post pinned to the top of its parent.
  Pinned
  /// The parent forum requires a tag on every post.
  RequireTag
  HideMediaDownloadOptions
  /// Every attachment in the channel is treated as a spoiler.
  IsSpoilerChannel
}

/// Discord's channel-flags table: 1 << 1, 1 << 4, 1 << 15, 1 << 21.
fn channel_flag_bit(flag: ChannelFlag) -> Int {
  case flag {
    Pinned -> 2
    RequireTag -> 16
    HideMediaDownloadOptions -> 32_768
    IsSpoilerChannel -> 2_097_152
  }
}

pub const no_channel_flags: ChannelFlags = flags.none

/// Build the `flags` an edit sends. Anything decoded off the wire should be
/// edited with `with_flag` instead, so bits this build cannot name survive.
pub fn channel_flags(of chosen: List(ChannelFlag)) -> ChannelFlags {
  list.fold(chosen, no_channel_flags, with_flag)
}

pub fn has_flag(bits: ChannelFlags, flag: ChannelFlag) -> Bool {
  flags.has_bit(bits, channel_flag_bit(flag))
}

pub fn with_flag(bits: ChannelFlags, flag: ChannelFlag) -> ChannelFlags {
  flags.set_bit(bits, channel_flag_bit(flag))
}

pub fn without_flag(bits: ChannelFlags, flag: ChannelFlag) -> ChannelFlags {
  flags.clear_bit(bits, channel_flag_bit(flag))
}

// The type is the whole answer, so these take it rather than a `Channel`:
// a THREAD_DELETE payload and an interaction's partial both have one.
//
// An unknown type answers False in every predicate below: a guess costs a 400
// that reads like a permissions bug.

pub fn is_thread(type_: ChannelType) -> Bool {
  case type_ {
    AnnouncementThread | PublicThread | PrivateThread -> True
    _ -> False
  }
}

pub fn is_dm(type_: ChannelType) -> Bool {
  case type_ {
    Dm | GroupDm -> True
    _ -> False
  }
}

/// Voice and stage channels have a text chat too.
pub fn is_textable(type_: ChannelType) -> Bool {
  case type_ {
    GuildText
    | Dm
    | GroupDm
    | GuildAnnouncement
    | GuildVoice
    | GuildStageVoice
    | AnnouncementThread
    | PublicThread
    | PrivateThread -> True
    _ -> False
  }
}

pub fn is_voice(type_: ChannelType) -> Bool {
  case type_ {
    GuildVoice | GuildStageVoice -> True
    _ -> False
  }
}

/// Forums and media channels hold threads only, so they are not textable.
pub fn is_thread_only(type_: ChannelType) -> Bool {
  case type_ {
    GuildForum | GuildMedia -> True
    _ -> False
  }
}

/// Who an overwrite applies to. Three cases, not two `Option`s: a type Discord
/// adds after this build is neither a role nor a member, and treating it as
/// either grants or denies the wrong people.
pub type OverwriteTarget {
  RoleTarget(id.RoleId)
  MemberTarget(id.UserId)
  /// The raw `type`, so a caller can recognise one this build cannot name.
  UnknownTarget(id.OverwriteId, Int)
}

pub fn overwrite_target(overwrite: PermissionOverwrite) -> OverwriteTarget {
  case overwrite.type_ {
    RoleOverwrite -> RoleTarget(id.retag(overwrite.id, to: id.role))
    MemberOverwrite -> MemberTarget(id.retag(overwrite.id, to: id.user))
    UnknownOverwriteType(raw) -> UnknownTarget(overwrite.id, raw)
  }
}

pub fn channel_type_from_int(value: Int) -> ChannelType {
  case value {
    0 -> GuildText
    1 -> Dm
    2 -> GuildVoice
    3 -> GroupDm
    4 -> GuildCategory
    5 -> GuildAnnouncement
    10 -> AnnouncementThread
    11 -> PublicThread
    12 -> PrivateThread
    13 -> GuildStageVoice
    14 -> GuildDirectory
    15 -> GuildForum
    16 -> GuildMedia
    other -> UnknownChannelType(other)
  }
}

pub fn channel_type_to_int(value: ChannelType) -> Int {
  case value {
    GuildText -> 0
    Dm -> 1
    GuildVoice -> 2
    GroupDm -> 3
    GuildCategory -> 4
    GuildAnnouncement -> 5
    AnnouncementThread -> 10
    PublicThread -> 11
    PrivateThread -> 12
    GuildStageVoice -> 13
    GuildDirectory -> 14
    GuildForum -> 15
    GuildMedia -> 16
    UnknownChannelType(other) -> other
  }
}

pub fn channel_type_decoder() -> Decoder(ChannelType) {
  wire.integer() |> decode.map(channel_type_from_int)
}

pub fn channel_type_to_json(value: ChannelType) -> Json {
  json.int(channel_type_to_int(value))
}

pub fn overwrite_type_from_int(value: Int) -> OverwriteType {
  case value {
    0 -> RoleOverwrite
    1 -> MemberOverwrite
    other -> UnknownOverwriteType(other)
  }
}

pub fn overwrite_type_to_int(value: OverwriteType) -> Int {
  case value {
    RoleOverwrite -> 0
    MemberOverwrite -> 1
    UnknownOverwriteType(other) -> other
  }
}

pub fn overwrite_type_decoder() -> Decoder(OverwriteType) {
  wire.integer() |> decode.map(overwrite_type_from_int)
}

pub fn overwrite_type_to_json(value: OverwriteType) -> Json {
  json.int(overwrite_type_to_int(value))
}

pub fn video_quality_mode_from_int(value: Int) -> VideoQualityMode {
  case value {
    1 -> AutoQuality
    2 -> FullQuality
    other -> UnknownVideoQualityMode(other)
  }
}

pub fn video_quality_mode_to_int(value: VideoQualityMode) -> Int {
  case value {
    AutoQuality -> 1
    FullQuality -> 2
    UnknownVideoQualityMode(other) -> other
  }
}

pub fn video_quality_mode_decoder() -> Decoder(VideoQualityMode) {
  wire.integer() |> decode.map(video_quality_mode_from_int)
}

pub fn video_quality_mode_to_json(value: VideoQualityMode) -> Json {
  json.int(video_quality_mode_to_int(value))
}

pub fn auto_archive_duration_from_int(value: Int) -> ThreadAutoArchiveDuration {
  case value {
    60 -> OneHour
    1440 -> OneDay
    4320 -> ThreeDays
    10_080 -> OneWeek
    other -> UnknownAutoArchiveDuration(other)
  }
}

pub fn auto_archive_duration_to_int(value: ThreadAutoArchiveDuration) -> Int {
  case value {
    OneHour -> 60
    OneDay -> 1440
    ThreeDays -> 4320
    OneWeek -> 10_080
    UnknownAutoArchiveDuration(other) -> other
  }
}

pub fn auto_archive_duration_decoder() -> Decoder(ThreadAutoArchiveDuration) {
  wire.integer() |> decode.map(auto_archive_duration_from_int)
}

pub fn auto_archive_duration_to_json(value: ThreadAutoArchiveDuration) -> Json {
  json.int(auto_archive_duration_to_int(value))
}

pub fn permission_overwrite_decoder() -> Decoder(PermissionOverwrite) {
  use id <- decode.field("id", id.decoder())
  use type_ <- decode.field("type", overwrite_type_decoder())
  use allow <- decode.field("allow", permissions.decoder())
  use deny <- decode.field("deny", permissions.decoder())
  decode.success(PermissionOverwrite(id:, type_:, allow:, deny:))
}

pub fn permission_overwrite_to_json(overwrite: PermissionOverwrite) -> Json {
  json.object([
    #("id", id.to_json(overwrite.id)),
    #("type", overwrite_type_to_json(overwrite.type_)),
    #("allow", permissions.to_json(overwrite.allow)),
    #("deny", permissions.to_json(overwrite.deny)),
  ])
}

pub fn thread_metadata_decoder() -> Decoder(ThreadMetadata) {
  use archived <- wire.flag_field("archived", False)
  use auto_archive_duration <- wire.opt_field(
    "auto_archive_duration",
    auto_archive_duration_decoder(),
  )
  use archive_timestamp <- wire.string_field("archive_timestamp", "")
  use locked <- wire.flag_field("locked", False)
  use invitable <- wire.opt_field("invitable", decode.bool)
  use create_timestamp <- wire.opt_field("create_timestamp", decode.string)
  decode.success(ThreadMetadata(
    archived:,
    // Discord's own default for a thread that never set one.
    auto_archive_duration: option.unwrap(auto_archive_duration, OneDay),
    archive_timestamp:,
    locked:,
    invitable:,
    create_timestamp:,
  ))
}

pub fn thread_member_decoder() -> Decoder(ThreadMember) {
  use id <- wire.opt_field("id", id.decoder())
  use user_id <- wire.opt_field("user_id", id.decoder())
  use join_timestamp <- wire.string_field("join_timestamp", "")
  use flags <- wire.int_field("flags", 0)
  use member <- wire.opt_field("member", member.decoder())
  decode.success(ThreadMember(id:, user_id:, join_timestamp:, flags:, member:))
}

pub fn decoder() -> Decoder(Channel) {
  use id <- decode.field("id", id.decoder())
  use type_ <- decode.field("type", channel_type_decoder())
  use guild_id <- wire.opt_field("guild_id", id.decoder())
  use position <- wire.opt_field("position", wire.integer())
  use permission_overwrites <- wire.opt_field(
    "permission_overwrites",
    decode.list(permission_overwrite_decoder()),
  )
  use name <- wire.opt_field("name", decode.string)
  use topic <- wire.opt_field("topic", decode.string)
  use nsfw <- wire.opt_field("nsfw", decode.bool)
  use last_message_id <- wire.opt_field("last_message_id", id.decoder())
  use bitrate <- wire.opt_field("bitrate", wire.integer())
  use user_limit <- wire.opt_field("user_limit", wire.integer())
  use rate_limit_per_user <- wire.opt_field(
    "rate_limit_per_user",
    wire.integer(),
  )
  use recipients <- wire.opt_field("recipients", decode.list(user.decoder()))
  use icon <- wire.opt_field("icon", decode.string)
  use owner_id <- wire.opt_field("owner_id", id.decoder())
  use application_id <- wire.opt_field("application_id", id.decoder())
  use managed <- wire.opt_field("managed", decode.bool)
  use parent_id <- wire.opt_field("parent_id", id.decoder())
  use last_pin_timestamp <- wire.opt_field("last_pin_timestamp", decode.string)
  use rtc_region <- wire.opt_field("rtc_region", decode.string)
  use video_quality_mode <- wire.opt_field(
    "video_quality_mode",
    video_quality_mode_decoder(),
  )
  use message_count <- wire.opt_field("message_count", wire.integer())
  use member_count <- wire.opt_field("member_count", wire.integer())
  use thread_metadata <- wire.opt_field(
    "thread_metadata",
    thread_metadata_decoder(),
  )
  use member <- wire.opt_field("member", thread_member_decoder())
  use default_auto_archive_duration <- wire.opt_field(
    "default_auto_archive_duration",
    auto_archive_duration_decoder(),
  )
  use permissions <- wire.opt_field("permissions", permissions.decoder())
  use channel_flags <- wire.opt_field("flags", flags.decoder())
  use total_message_sent <- wire.opt_field("total_message_sent", wire.integer())
  use default_thread_rate_limit_per_user <- wire.opt_field(
    "default_thread_rate_limit_per_user",
    wire.integer(),
  )
  use newly_created <- wire.opt_field("newly_created", decode.bool)
  decode.success(Channel(
    id:,
    type_:,
    guild_id:,
    position:,
    permission_overwrites:,
    name:,
    topic:,
    nsfw:,
    last_message_id:,
    bitrate:,
    user_limit:,
    rate_limit_per_user:,
    recipients:,
    icon:,
    owner_id:,
    application_id:,
    managed:,
    parent_id:,
    last_pin_timestamp:,
    rtc_region:,
    video_quality_mode:,
    message_count:,
    member_count:,
    thread_metadata:,
    member:,
    default_auto_archive_duration:,
    permissions:,
    flags: channel_flags,
    total_message_sent:,
    default_thread_rate_limit_per_user:,
    newly_created:,
  ))
}

pub fn thread_list_decoder() -> Decoder(ThreadList) {
  use threads <- wire.list_field("threads", decoder())
  use members <- wire.list_field("members", thread_member_decoder())
  use has_more <- wire.flag_field("has_more", False)
  decode.success(ThreadList(threads:, members:, has_more:))
}

pub fn active_threads_decoder() -> Decoder(ActiveThreads) {
  use threads <- wire.list_field("threads", decoder())
  use members <- wire.list_field("members", thread_member_decoder())
  decode.success(ActiveThreads(threads:, members:))
}
