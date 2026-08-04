import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import glyde/draft
import glyde/field.{Absent, Null, Present}
import glyde/id
import glyde/model/component
import glyde/model/message as model
import glyde/payload/allowed_mentions as mentions
import glyde/payload/embed
import glyde/payload/file
import glyde/rest/body

fn created(payload: draft.Draft) -> String {
  payload_json(draft.to_body(payload))
}

fn edited(payload: draft.Edit) -> String {
  payload_json(draft.edit_body(payload))
}

/// What these tests pin is the `payload_json` document. With files that body
/// goes out as multipart, and the fields are the same either way.
fn payload_json(sent: body.Body) -> String {
  let assert body.Form(payload:, files: _) = sent
  json.to_string(json.object(payload))
}

pub fn an_empty_create_is_an_empty_object_test() {
  assert created(draft.new()) == "{}"
}

/// A body carrying `"embeds":null,"tts":false` says something about fields the
/// caller never touched.
pub fn plain_text_carries_nothing_else_test() {
  assert created(draft.text("hello")) == "{\"content\":\"hello\"}"
}

pub fn a_reply_writes_the_reference_test() {
  let body =
    draft.text("hello")
    |> draft.mentions(mentions.none())
    |> draft.reply_to(id.from_string("5"))

  assert created(body)
    == "{\"content\":\"hello\","
    <> "\"allowed_mentions\":{\"parse\":[],\"replied_user\":false},"
    <> "\"message_reference\":{\"type\":0,\"message_id\":\"5\",\"fail_if_not_exists\":true}}"
}

/// `glyde.reply` sets the reference last, on a message the handler has
/// already built, so it has to leave the rest of it alone.
pub fn reply_to_keeps_what_was_set_before_it_test() {
  let card = embed.new() |> embed.title("card")
  let before = draft.text("hi") |> draft.embed(card) |> draft.tts
  let after = draft.reply_to(before, id.from_string("5"))

  assert after.content == Some("hi")
  assert after.embeds == [card]
  assert after.tts
  assert string.starts_with(
    created(after),
    created(before) |> string.drop_end(1),
  )
}

/// The one create Discord accepts with nothing but a reference.
pub fn a_forward_needs_a_channel_test() {
  let body =
    draft.new()
    |> draft.forward_of(id.from_string("5"), from: id.from_string("9"))

  assert created(body)
    == "{\"message_reference\":{\"type\":1,\"message_id\":\"5\",\"channel_id\":\"9\"}}"
}

pub fn a_reply_may_name_its_channel_and_guild_test() {
  let reference =
    draft.Reply(
      message_id: id.from_string("5"),
      channel_id: Some(id.from_string("9")),
      guild_id: Some(id.from_string("7")),
      fail_if_not_exists: False,
    )

  assert json.to_string(draft.reference_to_json(reference))
    == "{\"type\":0,\"message_id\":\"5\",\"channel_id\":\"9\",\"guild_id\":\"7\","
    <> "\"fail_if_not_exists\":false}"
}

pub fn a_file_becomes_an_attachments_entry_test() {
  let chart =
    file.described(
      file.file(filename: "chart.png", content_type: "image/png", data: <<1>>),
      "a chart",
    )

  let body = draft.text("see attached") |> draft.attach(chart)

  assert created(body)
    == "{\"content\":\"see attached\","
    <> "\"attachments\":[{\"id\":0,\"filename\":\"chart.png\",\"description\":\"a chart\"}]}"
}

/// The wire format follows the files: JSON without, multipart with, and the
/// caller never picks.
pub fn attaching_a_file_makes_the_body_multipart_test() {
  let assert Ok(boundary) = body.boundary("glyde")
  let content_type = fn(payload) {
    let #(header, _) = body.encode(draft.to_body(payload), boundary:)
    header
  }
  let chart =
    file.file(filename: "chart.png", content_type: "image/png", data: <<1>>)

  assert content_type(draft.text("hi")) == Some("application/json")
  assert content_type(draft.text("hi") |> draft.attach(chart))
    == Some("multipart/form-data; boundary=\"glyde\"")
}

/// One row per setter, each from `new()`, so the expected string is that
/// setter's whole effect and nothing else's.
pub fn each_setter_writes_its_own_key_test() {
  let card = embed.new() |> embed.title("t")
  let row = case component.rows([component.button("ok", "OK")]) {
    [row] -> row
    _ -> panic as "one button is one row"
  }

  let cases = [
    #(draft.new() |> draft.content("hi"), "{\"content\":\"hi\"}"),
    #(
      draft.new() |> draft.embed(card) |> draft.embed(card),
      "{\"embeds\":[{\"title\":\"t\"},{\"title\":\"t\"}]}",
    ),
    #(
      draft.new() |> draft.component(row),
      "{\"components\":"
        <> json.to_string(json.array([row], component.to_json))
        <> "}",
    ),
    #(
      draft.new()
        |> draft.sticker(id.from_string("1"))
        |> draft.sticker(id.from_string("2")),
      "{\"sticker_ids\":[\"1\",\"2\"]}",
    ),
    #(
      draft.new() |> draft.mentions(mentions.none()),
      "{\"allowed_mentions\":{\"parse\":[],\"replied_user\":false}}",
    ),
    #(draft.new() |> draft.tts, "{\"tts\":true}"),
    #(draft.new() |> draft.suppress_embeds, "{\"flags\":4}"),
    #(draft.new() |> draft.silent, "{\"flags\":4096}"),
    // The two named flags share one field, so they have to stack.
    #(draft.new() |> draft.suppress_embeds |> draft.silent, "{\"flags\":4100}"),
  ]

  list.each(cases, fn(row) {
    let #(body, expected) = row
    assert created(body) == expected
  })
}

/// An empty array is an absence on a create; on an edit it is an instruction.
pub fn empty_lists_are_omitted_on_a_create_test() {
  let body =
    draft.Draft(
      ..draft.new(),
      embeds: [],
      components: [],
      sticker_ids: [],
      files: [],
    )

  assert created(body) == "{}"
}

pub fn booleans_are_only_written_when_true_test() {
  let cases = [
    #(draft.Draft(..draft.new(), tts: False), "{}"),
    #(draft.Draft(..draft.new(), tts: True), "{\"tts\":true}"),
  ]

  list.each(cases, fn(row) {
    let #(body, expected) = row
    assert created(body) == expected
  })
}

/// Discord ignores `enforce_nonce` without a nonce, and `NoNonce` is the only
/// way to say "no nonce", so the inert pair cannot be built at all.
pub fn enforcement_without_a_nonce_is_not_written_test() {
  assert created(draft.Draft(..draft.new(), nonce: draft.NoNonce)) == "{}"
}

/// Zero flags is Discord's default, so writing it says nothing.
pub fn no_flags_is_not_written_test() {
  assert created(draft.Draft(..draft.new(), flags: model.no_flags)) == "{}"
}

pub fn set_flags_are_written_as_the_bitfield_test() {
  let flags = model.message_flags(of: [model.SuppressEmbeds])

  assert created(draft.Draft(..draft.new(), flags: flags)) == "{\"flags\":4}"
}

pub fn a_nonce_goes_out_ahead_of_the_body_test() {
  let body =
    draft.Draft(
      ..draft.text("hi"),
      nonce: draft.UseNonce(model.StringNonce("abc"), enforce: True),
    )

  assert created(body)
    == "{\"content\":\"hi\",\"nonce\":\"abc\",\"enforce_nonce\":true}"
}

/// A nonce exists so a retried POST does not post twice, so the plain
/// constructor is the enforcing one.
pub fn a_nonce_enforces_itself_by_default_test() {
  let body = draft.with_nonce(draft.text("hi"), model.StringNonce("abc"))

  assert created(body)
    == "{\"content\":\"hi\",\"nonce\":\"abc\",\"enforce_nonce\":true}"
}

/// Discord echoes the nonce on MESSAGE_CREATE either way, so opting out of the
/// dedup takes its own constructor.
pub fn a_correlation_nonce_can_opt_out_of_the_dedup_test() {
  let body =
    draft.with_correlation_nonce(draft.text("hi"), model.StringNonce("abc"))

  assert created(body) == "{\"content\":\"hi\",\"nonce\":\"abc\"}"
}

pub fn sticker_ids_are_written_as_an_array_test() {
  let body =
    draft.Draft(..draft.new(), sticker_ids: [
      id.from_string("1"),
      id.from_string("2"),
    ])

  assert created(body) == "{\"sticker_ids\":[\"1\",\"2\"]}"
}

pub fn components_are_handed_to_the_component_encoder_test() {
  let rows = component.rows([component.button("confirm", "Confirm")])
  let body = draft.Draft(..draft.new(), components: rows)
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
  let base = draft.edit(mentions.none())
  let policy = "\"allowed_mentions\":{\"parse\":[],\"replied_user\":false}"
  let suppress = model.message_flags(of: [model.SuppressEmbeds])

  let cases = [
    #(
      draft.Edit(..base, content: Present("@everyone hi")),
      "{\"content\":\"@everyone hi\"," <> policy <> "}",
    ),
    #(
      draft.Edit(..base, components: Present([])),
      "{" <> policy <> ",\"components\":[]}",
    ),
    #(draft.Edit(..base, flags: Present(suppress)), "{\"flags\":4}"),
    // Presence decides it: an edit to "" is still an edit to the content.
    #(
      draft.Edit(..base, content: Present("")),
      "{\"content\":\"\"," <> policy <> "}",
    ),
    #(draft.Edit(..base, content: Null), "{\"content\":null," <> policy <> "}"),
  ]

  list.each(cases, fn(row) {
    let #(body, expected) = row
    assert edited(body) == expected
  })
}

/// The rule governs whether the key is written, never what goes in it.
pub fn the_caller_s_policy_is_never_rewritten_test() {
  let body =
    draft.Edit(
      ..draft.edit(mentions.all() |> mentions.ping_reply(True)),
      content: Present("hi"),
    )

  assert edited(body)
    == "{\"content\":\"hi\",\"allowed_mentions\":"
    <> "{\"parse\":[\"users\",\"roles\",\"everyone\"],\"replied_user\":true}}"
}

/// Discord does not re-parse mentions on a PATCH that changes neither the
/// content nor the components.
pub fn an_edit_that_changes_nothing_says_nothing_test() {
  assert edited(draft.edit(mentions.all())) == "{}"
}

pub fn the_documented_edit_test() {
  let body =
    draft.Edit(
      ..draft.edit(mentions.none()),
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
  let base = draft.edit(mentions.none())

  let cases = [
    #(Absent, "{}"),
    #(Null, "{\"embeds\":null}"),
    #(Present([]), "{\"embeds\":[]}"),
  ]

  list.each(cases, fn(row) {
    let #(embeds, expected) = row
    assert edited(draft.Edit(..base, embeds: embeds)) == expected
  })
}

pub fn stripping_the_components_sends_an_empty_array_test() {
  let body = draft.Edit(..draft.edit(mentions.none()), components: Present([]))

  assert edited(body)
    == "{\"allowed_mentions\":{\"parse\":[],\"replied_user\":false},"
    <> "\"components\":[]}"
}

pub fn edited_flags_go_out_as_the_bitfield_test() {
  let body =
    draft.Edit(
      ..draft.edit(mentions.none()),
      flags: Present(model.message_flags(of: [model.SuppressEmbeds])),
    )

  assert edited(body) == "{\"flags\":4}"
}

/// Omitting the array keeps the existing attachments; an empty one clears them.
pub fn keeping_attachments_omits_the_key_test() {
  assert edited(draft.edit(mentions.none())) == "{}"
}

pub fn an_empty_array_deletes_all_attachments_test() {
  let body =
    draft.Edit(
      ..draft.edit(mentions.none()),
      attachments: file.SetAttachments(keep: [], add: []),
    )

  assert edited(body) == "{\"attachments\":[]}"
}

pub fn an_edit_can_keep_one_attachment_and_add_another_test() {
  let added =
    file.file(filename: "new.png", content_type: "image/png", data: <<2>>)

  let body =
    draft.Edit(
      ..draft.edit(mentions.none()),
      attachments: file.SetAttachments(
        keep: [file.keep(id.from_string("77"))],
        add: [added],
      ),
    )

  assert edited(body)
    == "{\"attachments\":[{\"id\":\"77\"},{\"id\":0,\"filename\":\"new.png\"}]}"

  assert draft.edit_files(body) == [added]
}

pub fn keeping_attachments_uploads_nothing_test() {
  assert draft.edit_files(draft.edit(mentions.none())) == []
  assert draft.edit_files(
      draft.Edit(
        ..draft.edit(mentions.none()),
        attachments: file.SetAttachments(keep: [], add: []),
      ),
    )
    == []
}

pub fn bulk_delete_lists_the_ids_test() {
  let body =
    draft.BulkDelete(messages: [id.from_string("1"), id.from_string("2")])

  assert payload_json(draft.bulk_delete_body(body))
    == "{\"messages\":[\"1\",\"2\"]}"
}

/// The last payload type in this module that could not reach its endpoint.
pub fn bulk_delete_has_a_body_test() {
  let ids = [id.from_string("1"), id.from_string("2")]

  assert draft.bulk_delete_body(draft.BulkDelete(messages: ids))
    == body.json([#("messages", json.array(ids, id.to_json))])
}

/// The smallest message Discord sends, with `extra` keys spliced in, each
/// written with its trailing comma.
fn received(content: String, extra: String) -> model.Message {
  let text =
    "{\"id\":\"1000\",\"channel_id\":\"2000\","
    <> "\"author\":{\"id\":\"3000\",\"username\":\"bob\",\"discriminator\":\"0\"},"
    <> "\"content\":"
    <> json.to_string(json.string(content))
    <> ",\"timestamp\":\"2024-01-01T00:00:00.000000+00:00\","
    <> "\"edited_timestamp\":null,\"tts\":true,\"mention_everyone\":false,"
    <> "\"mentions\":[],\"mention_roles\":[],\"pinned\":false,"
    <> extra
    <> "\"type\":0}"
  let assert Ok(value) = json.parse(text, model.decoder())
  value
}

/// Echoing a message back: what a create can say survives, and what only a
/// received message has (attachment URLs, the reply pointer, nonce, tts) does
/// not.
pub fn from_carries_what_a_create_can_set_test() {
  let heard =
    received(
      "hello",
      "\"attachments\":[{\"id\":\"13\",\"filename\":\"a.png\",\"size\":10,"
        <> "\"url\":\"u\",\"proxy_url\":\"p\"}],"
        <> "\"embeds\":[{\"type\":\"rich\",\"title\":\"t\",\"description\":\"d\","
        <> "\"provider\":{\"name\":\"x\"},\"video\":{\"url\":\"v\"},"
        <> "\"thumbnail\":{\"url\":\"th\",\"proxy_url\":\"pth\",\"width\":5},"
        <> "\"footer\":{\"text\":\"f\",\"proxy_icon_url\":\"pf\"},"
        <> "\"fields\":[{\"name\":\"n\",\"value\":\"v\",\"inline\":true}]}],"
        <> "\"sticker_items\":[{\"id\":\"11\",\"name\":\"wave\",\"format_type\":1}],"
        <> "\"message_reference\":{\"message_id\":\"9\",\"channel_id\":\"2000\"},"
        <> "\"nonce\":\"abc\","
        // SUPPRESS_EMBEDS | HAS_THREAD | SUPPRESS_NOTIFICATIONS | IS_VOICE_MESSAGE
        <> "\"flags\":"
        <> string.inspect(4 + 32 + 4096 + 8192)
        <> ",",
    )

  assert created(draft.from(heard))
    == "{\"content\":\"hello\","
    <> "\"embeds\":[{\"title\":\"t\",\"description\":\"d\","
    <> "\"footer\":{\"text\":\"f\"},\"thumbnail\":{\"url\":\"th\"},"
    <> "\"fields\":[{\"name\":\"n\",\"value\":\"v\",\"inline\":true}]}],"
    <> "\"sticker_ids\":[\"11\"],"
    <> "\"flags\":4100}"
}

pub fn from_carries_components_and_components_v2_test() {
  let heard =
    received(
      "",
      "\"components\":[{\"type\":10,\"id\":1,\"content\":\"# hi\"}],"
        <> "\"flags\":32768,",
    )
  let echoed = draft.from(heard)

  assert echoed.components == heard.components
  assert created(echoed)
    == "{\"components\":[{\"content\":\"# hi\",\"id\":1,\"type\":10}],"
    <> "\"flags\":32768}"
}

/// Without MESSAGE_CONTENT the content arrives as "", and a create that sends
/// `"content":""` beside nothing else is a 400.
pub fn from_omits_empty_content_test() {
  let echoed = draft.from(received("", ""))

  assert echoed.content == None
  assert created(echoed) == "{}"
}
