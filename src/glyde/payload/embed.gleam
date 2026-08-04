//// Building an embed to send.
////
//// ```gleam
//// embed.new()
//// |> embed.title("glyde")
//// |> embed.description("A sans-IO Discord library for Gleam.")
//// |> embed.color(0x5865F2)
//// |> embed.field("Runs on", "Erlang", inline: True)
//// ```
////
//// Setters replace, `field` appends. `glyde/model/embed` is the receive side,
//// a different type because Discord rejects fields on send that it returns on
//// receive.
////
//// Nothing here checks a length. Discord allows a 256 title, a 4096
//// description, 25 fields and 6000 characters overall.

import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import glyde/internal/utf16
import glyde/model/embed as received
import glyde/wire

/// Transparent, so a record update works as well as the pipeline.
pub type Embed {
  Embed(
    title: Option(String),
    description: Option(String),
    url: Option(String),
    /// ISO-8601. glyde does not own a clock, so this is a string you supply.
    timestamp: Option(String),
    /// 24-bit RGB, so `0x5865F2` is blurple.
    color: Option(Int),
    footer: Option(EmbedFooter),
    /// Just the URL: Discord rejects height, width and proxy_url on send.
    /// Point it at `attachment://<filename>` to use a file uploaded in the
    /// same request.
    image: Option(String),
    thumbnail: Option(String),
    author: Option(EmbedAuthor),
    fields: List(EmbedField),
  )
}

pub type EmbedFooter {
  EmbedFooter(text: String, icon_url: Option(String))
}

pub type EmbedAuthor {
  EmbedAuthor(name: String, url: Option(String), icon_url: Option(String))
}

pub type EmbedField {
  EmbedField(name: String, value: String, inline: Bool)
}

pub fn new() -> Embed {
  Embed(
    title: None,
    description: None,
    url: None,
    timestamp: None,
    color: None,
    footer: None,
    image: None,
    thumbnail: None,
    author: None,
    fields: [],
  )
}

/// The send shape of a received embed. Type, provider, video, proxy urls and
/// media sizes do not carry: Discord ignores them on a create anyway.
pub fn from(embed: received.Embed) -> Embed {
  Embed(
    title: embed.title,
    description: embed.description,
    url: embed.url,
    timestamp: embed.timestamp,
    color: embed.color,
    footer: option.map(embed.footer, fn(footer) {
      EmbedFooter(text: footer.text, icon_url: footer.icon_url)
    }),
    image: option.then(embed.image, fn(media) { media.url }),
    thumbnail: option.then(embed.thumbnail, fn(media) { media.url }),
    author: option.map(embed.author, fn(author) {
      EmbedAuthor(name: author.name, url: author.url, icon_url: author.icon_url)
    }),
    fields: list.map(embed.fields, fn(field) {
      EmbedField(name: field.name, value: field.value, inline: field.inline)
    }),
  )
}

pub fn title(embed: Embed, title: String) -> Embed {
  Embed(..embed, title: Some(title))
}

pub fn description(embed: Embed, description: String) -> Embed {
  Embed(..embed, description: Some(description))
}

/// Makes the title a link. Without a title it shows nothing.
pub fn url(embed: Embed, url: String) -> Embed {
  Embed(..embed, url: Some(url))
}

/// ISO-8601, for the timestamp Discord renders in the footer.
pub fn timestamp(embed: Embed, iso8601: String) -> Embed {
  Embed(..embed, timestamp: Some(iso8601))
}

/// The colour of the bar down the left, as 24-bit RGB.
pub fn color(embed: Embed, rgb: Int) -> Embed {
  Embed(..embed, color: Some(rgb))
}

pub fn image(embed: Embed, url: String) -> Embed {
  Embed(..embed, image: Some(url))
}

pub fn thumbnail(embed: Embed, url: String) -> Embed {
  Embed(..embed, thumbnail: Some(url))
}

pub fn author(embed: Embed, name: String) -> Embed {
  Embed(..embed, author: Some(EmbedAuthor(name:, url: None, icon_url: None)))
}

pub fn footer(embed: Embed, text: String) -> Embed {
  Embed(..embed, footer: Some(EmbedFooter(text:, icon_url: None)))
}

/// Append a field. Discord shows up to three inline fields side by side and
/// stacks the rest.
pub fn field(
  embed: Embed,
  name: String,
  value: String,
  inline inline: Bool,
) -> Embed {
  Embed(
    ..embed,
    fields: list.append(embed.fields, [EmbedField(name:, value:, inline:)]),
  )
}

/// Discord's cap across every embed on one message, not per embed. In UTF-16
/// code units, so an emoji spends two of them.
pub const total_character_limit: Int = 6000

/// What Discord counts against `total_character_limit`: title, description,
/// footer text, author name, and every field name and value, over all the
/// embeds a message carries. One embed on its own is `character_count([it])`.
pub fn character_count(embeds: List(Embed)) -> Int {
  list.fold(embeds, 0, fn(total, embed) { total + counted(embed) })
}

fn counted(embed: Embed) -> Int {
  let counted_option = fn(value: Option(String)) {
    case value {
      Some(v) -> utf16.length(v)
      None -> 0
    }
  }

  counted_option(embed.title)
  + counted_option(embed.description)
  + case embed.footer {
    Some(EmbedFooter(text:, ..)) -> utf16.length(text)
    None -> 0
  }
  + case embed.author {
    Some(EmbedAuthor(name:, ..)) -> utf16.length(name)
    None -> 0
  }
  + list.fold(embed.fields, 0, fn(total, f) {
    total + utf16.length(f.name) + utf16.length(f.value)
  })
}

/// Public so a hand-rolled request can reuse it.
pub fn to_json(embed: Embed) -> Json {
  wire.object([
    #("title", wire.put(wire.opt(embed.title), json.string)),
    #("description", wire.put(wire.opt(embed.description), json.string)),
    #("url", wire.put(wire.opt(embed.url), json.string)),
    #("timestamp", wire.put(wire.opt(embed.timestamp), json.string)),
    #("color", wire.put(wire.opt(embed.color), json.int)),
    #("footer", wire.put(wire.opt(embed.footer), footer_to_json)),
    #("image", wire.put(wire.opt(embed.image), url_object)),
    #("thumbnail", wire.put(wire.opt(embed.thumbnail), url_object)),
    #("author", wire.put(wire.opt(embed.author), author_to_json)),
    #("fields", wire.put_list(wire.opt_list(embed.fields), field_to_json)),
  ])
}

// Discord wants an object here, though the url is the only key that survives a
// send.
fn url_object(url: String) -> Json {
  json.object([#("url", json.string(url))])
}

fn footer_to_json(footer: EmbedFooter) -> Json {
  wire.object([
    #("text", wire.present(json.string(footer.text))),
    #("icon_url", wire.put(wire.opt(footer.icon_url), json.string)),
  ])
}

fn author_to_json(author: EmbedAuthor) -> Json {
  wire.object([
    #("name", wire.present(json.string(author.name))),
    #("url", wire.put(wire.opt(author.url), json.string)),
    #("icon_url", wire.put(wire.opt(author.icon_url), json.string)),
  ])
}

fn field_to_json(field: EmbedField) -> Json {
  json.object([
    #("name", json.string(field.name)),
    #("value", json.string(field.value)),
    #("inline", json.bool(field.inline)),
  ])
}
