//// A file attached to a message: what arrives with one, and what goes up on a
//// send or an edit. `Attachment` is the received record with its CDN URLs;
//// `File` is bytes to upload, paired with the `attachments` array by position.
////
//// The Clips-only fields, `clip_participants`, `clip_created_at` and
//// `application`, are not modelled.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import glyde/field.{type Field, Absent, Present}
import glyde/flags.{type Flags}
import glyde/id
import glyde/rest/body
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

/// Read `width` and `height` and pair them. Discord sends both or neither on
/// an attachment and on embed media, so one helper decodes both places.
pub fn dimensions_field(
  next: fn(Option(Dimensions)) -> Decoder(a),
) -> Decoder(a) {
  use width <- wire.opt_field("width", wire.integer())
  use height <- wire.opt_field("height", wire.integer())
  next(case width, height {
    Some(width), Some(height) -> Some(Dimensions(width:, height:))
    _, _ -> None
  })
}

/// Read `placeholder` and `placeholder_version` and pair them. Shared by
/// attachments and embed media.
pub fn placeholder_field(
  next: fn(Option(Placeholder)) -> Decoder(a),
) -> Decoder(a) {
  use hash <- wire.opt_field("placeholder", decode.string)
  use version <- wire.int_field("placeholder_version", 1)
  next(option.map(hash, fn(hash) { Placeholder(hash:, version:) }))
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
  use dimensions <- dimensions_field
  use placeholder <- placeholder_field
  use ephemeral <- wire.flag_field("ephemeral", False)
  use duration_secs <- wire.opt_field("duration_secs", wire.number())
  use waveform <- wire.opt_field("waveform", decode.string)
  use flags <- wire.enum_field("flags", flags.from_int)
  decode.success(Attachment(
    id:,
    filename:,
    title:,
    description:,
    content_type:,
    size:,
    url:,
    proxy_url:,
    dimensions:,
    placeholder:,
    ephemeral:,
    duration_secs:,
    waveform:,
    flags:,
  ))
}

// Uploads. Discord pairs a multipart part with its metadata through an
// `attachments` array whose `id` is the `n` in `files[n]`. The array and
// `parts` number the same list.

/// Discord blurs an attachment whose filename starts with this. There is no
/// boolean for it on the wire.
const spoiler_prefix = "SPOILER_"

/// A file to upload.
pub type File {
  File(
    filename: String,
    /// Discord answers 500 on some endpoints when a part carries no content
    /// type. Use `application/octet-stream` when you do not know.
    content_type: String,
    data: BitArray,
    /// Alt text, max 1024 characters.
    description: Option(String),
    title: Option(String),
    /// The one place the spoiler lives. `filename` never carries the prefix:
    /// `file` moves it here and `wire_filename` puts it back.
    spoiler: Bool,
    /// Set by `voice_message`. Discord needs both halves or neither, so they
    /// are one value.
    voice: Option(Voice),
  )
}

/// What makes an upload a voice message rather than an audio file.
pub type Voice {
  Voice(
    duration_secs: Float,
    /// Base64 of the sampled amplitudes.
    waveform: String,
  )
}

/// A `SPOILER_` prefix on `filename` is read as asking for a spoiler and moved
/// onto the boolean, so the two never say different things.
pub fn file(
  filename filename: String,
  content_type content_type: String,
  data data: BitArray,
) -> File {
  File(
    filename: bare_name(filename),
    content_type: content_type,
    data: data,
    description: None,
    title: None,
    spoiler: string.starts_with(filename, spoiler_prefix),
    voice: None,
  )
}

/// Alt text, read out by screen readers.
pub fn described(a_file: File, alt: String) -> File {
  File(..a_file, description: Some(alt))
}

/// Deliver it blurred, behind a click.
pub fn spoilered(a_file: File) -> File {
  File(..a_file, spoiler: True)
}

/// Send it as a voice message. Discord also wants the IS_VOICE_MESSAGE flag on
/// the message and an audio content type on the part.
pub fn voice_message(
  a_file: File,
  duration_secs duration_secs: Float,
  waveform waveform: String,
) -> File {
  File(..a_file, voice: Some(Voice(duration_secs:, waveform:)))
}

pub type KeptAttachment {
  KeptAttachment(
    id: id.AttachmentId,
    /// `None` leaves the value Discord already has. It is not a clear.
    description: Option(String),
    title: Option(String),
  )
}

pub fn keep(id: id.AttachmentId) -> KeptAttachment {
  KeptAttachment(id: id, description: None, title: None)
}

/// What a message's attachments should look like after an edit. Every route
/// that edits a message takes one of these: the rule is the same wherever the
/// field appears.
pub type EditAttachments {
  /// Leave them exactly as they are, and upload nothing.
  KeepAttachments

  /// The complete resulting set: `keep` plus `add`. Anything not listed is
  /// removed, so `SetAttachments(keep: [], add: [])` strips them all.
  SetAttachments(keep: List(KeptAttachment), add: List(File))
}

/// The `attachments` field of an edit. An empty array removes every
/// attachment, so `SetAttachments` always writes the key.
pub fn attachments_field(edit: EditAttachments) -> Field(Json) {
  case edit {
    KeepAttachments -> Absent
    SetAttachments(keep:, add:) -> Present(attachments_to_json(keep, add))
  }
}

/// The `attachments` field of a create, where the array is only the uploads
/// and no array at all means no uploads.
pub fn new_attachments_field(files: List(File)) -> Field(Json) {
  case files {
    [] -> Absent
    _ -> Present(attachments_to_json([], files))
  }
}

/// The files an edit uploads, in `files[n]` order.
pub fn added_files(edit: EditAttachments) -> List(File) {
  case edit {
    KeepAttachments -> []
    SetAttachments(add:, ..) -> add
  }
}

/// Kept attachments first with the snowflakes Discord issued, then new files
/// numbered from 0. That numbering indexes the multipart parts, not this array.
fn attachments_to_json(kept: List(KeptAttachment), files: List(File)) -> Json {
  json.preprocessed_array(list.append(
    list.map(kept, kept_to_json),
    list.index_map(files, file_to_json),
  ))
}

/// In `files[n]` order, the same order the `attachments` array numbers, so
/// part `n` points at entry `n`.
pub fn parts(files: List(File)) -> List(body.File) {
  list.map(files, fn(a_file) {
    body.File(
      filename: wire_filename(a_file),
      content_type: a_file.content_type,
      data: a_file.data,
    )
  })
}

/// The filename as it goes on the wire, spoiler prefix included. `spoiler`
/// decides, not the name: a record built by hand with a prefixed `filename`
/// gets stripped rather than prefixed twice.
pub fn wire_filename(a_file: File) -> String {
  case a_file.spoiler {
    True -> spoiler_prefix <> bare_name(a_file.filename)
    False -> bare_name(a_file.filename)
  }
}

fn bare_name(filename: String) -> String {
  case string.starts_with(filename, spoiler_prefix) {
    True -> string.drop_start(filename, string.length(spoiler_prefix))
    False -> filename
  }
}

fn kept_to_json(kept: KeptAttachment) -> Json {
  wire.object([
    #("id", Present(id.to_json(kept.id))),
    #("description", wire.put(wire.opt(kept.description), json.string)),
    #("title", wire.put(wire.opt(kept.title), json.string)),
  ])
}

fn file_to_json(a_file: File, index: Int) -> Json {
  wire.object([
    // Discord types this as "snowflake or number" and writes a bare number
    // for a new upload in its own example.
    #("id", Present(json.int(index))),
    #("filename", Present(json.string(wire_filename(a_file)))),
    #("description", wire.put(wire.opt(a_file.description), json.string)),
    #("title", wire.put(wire.opt(a_file.title), json.string)),
    // Both keys or neither: half a voice message is a 400.
    #("duration_secs", case a_file.voice {
      Some(Voice(duration_secs:, ..)) ->
        Present(wire.number_json(duration_secs))
      None -> Absent
    }),
    #("waveform", case a_file.voice {
      Some(Voice(waveform:, ..)) -> Present(json.string(waveform))
      None -> Absent
    }),
  ])
}
