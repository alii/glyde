import gleam/bit_array
import gleam/list
import gleam/string
import glyde/websocket/handshake

// The worked example in RFC 6455 section 1.3.

const rfc_key = "dGhlIHNhbXBsZSBub25jZQ=="

const rfc_accept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

/// SHA-1 of `challenge(rfc_key)`, written down so the base64 step is checked
/// against known bytes.
const rfc_digest = <<
  0xb3, 0x7a, 0x4f, 0x2c, 0xc0, 0x62, 0x4f, 0x16, 0x90, 0xf6, 0x46, 0x06, 0xcf,
  0x38, 0x59, 0x45, 0xb2, 0xbe, 0xc4, 0xea,
>>

/// The nonce the RFC's key is the base64 of.
const rfc_nonce = <<
  0x74, 0x68, 0x65, 0x20, 0x73, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x20, 0x6e, 0x6f,
  0x6e, 0x63, 0x65,
>>

fn ok_response() -> handshake.Response {
  handshake.Response(status: 101, headers: [
    #("upgrade", "websocket"),
    #("connection", "Upgrade"),
    #("sec-websocket-accept", rfc_accept),
  ])
}

/// The RFC's key, as the only type `request` and `challenge` take.
fn key() -> handshake.Key {
  let assert Ok(key) = handshake.key(rfc_nonce)
  key
}

/// The RFC's accept, as the only type `check` takes.
fn accept() -> handshake.Accept {
  handshake.accept(rfc_digest)
}

fn text(bytes: BitArray) -> String {
  let assert Ok(text) = bit_array.to_string(bytes)
  text
}

/// Room for any head these tests build. Only `next` reads a head, so a bound
/// is picked here rather than left to be forgotten.
fn parse(bytes: BitArray) -> handshake.Next {
  handshake.next(handshake.feed(handshake.new(8192), bytes))
}

// Key and accept

/// The key is base64 of the nonce, and the challenge is that key then the
/// GUID. The key is opaque, so the challenge is where its text shows.
pub fn challenge_is_the_base64_nonce_then_the_guid_test() {
  assert text(handshake.challenge(key()))
    == rfc_key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
}

/// RFC 6455 wants 16 bytes. A shorter nonce is a guessable key, and only `key`
/// builds one, so the rule cannot be skipped by a caller in a hurry.
pub fn key_refuses_a_nonce_that_is_not_16_bytes_test() {
  assert handshake.key(<<>>) == Error(0)
  assert handshake.key(<<0:size(120)>>) == Error(15)
  assert handshake.key(<<0:size(136)>>) == Error(17)

  let assert Ok(_) = handshake.key(<<0:size(128)>>)
}

/// The RFC's worked example: the digest base64s to the accept the response in
/// `ok_response` carries.
pub fn accept_matches_the_rfc_example_test() {
  assert handshake.check(ok_response(), accept: handshake.accept(rfc_digest))
    == Ok(Nil)
}

// The request

pub fn request_has_the_six_headers_the_handshake_needs_test() {
  let request =
    handshake.request(
      host: "gateway.discord.gg",
      port: 443,
      path: "/?v=10&encoding=json",
      key: key(),
      headers: [],
    )

  assert text(request)
    == "GET /?v=10&encoding=json HTTP/1.1\r\n"
    <> "host: gateway.discord.gg\r\n"
    <> "upgrade: websocket\r\n"
    <> "connection: Upgrade\r\n"
    <> "sec-websocket-key: "
    <> rfc_key
    <> "\r\n"
    <> "sec-websocket-version: 13\r\n"
    <> "\r\n"
}

/// 443 is the only default a wss client has, so it is the only one left off.
pub fn request_names_a_port_that_is_not_443_test() {
  let request =
    handshake.request(
      host: "localhost",
      port: 8443,
      path: "/",
      key: key(),
      headers: [],
    )

  assert string.contains(text(request), "host: localhost:8443\r\n")
}

/// Only `header` builds one, so a name the request cannot carry never reaches
/// `request` at all.
fn built(name: String, value: String) -> handshake.Header {
  let assert Ok(header) = handshake.header(name, value)
  header
}

pub fn request_appends_caller_headers_lowercased_test() {
  let request =
    handshake.request(
      host: "example.com",
      port: 443,
      path: "/",
      key: key(),
      headers: [
        built("User-Agent", "glyde"),
        built("  Authorization  ", "Bot token"),
      ],
    )

  assert string.ends_with(
    text(request),
    "sec-websocket-version: 13\r\n"
      <> "user-agent: glyde\r\n"
      <> "authorization: Bot token\r\n"
      <> "\r\n",
  )
}

pub fn header_refuses_a_name_the_handshake_owns_test() {
  let owned = [
    "Host", "Upgrade", "Connection", "Sec-WebSocket-Key",
    "Sec-WebSocket-Version", "Sec-WebSocket-Extensions",
    "Sec-WebSocket-Protocol",
  ]

  list.each(owned, fn(name) {
    assert handshake.header(name, "hijacked")
      == Error(handshake.Owned(string.lowercase(name)))
  })
}

/// The server splits a header line on its first colon, so a name carrying one
/// would arrive as a header glyde owns, whatever the value says. Rejecting
/// anything that is not an RFC 7230 token is what closes that door.
pub fn header_refuses_a_name_that_is_not_a_token_test() {
  list.each(["host: gateway.discord.gg", "x b", "x\tb", "x\r\ny"], fn(name) {
    assert handshake.header(name, "value") == Error(handshake.NotAToken(name))
  })

  assert handshake.header("   ", "nothing") == Error(handshake.NotAToken(""))
}

/// A newline in a value would end the request and start another one.
pub fn header_refuses_a_value_that_could_split_the_request_test() {
  assert handshake.header("x-a", "one\r\nx-injected: yes")
    == Error(handshake.Splittable)

  let request =
    handshake.request(
      host: "example.com",
      port: 443,
      path: "/",
      key: key(),
      headers: [built("x-fine", "three")],
    )

  assert !string.contains(text(request), "injected")
  assert string.contains(text(request), "x-fine: three\r\n")
}

// Parsing

fn upgrade_bytes() -> BitArray {
  bit_array.from_string(
    "HTTP/1.1 101 Switching Protocols\r\n"
    <> "Upgrade: websocket\r\n"
    <> "Connection: Upgrade\r\n"
    <> "Sec-WebSocket-Accept: "
    <> rfc_accept
    <> "\r\n\r\n",
  )
}

pub fn parse_reads_a_101_test() {
  assert parse(upgrade_bytes())
    == handshake.Head(
      handshake.Response(status: 101, headers: [
        #("upgrade", "websocket"),
        #("connection", "Upgrade"),
        #("sec-websocket-accept", rfc_accept),
      ]),
      <<>>,
    )
}

/// A server may put its first frame in the same packet as the 101.
pub fn parse_keeps_the_bytes_after_the_head_test() {
  let bytes = bit_array.append(upgrade_bytes(), <<0x81, 0x02, 0x68, 0x69>>)

  let assert handshake.Head(_, rest) = parse(bytes)
  assert rest == <<0x81, 0x02, 0x68, 0x69>>
}

/// The reader has no length to go on, so every prefix has to say Partial.
pub fn parse_wants_more_until_the_blank_line_test() {
  let bytes = upgrade_bytes()
  let size = bit_array.byte_size(bytes)

  list.each(prefixes(size - 1), fn(n) {
    let assert Ok(prefix) = bit_array.slice(bytes, 0, n)
    assert parse(prefix) == handshake.Partial
  })
}

fn prefixes(last: Int) -> List(Int) {
  case last < 0 {
    True -> []
    False -> [last, ..prefixes(last - 1)]
  }
}

pub fn parse_trims_and_lowercases_header_names_test() {
  let bytes =
    bit_array.from_string(
      "HTTP/1.1 101 x\r\n  X-Odd-Case  :   spaced   \r\n\r\n",
    )

  assert parse(bytes)
    == handshake.Head(
      handshake.Response(status: 101, headers: [#("x-odd-case", "spaced")]),
      <<>>,
    )
}

/// A header value may hold a colon, so only the first one splits the line.
pub fn parse_splits_a_header_on_its_first_colon_test() {
  let bytes = bit_array.from_string("HTTP/1.1 101 x\r\ndate: 10:30:00\r\n\r\n")

  assert parse(bytes)
    == handshake.Head(
      handshake.Response(status: 101, headers: [#("date", "10:30:00")]),
      <<>>,
    )
}

pub fn parse_reads_a_refusal_test() {
  let bytes =
    bit_array.from_string(
      "HTTP/1.1 429 Too Many Requests\r\nretry-after: 5\r\n\r\n{}",
    )

  assert parse(bytes)
    == handshake.Head(
      handshake.Response(status: 429, headers: [#("retry-after", "5")]),
      <<0x7B, 0x7D>>,
    )
}

pub fn parse_rejects_a_head_that_is_not_http_test() {
  assert parse(bit_array.from_string("hello there\r\n\r\n"))
    == handshake.Malformed(handshake.StatusNotHttp("hello there"))
}

pub fn parse_rejects_a_status_that_is_not_a_number_test() {
  assert parse(bit_array.from_string("HTTP/1.1 abc Nope\r\n\r\n"))
    == handshake.Malformed(handshake.StatusNotHttp("HTTP/1.1 abc Nope"))
}

pub fn parse_rejects_a_header_line_with_no_colon_test() {
  assert parse(bit_array.from_string("HTTP/1.1 101 x\r\nnonsense\r\n\r\n"))
    == handshake.Malformed(handshake.HeaderWithoutColon("nonsense"))
}

pub fn parse_rejects_a_head_that_is_not_text_test() {
  assert parse(<<0xFF, 0xFE, 13, 10, 13, 10>>)
    == handshake.Malformed(handshake.HeadNotText)
}

/// A head arrives over several reads, so the reader holds what it has.
pub fn feed_puts_a_head_back_together_test() {
  let bytes = upgrade_bytes()
  let size = bit_array.byte_size(bytes)
  let assert Ok(first) = bit_array.slice(bytes, 0, 20)
  let assert Ok(rest) = bit_array.slice(bytes, 20, size - 20)

  let reader = handshake.feed(handshake.new(8192), first)
  assert handshake.next(reader) == handshake.Partial

  let assert handshake.Head(response, <<>>) =
    handshake.next(handshake.feed(reader, rest))
  assert response.status == 101
}

/// A server that never sends the blank line would otherwise grow the buffer
/// until the VM dies. The bound is the reader's, so no caller can forget it.
pub fn next_refuses_a_head_that_never_ends_test() {
  let reader =
    handshake.feed(
      handshake.new(16),
      bit_array.from_string("HTTP/1.1 101 x\r\n"),
    )
  assert handshake.next(reader) == handshake.Partial

  let reader = handshake.feed(reader, bit_array.from_string("date: now\r\n"))
  assert handshake.next(reader) == handshake.TooLong(27)
}

/// The bound only refuses bytes that are not a head yet: one that has already
/// ended is delivered whatever its size.
pub fn next_reads_a_head_that_is_past_the_bound_but_finished_test() {
  let reader = handshake.feed(handshake.new(4), upgrade_bytes())

  let assert handshake.Head(..) = handshake.next(reader)
}

pub fn malformed_to_string_names_the_line_test() {
  assert handshake.malformed_to_string(handshake.HeadNotText)
    == "response head is not text"
  assert handshake.malformed_to_string(handshake.StatusNotHttp("nope"))
    == "status line is not HTTP: nope"
  assert handshake.malformed_to_string(handshake.HeaderWithoutColon("nope"))
    == "header line has no colon: nope"
}

// Checking

pub fn check_accepts_the_rfc_example_test() {
  assert handshake.check(ok_response(), accept: accept()) == Ok(Nil)
}

pub fn check_refuses_a_status_that_is_not_101_test() {
  let response = handshake.Response(..ok_response(), status: 429)

  assert handshake.check(response, accept: accept())
    == Error(handshake.NotSwitching(429))
}

/// A wrong accept means the peer never hashed our key.
pub fn check_refuses_a_wrong_accept_test() {
  let response =
    handshake.Response(status: 101, headers: [
      #("upgrade", "websocket"),
      #("connection", "Upgrade"),
      #("sec-websocket-accept", "AAAAAAAAAAAAAAAAAAAAAAAAAAA="),
    ])

  assert handshake.check(response, accept: accept())
    == Error(handshake.WrongHeader(
      "sec-websocket-accept",
      "AAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    ))
}

/// Base64 is case sensitive, so folding case accepts a value nobody computed.
pub fn check_compares_the_accept_case_sensitively_test() {
  let response =
    handshake.Response(status: 101, headers: [
      #("upgrade", "websocket"),
      #("connection", "Upgrade"),
      #("sec-websocket-accept", string.lowercase(rfc_accept)),
    ])

  let assert Error(handshake.WrongHeader(..)) =
    handshake.check(response, accept: accept())
}

pub fn check_needs_every_header_test() {
  let names = ["upgrade", "connection", "sec-websocket-accept"]

  list.each(names, fn(missing) {
    let headers =
      list.filter(ok_response().headers, fn(header) { header.0 != missing })
    let response = handshake.Response(..ok_response(), headers:)

    assert handshake.check(response, accept: accept())
      == Error(handshake.MissingHeader(missing))
  })
}

pub fn check_reads_upgrade_case_insensitively_test() {
  let response =
    handshake.Response(..ok_response(), headers: [
      #("upgrade", "WebSocket"),
      #("connection", "upgrade"),
      #("sec-websocket-accept", rfc_accept),
    ])

  assert handshake.check(response, accept: accept()) == Ok(Nil)
}

/// A server behind a proxy sends more than one connection token.
pub fn check_finds_upgrade_among_several_connection_tokens_test() {
  let response =
    handshake.Response(..ok_response(), headers: [
      #("upgrade", "websocket"),
      #("connection", "keep-alive, Upgrade"),
      #("sec-websocket-accept", rfc_accept),
    ])

  assert handshake.check(response, accept: accept()) == Ok(Nil)
}

pub fn check_refuses_a_connection_header_without_upgrade_test() {
  let response =
    handshake.Response(..ok_response(), headers: [
      #("upgrade", "websocket"),
      #("connection", "keep-alive"),
      #("sec-websocket-accept", rfc_accept),
    ])

  assert handshake.check(response, accept: accept())
    == Error(handshake.WrongHeader("connection", "keep-alive"))
}

/// glyde offers no extensions, so a server naming one has agreed to a framing
/// we cannot read. RFC 6455 says fail.
pub fn check_refuses_an_extension_we_never_offered_test() {
  let headers =
    list.append(ok_response().headers, [
      #("sec-websocket-extensions", "permessage-deflate"),
    ])
  let response = handshake.Response(..ok_response(), headers:)

  assert handshake.check(response, accept: accept())
    == Error(handshake.UnwantedHeader(
      "sec-websocket-extensions",
      "permessage-deflate",
    ))
}

pub fn check_refuses_a_subprotocol_we_never_offered_test() {
  let headers =
    list.append(ok_response().headers, [#("sec-websocket-protocol", "chat")])
  let response = handshake.Response(..ok_response(), headers:)

  assert handshake.check(response, accept: accept())
    == Error(handshake.UnwantedHeader("sec-websocket-protocol", "chat"))
}

/// An empty extensions header means the server agreed to none.
pub fn check_allows_an_empty_extensions_header_test() {
  let headers =
    list.append(ok_response().headers, [#("sec-websocket-extensions", "")])
  let response = handshake.Response(..ok_response(), headers:)

  assert handshake.check(response, accept: accept()) == Ok(Nil)
}

/// The empty one first, the real one second. Reading only the first copy would
/// take the refusal for a server that agreed to nothing, and glyde would then
/// read frames in a framing it cannot decode.
pub fn check_refuses_an_extension_behind_an_empty_one_test() {
  let headers =
    list.append(ok_response().headers, [
      #("sec-websocket-extensions", ""),
      #("sec-websocket-extensions", "permessage-deflate"),
    ])
  let response = handshake.Response(..ok_response(), headers:)

  assert handshake.check(response, accept: accept())
    == Error(handshake.UnwantedHeader(
      "sec-websocket-extensions",
      "permessage-deflate",
    ))
}

pub fn check_refuses_a_subprotocol_behind_an_empty_one_test() {
  let headers =
    list.append(ok_response().headers, [
      #("sec-websocket-protocol", ""),
      #("sec-websocket-protocol", "chat"),
    ])
  let response = handshake.Response(..ok_response(), headers:)

  assert handshake.check(response, accept: accept())
    == Error(handshake.UnwantedHeader("sec-websocket-protocol", "chat"))
}

/// A response that answers the same question twice is refused rather than read
/// as whichever copy came first, even when both copies say the same thing.
pub fn check_refuses_a_header_it_needs_sent_twice_test() {
  list.each(["upgrade", "connection", "sec-websocket-accept"], fn(name) {
    let assert Ok(value) = list.key_find(ok_response().headers, name)
    let headers = list.append(ok_response().headers, [#(name, value)])
    let response = handshake.Response(..ok_response(), headers:)

    assert handshake.check(response, accept: accept())
      == Error(handshake.RepeatedHeader(name))
  })
}

/// Two different accepts is the case that matters: one of them was computed by
/// something that never saw our key.
pub fn check_refuses_two_different_accepts_test() {
  let headers =
    list.append(ok_response().headers, [
      #("sec-websocket-accept", "AAAAAAAAAAAAAAAAAAAAAAAAAAA="),
    ])
  let response = handshake.Response(..ok_response(), headers:)

  assert handshake.check(response, accept: accept())
    == Error(handshake.RepeatedHeader("sec-websocket-accept"))
}

pub fn failure_to_string_names_the_problem_test() {
  assert handshake.failure_to_string(handshake.NotSwitching(429))
    == "upgrade refused with status 429"
  assert handshake.failure_to_string(handshake.MissingHeader("upgrade"))
    == "no upgrade header"
  assert handshake.failure_to_string(handshake.WrongHeader("upgrade", "h2c"))
    == "upgrade header says h2c"
  assert handshake.failure_to_string(handshake.RepeatedHeader("connection"))
    == "more than one connection header"
  assert handshake.failure_to_string(handshake.UnwantedHeader(
      "sec-websocket-extensions",
      "permessage-deflate",
    ))
    == "sec-websocket-extensions header offers permessage-deflate, which we did not ask for"
}
