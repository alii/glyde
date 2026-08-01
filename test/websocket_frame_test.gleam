import gleam/bit_array
import gleam/list
import gleam/string
import glyde/websocket/frame

// Building frames the way a server would: never masked, shortest length form.

fn server_frame(fin: Bool, opcode: Int, payload: BitArray) -> BitArray {
  let size = bit_array.byte_size(payload)
  let first = case fin {
    True -> 0x80 + opcode
    False -> opcode
  }
  let head = case size < 126, size < 65_536 {
    True, _ -> <<first, size>>
    _, True -> {
      let hi = size / 256
      let lo = size % 256
      <<first, 126, hi, lo>>
    }
    _, _ -> {
      let e = size / 16_777_216 % 256
      let f = size / 65_536 % 256
      let g = size / 256 % 256
      let h = size % 256
      <<first, 127, 0, 0, 0, 0, e, f, g, h>>
    }
  }
  bit_array.append(head, payload)
}

/// `n` bytes of `a`, built by doubling so a 65536 byte payload does not cost
/// 65536 appends.
fn filler(n: Int) -> BitArray {
  case n <= 0 {
    True -> <<>>
    False -> {
      let half = filler(n / 2)
      case n % 2 {
        0 -> bit_array.concat([half, half])
        _ -> bit_array.concat([half, half, <<0x61>>])
      }
    }
  }
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

/// Every frame in a buffer, in order. `Incomplete` and `Invalid` stop the walk.
fn decode_all(bytes: BitArray) -> #(List(frame.Frame), frame.Decoded) {
  decode_all_loop(bytes, [])
}

fn decode_all_loop(
  bytes: BitArray,
  acc: List(frame.Frame),
) -> #(List(frame.Frame), frame.Decoded) {
  case frame.decode(bytes) {
    frame.Complete(frame:, rest:) -> decode_all_loop(rest, [frame, ..acc])
    other -> #(list.reverse(acc), other)
  }
}

/// Decode a buffer and run every frame through the assembler, the way a
/// connection does.
fn messages(bytes: BitArray) -> List(frame.Taken) {
  let #(frames, _) = decode_all(bytes)
  messages_loop(frames, frame.Idle, [])
}

fn messages_loop(
  frames: List(frame.Frame),
  assembly: frame.Assembly,
  acc: List(frame.Taken),
) -> List(frame.Taken) {
  case frames {
    [] -> list.reverse(acc)
    [next, ..rest] -> {
      let taken = frame.take(assembly, next)
      case taken {
        frame.Whole(assembly:, ..) | frame.Held(assembly:) ->
          messages_loop(rest, assembly, [taken, ..acc])
        frame.Broken(..) -> list.reverse([taken, ..acc])
      }
    }
  }
}

pub fn opcode_round_trip_test() {
  let table = [
    #(0, frame.Continuation),
    #(1, frame.Text),
    #(2, frame.Binary),
    #(3, frame.Reserved(3)),
    #(7, frame.Reserved(7)),
    #(8, frame.Close),
    #(9, frame.Ping),
    #(10, frame.Pong),
    #(11, frame.Reserved(11)),
    #(15, frame.Reserved(15)),
  ]

  list.each(table, fn(row) {
    let #(code, opcode) = row
    assert frame.opcode_from_int(code) == opcode
    assert frame.opcode_to_int(opcode) == code
  })
}

/// A control frame is one whose opcode has its top bit set, which is the rule
/// that decides what may appear between the fragments of a message.
pub fn is_control_test() {
  assert !frame.is_control(frame.Continuation)
  assert !frame.is_control(frame.Text)
  assert !frame.is_control(frame.Binary)
  assert !frame.is_control(frame.Reserved(3))
  assert !frame.is_control(frame.Reserved(7))

  assert frame.is_control(frame.Close)
  assert frame.is_control(frame.Ping)
  assert frame.is_control(frame.Pong)
  assert frame.is_control(frame.Reserved(11))
  assert frame.is_control(frame.Reserved(15))
}

pub fn nothing_is_incomplete_test() {
  assert frame.decode(<<>>) == frame.Incomplete
  assert frame.decode(<<0x81>>) == frame.Incomplete
}

pub fn a_text_frame_decodes_test() {
  assert frame.decode(<<0x81, 0x05, "hello":utf8>>)
    == frame.Complete(
      frame.Frame(fin: True, opcode: frame.Text, payload: <<"hello":utf8>>),
      <<>>,
    )
}

pub fn an_empty_payload_decodes_test() {
  assert frame.decode(<<0x8A, 0x00>>)
    == frame.Complete(
      frame.Frame(fin: True, opcode: frame.Pong, payload: <<>>),
      <<>>,
    )
}

pub fn a_frame_without_fin_decodes_test() {
  assert frame.decode(<<0x01, 0x02, "hi":utf8>>)
    == frame.Complete(
      frame.Frame(fin: False, opcode: frame.Text, payload: <<"hi":utf8>>),
      <<>>,
    )
}

/// A read lands whatever the socket had, which is often more than one frame.
/// The bytes after the frame come back so the next decode starts on them.
pub fn trailing_bytes_come_back_test() {
  let two =
    bit_array.concat([
      server_frame(True, 1, <<"one":utf8>>),
      server_frame(True, 1, <<"two":utf8>>),
      <<0x81>>,
    ])

  let #(frames, tail) = decode_all(two)
  assert frames
    == [
      frame.Frame(fin: True, opcode: frame.Text, payload: <<"one":utf8>>),
      frame.Frame(fin: True, opcode: frame.Text, payload: <<"two":utf8>>),
    ]
  assert tail == frame.Incomplete
}

/// Every prefix short of the whole frame says `Incomplete`, and the whole
/// thing decodes to the same frame however it was split.
pub fn split_at_every_offset_test() {
  let bytes = server_frame(True, 1, <<"hello there":utf8>>)
  let size = bit_array.byte_size(bytes)

  list.each(offsets(size - 1), fn(at) {
    let assert Ok(prefix) = bit_array.slice(bytes, 0, at)
    assert frame.decode(prefix) == frame.Incomplete
  })

  assert frame.decode(bytes)
    == frame.Complete(
      frame.Frame(fin: True, opcode: frame.Text, payload: <<"hello there":utf8>>),
      <<>>,
    )
}

/// A break inside a two or eight byte length must not be read as a length.
pub fn split_at_every_offset_of_an_extended_length_test() {
  list.each([200, 300], fn(size) {
    let bytes = server_frame(True, 2, filler(size))
    let total = bit_array.byte_size(bytes)

    list.each(offsets(total - 1), fn(at) {
      let assert Ok(prefix) = bit_array.slice(bytes, 0, at)
      assert frame.decode(prefix) == frame.Incomplete
    })

    assert frame.decode(bytes)
      == frame.Complete(
        frame.Frame(fin: True, opcode: frame.Binary, payload: filler(size)),
        <<>>,
      )
  })
}

/// 0 to 125 inclusive is the seven bit form, 126 escapes to sixteen bits and
/// 127 to sixty four. The boundaries are where an off by one hides.
pub fn every_length_form_test() {
  list.each([0, 1, 124, 125, 126, 127, 65_535, 65_536], fn(size) {
    let payload = filler(size)
    let assert frame.Complete(decoded, <<>>) =
      frame.decode(server_frame(True, 2, payload))
    assert decoded
      == frame.Frame(fin: True, opcode: frame.Binary, payload: payload)
  })
}

pub fn the_seven_bit_form_stops_at_125_test() {
  let assert Ok(head) =
    bit_array.slice(server_frame(True, 2, filler(125)), 0, 2)
  assert head == <<0x82, 125>>

  let assert Ok(head) =
    bit_array.slice(server_frame(True, 2, filler(126)), 0, 4)
  assert head == <<0x82, 126, 0x00, 0x7E>>
}

pub fn the_sixteen_bit_form_stops_at_65535_test() {
  let assert Ok(head) =
    bit_array.slice(server_frame(True, 2, filler(65_535)), 0, 4)
  assert head == <<0x82, 126, 0xFF, 0xFF>>

  let assert Ok(head) =
    bit_array.slice(server_frame(True, 2, filler(65_536)), 0, 10)
  assert head == <<0x82, 127, 0, 0, 0, 0, 0, 1, 0, 0>>
}

/// RFC 6455 asks a sender for the shortest form; a receiver that insists on it
/// gains nothing.
pub fn a_padded_length_is_accepted_test() {
  assert frame.decode(<<0x81, 0x7E, 0x00, 0x02, "hi":utf8>>)
    == frame.Complete(
      frame.Frame(fin: True, opcode: frame.Text, payload: <<"hi":utf8>>),
      <<>>,
    )

  assert frame.decode(<<0x81, 0x7F, 0, 0, 0, 0, 0, 0, 0, 2, "hi":utf8>>)
    == frame.Complete(
      frame.Frame(fin: True, opcode: frame.Text, payload: <<"hi":utf8>>),
      <<>>,
    )
}

/// A length header that has not finished arriving is not a length.
pub fn a_truncated_length_is_incomplete_test() {
  assert frame.decode(<<0x81, 0x7E>>) == frame.Incomplete
  assert frame.decode(<<0x81, 0x7E, 0x00>>) == frame.Incomplete
  assert frame.decode(<<0x81, 0x7F>>) == frame.Incomplete
  assert frame.decode(<<0x81, 0x7F, 0, 0, 0, 0, 0, 0, 0>>) == frame.Incomplete
}

/// 2^53 - 1 is the ceiling glyde reads. It is accepted and waits for bytes that
/// never come; one more is refused rather than read at the wrong offset.
pub fn a_length_past_2_53_is_refused_test() {
  // 2^53 - 1, as 0x001FFFFFFFFFFFFF.
  assert frame.decode(<<
      0x82, 0x7F, 0x00, 0x1F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    >>)
    == frame.Incomplete

  // 2^53, one past the ceiling.
  assert frame.decode(<<
      0x82, 0x7F, 0x00, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    >>)
    == frame.Invalid(frame.PayloadTooLarge)

  // The high bit, which RFC 6455 requires to be clear.
  assert frame.decode(<<
      0x82, 0x7F, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    >>)
    == frame.Invalid(frame.PayloadTooLarge)

  // Anything in the top byte, whichever bit it is.
  assert frame.decode(<<
      0x82, 0x7F, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    >>)
    == frame.Invalid(frame.PayloadTooLarge)
}

/// Only the low three weights can be proved exactly, since proving one means
/// handing over that many bytes. The rest are pinned to "more than we hold".
pub fn the_sixty_four_bit_weights_are_right_test() {
  let table = [
    #(<<0, 0, 0, 0, 0, 0, 0, 1>>, 1),
    #(<<0, 0, 0, 0, 0, 0, 1, 0>>, 256),
    #(<<0, 0, 0, 0, 0, 1, 0, 0>>, 65_536),
    #(<<0, 0, 0, 0, 1, 0, 0, 0>>, 16_777_216),
    #(<<0, 0, 0, 1, 0, 0, 0, 0>>, 4_294_967_296),
    #(<<0, 0, 1, 0, 0, 0, 0, 0>>, 1_099_511_627_776),
    #(<<0, 1, 0, 0, 0, 0, 0, 0>>, 281_474_976_710_656),
    #(<<0x00, 0x1F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>, 9_007_199_254_740_991),
  ]

  list.each(table, fn(row) {
    let #(bytes, expected) = row
    assert expected <= frame.max_payload_bytes

    case expected <= 65_536 {
      True -> {
        let payload = filler(expected)
        let claimed = bit_array.concat([<<0x82, 0x7F>>, bytes, payload])
        assert frame.decode(claimed)
          == frame.Complete(
            frame.Frame(fin: True, opcode: frame.Binary, payload:),
            <<>>,
          )
      }
      // One byte of payload against a header claiming far more. A byte read
      // as worth nothing would complete the frame here instead of waiting.
      False -> {
        let claimed = bit_array.concat([<<0x82, 0x7F>>, bytes, <<0x61>>])
        assert frame.decode(claimed) == frame.Incomplete
      }
    }
  })
}

/// A codec that can crash takes the connection's process with it, so every
/// header has to come back as one of the three answers.
pub fn decode_never_crashes_test() {
  let tails = [<<>>, <<0x61>>, <<0x00, 0x00, 0x00, 0x00>>, filler(10)]
  let lengths = [0x00, 0x01, 0x7D, 0x7E, 0x7F, 0x80, 0xFD, 0xFE, 0xFF]

  list.each(offsets(255), fn(first) {
    list.each(lengths, fn(second) {
      list.each(tails, fn(tail) {
        case frame.decode(bit_array.concat([<<first, second>>, tail])) {
          frame.Complete(..) | frame.Incomplete | frame.Invalid(..) -> Nil
        }
      })
    })
  })
}

/// A server must never mask. One that does is not speaking the protocol at
/// us, and unmasking anyway would read a hostile or broken stream as data.
pub fn a_masked_inbound_frame_is_rejected_test() {
  assert frame.decode(<<0x81, 0x82, 0x01, 0x02, 0x03, 0x04, 0x49, 0x6B>>)
    == frame.Invalid(frame.InboundFrameMasked)

  // Even with no payload, where there is nothing to unmask.
  assert frame.decode(<<0x81, 0x80, 0x01, 0x02, 0x03, 0x04>>)
    == frame.Invalid(frame.InboundFrameMasked)
}

/// No extension is negotiated, so a reserved bit means either an extension we
/// never agreed to or a corrupt stream.
pub fn reserved_bits_are_rejected_test() {
  list.each([0x40, 0x20, 0x10, 0x70], fn(rsv) {
    let first = 0x80 + rsv + 1
    assert frame.decode(<<first, 0x02, "hi":utf8>>)
      == frame.Invalid(frame.ReservedBitsSet)
  })
}

/// A control frame has to fit in one piece, so a close, a ping or a pong can
/// always get through between the fragments of a message.
pub fn an_oversized_control_frame_is_rejected_test() {
  list.each([8, 9, 10], fn(opcode) {
    let first = 0x80 + opcode

    // Declared 126 bytes, and refused on the declaration alone. Waiting for
    // bytes that are going to be thrown away just delays the close.
    assert frame.decode(<<first, 0x7E, 0x00, 0x7E>>)
      == frame.Invalid(frame.ControlPayloadTooLarge(126))

    // 125 is still legal.
    let ok = server_frame(True, opcode, filler(125))
    let assert frame.Complete(decoded, <<>>) = frame.decode(ok)
    assert decoded.payload == filler(125)
  })

  assert frame.max_control_payload == 125
}

pub fn a_fragmented_control_frame_is_rejected_test() {
  list.each([8, 9, 10], fn(opcode) {
    assert frame.decode(<<opcode, 0x00>>)
      == frame.Invalid(
        frame.FragmentedControlFrame(frame.opcode_from_int(opcode)),
      )
  })
}

/// An unknown opcode is a value, not a decode failure: the connection is failed
/// a layer up.
pub fn a_reserved_opcode_decodes_test() {
  assert frame.decode(<<0x83, 0x01, 0x61>>)
    == frame.Complete(
      frame.Frame(fin: True, opcode: frame.Reserved(3), payload: <<0x61>>),
      <<>>,
    )

  // A reserved control opcode still obeys the control frame rules.
  assert frame.decode(<<0x8B, 0x7E, 0x00, 0x7E>>)
    == frame.Invalid(frame.ControlPayloadTooLarge(126))
}

/// A client masks every frame, and glyde never fragments what it sends, so
/// FIN is always set.
pub fn encode_masks_and_sets_fin_test() {
  assert frame.encode(frame.SendText, <<"Hi":utf8>>, frame.Mask(1, 2, 3, 4))
    == <<0x81, 0x82, 0x01, 0x02, 0x03, 0x04, 0x49, 0x6B>>
}

/// The mask repeats every four bytes. An off by one corrupts everything past
/// byte four and nothing before it.
pub fn encode_wraps_the_mask_every_four_bytes_test() {
  assert frame.encode(frame.SendText, <<"Hello":utf8>>, frame.Mask(1, 2, 3, 4))
    == <<0x81, 0x85, 0x01, 0x02, 0x03, 0x04, 0x49, 0x67, 0x6F, 0x68, 0x6E>>
}

/// Every payload length modulo four, so each tail case of the masking loop is
/// exercised.
pub fn encode_masks_every_tail_length_test() {
  let mask = frame.Mask(0x37, 0xFA, 0x21, 0x3D)

  list.each(offsets(9), fn(size) {
    let payload = filler(size)
    let encoded = frame.encode(frame.SendBinary, payload, mask)
    assert unmask(encoded) == payload
  })
}

/// A frame body is counted in bytes. `byte_size` rounds a part byte up, so
/// without the padding the header would declare a byte the body never sent and
/// the peer would read the next frame's header as the rest of this payload.
pub fn encode_pads_a_payload_that_is_not_whole_bytes_test() {
  let mask = frame.Mask(0, 0, 0, 0)

  assert frame.encode(frame.SendBinary, <<0xF:4>>, mask)
    == <<0x82, 0x81, 0, 0, 0, 0, 0xF0>>

  // Every part byte, so the declared length always has the bytes behind it.
  list.each(offsets(9), fn(size) {
    list.each([1, 2, 3, 4, 5, 6, 7], fn(bits) {
      let payload = <<filler(size):bits, 1:size(bits)>>
      let encoded = frame.encode(frame.SendBinary, payload, mask)
      assert bit_array.byte_size(encoded) == size + 7
    })
  })
}

pub fn encode_an_empty_payload_test() {
  assert frame.encode(frame.SendPing, <<>>, frame.Mask(9, 9, 9, 9))
    == <<0x89, 0x80, 9, 9, 9, 9>>
}

/// Masking is its own inverse, so the payload comes back byte for byte.
pub fn encode_round_trips_through_unmasking_test() {
  let payload = <<"héllo 🎮 世界":utf8>>
  let encoded =
    frame.encode(frame.SendText, payload, frame.Mask(0xDE, 0xAD, 0, 255))
  assert unmask(encoded) == payload
}

/// The shortest length form that fits, which is what RFC 6455 asks a sender
/// for.
pub fn encode_uses_the_shortest_length_form_test() {
  let mask = frame.Mask(0, 0, 0, 0)

  let assert Ok(head) =
    bit_array.slice(frame.encode(frame.SendBinary, filler(125), mask), 0, 2)
  assert head == <<0x82, 0xFD>>

  let assert Ok(head) =
    bit_array.slice(frame.encode(frame.SendBinary, filler(126), mask), 0, 4)
  assert head == <<0x82, 0xFE, 0x00, 0x7E>>

  let assert Ok(head) =
    bit_array.slice(frame.encode(frame.SendBinary, filler(65_535), mask), 0, 4)
  assert head == <<0x82, 0xFE, 0xFF, 0xFF>>

  let assert Ok(head) =
    bit_array.slice(frame.encode(frame.SendBinary, filler(65_536), mask), 0, 10)
  assert head == <<0x82, 0xFF, 0, 0, 0, 0, 0, 1, 0, 0>>
}

/// The generator promises a range and not a width, so the low eight bits are
/// taken rather than trusted.
pub fn mask_bytes_are_only_ever_a_byte_test() {
  assert frame.encode(
      frame.SendText,
      <<"Hi":utf8>>,
      frame.Mask(0x101, 0x102, 3, 4),
    )
    == frame.encode(frame.SendText, <<"Hi":utf8>>, frame.Mask(1, 2, 3, 4))
}

/// The five a client may send, each with the nibble RFC 6455 gives it beside
/// the FIN bit. A continuation and a reserved opcode are not among them, so
/// neither can be written at all.
pub fn encode_writes_the_rfc_nibble_for_each_sendable_test() {
  let table = [
    #(frame.SendText, 0x81),
    #(frame.SendBinary, 0x82),
    #(frame.SendClose, 0x88),
    #(frame.SendPing, 0x89),
    #(frame.SendPong, 0x8A),
  ]

  list.each(table, fn(row) {
    let #(kind, first) = row
    assert frame.encode(kind, <<>>, frame.Mask(0, 0, 0, 0))
      == <<first, 0x80, 0, 0, 0, 0>>
  })
}

/// What we send is what a server would have to read, so an encoded frame with
/// its mask undone is a frame this decoder accepts.
pub fn what_we_encode_a_server_could_decode_test() {
  let payload = <<"a message":utf8>>
  let encoded = frame.encode(frame.SendText, payload, frame.Mask(1, 2, 3, 4))
  let assert Ok(head) = bit_array.slice(encoded, 0, 1)
  let unmasked = bit_array.concat([head, <<9>>, unmask(encoded)])

  assert frame.decode(unmasked)
    == frame.Complete(
      frame.Frame(fin: True, opcode: frame.Text, payload:),
      <<>>,
    )
}

/// Undo the mask on a frame `encode` produced, seven bit length form only.
fn unmask(encoded: BitArray) -> BitArray {
  let assert <<_first, _second, a, b, c, d, payload:bytes>> = encoded
  unmask_loop(payload, [a, b, c, d], 0, [])
}

fn unmask_loop(
  payload: BitArray,
  key: List(Int),
  index: Int,
  acc: List(Int),
) -> BitArray {
  case payload {
    <<next, rest:bytes>> -> {
      let assert Ok(k) = list_at(key, index % 4)
      unmask_loop(rest, key, index + 1, [xor_byte(next, k), ..acc])
    }
    _ ->
      list.reverse(acc)
      |> list.map(fn(byte) { <<byte>> })
      |> bit_array.concat
  }
}

fn list_at(items: List(Int), index: Int) -> Result(Int, Nil) {
  case items, index {
    [first, ..], 0 -> Ok(first)
    [_, ..rest], n -> list_at(rest, n - 1)
    [], _ -> Error(Nil)
  }
}

/// XOR from first principles, so the test does not lean on the same call the
/// code under test makes.
fn xor_byte(value: Int, key: Int) -> Int {
  xor_bits(value, key, 1, 0)
}

fn xor_bits(value: Int, key: Int, weight: Int, acc: Int) -> Int {
  case weight > 128 {
    True -> acc
    False -> {
      let bit = case value / weight % 2 == key / weight % 2 {
        True -> 0
        False -> weight
      }
      xor_bits(value, key, weight * 2, acc + bit)
    }
  }
}

/// A close frame with no payload is legal and means the peer gave no code.
pub fn a_close_with_no_code_test() {
  assert frame.close_body(<<>>) == frame.NoCloseCode
}

pub fn a_close_with_a_code_and_no_reason_test() {
  assert frame.close_body(<<0x03, 0xE8>>)
    == frame.CloseCode(code: 1000, reason: "")
}

pub fn a_close_with_a_code_and_a_reason_test() {
  assert frame.close_body(<<0x0F, 0xA2, "Session no longer valid.":utf8>>)
    == frame.CloseCode(code: 4002, reason: "Session no longer valid.")
}

/// A code is two bytes. One byte cannot be a code and cannot be a reason
/// either, so there is nothing to read.
pub fn a_one_byte_close_body_is_truncated_test() {
  assert frame.close_body(<<0x03>>) == frame.TruncatedCloseBody
}

/// The reason is unreadable, the code beside it is not. Discord's own codes
/// arrive this way if a reason is cut mid-character, and the code is the part
/// that says whether the session can be resumed.
pub fn a_close_reason_that_is_not_utf8_keeps_the_code_test() {
  assert frame.close_body(<<0x0F, 0xA4, 0xFF, 0xFE>>)
    == frame.UnreadableReason(code: 4004)

  // A reason cut in the middle of a multi-byte character.
  assert frame.close_body(<<0x03, 0xE8, 0xF0, 0x9F, 0x8E>>)
    == frame.UnreadableReason(code: 1000)
}

/// Discord's own codes are four digits, so the top byte is not always zero.
pub fn close_codes_use_both_bytes_test() {
  list.each([1000, 1001, 1006, 4000, 4004, 4014, 65_535], fn(code) {
    assert frame.close_body(frame.close_payload(code, ""))
      == frame.CloseCode(code:, reason: "")
  })
}

pub fn close_payload_round_trips_test() {
  assert frame.close_body(frame.close_payload(1000, "goodbye"))
    == frame.CloseCode(code: 1000, reason: "goodbye")
}

/// The whole close frame has to fit in 125 bytes, so a long reason is cut
/// rather than allowed to make a frame the server will reject.
pub fn a_long_close_reason_is_trimmed_test() {
  let long = string.repeat("x", 300)
  let payload = frame.close_payload(1000, long)

  assert bit_array.byte_size(payload) == 125
  assert frame.close_body(payload)
    == frame.CloseCode(code: 1000, reason: string.repeat("x", 123))
}

/// Splitting a multi-byte character would produce a reason that is not UTF-8.
pub fn trimming_a_close_reason_keeps_it_utf8_test() {
  // Four bytes each, so 123 bytes of room holds 30 of them with 3 to spare.
  let long = string.repeat("🎮", 60)
  let payload = frame.close_payload(1000, long)

  assert bit_array.byte_size(payload) == 122
  assert frame.close_body(payload)
    == frame.CloseCode(code: 1000, reason: string.repeat("🎮", 30))
}

pub fn a_whole_text_frame_is_a_message_test() {
  assert messages(server_frame(True, 1, <<"hello":utf8>>))
    == [frame.Whole(frame.TextMessage("hello"), frame.Idle)]
}

pub fn a_whole_binary_frame_is_a_message_test() {
  assert messages(server_frame(True, 2, <<0x01, 0x02>>))
    == [frame.Whole(frame.BinaryMessage(<<0x01, 0x02>>), frame.Idle)]
}

/// The plain fragmentation case: a text frame with FIN clear, then
/// continuations until one has it set.
pub fn a_text_message_across_three_frames_test() {
  let bytes =
    bit_array.concat([
      server_frame(False, 1, <<"one ":utf8>>),
      server_frame(False, 0, <<"two ":utf8>>),
      server_frame(True, 0, <<"three":utf8>>),
    ])

  assert messages(bytes)
    == [
      frame.Held(frame.Fragmented(True, <<"one ":utf8>>)),
      frame.Held(frame.Fragmented(True, <<"one two ":utf8>>)),
      frame.Whole(frame.TextMessage("one two three"), frame.Idle),
    ]
}

pub fn a_binary_message_across_two_frames_test() {
  let bytes =
    bit_array.concat([
      server_frame(False, 2, <<0x01, 0x02>>),
      server_frame(True, 0, <<0x03>>),
    ])

  assert messages(bytes)
    == [
      frame.Held(frame.Fragmented(False, <<0x01, 0x02>>)),
      frame.Whole(frame.BinaryMessage(<<0x01, 0x02, 0x03>>), frame.Idle),
    ]
}

/// A server may ping between the fragments of a message, and the pong owed for
/// it must not disturb what is half assembled.
pub fn a_ping_between_fragments_leaves_the_message_alone_test() {
  let bytes =
    bit_array.concat([
      server_frame(False, 1, <<"half ":utf8>>),
      server_frame(True, 9, <<"keepalive":utf8>>),
      server_frame(True, 0, <<"a message":utf8>>),
    ])

  assert messages(bytes)
    == [
      frame.Held(frame.Fragmented(True, <<"half ":utf8>>)),
      frame.Whole(
        frame.PingMessage(<<"keepalive":utf8>>),
        frame.Fragmented(True, <<"half ":utf8>>),
      ),
      frame.Whole(frame.TextMessage("half a message"), frame.Idle),
    ]
}

/// Every kind of control frame, all three between the same two fragments.
pub fn every_control_frame_may_interleave_test() {
  let bytes =
    bit_array.concat([
      server_frame(False, 2, <<0x01>>),
      server_frame(True, 9, <<>>),
      server_frame(True, 10, <<0x2A>>),
      server_frame(True, 8, <<0x03, 0xE8, "bye":utf8>>),
      server_frame(True, 0, <<0x02>>),
    ])

  let held = frame.Fragmented(False, <<0x01>>)
  assert messages(bytes)
    == [
      frame.Held(held),
      frame.Whole(frame.PingMessage(<<>>), held),
      frame.Whole(frame.PongMessage(<<0x2A>>), held),
      frame.Whole(frame.CloseMessage(frame.CloseCode(1000, "bye")), held),
      frame.Whole(frame.BinaryMessage(<<0x01, 0x02>>), frame.Idle),
    ]
}

/// A fragment with nothing in it is legal and changes nothing but the FIN
/// flag it carries.
pub fn an_empty_fragment_is_allowed_test() {
  let bytes =
    bit_array.concat([
      server_frame(False, 1, <<"text":utf8>>),
      server_frame(False, 0, <<>>),
      server_frame(True, 0, <<>>),
    ])

  assert messages(bytes)
    == [
      frame.Held(frame.Fragmented(True, <<"text":utf8>>)),
      frame.Held(frame.Fragmented(True, <<"text":utf8>>)),
      frame.Whole(frame.TextMessage("text"), frame.Idle),
    ]
}

/// A codepoint may split across two fragments, so UTF-8 is only checked on the
/// finished message.
pub fn a_codepoint_split_across_fragments_test() {
  let bytes =
    bit_array.concat([
      server_frame(False, 1, <<0xF0, 0x9F>>),
      server_frame(True, 0, <<0x8E, 0xAE>>),
    ])

  assert messages(bytes)
    == [
      frame.Held(frame.Fragmented(True, <<0xF0, 0x9F>>)),
      frame.Whole(frame.TextMessage("🎮"), frame.Idle),
    ]
}

pub fn a_text_message_that_is_not_utf8_breaks_test() {
  assert messages(server_frame(True, 1, <<0xFF, 0xFE>>))
    == [frame.Broken(frame.TextNotUtf8)]
}

/// Binary carries whatever it carries.
pub fn a_binary_message_need_not_be_utf8_test() {
  assert messages(server_frame(True, 2, <<0xFF, 0xFE>>))
    == [frame.Whole(frame.BinaryMessage(<<0xFF, 0xFE>>), frame.Idle)]
}

pub fn a_continuation_with_nothing_to_continue_breaks_test() {
  assert messages(server_frame(True, 0, <<"orphan":utf8>>))
    == [frame.Broken(frame.ContinuationWithNoMessage)]

  assert messages(server_frame(False, 0, <<"orphan":utf8>>))
    == [frame.Broken(frame.ContinuationWithNoMessage)]
}

/// A server that begins a second message has lost track of the first, and
/// guessing which bytes belong to which is worse than closing.
pub fn a_second_message_before_the_first_finishes_breaks_test() {
  let bytes =
    bit_array.concat([
      server_frame(False, 1, <<"half":utf8>>),
      server_frame(True, 1, <<"another":utf8>>),
    ])

  assert messages(bytes)
    == [
      frame.Held(frame.Fragmented(True, <<"half":utf8>>)),
      frame.Broken(frame.MessageBeforeLastFinished(frame.Text)),
    ]
}

pub fn a_reserved_opcode_breaks_the_connection_test() {
  assert messages(server_frame(True, 3, <<>>))
    == [frame.Broken(frame.ReservedOpcode(3))]

  // A reserved control opcode, which decodes but still cannot be acted on.
  assert messages(server_frame(True, 11, <<>>))
    == [frame.Broken(frame.ReservedOpcode(11))]
}

/// Back to back messages on one connection. The second must carry none of the
/// first.
pub fn messages_in_sequence_test() {
  let bytes =
    bit_array.concat([
      server_frame(False, 1, <<"a":utf8>>),
      server_frame(True, 0, <<"b":utf8>>),
      server_frame(True, 1, <<"c":utf8>>),
      server_frame(False, 2, <<0x01>>),
      server_frame(True, 0, <<0x02>>),
    ])

  assert messages(bytes)
    == [
      frame.Held(frame.Fragmented(True, <<"a":utf8>>)),
      frame.Whole(frame.TextMessage("ab"), frame.Idle),
      frame.Whole(frame.TextMessage("c"), frame.Idle),
      frame.Held(frame.Fragmented(False, <<0x01>>)),
      frame.Whole(frame.BinaryMessage(<<0x01, 0x02>>), frame.Idle),
    ]
}

/// A close frame with no body is the peer leaving without a code, which the
/// caller has to tell apart from a code it does not recognise.
pub fn a_close_frame_with_no_body_test() {
  assert messages(server_frame(True, 8, <<>>))
    == [frame.Whole(frame.CloseMessage(frame.NoCloseCode), frame.Idle)]
}

/// A fragmented text message with a ping in the middle and a close at the end.
pub fn a_connection_worth_of_bytes_test() {
  let bytes =
    bit_array.concat([
      server_frame(False, 1, <<"{\"op\":":utf8>>),
      server_frame(True, 9, <<>>),
      server_frame(False, 0, <<"11":utf8>>),
      server_frame(True, 0, <<"}":utf8>>),
      server_frame(True, 8, <<0x0F, 0xA0, "Unknown error":utf8>>),
    ])

  let #(frames, tail) = decode_all(bytes)
  assert list.length(frames) == 5
  assert tail == frame.Incomplete

  let delivered =
    list.filter_map(messages(bytes), fn(taken) {
      case taken {
        frame.Whole(message:, ..) -> Ok(message)
        _ -> Error(Nil)
      }
    })

  assert delivered
    == [
      frame.PingMessage(<<>>),
      frame.TextMessage("{\"op\":11}"),
      frame.CloseMessage(frame.CloseCode(4000, "Unknown error")),
    ]
}
