import gleam/json
import gleam/list
import gleam/option.{None, Some}
import glyde/field.{Present}
import glyde/id
import glyde/payload/file
import glyde/rest/body

fn png(name: String) -> file.File {
  file.file(filename: name, content_type: "image/png", data: <<1, 2, 3>>)
}

/// `SetAttachments` always writes the key, so the array is always there.
fn encode(kept: List(file.KeptAttachment), files: List(file.File)) -> String {
  let assert Present(array) =
    file.attachments_field(file.SetAttachments(keep: kept, add: files))
  json.to_string(array)
}

pub fn a_new_file_is_numbered_from_zero_test() {
  assert encode([], [png("chart.png")])
    == "[{\"id\":0,\"filename\":\"chart.png\"}]"
}

pub fn description_rides_along_test() {
  assert encode([], [file.described(png("chart.png"), "a chart")])
    == "[{\"id\":0,\"filename\":\"chart.png\",\"description\":\"a chart\"}]"
}

/// `None` means leave the value alone, not clear it, so only the id goes out.
pub fn a_kept_attachment_is_just_its_id_test() {
  assert encode([file.keep(id.from_string("77"))], []) == "[{\"id\":\"77\"}]"
}

pub fn a_kept_attachment_can_be_relabelled_test() {
  let kept =
    file.KeptAttachment(
      id: id.from_string("77"),
      description: Some("new alt"),
      title: Some("Q3"),
    )

  assert encode([kept], [])
    == "[{\"id\":\"77\",\"description\":\"new alt\",\"title\":\"Q3\"}]"
}

/// `id` indexes the multipart parts, not this array, so files still start at 0.
pub fn kept_attachments_do_not_shift_the_file_numbering_test() {
  assert encode([file.keep(id.from_string("77"))], [png("a.png"), png("b.png")])
    == "[{\"id\":\"77\"},{\"id\":0,\"filename\":\"a.png\"},{\"id\":1,\"filename\":\"b.png\"}]"
}

pub fn an_empty_edit_removes_everything_test() {
  assert encode([], []) == "[]"
}

/// Discord has no spoiler flag: the filename prefix is the whole mechanism,
/// so both sides have to carry it.
pub fn a_spoiler_is_a_filename_prefix_on_both_sides_test() {
  let hidden = file.spoilered(png("plot.png"))

  assert encode([], [hidden])
    == "[{\"id\":0,\"filename\":\"SPOILER_plot.png\"}]"

  let assert [part] = file.parts([hidden])
  assert part.filename == "SPOILER_plot.png"
}

pub fn spoilering_twice_does_not_prefix_twice_test() {
  let hidden = file.spoilered(file.spoilered(png("plot.png")))
  assert file.wire_filename(hidden) == "SPOILER_plot.png"
}

/// A prefixed name is asking for a spoiler, so it moves onto the boolean and
/// `filename` holds the bare name. Otherwise the record reads as unspoilered
/// and goes out blurred anyway.
pub fn a_prefixed_name_sets_the_boolean_test() {
  let hidden = png("SPOILER_plot.png")

  assert hidden.filename == "plot.png"
  assert hidden.spoiler == True
  assert file.wire_filename(hidden) == "SPOILER_plot.png"
  assert file.wire_filename(file.spoilered(hidden)) == "SPOILER_plot.png"
}

/// `spoiler` is the switch. A record built by hand with a prefixed name and
/// the boolean off says "no spoiler", so no spoiler is what goes out.
pub fn the_boolean_wins_over_the_name_test() {
  let shown = file.File(..png("plot.png"), filename: "SPOILER_plot.png")

  assert file.wire_filename(shown) == "plot.png"
}

pub fn parts_keep_the_order_the_ids_were_written_in_test() {
  let files = [png("a.png"), png("b.png"), png("c.png")]
  let names = list.map(file.parts(files), fn(part) { part.filename })

  assert names == ["a.png", "b.png", "c.png"]
  assert file.parts(files)
    == [
      body.File(filename: "a.png", content_type: "image/png", data: <<1, 2, 3>>),
      body.File(filename: "b.png", content_type: "image/png", data: <<1, 2, 3>>),
      body.File(filename: "c.png", content_type: "image/png", data: <<1, 2, 3>>),
    ]
}

pub fn a_fresh_file_sets_nothing_else_test() {
  let plain = png("a.png")

  assert plain.description == None
  assert plain.title == None
  assert plain.spoiler == False
  assert plain.voice == None
}

fn voice(secs: Float) -> file.File {
  file.voice_message(
    file.file(filename: "voice-message.ogg", content_type: "audio/ogg", data: <<
      0,
    >>),
    duration_secs: secs,
    waveform: "AAAA",
  )
}

/// Discord takes `duration_secs` and `waveform` together or not at all, so
/// they are one field and half a voice message does not typecheck.
pub fn a_voice_message_carries_both_halves_test() {
  assert voice(3.0).voice
    == Some(file.Voice(duration_secs: 3.0, waveform: "AAAA"))
}

pub fn a_whole_duration_is_written_as_an_integer_test() {
  assert encode([], [voice(3.0)])
    == "[{\"id\":0,\"filename\":\"voice-message.ogg\",\"duration_secs\":3,\"waveform\":\"AAAA\"}]"
}

pub fn a_fractional_duration_keeps_its_decimal_test() {
  assert encode([], [voice(3.5)])
    == "[{\"id\":0,\"filename\":\"voice-message.ogg\",\"duration_secs\":3.5,\"waveform\":\"AAAA\"}]"
}

pub fn a_zero_duration_is_written_as_zero_test() {
  assert encode([], [voice(0.0)])
    == "[{\"id\":0,\"filename\":\"voice-message.ogg\",\"duration_secs\":0,\"waveform\":\"AAAA\"}]"
}

pub fn every_optional_key_is_omitted_when_unset_test() {
  assert encode([], [png("a.png")]) == "[{\"id\":0,\"filename\":\"a.png\"}]"
}
