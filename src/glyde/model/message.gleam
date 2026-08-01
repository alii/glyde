//// Messages, and everything reachable from one.
////
//// `content`, `embeds`, `attachments` and `components` arrive EMPTY, not
//// absent, without the MESSAGE_CONTENT intent. Nothing tells that apart from a
//// genuinely empty message.
////
//// MESSAGE_UPDATE does not carry a `Message`, whatever the docs say. Use
//// `update_decoder`, never `decoder`, on that event.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import glyde/field.{Absent, Null, Present}
import glyde/flags.{type Flags}
import glyde/id
import glyde/model/attachment
import glyde/model/channel
import glyde/model/component
import glyde/model/embed
import glyde/model/emoji
import glyde/model/member
import glyde/model/user
import glyde/wire.{type Field}

pub type Message {
  Message(
    id: id.MessageId,
    channel_id: id.ChannelId,
    /// A gateway extra. Absent in DMs and on ephemeral messages.
    guild_id: Option(id.GuildId),
    /// Not a real user when `webhook_id` is set: id, username and avatar only.
    author: user.User,
    /// A gateway extra with no `user` key: the author is the field above.
    member: Option(member.GuildMember),
    /// EMPTY, not absent, when the app lacks the MESSAGE_CONTENT intent.
    content: String,
    /// ISO-8601.
    timestamp: String,
    /// Null means never edited.
    edited_timestamp: Option(String),
    /// Always false on MESSAGE_UPDATE, whatever the original message was.
    tts: Bool,
    mention_everyone: Bool,
    mentions: List(Mention),
    mention_roles: List(id.RoleId),
    /// Crossposted messages only, and only from public text channels.
    mention_channels: List(ChannelMention),
    attachments: List(attachment.Attachment),
    embeds: List(embed.Embed),
    /// Absent when there are none, and from message search results.
    reactions: List(Reaction),
    /// `None` when there was none, and when the one sent was too big to hold.
    /// Always send `StringNonce`, whatever arrived here.
    nonce: Option(Nonce),
    pinned: Bool,
    /// The only reliable webhook test: `author.bot` is true of bots too.
    webhook_id: Option(id.WebhookId),
    type_: MessageType,
    application_id: Option(id.ApplicationId),
    flags: MessageFlags,
    message_reference: Option(MessageReference),
    /// `Absent` is never fetched, `Null` is deleted, the only signal a reply
    /// bot gets. Use `referenced` if you do not care which.
    referenced_message: Field(Message),
    thread: Option(channel.Channel),
    components: List(component.Component),
    sticker_items: List(StickerItem),
    /// Approximate, with gaps and duplicates. Ordering only.
    position: Option(Int),
  )
}

/// Discord splices `member` into each element of `mentions`.
pub type Mention {
  Mention(user: user.User, member: Option(member.GuildMember))
}

/// Discord echoes back whatever was sent, so both exist for reading. Always
/// SEND a `StringNonce`: it is a dedup key, and a number can be reinterpreted.
///
/// There is no variant for a nonce too big to hold, because this type is also
/// what a create sends: a lost value has to read as `None` and omit the key,
/// not encode as a null Discord would take for an instruction.
pub type Nonce {
  StringNonce(String)
  IntNonce(Int)
}

pub type ChannelMention {
  ChannelMention(
    id: id.ChannelId,
    guild_id: id.GuildId,
    type_: channel.ChannelType,
    name: String,
  )
}

pub type StickerItem {
  StickerItem(id: id.StickerId, name: String, format_type: StickerFormat)
}

/// Discord's sticker format table. A missing `format_type` reads as
/// `UnknownStickerFormat(0)`, which is not a value Discord sends.
pub type StickerFormat {
  PngSticker
  ApngSticker
  LottieSticker
  GifSticker
  UnknownStickerFormat(Int)
}

pub type Reaction {
  Reaction(
    /// Normal and super reactions added together.
    count: Int,
    count_details: ReactionCountDetails,
    me: Bool,
    me_burst: Bool,
    /// A PARTIAL emoji, with a null `id` for a unicode reaction.
    emoji: emoji.Emoji,
    /// Hex colours for the super-reaction burst, with no leading `#`.
    burst_colors: List(String),
  )
}

pub type ReactionCountDetails {
  ReactionCountDetails(burst: Int, normal: Int)
}

/// Discord's two kinds of reaction, one type for both the gateway events and
/// the `type` query parameter on the reactions route. A burst reaction is the
/// animated "super reaction" a Nitro subscriber can send.
pub type ReactionType {
  NormalReaction
  BurstReaction
  /// Discord adds values here between releases.
  UnknownReactionType(Int)
}

pub type MessageReference {
  MessageReference(
    /// Absent means DEFAULT, not unknown.
    type_: MessageReferenceType,
    /// Absent on CHANNEL_FOLLOW_ADD and THREAD_CREATED, which reference a
    /// channel and not a message.
    message_id: Option(id.MessageId),
    channel_id: Option(id.ChannelId),
    guild_id: Option(id.GuildId),
  )
}

pub type MessageReferenceType {
  /// Replies, crossposts, pins and thread starters. Populates
  /// `referenced_message`.
  DefaultReference
  /// Forwards. Populates `message_snapshots`, which is not modelled.
  ForwardReference
  UnknownReference(Int)
}

/// 0 to 46, with holes at 13, 30, 33 to 35, 40 to 43 and 45. Never index this
/// by position.
pub type MessageType {
  DefaultMessage
  RecipientAdd
  RecipientRemove
  Call
  ChannelNameChange
  ChannelIconChange
  ChannelPinnedMessage
  UserJoin
  GuildBoost
  GuildBoostTier1
  GuildBoostTier2
  GuildBoostTier3
  ChannelFollowAdd
  GuildDiscoveryDisqualified
  GuildDiscoveryRequalified
  GuildDiscoveryGracePeriodInitialWarning
  GuildDiscoveryGracePeriodFinalWarning
  ThreadCreated
  ReplyMessage
  ChatInputCommand
  ThreadStarterMessage
  GuildInviteReminder
  ContextMenuCommand
  AutoModerationAction
  RoleSubscriptionPurchase
  InteractionPremiumUpsell
  StageStart
  StageEnd
  StageSpeaker
  StageTopic
  GuildApplicationPremiumSubscription
  GuildIncidentAlertModeEnabled
  GuildIncidentAlertModeDisabled
  GuildIncidentReportRaid
  GuildIncidentReportFalseAlarm
  PurchaseNotification
  PollResult
  UnknownMessageType(Int)
}

pub fn message_type_from_int(value: Int) -> MessageType {
  case value {
    0 -> DefaultMessage
    1 -> RecipientAdd
    2 -> RecipientRemove
    3 -> Call
    4 -> ChannelNameChange
    5 -> ChannelIconChange
    6 -> ChannelPinnedMessage
    7 -> UserJoin
    8 -> GuildBoost
    9 -> GuildBoostTier1
    10 -> GuildBoostTier2
    11 -> GuildBoostTier3
    12 -> ChannelFollowAdd
    14 -> GuildDiscoveryDisqualified
    15 -> GuildDiscoveryRequalified
    16 -> GuildDiscoveryGracePeriodInitialWarning
    17 -> GuildDiscoveryGracePeriodFinalWarning
    18 -> ThreadCreated
    19 -> ReplyMessage
    20 -> ChatInputCommand
    21 -> ThreadStarterMessage
    22 -> GuildInviteReminder
    23 -> ContextMenuCommand
    24 -> AutoModerationAction
    25 -> RoleSubscriptionPurchase
    26 -> InteractionPremiumUpsell
    27 -> StageStart
    28 -> StageEnd
    29 -> StageSpeaker
    31 -> StageTopic
    32 -> GuildApplicationPremiumSubscription
    36 -> GuildIncidentAlertModeEnabled
    37 -> GuildIncidentAlertModeDisabled
    38 -> GuildIncidentReportRaid
    39 -> GuildIncidentReportFalseAlarm
    44 -> PurchaseNotification
    46 -> PollResult
    other -> UnknownMessageType(other)
  }
}

pub fn message_type_to_int(value: MessageType) -> Int {
  case value {
    DefaultMessage -> 0
    RecipientAdd -> 1
    RecipientRemove -> 2
    Call -> 3
    ChannelNameChange -> 4
    ChannelIconChange -> 5
    ChannelPinnedMessage -> 6
    UserJoin -> 7
    GuildBoost -> 8
    GuildBoostTier1 -> 9
    GuildBoostTier2 -> 10
    GuildBoostTier3 -> 11
    ChannelFollowAdd -> 12
    GuildDiscoveryDisqualified -> 14
    GuildDiscoveryRequalified -> 15
    GuildDiscoveryGracePeriodInitialWarning -> 16
    GuildDiscoveryGracePeriodFinalWarning -> 17
    ThreadCreated -> 18
    ReplyMessage -> 19
    ChatInputCommand -> 20
    ThreadStarterMessage -> 21
    GuildInviteReminder -> 22
    ContextMenuCommand -> 23
    AutoModerationAction -> 24
    RoleSubscriptionPurchase -> 25
    InteractionPremiumUpsell -> 26
    StageStart -> 27
    StageEnd -> 28
    StageSpeaker -> 29
    StageTopic -> 31
    GuildApplicationPremiumSubscription -> 32
    GuildIncidentAlertModeEnabled -> 36
    GuildIncidentAlertModeDisabled -> 37
    GuildIncidentReportRaid -> 38
    GuildIncidentReportFalseAlarm -> 39
    PurchaseNotification -> 44
    PollResult -> 46
    UnknownMessageType(other) -> other
  }
}

pub fn message_type_decoder() -> Decoder(MessageType) {
  wire.integer() |> decode.map(message_type_from_int)
}

pub fn message_type_to_json(value: MessageType) -> Json {
  json.int(message_type_to_int(value))
}

/// Whether `DELETE /channels/{id}/messages/{id}` accepts this message. An
/// unknown type answers False, because a guess costs a confusing 400.
pub fn is_deletable(value: MessageType) -> Bool {
  case value {
    RecipientAdd
    | RecipientRemove
    | Call
    | ChannelNameChange
    | ChannelIconChange
    | ThreadStarterMessage -> False
    UnknownMessageType(_) -> False
    _ -> True
  }
}

pub fn message_reference_type_from_int(value: Int) -> MessageReferenceType {
  case value {
    0 -> DefaultReference
    1 -> ForwardReference
    other -> UnknownReference(other)
  }
}

pub fn message_reference_type_to_int(value: MessageReferenceType) -> Int {
  case value {
    DefaultReference -> 0
    ForwardReference -> 1
    UnknownReference(other) -> other
  }
}

pub fn message_reference_type_decoder() -> Decoder(MessageReferenceType) {
  wire.integer() |> decode.map(message_reference_type_from_int)
}

pub fn message_reference_type_to_json(value: MessageReferenceType) -> Json {
  json.int(message_reference_type_to_int(value))
}

pub fn sticker_format_from_int(value: Int) -> StickerFormat {
  case value {
    1 -> PngSticker
    2 -> ApngSticker
    3 -> LottieSticker
    4 -> GifSticker
    other -> UnknownStickerFormat(other)
  }
}

/// The exact inverse of `sticker_format_from_int`: a value this build does not
/// know still goes back out as itself.
pub fn sticker_format_to_int(value: StickerFormat) -> Int {
  case value {
    PngSticker -> 1
    ApngSticker -> 2
    LottieSticker -> 3
    GifSticker -> 4
    UnknownStickerFormat(other) -> other
  }
}

pub fn reaction_type_from_int(value: Int) -> ReactionType {
  case value {
    0 -> NormalReaction
    1 -> BurstReaction
    other -> UnknownReactionType(other)
  }
}

/// The exact inverse of `reaction_type_from_int`: a value this build does not
/// know still goes back out as itself.
pub fn reaction_type_to_int(value: ReactionType) -> Int {
  case value {
    NormalReaction -> 0
    BurstReaction -> 1
    UnknownReactionType(other) -> other
  }
}

pub fn reaction_type_decoder() -> Decoder(ReactionType) {
  wire.integer() |> decode.map(reaction_type_from_int)
}

pub type MessageFlags =
  Flags(MessageFlag)

pub type MessageFlag {
  Crossposted
  IsCrosspost
  SuppressEmbeds
  SourceMessageDeleted
  Urgent
  HasThread
  Ephemeral
  Loading
  FailedToMentionSomeRolesInThread
  SuppressNotifications
  IsVoiceMessage
  HasSnapshot
  /// Once set on a message this can never be removed.
  IsComponentsV2
}

fn message_flag_bit(flag: MessageFlag) -> Int {
  case flag {
    Crossposted -> 1
    IsCrosspost -> 2
    SuppressEmbeds -> 4
    SourceMessageDeleted -> 8
    Urgent -> 16
    HasThread -> 32
    Ephemeral -> 64
    Loading -> 128
    FailedToMentionSomeRolesInThread -> 256
    SuppressNotifications -> 4096
    IsVoiceMessage -> 8192
    HasSnapshot -> 16_384
    IsComponentsV2 -> 32_768
  }
}

pub const no_flags: MessageFlags = flags.none

pub fn message_flags(of chosen: List(MessageFlag)) -> MessageFlags {
  list.fold(chosen, no_flags, with_flag)
}

pub fn has_flag(bits: MessageFlags, flag: MessageFlag) -> Bool {
  flags.has_bit(bits, message_flag_bit(flag))
}

pub fn with_flag(bits: MessageFlags, flag: MessageFlag) -> MessageFlags {
  flags.set_bit(bits, message_flag_bit(flag))
}

pub fn without_flag(bits: MessageFlags, flag: MessageFlag) -> MessageFlags {
  flags.clear_bit(bits, message_flag_bit(flag))
}

pub fn decoder() -> Decoder(Message) {
  use id <- decode.field("id", id.decoder())
  use channel_id <- decode.field("channel_id", id.decoder())
  use guild_id <- wire.opt_field("guild_id", id.decoder())
  use author <- decode.field("author", user.decoder())
  use member <- wire.opt_field("member", member.decoder())
  use content <- wire.string_field("content", "")
  use timestamp <- wire.string_field("timestamp", "")
  use edited_timestamp <- wire.opt_field("edited_timestamp", decode.string)
  use tts <- wire.flag_field("tts", False)
  use mention_everyone <- wire.flag_field("mention_everyone", False)
  use mentions <- wire.list_field("mentions", mention_decoder())
  use mention_roles <- wire.list_field("mention_roles", id.decoder())
  use mention_channels <- wire.list_field(
    "mention_channels",
    channel_mention_decoder(),
  )
  use attachments <- wire.list_field("attachments", attachment.decoder())
  use embeds <- wire.list_field("embeds", embed.decoder())
  use reactions <- wire.list_field("reactions", reaction_decoder())
  use nonce <- wire.opt_field("nonce", nonce_decoder())
  use pinned <- wire.flag_field("pinned", False)
  use webhook_id <- wire.opt_field("webhook_id", id.decoder())
  use type_ <- wire.int_field("type", 0)
  use application_id <- wire.opt_field("application_id", id.decoder())
  use flag_bits <- wire.int_field("flags", 0)
  use message_reference <- wire.opt_field(
    "message_reference",
    message_reference_decoder(),
  )
  use referenced_message <- wire.tri_field(
    "referenced_message",
    decode.recursive(decoder),
  )
  use thread <- wire.opt_field("thread", channel.decoder())
  use components <- wire.list_field("components", component.decoder())
  use sticker_items <- wire.list_field("sticker_items", sticker_item_decoder())
  use position <- wire.opt_field("position", wire.integer())
  decode.success(Message(
    id:,
    channel_id:,
    guild_id:,
    author:,
    member:,
    content:,
    timestamp:,
    edited_timestamp:,
    tts:,
    mention_everyone:,
    mentions:,
    mention_roles:,
    mention_channels:,
    attachments:,
    embeds:,
    reactions:,
    nonce: option.flatten(nonce),
    pinned:,
    webhook_id:,
    type_: message_type_from_int(type_),
    application_id:,
    flags: flags.from_int(flag_bits),
    message_reference:,
    referenced_message:,
    thread:,
    components:,
    sticker_items:,
    position:,
  ))
}

/// The user object is not nested: the spliced `member` sits beside its keys.
pub fn mention_decoder() -> Decoder(Mention) {
  use user <- decode.then(user.decoder())
  use member <- wire.opt_field("member", member.decoder())
  decode.success(Mention(user:, member:))
}

/// Total on purpose. `wire.integer` rejects a number too big to hold exactly,
/// and `decode.optional_field` passes that failure up, so without the last
/// alternative an oversized nonce would sink the whole message. Past 2^53-1
/// the low digits are already gone, so `None` is all there is to hand back.
pub fn nonce_decoder() -> Decoder(Option(Nonce)) {
  decode.one_of(
    decode.string |> decode.map(fn(text) { Some(StringNonce(text)) }),
    [
      wire.integer() |> decode.map(fn(value) { Some(IntNonce(value)) }),
      decode.success(None),
    ],
  )
}

pub fn nonce_to_json(value: Nonce) -> Json {
  case value {
    StringNonce(text) -> json.string(text)
    IntNonce(value) -> json.int(value)
  }
}

pub fn channel_mention_decoder() -> Decoder(ChannelMention) {
  use id <- decode.field("id", id.decoder())
  use guild_id <- decode.field("guild_id", id.decoder())
  use type_ <- wire.int_field("type", 0)
  use name <- wire.string_field("name", "")
  decode.success(ChannelMention(
    id:,
    guild_id:,
    type_: channel.channel_type_from_int(type_),
    name:,
  ))
}

pub fn sticker_item_decoder() -> Decoder(StickerItem) {
  use id <- decode.field("id", id.decoder())
  use name <- wire.string_field("name", "")
  use format_type <- wire.int_field("format_type", 0)
  decode.success(StickerItem(
    id:,
    name:,
    format_type: sticker_format_from_int(format_type),
  ))
}

/// The super-reaction fields are documented as required and are missing from
/// cached or replayed payloads, so they default.
pub fn reaction_decoder() -> Decoder(Reaction) {
  use count <- wire.int_field("count", 0)
  use count_details <- wire.defaulted_field(
    "count_details",
    reaction_count_details_decoder(),
    ReactionCountDetails(burst: 0, normal: 0),
  )
  use me <- wire.flag_field("me", False)
  use me_burst <- wire.flag_field("me_burst", False)
  use emoji <- decode.field("emoji", emoji.decoder())
  use burst_colors <- wire.list_field("burst_colors", decode.string)
  decode.success(Reaction(
    count:,
    count_details:,
    me:,
    me_burst:,
    emoji:,
    burst_colors:,
  ))
}

pub fn reaction_count_details_decoder() -> Decoder(ReactionCountDetails) {
  use burst <- wire.int_field("burst", 0)
  use normal <- wire.int_field("normal", 0)
  decode.success(ReactionCountDetails(burst:, normal:))
}

pub fn message_reference_decoder() -> Decoder(MessageReference) {
  use type_ <- wire.int_field("type", 0)
  use message_id <- wire.opt_field("message_id", id.decoder())
  use channel_id <- wire.opt_field("channel_id", id.decoder())
  use guild_id <- wire.opt_field("guild_id", id.decoder())
  decode.success(MessageReference(
    type_: message_reference_type_from_int(type_),
    message_id:,
    channel_id:,
    guild_id:,
  ))
}

/// `referenced_message` collapsed to an `Option`.
pub fn referenced(message: Message) -> Option(Message) {
  case message.referenced_message {
    Present(value) -> Some(value)
    Absent | Null -> None
  }
}

pub fn mentioned_users(message: Message) -> List(user.User) {
  list.map(message.mentions, fn(mention) { mention.user })
}

/// `author.bot` is true of ordinary bots too, so it is a different question.
pub fn is_from_webhook(message: Message) -> Bool {
  message.webhook_id != None
}

/// The MESSAGE_UPDATE payload, which is NOT a message object: an embed unfurl
/// sends four keys. `message` is `Some` only when a full object arrived.
pub type MessageUpdate {
  MessageUpdate(
    id: id.MessageId,
    channel_id: id.ChannelId,
    guild_id: Option(id.GuildId),
    message: Option(Message),
    /// The whole payload, for reaching the partial fields.
    raw: Dynamic,
  )
}

pub fn update_decoder() -> Decoder(MessageUpdate) {
  use id <- decode.field("id", id.decoder())
  use channel_id <- decode.field("channel_id", id.decoder())
  use guild_id <- wire.opt_field("guild_id", id.decoder())
  // `author` is the only key besides the two ids that `decoder` requires, so
  // its presence is what tells a full update from a partial one. Deciding on a
  // failed decode instead would file a full update that changed shape as a
  // partial and report nothing.
  use full <- wire.present_field("author")
  use message <- decode.then(case full {
    True -> decoder() |> decode.map(Some)
    False -> decode.success(None)
  })
  use raw <- decode.then(decode.dynamic)
  decode.success(MessageUpdate(id:, channel_id:, guild_id:, message:, raw:))
}

/// One entry from the pins API. The timestamp belongs to the pin, not to the
/// message.
pub type PinnedMessage {
  PinnedMessage(pinned_at: String, message: Message)
}

pub type PinList {
  PinList(items: List(PinnedMessage), has_more: Bool)
}

pub fn pinned_message_decoder() -> Decoder(PinnedMessage) {
  use pinned_at <- wire.string_field("pinned_at", "")
  use message <- decode.field("message", decoder())
  decode.success(PinnedMessage(pinned_at:, message:))
}

pub fn pin_list_decoder() -> Decoder(PinList) {
  use items <- wire.list_field("items", pinned_message_decoder())
  use has_more <- wire.flag_field("has_more", False)
  decode.success(PinList(items:, has_more:))
}
