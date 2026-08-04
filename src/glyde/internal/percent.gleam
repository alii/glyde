//// RFC 3986 percent-encoding for path segments, query halves and header
//// values. Not a URL library: one job, one function.

import gleam/bit_array
import gleam/int
import gleam/string

/// Percent-encoding over the UTF-8 bytes of `text`, keeping RFC 3986's
/// unreserved set and spelling everything else `%XX`. Good for a path segment,
/// a query key or value, and a header value.
///
/// Bytes and not graphemes, because one cluster can hold several bytes that
/// each need encoding, CRLF among them.
pub fn encode(text: String) -> String {
  encode_bytes(<<text:utf8>>, "")
}

fn encode_bytes(bytes: BitArray, acc: String) -> String {
  case bytes {
    <<byte, rest:bits>> -> {
      let encoded = case is_unreserved(byte) {
        True -> keep(byte)
        False -> percent(byte)
      }
      encode_bytes(rest, acc <> encoded)
    }
    _ -> acc
  }
}

/// RFC 3986's unreserved set, taken whole: `$` and `!` would survive a path
/// unencoded and are encoded anyway.
fn is_unreserved(byte: Int) -> Bool {
  { byte >= 0x61 && byte <= 0x7A }
  || { byte >= 0x41 && byte <= 0x5A }
  || { byte >= 0x30 && byte <= 0x39 }
  || byte == 0x2D
  || byte == 0x2E
  || byte == 0x5F
  || byte == 0x7E
}

fn keep(byte: Int) -> String {
  case bit_array.to_string(<<byte>>) {
    Ok(character) -> character
    // Unreachable, and percent-encoding spells the same character anyway.
    Error(_) -> percent(byte)
  }
}

fn percent(byte: Int) -> String {
  "%" <> string.pad_start(int.to_base16(byte), to: 2, with: "0")
}
