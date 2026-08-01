import gleam/bit_array
import gleam/int
import gleam/list
import glyde/websocket/frame
import glyde/websocket/stream

/// Room enough that nothing here trips the cap by accident: the widest
/// payload below is 120 KB. The tests that want the cap set their own.
const room: Int = 1_000_000

/// One unmasked frame in the shortest length form that fits.
fn server_frame(fin: Bool, opcode: Int, payload: BitArray) -> BitArray {
  let size = bit_array.byte_size(payload)
  let first = case fin {
    True -> 0x80 + opcode
    False -> opcode
  }
  let e = { size / 16_777_216 } % 256
  let f = { size / 65_536 } % 256
  let g = { size / 256 } % 256
  let h = size % 256
  let head = case size < 126, size < 65_536 {
    True, _ -> <<first, size>>
    _, True -> <<first, 126, g, h>>
    _, _ -> <<first, 127, 0, 0, 0, 0, e, f, g, h>>
  }
  bit_array.append(head, payload)
}

fn text_frame(fin: Bool, body: String) -> BitArray {
  server_frame(fin, 1, bit_array.from_string(body))
}

fn continuation(fin: Bool, body: String) -> BitArray {
  server_frame(fin, 0, bit_array.from_string(body))
}

/// Every message a stream gives up without reading more, and where it stops.
fn drain(stream: stream.Stream) -> #(List(frame.Message), stream.Next) {
  drain_loop(stream, [])
}

fn drain_loop(
  stream: stream.Stream,
  acc: List(frame.Message),
) -> #(List(frame.Message), stream.Next) {
  case stream.next(stream) {
    stream.Ready(message:, stream:) -> drain_loop(stream, [message, ..acc])
    other -> #(list.reverse(acc), other)
  }
}

fn messages(bytes: BitArray) -> List(frame.Message) {
  let #(messages, _) = drain(stream.new(bytes, room))
  messages
}

// The easy cases

pub fn new_starts_from_the_handshake_leftovers_test() {
  assert stream.new(<<1, 2, 3>>, room)
    == stream.Stream(buffer: <<1, 2, 3>>, assembly: frame.Idle, max_bytes: room)
}

pub fn one_frame_is_one_message_test() {
  assert messages(text_frame(True, "hello")) == [frame.TextMessage("hello")]
}

pub fn an_empty_stream_waits_test() {
  assert stream.next(stream.new(<<>>, room))
    == stream.Waiting(stream.new(<<>>, room))
}

/// A read regularly lands more than one frame.
pub fn one_read_can_hold_several_messages_test() {
  let bytes =
    bit_array.concat([
      text_frame(True, "one"),
      server_frame(True, 9, <<>>),
      text_frame(True, "two"),
    ])

  assert messages(bytes)
    == [
      frame.TextMessage("one"),
      frame.PingMessage(<<>>),
      frame.TextMessage("two"),
    ]
}

pub fn leftover_bytes_stay_in_the_buffer_test() {
  let bytes = bit_array.append(text_frame(True, "hi"), <<0x81, 0x05>>)

  let assert stream.Ready(message:, stream:) =
    stream.next(stream.new(bytes, room))
  assert message == frame.TextMessage("hi")
  assert stream
    == stream.Stream(
      buffer: <<0x81, 0x05>>,
      assembly: frame.Idle,
      max_bytes: room,
    )
}

// Bytes arriving in pieces

/// No prefix of a frame may produce a message early.
pub fn a_frame_split_anywhere_still_arrives_test() {
  let bytes = text_frame(True, "split me")
  let size = bit_array.byte_size(bytes)

  list.each(counting(size), fn(at) {
    let assert Ok(head) = bit_array.slice(bytes, 0, at)
    let assert Ok(tail) = bit_array.slice(bytes, at, size - at)

    let started = stream.new(head, room)
    case at == size {
      True -> Nil
      False -> {
        let assert stream.Waiting(_) = stream.next(started)
        Nil
      }
    }

    let assert stream.Ready(message:, ..) =
      stream.next(stream.feed(started, tail))
    assert message == frame.TextMessage("split me")
  })
}

fn counting(last: Int) -> List(Int) {
  case last < 0 {
    True -> []
    False -> [last, ..counting(last - 1)]
  }
}

pub fn feed_appends_to_what_is_already_held_test() {
  let stream =
    stream.new(<<1>>, room) |> stream.feed(<<2>>) |> stream.feed(<<3, 4>>)

  assert stream
    == stream.Stream(
      buffer: <<1, 2, 3, 4>>,
      assembly: frame.Idle,
      max_bytes: room,
    )
}

// Fragmented messages

pub fn fragments_become_one_message_test() {
  let bytes =
    bit_array.concat([
      text_frame(False, "one "),
      continuation(False, "two "),
      continuation(True, "three"),
    ])

  assert messages(bytes) == [frame.TextMessage("one two three")]
}

/// A ping between two fragments must leave the half-built message alone.
pub fn a_control_frame_between_fragments_does_not_disturb_it_test() {
  let bytes =
    bit_array.concat([
      text_frame(False, "half "),
      server_frame(True, 9, <<0x70, 0x69>>),
      continuation(True, "done"),
    ])

  assert messages(bytes)
    == [frame.PingMessage(<<0x70, 0x69>>), frame.TextMessage("half done")]
}

/// A caller that drops the returned stream loses the held fragment.
pub fn a_held_fragment_leaves_the_buffer_test() {
  let assert stream.Waiting(stream) =
    stream.next(stream.new(text_frame(False, "held"), room))

  assert stream
    == stream.Stream(
      buffer: <<>>,
      assembly: frame.Fragmented(text: True, payload: <<"held":utf8>>),
      max_bytes: room,
    )
}

/// A per-fragment UTF-8 check would reject a codepoint split across frames.
pub fn a_codepoint_may_straddle_two_fragments_test() {
  let bytes =
    bit_array.concat([
      server_frame(False, 1, <<0xE2, 0x82>>),
      server_frame(True, 0, <<0xAC>>),
    ])

  assert messages(bytes) == [frame.TextMessage("€")]
}

// Failures

pub fn a_reserved_bit_fails_the_stream_test() {
  assert stream.next(stream.new(<<0xC1, 0x00>>, room))
    == stream.Failed(frame.ReservedBitsSet)
}

pub fn a_masked_inbound_frame_fails_the_stream_test() {
  assert stream.next(stream.new(<<0x81, 0x80, 0, 0, 0, 0>>, room))
    == stream.Failed(frame.InboundFrameMasked)
}

pub fn a_continuation_with_nothing_to_continue_fails_test() {
  assert stream.next(stream.new(continuation(True, "orphan"), room))
    == stream.Failed(frame.ContinuationWithNoMessage)
}

pub fn a_new_message_before_the_last_one_finished_fails_test() {
  let bytes =
    bit_array.concat([text_frame(False, "one"), text_frame(True, "two")])

  let #(messages, next) = drain(stream.new(bytes, room))
  assert messages == []
  assert next == stream.Failed(frame.MessageBeforeLastFinished(frame.Text))
}

pub fn text_that_is_not_utf8_fails_test() {
  assert stream.next(stream.new(server_frame(True, 1, <<0xFF>>), room))
    == stream.Failed(frame.TextNotUtf8)
}

pub fn messages_already_read_survive_a_later_failure_test() {
  let bytes = bit_array.append(text_frame(True, "good"), <<0xC1, 0x00>>)

  let #(messages, next) = drain(stream.new(bytes, room))
  assert messages == [frame.TextMessage("good")]
  assert next == stream.Failed(frame.ReservedBitsSet)
}

// Counting what is held

pub fn buffered_counts_unparsed_bytes_test() {
  assert stream.buffered(stream.new(<<>>, room)) == 0
  assert stream.buffered(stream.new(<<1, 2, 3>>, room)) == 3
}

/// A caller capping a fragmenting peer has to see both halves.
pub fn buffered_counts_held_fragments_test() {
  let assert stream.Waiting(stream) =
    stream.next(stream.new(text_frame(False, "12345"), room))

  assert stream.buffered(stream) == 5
  assert stream.buffered(stream.feed(stream, <<0, 0>>)) == 7
}

// Fragmenting servers are rare, so this path gets the most pressure: any
// number of frames, control frames between them, no boundary matching a read.

/// `n` bytes of a repeating pattern, so a fragment stitched back out of order
/// changes the result. Printable ASCII, so it serves text and binary alike.
fn marked(n: Int) -> BitArray {
  marked_loop(n, 0, [])
}

fn marked_loop(left: Int, i: Int, acc: List(BitArray)) -> BitArray {
  case left <= 0 {
    True -> bit_array.concat(list.reverse(acc))
    False -> {
      let chunk = bit_array.from_string(int.to_string(i) <> "-abcdefghij|")
      let take = int.min(left, bit_array.byte_size(chunk))
      let assert Ok(chunk) = bit_array.slice(chunk, 0, take)
      marked_loop(left - take, i + 1, [chunk, ..acc])
    }
  }
}

/// `payload` cut into `pieces` frames: one opener carrying the opcode, then
/// continuations, with FIN only on the last.
fn fragmented(opcode: Int, payload: BitArray, pieces: Int) -> List(BitArray) {
  let size = bit_array.byte_size(payload)
  let each = int.max(1, size / pieces)
  cut(opcode, payload, each, 0, size, [])
}

fn cut(
  opcode: Int,
  payload: BitArray,
  each: Int,
  at: Int,
  size: Int,
  acc: List(BitArray),
) -> List(BitArray) {
  let left = size - at
  let take = int.min(each, left)
  let last = at + take >= size
  let assert Ok(piece) = bit_array.slice(payload, at, take)
  let code = case acc {
    [] -> opcode
    _ -> 0
  }
  let frame = server_frame(last, code, piece)
  case last {
    True -> list.reverse([frame, ..acc])
    False -> cut(opcode, payload, each, at + take, size, [frame, ..acc])
  }
}

pub fn a_long_fragment_chain_assembles_in_order_test() {
  let payload = marked(4096)
  let bytes = bit_array.concat(fragmented(2, payload, 256))

  assert messages(bytes) == [frame.BinaryMessage(payload)]
}

/// Fixed size reads that never line up with a frame boundary.
pub fn a_fragment_chain_survives_reads_that_straddle_frames_test() {
  let payload = marked(4096)
  let bytes = bit_array.concat(fragmented(1, payload, 128))
  let assert Ok(text) = bit_array.to_string(payload)

  list.each([1, 2, 3, 7, 13, 64, 97, 512, 4099], fn(read) {
    assert dribble(bytes, read) == [frame.TextMessage(text)]
  })
}

/// Feed `bytes` in `read` sized pieces, draining after each.
fn dribble(bytes: BitArray, read: Int) -> List(frame.Message) {
  dribble_loop(bytes, read, 0, stream.new(<<>>, room), [])
}

fn dribble_loop(
  bytes: BitArray,
  read: Int,
  at: Int,
  held: stream.Stream,
  acc: List(frame.Message),
) -> List(frame.Message) {
  let size = bit_array.byte_size(bytes)
  case at >= size {
    True -> {
      let #(last, next) = drain(held)
      let assert stream.Waiting(_) = next
      list.append(list.reverse(acc), last)
    }
    False -> {
      let take = int.min(read, size - at)
      let assert Ok(piece) = bit_array.slice(bytes, at, take)
      let #(found, next) = drain(stream.feed(held, piece))
      let assert stream.Waiting(held) = next
      dribble_loop(
        bytes,
        read,
        at + take,
        held,
        list.fold(found, acc, fn(acc, message) { [message, ..acc] }),
      )
    }
  }
}

/// A ping between every pair of fragments, each delivered on its own and in
/// order, with the message underneath still whole.
pub fn control_frames_between_every_fragment_test() {
  let payload = marked(600)
  let pieces = fragmented(1, payload, 20)
  let assert Ok(text) = bit_array.to_string(payload)

  let bytes =
    bit_array.concat(
      list.index_map(pieces, fn(piece, i) {
        bit_array.append(piece, server_frame(True, 9, <<i>>))
      }),
    )

  let found = messages(bytes)
  let pings =
    list.filter(found, fn(message) {
      case message {
        frame.PingMessage(_) -> True
        _ -> False
      }
    })
  let texts =
    list.filter(found, fn(message) {
      case message {
        frame.TextMessage(_) -> True
        _ -> False
      }
    })

  assert list.length(pings) == list.length(pieces)
  assert texts == [frame.TextMessage(text)]
  // The message lands on its last fragment, so one ping follows it.
  let assert Ok(last) = list.last(found)
  let assert frame.PingMessage(_) = last
}

/// A zero length continuation must not end the message or add a byte.
pub fn an_empty_fragment_changes_nothing_test() {
  let bytes =
    bit_array.concat([
      server_frame(False, 1, <<"one":utf8>>),
      server_frame(False, 0, <<>>),
      server_frame(False, 0, <<" two":utf8>>),
      server_frame(True, 0, <<>>),
    ])

  assert messages(bytes) == [frame.TextMessage("one two")]
}

// Length forms, through the stream rather than the codec

/// 60000 bytes needs the 16 bit length form and 70000 needs the 64 bit one.
/// Both are sizes a real gateway sends.
pub fn the_wide_length_forms_carry_a_whole_message_test() {
  list.each([126, 65_535, 65_536, 70_000], fn(size) {
    let payload = marked(size)
    assert messages(server_frame(True, 2, payload))
      == [frame.BinaryMessage(payload)]
  })
}

pub fn a_wide_frame_arrives_across_many_reads_test() {
  let payload = marked(70_000)
  let bytes = server_frame(True, 2, payload)

  assert dribble(bytes, 1024) == [frame.BinaryMessage(payload)]
}

/// A chain whose pieces each need the 16 bit length form.
pub fn wide_fragments_assemble_test() {
  let payload = marked(120_000)
  let bytes = bit_array.concat(fragmented(2, payload, 3))

  assert messages(bytes) == [frame.BinaryMessage(payload)]
  assert dribble(bytes, 7000) == [frame.BinaryMessage(payload)]
}

/// The frame that finishes a message hands all of it over and leaves nothing.
pub fn buffered_grows_with_a_fragment_chain_test() {
  let payload = marked(1000)
  let size = bit_array.byte_size(payload)
  let assert [last, ..reversed] = list.reverse(fragmented(2, payload, 10))
  let opening = list.reverse(reversed)

  let #(held, counts) =
    list.fold(opening, #(stream.new(<<>>, room), []), fn(state, piece) {
      let #(held, counts) = state
      let assert stream.Waiting(held) = stream.next(stream.feed(held, piece))
      #(held, [stream.buffered(held), ..counts])
    })

  let counts = list.reverse(counts)
  assert list.length(counts) == list.length(opening)
  assert counts == list.sort(counts, int.compare)
  let assert Ok(most) = list.last(counts)
  assert most < size

  let assert stream.Ready(message:, stream: done) =
    stream.next(stream.feed(held, last))
  assert message == frame.BinaryMessage(payload)
  assert stream.buffered(done) == 0
  assert done.assembly == frame.Idle
}

// The cap

/// A peer that never sets FIN grows the assembly rather than the buffer, so
/// the cap has to count both or it never fires.
pub fn a_fragment_chain_past_the_cap_overflows_test() {
  let assert [opener, ..rest] = fragmented(1, marked(300), 10)

  let outcome =
    list.fold(rest, stream.next(stream.new(opener, 100)), fn(next, piece) {
      case next {
        stream.Waiting(held) -> stream.next(stream.feed(held, piece))
        other -> other
      }
    })

  let assert stream.Overflowed(held) = outcome
  assert held > 100
}

/// The same chain with room for it, so the cap is what made the difference.
pub fn the_same_chain_under_the_cap_still_arrives_test() {
  let payload = marked(300)
  let assert Ok(text) = bit_array.to_string(payload)

  assert messages(bit_array.concat(fragmented(1, payload, 10)))
    == [frame.TextMessage(text)]
}

/// Bytes that never became a frame count too: a peer can sit on a half frame
/// as easily as on a half message.
pub fn unparsed_bytes_count_towards_the_cap_test() {
  assert stream.next(stream.new(<<1, 2, 3>>, 3))
    == stream.Waiting(stream.new(<<1, 2, 3>>, 3))

  assert stream.next(stream.new(<<1, 2, 3>>, 2)) == stream.Overflowed(3)
}

/// The cap is on bytes that cannot become a message, not on bytes held. Two
/// reads before a drain is ordinary use, and both messages are deliverable.
pub fn whole_messages_over_the_cap_still_arrive_test() {
  let assert Ok(text) = bit_array.to_string(marked(200))
  let bytes = text_frame(True, text)

  let held = stream.feed(stream.new(bytes, 300), bytes)
  assert stream.buffered(held) > 300

  let #(messages, next) = drain(held)
  assert messages == [frame.TextMessage(text), frame.TextMessage(text)]
  assert next == stream.Waiting(stream.new(<<>>, 300))
}

/// Delivering first does not drop the bound: the leftovers are measured once
/// nothing more can come out of them.
pub fn the_cap_fires_on_what_is_left_after_the_messages_test() {
  let assert Ok(text) = bit_array.to_string(marked(200))
  // A binary frame head declaring 256 bytes, with none of them.
  let bytes = bit_array.append(text_frame(True, text), <<0x82, 126, 1, 0>>)

  let #(messages, next) = drain(stream.new(bytes, 3))
  assert messages == [frame.TextMessage(text)]
  assert next == stream.Overflowed(4)
}
