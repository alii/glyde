import gleam/http
import gleam/list
import gleam/option.{None, Some}
import glyde/id
import glyde/rest/route
import glyde/rest/seg

const channel: String = "41771983423143937"

const message: String = "308994132968210433"

const guild: String = "197038439483310086"

const user: String = "80351110224678912"

const hook: String = "1234567890123456789"

const now: Int = 1_700_000_000_000

fn channel_id() -> id.ChannelId {
  id.from_string(channel)
}

fn message_id() -> id.MessageId {
  id.from_string(message)
}

fn guild_id() -> id.GuildId {
  id.from_string(guild)
}

fn user_id() -> id.UserId {
  id.from_string(user)
}

fn webhook_id() -> id.WebhookId {
  id.from_string(hook)
}

/// Segments, the URL they build and the bucket template, out of one walk.
fn resolve_table() -> List(#(List(seg.Seg), String, String, route.Major)) {
  [
    #(
      [seg.lit("channels"), seg.channel(channel_id()), seg.lit("messages")],
      "/channels/" <> channel <> "/messages",
      "/channels/{channel.id}/messages",
      route.ChannelMajor(channel),
    ),
    #(
      [
        seg.lit("channels"),
        seg.channel(channel_id()),
        seg.lit("messages"),
        seg.id(message_id()),
      ],
      "/channels/" <> channel <> "/messages/" <> message,
      "/channels/{channel.id}/messages/{id}",
      route.ChannelMajor(channel),
    ),
    #(
      [
        seg.lit("guilds"),
        seg.guild(guild_id()),
        seg.lit("members"),
        seg.id(user_id()),
      ],
      "/guilds/" <> guild <> "/members/" <> user,
      "/guilds/{guild.id}/members/{id}",
      route.GuildMajor(guild),
    ),
    #(
      [seg.lit("users"), seg.lit("@me"), seg.lit("guilds")],
      "/users/@me/guilds",
      "/users/@me/guilds",
      route.NoMajor,
    ),
    #(
      [seg.lit("webhooks"), seg.webhook(webhook_id(), "tok-AAA")],
      "/webhooks/" <> hook <> "/tok-AAA",
      "/webhooks/{webhook.id}/{webhook.token}",
      route.WebhookMajor(hook, route.webhook_token(Some("tok-AAA"))),
    ),
    // The tokenless form is one segment, not a token left empty.
    #(
      [seg.lit("webhooks"), seg.webhook_id(webhook_id())],
      "/webhooks/" <> hook,
      "/webhooks/{webhook.id}",
      route.WebhookMajor(hook, route.webhook_token(None)),
    ),
    #(
      [
        seg.lit("applications"),
        seg.id(webhook_id()),
        seg.lit("guilds"),
        seg.guild(guild_id()),
        seg.lit("commands"),
      ],
      "/applications/" <> hook <> "/guilds/" <> guild <> "/commands",
      "/applications/{id}/guilds/{guild.id}/commands",
      route.GuildMajor(guild),
    ),
    #(
      [
        seg.lit("interactions"),
        seg.id(webhook_id()),
        seg.opaque_text("tok-BBB"),
        seg.lit("callback"),
      ],
      "/interactions/" <> hook <> "/tok-BBB/callback",
      "/interactions/{id}/{opaque}/callback",
      route.NoMajor,
    ),
    #(
      [seg.lit("gateway"), seg.lit("bot")],
      "/gateway/bot",
      "/gateway/bot",
      route.NoMajor,
    ),
  ]
}

pub fn resolve_table_test() {
  list.each(resolve_table(), fn(row) {
    let #(segments, path, template, major) = row
    let resolved = seg.resolve(http.Get, segments)
    assert #(resolved.path, route.template(resolved.route)) == #(path, template)
    assert #(path, route.same_major(route.major(resolved.route), major))
      == #(path, True)
  })
}

/// A path cannot know a sublimit: only the caller knows the message's age.
pub fn resolve_carries_the_method_and_no_sublimit_test() {
  let resolved =
    seg.resolve(http.Delete, [
      seg.lit("channels"),
      seg.channel(channel_id()),
      seg.lit("messages"),
      seg.id(message_id()),
    ])
  assert route.method(resolved.route) == http.Delete
  assert route.sublimit(resolved.route) == route.NoSublimit
}

pub fn an_empty_path_is_the_root_test() {
  let resolved = seg.resolve(http.Get, [])
  assert resolved.path == "/"
  assert route.template(resolved.route) == "/"
  assert route.same_major(route.major(resolved.route), route.NoMajor)
}

/// The emoji and the reactor are erased from the template but not the URL.
pub fn a_reaction_keeps_its_tail_in_the_url_only_test() {
  let head = [
    seg.lit("channels"),
    seg.channel(channel_id()),
    seg.lit("messages"),
    seg.id(message_id()),
    seg.lit("reactions"),
  ]
  let mine =
    seg.resolve(
      http.Put,
      list.append(head, [seg.reaction("👍"), seg.lit("@me")]),
    )
  let theirs =
    seg.resolve(
      http.Put,
      list.append(head, [seg.reaction("mymoji:" <> message), seg.id(user_id())]),
    )

  assert mine.path
    == "/channels/"
    <> channel
    <> "/messages/"
    <> message
    <> "/reactions/%F0%9F%91%8D/@me"
  assert theirs.path
    == "/channels/"
    <> channel
    <> "/messages/"
    <> message
    <> "/reactions/mymoji%3A"
    <> message
    <> "/"
    <> user

  assert route.template(mine.route)
    == "/channels/{channel.id}/messages/{id}/reactions/{reaction}"
  assert route.key(mine.route, now_ms: now)
    == route.key(theirs.route, now_ms: now)
}

/// Removing every reaction has nothing after `reactions` to collapse.
pub fn removing_every_reaction_is_a_different_template_test() {
  let all =
    seg.resolve(http.Delete, [
      seg.lit("channels"),
      seg.channel(channel_id()),
      seg.lit("messages"),
      seg.id(message_id()),
      seg.lit("reactions"),
    ])
  assert route.template(all.route)
    == "/channels/{channel.id}/messages/{id}/reactions"
}

/// A literal is already a valid path; encoding it would ask for `%40me`.
pub fn literals_are_not_encoded_test() {
  let resolved =
    seg.resolve(http.Get, [seg.lit("users"), seg.lit("@me"), seg.lit("~x.y_z")])
  assert resolved.path == "/users/@me/~x.y_z"
}

/// The other half of that: `loose` is a caller's value, so the path encodes it
/// and it cannot add a segment. The template keeps the text, because there is
/// no placeholder to stand in for a segment glyde does not recognise.
pub fn loose_text_is_encoded_and_a_literal_is_not_test() {
  let resolved =
    seg.resolve(http.Get, [seg.lit("users"), seg.lit("@me"), seg.loose("a/b")])
  assert resolved.path == "/users/@me/a%2Fb"
  assert route.template(resolved.route) == "/users/@me/a/b"
}

/// A snowflake handed to `loose` is an ordinary id, template and all.
pub fn loose_recognises_a_snowflake_test() {
  let resolved = seg.resolve(http.Get, [seg.lit("users"), seg.loose(user)])
  assert resolved.path == "/users/" <> user
  assert route.template(resolved.route) == "/users/{id}"
}

/// `id.from_string` does not validate, so encoding turns a crafted id into a
/// 404 rather than an authenticated request somewhere else.
pub fn an_id_cannot_climb_out_of_its_segment_test() {
  let hostile: id.MessageId = id.from_string("1/../../users/@me")
  let resolved =
    seg.resolve(http.Get, [
      seg.lit("channels"),
      seg.channel(channel_id()),
      seg.lit("messages"),
      seg.id(hostile),
    ])
  assert resolved.path
    == "/channels/" <> channel <> "/messages/1%2F..%2F..%2Fusers%2F%40me"
}

/// The first major segment wins; a channel id further along is an ordinary id.
pub fn only_the_first_major_counts_test() {
  let resolved =
    seg.resolve(http.Get, [
      seg.lit("guilds"),
      seg.guild(guild_id()),
      seg.lit("channels"),
      seg.channel(channel_id()),
    ])
  assert route.same_major(route.major(resolved.route), route.GuildMajor(guild))
  assert route.template(resolved.route)
    == "/guilds/{guild.id}/channels/{channel.id}"
}

/// Two spellings of one route would be two buckets and twice the traffic
/// Discord allows.
pub fn a_parsed_route_matches_the_built_one_test() {
  let cases = [
    #(http.Post, [
      seg.lit("channels"),
      seg.channel(channel_id()),
      seg.lit("messages"),
    ]),
    #(http.Delete, [
      seg.lit("channels"),
      seg.channel(channel_id()),
      seg.lit("messages"),
      seg.id(message_id()),
    ]),
    #(http.Put, [
      seg.lit("guilds"),
      seg.guild(guild_id()),
      seg.lit("members"),
      seg.id(user_id()),
      seg.lit("roles"),
      seg.id(message_id()),
    ]),
    #(http.Put, [
      seg.lit("channels"),
      seg.channel(channel_id()),
      seg.lit("messages"),
      seg.id(message_id()),
      seg.lit("reactions"),
      seg.reaction("👍"),
      seg.lit("@me"),
    ]),
    #(http.Delete, [
      seg.lit("channels"),
      seg.channel(channel_id()),
      seg.lit("messages"),
      seg.id(message_id()),
      seg.lit("reactions"),
    ]),
    #(http.Post, [seg.lit("webhooks"), seg.webhook(webhook_id(), "tok-AAA")]),
    #(http.Get, [seg.lit("webhooks"), seg.webhook_id(webhook_id())]),
    #(http.Patch, [
      seg.lit("webhooks"),
      seg.webhook(webhook_id(), "tok-AAA"),
      seg.lit("messages"),
      seg.lit("@original"),
    ]),
    // The guild is the major parameter here even though the application id
    // comes first, so a parser that only looks at the head disagrees.
    #(http.Post, [
      seg.lit("applications"),
      seg.id(webhook_id()),
      seg.lit("guilds"),
      seg.guild(guild_id()),
      seg.lit("commands"),
    ]),
    // And the other way for the same pair: a `/users` path is one bucket, so
    // `glyde/api/user` writes the guild as a plain id and the parser has to
    // read it back as one.
    #(http.Get, [
      seg.lit("users"),
      seg.lit("@me"),
      seg.lit("guilds"),
      seg.id(guild_id()),
      seg.lit("member"),
    ]),
    #(http.Post, [
      seg.lit("interactions"),
      seg.id(webhook_id()),
      seg.opaque_text("tok-BBB"),
      seg.lit("callback"),
    ]),
    #(http.Get, [seg.lit("gateway"), seg.lit("bot")]),
  ]

  list.each(cases, fn(row) {
    let #(method, segments) = row
    let built = seg.resolve(method, segments)
    let parsed = seg.from_path(method, built.path, route.NoSublimit)
    assert #(built.path, route.key(built.route, now_ms: now))
      == #(built.path, route.key(parsed, now_ms: now))
  })
}

/// Discord's oldest ids are shorter than the 17 digits a string parser has to
/// guess with, so it misses the major parameter and a typed segment cannot.
pub fn typed_segments_beat_parsing_a_url_test() {
  let old: id.ChannelId = id.from_string("1234567890123456")
  let built =
    seg.resolve(http.Get, [
      seg.lit("channels"),
      seg.channel(old),
      seg.lit("messages"),
    ])
  let parsed = seg.from_path(http.Get, built.path, route.NoSublimit)

  assert route.same_major(
    route.major(built.route),
    route.ChannelMajor("1234567890123456"),
  )
  assert route.same_major(route.major(parsed), route.NoMajor)
}
