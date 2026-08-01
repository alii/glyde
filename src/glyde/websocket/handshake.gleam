//// The RFC 6455 opening handshake, as pure Gleam over `BitArray`. Client side
//// only, and it hashes nothing: SHA-1 of the key arrives as a digest.
////
//// `Sec-WebSocket-Accept` is the only evidence the peer understood a WebSocket
//// request rather than replaying a cached 101, so `check` verifies it exactly
//// and refuses anything the server offers that we did not ask for.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// RFC 6455 section 1.3. Fixed for every connection, and not a secret.
const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

/// The `Sec-WebSocket-Key` we sent. Only `key` builds one, so the nonce rule is
/// checked in one place and nothing else can go out as a key.
pub opaque type Key {
  Key(encoded: String)
}

/// The `Sec-WebSocket-Accept` we expect back. Kept apart from `Key` so that
/// passing one where the other goes does not compile: both are short base64,
/// and swapped they would fail every handshake with nothing to point at.
pub opaque type Accept {
  Accept(encoded: String)
}

/// The `Sec-WebSocket-Key` for a nonce. RFC 6455 wants 16 random bytes, and
/// the caller draws them: this module has no random source. The `Error` hands
/// back the byte count it was given.
pub fn key(nonce: BitArray) -> Result(Key, Int) {
  case bit_array.byte_size(nonce) {
    16 -> Ok(Key(bit_array.base64_encode(nonce, True)))
    size -> Error(size)
  }
}

/// The bytes whose SHA-1 the server is expected to have taken.
pub fn challenge(key: Key) -> BitArray {
  bit_array.from_string(key.encoded <> guid)
}

/// The `Sec-WebSocket-Accept` the server must send back, given the SHA-1 of
/// `challenge(key)`.
pub fn accept(digest: BitArray) -> Accept {
  Accept(bit_array.base64_encode(digest, True))
}

/// One header the caller adds to the opening GET. Only `header` builds one, so
/// a name that would forge a second header cannot reach this list.
pub opaque type Header {
  Header(name: String, value: String)
}

/// Why a header was refused.
pub type HeaderProblem {
  /// One of the seven the handshake speaks for itself: the five it writes,
  /// and the two only a server is allowed to answer with.
  Owned(name: String)

  /// Not an RFC 7230 token. A name with a colon in it is the one that matters:
  /// the server splits a line on its first colon, so `host: x` as a name would
  /// arrive as a `host` header however the value is written.
  NotAToken(name: String)

  /// A carriage return or a newline in the value, which would end the header
  /// and start one the caller did not write.
  Splittable
}

/// RFC 7230's `tchar`, lowercased: a name is trimmed and lowercased before it
/// is checked, so the uppercase half would never match.
const tchars = "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyz"

/// Build a header for `request`. The name is trimmed and lowercased first.
pub fn header(name: String, value: String) -> Result(Header, HeaderProblem) {
  let name = string.lowercase(string.trim(name))
  use <- bool.guard(ours(name), Error(Owned(name)))
  use <- bool.guard(!is_token(name), Error(NotAToken(name)))
  use <- bool.guard(splittable(value), Error(Splittable))
  Ok(Header(name:, value:))
}

fn is_token(name: String) -> Bool {
  name != "" && list.all(string.to_graphemes(name), string.contains(tchars, _))
}

/// The bytes of the opening GET. `path` is sent as given, query string and all.
pub fn request(
  host host: String,
  port port: Int,
  path path: String,
  key key: Key,
  headers headers: List(Header),
) -> BitArray {
  // RFC 9110 says to leave the default port off the authority, and 443 is the
  // only default a `wss` client has.
  let authority = case port {
    443 -> host
    port -> host <> ":" <> int.to_string(port)
  }

  let lines = [
    "GET " <> path <> " HTTP/1.1",
    "host: " <> authority,
    "upgrade: websocket",
    "connection: Upgrade",
    "sec-websocket-key: " <> key.encoded,
    "sec-websocket-version: 13",
    ..list.map(headers, written)
  ]

  bit_array.from_string(string.join(lines, "\r\n") <> "\r\n\r\n")
}

fn written(header: Header) -> String {
  header.name <> ": " <> header.value
}

fn ours(name: String) -> Bool {
  case name {
    "host"
    | "upgrade"
    | "connection"
    | "sec-websocket-key"
    | "sec-websocket-version"
    | "sec-websocket-extensions"
    | "sec-websocket-protocol" -> True
    _ -> False
  }
}

fn splittable(text: String) -> Bool {
  string.contains(text, "\r") || string.contains(text, "\n")
}

/// The head only. A 101 has no body.
pub type Response {
  Response(status: Int, headers: List(#(String, String)))
}

/// The bytes of a head as they arrive, and the cap on them. `max_bytes` lives
/// in here so it cannot drift between calls, and so that a server which never
/// sends the blank line is this module's problem rather than every caller's.
pub type Reader {
  Reader(buffer: BitArray, max_bytes: Int)
}

/// `max_bytes` bounds the head. It also bounds the rescan `next` does, which
/// costs work in the square of this number.
pub fn new(max_bytes: Int) -> Reader {
  Reader(buffer: <<>>, max_bytes:)
}

pub fn feed(reader: Reader, bytes: BitArray) -> Reader {
  Reader(..reader, buffer: bit_array.append(reader.buffer, bytes))
}

pub type Next {
  /// `rest` is already frames: a server may send its first in the same packet
  /// as the 101.
  Head(response: Response, rest: BitArray)

  /// The head is not finished. Read more bytes and `feed` them.
  Partial

  Malformed(reason: Bad)

  /// `max_bytes` went by with no blank line ending the head. Our bound, not
  /// the RFC's.
  TooLong(bytes: Int)
}

/// Why the bytes are not a response head. Not a `Failure`: that one is a head
/// that read fine and does not complete the handshake.
pub type Bad {
  HeadNotText
  StatusNotHttp(line: String)
  HeaderWithoutColon(line: String)
}

pub fn malformed_to_string(bad: Bad) -> String {
  case bad {
    HeadNotText -> "response head is not text"
    StatusNotHttp(line) -> "status line is not HTTP: " <> line
    HeaderWithoutColon(line) -> "header line has no colon: " <> line
  }
}

/// Read the response head, if all of it has arrived. Header names come back
/// lowercased and trimmed; values keep their case, since accept is base64.
pub fn next(reader: Reader) -> Next {
  case scan(reader.buffer, 0) {
    Error(Nil) -> {
      let held = bit_array.byte_size(reader.buffer)
      use <- bool.guard(held > reader.max_bytes, TooLong(held))
      Partial
    }
    Ok(#(length, rest)) ->
      case
        bit_array.slice(reader.buffer, 0, length)
        |> result.try(bit_array.to_string)
      {
        Error(Nil) -> Malformed(HeadNotText)
        Ok(head) -> lines_of(head, rest)
      }
  }
}

/// Walk to the blank line that ends the head, counting the bytes before it.
fn scan(bytes: BitArray, seen: Int) -> Result(#(Int, BitArray), Nil) {
  case bytes {
    <<13, 10, 13, 10, rest:bytes>> -> Ok(#(seen, rest))
    <<_, more:bytes>> -> scan(more, seen + 1)
    _ -> Error(Nil)
  }
}

fn lines_of(head: String, rest: BitArray) -> Next {
  // Split once rather than on every CRLF: the status line is everything up to
  // the first one, and a head with none at all is a status line on its own.
  let #(status, lines) = case string.split_once(head, "\r\n") {
    Ok(#(status, headers)) -> #(status, string.split(headers, "\r\n"))
    Error(Nil) -> #(head, [])
  }

  case status_of(status), headers_of(lines, []) {
    Ok(status), Ok(headers) -> Head(Response(status:, headers:), rest)
    Error(reason), _ | _, Error(reason) -> Malformed(reason)
  }
}

fn status_of(line: String) -> Result(Int, Bad) {
  case string.split(line, " ") {
    [version, code, ..] ->
      case string.starts_with(version, "HTTP/"), int.parse(code) {
        True, Ok(code) -> Ok(code)
        _, _ -> Error(StatusNotHttp(line))
      }
    _ -> Error(StatusNotHttp(line))
  }
}

fn headers_of(
  lines: List(String),
  acc: List(#(String, String)),
) -> Result(List(#(String, String)), Bad) {
  case lines {
    [] -> Ok(list.reverse(acc))
    [line, ..rest] ->
      case string.split_once(line, ":") {
        // A folded continuation line lands here. RFC 9110 deprecated folding,
        // so this fails rather than stitch it back together on a guess.
        Error(Nil) -> Error(HeaderWithoutColon(line))
        Ok(#(name, value)) -> {
          let name = string.lowercase(string.trim(name))
          headers_of(rest, [#(name, string.trim(value)), ..acc])
        }
      }
  }
}

/// Why a response is not the upgrade we asked for.
pub type Failure {
  /// Anything other than 101. Discord answers a rate limited upgrade with 429.
  NotSwitching(status: Int)
  MissingHeader(name: String)
  WrongHeader(name: String, value: String)
  /// The same header twice. A response that answers one of these questions two
  /// ways is refused rather than read as whichever copy came first.
  RepeatedHeader(name: String)
  /// The server agreed to something we never offered. RFC 6455 says to fail.
  UnwantedHeader(name: String, value: String)
}

/// Decide whether a response completes the handshake. `accept` is what
/// `accept/1` produced for the key we sent.
pub fn check(
  response: Response,
  accept accept: Accept,
) -> Result(Nil, Failure) {
  use <- bool.guard(
    response.status != 101,
    Error(NotSwitching(response.status)),
  )
  use <- require(response, "upgrade", is_websocket)
  use <- require(response, "connection", has_upgrade)
  use <- require(response, "sec-websocket-accept", fn(value) {
    value == accept.encoded
  })
  use <- refuse(response, "sec-websocket-extensions")
  use <- refuse(response, "sec-websocket-protocol")
  Ok(Nil)
}

fn is_websocket(value: String) -> Bool {
  string.lowercase(value) == "websocket"
}

/// `Connection` is a comma separated list, and a proxy may add tokens to it.
fn has_upgrade(value: String) -> Bool {
  string.split(value, ",")
  |> list.any(fn(token) { string.lowercase(string.trim(token)) == "upgrade" })
}

/// Every copy of the header, never the first: a server that repeats one is
/// telling us two things, and picking one of them is guessing.
fn require(
  response: Response,
  name: String,
  good: fn(String) -> Bool,
  then: fn() -> Result(Nil, Failure),
) -> Result(Nil, Failure) {
  case list.key_filter(response.headers, name) {
    [] -> Error(MissingHeader(name))
    [value] ->
      case good(value) {
        True -> then()
        False -> Error(WrongHeader(name, value))
      }
    [_, _, ..] -> Error(RepeatedHeader(name))
  }
}

fn refuse(
  response: Response,
  name: String,
  then: fn() -> Result(Nil, Failure),
) -> Result(Nil, Failure) {
  // Every copy has to be empty. Stopping at the first would walk past a server
  // that sends the header twice, agreeing to nothing and then to an extension,
  // and glyde would go on to read frames it cannot decode.
  case list.filter(list.key_filter(response.headers, name), fn(v) { v != "" }) {
    // An empty value is a server saying it agreed to nothing.
    [] -> then()
    [value, ..] -> Error(UnwantedHeader(name, value))
  }
}

pub fn failure_to_string(failure: Failure) -> String {
  case failure {
    // Discord answers a rate limited upgrade with 429, so the status is the
    // whole message for the reader who has to act on it.
    NotSwitching(status) ->
      "upgrade refused with status " <> int.to_string(status)
    MissingHeader(name) -> "no " <> name <> " header"
    WrongHeader(name, value) -> name <> " header says " <> value
    RepeatedHeader(name) -> "more than one " <> name <> " header"
    UnwantedHeader(name, value) ->
      name <> " header offers " <> value <> ", which we did not ask for"
  }
}
