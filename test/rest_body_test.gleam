import gleam/bit_array
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import glyde/rest/body

const raw = "abc123"

/// Short and legal, so the expected bytes below stay readable.
fn boundary() -> body.Boundary {
  let assert Ok(boundary) = body.boundary(raw)
  boundary
}

fn png() -> body.File {
  body.File(
    filename: "graph.png",
    content_type: "image/png",
    data: bit_array.from_string("PNG BYTES"),
  )
}

fn text(wire: body.Wire) -> String {
  case wire {
    body.Bytes(data) -> {
      let assert Ok(rendered) = bit_array.to_string(data)
      rendered
    }
    body.Text(rendered) -> rendered
    body.Empty -> ""
  }
}

pub fn no_body_test() {
  assert body.encode(body.NoBody, boundary: boundary()) == #(None, body.Empty)
}

pub fn json_body_test() {
  let payload = [#("content", json.string("pong"))]

  assert body.encode(body.json(payload), boundary: boundary())
    == #(Some("application/json"), body.Text("{\"content\":\"pong\"}"))
}

/// The bulk overwrite `PUT`s take a top-level array, which `Form` cannot hold.
pub fn json_array_body_test() {
  let items = [
    json.object([#("name", json.string("ping"))]),
    json.object([#("name", json.string("pong"))]),
  ]

  assert body.encode(body.json_array(items), boundary: boundary())
    == #(
      Some("application/json"),
      body.Text("[{\"name\":\"ping\"},{\"name\":\"pong\"}]"),
    )
}

/// An empty bulk overwrite is `[]`, the instruction that deletes every command.
pub fn empty_json_array_body_test() {
  assert body.encode(body.json_array([]), boundary: boundary())
    == #(Some("application/json"), body.Text("[]"))
}

/// No parts, so no delimiter to end early.
pub fn json_doc_never_collides_test() {
  let doc = body.json_array([json.string("--" <> raw)])
  assert body.boundary_collides(doc, boundary()) == False
}

/// `body.json` is a `Form` with no files, so the two encode identically.
pub fn json_helper_matches_an_empty_form_test() {
  let fields = [#("content", json.string("pong"))]
  assert body.encode(body.json(fields), boundary: boundary())
    == body.encode(body.Form(payload: fields, files: []), boundary: boundary())
}

/// An empty file list means no files, not an empty multipart envelope.
pub fn form_without_files_is_json_test() {
  let form = body.Form(payload: [#("content", json.string("pong"))], files: [])
  let #(content_type, wire) = body.encode(form, boundary: boundary())

  assert content_type == Some("application/json")
  assert wire == body.Text("{\"content\":\"pong\"}")
  assert string.contains(text(wire), raw) == False
}

/// The whole wire format, byte for byte.
pub fn multipart_bytes_are_exact_test() {
  let form =
    body.Form(payload: [#("content", json.string("here you go"))], files: [
      png(),
    ])

  let expected =
    "--abc123\r\n"
    <> "Content-Disposition: form-data; name=\"payload_json\"\r\n"
    <> "Content-Type: application/json\r\n"
    <> "\r\n"
    <> "{\"content\":\"here you go\",\"attachments\":[{\"id\":0,\"filename\":\"graph.png\"}]}\r\n"
    <> "--abc123\r\n"
    <> "Content-Disposition: form-data; name=\"files[0]\"; filename=\"graph.png\"\r\n"
    <> "Content-Type: image/png\r\n"
    <> "\r\n"
    <> "PNG BYTES\r\n"
    <> "--abc123--"

  assert body.encode(form, boundary: boundary())
    == #(
      Some("multipart/form-data; boundary=\"abc123\""),
      body.Bytes(bit_array.from_string(expected)),
    )
}

/// A trailing CRLF after the closing delimiter is legal; glyde sends none.
pub fn no_trailing_newline_test() {
  let form = body.Form(payload: [], files: [png()])
  let #(_, wire) = body.encode(form, boundary: boundary())

  assert string.ends_with(text(wire), "\r\n--abc123--")
}

/// The `attachments` array carries the same numbers as the parts.
pub fn files_are_numbered_and_cross_referenced_test() {
  let gif =
    body.File(
      filename: "b.gif",
      content_type: "image/gif",
      data: bit_array.from_string("GIF"),
    )
  let form = body.Form(payload: [], files: [png(), gif])
  let rendered = text(body.encode(form, boundary: boundary()).1)

  assert string.contains(
    rendered,
    "\"attachments\":[{\"id\":0,\"filename\":\"graph.png\"},{\"id\":1,\"filename\":\"b.gif\"}]",
  )
  assert string.contains(rendered, "name=\"files[0]\"; filename=\"graph.png\"")
  assert string.contains(rendered, "name=\"files[1]\"; filename=\"b.gif\"")
}

/// Discord's multipart parser rejects a percent-encoded part name.
pub fn brackets_are_literal_test() {
  let form = body.Form(payload: [], files: [png()])
  let rendered = text(body.encode(form, boundary: boundary()).1)

  assert string.contains(rendered, "name=\"files[0]\"")
  assert string.contains(rendered, "files%5B0%5D") == False
}

/// The attachments array is what ties an upload to the message.
pub fn attachments_are_the_only_payload_test() {
  let form = body.Form(payload: [], files: [png()])
  let rendered = text(body.encode(form, boundary: boundary()).1)

  assert string.contains(
    rendered,
    "\r\n\r\n{\"attachments\":[{\"id\":0,\"filename\":\"graph.png\"}]}\r\n",
  )
}

/// The interaction callback nests its `attachments` under `data`, where the
/// top-level key search cannot see it. A `Finished` payload goes out as given.
pub fn a_finished_payload_gains_no_attachments_test() {
  let nested =
    json.object([
      #("type", json.int(4)),
      #(
        "data",
        json.object([
          #(
            "attachments",
            json.preprocessed_array([
              json.object([
                #("id", json.int(0)),
                #("filename", json.string("graph.png")),
              ]),
            ]),
          ),
        ]),
      ),
    ])

  let expected =
    "--abc123\r\n"
    <> "Content-Disposition: form-data; name=\"payload_json\"\r\n"
    <> "Content-Type: application/json\r\n"
    <> "\r\n"
    <> "{\"type\":4,\"data\":{\"attachments\":[{\"id\":0,\"filename\":\"graph.png\"}]}}\r\n"
    <> "--abc123\r\n"
    <> "Content-Disposition: form-data; name=\"files[0]\"; filename=\"graph.png\"\r\n"
    <> "Content-Type: image/png\r\n"
    <> "\r\n"
    <> "PNG BYTES\r\n"
    <> "--abc123--"

  let #(content_type, wire) =
    body.encode(
      body.Finished(payload: nested, files: [png()]),
      boundary: boundary(),
    )

  let assert Some(kind) = content_type
  assert string.starts_with(kind, "multipart/form-data; boundary=")
  assert text(wire) == expected
}

/// With no files it is the document and nothing else.
pub fn a_finished_payload_without_files_is_json_test() {
  assert body.encode(
      body.Finished(payload: json.object([#("type", json.int(1))]), files: []),
      boundary: boundary(),
    )
    == #(Some("application/json"), body.Text("{\"type\":1}"))
}

/// A caller who supplies `attachments` must not get a second copy of the key:
/// which one Discord reads is undefined.
pub fn caller_attachments_win_test() {
  let mine =
    json.preprocessed_array([json.object([#("id", json.string("998877"))])])
  let form = body.Form(payload: [#("attachments", mine)], files: [png()])

  let expected =
    "--abc123\r\n"
    <> "Content-Disposition: form-data; name=\"payload_json\"\r\n"
    <> "Content-Type: application/json\r\n"
    <> "\r\n"
    <> "{\"attachments\":[{\"id\":\"998877\"}]}\r\n"
    <> "--abc123\r\n"
    <> "Content-Disposition: form-data; name=\"files[0]\"; filename=\"graph.png\"\r\n"
    <> "Content-Type: image/png\r\n"
    <> "\r\n"
    <> "PNG BYTES\r\n"
    <> "--abc123--"

  assert body.encode(form, boundary: boundary()).1
    == body.Bytes(bit_array.from_string(expected))
}

/// Bytes that are not text must come out unchanged.
pub fn binary_data_is_untouched_test() {
  let jpeg =
    body.File(filename: "p.jpg", content_type: "image/jpeg", data: <<
      0xFF,
      0xD8,
      0xFF,
      0x00,
      0x1B,
    >>)
  let form = body.Form(payload: [], files: [jpeg])

  let head =
    "--abc123\r\n"
    <> "Content-Disposition: form-data; name=\"payload_json\"\r\n"
    <> "Content-Type: application/json\r\n"
    <> "\r\n"
    <> "{\"attachments\":[{\"id\":0,\"filename\":\"p.jpg\"}]}\r\n"
    <> "--abc123\r\n"
    <> "Content-Disposition: form-data; name=\"files[0]\"; filename=\"p.jpg\"\r\n"
    <> "Content-Type: image/jpeg\r\n"
    <> "\r\n"

  let expected =
    bit_array.concat([
      bit_array.from_string(head),
      <<0xFF, 0xD8, 0xFF, 0x00, 0x1B>>,
      bit_array.from_string("\r\n--abc123--"),
    ])

  assert body.encode(form, boundary: boundary()).1 == body.Bytes(expected)
}

/// A filename comes from a human and lands in a quoted header parameter.
pub fn filename_cannot_write_headers_test() {
  let awkward =
    body.File(
      filename: "a\"b\r\nContent-Type: text/html\r\n\r\n.png",
      content_type: "image/png",
      data: bit_array.from_string("x"),
    )
  let form = body.Form(payload: [], files: [awkward])
  let rendered = text(body.encode(form, boundary: boundary()).1)

  assert string.contains(
    rendered,
    "filename=\"a\\\"bContent-Type: text/html.png\"\r\nContent-Type: image/png\r\n",
  )
}

pub fn content_type_cannot_write_headers_test() {
  let awkward =
    body.File(
      filename: "a.png",
      content_type: "image/png\r\nX-Evil: 1",
      data: bit_array.from_string("x"),
    )
  let form = body.Form(payload: [], files: [awkward])
  let rendered = text(body.encode(form, boundary: boundary()).1)

  assert string.contains(rendered, "Content-Type: image/pngX-Evil: 1\r\n\r\nx")
}

/// A filename Discord accepts but ASCII does not.
pub fn unicode_filename_test() {
  let file =
    body.File(
      filename: "café 🎉.png",
      content_type: "image/png",
      data: bit_array.from_string("x"),
    )
  let form = body.Form(payload: [], files: [file])
  let rendered = text(body.encode(form, boundary: boundary()).1)

  assert string.contains(rendered, "filename=\"café 🎉.png\"")
  assert string.contains(rendered, "\"filename\":\"café 🎉.png\"")
}

fn collision_table() -> List(#(String, body.Body, Bool)) {
  let file = fn(name, content_type, data) {
    body.Form(payload: [], files: [
      body.File(
        filename: name,
        content_type:,
        data: bit_array.from_string(data),
      ),
    ])
  }

  [
    #("clean", file("a.png", "image/png", "harmless"), False),
    #("inside the file bytes", file("a.png", "image/png", "xx--abc123xx"), True),
    #("the whole file", file("a.png", "image/png", "--abc123"), True),
    #("at the very end", file("a.png", "image/png", "x--abc123"), True),
    #("in the filename", file("--abc123.png", "image/png", "ok"), True),
    #("in the content type", file("a.png", "image/--abc123", "ok"), True),
    #(
      "in the payload",
      body.Form(payload: [#("content", json.string("--abc123"))], files: [
        png(),
      ]),
      True,
    ),
    // A parser looks for the delimiter, which is the boundary behind two
    // hyphens. The boundary on its own ends nothing.
    #(
      "the boundary without the hyphens ends no part",
      file("a.png", "image/png", "xxabc123xx"),
      False,
    ),
    #("no body at all", body.NoBody, False),
    #(
      "a body with no files cannot collide, it has no parts",
      body.json([#("content", json.string("--abc123"))]),
      False,
    ),
    #(
      "nor can a form with no files",
      body.Form(payload: [#("content", json.string("--abc123"))], files: []),
      False,
    ),
  ]
}

pub fn boundary_collision_table_test() {
  list.each(collision_table(), fn(row) {
    let #(name, subject, expected) = row
    assert #(name, body.boundary_collides(subject, boundary()))
      == #(name, expected)
  })
}

/// The delimiter is counted in the bytes that go out, not guessed from the
/// pieces: `quoted` drops the CRLF and leaves a delimiter behind.
pub fn a_filename_that_becomes_the_delimiter_collides_test() {
  let sneaky =
    body.Form(payload: [], files: [
      body.File(
        filename: "--abc\r\n123.png",
        content_type: "image/png",
        data: bit_array.from_string("x"),
      ),
    ])

  assert body.boundary_collides(sneaky, boundary())

  // So the delimiter that goes out is not the one the filename spells.
  let #(content_type, _) = body.encode(sneaky, boundary: boundary())
  assert content_type != Some("multipart/form-data; boundary=\"" <> raw <> "\"")
}

/// The point of all of it: whatever the parts hold, the delimiter that goes
/// out appears exactly where `multipart` wrote it, and the header says so.
pub fn encode_grows_a_boundary_the_parts_contain_test() {
  let hostile =
    body.Form(payload: [], files: [
      body.File(
        filename: "a.png",
        content_type: "image/png",
        data: bit_array.from_string("--abc123 and --abc123z too"),
      ),
    ])

  let #(content_type, wire) = body.encode(hostile, boundary: boundary())
  let written = written_boundary(content_type)

  // One retry. The file has a delimiter behind a space and one behind a "z",
  // and "0" is the lowest run of digits behind none of them.
  assert written == "abc1230"
  assert count(text(wire), "--" <> written) == 3
  assert string.contains(text(wire), "--abc123 and --abc123z too")
}

/// The same growth driven by `payload_json` rather than the file bytes: a
/// message whose text is the delimiter would otherwise end its own part.
pub fn a_payload_that_spells_the_delimiter_grows_the_boundary_test() {
  let hostile =
    body.Form(payload: [#("content", json.string("--" <> raw))], files: [png()])

  let expected =
    "--abc1230\r\n"
    <> "Content-Disposition: form-data; name=\"payload_json\"\r\n"
    <> "Content-Type: application/json\r\n"
    <> "\r\n"
    <> "{\"content\":\"--abc123\",\"attachments\":[{\"id\":0,\"filename\":\"graph.png\"}]}\r\n"
    <> "--abc1230\r\n"
    <> "Content-Disposition: form-data; name=\"files[0]\"; filename=\"graph.png\"\r\n"
    <> "Content-Type: image/png\r\n"
    <> "\r\n"
    <> "PNG BYTES\r\n"
    <> "--abc1230--"

  let #(content_type, wire) = body.encode(hostile, boundary: boundary())

  // One retry: the payload holds the delimiter behind a quote, so "0" is free.
  assert written_boundary(content_type) == "abc1230"
  assert wire == body.Bytes(bit_array.from_string(expected))
  assert count(text(wire), "--abc1230") == 3
}

/// A file that spells the boundary behind every one-digit run only moves the
/// escape to two digits. Growing by a fixed character instead would re-encode
/// and re-scan the whole body once per character the file supplies.
pub fn a_boundary_the_parts_hold_behind_every_digit_test() {
  let ladder =
    ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
    |> list.map(fn(digit) { "--" <> raw <> digit })
    |> string.join(" ")

  let hostile =
    body.Form(payload: [], files: [
      body.File(
        filename: "a.png",
        content_type: "image/png",
        data: bit_array.from_string(ladder),
      ),
    ])

  let #(content_type, wire) = body.encode(hostile, boundary: boundary())
  let written = written_boundary(content_type)

  assert written == "abc12300"
  assert count(text(wire), "--" <> written) == 3
  assert string.contains(text(wire), ladder)
}

/// A part carrying a partial byte knocks the delimiters after it off byte
/// lines, so fewer turn up than were written. A longer boundary cannot put
/// them back, and retrying until it does would never return.
pub fn a_part_with_a_partial_byte_stops_test() {
  let form =
    body.Form(payload: [], files: [
      body.File(filename: "a.png", content_type: "image/png", data: <<
        1:size(3),
      >>),
    ])

  let #(content_type, _) = body.encode(form, boundary: boundary())
  assert content_type == Some("multipart/form-data; boundary=\"abc123\"")
}

/// A `bchar` can be a space or one of HTTP's separators, so an unquoted
/// parameter would end at the first one and the server would find no boundary.
pub fn the_header_quotes_the_boundary_test() {
  let assert Ok(spaced) = body.boundary("a b(),/:=?")
  let form = body.Form(payload: [], files: [png()])
  let #(content_type, _) = body.encode(form, boundary: spaced)

  assert content_type == Some("multipart/form-data; boundary=\"a b(),/:=?\"")
}

fn written_boundary(content_type: Option(String)) -> String {
  let assert Some("multipart/form-data; boundary=\"" <> tail) = content_type
  // A quote is not a `bchar`, so the first one closes the parameter.
  let assert Ok(#(written, "")) = string.split_once(tail, "\"")
  written
}

fn count(haystack: String, needle: String) -> Int {
  list.length(string.split(haystack, needle)) - 1
}

/// RFC 2046 section 5.1.1. `Config.boundary` is one of these, so none of them
/// can reach a `Content-Type` header.
pub fn boundary_rejects_what_no_server_can_parse_test() {
  let assert Error(body.BoundaryEmpty) = body.boundary("")
  let assert Error(body.BoundaryTooLong(71)) =
    body.boundary(string.repeat("a", 71))
  let assert Error(body.BoundaryIllegalCharacter("\r")) = body.boundary("a\rb")
  let assert Error(body.BoundaryIllegalCharacter("é")) = body.boundary("café")
  let assert Error(body.BoundaryTrailingSpace) = body.boundary("a b ")

  let assert Ok(legal) = body.boundary("a b'()+_,-./:=?09Z")
  assert body.boundary_to_string(legal) == "a b'()+_,-./:=?09Z"
  assert body.boundary_to_string(boundary()) == raw
}
