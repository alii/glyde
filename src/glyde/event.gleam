//// Gateway dispatch events, decoded.
////
//// `decode` is total: an unmodelled name, or a payload that did not fit, comes
//// back as `Raw` with `d` untouched, so a host's `case` needs no error arm.
//// `dispatch` is the same decode with the outcome kept apart, which is how
//// glyde's own schema drift is told from an event it never modelled.
////
//// The payload records and their decoders live in `glyde/event/*`, one module
//// per family. This module is the sum type and the table that routes to them.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/option.{type Option, None, Some}
import glyde/channel
import glyde/emoji
import glyde/event/channels
import glyde/event/guilds
import glyde/event/messages
import glyde/event/presence
import glyde/event/session
import glyde/event/voice
import glyde/guild
import glyde/id
import glyde/interaction
import glyde/member
import glyde/message
import glyde/ready
import glyde/role
import glyde/user
import glyde/voice_state

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
  RateLimitedEvent(session.RateLimited)

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
  GuildMembersChunk(guilds.MembersChunk)

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

  MessageReactionAdd(messages.ReactionAdd)

  /// Not a mirror of the add. See `messages.ReactionRemove`.
  MessageReactionRemove(messages.ReactionRemove)

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

  TypingStartEvent(presence.TypingStart)

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
  option.is_some(decoder_for(name))
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

/// The one table. Adding an event is one line here plus one in `name`. A
/// family decoder returns its own record to map, or takes the constructor.
fn decoder_for(name: String) -> Option(Decoder(Event)) {
  case name {
    "READY" -> Some(decode.map(ready.decoder(), ReadyEvent))
    // `d` is a routing breadcrumb with nothing a host can use.
    "RESUMED" -> Some(decode.success(ResumedEvent))
    "RATE_LIMITED" ->
      Some(decode.map(session.rate_limited_decoder(), RateLimitedEvent))

    "GUILD_CREATE" ->
      Some(guilds.create_decoder(
        available: GuildCreateAvailable,
        unavailable: GuildCreateUnavailable,
      ))
    "GUILD_UPDATE" -> Some(decode.map(guild.decoder(), GuildUpdate))
    "GUILD_DELETE" ->
      Some(guilds.delete_decoder(
        outage: GuildUnavailable,
        removed: GuildRemoved,
      ))

    "GUILD_MEMBER_ADD" -> Some(guilds.member_decoder(GuildMemberAdd))
    "GUILD_MEMBER_REMOVE" -> Some(guilds.user_decoder(GuildMemberRemove))
    "GUILD_MEMBER_UPDATE" -> Some(guilds.member_decoder(GuildMemberUpdate))
    "GUILD_MEMBERS_CHUNK" ->
      Some(decode.map(guilds.members_chunk_decoder(), GuildMembersChunk))

    "GUILD_ROLE_CREATE" -> Some(guilds.role_decoder(GuildRoleCreate))
    "GUILD_ROLE_UPDATE" -> Some(guilds.role_decoder(GuildRoleUpdate))
    "GUILD_ROLE_DELETE" -> Some(guilds.role_delete_decoder(GuildRoleDelete))

    "GUILD_BAN_ADD" -> Some(guilds.user_decoder(GuildBanAdd))
    "GUILD_BAN_REMOVE" -> Some(guilds.user_decoder(GuildBanRemove))
    "GUILD_EMOJIS_UPDATE" ->
      Some(guilds.emojis_update_decoder(GuildEmojisUpdate))

    "CHANNEL_CREATE" -> Some(decode.map(channel.decoder(), ChannelCreate))
    "CHANNEL_UPDATE" -> Some(decode.map(channel.decoder(), ChannelUpdate))
    "CHANNEL_DELETE" -> Some(decode.map(channel.decoder(), ChannelDelete))
    "CHANNEL_PINS_UPDATE" ->
      Some(channels.pins_update_decoder(ChannelPinsUpdate))

    "THREAD_CREATE" -> Some(decode.map(channel.decoder(), ThreadCreate))
    "THREAD_UPDATE" -> Some(decode.map(channel.decoder(), ThreadUpdate))
    "THREAD_DELETE" -> Some(channels.thread_delete_decoder(ThreadDelete))

    "MESSAGE_CREATE" -> Some(decode.map(message.decoder(), MessageCreate))
    "MESSAGE_UPDATE" ->
      Some(decode.map(message.update_decoder(), MessageUpdate))
    "MESSAGE_DELETE" -> Some(messages.delete_decoder(MessageDelete))
    "MESSAGE_DELETE_BULK" ->
      Some(messages.delete_bulk_decoder(MessageDeleteBulk))

    "MESSAGE_REACTION_ADD" ->
      Some(decode.map(messages.reaction_add_decoder(), MessageReactionAdd))
    "MESSAGE_REACTION_REMOVE" ->
      Some(decode.map(messages.reaction_remove_decoder(), MessageReactionRemove))
    "MESSAGE_REACTION_REMOVE_ALL" ->
      Some(messages.reaction_remove_all_decoder(MessageReactionRemoveAll))
    "MESSAGE_REACTION_REMOVE_EMOJI" ->
      Some(messages.reaction_remove_emoji_decoder(MessageReactionRemoveEmoji))

    "INTERACTION_CREATE" ->
      Some(decode.map(interaction.decoder(), InteractionCreate))
    "TYPING_START" ->
      Some(decode.map(presence.typing_start_decoder(), TypingStartEvent))
    "USER_UPDATE" -> Some(decode.map(user.decoder(), UserUpdate))
    "VOICE_STATE_UPDATE" ->
      Some(decode.map(voice_state.decoder(), VoiceStateUpdate))
    "VOICE_SERVER_UPDATE" ->
      Some(voice.server_update_decoder(VoiceServerUpdate))

    _ -> None
  }
}
