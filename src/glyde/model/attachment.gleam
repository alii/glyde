//// A file attached to a message. The Clips-only fields, `clip_participants`,
//// `clip_created_at` and `application`, are not modelled.

import gleam/dynamic/decode.{type Decoder}
import gleam/option.{type Option, None, Some}
import glyde/flags.{type Flags}
import glyde/id
import glyde/wire

pub type Attachment {
  Attachment(
    id: id.AttachmentId,
    filename: String,
    title: Option(String),
    /// Alt text, up to 1024 characters.
    description: Option(String),
    content_type: Option(String),
    /// Bytes.
    size: Int,
    /// A signed CDN URL that expires. Re-fetch the message, do not store it.
    url: String,
    /// The same URL through Discord's media proxy, and it expires too.
    proxy_url: String,
    /// Absent for anything that is not an image or a video. Discord sends
    /// both sides or neither, so one value carries both.
    dimensions: Option(Dimensions),
    /// A thumbhash: a blurred preview to paint while the image loads. The
    /// version only says how the hash is encoded, so one value carries both.
    placeholder: Option(Placeholder),
    /// Garbage collected, so the URL dies before its signature expires.
    ephemeral: Bool,
    /// Voice messages and videos. Discord sends a whole number of seconds as
    /// `3`, not `3.0`.
    duration_secs: Option(Float),
    /// Base64 waveform preview for a voice message.
    waveform: Option(String),
    flags: AttachmentFlags,
  )
}

/// Pixels. An image or a video has both, anything else has neither.
pub type Dimensions {
  Dimensions(width: Int, height: Int)
}

/// A thumbhash and the layout it is encoded in. Discord documents 1 as the
/// only version so far, so a hash that arrives without one reads as 1.
pub type Placeholder {
  Placeholder(hash: String, version: Int)
}

pub type AttachmentFlags =
  Flags(AttachmentFlag)

pub type AttachmentFlag {
  IsClip
  IsThumbnail
  /// Discord deprecated this one and still sends it.
  IsRemix
  IsSpoiler
  IsAnimated
}

/// Discord's attachment-flags table. Bit 4 is a hole.
fn attachment_flag_bit(flag: AttachmentFlag) -> Int {
  case flag {
    IsClip -> 1
    IsThumbnail -> 2
    IsRemix -> 4
    IsSpoiler -> 8
    IsAnimated -> 32
  }
}

pub fn has_flag(bits: AttachmentFlags, flag: AttachmentFlag) -> Bool {
  flags.has_bit(bits, attachment_flag_bit(flag))
}

pub fn decoder() -> Decoder(Attachment) {
  use id <- decode.field("id", id.decoder())
  use filename <- wire.string_field("filename", "")
  use title <- wire.opt_field("title", decode.string)
  use description <- wire.opt_field("description", decode.string)
  use content_type <- wire.opt_field("content_type", decode.string)
  use size <- wire.int_field("size", 0)
  use url <- wire.string_field("url", "")
  use proxy_url <- wire.string_field("proxy_url", "")
  use height <- wire.opt_field("height", wire.integer())
  use width <- wire.opt_field("width", wire.integer())
  use placeholder <- wire.opt_field("placeholder", decode.string)
  use placeholder_version <- wire.int_field("placeholder_version", 1)
  use ephemeral <- wire.flag_field("ephemeral", False)
  use duration_secs <- wire.opt_field("duration_secs", wire.number())
  use waveform <- wire.opt_field("waveform", decode.string)
  use flag_bits <- wire.int_field("flags", 0)
  decode.success(Attachment(
    id:,
    filename:,
    title:,
    description:,
    content_type:,
    size:,
    url:,
    proxy_url:,
    dimensions: case width, height {
      Some(width), Some(height) -> Some(Dimensions(width:, height:))
      _, _ -> None
    },
    placeholder: option.map(placeholder, fn(hash) {
      Placeholder(hash:, version: placeholder_version)
    }),
    ephemeral:,
    duration_secs:,
    waveform:,
    flags: flags.from_int(flag_bits),
  ))
}
