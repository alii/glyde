//// GUILD_* dispatches: the guild coming and going, its members, roles, bans
//// and emojis. Decoders take the constructor to build, so `Event` stays out.

import gleam/dynamic/decode.{type Decoder}
import gleam/option.{type Option}
import glyde/emoji
import glyde/guild
import glyde/id
import glyde/member
import glyde/role
import glyde/user
import glyde/wire

pub type MembersChunk {
  MembersChunk(
    guild_id: id.GuildId,
    /// At most 1000. glyde does not reassemble the chunks: count them with
    /// `chunk_index` and `chunk_count`.
    members: List(member.GuildMember),
    chunk_index: Int,
    chunk_count: Int,
    /// Echoes the request back, so this is whatever the caller sent, a real
    /// snowflake or not.
    not_found: List(id.UserId),
    /// Absent when the request's nonce was over 32 bytes, which Discord drops
    /// silently.
    nonce: Option(String),
  )
}

/// GUILD_CREATE. On the VALUE of `unavailable`: `true` is a two-key stub,
/// absent or `false` is the whole guild. GUILD_DELETE goes on the key instead.
pub fn create_decoder(
  available available: fn(guild.Guild) -> event,
  unavailable unavailable: fn(id.GuildId) -> event,
) -> Decoder(event) {
  use maybe <- decode.then(guild.maybe_available_decoder())
  decode.success(case maybe {
    guild.AvailableGuild(up) -> available(up)
    guild.OfflineGuild(offline) -> unavailable(offline)
  })
}

/// GUILD_DELETE. On the PRESENCE of `unavailable`, not its value. The two are
/// different events: an outage stays in the cache, a removal leaves it.
pub fn delete_decoder(
  outage outage: fn(id.GuildId) -> event,
  removed removed: fn(id.GuildId) -> event,
) -> Decoder(event) {
  use departure <- decode.then(guild.departure_decoder())
  decode.success(case departure {
    guild.GuildOutage(offline) -> outage(offline)
    guild.GuildGone(gone) -> removed(gone)
  })
}

/// GUILD_MEMBER_ADD and GUILD_MEMBER_UPDATE: `d` is the member object itself
/// with `guild_id` bolted on.
pub fn member_decoder(
  build: fn(id.GuildId, member.GuildMember) -> event,
) -> Decoder(event) {
  use guild_id <- decode.field("guild_id", id.decoder())
  use found <- decode.then(member.decoder())
  decode.success(build(guild_id, found))
}

/// GUILD_MEMBER_REMOVE, GUILD_BAN_ADD and GUILD_BAN_REMOVE, which share the
/// shape `{"guild_id": .., "user": {..}}`.
pub fn user_decoder(
  build: fn(id.GuildId, user.User) -> event,
) -> Decoder(event) {
  keyed_decoder("user", user.decoder(), build)
}

/// GUILD_ROLE_CREATE and GUILD_ROLE_UPDATE.
pub fn role_decoder(
  build: fn(id.GuildId, role.Role) -> event,
) -> Decoder(event) {
  keyed_decoder("role", role.decoder(), build)
}

pub fn role_delete_decoder(
  build: fn(id.GuildId, id.RoleId) -> event,
) -> Decoder(event) {
  use guild_id <- decode.field("guild_id", id.decoder())
  use role_id <- decode.field("role_id", id.decoder())
  decode.success(build(guild_id, role_id))
}

/// `emojis` is required, unlike nearly every other list here: the array
/// replaces the guild's whole set, so a missing key must not read as `[]`.
pub fn emojis_update_decoder(
  build: fn(id.GuildId, List(emoji.GuildEmoji)) -> event,
) -> Decoder(event) {
  use guild_id <- decode.field("guild_id", id.decoder())
  use emojis <- decode.field("emojis", decode.list(emoji.guild_emoji_decoder()))
  decode.success(build(guild_id, emojis))
}

pub fn members_chunk_decoder() -> Decoder(MembersChunk) {
  use guild_id <- decode.field("guild_id", id.decoder())
  // Required, unlike `not_found`: a chunk with no `members` key is malformed,
  // and reading it as empty loses members with no sign anything went wrong.
  use members <- decode.field("members", decode.list(member.decoder()))
  use chunk_index <- decode.field("chunk_index", wire.integer())
  use chunk_count <- decode.field("chunk_count", wire.integer())
  use not_found <- wire.list_field("not_found", id.lenient_decoder())
  use nonce <- wire.opt_field("nonce", decode.string)
  decode.success(MembersChunk(
    guild_id:,
    members:,
    chunk_index:,
    chunk_count:,
    not_found:,
    nonce:,
  ))
}

/// For the events shaped `{"guild_id": .., "<key>": {..}}`.
fn keyed_decoder(
  key: String,
  inner: Decoder(a),
  build: fn(id.GuildId, a) -> event,
) -> Decoder(event) {
  use guild_id <- decode.field("guild_id", id.decoder())
  use value <- decode.field(key, inner)
  decode.success(build(guild_id, value))
}
