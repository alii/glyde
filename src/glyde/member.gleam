//// A guild member: the account plus everything true of it in one guild only.
////
//// `roles` is the only field every wire shape carries. Interaction resolved
//// data drops `user`, `deaf` and `mute`; GUILD_MEMBER_UPDATE drops `flags`.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import glyde/field.{type Field, Absent}
import glyde/flags.{type Flags}
import glyde/id
import glyde/permissions
import glyde/rest/body.{type Body}
import glyde/rest/image.{type ImageData}
import glyde/user
import glyde/wire

pub type GuildMember {
  GuildMember(
    /// Absent in resolved data, where the id is the map key, and on the
    /// partial member in MESSAGE_CREATE and MESSAGE_UPDATE.
    user: Option(user.User),
    nick: Option(String),
    /// Per-guild avatar hash, not the account one.
    avatar: Option(String),
    banner: Option(String),
    roles: List(id.RoleId),
    /// Null means the member was invited as a guest. Absent on some partials.
    joined_at: Option(String),
    /// ISO-8601, when the member started boosting the guild.
    premium_since: Option(String),
    deaf: Option(Bool),
    mute: Option(Bool),
    /// `None` on the shapes that drop the key, GUILD_MEMBER_UPDATE included.
    /// Defaulting it to 0 would let a cache merge clear flags nobody cleared.
    flags: Option(GuildMemberFlags),
    /// Only the GUILD_ events send this, so absent is not the same as false.
    pending: Option(Bool),
    /// Interactions only, and scoped to the interaction's channel, not the
    /// guild.
    permissions: Option(permissions.Permissions),
    /// ISO-8601 expiry of a timeout. A past time is not a timeout either, so
    /// compare it against the clock instead of testing for null.
    communication_disabled_until: Option(String),
  )
}

pub type GuildMemberFlags =
  Flags(GuildMemberFlag)

pub type GuildMemberFlag {
  DidRejoin
  CompletedOnboarding
  BypassesVerification
  StartedOnboarding
  IsGuest
  StartedHomeActions
  CompletedHomeActions
  AutomodQuarantinedUsername
  DmSettingsUpsellAcknowledged
  AutomodQuarantinedGuildTag
}

/// Discord's member-flags table. Bit 8 is a hole, so these are not an ordinal.
fn member_flag_bit(flag: GuildMemberFlag) -> Int {
  case flag {
    DidRejoin -> 1
    CompletedOnboarding -> 2
    BypassesVerification -> 4
    StartedOnboarding -> 8
    IsGuest -> 16
    StartedHomeActions -> 32
    CompletedHomeActions -> 64
    AutomodQuarantinedUsername -> 128
    DmSettingsUpsellAcknowledged -> 512
    AutomodQuarantinedGuildTag -> 1024
  }
}

pub const no_member_flags: GuildMemberFlags = flags.none

/// Build the `flags` an edit sends. Anything decoded off the wire should be
/// edited with `with_flag` instead, so bits this build cannot name survive.
pub fn member_flags(of chosen: List(GuildMemberFlag)) -> GuildMemberFlags {
  list.fold(chosen, no_member_flags, with_flag)
}

pub fn has_flag(bits: GuildMemberFlags, flag: GuildMemberFlag) -> Bool {
  flags.has_bit(bits, member_flag_bit(flag))
}

pub fn with_flag(
  bits: GuildMemberFlags,
  flag: GuildMemberFlag,
) -> GuildMemberFlags {
  flags.set_bit(bits, member_flag_bit(flag))
}

pub fn without_flag(
  bits: GuildMemberFlags,
  flag: GuildMemberFlag,
) -> GuildMemberFlags {
  flags.clear_bit(bits, member_flag_bit(flag))
}

/// The per-guild nickname, then whatever the account itself answers.
pub fn display_name(member: GuildMember) -> Option(String) {
  case member.nick {
    Some(nick) -> Some(nick)
    None -> option.then(member.user, user.display_name)
  }
}

pub fn decoder() -> Decoder(GuildMember) {
  use account <- wire.opt_field("user", user.decoder())
  use nick <- wire.opt_field("nick", decode.string)
  use avatar <- wire.opt_field("avatar", decode.string)
  use banner <- wire.opt_field("banner", decode.string)
  use roles <- wire.list_field("roles", id.decoder())
  use joined_at <- wire.opt_field("joined_at", decode.string)
  use premium_since <- wire.opt_field("premium_since", decode.string)
  use deaf <- wire.opt_field("deaf", decode.bool)
  use mute <- wire.opt_field("mute", decode.bool)
  use decoded_flags <- wire.opt_field("flags", flags.decoder())
  use pending <- wire.opt_field("pending", decode.bool)
  use perms <- wire.opt_field("permissions", permissions.decoder())
  use communication_disabled_until <- wire.opt_field(
    "communication_disabled_until",
    decode.string,
  )
  decode.success(GuildMember(
    user: account,
    nick:,
    avatar:,
    banner:,
    roles:,
    joined_at:,
    premium_since:,
    deaf:,
    mute:,
    flags: decoded_flags,
    pending:,
    permissions: perms,
    communication_disabled_until:,
  ))
}

// -- Bodies for /guilds/{g}/members and /guilds/{g}/bans ---------------------

/// `PATCH /guilds/{g}/members/{u}`.
pub type EditGuildMember {
  EditGuildMember(
    /// `Null` resets the member to their username.
    nick: Field(String),
    /// The complete set of roles after the edit, not an addition.
    roles: Option(List(id.RoleId)),
    mute: Option(Bool),
    deaf: Option(Bool),
    /// `Null` disconnects the member from voice. Either way they have to
    /// already be in a voice channel.
    channel_id: Field(id.ChannelId),
    /// An ISO-8601 instant up to 28 days out, `Null` to lift the timeout. A
    /// target with ADMINISTRATOR or one that owns the guild is a 403.
    communication_disabled_until: Field(String),
    /// Discord's member-flags table marks this the only editable one, so it is
    /// the whole `flags` field. DID_REJOIN, COMPLETED_ONBOARDING and IS_GUEST
    /// are read-only and cannot be spelled here.
    bypasses_verification: Option(Bool),
  )
}

pub fn edit_guild_member() -> EditGuildMember {
  EditGuildMember(
    nick: Absent,
    roles: None,
    mute: None,
    deaf: None,
    channel_id: Absent,
    communication_disabled_until: Absent,
    bypasses_verification: None,
  )
}

pub fn edit_guild_member_body(payload: EditGuildMember) -> Body {
  body.json(
    wire.entries([
      #("nick", wire.put(payload.nick, json.string)),
      #("roles", wire.put_list(wire.opt(payload.roles), id.to_json)),
      #("mute", wire.put(wire.opt(payload.mute), json.bool)),
      #("deaf", wire.put(wire.opt(payload.deaf), json.bool)),
      #("channel_id", wire.put(payload.channel_id, id.to_json)),
      #(
        "communication_disabled_until",
        wire.put(payload.communication_disabled_until, json.string),
      ),
      #(
        "flags",
        wire.put(wire.opt(payload.bypasses_verification), verification_bypass),
      ),
    ]),
  )
}

/// `PATCH /guilds/{g}/members/@me`. Every field clears on null.
pub type EditCurrentMember {
  EditCurrentMember(
    nick: Field(String),
    avatar: Field(ImageData),
    banner: Field(ImageData),
    bio: Field(String),
  )
}

pub fn edit_current_member() -> EditCurrentMember {
  EditCurrentMember(nick: Absent, avatar: Absent, banner: Absent, bio: Absent)
}

pub fn edit_current_member_body(payload: EditCurrentMember) -> Body {
  body.json(
    wire.entries([
      #("nick", wire.put(payload.nick, json.string)),
      #("avatar", wire.put(payload.avatar, image.to_json)),
      #("banner", wire.put(payload.banner, image.to_json)),
      #("bio", wire.put(payload.bio, json.string)),
    ]),
  )
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

pub fn create_ban_body(payload: CreateBan) -> Body {
  body.json(
    wire.entries([
      #(
        "delete_message_seconds",
        wire.put(wire.opt(payload.delete_message_seconds), json.int),
      ),
    ]),
  )
}

/// BYPASSES_VERIFICATION, 1 << 2, on its own. The bit comes from this module's
/// flag table so the number is written down once.
fn verification_bypass(enabled: Bool) -> Json {
  flags.to_json(case enabled {
    True -> member_flags(of: [BypassesVerification])
    False -> no_member_flags
  })
}
