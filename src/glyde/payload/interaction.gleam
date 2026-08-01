//// The response to an interaction: `POST /interactions/{id}/{token}/callback`.
////
//// Types 4 and 7 share a JSON shape and not their semantics: 4 creates a
//// message, so an omitted key is unset; 7 edits the message the component sits
//// on, so an omitted key keeps the old value. Hence two types.
////
//// Deferring fixes ephemerality for the whole interaction: defer publicly,
//// edit with EPHEMERAL, and the reply leaks into the channel.

import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import glyde/field.{type Field, Absent, Present}
import glyde/flags
import glyde/model/application_command.{type ApplicationCommandOptionChoice}
import glyde/model/component.{type Component}
import glyde/model/interaction
import glyde/model/message.{
  type MessageFlags, Ephemeral, message_flags, no_flags, with_flag,
}
import glyde/payload/allowed_mentions.{type AllowedMentions}
import glyde/payload/embed.{type Embed}
import glyde/payload/file.{type File}
import glyde/payload/message as outgoing
import glyde/rest/body.{type Body}
import glyde/wire

/// Send-only, so no unknown tail.
pub type InteractionResponse {
  /// ACK a PING. A gateway bot never sends this; an HTTP-interactions bot that
  /// cannot send it can never register its endpoint.
  Pong

  /// Reply with a new message. Create semantics.
  ChannelMessageWithSource(MessageCallbackData)

  /// "Thinking...". Turns the three-second budget into fifteen minutes; finish
  /// with `PATCH /webhooks/{app}/{token}/messages/@original`. EPHEMERAL is the
  /// only flag accepted, hence `Bool`.
  DeferredChannelMessageWithSource(ephemeral: Bool)

  /// Components only. ACK with no loading state, and no data at all.
  DeferredUpdateMessage

  /// Components only. Edit semantics: `Present([])` takes the components off
  /// the message. Field for field and key for key this is a message edit, so
  /// it carries the same type, built with `payload/message.edit`.
  UpdateMessage(outgoing.EditMessage)

  /// Autocomplete only. An empty list is legal and means no suggestions.
  /// Max 25.
  AutocompleteResult(choices: List(ApplicationCommandOptionChoice))
}

/// Callback data for `ChannelMessageWithSource`. Same shape and rules as
/// `CreateMessage`.
pub type MessageCallbackData {
  MessageCallbackData(
    content: Option(String),
    tts: Bool,
    embeds: List(Embed),
    components: List(Component),
    files: List(File),
    /// A decision, never a default: leaving it out lets Discord turn every
    /// @mention in the content into a real ping.
    allowed_mentions: Option(AllowedMentions),
    /// Only EPHEMERAL, SUPPRESS_EMBEDS, SUPPRESS_NOTIFICATIONS,
    /// IS_VOICE_MESSAGE and IS_COMPONENTS_V2 are accepted. Prefer `ephemeral`
    /// to assembling this by hand.
    flags: MessageFlags,
  )
}

pub fn message_data() -> MessageCallbackData {
  MessageCallbackData(
    content: None,
    tts: False,
    embeds: [],
    components: [],
    files: [],
    allowed_mentions: None,
    flags: no_flags,
  )
}

pub fn text(content: String) -> MessageCallbackData {
  MessageCallbackData(..message_data(), content: Some(content))
}

/// Only the invoking user sees it.
pub fn ephemeral(data: MessageCallbackData) -> MessageCallbackData {
  MessageCallbackData(..data, flags: with_flag(data.flags, Ephemeral))
}

/// The only constructor: the mention policy is not optional.
pub fn update_data(mentions: AllowedMentions) -> outgoing.EditMessage {
  outgoing.edit(mentions)
}

pub fn to_json(response: InteractionResponse) -> Json {
  json.object(response_fields(response))
}

/// A ready-to-send body for the callback route, files already paired to their
/// `attachments` entries.
///
/// The callback nests its `attachments` array under `data`, so the document is
/// finished here rather than left open: a top-level array as well would name
/// the same parts twice, and the copy without the kept ones deletes them.
pub fn response_body(response: InteractionResponse) -> Body {
  case response_files(response) {
    [] -> body.json(response_fields(response))
    files -> body.Finished(payload: to_json(response), files: file.parts(files))
  }
}

fn response_fields(response: InteractionResponse) -> List(#(String, Json)) {
  wire.entries([
    #(
      "type",
      Present(interaction.callback_type_to_json(callback_type(response))),
    ),
    #("data", data(response)),
  ])
}

/// The callback type Discord reads off the envelope. The numbering lives in
/// `model/interaction`, which decodes the same values coming back.
pub fn callback_type(
  response: InteractionResponse,
) -> interaction.InteractionCallbackType {
  case response {
    Pong -> interaction.PongCallback
    ChannelMessageWithSource(_) -> interaction.ChannelMessageWithSourceCallback
    DeferredChannelMessageWithSource(_) ->
      interaction.DeferredChannelMessageWithSourceCallback
    DeferredUpdateMessage -> interaction.DeferredUpdateMessageCallback
    UpdateMessage(_) -> interaction.UpdateMessageCallback
    AutocompleteResult(_) -> interaction.AutocompleteResultCallback
  }
}

/// The files the multipart body has to carry, in `files[n]` order.
pub fn response_files(response: InteractionResponse) -> List(File) {
  case response {
    ChannelMessageWithSource(data) -> data.files
    UpdateMessage(data) -> outgoing.edit_files(data)
    Pong
    | DeferredChannelMessageWithSource(_)
    | DeferredUpdateMessage
    | AutocompleteResult(_) -> []
  }
}

pub fn message_data_to_json(data: MessageCallbackData) -> Json {
  wire.object(message_data_entries(data))
}

pub fn update_data_to_json(data: outgoing.EditMessage) -> Json {
  wire.object(outgoing.edit_entries(data))
}

fn data(response: InteractionResponse) -> Field(Json) {
  case response {
    Pong | DeferredUpdateMessage -> Absent

    ChannelMessageWithSource(data) -> Present(message_data_to_json(data))

    // EPHEMERAL is all this response can carry, so a public defer sends no
    // `data` at all.
    DeferredChannelMessageWithSource(True) ->
      Present(
        json.object([
          #("flags", flags.to_json(message_flags(of: [Ephemeral]))),
        ]),
      )
    DeferredChannelMessageWithSource(False) -> Absent

    UpdateMessage(data) -> Present(update_data_to_json(data))

    AutocompleteResult(choices:) ->
      Present(
        json.object([
          #("choices", json.array(choices, application_command.choice_to_json)),
        ]),
      )
  }
}

fn message_data_entries(
  data: MessageCallbackData,
) -> List(#(String, Field(Json))) {
  [
    #("tts", wire.flag(data.tts)),
    #("content", wire.put(wire.opt(data.content), json.string)),
    #("embeds", wire.put_list(wire.opt_list(data.embeds), embed.to_json)),
    #(
      "allowed_mentions",
      wire.put(wire.opt(data.allowed_mentions), allowed_mentions.to_json),
    ),
    #("flags", outgoing.flags_field(data.flags)),
    #(
      "components",
      wire.put_list(wire.opt_list(data.components), component.to_json),
    ),
    #("attachments", file.new_attachments_field(data.files)),
  ]
}
