//// MESSAGE_* dispatches: deletes and reactions. Create and update decode
//// straight to `glyde/message`.

import gleam/dynamic/decode.{type Decoder}
import gleam/option.{type Option}
import glyde/emoji
import glyde/id
import glyde/member
import glyde/message.{type ReactionType}
import glyde/wire

/// Not a mirror of `ReactionRemove`: the add carries `member`,
/// `message_author_id` and `burst_colors`, and the remove carries none.
pub type ReactionAdd {
  ReactionAdd(
    user_id: id.UserId,
    channel_id: id.ChannelId,
    message_id: id.MessageId,
    guild_id: Option(id.GuildId),
    /// Present on a guild reaction, absent in a DM.
    member: Option(member.GuildMember),
    /// Partial: `id` and `name` only, and `id` is null for a unicode emoji.
    emoji: emoji.Emoji,
    /// Who wrote the message being reacted to. Absent on an older payload.
    message_author_id: Option(id.UserId),
    burst: Bool,
    /// Hex colours of the burst animation, as sent.
    burst_colors: List(String),
    type_: ReactionType,
  )
}

/// Three fields fewer than `ReactionAdd`, which is Discord's shape.
pub type ReactionRemove {
  ReactionRemove(
    user_id: id.UserId,
    channel_id: id.ChannelId,
    message_id: id.MessageId,
    guild_id: Option(id.GuildId),
    emoji: emoji.Emoji,
    burst: Bool,
    type_: ReactionType,
  )
}

/// MESSAGE_DELETE, as message id, channel id, guild id.
pub fn delete_decoder(
  build: fn(id.MessageId, id.ChannelId, Option(id.GuildId)) -> event,
) -> Decoder(event) {
  use message_id <- decode.field("id", id.decoder())
  use channel_id <- decode.field("channel_id", id.decoder())
  use guild_id <- wire.opt_field("guild_id", id.decoder())
  decode.success(build(message_id, channel_id, guild_id))
}

/// MESSAGE_DELETE_BULK, as message ids, channel id, guild id.
pub fn delete_bulk_decoder(
  build: fn(List(id.MessageId), id.ChannelId, Option(id.GuildId)) -> event,
) -> Decoder(event) {
  use ids <- decode.field("ids", decode.list(id.decoder()))
  use channel_id <- decode.field("channel_id", id.decoder())
  use guild_id <- wire.opt_field("guild_id", id.decoder())
  decode.success(build(ids, channel_id, guild_id))
}

pub fn reaction_add_decoder() -> Decoder(ReactionAdd) {
  use user_id <- decode.field("user_id", id.decoder())
  use channel_id <- decode.field("channel_id", id.decoder())
  use message_id <- decode.field("message_id", id.decoder())
  use guild_id <- wire.opt_field("guild_id", id.decoder())
  use reactor <- wire.opt_field("member", member.decoder())
  use reaction <- decode.field("emoji", emoji.decoder())
  use message_author_id <- wire.opt_field("message_author_id", id.decoder())
  use burst <- wire.flag_field("burst", False)
  use burst_colors <- wire.list_field("burst_colors", decode.string)
  use type_ <- reaction_type_field()
  decode.success(ReactionAdd(
    user_id:,
    channel_id:,
    message_id:,
    guild_id:,
    member: reactor,
    emoji: reaction,
    message_author_id:,
    burst:,
    burst_colors:,
    type_:,
  ))
}

/// No `member`, no `message_author_id`, no `burst_colors`. Copying the add
/// decoder keeps them, and `decode.field` on an absent key drops the event.
pub fn reaction_remove_decoder() -> Decoder(ReactionRemove) {
  use user_id <- decode.field("user_id", id.decoder())
  use channel_id <- decode.field("channel_id", id.decoder())
  use message_id <- decode.field("message_id", id.decoder())
  use guild_id <- wire.opt_field("guild_id", id.decoder())
  use reaction <- decode.field("emoji", emoji.decoder())
  use burst <- wire.flag_field("burst", False)
  use type_ <- reaction_type_field()
  decode.success(ReactionRemove(
    user_id:,
    channel_id:,
    message_id:,
    guild_id:,
    emoji: reaction,
    burst:,
    type_:,
  ))
}

/// MESSAGE_REACTION_REMOVE_ALL, as channel id, message id, guild id.
pub fn reaction_remove_all_decoder(
  build: fn(id.ChannelId, id.MessageId, Option(id.GuildId)) -> event,
) -> Decoder(event) {
  use channel_id <- decode.field("channel_id", id.decoder())
  use message_id <- decode.field("message_id", id.decoder())
  use guild_id <- wire.opt_field("guild_id", id.decoder())
  decode.success(build(channel_id, message_id, guild_id))
}

/// MESSAGE_REACTION_REMOVE_EMOJI, as channel id, message id, guild id, emoji.
pub fn reaction_remove_emoji_decoder(
  build: fn(id.ChannelId, id.MessageId, Option(id.GuildId), emoji.Emoji) ->
    event,
) -> Decoder(event) {
  use channel_id <- decode.field("channel_id", id.decoder())
  use message_id <- decode.field("message_id", id.decoder())
  use guild_id <- wire.opt_field("guild_id", id.decoder())
  use reaction <- decode.field("emoji", emoji.decoder())
  decode.success(build(channel_id, message_id, guild_id, reaction))
}

/// The reaction `type`, which an older payload omits. Only absence defaults:
/// a `type` that is present and unmodelled fails the decode, so a burst
/// reaction is never handed to a host as a normal one.
fn reaction_type_field(
  next: fn(ReactionType) -> Decoder(final),
) -> Decoder(final) {
  wire.type_or(
    "type",
    message.reaction_type_from_int,
    message.NormalReaction,
    "ReactionType",
    next,
  )
}
