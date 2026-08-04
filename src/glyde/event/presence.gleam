//// Who is doing what: TYPING_START today. USER_UPDATE decodes straight to
//// `glyde/user`, and PRESENCE_UPDATE is not modelled yet.

import gleam/dynamic/decode.{type Decoder}
import gleam/option.{type Option}
import glyde/id
import glyde/member
import glyde/wire

pub type TypingStart {
  TypingStart(
    channel_id: id.ChannelId,
    guild_id: Option(id.GuildId),
    user_id: id.UserId,
    /// UNIX SECONDS. Not milliseconds and not ISO-8601, and the only unix
    /// timestamp anywhere in the dispatch surface.
    timestamp: Int,
    /// Present on a guild channel, absent in a DM.
    member: Option(member.GuildMember),
  )
}

pub fn typing_start_decoder() -> Decoder(TypingStart) {
  use channel_id <- decode.field("channel_id", id.decoder())
  use guild_id <- wire.opt_field("guild_id", id.decoder())
  use user_id <- decode.field("user_id", id.decoder())
  use timestamp <- decode.field("timestamp", wire.integer())
  use typist <- wire.opt_field("member", member.decoder())
  decode.success(TypingStart(
    channel_id:,
    guild_id:,
    user_id:,
    timestamp:,
    member: typist,
  ))
}
