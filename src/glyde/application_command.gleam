//// Application commands: what a bot registers, as opposed to what a user
//// invoked. `glyde/interaction` is the other half.
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
import gleam/result
import gleam/string
import glyde/channel
import glyde/component
import glyde/field.{type Field, Absent, Present}
import glyde/id
import glyde/permissions.{type Permissions}
import glyde/rest.{type Call}
import glyde/rest/body.{type Body}
import glyde/rest/query
import glyde/rest/seg
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

/// `RawPayload` is `glyde/component`'s, so the two places that keep an
/// unmodelled payload keep it the same way. The failure arm is unreachable
/// from here: `option_decoder` has already read this value as an object.
fn raw_payload(value: Dynamic) -> component.RawPayload {
  component.raw_payload(value)
  |> result.lazy_unwrap(component.empty_raw_payload)
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

// -- Bodies for creating and editing commands --------------------------------

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

/// A command registered globally. `integration_types` and `contexts` are a 400
/// on the guild route, so they exist here and nowhere else.
pub type GlobalCommand {
  GlobalCommand(
    command: CreateApplicationCommand,
    /// Empty writes no key.
    integration_types: List(ApplicationIntegrationType),
    contexts: List(InteractionContextType),
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
  AsChatInput(
    /// 1 to 100 characters.
    description: String,
    description_localizations: Dict(String, String),
    options: List(ApplicationCommandOption),
  )
  /// Right-click on a user.
  AsUserCommand
  /// Right-click on a message.
  AsMessageCommand
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
    AsChatInput(description:, description_localizations: dict.new(), options:),
  )
}

pub fn new_user_command(name name: String) -> CreateApplicationCommand {
  new_command(name, AsUserCommand)
}

pub fn new_message_command(name name: String) -> CreateApplicationCommand {
  new_command(name, AsMessageCommand)
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
    AsChatInput(description:, description_localizations:, options:) -> [
      #("description", Present(json.string(description))),
      #(
        "description_localizations",
        created_localizations(description_localizations),
      ),
      #("options", wire.put(wire.opt_list(options), options_to_json)),
    ]
    AsUserCommand | AsMessageCommand -> []
  }
}

/// The wire number, which is the only thing the two context-menu kinds change.
fn command_type(kind: CreateKind) -> Json {
  command_type_to_json(case kind {
    AsChatInput(..) -> ChatInput
    AsUserCommand -> UserCommand
    AsMessageCommand -> MessageCommand
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
    integration_types: Option(List(ApplicationIntegrationType)),
    /// `Null` restores all contexts.
    contexts: Field(List(InteractionContextType)),
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
    #("options", wire.put(wire.opt(command.options), options_to_json)),
    #(
      "default_member_permissions",
      wire.put(command.default_member_permissions, permissions.to_json),
    ),
    #("nsfw", wire.put(wire.opt(command.nsfw), json.bool)),
  ]
}

fn localizations(value: Field(Dict(String, String))) -> Field(Json) {
  wire.put(value, localizations_to_json)
}

/// A create has no null to send, so an empty map is how it says nothing.
fn created_localizations(entries: Dict(String, String)) -> Field(Json) {
  localizations(case dict.is_empty(entries) {
    True -> Absent
    False -> Present(entries)
  })
}

fn integrations(value: Field(List(ApplicationIntegrationType))) -> Field(Json) {
  wire.put_list(value, integration_type_to_json)
}

fn context_list(value: Field(List(InteractionContextType))) -> Field(Json) {
  wire.put_list(value, context_type_to_json)
}

// -- Endpoints ---------------------------------------------------------------

/// `GET /applications/{application.id}/commands`. `name` and `description`
/// arrive either way. `with_localizations` swaps the single `name_localized`
/// and `description_localized` for the full `name_localizations` and
/// `description_localizations` maps.
pub fn get_global_commands(
  application: id.ApplicationId,
  with_localizations with_localizations: Bool,
) -> Call(List(ApplicationCommand)) {
  rest.get(global_at(application), rest.Decoded(decode.list(decoder())))
  |> rest.query(localizations_param(with_localizations))
}

/// `POST /applications/{application.id}/commands`. Safe to run on every boot:
/// Discord answers 200 and updates in place when the name already exists.
pub fn create_global_command(
  application: id.ApplicationId,
  create: GlobalCommand,
) -> Call(ApplicationCommand) {
  rest.post(
    global_at(application),
    global_body(create),
    rest.Decoded(decoder()),
  )
}

pub fn get_global_command(
  application: id.ApplicationId,
  command_id: id.CommandId,
) -> Call(ApplicationCommand) {
  rest.get(global_one_at(application, command_id), rest.Decoded(decoder()))
}

/// `PATCH /applications/{application.id}/commands/{id}`.
pub fn edit_global_command(
  application: id.ApplicationId,
  command_id: id.CommandId,
  edit: EditGlobalCommand,
) -> Call(ApplicationCommand) {
  rest.patch(
    global_one_at(application, command_id),
    edit_global_body(edit),
    rest.Decoded(decoder()),
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
  commands: List(GlobalCommand),
) -> Call(List(ApplicationCommand)) {
  rest.put(
    global_at(application),
    bulk_global_body(commands),
    rest.Decoded(decode.list(decoder())),
  )
}

pub fn get_guild_commands(
  application: id.ApplicationId,
  guild: id.GuildId,
  with_localizations with_localizations: Bool,
) -> Call(List(ApplicationCommand)) {
  rest.get(guild_at(application, guild), rest.Decoded(decode.list(decoder())))
  |> rest.query(localizations_param(with_localizations))
}

/// `POST /applications/{application.id}/guilds/{guild.id}/commands`. Appears
/// immediately, where a global command can take an hour to propagate.
pub fn create_guild_command(
  application: id.ApplicationId,
  guild: id.GuildId,
  create: CreateApplicationCommand,
) -> Call(ApplicationCommand) {
  rest.post(
    guild_at(application, guild),
    guild_body(create),
    rest.Decoded(decoder()),
  )
}

pub fn get_guild_command(
  application: id.ApplicationId,
  guild: id.GuildId,
  command_id: id.CommandId,
) -> Call(ApplicationCommand) {
  rest.get(
    guild_one_at(application, guild, command_id),
    rest.Decoded(decoder()),
  )
}

/// `PATCH /applications/{application.id}/guilds/{guild.id}/commands/{id}`.
pub fn edit_guild_command(
  application: id.ApplicationId,
  guild: id.GuildId,
  command_id: id.CommandId,
  edit: EditApplicationCommand,
) -> Call(ApplicationCommand) {
  rest.patch(
    guild_one_at(application, guild, command_id),
    edit_guild_body(edit),
    rest.Decoded(decoder()),
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
  commands: List(CreateApplicationCommand),
) -> Call(List(ApplicationCommand)) {
  rest.put(
    guild_at(application, guild),
    bulk_guild_body(commands),
    rest.Decoded(decode.list(decoder())),
  )
}

fn localizations_param(wanted: Bool) -> List(query.Param) {
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
