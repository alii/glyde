//// A message on its way out: the create body every bot builds, plus the edit
//// and bulk-delete bodies that sit beside it.
////
//// Create and edit are separate types: an empty array is an absence on POST
//// and an instruction on PATCH. `allowed_mentions` is required on `edit`
//// because an edit without it re-parses the content with Discord's defaults,
//// whatever the message was sent with.
////
//// A draft is built by piping from `new()` or `text`. Setters for the list
//// fields (`embed`, `attach`, `component`, `sticker`) append; the rest replace.

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
pub type Draft {
  Draft(
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

const empty = Draft(
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

/// An empty draft, to pipe setters onto.
pub fn new() -> Draft {
  empty
}

/// `new() |> content(content)`, since most messages start with words.
pub fn text(content: String) -> Draft {
  Draft(..new(), content: Some(content))
}

/// A draft with this message's content, embeds, components, stickers and
/// the flags a create may set. Attachments do not carry: a received one is a
/// URL, a draft's is bytes. Nor do the receive-only parts of an embed (type,
/// provider, video, proxy urls, media sizes), which Discord drops on send.
pub fn from(message: message.Message) -> Draft {
  Draft(
    ..new(),
    content: case message.content {
      "" -> None
      content -> Some(content)
    },
    embeds: list.map(message.embeds, embed.from),
    components: message.components,
    sticker_ids: list.map(message.sticker_items, fn(item) { item.id }),
    flags: settable_on_create(message.flags),
  )
}

// IS_VOICE_MESSAGE is settable too, but only with the audio file beside it,
// and files do not carry.
fn settable_on_create(received: message.MessageFlags) -> message.MessageFlags {
  [
    message.SuppressEmbeds,
    message.SuppressNotifications,
    message.IsComponentsV2,
  ]
  |> list.filter(fn(flag) { message.has_flag(received, flag) })
  |> message.message_flags
}

pub fn content(draft: Draft, content: String) -> Draft {
  Draft(..draft, content: Some(content))
}

pub fn embed(draft: Draft, embed: Embed) -> Draft {
  Draft(..draft, embeds: list.append(draft.embeds, [embed]))
}

/// `to_body` writes the matching `attachments` entry, so an embed can point
/// at it with `attachment://{filename}`.
pub fn attach(draft: Draft, file: File) -> Draft {
  Draft(..draft, files: list.append(draft.files, [file]))
}

/// One top-level component, so an action row at a time.
pub fn component(draft: Draft, component: component.Component) -> Draft {
  Draft(..draft, components: list.append(draft.components, [component]))
}

/// Discord takes at most 3.
pub fn sticker(draft: Draft, sticker: id.StickerId) -> Draft {
  Draft(..draft, sticker_ids: list.append(draft.sticker_ids, [sticker]))
}

/// Without this Discord pings every mention in the content.
pub fn mentions(draft: Draft, policy: AllowedMentions) -> Draft {
  Draft(..draft, allowed_mentions: Some(policy))
}

/// Make it a reply. `fail_if_not_exists` stays at Discord's default, so
/// replying to a message that has since been deleted is a 400.
pub fn reply_to(draft: Draft, message_id: id.MessageId) -> Draft {
  Draft(
    ..draft,
    reference: Some(Reply(
      message_id: message_id,
      channel_id: None,
      guild_id: None,
      fail_if_not_exists: True,
    )),
  )
}

/// Make it a forward. Discord accepts `new() |> forward_of(..)` on its own: a
/// forward needs no content.
pub fn forward_of(
  draft: Draft,
  message_id: id.MessageId,
  from channel_id: id.ChannelId,
) -> Draft {
  Draft(
    ..draft,
    reference: Some(Forward(
      message_id: message_id,
      channel_id: channel_id,
      guild_id: None,
    )),
  )
}

/// Read aloud by the client to anyone with the channel open.
pub fn tts(draft: Draft) -> Draft {
  Draft(..draft, tts: True)
}

/// No link previews. The other create-time flags are IS_VOICE_MESSAGE and
/// IS_COMPONENTS_V2; set those on `flags` directly.
pub fn suppress_embeds(draft: Draft) -> Draft {
  with(draft, message.SuppressEmbeds)
}

/// Delivered without a push or desktop notification, mentions included.
pub fn silent(draft: Draft) -> Draft {
  with(draft, message.SuppressNotifications)
}

fn with(draft: Draft, flag: message.MessageFlag) -> Draft {
  Draft(..draft, flags: message.with_flag(draft.flags, flag))
}

/// A nonce Discord echoes back on MESSAGE_CREATE, enforced, so a retried POST
/// returns the first message rather than posting twice. The safe one is the
/// short name on purpose: a retry is the reason to reach for a nonce at all.
pub fn with_nonce(draft: Draft, value: message.Nonce) -> Draft {
  Draft(..draft, nonce: UseNonce(value:, enforce: True))
}

/// A nonce only for correlating MESSAGE_CREATE back to the create. Discord
/// does not dedupe on it, so a retried POST posts a second message.
pub fn with_correlation_nonce(draft: Draft, value: message.Nonce) -> Draft {
  Draft(..draft, nonce: UseNonce(value:, enforce: False))
}

/// A ready-to-send body, files already paired to their `attachments` entries.
pub fn to_body(draft: Draft) -> Body {
  case draft.files {
    [] -> body.json(create_fields(draft))
    files -> body.Form(payload: create_fields(draft), files: file.parts(files))
  }
}

fn create_fields(draft: Draft) -> List(#(String, Json)) {
  wire.entries([
    #("content", wire.put(wire.opt(draft.content), json.string)),
    #("nonce", nonce(draft.nonce)),
    #("tts", wire.flag(draft.tts)),
    #("embeds", wire.put_list(wire.opt_list(draft.embeds), embed.to_json)),
    #(
      "allowed_mentions",
      wire.put(wire.opt(draft.allowed_mentions), allowed_mentions.to_json),
    ),
    #(
      "message_reference",
      wire.put(wire.opt(draft.reference), reference_to_json),
    ),
    #(
      "components",
      wire.put_list(wire.opt_list(draft.components), component.to_json),
    ),
    #(
      "sticker_ids",
      wire.put_list(wire.opt_list(draft.sticker_ids), id.to_json),
    ),
    #("attachments", file.new_attachments_field(draft.files)),
    #("flags", flags_field(draft.flags)),
    #("enforce_nonce", enforcement(draft.nonce)),
  ])
}

/// `PATCH /channels/{c}/messages/{m}`. The `attachments` array has to name
/// every attachment that survives the edit, so it and the uploads are one
/// field.
pub type Edit {
  Edit(
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
pub fn edit(mentions: AllowedMentions) -> Edit {
  Edit(
    content: Absent,
    embeds: Absent,
    components: Absent,
    flags: Absent,
    allowed_mentions: mentions,
    attachments: KeepAttachments,
  )
}

/// A ready-to-send body for a `PATCH`, files included.
pub fn edit_body(edit: Edit) -> Body {
  case edit_files(edit) {
    [] -> body.json(edit_fields(edit))
    files -> body.Form(payload: edit_fields(edit), files: file.parts(files))
  }
}

fn edit_fields(edit: Edit) -> List(#(String, Json)) {
  wire.entries(edit_entries(edit))
}

/// The edit keys before the absent ones are dropped. Public because the
/// interaction callback nests the same six keys under `data`.
pub fn edit_entries(edit: Edit) -> List(#(String, Field(Json))) {
  [
    #("content", wire.put(edit.content, json.string)),
    #("embeds", wire.put_list(edit.embeds, embed.to_json)),
    #("flags", wire.put(edit.flags, flags.to_json)),
    #(
      "allowed_mentions",
      allowed_mentions.mention_policy(
        edit.allowed_mentions,
        content: edit.content,
        components: edit.components,
      ),
    ),
    #("components", wire.put_list(edit.components, component.to_json)),
    #("attachments", file.attachments_field(edit.attachments)),
  ]
}

/// The files the multipart body has to carry, in `files[n]` order.
pub fn edit_files(edit: Edit) -> List(File) {
  file.added_files(edit.attachments)
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
