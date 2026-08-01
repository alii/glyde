//// Where one zlib-stream payload ends and the next begins: the buffer, the
//// terminator, the bound and the reset. The inflate itself belongs to the
//// adapter.
////
//// Stateless. The buffer is a `BitArray` the caller carries and hands back,
//// and the one outcome that still holds bytes is the only one carrying any. A
//// caller cannot keep a stale buffer beside a finished payload, because there
//// is nowhere to keep it.

import gleam/bit_array

/// What taking in one binary WebSocket message produced.
pub type Intake {
  /// Not a whole payload yet. `buffer` is what to hold until the next message.
  /// Still proof of life: counting only complete payloads makes a big
  /// `GUILD_CREATE` a zombie.
  Partial(buffer: BitArray)

  /// One complete payload, ready for the inflater. Nothing is held over.
  Payload(bytes: BitArray)

  /// Holding this message would have taken the buffer past `max_bytes` with no
  /// complete payload in it. The bytes are gone: they mean nothing without the
  /// inflate context.
  Overflow(bytes: Int)
}

/// What `Z_SYNC_FLUSH` leaves at the end of every zlib-stream payload.
/// Discord's own example checks exactly these four bytes.
pub const sync_suffix: BitArray = <<0x00, 0x00, 0xFF, 0xFF>>

/// The buffer a connection starts with. Cleared on every new connection,
/// resume included: leftovers will not decode against a fresh zlib context.
pub const empty: BitArray = <<>>

/// Take one whole binary WebSocket message and say what it completed.
///
/// `message` must be a reassembled message, not an RFC 6455 frame. Discord
/// ends a payload on a message boundary, so a caller that fed frames would
/// flush a truncated payload the first time one was split.
///
/// `max_bytes` bounds only what is held over between messages, so a payload
/// that is complete on arrival is delivered however large it is. Bounding a
/// single message is the transport's job. Discord publishes no size; this one
/// is ours.
pub fn feed(
  buffer: BitArray,
  message message: BitArray,
  max_bytes max_bytes: Int,
) -> Intake {
  // Only the arriving message can end a payload. The terminator bytes also
  // occur inside compressed data, which is why the bytes held are never the
  // ones tested.
  case ends_with_sync(message) {
    True -> Payload(bit_array.append(buffer, message))
    False -> {
      // Add the sizes rather than the bytes: building the oversized buffer to
      // then refuse it is the allocation the bound exists to prevent.
      let size = bit_array.byte_size(buffer) + bit_array.byte_size(message)
      case size > max_bytes {
        True -> Overflow(size)
        False -> Partial(bit_array.append(buffer, message))
      }
    }
  }
}

/// Whether these bytes end with the zlib-stream terminator. The backwards
/// slice handles fewer than four bytes with no size arithmetic.
pub fn ends_with_sync(bytes: BitArray) -> Bool {
  bit_array.slice(bytes, bit_array.byte_size(bytes), -4) == Ok(sync_suffix)
}
