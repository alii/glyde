import gleam/http
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import glyde/attachment
import glyde/embed
import glyde/flags
import glyde/id
import glyde/message
import glyde/rest
import glyde/rest/body

fn parse(text: String) -> Result(embed.Embed, json.DecodeError) {
  json.parse(text, embed.decoder())
}

/// A link preview carries no title, description or color, and it is the most
/// common embed there is.
pub fn link_preview_embed_decodes_test() {
  let assert Ok(value) =
    parse(
      "{\"type\":\"link\",\"url\":\"https://example.com\",\"provider\":{\"name\":\"Example\",\"url\":\"https://example.com\"}}",
    )
  assert value.title == None
  assert value.description == None
  assert value.color == None
  assert value.type_ == Some(embed.Link)
  assert value.provider
    == Some(embed.EmbedProvider(
      name: Some("Example"),
      url: Some("https://example.com"),
    ))
}

/// Nothing at all is still a valid embed.
pub fn empty_embed_decodes_test() {
  let assert Ok(value) = parse("{}")
  assert value.title == None
  assert value.fields == []
  assert flags.to_int(value.flags) == 0
}

pub fn full_rich_embed_decodes_test() {
  let assert Ok(value) =
    parse(
      "{\"title\":\"t\",\"type\":\"rich\",\"description\":\"d\",\"url\":\"u\","
      <> "\"timestamp\":\"2024-01-01T00:00:00.000000+00:00\",\"color\":3447003,"
      <> "\"footer\":{\"text\":\"f\",\"icon_url\":\"fi\",\"proxy_icon_url\":\"fp\"},"
      <> "\"image\":{\"url\":\"i\",\"proxy_url\":\"ip\",\"height\":10,\"width\":20},"
      <> "\"thumbnail\":{\"url\":\"th\"},\"video\":{\"url\":\"v\"},"
      <> "\"author\":{\"name\":\"a\",\"url\":\"au\"},"
      <> "\"fields\":[{\"name\":\"n\",\"value\":\"v\",\"inline\":true},"
      <> "{\"name\":\"n2\",\"value\":\"v2\"}],\"flags\":32}",
    )
  assert value.title == Some("t")
  assert value.color == Some(3_447_003)
  assert embed.has_flag(value.flags, embed.IsContentInventoryEntry)
  assert value.footer
    == Some(embed.EmbedFooter(
      text: "f",
      icon_url: Some("fi"),
      proxy_icon_url: Some("fp"),
    ))
  assert value.image
    == Some(embed.EmbedMedia(
      url: Some("i"),
      proxy_url: Some("ip"),
      dimensions: Some(attachment.Dimensions(width: 20, height: 10)),
      content_type: None,
      placeholder: None,
      description: None,
      flags: flags.from_int(0),
    ))
  assert value.author
    == Some(embed.EmbedAuthor(
      name: "a",
      url: Some("au"),
      icon_url: None,
      proxy_icon_url: None,
    ))
  assert value.fields
    == [
      embed.EmbedField(name: "n", value: "v", inline: True),
      embed.EmbedField(name: "n2", value: "v2", inline: False),
    ]
}

/// Discord sends explicit nulls for these on partial objects.
pub fn explicit_nulls_do_not_fail_the_embed_test() {
  let nulls = [
    "{\"title\":null}", "{\"description\":null}", "{\"color\":null}",
    "{\"fields\":null}", "{\"footer\":null}", "{\"image\":null}",
    "{\"flags\":null}", "{\"type\":null}", "{\"timestamp\":null}",
    "{\"author\":null}", "{\"provider\":null}", "{\"video\":null}",
    "{\"thumbnail\":null}", "{\"url\":null}",
  ]
  list.each(nulls, fn(text) {
    let assert Ok(_) = parse(text)
    Nil
  })
}

pub fn null_array_becomes_empty_not_an_error_test() {
  let assert Ok(value) = parse("{\"fields\":null}")
  assert value.fields == []
}

/// Discord writes the same integer field as `2` and as `2.0`.
pub fn integer_fields_accept_both_json_number_spellings_test() {
  let assert Ok(plain) = parse("{\"color\":3447003,\"flags\":32}")
  let assert Ok(decimal) = parse("{\"color\":3447003.0,\"flags\":32.0}")
  assert plain.color == Some(3_447_003)
  assert decimal.color == Some(3_447_003)
  assert flags.to_int(plain.flags) == 32
  assert flags.to_int(decimal.flags) == 32
}

pub fn media_placeholder_fields_decode_test() {
  let assert Ok(value) =
    parse(
      "{\"image\":{\"url\":\"u\",\"content_type\":\"image/png\","
      <> "\"placeholder\":\"abc\",\"placeholder_version\":1,"
      <> "\"description\":\"alt text\",\"flags\":32}}",
    )
  let assert Some(image) = value.image
  assert image.content_type == Some("image/png")
  assert image.placeholder
    == Some(attachment.Placeholder(hash: "abc", version: 1))
  assert image.description == Some("alt text")
  assert embed.has_media_flag(image.flags, embed.IsAnimated)
}

/// Discord ships embed types it never documented, so `type` is an open set.
/// A value this build has no name for decodes as `None` rather than failing
/// the embed.
pub fn undocumented_embed_type_tolerated_test() {
  let assert Ok(value) = parse("{\"type\":\"something_new\"}")
  assert value.type_ == None
}

/// Every documented type has a name, and an unmodelled one is `None`.
pub fn embed_types_round_trip_test() {
  let table = [
    #("rich", embed.Rich),
    #("image", embed.Image),
    #("video", embed.Video),
    #("gifv", embed.Gifv),
    #("article", embed.Article),
    #("link", embed.Link),
    #("poll_result", embed.PollResult),
    #("auto_moderation_message", embed.AutoModerationMessage),
  ]
  list.each(table, fn(row) {
    let #(text, value) = row
    assert embed.embed_type_from_string(text) == Some(value)
    assert embed.embed_type_to_string(value) == text
  })
  assert embed.embed_type_from_string("mystery") == None
}

/// Discord omits `inline` rather than sending false.
pub fn absent_inline_is_false_test() {
  let assert Ok(value) =
    parse("{\"fields\":[{\"name\":\"n\",\"value\":\"v\"}]}")
  assert value.fields
    == [embed.EmbedField(name: "n", value: "v", inline: False)]
}

/// A malformed footer should not take the whole message down.
pub fn missing_required_strings_default_rather_than_fail_test() {
  let assert Ok(value) = parse("{\"footer\":{},\"author\":{},\"fields\":[{}]}")
  assert value.footer
    == Some(embed.EmbedFooter(text: "", icon_url: None, proxy_icon_url: None))
  assert value.author
    == Some(embed.EmbedAuthor(
      name: "",
      url: None,
      icon_url: None,
      proxy_icon_url: None,
    ))
  assert value.fields == [embed.EmbedField(name: "", value: "", inline: False)]
}

pub fn empty_embed_sends_nothing_test() {
  assert json.to_string(embed.to_json(embed.new())) == "{}"
}

pub fn setters_chain_test() {
  let built =
    embed.new()
    |> embed.title("glyde")
    |> embed.url("https://github.com/alii/glyde")
    |> embed.description("A sans-IO Discord library for Gleam.")
    |> embed.color(0x5865F2)
    |> embed.author("Alistair")

  assert built.title == Some("glyde")
  assert built.url == Some("https://github.com/alii/glyde")
  assert built.color == Some(0x5865F2)
  assert built.author == Some(embed.EmbedAuthor("Alistair", None, None, None))
}

pub fn setters_replace_test() {
  let built = embed.new() |> embed.title("first") |> embed.title("second")
  assert built.title == Some("second")
}

/// `field` is the one setter that appends.
pub fn fields_append_test() {
  let built =
    embed.new()
    |> embed.field("Runs on", "Erlang", inline: True)
    |> embed.field("Licence", "Apache-2.0", inline: True)

  assert built.fields
    == [
      embed.EmbedField("Runs on", "Erlang", True),
      embed.EmbedField("Licence", "Apache-2.0", True),
    ]
}

/// The url is the only key of the image object that survives a send.
pub fn image_is_wrapped_in_an_object_test() {
  let encoded = json.to_string(embed.to_json(embed.new() |> embed.image("u")))
  assert encoded == "{\"image\":{\"url\":\"u\"}}"
}

/// Discord's 6000 counts UTF-16 code units, so an emoji is two, and it spans
/// every embed on the message rather than each one on its own.
pub fn character_count_test() {
  let built =
    embed.new()
    |> embed.title("abc")
    |> embed.description("de")
    |> embed.footer("f")
    |> embed.author("gh")
    |> embed.field("ij", "k", inline: False)

  assert embed.character_count([built]) == 11
  assert embed.character_count([embed.new() |> embed.title("🎮")]) == 2
  assert embed.character_count([]) == 0

  // The ten embeds a message may carry are one budget between them.
  assert embed.character_count([built, built]) == 22
  assert embed.total_character_limit == 6000
}

/// A built embed reaches Discord as a real HTTP request.
pub fn an_embed_becomes_a_request_test() {
  let card =
    embed.new()
    |> embed.title("v0.1.0")
    |> embed.description("shipped")
    |> embed.color(0x5865F2)

  let call =
    message.send_call(
      id.from_string("41771983423143937"),
      message.text("release") |> message.embed(card),
    )

  let req = rest.request(rest.config(rest.bot("token")), call)

  assert req.method == http.Post
  assert req.host == "discord.com"
  assert req.path == "/api/v10/channels/41771983423143937/messages"
  assert request.get_header(req, "content-type") == Ok("application/json")

  let body = wire_text(req.body)
  assert string.contains(body, "\"content\":\"release\"")
  assert string.contains(body, "\"title\":\"v0.1.0\"")
  assert string.contains(body, "\"color\":5793266")
  assert !string.contains(body, "null")
}

fn wire_text(wire: body.Wire) -> String {
  case wire {
    body.Text(text) -> text
    _ -> ""
  }
}
