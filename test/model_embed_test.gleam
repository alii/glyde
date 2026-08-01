import gleam/json
import gleam/list
import gleam/option.{None, Some}
import glyde/flags
import glyde/model/embed

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
      height: Some(10),
      width: Some(20),
      content_type: None,
      placeholder: None,
      placeholder_version: None,
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
  assert image.placeholder == Some("abc")
  assert image.placeholder_version == Some(1)
  assert image.description == Some("alt text")
  assert embed.has_media_flag(image.flags, embed.IsAnimated)
}

/// Discord ships embed types it never documented, so `type` is an open set.
pub fn undocumented_embed_type_survives_test() {
  let assert Ok(value) = parse("{\"type\":\"something_new\"}")
  assert value.type_ == Some(embed.UnknownEmbedType("something_new"))
  assert embed.embed_type_to_string(embed.UnknownEmbedType("something_new"))
    == "something_new"
}

/// Every documented type has a name, and the tail keeps the raw string.
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
    #("mystery", embed.UnknownEmbedType("mystery")),
  ]
  list.each(table, fn(row) {
    let #(text, value) = row
    assert embed.embed_type_from_string(text) == value
    assert embed.embed_type_to_string(value) == text
  })
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
