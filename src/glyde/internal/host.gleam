//// Gateway host parsing and defaults. Discord hands out one shape of gateway
//// URL and a shard needs the host to dial, nothing else.

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

/// Discord's front door. The one gateway host the library knows without being
/// told, so the string lives here and nowhere else.
pub const discord_gateway: Host = Host("gateway.discord.gg")

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
