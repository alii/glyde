import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import glyde/application_command
import glyde/attachment
import glyde/channel
import glyde/component
import glyde/field.{Null, Present}
import glyde/id
import glyde/interaction.{
  AutocompleteResult, ChannelMessageWithSource, DeferredChannelMessageWithSource,
  DeferredUpdateMessage, MessageCallbackData, Pong, UpdateMessage,
}
import glyde/mentions
import glyde/message.{Edit}
import glyde/permissions
import glyde/rest/body

fn parse(text: String) -> Result(interaction.Interaction, json.DecodeError) {
  json.parse(text, interaction.decoder())
}

fn options(text: String) -> List(interaction.InteractionOption) {
  let assert Ok(decoded) =
    json.parse(text, decode.list(interaction.option_decoder()))
  decoded
}

/// A PING carries five keys, and four fields Discord documents as required are
/// not among them.
pub fn decodes_a_ping_test() {
  let assert Ok(ping) =
    parse(
      "{\"id\":\"1\",\"application_id\":\"2\",\"type\":1,\"token\":\"secret\",\"version\":1}",
    )
  assert ping.type_ == interaction.PingInteraction
  assert ping.data == interaction.NoData
  assert ping.channel_id == None
  assert ping.channel == None
  assert ping.app_permissions == None
  assert ping.member == None
  assert ping.user == None
  assert ping.attachment_size_limit == None
  assert dict.size(ping.authorizing_integration_owners) == 0
  assert interaction.reveal_token(ping.token) == "secret"
  assert ping.version == 1
}

pub fn requires_id_application_id_type_and_token_test() {
  let assert Error(_) =
    parse("{\"application_id\":\"2\",\"type\":1,\"token\":\"t\"}")
  let assert Error(_) = parse("{\"id\":\"1\",\"type\":1,\"token\":\"t\"}")
  let assert Error(_) =
    parse("{\"id\":\"1\",\"application_id\":\"2\",\"token\":\"t\"}")
  let assert Error(_) =
    parse("{\"id\":\"1\",\"application_id\":\"2\",\"type\":1}")
}

const command_body: String = "{\"id\":\"3\",\"name\":\"blep\",\"type\":1,\"options\":[{\"name\":\"animal\",\"type\":3,\"value\":\"cat\"}]}"

/// Types 2 and 4 send a byte-identical `data` object and mean opposite things.
pub fn the_same_data_decodes_two_ways_by_envelope_type_test() {
  let envelope = fn(type_: String) {
    "{\"id\":\"1\",\"application_id\":\"2\",\"type\":"
    <> type_
    <> ",\"token\":\"t\",\"version\":1,\"data\":"
    <> command_body
    <> "}"
  }

  let assert Ok(invoked) = parse(envelope("2"))
  let assert interaction.CommandData(name:, ..) = invoked.data
  assert name == "blep"

  let assert Ok(typing) = parse(envelope("4"))
  let assert interaction.AutocompleteData(name:, ..) = typing.data
  assert name == "blep"
}

/// The data decoder is a function of the envelope's type and nothing else.
pub fn data_decoder_dispatches_on_the_envelope_type_test() {
  let assert Ok(command) =
    json.parse(
      command_body,
      interaction.data_decoder(interaction.ApplicationCommandInteraction),
    )
  let assert interaction.CommandData(..) = command

  let assert Ok(autocomplete) =
    json.parse(
      command_body,
      interaction.data_decoder(interaction.AutocompleteInteraction),
    )
  let assert interaction.AutocompleteData(..) = autocomplete
}

/// An unmodelled type keeps the envelope's NUMBER, so `UnknownData` still says
/// what arrived even though the decoder is chosen by the variant.
pub fn an_unmodelled_type_keeps_its_wire_number_test() {
  let assert Ok(modal) =
    json.parse(
      "{\"custom_id\":\"feedback\"}",
      interaction.data_decoder(interaction.ModalSubmitInteraction),
    )
  let assert interaction.UnknownData(type_: 5, ..) = modal

  let assert Ok(future) =
    json.parse(
      "{\"whatever\":7}",
      interaction.data_decoder(interaction.UnknownInteractionType(99)),
    )
  let assert interaction.UnknownData(type_: 99, ..) = future
}

pub fn decodes_a_slash_command_test() {
  let assert Ok(invoked) =
    parse(
      "{\"id\":\"1\",\"application_id\":\"2\",\"type\":2,\"token\":\"t\",\"version\":1,\"guild_id\":\"9\",\"channel_id\":\"8\",\"locale\":\"en-GB\",\"guild_locale\":\"en-US\",\"app_permissions\":\"2048\",\"attachment_size_limit\":26214400,\"data\":{\"id\":\"3\",\"name\":\"blep\",\"type\":1,\"guild_id\":\"7\",\"options\":[{\"name\":\"animal\",\"type\":3,\"value\":\"cat\"}]}}",
    )
  assert interaction.interaction_type_to_int(invoked.type_) == 2
  assert option.map(invoked.guild_id, id.to_string) == Some("9")
  assert invoked.locale == Some("en-GB")
  assert invoked.guild_locale == Some("en-US")
  assert invoked.attachment_size_limit == Some(26_214_400)
  let assert Some(allowed) = invoked.app_permissions
  assert permissions.to_string(allowed) == "2048"

  let assert interaction.CommandData(id:, type_:, guild_id:, options:, ..) =
    invoked.data
  assert id.to_string(id) == "3"
  assert type_ == application_command.ChatInput
  // The registration guild, not the invocation guild.
  assert option.map(guild_id, id.to_string) == Some("7")
  assert interaction.string_option(options, "animal") == Some("cat")
}

/// `type` is optional on the data object and defaults to CHAT_INPUT.
pub fn command_data_defaults_to_chat_input_test() {
  let assert Ok(data) =
    json.parse(
      "{\"id\":\"3\",\"name\":\"blep\"}",
      interaction.data_decoder(interaction.ApplicationCommandInteraction),
    )
  let assert interaction.CommandData(type_:, resolved:, options:, ..) = data
  assert type_ == application_command.ChatInput
  assert options == []
  assert resolved == interaction.empty_resolved()
}

/// A button press and a select submitted with nothing chosen both send an
/// empty `values`, so `component_type` is the discriminator.
pub fn component_data_distinguishes_by_type_not_emptiness_test() {
  let assert Ok(button) =
    json.parse(
      "{\"custom_id\":\"click_one\",\"component_type\":2}",
      interaction.data_decoder(interaction.MessageComponentInteraction),
    )
  let assert interaction.ComponentData(custom_id:, submission:, ..) = button
  assert custom_id == "click_one"
  assert submission == interaction.ButtonPress

  let assert Ok(select) =
    json.parse(
      "{\"custom_id\":\"pick\",\"component_type\":3,\"values\":[]}",
      interaction.data_decoder(interaction.MessageComponentInteraction),
    )
  let assert interaction.ComponentData(submission:, ..) = select
  assert submission == interaction.StringSelect(values: [])

  let assert Ok(chosen) =
    json.parse(
      "{\"custom_id\":\"pick\",\"component_type\":3,\"values\":[\"a\",\"b\"]}",
      interaction.data_decoder(interaction.MessageComponentInteraction),
    )
  let assert interaction.ComponentData(submission:, ..) = chosen
  assert submission == interaction.StringSelect(values: ["a", "b"])
}

/// The entity selects submit ids, not labels, and each one says which kind of
/// id it sent.
pub fn entity_select_submissions_carry_typed_ids_test() {
  let assert Ok(users) =
    json.parse(
      "{\"custom_id\":\"who\",\"component_type\":5,\"values\":[\"7\"]}",
      interaction.data_decoder(interaction.MessageComponentInteraction),
    )
  let assert interaction.ComponentData(submission:, ..) = users
  assert submission == interaction.UserSelect(users: [id.from_string("7")])

  let assert Ok(roles) =
    json.parse(
      "{\"custom_id\":\"which\",\"component_type\":6,\"values\":[\"8\"]}",
      interaction.data_decoder(interaction.MessageComponentInteraction),
    )
  let assert interaction.ComponentData(submission:, ..) = roles
  assert submission == interaction.RoleSelect(roles: [id.from_string("8")])

  let assert Ok(channels) =
    json.parse(
      "{\"custom_id\":\"where\",\"component_type\":8,\"values\":[\"9\"]}",
      interaction.data_decoder(interaction.MessageComponentInteraction),
    )
  let assert interaction.ComponentData(submission:, ..) = channels
  assert submission
    == interaction.ChannelSelect(channels: [id.from_string("9")])
}

/// A mentionable select mixes the two, and only `resolved` tells them apart.
/// An id in neither map is neither: tagging it a user would hand a role id to
/// a route that bans people.
pub fn a_mentionable_select_splits_users_from_roles_test() {
  let assert Ok(picked) =
    json.parse(
      "{\"custom_id\":\"ping\",\"component_type\":7,"
        <> "\"values\":[\"7\",\"8\",\"9\"],"
        <> "\"resolved\":{\"users\":{\"7\":{\"id\":\"7\"}},"
        <> "\"roles\":{\"8\":{\"id\":\"8\",\"permissions\":\"0\"}}}}",
      interaction.data_decoder(interaction.MessageComponentInteraction),
    )
  let assert interaction.ComponentData(submission:, ..) = picked
  assert submission
    == interaction.MentionableSelect(mentions: [
      interaction.MentionedUser(id.from_string("7")),
      interaction.MentionedRole(id.from_string("8")),
      interaction.UnknownMentionable("9"),
    ])
}

/// `resolved.members` is enough on its own: a guild mentionable select fills
/// it beside `users`, and a partial one is still a user.
pub fn a_mentionable_only_in_members_is_a_user_test() {
  let assert Ok(picked) =
    json.parse(
      "{\"custom_id\":\"ping\",\"component_type\":7,\"values\":[\"7\"],"
        <> "\"resolved\":{\"members\":{\"7\":{\"roles\":[]}}}}",
      interaction.data_decoder(interaction.MessageComponentInteraction),
    )
  let assert interaction.ComponentData(submission:, ..) = picked
  assert submission
    == interaction.MentionableSelect(mentions: [
      interaction.MentionedUser(id.from_string("7")),
    ])
}

/// A component type this build does not know keeps its values as sent, and so
/// does one it knows by name but that submits nothing: type 1 is an action row
/// and type 4 a text input, and neither sends a component interaction.
pub fn an_unknown_component_submission_keeps_its_values_test() {
  let types = [42, 1, 4]
  list.each(types, fn(wire) {
    let assert Ok(future) =
      json.parse(
        "{\"custom_id\":\"x\",\"component_type\":"
          <> int.to_string(wire)
          <> ",\"values\":[\"a\"]}",
        interaction.data_decoder(interaction.MessageComponentInteraction),
      )
    let assert interaction.ComponentData(submission:, ..) = future
    assert submission
      == interaction.UnknownSubmission(component_type: wire, values: ["a"])
  })
}

/// MODAL_SUBMIT is unmodelled, so a caller hand-rolls against the raw payload.
pub fn a_modal_submit_keeps_its_raw_payload_test() {
  let assert Ok(modal) =
    parse(
      "{\"id\":\"1\",\"application_id\":\"2\",\"type\":5,\"token\":\"t\",\"version\":1,\"data\":{\"custom_id\":\"feedback\",\"components\":[]}}",
    )
  assert modal.type_ == interaction.ModalSubmitInteraction
  let assert interaction.UnknownData(type_: 5, raw:) = modal.data
  assert decode.run(raw, decode.at(["custom_id"], decode.string))
    == Ok("feedback")
}

/// The interaction decode is all or nothing.
pub fn a_future_interaction_type_decodes_test() {
  let assert Ok(future) =
    parse(
      "{\"id\":\"1\",\"application_id\":\"2\",\"type\":99,\"token\":\"t\",\"version\":1,\"data\":{\"whatever\":7}}",
    )
  assert future.type_ == interaction.UnknownInteractionType(99)
  let assert interaction.UnknownData(type_: 99, raw:) = future.data
  assert decode.run(raw, decode.at(["whatever"], decode.int)) == Ok(7)
}

/// `Interaction.guild` is a three-field partial, not a full guild.
pub fn the_guild_field_is_a_three_field_partial_test() {
  let assert Ok(invoked) =
    parse(
      "{\"id\":\"1\",\"application_id\":\"2\",\"type\":2,\"token\":\"t\",\"version\":1,\"guild\":{\"id\":\"9\",\"locale\":\"en-US\",\"features\":[\"COMMUNITY\"]},\"data\":{\"id\":\"3\",\"name\":\"x\"}}",
    )
  let assert Some(server) = invoked.guild
  assert id.to_string(server.id) == "9"
  assert server.locale == "en-US"
  assert server.features == ["COMMUNITY"]
}

/// Only `id` and `type` are guaranteed on the channel.
pub fn the_channel_field_is_a_partial_test() {
  let assert Ok(invoked) =
    parse(
      "{\"id\":\"1\",\"application_id\":\"2\",\"type\":2,\"token\":\"t\",\"version\":1,\"channel\":{\"id\":\"8\",\"type\":0},\"data\":{\"id\":\"3\",\"name\":\"x\"}}",
    )
  let assert Some(room) = invoked.channel
  assert id.to_string(room.id) == "8"
  assert room.type_ == channel.GuildText
  assert room.name == None
}

/// In a guild the invoking user is at `member.user`, and in a DM it is at
/// `user`. A bot that reads only `user` sees nobody for every guild command.
pub fn invoking_user_reads_both_shapes_test() {
  let assert Ok(in_guild) =
    parse(
      "{\"id\":\"1\",\"application_id\":\"2\",\"type\":2,\"token\":\"t\",\"version\":1,\"member\":{\"roles\":[],\"user\":{\"id\":\"5\",\"username\":\"nelly\"}},\"data\":{\"id\":\"3\",\"name\":\"x\"}}",
    )
  let assert Some(who) = interaction.invoking_user(in_guild)
  assert who.username == "nelly"

  let assert Ok(in_dm) =
    parse(
      "{\"id\":\"1\",\"application_id\":\"2\",\"type\":2,\"token\":\"t\",\"version\":1,\"user\":{\"id\":\"5\",\"username\":\"dmuser\"},\"data\":{\"id\":\"3\",\"name\":\"x\"}}",
    )
  let assert Some(alone) = interaction.invoking_user(in_dm)
  assert alone.username == "dmuser"

  let assert Ok(ping) =
    parse(
      "{\"id\":\"1\",\"application_id\":\"2\",\"type\":1,\"token\":\"t\",\"version\":1}",
    )
  assert interaction.invoking_user(ping) == None
}

/// `target_id` is a user id for USER commands and a message id for MESSAGE.
pub fn context_menu_targets_are_read_by_command_type_test() {
  let assert Ok(on_user) =
    json.parse(
      "{\"id\":\"3\",\"name\":\"report\",\"type\":2,\"target_id\":\"5\"}",
      interaction.data_decoder(interaction.ApplicationCommandInteraction),
    )
  assert option.map(interaction.target_user_id(on_user), id.to_string)
    == Some("5")
  assert interaction.target_message_id(on_user) == None

  let assert Ok(on_message) =
    json.parse(
      "{\"id\":\"3\",\"name\":\"pin it\",\"type\":3,\"target_id\":\"6\"}",
      interaction.data_decoder(interaction.ApplicationCommandInteraction),
    )
  assert option.map(interaction.target_message_id(on_message), id.to_string)
    == Some("6")
  assert interaction.target_user_id(on_message) == None

  let assert Ok(slash) =
    json.parse(
      "{\"id\":\"3\",\"name\":\"blep\",\"type\":1}",
      interaction.data_decoder(interaction.ApplicationCommandInteraction),
    )
  assert interaction.target_user_id(slash) == None
  assert interaction.target_message_id(slash) == None
}

/// Absent `resolved` is an empty map, so a call site never unwraps first.
pub fn resolved_is_empty_rather_than_absent_test() {
  let assert Ok(data) =
    json.parse(
      "{\"id\":\"3\",\"name\":\"x\"}",
      interaction.data_decoder(interaction.ApplicationCommandInteraction),
    )
  let assert interaction.CommandData(resolved:, ..) = data
  assert dict.size(resolved.users) == 0
  assert dict.size(resolved.members) == 0
  assert dict.size(resolved.roles) == 0
  assert dict.size(resolved.channels) == 0
  assert dict.size(resolved.messages) == 0
  assert dict.size(resolved.attachments) == 0
}

/// An explicit null is the same as an absent key everywhere else in glyde, and
/// this decoder is all or nothing: one null used to sink the interaction.
pub fn an_explicit_null_takes_the_default_test() {
  let assert Ok(pinged) =
    parse(
      "{\"id\":\"1\",\"application_id\":\"2\",\"type\":1,\"token\":\"t\",\"data\":null}",
    )
  assert pinged.data == interaction.NoData

  let assert Ok(data) =
    json.parse(
      "{\"id\":\"3\",\"name\":\"x\",\"type\":null,\"resolved\":null}",
      interaction.data_decoder(interaction.ApplicationCommandInteraction),
    )
  let assert interaction.CommandData(type_:, resolved:, ..) = data
  assert type_ == application_command.ChatInput
  assert resolved == interaction.empty_resolved()
}

/// `resolved.members` drops `user`, `deaf` and `mute`. A strict member
/// decoder there fails every context-menu command and every user select.
pub fn resolved_members_are_partial_test() {
  let assert Ok(data) =
    json.parse(
      "{\"id\":\"3\",\"name\":\"x\",\"resolved\":{\"users\":{\"5\":{\"id\":\"5\",\"username\":\"nelly\"}},\"members\":{\"5\":{\"roles\":[\"9\"],\"joined_at\":\"2021-01-01T00:00:00+00:00\",\"pending\":false}}}}",
      interaction.data_decoder(interaction.ApplicationCommandInteraction),
    )
  let assert interaction.CommandData(resolved:, ..) = data
  let assert Ok(who) = dict.get(resolved.users, id.from_string("5"))
  assert who.username == "nelly"
  let assert Ok(membership) = dict.get(resolved.members, id.from_string("5"))
  assert membership.user == None
  assert membership.deaf == None
  assert membership.mute == None
  assert list.map(membership.roles, id.to_string) == ["9"]
}

/// A resolved channel carries the invoking user's computed permissions, which
/// a full `Channel` never does.
pub fn resolved_channels_carry_the_users_permissions_test() {
  let assert Ok(data) =
    json.parse(
      "{\"id\":\"3\",\"name\":\"x\",\"resolved\":{\"channels\":{\"8\":{\"id\":\"8\",\"type\":11,\"name\":\"a thread\",\"permissions\":\"2048\",\"parent_id\":\"7\",\"thread_metadata\":{\"archived\":false,\"auto_archive_duration\":1440,\"archive_timestamp\":\"2021-01-01T00:00:00+00:00\",\"locked\":false}}}}}",
      interaction.data_decoder(interaction.ApplicationCommandInteraction),
    )
  let assert interaction.CommandData(resolved:, ..) = data
  let assert Ok(room) = dict.get(resolved.channels, id.from_string("8"))
  assert room.type_ == channel.PublicThread
  assert room.name == Some("a thread")
  assert option.map(room.parent_id, id.to_string) == Some("7")
  let assert Some(granted) = room.permissions
  assert permissions.to_string(granted) == "2048"
  let assert Some(meta) = room.thread_metadata
  assert meta.auto_archive_duration == channel.OneDay
}

pub fn resolved_carries_messages_and_attachments_test() {
  let assert Ok(data) =
    json.parse(
      "{\"id\":\"3\",\"name\":\"x\",\"resolved\":{\"messages\":{\"6\":{\"id\":\"6\",\"channel_id\":\"8\",\"author\":{\"id\":\"5\"},\"content\":\"hi\",\"timestamp\":\"2021-01-01T00:00:00+00:00\",\"type\":0}},\"attachments\":{\"7\":{\"id\":\"7\",\"filename\":\"a.png\",\"size\":10,\"url\":\"https://cdn/a.png\",\"proxy_url\":\"https://proxy/a.png\"}}}}",
      interaction.data_decoder(interaction.ApplicationCommandInteraction),
    )
  let assert interaction.CommandData(resolved:, ..) = data
  let assert Ok(replied) = dict.get(resolved.messages, id.from_string("6"))
  assert replied.content == "hi"
  let assert Ok(file) = dict.get(resolved.attachments, id.from_string("7"))
  assert file.filename == "a.png"
}

/// A subcommand carries `options` and no `value`.
pub fn a_subcommand_has_no_value_test() {
  let assert [group] =
    options(
      "[{\"name\":\"config\",\"type\":2,\"options\":[{\"name\":\"set\",\"type\":1,\"options\":[{\"name\":\"key\",\"type\":3,\"value\":\"colour\"}]}]}]",
    )
  assert group.type_ == application_command.SubCommandGroup
  assert group.value == interaction.NoValue
  let assert [sub] = group.options
  assert sub.type_ == application_command.SubCommand
  assert sub.value == interaction.NoValue
  let assert [leaf] = sub.options
  assert leaf.value == interaction.StringValue("colour")
}

/// The value is read by the option's DECLARED type, so the same JSON number
/// lands in a different variant depending on what the command declared.
pub fn option_values_follow_the_declared_type_test() {
  let assert [integer] = options("[{\"name\":\"n\",\"type\":4,\"value\":3}]")
  assert integer.value == interaction.IntValue(3)

  let assert [number] = options("[{\"name\":\"n\",\"type\":10,\"value\":3}]")
  assert number.value == interaction.FloatValue(3.0)

  let assert [truth] = options("[{\"name\":\"b\",\"type\":5,\"value\":true}]")
  assert truth.value == interaction.BoolValue(True)

  let assert [text] = options("[{\"name\":\"s\",\"type\":3,\"value\":\"hi\"}]")
  assert text.value == interaction.StringValue("hi")
}

/// `3.0` on an INTEGER option and `3` on a NUMBER option each land in the
/// variant the command declared.
pub fn whole_numbers_follow_the_declared_type_test() {
  let assert [integer] = options("[{\"name\":\"n\",\"type\":4,\"value\":3.0}]")
  assert integer.value == interaction.IntValue(3)

  let assert [number] = options("[{\"name\":\"n\",\"type\":10,\"value\":3.0}]")
  assert number.value == interaction.FloatValue(3.0)

  let assert [fractional] =
    options("[{\"name\":\"n\",\"type\":4,\"value\":3.5}]")
  assert fractional.value == interaction.FloatValue(3.5)
}

/// Discord validates numeric input in the client only and relays raw
/// keystrokes, so a focused INTEGER option really can deliver a string.
pub fn a_focused_numeric_option_may_arrive_as_a_string_test() {
  let assert [half_typed] =
    options("[{\"name\":\"n\",\"type\":4,\"value\":\"12x\",\"focused\":true}]")
  assert half_typed.value == interaction.StringValue("12x")
  assert half_typed.focused == True
}

/// The five snowflake-valued types all arrive as strings holding the id.
pub fn snowflake_options_arrive_as_strings_test() {
  list.each([6, 7, 8, 9, 11], fn(declared) {
    let assert [picked] =
      options(
        "[{\"name\":\"who\",\"type\":"
        <> json.to_string(json.int(declared))
        <> ",\"value\":\"80351110224678912\"}]",
      )
    assert picked.value == interaction.StringValue("80351110224678912")
  })
}

/// One failure here loses the whole INTERACTION_CREATE.
pub fn an_unknown_option_type_decodes_test() {
  let assert [odd] = options("[{\"name\":\"x\",\"type\":77,\"value\":\"v\"}]")
  assert odd.type_ == application_command.UnknownOptionType(77)
  assert odd.value == interaction.StringValue("v")
}

/// Autocomplete sends only what the user has typed, so a required option can
/// be missing and the one being typed can have no value at all.
pub fn an_autocomplete_option_may_carry_no_value_test() {
  let assert [typing] =
    options("[{\"name\":\"q\",\"type\":3,\"focused\":true}]")
  assert typing.value == interaction.NoValue
  assert typing.focused == True
}

/// `/config set key:<typing>` focuses an option two levels down.
pub fn focused_option_descends_through_subcommands_test() {
  let nested =
    options(
      "[{\"name\":\"config\",\"type\":2,\"options\":[{\"name\":\"set\",\"type\":1,\"options\":[{\"name\":\"key\",\"type\":3,\"value\":\"col\",\"focused\":true}]}]}]",
    )
  let assert Some(typing) = interaction.focused_option(nested)
  assert typing.name == "key"

  let flat = options("[{\"name\":\"animal\",\"type\":3,\"value\":\"cat\"}]")
  assert interaction.focused_option(flat) == None
}

pub fn subcommand_path_flattens_the_tree_test() {
  let nested =
    options(
      "[{\"name\":\"config\",\"type\":2,\"options\":[{\"name\":\"set\",\"type\":1,\"options\":[{\"name\":\"key\",\"type\":3,\"value\":\"col\"}]}]}]",
    )
  let #(path, leaves) = interaction.subcommand_path(nested)
  assert path == ["config", "set"]
  assert list.map(leaves, fn(leaf) { leaf.name }) == ["key"]

  let flat = options("[{\"name\":\"animal\",\"type\":3,\"value\":\"cat\"}]")
  let #(none_deep, same) = interaction.subcommand_path(flat)
  assert none_deep == []
  assert list.map(same, fn(leaf) { leaf.name }) == ["animal"]
}

/// The accessors read the invoked subcommand's parameters, which is the depth
/// `focused_option` already descends to. A flat scan of the top-level options
/// answers `None` for every parameter of `/config set key:colour`.
pub fn the_accessors_descend_through_subcommands_test() {
  let nested =
    options(
      "[{\"name\":\"config\",\"type\":2,\"options\":[{\"name\":\"set\",\"type\":1,\"options\":["
      <> "{\"name\":\"key\",\"type\":3,\"value\":\"colour\",\"focused\":true},"
      <> "{\"name\":\"who\",\"type\":6,\"value\":\"51\"}]}]}]",
    )
  assert interaction.string_option(nested, "key") == Some("colour")
  assert option.map(interaction.user_option(nested, "who"), id.to_string)
    == Some("51")

  // The half of the API that already descended agrees with the other half.
  let assert Some(typing) = interaction.focused_option(nested)
  assert interaction.string_option(nested, typing.name) == Some("colour")

  // A group and a subcommand are the path, not parameters. `subcommand_path`
  // is what names those.
  assert interaction.find_option(nested, "config") == None
  assert interaction.find_option(nested, "set") == None
}

pub fn typed_option_accessors_test() {
  let mixed =
    options(
      "[{\"name\":\"s\",\"type\":3,\"value\":\"hi\"},{\"name\":\"i\",\"type\":4,\"value\":7},{\"name\":\"f\",\"type\":10,\"value\":1.5},{\"name\":\"b\",\"type\":5,\"value\":false},{\"name\":\"u\",\"type\":6,\"value\":\"51\"},{\"name\":\"c\",\"type\":7,\"value\":\"52\"},{\"name\":\"r\",\"type\":8,\"value\":\"53\"},{\"name\":\"a\",\"type\":11,\"value\":\"54\"}]",
    )
  assert interaction.string_option(mixed, "s") == Some("hi")
  assert interaction.int_option(mixed, "i") == Some(7)
  assert interaction.float_option(mixed, "f") == Some(1.5)
  assert interaction.bool_option(mixed, "b") == Some(False)
  assert option.map(interaction.user_option(mixed, "u"), id.to_string)
    == Some("51")
  assert option.map(interaction.channel_option(mixed, "c"), id.to_string)
    == Some("52")
  assert option.map(interaction.role_option(mixed, "r"), id.to_string)
    == Some("53")
  assert option.map(interaction.attachment_option(mixed, "a"), id.to_string)
    == Some("54")
}

/// An accessor declines rather than guessing a conversion.
pub fn an_accessor_declines_the_wrong_type_test() {
  let mixed = options("[{\"name\":\"s\",\"type\":3,\"value\":\"hi\"}]")
  assert interaction.int_option(mixed, "s") == None
  assert interaction.string_option(mixed, "missing") == None
  assert interaction.find_option(mixed, "missing") == None
  let assert Some(found) = interaction.find_option(mixed, "s")
  assert found.name == "s"
}

/// A snowflake accessor takes the DECLARED type, not any option that happens
/// to hold a string. Free text read as a user id goes straight into a route.
pub fn a_snowflake_accessor_refuses_a_free_text_option_test() {
  let prose =
    options("[{\"name\":\"reason\",\"type\":3,\"value\":\"be nice\"}]")
  assert interaction.user_option(prose, "reason") == None
  assert interaction.channel_option(prose, "reason") == None
  assert interaction.role_option(prose, "reason") == None
  assert interaction.attachment_option(prose, "reason") == None

  // And it does not take a snowflake option of the wrong kind either.
  let a_role = options("[{\"name\":\"who\",\"type\":8,\"value\":\"53\"}]")
  assert interaction.user_option(a_role, "who") == None
  assert option.map(interaction.role_option(a_role, "who"), id.to_string)
    == Some("53")
}

/// MENTIONABLE is a user id or a role id, and only `resolved` says which, so
/// neither accessor will guess at one.
pub fn a_snowflake_accessor_refuses_a_mentionable_option_test() {
  let either = options("[{\"name\":\"who\",\"type\":9,\"value\":\"53\"}]")
  assert interaction.user_option(either, "who") == None
  assert interaction.role_option(either, "who") == None
}

/// The accessor that does read one takes `resolved`, which is what settles it.
pub fn mentionable_option_reads_the_resolved_kind_test() {
  let assert Ok(interaction.CommandData(options: picked, resolved:, ..)) =
    json.parse(
      "{\"id\":\"3\",\"name\":\"x\",\"options\":[{\"name\":\"who\",\"type\":9,\"value\":\"53\"},"
        <> "{\"name\":\"whom\",\"type\":9,\"value\":\"7\"},"
        <> "{\"name\":\"stranger\",\"type\":9,\"value\":\"99\"},"
        <> "{\"name\":\"reason\",\"type\":3,\"value\":\"be nice\"}],"
        <> "\"resolved\":{\"users\":{\"7\":{\"id\":\"7\"}},"
        <> "\"roles\":{\"53\":{\"id\":\"53\",\"permissions\":\"0\"}}}}",
      interaction.data_decoder(interaction.ApplicationCommandInteraction),
    )
  assert interaction.mentionable_option(picked, "who", resolved)
    == Some(interaction.MentionedRole(id.from_string("53")))
  assert interaction.mentionable_option(picked, "whom", resolved)
    == Some(interaction.MentionedUser(id.from_string("7")))

  // In neither map, so nothing here says which it is.
  assert interaction.mentionable_option(picked, "stranger", resolved)
    == Some(interaction.UnknownMentionable("99"))

  // And it takes the declared type like the other snowflake accessors do.
  assert interaction.mentionable_option(picked, "reason", resolved) == None
  assert interaction.mentionable_option(picked, "missing", resolved) == None
}

/// The keys are `"0"` and `"1"`, and under a guild install in a bot DM the
/// value is the literal `"0"`. The sentinel is decoded away, so no reader is
/// left holding a string that looks like a snowflake: `id.from_string("0")`
/// does not fail, it mints a guild zero and puts it in a route.
pub fn the_no_owner_sentinel_is_decoded_away_test() {
  let assert Ok(invoked) =
    parse(
      "{\"id\":\"1\",\"application_id\":\"2\",\"type\":2,\"token\":\"t\",\"version\":1,\"authorizing_integration_owners\":{\"0\":\"0\",\"1\":\"80351110224678912\"},\"data\":{\"id\":\"3\",\"name\":\"x\"}}",
    )
  let owners = invoked.authorizing_integration_owners
  assert dict.get(owners, application_command.GuildInstall)
    == Ok(interaction.NoOwner)
  assert dict.get(owners, application_command.UserInstall)
    == Ok(interaction.OwnedBy("80351110224678912"))

  assert interaction.authorizing_guild_id(invoked) == None
  assert option.map(interaction.authorizing_user_id(invoked), id.to_string)
    == Some("80351110224678912")
}

/// A guild install invoked in the guild names it, and there is no sentinel to
/// step around.
pub fn authorizing_guild_id_reads_a_real_guild_test() {
  let assert Ok(invoked) =
    parse(
      "{\"id\":\"1\",\"application_id\":\"2\",\"type\":2,\"token\":\"t\",\"version\":1,\"authorizing_integration_owners\":{\"0\":\"197038439483310086\"},\"data\":{\"id\":\"3\",\"name\":\"x\"}}",
    )
  assert option.map(interaction.authorizing_guild_id(invoked), id.to_string)
    == Some("197038439483310086")
  assert interaction.authorizing_user_id(invoked) == None
}

/// An unparseable key becomes an unknown variant that keeps the key, so two of
/// them do not collapse onto one entry.
pub fn an_unparseable_integration_key_does_not_fail_the_decode_test() {
  let assert Ok(invoked) =
    parse(
      "{\"id\":\"1\",\"application_id\":\"2\",\"type\":2,\"token\":\"t\",\"version\":1,\"authorizing_integration_owners\":{\"nope\":\"9\",\"nah\":\"8\"},\"data\":{\"id\":\"3\",\"name\":\"x\"}}",
    )
  let owners = invoked.authorizing_integration_owners
  assert dict.size(owners) == 2
  assert dict.get(owners, application_command.UnknownIntegrationKey("nope"))
    == Ok(interaction.OwnedBy("9"))
  assert dict.get(owners, application_command.UnknownIntegrationKey("nah"))
    == Ok(interaction.OwnedBy("8"))
}

pub fn context_is_optional_test() {
  let assert Ok(in_guild) =
    parse(
      "{\"id\":\"1\",\"application_id\":\"2\",\"type\":2,\"token\":\"t\",\"version\":1,\"context\":0,\"data\":{\"id\":\"3\",\"name\":\"x\"}}",
    )
  assert in_guild.context == Some(application_command.GuildContext)

  let assert Ok(unstated) =
    parse(
      "{\"id\":\"1\",\"application_id\":\"2\",\"type\":1,\"token\":\"t\",\"version\":1}",
    )
  assert unstated.context == None
}

pub fn interaction_type_round_trips_test() {
  let cases = [
    #(1, interaction.PingInteraction),
    #(2, interaction.ApplicationCommandInteraction),
    #(3, interaction.MessageComponentInteraction),
    #(4, interaction.AutocompleteInteraction),
    #(5, interaction.ModalSubmitInteraction),
  ]
  list.each(cases, fn(pair) {
    let #(wire, variant) = pair
    assert interaction.interaction_type_from_int(wire) == variant
    assert interaction.interaction_type_to_int(variant) == wire
  })
  assert interaction.interaction_type_from_int(6)
    == interaction.UnknownInteractionType(6)
  assert interaction.interaction_type_to_int(interaction.UnknownInteractionType(
      6,
    ))
    == 6
}

/// The callback numbering has holes, so a dense index sends the wrong number.
pub fn callback_type_round_trips_over_its_holes_test() {
  let cases = [
    #(1, interaction.PongCallback),
    #(4, interaction.ChannelMessageWithSourceCallback),
    #(5, interaction.DeferredChannelMessageWithSourceCallback),
    #(6, interaction.DeferredUpdateMessageCallback),
    #(7, interaction.UpdateMessageCallback),
    #(8, interaction.AutocompleteResultCallback),
    #(9, interaction.ModalCallback),
    #(10, interaction.PremiumRequiredCallback),
    #(12, interaction.LaunchActivityCallback),
  ]
  list.each(cases, fn(pair) {
    let #(wire, variant) = pair
    assert interaction.callback_type_from_int(wire) == variant
    assert interaction.callback_type_to_int(variant) == wire
  })
  list.each([0, 2, 3, 11, 13], fn(hole) {
    assert interaction.callback_type_from_int(hole)
      == interaction.UnknownCallbackType(hole)
    assert interaction.callback_type_to_int(interaction.UnknownCallbackType(
        hole,
      ))
      == hole
  })
}

pub fn callback_types_encode_as_their_wire_numbers_test() {
  assert json.to_string(interaction.callback_type_to_json(
      interaction.LaunchActivityCallback,
    ))
    == "12"
  assert json.to_string(interaction.interaction_type_to_json(
      interaction.AutocompleteInteraction,
    ))
    == "4"
}

/// Without `?with_response=true` the route answers 204 and no body.
pub fn decodes_a_callback_response_test() {
  let assert Ok(answered) =
    json.parse(
      "{\"interaction\":{\"id\":\"1\",\"type\":2,\"response_message_id\":\"6\",\"response_message_loading\":false,\"response_message_ephemeral\":false},\"resource\":{\"type\":4,\"message\":{\"id\":\"6\",\"channel_id\":\"8\",\"author\":{\"id\":\"5\"},\"content\":\"done\",\"timestamp\":\"2021-01-01T00:00:00+00:00\",\"type\":0}}}",
      interaction.callback_response_decoder(),
    )
  assert interaction.interaction_type_to_int(answered.interaction.type_) == 2
  assert option.map(answered.interaction.response_message_id, id.to_string)
    == Some("6")
  let assert Some(resource) = answered.resource
  assert resource.type_ == interaction.ChannelMessageWithSourceCallback
  let assert Some(posted) = resource.message
  assert posted.content == "done"
}

/// A deferred response creates no message, so the resource is absent.
pub fn a_deferred_callback_response_has_no_resource_test() {
  let assert Ok(deferred) =
    json.parse(
      "{\"interaction\":{\"id\":\"1\",\"type\":2}}",
      interaction.callback_response_decoder(),
    )
  assert deferred.resource == None
  assert deferred.interaction.response_message_id == None
}

/// The three-second clock starts when Discord created the interaction, so the
/// budget comes out of the snowflake.
pub fn the_response_budget_comes_from_the_snowflake_test() {
  let assert Ok(invoked) =
    parse(
      "{\"id\":\"175928847299117063\",\"application_id\":\"2\",\"type\":1,\"token\":\"t\",\"version\":1}",
    )
  let created = 1_462_015_105_796
  assert interaction.remaining_response_budget_ms(invoked, now_ms: created)
    == 3000
  assert interaction.remaining_response_budget_ms(
      invoked,
      now_ms: created + 1000,
    )
    == 2000
  assert interaction.remaining_response_budget_ms(
      invoked,
      now_ms: created + 2999,
    )
    == 1
}

/// Past the deadline the answer is 0, so lateness cannot read as time in hand.
pub fn an_expired_budget_is_zero_test() {
  let assert Ok(invoked) =
    parse(
      "{\"id\":\"175928847299117063\",\"application_id\":\"2\",\"type\":1,\"token\":\"t\",\"version\":1}",
    )
  assert interaction.remaining_response_budget_ms(
      invoked,
      now_ms: 1_462_015_999_999,
    )
    == 0
}

/// The decoder rejects a non-snowflake id, but `id.from_string` does not, so
/// one can still reach here. 0 makes the caller defer rather than gamble.
pub fn a_budget_for_an_unparseable_id_is_zero_test() {
  let assert Ok(fine) =
    parse(
      "{\"id\":\"1\",\"application_id\":\"2\",\"type\":1,\"token\":\"t\",\"version\":1}",
    )
  let odd =
    interaction.Interaction(..fine, id: id.from_string("not-a-snowflake"))
  assert interaction.remaining_response_budget_ms(odd, now_ms: 0) == 0
}

pub fn a_non_snowflake_id_fails_the_decode_test() {
  let assert Error(_) =
    parse(
      "{\"id\":\"not-a-snowflake\",\"application_id\":\"2\",\"type\":1,\"token\":\"t\",\"version\":1}",
    )
}

/// One unknown enum value must not fail the whole INTERACTION_CREATE.
pub fn unknown_enum_values_do_not_sink_the_interaction_test() {
  let assert Ok(invoked) =
    parse(
      "{\"id\":\"1\",\"application_id\":\"2\",\"type\":2,\"token\":\"t\",\"version\":1,\"context\":77,\"channel\":{\"id\":\"8\",\"type\":98},\"data\":{\"id\":\"3\",\"name\":\"x\",\"type\":9,\"options\":[{\"name\":\"o\",\"type\":88,\"value\":\"v\"}]}}",
    )
  assert invoked.context == Some(application_command.UnknownContext(77))
  let assert Some(room) = invoked.channel
  assert room.type_ == channel.UnknownChannelType(98)
  let assert interaction.CommandData(type_:, options:, ..) = invoked.data
  assert type_ == application_command.UnknownCommandType(9)
  let assert [odd] = options
  assert odd.type_ == application_command.UnknownOptionType(88)
}

/// A component interaction carries the message its component was attached to.
pub fn a_component_interaction_carries_its_message_test() {
  let assert Ok(pressed) =
    parse(
      "{\"id\":\"1\",\"application_id\":\"2\",\"type\":3,\"token\":\"t\",\"version\":1,\"message\":{\"id\":\"6\",\"channel_id\":\"8\",\"author\":{\"id\":\"5\"},\"content\":\"pick one\",\"timestamp\":\"2021-01-01T00:00:00+00:00\",\"type\":0},\"data\":{\"custom_id\":\"a\",\"component_type\":2}}",
    )
  let assert Some(carrying) = pressed.message
  assert carrying.content == "pick one"
}

pub fn version_defaults_to_one_test() {
  let assert Ok(invoked) =
    parse("{\"id\":\"1\",\"application_id\":\"2\",\"type\":1,\"token\":\"t\"}")
  assert invoked.version == 1
}

/// Every branch ends in `UnknownValue` rather than an error.
pub fn a_value_of_any_shape_still_decodes_test() {
  let odd_shapes = [
    "[{\"name\":\"n\",\"type\":4,\"value\":null}]",
    "[{\"name\":\"b\",\"type\":5,\"value\":[1,2]}]",
    "[{\"name\":\"f\",\"type\":10,\"value\":{\"nested\":true}}]",
    "[{\"name\":\"s\",\"type\":3,\"value\":[]}]",
  ]
  list.each(odd_shapes, fn(body) {
    let assert [odd] = options(body)
    let assert interaction.UnknownValue(_) = odd.value
  })
}

fn boundary() -> body.Boundary {
  let assert Ok(boundary) = body.boundary("abc123")
  boundary
}

fn encoded(response: interaction.InteractionResponse) -> String {
  json.to_string(interaction.to_json(response))
}

fn choice(name: String) -> application_command.ApplicationCommandOptionChoice {
  application_command.ApplicationCommandOptionChoice(
    name: name,
    name_localizations: None,
    value: application_command.StringChoice(name),
  )
}

/// 4 creates and 7 edits, which is why they are separate variants. The
/// numbering is `model/interaction`'s, the same table the callback decodes.
pub fn every_response_states_its_callback_type_test() {
  let cases = [
    #(Pong, interaction.PongCallback, 1),
    #(
      ChannelMessageWithSource(interaction.message_data()),
      interaction.ChannelMessageWithSourceCallback,
      4,
    ),
    #(
      DeferredChannelMessageWithSource(False),
      interaction.DeferredChannelMessageWithSourceCallback,
      5,
    ),
    #(DeferredUpdateMessage, interaction.DeferredUpdateMessageCallback, 6),
    #(
      UpdateMessage(interaction.update_data(mentions.none())),
      interaction.UpdateMessageCallback,
      7,
    ),
    #(
      AutocompleteResult(choices: []),
      interaction.AutocompleteResultCallback,
      8,
    ),
  ]

  list.each(cases, fn(row) {
    let #(response, kind, number) = row
    assert interaction.callback_type(response) == kind
    assert string.starts_with(encoded(response), "{\"type\":" <> int(number))
  })
}

fn int(value: Int) -> String {
  json.to_string(json.int(value))
}

/// An empty `data` object would be a message with no content, not an ack.
pub fn the_acknowledgements_carry_no_data_test() {
  assert encoded(Pong) == "{\"type\":1}"
  assert encoded(DeferredUpdateMessage) == "{\"type\":6}"
}

pub fn a_plain_reply_is_content_and_nothing_else_test() {
  assert encoded(ChannelMessageWithSource(interaction.text("Pong!")))
    == "{\"type\":4,\"data\":{\"content\":\"Pong!\"}}"
}

pub fn an_empty_reply_writes_an_empty_object_test() {
  assert encoded(ChannelMessageWithSource(interaction.message_data()))
    == "{\"type\":4,\"data\":{}}"
}

pub fn ephemeral_sets_the_flag_the_invoker_sees_test() {
  let data = interaction.text("Pong!") |> interaction.ephemeral

  assert encoded(ChannelMessageWithSource(data))
    == "{\"type\":4,\"data\":{\"content\":\"Pong!\",\"flags\":64}}"
}

pub fn ephemeral_is_idempotent_test() {
  let once = interaction.text("hi") |> interaction.ephemeral
  let twice = once |> interaction.ephemeral

  assert once == twice
}

pub fn ephemeral_keeps_the_flags_already_set_test() {
  let data =
    MessageCallbackData(
      ..interaction.text("hi"),
      flags: message.message_flags(of: [message.SuppressEmbeds]),
    )
    |> interaction.ephemeral

  assert encoded(ChannelMessageWithSource(data))
    == "{\"type\":4,\"data\":{\"content\":\"hi\",\"flags\":68}}"
}

/// Nothing to clear on a message that does not exist yet.
pub fn empty_lists_are_omitted_on_a_reply_test() {
  let data =
    MessageCallbackData(
      ..interaction.text("hi"),
      embeds: [],
      components: [],
      files: [],
    )

  assert encoded(ChannelMessageWithSource(data))
    == "{\"type\":4,\"data\":{\"content\":\"hi\"}}"
}

pub fn a_reply_carries_its_mention_policy_test() {
  let data =
    MessageCallbackData(
      ..interaction.text("@everyone hi"),
      allowed_mentions: Some(mentions.none()),
    )

  assert encoded(ChannelMessageWithSource(data))
    == "{\"type\":4,\"data\":{\"content\":\"@everyone hi\","
    <> "\"allowed_mentions\":{\"parse\":[],\"replied_user\":false}}}"
}

pub fn a_reply_numbers_its_files_from_zero_test() {
  let chart =
    attachment.file(filename: "chart.png", content_type: "image/png", data: <<
      1,
    >>)

  let data =
    MessageCallbackData(..interaction.text("see attached"), files: [
      chart,
    ])

  assert encoded(ChannelMessageWithSource(data))
    == "{\"type\":4,\"data\":{\"content\":\"see attached\","
    <> "\"attachments\":[{\"id\":0,\"filename\":\"chart.png\"}]}}"
}

pub fn tts_is_only_written_when_true_test() {
  let data = MessageCallbackData(..interaction.text("hi"), tts: True)

  assert encoded(ChannelMessageWithSource(data))
    == "{\"type\":4,\"data\":{\"tts\":true,\"content\":\"hi\"}}"
}

/// EPHEMERAL is the only flag this response takes.
pub fn a_public_defer_carries_nothing_test() {
  assert encoded(DeferredChannelMessageWithSource(False)) == "{\"type\":5}"
}

/// The defer fixes ephemerality for the whole interaction: deferring publicly
/// and then editing with EPHEMERAL leaks the reply into the channel.
pub fn an_ephemeral_defer_sets_the_flag_test() {
  assert encoded(DeferredChannelMessageWithSource(True))
    == "{\"type\":5,\"data\":{\"flags\":64}}"
}

/// Type 4 reads the same empty object as a new message.
pub fn an_empty_update_changes_nothing_test() {
  assert encoded(UpdateMessage(interaction.update_data(mentions.none())))
    == "{\"type\":7,\"data\":{}}"
}

/// Setting the content must not decide anything about the buttons.
pub fn updating_the_content_leaves_the_components_alone_test() {
  let data =
    Edit(..interaction.update_data(mentions.none()), content: Present("Done"))

  assert encoded(UpdateMessage(data))
    == "{\"type\":7,\"data\":{\"content\":\"Done\","
    <> "\"allowed_mentions\":{\"parse\":[],\"replied_user\":false}}}"
}

/// Leaving the key out keeps the buttons live.
pub fn stripping_the_components_sends_an_empty_array_test() {
  let data =
    Edit(..interaction.update_data(mentions.none()), components: Present([]))

  assert encoded(UpdateMessage(data))
    == "{\"type\":7,\"data\":{"
    <> "\"allowed_mentions\":{\"parse\":[],\"replied_user\":false},"
    <> "\"components\":[]}}"
}

pub fn the_three_states_of_an_updated_list_test() {
  let base = interaction.update_data(mentions.none())

  let cases = [
    #(field.Absent, "{\"type\":7,\"data\":{}}"),
    #(Null, "{\"type\":7,\"data\":{\"embeds\":null}}"),
    #(Present([]), "{\"type\":7,\"data\":{\"embeds\":[]}}"),
  ]

  list.each(cases, fn(row) {
    let #(embeds, expected) = row
    let data = Edit(..base, embeds: embeds)

    assert encoded(UpdateMessage(data)) == expected
  })
}

/// An update that changes the content and omits the policy is re-parsed with
/// Discord's defaults, so the policy rides along with `content` and
/// `components` and stays off everything else.
pub fn the_policy_rides_with_content_and_components_test() {
  let base = interaction.update_data(mentions.none())
  let policy = "\"allowed_mentions\":{\"parse\":[],\"replied_user\":false}"

  let cases = [
    #(
      Edit(..base, content: Present("@everyone hi")),
      "{\"type\":7,\"data\":{\"content\":\"@everyone hi\"," <> policy <> "}}",
    ),
    #(
      Edit(..base, components: Present([])),
      "{\"type\":7,\"data\":{" <> policy <> ",\"components\":[]}}",
    ),
    #(
      Edit(
        ..base,
        flags: Present(message.message_flags(of: [message.SuppressEmbeds])),
      ),
      "{\"type\":7,\"data\":{\"flags\":4}}",
    ),
  ]

  list.each(cases, fn(row) {
    let #(data, expected) = row
    assert encoded(UpdateMessage(data)) == expected
  })
}

/// The rule governs whether the key is written, never what goes in it.
pub fn the_callers_policy_is_never_rewritten_test() {
  let data =
    Edit(
      ..interaction.update_data(mentions.all() |> mentions.ping_reply(True)),
      content: Present("hi"),
    )

  assert encoded(UpdateMessage(data))
    == "{\"type\":7,\"data\":{\"content\":\"hi\",\"allowed_mentions\":"
    <> "{\"parse\":[\"users\",\"roles\",\"everyone\"],\"replied_user\":true}}}"
}

pub fn an_update_can_replace_the_attachments_test() {
  let data =
    Edit(
      ..interaction.update_data(mentions.none()),
      attachments: attachment.SetAttachments(keep: [], add: []),
    )

  assert encoded(UpdateMessage(data))
    == "{\"type\":7,\"data\":{\"attachments\":[]}}"
}

pub fn an_updated_component_row_is_handed_to_the_encoder_test() {
  let rows = component.rows([component.button("confirm", "Confirm")])
  let data =
    Edit(..interaction.update_data(mentions.none()), components: Present(rows))
  let encoded_rows = json.to_string(json.array(rows, component.to_json))

  assert encoded(UpdateMessage(data))
    == "{\"type\":7,\"data\":{"
    <> "\"allowed_mentions\":{\"parse\":[],\"replied_user\":false},"
    <> "\"components\":"
    <> encoded_rows
    <> "}}"
}

/// An empty list means there is nothing to suggest, so the key is written.
pub fn no_suggestions_is_still_a_choices_array_test() {
  assert encoded(AutocompleteResult(choices: []))
    == "{\"type\":8,\"data\":{\"choices\":[]}}"
}

pub fn choices_go_out_in_the_order_given_test() {
  let choices = [choice("alpha"), choice("beta")]
  let encoded_choices =
    json.to_string(json.array(choices, application_command.choice_to_json))

  assert encoded(AutocompleteResult(choices: choices))
    == "{\"type\":8,\"data\":{\"choices\":" <> encoded_choices <> "}}"
}

/// Discord's limit is 25, and Discord is the one that answers for it: glyde
/// sends the list it was handed rather than quietly dropping the tail.
pub fn a_list_past_the_limit_is_sent_whole_test() {
  let choices =
    list.index_map(list.repeat(Nil, 30), fn(_, index) { choice(int(index)) })
  let encoded_choices =
    json.to_string(json.array(choices, application_command.choice_to_json))

  assert encoded(AutocompleteResult(choices: choices))
    == "{\"type\":8,\"data\":{\"choices\":" <> encoded_choices <> "}}"
}

/// The multipart body is built from this list.
pub fn only_the_two_data_carrying_responses_have_files_test() {
  let cases = [
    Pong,
    DeferredChannelMessageWithSource(True),
    DeferredChannelMessageWithSource(False),
    DeferredUpdateMessage,
    AutocompleteResult(choices: [choice("alpha")]),
    UpdateMessage(interaction.update_data(mentions.none())),
    ChannelMessageWithSource(interaction.message_data()),
  ]

  list.each(cases, fn(response) {
    assert interaction.response_files(response) == []
  })
}

pub fn a_reply_hands_over_its_files_in_order_test() {
  let first =
    attachment.file(filename: "a.png", content_type: "image/png", data: <<1>>)
  let second =
    attachment.file(filename: "b.gif", content_type: "image/gif", data: <<2>>)

  let data =
    MessageCallbackData(..interaction.message_data(), files: [
      first,
      second,
    ])

  assert interaction.response_files(ChannelMessageWithSource(data))
    == [first, second]
}

/// `KeepAttachments` uploads nothing, so it cannot carry files.
pub fn an_update_uploads_only_what_it_adds_test() {
  let added =
    attachment.file(filename: "new.png", content_type: "image/png", data: <<3>>)

  let data =
    Edit(
      ..interaction.update_data(mentions.none()),
      attachments: attachment.SetAttachments(keep: [], add: [added]),
    )

  assert interaction.response_files(UpdateMessage(data)) == [added]
}

/// Without a body the callback route cannot be called at all, which is the
/// one request every interaction bot has to make.
pub fn a_response_becomes_a_plain_json_body_test() {
  assert interaction.response_body(
      ChannelMessageWithSource(interaction.text("Pong!")),
    )
    == body.json([
      #("type", json.int(4)),
      #("data", json.object([#("content", json.string("Pong!"))])),
    ])
}

/// `response_files` and the `attachments` array have to number the same list,
/// so the body pairs them rather than leaving the caller to.
pub fn a_response_with_a_file_goes_out_multipart_test() {
  let upload =
    attachment.file(filename: "graph.png", content_type: "image/png", data: <<
      9,
    >>)

  let data = MessageCallbackData(..interaction.message_data(), files: [upload])
  let response = ChannelMessageWithSource(data)

  let #(content_type, wire) =
    body.encode(interaction.response_body(response), boundary: boundary())

  let assert Some(kind) = content_type
  assert string.starts_with(kind, "multipart/form-data; boundary=\"")
  // The callback's array lives under `data`, and it is the only one: a second
  // at the top level is not part of the callback object.
  assert payload_json(wire) == encoded(response)
  assert payload_json(wire)
    == "{\"type\":4,\"data\":{\"attachments\":[{\"id\":0,\"filename\":\"graph.png\"}]}}"
}

/// An edit that keeps an attachment and uploads another says so once. A
/// top-level array holding only the upload would delete the kept one.
pub fn an_update_names_every_attachment_once_test() {
  let added =
    attachment.file(filename: "new.png", content_type: "image/png", data: <<3>>)

  let data =
    Edit(
      ..interaction.update_data(mentions.none()),
      attachments: attachment.SetAttachments(
        keep: [attachment.keep(id.from_string("999888777"))],
        add: [added],
      ),
    )
  let response = UpdateMessage(data)

  let #(_, wire) =
    body.encode(interaction.response_body(response), boundary: boundary())

  assert payload_json(wire) == encoded(response)
  assert string.contains(payload_json(wire), "999888777")
}

/// The `payload_json` part, which is the whole document Discord reads.
fn payload_json(wire: body.Wire) -> String {
  let assert body.Bytes(bytes) = wire
  let assert Ok(rendered) = bit_array.to_string(bytes)
  let assert Ok(#(_, after_headers)) = string.split_once(rendered, "\r\n\r\n")
  let assert Ok(#(document, _)) = string.split_once(after_headers, "\r\n--")
  document
}
