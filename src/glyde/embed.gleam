//// Message embeds. One type for both directions: the receive-only fields
//// (type, provider, video, proxy urls, media sizes) are `None` on a value you
//// build and `to_json` never writes them, so a received embed round-trips
//// through a draft without a conversion.
////
//// ```gleam
//// embed.new()
//// |> embed.title("glyde")
//// |> embed.description("A sans-IO Discord library for Gleam.")
//// |> embed.color(0x5865F2)
//// |> embed.field("Runs on", "Erlang", inline: True)
//// ```
////
//// Setters replace, `field` appends. Nothing checks a length. Discord allows
//// a 256 title, a 4096 description, 25 fields and 6000 characters overall.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import glyde/flags.{type Flags}
import glyde/internal/utf16
import glyde/wire

pub type Embed {
  Embed(
    /// Max 256 characters.
    title: Option(String),
    /// Receive only. An open set: Discord ships values it has not documented.
    type_: Option(EmbedType),
    /// Max 4096 characters.
    description: Option(String),
    /// Embeds sharing a url are merged into one by the client.
    url: Option(String),
    /// ISO-8601. glyde does not own a clock, so this is a string you supply.
    timestamp: Option(String),
    /// 24-bit RGB, so `0x5865F2` is blurple.
    color: Option(Int),
    footer: Option(EmbedFooter),
    /// On send only `url` is read. Point it at `attachment://<filename>` to
    /// use a file uploaded in the same request.
    image: Option(EmbedMedia),
    thumbnail: Option(EmbedMedia),
    /// Receive only.
    video: Option(EmbedMedia),
    /// Receive only.
    provider: Option(EmbedProvider),
    author: Option(EmbedAuthor),
    /// Max 25.
    fields: List(EmbedField),
    /// Receive only.
    flags: EmbedFlags,
  )
}

/// Discord's documented embed types, plus the tail for the ones it ships
/// without documenting. Only `Rich` is ever sent by a bot; the rest are what
/// the client made of a link.
pub type EmbedType {
  Rich
  Image
  Video
  Gifv
  Article
  Link
  PollResult
  AutoModerationMessage
  UnknownEmbedType(String)
}

fn known_embed_type(value: String) -> Option(EmbedType) {
  case value {
    "rich" -> Some(Rich)
    "image" -> Some(Image)
    "video" -> Some(Video)
    "gifv" -> Some(Gifv)
    "article" -> Some(Article)
    "link" -> Some(Link)
    "poll_result" -> Some(PollResult)
    "auto_moderation_message" -> Some(AutoModerationMessage)
    _ -> None
  }
}

pub fn embed_type_from_string(value: String) -> EmbedType {
  known_embed_type(value) |> option.unwrap(UnknownEmbedType(value))
}

pub fn embed_type_to_string(value: EmbedType) -> String {
  case value {
    Rich -> "rich"
    Image -> "image"
    Video -> "video"
    Gifv -> "gifv"
    Article -> "article"
    Link -> "link"
    PollResult -> "poll_result"
    AutoModerationMessage -> "auto_moderation_message"
    UnknownEmbedType(other) -> other
  }
}

pub fn embed_type_decoder() -> Decoder(EmbedType) {
  wire.string_enum_with_fallback(known_embed_type, UnknownEmbedType)
}

pub type EmbedFlags =
  Flags(EmbedFlag)

pub type EmbedFlag {
  /// The embed is a content inventory entry, which a bot never sends.
  IsContentInventoryEntry
}

/// Discord's embed-flags table: the one named bit is 1 << 5.
fn embed_flag_bit(flag: EmbedFlag) -> Int {
  case flag {
    IsContentInventoryEntry -> 32
  }
}

pub fn has_flag(bits: EmbedFlags, flag: EmbedFlag) -> Bool {
  flags.has_bit(bits, embed_flag_bit(flag))
}

pub type EmbedFooter {
  EmbedFooter(
    /// Max 2048 characters.
    text: String,
    icon_url: Option(String),
    /// Receive only.
    proxy_icon_url: Option(String),
  )
}

/// One record for `image`, `thumbnail` and `video`. On send only `url` goes
/// out; Discord rejects height, width and proxy_url on an embed you post.
pub type EmbedMedia {
  EmbedMedia(
    url: Option(String),
    proxy_url: Option(String),
    height: Option(Int),
    width: Option(Int),
    content_type: Option(String),
    /// A thumbhash: a blurred preview to paint while the image loads.
    placeholder: Option(String),
    placeholder_version: Option(Int),
    /// Alt text.
    description: Option(String),
    flags: EmbedMediaFlags,
  )
}

/// Its own type, not the attachment one: Discord documents a separate table
/// for embed media, and today it names a single bit.
pub type EmbedMediaFlags =
  Flags(EmbedMediaFlag)

pub type EmbedMediaFlag {
  IsAnimated
}

/// Discord's embed-media-flags table: the one named bit is 1 << 5.
fn media_flag_bit(flag: EmbedMediaFlag) -> Int {
  case flag {
    IsAnimated -> 32
  }
}

pub fn has_media_flag(bits: EmbedMediaFlags, flag: EmbedMediaFlag) -> Bool {
  flags.has_bit(bits, media_flag_bit(flag))
}

pub type EmbedProvider {
  EmbedProvider(name: Option(String), url: Option(String))
}

pub type EmbedAuthor {
  EmbedAuthor(
    /// Max 256 characters.
    name: String,
    url: Option(String),
    icon_url: Option(String),
    /// Receive only.
    proxy_icon_url: Option(String),
  )
}

pub type EmbedField {
  /// `name` max 256, `value` max 1024, and 6000 characters across the embed.
  EmbedField(name: String, value: String, inline: Bool)
}

/// An empty embed, to pipe setters onto.
pub fn new() -> Embed {
  Embed(
    title: None,
    type_: None,
    description: None,
    url: None,
    timestamp: None,
    color: None,
    footer: None,
    image: None,
    thumbnail: None,
    video: None,
    provider: None,
    author: None,
    fields: [],
    flags: flags.none,
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
  Embed(..embed, image: Some(media_url(url)))
}

pub fn thumbnail(embed: Embed, url: String) -> Embed {
  Embed(..embed, thumbnail: Some(media_url(url)))
}

fn media_url(url: String) -> EmbedMedia {
  EmbedMedia(
    url: Some(url),
    proxy_url: None,
    height: None,
    width: None,
    content_type: None,
    placeholder: None,
    placeholder_version: None,
    description: None,
    flags: flags.none,
  )
}

pub fn author(embed: Embed, name: String) -> Embed {
  Embed(
    ..embed,
    author: Some(EmbedAuthor(
      name:,
      url: None,
      icon_url: None,
      proxy_icon_url: None,
    )),
  )
}

pub fn footer(embed: Embed, text: String) -> Embed {
  Embed(
    ..embed,
    footer: Some(EmbedFooter(text:, icon_url: None, proxy_icon_url: None)),
  )
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

/// The send shape. Type, provider, video, proxy urls and media sizes are not
/// written: Discord ignores them on a create anyway.
pub fn to_json(embed: Embed) -> Json {
  wire.object([
    #("title", wire.put(wire.opt(embed.title), json.string)),
    #("description", wire.put(wire.opt(embed.description), json.string)),
    #("url", wire.put(wire.opt(embed.url), json.string)),
    #("timestamp", wire.put(wire.opt(embed.timestamp), json.string)),
    #("color", wire.put(wire.opt(embed.color), json.int)),
    #("footer", wire.put(wire.opt(embed.footer), footer_to_json)),
    #("image", wire.put(wire.opt(embed.image), media_to_json)),
    #("thumbnail", wire.put(wire.opt(embed.thumbnail), media_to_json)),
    #("author", wire.put(wire.opt(embed.author), author_to_json)),
    #("fields", wire.put_list(wire.opt_list(embed.fields), field_to_json)),
  ])
}

// Discord wants an object here, though the url is the only key that survives a
// send.
fn media_to_json(media: EmbedMedia) -> Json {
  wire.object([#("url", wire.put(wire.opt(media.url), json.string))])
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

pub fn decoder() -> Decoder(Embed) {
  use title <- wire.opt_field("title", decode.string)
  use type_ <- wire.opt_field("type", embed_type_decoder())
  use description <- wire.opt_field("description", decode.string)
  use url <- wire.opt_field("url", decode.string)
  use timestamp <- wire.opt_field("timestamp", decode.string)
  use color <- wire.opt_field("color", wire.integer())
  use footer <- wire.opt_field("footer", footer_decoder())
  use image <- wire.opt_field("image", media_decoder())
  use thumbnail <- wire.opt_field("thumbnail", media_decoder())
  use video <- wire.opt_field("video", media_decoder())
  use provider <- wire.opt_field("provider", provider_decoder())
  use author <- wire.opt_field("author", author_decoder())
  use fields <- wire.list_field("fields", field_decoder())
  use flag_bits <- wire.int_field("flags", 0)
  decode.success(Embed(
    title:,
    type_:,
    description:,
    url:,
    timestamp:,
    color:,
    footer:,
    image:,
    thumbnail:,
    video:,
    provider:,
    author:,
    fields:,
    flags: flags.from_int(flag_bits),
  ))
}

pub fn footer_decoder() -> Decoder(EmbedFooter) {
  use text <- wire.string_field("text", "")
  use icon_url <- wire.opt_field("icon_url", decode.string)
  use proxy_icon_url <- wire.opt_field("proxy_icon_url", decode.string)
  decode.success(EmbedFooter(text:, icon_url:, proxy_icon_url:))
}

pub fn media_decoder() -> Decoder(EmbedMedia) {
  use url <- wire.opt_field("url", decode.string)
  use proxy_url <- wire.opt_field("proxy_url", decode.string)
  use height <- wire.opt_field("height", wire.integer())
  use width <- wire.opt_field("width", wire.integer())
  use content_type <- wire.opt_field("content_type", decode.string)
  use placeholder <- wire.opt_field("placeholder", decode.string)
  use placeholder_version <- wire.opt_field(
    "placeholder_version",
    wire.integer(),
  )
  use description <- wire.opt_field("description", decode.string)
  use flag_bits <- wire.int_field("flags", 0)
  decode.success(EmbedMedia(
    url:,
    proxy_url:,
    height:,
    width:,
    content_type:,
    placeholder:,
    placeholder_version:,
    description:,
    flags: flags.from_int(flag_bits),
  ))
}

pub fn provider_decoder() -> Decoder(EmbedProvider) {
  use name <- wire.opt_field("name", decode.string)
  use url <- wire.opt_field("url", decode.string)
  decode.success(EmbedProvider(name:, url:))
}

pub fn author_decoder() -> Decoder(EmbedAuthor) {
  use name <- wire.string_field("name", "")
  use url <- wire.opt_field("url", decode.string)
  use icon_url <- wire.opt_field("icon_url", decode.string)
  use proxy_icon_url <- wire.opt_field("proxy_icon_url", decode.string)
  decode.success(EmbedAuthor(name:, url:, icon_url:, proxy_icon_url:))
}

pub fn field_decoder() -> Decoder(EmbedField) {
  use name <- wire.string_field("name", "")
  use value <- wire.string_field("value", "")
  use inline <- wire.flag_field("inline", False)
  decode.success(EmbedField(name:, value:, inline:))
}
