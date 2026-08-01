import gleam/bit_array
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import glyde/field.{Null, Present}
import glyde/id
import glyde/model/application_command as model
import glyde/model/component
import glyde/model/interaction as model_interaction
import glyde/model/message as model_message
import glyde/payload/allowed_mentions as mentions
import glyde/payload/file
import glyde/payload/interaction.{
  AutocompleteResult, ChannelMessageWithSource, DeferredChannelMessageWithSource,
  DeferredUpdateMessage, MessageCallbackData, Pong, UpdateMessage,
}
import glyde/payload/message.{EditMessage}
import glyde/rest/body

fn boundary() -> body.Boundary {
  let assert Ok(boundary) = body.boundary("abc123")
  boundary
}

fn encoded(response: interaction.InteractionResponse) -> String {
  json.to_string(interaction.to_json(response))
}

fn choice(name: String) -> model.ApplicationCommandOptionChoice {
  model.ApplicationCommandOptionChoice(
    name: name,
    name_localizations: None,
    value: model.StringChoice(name),
  )
}

/// 4 creates and 7 edits, which is why they are separate variants. The
/// numbering is `model/interaction`'s, the same table the callback decodes.
pub fn every_response_states_its_callback_type_test() {
  let cases = [
    #(Pong, model_interaction.PongCallback, 1),
    #(
      ChannelMessageWithSource(interaction.message_data()),
      model_interaction.ChannelMessageWithSourceCallback,
      4,
    ),
    #(
      DeferredChannelMessageWithSource(False),
      model_interaction.DeferredChannelMessageWithSourceCallback,
      5,
    ),
    #(DeferredUpdateMessage, model_interaction.DeferredUpdateMessageCallback, 6),
    #(
      UpdateMessage(interaction.update_data(mentions.none())),
      model_interaction.UpdateMessageCallback,
      7,
    ),
    #(
      AutocompleteResult(choices: []),
      model_interaction.AutocompleteResultCallback,
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
      flags: model_message.message_flags(of: [model_message.SuppressEmbeds]),
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
    file.file(filename: "chart.png", content_type: "image/png", data: <<1>>)

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
    EditMessage(
      ..interaction.update_data(mentions.none()),
      content: Present("Done"),
    )

  assert encoded(UpdateMessage(data))
    == "{\"type\":7,\"data\":{\"content\":\"Done\","
    <> "\"allowed_mentions\":{\"parse\":[],\"replied_user\":false}}}"
}

/// Leaving the key out keeps the buttons live.
pub fn stripping_the_components_sends_an_empty_array_test() {
  let data =
    EditMessage(
      ..interaction.update_data(mentions.none()),
      components: Present([]),
    )

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
    let data = EditMessage(..base, embeds: embeds)

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
      EditMessage(..base, content: Present("@everyone hi")),
      "{\"type\":7,\"data\":{\"content\":\"@everyone hi\"," <> policy <> "}}",
    ),
    #(
      EditMessage(..base, components: Present([])),
      "{\"type\":7,\"data\":{" <> policy <> ",\"components\":[]}}",
    ),
    #(
      EditMessage(
        ..base,
        flags: Present(
          model_message.message_flags(of: [model_message.SuppressEmbeds]),
        ),
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
    EditMessage(
      ..interaction.update_data(mentions.all() |> mentions.ping_reply(True)),
      content: Present("hi"),
    )

  assert encoded(UpdateMessage(data))
    == "{\"type\":7,\"data\":{\"content\":\"hi\",\"allowed_mentions\":"
    <> "{\"parse\":[\"users\",\"roles\",\"everyone\"],\"replied_user\":true}}}"
}

pub fn an_update_can_replace_the_attachments_test() {
  let data =
    EditMessage(
      ..interaction.update_data(mentions.none()),
      attachments: file.SetAttachments(keep: [], add: []),
    )

  assert encoded(UpdateMessage(data))
    == "{\"type\":7,\"data\":{\"attachments\":[]}}"
}

pub fn an_updated_component_row_is_handed_to_the_encoder_test() {
  let rows = component.rows([component.button("confirm", "Confirm")])
  let data =
    EditMessage(
      ..interaction.update_data(mentions.none()),
      components: Present(rows),
    )
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
    json.to_string(json.array(choices, model.choice_to_json))

  assert encoded(AutocompleteResult(choices: choices))
    == "{\"type\":8,\"data\":{\"choices\":" <> encoded_choices <> "}}"
}

/// Discord's limit is 25, and Discord is the one that answers for it: glyde
/// sends the list it was handed rather than quietly dropping the tail.
pub fn a_list_past_the_limit_is_sent_whole_test() {
  let choices =
    list.index_map(list.repeat(Nil, 30), fn(_, index) { choice(int(index)) })
  let encoded_choices =
    json.to_string(json.array(choices, model.choice_to_json))

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
    file.file(filename: "a.png", content_type: "image/png", data: <<1>>)
  let second =
    file.file(filename: "b.gif", content_type: "image/gif", data: <<2>>)

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
    file.file(filename: "new.png", content_type: "image/png", data: <<3>>)

  let data =
    EditMessage(
      ..interaction.update_data(mentions.none()),
      attachments: file.SetAttachments(keep: [], add: [added]),
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
    file.file(filename: "graph.png", content_type: "image/png", data: <<9>>)

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
    file.file(filename: "new.png", content_type: "image/png", data: <<3>>)

  let data =
    EditMessage(
      ..interaction.update_data(mentions.none()),
      attachments: file.SetAttachments(
        keep: [file.keep(id.from_string("999888777"))],
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
