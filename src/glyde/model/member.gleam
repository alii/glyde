//// A guild member: the account plus everything true of it in one guild only.
////
//// `roles` is the only field every wire shape carries. Interaction resolved
//// data drops `user`, `deaf` and `mute`; GUILD_MEMBER_UPDATE drops `flags`.

import gleam/dynamic/decode.{type Decoder}
import gleam/list
import gleam/option.{type Option, None, Some}
import glyde/flags.{type Flags}
import glyde/id
import glyde/model/user
import glyde/permissions
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
