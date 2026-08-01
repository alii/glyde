import gleam/list
import gleam/result
import gleam/string
import glyde/internal/url

const snowflake: String = "308994132968210433"

pub fn host_of_table_test() {
  let table = [
    #(
      "wss://gateway-us-east1-b.discord.gg",
      Ok("gateway-us-east1-b.discord.gg"),
    ),
    #("wss://gateway.discord.gg/", Ok("gateway.discord.gg")),
    #("wss://gateway.discord.gg/?v=6&encoding=etf", Ok("gateway.discord.gg")),
    // A URL with a query and no path puts the `?` straight after the host.
    #("wss://gateway.discord.gg?v=6", Ok("gateway.discord.gg")),
    #("wss://h.discord.gg/some/path", Ok("h.discord.gg")),
    #("wss://h.discord.gg#fragment", Ok("h.discord.gg")),
    #("wss://h.discord.gg:443", Ok("h.discord.gg:443")),
    #("https://h.discord.gg/", Ok("h.discord.gg")),
    #("gateway.discord.gg", Ok("gateway.discord.gg")),
    // Nothing to dial. An empty host would be dialled as `wss:///?v=10`.
    #("wss://", Error(Nil)),
    #("", Error(Nil)),
    #("/nonsense", Error(Nil)),
    // A URL that already had a scheme on it when the scheme went on again.
    #("wss://wss://gateway.discord.gg", Error(Nil)),
    #("wss://:443", Error(Nil)),
    #("wss://not a host/", Error(Nil)),
  ]
  list.each(table, fn(row) {
    let #(input, expected) = row
    assert result.map(url.host_of(input), url.to_string) == expected
  })
}

/// RFC 3986 unreserved is letters, digits and `-._~`. Everything else Discord
/// sees in a path segment, a query half or a header value is encoded.
fn encoding_table() -> List(#(String, String)) {
  [
    #("", ""),
    #("abcXYZ019", "abcXYZ019"),
    #("~-._", "~-._"),
    #(snowflake, snowflake),
    // A sub-delim, which a lenient encoder leaves alone.
    #("$", "%24"),
    #(":", "%3A"),
    #("/", "%2F"),
    #("@", "%40"),
    #("%", "%25"),
    #("+", "%2B"),
    #(" ", "%20"),
    #("?", "%3F"),
    #("#", "%23"),
    #("&", "%26"),
    #("=", "%3D"),
    #("!", "%21"),
    #("*", "%2A"),
    #("(", "%28"),
    #(")", "%29"),
    #(",", "%2C"),
    #(";", "%3B"),
    #("'", "%27"),
    // A raw CR or LF in a header value splits the request in two.
    #("\r\n", "%0D%0A"),
    // A custom emoji reaction is `name:id`, and the colon has to go.
    #("mymoji:" <> snowflake, "mymoji%3A" <> snowflake),
    // Two bytes.
    #("é", "%C3%A9"),
    // Three bytes.
    #("✅", "%E2%9C%85"),
    // Four bytes, the common case for a reaction.
    #("👍", "%F0%9F%91%8D"),
    // Four codepoints in one grapheme.
    #("🏳️‍🌈", "%F0%9F%8F%B3%EF%B8%8F%E2%80%8D%F0%9F%8C%88"),
    #("a👍b", "a%F0%9F%91%8Db"),
  ]
}

pub fn percent_encode_table_test() {
  list.each(encoding_table(), fn(row) {
    let #(text, encoded) = row
    assert #(text, url.percent_encode(text)) == #(text, encoded)
  })
}

fn occurrences(in text: String, of piece: String) -> Int {
  list.length(string.split(text, piece)) - 1
}

/// `resume_gateway_url` is a bare host with no path, so the shard supplies
/// both the `/` and the query. Wrong gives a double slash or two `?`.
pub fn a_host_takes_a_query_string_cleanly_test() {
  let query = "/?v=10&encoding=json"
  let table = [
    #(
      "wss://gateway-us-east1-b.discord.gg",
      "wss://gateway-us-east1-b.discord.gg/?v=10&encoding=json",
    ),
    #(
      "wss://gateway.discord.gg/",
      "wss://gateway.discord.gg/?v=10&encoding=json",
    ),
    #(
      "wss://gateway.discord.gg/?v=6&encoding=etf",
      "wss://gateway.discord.gg/?v=10&encoding=json",
    ),
    #(
      "wss://gateway.discord.gg?v=6",
      "wss://gateway.discord.gg/?v=10&encoding=json",
    ),
  ]
  list.each(table, fn(row) {
    let #(input, expected) = row
    let assert Ok(host) = url.host_of(input)
    let built = "wss://" <> url.to_string(host) <> query
    assert built == expected
    assert occurrences(in: built, of: "?") == 1
    assert occurrences(in: built, of: "//") == 1
  })
}
