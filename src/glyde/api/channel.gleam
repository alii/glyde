//// Messages, reactions, pins, typing, the channel itself, and the threads
//// that hang off one.
////
//// ```gleam
//// let call = channel.create_message(channel_id, body.json(fields))
//// let request = rest.request(config, call)
//// ```

import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import glyde/id
import glyde/model/channel.{type Channel, type ThreadList, type ThreadMetadata}
import glyde/model/emoji.{type Emoji, Custom, Unicode}
import glyde/model/message.{
  type Message, type PinList, type PinnedMessage, type ReactionType,
}
import glyde/model/user.{type User}
import glyde/rest.{type Call}
import glyde/rest/body.{type Body}
import glyde/rest/query
import glyde/rest/seg

/// Where in a channel's history to read. One value, not three optional fields,
/// because Discord rejects two cursors on one request.
pub type MessageCursor {
  /// Centred on a message, returning the ones either side of it.
  Around(id.MessageId)
  /// Older than a message.
  Before(id.MessageId)
  /// Newer than a message.
  After(id.MessageId)
}

/// `GET /channels/{channel.id}/messages`. `None` is no cursor, which Discord
/// reads as the newest messages. Discord caps `limit` at 100 and defaults it
/// to 50.
pub fn get_messages(
  channel: id.ChannelId,
  cursor cursor: Option(MessageCursor),
  limit limit: Option(Int),
) -> Call(List(Message)) {
  rest.get(messages_at(channel), rest.Decoded(decode.list(message.decoder())))
  |> rest.query(
    list.flatten([cursor_param(cursor), query.opt("limit", limit, query.number)]),
  )
}

fn cursor_param(cursor: Option(MessageCursor)) -> List(query.Param) {
  case cursor {
    None -> []
    Some(Around(message)) -> query.one("around", query.snowflake(message))
    Some(Before(message)) -> query.one("before", query.snowflake(message))
    Some(After(message)) -> query.one("after", query.snowflake(message))
  }
}

pub fn get_message(
  channel: id.ChannelId,
  message: id.MessageId,
) -> Call(Message) {
  rest.get(message_at(channel, message), rest.Decoded(message.decoder()))
}

/// `POST /channels/{channel.id}/messages`. Attach files with `rest.attach`.
pub fn create_message(channel: id.ChannelId, body: Body) -> Call(Message) {
  rest.post(messages_at(channel), body, rest.Decoded(message.decoder()))
}

/// `PATCH /channels/{channel.id}/messages/{message.id}`. An `attachments`
/// array is the complete list of files to keep, so anything left out is
/// deleted. Omitting the key keeps them all.
pub fn edit_message(
  channel: id.ChannelId,
  message: id.MessageId,
  body: Body,
) -> Call(Message) {
  rest.patch(
    message_at(channel, message),
    body,
    rest.Decoded(message.decoder()),
  )
}

/// `DELETE /channels/{channel.id}/messages/{message.id}`. Discord splits this
/// route into three buckets by the target's age and reports none of it in the
/// headers (discord-api-docs#1092, #1295), so `route.Aged` carries the age.
pub fn delete_message(
  channel: id.ChannelId,
  message: id.MessageId,
) -> Call(Nil) {
  rest.delete(message_at(channel, message), rest.NoContent(Nil))
  // `id.from_string` does not validate, so the id may not be a snowflake.
  // Discord's epoch is the safe answer: slowest bucket, and outside the
  // bulk-delete window.
  |> rest.age_bucket(id.created_at_ms_or(message, default: id.discord_epoch_ms))
}

/// `POST /channels/{channel.id}/messages/bulk-delete`. Discord takes 2 to 100
/// ids and rejects the whole request if any message is over two weeks old.
pub fn bulk_delete_messages(channel: id.ChannelId, body: Body) -> Call(Nil) {
  rest.post(
    list.append(messages_at(channel), [seg.lit("bulk-delete")]),
    body,
    rest.NoContent(Nil),
  )
}

/// The `{emoji}` in a reaction path. Only ever decoded text, so a value that
/// is already percent-encoded cannot be handed in and encoded twice.
pub opaque type ReactionEmoji {
  ReactionEmoji(param: String)
}

/// A standard emoji, written as the characters themselves: `"🔥"`.
pub fn unicode_emoji(text: String) -> ReactionEmoji {
  ReactionEmoji(text)
}

/// A custom guild emoji, which Discord wants as `name:id`. The colon is
/// percent-encoded on the way out, which Discord accepts.
pub fn custom_emoji(emoji: id.EmojiId, name: String) -> ReactionEmoji {
  ReactionEmoji(name <> ":" <> id.to_string(emoji))
}

/// A custom emoji whose name you do not have. Discord reads only the id, so
/// the name goes out as the literal `e`.
pub fn custom_emoji_by_id(emoji: id.EmojiId) -> ReactionEmoji {
  ReactionEmoji("e:" <> id.to_string(emoji))
}

/// An emoji that came off the wire, from a reaction event or a component.
pub fn reaction_emoji(emoji: Emoji) -> ReactionEmoji {
  case emoji.kind {
    Unicode(name:) -> unicode_emoji(name)
    Custom(id: emoji_id, name: Some(name)) -> custom_emoji(emoji_id, name)
    Custom(id: emoji_id, name: None) -> custom_emoji_by_id(emoji_id)
  }
}

/// Which reactions the route asks for. Two variants and not the model's
/// `ReactionType`: that one has an unknown tail for reading events, and
/// putting a number Discord does not know on `type` is a 400.
pub type ReactionKind {
  Normal
  Burst
}

/// A reaction type this route cannot ask for: a kind Discord added after this
/// build. `wire_value` is the number it sent, which is a value to handle and
/// not one to put on a query string.
pub type UnsendableReaction {
  UnsendableReaction(wire_value: Int)
}

/// Narrow a reaction type read off a MESSAGE_REACTION_ADD into one this route
/// can ask for.
pub fn reaction_kind(
  value: ReactionType,
) -> Result(ReactionKind, UnsendableReaction) {
  case value {
    message.NormalReaction -> Ok(Normal)
    message.BurstReaction -> Ok(Burst)
    message.UnknownReactionType(other) -> Error(UnsendableReaction(other))
  }
}

/// Through the model's table, so the two numbers are written in one place.
fn reaction_type(kind: ReactionKind) -> String {
  let type_ = case kind {
    Normal -> message.NormalReaction
    Burst -> message.BurstReaction
  }
  int.to_string(message.reaction_type_to_int(type_))
}

/// `PUT /channels/{channel.id}/messages/{message.id}/reactions/{emoji}/@me`.
pub fn create_reaction(
  channel: id.ChannelId,
  message: id.MessageId,
  emoji: ReactionEmoji,
) -> Call(Nil) {
  rest.put(
    list.append(reactions_at(channel, message, emoji), [seg.lit("@me")]),
    body.NoBody,
    rest.NoContent(Nil),
  )
}

/// `DELETE /channels/{channel.id}/messages/{message.id}/reactions/{emoji}/@me`.
pub fn delete_own_reaction(
  channel: id.ChannelId,
  message: id.MessageId,
  emoji: ReactionEmoji,
) -> Call(Nil) {
  rest.delete(
    list.append(reactions_at(channel, message, emoji), [seg.lit("@me")]),
    rest.NoContent(Nil),
  )
}

/// `DELETE /channels/{channel.id}/messages/{message.id}/reactions/{emoji}/{user.id}`.
pub fn delete_user_reaction(
  channel: id.ChannelId,
  message: id.MessageId,
  emoji: ReactionEmoji,
  user: id.UserId,
) -> Call(Nil) {
  rest.delete(
    list.append(reactions_at(channel, message, emoji), [seg.id(user)]),
    rest.NoContent(Nil),
  )
}

/// `GET /channels/{channel.id}/messages/{message.id}/reactions/{emoji}`, the
/// users who reacted with it.
pub fn get_reactions(
  channel: id.ChannelId,
  message: id.MessageId,
  emoji: ReactionEmoji,
  type_ type_: Option(ReactionKind),
  after after: Option(id.UserId),
  limit limit: Option(Int),
) -> Call(List(User)) {
  rest.get(
    reactions_at(channel, message, emoji),
    rest.Decoded(decode.list(user.decoder())),
  )
  |> rest.query(
    list.flatten([
      query.opt("type", type_, reaction_type),
      query.opt("after", after, query.snowflake),
      query.opt("limit", limit, query.number),
    ]),
  )
}

/// `DELETE /channels/{channel.id}/messages/{message.id}/reactions/{emoji}`,
/// every user's reaction with that one emoji.
pub fn delete_emoji_reactions(
  channel: id.ChannelId,
  message: id.MessageId,
  emoji: ReactionEmoji,
) -> Call(Nil) {
  rest.delete(reactions_at(channel, message, emoji), rest.NoContent(Nil))
}

/// `DELETE /channels/{channel.id}/messages/{message.id}/reactions`, every
/// reaction on the message. Its own bucket, having no emoji to collapse at.
pub fn delete_all_reactions(
  channel: id.ChannelId,
  message: id.MessageId,
) -> Call(Nil) {
  rest.delete(
    list.append(message_at(channel, message), [seg.lit("reactions")]),
    rest.NoContent(Nil),
  )
}

/// A point in time to page back from. Three routes here order by an instant
/// instead of by snowflake, and a snowflake in one of their `before`
/// parameters is accepted and answers the wrong window, so this is not a
/// `MessageCursor` and not a bare string.
pub opaque type TimeCursor {
  TimeCursor(timestamp: String)
}

/// When a message was pinned. Page on with the oldest entry you just read.
pub fn pinned_at(pin: PinnedMessage) -> TimeCursor {
  TimeCursor(pin.pinned_at)
}

/// When a thread was archived, which is the order the archived listings come
/// in. Page on with the oldest thread you just read.
pub fn archived_at(thread: ThreadMetadata) -> TimeCursor {
  TimeCursor(thread.archive_timestamp)
}

/// An instant of your own, as ISO-8601. Every timestamp Discord sends is
/// already in this shape.
pub fn at_time(iso8601: String) -> TimeCursor {
  TimeCursor(iso8601)
}

fn before_param(before: Option(TimeCursor)) -> List(query.Param) {
  query.opt("before", before, fn(cursor) { cursor.timestamp })
}

/// `GET /channels/{channel.id}/messages/pins`, each message wrapped in its pin
/// time. Pages backwards through the order the messages were pinned in.
pub fn get_pins(
  channel: id.ChannelId,
  before before: Option(TimeCursor),
  limit limit: Option(Int),
) -> Call(PinList) {
  rest.get(pins_at(channel), rest.Decoded(message.pin_list_decoder()))
  |> rest.query(
    list.flatten([before_param(before), query.opt("limit", limit, query.number)]),
  )
}

/// `PUT /channels/{channel.id}/messages/pins/{message.id}`.
pub fn pin_message(channel: id.ChannelId, message: id.MessageId) -> Call(Nil) {
  rest.put(pin_at(channel, message), body.NoBody, rest.NoContent(Nil))
}

/// `DELETE /channels/{channel.id}/messages/pins/{message.id}`.
pub fn unpin_message(
  channel: id.ChannelId,
  message: id.MessageId,
) -> Call(Nil) {
  rest.delete(pin_at(channel, message), rest.NoContent(Nil))
}

/// `POST /channels/{channel.id}/typing`. The indicator lasts ten seconds or
/// until the bot posts.
pub fn trigger_typing(channel: id.ChannelId) -> Call(Nil) {
  rest.post(
    [seg.lit("channels"), seg.channel(channel), seg.lit("typing")],
    body.NoBody,
    rest.NoContent(Nil),
  )
}

pub fn get_channel(channel: id.ChannelId) -> Call(Channel) {
  rest.get(
    [seg.lit("channels"), seg.channel(channel)],
    rest.Decoded(channel.decoder()),
  )
}

/// `PATCH /channels/{channel.id}`. Name and topic edits carry an undocumented
/// limit of two per ten minutes, and glyde cannot see inside the body, so
/// `name_or_topic` puts the call in that sublimit rather than letting it spend
/// the channel's whole PATCH budget. `payload/channel.edits_name_or_topic` is
/// the answer for an `EditGuildChannel`.
pub fn edit_channel(
  channel: id.ChannelId,
  body: Body,
  name_or_topic name_or_topic: Bool,
) -> Call(Channel) {
  let call =
    rest.patch(
      [seg.lit("channels"), seg.channel(channel)],
      body,
      rest.Decoded(channel.decoder()),
    )

  case name_or_topic {
    True -> rest.split_bucket(call, "name-or-topic")
    False -> call
  }
}

/// `DELETE /channels/{channel.id}`, which closes a DM and deletes anything
/// else. Answers with the channel it removed, not 204.
pub fn delete_channel(channel: id.ChannelId) -> Call(Channel) {
  rest.delete(
    [seg.lit("channels"), seg.channel(channel)],
    rest.Decoded(channel.decoder()),
  )
}

/// `PUT /channels/{channel.id}/permissions/{overwrite.id}`. The overwrite id
/// is a role id or a user id, and only the `type` in the body says which.
pub fn edit_channel_permissions(
  channel: id.ChannelId,
  overwrite: id.OverwriteId,
  body: Body,
) -> Call(Nil) {
  rest.put(overwrite_at(channel, overwrite), body, rest.NoContent(Nil))
}

pub fn delete_channel_permission(
  channel: id.ChannelId,
  overwrite: id.OverwriteId,
) -> Call(Nil) {
  rest.delete(overwrite_at(channel, overwrite), rest.NoContent(Nil))
}

/// `POST /channels/{channel.id}/messages/{message.id}/threads`, a thread
/// hanging off an existing message.
pub fn start_thread_from_message(
  channel: id.ChannelId,
  message: id.MessageId,
  body: Body,
) -> Call(Channel) {
  rest.post(
    list.append(message_at(channel, message), [seg.lit("threads")]),
    body,
    rest.Decoded(channel.decoder()),
  )
}

/// `POST /channels/{channel.id}/threads`, a thread with no starter message.
/// The same path creates a forum or media post, with a different body.
pub fn start_thread(channel: id.ChannelId, body: Body) -> Call(Channel) {
  rest.post(
    [seg.lit("channels"), seg.channel(channel), seg.lit("threads")],
    body,
    rest.Decoded(channel.decoder()),
  )
}

/// `PUT /channels/{thread.id}/thread-members/@me`.
pub fn join_thread(thread: id.ChannelId) -> Call(Nil) {
  rest.put(
    thread_member_at(thread, seg.lit("@me")),
    body.NoBody,
    rest.NoContent(Nil),
  )
}

/// `DELETE /channels/{thread.id}/thread-members/@me`.
pub fn leave_thread(thread: id.ChannelId) -> Call(Nil) {
  rest.delete(thread_member_at(thread, seg.lit("@me")), rest.NoContent(Nil))
}

/// `PUT /channels/{thread.id}/thread-members/{user.id}`.
pub fn add_thread_member(thread: id.ChannelId, user: id.UserId) -> Call(Nil) {
  rest.put(
    thread_member_at(thread, seg.id(user)),
    body.NoBody,
    rest.NoContent(Nil),
  )
}

/// `DELETE /channels/{thread.id}/thread-members/{user.id}`.
pub fn remove_thread_member(
  thread: id.ChannelId,
  user: id.UserId,
) -> Call(Nil) {
  rest.delete(thread_member_at(thread, seg.id(user)), rest.NoContent(Nil))
}

/// `GET /channels/{channel.id}/threads/archived/public`, newest archive first.
pub fn get_public_archived_threads(
  channel: id.ChannelId,
  before before: Option(TimeCursor),
  limit limit: Option(Int),
) -> Call(ThreadList) {
  archived_threads(channel, "public", before, limit)
}

/// `GET /channels/{channel.id}/threads/archived/private`, which needs
/// MANAGE_THREADS.
pub fn get_private_archived_threads(
  channel: id.ChannelId,
  before before: Option(TimeCursor),
  limit limit: Option(Int),
) -> Call(ThreadList) {
  archived_threads(channel, "private", before, limit)
}

fn archived_threads(
  channel: id.ChannelId,
  visibility: String,
  before: Option(TimeCursor),
  limit: Option(Int),
) -> Call(ThreadList) {
  rest.get(
    [
      seg.lit("channels"),
      seg.channel(channel),
      seg.lit("threads"),
      seg.lit("archived"),
      seg.lit(visibility),
    ],
    rest.Decoded(channel.thread_list_decoder()),
  )
  |> rest.query(
    list.flatten([before_param(before), query.opt("limit", limit, query.number)]),
  )
}

fn messages_at(channel: id.ChannelId) -> List(seg.Seg) {
  [seg.lit("channels"), seg.channel(channel), seg.lit("messages")]
}

fn message_at(channel: id.ChannelId, message: id.MessageId) -> List(seg.Seg) {
  list.append(messages_at(channel), [seg.id(message)])
}

/// Everything up to and including the emoji. `seg.reaction` erases it from the
/// template, so the five routes built on this share one bucket per method.
fn reactions_at(
  channel: id.ChannelId,
  message: id.MessageId,
  emoji: ReactionEmoji,
) -> List(seg.Seg) {
  list.append(message_at(channel, message), [
    seg.lit("reactions"),
    seg.reaction(emoji.param),
  ])
}

fn pins_at(channel: id.ChannelId) -> List(seg.Seg) {
  list.append(messages_at(channel), [seg.lit("pins")])
}

fn pin_at(channel: id.ChannelId, message: id.MessageId) -> List(seg.Seg) {
  list.append(pins_at(channel), [seg.id(message)])
}

fn thread_member_at(thread: id.ChannelId, who: seg.Seg) -> List(seg.Seg) {
  [seg.lit("channels"), seg.channel(thread), seg.lit("thread-members"), who]
}

fn overwrite_at(
  channel: id.ChannelId,
  overwrite: id.OverwriteId,
) -> List(seg.Seg) {
  [
    seg.lit("channels"),
    seg.channel(channel),
    seg.lit("permissions"),
    seg.id(overwrite),
  ]
}
