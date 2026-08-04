import gleam/list
import gleam/result
import gleam/string
import glyde/internal/host

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
    assert result.map(host.host_of(input), host.to_string) == expected
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
    let assert Ok(parsed) = host.host_of(input)
    let built = "wss://" <> host.to_string(parsed) <> query
    assert built == expected
    assert occurrences(in: built, of: "?") == 1
    assert occurrences(in: built, of: "//") == 1
  })
}
