//// Counting a string the way Discord counts it, in UTF-16 code units, which
//// Gleam does not offer. The family emoji "👩‍👩‍👧‍👦" is one grapheme to
//// `string.length`, twenty-five bytes on the wire, and eleven of Discord's
//// characters.
////
//// Only `embed.character_count` reads this. Nothing here enforces a
//// limit: an over-long field is Discord's 50035 to raise, not glyde's.

import gleam/list
import gleam/string

/// UTF-16 code units. Anything past the basic multilingual plane counts twice:
/// most emoji, and every character of a two-letter flag.
pub fn length(text: String) -> Int {
  string.to_utf_codepoints(text)
  |> list.fold(0, fn(total, codepoint) {
    case string.utf_codepoint_to_int(codepoint) >= 0x10000 {
      True -> total + 2
      False -> total + 1
    }
  })
}
