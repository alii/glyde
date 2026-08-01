//// The concrete path and the rate-limit template come out of one walk of the
//// same typed segments, so they cannot drift apart. A path glyde does not
//// wrap goes through `from_path`, which classifies the raw segments and then
//// takes the same walk.

import gleam/http
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import glyde/id.{type Id}
import glyde/internal/url
import glyde/rest/route.{type Major, type Route, type Sublimit}

pub opaque type Seg {
  /// A constant written in the source, from `lit`. The only segment that
  /// reaches the path unencoded.
  Literal(String)
  MajorChannel(String)
  MajorGuild(String)
  MajorWebhook(id: String, token: Option(String))
  PlainId(String)
  ReactionEmoji(String)
  OpaqueText(String)
  /// Text out of a caller's value, from `loose`. It keeps its shape in the
  /// template because the bucket depends on it, and is encoded in the path.
  Unknown(String)
}

pub type Resolved {
  Resolved(path: String, route: Route)
}

/// A literal path segment, not percent-encoded: encoding one would turn
/// `@me` into `%40me`, a different resource to Discord. For a constant only;
/// text from a caller's value goes through `loose`.
pub fn lit(text: String) -> Seg {
  Literal(text)
}

/// A segment that is not a constant and is not an id glyde has a type for: it
/// is percent-encoded in the path, and stays as written in the bucket template
/// because there is nothing to replace it with. A snowflake is an ordinary id.
pub fn loose(text: String) -> Seg {
  case is_snowflake(text) {
    True -> PlainId(text)
    False -> Unknown(text)
  }
}

/// A channel id, a major parameter: erased from the template, kept in the
/// bucket key.
pub fn channel(channel_id: Id(id.Channel)) -> Seg {
  MajorChannel(id.to_string(channel_id))
}

/// A guild id, the other single-segment major parameter.
pub fn guild(guild_id: Id(id.Guild)) -> Seg {
  MajorGuild(id.to_string(guild_id))
}

/// A webhook's id and token, one major parameter across two path segments.
/// One value here, so half of it cannot reach a bucket key.
pub fn webhook(hook: Id(id.Webhook), token: String) -> List(Seg) {
  [MajorWebhook(id.to_string(hook), Some(token))]
}

/// The tokenless form, `GET /webhooks/{webhook.id}`, which Discord buckets by
/// the id alone. One path segment, not two.
pub fn webhook_id(hook: Id(id.Webhook)) -> List(Seg) {
  [MajorWebhook(id.to_string(hook), None)]
}

/// A non-major id: a message id, a user id inside a guild route. Erased from
/// the template and absent from the bucket key.
pub fn id(snowflake: Id(kind)) -> Seg {
  PlainId(id.to_string(snowflake))
}

/// A reaction emoji. Discord buckets every reaction on a message together, so
/// the emoji and everything after it leaves the template.
pub fn reaction(emoji: String) -> Seg {
  ReactionEmoji(emoji)
}

/// Free text that is neither an id nor a literal: an interaction token, an
/// invite code. Erased from the template.
pub fn opaque_text(text: String) -> Seg {
  OpaqueText(text)
}

/// Sublimit is left at `NoSublimit`: a path cannot know how old the message it
/// deletes is. The caller sets that on the route.
pub fn resolve(method: http.Method, segments: List(Seg)) -> Resolved {
  let walked = list.fold(segments, Walk([], [], False, route.NoMajor), step)
  Resolved(
    path: join(walked.path),
    route: route.new(
      method,
      join(walked.template),
      walked.major,
      route.NoSublimit,
    ),
  )
}

/// The rate-limit identity of a path glyde does not wrap, read back out of the
/// path string. It classifies the segments and then takes the walk `resolve`
/// takes, so a hand-written path and a built one cannot disagree about which
/// bucket they are in.
///
/// Only ids and the two token positions are replaced. Any other variable
/// segment stays in the template, so keep further secrets out of the path.
pub fn from_path(
  method: http.Method,
  path: String,
  sublimit: Sublimit,
) -> Route {
  let segments =
    path
    |> before_query
    |> string.split("/")
    |> list.filter(fn(segment) { segment != "" })

  // The walk re-encodes a path the caller already has, so that half is thrown
  // away.
  let Resolved(path: _, route: read) = resolve(method, classify(segments))
  route.with_sublimit(read, sublimit)
}

type Walk {
  Walk(
    path: List(String),
    template: List(String),
    /// Set by a reaction segment. Everything after one leaves the template.
    collapsed: Bool,
    major: Major,
  )
}

fn step(walk: Walk, segment: Seg) -> Walk {
  let template = case walk.collapsed {
    True -> walk.template
    False -> [template_of(segment), ..walk.template]
  }
  // First major segment wins. No route has two, and Discord limits
  // `/applications/{id}/guilds/{guild.id}/commands` per guild, so position in
  // the path is not what decides it.
  let major = case walk.major {
    route.NoMajor -> major_of(segment)
    found -> found
  }
  Walk(
    path: [path_of(segment), ..walk.path],
    template:,
    collapsed: walk.collapsed || is_reaction(segment),
    major:,
  )
}

fn join(reversed: List(String)) -> String {
  "/" <> string.join(list.reverse(reversed), "/")
}

/// Ids are encoded too. `id.from_string` does not validate, so an id carrying
/// `/../` becomes a 404 rather than a request somewhere else.
fn path_of(segment: Seg) -> String {
  case segment {
    Literal(text) -> text
    MajorWebhook(value, Some(token)) ->
      url.percent_encode(value) <> "/" <> url.percent_encode(token)
    MajorChannel(value)
    | MajorGuild(value)
    | MajorWebhook(value, None)
    | PlainId(value)
    | ReactionEmoji(value)
    | OpaqueText(value)
    | Unknown(value) -> url.percent_encode(value)
  }
}

fn template_of(segment: Seg) -> String {
  case segment {
    Literal(text) -> text
    MajorChannel(_) -> route.channel_placeholder
    MajorGuild(_) -> route.guild_placeholder
    MajorWebhook(_, None) -> route.webhook_placeholder
    MajorWebhook(_, Some(_)) ->
      route.webhook_placeholder <> "/" <> route.webhook_token_placeholder
    PlainId(_) -> route.id_placeholder
    ReactionEmoji(_) -> route.reaction_placeholder
    OpaqueText(_) -> route.opaque_placeholder
    Unknown(text) -> text
  }
}

fn major_of(segment: Seg) -> Major {
  case segment {
    MajorChannel(value) -> route.ChannelMajor(value)
    MajorGuild(value) -> route.GuildMajor(value)
    MajorWebhook(value, token) ->
      route.WebhookMajor(value, route.webhook_token(token))
    _ -> route.NoMajor
  }
}

fn is_reaction(segment: Seg) -> Bool {
  case segment {
    ReactionEmoji(_) -> True
    _ -> False
  }
}

/// One rule per shape Discord gives a meaning to, first match wins, and the
/// walk decides which of the majors found is the route's own.
fn classify(segments: List(String)) -> List(Seg) {
  case segments {
    [] -> []

    ["channels", value, ..rest] ->
      major_pair("channels", MajorChannel, value, rest)

    ["guilds", value, ..rest] -> major_pair("guilds", MajorGuild, value, rest)

    // The exception to the pair rules: Discord buckets every `/users` route
    // together, so nothing inside one is a major parameter. Not the user id,
    // and not the guild in `/users/@me/guilds/{id}`, which addresses the bot's
    // own membership rather than the guild. `glyde/api/user` says the same.
    ["users", ..rest] -> [Literal("users"), ..list.map(rest, loose)]

    ["webhooks", value, token, ..rest] ->
      case is_snowflake(value) {
        True -> [
          Literal("webhooks"),
          MajorWebhook(value, Some(token)),
          ..classify(rest)
        ]
        False -> [Literal("webhooks"), ..classify([value, token, ..rest])]
      }

    ["webhooks", value] ->
      major_pair("webhooks", fn(hook) { MajorWebhook(hook, None) }, value, [])

    // The third segment is an interaction token whatever it looks like, and
    // it must not reach a key.
    ["interactions", value, token, ..rest] -> [
      Literal("interactions"),
      loose(value),
      OpaqueText(token),
      ..classify(rest)
    ]

    ["reactions", emoji, ..rest] -> [
      Literal("reactions"),
      ReactionEmoji(emoji),
      ..classify(rest)
    ]

    [segment, ..rest] -> [loose(segment), ..classify(rest)]
  }
}

/// A literal followed by a snowflake is that literal's major parameter. Any
/// other value goes back through `classify` alone, so `/channels/@me` keeps its
/// shape and a second rule can still claim it.
fn major_pair(
  literal: String,
  major: fn(String) -> Seg,
  value: String,
  rest: List(String),
) -> List(Seg) {
  case is_snowflake(value) {
    True -> [Literal(literal), major(value), ..classify(rest)]
    False -> [Literal(literal), ..classify([value, ..rest])]
  }
}

fn before_query(path: String) -> String {
  case string.split_once(path, "?") {
    Ok(#(before, _)) -> before
    Error(_) -> path
  }
}

/// Discord's ids run to 17, 18 or 19 digits.
fn is_snowflake(text: String) -> Bool {
  let length = string.length(text)
  length >= 17 && length <= 19 && all_digits(string.to_graphemes(text))
}

fn all_digits(graphemes: List(String)) -> Bool {
  list.all(graphemes, fn(grapheme) {
    case grapheme {
      "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
      _ -> False
    }
  })
}
