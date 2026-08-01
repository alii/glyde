//// Bodies for the endpoints under `/guilds/{g}/members` and
//// `/guilds/{g}/bans`.

import gleam/json.{type Json}
import gleam/option.{type Option, None}
import glyde/field.{type Field, Absent}
import glyde/flags
import glyde/id
import glyde/model/member
import glyde/rest/body.{type Body}
import glyde/rest/image.{type ImageData}
import glyde/wire

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

/// BYPASSES_VERIFICATION, 1 << 2, on its own. The bit comes from the model's
/// flag table so the number is written down once.
fn verification_bypass(enabled: Bool) -> Json {
  flags.to_json(case enabled {
    True -> member.member_flags(of: [member.BypassesVerification])
    False -> member.no_member_flags
  })
}
