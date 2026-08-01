//// Message embeds, as they arrive. Every top-level field is optional: the
//// commonest embed is a link preview with no title, description or colour.
////
//// `glyde/payload/embed` is the send shape, which drops what Discord ignores.

import gleam/dynamic/decode.{type Decoder}
import gleam/option.{type Option, None, Some}
import glyde/flags.{type Flags}
import glyde/wire

pub type Embed {
  Embed(
    /// Max 256 characters.
    title: Option(String),
    /// An open set: Discord ships values it has not documented.
    type_: Option(EmbedType),
    /// Max 4096 characters.
    description: Option(String),
    /// Embeds sharing a url are merged into one by the client.
    url: Option(String),
    /// ISO-8601.
    timestamp: Option(String),
    /// 0xRRGGBB.
    color: Option(Int),
    footer: Option(EmbedFooter),
    image: Option(EmbedMedia),
    thumbnail: Option(EmbedMedia),
    /// Receive only.
    video: Option(EmbedMedia),
    /// Receive only.
    provider: Option(EmbedProvider),
    author: Option(EmbedAuthor),
    /// Max 25.
    fields: List(EmbedField),
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
  case known_embed_type(value) {
    Some(known) -> known
    None -> UnknownEmbedType(value)
  }
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

/// One record for `image`, `thumbnail` and `video`.
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
