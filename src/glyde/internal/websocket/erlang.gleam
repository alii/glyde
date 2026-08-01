//// A WebSocket client: TLS, the RFC 6455 upgrade, and the codec in
//// `glyde/websocket/frame`. The socket is passive, so nothing arrives until
//// `receive` is called.
////
//// Two protocol duties are the caller's, because both need a mask and this
//// module has no random source: answer a `PingMessage` with `send_pong`, and
//// answer a `CloseMessage` with `close`, then stop reading.
////
//// `wss` only, no extensions, no reconnect, no outbound fragmentation, no
//// proxy or redirect, and a hostname has to be ASCII.

import gleam/bit_array
import gleam/bool
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/option
import gleam/result
import gleam/uri
import glyde/internal/timing
import glyde/websocket/frame
import glyde/websocket/handshake
import glyde/websocket/stream

pub type SslSocket

/// One connected WebSocket and its unread bytes. `receive` gives back a new
/// one and leaves the old holding stale bytes, so always carry the newest.
pub type Socket {
  Socket(ssl: SslSocket, stream: stream.Stream)
}

/// What is wrong with the URL. The URL itself rides beside it in `BadUrl`.
pub type UrlProblem {
  NotParseable
  NotWss
  NoHost

  /// `ssl:connect` is handed the host as bytes, so a name outside ASCII would
  /// go out as its UTF-8, never as the punycode a server answers to.
  NonAsciiHost
}

/// What went wrong with a socket that was already up. A peer that hung up is
/// not in here: that is `Closed`, which a caller acts on differently.
pub type SocketProblem {
  /// A read or a write ran past its timeout.
  TimedOut

  /// Whatever `ssl` said, rendered: a reason term is the one thing Gleam
  /// cannot print, so the FFI does it.
  Broke(reason: String)

  /// `ssl` raised rather than answering, which means the library itself gave
  /// up, not the peer. Retrying the same call gets the same raise.
  Crashed(reason: String)
}

pub type Error {
  /// Refused before anything was dialled.
  BadUrl(url: String, problem: UrlProblem)

  /// The nonce is not the 16 bytes RFC 6455 asks for. The count is what
  /// `connect` was handed.
  BadNonce(bytes: Int)

  /// TLS would not come up: DNS, a refused port, a certificate that did not
  /// verify.
  ConnectFailed(reason: String)

  /// The `ssl` application would not start, usually an OTP build without the
  /// crypto NIF. Nothing about the host changes between dials, so retrying
  /// this one never helps.
  SslUnavailable(reason: String)

  /// The head read fine and is not the upgrade we asked for. Discord sends 429
  /// when a bot dials too often.
  HandshakeRefused(failure: handshake.Failure)

  /// The bytes the server sent are not a response head at all.
  HandshakeUnreadable(reason: handshake.Bad)

  /// `max_head_bytes` arrived with no blank line ending the head.
  HeadTooLong(bytes: Int)

  /// The socket itself failed after it was up. The problem is unrendered, so a
  /// caller can tell a timeout from a TLS alert without reading words.
  SocketFailed(problem: SocketProblem)

  /// The peer went away. Any close frame it sent is already in the messages
  /// received.
  Closed

  /// The bytes stopped being RFC 6455. The reason is `frame`'s, unrendered, so
  /// a caller can match it.
  ProtocolFailed(reason: frame.Violation)

  /// The bytes held with no whole message out of them went past the
  /// `max_bytes` `connect` was given. Our bound, not the RFC's.
  BufferFull(bytes: Int)
}

/// The HTTP status of a refused upgrade, for a caller that acts on the number
/// rather than printing it. `Error(Nil)` for every other way a dial fails.
pub fn refusal_status(error: Error) -> Result(Int, Nil) {
  case error {
    HandshakeRefused(handshake.NotSwitching(status)) -> Ok(status)
    _ -> Error(Nil)
  }
}

pub fn error_to_string(error: Error) -> String {
  case error {
    BadUrl(url:, problem:) -> "bad url: " <> url_problem_to_string(problem, url)
    BadNonce(bytes) ->
      "handshake nonce is " <> int.to_string(bytes) <> " bytes, not 16"
    ConnectFailed(reason) -> "could not connect: " <> reason
    SslUnavailable(reason) -> "the ssl application will not start: " <> reason
    HandshakeRefused(failure) ->
      "handshake failed: " <> handshake.failure_to_string(failure)
    HandshakeUnreadable(reason) ->
      "handshake failed: " <> handshake.malformed_to_string(reason)
    HeadTooLong(bytes) ->
      "handshake failed: response head never ended in "
      <> int.to_string(bytes)
      <> " bytes"
    SocketFailed(problem) ->
      "socket failed: " <> socket_problem_to_string(problem)
    Closed -> "connection closed"
    ProtocolFailed(reason) ->
      "protocol violated: " <> frame.violation_to_string(reason)
    BufferFull(bytes) ->
      "buffer full at "
      <> int.to_string(bytes)
      <> " bytes with no message in it"
  }
}

fn url_problem_to_string(problem: UrlProblem, url: String) -> String {
  case problem {
    NotParseable -> "cannot be parsed: " <> url
    NotWss -> "only wss is supported: " <> url
    NoHost -> "no host: " <> url
    NonAsciiHost -> "host is not ascii: " <> url
  }
}

fn socket_problem_to_string(problem: SocketProblem) -> String {
  case problem {
    TimedOut -> "timed out"
    Broke(reason) -> reason
    Crashed(reason) -> "ssl raised " <> reason
  }
}

pub type Received {
  Arrived(socket: Socket, message: frame.Message)

  /// Nothing complete arrived before the timeout.
  Silent(socket: Socket)

  /// The socket is finished and already torn down. Nothing to carry on with.
  Dropped(error: Error)
}

/// Bytes held that have not become a message, against the `max_bytes`
/// `connect` was given. Past it the next `receive` is `Dropped(BufferFull)`.
pub fn buffered(socket: Socket) -> Int {
  stream.buffered(socket.stream)
}

/// Dial a `wss` URL and complete the upgrade, returning once it is open.
///
/// `nonce` is 16 random bytes for `Sec-WebSocket-Key`, any other length being
/// `BadNonce`; this module draws none itself. `timeout` bounds the dial, then
/// bounds the whole upgrade again, and becomes the socket's send timeout.
/// `max_bytes` bounds the bytes the socket will hold with no whole message out
/// of them. A header the handshake owns cannot be overridden.
pub fn connect(
  url url: String,
  nonce nonce: BitArray,
  headers headers: List(handshake.Header),
  timeout timeout: Int,
  max_bytes max_bytes: Int,
) -> Result(Socket, Error) {
  use target <- result.try(target_of(url))
  use key <- result.try(
    handshake.key(nonce) |> result.map_error(fn(bytes) { BadNonce(bytes) }),
  )
  use ssl <- result.try(dial(target, timeout))

  case upgrade(ssl, target, key, headers, timeout) {
    Ok(leftover) -> Ok(Socket(ssl:, stream: stream.new(leftover, max_bytes)))
    Error(error) -> {
      ssl_close(ssl)
      Error(error)
    }
  }
}

pub fn send_text(
  socket: Socket,
  text: String,
  mask: frame.Mask,
) -> Result(Nil, Error) {
  send(socket, frame.SendText, bit_array.from_string(text), mask)
}

pub fn send_bytes(
  socket: Socket,
  bytes: BitArray,
  mask: frame.Mask,
) -> Result(Nil, Error) {
  send(socket, frame.SendBinary, bytes, mask)
}

/// Answer a `PingMessage`. RFC 6455 wants the payload echoed unchanged.
pub fn send_pong(
  socket: Socket,
  payload: BitArray,
  mask: frame.Mask,
) -> Result(Nil, Error) {
  send(socket, frame.SendPong, payload, mask)
}

/// Take the next message, waiting up to `timeout` milliseconds.
///
/// The timeout bounds the call, not one read: the deadline is set here, so a
/// peer sending bytes that never finish a message runs it out the same as
/// silence does.
pub fn receive(socket: Socket, timeout timeout: Int) -> Received {
  receive_by(socket, timing.now() + timeout)
}

fn receive_by(socket: Socket, deadline: Int) -> Received {
  case stream.next(socket.stream) {
    stream.Ready(message:, stream: read) ->
      Arrived(Socket(..socket, stream: read), message)

    stream.Failed(reason) -> dropped(socket, ProtocolFailed(reason))

    stream.Overflowed(bytes) -> dropped(socket, BufferFull(bytes))

    stream.Waiting(stream: read) -> {
      let socket = Socket(..socket, stream: read)
      // Zero left is still a read: it takes whatever already arrived and then
      // stalls, which is what a caller polling with `timeout: 0` asks for.
      case ssl_recv(socket.ssl, left_of(deadline)) {
        Ok(bytes) ->
          receive_by(
            Socket(..socket, stream: stream.feed(read, bytes)),
            deadline,
          )
        Error(Stalled) -> Silent(socket)
        Error(trouble) -> dropped(socket, trouble_to_error(trouble))
      }
    }
  }
}

/// Milliseconds a read may still take. Never negative: `ssl:recv` wants a
/// timeout, not a point in time.
fn left_of(deadline: Int) -> Int {
  int.max(0, deadline - timing.now())
}

/// `Dropped` hands back no socket, so the teardown happens here or never.
fn dropped(socket: Socket, error: Error) -> Received {
  ssl_close(socket.ssl)
  Dropped(error)
}

/// Send a close frame, then tear the socket down. Any code fits, and
/// `frame.close_payload` cuts the reason to fit. Does not wait for the peer.
///
/// The teardown is the contract and the frame is best effort: answering a
/// peer's own close usually cannot write, because it has already gone.
pub fn close(
  socket: Socket,
  code: Int,
  reason: String,
  mask: frame.Mask,
) -> Nil {
  let _ = send(socket, frame.SendClose, frame.close_payload(code, reason), mask)
  ssl_close(socket.ssl)
}

/// Abandon the socket with no close frame. For a peer that has already gone.
pub fn drop(socket: Socket) -> Nil {
  ssl_close(socket.ssl)
}

/// The `Sec-WebSocket-Accept` a server must send for this key.
pub fn accept_for(key: handshake.Key) -> handshake.Accept {
  handshake.accept(hash(Sha, handshake.challenge(key)))
}

fn send(
  socket: Socket,
  kind: frame.Sendable,
  payload: BitArray,
  mask: frame.Mask,
) -> Result(Nil, Error) {
  ssl_send(socket.ssl, frame.encode(kind, payload, mask))
  |> result.map_error(trouble_to_error)
}

type Target {
  Target(host: String, port: Int, path: String)
}

fn target_of(url: String) -> Result(Target, Error) {
  use parsed <- result.try(
    uri.parse(url)
    |> result.replace_error(BadUrl(url:, problem: NotParseable)),
  )

  use <- bool.guard(
    parsed.scheme != option.Some("wss"),
    Error(BadUrl(url:, problem: NotWss)),
  )

  case parsed.host {
    option.Some("") | option.None -> Error(BadUrl(url:, problem: NoHost))
    option.Some(host) -> {
      // `uri_string:parse` turns a non-ASCII URL away before this is reached.
      // The check still belongs here: the invariant is this module's, and
      // `to_charlist` would hand `ssl:connect` the UTF-8 bytes, leaving SNI
      // and the certificate check to be made against mojibake.
      use <- bool.guard(
        !ascii(host),
        Error(BadUrl(url:, problem: NonAsciiHost)),
      )
      let port = option.unwrap(parsed.port, 443)
      let path = case parsed.path {
        "" -> "/"
        path -> path
      }
      let path = case parsed.query {
        option.Some(query) -> path <> "?" <> query
        option.None -> path
      }
      Ok(Target(host:, port:, path:))
    }
  }
}

fn ascii(host: String) -> Bool {
  all_ascii(bit_array.from_string(host))
}

fn all_ascii(bytes: BitArray) -> Bool {
  case bytes {
    <<byte, rest:bytes>> if byte < 0x80 -> all_ascii(rest)
    <<>> -> True
    _ -> False
  }
}

fn dial(target: Target, timeout: Int) -> Result(SslSocket, Error) {
  // A library cannot assume its host started ssl, and starting an already
  // started application is not an error.
  use _ <- result.try(
    ensure_all_started(Ssl)
    |> result.map_error(fn(reason) { SslUnavailable(describe(reason)) }),
  )

  let host = to_charlist(target.host)
  let options = [
    Binary,
    // Passive: any other mode delivers to a mailbox, which needs a process.
    Active(False),
    Verify(VerifyPeer),
    Cacerts(cacerts()),
    // Without these two a certificate for any host verifies. SNI also tells a
    // shared frontend which certificate to serve.
    ServerNameIndication(host),
    CustomizeHostnameCheck([MatchFun(https_match_fun(Https))]),
    Nodelay(True),
    SendTimeout(timeout),
    SendTimeoutClose(True),
  ]

  ssl_connect(host, target.port, options, timeout)
  |> result.map_error(fn(trouble) { ConnectFailed(said(trouble)) })
}

/// A dial that does not come up is `ConnectFailed` however it failed: there is
/// no socket either way, and only the words differ.
fn said(trouble: Trouble) -> String {
  case trouble {
    Hangup -> "closed"
    Stalled -> "timed out"
    Broken(reason) -> reason
    Raised(reason) -> "ssl raised " <> reason
  }
}

/// Our number: 8 KB is what common HTTP servers cap a response head at.
const max_head_bytes: Int = 8192

fn upgrade(
  ssl: SslSocket,
  target: Target,
  key: handshake.Key,
  headers: List(handshake.Header),
  timeout: Int,
) -> Result(BitArray, Error) {
  let request =
    handshake.request(
      host: target.host,
      port: target.port,
      path: target.path,
      key:,
      headers:,
    )

  use _ <- result.try(
    ssl_send(ssl, request) |> result.map_error(trouble_to_error),
  )
  use head <- result.try(read_head(
    ssl,
    handshake.new(max_head_bytes),
    timing.now() + timeout,
  ))
  let #(response, leftover) = head

  handshake.check(response, accept: accept_for(key))
  |> result.map_error(HandshakeRefused)
  |> result.replace(leftover)
}

/// `deadline` is a point on `timing.now`, not a per-read timeout: a server
/// trickling a head one byte at a time must not buy itself forever.
fn read_head(
  ssl: SslSocket,
  reader: handshake.Reader,
  deadline: Int,
) -> Result(#(handshake.Response, BitArray), Error) {
  case handshake.next(reader) {
    handshake.Head(response:, rest:) -> Ok(#(response, rest))
    handshake.Malformed(reason) -> Error(HandshakeUnreadable(reason))
    handshake.TooLong(bytes) -> Error(HeadTooLong(bytes))
    handshake.Partial -> {
      case ssl_recv(ssl, left_of(deadline)) {
        Ok(bytes) -> read_head(ssl, handshake.feed(reader, bytes), deadline)
        Error(trouble) -> Error(trouble_to_error(trouble))
      }
    }
  }
}

/// The FFI names the two reasons a caller acts on; the rest arrive rendered.
/// `Raised` is an `ssl` call that unwound instead of answering, caught in the
/// FFI so this module never has to think about which failures do that.
type Trouble {
  Hangup
  Stalled
  Broken(reason: String)
  Raised(reason: String)
}

fn trouble_to_error(trouble: Trouble) -> Error {
  case trouble {
    Hangup -> Closed
    Stalled -> SocketFailed(TimedOut)
    Broken(reason) -> SocketFailed(Broke(reason))
    Raised(reason) -> SocketFailed(Crashed(reason))
  }
}

type Charlist

/// The atom `sha`, for `crypto:hash`.
type Digest {
  Sha
}

/// The atom `ssl`, for `application:ensure_all_started`.
type Application {
  Ssl
}

/// The atom `https`, which picks the hostname matching rules a browser uses.
type Scheme {
  Https
}

type Verification {
  VerifyPeer
}

type HostnameCheck {
  MatchFun(Dynamic)
}

/// Each constructor is already the term `ssl:connect` expects.
type Opt {
  Binary
  Active(Bool)
  Verify(Verification)
  Cacerts(Dynamic)
  ServerNameIndication(Charlist)
  CustomizeHostnameCheck(List(HostnameCheck))
  Nodelay(Bool)
  SendTimeout(Int)
  SendTimeoutClose(Bool)
}

@external(erlang, "erlang", "binary_to_list")
fn to_charlist(text: String) -> Charlist

@external(erlang, "application", "ensure_all_started")
fn ensure_all_started(application: Application) -> Result(Dynamic, Dynamic)

@external(erlang, "public_key", "cacerts_get")
fn cacerts() -> Dynamic

@external(erlang, "public_key", "pkix_verify_hostname_match_fun")
fn https_match_fun(scheme: Scheme) -> Dynamic

@external(erlang, "crypto", "hash")
fn hash(algorithm: Digest, data: BitArray) -> BitArray

@external(erlang, "glyde_websocket_ffi", "connect")
fn ssl_connect(
  host: Charlist,
  port: Int,
  options: List(Opt),
  timeout: Int,
) -> Result(SslSocket, Trouble)

@external(erlang, "glyde_websocket_ffi", "close")
fn ssl_close(ssl: SslSocket) -> Nil

@external(erlang, "glyde_websocket_ffi", "send")
fn ssl_send(ssl: SslSocket, bytes: BitArray) -> Result(Nil, Trouble)

@external(erlang, "glyde_websocket_ffi", "recv")
fn ssl_recv(ssl: SslSocket, timeout: Int) -> Result(BitArray, Trouble)

@external(erlang, "glyde_term_ffi", "describe")
fn describe(reason: Dynamic) -> String
