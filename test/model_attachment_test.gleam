import gleam/json
import gleam/list
import gleam/option.{None, Some}
import glyde/flags
import glyde/id
import glyde/model/attachment

fn parse(text: String) -> Result(attachment.Attachment, json.DecodeError) {
  json.parse(text, attachment.decoder())
}

pub fn decodes_an_image_test() {
  let assert Ok(file) =
    parse(
      "{\"id\":\"690922406474612846\",\"filename\":\"cat.png\",\"title\":\"A cat\",\"description\":\"A ginger cat asleep\",\"content_type\":\"image/png\",\"size\":34567,\"url\":\"https://cdn.discordapp.com/attachments/1/2/cat.png?ex=1\",\"proxy_url\":\"https://media.discordapp.net/attachments/1/2/cat.png\",\"height\":1080,\"width\":1920,\"placeholder\":\"1RcJHYQIiId8eIl8AaBGGJKHOA\",\"placeholder_version\":1,\"flags\":0}",
    )
  assert id.to_string(file.id) == "690922406474612846"
  assert file.filename == "cat.png"
  assert file.title == Some("A cat")
  assert file.description == Some("A ginger cat asleep")
  assert file.content_type == Some("image/png")
  assert file.size == 34_567
  assert file.dimensions
    == Some(attachment.Dimensions(width: 1920, height: 1080))
  assert file.placeholder
    == Some(attachment.Placeholder(
      hash: "1RcJHYQIiId8eIl8AaBGGJKHOA",
      version: 1,
    ))
  assert file.ephemeral == False
  assert file.duration_secs == None
  assert flags.to_int(file.flags) == 0
}

/// Discord documents `duration_secs` as a float and then writes `6`, not `6.0`.
pub fn duration_accepts_an_integer_and_a_float_test() {
  let cases = [
    #("{\"id\":\"1\",\"duration_secs\":3}", 3.0),
    #("{\"id\":\"1\",\"duration_secs\":3.0}", 3.0),
    #("{\"id\":\"1\",\"duration_secs\":3.5}", 3.5),
    #("{\"id\":\"1\",\"duration_secs\":0}", 0.0),
  ]
  list.each(cases, fn(row) {
    let #(text, expected) = row
    let assert Ok(file) = parse(text)
    assert file.duration_secs == Some(expected)
  })
}

pub fn decodes_a_voice_message_test() {
  let assert Ok(file) =
    parse(
      "{\"id\":\"1\",\"filename\":\"voice-message.ogg\",\"content_type\":\"audio/ogg\",\"size\":9000,\"url\":\"https://cdn.discordapp.com/x.ogg\",\"proxy_url\":\"https://media.discordapp.net/x.ogg\",\"duration_secs\":6,\"waveform\":\"FzYACgAAAAAAACQAAAAAAAA=\",\"flags\":8192}",
    )
  assert file.duration_secs == Some(6.0)
  assert file.waveform == Some("FzYACgAAAAAAACQAAAAAAAA=")
}

/// The docs write `height?` and `?integer`, so absent and null both turn up.
/// One side alone is a shape Discord never sends, and it is no dimensions.
pub fn height_and_width_tolerate_absent_and_null_test() {
  let cases = [
    "{\"id\":\"1\"}",
    "{\"id\":\"1\",\"height\":null,\"width\":null}",
    "{\"id\":\"1\",\"height\":1080}",
    "{\"id\":\"1\",\"width\":1920}",
  ]
  list.each(cases, fn(text) {
    let assert Ok(file) = parse(text)
    assert file.dimensions == None
  })
}

/// The version says how the hash is encoded, so it is nothing on its own, and
/// a hash without one is the version Discord documents.
pub fn a_placeholder_needs_its_hash_test() {
  let assert Ok(neither) = parse("{\"id\":\"1\"}")
  assert neither.placeholder == None

  let assert Ok(version_only) =
    parse("{\"id\":\"1\",\"placeholder_version\":1}")
  assert version_only.placeholder == None

  let assert Ok(hash_only) = parse("{\"id\":\"1\",\"placeholder\":\"abc\"}")
  assert hash_only.placeholder
    == Some(attachment.Placeholder(hash: "abc", version: 1))
}

pub fn a_whole_dimension_written_as_a_float_decodes_test() {
  let assert Ok(file) =
    parse("{\"id\":\"1\",\"height\":1080.0,\"width\":1920.0}")
  assert file.dimensions
    == Some(attachment.Dimensions(width: 1920, height: 1080))
}

pub fn a_fractional_dimension_is_rejected_test() {
  let assert Error(_) = parse("{\"id\":\"1\",\"height\":10.5}")
}

pub fn requires_an_id_test() {
  let assert Error(_) = parse("{\"filename\":\"cat.png\"}")
}

/// A partial attachment on an edited message carries only the id.
pub fn decodes_an_id_and_nothing_else_test() {
  let assert Ok(file) = parse("{\"id\":\"1\"}")
  assert file.filename == ""
  assert file.url == ""
  assert file.proxy_url == ""
  assert file.size == 0
  assert file.ephemeral == False
  assert file.waveform == None
  assert flags.to_int(file.flags) == 0
}

pub fn ephemeral_defaults_to_false_test() {
  let assert Ok(kept) = parse("{\"id\":\"1\"}")
  assert kept.ephemeral == False

  let assert Ok(temporary) = parse("{\"id\":\"1\",\"ephemeral\":true}")
  assert temporary.ephemeral == True
}

pub fn attachment_flag_bits_test() {
  let table = [
    #(attachment.IsClip, 1),
    #(attachment.IsThumbnail, 2),
    #(attachment.IsRemix, 4),
    #(attachment.IsSpoiler, 8),
    #(attachment.IsAnimated, 32),
  ]
  list.each(table, fn(row) {
    let #(flag, bit) = row
    assert attachment.has_flag(flags.from_int(bit), flag) == True
    assert attachment.has_flag(flags.from_int(0), flag) == False
    list.each(table, fn(other) {
      case other.1 == bit {
        True -> Nil
        False -> {
          assert attachment.has_flag(flags.from_int(bit), other.0) == False
          Nil
        }
      }
    })
  })
}

/// Bit 4 is a hole in Discord's table, so 16 names nothing.
pub fn bit_16_belongs_to_no_named_flag_test() {
  let assert Ok(file) = parse("{\"id\":\"1\",\"flags\":16}")
  let named = [
    attachment.IsClip,
    attachment.IsThumbnail,
    attachment.IsRemix,
    attachment.IsSpoiler,
    attachment.IsAnimated,
  ]
  list.each(named, fn(flag) {
    assert attachment.has_flag(file.flags, flag) == False
  })
  assert flags.to_int(file.flags) == 16
}

pub fn decodes_the_spoiler_flag_test() {
  let assert Ok(file) = parse("{\"id\":\"1\",\"flags\":8}")
  assert attachment.has_flag(file.flags, attachment.IsSpoiler) == True
  assert attachment.has_flag(file.flags, attachment.IsClip) == False
}

/// A flag Discord adds later has to survive a decode and re-encode.
pub fn unknown_flag_bits_survive_test() {
  let assert Ok(file) = parse("{\"id\":\"1\",\"flags\":1048584}")
  assert flags.to_int(file.flags) == 1_048_584
  assert attachment.has_flag(file.flags, attachment.IsSpoiler) == True
}

/// Discord sends a null size on some partial attachments.
pub fn a_null_number_falls_back_to_the_default_test() {
  let assert Ok(file) = parse("{\"id\":\"1\",\"size\":null,\"flags\":null}")
  assert file.size == 0
  assert flags.to_int(file.flags) == 0
}
