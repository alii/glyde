//// Bodies for creating and editing a message.
////
//// Create and edit are separate types: an empty array is an absence on POST
//// and an instruction on PATCH. `allowed_mentions` is required on `edit`
//// because an edit without it re-parses the content with Discord's defaults,
//// whatever the message was sent with.

import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import glyde/field.{type Field, Absent, Present}
import glyde/flags
import glyde/id
import glyde/model/component
import glyde/model/message
import glyde/payload/allowed_mentions.{type AllowedMentions}
import glyde/payload/embed.{type Embed}
import glyde/payload/file.{type EditAttachments, type File, KeepAttachments}
import glyde/rest/body.{type Body}
import glyde/wire

/// A reply or a forward, sent as `message_reference`.
pub type Reference {
  Reply(
    message_id: id.MessageId,
    /// Discord infers the current channel when this is `None`.
    channel_id: Option(id.ChannelId),
    guild_id: Option(id.GuildId),
    /// False turns a reply to a deleted message into a plain message rather
    /// than a 400. Discord's own default is true.
    fail_if_not_exists: Bool,
  )

  /// Only DEFAULT, REPLY, CHAT_INPUT_COMMAND and CONTEXT_MENU_COMMAND messages
  /// can be forwarded, and the app has to be able to read the content or
  /// Discord answers error code 160014.
  Forward(
    message_id: id.MessageId,
    channel_id: id.ChannelId,
    guild_id: Option(id.GuildId),
  )
}

pub fn reference_to_json(value: Reference) -> Json {
  case value {
    Reply(message_id:, channel_id:, guild_id:, fail_if_not_exists:) ->
      wire.object([
        #("type", Present(reference_type(value))),
        #("message_id", Present(id.to_json(message_id))),
        #("channel_id", wire.put(wire.opt(channel_id), id.to_json)),
        #("guild_id", wire.put(wire.opt(guild_id), id.to_json)),
        #("fail_if_not_exists", Present(json.bool(fail_if_not_exists))),
      ])

    Forward(message_id:, channel_id:, guild_id:) ->
      wire.object([
        #("type", Present(reference_type(value))),
        #("message_id", Present(id.to_json(message_id))),
        #("channel_id", Present(id.to_json(channel_id))),
        #("guild_id", wire.put(wire.opt(guild_id), id.to_json)),
      ])
  }
}

fn reference_type(value: Reference) -> Json {
  message.message_reference_type_to_json(case value {
    Reply(..) -> message.DefaultReference
    Forward(..) -> message.ForwardReference
  })
}

/// `POST /channels/{c}/messages`. Discord needs at least one of `content`,
/// `embeds`, `sticker_ids`, `components`, a file or a poll, unless it is a
/// forward. Not checked here: Discord's 400 names the bad fields.
pub type CreateMessage {
  CreateMessage(
    /// Max 2000 characters.
    content: Option(String),
    /// Max 10, and 6000 characters across all of them.
    embeds: List(Embed),
    components: List(component.Component),
    /// Max 3.
    sticker_ids: List(id.StickerId),
    /// Drives both the `attachments` array and the `files[n]` parts.
    files: List(File),
    /// `None` is Discord's default: parse and deliver every mention in the
    /// content. A decision, not an absence.
    allowed_mentions: Option(AllowedMentions),
    reference: Option(Reference),
    tts: Bool,
    /// Discord ignores `enforce_nonce` without a nonce, so the two are one
    /// value and the inert combination cannot be built.
    nonce: NoncePolicy,
    /// Only SUPPRESS_EMBEDS, SUPPRESS_NOTIFICATIONS, IS_VOICE_MESSAGE and
    /// IS_COMPONENTS_V2 can be set on a create.
    flags: message.MessageFlags,
  )
}

/// Whether the create carries a nonce, and what Discord should do with it.
pub type NoncePolicy {
  NoNonce

  /// Max 25 characters. Always send a `StringNonce`. `enforce` makes the
  /// create idempotent for a few minutes: a second POST with the same nonce
  /// returns the first message instead of posting twice.
  UseNonce(value: message.Nonce, enforce: Bool)
}

/// A nonce Discord echoes back on MESSAGE_CREATE, enforced, so a retried POST
/// returns the first message rather than posting twice. The safe one is the
/// short name on purpose: a retry is the reason to reach for a nonce at all.
pub fn with_nonce(
  payload: CreateMessage,
  value: message.Nonce,
) -> CreateMessage {
  CreateMessage(..payload, nonce: UseNonce(value:, enforce: True))
}

/// A nonce only for correlating MESSAGE_CREATE back to the create. Discord
/// does not dedupe on it, so a retried POST posts a second message.
pub fn with_correlation_nonce(
  payload: CreateMessage,
  value: message.Nonce,
) -> CreateMessage {
  CreateMessage(..payload, nonce: UseNonce(value:, enforce: False))
}

/// An empty message. Build on it with a record update.
pub fn create() -> CreateMessage {
  CreateMessage(
    content: None,
    embeds: [],
    components: [],
    sticker_ids: [],
    files: [],
    allowed_mentions: None,
    reference: None,
    tts: False,
    nonce: NoNonce,
    flags: message.no_flags,
  )
}

pub fn text(content: String) -> CreateMessage {
  CreateMessage(..create(), content: Some(content))
}

/// A reply. `fail_if_not_exists` stays at Discord's default, so replying to a
/// message that has since been deleted is a 400.
pub fn reply_to(message_id: id.MessageId, content: String) -> CreateMessage {
  CreateMessage(
    ..text(content),
    reference: Some(Reply(
      message_id: message_id,
      channel_id: None,
      guild_id: None,
      fail_if_not_exists: True,
    )),
  )
}

/// A forward, which carries no content of its own.
pub fn forward_of(
  message_id: id.MessageId,
  from channel_id: id.ChannelId,
) -> CreateMessage {
  CreateMessage(
    ..create(),
    reference: Some(Forward(
      message_id: message_id,
      channel_id: channel_id,
      guild_id: None,
    )),
  )
}

/// A ready-to-send body, files already paired to their `attachments` entries.
pub fn create_body(payload: CreateMessage) -> Body {
  case payload.files {
    [] -> body.json(create_fields(payload))
    files ->
      body.Form(payload: create_fields(payload), files: file.parts(files))
  }
}

fn create_fields(payload: CreateMessage) -> List(#(String, Json)) {
  wire.entries([
    #("content", wire.put(wire.opt(payload.content), json.string)),
    #("nonce", nonce(payload.nonce)),
    #("tts", wire.flag(payload.tts)),
    #("embeds", wire.put_list(wire.opt_list(payload.embeds), embed.to_json)),
    #(
      "allowed_mentions",
      wire.put(wire.opt(payload.allowed_mentions), allowed_mentions.to_json),
    ),
    #(
      "message_reference",
      wire.put(wire.opt(payload.reference), reference_to_json),
    ),
    #(
      "components",
      wire.put_list(wire.opt_list(payload.components), component.to_json),
    ),
    #(
      "sticker_ids",
      wire.put_list(wire.opt_list(payload.sticker_ids), id.to_json),
    ),
    #("attachments", file.new_attachments_field(payload.files)),
    #("flags", flags_field(payload.flags)),
    #("enforce_nonce", enforcement(payload.nonce)),
  ])
}

/// `PATCH /channels/{c}/messages/{m}`. The `attachments` array has to name
/// every attachment that survives the edit, so it and the uploads are one
/// field.
pub type EditMessage {
  EditMessage(
    content: Field(String),
    /// `Null` sends `null`. `Present([])` empties the list, which is what
    /// IS_COMPONENTS_V2 requires: it wants `[]` specifically, not `null`.
    embeds: Field(List(Embed)),
    components: Field(List(component.Component)),
    /// SUPPRESS_EMBEDS can be set and unset. IS_COMPONENTS_V2 can only be
    /// set, and never comes off that message again.
    flags: Field(message.MessageFlags),
    /// Not optional. An edit that leaves it out re-parses the content with
    /// Discord's defaults, whatever the message was sent with.
    allowed_mentions: AllowedMentions,
    attachments: EditAttachments,
  )
}

/// The only constructor: the mention policy is not optional.
pub fn edit(mentions: AllowedMentions) -> EditMessage {
  EditMessage(
    content: Absent,
    embeds: Absent,
    components: Absent,
    flags: Absent,
    allowed_mentions: mentions,
    attachments: KeepAttachments,
  )
}

/// A ready-to-send body for a `PATCH`, files included.
pub fn edit_body(payload: EditMessage) -> Body {
  case edit_files(payload) {
    [] -> body.json(edit_fields(payload))
    files -> body.Form(payload: edit_fields(payload), files: file.parts(files))
  }
}

fn edit_fields(payload: EditMessage) -> List(#(String, Json)) {
  wire.entries(edit_entries(payload))
}

/// The edit keys before the absent ones are dropped. Public because the
/// interaction callback nests the same six keys under `data`.
pub fn edit_entries(payload: EditMessage) -> List(#(String, Field(Json))) {
  [
    #("content", wire.put(payload.content, json.string)),
    #("embeds", wire.put_list(payload.embeds, embed.to_json)),
    #("flags", wire.put(payload.flags, flags.to_json)),
    #(
      "allowed_mentions",
      allowed_mentions.mention_policy(
        payload.allowed_mentions,
        content: payload.content,
        components: payload.components,
      ),
    ),
    #("components", wire.put_list(payload.components, component.to_json)),
    #("attachments", file.attachments_field(payload.attachments)),
  ]
}

/// The files the multipart body has to carry, in `files[n]` order.
pub fn edit_files(payload: EditMessage) -> List(File) {
  file.added_files(payload.attachments)
}

/// `POST /channels/{c}/messages/bulk-delete`. Two to 100 ids, none older than
/// 14 days, or Discord rejects the whole batch.
pub type BulkDelete {
  BulkDelete(messages: List(id.MessageId))
}

pub fn bulk_delete_body(payload: BulkDelete) -> Body {
  body.json([#("messages", json.array(payload.messages, id.to_json))])
}

/// No flags set is an absence, not a zero. Public because a create and an
/// interaction callback both write the key this way.
pub fn flags_field(value: message.MessageFlags) -> Field(Json) {
  case flags.to_int(value) {
    0 -> Absent
    _ -> Present(flags.to_json(value))
  }
}

fn nonce(policy: NoncePolicy) -> Field(Json) {
  case policy {
    NoNonce -> Absent
    UseNonce(value:, ..) -> Present(message.nonce_to_json(value))
  }
}

/// Never written on its own: Discord ignores `enforce_nonce` with no nonce
/// beside it, and false is its default.
fn enforcement(policy: NoncePolicy) -> Field(Json) {
  case policy {
    NoNonce | UseNonce(enforce: False, ..) -> Absent
    UseNonce(enforce: True, ..) -> Present(json.bool(True))
  }
}

/// Append an embed. Repeated calls build the list up.
pub fn embed(payload: CreateMessage, embed: Embed) -> CreateMessage {
  CreateMessage(..payload, embeds: list.append(payload.embeds, [embed]))
}

/// Replaces the text, where `embed` appends.
pub fn content(payload: CreateMessage, content: String) -> CreateMessage {
  CreateMessage(..payload, content: Some(content))
}
