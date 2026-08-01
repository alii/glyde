//// RFC 6455 framing for a client, as pure Gleam over `BitArray`. No FFI, no
//// socket, no randomness.
////
//// `decode` and `encode` are one frame each way. `take` feeds decoded frames
//// into an `Assembly` and hands back whole messages, since a message may
//// arrive as several frames with control frames in between.
////
//// Client role only: an inbound masked frame is rejected, every outbound frame
//// is masked and sets FIN, and a reserved bit is rejected rather than ignored.
//// An inbound length padded into a longer form than it needs is accepted.
//// Close codes stay plain numbers; `glyde/gateway/close` reads them.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/string

/// RFC 6455 caps a control frame payload at 125 bytes so that a close, ping or
/// pong can always be sent in one piece.
pub const max_control_payload: Int = 125

/// Our cap on a declared payload length, 2^53 - 1. The wire allows 63 bits,
/// which would ask us to buffer a petabyte. Refused, never truncated.
pub const max_payload_bytes: Int = 9_007_199_254_740_991

/// The three reserved bits, which are only meaningful with an extension.
const rsv_bits: Int = 0x70

pub type Opcode {
  /// More of the message that came before.
  Continuation
  Text
  Binary
  Close
  Ping
  Pong
  /// 3 to 7 and 11 to 15, which RFC 6455 reserves. A value rather than an
  /// error keeps the codec total; `take` still ends the connection.
  Reserved(code: Int)
}

/// What `encode` will build. Only these five: a client never sends a reserved
/// opcode, and a `Continuation` has nothing to continue when every frame out
/// of here sets FIN.
pub type Sendable {
  SendText
  SendBinary
  SendPing
  SendPong
  SendClose
}

pub type Frame {
  Frame(fin: Bool, opcode: Opcode, payload: BitArray)
}

/// Why the bytes are not RFC 6455 any more. A value rather than a sentence, so
/// a caller can act on one without reading English.
pub type Violation {
  ReservedBitsSet
  InboundFrameMasked
  /// A declared length above `max_payload_bytes`. The length is not carried:
  /// the high bytes alone refuse it, before the rest are read.
  PayloadTooLarge
  FragmentedControlFrame(opcode: Opcode)
  ControlPayloadTooLarge(length: Int)
  ReservedOpcode(code: Int)
  ContinuationWithNoMessage
  MessageBeforeLastFinished(opcode: Opcode)
  TextNotUtf8
}

/// For a log line or a message to a human. A caller deciding what to do reads
/// the `Violation` itself.
pub fn violation_to_string(violation: Violation) -> String {
  case violation {
    ReservedBitsSet -> "reserved bits set"
    InboundFrameMasked -> "inbound frame is masked"
    PayloadTooLarge -> "payload length above 2^53 - 1"
    FragmentedControlFrame(opcode) ->
      "fragmented control frame, opcode " <> opcode_number(opcode)
    ControlPayloadTooLarge(length) ->
      "control frame payload over "
      <> int.to_string(max_control_payload)
      <> " bytes, declared "
      <> int.to_string(length)
    ReservedOpcode(code) -> "reserved opcode " <> int.to_string(code)
    ContinuationWithNoMessage -> "continuation with no message to continue"
    MessageBeforeLastFinished(opcode) ->
      "new message before the last one finished, opcode "
      <> opcode_number(opcode)
    TextNotUtf8 -> "text message is not valid UTF-8"
  }
}

fn opcode_number(opcode: Opcode) -> String {
  int.to_string(opcode_to_int(opcode))
}

pub type Decoded {
  /// `rest` goes straight back into `decode`: one read often lands several
  /// frames.
  Complete(frame: Frame, rest: BitArray)

  Incomplete

  /// These bytes cannot be a frame. The connection is finished.
  Invalid(reason: Violation)
}

/// The four bytes a client masks a frame with. RFC 6455 wants them
/// unpredictable, so draw them from a real random source, never a seeded one.
pub type Mask {
  Mask(a: Int, b: Int, c: Int, d: Int)
}

/// Read one frame from the front of a buffer. Total: malformed input is a
/// value, never a crash.
pub fn decode(bytes: BitArray) -> Decoded {
  case bytes {
    <<first, second, rest:bytes>> -> {
      // Reading past a reserved bit would decode an extension's framing as
      // payload.
      use <- bool.guard(
        int.bitwise_and(first, rsv_bits) != 0,
        Invalid(ReservedBitsSet),
      )
      // A server must never mask. One that does is not speaking RFC 6455.
      use <- bool.guard(second >= 0x80, Invalid(InboundFrameMasked))

      let fin = first >= 0x80
      let opcode = opcode_from_int(int.bitwise_and(first, 0x0F))

      case length_of(int.bitwise_and(second, 0x7F), rest) {
        NeedMore -> Incomplete
        TooLarge -> Invalid(PayloadTooLarge)
        Length(length:, body:) -> body_of(fin, opcode, length, body)
      }
    }

    _ -> Incomplete
  }
}

type Length {
  Length(length: Int, body: BitArray)
  NeedMore
  TooLarge
}

fn length_of(short: Int, rest: BitArray) -> Length {
  case short {
    126 ->
      case rest {
        <<hi, lo, body:bytes>> -> Length(length: hi * 256 + lo, body:)
        _ -> NeedMore
      }

    127 ->
      case rest {
        <<a, b, c, d, e, f, g, h, body:bytes>> ->
          // A byte at a time so the high bits can be checked first: that is
          // what enforces `max_payload_bytes`.
          case a, b <= 0x1F {
            0, True ->
              Length(
                length: b
                  * 281_474_976_710_656
                  + c
                  * 1_099_511_627_776
                  + d
                  * 4_294_967_296
                  + e
                  * 16_777_216
                  + f
                  * 65_536
                  + g
                  * 256
                  + h,
                body:,
              )
            _, _ -> TooLarge
          }
        _ -> NeedMore
      }

    length -> Length(length:, body: rest)
  }
}

fn body_of(fin: Bool, opcode: Opcode, length: Int, body: BitArray) -> Decoded {
  // Checked on the declared length, before waiting for bytes that would only
  // be thrown away.
  let control = is_control(opcode)
  use <- bool.guard(control && !fin, Invalid(FragmentedControlFrame(opcode)))
  use <- bool.guard(
    control && length > max_control_payload,
    Invalid(ControlPayloadTooLarge(length)),
  )

  case body {
    <<payload:bytes-size(length), rest:bytes>> ->
      Complete(Frame(fin:, opcode:, payload:), rest)
    _ -> Incomplete
  }
}

/// Build one frame, masked, with FIN set.
///
/// An oversized control payload is not enforced: truncating a pong would break
/// the echo, and `decode` refuses one on the way in. `close_payload` fits a
/// close reason for you.
///
/// A payload that is not a whole number of bytes is padded with zero bits: a
/// frame body is counted in bytes, so there is nowhere to put the odd bits.
pub fn encode(kind: Sendable, payload: BitArray, mask: Mask) -> BitArray {
  // Before the size is read, because `byte_size` rounds up: an unpadded 12 bit
  // payload would declare 2 bytes and send 1.
  let payload = bit_array.pad_to_bytes(payload)
  let size = bit_array.byte_size(payload)
  let mask = Mask(byte(mask.a), byte(mask.b), byte(mask.c), byte(mask.d))
  let Mask(a, b, c, d) = mask
  let first = 0x80 + sendable_to_int(kind)

  bit_array.concat([
    <<first>>,
    // The mask bit rides on top of whichever length form is used.
    length_bytes(size),
    <<a, b, c, d>>,
    apply_mask(payload, mask, []),
  ])
}

/// The shortest length form that fits, which is what RFC 6455 asks for.
fn length_bytes(size: Int) -> BitArray {
  case size < 126, size < 65_536 {
    True, _ -> {
      let short = 0x80 + size
      <<short>>
    }
    _, True -> <<0xFE, size:16>>
    _, _ -> <<0xFF, size:64>>
  }
}

/// XOR each byte with the mask byte at its index modulo four. Four at a time
/// keeps the index implicit, so there is no counter to get wrong.
fn apply_mask(payload: BitArray, mask: Mask, acc: List(BitArray)) -> BitArray {
  let Mask(a, b, c, d) = mask
  case payload {
    <<w, x, y, z, rest:bytes>> ->
      apply_mask(rest, mask, [
        <<xor(w, a), xor(x, b), xor(y, c), xor(z, d)>>,
        ..acc
      ])
    <<w, x, y>> -> joined([<<xor(w, a), xor(x, b), xor(y, c)>>, ..acc])
    <<w, x>> -> joined([<<xor(w, a), xor(x, b)>>, ..acc])
    <<w>> -> joined([<<xor(w, a)>>, ..acc])
    // `encode` pads first, so nothing but the empty tail reaches this.
    _ -> joined(acc)
  }
}

fn joined(reversed: List(BitArray)) -> BitArray {
  bit_array.concat(list.reverse(reversed))
}

fn xor(value: Int, key: Int) -> Int {
  int.bitwise_exclusive_or(value, key)
}

fn byte(value: Int) -> Int {
  int.bitwise_and(value, 0xFF)
}

pub fn opcode_to_int(opcode: Opcode) -> Int {
  case opcode {
    Continuation -> 0
    Text -> 1
    Binary -> 2
    Close -> 8
    Ping -> 9
    Pong -> 10
    Reserved(code) -> code
  }
}

/// RFC 6455 section 5.2. Total, so there is no wider number to trim back into
/// the nibble and no way to write a frame the opcode field cannot hold.
fn sendable_to_int(kind: Sendable) -> Int {
  case kind {
    SendText -> 1
    SendBinary -> 2
    SendClose -> 8
    SendPing -> 9
    SendPong -> 10
  }
}

pub fn opcode_from_int(code: Int) -> Opcode {
  case code {
    0 -> Continuation
    1 -> Text
    2 -> Binary
    8 -> Close
    9 -> Ping
    10 -> Pong
    other -> Reserved(code: other)
  }
}

/// Control frames may appear between a message's fragments, and must arrive
/// whole and within `max_control_payload`.
pub fn is_control(opcode: Opcode) -> Bool {
  opcode_to_int(opcode) >= 8
}

pub type CloseBody {
  /// No payload. Allowed, and it means the peer gave no code.
  NoCloseCode

  CloseCode(code: Int, reason: String)

  /// A single byte, too few to hold a code. Nothing in it to read.
  TruncatedCloseBody

  /// The code read, and the reason after it is not UTF-8. Kept apart from
  /// `TruncatedCloseBody` because the code is the part a caller acts on.
  UnreadableReason(code: Int)
}

pub fn close_body(payload: BitArray) -> CloseBody {
  case payload {
    <<>> -> NoCloseCode
    <<hi, lo, reason:bytes>> -> {
      let code = hi * 256 + lo
      case bit_array.to_string(reason) {
        Ok(reason) -> CloseCode(code:, reason:)
        Error(_) -> UnreadableReason(code:)
      }
    }
    _ -> TruncatedCloseBody
  }
}

/// The reason is cut on a codepoint boundary to fit beside the code. Trims
/// rather than fails: a reason is a courtesy, a dropped connection is not.
pub fn close_payload(code: Int, reason: String) -> BitArray {
  let code = int.bitwise_and(code, 0xFFFF)
  let hi = code / 256
  let lo = code % 256
  let reason =
    fit(string.to_utf_codepoints(reason), max_control_payload - 2, [])
  bit_array.concat([<<hi, lo>>, bit_array.from_string(reason)])
}

fn fit(
  codepoints: List(UtfCodepoint),
  left: Int,
  acc: List(UtfCodepoint),
) -> String {
  case codepoints {
    [] -> string.from_utf_codepoints(list.reverse(acc))
    [next, ..rest] -> {
      let width = utf8_width(string.utf_codepoint_to_int(next))
      case width > left {
        True -> string.from_utf_codepoints(list.reverse(acc))
        False -> fit(rest, left - width, [next, ..acc])
      }
    }
  }
}

fn utf8_width(codepoint: Int) -> Int {
  case codepoint < 0x80, codepoint < 0x800, codepoint < 0x10000 {
    True, _, _ -> 1
    _, True, _ -> 2
    _, _, True -> 3
    _, _, _ -> 4
  }
}

/// A message being put back together. Unbounded: a caller that wants a cap on
/// endless fragmenting measures `Fragmented`'s payload itself.
pub type Assembly {
  Idle

  /// `text` is taken from the first fragment, since continuations no longer
  /// say.
  Fragmented(text: Bool, payload: BitArray)
}

/// A complete message, or a control frame, which is always complete.
pub type Message {
  TextMessage(text: String)
  BinaryMessage(bytes: BitArray)
  PingMessage(payload: BitArray)
  PongMessage(payload: BitArray)
  CloseMessage(body: CloseBody)
}

pub type Taken {
  /// A control frame that arrived between fragments hands the assembly back
  /// untouched.
  Whole(message: Message, assembly: Assembly)

  /// A fragment stored. Nothing to deliver yet.
  Held(assembly: Assembly)

  /// The fragment sequence is broken, so the connection is finished.
  Broken(reason: Violation)
}

/// Feed one decoded frame to the message assembler. A control frame may arrive
/// between fragments: it is delivered alone and leaves the assembly alone.
pub fn take(assembly: Assembly, frame: Frame) -> Taken {
  case frame.opcode {
    Ping -> Whole(PingMessage(frame.payload), assembly)
    Pong -> Whole(PongMessage(frame.payload), assembly)
    Close -> Whole(CloseMessage(close_body(frame.payload)), assembly)

    // RFC 6455 says to fail the connection on an opcode we do not know.
    Reserved(code) -> Broken(ReservedOpcode(code))

    Continuation ->
      case assembly {
        Idle -> Broken(ContinuationWithNoMessage)
        Fragmented(text:, payload:) -> {
          let payload = bit_array.append(payload, frame.payload)
          case frame.fin {
            False -> Held(Fragmented(text:, payload:))
            True -> deliver(text, payload)
          }
        }
      }

    Text | Binary ->
      case assembly {
        Fragmented(..) -> Broken(MessageBeforeLastFinished(frame.opcode))
        Idle ->
          case frame.fin {
            True -> deliver(frame.opcode == Text, frame.payload)
            False -> Held(Fragmented(frame.opcode == Text, frame.payload))
          }
      }
  }
}

fn deliver(text: Bool, payload: BitArray) -> Taken {
  case text {
    False -> Whole(BinaryMessage(payload), Idle)
    // Checked on the assembled message, never a fragment: a codepoint may be
    // split across two frames.
    True ->
      case bit_array.to_string(payload) {
        Ok(text) -> Whole(TextMessage(text), Idle)
        Error(_) -> Broken(TextNotUtf8)
      }
  }
}
