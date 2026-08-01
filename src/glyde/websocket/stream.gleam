//// The loop around `frame`: a socket read lands whatever bytes arrived, which
//// may be half a frame, four frames, or one whose message needs three more
//// reads. This holds the leftovers and the half-built message together.

import gleam/bit_array
import gleam/bool
import glyde/websocket/frame

/// Bytes waiting to be read, and the message being put back together.
/// `max_bytes` lives in here so it cannot drift between calls.
pub type Stream {
  Stream(buffer: BitArray, assembly: frame.Assembly, max_bytes: Int)
}

/// Start from whatever followed the handshake: a server may put its first
/// frame in the same packet as the 101.
///
/// `max_bytes` bounds what one stream will hold with no whole message out of
/// it. Without a bound a peer that fragments forever grows the process until
/// the VM dies.
pub fn new(leftover: BitArray, max_bytes: Int) -> Stream {
  Stream(buffer: leftover, assembly: frame.Idle, max_bytes:)
}

pub fn feed(stream: Stream, bytes: BitArray) -> Stream {
  Stream(..stream, buffer: bit_array.append(stream.buffer, bytes))
}

pub type Next {
  /// Ask again before reading the socket: one read often lands several frames.
  Ready(message: frame.Message, stream: Stream)

  /// Nothing complete yet. Read more bytes and `feed` them.
  Waiting(stream: Stream)

  /// The stream is not RFC 6455 any more. The reason is `frame`'s, unrendered,
  /// so a caller can match it.
  Failed(reason: frame.Violation)

  /// The bytes held went past `max_bytes` without becoming a message. They are
  /// gone, and so is the stream: a peer that keeps fragmenting will not stop
  /// because the next read was refused.
  Overflowed(bytes: Int)
}

/// Take the next whole message out of the buffer. Even a `Waiting` hands back
/// a stream with absorbed fragments moved into the assembly; dropping it loses
/// them.
pub fn next(stream: Stream) -> Next {
  case frame.decode(stream.buffer) {
    // The bound is checked here alone, so bytes that are already messages get
    // delivered rather than refused. A peer that fragments forever still trips
    // it: every fragment absorbed comes back through here with nothing to
    // decode.
    frame.Incomplete -> {
      let held = buffered(stream)
      use <- bool.guard(held > stream.max_bytes, Overflowed(held))
      Waiting(stream)
    }
    frame.Invalid(reason) -> Failed(reason)
    frame.Complete(frame: one, rest:) ->
      case frame.take(stream.assembly, one) {
        frame.Broken(reason) -> Failed(reason)
        frame.Whole(message:, assembly:) ->
          Ready(message, Stream(..stream, buffer: rest, assembly:))
        frame.Held(assembly:) -> next(Stream(..stream, buffer: rest, assembly:))
      }
  }
}

/// Bytes held, unparsed plus half-assembled, which is what `max_bytes` bounds.
pub fn buffered(stream: Stream) -> Int {
  let held = case stream.assembly {
    frame.Idle -> 0
    frame.Fragmented(payload:, ..) -> bit_array.byte_size(payload)
  }
  bit_array.byte_size(stream.buffer) + held
}
