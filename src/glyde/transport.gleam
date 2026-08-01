//// What the built-in runtime asks of the outside world: one socket, one HTTP
//// client, one clock. `glyde.with_transport` swaps it for a proxy, a
//// recording double, or a script in a test.
////
//// Stdlib and `gleam_http` only. Writing a transport must not drag in the
//// Erlang one, which lives in `glyde/transport/erlang`.
////
//// Not `glyde/client.Transport`, which is the six outputs of the pure state
//// machine. This is the platform underneath one.

import gleam/http/request.{type Request}
import gleam/http/response.{type Response}

/// Why an HTTP request came back with nothing. A shape and not a rendering, so
/// a caller can tell a timeout from a name that does not resolve.
pub type Unreachable {
  /// No connection at all: a name that does not resolve, a refused port, a TLS
  /// handshake that failed.
  ConnectFailed(detail: String)

  /// The request went out and nothing came back in time.
  TimedOut

  /// Something came back and it was not an HTTP response we could read.
  Unreadable

  /// Anything the other three do not cover, for a transport of your own.
  Other(detail: String)
}

/// An HTTP answer, or why there was none.
pub type Answer =
  Result(Response(BitArray), Unreachable)

/// What a socket says, in order: `Opened` at most once and before everything,
/// then messages, then exactly one `Closed`.
pub type Event {
  /// The socket is open. Nothing can be sent before this arrives.
  Opened

  /// Discord's gateway payloads arrive here as JSON.
  TextMessage(text: String)

  /// What Discord sends once a compressed transport is negotiated.
  BinaryMessage(bytes: BitArray)

  /// 1006 means no close frame at all: a dial that never connected, a dead
  /// transport, a close of your own. 1005 means the peer named no code.
  Closed(code: Int, reason: String)

  /// Advisory: a `Closed` always follows and that is what ends the socket.
  Failed(reason: String)

  /// The upgrade was answered and it was not 101. Discord sends 401 for a dead
  /// token and 429 for a bot dialling too often, and the shard reads the
  /// number. A transport that cannot see one reports `Failed` instead.
  Refused(status: Int, reason: String)
}

/// Everything the built-in runtime asks of the outside world. Every function
/// is synchronous: it answers before it returns.
pub type Transport {
  Transport(
    /// Dial a `wss` URL. Blocks until TLS and the upgrade are done, and the
    /// socket reports `Opened` through its own `turn` afterwards.
    open: fn(String) -> Socket,
    /// One HTTP request. Never raises: an unreachable host is `Unreachable`,
    /// because a dead REST call must not take a live gateway session with it.
    request: fn(Request(BitArray)) -> Answer,
    /// Milliseconds on a clock that only goes forwards. Every deadline is read
    /// from it, so a transport that jumps runs a whole session in no time.
    now: fn() -> Int,
    /// Wait `in_ms`. Only reached with no socket to wait on, which is the gap
    /// between a close and the next dial.
    idle: fn(Int) -> Nil,
  )
}

pub type Socket {
  Socket(
    /// Write one text frame. `False` means the socket is dead: the runtime
    /// stops writing and reports the close itself.
    send: fn(String) -> Bool,
    /// Write a close frame with this code, then tear the socket down. Nothing
    /// to report: the socket is finished either way.
    close: fn(Int) -> Nil,
    /// Abandon the socket with no close frame. Nothing to report, as above.
    drop: fn() -> Nil,
    /// Block until the socket says something or `in_ms` passes, then answer
    /// with what it said and the socket to use next.
    turn: fn(Int) -> #(Socket, List(Event)),
  )
}

/// One line per reason, for a host that just wants to print it.
pub fn describe(reason: Unreachable) -> String {
  case reason {
    ConnectFailed(detail:) -> "could not connect: " <> detail
    TimedOut -> "no answer in time"
    Unreadable -> "the answer was not a readable HTTP response"
    Other(detail:) -> detail
  }
}
