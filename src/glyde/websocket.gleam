//// A WebSocket client.
////
//// ```gleam
//// let assert Ok(bye) = websocket.close_code(1000)
////
//// let socket = websocket.open("wss://gateway.discord.gg/?v=10")
//// let socket = websocket.send_text(socket, identify)
//// let socket = websocket.close(socket, bye, "bye")
//// ```
////
//// Every call hands back the socket to use next, the writes included: a write
//// that fails is what ends a socket most of the time, and the reason for it
//// comes out of the next `poll`.
////
//// Mask bytes and the handshake nonce come from `crypto:strong_rand_bytes`,
//// never from `glyde/rng`, which is reproducible and so is the very thing
//// masking exists to stop.
////
//// No reconnect: `glyde/gateway` owns redialling. No ping, though a peer's is
//// answered here and never reported. No extensions, no `ws://`, no server
//// role, no subprotocols, no request headers, no backpressure.
////
//// The events are `glyde/transport.Event`, not ours: they are the vocabulary
//// every transport speaks, and one of those is this client.

import gleam/list
import gleam/option.{type Option, None, Some}
import glyde/internal/websocket/erlang
import glyde/transport.{
  type Event, BinaryMessage, Closed, Failed, Opened, Refused, TextMessage,
}
import glyde/websocket/frame

/// Milliseconds. Our number: Discord's gateway answers in well under a second.
pub const dial_timeout: Int = 10_000

/// Bytes one socket will hold with no whole message out of them before it
/// gives up on the peer. The same ceiling `glyde/gateway` puts on a
/// reassembled payload, which is the largest thing that can arrive.
pub const max_buffered_bytes: Int = 33_554_432

/// A socket and what it still owes the caller. It carries bytes read but not
/// yet handed over, and every call that changes it hands back a new one, so
/// always use the newest.
///
/// Nothing can be reported before `open` returns, so the events it cannot
/// deliver wait in here until the first `poll`.
pub opaque type Socket {
  /// Connected. `Opened` is owed.
  Dialled(live: erlang.Socket)

  /// Open, with `Opened` already reported.
  Reading(live: erlang.Socket)

  /// The transport is down and `Closed` has not gone out. Covers a dial that
  /// never came up, a write that failed and a close of our own; `trouble`,
  /// when there is one, goes out just before the `Closed`.
  Ending(trouble: Option(Event))

  /// `Closed` has been reported. Nothing further will happen.
  Done
}

/// A close code a client is allowed to put on the wire, and the only thing
/// `close` accepts: a code it would have turned down cannot reach it.
pub opaque type CloseCode {
  CloseCode(number: Int)
}

/// 1000, or anything from 3000 to 4999, which is what RFC 6455 lets a client
/// send. Discord uses 1000 to end a session and 4000 to keep it resumable.
/// The `Error` hands the number back.
pub fn close_code(number: Int) -> Result(CloseCode, Int) {
  case number == 1000 || { number >= 3000 && number <= 4999 } {
    True -> Ok(CloseCode(number))
    False -> Error(number)
  }
}

/// Dial a `wss` URL.
///
/// Blocks for up to `dial_timeout`. Nothing is reported here, a failed dial
/// included: that comes out of the first `poll`.
pub fn open(url: String) -> Socket {
  let dialled =
    erlang.connect(
      url:,
      nonce: strong_rand_bytes(16),
      headers: [],
      timeout: dial_timeout,
      max_bytes: max_buffered_bytes,
    )

  case dialled {
    Ok(live) -> Dialled(live)
    Error(error) -> Ending(Some(trouble(error)))
  }
}

/// A refused upgrade carries the status, because the gateway halts on a 401
/// and waits on a 429. Everything else is only words.
fn trouble(error: erlang.Error) -> Event {
  let reason = erlang.error_to_string(error)
  case erlang.refusal_status(error) {
    Ok(status) -> Refused(status:, reason:)
    Error(Nil) -> Failed(reason)
  }
}

/// A socket for a dial that never got as far as answering, because the
/// platform raised under it. It behaves like any other failed dial: no writes,
/// and the reason out of the first `poll`.
pub fn failed(reason: String) -> Socket {
  Ending(Some(Failed(reason)))
}

/// Write one text frame. A socket whose write failed comes back ending, so
/// `live` says whether it went out and the next `poll` says why it did not.
pub fn send_text(socket: Socket, text: String) -> Socket {
  case socket {
    Dialled(live) | Reading(live) ->
      wrote(socket, live, erlang.send_text(live, text, mask()))
    Ending(_) | Done -> socket
  }
}

/// Write one binary frame. Answers like `send_text`.
pub fn send_bytes(socket: Socket, bytes: BitArray) -> Socket {
  case socket {
    Dialled(live) | Reading(live) ->
      wrote(socket, live, erlang.send_bytes(live, bytes, mask()))
    Ending(_) | Done -> socket
  }
}

/// Start closing: the frame goes out and the transport comes down, so carry
/// the socket this hands back. It refuses every write and owes exactly one
/// `Closed(1006, "")`, which a later `poll` reports.
///
/// The reason is cut to 123 bytes. Closing a socket that is already ending or
/// finished leaves it alone.
pub fn close(socket: Socket, code: CloseCode, reason: String) -> Socket {
  case socket {
    Dialled(live) | Reading(live) -> {
      erlang.close(live, code.number, reason, mask())
      Ending(None)
    }
    Ending(_) | Done -> socket
  }
}

/// Abandon the socket, with no close frame. For a peer that has already gone
/// or a socket that was never up. It owes the same one `Closed` `close` does,
/// so nothing is lost by a caller that counts them.
pub fn drop(socket: Socket) -> Socket {
  case socket {
    Dialled(live) | Reading(live) -> {
      erlang.drop(live)
      Ending(None)
    }
    Ending(_) | Done -> socket
  }
}

/// Whether a write would be attempted. False from the moment the socket starts
/// ending, which is one `poll` before `finished` can be true.
pub fn live(socket: Socket) -> Bool {
  case socket {
    Dialled(_) | Reading(_) -> True
    Ending(_) | Done -> False
  }
}

/// Whether `Closed` has been reported and there is nothing left to do.
pub fn finished(socket: Socket) -> Bool {
  case socket {
    Done -> True
    Dialled(_) | Reading(_) | Ending(_) -> False
  }
}

/// Read for up to `timeout` milliseconds and hand what came of it to `report`.
///
/// Stop once `finished` says so: a finished socket returns at once, so a loop
/// that keeps going spins. The timeout bounds the whole read, so a peer that
/// sends bytes without finishing a message cannot stretch it.
pub fn turn(
  socket: Socket,
  timeout timeout: Int,
  report report: fn(Event) -> Nil,
) -> Socket {
  let #(socket, events) = poll(socket, timeout:)
  list.each(events, report)
  socket
}

/// `turn` with the events handed back instead of reported.
pub fn poll(socket: Socket, timeout timeout: Int) -> #(Socket, List(Event)) {
  case socket {
    Done -> #(socket, [])

    Ending(trouble) -> ended(1006, "", owed(trouble))

    Dialled(live) -> #(Reading(live), [Opened])

    Reading(live) -> read(live, timeout)
  }
}

fn read(live: erlang.Socket, timeout: Int) -> #(Socket, List(Event)) {
  case erlang.receive(live, timeout) {
    erlang.Silent(live) -> #(Reading(live), [])

    // The peer went away without a close frame, which is what 1006 is for.
    // `Dropped` has already torn the transport down.
    erlang.Dropped(erlang.Closed) -> ended(1006, "", [])

    erlang.Dropped(error) ->
      ended(1006, "", [Failed(erlang.error_to_string(error))])

    erlang.Arrived(live, message) ->
      case message {
        frame.TextMessage(text) -> #(Reading(live), [TextMessage(text:)])

        frame.BinaryMessage(bytes) -> #(Reading(live), [BinaryMessage(bytes:)])

        // Answered here, never reported. RFC 6455 wants the payload unchanged.
        // A pong that will not go out ends the socket like any other failed
        // write, so the reason is the write's and not the next read's.
        frame.PingMessage(payload) -> {
          let sent = erlang.send_pong(live, payload, mask())
          #(wrote(Reading(live), live, sent), [])
        }

        // Nothing here sends a ping, so any pong is the peer's business.
        frame.PongMessage(_) -> #(Reading(live), [])

        frame.CloseMessage(body) -> closing(live, body)
      }
  }
}

/// Always answers 1000 unless we are the one objecting: a code the peer chose
/// is not always one a client may send back.
fn closing(
  live: erlang.Socket,
  body: frame.CloseBody,
) -> #(Socket, List(Event)) {
  case body {
    frame.CloseCode(code:, reason:) -> {
      erlang.close(live, 1000, "", mask())
      ended(code, reason, [])
    }

    frame.NoCloseCode -> {
      erlang.close(live, 1000, "", mask())
      ended(1005, "", [])
    }

    // RFC 6455 calls a non-UTF-8 reason a protocol error, so the answer is
    // 1002. The code beside it read fine, and it is the part a caller acts on,
    // so it is reported rather than thrown away with the reason.
    frame.UnreadableReason(code) -> {
      erlang.close(live, 1002, "", mask())
      ended(code, "", [Failed("close reason is not utf-8")])
    }

    // Too few bytes for a code, which RFC 6455 also calls a protocol error.
    frame.TruncatedCloseBody -> {
      erlang.close(live, 1002, "", mask())
      ended(1006, "", [Failed("close frame carries no readable code")])
    }
  }
}

fn ended(
  code: Int,
  reason: String,
  before: List(Event),
) -> #(Socket, List(Event)) {
  #(Done, list.append(before, [Closed(code:, reason:)]))
}

/// The ending's own event goes out ahead of the `Closed` when there is one.
fn owed(trouble: Option(Event)) -> List(Event) {
  case trouble {
    Some(event) -> [event]
    None -> []
  }
}

/// A write that fails leaves nothing to read, so the transport goes down here
/// rather than at the next read timeout, and the reason waits for `poll`. A
/// write that went out leaves the socket as it was, `Opened` still owed if it
/// was owed.
fn wrote(
  socket: Socket,
  live: erlang.Socket,
  sent: Result(Nil, erlang.Error),
) -> Socket {
  case sent {
    Ok(Nil) -> socket
    Error(error) -> {
      erlang.drop(live)
      Ending(Some(Failed(erlang.error_to_string(error))))
    }
  }
}

/// Four unpredictable bytes, read as one number: matching `<<a, b, c, d>>`
/// needs a `let assert`, and a mask is not worth crashing a bot over.
fn mask() -> frame.Mask {
  let drawn = decode_unsigned(strong_rand_bytes(4))
  frame.Mask(
    a: drawn / 16_777_216,
    b: drawn / 65_536 % 256,
    c: drawn / 256 % 256,
    d: drawn % 256,
  )
}

@external(erlang, "crypto", "strong_rand_bytes")
fn strong_rand_bytes(count: Int) -> BitArray

@external(erlang, "binary", "decode_unsigned")
fn decode_unsigned(bytes: BitArray) -> Int
