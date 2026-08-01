//// Three gateway URLs exist and mixing them up is a standing bug:
////
//// - `get_gateway` before any connection that will IDENTIFY. Needs no token.
//// - `get_gateway_bot` for the same, plus the shard count and the identify
////   permit inputs. This is the one a bot calls.
//// - `resume_gateway_url` from READY, and only before a RESUME. It arrives
////   over the gateway, so it is not here.

import glyde/model/gateway_info.{type GatewayBot, type GatewayInfo}
import glyde/rest.{type Call}
import glyde/rest/seg

/// `GET /gateway`, the WebSocket URL and nothing else. The one route here that
/// needs no token, and sending the bot's anyway is harmless, so this goes
/// through the same `rest.Config` as everything else.
pub fn get_gateway() -> Call(GatewayInfo) {
  rest.get([seg.lit("gateway")], rest.Decoded(gateway_info.decoder()))
}

/// `GET /gateway/bot`, the URL plus the recommended shard count and how many
/// shards may identify in the same five-second window. A guessed shard count
/// closes the socket 4010 or 4011, neither of which a reconnect fixes.
/// Identifying past `max_concurrency` costs an INVALID_SESSION instead, which
/// is why the answer feeds `gateway_info.identify_queue`.
pub fn get_gateway_bot() -> Call(GatewayBot) {
  rest.get(
    [seg.lit("gateway"), seg.lit("bot")],
    rest.Decoded(gateway_info.bot_decoder()),
  )
}
