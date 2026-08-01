import gleam/json
import gleam/list
import gleam/option.{None, Some}
import glyde/field.{Absent, Null, Present}
import glyde/id
import glyde/model/component
import glyde/model/message as model
import glyde/payload/allowed_mentions as mentions
import glyde/payload/embed
import glyde/payload/file
import glyde/payload/message
import glyde/rest/body

fn created(payload: message.CreateMessage) -> String {
  payload_json(message.create_body(payload))
}

fn edited(payload: message.EditMessage) -> String {
  payload_json(message.edit_body(payload))
}

/// What these tests pin is the `payload_json` document. With files that body
/// goes out as multipart, and the fields are the same either way.
fn payload_json(sent: body.Body) -> String {
  let assert body.Form(payload:, files: _) = sent
  json.to_string(json.object(payload))
}

pub fn an_empty_create_is_an_empty_object_test() {
  assert created(message.create()) == "{}"
}

/// A body carrying `"embeds":null,"tts":false` says something about fields the
/// caller never touched.
pub fn plain_text_carries_nothing_else_test() {
  assert created(message.text("hello")) == "{\"content\":\"hello\"}"
}

pub fn a_reply_writes_the_reference_test() {
  let body =
    message.CreateMessage(
      ..message.reply_to(id.from_string("5"), "hello"),
      allowed_mentions: Some(mentions.none()),
    )

  assert created(body)
    == "{\"content\":\"hello\","
    <> "\"allowed_mentions\":{\"parse\":[],\"replied_user\":false},"
    <> "\"message_reference\":{\"type\":0,\"message_id\":\"5\",\"fail_if_not_exists\":true}}"
}

/// The one create Discord accepts with nothing but a reference.
pub fn a_forward_needs_a_channel_test() {
  let body = message.forward_of(id.from_string("5"), from: id.from_string("9"))

  assert created(body)
    == "{\"message_reference\":{\"type\":1,\"message_id\":\"5\",\"channel_id\":\"9\"}}"
}

pub fn a_reply_may_name_its_channel_and_guild_test() {
  let reference =
    message.Reply(
      message_id: id.from_string("5"),
      channel_id: Some(id.from_string("9")),
      guild_id: Some(id.from_string("7")),
      fail_if_not_exists: False,
    )

  assert json.to_string(message.reference_to_json(reference))
    == "{\"type\":0,\"message_id\":\"5\",\"channel_id\":\"9\",\"guild_id\":\"7\","
    <> "\"fail_if_not_exists\":false}"
}

pub fn a_file_becomes_an_attachments_entry_test() {
  let chart =
    file.described(
      file.file(filename: "chart.png", content_type: "image/png", data: <<1>>),
      "a chart",
    )

  let body =
    message.CreateMessage(..message.text("see attached"), files: [
      chart,
    ])

  assert created(body)
    == "{\"content\":\"see attached\","
    <> "\"attachments\":[{\"id\":0,\"filename\":\"chart.png\",\"description\":\"a chart\"}]}"
}

/// An empty array is an absence on a create; on an edit it is an instruction.
pub fn empty_lists_are_omitted_on_a_create_test() {
  let body =
    message.CreateMessage(
      ..message.create(),
      embeds: [],
      components: [],
      sticker_ids: [],
      files: [],
    )

  assert created(body) == "{}"
}

pub fn booleans_are_only_written_when_true_test() {
  let cases = [
    #(message.CreateMessage(..message.create(), tts: False), "{}"),
    #(message.CreateMessage(..message.create(), tts: True), "{\"tts\":true}"),
  ]

  list.each(cases, fn(row) {
    let #(body, expected) = row
    assert created(body) == expected
  })
}

/// Discord ignores `enforce_nonce` without a nonce, and `NoNonce` is the only
/// way to say "no nonce", so the inert pair cannot be built at all.
pub fn enforcement_without_a_nonce_is_not_written_test() {
  assert created(
      message.CreateMessage(..message.create(), nonce: message.NoNonce),
    )
    == "{}"
}

/// Zero flags is Discord's default, so writing it says nothing.
pub fn no_flags_is_not_written_test() {
  assert created(
      message.CreateMessage(..message.create(), flags: model.no_flags),
    )
    == "{}"
}

pub fn set_flags_are_written_as_the_bitfield_test() {
  let flags = model.message_flags(of: [model.SuppressEmbeds])

  assert created(message.CreateMessage(..message.create(), flags: flags))
    == "{\"flags\":4}"
}

pub fn a_nonce_goes_out_ahead_of_the_body_test() {
  let body =
    message.CreateMessage(
      ..message.text("hi"),
      nonce: message.UseNonce(model.StringNonce("abc"), enforce: True),
    )

  assert created(body)
    == "{\"content\":\"hi\",\"nonce\":\"abc\",\"enforce_nonce\":true}"
}

/// A nonce exists so a retried POST does not post twice, so the plain
/// constructor is the enforcing one.
pub fn a_nonce_enforces_itself_by_default_test() {
  let body = message.with_nonce(message.text("hi"), model.StringNonce("abc"))

  assert created(body)
    == "{\"content\":\"hi\",\"nonce\":\"abc\",\"enforce_nonce\":true}"
}

/// Discord echoes the nonce on MESSAGE_CREATE either way, so opting out of the
/// dedup takes its own constructor.
pub fn a_correlation_nonce_can_opt_out_of_the_dedup_test() {
  let body =
    message.with_correlation_nonce(message.text("hi"), model.StringNonce("abc"))

  assert created(body) == "{\"content\":\"hi\",\"nonce\":\"abc\"}"
}

pub fn sticker_ids_are_written_as_an_array_test() {
  let body =
    message.CreateMessage(..message.create(), sticker_ids: [
      id.from_string("1"),
      id.from_string("2"),
    ])

  assert created(body) == "{\"sticker_ids\":[\"1\",\"2\"]}"
}

pub fn components_are_handed_to_the_component_encoder_test() {
  let rows = component.rows([component.button("confirm", "Confirm")])
  let body = message.CreateMessage(..message.create(), components: rows)
  let encoded = json.to_string(json.array(rows, component.to_json))

  assert created(body) == "{\"components\":" <> encoded <> "}"
}

pub fn an_empty_embed_is_an_empty_object_test() {
  assert json.to_string(embed.to_json(embed.new())) == "{}"
}

pub fn an_embed_image_is_reduced_to_its_url_test() {
  let value =
    embed.Embed(
      ..embed.new(),
      image: Some("attachment://chart.png"),
      thumbnail: Some("https://example.com/t.png"),
    )

  assert json.to_string(embed.to_json(value))
    == "{\"image\":{\"url\":\"attachment://chart.png\"},"
    <> "\"thumbnail\":{\"url\":\"https://example.com/t.png\"}}"
}

pub fn a_full_embed_keeps_discords_field_order_test() {
  let value =
    embed.Embed(
      title: Some("Report"),
      description: Some("Q3"),
      url: Some("https://example.com"),
      timestamp: Some("2024-01-01T00:00:00.000Z"),
      color: Some(5_814_783),
      footer: Some(embed.EmbedFooter(
        text: "footer",
        icon_url: Some("https://example.com/f.png"),
      )),
      image: Some("https://example.com/i.png"),
      thumbnail: None,
      author: Some(embed.EmbedAuthor(name: "glyde", url: None, icon_url: None)),
      fields: [embed.EmbedField(name: "n", value: "v", inline: True)],
    )

  assert json.to_string(embed.to_json(value))
    == "{\"title\":\"Report\",\"description\":\"Q3\",\"url\":\"https://example.com\","
    <> "\"timestamp\":\"2024-01-01T00:00:00.000Z\",\"color\":5814783,"
    <> "\"footer\":{\"text\":\"footer\",\"icon_url\":\"https://example.com/f.png\"},"
    <> "\"image\":{\"url\":\"https://example.com/i.png\"},"
    <> "\"author\":{\"name\":\"glyde\"},"
    <> "\"fields\":[{\"name\":\"n\",\"value\":\"v\",\"inline\":true}]}"
}

/// An embed that arrived with `inline` set goes back out the same.
pub fn an_embed_field_always_states_inline_test() {
  let value =
    embed.Embed(..embed.new(), fields: [
      embed.EmbedField(name: "n", value: "v", inline: False),
    ])

  assert json.to_string(embed.to_json(value))
    == "{\"fields\":[{\"name\":\"n\",\"value\":\"v\",\"inline\":false}]}"
}

/// A flags-only edit carrying the policy is refused on another app's message,
/// which is how suppressing embeds on someone else's message breaks.
pub fn the_policy_rides_with_content_and_components_test() {
  let base = message.edit(mentions.none())
  let policy = "\"allowed_mentions\":{\"parse\":[],\"replied_user\":false}"
  let suppress = model.message_flags(of: [model.SuppressEmbeds])

  let cases = [
    #(
      message.EditMessage(..base, content: Present("@everyone hi")),
      "{\"content\":\"@everyone hi\"," <> policy <> "}",
    ),
    #(
      message.EditMessage(..base, components: Present([])),
      "{" <> policy <> ",\"components\":[]}",
    ),
    #(message.EditMessage(..base, flags: Present(suppress)), "{\"flags\":4}"),
    // Presence decides it: an edit to "" is still an edit to the content.
    #(
      message.EditMessage(..base, content: Present("")),
      "{\"content\":\"\"," <> policy <> "}",
    ),
    #(
      message.EditMessage(..base, content: Null),
      "{\"content\":null," <> policy <> "}",
    ),
  ]

  list.each(cases, fn(row) {
    let #(body, expected) = row
    assert edited(body) == expected
  })
}

/// The rule governs whether the key is written, never what goes in it.
pub fn the_caller_s_policy_is_never_rewritten_test() {
  let body =
    message.EditMessage(
      ..message.edit(mentions.all() |> mentions.ping_reply(True)),
      content: Present("hi"),
    )

  assert edited(body)
    == "{\"content\":\"hi\",\"allowed_mentions\":"
    <> "{\"parse\":[\"users\",\"roles\",\"everyone\"],\"replied_user\":true}}"
}

/// Discord does not re-parse mentions on a PATCH that changes neither the
/// content nor the components.
pub fn an_edit_that_changes_nothing_says_nothing_test() {
  assert edited(message.edit(mentions.all())) == "{}"
}

pub fn the_documented_edit_test() {
  let body =
    message.EditMessage(
      ..message.edit(mentions.none()),
      content: Present("new"),
      embeds: Null,
      attachments: file.SetAttachments(
        keep: [file.keep(id.from_string("77"))],
        add: [],
      ),
    )

  assert edited(body)
    == "{\"content\":\"new\",\"embeds\":null,"
    <> "\"allowed_mentions\":{\"parse\":[],\"replied_user\":false},"
    <> "\"attachments\":[{\"id\":\"77\"}]}"
}

/// `Present([])` empties the list and `Null` nulls it. With IS_COMPONENTS_V2
/// set Discord wants `embeds` reset to `[]` specifically.
pub fn the_three_states_of_an_edited_list_test() {
  let base = message.edit(mentions.none())

  let cases = [
    #(Absent, "{}"),
    #(Null, "{\"embeds\":null}"),
    #(Present([]), "{\"embeds\":[]}"),
  ]

  list.each(cases, fn(row) {
    let #(embeds, expected) = row
    assert edited(message.EditMessage(..base, embeds: embeds)) == expected
  })
}

pub fn stripping_the_components_sends_an_empty_array_test() {
  let body =
    message.EditMessage(
      ..message.edit(mentions.none()),
      components: Present([]),
    )

  assert edited(body)
    == "{\"allowed_mentions\":{\"parse\":[],\"replied_user\":false},"
    <> "\"components\":[]}"
}

pub fn edited_flags_go_out_as_the_bitfield_test() {
  let body =
    message.EditMessage(
      ..message.edit(mentions.none()),
      flags: Present(model.message_flags(of: [model.SuppressEmbeds])),
    )

  assert edited(body) == "{\"flags\":4}"
}

/// Omitting the array keeps the existing attachments; an empty one clears them.
pub fn keeping_attachments_omits_the_key_test() {
  assert edited(message.edit(mentions.none())) == "{}"
}

pub fn an_empty_array_deletes_all_attachments_test() {
  let body =
    message.EditMessage(
      ..message.edit(mentions.none()),
      attachments: file.SetAttachments(keep: [], add: []),
    )

  assert edited(body) == "{\"attachments\":[]}"
}

pub fn an_edit_can_keep_one_attachment_and_add_another_test() {
  let added =
    file.file(filename: "new.png", content_type: "image/png", data: <<2>>)

  let body =
    message.EditMessage(
      ..message.edit(mentions.none()),
      attachments: file.SetAttachments(
        keep: [file.keep(id.from_string("77"))],
        add: [added],
      ),
    )

  assert edited(body)
    == "{\"attachments\":[{\"id\":\"77\"},{\"id\":0,\"filename\":\"new.png\"}]}"

  assert message.edit_files(body) == [added]
}

pub fn keeping_attachments_uploads_nothing_test() {
  assert message.edit_files(message.edit(mentions.none())) == []
  assert message.edit_files(
      message.EditMessage(
        ..message.edit(mentions.none()),
        attachments: file.SetAttachments(keep: [], add: []),
      ),
    )
    == []
}

pub fn bulk_delete_lists_the_ids_test() {
  let body =
    message.BulkDelete(messages: [id.from_string("1"), id.from_string("2")])

  assert payload_json(message.bulk_delete_body(body))
    == "{\"messages\":[\"1\",\"2\"]}"
}

/// The last payload type in this module that could not reach its endpoint.
pub fn bulk_delete_has_a_body_test() {
  let ids = [id.from_string("1"), id.from_string("2")]

  assert message.bulk_delete_body(message.BulkDelete(messages: ids))
    == body.json([#("messages", json.array(ids, id.to_json))])
}
