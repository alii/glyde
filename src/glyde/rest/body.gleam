//// `Body` is what an endpoint builds, `Wire` is what it serialises into. A
//// request is always `Request(Wire)`, files or not.

import gleam/bit_array
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string

const json_type = "application/json"

const multipart_type = "multipart/form-data"

/// `Form` keeps its fields open rather than closing them into a document,
/// because the `attachments` array Discord matches parts against goes inside
/// them. The routes that write that array themselves use the other two.
pub type Body {
  NoBody

  /// `payload_json` plus one part per file, and plain JSON when there are no
  /// files. Supplying `attachments` yourself takes over matching ids to parts.
  Form(payload: List(#(String, Json)), files: List(File))

  /// The same envelope with `payload_json` already written. For a route whose
  /// `attachments` array is not at the top level: the interaction callback
  /// nests its own under `data`, and a second top-level array would name the
  /// same parts again and disagree with the first.
  Finished(payload: Json, files: List(File))

  /// A top-level JSON array, which the bulk command overwrite `PUT`s take.
  /// Every route with an array body is a replace, so none of them take files.
  JsonArray(items: List(Json))
}

/// Plain `application/json`. A file can still be added later.
pub fn json(fields: List(#(String, Json))) -> Body {
  Form(payload: fields, files: [])
}

/// A top-level JSON array, which the bulk command overwrite `PUT`s take.
pub fn json_array(items: List(Json)) -> Body {
  JsonArray(items:)
}

/// No field name: `encode` names each part `files[n]` from its position and
/// writes the matching `attachments` entry from the same list.
pub type File {
  File(
    filename: String,
    /// Discord answers 500 on some endpoints when a part carries no content
    /// type. Use `application/octet-stream` if you do not know.
    content_type: String,
    data: BitArray,
  )
}

/// Separate cases because some HTTP clients take a String and nothing else.
/// Such an adapter can match on `Bytes` and fail instead of mangling a JPEG.
pub type Wire {
  Empty
  Text(String)
  Bytes(BitArray)
}

/// The multipart delimiter, checked on the way in. Opaque so a boundary no
/// server can parse, `""` above all, cannot reach a `Content-Type` header.
pub opaque type Boundary {
  Boundary(text: String)
}

/// Why a string is not a boundary. RFC 2046 section 5.1.1 allows 1 to 70
/// characters from a fixed set, and forbids a trailing space.
pub type InvalidBoundary {
  BoundaryEmpty
  BoundaryTooLong(length: Int)
  /// The first character outside RFC 2046's `bchars`.
  BoundaryIllegalCharacter(character: String)
  BoundaryTrailingSpace
}

/// Our own 40 characters. Long enough that a body containing it by accident is
/// not a thing, and `encode` handles the body that contains it on purpose.
pub const default_boundary: Boundary = Boundary(
  "glydeBoundary7Zx3Qv9Kw1Mn5Bt2Rc8Yd4Hj6Fs",
)

/// A boundary of your own. RFC 2046 section 5.1.1: 1 to 70 characters of
/// `A-Z a-z 0-9 '()+_,-./:=?` and space, and not a space at the end.
pub fn boundary(text: String) -> Result(Boundary, InvalidBoundary) {
  let points = string.to_utf_codepoints(text)
  case list.length(points) {
    0 -> Error(BoundaryEmpty)
    length if length > 70 -> Error(BoundaryTooLong(length:))
    _ ->
      case list.find(points, fn(point) { !is_bchar(point) }) {
        Ok(bad) ->
          Error(BoundaryIllegalCharacter(string.from_utf_codepoints([bad])))
        Error(_) ->
          case string.ends_with(text, " ") {
            True -> Error(BoundaryTrailingSpace)
            False -> Ok(Boundary(text))
          }
      }
  }
}

/// The characters themselves, for a host writing the header by hand. What
/// `encode` used may be longer: see `encode`. A `bchar` can be a space, so
/// write it as a quoted string, `boundary="..."`.
pub fn boundary_to_string(boundary: Boundary) -> String {
  boundary.text
}

/// RFC 2046 section 5.1.1 `bchars`: letters, digits, `'()+_,-./:=?`, space.
fn is_bchar(point: UtfCodepoint) -> Bool {
  case string.utf_codepoint_to_int(point) {
    code if code >= 48 && code <= 57 -> True
    code if code >= 65 && code <= 90 -> True
    code if code >= 97 && code <= 122 -> True
    32 | 39 | 40 | 41 | 43 | 44 | 45 | 46 | 47 | 58 | 61 | 63 | 95 -> True
    _ -> False
  }
}

/// Serialise a body, with the `content-type` header value it needs. A
/// delimiter inside a part would end it early, so a boundary the parts contain
/// grows until they do not: the header always names what was written.
pub fn encode(
  body: Body,
  boundary boundary: Boundary,
) -> #(Option(String), Wire) {
  case body {
    NoBody -> #(None, Empty)

    // An empty multipart envelope earns a misleading 400 from an endpoint
    // expecting JSON.
    Form(payload, []) -> as_json(json.object(payload))
    Form(payload, files) ->
      as_multipart(
        json.object(with_attachments(payload, files)),
        files,
        boundary,
      )

    Finished(payload, []) -> as_json(payload)
    Finished(payload, files) -> as_multipart(payload, files, boundary)

    JsonArray(items) -> as_json(json.preprocessed_array(items))
  }
}

fn as_json(document: Json) -> #(Option(String), Wire) {
  #(Some(json_type), Text(json.to_string(document)))
}

fn as_multipart(
  document: Json,
  files: List(File),
  boundary: Boundary,
) -> #(Option(String), Wire) {
  let #(written, bytes) =
    uncollided(json.to_string(document), files, boundary.text)
  // A `bchar` can be a space or one of HTTP's separators, so the parameter has
  // to be a quoted string. Quote and backslash are not `bchar`s, so there is
  // nothing inside to escape.
  #(Some(multipart_type <> "; boundary=\"" <> written <> "\""), Bytes(bytes))
}

/// Flatten a `Wire` for an HTTP client that takes bytes. `rest.request` hands
/// back a `Request(Wire)`, so every host doing its own IO ends here.
pub fn to_bits(wire: Wire) -> BitArray {
  case wire {
    Empty -> <<>>
    Text(text) -> bit_array.from_string(text)
    Bytes(data) -> data
  }
}

/// True when the parts contain the delimiter, which `encode` answers by
/// growing the boundary. Ask before encoding if you want to know it happened.
pub fn boundary_collides(body: Body, boundary: Boundary) -> Bool {
  case body {
    Form(payload, [_, ..] as files) ->
      collides(
        json.to_string(json.object(with_attachments(payload, files))),
        files,
        boundary,
      )

    Finished(payload, [_, ..] as files) ->
      collides(json.to_string(payload), files, boundary)

    _ -> False
  }
}

fn collides(payload: String, files: List(File), boundary: Boundary) -> Bool {
  let bytes = multipart(payload, files, boundary.text)
  list.length(delimiters_in(bytes, boundary.text)) > delimiters_written(files)
}

/// The parts, and the boundary they were written with.
///
/// A retry appends a run of digits the parts hold behind no delimiter, so the
/// boundary jumps straight to one they cannot contain. Growing it a character
/// at a time instead would let the file bytes, which come from strangers,
/// decide how many times the whole body is re-serialised and re-scanned.
fn uncollided(
  payload: String,
  files: List(File),
  boundary: String,
) -> #(String, BitArray) {
  let bytes = multipart(payload, files, boundary)
  let found = delimiters_in(bytes, boundary)
  case list.length(found) > delimiters_written(files) {
    // Digits are `bchar`s, so the longer boundary is still a legal one, and
    // the run is only as wide as the delimiter count has digits: pushing past
    // RFC 2046's 70 characters would take ten billion delimiters in one body.
    True -> uncollided(payload, files, boundary <> escape_run(bytes, found))
    False -> #(boundary, bytes)
  }
}

/// One before `payload_json`, one before each file, one to close. A part
/// carrying a partial byte knocks the ones after it off byte lines, so a scan
/// can find fewer: only finding more is a collision, and worth a retry.
fn delimiters_written(files: List(File)) -> Int {
  2 + list.length(files)
}

/// Where `--boundary` sits in the assembled parts, as offset and size.
/// Searched in the bytes that go out rather than re-derived from the pieces,
/// so it cannot drift from what `multipart` writes. A parser does not read a
/// delimiter twice, so nor does this.
fn delimiters_in(bytes: BitArray, boundary: String) -> List(#(Int, Int)) {
  // `binary:matches` wants whole bytes, and a file can carry a partial one.
  // Padding is a no-op on everything else.
  binary_matches(
    bit_array.pad_to_bytes(bytes),
    bit_array.from_string("--" <> boundary),
  )
}

/// The lowest run of digits that no delimiter in the parts is followed by.
/// There are more runs that wide than there are delimiters to block them, so
/// one is always free, which is what makes a single retry enough.
fn escape_run(bytes: BitArray, found: List(#(Int, Int))) -> String {
  let width = string.length(int.to_string(list.length(found)))
  let taken =
    found
    |> list.filter_map(fn(delimiter) {
      let #(at, size) = delimiter
      // Bytes that are not text cannot spell a run of digits, so dropping
      // them drops nothing that could have blocked one.
      bit_array.slice(bytes, at + size, width)
      |> result.try(bit_array.to_string)
    })
    |> set.from_list

  first_free(0, width, taken)
}

fn first_free(from: Int, width: Int, taken: Set(String)) -> String {
  let candidate = string.pad_start(int.to_string(from), to: width, with: "0")
  case set.contains(taken, candidate) {
    True -> first_free(from + 1, width, taken)
    False -> candidate
  }
}

/// OTP's Boyer-Moore. Stepping through the body from Gleam allocates a
/// sub-binary per byte, which on a megabyte upload costs orders of magnitude
/// more than assembling the body did.
@external(erlang, "binary", "matches")
fn binary_matches(subject: BitArray, pattern: BitArray) -> List(#(Int, Int)) {
  case bit_array.byte_size(pattern) {
    // Unreachable: the pattern is always "--" and a boundary. Without it a
    // zero-width match would never advance.
    0 -> []
    size -> scan_matches(subject, pattern, size, 0, [])
  }
}

/// Steps past a hit rather than over it, so the matches come back
/// non-overlapping, which is what `binary:matches` gives on Erlang.
fn scan_matches(
  subject: BitArray,
  pattern: BitArray,
  size: Int,
  at: Int,
  found: List(#(Int, Int)),
) -> List(#(Int, Int)) {
  case bit_array.slice(subject, at, size) {
    Error(Nil) -> list.reverse(found)
    Ok(window) ->
      case window == pattern {
        True ->
          scan_matches(subject, pattern, size, at + size, [#(at, size), ..found])
        False -> scan_matches(subject, pattern, size, at + 1, found)
      }
  }
}

fn multipart(payload: String, files: List(File), boundary: String) -> BitArray {
  let head =
    "--"
    <> boundary
    <> "\r\nContent-Disposition: form-data; name=\"payload_json\"\r\n"
    <> "Content-Type: "
    <> json_type
    <> "\r\n\r\n"
    <> payload
    <> "\r\n"

  let parts =
    list.index_map(files, fn(file, index) { file_part(file, index, boundary) })

  // No CRLF after the closing delimiter. Discord accepts one either way.
  let close = bit_array.from_string("--" <> boundary <> "--")

  bit_array.concat([bit_array.from_string(head), ..list.append(parts, [close])])
}

fn file_part(file: File, index: Int, boundary: String) -> BitArray {
  // The brackets in `files[n]` are literal: Discord's parser rejects
  // `files%5B0%5D` and answers with a 400 that points at the body.
  let head =
    "--"
    <> boundary
    <> "\r\nContent-Disposition: form-data; name=\"files["
    <> int.to_string(index)
    <> "]\"; filename=\""
    <> quoted(file.filename)
    <> "\"\r\nContent-Type: "
    <> header_safe(file.content_type)
    <> "\r\n\r\n"

  bit_array.concat([
    bit_array.from_string(head),
    file.data,
    bit_array.from_string("\r\n"),
  ])
}

/// Discord matches a part to its metadata through an `attachments` entry whose
/// `id` is the `n` in `files[n]`. A payload that already has the key keeps it.
/// A payload that names its parts somewhere else is a `Finished` body, which
/// never reaches here.
fn with_attachments(
  payload: List(#(String, Json)),
  files: List(File),
) -> List(#(String, Json)) {
  case list.key_find(payload, "attachments") {
    Ok(_) -> payload
    Error(_) -> list.append(payload, [#("attachments", attachments(files))])
  }
}

fn attachments(files: List(File)) -> Json {
  json.preprocessed_array(
    list.index_map(files, fn(file, index) {
      json.object([
        // Discord types this as "snowflake or number" and its own example
        // writes a bare number for a new upload.
        #("id", json.int(index)),
        #("filename", json.string(file.filename)),
      ])
    }),
  )
}

/// A filename is caller data inside a quoted header parameter. Codepoints, not
/// `string.replace`, which matches clusters and so never matches "\r" in CRLF.
fn quoted(text: String) -> String {
  string.to_utf_codepoints(text)
  |> list.filter_map(fn(point) {
    case string.utf_codepoint_to_int(point) {
      // CR and LF cannot appear at all; quote and backslash can, escaped.
      13 | 10 -> Error(Nil)
      34 -> Ok("\\\"")
      92 -> Ok("\\\\")
      _ -> Ok(string.from_utf_codepoints([point]))
    }
  })
  |> string.concat
}

fn header_safe(text: String) -> String {
  string.to_utf_codepoints(text)
  |> list.filter(fn(point) {
    case string.utf_codepoint_to_int(point) {
      // CR and LF.
      13 | 10 -> False
      _ -> True
    }
  })
  |> string.from_utf_codepoints
}
