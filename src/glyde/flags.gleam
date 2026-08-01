//// Bitfields Discord sends as a JSON number.
////
//// `Flags(kind)` is the raw bits tagged by the flag type that names them, so
//// a bit newer than this build survives a decode and a re-encode: an edit
//// sends every previously set bit back, and dropping one clears a setting
//// nobody touched. The bit table stays private to the model that owns it,
//// which is why the setters here take a bit rather than a flag.
////
//// `set_bit` and `clear_bit` are shared by every family, including the ones
//// Discord never lets a bot write. A family is meant to be edited only if its
//// model exposes a named-flag builder: message, channel and member do.

import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import glyde/wire

pub opaque type Flags(kind) {
  Flags(bits: Int)
}

pub const none: Flags(kind) = Flags(0)

pub fn to_int(flags: Flags(kind)) -> Int {
  flags.bits
}

pub fn from_int(bits: Int) -> Flags(kind) {
  Flags(bits)
}

pub fn to_json(flags: Flags(kind)) -> Json {
  json.int(flags.bits)
}

pub fn decoder() -> Decoder(Flags(kind)) {
  wire.integer() |> decode.map(from_int)
}

/// True when any bit of `bit` is set. Pass a single bit from the owning
/// model's table: a multi-bit mask answers "any", not "all".
pub fn has_bit(flags: Flags(kind), bit: Int) -> Bool {
  wire.has_bit(flags.bits, bit)
}

pub fn set_bit(flags: Flags(kind), bit: Int) -> Flags(kind) {
  Flags(int.bitwise_or(flags.bits, bit))
}

pub fn clear_bit(flags: Flags(kind), bit: Int) -> Flags(kind) {
  Flags(int.bitwise_and(flags.bits, int.bitwise_not(bit)))
}
