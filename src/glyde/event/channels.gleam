//// CHANNEL_* and THREAD_* dispatches. Create, update and delete decode
//// straight to `glyde/channel`; these are the two that are not a channel.

import gleam/dynamic/decode.{type Decoder}
import gleam/option.{type Option}
import glyde/channel
import glyde/id
import glyde/wire

/// CHANNEL_PINS_UPDATE, as guild id, channel id, last pin timestamp.
pub fn pins_update_decoder(
  build: fn(Option(id.GuildId), id.ChannelId, Option(String)) -> event,
) -> Decoder(event) {
  use guild_id <- wire.opt_field("guild_id", id.decoder())
  use channel_id <- decode.field("channel_id", id.decoder())
  use last_pin_timestamp <- wire.opt_field("last_pin_timestamp", decode.string)
  decode.success(build(guild_id, channel_id, last_pin_timestamp))
}

/// THREAD_DELETE, as thread id, guild id, parent id, type. Four keys that the
/// channel decoder would also accept, since a channel needs only two.
pub fn thread_delete_decoder(
  build: fn(id.ChannelId, id.GuildId, Option(id.ChannelId), channel.ChannelType) ->
    event,
) -> Decoder(event) {
  use thread_id <- decode.field("id", id.decoder())
  use guild_id <- decode.field("guild_id", id.decoder())
  use parent_id <- wire.opt_field("parent_id", id.decoder())
  use type_ <- decode.field("type", channel.channel_type_decoder())
  decode.success(build(thread_id, guild_id, parent_id, type_))
}
