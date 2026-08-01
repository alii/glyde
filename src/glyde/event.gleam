//// Gateway dispatch events, decoded.
////
//// `decode` is total: an unmodelled name, or a payload that did not fit, comes
//// back as `Raw` with `d` untouched, so a host's `case` needs no error arm.
//// `dispatch` is the same decode with the outcome kept apart, which is how
//// glyde's own schema drift is told from an event it never modelled.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/int
import gleam/option.{type Option, None, Some}
import glyde/id
import glyde/model/channel
import glyde/model/emoji
import glyde/model/guild
import glyde/model/interaction
import glyde/model/member
import glyde/model/message.{type ReactionType}
import glyde/model/ready
import glyde/model/role
import glyde/model/user
import glyde/model/voice_state
import glyde/wire

/// One decoded dispatch.
pub type Event {
  /// READY. The handshake reads `session_id` and `resume_gateway_url` out of
  /// this same `d`, so a decoder bug here cannot cost a session.
  ReadyEvent(ready.Ready)

  /// RESUMED. Replay is finished and everything after this is new. `d` is
  /// `{"_trace":[…]}`, Discord's own routing breadcrumb.
  ResumedEvent

  /// RATE_LIMITED. A dispatch, not an opcode: it arrives with `"op":0` and
  /// advances the sequence, so a client switching on `op` never sees it.
  RateLimitedEvent(RateLimited)

  /// GUILD_CREATE for a guild that is up. Sent on connect for every guild the
  /// bot is in, then again whenever it joins one.
  GuildCreateAvailable(guild: guild.Guild)

  /// GUILD_CREATE for a guild that is still down. Two keys, no more.
  GuildCreateUnavailable(id: id.GuildId)

  GuildUpdate(guild: guild.Guild)

  /// GUILD_DELETE during a Discord outage. Still the bot's guild, and it
  /// comes back as a GUILD_CREATE. Do not evict it from a cache.
  GuildUnavailable(id: id.GuildId)

  /// GUILD_DELETE because the bot was kicked or banned, or the guild was
  /// deleted. This one is permanent.
  GuildRemoved(id: id.GuildId)

  /// `d` is the member object with an extra `guild_id`, which is why the id
  /// sits beside the member rather than inside it.
  GuildMemberAdd(guild_id: id.GuildId, member: member.GuildMember)

  GuildMemberRemove(guild_id: id.GuildId, user: user.User)

  /// A partial member: `deaf`, `mute` and `flags` can be missing despite the
  /// docs. Privileged behind `GuildMembers`, bar the bot's own member.
  GuildMemberUpdate(guild_id: id.GuildId, member: member.GuildMember)

  /// The answer to REQUEST_GUILD_MEMBERS, at most 1000 members per chunk.
  GuildMembersChunk(MembersChunk)

  GuildRoleCreate(guild_id: id.GuildId, role: role.Role)

  GuildRoleUpdate(guild_id: id.GuildId, role: role.Role)

  GuildRoleDelete(guild_id: id.GuildId, role_id: id.RoleId)

  /// Needs `GuildModeration` plus either BAN_MEMBERS or VIEW_AUDIT_LOG.
  GuildBanAdd(guild_id: id.GuildId, user: user.User)

  GuildBanRemove(guild_id: id.GuildId, user: user.User)

  /// `emojis` is the guild's whole list, never a delta. Replace, do not merge:
  /// a deleted emoji is only ever signalled by its absence here.
  GuildEmojisUpdate(guild_id: id.GuildId, emojis: List(emoji.GuildEmoji))

  ChannelCreate(channel: channel.Channel)

  ChannelUpdate(channel: channel.Channel)

  ChannelDelete(channel: channel.Channel)

  /// `last_pin_timestamp` is ISO-8601, and `None` once the last pin is
  /// removed. The event does not say which message was pinned.
  ChannelPinsUpdate(
    guild_id: Option(id.GuildId),
    channel_id: id.ChannelId,
    last_pin_timestamp: Option(String),
  )

  /// `channel` carries `newly_created`, which tells a thread opened on a brand
  /// new message from one opened on an old one.
  ThreadCreate(channel: channel.Channel)

  ThreadUpdate(channel: channel.Channel)

  /// Four keys and no more. It looks like a channel and is not one, and the
  /// channel decoder would accept it: a channel needs only `id` and `type`.
  ThreadDelete(
    id: id.ChannelId,
    guild_id: id.GuildId,
    parent_id: Option(id.ChannelId),
    type_: channel.ChannelType,
  )

  /// Without `MessageContent`, `content`, `embeds`, `attachments` and
  /// `components` are empty unless the message mentions the bot or is a DM.
  MessageCreate(message: message.Message)

  /// Not a `Message`. Discord sends only what changed, so everything but `id`
  /// and `channel_id` is optional: an embed-only edit has no author.
  MessageUpdate(message: message.MessageUpdate)

  MessageDelete(
    id: id.MessageId,
    channel_id: id.ChannelId,
    guild_id: Option(id.GuildId),
  )

  /// Guild channels only. Discord does not list this one under
  /// DIRECT_MESSAGES, so a DM bot relying on it to clean up never gets it.
  MessageDeleteBulk(
    ids: List(id.MessageId),
    channel_id: id.ChannelId,
    guild_id: Option(id.GuildId),
  )

  MessageReactionAdd(ReactionAdd)

  /// Not a mirror of the add. See `ReactionRemove`.
  MessageReactionRemove(ReactionRemove)

  /// Every reaction on the message is gone.
  MessageReactionRemoveAll(
    channel_id: id.ChannelId,
    message_id: id.MessageId,
    guild_id: Option(id.GuildId),
  )

  /// Every reaction of one emoji is gone.
  MessageReactionRemoveEmoji(
    channel_id: id.ChannelId,
    message_id: id.MessageId,
    guild_id: Option(id.GuildId),
    emoji: emoji.Emoji,
  )

  /// Ungated: a bot with no intents still gets every interaction.
  InteractionCreate(interaction: interaction.Interaction)

  TypingStartEvent(TypingStart)

  /// The bot's own user changed. Not sent for anyone else.
  UserUpdate(user: user.User)

  /// A null `channel_id` on the state means the user left voice, and there is
  /// no separate event for that. `voice_state.has_left` asks it directly.
  VoiceStateUpdate(voice_state.VoiceState)

  /// `endpoint` is `None` when the voice server went away. Disconnect and wait
  /// for the next one. Reconnecting to nothing loops.
  VoiceServerUpdate(
    token: String,
    guild_id: id.GuildId,
    endpoint: Option(String),
  )

  /// A dispatch glyde did not model, or one whose `d` did not fit, with `d`
  /// intact. `is_modelled` tells those apart; `dispatch` gives the errors.
  Raw(name: String, data: Dynamic)
}

/// Not a mirror of `ReactionRemove`: the add carries `member`,
/// `message_author_id` and `burst_colors`, and the remove carries none.
pub type ReactionAdd {
  ReactionAdd(
    user_id: id.UserId,
    channel_id: id.ChannelId,
    message_id: id.MessageId,
    guild_id: Option(id.GuildId),
    /// Present on a guild reaction, absent in a DM.
    member: Option(member.GuildMember),
    /// Partial: `id` and `name` only, and `id` is null for a unicode emoji.
    emoji: emoji.Emoji,
    /// Who wrote the message being reacted to. Absent on an older payload.
    message_author_id: Option(id.UserId),
    burst: Bool,
    /// Hex colours of the burst animation, as sent.
    burst_colors: List(String),
    type_: ReactionType,
  )
}

/// Three fields fewer than `ReactionAdd`, which is Discord's shape.
pub type ReactionRemove {
  ReactionRemove(
    user_id: id.UserId,
    channel_id: id.ChannelId,
    message_id: id.MessageId,
    guild_id: Option(id.GuildId),
    emoji: emoji.Emoji,
    burst: Bool,
    type_: ReactionType,
  )
}

pub type TypingStart {
  TypingStart(
    channel_id: id.ChannelId,
    guild_id: Option(id.GuildId),
    user_id: id.UserId,
    /// UNIX SECONDS. Not milliseconds and not ISO-8601, and the only unix
    /// timestamp anywhere in the dispatch surface.
    timestamp: Int,
    /// Present on a guild channel, absent in a DM.
    member: Option(member.GuildMember),
  )
}

pub type MembersChunk {
  MembersChunk(
    guild_id: id.GuildId,
    /// At most 1000. glyde does not reassemble the chunks: count them with
    /// `chunk_index` and `chunk_count`.
    members: List(member.GuildMember),
    chunk_index: Int,
    chunk_count: Int,
    /// Echoes the request back, so this is whatever the caller sent, a real
    /// snowflake or not. A String, never an `Id`.
    not_found: List(String),
    /// Absent when the request's nonce was over 32 bytes, which Discord drops
    /// silently.
    nonce: Option(String),
  )
}

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

pub type Dispatch {
  Dispatch(
    name: String,
    /// `d` exactly as it arrived, the hatch for anything glyde does not model.
    data: Dynamic,
    outcome: Outcome,
  )
}

/// The three things one dispatch can be. `Malformed` is a glyde bug or a
/// Discord schema change: report it. `Unmodelled` is ordinary.
pub type Outcome {
  Decoded(Event)
  Unmodelled
  Malformed(errors: List(decode.DecodeError))
}

/// Decode one dispatch. Total.
pub fn decode(name: String, data: Dynamic) -> Event {
  case dispatch(name, data).outcome {
    Decoded(event) -> event
    Unmodelled | Malformed(_) -> Raw(name:, data:)
  }
}

/// Decode one dispatch, keeping `d` and saying which of the three happened.
/// Total.
pub fn dispatch(name: String, data: Dynamic) -> Dispatch {
  case decoder_for(name) {
    None -> Dispatch(name:, data:, outcome: Unmodelled)
    Some(decoder) ->
      case decode.run(data, decoder) {
        Ok(event) -> Dispatch(name:, data:, outcome: Decoded(event))
        Error(errors) -> Dispatch(name:, data:, outcome: Malformed(errors:))
      }
  }
}

/// The question to ask about a `Raw`: an unmodelled name is ordinary, a
/// modelled one that came back `Raw` is a payload that did not fit.
pub fn is_modelled(name: String) -> Bool {
  case decoder_for(name) {
    Some(_) -> True
    None -> False
  }
}

/// The wire `t` an event came from. The inverse of `decoder_for`'s table: a
/// name added to one and not the other silently drops an event.
pub fn name(event: Event) -> String {
  case event {
    ReadyEvent(_) -> "READY"
    ResumedEvent -> "RESUMED"
    RateLimitedEvent(_) -> "RATE_LIMITED"
    GuildCreateAvailable(_) | GuildCreateUnavailable(_) -> "GUILD_CREATE"
    GuildUpdate(_) -> "GUILD_UPDATE"
    GuildUnavailable(_) | GuildRemoved(_) -> "GUILD_DELETE"
    GuildMemberAdd(..) -> "GUILD_MEMBER_ADD"
    GuildMemberRemove(..) -> "GUILD_MEMBER_REMOVE"
    GuildMemberUpdate(..) -> "GUILD_MEMBER_UPDATE"
    GuildMembersChunk(_) -> "GUILD_MEMBERS_CHUNK"
    GuildRoleCreate(..) -> "GUILD_ROLE_CREATE"
    GuildRoleUpdate(..) -> "GUILD_ROLE_UPDATE"
    GuildRoleDelete(..) -> "GUILD_ROLE_DELETE"
    GuildBanAdd(..) -> "GUILD_BAN_ADD"
    GuildBanRemove(..) -> "GUILD_BAN_REMOVE"
    GuildEmojisUpdate(..) -> "GUILD_EMOJIS_UPDATE"
    ChannelCreate(_) -> "CHANNEL_CREATE"
    ChannelUpdate(_) -> "CHANNEL_UPDATE"
    ChannelDelete(_) -> "CHANNEL_DELETE"
    ChannelPinsUpdate(..) -> "CHANNEL_PINS_UPDATE"
    ThreadCreate(_) -> "THREAD_CREATE"
    ThreadUpdate(_) -> "THREAD_UPDATE"
    ThreadDelete(..) -> "THREAD_DELETE"
    MessageCreate(_) -> "MESSAGE_CREATE"
    MessageUpdate(_) -> "MESSAGE_UPDATE"
    MessageDelete(..) -> "MESSAGE_DELETE"
    MessageDeleteBulk(..) -> "MESSAGE_DELETE_BULK"
    MessageReactionAdd(_) -> "MESSAGE_REACTION_ADD"
    MessageReactionRemove(_) -> "MESSAGE_REACTION_REMOVE"
    MessageReactionRemoveAll(..) -> "MESSAGE_REACTION_REMOVE_ALL"
    MessageReactionRemoveEmoji(..) -> "MESSAGE_REACTION_REMOVE_EMOJI"
    InteractionCreate(_) -> "INTERACTION_CREATE"
    TypingStartEvent(_) -> "TYPING_START"
    UserUpdate(_) -> "USER_UPDATE"
    VoiceStateUpdate(_) -> "VOICE_STATE_UPDATE"
    VoiceServerUpdate(..) -> "VOICE_SERVER_UPDATE"
    Raw(wire_name, _) -> wire_name
  }
}

/// The one table. Adding an event is one line here plus one in `name`.
fn decoder_for(name: String) -> Option(Decoder(Event)) {
  case name {
    "READY" -> Some(decode.map(ready.decoder(), ReadyEvent))
    // `d` is a routing breadcrumb with nothing a host can use.
    "RESUMED" -> Some(decode.success(ResumedEvent))
    "RATE_LIMITED" -> Some(decode.map(rate_limited_decoder(), RateLimitedEvent))

    "GUILD_CREATE" -> Some(guild_create_decoder())
    "GUILD_UPDATE" -> Some(decode.map(guild.decoder(), GuildUpdate))
    "GUILD_DELETE" -> Some(guild_delete_decoder())

    "GUILD_MEMBER_ADD" -> Some(flat_decoder(member.decoder(), GuildMemberAdd))
    "GUILD_MEMBER_REMOVE" ->
      Some(keyed_decoder("user", user.decoder(), GuildMemberRemove))
    "GUILD_MEMBER_UPDATE" ->
      Some(flat_decoder(member.decoder(), GuildMemberUpdate))
    "GUILD_MEMBERS_CHUNK" ->
      Some(decode.map(members_chunk_decoder(), GuildMembersChunk))

    "GUILD_ROLE_CREATE" ->
      Some(keyed_decoder("role", role.decoder(), GuildRoleCreate))
    "GUILD_ROLE_UPDATE" ->
      Some(keyed_decoder("role", role.decoder(), GuildRoleUpdate))
    "GUILD_ROLE_DELETE" -> Some(role_delete_decoder())

    "GUILD_BAN_ADD" -> Some(keyed_decoder("user", user.decoder(), GuildBanAdd))
    "GUILD_BAN_REMOVE" ->
      Some(keyed_decoder("user", user.decoder(), GuildBanRemove))
    "GUILD_EMOJIS_UPDATE" -> Some(emojis_update_decoder())

    "CHANNEL_CREATE" -> Some(decode.map(channel.decoder(), ChannelCreate))
    "CHANNEL_UPDATE" -> Some(decode.map(channel.decoder(), ChannelUpdate))
    "CHANNEL_DELETE" -> Some(decode.map(channel.decoder(), ChannelDelete))
    "CHANNEL_PINS_UPDATE" -> Some(channel_pins_decoder())

    "THREAD_CREATE" -> Some(decode.map(channel.decoder(), ThreadCreate))
    "THREAD_UPDATE" -> Some(decode.map(channel.decoder(), ThreadUpdate))
    "THREAD_DELETE" -> Some(thread_delete_decoder())

    "MESSAGE_CREATE" -> Some(decode.map(message.decoder(), MessageCreate))
    "MESSAGE_UPDATE" ->
      Some(decode.map(message.update_decoder(), MessageUpdate))
    "MESSAGE_DELETE" -> Some(message_delete_decoder())
    "MESSAGE_DELETE_BULK" -> Some(message_delete_bulk_decoder())

    "MESSAGE_REACTION_ADD" -> Some(reaction_add_decoder())
    "MESSAGE_REACTION_REMOVE" -> Some(reaction_remove_decoder())
    "MESSAGE_REACTION_REMOVE_ALL" -> Some(reaction_remove_all_decoder())
    "MESSAGE_REACTION_REMOVE_EMOJI" -> Some(reaction_remove_emoji_decoder())

    "INTERACTION_CREATE" ->
      Some(decode.map(interaction.decoder(), InteractionCreate))
    "TYPING_START" -> Some(decode.map(typing_start_decoder(), TypingStartEvent))
    "USER_UPDATE" -> Some(decode.map(user.decoder(), UserUpdate))
    "VOICE_STATE_UPDATE" ->
      Some(decode.map(voice_state.decoder(), VoiceStateUpdate))
    "VOICE_SERVER_UPDATE" -> Some(voice_server_decoder())

    _ -> None
  }
}

/// On the VALUE of `unavailable`: `true` is a two-key stub, absent or `false`
/// is the whole guild. GUILD_DELETE goes on the key's presence instead.
fn guild_create_decoder() -> Decoder(Event) {
  use maybe <- decode.then(guild.maybe_available_decoder())
  decode.success(case maybe {
    guild.AvailableGuild(available) -> GuildCreateAvailable(guild: available)
    guild.OfflineGuild(offline) -> GuildCreateUnavailable(id: offline)
  })
}

/// On the PRESENCE of `unavailable`, not its value, which `departure_decoder`
/// reads. The two departures are different events: an outage leaves the guild
/// in the cache, a removal takes it out.
fn guild_delete_decoder() -> Decoder(Event) {
  use departure <- decode.then(guild.departure_decoder())
  decode.success(case departure {
    guild.GuildOutage(offline) -> GuildUnavailable(id: offline)
    guild.GuildGone(removed) -> GuildRemoved(id: removed)
  })
}

/// For the events whose `d` is the object itself with `guild_id` bolted on.
fn flat_decoder(
  inner: Decoder(a),
  build: fn(id.GuildId, a) -> Event,
) -> Decoder(Event) {
  use guild_id <- decode.field("guild_id", id.decoder())
  use payload <- decode.then(inner)
  decode.success(build(guild_id, payload))
}

/// For the events shaped `{"guild_id": …, "<key>": {…}}`.
fn keyed_decoder(
  key: String,
  inner: Decoder(a),
  build: fn(id.GuildId, a) -> Event,
) -> Decoder(Event) {
  use guild_id <- decode.field("guild_id", id.decoder())
  use value <- decode.field(key, inner)
  decode.success(build(guild_id, value))
}

fn role_delete_decoder() -> Decoder(Event) {
  use guild_id <- decode.field("guild_id", id.decoder())
  use role_id <- decode.field("role_id", id.decoder())
  decode.success(GuildRoleDelete(guild_id:, role_id:))
}

/// `emojis` is required, unlike nearly every other list here: the array
/// replaces the guild's whole set, so a missing key must not read as `[]`.
fn emojis_update_decoder() -> Decoder(Event) {
  use guild_id <- decode.field("guild_id", id.decoder())
  use emojis <- decode.field("emojis", decode.list(emoji.guild_emoji_decoder()))
  decode.success(GuildEmojisUpdate(guild_id:, emojis:))
}

fn channel_pins_decoder() -> Decoder(Event) {
  use guild_id <- wire.opt_field("guild_id", id.decoder())
  use channel_id <- decode.field("channel_id", id.decoder())
  use last_pin_timestamp <- wire.opt_field("last_pin_timestamp", decode.string)
  decode.success(ChannelPinsUpdate(guild_id:, channel_id:, last_pin_timestamp:))
}

fn thread_delete_decoder() -> Decoder(Event) {
  use thread_id <- decode.field("id", id.decoder())
  use guild_id <- decode.field("guild_id", id.decoder())
  use parent_id <- wire.opt_field("parent_id", id.decoder())
  use type_ <- decode.field("type", channel.channel_type_decoder())
  decode.success(ThreadDelete(id: thread_id, guild_id:, parent_id:, type_:))
}

fn message_delete_decoder() -> Decoder(Event) {
  use message_id <- decode.field("id", id.decoder())
  use channel_id <- decode.field("channel_id", id.decoder())
  use guild_id <- wire.opt_field("guild_id", id.decoder())
  decode.success(MessageDelete(id: message_id, channel_id:, guild_id:))
}

fn message_delete_bulk_decoder() -> Decoder(Event) {
  use ids <- decode.field("ids", decode.list(id.decoder()))
  use channel_id <- decode.field("channel_id", id.decoder())
  use guild_id <- wire.opt_field("guild_id", id.decoder())
  decode.success(MessageDeleteBulk(ids:, channel_id:, guild_id:))
}

fn reaction_add_decoder() -> Decoder(Event) {
  use user_id <- decode.field("user_id", id.decoder())
  use channel_id <- decode.field("channel_id", id.decoder())
  use message_id <- decode.field("message_id", id.decoder())
  use guild_id <- wire.opt_field("guild_id", id.decoder())
  use reactor <- wire.opt_field("member", member.decoder())
  use reaction <- decode.field("emoji", emoji.decoder())
  use message_author_id <- wire.opt_field("message_author_id", id.decoder())
  use burst <- wire.flag_field("burst", False)
  use burst_colors <- wire.list_field("burst_colors", decode.string)
  use type_ <- reaction_type_field()
  decode.success(
    MessageReactionAdd(ReactionAdd(
      user_id:,
      channel_id:,
      message_id:,
      guild_id:,
      member: reactor,
      emoji: reaction,
      message_author_id:,
      burst:,
      burst_colors:,
      type_:,
    )),
  )
}

/// No `member`, no `message_author_id`, no `burst_colors`. Copying the add
/// decoder keeps them, and `decode.field` on an absent key drops the event.
fn reaction_remove_decoder() -> Decoder(Event) {
  use user_id <- decode.field("user_id", id.decoder())
  use channel_id <- decode.field("channel_id", id.decoder())
  use message_id <- decode.field("message_id", id.decoder())
  use guild_id <- wire.opt_field("guild_id", id.decoder())
  use reaction <- decode.field("emoji", emoji.decoder())
  use burst <- wire.flag_field("burst", False)
  use type_ <- reaction_type_field()
  decode.success(
    MessageReactionRemove(ReactionRemove(
      user_id:,
      channel_id:,
      message_id:,
      guild_id:,
      emoji: reaction,
      burst:,
      type_:,
    )),
  )
}

fn reaction_remove_all_decoder() -> Decoder(Event) {
  use channel_id <- decode.field("channel_id", id.decoder())
  use message_id <- decode.field("message_id", id.decoder())
  use guild_id <- wire.opt_field("guild_id", id.decoder())
  decode.success(MessageReactionRemoveAll(channel_id:, message_id:, guild_id:))
}

fn reaction_remove_emoji_decoder() -> Decoder(Event) {
  use channel_id <- decode.field("channel_id", id.decoder())
  use message_id <- decode.field("message_id", id.decoder())
  use guild_id <- wire.opt_field("guild_id", id.decoder())
  use reaction <- decode.field("emoji", emoji.decoder())
  decode.success(MessageReactionRemoveEmoji(
    channel_id:,
    message_id:,
    guild_id:,
    emoji: reaction,
  ))
}

fn typing_start_decoder() -> Decoder(TypingStart) {
  use channel_id <- decode.field("channel_id", id.decoder())
  use guild_id <- wire.opt_field("guild_id", id.decoder())
  use user_id <- decode.field("user_id", id.decoder())
  use timestamp <- decode.field("timestamp", wire.integer())
  use typist <- wire.opt_field("member", member.decoder())
  decode.success(TypingStart(
    channel_id:,
    guild_id:,
    user_id:,
    timestamp:,
    member: typist,
  ))
}

fn members_chunk_decoder() -> Decoder(MembersChunk) {
  use guild_id <- decode.field("guild_id", id.decoder())
  // Required, unlike `not_found`: a chunk with no `members` key is malformed,
  // and reading it as empty loses members with no sign anything went wrong.
  use members <- decode.field("members", decode.list(member.decoder()))
  use chunk_index <- decode.field("chunk_index", wire.integer())
  use chunk_count <- decode.field("chunk_count", wire.integer())
  use not_found <- wire.list_field("not_found", snowflake_or_number())
  use nonce <- wire.opt_field("nonce", decode.string)
  decode.success(MembersChunk(
    guild_id:,
    members:,
    chunk_index:,
    chunk_count:,
    not_found:,
    nonce:,
  ))
}

fn rate_limited_decoder() -> Decoder(RateLimited) {
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

fn voice_server_decoder() -> Decoder(Event) {
  use token <- decode.field("token", decode.string)
  use guild_id <- decode.field("guild_id", id.decoder())
  // Required and nullable: the null says the voice server went away, so an
  // absent key must fail rather than forge that.
  use endpoint <- wire.nullable_field("endpoint", decode.string)
  decode.success(VoiceServerUpdate(token:, guild_id:, endpoint:))
}

/// The reaction `type`, which an older payload omits. Only absence defaults:
/// a `type` that is present and unreadable is a burst reaction we would
/// otherwise hand to a host as a normal one.
fn reaction_type_field(
  next: fn(ReactionType) -> Decoder(final),
) -> Decoder(final) {
  decode.optional_field(
    "type",
    message.NormalReaction,
    message.reaction_type_decoder(),
    next,
  )
}

/// A snowflake that can come back as a JSON number, because that is what the
/// caller sent. Only `GUILD_MEMBERS_CHUNK.not_found` does this.
///
/// `decode.int` and not `wire.integer()`: every snowflake is 17 to 19 digits,
/// which is past that helper's 2^53 ceiling. A bare number is already rounded
/// by any JSON parser working in doubles, which is why glyde sends snowflakes
/// as strings.
fn snowflake_or_number() -> Decoder(String) {
  decode.one_of(decode.string, or: [decode.map(decode.int, int.to_string)])
}
