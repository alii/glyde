//// Application commands: what a bot registers, as opposed to what a user
//// invoked. `model/interaction` is the other half.
////
//// `InteractionContextType` and `ApplicationIntegrationType` are declared at
//// registration, so they live here rather than in `interaction`.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import glyde/id
import glyde/model/channel
import glyde/model/component
import glyde/permissions
import glyde/wire

pub type ApplicationCommand {
  ApplicationCommand(
    id: id.CommandId,
    /// Optional on the wire, defaulting to CHAT_INPUT.
    type_: ApplicationCommandType,
    application_id: id.ApplicationId,
    /// Absent for a global command.
    guild_id: Option(id.GuildId),
    name: String,
    /// Only with `?with_localizations=true`.
    name_localizations: Option(Dict(String, String)),
    /// The EMPTY STRING for USER and MESSAGE commands, and never null.
    description: String,
    description_localizations: Option(Dict(String, String)),
    /// CHAT_INPUT only.
    options: List(ApplicationCommandOption),
    /// `None` is no override. `Some` of the empty set, the string "0", is
    /// admins only. Collapsing the two exposes or hides a command.
    default_member_permissions: Option(permissions.Permissions),
    /// Deprecated for `contexts`, and still sent.
    dm_permission: Option(Bool),
    nsfw: Bool,
    integration_types: List(ApplicationIntegrationType),
    /// `None` is absent or null, which Discord reads as every context.
    contexts: Option(List(InteractionContextType)),
    /// A snowflake despite the name, bumped on every substantial change.
    version: String,
    /// Only when the request did not ask for the full dictionaries.
    name_localized: Option(String),
    description_localized: Option(String),
  )
}

pub type ApplicationCommandType {
  ChatInput
  UserCommand
  MessageCommand
  /// Activities only.
  PrimaryEntryPoint
  UnknownCommandType(Int)
}

/// Where in Discord a command may be used, or was used from.
pub type InteractionContextType {
  GuildContext
  BotDmContext
  PrivateChannelContext
  UnknownContext(Int)
}

/// How an app was installed. Also a JSON object key, as "0" or "1".
pub type ApplicationIntegrationType {
  GuildInstall
  UserInstall
  UnknownIntegrationType(Int)
  /// An object key that was not a number at all. It keeps the raw key, because
  /// this is a `Dict` key: one shared sentinel would drop every unparseable
  /// entry but the last.
  UnknownIntegrationKey(String)
}

pub type ApplicationCommandOptionType {
  SubCommand
  SubCommandGroup
  StringOption
  IntegerOption
  BooleanOption
  UserOption
  ChannelOption
  RoleOption
  MentionableOption
  NumberOption
  AttachmentOption
  UnknownOptionType(Int)
}

/// One parameter of a command. Everything an option type does not have goes in
/// `kind`, so a length bound on an INTEGER does not typecheck.
pub type ApplicationCommandOption {
  ApplicationCommandOption(
    /// 1 to 32 characters.
    name: String,
    name_localizations: Option(Dict(String, String)),
    /// 1 to 100 characters.
    description: String,
    description_localizations: Option(Dict(String, String)),
    /// Discord answers 50035 unless every required option comes before every
    /// optional one. `options_to_json` sorts them, so the order they are built
    /// in does not matter.
    required: Bool,
    kind: OptionKind,
    /// Only when the request did not ask for the full dictionaries.
    name_localized: Option(String),
    description_localized: Option(String),
  )
}

/// The option type and the fields that type is allowed to carry, in one tag.
pub type OptionKind {
  /// Recursive: a subcommand holds the value-bearing options.
  SubCommandKind(options: List(ApplicationCommandOption))
  SubCommandGroupKind(options: List(ApplicationCommandOption))
  StringKind(
    suggestions: Suggestions,
    min_length: Option(Int),
    max_length: Option(Int),
  )
  IntegerKind(suggestions: Suggestions, min: Option(Int), max: Option(Int))
  /// A double, whole bounds included: Discord writes `5` and means `5.0`.
  NumberKind(suggestions: Suggestions, min: Option(Float), max: Option(Float))
  /// Empty offers every channel type.
  ChannelKind(channel_types: List(channel.ChannelType))
  BooleanKind
  UserKind
  RoleKind
  MentionableKind
  AttachmentKind
  /// A type added since this build. It keeps every field the option arrived
  /// with, because nothing here knows which of them the new type allows and a
  /// bulk overwrite sends back whatever was decoded. The modelled keys below
  /// are the ones this build can read; `raw` is the whole payload, so a key
  /// added since is not a key deleted on the next overwrite.
  UnknownKind(
    type_: Int,
    choices: List(ApplicationCommandOptionChoice),
    options: List(ApplicationCommandOption),
    channel_types: List(channel.ChannelType),
    min_value: Option(OptionNumberLimit),
    max_value: Option(OptionNumberLimit),
    min_length: Option(Int),
    max_length: Option(Int),
    autocomplete: Bool,
    raw: component.RawPayload,
  )
}

/// Where a STRING, INTEGER or NUMBER option gets its values from. Discord
/// answers 50035 to choices beside `autocomplete`, so the two are one tag and
/// the pair cannot be built.
pub type Suggestions {
  /// Max 25.
  Choices(List(ApplicationCommandOptionChoice))
  Autocomplete
  NoSuggestions
}

/// A bound as it arrives on the wire, before the declared type narrows it to
/// the `Int` or `Float` its kind holds. Whole for INTEGER, fractional for
/// NUMBER.
pub type OptionNumberLimit {
  IntLimit(Int)
  FloatLimit(Float)
}

pub type ApplicationCommandOptionChoice {
  ApplicationCommandOptionChoice(
    name: String,
    name_localizations: Option(Dict(String, String)),
    value: ChoiceValue,
  )
}

/// A choice's value, in the type its option declares.
pub type ChoiceValue {
  StringChoice(String)
  IntChoice(Int)
  FloatChoice(Float)
}

/// Any option, with everything its type is allowed to carry in `kind`:
/// `option(name: "who", description: "d", kind: UserKind)`, or
/// `SubCommandKind(options:)` for a subcommand, the deepest of the three levels
/// Discord allows being a group holding subcommands holding values.
///
/// Optional, no localizations: Discord's own defaults, not ours. Change any of
/// them with a record update.
pub fn option(
  name name: String,
  description description: String,
  kind kind: OptionKind,
) -> ApplicationCommandOption {
  ApplicationCommandOption(
    name:,
    name_localizations: None,
    description:,
    description_localizations: None,
    required: False,
    kind:,
    name_localized: None,
    description_localized: None,
  )
}

/// A STRING with no suggestions and no length bounds.
pub fn string_option(
  name name: String,
  description description: String,
) -> ApplicationCommandOption {
  option(
    name,
    description,
    StringKind(suggestions: NoSuggestions, min_length: None, max_length: None),
  )
}

/// An INTEGER with no suggestions and no bounds.
pub fn integer_option(
  name name: String,
  description description: String,
) -> ApplicationCommandOption {
  option(
    name,
    description,
    IntegerKind(suggestions: NoSuggestions, min: None, max: None),
  )
}

/// A NUMBER with no suggestions and no bounds.
pub fn number_option(
  name name: String,
  description description: String,
) -> ApplicationCommandOption {
  option(
    name,
    description,
    NumberKind(suggestions: NoSuggestions, min: None, max: None),
  )
}

pub fn boolean_option(
  name name: String,
  description description: String,
) -> ApplicationCommandOption {
  option(name, description, BooleanKind)
}

pub fn user_option(
  name name: String,
  description description: String,
) -> ApplicationCommandOption {
  option(name, description, UserKind)
}

/// Offers every channel type. Narrow it with a record update on the kind.
pub fn channel_option(
  name name: String,
  description description: String,
) -> ApplicationCommandOption {
  option(name, description, ChannelKind(channel_types: []))
}

pub fn role_option(
  name name: String,
  description description: String,
) -> ApplicationCommandOption {
  option(name, description, RoleKind)
}

/// A user or a role, resolved either way.
pub fn mentionable_option(
  name name: String,
  description description: String,
) -> ApplicationCommandOption {
  option(name, description, MentionableKind)
}

pub fn attachment_option(
  name name: String,
  description description: String,
) -> ApplicationCommandOption {
  option(name, description, AttachmentKind)
}

pub fn sub_command(
  name name: String,
  description description: String,
  options options: List(ApplicationCommandOption),
) -> ApplicationCommandOption {
  option(name, description, SubCommandKind(options:))
}

pub fn sub_command_group(
  name name: String,
  description description: String,
  options options: List(ApplicationCommandOption),
) -> ApplicationCommandOption {
  option(name, description, SubCommandGroupKind(options:))
}

pub fn command_type_from_int(value: Int) -> ApplicationCommandType {
  case value {
    1 -> ChatInput
    2 -> UserCommand
    3 -> MessageCommand
    4 -> PrimaryEntryPoint
    other -> UnknownCommandType(other)
  }
}

pub fn command_type_to_int(value: ApplicationCommandType) -> Int {
  case value {
    ChatInput -> 1
    UserCommand -> 2
    MessageCommand -> 3
    PrimaryEntryPoint -> 4
    UnknownCommandType(other) -> other
  }
}

pub fn command_type_decoder() -> Decoder(ApplicationCommandType) {
  wire.integer() |> decode.map(command_type_from_int)
}

pub fn command_type_to_json(value: ApplicationCommandType) -> Json {
  json.int(command_type_to_int(value))
}

pub fn context_type_from_int(value: Int) -> InteractionContextType {
  case value {
    0 -> GuildContext
    1 -> BotDmContext
    2 -> PrivateChannelContext
    other -> UnknownContext(other)
  }
}

pub fn context_type_to_int(value: InteractionContextType) -> Int {
  case value {
    GuildContext -> 0
    BotDmContext -> 1
    PrivateChannelContext -> 2
    UnknownContext(other) -> other
  }
}

pub fn context_type_decoder() -> Decoder(InteractionContextType) {
  wire.integer() |> decode.map(context_type_from_int)
}

pub fn context_type_to_json(value: InteractionContextType) -> Json {
  json.int(context_type_to_int(value))
}

pub fn integration_type_from_int(value: Int) -> ApplicationIntegrationType {
  case value {
    0 -> GuildInstall
    1 -> UserInstall
    other -> UnknownIntegrationType(other)
  }
}

pub fn integration_type_to_int(value: ApplicationIntegrationType) -> Int {
  case value {
    GuildInstall -> 0
    UserInstall -> 1
    UnknownIntegrationType(other) -> other
    // Only ever a key Discord sent us, never something to send back, so -1 is
    // a placeholder rather than a number that means anything.
    UnknownIntegrationKey(_) -> -1
  }
}

pub fn integration_type_decoder() -> Decoder(ApplicationIntegrationType) {
  wire.integer() |> decode.map(integration_type_from_int)
}

pub fn integration_type_to_json(value: ApplicationIntegrationType) -> Json {
  json.int(integration_type_to_int(value))
}

/// From a JSON object KEY, the string "0" or "1". A key that is not a number
/// keeps its text rather than failing the interaction.
pub fn integration_type_key_decoder() -> Decoder(ApplicationIntegrationType) {
  decode.string
  |> decode.map(fn(key) {
    case int.parse(key) {
      Ok(value) -> integration_type_from_int(value)
      Error(Nil) -> UnknownIntegrationKey(key)
    }
  })
}

pub fn option_type_from_int(value: Int) -> ApplicationCommandOptionType {
  case value {
    1 -> SubCommand
    2 -> SubCommandGroup
    3 -> StringOption
    4 -> IntegerOption
    5 -> BooleanOption
    6 -> UserOption
    7 -> ChannelOption
    8 -> RoleOption
    9 -> MentionableOption
    10 -> NumberOption
    11 -> AttachmentOption
    other -> UnknownOptionType(other)
  }
}

pub fn option_type_to_int(value: ApplicationCommandOptionType) -> Int {
  case value {
    SubCommand -> 1
    SubCommandGroup -> 2
    StringOption -> 3
    IntegerOption -> 4
    BooleanOption -> 5
    UserOption -> 6
    ChannelOption -> 7
    RoleOption -> 8
    MentionableOption -> 9
    NumberOption -> 10
    AttachmentOption -> 11
    UnknownOptionType(other) -> other
  }
}

pub fn option_type_decoder() -> Decoder(ApplicationCommandOptionType) {
  wire.integer() |> decode.map(option_type_from_int)
}

pub fn option_type_to_json(value: ApplicationCommandOptionType) -> Json {
  json.int(option_type_to_int(value))
}

/// The declared type picks the variant, not the JSON: Discord writes a whole
/// NUMBER bound as `5`, and sending an INTEGER bound as `5.0` is a 400. A type
/// this build does not know takes either shape, so one new option type does not
/// sink the whole response.
pub fn number_limit_decoder(
  option_type: ApplicationCommandOptionType,
) -> Decoder(OptionNumberLimit) {
  case option_type {
    NumberOption -> wire.number() |> decode.map(FloatLimit)
    IntegerOption -> wire.integer() |> decode.map(IntLimit)
    _ ->
      decode.one_of(wire.integer() |> decode.map(IntLimit), [
        wire.number() |> decode.map(FloatLimit),
      ])
  }
}

/// A choice's value, likewise picked by the option's declared type, and
/// likewise tolerant for a type this build does not know.
pub fn choice_value_decoder(
  option_type: ApplicationCommandOptionType,
) -> Decoder(ChoiceValue) {
  case option_type {
    IntegerOption -> wire.integer() |> decode.map(IntChoice)
    NumberOption -> wire.number() |> decode.map(FloatChoice)
    StringOption -> decode.string |> decode.map(StringChoice)
    _ ->
      decode.one_of(decode.string |> decode.map(StringChoice), [
        wire.integer() |> decode.map(IntChoice),
        wire.number() |> decode.map(FloatChoice),
      ])
  }
}

pub fn choice_value_to_json(value: ChoiceValue) -> Json {
  case value {
    StringChoice(text) -> json.string(text)
    IntChoice(number) -> json.int(number)
    FloatChoice(number) -> json.float(number)
  }
}

pub fn number_limit_to_json(value: OptionNumberLimit) -> Json {
  case value {
    IntLimit(number) -> json.int(number)
    FloatLimit(number) -> json.float(number)
  }
}

fn localizations_decoder() -> Decoder(Dict(String, String)) {
  decode.dict(decode.string, decode.string)
}

pub fn choice_decoder(
  option_type: ApplicationCommandOptionType,
) -> Decoder(ApplicationCommandOptionChoice) {
  use name <- decode.field("name", decode.string)
  use name_localizations <- wire.opt_field(
    "name_localizations",
    localizations_decoder(),
  )
  use value <- decode.field("value", choice_value_decoder(option_type))
  decode.success(ApplicationCommandOptionChoice(
    name:,
    name_localizations:,
    value:,
  ))
}

pub fn option_decoder() -> Decoder(ApplicationCommandOption) {
  use <- decode.recursive
  use raw <- wire.raw()
  use declared <- decode.field("type", wire.integer())
  let type_ = option_type_from_int(declared)
  use name <- decode.field("name", decode.string)
  use name_localizations <- wire.opt_field(
    "name_localizations",
    localizations_decoder(),
  )
  use description <- wire.string_field("description", "")
  use description_localizations <- wire.opt_field(
    "description_localizations",
    localizations_decoder(),
  )
  use required <- wire.flag_field("required", False)
  use choices <- wire.list_field("choices", choice_decoder(type_))
  use options <- wire.list_field("options", option_decoder())
  use channel_types <- wire.list_field(
    "channel_types",
    channel.channel_type_decoder(),
  )
  use min_value <- wire.opt_field("min_value", number_limit_decoder(type_))
  use max_value <- wire.opt_field("max_value", number_limit_decoder(type_))
  use min_length <- wire.opt_field("min_length", wire.integer())
  use max_length <- wire.opt_field("max_length", wire.integer())
  use autocomplete <- wire.flag_field("autocomplete", False)
  use name_localized <- wire.opt_field("name_localized", decode.string)
  use description_localized <- wire.opt_field(
    "description_localized",
    decode.string,
  )
  // Every key the option family can carry is read, then the declared type says
  // which of them this option actually has. The rest are Discord sending a
  // field its own docs forbid, and they go no further than here.
  let kind = case type_ {
    SubCommand -> SubCommandKind(options:)
    SubCommandGroup -> SubCommandGroupKind(options:)
    StringOption ->
      StringKind(
        suggestions: suggestions_from(choices, autocomplete),
        min_length:,
        max_length:,
      )
    IntegerOption ->
      IntegerKind(
        suggestions: suggestions_from(choices, autocomplete),
        min: whole(min_value),
        max: whole(max_value),
      )
    NumberOption ->
      NumberKind(
        suggestions: suggestions_from(choices, autocomplete),
        min: fractional(min_value),
        max: fractional(max_value),
      )
    ChannelOption -> ChannelKind(channel_types:)
    BooleanOption -> BooleanKind
    UserOption -> UserKind
    RoleOption -> RoleKind
    MentionableOption -> MentionableKind
    AttachmentOption -> AttachmentKind
    // An unknown type is the one case that cannot be narrowed, so it keeps
    // everything, the payload included: dropping a key here would delete it
    // from the command on the next bulk overwrite.
    UnknownOptionType(other) ->
      UnknownKind(
        type_: other,
        choices:,
        options:,
        channel_types:,
        min_value:,
        max_value:,
        min_length:,
        max_length:,
        autocomplete:,
        raw: raw_payload(raw),
      )
  }
  decode.success(ApplicationCommandOption(
    name:,
    name_localizations:,
    description:,
    description_localizations:,
    required:,
    kind:,
    name_localized:,
    description_localized:,
  ))
}

/// `RawPayload` is `glyde/model/component`'s, so the two places that keep an
/// unmodelled payload keep it the same way. The failure arm is unreachable
/// from here: `option_decoder` has already read this value as an object.
fn raw_payload(value: Dynamic) -> component.RawPayload {
  case component.raw_payload(value) {
    Ok(payload) -> payload
    Error(Nil) -> component.empty_raw_payload()
  }
}

/// Discord never sends both, and if it ever did the choices are the half that
/// carries data, so they win.
fn suggestions_from(
  choices: List(ApplicationCommandOptionChoice),
  autocomplete: Bool,
) -> Suggestions {
  case choices, autocomplete {
    [], False -> NoSuggestions
    [], True -> Autocomplete
    _, _ -> Choices(choices)
  }
}

/// `number_limit_decoder` picked the variant from the declared type, so an
/// INTEGER bound is already whole and a NUMBER one already fractional. The
/// other arm cannot be reached from `option_decoder`.
fn whole(limit: Option(OptionNumberLimit)) -> Option(Int) {
  case limit {
    Some(IntLimit(value)) -> Some(value)
    _ -> None
  }
}

fn fractional(limit: Option(OptionNumberLimit)) -> Option(Float) {
  case limit {
    Some(FloatLimit(value)) -> Some(value)
    _ -> None
  }
}

pub fn decoder() -> Decoder(ApplicationCommand) {
  use id <- decode.field("id", id.decoder())
  use type_ <- wire.defaulted_field("type", command_type_decoder(), ChatInput)
  use application_id <- decode.field("application_id", id.decoder())
  use guild_id <- wire.opt_field("guild_id", id.decoder())
  use name <- decode.field("name", decode.string)
  use name_localizations <- wire.opt_field(
    "name_localizations",
    localizations_decoder(),
  )
  use description <- wire.string_field("description", "")
  use description_localizations <- wire.opt_field(
    "description_localizations",
    localizations_decoder(),
  )
  use options <- wire.list_field("options", option_decoder())
  use default_member_permissions <- wire.opt_field(
    "default_member_permissions",
    permissions.decoder(),
  )
  use dm_permission <- wire.opt_field("dm_permission", decode.bool)
  use nsfw <- wire.flag_field("nsfw", False)
  use integration_types <- wire.list_field(
    "integration_types",
    integration_type_decoder(),
  )
  use contexts <- wire.opt_field(
    "contexts",
    decode.list(context_type_decoder()),
  )
  use version <- wire.string_field("version", "")
  use name_localized <- wire.opt_field("name_localized", decode.string)
  use description_localized <- wire.opt_field(
    "description_localized",
    decode.string,
  )
  decode.success(ApplicationCommand(
    id:,
    type_:,
    application_id:,
    guild_id:,
    name:,
    name_localizations:,
    description:,
    description_localizations:,
    options:,
    default_member_permissions:,
    dm_permission:,
    nsfw:,
    integration_types:,
    contexts:,
    version:,
    name_localized:,
    description_localized:,
  ))
}

pub fn choice_to_json(choice: ApplicationCommandOptionChoice) -> Json {
  wire.object([
    #("name", wire.put(wire.present(choice.name), json.string)),
    #(
      "name_localizations",
      wire.put(wire.opt(choice.name_localizations), localizations_to_json),
    ),
    #("value", wire.put(wire.present(choice.value), choice_value_to_json)),
  ])
}

pub fn option_to_json(option: ApplicationCommandOption) -> Json {
  let modelled =
    wire.entries(
      list.flatten([
        [
          #(
            "type",
            wire.put(
              wire.present(option_kind_type(option.kind)),
              option_type_to_json,
            ),
          ),
          #("name", wire.put(wire.present(option.name), json.string)),
          #(
            "name_localizations",
            wire.put(wire.opt(option.name_localizations), localizations_to_json),
          ),
          #(
            "description",
            wire.put(wire.present(option.description), json.string),
          ),
          #(
            "description_localizations",
            wire.put(
              wire.opt(option.description_localizations),
              localizations_to_json,
            ),
          ),
          #("required", wire.put(wire.present(option.required), json.bool)),
        ],
        kind_entries(option.kind),
      ]),
    )
  json.object(list.append(modelled, unmodelled_entries(option.kind, modelled)))
}

/// What an unknown option type arrived with and this build has no field for.
/// The modelled keys are written first and win, so an edit to `name` is not
/// undone by the name the option was decoded from.
fn unmodelled_entries(
  kind: OptionKind,
  written: List(#(String, Json)),
) -> List(#(String, Json)) {
  case kind {
    UnknownKind(raw:, ..) ->
      component.raw_payload_entries(raw)
      |> list.filter(fn(entry) {
        !list.any(written, fn(already) { already.0 == entry.0 })
      })
    _ -> []
  }
}

/// An option list as Discord wants it: every required option first, or it
/// answers 50035. `list.partition` keeps the order inside each group, so a
/// caller's own ordering survives.
pub fn options_to_json(options: List(ApplicationCommandOption)) -> Json {
  let #(required, rest) =
    list.partition(options, fn(option) { option.required })
  json.array(list.append(required, rest), option_to_json)
}

/// The type a kind sends, the way `component.row_child_type` works.
pub fn option_kind_type(kind: OptionKind) -> ApplicationCommandOptionType {
  case kind {
    SubCommandKind(..) -> SubCommand
    SubCommandGroupKind(..) -> SubCommandGroup
    StringKind(..) -> StringOption
    IntegerKind(..) -> IntegerOption
    NumberKind(..) -> NumberOption
    ChannelKind(..) -> ChannelOption
    BooleanKind -> BooleanOption
    UserKind -> UserOption
    RoleKind -> RoleOption
    MentionableKind -> MentionableOption
    AttachmentKind -> AttachmentOption
    UnknownKind(type_:, ..) -> UnknownOptionType(type_)
  }
}

/// Only the keys the kind actually has. `autocomplete` is one of them: Discord
/// takes it on STRING, INTEGER and NUMBER, and on a type this build has never
/// seen, where the key came from Discord in the first place.
fn kind_entries(kind: OptionKind) -> List(#(String, wire.Field(Json))) {
  case kind {
    SubCommandKind(options:) | SubCommandGroupKind(options:) -> [
      #("options", wire.put(wire.opt_list(options), options_to_json)),
    ]

    StringKind(suggestions:, min_length:, max_length:) ->
      list.flatten([
        suggestion_entries(suggestions),
        [
          #("min_length", wire.put(wire.opt(min_length), json.int)),
          #("max_length", wire.put(wire.opt(max_length), json.int)),
        ],
      ])

    IntegerKind(suggestions:, min:, max:) ->
      list.flatten([
        suggestion_entries(suggestions),
        [
          #("min_value", wire.put(wire.opt(min), json.int)),
          #("max_value", wire.put(wire.opt(max), json.int)),
        ],
      ])

    NumberKind(suggestions:, min:, max:) ->
      list.flatten([
        suggestion_entries(suggestions),
        [
          #("min_value", wire.put(wire.opt(min), json.float)),
          #("max_value", wire.put(wire.opt(max), json.float)),
        ],
      ])

    ChannelKind(channel_types:) -> [
      #(
        "channel_types",
        wire.put_list(
          wire.opt_list(channel_types),
          channel.channel_type_to_json,
        ),
      ),
    ]

    BooleanKind | UserKind | RoleKind | MentionableKind | AttachmentKind -> []

    // Everything this build can read, back out the way it came in. What it
    // cannot read is written after these by `unmodelled_entries`.
    UnknownKind(
      type_: _,
      choices:,
      options:,
      channel_types:,
      min_value:,
      max_value:,
      min_length:,
      max_length:,
      autocomplete:,
      raw: _,
    ) -> [
      #("choices", wire.put_list(wire.opt_list(choices), choice_to_json)),
      #("options", wire.put(wire.opt_list(options), options_to_json)),
      #(
        "channel_types",
        wire.put_list(
          wire.opt_list(channel_types),
          channel.channel_type_to_json,
        ),
      ),
      #("min_value", wire.put(wire.opt(min_value), number_limit_to_json)),
      #("max_value", wire.put(wire.opt(max_value), number_limit_to_json)),
      #("min_length", wire.put(wire.opt(min_length), json.int)),
      #("max_length", wire.put(wire.opt(max_length), json.int)),
      #("autocomplete", autocomplete_entry(autocomplete)),
    ]
  }
}

/// One key or the other, never the pair.
fn suggestion_entries(value: Suggestions) -> List(#(String, wire.Field(Json))) {
  case value {
    Choices(choices) -> [
      #("choices", wire.put_list(wire.opt_list(choices), choice_to_json)),
    ]
    Autocomplete -> [#("autocomplete", autocomplete_entry(True))]
    NoSuggestions -> []
  }
}

/// False is Discord's default, so it is the same key left out.
fn autocomplete_entry(value: Bool) -> wire.Field(Json) {
  case value {
    True -> wire.put(wire.present(True), json.bool)
    False -> wire.absent()
  }
}

/// Sorted by locale: `Dict` iteration order is unspecified and these become
/// request bytes.
pub fn localizations_to_json(entries: Dict(String, String)) -> Json {
  entries
  |> dict.to_list
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> list.map(fn(entry) { #(entry.0, json.string(entry.1)) })
  |> json.object
}
