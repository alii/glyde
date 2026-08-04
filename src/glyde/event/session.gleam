//// The session's own dispatches. READY decodes in `glyde/ready` and RESUMED
//// carries nothing, which leaves RATE_LIMITED.

import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/option.{type Option, None, Some}
import glyde/id
import glyde/wire

/// The answer to going over a gateway send limit, today one
/// REQUEST_GUILD_MEMBERS per guild per 30 seconds.
pub type RateLimited {
  RateLimited(
    /// The send opcode that was limited. 8 today.
    opcode: Int,
    /// SECONDS, fractional, and a bare `30` when the value is whole.
    /// `retry_after_ms` is usually what you want.
    retry_after: Float,
    /// `None` for any opcode this build has no meta shape for, and for a
    /// missing `meta` key.
    meta: Option(RateLimitMeta),
  )
}

/// Keyed by opcode. Only opcode 8's shape is documented; a value this build
/// has no shape for decodes as `None`.
pub type RateLimitMeta {
  MemberRequestMeta(guild_id: id.GuildId, nonce: Option(String))
}

/// `retry_after` in milliseconds, never negative: "retry now" is the only
/// reading of a negative delay a host can act on. Our floor, not Discord's.
pub fn retry_after_ms(limited: RateLimited) -> Int {
  let ms = limited.retry_after *. 1000.0
  // Discord's number arms a timer. No real wait goes near 2^53, so clamp.
  case ms >. 0.0, ms <. 9_007_199_254_740_992.0 {
    True, True -> float.round(ms)
    True, False -> 9_007_199_254_740_991
    False, _ -> 0
  }
}

pub fn rate_limited_decoder() -> Decoder(RateLimited) {
  use opcode <- decode.field("opcode", wire.integer())
  use retry_after <- decode.field("retry_after", wire.number())
  use meta <- wire.soft_field("meta", meta_decoder(opcode))
  decode.success(RateLimited(opcode:, retry_after:, meta: option.flatten(meta)))
}

/// Opcode 8 is the only meta shape Discord documents. Anything else, a
/// missing meta included, gives `None`.
fn meta_decoder(opcode: Int) -> Decoder(Option(RateLimitMeta)) {
  case opcode {
    8 -> member_request_meta_decoder() |> decode.map(Some)
    _ -> decode.success(None)
  }
}

fn member_request_meta_decoder() -> Decoder(RateLimitMeta) {
  use guild_id <- decode.field("guild_id", id.decoder())
  use nonce <- wire.opt_field("nonce", decode.string)
  decode.success(MemberRequestMeta(guild_id:, nonce:))
}
