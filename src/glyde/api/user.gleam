//// A user id is never a major parameter, so every `/users/...` route shares
//// one bucket per method and path.

import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import glyde/id
import glyde/model/channel.{type Channel}
import glyde/model/guild.{type UserGuild}
import glyde/model/member.{type GuildMember}
import glyde/model/user.{type CurrentUser, type User}
import glyde/rest.{type Call}
import glyde/rest/body.{type Body}
import glyde/rest/query
import glyde/rest/seg

/// `GET /users/@me`, the bot's own user. A `CurrentUser`, which carries
/// `verified` and `email` that a plain `User` does not have.
pub fn get_current_user() -> Call(CurrentUser) {
  rest.get(
    [seg.lit("users"), seg.lit("@me")],
    rest.Decoded(user.current_user_decoder()),
  )
}

pub fn get_user(user: id.UserId) -> Call(User) {
  rest.get([seg.lit("users"), seg.id(user)], rest.Decoded(user.decoder()))
}

/// `POST /users/@me/channels`, opening a DM. Safe to call again: Discord
/// returns the existing channel when there is one. Discord also blocks a bot
/// that opens a lot of DM channels quickly from opening any more, so keep the
/// channel id rather than reopening before every message. Build the body with
/// `payload/user.create_dm_body`.
pub fn create_dm(body: Body) -> Call(Channel) {
  rest.post(
    [seg.lit("users"), seg.lit("@me"), seg.lit("channels")],
    body,
    rest.Decoded(channel.decoder()),
  )
}

/// Which way `get_current_user_guilds` pages, by guild id. One value, because
/// Discord does not say what it does with both.
pub type GuildCursor {
  /// Guilds whose id sorts below this one.
  GuildsBefore(id.GuildId)
  /// Guilds whose id sorts above this one.
  GuildsAfter(id.GuildId)
}

/// `GET /users/@me/guilds`, the guilds the bot is in. A `UserGuild` and not a
/// `Guild`: the answer is nine keys, and `owner` and `permissions` come from
/// nowhere else. Discord caps `limit` at 200 and defaults it to 200.
pub fn get_current_user_guilds(
  cursor cursor: Option(GuildCursor),
  limit limit: Option(Int),
  with_counts with_counts: Bool,
) -> Call(List(UserGuild)) {
  rest.get(
    [seg.lit("users"), seg.lit("@me"), seg.lit("guilds")],
    rest.Decoded(decode.list(guild.user_guild_decoder())),
  )
  |> rest.query(
    list.flatten([
      guild_cursor_param(cursor),
      query.opt("limit", limit, query.number),
      query.one("with_counts", query.flag(with_counts)),
    ]),
  )
}

fn guild_cursor_param(cursor: Option(GuildCursor)) -> List(query.Param) {
  case cursor {
    None -> []
    Some(GuildsBefore(guild)) -> query.one("before", query.snowflake(guild))
    Some(GuildsAfter(guild)) -> query.one("after", query.snowflake(guild))
  }
}

/// `GET /users/@me/guilds/{guild.id}/member`, the bot's own membership of one
/// guild. The guild is a plain segment here, not the major parameter: this is
/// a `/users` route, and every one of them shares a bucket.
pub fn get_current_user_guild_member(guild: id.GuildId) -> Call(GuildMember) {
  rest.get(
    guild_at(guild) |> list.append([seg.lit("member")]),
    rest.Decoded(member.decoder()),
  )
}

/// `DELETE /users/@me/guilds/{guild.id}`, leaving a guild. Discord answers 204
/// whether or not the bot was in it.
pub fn leave_guild(guild: id.GuildId) -> Call(Nil) {
  rest.delete(guild_at(guild), rest.NoContent(Nil))
}

fn guild_at(guild: id.GuildId) -> List(seg.Seg) {
  [seg.lit("users"), seg.lit("@me"), seg.lit("guilds"), seg.id(guild)]
}
