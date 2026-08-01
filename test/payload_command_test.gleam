import gleam/dict
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/string
import glyde/field.{Absent, Null, Present}
import glyde/model/application_command as model
import glyde/payload/command.{
  CreateApplicationCommand, EditApplicationCommand, EditGlobalCommand,
  GlobalCommand,
}
import glyde/permissions
import glyde/rest/body

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

fn option(name: String) -> model.ApplicationCommandOption {
  model.string_option(name: name, description: "an option")
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
  let encoded = json.to_string(json.array(options, model.option_to_json))

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
  let wanted = model.ApplicationCommandOption(..option("who"), required: True)

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
  assert menu.kind == command.UserCommand

  let slash = command.new_chat_input(name: "ping", description: "d")
  assert slash.kind
    == command.ChatInput(
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
