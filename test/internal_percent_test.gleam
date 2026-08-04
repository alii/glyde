import gleam/list
import glyde/internal/percent

const snowflake: String = "308994132968210433"

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
    assert #(text, percent.encode(text)) == #(text, encoded)
  })
}
