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
import gleam/option.{type Option, None}
import glyde/field.{type Field, Absent, Present}
import glyde/flags.{type Flags}
import glyde/id
import glyde/member
import glyde/permissions.{type Permissions}
import glyde/rest.{type Call}
import glyde/rest/body.{type Body}
import glyde/rest/query
import glyde/rest/seg
import glyde/user
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
    /// `app_permissions` on `interaction.Interaction`, a key of the
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

/// A point in time to page back from. Three routes here order by an instant
/// instead of by snowflake, and a snowflake in one of their `before`
/// parameters is accepted and answers the wrong window, so this is not a
/// bare string.
pub opaque type TimeCursor {
  TimeCursor(timestamp: String)
}

/// When a thread was archived, which is the order the archived listings come
/// in. Page on with the oldest thread you just read.
pub fn archived_at(thread: ThreadMetadata) -> TimeCursor {
  TimeCursor(thread.archive_timestamp)
}

/// An instant of your own, as ISO-8601. Every timestamp Discord sends is
/// already in this shape.
pub fn at_time(iso8601: String) -> TimeCursor {
  TimeCursor(iso8601)
}

/// The wrapped ISO-8601, for building `?before=` where the type lives in
/// another module.
pub fn time_cursor_value(cursor: TimeCursor) -> String {
  cursor.timestamp
}

// -- Bodies for creating and editing channels and threads --------------------
//
// The enums here are send-only, so none of them has an unknown tail: a value
// Discord does not know is a 400, not something to survive. Each holds the
// values its endpoint accepts and nothing else.
//
// `PATCH /channels/{id}` takes two structurally different bodies at one URL,
// so a guild channel and a thread are two types with an encoder each. On an
// edit `null` is an instruction, which is what `Field` is for; a create has
// nothing to clear, so it uses `Option`.

/// What `POST /guilds/{g}/channels` can create. Threads come from the thread
/// routes and a DM is not a guild channel, so neither is in here.
pub type CreatableChannelType {
  TextChannel
  VoiceChannel
  CategoryChannel
  AnnouncementChannel
  StageChannel
  ForumChannel
  MediaChannel
}

/// The only conversion `PATCH /channels/{id}` does: text to announcement and
/// back, in a guild with the NEWS feature.
pub type ChannelConversion {
  ToText
  ToAnnouncement
}

/// One permission overwrite as it goes out.
///
/// Opaque because Discord reads `type` to decide what the id means: a role id
/// under `type: 1` is not an error, it applies the overwrite to whichever
/// member happens to have that id. The two constructors are the only way in,
/// so the pair cannot disagree.
pub opaque type OverwriteBody {
  OverwriteBody(
    id: id.OverwriteId,
    type_: OverwriteType,
    allow: Permissions,
    deny: Permissions,
  )
}

pub fn role_overwrite(role: id.RoleId) -> OverwriteBody {
  OverwriteBody(
    id: id.retag(role, to: id.overwrite),
    type_: RoleOverwrite,
    allow: permissions.none(),
    deny: permissions.none(),
  )
}

pub fn member_overwrite(user: id.UserId) -> OverwriteBody {
  OverwriteBody(
    id: id.retag(user, to: id.overwrite),
    type_: MemberOverwrite,
    allow: permissions.none(),
    deny: permissions.none(),
  )
}

/// An overwrite read off a channel, ready to send back.
/// `permission_overwrites` replaces the whole array, so an edit that changes
/// one entry has to send the others back with it, and they arrive as
/// `PermissionOverwrite`.
///
/// `Error` carries the number Discord sent for a type this build does not
/// know: echoing it back would tell Discord the id means something else.
pub fn overwrite_from(
  overwrite: PermissionOverwrite,
) -> Result(OverwriteBody, Int) {
  case overwrite.type_ {
    RoleOverwrite | MemberOverwrite ->
      Ok(OverwriteBody(
        id: overwrite.id,
        type_: overwrite.type_,
        allow: overwrite.allow,
        deny: overwrite.deny,
      ))
    UnknownOverwriteType(raw) -> Error(raw)
  }
}

/// The complete allowed set, not an addition to what is already there.
pub fn allowing(body: OverwriteBody, allow: Permissions) -> OverwriteBody {
  OverwriteBody(..body, allow: allow)
}

/// The complete denied set. Anything in neither set is inherited.
pub fn denying(body: OverwriteBody, deny: Permissions) -> OverwriteBody {
  OverwriteBody(..body, deny: deny)
}

/// The id for the path of `PUT /channels/{c}/permissions/{o}`, so the path and
/// the body come from the same value.
pub fn overwrite_id(body: OverwriteBody) -> id.OverwriteId {
  body.id
}

/// An entry in a `permission_overwrites` array, id included.
pub fn overwrite_body_to_json(payload: OverwriteBody) -> Json {
  json.object([#("id", id.to_json(payload.id)), ..overwrite_fields(payload)])
}

/// `PUT /channels/{c}/permissions/{o}`, which carries the id in the path
/// instead. Replaces the whole overwrite.
pub fn overwrite_permissions_body(payload: OverwriteBody) -> Body {
  body.json(overwrite_fields(payload))
}

fn overwrite_fields(payload: OverwriteBody) -> List(#(String, Json)) {
  [
    #("type", overwrite_type_to_json(payload.type_)),
    // Both always written: Discord reads a missing bitfield as "0", so leaving
    // one out clears it rather than keeping what was there.
    #("allow", permissions.to_json(payload.allow)),
    #("deny", permissions.to_json(payload.deny)),
  ]
}

/// `POST /guilds/{g}/channels`. Only `name` is required.
pub type CreateChannel {
  CreateChannel(
    /// 1 to 100 characters.
    name: String,
    /// Discord defaults this to a text 
    type_: Option(CreatableChannelType),
    topic: Option(String),
    bitrate: Option(Int),
    user_limit: Option(Int),
    /// Seconds.
    rate_limit_per_user: Option(Int),
    position: Option(Int),
    permission_overwrites: Option(List(OverwriteBody)),
    parent_id: Option(id.ChannelId),
    nsfw: Option(Bool),
    rtc_region: Option(String),
    video_quality_mode: Option(VideoQualityMode),
    /// Minutes.
    default_auto_archive_duration: Option(ThreadAutoArchiveDuration),
    default_thread_rate_limit_per_user: Option(Int),
    /// The complete set, not an addition: Discord reads `flags` as the whole
    /// bitfield, so a flag left out of the list is off.
    flags: Option(List(ChannelFlag)),
  )
}

pub fn create_channel(name: String) -> CreateChannel {
  CreateChannel(
    name: name,
    type_: None,
    topic: None,
    bitrate: None,
    user_limit: None,
    rate_limit_per_user: None,
    position: None,
    permission_overwrites: None,
    parent_id: None,
    nsfw: None,
    rtc_region: None,
    video_quality_mode: None,
    default_auto_archive_duration: None,
    default_thread_rate_limit_per_user: None,
    flags: None,
  )
}

pub fn create_channel_body(payload: CreateChannel) -> Body {
  body.json(
    wire.entries([
      #("name", Present(json.string(payload.name))),
      #("type", wire.put(wire.opt(payload.type_), creatable_type_to_json)),
      #("topic", wire.put(wire.opt(payload.topic), json.string)),
      #("bitrate", wire.put(wire.opt(payload.bitrate), json.int)),
      #("user_limit", wire.put(wire.opt(payload.user_limit), json.int)),
      #("rate_limit_per_user", seconds(wire.opt(payload.rate_limit_per_user))),
      #("position", wire.put(wire.opt(payload.position), json.int)),
      #(
        "permission_overwrites",
        overwrites(wire.opt(payload.permission_overwrites)),
      ),
      #("parent_id", wire.put(wire.opt(payload.parent_id), id.to_json)),
      #("nsfw", wire.put(wire.opt(payload.nsfw), json.bool)),
      #("rtc_region", wire.put(wire.opt(payload.rtc_region), json.string)),
      #("video_quality_mode", quality(wire.opt(payload.video_quality_mode))),
      #(
        "default_auto_archive_duration",
        archive(wire.opt(payload.default_auto_archive_duration)),
      ),
      #(
        "default_thread_rate_limit_per_user",
        seconds(wire.opt(payload.default_thread_rate_limit_per_user)),
      ),
      #("flags", wire.put(wire.opt(payload.flags), settable_flags_to_json)),
    ]),
  )
}

/// `PATCH /channels/{id}` for a guild  Group DM edits are out of v1.
pub type EditGuildChannel {
  EditGuildChannel(
    name: Option(String),
    type_: Option(ChannelConversion),
    position: Field(Int),
    topic: Field(String),
    nsfw: Field(Bool),
    rate_limit_per_user: Field(Int),
    bitrate: Field(Int),
    user_limit: Field(Int),
    /// A list replaces the whole set, never merges. `Null` means no
    /// overwrites at all. Leaving them alone is `Absent`.
    permission_overwrites: Field(List(OverwriteBody)),
    /// `Null` moves the channel out of its category.
    parent_id: Field(id.ChannelId),
    /// `Null` hands region selection back to Discord.
    rtc_region: Field(String),
    video_quality_mode: Field(VideoQualityMode),
    default_auto_archive_duration: Field(ThreadAutoArchiveDuration),
    default_thread_rate_limit_per_user: Option(Int),
    /// The complete set, not an addition: Discord reads `flags` as the whole
    /// bitfield, so a flag left out of the list is off.
    flags: Option(List(ChannelFlag)),
  )
}

pub fn edit_guild_channel() -> EditGuildChannel {
  EditGuildChannel(
    name: None,
    type_: None,
    position: Absent,
    topic: Absent,
    nsfw: Absent,
    rate_limit_per_user: Absent,
    bitrate: Absent,
    user_limit: Absent,
    permission_overwrites: Absent,
    parent_id: Absent,
    rtc_region: Absent,
    video_quality_mode: Absent,
    default_auto_archive_duration: Absent,
    default_thread_rate_limit_per_user: None,
    flags: None,
  )
}

pub fn edit_guild_channel_body(payload: EditGuildChannel) -> Body {
  body.json(
    wire.entries([
      #("name", wire.put(wire.opt(payload.name), json.string)),
      #("type", wire.put(wire.opt(payload.type_), conversion_to_json)),
      #("position", wire.put(payload.position, json.int)),
      #("topic", wire.put(payload.topic, json.string)),
      #("nsfw", wire.put(payload.nsfw, json.bool)),
      #("rate_limit_per_user", seconds(payload.rate_limit_per_user)),
      #("bitrate", wire.put(payload.bitrate, json.int)),
      #("user_limit", wire.put(payload.user_limit, json.int)),
      #("permission_overwrites", overwrites(payload.permission_overwrites)),
      #("parent_id", wire.put(payload.parent_id, id.to_json)),
      #("rtc_region", wire.put(payload.rtc_region, json.string)),
      #("video_quality_mode", quality(payload.video_quality_mode)),
      #(
        "default_auto_archive_duration",
        archive(payload.default_auto_archive_duration),
      ),
      #(
        "default_thread_rate_limit_per_user",
        seconds(wire.opt(payload.default_thread_rate_limit_per_user)),
      ),
      #("flags", wire.put(wire.opt(payload.flags), settable_flags_to_json)),
    ]),
  )
}

/// Whether this edit touches `name` or `topic`. Discord meters those two at
/// two per ten minutes and says nothing about it in the headers, so
/// `edit` asks for the answer and the payload is what
/// holds it. Clearing the topic counts: it is still a topic edit.
pub fn edits_name_or_topic(payload: EditGuildChannel) -> Bool {
  payload.name != None || !field.is_absent(payload.topic)
}

/// `PATCH /channels/{id}` for a thread, which shares the URL with
/// `EditGuildChannel` and nothing else.
pub type EditThread {
  EditThread(
    name: Option(String),
    archived: Option(Bool),
    auto_archive_duration: Option(ThreadAutoArchiveDuration),
    locked: Option(Bool),
    /// Private threads only.
    invitable: Option(Bool),
    rate_limit_per_user: Field(Int),
    /// PINNED, the whole of what `flags` can say on a thread. A post in a
    /// forum or media channel only.
    pinned: Option(Bool),
  )
}

pub fn new_edit_thread() -> EditThread {
  EditThread(
    name: None,
    archived: None,
    auto_archive_duration: None,
    locked: None,
    invitable: None,
    rate_limit_per_user: Absent,
    pinned: None,
  )
}

pub fn edit_thread_body(payload: EditThread) -> Body {
  body.json(
    wire.entries([
      #("name", wire.put(wire.opt(payload.name), json.string)),
      #("archived", wire.put(wire.opt(payload.archived), json.bool)),
      #(
        "auto_archive_duration",
        archive(wire.opt(payload.auto_archive_duration)),
      ),
      #("locked", wire.put(wire.opt(payload.locked), json.bool)),
      #("invitable", wire.put(wire.opt(payload.invitable), json.bool)),
      #("rate_limit_per_user", seconds(payload.rate_limit_per_user)),
      #("flags", wire.put(wire.opt(payload.pinned), pinned_to_json)),
    ]),
  )
}

/// `POST /channels/{c}/messages/{m}/threads`. The thread takes the source
/// message's id, so a message can only ever have one.
pub type CreateThreadFromMessage {
  CreateThreadFromMessage(
    name: String,
    auto_archive_duration: Option(ThreadAutoArchiveDuration),
    rate_limit_per_user: Option(Int),
  )
}

pub fn create_thread_from_message(name: String) -> CreateThreadFromMessage {
  CreateThreadFromMessage(
    name: name,
    auto_archive_duration: None,
    rate_limit_per_user: None,
  )
}

pub fn create_thread_from_message_body(
  payload: CreateThreadFromMessage,
) -> Body {
  body.json(
    wire.entries([
      #("name", Present(json.string(payload.name))),
      #(
        "auto_archive_duration",
        archive(wire.opt(payload.auto_archive_duration)),
      ),
      #("rate_limit_per_user", seconds(wire.opt(payload.rate_limit_per_user))),
    ]),
  )
}

/// `POST /channels/{c}/threads`. `type_` is required rather than optional:
/// leaving it out gets a private thread today, and Discord has said that
/// default will change.
pub type CreateThread {
  CreateThread(
    name: String,
    type_: ChannelType,
    auto_archive_duration: Option(ThreadAutoArchiveDuration),
    /// Private threads only.
    invitable: Option(Bool),
    rate_limit_per_user: Option(Int),
  )
}

pub fn create_thread(name: String, type_: ChannelType) -> CreateThread {
  CreateThread(
    name: name,
    type_: type_,
    auto_archive_duration: None,
    invitable: None,
    rate_limit_per_user: None,
  )
}

pub fn create_thread_body(payload: CreateThread) -> Body {
  body.json(
    wire.entries([
      #("name", Present(json.string(payload.name))),
      #("type", Present(channel_type_to_json(payload.type_))),
      #(
        "auto_archive_duration",
        archive(wire.opt(payload.auto_archive_duration)),
      ),
      #("invitable", wire.put(wire.opt(payload.invitable), json.bool)),
      #("rate_limit_per_user", seconds(wire.opt(payload.rate_limit_per_user))),
    ]),
  )
}

/// `Present([])` is an instruction here, so the empty array survives.
fn overwrites(value: Field(List(OverwriteBody))) -> Field(Json) {
  wire.put_list(value, overwrite_body_to_json)
}

fn archive(value: Field(ThreadAutoArchiveDuration)) -> Field(Json) {
  wire.put(value, auto_archive_duration_to_json)
}

fn seconds(value: Field(Int)) -> Field(Json) {
  wire.put(value, json.int)
}

fn quality(value: Field(VideoQualityMode)) -> Field(Json) {
  wire.put(value, video_quality_mode_to_json)
}

fn creatable_type_to_json(value: CreatableChannelType) -> Json {
  channel_type_to_json(case value {
    TextChannel -> GuildText
    VoiceChannel -> GuildVoice
    CategoryChannel -> GuildCategory
    AnnouncementChannel -> GuildAnnouncement
    StageChannel -> GuildStageVoice
    ForumChannel -> GuildForum
    MediaChannel -> GuildMedia
  })
}

fn conversion_to_json(value: ChannelConversion) -> Json {
  channel_type_to_json(case value {
    ToText -> GuildText
    ToAnnouncement -> GuildAnnouncement
  })
}

/// Only `RequireTag` and `HideMediaDownloadOptions` can be set on a create or
/// an edit; the read-only bits are stripped so an edit that round-trips flags
/// off a received channel does not send `PINNED` back.
fn settable_flags_to_json(chosen: List(ChannelFlag)) -> Json {
  let settable =
    list.filter(chosen, fn(flag) {
      case flag {
        RequireTag | HideMediaDownloadOptions -> True
        Pinned | IsSpoilerChannel -> False
      }
    })
  flags.to_json(channel_flags(of: settable))
}

/// PINNED on its own, or an empty bitfield to unpin.
fn pinned_to_json(pinned: Bool) -> Json {
  flags.to_json(case pinned {
    True -> channel_flags(of: [Pinned])
    False -> no_channel_flags
  })
}

// -- Endpoints ---------------------------------------------------------------

/// `GET /channels/{channel.id}`, as Get Channel.
pub fn get(channel: id.ChannelId) -> Call(Channel) {
  rest.get([seg.lit("channels"), seg.channel(channel)], rest.Decoded(decoder()))
}

/// `PATCH /channels/{channel.id}`, as Modify Channel, for a guild channel.
/// Name and topic edits carry an undocumented limit of two per ten minutes and
/// glyde cannot see inside the body, so `edits_name_or_topic` on the payload
/// puts the call in that sublimit rather than letting it spend the channel's
/// whole PATCH budget.
pub fn edit(channel: id.ChannelId, edit: EditGuildChannel) -> Call(Channel) {
  let call =
    rest.patch(
      [seg.lit("channels"), seg.channel(channel)],
      edit_guild_channel_body(edit),
      rest.Decoded(decoder()),
    )

  case edits_name_or_topic(edit) {
    True -> rest.split_bucket(call, "name-or-topic")
    False -> call
  }
}

/// `PATCH /channels/{channel.id}`, as Modify Channel, for a thread. Same route
/// as `edit`, different body.
pub fn edit_thread(thread: id.ChannelId, edit: EditThread) -> Call(Channel) {
  let call =
    rest.patch(
      [seg.lit("channels"), seg.channel(thread)],
      edit_thread_body(edit),
      rest.Decoded(decoder()),
    )

  // Name edits share the two-per-ten-minutes sublimit with guild channels.
  case edit.name {
    None -> call
    _ -> rest.split_bucket(call, "name-or-topic")
  }
}

/// `DELETE /channels/{channel.id}`, as Delete/Close Channel. Closes a DM and
/// deletes anything else. Answers with the channel it removed, not 204.
pub fn delete(channel: id.ChannelId) -> Call(Channel) {
  rest.delete(
    [seg.lit("channels"), seg.channel(channel)],
    rest.Decoded(decoder()),
  )
}

/// `POST /users/@me/channels`, as Create DM. Safe to call again: Discord
/// returns the existing channel when there is one. Discord also blocks a bot
/// that opens a lot of DM channels quickly from opening any more, so keep the
/// channel id rather than reopening before every message.
pub fn open_dm(recipient: id.UserId) -> Call(Channel) {
  rest.post(
    [seg.lit("users"), seg.lit("@me"), seg.lit("channels")],
    body.json([#("recipient_id", id.to_json(recipient))]),
    rest.Decoded(decoder()),
  )
}

/// `POST /channels/{channel.id}/typing`, as Trigger Typing Indicator. Lasts
/// ten seconds or until the bot posts.
pub fn typing(channel: id.ChannelId) -> Call(Nil) {
  rest.post(
    [seg.lit("channels"), seg.channel(channel), seg.lit("typing")],
    body.NoBody,
    rest.NoContent(Nil),
  )
}

/// `PUT /channels/{channel.id}/permissions/{overwrite.id}`, as Edit Channel
/// Permissions. The path id and the body's `type` come from the same
/// `OverwriteBody`, so a role id cannot go out under `type: 1`.
pub fn set_permission(
  channel: id.ChannelId,
  overwrite: OverwriteBody,
) -> Call(Nil) {
  rest.put(
    overwrite_at(channel, overwrite_id(overwrite)),
    overwrite_permissions_body(overwrite),
    rest.NoContent(Nil),
  )
}

/// `DELETE /channels/{channel.id}/permissions/{overwrite.id}`, as Delete
/// Channel Permission.
pub fn clear_permission(
  channel: id.ChannelId,
  overwrite: id.OverwriteId,
) -> Call(Nil) {
  rest.delete(overwrite_at(channel, overwrite), rest.NoContent(Nil))
}

/// `POST /channels/{channel.id}/messages/{message.id}/threads`, as Start
/// Thread From Message.
pub fn start_thread_from_message(
  channel: id.ChannelId,
  message: id.MessageId,
  thread: CreateThreadFromMessage,
) -> Call(Channel) {
  rest.post(
    [
      seg.lit("channels"),
      seg.channel(channel),
      seg.lit("messages"),
      seg.id(message),
      seg.lit("threads"),
    ],
    create_thread_from_message_body(thread),
    rest.Decoded(decoder()),
  )
}

/// `POST /channels/{channel.id}/threads`, as Start Thread Without Message.
/// The same path creates a forum or media post, with a different body.
pub fn start_thread(
  channel: id.ChannelId,
  thread: CreateThread,
) -> Call(Channel) {
  rest.post(
    [seg.lit("channels"), seg.channel(channel), seg.lit("threads")],
    create_thread_body(thread),
    rest.Decoded(decoder()),
  )
}

/// `PUT /channels/{thread.id}/thread-members/@me`, as Join Thread.
pub fn join_thread(thread: id.ChannelId) -> Call(Nil) {
  rest.put(
    thread_member_at(thread, seg.lit("@me")),
    body.NoBody,
    rest.NoContent(Nil),
  )
}

/// `DELETE /channels/{thread.id}/thread-members/@me`, as Leave Thread.
pub fn leave_thread(thread: id.ChannelId) -> Call(Nil) {
  rest.delete(thread_member_at(thread, seg.lit("@me")), rest.NoContent(Nil))
}

/// `PUT /channels/{thread.id}/thread-members/{user.id}`, as Add Thread Member.
pub fn add_thread_member(thread: id.ChannelId, user: id.UserId) -> Call(Nil) {
  rest.put(
    thread_member_at(thread, seg.id(user)),
    body.NoBody,
    rest.NoContent(Nil),
  )
}

/// `DELETE /channels/{thread.id}/thread-members/{user.id}`, as Remove Thread
/// Member.
pub fn remove_thread_member(
  thread: id.ChannelId,
  user: id.UserId,
) -> Call(Nil) {
  rest.delete(thread_member_at(thread, seg.id(user)), rest.NoContent(Nil))
}

/// `GET /channels/{channel.id}/threads/archived/public`, as List Public
/// Archived Threads. Newest archive first.
pub fn public_archived_threads(
  channel: id.ChannelId,
  before before: Option(TimeCursor),
  limit limit: Option(Int),
) -> Call(ThreadList) {
  archived_threads(channel, "public", before, limit)
}

/// `GET /channels/{channel.id}/threads/archived/private`, as List Private
/// Archived Threads. Needs MANAGE_THREADS.
pub fn private_archived_threads(
  channel: id.ChannelId,
  before before: Option(TimeCursor),
  limit limit: Option(Int),
) -> Call(ThreadList) {
  archived_threads(channel, "private", before, limit)
}

fn archived_threads(
  channel: id.ChannelId,
  visibility: String,
  before: Option(TimeCursor),
  limit: Option(Int),
) -> Call(ThreadList) {
  rest.get(
    [
      seg.lit("channels"),
      seg.channel(channel),
      seg.lit("threads"),
      seg.lit("archived"),
      seg.lit(visibility),
    ],
    rest.Decoded(thread_list_decoder()),
  )
  |> rest.query(
    list.flatten([
      query.opt("before", before, time_cursor_value),
      query.opt("limit", limit, query.number),
    ]),
  )
}

fn thread_member_at(thread: id.ChannelId, who: seg.Seg) -> List(seg.Seg) {
  [seg.lit("channels"), seg.channel(thread), seg.lit("thread-members"), who]
}

fn overwrite_at(
  channel: id.ChannelId,
  overwrite: id.OverwriteId,
) -> List(seg.Seg) {
  [
    seg.lit("channels"),
    seg.channel(channel),
    seg.lit("permissions"),
    seg.id(overwrite),
  ]
}
