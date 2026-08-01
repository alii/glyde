import gleam/bit_array
import gleam/list
import glyde/gateway/reassembly

/// Only the terminator has to be real. No prefix of this ends with it, so the
/// only complete payload it can produce is the whole thing.
const message = <<0x78, 0x9C, 0xAA, 0x56, 0x4A, 0xCE, 0x00, 0x00, 0xFF, 0xFF>>

/// Far above anything these tests feed.
const cap = 1024

/// Feed messages the way the shard does: carry the buffer a `Partial` hands
/// back into the next message, and start from empty after any other outcome.
/// Each row is one whole `Intake`, so the buffer the caller now holds is
/// asserted along with what completed.
fn drive(max_bytes: Int, messages: List(BitArray)) -> List(reassembly.Intake) {
  drive_loop(reassembly.empty, max_bytes, messages, [])
}

fn drive_loop(
  buffer: BitArray,
  max_bytes: Int,
  messages: List(BitArray),
  acc: List(reassembly.Intake),
) -> List(reassembly.Intake) {
  case messages {
    [] -> list.reverse(acc)
    [message, ..rest] -> {
      let taken = reassembly.feed(buffer, message:, max_bytes:)
      let next = case taken {
        reassembly.Partial(held) -> held
        reassembly.Payload(_) | reassembly.Overflow(_) -> reassembly.empty
      }
      drive_loop(next, max_bytes, rest, [taken, ..acc])
    }
  }
}

fn payloads(taken: List(reassembly.Intake)) -> List(BitArray) {
  list.filter_map(taken, fn(row) {
    case row {
      reassembly.Payload(bytes) -> Ok(bytes)
      _ -> Error(Nil)
    }
  })
}

fn joined(parts: List(BitArray)) -> BitArray {
  bit_array.concat(parts)
}

/// 0 up to and including `last`.
fn offsets(last: Int) -> List(Int) {
  offsets_loop(last, [])
}

fn offsets_loop(n: Int, acc: List(Int)) -> List(Int) {
  case n < 0 {
    True -> acc
    False -> offsets_loop(n - 1, [n, ..acc])
  }
}

/// Fewer than four bytes can never carry the terminator, and the four bytes
/// only count at the very end.
fn suffix_table() -> List(#(BitArray, Bool)) {
  [
    #(<<>>, False),
    #(<<0xFF>>, False),
    #(<<0xFF, 0xFF>>, False),
    #(<<0x00, 0xFF, 0xFF>>, False),
    #(<<0x00, 0x00, 0xFF>>, False),
    #(<<0x00, 0x00, 0xFF, 0xFF>>, True),
    #(<<0x09, 0x00, 0x00, 0xFF, 0xFF>>, True),
    #(<<0x00, 0x00, 0x00, 0xFF, 0xFF>>, True),
    #(<<0x00, 0x00, 0xFF, 0xFF, 0x09>>, False),
    #(<<0xFF, 0xFF, 0x00, 0x00>>, False),
    #(<<0x00, 0x00, 0xFF, 0x00>>, False),
  ]
}

pub fn ends_with_sync_table_test() {
  list.each(suffix_table(), fn(row) {
    let #(bytes, expected) = row
    assert reassembly.ends_with_sync(bytes) == expected
  })
}

pub fn sync_suffix_is_four_bytes_test() {
  assert bit_array.byte_size(reassembly.sync_suffix) == 4
  assert reassembly.ends_with_sync(reassembly.sync_suffix)
}

pub fn empty_buffer_holds_nothing_test() {
  assert bit_array.byte_size(reassembly.empty) == 0
}

/// The last four bytes are the whole of the completion decision: reading a
/// zlib stream without the terminator rule buffers forever.
pub fn completion_comes_from_the_terminator_test() {
  let terminated = <<0x01, 0x00, 0x00, 0xFF, 0xFF>>
  let open = <<0x01, 0x02>>

  let outcome = fn(message) {
    reassembly.feed(reassembly.empty, message:, max_bytes: cap)
  }

  assert outcome(terminated) == reassembly.Payload(terminated)
  assert outcome(open) == reassembly.Partial(open)
  assert outcome(<<>>) == reassembly.Partial(<<>>)
}

/// One payload over three messages, with the terminator at the end of the
/// third.
pub fn three_messages_complete_on_the_last_test() {
  let one = <<0x78, 0x9C, 0xAA>>
  let two = <<0x56, 0x4A, 0xCE>>
  let three = <<0x03, 0x00, 0x00, 0xFF, 0xFF>>

  assert drive(cap, [one, two, three])
    == [
      reassembly.Partial(one),
      reassembly.Partial(joined([one, two])),
      reassembly.Payload(joined([one, two, three])),
    ]
}

/// Split at every byte offset. A break that leaves the terminator whole in the
/// last message completes; one inside it does not.
pub fn split_at_every_offset_test() {
  let size = bit_array.byte_size(message)

  list.each(offsets(size), fn(at) {
    let assert Ok(head) = bit_array.slice(message, 0, at)
    let assert Ok(tail) = bit_array.slice(message, at, size - at)

    // Breaking at `size` leaves an empty tail, so the head carried the
    // terminator.
    let terminator_is_whole = at <= size - 4 || at == size

    let taken = drive(cap, [head, tail])
    case terminator_is_whole {
      True -> {
        assert payloads(taken) == [message]
      }
      False -> {
        assert payloads(taken) == []
      }
    }
  })
}

pub fn one_message_is_one_payload_test() {
  assert drive(cap, [message]) == [reassembly.Payload(message)]
}

/// Back to back payloads on the same connection. `Payload` carries no buffer,
/// so the second payload cannot carry any of the first.
pub fn payloads_in_sequence_test() {
  let head = <<0x01, 0x02>>
  let tail = <<0x03, 0x00, 0x00, 0xFF, 0xFF>>

  assert drive(cap, [message, head, tail])
    == [
      reassembly.Payload(message),
      reassembly.Partial(head),
      reassembly.Payload(joined([head, tail])),
    ]
}

/// The terminator only terminates at the end. Compressed data may contain
/// those four bytes anywhere.
pub fn terminator_in_the_middle_is_not_the_end_test() {
  let held = <<0x01, 0x00, 0x00, 0xFF, 0xFF, 0x02>>

  assert drive(cap, [held]) == [reassembly.Partial(held)]
}

/// Completion is judged on the arriving message: the terminator bytes are an
/// empty stored deflate block, so flushing early poisons the codec silently.
pub fn a_split_terminator_does_not_complete_test() {
  let one = <<0x01, 0x00, 0x00, 0xFF>>
  let two = <<0xFF>>

  assert drive(cap, [one, two])
    == [reassembly.Partial(one), reassembly.Partial(joined([one, two]))]
}

/// An internal terminator at the end of the buffer: judged on the buffer this
/// flushes a truncated payload.
pub fn an_internal_terminator_at_a_message_boundary_does_not_flush_test() {
  let one = <<0x78, 0x9C, 0x00, 0x00, 0xFF, 0xFF>>
  let two = <<0xAA>>
  let three = <<0x56, 0x00, 0x00, 0xFF, 0xFF>>

  // The second message carries the byte that would have been mistaken for the
  // end of another payload.
  assert drive(cap, [one, two, three])
    == [
      reassembly.Payload(one),
      reassembly.Partial(two),
      reassembly.Payload(joined([two, three])),
    ]
}

/// An empty message changes nothing and must not be mistaken for a payload.
pub fn empty_message_keeps_the_buffer_test() {
  let one = <<0x01, 0x02>>

  assert drive(cap, [one, <<>>])
    == [reassembly.Partial(one), reassembly.Partial(one)]
}

/// A gateway that stops sending the terminator must not grow the buffer
/// forever. Overflow is a state the caller acts on, not a crash.
pub fn buffer_past_the_bound_overflows_test() {
  let four = <<0x01, 0x02, 0x03, 0x04>>

  assert drive(6, [four, four])
    == [reassembly.Partial(four), reassembly.Overflow(8)]
}

/// Exactly at the bound is still inside it.
pub fn the_bound_is_exclusive_test() {
  let four = <<0x01, 0x02, 0x03, 0x04>>

  assert drive(8, [four, four])
    == [reassembly.Partial(four), reassembly.Partial(joined([four, four]))]
}

/// The bound exists to stop a partial buffer growing forever, so it never
/// refuses bytes that are already a whole payload. Tearing the connection down
/// with the payload in hand costs a session for nothing.
pub fn a_complete_payload_over_the_bound_is_delivered_test() {
  assert drive(4, [message]) == [reassembly.Payload(message)]
}

/// Same rule when the payload completes across messages: the message that
/// carries the terminator is never measured, only ones that would be held.
pub fn a_terminating_message_past_the_bound_is_delivered_test() {
  let head = <<0x01, 0x02, 0x03, 0x04>>
  let tail = <<0x05, 0x00, 0x00, 0xFF, 0xFF>>

  assert drive(5, [head, tail])
    == [reassembly.Partial(head), reassembly.Payload(joined([head, tail]))]
}

/// The bytes only mean anything to the inflate context that was reading them.
pub fn overflow_starts_over_test() {
  let big = <<0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B>>

  assert drive(10, [big, message])
    == [reassembly.Overflow(11), reassembly.Payload(message)]
}

pub fn a_zero_bound_overflows_on_the_first_byte_test() {
  assert drive(0, [<<0x01>>]) == [reassembly.Overflow(1)]
}

/// A half message is not decodable by the next connection's inflate context,
/// so it goes with the context, on a resume as much as on an identify.
pub fn reset_drops_a_stranded_half_message_test() {
  let stranded = <<0xDE, 0xAD>>
  assert reassembly.feed(reassembly.empty, message: stranded, max_bytes: cap)
    == reassembly.Partial(stranded)

  assert reassembly.feed(reassembly.empty, message:, max_bytes: cap)
    == reassembly.Payload(message)
}
