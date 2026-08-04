import gleam/json

import glyde/gateway_info.{
  type GatewayBot, GatewayBot, GatewayInfo, Open, SessionStartLimit, Spent,
}
import glyde/identify_queue.{Deny, Request}
import glyde/internal/url
import glyde/rest

/// A real `GET /gateway/bot` response for a one-shard bot.
const live_bot: String = "{\"url\":\"wss://gateway.discord.gg\",\"shards\":1,\"session_start_limit\":{\"max_concurrency\":1,\"remaining\":1000,\"reset_after\":0,\"total\":1000}}"

const url_only: String = "{\"url\":\"wss://gateway.discord.gg\"}"

fn parse_bot(text: String) -> Result(GatewayBot, json.DecodeError) {
  json.parse(text, gateway_info.bot_decoder())
}

fn host(text: String) -> url.Host {
  let assert Ok(host) = url.host_of(text)
  host
}

fn live() -> GatewayBot {
  GatewayBot(
    url: "wss://gateway.discord.gg",
    dial_host: host("gateway.discord.gg"),
    shards: 1,
    session_start_limit: SessionStartLimit(
      total: 1000,
      remaining: 1000,
      reset_after_ms: 0,
      max_concurrency: 1,
    ),
  )
}

pub fn decodes_the_live_gateway_bot_response_test() {
  let assert Ok(bot) = parse_bot(live_bot)
  assert bot == live()
}

pub fn decodes_the_url_only_response_test() {
  let assert Ok(info) = json.parse(url_only, gateway_info.decoder())
  assert info
    == GatewayInfo(
      url: "wss://gateway.discord.gg",
      dial_host: host("gateway.discord.gg"),
    )
}

/// A bot cannot start without this response, so an unknown key must cost
/// nothing.
pub fn an_unknown_key_is_ignored_test() {
  let assert Ok(bot) =
    parse_bot(
      "{\"url\":\"wss://gateway.discord.gg\",\"shards\":1,\"session_start_limit\":{\"max_concurrency\":1,\"remaining\":1000,\"reset_after\":0,\"total\":1000,\"burst\":true},\"experiment\":\"on\"}",
    )
  assert bot.url == "wss://gateway.discord.gg"
  assert bot.session_start_limit.max_concurrency == 1
}

/// Discord writes `shards` as `2` and as `2.0`.
pub fn a_whole_number_may_carry_a_decimal_point_test() {
  let assert Ok(bot) =
    parse_bot(
      "{\"url\":\"wss://gateway.discord.gg\",\"shards\":2.0,\"session_start_limit\":{\"max_concurrency\":4.0,\"remaining\":1000,\"reset_after\":0,\"total\":1000}}",
    )
  assert bot.shards == 2
  assert bot.session_start_limit.max_concurrency == 4
}

/// Guessing the session limit high costs the token.
pub fn a_missing_session_start_limit_is_an_error_test() {
  let assert Error(_) =
    parse_bot("{\"url\":\"wss://gateway.discord.gg\",\"shards\":1}")
}

/// `max_concurrency` is the queue's bucket count.
pub fn the_identify_queue_takes_its_buckets_from_the_response_test() {
  let assert Ok(sixteen) =
    parse_bot(
      "{\"url\":\"wss://gateway.discord.gg\",\"shards\":32,\"session_start_limit\":{\"max_concurrency\":16,\"remaining\":940,\"reset_after\":3600000,\"total\":1000}}",
    )
  let queue = gateway_info.identify_queue(sixteen, now_ms: 0)

  assert identify_queue.remaining(queue) == 940
  assert identify_queue.rate_limit_key(queue, shard: 17) == 1
  assert identify_queue.rate_limit_key(queue, shard: 16) == 0
}

/// `reset_after` is a duration and the queue counts in instants.
pub fn reset_after_becomes_an_instant_on_the_callers_clock_test() {
  let assert Ok(spent) =
    parse_bot(
      "{\"url\":\"wss://gateway.discord.gg\",\"shards\":1,\"session_start_limit\":{\"max_concurrency\":1,\"remaining\":0,\"reset_after\":60000,\"total\":1000}}",
    )
  let queue = gateway_info.identify_queue(spent, now_ms: 1_000_000)

  let #(_, out) =
    identify_queue.step(queue, now_ms: 1_000_000, input: Request(shard: 0))
  assert out == [Deny(shard: 0, refresh_at_ms: 1_060_000)]
}

pub fn start_window_reads_the_budget_test() {
  let assert Ok(fresh) = parse_bot(live_bot)
  assert gateway_info.start_window(fresh, now_ms: 1_000_000)
    == Open(remaining: 1000)

  let assert Ok(spent) =
    parse_bot(
      "{\"url\":\"wss://gateway.discord.gg\",\"shards\":1,\"session_start_limit\":{\"max_concurrency\":1,\"remaining\":0,\"reset_after\":60000,\"total\":1000}}",
    )
  // A duration on the wire, an instant on the caller's clock.
  assert gateway_info.start_window(spent, now_ms: 1_000_000)
    == Spent(resets_at_ms: 1_060_000)
}

/// `gateway.Config.host` takes no scheme, and every URL Discord hands out has
/// one, so the response carries the two separately.
pub fn the_dial_host_drops_the_scheme_test() {
  let assert Ok(bot) = parse_bot(live_bot)
  assert bot.dial_host == host("gateway.discord.gg")

  let assert Ok(with_query) =
    json.parse(
      "{\"url\":\"wss://gateway.discord.gg/?v=10\"}",
      gateway_info.decoder(),
    )
  assert with_query.dial_host == host("gateway.discord.gg")
}

/// A response with no host in its URL is broken, not a host to guess: nothing
/// downstream can dial it, so it never becomes a `GatewayInfo` at all.
pub fn a_url_with_no_host_fails_the_decode_test() {
  assert json.parse("{\"url\":\"\"}", gateway_info.decoder()) |> is_error
  assert json.parse("{\"url\":\"wss://\"}", gateway_info.decoder()) |> is_error
}

fn is_error(result: Result(a, e)) -> Bool {
  case result {
    Error(_) -> True
    Ok(_) -> False
  }
}

fn answer(call: rest.Call(a), body: String) -> Result(a, rest.Failure) {
  rest.response(call, status: 200, headers: [], body: <<body:utf8>>)
}

/// A `Call` carries the decoder for the response, not only the path.
pub fn the_endpoints_decode_their_own_responses_test() {
  assert answer(gateway_info.get_bot(), live_bot) == Ok(live())
  assert answer(gateway_info.get(), url_only)
    == Ok(GatewayInfo(
      url: "wss://gateway.discord.gg",
      dial_host: host("gateway.discord.gg"),
    ))
}
