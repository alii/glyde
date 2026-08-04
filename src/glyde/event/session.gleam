//// The session's own dispatches. READY decodes in `glyde/ready` and RESUMED
//// carries nothing, which leaves RATE_LIMITED.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/option.{type Option}
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
    meta: RateLimitMeta,
  )
}

/// Keyed by opcode, and open. Only opcode 8's shape is documented, and `meta`
/// can be missing altogether.
pub type RateLimitMeta {
  MemberRequestMeta(guild_id: id.GuildId, nonce: Option(String))
  /// Any other opcode, and any opcode 8 whose meta had no `guild_id`. `raw` is
  /// the meta object as sent, or null when there was none.
  UnknownMeta(opcode: Int, raw: Dynamic)
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
  use meta <- decode.optional_field("meta", dynamic.nil(), decode.dynamic)
  decode.success(RateLimited(
    opcode:,
    retry_after:,
    meta: rate_limit_meta(opcode, meta),
  ))
}

/// Opcode 8 is the only meta shape Discord documents. Anything else, a
/// missing meta included, keeps the raw object rather than guessing.
fn rate_limit_meta(opcode: Int, raw: Dynamic) -> RateLimitMeta {
  case opcode, decode.run(raw, member_request_meta_decoder()) {
    8, Ok(meta) -> meta
    _, _ -> UnknownMeta(opcode:, raw:)
  }
}

fn member_request_meta_decoder() -> Decoder(RateLimitMeta) {
  use guild_id <- decode.field("guild_id", id.decoder())
  use nonce <- wire.opt_field("nonce", decode.string)
  decode.success(MemberRequestMeta(guild_id:, nonce:))
}
