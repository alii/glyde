import gleam/http
import gleam/list
import gleam/option.{None, Some}
import glyde/rest/route
import glyde/rest/seg

const channel: String = "41771983423143937"

const message: String = "308994132968210433"

const other_message: String = "882899721348123456"

const guild: String = "197038439483310086"

const user: String = "80351110224678912"

const hook: String = "1234567890123456789"

/// Any fixed instant. Only the `Aged` sublimit reads it.
const now: Int = 1_700_000_000_000

fn tokened(token: String) -> route.Major {
  route.WebhookMajor(hook, route.webhook_token(Some(token)))
}

fn tokenless() -> route.Major {
  route.WebhookMajor(hook, route.webhook_token(None))
}

/// One row per shape of path, and so also what `from_path` may be handed.
fn derivation_table() -> List(#(String, String, route.Major)) {
  [
    #(
      "/channels/" <> channel <> "/messages",
      "/channels/{channel.id}/messages",
      route.ChannelMajor(channel),
    ),
    #(
      "/channels/" <> channel <> "/messages/" <> message,
      "/channels/{channel.id}/messages/{id}",
      route.ChannelMajor(channel),
    ),
    #(
      "/guilds/" <> guild <> "/channels",
      "/guilds/{guild.id}/channels",
      route.GuildMajor(guild),
    ),
    #(
      "/guilds/" <> guild <> "/members/" <> user <> "/roles/" <> message,
      "/guilds/{guild.id}/members/{id}/roles/{id}",
      route.GuildMajor(guild),
    ),
    // Discord names only channels, guilds and webhooks, so this collapses.
    #(
      "/applications/" <> hook <> "/commands",
      "/applications/{id}/commands",
      route.NoMajor,
    ),
    // A `guilds/{id}` pair is the major parameter wherever it sits, which is
    // how Discord limits this one: per guild, not per application.
    #(
      "/applications/" <> hook <> "/guilds/" <> guild <> "/commands",
      "/applications/{id}/guilds/{guild.id}/commands",
      route.GuildMajor(guild),
    ),
    #("/users/@me/channels", "/users/@me/channels", route.NoMajor),
    // Except under `/users`, where the whole path is one bucket and the guild
    // id is an ordinary id. `glyde/api/user` builds this row the same way.
    #(
      "/users/@me/guilds/" <> guild <> "/member",
      "/users/@me/guilds/{id}/member",
      route.NoMajor,
    ),
    #(
      "/webhooks/" <> hook <> "/tok-AAA",
      "/webhooks/{webhook.id}/{webhook.token}",
      tokened("tok-AAA"),
    ),
    #(
      "/webhooks/" <> hook <> "/tok-AAA/messages/@original",
      "/webhooks/{webhook.id}/{webhook.token}/messages/@original",
      tokened("tok-AAA"),
    ),
    // The id alone is a major parameter when the path carries no token.
    #("/webhooks/" <> hook, "/webhooks/{webhook.id}", tokenless()),
    #(
      "/channels/" <> channel <> "/messages/" <> message <> "/reactions/x/@me",
      "/channels/{channel.id}/messages/{id}/reactions/{reaction}",
      route.ChannelMajor(channel),
    ),
    // Nothing after `reactions` to collapse, so this keeps its own template.
    #(
      "/channels/" <> channel <> "/messages/" <> message <> "/reactions",
      "/channels/{channel.id}/messages/{id}/reactions",
      route.ChannelMajor(channel),
    ),
    #(
      "/interactions/" <> hook <> "/tok-BBB/callback",
      "/interactions/{id}/{opaque}/callback",
      route.NoMajor,
    ),
    #("/gateway/bot", "/gateway/bot", route.NoMajor),
  ]
}

pub fn derivation_table_test() {
  list.each(derivation_table(), fn(row) {
    let #(path, template, major) = row
    let derived = seg.from_path(http.Get, path, route.NoSublimit)
    assert #(path, route.template(derived)) == #(path, template)
    assert #(path, route.same_major(route.major(derived), major))
      == #(path, True)
  })
}

/// The query string is not part of a request's identity, and two methods on
/// one path are two buckets.
pub fn query_string_is_stripped_test() {
  let with_query =
    seg.from_path(
      http.Get,
      "/channels/" <> channel <> "/messages?limit=50&after=1",
      route.NoSublimit,
    )
  let without =
    seg.from_path(
      http.Get,
      "/channels/" <> channel <> "/messages",
      route.NoSublimit,
    )
  assert route.key(with_query, now_ms: now) == route.key(without, now_ms: now)
}

pub fn the_method_is_part_of_the_key_test() {
  let path = "/channels/" <> channel <> "/messages"
  let get = seg.from_path(http.Get, path, route.NoSublimit)
  let post = seg.from_path(http.Post, path, route.NoSublimit)
  assert route.key(get, now_ms: now) != route.key(post, now_ms: now)
}

pub fn a_leading_slash_is_optional_test() {
  let with_slash = seg.from_path(http.Get, "/gateway/bot", route.NoSublimit)
  let without = seg.from_path(http.Get, "gateway/bot", route.NoSublimit)
  assert route.key(with_slash, now_ms: now) == route.key(without, now_ms: now)
}

/// Two messages in one channel share a bucket; two channels do not.
pub fn ids_collapse_but_majors_do_not_test() {
  let path = fn(c, m) { "/channels/" <> c <> "/messages/" <> m }
  let first =
    seg.from_path(http.Delete, path(channel, message), route.NoSublimit)
  let second =
    seg.from_path(http.Delete, path(channel, other_message), route.NoSublimit)
  let elsewhere =
    seg.from_path(http.Delete, path(guild, message), route.NoSublimit)

  assert route.key(first, now_ms: now) == route.key(second, now_ms: now)
  assert route.key(first, now_ms: now) != route.key(elsewhere, now_ms: now)
}

/// Every reaction on a message is one bucket, whatever the emoji.
pub fn reactions_share_one_bucket_test() {
  let head = "/channels/" <> channel <> "/messages/" <> message <> "/reactions/"
  let mine =
    seg.from_path(http.Put, head <> "%F0%9F%91%8D/@me", route.NoSublimit)
  let theirs =
    seg.from_path(
      http.Put,
      head <> "custom%3A" <> hook <> "/" <> user,
      route.NoSublimit,
    )
  assert route.key(mine, now_ms: now) == route.key(theirs, now_ms: now)
}

/// The token tells two webhooks apart, so it is the major parameter and not
/// part of the route key.
pub fn a_webhook_token_is_a_major_parameter_and_not_a_route_test() {
  let first =
    seg.from_path(http.Post, "/webhooks/" <> hook <> "/AAA", route.NoSublimit)
  let second =
    seg.from_path(http.Post, "/webhooks/" <> hook <> "/BBB", route.NoSublimit)
  let untokened =
    seg.from_path(http.Post, "/webhooks/" <> hook, route.NoSublimit)

  assert route.route_key(first, now_ms: now)
    == route.route_key(second, now_ms: now)
  assert route.key(first, now_ms: now) != route.key(second, now_ms: now)
  assert route.key(first, now_ms: now) != route.key(untokened, now_ms: now)
  assert !route.same_major(route.major(first), route.major(untokened))
}

pub fn a_webhook_token_never_reaches_the_route_key_test() {
  let with_token =
    seg.from_path(
      http.Patch,
      "/webhooks/" <> hook <> "/s3cret/messages/@original",
      route.NoSublimit,
    )
  assert route.route_key(with_token, now_ms: now)
    == "PATCH /webhooks/{webhook.id}/{webhook.token}/messages/@original"
}

/// The interaction token is the other secret Discord puts in a path.
pub fn an_interaction_token_never_reaches_a_key_test() {
  let callback =
    seg.from_path(
      http.Post,
      "/interactions/" <> hook <> "/s3cret/callback",
      route.NoSublimit,
    )
  assert route.key(callback, now_ms: now)
    == "POST /interactions/{id}/{opaque}/callback unbound"
}

/// Discord exempts interaction callbacks from the global limit, so the limiter
/// has to spot one without matching on a string.
pub fn the_interaction_callback_is_unbound_test() {
  let callback =
    seg.from_path(
      http.Post,
      "/interactions/" <> hook <> "/tok/callback",
      route.NoSublimit,
    )
  assert route.unbound(callback)

  let follow_up =
    seg.from_path(http.Post, "/webhooks/" <> hook <> "/tok", route.NoSublimit)
  assert !route.unbound(follow_up)
}

pub fn everything_else_is_standard_test() {
  list.each(derivation_table(), fn(row) {
    let #(path, template, _) = row
    let derived = seg.from_path(http.Get, path, route.NoSublimit)
    let expected = template == "/interactions/{id}/{opaque}/callback"
    assert #(path, route.unbound(derived)) == #(path, expected)
  })
}

/// Deleting a message splits three ways by the message's age.
pub fn message_age_splits_three_ways_test() {
  let path = "/channels/" <> channel <> "/messages/" <> message
  let at = fn(created) {
    route.key(
      seg.from_path(http.Delete, path, route.Aged(created)),
      now_ms: now,
    )
  }

  let fresh = at(now - 5000)
  let ordinary = at(now - 3_600_000)
  let ancient = at(now - 30 * 24 * 60 * 60 * 1000)

  assert fresh != ordinary
  assert ordinary != ancient
  assert fresh != ancient
}

/// The thresholds are 10 seconds and 14 days, undocumented and inclusive.
pub fn message_age_boundaries_test() {
  let path = "/channels/" <> channel <> "/messages/" <> message
  let at = fn(age) {
    route.route_key(
      seg.from_path(http.Delete, path, route.Aged(now - age)),
      now_ms: now,
    )
  }
  let band = fn(name) {
    "DELETE /channels/{channel.id}/messages/{id} age:" <> name
  }

  assert at(0) == band("under-10s")
  assert at(10_000) == band("under-10s")
  assert at(10_001) == band("normal")
  assert at(1_209_599_999) == band("normal")
  assert at(1_209_600_000) == band("over-14d")
  assert at(2_000_000_000) == band("over-14d")
}

/// A future timestamp means the clocks disagree, and new is the safe read.
pub fn a_message_from_the_future_is_new_test() {
  let path = "/channels/" <> channel <> "/messages/" <> message
  let ahead =
    route.route_key(
      seg.from_path(http.Delete, path, route.Aged(now + 60_000)),
      now_ms: now,
    )
  assert ahead == "DELETE /channels/{channel.id}/messages/{id} age:under-10s"
}

/// Discord limits a named sublimit separately from its endpoint.
pub fn a_named_sublimit_is_its_own_bucket_test() {
  let path = "/channels/" <> channel
  let plain = seg.from_path(http.Patch, path, route.NoSublimit)
  let named = seg.from_path(http.Patch, path, route.Named("name-or-topic"))

  assert route.key(plain, now_ms: now)
    == "PATCH /channels/{channel.id} channel:" <> channel
  assert route.key(named, now_ms: now)
    == "PATCH /channels/{channel.id} sub:name-or-topic channel:" <> channel
}

/// A limiter holds the bucket hash per route and pairs it with the major.
pub fn the_key_is_the_route_key_plus_the_major_test() {
  let derived =
    seg.from_path(
      http.Get,
      "/channels/" <> channel <> "/messages",
      route.NoSublimit,
    )
  assert route.route_key(derived, now_ms: now)
    == "GET /channels/{channel.id}/messages"
  assert route.key(derived, now_ms: now)
    == "GET /channels/{channel.id}/messages channel:" <> channel
}

pub fn routes_without_a_major_share_one_sentinel_test() {
  let gateway = seg.from_path(http.Get, "/gateway/bot", route.NoSublimit)
  assert route.key(gateway, now_ms: now) == "GET /gateway/bot global"
}

/// Ids run 17 to 19 digits; a number outside that range is something else.
pub fn only_snowflake_shaped_numbers_collapse_test() {
  let short =
    seg.from_path(http.Get, "/channels/1234567890123456", route.NoSublimit)
  let long =
    seg.from_path(http.Get, "/channels/12345678901234567890", route.NoSublimit)

  assert route.template(short) == "/channels/1234567890123456"
  assert route.same_major(route.major(short), route.NoMajor)
  assert route.template(long) == "/channels/12345678901234567890"
  assert route.same_major(route.major(long), route.NoMajor)
}

/// `from_path` takes whatever a user wrote, and a useless key beats a crash.
pub fn from_path_is_total_test() {
  let key = fn(path) {
    route.key(seg.from_path(http.Get, path, route.NoSublimit), now_ms: now)
  }

  assert key("") == "GET / global"
  assert key("/") == "GET / global"
  assert key("?limit=1") == "GET / global"
  assert key("//channels//" <> channel <> "//")
    == "GET /channels/{channel.id} channel:" <> channel
  assert key("/channels/👍") == "GET /channels/👍 global"
}

/// A route built from a template agrees with one parsed from a path.
pub fn new_derives_the_class_test() {
  let built =
    route.new(
      http.Post,
      "/interactions/{id}/{opaque}/callback",
      route.NoMajor,
      route.NoSublimit,
    )
  assert route.unbound(built)

  let ordinary =
    route.new(
      http.Post,
      "/channels/{channel.id}/messages",
      route.ChannelMajor(channel),
      route.NoSublimit,
    )
  assert !route.unbound(ordinary)
}

/// The sublimit is the only part of a finished route a caller may move, and it
/// leaves the rest of the key alone.
pub fn with_sublimit_replaces_only_the_sublimit_test() {
  let plain =
    seg.from_path(http.Patch, "/channels/" <> channel, route.NoSublimit)
  let named = route.with_sublimit(plain, route.Named("name-or-topic"))

  assert route.sublimit(named) == route.Named("name-or-topic")
  assert route.template(named) == route.template(plain)
  assert route.major_key(named) == route.major_key(plain)
  assert route.sublimit(route.with_sublimit(named, route.NoSublimit))
    == route.NoSublimit
}
