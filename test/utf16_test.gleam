import gleam/bit_array
import gleam/list
import gleam/string
import glyde/internal/utf16

// Written as escapes so the code points are countable in the source.
const combining_accent = "e\u{0301}"

const precomposed_accent = "\u{00E9}"

const treble_clef = "\u{1D11E}"

const family = "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"

const flag_gb = "\u{1F1EC}\u{1F1E7}"

pub fn empty_is_zero_test() {
  assert utf16.length("") == 0
}

pub fn ascii_counts_one_each_test() {
  assert utf16.length("hello") == 5
}

/// Discord counts UTF-16 code units. The three counts agree only on ASCII.
pub fn the_three_lengths_test() {
  let rows = [
    #("hello", 5, 5, 5),
    #(precomposed_accent, 1, 1, 2),
    #(combining_accent, 2, 1, 3),
    #(treble_clef, 2, 1, 4),
    #(flag_gb, 4, 1, 8),
    #(family, 11, 1, 25),
  ]

  list.each(rows, fn(row) {
    let #(sample, units, graphemes, bytes) = row
    assert utf16.length(sample) == units
    assert string.length(sample) == graphemes
    assert bit_array.byte_size(bit_array.from_string(sample)) == bytes
  })
}

/// The two accents look identical and are different lengths to Discord, so
/// glyde reports what will be sent rather than normalising.
pub fn composed_and_decomposed_differ_test() {
  assert utf16.length(precomposed_accent) == 1
  assert utf16.length(combining_accent) == 2
}

/// `string.replace` matches grapheme clusters and CRLF is one, so stripping
/// "\r" from a CRLF pair leaves a header injection wide open.
pub fn string_replace_is_grapheme_aware_test() {
  let evil = "file\r\nX-Injected: yes.png"
  assert string.replace(evil, "\r", "") == evil

  // "\n" alone still matches the tail of the cluster.
  assert string.replace(evil, "\n", "") == "file\rX-Injected: yes.png"

  // The trap is in `replace`, not in the segmentation.
  assert string.to_graphemes("a\r\nb") == ["a", "\r\n", "b"]
  assert string.length("a\r\nb") == 3
}

pub fn filtering_codepoints_removes_the_control_characters_test() {
  let cleaned =
    "file\r\nX-Injected: yes.png"
    |> string.to_utf_codepoints
    |> list.filter(fn(c) { string.utf_codepoint_to_int(c) >= 0x20 })
    |> string.from_utf_codepoints

  assert cleaned == "fileX-Injected: yes.png"
}
