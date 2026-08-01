//// The two gateway-discovery responses. `GET /gateway/bot` carries the URL,
//// the shard count and the session start limit; `GET /gateway` the URL alone.
////
//// Every field is required. A connect is planned from these numbers, and the
//// penalty for guessing one is in `SessionStartLimit`.

import gleam/dynamic/decode.{type Decoder}
import gleam/int
import glyde/identify_queue.{type Queue} as queue
import glyde/internal/url
import glyde/wire

/// `GET /gateway`.
pub type GatewayInfo {
  GatewayInfo(
    /// As Discord sent it, `wss://` scheme and all.
    url: String,
    /// The same URL with the scheme taken off, which is what a shard dials.
    /// Hand it to `gateway.Config.host`.
    dial_host: url.Host,
  )
}

/// `GET /gateway/bot`.
pub type GatewayBot {
  GatewayBot(
    /// As Discord sent it, `wss://` scheme and all.
    url: String,
    /// The same URL with the scheme taken off, which is what a shard dials.
    /// Hand it to `gateway.Config.host`.
    dial_host: url.Host,
    /// Discord's recommendation. Higher is allowed, lower closes with 4011.
    shards: Int,
    session_start_limit: SessionStartLimit,
  )
}

/// The daily budget of session starts. Exceeding `max_concurrency` costs an
/// INVALID_SESSION; exhausting `remaining` resets the bot's token.
pub type SessionStartLimit {
  SessionStartLimit(
    /// 1000 for most bots, more past 150 000 guilds.
    total: Int,
    remaining: Int,
    /// A duration, not an instant: how long until `remaining` returns to
    /// `total`.
    reset_after_ms: Int,
    /// How many shards may IDENTIFY in the same five-second window.
    max_concurrency: Int,
  )
}

pub fn decoder() -> Decoder(GatewayInfo) {
  use address <- decode.field("url", decode.string)
  use dial_host <- decode.field("url", host_decoder())
  decode.success(GatewayInfo(url: address, dial_host:))
}

pub fn bot_decoder() -> Decoder(GatewayBot) {
  use address <- decode.field("url", decode.string)
  use dial_host <- decode.field("url", host_decoder())
  use shards <- decode.field("shards", wire.integer())
  use limit <- decode.field(
    "session_start_limit",
    session_start_limit_decoder(),
  )
  decode.success(GatewayBot(
    url: address,
    dial_host:,
    shards:,
    session_start_limit: limit,
  ))
}

/// The URL again, as the host a shard dials. A response with no host in it is
/// broken rather than something to guess a default for, so it fails the decode
/// and reaches the caller as `error.Malformed`.
fn host_decoder() -> Decoder(url.Host) {
  use address <- decode.then(decode.string)
  case url.host_of(address) {
    Ok(host) -> decode.success(host)
    Error(Nil) -> decode.failure(discarded_host(), "GatewayUrl")
  }
}

/// `decode.failure` wants a value of the type it could not build, and a `Host`
/// cannot be conjured. `decode.run` returns the errors and never this, and
/// Discord's front door is what a shard would have dialled anyway.
fn discarded_host() -> url.Host {
  let assert Ok(host) = url.host_of("gateway.discord.gg")
  host
}

pub fn session_start_limit_decoder() -> Decoder(SessionStartLimit) {
  use total <- decode.field("total", wire.integer())
  use remaining <- decode.field("remaining", wire.integer())
  use reset_after_ms <- decode.field("reset_after", wire.integer())
  use max_concurrency <- decode.field("max_concurrency", wire.integer())
  decode.success(SessionStartLimit(
    total:,
    remaining:,
    reset_after_ms:,
    max_concurrency:,
  ))
}

/// `reset_after` is a duration and the queue counts instants. Read the clock
/// when the response arrived: any later is time the queue thinks it still has.
pub fn identify_queue(bot: GatewayBot, now_ms now_ms: Int) -> Queue {
  let SessionStartLimit(remaining:, reset_after_ms:, max_concurrency:, ..) =
    bot.session_start_limit
  queue.new(max_concurrency:, remaining:, reset_at_ms: now_ms + reset_after_ms)
}

pub type StartWindow {
  Open(remaining: Int)

  /// Wait, do not retry: trying past the limit resets the bot's token.
  /// `resets_at_ms` is an instant on the caller's clock, like every other
  /// deadline glyde hands back.
  Spent(resets_at_ms: Int)
}

/// Same clock rule as `identify_queue`: `reset_after` is a duration, so read
/// the clock when the response arrived, not when someone asks.
pub fn start_window(bot: GatewayBot, now_ms now_ms: Int) -> StartWindow {
  case bot.session_start_limit {
    SessionStartLimit(remaining:, ..) if remaining > 0 -> Open(remaining:)
    // Nothing downstream re-checks this one, unlike the queue's `reset_at_ms`,
    // so a negative duration off the wire is floored here.
    SessionStartLimit(reset_after_ms:, ..) ->
      Spent(resets_at_ms: now_ms + int.max(reset_after_ms, 0))
  }
}
