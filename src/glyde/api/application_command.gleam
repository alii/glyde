//// Registering commands, globally and for one guild.
////
//// The application id is not a major parameter, so the global routes share
//// one bucket per method and path across every application. The guild routes
//// take the guild major.
////
//// Discord meters command creates at 200 a day per guild. A create for a name
//// that already exists is an update and does not count, so a startup sync that
//// only overwrites spends none of that budget.
////
//// The mutating routes take a `payload/command` value, not a body, so the two
//// fields only a global command may carry and the top-level array a bulk
//// overwrite wants cannot arrive at the wrong route.

import gleam/dynamic/decode
import gleam/list
import glyde/id
import glyde/model/application_command.{type ApplicationCommand} as model
import glyde/payload/command
import glyde/rest.{type Call}
import glyde/rest/query
import glyde/rest/seg

/// `GET /applications/{application.id}/commands`. `name` and `description`
/// arrive either way. `with_localizations` swaps the single `name_localized`
/// and `description_localized` for the full `name_localizations` and
/// `description_localizations` maps.
pub fn get_global_commands(
  application: id.ApplicationId,
  with_localizations with_localizations: Bool,
) -> Call(List(ApplicationCommand)) {
  rest.get(global_at(application), rest.Decoded(decode.list(model.decoder())))
  |> rest.query(localizations(with_localizations))
}

/// `POST /applications/{application.id}/commands`. Safe to run on every boot:
/// Discord answers 200 and updates in place when the name already exists.
pub fn create_global_command(
  application: id.ApplicationId,
  create: command.GlobalCommand,
) -> Call(ApplicationCommand) {
  rest.post(
    global_at(application),
    command.global_body(create),
    rest.Decoded(model.decoder()),
  )
}

pub fn get_global_command(
  application: id.ApplicationId,
  command_id: id.CommandId,
) -> Call(ApplicationCommand) {
  rest.get(
    global_one_at(application, command_id),
    rest.Decoded(model.decoder()),
  )
}

/// `PATCH /applications/{application.id}/commands/{command.id}`.
pub fn edit_global_command(
  application: id.ApplicationId,
  command_id: id.CommandId,
  edit: command.EditGlobalCommand,
) -> Call(ApplicationCommand) {
  rest.patch(
    global_one_at(application, command_id),
    command.edit_global_body(edit),
    rest.Decoded(model.decoder()),
  )
}

pub fn delete_global_command(
  application: id.ApplicationId,
  command_id: id.CommandId,
) -> Call(Nil) {
  rest.delete(global_one_at(application, command_id), rest.NoContent(Nil))
}

/// `PUT /applications/{application.id}/commands`, replacing the whole set.
/// Every command type at once: a list holding only slash commands silently
/// deletes the application's user and message commands.
pub fn set_global_commands(
  application: id.ApplicationId,
  commands: List(command.GlobalCommand),
) -> Call(List(ApplicationCommand)) {
  rest.put(
    global_at(application),
    command.bulk_global_body(commands),
    rest.Decoded(decode.list(model.decoder())),
  )
}

pub fn get_guild_commands(
  application: id.ApplicationId,
  guild: id.GuildId,
  with_localizations with_localizations: Bool,
) -> Call(List(ApplicationCommand)) {
  rest.get(
    guild_at(application, guild),
    rest.Decoded(decode.list(model.decoder())),
  )
  |> rest.query(localizations(with_localizations))
}

/// `POST /applications/{application.id}/guilds/{guild.id}/commands`. Appears
/// immediately, where a global command can take an hour to propagate.
pub fn create_guild_command(
  application: id.ApplicationId,
  guild: id.GuildId,
  create: command.CreateApplicationCommand,
) -> Call(ApplicationCommand) {
  rest.post(
    guild_at(application, guild),
    command.guild_body(create),
    rest.Decoded(model.decoder()),
  )
}

pub fn get_guild_command(
  application: id.ApplicationId,
  guild: id.GuildId,
  command_id: id.CommandId,
) -> Call(ApplicationCommand) {
  rest.get(
    guild_one_at(application, guild, command_id),
    rest.Decoded(model.decoder()),
  )
}

/// `PATCH /applications/{application.id}/guilds/{guild.id}/commands/{id}`.
pub fn edit_guild_command(
  application: id.ApplicationId,
  guild: id.GuildId,
  command_id: id.CommandId,
  edit: command.EditApplicationCommand,
) -> Call(ApplicationCommand) {
  rest.patch(
    guild_one_at(application, guild, command_id),
    command.edit_guild_body(edit),
    rest.Decoded(model.decoder()),
  )
}

pub fn delete_guild_command(
  application: id.ApplicationId,
  guild: id.GuildId,
  command_id: id.CommandId,
) -> Call(Nil) {
  rest.delete(guild_one_at(application, guild, command_id), rest.NoContent(Nil))
}

/// `PUT /applications/{application.id}/guilds/{guild.id}/commands`, which
/// replaces every command type this application has in that guild.
pub fn set_guild_commands(
  application: id.ApplicationId,
  guild: id.GuildId,
  commands: List(command.CreateApplicationCommand),
) -> Call(List(ApplicationCommand)) {
  rest.put(
    guild_at(application, guild),
    command.bulk_guild_body(commands),
    rest.Decoded(decode.list(model.decoder())),
  )
}

fn localizations(wanted: Bool) -> List(query.Param) {
  query.one("with_localizations", query.flag(wanted))
}

fn global_at(application: id.ApplicationId) -> List(seg.Seg) {
  [seg.lit("applications"), seg.id(application), seg.lit("commands")]
}

fn global_one_at(
  application: id.ApplicationId,
  command_id: id.CommandId,
) -> List(seg.Seg) {
  list.append(global_at(application), [seg.id(command_id)])
}

/// The guild is the major parameter, not the application, even though the
/// application id comes first in the path. Discord limits these per guild.
fn guild_at(application: id.ApplicationId, guild: id.GuildId) -> List(seg.Seg) {
  [
    seg.lit("applications"),
    seg.id(application),
    seg.lit("guilds"),
    seg.guild(guild),
    seg.lit("commands"),
  ]
}

fn guild_one_at(
  application: id.ApplicationId,
  guild: id.GuildId,
  command_id: id.CommandId,
) -> List(seg.Seg) {
  list.append(guild_at(application, guild), [seg.id(command_id)])
}
