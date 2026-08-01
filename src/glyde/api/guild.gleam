//// The guild itself, its channels, active threads, bans, members and roles.
////
//// Everything here takes the guild major parameter, so two guilds get
//// independent buckets for the same endpoint.

import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import glyde/id
import glyde/model/channel.{type ActiveThreads, type Channel}
import glyde/model/guild.{type Ban, type Guild}
import glyde/model/member.{type GuildMember}
import glyde/model/role.{type Role}
import glyde/rest.{type Call}
import glyde/rest/body.{type Body}
import glyde/rest/query
import glyde/rest/seg

/// `GET /guilds/{guild.id}`. `with_counts` adds `approximate_member_count`
/// and `approximate_presence_count`, absent without it.
pub fn get_guild(
  guild: id.GuildId,
  with_counts with_counts: Bool,
) -> Call(Guild) {
  rest.get([seg.lit("guilds"), seg.guild(guild)], rest.Decoded(guild.decoder()))
  |> rest.query(query.one("with_counts", query.flag(with_counts)))
}

/// `GET /guilds/{guild.id}/channels`. Threads are not included.
pub fn get_channels(guild: id.GuildId) -> Call(List(Channel)) {
  rest.get(
    [seg.lit("guilds"), seg.guild(guild), seg.lit("channels")],
    rest.Decoded(decode.list(channel.decoder())),
  )
}

pub fn create_channel(guild: id.GuildId, body: Body) -> Call(Channel) {
  rest.post(
    [seg.lit("guilds"), seg.guild(guild), seg.lit("channels")],
    body,
    rest.Decoded(channel.decoder()),
  )
}

/// `GET /guilds/{guild.id}/threads/active`, every active thread the bot can
/// see. Unpaged, so the answer is an `ActiveThreads` and not a `ThreadList`.
pub fn get_active_threads(guild: id.GuildId) -> Call(ActiveThreads) {
  rest.get(
    [seg.lit("guilds"), seg.guild(guild), seg.lit("threads"), seg.lit("active")],
    rest.Decoded(channel.active_threads_decoder()),
  )
}

/// Which way `get_bans` pages, by user id. One value, not two optional fields:
/// Discord's Get Guild Bans table says `before` wins when both are sent, so a
/// `before` left over from the previous page would silently page backwards.
pub type BanCursor {
  /// Bans on users whose id sorts below this one.
  BansBefore(id.UserId)
  /// Bans on users whose id sorts above this one.
  BansAfter(id.UserId)
}

/// `GET /guilds/{guild.id}/bans`. Discord caps `limit` at 1000.
pub fn get_bans(
  guild: id.GuildId,
  cursor cursor: Option(BanCursor),
  limit limit: Option(Int),
) -> Call(List(Ban)) {
  rest.get(bans_at(guild), rest.Decoded(decode.list(guild.ban_decoder())))
  |> rest.query(
    list.flatten([
      ban_cursor_param(cursor),
      query.opt("limit", limit, query.number),
    ]),
  )
}

fn ban_cursor_param(cursor: Option(BanCursor)) -> List(query.Param) {
  case cursor {
    None -> []
    Some(BansBefore(user)) -> query.one("before", query.snowflake(user))
    Some(BansAfter(user)) -> query.one("after", query.snowflake(user))
  }
}

/// `GET /guilds/{guild.id}/bans/{user.id}`, which answers 404 when the user
/// is not banned rather than an empty success.
pub fn get_ban(guild: id.GuildId, user: id.UserId) -> Call(Ban) {
  rest.get(ban_at(guild, user), rest.Decoded(guild.ban_decoder()))
}

/// `PUT /guilds/{guild.id}/bans/{user.id}`. `delete_message_seconds` in the
/// body also deletes the user's recent messages, up to seven days back.
pub fn create_ban(guild: id.GuildId, user: id.UserId, body: Body) -> Call(Nil) {
  rest.put(ban_at(guild, user), body, rest.NoContent(Nil))
}

pub fn remove_ban(guild: id.GuildId, user: id.UserId) -> Call(Nil) {
  rest.delete(ban_at(guild, user), rest.NoContent(Nil))
}

/// `GET /guilds/{guild.id}/members`, paged by user id. Without the privileged
/// GUILD_MEMBERS intent Discord answers 403, not a short list: the short list
/// is GUILD_CREATE's behaviour, over on `model/guild.GatewayCreate.members`.
/// Discord caps `limit` at 1000 and defaults it to 1.
pub fn get_members(
  guild: id.GuildId,
  after after: Option(id.UserId),
  limit limit: Option(Int),
) -> Call(List(GuildMember)) {
  rest.get(members_at(guild), rest.Decoded(decode.list(member.decoder())))
  |> rest.query(
    list.flatten([
      query.opt("after", after, query.snowflake),
      query.opt("limit", limit, query.number),
    ]),
  )
}

pub fn get_member(guild: id.GuildId, user: id.UserId) -> Call(GuildMember) {
  rest.get(member_at(guild, user), rest.Decoded(member.decoder()))
}

/// `GET /guilds/{guild.id}/members/search`, a prefix match on username or
/// nickname. Discord caps `limit` at 1000 and defaults it to 1.
pub fn search_members(
  guild: id.GuildId,
  query search: String,
  limit limit: Option(Int),
) -> Call(List(GuildMember)) {
  rest.get(
    list.append(members_at(guild), [seg.lit("search")]),
    rest.Decoded(decode.list(member.decoder())),
  )
  |> rest.query(
    list.flatten([
      query.one("query", query.text(search)),
      query.opt("limit", limit, query.number),
    ]),
  )
}

/// `PATCH /guilds/{guild.id}/members/{user.id}`: nickname, roles, mute,
/// deafen, timeout, and moving them between voice channels.
pub fn edit_member(
  guild: id.GuildId,
  user: id.UserId,
  body: Body,
) -> Call(GuildMember) {
  rest.patch(member_at(guild, user), body, rest.Decoded(member.decoder()))
}

/// `PATCH /guilds/{guild.id}/members/@me`: nick, avatar, banner and bio, the
/// four `payload/member.EditCurrentMember` carries. `@me` is a literal, so
/// this is not the by-id bucket.
pub fn edit_current_member(guild: id.GuildId, body: Body) -> Call(GuildMember) {
  rest.patch(
    list.append(members_at(guild), [seg.lit("@me")]),
    body,
    rest.Decoded(member.decoder()),
  )
}

/// `DELETE /guilds/{guild.id}/members/{user.id}`, a kick.
pub fn kick_member(guild: id.GuildId, user: id.UserId) -> Call(Nil) {
  rest.delete(member_at(guild, user), rest.NoContent(Nil))
}

pub fn add_member_role(
  guild: id.GuildId,
  user: id.UserId,
  role: id.RoleId,
) -> Call(Nil) {
  rest.put(member_role_at(guild, user, role), body.NoBody, rest.NoContent(Nil))
}

pub fn remove_member_role(
  guild: id.GuildId,
  user: id.UserId,
  role: id.RoleId,
) -> Call(Nil) {
  rest.delete(member_role_at(guild, user, role), rest.NoContent(Nil))
}

pub fn get_roles(guild: id.GuildId) -> Call(List(Role)) {
  rest.get(roles_at(guild), rest.Decoded(decode.list(role.decoder())))
}

pub fn get_role(guild: id.GuildId, role: id.RoleId) -> Call(Role) {
  rest.get(role_at(guild, role), rest.Decoded(role.decoder()))
}

pub fn create_role(guild: id.GuildId, body: Body) -> Call(Role) {
  rest.post(roles_at(guild), body, rest.Decoded(role.decoder()))
}

pub fn edit_role(guild: id.GuildId, role: id.RoleId, body: Body) -> Call(Role) {
  rest.patch(role_at(guild, role), body, rest.Decoded(role.decoder()))
}

pub fn delete_role(guild: id.GuildId, role: id.RoleId) -> Call(Nil) {
  rest.delete(role_at(guild, role), rest.NoContent(Nil))
}

fn bans_at(guild: id.GuildId) -> List(seg.Seg) {
  [seg.lit("guilds"), seg.guild(guild), seg.lit("bans")]
}

fn ban_at(guild: id.GuildId, user: id.UserId) -> List(seg.Seg) {
  list.append(bans_at(guild), [seg.id(user)])
}

fn members_at(guild: id.GuildId) -> List(seg.Seg) {
  [seg.lit("guilds"), seg.guild(guild), seg.lit("members")]
}

fn member_at(guild: id.GuildId, user: id.UserId) -> List(seg.Seg) {
  list.append(members_at(guild), [seg.id(user)])
}

fn member_role_at(
  guild: id.GuildId,
  user: id.UserId,
  role: id.RoleId,
) -> List(seg.Seg) {
  list.append(member_at(guild, user), [seg.lit("roles"), seg.id(role)])
}

fn roles_at(guild: id.GuildId) -> List(seg.Seg) {
  [seg.lit("guilds"), seg.guild(guild), seg.lit("roles")]
}

fn role_at(guild: id.GuildId, role: id.RoleId) -> List(seg.Seg) {
  list.append(roles_at(guild), [seg.id(role)])
}
