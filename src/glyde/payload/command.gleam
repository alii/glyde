//// Bodies for registering and editing application commands.
////
//// `integration_types` and `contexts` are a 400 on
//// `/applications/{app}/guilds/{g}/commands`, so they live on the global
//// shapes only: a guild body has no field to put them in, and the same value
//// cannot reach both scopes. The trap left is the bulk overwrite `PUT`, which
//// replaces every command type at once, so a startup sync deletes the bot's
//// context-menu commands unless they are in the list.

import gleam/dict.{type Dict}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None}
import glyde/field.{type Field, Absent, Present}
import glyde/model/application_command.{type ApplicationCommandOption}
import glyde/permissions.{type Permissions}
import glyde/rest/body.{type Body}
import glyde/wire

/// What both scopes take. The three command types share every field here, and
/// `kind` holds what only a slash command has.
///
/// This is the guild body as it stands. Wrap it in `global` for the two fields
/// a global command may also carry.
pub type CreateApplicationCommand {
  CreateApplicationCommand(
    kind: CreateKind,
    /// 1 to 32 characters, lowercase for a slash command.
    name: String,
    /// Empty writes no key.
    name_localizations: Dict(String, String),
    /// `None` leaves Discord's default, which is that everyone can use it.
    /// `Some(permissions.none())` is admins only.
    default_member_permissions: Option(Permissions),
    nsfw: Bool,
  )
}

/// Where a global command can be installed. `model/application_command` keeps
/// an unknown tail on the decoded enum so one new install target cannot drop an
/// interaction; going out, a target Discord does not know is a 400, so this
/// side holds the two it accepts and nothing else.
pub type InstallContext {
  /// Installed to a guild.
  GuildInstall
  /// Installed to a user, who then carries it everywhere.
  UserInstall
}

/// Where a global command can be used. Send-only, so no unknown tail: see
/// `InstallContext`.
pub type CommandContext {
  GuildContext
  /// A DM with the bot itself.
  BotDmContext
  /// A group DM, or a DM with anyone but the bot.
  PrivateChannelContext
}

/// A command registered globally. `integration_types` and `contexts` are a 400
/// on the guild route, so they exist here and nowhere else.
pub type GlobalCommand {
  GlobalCommand(
    command: CreateApplicationCommand,
    /// Empty writes no key.
    integration_types: List(InstallContext),
    contexts: List(CommandContext),
  )
}

/// The same command, global, with Discord's defaults for the two fields only
/// this scope has. Set either with a record update.
pub fn global(command: CreateApplicationCommand) -> GlobalCommand {
  GlobalCommand(command:, integration_types: [], contexts: [])
}

/// Which of the three a body registers. A context-menu command with a
/// description or an option is a 400, so neither is reachable from one.
pub type CreateKind {
  /// A slash command.
  ChatInput(
    /// 1 to 100 characters.
    description: String,
    description_localizations: Dict(String, String),
    options: List(ApplicationCommandOption),
  )
  /// Right-click on a user.
  UserCommand
  /// Right-click on a message.
  MessageCommand
}

pub fn new_chat_input(
  name name: String,
  description description: String,
) -> CreateApplicationCommand {
  chat_input(name:, description:, options: [])
}

/// The same slash command with its parameters. The encoder puts the required
/// ones first, so they can be listed in any order.
pub fn chat_input(
  name name: String,
  description description: String,
  options options: List(ApplicationCommandOption),
) -> CreateApplicationCommand {
  new_command(
    name,
    ChatInput(description:, description_localizations: dict.new(), options:),
  )
}

pub fn new_user_command(name name: String) -> CreateApplicationCommand {
  new_command(name, UserCommand)
}

pub fn new_message_command(name name: String) -> CreateApplicationCommand {
  new_command(name, MessageCommand)
}

fn new_command(name: String, kind: CreateKind) -> CreateApplicationCommand {
  CreateApplicationCommand(
    kind:,
    name:,
    name_localizations: dict.new(),
    default_member_permissions: None,
    nsfw: False,
  )
}

pub fn global_to_json(command: GlobalCommand) -> Json {
  json.object(global_fields(command))
}

/// The body for `POST /applications/{app}/commands`.
pub fn global_body(command: GlobalCommand) -> Body {
  body.json(global_fields(command))
}

pub fn guild_to_json(command: CreateApplicationCommand) -> Json {
  json.object(guild_fields(command))
}

/// The body for `POST /applications/{app}/guilds/{guild}/commands`.
pub fn guild_body(command: CreateApplicationCommand) -> Body {
  body.json(guild_fields(command))
}

/// The body for `PUT /applications/{app}/commands`, whose payload is a
/// top-level array. An empty list deletes every global command.
pub fn bulk_global_body(commands: List(GlobalCommand)) -> Body {
  body.json_array(list.map(commands, global_to_json))
}

/// The same for `PUT /applications/{app}/guilds/{guild}/commands`, which
/// empties that guild rather than the application.
pub fn bulk_guild_body(commands: List(CreateApplicationCommand)) -> Body {
  body.json_array(list.map(commands, guild_to_json))
}

fn guild_fields(command: CreateApplicationCommand) -> List(#(String, Json)) {
  wire.entries(shared_fields(command))
}

fn global_fields(command: GlobalCommand) -> List(#(String, Json)) {
  wire.entries(
    list.flatten([
      shared_fields(command.command),
      [
        #(
          "integration_types",
          integrations(wire.opt_list(command.integration_types)),
        ),
        #("contexts", context_list(wire.opt_list(command.contexts))),
      ],
    ]),
  )
}

fn shared_fields(
  command: CreateApplicationCommand,
) -> List(#(String, Field(Json))) {
  list.flatten([
    [
      #("name", Present(json.string(command.name))),
      #("name_localizations", created_localizations(command.name_localizations)),
    ],
    kind_fields(command.kind),
    [
      #(
        "default_member_permissions",
        wire.put(
          wire.opt(command.default_member_permissions),
          permissions.to_json,
        ),
      ),
      #("type", Present(command_type(command.kind))),
      #("nsfw", wire.flag(command.nsfw)),
    ],
  ])
}

/// The three keys only a slash command may send.
fn kind_fields(kind: CreateKind) -> List(#(String, Field(Json))) {
  case kind {
    ChatInput(description:, description_localizations:, options:) -> [
      #("description", Present(json.string(description))),
      #(
        "description_localizations",
        created_localizations(description_localizations),
      ),
      #(
        "options",
        wire.put(wire.opt_list(options), application_command.options_to_json),
      ),
    ]
    UserCommand | MessageCommand -> []
  }
}

/// The wire number, which is the only thing the two context-menu kinds change.
fn command_type(kind: CreateKind) -> Json {
  application_command.command_type_to_json(case kind {
    ChatInput(..) -> application_command.ChatInput
    UserCommand -> application_command.UserCommand
    MessageCommand -> application_command.MessageCommand
  })
}

/// `PATCH /applications/{app}/guilds/{guild}/commands/{cmd}`, and the half a
/// global edit shares with it. Any field sent overwrites.
///
/// `Field` only where null is legal. Discord answers 400 to a null `name`,
/// `description`, `options` or `nsfw`, so those four stay `Option`.
/// `Some([])` empties the option list.
pub type EditApplicationCommand {
  EditApplicationCommand(
    name: Option(String),
    description: Option(String),
    options: Option(List(ApplicationCommandOption)),
    nsfw: Option(Bool),
    /// `Null` removes every name localisation.
    name_localizations: Field(Dict(String, String)),
    description_localizations: Field(Dict(String, String)),
    /// `Null` restores the default visibility. `Present(permissions.none())`,
    /// the string "0", is admins only. Different instructions.
    default_member_permissions: Field(Permissions),
  )
}

/// `PATCH /applications/{app}/commands/{cmd}`: the shared fields plus the two
/// the guild route answers 400 to. A null `integration_types` is a 400 too, so
/// that one is an `Option`.
pub type EditGlobalCommand {
  EditGlobalCommand(
    command: EditApplicationCommand,
    integration_types: Option(List(InstallContext)),
    /// `Null` restores all contexts.
    contexts: Field(List(CommandContext)),
  )
}

pub fn edit() -> EditApplicationCommand {
  EditApplicationCommand(
    name: None,
    description: None,
    options: None,
    nsfw: None,
    name_localizations: Absent,
    description_localizations: Absent,
    default_member_permissions: Absent,
  )
}

/// An edit of a global command, touching nothing. Reach the shared fields
/// through `command`.
pub fn edit_global() -> EditGlobalCommand {
  EditGlobalCommand(command: edit(), integration_types: None, contexts: Absent)
}

pub fn edit_global_body(command: EditGlobalCommand) -> Body {
  body.json(
    wire.entries(
      list.flatten([
        shared_edit_fields(command.command),
        [
          #(
            "integration_types",
            integrations(wire.opt(command.integration_types)),
          ),
          #("contexts", context_list(command.contexts)),
        ],
      ]),
    ),
  )
}

pub fn edit_guild_body(command: EditApplicationCommand) -> Body {
  body.json(wire.entries(shared_edit_fields(command)))
}

fn shared_edit_fields(
  command: EditApplicationCommand,
) -> List(#(String, Field(Json))) {
  [
    #("name", wire.put(wire.opt(command.name), json.string)),
    #("name_localizations", localizations(command.name_localizations)),
    #("description", wire.put(wire.opt(command.description), json.string)),
    #(
      "description_localizations",
      localizations(command.description_localizations),
    ),
    #(
      "options",
      wire.put(wire.opt(command.options), application_command.options_to_json),
    ),
    #(
      "default_member_permissions",
      wire.put(command.default_member_permissions, permissions.to_json),
    ),
    #("nsfw", wire.put(wire.opt(command.nsfw), json.bool)),
  ]
}

fn localizations(value: Field(Dict(String, String))) -> Field(Json) {
  wire.put(value, application_command.localizations_to_json)
}

/// A create has no null to send, so an empty map is how it says nothing.
fn created_localizations(entries: Dict(String, String)) -> Field(Json) {
  localizations(case dict.is_empty(entries) {
    True -> Absent
    False -> Present(entries)
  })
}

/// The wire numbers stay in `model/application_command`, so they are written
/// down once for both directions.
fn integrations(value: Field(List(InstallContext))) -> Field(Json) {
  use install <- wire.put_list(value)
  application_command.integration_type_to_json(case install {
    GuildInstall -> application_command.GuildInstall
    UserInstall -> application_command.UserInstall
  })
}

fn context_list(value: Field(List(CommandContext))) -> Field(Json) {
  use context <- wire.put_list(value)
  application_command.context_type_to_json(case context {
    GuildContext -> application_command.GuildContext
    BotDmContext -> application_command.BotDmContext
    PrivateChannelContext -> application_command.PrivateChannelContext
  })
}
