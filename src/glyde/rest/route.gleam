//// A route is the rate-limit identity of a call. `glyde/rest/seg` is the only
//// way to build one: alongside the path from typed segments, or read back out
//// of a path string with `seg.from_path`. Both walk the same segment rules, so
//// two spellings of one endpoint cannot land in two buckets.

import gleam/http
import gleam/option.{type Option, None, Some}
import gleam/string

/// Opaque because `class` is derived from `template`. A record update could
/// move one and leave the other, and a route that wrongly claims to be an
/// interaction callback skips the global limit.
pub opaque type Route {
  Route(
    method: http.Method,
    template: String,
    major: Major,
    class: Class,
    sublimit: Sublimit,
  )
}

/// Discord's major parameters. Two channels have independent buckets for the
/// same endpoint; two messages in the same channel do not.
pub type Major {
  NoMajor
  ChannelMajor(String)
  GuildMajor(String)
  /// Id and token together. The token is absent on the
  /// `GET /webhooks/{webhook.id}` form, where Discord takes the id alone.
  WebhookMajor(id: String, token: WebhookToken)
}

/// A live credential that is also half a major parameter. A closure, not a
/// field, because `echo` and `string.inspect` read straight through an opaque
/// record. Reaching the bucket key is the one thing it still has to do, so
/// `key` and `major_key` return the token in plain text and everything else
/// does not.
pub opaque type WebhookToken {
  WebhookToken(reveal: fn() -> Option(String))
}

/// `None` is the tokenless `GET /webhooks/{webhook.id}` form.
pub fn webhook_token(token: Option(String)) -> WebhookToken {
  WebhookToken(fn() { token })
}

/// Derived from the template by `new`, never set by hand.
type Class {
  /// Per-bucket limits plus the global 50/s.
  Standard
  /// Interaction callbacks: exempt from the global limit and unbucketed.
  Unbound
}

/// Discord's undocumented per-resource sublimits. Invisible in the headers:
/// a 429 with a large `retry_after` on a bucket that still claims capacity.
pub type Sublimit {
  NoSublimit
  /// A named subset of an endpoint: "name-or-topic" on `PATCH /channels/{id}`
  /// is 2 per 10 minutes.
  Named(String)
  /// Deleting a message older than two weeks lands in a different bucket
  /// (discord-api-docs#1295). The limiter has the clock, so it resolves this.
  Aged(created_at_ms: Int)
}

// `seg` writes every template with these, whichever way it built the route.

pub const channel_placeholder: String = "{channel.id}"

pub const guild_placeholder: String = "{guild.id}"

pub const webhook_placeholder: String = "{webhook.id}"

/// Half of a webhook's major parameter, which has no business in a template.
pub const webhook_token_placeholder: String = "{webhook.token}"

/// Any id that is not a major parameter. Discord buckets these together, so
/// they need no name of their own.
pub const id_placeholder: String = "{id}"

/// A reaction emoji and everything after it.
pub const reaction_placeholder: String = "{reaction}"

/// Text that is neither an id nor a literal: an interaction token, an invite
/// code.
pub const opaque_placeholder: String = "{opaque}"

/// Under 10 seconds old, per discord-api-docs#1092.
const fresh_ms: Int = 10_000

/// Two weeks, per discord-api-docs#1295.
const ancient_ms: Int = 1_209_600_000

/// Every route goes through here, so the one endpoint Discord exempts from the
/// global limit is recognised in a single place.
pub fn new(
  method: http.Method,
  template: String,
  major: Major,
  sublimit: Sublimit,
) -> Route {
  Route(method:, template:, major:, class: classify(template), sublimit:)
}

/// The one part of a route a caller may change: a path cannot know how old the
/// message it deletes is.
pub fn with_sublimit(route: Route, sublimit: Sublimit) -> Route {
  Route(..route, sublimit:)
}

pub fn method(route: Route) -> http.Method {
  route.method
}

/// The unsubstituted template, e.g. "/channels/{channel.id}/messages".
pub fn template(route: Route) -> String {
  route.template
}

pub fn major(route: Route) -> Major {
  route.major
}

pub fn sublimit(route: Route) -> Sublimit {
  route.sublimit
}

/// Exempt from the global limit and in no bucket. True for interaction
/// callbacks and nothing else.
pub fn unbound(route: Route) -> Bool {
  route.class == Unbound
}

/// The provisional bucket key, until `x-ratelimit-bucket` names the real one.
/// Holds the webhook token on a webhook route, so keep it out of logs.
pub fn key(route: Route, now_ms now_ms: Int) -> String {
  route_key(route, now_ms: now_ms) <> " " <> major_key(route)
}

/// The route half of the key. Discord reports one hash per route and the real
/// bucket is that hash paired with the major parameter, so both halves exist.
pub fn route_key(route: Route, now_ms now_ms: Int) -> String {
  http.method_to_string(route.method)
  <> " "
  <> route.template
  <> sublimit_key(route.sublimit, now_ms)
}

/// An interaction has three seconds to be answered, and Discord exempts this
/// one endpoint from the global limit.
fn classify(template: String) -> Class {
  case
    string.starts_with(template, "/interactions/")
    && string.ends_with(template, "/callback")
  {
    True -> Unbound
    False -> Standard
  }
}

/// The major half of the key, to pair with Discord's `x-ratelimit-bucket`
/// hash. Holds the webhook token on a webhook route, so keep it out of logs.
pub fn major_key(route: Route) -> String {
  case route.class {
    // An unbound route is in no bucket; the key exists to not look like one.
    Unbound -> "unbound"
    Standard -> major_to_key(route.major)
  }
}

/// Whether two majors name the same bucket. `Major` holds a closure, and
/// comparing closures with `==` does not answer this question.
pub fn same_major(one: Major, other: Major) -> Bool {
  major_to_key(one) == major_to_key(other)
}

fn major_to_key(major: Major) -> String {
  case major {
    NoMajor -> "global"
    ChannelMajor(id) -> "channel:" <> id
    GuildMajor(id) -> "guild:" <> id
    WebhookMajor(id, token) ->
      case token.reveal() {
        None -> "webhook:" <> id
        Some(text) -> "webhook:" <> id <> "/" <> text
      }
  }
}

fn sublimit_key(sublimit: Sublimit, now_ms: Int) -> String {
  case sublimit {
    NoSublimit -> ""
    Named(name) -> " sub:" <> name
    Aged(created_at_ms) -> " age:" <> age_band(now_ms - created_at_ms)
  }
}

/// Three bands, undocumented outside discord-api-docs#1092 and #1295. A
/// message dated in the future is a clock disagreement, and counts as new.
fn age_band(age_ms: Int) -> String {
  case age_ms {
    ms if ms <= fresh_ms -> "under-10s"
    ms if ms >= ancient_ms -> "over-14d"
    _ -> "normal"
  }
}
