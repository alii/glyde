//// Interactions: what arrives when someone runs a command, presses a button
//// or types into an autocomplete box.
////
//// `data` is decoded on the envelope's `type`, never on the shape of `data`:
//// command (2) and autocomplete (4) send identical objects, so shape sniffing
//// answers an autocomplete keystroke with a message per letter.
////
//// A `type` this build has no name for fails the decode, so it reaches
//// `on_status` as `Undecodable` rather than the handler as an `Option` to
//// unwrap. A PING carries five keys, which is why most other "required"
//// fields are optional here.

import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import glyde/api
import glyde/application_command
import glyde/attachment
import glyde/channel
import glyde/component
import glyde/embed.{type Embed}
import glyde/field.{type Field, Absent, Present}
import glyde/flags
import glyde/id
import glyde/member
import glyde/mentions.{type AllowedMentions}
import glyde/message
import glyde/permissions
import glyde/rest.{type Call}
import glyde/rest/body.{type Body}
import glyde/rest/query
import glyde/rest/seg
import glyde/role
import glyde/user
import glyde/webhook
import glyde/wire

/// The credential half of an interaction: this plus the id answers as the bot
/// for fifteen minutes with no `Authorization` header. Opaque and with no
/// `to_string`, so `echo interaction` cannot spill it. A closure, not a field,
/// because `string.inspect` ignores opaqueness.
pub opaque type InteractionToken {
  InteractionToken(reveal: fn() -> String)
}

/// For a token that did not come through this decoder: an HTTP-interactions
/// endpoint reading it out of its own request, or one kept across a restart.
pub fn interaction_token(raw: String) -> InteractionToken {
  InteractionToken(fn() { raw })
}

/// The token as a path segment wants it.
fn reveal_token(token: InteractionToken) -> String {
  token.reveal()
}

pub type Interaction {
  Interaction(
    id: id.InteractionId,
    application_id: id.ApplicationId,
    /// Selects which `data` variant you get. Match on `data`, not on this.
    type_: InteractionType,
    /// `NoData` for a PING, not an `Option`, so a handler writes one `case`.
    data: InteractionData,
    guild: Option(InteractionGuild),
    /// Absent, not null, in DMs.
    guild_id: Option(id.GuildId),
    /// A PARTIAL channel: assume only `id` and `type_` are populated.
    channel: Option(channel.Channel),
    /// Absent on a PING.
    channel_id: Option(id.ChannelId),
    /// Present only in a guild, where `member.user` is the invoking user.
    member: Option(member.GuildMember),
    /// Present only in a DM. Use `invoking_user` to get either.
    user: Option(user.User),
    /// Valid 15 minutes, first response due in 3 seconds. Hand it to
    /// `responding_to` rather than reading it out.
    token: InteractionToken,
    /// Always 1.
    version: Int,
    /// The message a component was attached to.
    message: Option(message.Message),
    /// What the APP may do here, not what the user may do. Absent on a PING.
    app_permissions: Option(permissions.Effective),
    locale: Option(String),
    guild_locale: Option(String),
    /// Who installed the app, one entry per install type it ran under. Empty
    /// on a PING. `authorizing_guild_id` and `authorizing_user_id` read it as
    /// typed ids.
    authorizing_integration_owners: Dict(IntegrationOwnerKey, AuthorizingOwner),
    context: Option(application_command.InteractionContextType),
    /// Bytes. Absent on a PING.
    attachment_size_limit: Option(Int),
  )
}

/// Not a `Guild`: the guild decoder fails on these three fields.
pub type InteractionGuild {
  InteractionGuild(id: id.GuildId, locale: String, features: List(String))
}

/// A key of `authorizing_integration_owners`, which arrives as a JSON object
/// key: the string "0" or "1". Its own type rather than
/// `ApplicationIntegrationType` so an unparseable key never reaches
/// `integration_types` on a command create, where it would send garbage.
pub type IntegrationOwnerKey {
  KnownIntegration(application_command.ApplicationIntegrationType)
  /// A key that was not a number at all. Keeps the raw text so two of them
  /// stay two entries; one shared sentinel would drop every one but the last.
  UnparsedIntegrationKey(String)
}

/// One entry of `authorizing_integration_owners`. A guild install invoked in
/// the app's own DM has no guild to name, and Discord says so with a sentinel
/// rather than by leaving the entry out.
pub type AuthorizingOwner {
  /// A snowflake: a guild id under `GuildInstall`, a user id under
  /// `UserInstall`.
  OwnedBy(String)
  NoOwner
}

/// A value this build has no name for fails the decode.
pub type InteractionType {
  /// HTTP interactions only. Never arrives over the gateway.
  PingInteraction
  ApplicationCommandInteraction
  MessageComponentInteraction
  AutocompleteInteraction
  /// Its data is not modelled, so `data` decodes as `NoData`.
  ModalSubmitInteraction
}

pub type InteractionData {
  /// Type 2. A slash command or a context-menu command.
  CommandData(
    id: id.CommandId,
    /// The top-level command name only. Subcommand names live in `options`.
    name: String,
    type_: application_command.ApplicationCommandType,
    /// Absent `resolved` decodes to an empty one, so no `Option` to unwrap.
    resolved: ResolvedData,
    options: List(InteractionOption),
    /// Where the command is REGISTERED, not where it was invoked.
    guild_id: Option(id.GuildId),
    /// A user id for USER commands, a message id for MESSAGE ones. Read it
    /// through `target_user_id` and `target_message_id`.
    target_id: Option(String),
  )

  /// Type 4. Byte-identical to `CommandData` on the wire and a different thing
  /// to answer. `options` is partial, and the one being typed has `focused`.
  AutocompleteData(
    id: id.CommandId,
    name: String,
    type_: application_command.ApplicationCommandType,
    options: List(InteractionOption),
    guild_id: Option(id.GuildId),
  )

  /// Type 3. A button press or a select submission.
  ComponentData(
    custom_id: String,
    /// What was submitted, tagged by the component that sent it. A button
    /// press carries nothing, so there is no empty `values` to read. `None`
    /// for a component type this build does not model.
    submission: Option(ComponentSubmission),
    resolved: ResolvedData,
  )

  /// Type 1 (PING) and type 5 (MODAL_SUBMIT). The envelope's id and token are
  /// still there for a caller to answer "unsupported".
  NoData
}

/// What the component sent back, one variant per `component_type`. Discord
/// writes every submission as the same `values` array of strings, so this is
/// what says whether reading it means anything and what the strings are.
pub type ComponentSubmission {
  /// Type 2. A button submits nothing but its `custom_id`.
  ButtonPress
  /// Type 3. The `value` of each chosen option, not its label.
  StringSelect(values: List(String))
  /// Type 5.
  UserSelect(users: List(id.UserId))
  /// Type 6.
  RoleSelect(roles: List(id.RoleId))
  /// Type 7. Users and roles come back in one list. An id in neither
  /// `resolved` map is dropped, since nothing says which it is.
  MentionableSelect(mentions: List(Mentionable))
  /// Type 8.
  ChannelSelect(channels: List(id.ChannelId))
}

/// One pick from a mentionable select, which is the only component that can
/// return a user and a role in the same list. An id in neither `resolved` map
/// is dropped from the list.
pub type Mentionable {
  MentionedUser(id: id.UserId)
  MentionedRole(id: id.RoleId)
}

/// One parameter of an invoked command. Nests at most three deep: group,
/// subcommand, then the value-bearing options.
pub type InteractionOption {
  InteractionOption(
    name: String,
    /// `None` for a value this build has no name for.
    type_: Option(application_command.ApplicationCommandOptionType),
    /// `NoValue` for subcommands and groups, which carry `options` instead,
    /// and for an autocomplete option not yet typed.
    value: OptionValue,
    /// Empty unless this is a subcommand or a subcommand group.
    options: List(InteractionOption),
    /// True on the option the user is typing. Autocomplete only.
    focused: Bool,
  )
}

/// The snowflake option types arrive as a `StringValue` holding the id. Look
/// it up in `resolved`, or use the typed accessors below.
pub type OptionValue {
  StringValue(String)
  IntValue(Int)
  FloatValue(Float)
  BoolValue(Bool)
  /// The `value` key was absent, or was present and not a string, number or
  /// bool.
  NoValue
}

/// Everything the user picked, already fetched. Absent maps decode to empty.
pub type ResolvedData {
  ResolvedData(
    users: Dict(id.UserId, user.User),
    /// Partial: no `user`, `deaf` or `mute`. The id is already the map key.
    members: Dict(id.UserId, member.GuildMember),
    roles: Dict(id.RoleId, role.Role),
    channels: Dict(id.ChannelId, ResolvedChannel),
    /// Only ever populated for MESSAGE context-menu commands.
    messages: Dict(id.MessageId, message.Message),
    /// Never populated for message components.
    attachments: Dict(id.AttachmentId, attachment.Attachment),
  )
}

/// Narrower than `Channel` except for `permissions`, the invoking user's
/// computed permissions, which a `Channel` decode would drop.
pub type ResolvedChannel {
  ResolvedChannel(
    id: id.ChannelId,
    type_: channel.ChannelType,
    name: Option(String),
    permissions: Option(permissions.Effective),
    parent_id: Option(id.ChannelId),
    /// Present when the resolved channel is a thread.
    thread_metadata: Option(channel.ThreadMetadata),
  )
}

/// The body of `POST …/callback?with_response=true`. Without that parameter
/// the route answers 204.
pub type InteractionCallbackResponse {
  InteractionCallbackResponse(
    interaction: InteractionCallback,
    resource: Option(InteractionCallbackResource),
  )
}

pub type InteractionCallback {
  InteractionCallback(
    id: id.InteractionId,
    type_: InteractionType,
    /// The message your response created. Absent for a deferred response and
    /// for autocomplete.
    response_message_id: Option(id.MessageId),
    response_message_loading: Option(Bool),
    response_message_ephemeral: Option(Bool),
  )
}

pub type InteractionCallbackResource {
  InteractionCallbackResource(
    type_: InteractionCallbackType,
    /// Only for CHANNEL_MESSAGE_WITH_SOURCE and UPDATE_MESSAGE.
    message: Option(message.Message),
  )
}

/// The numbering skips 11, so never index this by position. A value this
/// build has no name for fails the decode.
pub type InteractionCallbackType {
  PongCallback
  ChannelMessageWithSourceCallback
  DeferredChannelMessageWithSourceCallback
  DeferredUpdateMessageCallback
  UpdateMessageCallback
  AutocompleteResultCallback
  ModalCallback
  /// Deprecated by Discord.
  PremiumRequiredCallback
  /// Activities.
  LaunchActivityCallback
}

pub fn interaction_type_from_int(value: Int) -> Option(InteractionType) {
  case value {
    1 -> Some(PingInteraction)
    2 -> Some(ApplicationCommandInteraction)
    3 -> Some(MessageComponentInteraction)
    4 -> Some(AutocompleteInteraction)
    5 -> Some(ModalSubmitInteraction)
    _ -> None
  }
}

pub fn interaction_type_to_int(value: InteractionType) -> Int {
  case value {
    PingInteraction -> 1
    ApplicationCommandInteraction -> 2
    MessageComponentInteraction -> 3
    AutocompleteInteraction -> 4
    ModalSubmitInteraction -> 5
  }
}

pub fn interaction_type_decoder() -> Decoder(InteractionType) {
  wire.strict(interaction_type_from_int, PingInteraction, "InteractionType")
}

pub fn interaction_type_to_json(value: InteractionType) -> Json {
  json.int(interaction_type_to_int(value))
}

pub fn callback_type_from_int(value: Int) -> Option(InteractionCallbackType) {
  case value {
    1 -> Some(PongCallback)
    4 -> Some(ChannelMessageWithSourceCallback)
    5 -> Some(DeferredChannelMessageWithSourceCallback)
    6 -> Some(DeferredUpdateMessageCallback)
    7 -> Some(UpdateMessageCallback)
    8 -> Some(AutocompleteResultCallback)
    9 -> Some(ModalCallback)
    10 -> Some(PremiumRequiredCallback)
    12 -> Some(LaunchActivityCallback)
    _ -> None
  }
}

pub fn callback_type_to_int(value: InteractionCallbackType) -> Int {
  case value {
    PongCallback -> 1
    ChannelMessageWithSourceCallback -> 4
    DeferredChannelMessageWithSourceCallback -> 5
    DeferredUpdateMessageCallback -> 6
    UpdateMessageCallback -> 7
    AutocompleteResultCallback -> 8
    ModalCallback -> 9
    PremiumRequiredCallback -> 10
    LaunchActivityCallback -> 12
  }
}

pub fn callback_type_decoder() -> Decoder(InteractionCallbackType) {
  wire.strict(callback_type_from_int, PongCallback, "InteractionCallbackType")
}

pub fn callback_type_to_json(value: InteractionCallbackType) -> Json {
  json.int(callback_type_to_int(value))
}

/// In a guild the user is at `member.user`, in a DM at `user`.
pub fn invoking_user(interaction: Interaction) -> Option(user.User) {
  case interaction.member {
    Some(who) -> who.user
    None -> interaction.user
  }
}

pub fn target_user_id(data: InteractionData) -> Option(id.UserId) {
  case data {
    CommandData(
      type_: application_command.UserCommand,
      target_id: Some(target),
      ..,
    ) -> Some(id.from_string(target))
    _ -> None
  }
}

pub fn target_message_id(data: InteractionData) -> Option(id.MessageId) {
  case data {
    CommandData(
      type_: application_command.MessageCommand,
      target_id: Some(target),
      ..,
    ) -> Some(id.from_string(target))
    _ -> None
  }
}

/// Discord's stand-in for "no guild" under a guild install in the app's own
/// DM. Decoded to `NoOwner` on the way in: `id.from_string` does not validate,
/// so a caller that missed it would mint a guild zero.
const no_authorizing_owner: String = "0"

fn authorizing_owner_decoder() -> Decoder(AuthorizingOwner) {
  use raw <- decode.map(decode.string)
  case raw == no_authorizing_owner {
    True -> NoOwner
    False -> OwnedBy(raw)
  }
}

/// A key that is not a number, or is a number this build has no name for,
/// keeps its text rather than failing the interaction: this decode is all or
/// nothing.
fn integration_owner_key_decoder() -> Decoder(IntegrationOwnerKey) {
  use key <- decode.map(decode.string)
  case
    option.then(
      option.from_result(int.parse(key)),
      application_command.integration_type_from_int,
    )
  {
    Some(value) -> KnownIntegration(value)
    None -> UnparsedIntegrationKey(key)
  }
}

fn authorizing_owner(
  interaction: Interaction,
  install: application_command.ApplicationIntegrationType,
) -> Option(id.Id(k)) {
  case
    dict.get(
      interaction.authorizing_integration_owners,
      KnownIntegration(install),
    )
  {
    Ok(OwnedBy(owner)) -> Some(id.from_string(owner))
    _ -> None
  }
}

/// The guild that installed the app, when the interaction ran under a guild
/// install. `None` in a bot DM, where Discord sends the sentinel instead.
pub fn authorizing_guild_id(interaction: Interaction) -> Option(id.GuildId) {
  authorizing_owner(interaction, application_command.GuildInstall)
}

/// The user who installed the app, when the interaction ran under a user
/// install.
pub fn authorizing_user_id(interaction: Interaction) -> Option(id.UserId) {
  authorizing_owner(interaction, application_command.UserInstall)
}

pub fn empty_resolved() -> ResolvedData {
  ResolvedData(
    users: dict.new(),
    members: dict.new(),
    roles: dict.new(),
    channels: dict.new(),
    messages: dict.new(),
    attachments: dict.new(),
  )
}

pub fn interaction_guild_decoder() -> Decoder(InteractionGuild) {
  use id <- decode.field("id", id.decoder())
  use locale <- wire.string_field("locale", "")
  use features <- wire.list_field("features", decode.string)
  decode.success(InteractionGuild(id:, locale:, features:))
}

pub fn resolved_channel_decoder() -> Decoder(ResolvedChannel) {
  use id <- decode.field("id", id.decoder())
  use type_ <- wire.type_field(
    "type",
    channel.channel_type_from_int,
    channel.GuildText,
    "ChannelType",
  )
  use name <- wire.opt_field("name", decode.string)
  use perms <- wire.opt_field("permissions", permissions.effective_decoder())
  use parent_id <- wire.opt_field("parent_id", id.decoder())
  use thread_metadata <- wire.opt_field(
    "thread_metadata",
    channel.thread_metadata_decoder(),
  )
  decode.success(ResolvedChannel(
    id:,
    type_:,
    name:,
    permissions: perms,
    parent_id:,
    thread_metadata:,
  ))
}

pub fn resolved_decoder() -> Decoder(ResolvedData) {
  use users <- wire.dict_field("users", id.decoder(), user.decoder())
  use members <- wire.dict_field("members", id.decoder(), member.decoder())
  use roles <- wire.dict_field("roles", id.decoder(), role.decoder())
  use channels <- wire.dict_field(
    "channels",
    id.decoder(),
    resolved_channel_decoder(),
  )
  use messages <- wire.dict_field("messages", id.decoder(), message.decoder())
  use attachments <- wire.dict_field(
    "attachments",
    id.decoder(),
    attachment.decoder(),
  )
  decode.success(ResolvedData(
    users:,
    members:,
    roles:,
    channels:,
    messages:,
    attachments:,
  ))
}

/// The declared type picks the variant, not the JSON shape. Discord validates
/// numeric input client-side only, so every ladder ends in `NoValue`.
fn option_value_decoder(
  option_type: Option(application_command.ApplicationCommandOptionType),
) -> Decoder(OptionValue) {
  case option_type {
    Some(application_command.SubCommand)
    | Some(application_command.SubCommandGroup) -> decode.success(NoValue)
    Some(application_command.IntegerOption) ->
      decode.one_of(wire.integer() |> decode.map(IntValue), [
        wire.number() |> decode.map(FloatValue),
        decode.string |> decode.map(StringValue),
        decode.success(NoValue),
      ])
    Some(application_command.BooleanOption) ->
      decode.one_of(decode.bool |> decode.map(BoolValue), [
        decode.string |> decode.map(StringValue),
        decode.success(NoValue),
      ])
    // A whole NUMBER still lands as a Float, which is what was declared.
    Some(application_command.NumberOption) ->
      decode.one_of(wire.number() |> decode.map(FloatValue), [
        decode.string |> decode.map(StringValue),
        decode.success(NoValue),
      ])
    // STRING, the snowflake types, and anything this build does not know.
    _ ->
      decode.one_of(decode.string |> decode.map(StringValue), [
        decode.bool |> decode.map(BoolValue),
        wire.integer() |> decode.map(IntValue),
        wire.number() |> decode.map(FloatValue),
        decode.success(NoValue),
      ])
  }
}

pub fn option_decoder() -> Decoder(InteractionOption) {
  use <- decode.recursive
  use name <- decode.field("name", decode.string)
  use declared <- decode.field("type", wire.integer())
  let type_ = application_command.option_type_from_int(declared)
  use value <- decode.optional_field(
    "value",
    NoValue,
    option_value_decoder(type_),
  )
  use options <- wire.list_field("options", option_decoder())
  use focused <- wire.flag_field("focused", False)
  decode.success(InteractionOption(name:, type_:, value:, options:, focused:))
}

/// The envelope's `type` picks the decoder. A type whose data this build does
/// not model gives `NoData`, so the envelope's id and token are still there.
pub fn data_decoder(
  interaction_type: InteractionType,
) -> Decoder(InteractionData) {
  case interaction_type {
    ApplicationCommandInteraction -> command_data_decoder()
    MessageComponentInteraction -> component_data_decoder()
    AutocompleteInteraction -> autocomplete_data_decoder()
    PingInteraction | ModalSubmitInteraction -> decode.success(NoData)
  }
}

fn command_data_decoder() -> Decoder(InteractionData) {
  use id <- decode.field("id", id.decoder())
  use name <- wire.string_field("name", "")
  use type_ <- wire.type_or(
    "type",
    application_command.command_type_from_int,
    application_command.ChatInput,
    "ApplicationCommandType",
  )
  use resolved <- wire.defaulted_field(
    "resolved",
    resolved_decoder(),
    empty_resolved(),
  )
  use options <- wire.list_field("options", option_decoder())
  use guild_id <- wire.opt_field("guild_id", id.decoder())
  use target_id <- wire.opt_field("target_id", decode.string)
  decode.success(CommandData(
    id:,
    name:,
    type_:,
    resolved:,
    options:,
    guild_id:,
    target_id:,
  ))
}

fn autocomplete_data_decoder() -> Decoder(InteractionData) {
  use id <- decode.field("id", id.decoder())
  use name <- wire.string_field("name", "")
  use type_ <- wire.type_or(
    "type",
    application_command.command_type_from_int,
    application_command.ChatInput,
    "ApplicationCommandType",
  )
  use options <- wire.list_field("options", option_decoder())
  use guild_id <- wire.opt_field("guild_id", id.decoder())
  decode.success(AutocompleteData(id:, name:, type_:, options:, guild_id:))
}

fn component_data_decoder() -> Decoder(InteractionData) {
  use custom_id <- wire.string_field("custom_id", "")
  use component_type <- wire.int_field("component_type", 0)
  use values <- wire.list_field("values", decode.string)
  use resolved <- wire.defaulted_field(
    "resolved",
    resolved_decoder(),
    empty_resolved(),
  )
  decode.success(ComponentData(
    custom_id:,
    submission: submission(
      component.component_type_from_int(component_type),
      values,
      resolved,
    ),
    resolved:,
  ))
}

/// The declared `component_type` picks the variant. The wire shape cannot: an
/// empty select and a button press send the same keys. The numbering is
/// `glyde/component`'s, so there is one table of it.
fn submission(
  component_type: Option(component.ComponentType),
  values: List(String),
  resolved: ResolvedData,
) -> Option(ComponentSubmission) {
  case component_type {
    Some(component.ButtonType) -> Some(ButtonPress)
    Some(component.StringSelectType) -> Some(StringSelect(values:))
    Some(component.UserSelectType) ->
      Some(UserSelect(users: list.map(values, id.from_string)))
    Some(component.RoleSelectType) ->
      Some(RoleSelect(roles: list.map(values, id.from_string)))
    Some(component.MentionableSelectType) ->
      Some(
        MentionableSelect(
          mentions: list.filter_map(values, fn(raw) {
            option.to_result(mentionable(raw, resolved), Nil)
          }),
        ),
      )
    Some(component.ChannelSelectType) ->
      Some(ChannelSelect(channels: list.map(values, id.from_string)))
    // An action row and a text input never submit an interaction, so they go
    // the same way as a type this build has no name for.
    Some(component.ActionRowType) | Some(component.TextInputType) | None -> None
  }
}

/// Only `resolved` tells a picked user from a picked role, and Discord fills
/// it for every entity select. An id in neither map is dropped rather than
/// defaulting to a user: `user_option` refuses the same guess.
fn mentionable(raw: String, resolved: ResolvedData) -> Option(Mentionable) {
  case
    dict.has_key(resolved.roles, id.from_string(raw)),
    dict.has_key(resolved.users, id.from_string(raw))
    || dict.has_key(resolved.members, id.from_string(raw))
  {
    True, _ -> Some(MentionedRole(id.from_string(raw)))
    False, True -> Some(MentionedUser(id.from_string(raw)))
    False, False -> None
  }
}

pub fn decoder() -> Decoder(Interaction) {
  use id <- decode.field("id", id.decoder())
  use application_id <- decode.field("application_id", id.decoder())
  use type_ <- decode.field("type", interaction_type_decoder())
  use data <- wire.defaulted_field("data", data_decoder(type_), NoData)
  use guild <- wire.opt_field("guild", interaction_guild_decoder())
  use guild_id <- wire.opt_field("guild_id", id.decoder())
  use channel <- wire.opt_field("channel", channel.decoder())
  use channel_id <- wire.opt_field("channel_id", id.decoder())
  use member <- wire.opt_field("member", member.decoder())
  use user <- wire.opt_field("user", user.decoder())
  use token <- decode.field(
    "token",
    decode.string |> decode.map(interaction_token),
  )
  use version <- wire.int_field("version", 1)
  use message <- wire.opt_field("message", message.decoder())
  use app_permissions <- wire.opt_field(
    "app_permissions",
    permissions.effective_decoder(),
  )
  use locale <- wire.opt_field("locale", decode.string)
  use guild_locale <- wire.opt_field("guild_locale", decode.string)
  use owners <- wire.dict_field(
    "authorizing_integration_owners",
    integration_owner_key_decoder(),
    authorizing_owner_decoder(),
  )
  use context <- wire.known_field(
    "context",
    application_command.context_type_from_int,
  )
  use attachment_size_limit <- wire.opt_field(
    "attachment_size_limit",
    wire.integer(),
  )
  decode.success(Interaction(
    id:,
    application_id:,
    type_:,
    data:,
    guild:,
    guild_id:,
    channel:,
    channel_id:,
    member:,
    user:,
    token:,
    version:,
    message:,
    app_permissions:,
    locale:,
    guild_locale:,
    authorizing_integration_owners: owners,
    context:,
    attachment_size_limit:,
  ))
}

pub fn callback_decoder() -> Decoder(InteractionCallback) {
  use id <- decode.field("id", id.decoder())
  use type_ <- decode.field("type", interaction_type_decoder())
  use response_message_id <- wire.opt_field("response_message_id", id.decoder())
  use response_message_loading <- wire.opt_field(
    "response_message_loading",
    decode.bool,
  )
  use response_message_ephemeral <- wire.opt_field(
    "response_message_ephemeral",
    decode.bool,
  )
  decode.success(InteractionCallback(
    id:,
    type_:,
    response_message_id:,
    response_message_loading:,
    response_message_ephemeral:,
  ))
}

pub fn callback_resource_decoder() -> Decoder(InteractionCallbackResource) {
  use type_ <- decode.field("type", callback_type_decoder())
  use message <- wire.opt_field("message", message.decoder())
  decode.success(InteractionCallbackResource(type_:, message:))
}

pub fn callback_response_decoder() -> Decoder(InteractionCallbackResponse) {
  use interaction <- decode.field("interaction", callback_decoder())
  use resource <- wire.opt_field("resource", callback_resource_decoder())
  decode.success(InteractionCallbackResponse(interaction:, resource:))
}

/// A named parameter of the command the user actually invoked. Descends
/// through subcommands first, so `/config set key:red` finds `key` from the
/// top-level options, the same depth `focused_option` reads at. A group or a
/// subcommand is not a parameter and is not found here: `subcommand_path`
/// returns those names.
pub fn find_option(
  options: List(InteractionOption),
  name: String,
) -> Option(InteractionOption) {
  let #(_path, leaves) = subcommand_path(options)
  list.find(leaves, fn(option) { option.name == name })
  |> option.from_result
}

fn value_of(
  options: List(InteractionOption),
  name: String,
) -> Option(OptionValue) {
  option.map(find_option(options, name), fn(found) { found.value })
}

pub fn string_option(
  options: List(InteractionOption),
  name: String,
) -> Option(String) {
  case value_of(options, name) {
    Some(StringValue(value)) -> Some(value)
    _ -> None
  }
}

pub fn int_option(
  options: List(InteractionOption),
  name: String,
) -> Option(Int) {
  case value_of(options, name) {
    Some(IntValue(value)) -> Some(value)
    _ -> None
  }
}

pub fn float_option(
  options: List(InteractionOption),
  name: String,
) -> Option(Float) {
  case value_of(options, name) {
    Some(FloatValue(value)) -> Some(value)
    _ -> None
  }
}

pub fn bool_option(
  options: List(InteractionOption),
  name: String,
) -> Option(Bool) {
  case value_of(options, name) {
    Some(BoolValue(value)) -> Some(value)
    _ -> None
  }
}

/// Every snowflake option arrives as a string id, so the four accessors below
/// differ only in the one type they accept and the tag they return. An option
/// the command did not declare as `accepting` is `None`: free text is not a
/// snowflake however much a phantom type is willing to call it one.
fn id_option(
  options: List(InteractionOption),
  name: String,
  accepting accepting: application_command.ApplicationCommandOptionType,
) -> Option(id.Id(k)) {
  case find_option(options, name) {
    Some(InteractionOption(type_:, value: StringValue(raw), ..)) ->
      case type_ == Some(accepting) {
        True -> Some(id.from_string(raw))
        False -> None
      }
    _ -> None
  }
}

/// MENTIONABLE is not accepted here: only `resolved` says whether its id is a
/// user or a role, so reading one as a user is a coin flip. Read one with
/// `mentionable_option`, which takes the `resolved` that settles it.
pub fn user_option(
  options: List(InteractionOption),
  name: String,
) -> Option(id.UserId) {
  id_option(options, name, accepting: application_command.UserOption)
}

pub fn channel_option(
  options: List(InteractionOption),
  name: String,
) -> Option(id.ChannelId) {
  id_option(options, name, accepting: application_command.ChannelOption)
}

/// MENTIONABLE is not accepted, for the reason `user_option` gives.
pub fn role_option(
  options: List(InteractionOption),
  name: String,
) -> Option(id.RoleId) {
  id_option(options, name, accepting: application_command.RoleOption)
}

pub fn attachment_option(
  options: List(InteractionOption),
  name: String,
) -> Option(id.AttachmentId) {
  id_option(options, name, accepting: application_command.AttachmentOption)
}

/// The one snowflake accessor that reads a MENTIONABLE, because the `resolved`
/// that says user or role is handed to it. Take it off the same `CommandData`
/// the options came from.
pub fn mentionable_option(
  options: List(InteractionOption),
  name: String,
  resolved: ResolvedData,
) -> Option(Mentionable) {
  case find_option(options, name) {
    Some(InteractionOption(
      type_: Some(application_command.MentionableOption),
      value: StringValue(raw),
      ..,
    )) -> mentionable(raw, resolved)
    _ -> None
  }
}

/// The option being typed, during autocomplete. Descends into subcommands:
/// `/config set key:<typing>` is two levels down.
pub fn focused_option(
  options: List(InteractionOption),
) -> Option(InteractionOption) {
  case options {
    [] -> None
    [first, ..rest] ->
      case first.focused {
        True -> Some(first)
        False ->
          focused_option(first.options)
          |> option.lazy_or(fn() { focused_option(rest) })
      }
  }
}

/// Flatten `/group sub key:value` to `#(["group", "sub"], [the key option])`.
pub fn subcommand_path(
  options: List(InteractionOption),
) -> #(List(String), List(InteractionOption)) {
  case list.find(options, is_subcommand_like) {
    Ok(sub) -> {
      let #(deeper, leaves) = subcommand_path(sub.options)
      #([sub.name, ..deeper], leaves)
    }
    Error(Nil) -> #([], options)
  }
}

fn is_subcommand_like(option: InteractionOption) -> Bool {
  case option.type_ {
    Some(application_command.SubCommand)
    | Some(application_command.SubCommandGroup) -> True
    _ -> False
  }
}

/// Discord's deadline for the first response to an interaction.
pub const initial_response_ms: Int = 3000

/// Milliseconds left for the first response, counted from the interaction's
/// snowflake and not from receipt. 0 once closed, and 0 for a non-snowflake.
pub fn remaining_response_budget_ms(
  interaction: Interaction,
  now_ms now_ms: Int,
) -> Int {
  // Not `id.created_at_ms_or(default: discord_epoch_ms)`: the caller supplies
  // `now_ms`, and one counting from 0 would read the epoch fallback as 45
  // years of budget. The fallback belongs on the answer, not the timestamp.
  case id.created_at_ms(interaction.id) {
    Ok(created) -> int.max(0, created + initial_response_ms - now_ms)
    Error(Nil) -> 0
  }
}

// -- Response bodies ---------------------------------------------------------
//
// Types 4 and 7 share a JSON shape and not their semantics: 4 creates a
// message, so an omitted key is unset; 7 edits the message the component sits
// on, so an omitted key keeps the old value. Hence two types.
//
// Deferring fixes ephemerality for the whole interaction: defer publicly,
// edit with EPHEMERAL, and the reply leaks into the channel.

/// Send-only, so no unknown tail.
pub type InteractionResponse {
  /// ACK a PING. A gateway bot never sends this; an HTTP-interactions bot that
  /// cannot send it can never register its endpoint.
  Pong

  /// Reply with a new message. Create semantics.
  ChannelMessageWithSource(MessageCallbackData)

  /// "Thinking...". Turns the three-second budget into fifteen minutes; finish
  /// with `PATCH /webhooks/{app}/{token}/messages/@original`. EPHEMERAL is the
  /// only flag accepted, hence `Bool`.
  DeferredChannelMessageWithSource(ephemeral: Bool)

  /// Components only. ACK with no loading state, and no data at all.
  DeferredUpdateMessage

  /// Components only. Edit semantics: `Present([])` takes the components off
  /// the message. Field for field and key for key this is a message edit, so
  /// it carries the same type, built with `update_data`.
  UpdateMessage(message.Edit)

  /// Autocomplete only. An empty list is legal and means no suggestions.
  /// Max 25. `ChoiceValue` because the option being typed is only known at
  /// runtime, so this response cannot be tied to one value type.
  AutocompleteResult(
    choices: List(
      application_command.ApplicationCommandOptionChoice(
        application_command.ChoiceValue,
      ),
    ),
  )
}

/// Callback data for `ChannelMessageWithSource`. Same shape and rules as
/// `Draft`.
pub type MessageCallbackData {
  MessageCallbackData(
    content: Option(String),
    tts: Bool,
    embeds: List(Embed),
    components: List(component.Component),
    files: List(attachment.File),
    /// A decision, never a default: leaving it out lets Discord turn every
    /// @mention in the content into a real ping.
    allowed_mentions: Option(AllowedMentions),
    /// Only EPHEMERAL, SUPPRESS_EMBEDS, SUPPRESS_NOTIFICATIONS,
    /// IS_VOICE_MESSAGE and IS_COMPONENTS_V2 are accepted. Prefer `ephemeral`
    /// to assembling this by hand.
    flags: message.MessageFlags,
  )
}

pub fn message_data() -> MessageCallbackData {
  MessageCallbackData(
    content: None,
    tts: False,
    embeds: [],
    components: [],
    files: [],
    allowed_mentions: None,
    flags: message.no_flags,
  )
}

pub fn text(content: String) -> MessageCallbackData {
  MessageCallbackData(..message_data(), content: Some(content))
}

/// Only the invoking user sees it.
pub fn ephemeral(data: MessageCallbackData) -> MessageCallbackData {
  MessageCallbackData(
    ..data,
    flags: message.with_flag(data.flags, message.Ephemeral),
  )
}

/// Same as `message.new_edit`: the mention policy is not optional.
pub fn update_data(mentions: AllowedMentions) -> message.Edit {
  message.new_edit(mentions)
}

/// A `Draft` as callback data, so `message.text` and its setters build an
/// interaction reply as well as a channel post. `sticker_ids`, `reference` and
/// `nonce` are dropped: an interaction response is not a channel create, and
/// Discord takes none of them here.
pub fn from_draft(draft: message.Draft) -> MessageCallbackData {
  MessageCallbackData(
    content: draft.content,
    tts: draft.tts,
    embeds: draft.embeds,
    components: draft.components,
    files: draft.files,
    allowed_mentions: draft.allowed_mentions,
    flags: draft.flags,
  )
}

pub fn response_to_json(response: InteractionResponse) -> Json {
  json.object(response_fields(response))
}

/// A ready-to-send body for the callback route, files already paired to their
/// `attachments` entries. `callback` calls this for you; an HTTP-interactions
/// bot writing straight to its own HTTP response uses it directly.
///
/// The callback nests its `attachments` array under `data`, so the document is
/// finished here rather than left open: a top-level array as well would name
/// the same parts twice, and the copy without the kept ones deletes them.
pub fn response_body(response: InteractionResponse) -> Body {
  case response_files(response) {
    [] -> body.json(response_fields(response))
    files ->
      body.Finished(
        payload: response_to_json(response),
        files: attachment.parts(files),
      )
  }
}

fn response_fields(response: InteractionResponse) -> List(#(String, Json)) {
  wire.entries([
    #("type", Present(callback_type_to_json(callback_type(response)))),
    #("data", data(response)),
  ])
}

/// The callback type Discord reads off the envelope. Shares its numbering
/// with `callback_type_from_int`, so encode and decode use one table.
pub fn callback_type(response: InteractionResponse) -> InteractionCallbackType {
  case response {
    Pong -> PongCallback
    ChannelMessageWithSource(_) -> ChannelMessageWithSourceCallback
    DeferredChannelMessageWithSource(_) ->
      DeferredChannelMessageWithSourceCallback
    DeferredUpdateMessage -> DeferredUpdateMessageCallback
    UpdateMessage(_) -> UpdateMessageCallback
    AutocompleteResult(_) -> AutocompleteResultCallback
  }
}

/// The files the multipart body has to carry, in `files[n]` order.
pub fn response_files(response: InteractionResponse) -> List(attachment.File) {
  case response {
    ChannelMessageWithSource(data) -> data.files
    UpdateMessage(data) -> message.edit_files(data)
    Pong
    | DeferredChannelMessageWithSource(_)
    | DeferredUpdateMessage
    | AutocompleteResult(_) -> []
  }
}

pub fn message_data_to_json(data: MessageCallbackData) -> Json {
  wire.object(message_data_entries(data))
}

pub fn update_data_to_json(data: message.Edit) -> Json {
  wire.object(message.edit_entries(data))
}

fn data(response: InteractionResponse) -> Field(Json) {
  case response {
    Pong | DeferredUpdateMessage -> Absent

    ChannelMessageWithSource(data) -> Present(message_data_to_json(data))

    // EPHEMERAL is all this response can carry, so a public defer sends no
    // `data` at all.
    DeferredChannelMessageWithSource(True) ->
      Present(
        json.object([
          #(
            "flags",
            flags.to_json(message.message_flags(of: [message.Ephemeral])),
          ),
        ]),
      )
    DeferredChannelMessageWithSource(False) -> Absent

    UpdateMessage(data) -> Present(update_data_to_json(data))

    AutocompleteResult(choices:) ->
      Present(
        json.object([
          #(
            "choices",
            json.array(choices, application_command.choice_to_json(
              _,
              application_command.choice_value_to_json,
            )),
          ),
        ]),
      )
  }
}

fn message_data_entries(
  data: MessageCallbackData,
) -> List(#(String, Field(Json))) {
  [
    #("tts", wire.flag(data.tts)),
    #("content", wire.put(wire.opt(data.content), json.string)),
    #("embeds", wire.put_list(wire.opt_list(data.embeds), embed.to_json)),
    #(
      "allowed_mentions",
      wire.put(wire.opt(data.allowed_mentions), mentions.to_json),
    ),
    #("flags", message.flags_field(data.flags)),
    #(
      "components",
      wire.put_list(wire.opt_list(data.components), component.to_json),
    ),
    #("attachments", attachment.new_attachments_field(data.files)),
  ]
}

// -- Endpoints ---------------------------------------------------------------

/// Who to answer. One value, because the ids and the token have to come from
/// the same interaction: the `Id` tags catch an id swapped for an id, and this
/// catches the token of the other interaction in flight.
pub opaque type Responder {
  Responder(
    interaction: id.InteractionId,
    application: id.ApplicationId,
    token: InteractionToken,
  )
}

/// The gateway path. Everything comes off the one INTERACTION_CREATE, so the
/// three cannot disagree.
pub fn responding_to(interaction: Interaction) -> Responder {
  Responder(
    interaction: interaction.id,
    application: interaction.application_id,
    token: interaction.token,
  )
}

/// The HTTP-interactions path, and a token kept somewhere across a restart.
/// Prefer `responding_to` where there is an `Interaction` to hand.
pub fn responder(
  interaction interaction: id.InteractionId,
  application application: id.ApplicationId,
  token token: InteractionToken,
) -> Responder {
  Responder(interaction:, application:, token:)
}

/// `POST /interactions/{interaction.id}/{token}/callback`, the first answer.
/// Answers 204: use `callback_with_response` if you need the message id.
pub fn callback(
  api: api.Api,
  responder: Responder,
  response: InteractionResponse,
) -> Result(Nil, api.CallFailure) {
  api.execute(api, callback_call(responder, response))
}

/// The `Call` for [callback], for building the request without sending it.
pub fn callback_call(
  responder: Responder,
  response: InteractionResponse,
) -> Call(Nil) {
  rest.post(
    callback_at(responder),
    response_body(response),
    rest.NoContent(Nil),
  )
}

/// `POST /interactions/{interaction.id}/{token}/callback?with_response=true`,
/// answering 200 with the callback resource instead of 204.
pub fn callback_with_response(
  api: api.Api,
  responder: Responder,
  response: InteractionResponse,
) -> Result(InteractionCallbackResponse, api.CallFailure) {
  api.execute(api, callback_with_response_call(responder, response))
}

/// The `Call` for [callback_with_response], for building the request without
/// sending it.
pub fn callback_with_response_call(
  responder: Responder,
  response: InteractionResponse,
) -> Call(InteractionCallbackResponse) {
  rest.post(
    callback_at(responder),
    response_body(response),
    rest.Decoded(callback_response_decoder()),
  )
  |> rest.query(query.one("with_response", True, query.flag))
}

/// `GET /webhooks/{application.id}/{token}/messages/@original`.
pub fn get_original_response(
  api: api.Api,
  responder: Responder,
) -> Result(message.Message, api.CallFailure) {
  api.execute(api, get_original_response_call(responder))
}

/// The `Call` for [get_original_response], for building the request without
/// sending it.
pub fn get_original_response_call(
  responder: Responder,
) -> Call(message.Message) {
  webhook.get_original_message_call(as_webhook(responder), thread: None)
}

/// `PATCH /webhooks/{application.id}/{token}/messages/@original`. Turns a
/// deferred response into a real one, and edits one already sent.
pub fn edit_original_response(
  api: api.Api,
  responder: Responder,
  body: Body,
) -> Result(message.Message, api.CallFailure) {
  api.execute(api, edit_original_response_call(responder, body))
}

/// The `Call` for [edit_original_response], for building the request without
/// sending it.
pub fn edit_original_response_call(
  responder: Responder,
  body: Body,
) -> Call(message.Message) {
  webhook.edit_original_message_call(as_webhook(responder), body, thread: None)
}

/// `DELETE /webhooks/{application.id}/{token}/messages/@original`, which
/// works on an ephemeral response as well.
pub fn delete_original_response(
  api: api.Api,
  responder: Responder,
) -> Result(Nil, api.CallFailure) {
  api.execute(api, delete_original_response_call(responder))
}

/// The `Call` for [delete_original_response], for building the request
/// without sending it.
pub fn delete_original_response_call(responder: Responder) -> Call(Nil) {
  webhook.delete_original_message_call(as_webhook(responder), thread: None)
}

/// `POST /webhooks/{application.id}/{token}?wait=true`, an extra message on
/// the same interaction. Capped at five when the app is user-installed and not
/// a member of the server, `40094` past that.
pub fn create_followup(
  api: api.Api,
  responder: Responder,
  body: Body,
) -> Result(message.Message, api.CallFailure) {
  api.execute(api, create_followup_call(responder, body))
}

/// The `Call` for [create_followup], for building the request without sending
/// it.
pub fn create_followup_call(
  responder: Responder,
  body: Body,
) -> Call(message.Message) {
  webhook.execute_and_wait_call(as_webhook(responder), body, thread: None)
}

/// `GET /webhooks/{application.id}/{token}/messages/{message.id}`.
pub fn get_followup(
  api: api.Api,
  responder: Responder,
  message: id.MessageId,
) -> Result(message.Message, api.CallFailure) {
  api.execute(api, get_followup_call(responder, message))
}

/// The `Call` for [get_followup], for building the request without sending it.
pub fn get_followup_call(
  responder: Responder,
  message: id.MessageId,
) -> Call(message.Message) {
  webhook.get_message_call(as_webhook(responder), message, thread: None)
}

/// `PATCH /webhooks/{application.id}/{token}/messages/{message.id}`.
pub fn edit_followup(
  api: api.Api,
  responder: Responder,
  message: id.MessageId,
  body: Body,
) -> Result(message.Message, api.CallFailure) {
  api.execute(api, edit_followup_call(responder, message, body))
}

/// The `Call` for [edit_followup], for building the request without sending
/// it.
pub fn edit_followup_call(
  responder: Responder,
  message: id.MessageId,
  body: Body,
) -> Call(message.Message) {
  webhook.edit_message_call(as_webhook(responder), message, body, thread: None)
}

/// `DELETE /webhooks/{application.id}/{token}/messages/{message.id}`.
pub fn delete_followup(
  api: api.Api,
  responder: Responder,
  message: id.MessageId,
) -> Result(Nil, api.CallFailure) {
  api.execute(api, delete_followup_call(responder, message))
}

/// The `Call` for [delete_followup], for building the request without sending
/// it.
pub fn delete_followup_call(
  responder: Responder,
  message: id.MessageId,
) -> Call(Nil) {
  webhook.delete_message_call(as_webhook(responder), message, thread: None)
}

// -- Shortcuts ---------------------------------------------------------------
//
// The `Interaction` off the gateway straight to a `Call`, so a handler writes
// `interaction.respond(it, message.text("hi"))` rather than assembling a
// `Responder` and a callback body itself. Each is the plumbing above with the
// two arguments picked.

/// Reply with a message. Callback type 4. The first response owed within
/// three seconds; past that Discord drops the interaction and this call
/// answers 404. `defer` first if the reply takes longer to build.
pub fn respond(
  api: api.Api,
  interaction: Interaction,
  draft: message.Draft,
) -> Result(Nil, api.CallFailure) {
  api.execute(api, respond_call(interaction, draft))
}

/// The bare `Call`, for driving `glyde/rest` yourself.
pub fn respond_call(
  interaction: Interaction,
  draft: message.Draft,
) -> Call(Nil) {
  callback_call(
    responding_to(interaction),
    ChannelMessageWithSource(from_draft(draft)),
  )
}

/// Show "thinking..." and buy fifteen minutes. Callback type 5. Send within
/// three seconds, then finish with `edit_response`. The reply is public: the
/// eventual edit cannot make it ephemeral, so pick `defer_ephemeral` now if
/// only the invoker should see it.
pub fn defer(
  api: api.Api,
  interaction: Interaction,
) -> Result(Nil, api.CallFailure) {
  api.execute(api, defer_call(interaction))
}

/// The `Call` for [defer], for building the request without sending it.
pub fn defer_call(interaction: Interaction) -> Call(Nil) {
  callback_call(
    responding_to(interaction),
    DeferredChannelMessageWithSource(ephemeral: False),
  )
}

/// `defer` with the reply visible only to the invoker. Fixed at defer time:
/// the eventual `edit_response` cannot change it back to public.
pub fn defer_ephemeral(
  api: api.Api,
  interaction: Interaction,
) -> Result(Nil, api.CallFailure) {
  api.execute(api, defer_ephemeral_call(interaction))
}

/// The `Call` for [defer_ephemeral], for building the request without sending
/// it.
pub fn defer_ephemeral_call(interaction: Interaction) -> Call(Nil) {
  callback_call(
    responding_to(interaction),
    DeferredChannelMessageWithSource(ephemeral: True),
  )
}

/// Turn a deferred response into a real one, or edit one already sent.
/// `PATCH /webhooks/{application.id}/{token}/messages/@original`.
pub fn edit_response(
  api: api.Api,
  interaction: Interaction,
  edit: message.Edit,
) -> Result(message.Message, api.CallFailure) {
  api.execute(api, edit_response_call(interaction, edit))
}

/// The `Call` for [edit_response], for building the request without sending
/// it.
pub fn edit_response_call(
  interaction: Interaction,
  edit: message.Edit,
) -> Call(message.Message) {
  edit_original_response_call(
    responding_to(interaction),
    message.edit_body(edit),
  )
}

/// A second message on the same interaction, after `respond` or `defer` has
/// answered it. `POST /webhooks/{application.id}/{token}?wait=true`.
pub fn followup(
  api: api.Api,
  interaction: Interaction,
  draft: message.Draft,
) -> Result(message.Message, api.CallFailure) {
  api.execute(api, followup_call(interaction, draft))
}

/// The `Call` for [followup], for building the request without sending it.
pub fn followup_call(
  interaction: Interaction,
  draft: message.Draft,
) -> Call(message.Message) {
  create_followup_call(responding_to(interaction), message.to_body(draft))
}

/// This route is `route.Unbound`: it sits in no bucket, so the token cannot
/// reach a key however the path is written. `credential` keeps it out of the
/// template and drops the `Authorization` header.
fn callback_at(responder: Responder) -> List(seg.Seg) {
  [
    seg.lit("interactions"),
    seg.id(responder.interaction),
    seg.credential(reveal_token(responder.token)),
    seg.lit("callback"),
  ]
}

/// Follow-ups are the webhook routes with the application id in the webhook
/// id's place, which is Discord's own spelling of them.
fn as_webhook(responder: Responder) -> webhook.Credential {
  webhook.application_credential(
    responder.application,
    reveal_token(responder.token),
  )
}
