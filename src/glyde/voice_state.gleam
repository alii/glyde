//// Who is in a voice channel. One per member on VOICE_STATE_UPDATE, and a
//// partial one per member inside GUILD_CREATE.

import gleam/dynamic/decode.{type Decoder}
import gleam/option.{type Option}
import glyde/id
import glyde/member.{type GuildMember}
import glyde/wire

pub type VoiceState {
  VoiceState(
    /// Absent on the partial states inside GUILD_CREATE.
    guild_id: Option(id.GuildId),
    /// `None` means the user left voice.
    channel_id: Option(id.ChannelId),
    user_id: id.UserId,
    /// Absent outside a guild.
    member: Option(GuildMember),
    /// Opaque, not a snowflake. The voice gateway wants it back verbatim.
    session_id: String,
    /// Server-side deafen, set by a moderator.
    deaf: Bool,
    /// Server-side mute, set by a moderator.
    mute: Bool,
    self_deaf: Bool,
    self_mute: Bool,
    /// The user is streaming with Go Live.
    self_stream: Bool,
    self_video: Bool,
    /// In a stage channel, this means the audience.
    suppress: Bool,
    /// ISO-8601, when the user raised their hand in a stage channel.
    request_to_speak_timestamp: Option(String),
  )
}

/// There is no leave event: a leave is a null `channel_id`.
pub fn has_left(state: VoiceState) -> Bool {
  state.channel_id == option.None
}

pub fn decoder() -> Decoder(VoiceState) {
  use guild_id <- wire.opt_field("guild_id", id.decoder())
  // Required and nullable, not optional: the null is the leave, so an absent
  // key must fail rather than read as one.
  use channel_id <- wire.nullable_field("channel_id", id.decoder())
  use user_id <- decode.field("user_id", id.decoder())
  use who <- wire.opt_field("member", member.decoder())
  // Required, unlike the flags below: the voice gateway is handed this
  // verbatim, and a default would forge a token that cannot work.
  use session_id <- decode.field("session_id", decode.string)
  use deaf <- wire.flag_field("deaf", False)
  use mute <- wire.flag_field("mute", False)
  use self_deaf <- wire.flag_field("self_deaf", False)
  use self_mute <- wire.flag_field("self_mute", False)
  use self_stream <- wire.flag_field("self_stream", False)
  use self_video <- wire.flag_field("self_video", False)
  use suppress <- wire.flag_field("suppress", False)
  use request_to_speak_timestamp <- wire.opt_field(
    "request_to_speak_timestamp",
    decode.string,
  )
  decode.success(VoiceState(
    guild_id:,
    channel_id:,
    user_id:,
    member: who,
    session_id:,
    deaf:,
    mute:,
    self_deaf:,
    self_mute:,
    self_stream:,
    self_video:,
    suppress:,
    request_to_speak_timestamp:,
  ))
}
