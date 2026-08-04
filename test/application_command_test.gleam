import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import glyde/application_command.{
  CreateApplicationCommand, EditApplicationCommand, EditGlobalCommand,
  GlobalCommand,
} as command
import glyde/channel
import glyde/field.{Absent, Null, Present}
import glyde/id
import glyde/permissions
import glyde/rest/body

fn parse(text: String) -> Result(command.ApplicationCommand, json.DecodeError) {
  json.parse(text, command.decoder())
}

fn parse_option(
  text: String,
) -> Result(command.ApplicationCommandOption, json.DecodeError) {
  json.parse(
    text,
    decode.then(command.option_decoder(), fn(found) {
      case found {
        Some(value) -> decode.success(value)
        None -> decode.failure(command.string_option("", ""), "modelled")
      }
    }),
  )
}

pub fn command_type_round_trips_test() {
  list.each(
    [
      #(1, command.ChatInput),
      #(2, command.UserCommand),
      #(3, command.MessageCommand),
      #(4, command.PrimaryEntryPoint),
    ],
    fn(row) {
      assert command.command_type_from_int(row.0) == Some(row.1)
      assert command.command_type_to_int(row.1) == row.0
    },
  )
  assert command.command_type_from_int(99) == None
}

pub fn option_type_round_trips_every_value_test() {
  list.each(
    [
      #(1, command.SubCommand),
      #(2, command.SubCommandGroup),
      #(3, command.StringOption),
      #(4, command.IntegerOption),
      #(5, command.BooleanOption),
      #(6, command.UserOption),
      #(7, command.ChannelOption),
      #(8, command.RoleOption),
      #(9, command.MentionableOption),
      #(10, command.NumberOption),
      #(11, command.AttachmentOption),
    ],
    fn(row) {
      assert command.option_type_from_int(row.0) == Some(row.1)
      assert command.option_type_to_int(row.1) == row.0
    },
  )
  assert command.option_type_from_int(12) == None
}

pub fn context_and_integration_types_round_trip_test() {
  list.each(
    [
      #(0, command.GuildContext),
      #(1, command.BotDmContext),
      #(2, command.PrivateChannelContext),
    ],
    fn(row) {
      assert command.context_type_from_int(row.0) == Some(row.1)
      assert command.context_type_to_int(row.1) == row.0
    },
  )
  assert command.context_type_from_int(7) == None
  list.each([#(0, command.GuildInstall), #(1, command.UserInstall)], fn(row) {
    assert command.integration_type_from_int(row.0) == Some(row.1)
    assert command.integration_type_to_int(row.1) == row.0
  })
  assert command.integration_type_from_int(7) == None
}

/// An absent `type` means CHAT_INPUT, and Discord omits it often.
pub fn an_absent_type_means_chat_input_test() {
  let assert Ok(found) =
    parse(
      "{\"id\":\"1\",\"application_id\":\"2\",\"name\":\"blep\",\"description\":\"send a bleep\",\"version\":\"3\"}",
    )
  assert found.type_ == command.ChatInput
}

/// USER and MESSAGE commands carry `""` and never null.
pub fn a_context_menu_command_has_an_empty_description_test() {
  let assert Ok(found) =
    parse(
      "{\"id\":\"1\",\"application_id\":\"2\",\"type\":2,\"name\":\"High Five\",\"description\":\"\",\"version\":\"3\"}",
    )
  assert found.type_ == command.UserCommand
  assert found.description == ""
}

/// A `type` this build has no name for is a glyde bug, so it fails the decode
/// rather than making every caller unwrap.
pub fn an_unmodelled_command_type_fails_test() {
  let assert Error(_) =
    parse(
      "{\"id\":\"1\",\"application_id\":\"2\",\"type\":99,\"name\":\"x\",\"description\":\"\",\"version\":\"3\"}",
    )
}

/// `None` is no override; `"0"` is admins only.
pub fn default_member_permissions_keeps_none_apart_from_zero_test() {
  let assert Ok(defaulted) =
    parse(
      "{\"id\":\"1\",\"application_id\":\"2\",\"name\":\"n\",\"description\":\"d\",\"default_member_permissions\":null}",
    )
  assert defaulted.default_member_permissions == None

  let assert Ok(admins) =
    parse(
      "{\"id\":\"1\",\"application_id\":\"2\",\"name\":\"n\",\"description\":\"d\",\"default_member_permissions\":\"0\"}",
    )
  let assert Some(perms) = admins.default_member_permissions
  assert permissions.to_string(perms) == "0"
}

/// `version` is a snowflake despite the name.
pub fn version_stays_a_string_test() {
  let assert Ok(found) =
    parse(
      "{\"id\":\"1\",\"application_id\":\"2\",\"name\":\"n\",\"description\":\"d\",\"version\":\"1234567890123456789\"}",
    )
  assert found.version == "1234567890123456789"
}

/// Null means every context and absent means the app did not say; Discord
/// treats them the same.
pub fn contexts_and_integration_types_decode_test() {
  let assert Ok(found) =
    parse(
      "{\"id\":\"1\",\"application_id\":\"2\",\"name\":\"n\",\"description\":\"d\",\"integration_types\":[0,1],\"contexts\":[0,1,2]}",
    )
  assert found.integration_types == [command.GuildInstall, command.UserInstall]
  assert found.contexts
    == Some([
      command.GuildContext,
      command.BotDmContext,
      command.PrivateChannelContext,
    ])

  let assert Ok(everywhere) =
    parse(
      "{\"id\":\"1\",\"application_id\":\"2\",\"name\":\"n\",\"description\":\"d\",\"contexts\":null}",
    )
  assert everywhere.contexts == None
}

pub fn localizations_decode_test() {
  let assert Ok(found) =
    parse(
      "{\"id\":\"1\",\"application_id\":\"2\",\"name\":\"birthday\",\"description\":\"d\",\"name_localizations\":{\"fr\":\"anniversaire\",\"de\":\"geburtstag\"},\"description_localizations\":null,\"name_localized\":\"anniversaire\"}",
    )
  let assert Some(names) = found.name_localizations
  assert dict.get(names, "fr") == Ok("anniversaire")
  assert dict.get(names, "de") == Ok("geburtstag")
  assert found.description_localizations == None
  assert found.name_localized == Some("anniversaire")
}

/// Three levels is the deepest Discord allows.
pub fn options_nest_three_deep_test() {
  let assert Ok(group) =
    parse_option(
      "{\"type\":2,\"name\":\"permissions\",\"description\":\"g\",\"options\":[{\"type\":1,\"name\":\"user\",\"description\":\"s\",\"options\":[{\"type\":6,\"name\":\"who\",\"description\":\"o\",\"required\":true}]}]}",
    )
  let assert command.SubCommandGroupKind(options: [sub]) = group.kind
  let assert command.SubCommandKind(options: [leaf]) = sub.kind
  assert leaf.kind == command.UserKind
  assert leaf.required == True
}

/// The same enum the channel model uses; a value it has no name for is
/// dropped from the list.
pub fn channel_types_on_an_option_filter_unmodelled_test() {
  let assert Ok(found) =
    parse_option(
      "{\"type\":7,\"name\":\"where\",\"description\":\"d\",\"channel_types\":[0,2,99]}",
    )
  assert found.kind
    == command.ChannelKind(channel_types: [
      channel.GuildText,
      channel.GuildVoice,
    ])
}

/// A bound only exists on the three kinds that have one, so a `min_length` on
/// an INTEGER is a compile error rather than a 50035.
pub fn only_the_kinds_with_bounds_carry_them_test() {
  let assert Ok(text) =
    parse_option(
      "{\"type\":3,\"name\":\"word\",\"description\":\"d\",\"min_length\":1,\"max_length\":6}",
    )
  assert text.kind
    == command.StringKind(
      suggestions: command.NoSuggestions,
      min_length: Some(1),
      max_length: Some(6),
    )

  let assert Ok(flag) =
    parse_option("{\"type\":5,\"name\":\"loud\",\"description\":\"d\"}")
  assert flag.kind == command.BooleanKind
}

/// Sending an INTEGER bound back as `5.0` is a 400, so the declared type picks
/// the variant, not the JSON shape.
pub fn integer_option_bounds_stay_whole_test() {
  let assert Ok(found) =
    parse_option(
      "{\"type\":4,\"name\":\"count\",\"description\":\"d\",\"min_value\":1,\"max_value\":100}",
    )
  assert found.kind
    == command.IntegerKind(
      suggestions: command.NoSuggestions,
      min: Some(1),
      max: Some(100),
    )
}

/// A NUMBER bound is a double even when Discord writes it without a decimal
/// point.
pub fn number_option_bounds_stay_fractional_test() {
  let assert Ok(written_whole) =
    parse_option(
      "{\"type\":10,\"name\":\"ratio\",\"description\":\"d\",\"min_value\":5,\"max_value\":10.5}",
    )
  assert written_whole.kind
    == command.NumberKind(
      suggestions: command.NoSuggestions,
      min: Some(5.0),
      max: Some(10.5),
    )

  let assert Ok(written_decimal) =
    parse_option(
      "{\"type\":10,\"name\":\"ratio\",\"description\":\"d\",\"min_value\":5.0}",
    )
  assert written_decimal.kind
    == command.NumberKind(
      suggestions: command.NoSuggestions,
      min: Some(5.0),
      max: None,
    )
}

/// An option whose type this build has no name for is dropped from `options`
/// on decode, and the known one beside it survives.
pub fn an_unmodelled_option_type_is_filtered_test() {
  let assert Ok(found) =
    parse(
      "{\"id\":\"1\",\"application_id\":\"2\",\"name\":\"n\",\"description\":\"d\",\"options\":[{\"type\":42,\"name\":\"mystery\",\"description\":\"d\"},{\"type\":3,\"name\":\"kept\",\"description\":\"d\"}]}",
    )
  let assert [kept] = found.options
  assert kept.name == "kept"
  assert kept.kind
    == command.StringKind(
      suggestions: command.NoSuggestions,
      min_length: None,
      max_length: None,
    )
}

/// A choice value is the option's own type, so a STRING choice is a `String`
/// and an INTEGER choice an `Int`, no wrapper to unwrap. The NUMBER case
/// checks a whole `1` still comes out `1.0`.
pub fn choice_values_follow_the_declared_option_type_test() {
  let assert Ok(strings) =
    parse_option(
      "{\"type\":3,\"name\":\"animal\",\"description\":\"d\",\"choices\":[{\"name\":\"Dog\",\"value\":\"dog\"}]}",
    )
  let assert command.StringKind(suggestions: command.Choices(choices), ..) =
    strings.kind
  assert list.map(choices, fn(choice) { choice.value }) == ["dog"]

  let assert Ok(ints) =
    parse_option(
      "{\"type\":4,\"name\":\"count\",\"description\":\"d\",\"choices\":[{\"name\":\"One\",\"value\":1}]}",
    )
  let assert command.IntegerKind(suggestions: command.Choices(choices), ..) =
    ints.kind
  assert list.map(choices, fn(choice) { choice.value }) == [1]

  let assert Ok(floats) =
    parse_option(
      "{\"type\":10,\"name\":\"ratio\",\"description\":\"d\",\"choices\":[{\"name\":\"Half\",\"value\":0.5},{\"name\":\"One\",\"value\":1}]}",
    )
  let assert command.NumberKind(suggestions: command.Choices(choices), ..) =
    floats.kind
  assert list.map(choices, fn(choice) { choice.value }) == [0.5, 1.0]
}

pub fn choice_value_encodes_in_its_own_type_test() {
  assert json.to_string(command.choice_value_to_json(command.StringChoice("a")))
    == "\"a\""
  assert json.to_string(command.choice_value_to_json(command.IntChoice(1)))
    == "1"
  assert json.to_string(command.choice_value_to_json(command.FloatChoice(0.5)))
    == "0.5"
}

/// Discord reads a null as an instruction, not as an absence.
pub fn option_encoding_omits_what_was_never_set_test() {
  let assert Ok(found) =
    parse_option(
      "{\"type\":3,\"name\":\"animal\",\"description\":\"pick one\"}",
    )
  assert json.to_string(command.option_to_json(found))
    == "{\"type\":3,\"name\":\"animal\",\"description\":\"pick one\",\"required\":false}"
}

/// The same input builds the same bytes every run, which is what makes a
/// request diffable.
pub fn option_encoding_round_trips_its_bounds_test() {
  let assert Ok(found) =
    parse_option(
      "{\"type\":4,\"name\":\"count\",\"description\":\"how many\",\"required\":true,\"min_value\":1,\"max_value\":100}",
    )
  assert json.to_string(command.option_to_json(found))
    == "{\"type\":4,\"name\":\"count\",\"description\":\"how many\",\"required\":true,\"min_value\":1,\"max_value\":100}"
}

/// Discord answers 50035 when an optional option comes before a required one,
/// so the encoder puts the required ones first and keeps the order inside each
/// group.
pub fn required_options_are_encoded_first_test() {
  let names =
    [
      command.string_option(name: "second", description: "d"),
      required(command.string_option(name: "first", description: "d")),
      command.string_option(name: "third", description: "d"),
      required(command.integer_option(name: "count", description: "d")),
    ]
    |> command.options_to_json
    |> json.to_string

  assert string.contains(names, "\"name\":\"first\"")
  let assert [_, after_first] = string.split(names, "\"name\":\"first\"")
  assert string.contains(after_first, "\"name\":\"count\"")
  let assert [_, after_count] = string.split(after_first, "\"name\":\"count\"")
  assert string.contains(after_count, "\"name\":\"second\"")
  let assert [_, after_second] =
    string.split(after_count, "\"name\":\"second\"")
  assert string.contains(after_second, "\"name\":\"third\"")
}

/// A subcommand's own options are sorted too. The payload layer only ever sees
/// the top level, so this has to happen here.
pub fn a_subcommands_options_are_sorted_as_well_test() {
  let encoded =
    command.sub_command(name: "get", description: "d", options: [
      command.string_option(name: "optional", description: "d"),
      required(command.user_option(name: "who", description: "d")),
    ])
    |> command.option_to_json
    |> json.to_string

  let assert [_, after_who] = string.split(encoded, "\"name\":\"who\"")
  assert string.contains(after_who, "\"name\":\"optional\"")
}

/// One string option used to mean writing sixteen fields.
pub fn the_constructors_default_everything_discord_defaults_test() {
  assert json.to_string(
      command.option_to_json(command.string_option(
        name: "animal",
        description: "pick one",
      )),
    )
    == "{\"type\":3,\"name\":\"animal\",\"description\":\"pick one\",\"required\":false}"

  assert json.to_string(
      command.option_to_json(command.channel_option(
        name: "where",
        description: "d",
      )),
    )
    == "{\"type\":7,\"name\":\"where\",\"description\":\"d\",\"required\":false}"
}

fn required(
  option: command.ApplicationCommandOption,
) -> command.ApplicationCommandOption {
  command.ApplicationCommandOption(..option, required: True)
}

/// A `Dict` has no stable iteration order, so the encoder sorts.
pub fn localizations_encode_in_a_stable_order_test() {
  let assert Ok(found) =
    parse_option(
      "{\"type\":3,\"name\":\"animal\",\"description\":\"d\",\"name_localizations\":{\"fr\":\"animal\",\"de\":\"tier\",\"es\":\"animal\"}}",
    )
  assert json.to_string(command.option_to_json(found))
    == "{\"type\":3,\"name\":\"animal\",\"name_localizations\":{\"de\":\"tier\",\"es\":\"animal\",\"fr\":\"animal\"},\"description\":\"d\",\"required\":false}"
}

pub fn choice_encoding_test() {
  let assert Ok(found) =
    json.parse(
      "{\"name\":\"Dog\",\"value\":\"dog\"}",
      command.choice_decoder(decode.string),
    )
  assert json.to_string(command.choice_to_json(found, json.string))
    == "{\"name\":\"Dog\",\"value\":\"dog\"}"
}

pub fn decodes_a_full_command_test() {
  let assert Ok(found) =
    parse(
      "{\"id\":\"1234567890123456789\",\"type\":1,\"application_id\":\"9876543210987654321\",\"guild_id\":\"41771983423143937\",\"name\":\"permissions\",\"description\":\"Get or edit permissions\",\"options\":[{\"type\":2,\"name\":\"user\",\"description\":\"for a user\",\"options\":[{\"type\":1,\"name\":\"get\",\"description\":\"get\",\"options\":[{\"type\":6,\"name\":\"user\",\"description\":\"the user\",\"required\":true}]}]}],\"default_member_permissions\":\"8\",\"dm_permission\":false,\"nsfw\":false,\"integration_types\":[0],\"contexts\":[0],\"version\":\"1234567890123456790\"}",
    )
  assert id.to_string(found.id) == "1234567890123456789"
  assert found.type_ == command.ChatInput
  assert option.map(found.guild_id, id.to_string) == Some("41771983423143937")
  assert found.dm_permission == Some(False)
  assert found.nsfw == False
  let assert [group] = found.options
  assert command.option_kind_type(group.kind) == command.SubCommandGroup
}

/// An option whose type this build has no name for is `None`, so it never
/// reaches `options`.
pub fn an_unmodelled_option_type_decodes_as_none_test() {
  assert json.parse(
      "{\"type\":42,\"name\":\"mystery\",\"description\":\"d\"}",
      command.option_decoder(),
    )
    == Ok(None)
}

pub fn a_command_without_its_required_ids_fails_test() {
  let assert Error(_) = parse("{\"application_id\":\"2\",\"name\":\"n\"}")
  let assert Error(_) = parse("{\"id\":\"1\",\"name\":\"n\"}")
  let assert Error(_) = parse("{\"id\":\"1\",\"application_id\":\"2\"}")
}

/// The guild shape is the shared one, so most of these encode through it.
fn created(value: command.CreateApplicationCommand) -> String {
  json.to_string(command.guild_to_json(value))
}

fn created_globally(value: command.GlobalCommand) -> String {
  json.to_string(command.global_to_json(value))
}

fn edited(value: command.EditApplicationCommand) -> String {
  payload_json(command.edit_guild_body(value))
}

fn edited_global(value: command.EditGlobalCommand) -> String {
  payload_json(command.edit_global_body(value))
}

/// What the edit tests pin is the JSON document the body carries.
fn payload_json(sent: body.Body) -> String {
  let assert body.Form(payload:, files: _) = sent
  json.to_string(json.object(payload))
}

fn option(name: String) -> command.ApplicationCommandOption {
  command.string_option(name: name, description: "an option")
}

pub fn a_slash_command_needs_a_name_and_a_description_test() {
  assert created(command.new_chat_input(
      name: "ping",
      description: "Check the bot is alive",
    ))
    == "{\"name\":\"ping\",\"description\":\"Check the bot is alive\",\"type\":1}"
}

/// The kinds differ by one wire number, and the wrong one registers a slash
/// command where a right-click was meant.
pub fn each_kind_states_its_own_type_test() {
  let cases = [
    #(command.new_chat_input(name: "ping", description: "d"), "\"type\":1"),
    #(command.new_user_command(name: "Report"), "\"type\":2"),
    #(command.new_message_command(name: "Pin it"), "\"type\":3"),
  ]

  list.each(cases, fn(row) {
    let #(value, kind) = row
    assert string.contains(created(value), kind)
  })
}

pub fn a_context_menu_command_is_just_a_name_test() {
  assert created(command.new_user_command(name: "Report"))
    == "{\"name\":\"Report\",\"type\":2}"

  assert created(command.new_message_command(name: "Pin it"))
    == "{\"name\":\"Pin it\",\"type\":3}"
}

/// Discord answers 400 to a description or an option on a context-menu command.
pub fn a_context_menu_command_carries_no_description_test() {
  let encoded = created(command.new_user_command(name: "Report"))

  assert !string.contains(encoded, "description")
  assert !string.contains(encoded, "options")
}

pub fn options_ride_along_in_the_order_given_test() {
  let options = [option("first"), option("second")]
  let encoded = json.to_string(json.array(options, command.option_to_json))

  assert created(command.chat_input(
      name: "echo",
      description: "Say it back",
      options: options,
    ))
    == "{\"name\":\"echo\",\"description\":\"Say it back\",\"options\":"
    <> encoded
    <> ",\"type\":1}"
}

/// Discord answers 50035 when an optional option comes first, and the encoder
/// fixes the order rather than passing the mistake on.
pub fn required_options_are_moved_to_the_front_test() {
  let wanted = command.ApplicationCommandOption(..option("who"), required: True)

  let encoded =
    created(
      command.chat_input(name: "echo", description: "d", options: [
        option("maybe"),
        wanted,
      ]),
    )

  let assert [_, after_wanted] = string.split(encoded, "\"name\":\"who\"")
  assert string.contains(after_wanted, "\"name\":\"maybe\"")
}

/// A description and an option live on the slash-command kind only, so a
/// context-menu body has no field to put either in.
pub fn the_kind_is_what_the_three_constructors_differ_by_test() {
  let menu = command.new_user_command(name: "Report")
  assert menu.kind == command.AsUserCommand

  let slash = command.new_chat_input(name: "ping", description: "d")
  assert slash.kind
    == command.AsChatInput(
      description: "d",
      description_localizations: dict.new(),
      options: [],
    )
}

/// False is Discord's own default, so writing it says nothing.
pub fn nsfw_is_only_written_when_true_test() {
  let base = command.new_chat_input(name: "ping", description: "d")

  assert !string.contains(created(base), "nsfw")

  assert string.contains(
    created(CreateApplicationCommand(..base, nsfw: True)),
    "\"nsfw\":true",
  )
}

/// Discord takes permission bitfields as decimal strings, never numbers.
pub fn admins_only_is_the_string_zero_test() {
  let base = command.new_chat_input(name: "ban", description: "d")

  let value =
    CreateApplicationCommand(
      ..base,
      default_member_permissions: Some(permissions.none()),
    )

  assert string.contains(created(value), "\"default_member_permissions\":\"0\"")
}

pub fn a_named_permission_keeps_its_decimal_string_test() {
  let base = command.new_chat_input(name: "ban", description: "d")

  let value =
    CreateApplicationCommand(
      ..base,
      default_member_permissions: Some(
        permissions.new([permissions.BanMembers]),
      ),
    )

  assert string.contains(created(value), "\"default_member_permissions\":\"4\"")
}

/// Both are a 400 on a guild command, so only the global shape has a field
/// for either: `guild_body` takes a value that cannot hold one.
pub fn install_targets_and_contexts_are_number_arrays_test() {
  let base = command.new_chat_input(name: "ping", description: "d")

  let value =
    GlobalCommand(
      ..command.global(base),
      integration_types: [command.GuildInstall, command.UserInstall],
      contexts: [command.GuildContext, command.PrivateChannelContext],
    )

  assert created_globally(value)
    == "{\"name\":\"ping\",\"description\":\"d\",\"type\":1,"
    <> "\"integration_types\":[0,1],\"contexts\":[0,2]}"
}

/// `global` adds those two keys and nothing else, so a command that sets
/// neither is the same bytes in both scopes.
pub fn the_two_scopes_agree_on_everything_else_test() {
  let base = command.new_chat_input(name: "ping", description: "d")

  assert command.global_body(command.global(base)) == command.guild_body(base)
}

/// A `Dict` has no stable iteration order, so the encoder sorts by locale and
/// the same command is always the same bytes.
pub fn localizations_are_written_in_locale_order_test() {
  let base = command.new_chat_input(name: "ping", description: "d")

  let value =
    CreateApplicationCommand(
      ..base,
      name_localizations: dict.from_list([
        #("fr", "ping-fr"),
        #("de", "ping-de"),
      ]),
    )

  assert string.contains(
    created(value),
    "\"name_localizations\":{\"de\":\"ping-de\",\"fr\":\"ping-fr\"}",
  )
}

pub fn a_body_carries_the_same_fields_as_the_json_test() {
  assert command.guild_body(command.new_chat_input(
      name: "ping",
      description: "d",
    ))
    == body.json([
      #("name", json.string("ping")),
      #("description", json.string("d")),
      #("type", json.int(1)),
    ])
}

/// The bulk overwrite is a top-level array, not an object, and until `Body`
/// could hold one the route had no body builder at all.
pub fn a_bulk_body_is_a_top_level_array_test() {
  let commands = [
    command.new_chat_input(name: "ping", description: "d"),
    command.new_user_command(name: "Report"),
  ]

  assert body.encode(
      command.bulk_guild_body(commands),
      boundary: body.default_boundary,
    )
    == #(
      Some("application/json"),
      body.Text(
        "[{\"name\":\"ping\",\"description\":\"d\",\"type\":1},"
        <> "{\"name\":\"Report\",\"type\":2}]",
      ),
    )
}

/// Discord reads `[]` as "delete every command in this scope", so it has to
/// survive as an empty array rather than becoming an empty object.
pub fn an_empty_bulk_body_stays_an_array_test() {
  assert body.encode(
      command.bulk_guild_body([]),
      boundary: body.default_boundary,
    )
    == #(Some("application/json"), body.Text("[]"))

  assert body.encode(
      command.bulk_global_body([]),
      boundary: body.default_boundary,
    )
    == #(Some("application/json"), body.Text("[]"))
}

pub fn an_empty_edit_is_an_empty_object_test() {
  assert edited(command.edit()) == "{}"
}

pub fn an_edit_writes_only_what_was_set_test() {
  let value =
    EditApplicationCommand(
      ..command.edit(),
      description: Some("A better description"),
    )

  assert edited(value) == "{\"description\":\"A better description\"}"
}

/// An option list is replaced whole, so `Some([])` is how a command loses its
/// options.
pub fn an_empty_option_list_clears_the_options_test() {
  assert edited(EditApplicationCommand(..command.edit(), options: Some([])))
    == "{\"options\":[]}"
}

/// Absent leaves the visibility alone, null restores the default, and "0"
/// hides the command from everyone but admins.
pub fn the_three_states_of_the_default_permission_test() {
  let cases = [
    #(Absent, "{}"),
    #(Null, "{\"default_member_permissions\":null}"),
    #(Present(permissions.none()), "{\"default_member_permissions\":\"0\"}"),
  ]

  list.each(cases, fn(row) {
    let #(value, expected) = row
    let edit =
      EditApplicationCommand(
        ..command.edit(),
        default_member_permissions: value,
      )

    assert edited(edit) == expected
  })
}

pub fn clearing_the_contexts_restores_all_of_them_test() {
  assert edited_global(
      EditGlobalCommand(..command.edit_global(), contexts: Null),
    )
    == "{\"contexts\":null}"
}

pub fn clearing_the_localizations_removes_them_test() {
  let value =
    EditApplicationCommand(
      ..command.edit(),
      name_localizations: Null,
      description_localizations: Null,
    )

  assert edited(value)
    == "{\"name_localizations\":null,\"description_localizations\":null}"
}

pub fn an_edited_localization_set_is_sorted_too_test() {
  let value =
    EditApplicationCommand(
      ..command.edit(),
      name_localizations: Present(
        dict.from_list([#("fr", "b"), #("de", "a"), #("bg", "c")]),
      ),
    )

  assert edited(value)
    == "{\"name_localizations\":{\"bg\":\"c\",\"de\":\"a\",\"fr\":\"b\"}}"
}

/// Discord answers 400 to a null on these five, so they are plain options and
/// the clear does not typecheck.
pub fn the_fields_that_cannot_be_cleared_write_a_value_or_nothing_test() {
  let value =
    EditGlobalCommand(
      ..command.edit_global(),
      command: EditApplicationCommand(
        ..command.edit(),
        name: Some("renamed"),
        nsfw: Some(False),
      ),
      integration_types: Some([command.UserInstall]),
    )

  assert edited_global(value)
    == "{\"name\":\"renamed\",\"nsfw\":false,\"integration_types\":[1]}"
}

pub fn an_edit_body_carries_the_same_fields_test() {
  let value = EditApplicationCommand(..command.edit(), name: Some("renamed"))

  assert command.edit_guild_body(value)
    == body.json([#("name", json.string("renamed"))])
}
