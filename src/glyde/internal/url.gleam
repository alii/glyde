//// The two URL jobs the library has: reading a host back out of a gateway
//// URL, and percent-encoding text on its way into one. Not a URL library:
//// Discord hands out one shape of gateway URL and a shard needs the host to
//// dial, nothing else.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/string

/// Somewhere to dial: a bare host with an optional port, no scheme and no
/// path. `host_of` is the only way to build one, so a slot that holds one of
/// these cannot be handed a whole URL by mistake.
pub opaque type Host {
  Host(text: String)
}

/// The bare host of a gateway URL: after the scheme, up to the first `/`, `?`
/// or `#`. A shard builds its own query string, so the host comes back with
/// neither. `Error(Nil)` when what is left is not something to dial.
pub fn host_of(url: String) -> Result(Host, Nil) {
  let after_scheme = case string.split_once(url, "://") {
    Ok(#(_, rest)) -> rest
    Error(_) -> url
  }
  let host =
    after_scheme
    |> string.to_graphemes
    |> list.take_while(fn(char) { char != "/" && char != "?" && char != "#" })
    |> string.concat

  case dialable(host) {
    True -> Ok(Host(host))
    False -> Error(Nil)
  }
}

/// For the one place that puts a scheme back on: whoever builds the URL.
pub fn to_string(host: Host) -> String {
  host.text
}

/// A colon separates a port, so `h.discord.gg:443` is a host. Nothing on one
/// side of that colon means the slice is a scheme a doubled `wss://` left
/// behind, or a port with no host in front of it. A space rules out the rest
/// of the strings that were never a URL.
fn dialable(host: String) -> Bool {
  host != ""
  && !string.contains(host, " ")
  && !string.starts_with(host, ":")
  && !string.ends_with(host, ":")
}

/// Percent-encoding over the UTF-8 bytes of `text`, keeping RFC 3986's
/// unreserved set and spelling everything else `%XX`. Good for a path segment,
/// a query key or value, and a header value.
///
/// Bytes and not graphemes, because one cluster can hold several bytes that
/// each need encoding, CRLF among them.
pub fn percent_encode(text: String) -> String {
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
