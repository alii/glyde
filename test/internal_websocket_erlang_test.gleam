import gleam/list
import glyde/internal/websocket/erlang
import glyde/websocket/frame
import glyde/websocket/handshake

// A test cannot dial a socket, so only what runs before one is opened is here.
// The rest is pure and lives in `frame`, `handshake` and `stream`.

/// The gateway halts on a 401 and waits on a 429, so a refused upgrade has to
/// hand the number over and not only the words.
pub fn a_refused_upgrade_hands_over_its_status_test() {
  assert erlang.refusal_status(
      erlang.HandshakeRefused(handshake.NotSwitching(401)),
    )
    == Ok(401)
  assert erlang.refusal_status(
      erlang.HandshakeRefused(handshake.NotSwitching(429)),
    )
    == Ok(429)

  // A handshake that answered 101 and then failed a header check has no status
  // worth acting on, and neither has a dial that never got an answer.
  assert erlang.refusal_status(
      erlang.HandshakeRefused(handshake.MissingHeader("upgrade")),
    )
    == Error(Nil)
  assert erlang.refusal_status(erlang.ConnectFailed("econnrefused"))
    == Error(Nil)
}

pub fn error_to_string_names_the_problem_test() {
  assert erlang.error_to_string(erlang.BadUrl("wss:///v=10", erlang.NoHost))
    == "bad url: no host: wss:///v=10"
  assert erlang.error_to_string(erlang.BadUrl("wss://ö.gg/", erlang.NotWss))
    == "bad url: only wss is supported: wss://ö.gg/"
  assert erlang.error_to_string(erlang.BadUrl(
      "wss://ö.gg/",
      erlang.NotParseable,
    ))
    == "bad url: cannot be parsed: wss://ö.gg/"
  assert erlang.error_to_string(erlang.BadUrl(
      "wss://ö.gg/",
      erlang.NonAsciiHost,
    ))
    == "bad url: host is not ascii: wss://ö.gg/"
  assert erlang.error_to_string(erlang.BadNonce(8))
    == "handshake nonce is 8 bytes, not 16"
  assert erlang.error_to_string(erlang.ConnectFailed("econnrefused"))
    == "could not connect: econnrefused"
  assert erlang.error_to_string(
      erlang.HandshakeRefused(handshake.NotSwitching(429)),
    )
    == "handshake failed: upgrade refused with status 429"
  assert erlang.error_to_string(
      erlang.HandshakeRefused(handshake.MissingHeader("upgrade")),
    )
    == "handshake failed: no upgrade header"
  assert erlang.error_to_string(erlang.HandshakeUnreadable(
      handshake.HeadNotText,
    ))
    == "handshake failed: response head is not text"
  assert erlang.error_to_string(erlang.HeadTooLong(8192))
    == "handshake failed: response head never ended in 8192 bytes"
}

pub fn live_error_to_string_names_the_problem_test() {
  assert erlang.live_error_to_string(erlang.SocketFailed(erlang.TimedOut))
    == "socket failed: timed out"
  assert erlang.live_error_to_string(
      erlang.SocketFailed(erlang.Broke("closed")),
    )
    == "socket failed: closed"
  assert erlang.live_error_to_string(
      erlang.SocketFailed(erlang.Crashed("error: badarg at {ssl,send,2,[]}")),
    )
    == "socket failed: ssl raised error: badarg at {ssl,send,2,[]}"
  assert erlang.live_error_to_string(erlang.Closed) == "connection closed"
  assert erlang.live_error_to_string(erlang.ProtocolFailed(
      frame.ReservedBitsSet,
    ))
    == "protocol violated: reserved bits set"
  assert erlang.live_error_to_string(
      erlang.ProtocolFailed(frame.ControlPayloadTooLarge(126)),
    )
    == "protocol violated: control frame payload over 125 bytes, declared 126"
  assert erlang.live_error_to_string(erlang.BufferFull(4096))
    == "buffer full at 4096 bytes with no message in it"
}

/// The nonce the RFC's key is the base64 of.
const rfc_nonce = <<
  0x74, 0x68, 0x65, 0x20, 0x73, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x20, 0x6e, 0x6f,
  0x6e, 0x63, 0x65,
>>

/// SHA-1 of `challenge(key(rfc_nonce))`, which base64s to the accept the RFC
/// prints.
const rfc_digest = <<
  0xb3, 0x7a, 0x4f, 0x2c, 0xc0, 0x62, 0x4f, 0x16, 0x90, 0xf6, 0x46, 0x06, 0xcf,
  0x38, 0x59, 0x45, 0xb2, 0xbe, 0xc4, 0xea,
>>

fn key(nonce: BitArray) -> handshake.Key {
  let assert Ok(key) = handshake.key(nonce)
  key
}

/// RFC 6455 section 1.3's worked example, through the real `crypto:hash`.
pub fn accept_for_matches_the_rfc_example_test() {
  assert erlang.accept_for(key(rfc_nonce)) == handshake.accept(rfc_digest)
}

pub fn accept_for_changes_with_the_key_test() {
  assert erlang.accept_for(key(rfc_nonce))
    != erlang.accept_for(key(<<0:size(128)>>))
}

/// Refused before a socket is opened, so this touches no network.
pub fn connect_refuses_a_url_it_cannot_dial_test() {
  let urls = [
    "wss://", "wss:///path", "ws://gateway.discord.gg/", "https://example.com/",
    "gateway.discord.gg", "",
  ]

  list.each(urls, fn(url) {
    let assert Error(erlang.BadUrl(..)) =
      erlang.connect(
        url:,
        nonce: <<0:size(128)>>,
        headers: [],
        timeout: 1,
        max_bytes: 1024,
      )
  })
}

pub fn connect_says_which_url_it_refused_and_why_test() {
  assert refused("ws://gateway.discord.gg/")
    == erlang.BadUrl("ws://gateway.discord.gg/", erlang.NotWss)

  assert refused("wss:///v=10") == erlang.BadUrl("wss:///v=10", erlang.NoHost)
}

/// `ssl:connect` takes the host as bytes, so a name outside ASCII would go out
/// as its UTF-8 rather than the punycode the server knows itself by. Erlang's
/// URI parser turns this one away first, so the problem named is the parse.
pub fn connect_refuses_a_host_that_is_not_ascii_test() {
  assert refused("wss://gateway.discörd.gg/")
    == erlang.BadUrl("wss://gateway.discörd.gg/", erlang.NotParseable)
}

fn refused(url: String) -> erlang.Error {
  let assert Error(error) =
    erlang.connect(
      url:,
      nonce: <<0:size(128)>>,
      headers: [],
      timeout: 1,
      max_bytes: 1024,
    )
  error
}
