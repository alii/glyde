//// Files going up with a message, and the attachments already on one that an
//// edit should keep.
////
//// Discord pairs an uploaded part with its metadata through an `attachments`
//// array whose `id` is the `n` in the `files[n]` part name. The array and
//// `parts` number the same list.
////
//// On an edit that array is the complete resulting set: anything left out is
//// deleted, so kept attachments and new files go together.

import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import glyde/field.{type Field, Absent, Present}
import glyde/id
import glyde/rest/body
import glyde/wire

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
    #("description", text(kept.description)),
    #("title", text(kept.title)),
  ])
}

fn file_to_json(a_file: File, index: Int) -> Json {
  wire.object([
    // Discord types this as "snowflake or number" and writes a bare number
    // for a new upload in its own example.
    #("id", Present(json.int(index))),
    #("filename", Present(json.string(wire_filename(a_file)))),
    #("description", text(a_file.description)),
    #("title", text(a_file.title)),
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

fn text(value: Option(String)) -> Field(Json) {
  case value {
    Some(string) -> Present(json.string(string))
    None -> Absent
  }
}
