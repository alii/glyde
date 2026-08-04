//// VOICE_* dispatches. VOICE_STATE_UPDATE decodes straight to
//// `glyde/voice_state`.

import gleam/dynamic/decode.{type Decoder}
import gleam/option.{type Option}
import glyde/id
import glyde/wire

/// VOICE_SERVER_UPDATE, as token, guild id, endpoint.
pub fn server_update_decoder(
  build: fn(String, id.GuildId, Option(String)) -> event,
) -> Decoder(event) {
  use token <- decode.field("token", decode.string)
  use guild_id <- decode.field("guild_id", id.decoder())
  // Required and nullable: the null says the voice server went away, so an
  // absent key must fail rather than forge that.
  use endpoint <- wire.nullable_field("endpoint", decode.string)
  decode.success(build(token, guild_id, endpoint))
}
