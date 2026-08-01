//// Bodies for creating and editing channels and threads.
////
//// The enums here are send-only, so none of them has an unknown tail: a value
//// Discord does not know is a 400, not something to survive. Each holds the
//// values its endpoint accepts and nothing else, and `glyde/model/channel`
//// stays the one place the wire numbers live.
////
//// `PATCH /channels/{id}` takes two structurally different bodies at one URL,
//// so a guild channel and a thread are two types with an encoder each. On an
//// edit `null` is an instruction, which is what `Field` is for; a create has
//// nothing to clear, so it uses `Option`.

import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None}
import glyde/field.{type Field, Absent, Present}
import glyde/flags
import glyde/id
import glyde/model/channel
import glyde/permissions.{type Permissions}
import glyde/rest/body.{type Body}
import glyde/wire

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

/// The kinds `POST /channels/{c}/threads` creates.
pub type ThreadType {
  PublicThread
  PrivateThread
  AnnouncementThread
}

pub type VideoQuality {
  AutoQuality
  FullQuality
}

/// Minutes, and Discord takes only these four.
pub type AutoArchiveDuration {
  OneHour
  OneDay
  ThreeDays
  OneWeek
}

/// The two channel flags a create or an edit may set. The rest of Discord's
/// channel-flags table is read-only: PINNED belongs to a forum post rather
/// than a channel, and IS_SPOILER_CHANNEL is not settable over the API at all.
pub type SettableChannelFlag {
  /// Every post in the forum must carry a tag. Forum channels only.
  RequireTag
  /// Media channels only.
  HideMediaDownloadOptions
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
    type_: channel.OverwriteType,
    allow: Permissions,
    deny: Permissions,
  )
}

pub fn role_overwrite(role: id.RoleId) -> OverwriteBody {
  OverwriteBody(
    id: id.retag(role, to: id.overwrite),
    type_: channel.RoleOverwrite,
    allow: permissions.none(),
    deny: permissions.none(),
  )
}

pub fn member_overwrite(user: id.UserId) -> OverwriteBody {
  OverwriteBody(
    id: id.retag(user, to: id.overwrite),
    type_: channel.MemberOverwrite,
    allow: permissions.none(),
    deny: permissions.none(),
  )
}

/// An overwrite read off a channel, ready to send back.
/// `permission_overwrites` replaces the whole array, so an edit that changes
/// one entry has to send the others back with it, and they arrive as
/// `model/channel.PermissionOverwrite`.
///
/// `Error` carries the number Discord sent for a type this build does not
/// know: echoing it back would tell Discord the id means something else.
pub fn overwrite_from(
  overwrite: channel.PermissionOverwrite,
) -> Result(OverwriteBody, Int) {
  case overwrite.type_ {
    channel.RoleOverwrite | channel.MemberOverwrite ->
      Ok(OverwriteBody(
        id: overwrite.id,
        type_: overwrite.type_,
        allow: overwrite.allow,
        deny: overwrite.deny,
      ))
    channel.UnknownOverwriteType(raw) -> Error(raw)
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
    #("type", channel.overwrite_type_to_json(payload.type_)),
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
    /// Discord defaults this to a text channel.
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
    video_quality_mode: Option(VideoQuality),
    /// Minutes.
    default_auto_archive_duration: Option(AutoArchiveDuration),
    default_thread_rate_limit_per_user: Option(Int),
    /// The complete set, not an addition: Discord reads `flags` as the whole
    /// bitfield, so a flag left out of the list is off.
    flags: Option(List(SettableChannelFlag)),
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

/// `PATCH /channels/{id}` for a guild channel. Group DM edits are out of v1.
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
    video_quality_mode: Field(VideoQuality),
    default_auto_archive_duration: Field(AutoArchiveDuration),
    default_thread_rate_limit_per_user: Option(Int),
    /// The complete set, not an addition: Discord reads `flags` as the whole
    /// bitfield, so a flag left out of the list is off.
    flags: Option(List(SettableChannelFlag)),
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
/// `api/channel.edit_channel` asks for the answer and the payload is what
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
    auto_archive_duration: Option(AutoArchiveDuration),
    locked: Option(Bool),
    /// Private threads only.
    invitable: Option(Bool),
    rate_limit_per_user: Field(Int),
    /// PINNED, the whole of what `flags` can say on a thread. A post in a
    /// forum or media channel only.
    pinned: Option(Bool),
  )
}

pub fn edit_thread() -> EditThread {
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
    auto_archive_duration: Option(AutoArchiveDuration),
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
    type_: ThreadType,
    auto_archive_duration: Option(AutoArchiveDuration),
    /// Private threads only.
    invitable: Option(Bool),
    rate_limit_per_user: Option(Int),
  )
}

pub fn create_thread(name: String, type_: ThreadType) -> CreateThread {
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
      #("type", Present(thread_type_to_json(payload.type_))),
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

fn archive(value: Field(AutoArchiveDuration)) -> Field(Json) {
  wire.put(value, auto_archive_duration_to_json)
}

fn seconds(value: Field(Int)) -> Field(Json) {
  wire.put(value, json.int)
}

fn quality(value: Field(VideoQuality)) -> Field(Json) {
  wire.put(value, video_quality_to_json)
}

fn creatable_type_to_json(value: CreatableChannelType) -> Json {
  channel.channel_type_to_json(case value {
    TextChannel -> channel.GuildText
    VoiceChannel -> channel.GuildVoice
    CategoryChannel -> channel.GuildCategory
    AnnouncementChannel -> channel.GuildAnnouncement
    StageChannel -> channel.GuildStageVoice
    ForumChannel -> channel.GuildForum
    MediaChannel -> channel.GuildMedia
  })
}

fn conversion_to_json(value: ChannelConversion) -> Json {
  channel.channel_type_to_json(case value {
    ToText -> channel.GuildText
    ToAnnouncement -> channel.GuildAnnouncement
  })
}

fn thread_type_to_json(value: ThreadType) -> Json {
  channel.channel_type_to_json(case value {
    PublicThread -> channel.PublicThread
    PrivateThread -> channel.PrivateThread
    AnnouncementThread -> channel.AnnouncementThread
  })
}

fn video_quality_to_json(value: VideoQuality) -> Json {
  channel.video_quality_mode_to_json(case value {
    AutoQuality -> channel.AutoQuality
    FullQuality -> channel.FullQuality
  })
}

fn auto_archive_duration_to_json(value: AutoArchiveDuration) -> Json {
  channel.auto_archive_duration_to_json(case value {
    OneHour -> channel.OneHour
    OneDay -> channel.OneDay
    ThreeDays -> channel.ThreeDays
    OneWeek -> channel.OneWeek
  })
}

/// The bits come from the model's flag table so the numbers are written down
/// once.
fn settable_flags_to_json(chosen: List(SettableChannelFlag)) -> Json {
  flags.to_json(channel.channel_flags(of: list.map(chosen, settable_flag)))
}

fn settable_flag(flag: SettableChannelFlag) -> channel.ChannelFlag {
  case flag {
    RequireTag -> channel.RequireTag
    HideMediaDownloadOptions -> channel.HideMediaDownloadOptions
  }
}

/// PINNED on its own, or an empty bitfield to unpin.
fn pinned_to_json(pinned: Bool) -> Json {
  flags.to_json(case pinned {
    True -> channel.channel_flags(of: [channel.Pinned])
    False -> channel.no_channel_flags
  })
}
