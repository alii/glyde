//// Messages: what arrives, what to send, and every endpoint that acts on one.
////
//// A `Draft` builds the create body, an `Edit` the patch body. `send`,
//// `reply`, `edit`, `delete`, `react` and `pin` take a whole `Message` where
//// they can, so the ids come from the value you already hold; each has an
//// `_id` variant for a caller who only has ids.
////
//// `content`, `embeds`, `attachments` and `components` arrive EMPTY, not
//// absent, without the MESSAGE_CONTENT intent. Nothing tells that apart from a
//// genuinely empty message.
////
//// MESSAGE_UPDATE does not carry a `Message`, whatever the docs say. Use
//// `update_decoder`, never `decoder`, on that event.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import glyde/api
import glyde/attachment.{type EditAttachments, type File, KeepAttachments}
import glyde/channel
import glyde/component
import glyde/embed.{type Embed}
import glyde/emoji.{type Emoji, Custom, Unicode}
import glyde/field.{type Field, Absent, Null, Present}
import glyde/flags.{type Flags}
import glyde/id
import glyde/member
import glyde/mentions.{type AllowedMentions}
import glyde/rest.{type Call}
import glyde/rest/body.{type Body}
import glyde/rest/query
import glyde/rest/seg
import glyde/user
import glyde/wire

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

/// Discord's sticker format table. A value this build has no name for fails
/// the decode.
pub type StickerFormat {
  PngSticker
  ApngSticker
  LottieSticker
  GifSticker
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
/// animated "super reaction" a Nitro subscriber can send. A value this build
/// has no name for fails the decode.
pub type ReactionType {
  NormalReaction
  BurstReaction
}

pub type MessageReference {
  MessageReference(
    /// Absent reads as DEFAULT. A value this build has no name for fails the
    /// decode.
    type_: MessageReferenceType,
    /// Absent on CHANNEL_FOLLOW_ADD and THREAD_CREATED, which reference a
    /// channel and not a message.
    message_id: Option(id.MessageId),
    channel_id: Option(id.ChannelId),
    guild_id: Option(id.GuildId),
  )
}

/// A value this build has no name for fails the decode.
pub type MessageReferenceType {
  /// Replies, crossposts, pins and thread starters. Populates
  /// `referenced_message`.
  DefaultReference
  /// Forwards. Populates `message_snapshots`, which is not modelled.
  ForwardReference
}

/// 0 to 46, with holes at 13, 30, 33 to 35, 40 to 43 and 45. Never index this
/// by position. A value this build has no name for fails the decode.
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
}

pub fn message_type_from_int(value: Int) -> Option(MessageType) {
  case value {
    0 -> Some(DefaultMessage)
    1 -> Some(RecipientAdd)
    2 -> Some(RecipientRemove)
    3 -> Some(Call)
    4 -> Some(ChannelNameChange)
    5 -> Some(ChannelIconChange)
    6 -> Some(ChannelPinnedMessage)
    7 -> Some(UserJoin)
    8 -> Some(GuildBoost)
    9 -> Some(GuildBoostTier1)
    10 -> Some(GuildBoostTier2)
    11 -> Some(GuildBoostTier3)
    12 -> Some(ChannelFollowAdd)
    14 -> Some(GuildDiscoveryDisqualified)
    15 -> Some(GuildDiscoveryRequalified)
    16 -> Some(GuildDiscoveryGracePeriodInitialWarning)
    17 -> Some(GuildDiscoveryGracePeriodFinalWarning)
    18 -> Some(ThreadCreated)
    19 -> Some(ReplyMessage)
    20 -> Some(ChatInputCommand)
    21 -> Some(ThreadStarterMessage)
    22 -> Some(GuildInviteReminder)
    23 -> Some(ContextMenuCommand)
    24 -> Some(AutoModerationAction)
    25 -> Some(RoleSubscriptionPurchase)
    26 -> Some(InteractionPremiumUpsell)
    27 -> Some(StageStart)
    28 -> Some(StageEnd)
    29 -> Some(StageSpeaker)
    31 -> Some(StageTopic)
    32 -> Some(GuildApplicationPremiumSubscription)
    36 -> Some(GuildIncidentAlertModeEnabled)
    37 -> Some(GuildIncidentAlertModeDisabled)
    38 -> Some(GuildIncidentReportRaid)
    39 -> Some(GuildIncidentReportFalseAlarm)
    44 -> Some(PurchaseNotification)
    46 -> Some(PollResult)
    _ -> None
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
  }
}

pub fn message_type_decoder() -> Decoder(MessageType) {
  wire.strict(message_type_from_int, DefaultMessage, "MessageType")
}

pub fn message_type_to_json(value: MessageType) -> Json {
  json.int(message_type_to_int(value))
}

/// Whether `DELETE /channels/{id}/messages/{id}` accepts this message.
pub fn is_deletable(value: MessageType) -> Bool {
  case value {
    RecipientAdd
    | RecipientRemove
    | Call
    | ChannelNameChange
    | ChannelIconChange
    | ThreadStarterMessage -> False
    DefaultMessage
    | ChannelPinnedMessage
    | UserJoin
    | GuildBoost
    | GuildBoostTier1
    | GuildBoostTier2
    | GuildBoostTier3
    | ChannelFollowAdd
    | GuildDiscoveryDisqualified
    | GuildDiscoveryRequalified
    | GuildDiscoveryGracePeriodInitialWarning
    | GuildDiscoveryGracePeriodFinalWarning
    | ThreadCreated
    | ReplyMessage
    | ChatInputCommand
    | GuildInviteReminder
    | ContextMenuCommand
    | AutoModerationAction
    | RoleSubscriptionPurchase
    | InteractionPremiumUpsell
    | StageStart
    | StageEnd
    | StageSpeaker
    | StageTopic
    | GuildApplicationPremiumSubscription
    | GuildIncidentAlertModeEnabled
    | GuildIncidentAlertModeDisabled
    | GuildIncidentReportRaid
    | GuildIncidentReportFalseAlarm
    | PurchaseNotification
    | PollResult -> True
  }
}

pub fn message_reference_type_from_int(
  value: Int,
) -> Option(MessageReferenceType) {
  case value {
    0 -> Some(DefaultReference)
    1 -> Some(ForwardReference)
    _ -> None
  }
}

pub fn message_reference_type_to_int(value: MessageReferenceType) -> Int {
  case value {
    DefaultReference -> 0
    ForwardReference -> 1
  }
}

pub fn message_reference_type_decoder() -> Decoder(MessageReferenceType) {
  wire.strict(
    message_reference_type_from_int,
    DefaultReference,
    "MessageReferenceType",
  )
}

pub fn message_reference_type_to_json(value: MessageReferenceType) -> Json {
  json.int(message_reference_type_to_int(value))
}

pub fn sticker_format_from_int(value: Int) -> Option(StickerFormat) {
  case value {
    1 -> Some(PngSticker)
    2 -> Some(ApngSticker)
    3 -> Some(LottieSticker)
    4 -> Some(GifSticker)
    _ -> None
  }
}

pub fn sticker_format_to_int(value: StickerFormat) -> Int {
  case value {
    PngSticker -> 1
    ApngSticker -> 2
    LottieSticker -> 3
    GifSticker -> 4
  }
}

pub fn reaction_type_from_int(value: Int) -> Option(ReactionType) {
  case value {
    0 -> Some(NormalReaction)
    1 -> Some(BurstReaction)
    _ -> None
  }
}

pub fn reaction_type_to_int(value: ReactionType) -> Int {
  case value {
    NormalReaction -> 0
    BurstReaction -> 1
  }
}

pub fn reaction_type_decoder() -> Decoder(ReactionType) {
  wire.strict(reaction_type_from_int, NormalReaction, "ReactionType")
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
  use type_ <- wire.type_field(
    "type",
    message_type_from_int,
    DefaultMessage,
    "MessageType",
  )
  use application_id <- wire.opt_field("application_id", id.decoder())
  use flags <- wire.enum_field("flags", flags.from_int)
  use message_reference <- wire.opt_field(
    "message_reference",
    message_reference_decoder(),
  )
  use referenced_message <- wire.tri_field(
    "referenced_message",
    decode.recursive(decoder),
  )
  use thread <- wire.opt_field("thread", channel.decoder())
  use components <- wire.known_list_field("components", component.decoder())
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
    type_:,
    application_id:,
    flags:,
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
  use type_ <- wire.type_field(
    "type",
    channel.channel_type_from_int,
    channel.GuildText,
    "ChannelType",
  )
  use name <- wire.string_field("name", "")
  decode.success(ChannelMention(id:, guild_id:, type_:, name:))
}

pub fn sticker_item_decoder() -> Decoder(StickerItem) {
  use id <- decode.field("id", id.decoder())
  use name <- wire.string_field("name", "")
  use format_type <- wire.type_field(
    "format_type",
    sticker_format_from_int,
    PngSticker,
    "StickerFormat",
  )
  decode.success(StickerItem(id:, name:, format_type:))
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
  // Absent means DEFAULT.
  use type_ <- wire.type_or(
    "type",
    message_reference_type_from_int,
    DefaultReference,
    "MessageReferenceType",
  )
  use message_id <- wire.opt_field("message_id", id.decoder())
  use channel_id <- wire.opt_field("channel_id", id.decoder())
  use guild_id <- wire.opt_field("guild_id", id.decoder())
  decode.success(MessageReference(type_:, message_id:, channel_id:, guild_id:))
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

// -- Draft: the create body --------------------------------------------------

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
  message_reference_type_to_json(case value {
    Reply(..) -> DefaultReference
    Forward(..) -> ForwardReference
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
    flags: MessageFlags,
  )
}

/// Whether the create carries a nonce, and what Discord should do with it.
pub type NoncePolicy {
  NoNonce

  /// Max 25 characters. Always send a `StringNonce`. `enforce` makes the
  /// create idempotent for a few minutes: a second POST with the same nonce
  /// returns the first message instead of posting twice.
  UseNonce(value: Nonce, enforce: Bool)
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
  flags: no_flags,
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
/// URL, a draft's is bytes. The receive-only parts of an embed (type,
/// provider, video, proxy urls) come along and are dropped by `embed.to_json`.
pub fn redraft(message: Message) -> Draft {
  Draft(
    ..new(),
    content: case message.content {
      "" -> None
      content -> Some(content)
    },
    embeds: message.embeds,
    components: message.components,
    sticker_ids: list.map(message.sticker_items, fn(item) { item.id }),
    flags: settable_on_create(message.flags),
  )
}

// IS_VOICE_MESSAGE is settable too, but only with the audio file beside it,
// and files do not carry.
fn settable_on_create(received: MessageFlags) -> MessageFlags {
  [SuppressEmbeds, SuppressNotifications, IsComponentsV2]
  |> list.filter(fn(flag) { has_flag(received, flag) })
  |> message_flags
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
pub fn allowed_mentions(draft: Draft, policy: AllowedMentions) -> Draft {
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
  with(draft, SuppressEmbeds)
}

/// Delivered without a push or desktop notification, mentions included.
pub fn silent(draft: Draft) -> Draft {
  with(draft, SuppressNotifications)
}

fn with(draft: Draft, flag: MessageFlag) -> Draft {
  Draft(..draft, flags: with_flag(draft.flags, flag))
}

/// A nonce Discord echoes back on MESSAGE_CREATE, enforced, so a retried POST
/// returns the first message rather than posting twice. The safe one is the
/// short name on purpose: a retry is the reason to reach for a nonce at all.
pub fn with_nonce(draft: Draft, value: Nonce) -> Draft {
  Draft(..draft, nonce: UseNonce(value:, enforce: True))
}

/// A nonce only for correlating MESSAGE_CREATE back to the create. Discord
/// does not dedupe on it, so a retried POST posts a second message.
pub fn with_correlation_nonce(draft: Draft, value: Nonce) -> Draft {
  Draft(..draft, nonce: UseNonce(value:, enforce: False))
}

/// A ready-to-send body, files already paired to their `attachments` entries.
pub fn to_body(draft: Draft) -> Body {
  case draft.files {
    [] -> body.json(create_fields(draft))
    files ->
      body.Form(payload: create_fields(draft), files: attachment.parts(files))
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
      wire.put(wire.opt(draft.allowed_mentions), mentions.to_json),
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
    #("attachments", attachment.new_attachments_field(draft.files)),
    #("flags", flags_field(draft.flags)),
    #("enforce_nonce", enforcement(draft.nonce)),
  ])
}

// -- Edit: the patch body ----------------------------------------------------

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
    flags: Field(MessageFlags),
    /// Not optional. An edit that leaves it out re-parses the content with
    /// Discord's defaults, whatever the message was sent with.
    allowed_mentions: AllowedMentions,
    attachments: EditAttachments,
  )
}

/// The only `Edit` constructor: the mention policy is not optional.
pub fn new_edit(mentions: AllowedMentions) -> Edit {
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
    files ->
      body.Form(payload: edit_fields(edit), files: attachment.parts(files))
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
    #("allowed_mentions", mention_policy(edit)),
    #("components", wire.put_list(edit.components, component.to_json)),
    #("attachments", attachment.attachments_field(edit.attachments)),
  ]
}

/// The `allowed_mentions` entry for an edit, written only when the edit
/// touches `content` or `components`, which are what Discord re-parses
/// mentions from. Sending it otherwise breaks suppressing embeds on somebody
/// else's message, which Discord refuses it on.
fn mention_policy(edit: Edit) -> Field(Json) {
  case field.is_absent(edit.content) && field.is_absent(edit.components) {
    True -> Absent
    False -> Present(mentions.to_json(edit.allowed_mentions))
  }
}

/// The files the multipart body has to carry, in `files[n]` order.
pub fn edit_files(edit: Edit) -> List(File) {
  attachment.added_files(edit.attachments)
}

/// `POST /channels/{c}/messages/bulk-delete`. Two to 100 ids, none older than
/// 14 days, or Discord rejects the whole batch.
pub fn bulk_delete_body(messages: List(id.MessageId)) -> Body {
  body.json([#("messages", json.array(messages, id.to_json))])
}

/// No flags set is an absence, not a zero. Public because a create and an
/// interaction callback both write the key this way.
pub fn flags_field(value: MessageFlags) -> Field(Json) {
  case flags.to_int(value) {
    0 -> Absent
    _ -> Present(flags.to_json(value))
  }
}

fn nonce(policy: NoncePolicy) -> Field(Json) {
  case policy {
    NoNonce -> Absent
    UseNonce(value:, ..) -> Present(nonce_to_json(value))
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

// -- Endpoints ---------------------------------------------------------------

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

/// `GET /channels/{channel.id}/messages`, as Get Channel Messages. `None` is
/// no cursor, which Discord reads as the newest messages. Discord caps `limit`
/// at 100 and defaults it to 50.
pub fn list(
  api: api.Api,
  channel: id.ChannelId,
  cursor cursor: Option(MessageCursor),
  limit limit: Option(Int),
) -> Result(List(Message), api.CallFailure) {
  api.execute(api, list_call(channel, cursor:, limit:))
}

/// The `Call` for [list], for building the request without sending it.
pub fn list_call(
  channel: id.ChannelId,
  cursor cursor: Option(MessageCursor),
  limit limit: Option(Int),
) -> Call(List(Message)) {
  rest.get(messages_at(channel), rest.Decoded(decode.list(decoder())))
  |> rest.query(
    list.flatten([cursor_param(cursor), query.opt("limit", limit, query.number)]),
  )
}

fn cursor_param(cursor: Option(MessageCursor)) -> List(query.Param) {
  case cursor {
    None -> []
    Some(Around(message)) -> query.one("around", message, query.snowflake)
    Some(Before(message)) -> query.one("before", message, query.snowflake)
    Some(After(message)) -> query.one("after", message, query.snowflake)
  }
}

/// `GET /channels/{channel.id}/messages/{message.id}`, as Get Channel Message.
pub fn get(
  api: api.Api,
  channel: id.ChannelId,
  message: id.MessageId,
) -> Result(Message, api.CallFailure) {
  api.execute(api, get_call(channel, message))
}

/// The `Call` for [get], for building the request without sending it.
pub fn get_call(channel: id.ChannelId, message: id.MessageId) -> Call(Message) {
  rest.get(message_at(channel, message), rest.Decoded(decoder()))
}

/// `POST /channels/{channel.id}/messages`, as Create Message.
pub fn send(
  api: api.Api,
  channel: id.ChannelId,
  draft: Draft,
) -> Result(Message, api.CallFailure) {
  api.execute(api, send_call(channel, draft))
}

/// The bare `Call`, for driving `glyde/rest` yourself.
pub fn send_call(channel: id.ChannelId, draft: Draft) -> Call(Message) {
  rest.post(messages_at(channel), to_body(draft), rest.Decoded(decoder()))
}

/// `send(api, to.channel_id, draft |> reply_to(to.id))`, so Discord shows it
/// attached to the message rather than as a bare post.
pub fn reply(
  api: api.Api,
  to: Message,
  draft: Draft,
) -> Result(Message, api.CallFailure) {
  api.execute(api, reply_call(to, draft))
}

/// The `Call` for `reply`, for building the request without sending it.
pub fn reply_call(to: Message, draft: Draft) -> Call(Message) {
  send_call(to.channel_id, reply_to(draft, to.id))
}

/// `PATCH /channels/{channel.id}/messages/{message.id}`, as Edit Message.
pub fn edit(
  api: api.Api,
  msg: Message,
  edit: Edit,
) -> Result(Message, api.CallFailure) {
  api.execute(api, edit_call(msg, edit))
}

/// The `Call` for `edit`, for building the request without sending it.
pub fn edit_call(msg: Message, edit: Edit) -> Call(Message) {
  edit_id_call(msg.channel_id, msg.id, edit)
}

/// `edit` for a caller who only has the ids.
pub fn edit_id(
  api: api.Api,
  channel: id.ChannelId,
  message: id.MessageId,
  edit: Edit,
) -> Result(Message, api.CallFailure) {
  api.execute(api, edit_id_call(channel, message, edit))
}

/// The bare `Call`, for driving `glyde/rest` yourself.
pub fn edit_id_call(
  channel: id.ChannelId,
  message: id.MessageId,
  edit: Edit,
) -> Call(Message) {
  rest.patch(
    message_at(channel, message),
    edit_body(edit),
    rest.Decoded(decoder()),
  )
}

/// `DELETE /channels/{channel.id}/messages/{message.id}`, as Delete Message.
pub fn delete(api: api.Api, msg: Message) -> Result(Nil, api.CallFailure) {
  api.execute(api, delete_call(msg))
}

/// The `Call` for [delete], for building the request without sending it.
pub fn delete_call(msg: Message) -> Call(Nil) {
  delete_id_call(msg.channel_id, msg.id)
}

/// `delete` for a caller who only has the ids. Discord splits this route into
/// three buckets by the target's age and reports none of it in the headers
/// (discord-api-docs#1092, #1295), so `route.Aged` carries the age.
pub fn delete_id(
  api: api.Api,
  channel: id.ChannelId,
  message: id.MessageId,
) -> Result(Nil, api.CallFailure) {
  api.execute(api, delete_id_call(channel, message))
}

/// The `Call` for [delete_id], for building the request without sending it.
pub fn delete_id_call(
  channel: id.ChannelId,
  message: id.MessageId,
) -> Call(Nil) {
  rest.delete(message_at(channel, message), rest.NoContent(Nil))
  // `id.from_string` does not validate, so the id may not be a snowflake.
  // Discord's epoch is the safe answer: slowest bucket, and outside the
  // bulk-delete window.
  |> rest.age_bucket(id.created_at_ms_or(message, default: id.discord_epoch_ms))
}

/// `POST /channels/{channel.id}/messages/bulk-delete`, as Bulk Delete
/// Messages. Discord takes 2 to 100 ids and rejects the whole request if any
/// message is over two weeks old.
pub fn bulk_delete(
  api: api.Api,
  channel: id.ChannelId,
  messages: List(id.MessageId),
) -> Result(Nil, api.CallFailure) {
  api.execute(api, bulk_delete_call(channel, messages))
}

/// The `Call` for [bulk_delete], for building the request without sending it.
pub fn bulk_delete_call(
  channel: id.ChannelId,
  messages: List(id.MessageId),
) -> Call(Nil) {
  rest.post(
    list.append(messages_at(channel), [seg.lit("bulk-delete")]),
    bulk_delete_body(messages),
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
  case emoji {
    Unicode(name:) -> unicode_emoji(name)
    Custom(id: emoji_id, name: Some(name), ..) -> custom_emoji(emoji_id, name)
    Custom(id: emoji_id, name: None, ..) -> custom_emoji_by_id(emoji_id)
  }
}

/// Through this module's own table, so the two numbers are written once.
fn reaction_type(kind: ReactionType) -> String {
  int.to_string(reaction_type_to_int(kind))
}

/// `PUT .../reactions/{emoji}/@me`, as Create Reaction.
pub fn react(
  api: api.Api,
  msg: Message,
  emoji: ReactionEmoji,
) -> Result(Nil, api.CallFailure) {
  api.execute(api, react_call(msg, emoji))
}

/// The `Call` for [react], for building the request without sending it.
pub fn react_call(msg: Message, emoji: ReactionEmoji) -> Call(Nil) {
  react_id_call(msg.channel_id, msg.id, emoji)
}

/// `react` for a caller who only has the ids.
pub fn react_id(
  api: api.Api,
  channel: id.ChannelId,
  message: id.MessageId,
  emoji: ReactionEmoji,
) -> Result(Nil, api.CallFailure) {
  api.execute(api, react_id_call(channel, message, emoji))
}

/// The `Call` for [react_id], for building the request without sending it.
pub fn react_id_call(
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

/// `DELETE .../reactions/{emoji}/@me`, as Delete Own Reaction.
pub fn unreact(
  api: api.Api,
  msg: Message,
  emoji: ReactionEmoji,
) -> Result(Nil, api.CallFailure) {
  api.execute(api, unreact_call(msg, emoji))
}

/// The `Call` for [unreact], for building the request without sending it.
pub fn unreact_call(msg: Message, emoji: ReactionEmoji) -> Call(Nil) {
  unreact_id_call(msg.channel_id, msg.id, emoji)
}

/// `unreact` for a caller who only has the ids.
pub fn unreact_id(
  api: api.Api,
  channel: id.ChannelId,
  message: id.MessageId,
  emoji: ReactionEmoji,
) -> Result(Nil, api.CallFailure) {
  api.execute(api, unreact_id_call(channel, message, emoji))
}

/// The `Call` for [unreact_id], for building the request without sending it.
pub fn unreact_id_call(
  channel: id.ChannelId,
  message: id.MessageId,
  emoji: ReactionEmoji,
) -> Call(Nil) {
  rest.delete(
    list.append(reactions_at(channel, message, emoji), [seg.lit("@me")]),
    rest.NoContent(Nil),
  )
}

/// `DELETE .../reactions/{emoji}/{user.id}`, as Delete User Reaction.
pub fn remove_reaction(
  api: api.Api,
  msg: Message,
  emoji: ReactionEmoji,
  user: id.UserId,
) -> Result(Nil, api.CallFailure) {
  api.execute(api, remove_reaction_call(msg, emoji, user))
}

/// The `Call` for [remove_reaction], for building the request without sending
/// it.
pub fn remove_reaction_call(
  msg: Message,
  emoji: ReactionEmoji,
  user: id.UserId,
) -> Call(Nil) {
  remove_reaction_id_call(msg.channel_id, msg.id, emoji, user)
}

/// `remove_reaction` for a caller who only has the ids.
pub fn remove_reaction_id(
  api: api.Api,
  channel: id.ChannelId,
  message: id.MessageId,
  emoji: ReactionEmoji,
  user: id.UserId,
) -> Result(Nil, api.CallFailure) {
  api.execute(api, remove_reaction_id_call(channel, message, emoji, user))
}

/// The `Call` for [remove_reaction_id], for building the request without
/// sending it.
pub fn remove_reaction_id_call(
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

/// `GET .../reactions/{emoji}`, as Get Reactions: the users who reacted.
pub fn reactions(
  api: api.Api,
  msg: Message,
  emoji: ReactionEmoji,
  type_ type_: Option(ReactionType),
  after after: Option(id.UserId),
  limit limit: Option(Int),
) -> Result(List(user.User), api.CallFailure) {
  api.execute(api, reactions_call(msg, emoji, type_:, after:, limit:))
}

/// The `Call` for [reactions], for building the request without sending it.
pub fn reactions_call(
  msg: Message,
  emoji: ReactionEmoji,
  type_ type_: Option(ReactionType),
  after after: Option(id.UserId),
  limit limit: Option(Int),
) -> Call(List(user.User)) {
  reactions_id_call(msg.channel_id, msg.id, emoji, type_:, after:, limit:)
}

/// `reactions` for a caller who only has the ids.
pub fn reactions_id(
  api: api.Api,
  channel: id.ChannelId,
  message: id.MessageId,
  emoji: ReactionEmoji,
  type_ type_: Option(ReactionType),
  after after: Option(id.UserId),
  limit limit: Option(Int),
) -> Result(List(user.User), api.CallFailure) {
  api.execute(
    api,
    reactions_id_call(channel, message, emoji, type_:, after:, limit:),
  )
}

/// The `Call` for [reactions_id], for building the request without sending it.
pub fn reactions_id_call(
  channel: id.ChannelId,
  message: id.MessageId,
  emoji: ReactionEmoji,
  type_ type_: Option(ReactionType),
  after after: Option(id.UserId),
  limit limit: Option(Int),
) -> Call(List(user.User)) {
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

/// `DELETE .../reactions/{emoji}`, as Delete All Reactions For Emoji.
pub fn clear_emoji_reactions(
  api: api.Api,
  msg: Message,
  emoji: ReactionEmoji,
) -> Result(Nil, api.CallFailure) {
  api.execute(api, clear_emoji_reactions_call(msg, emoji))
}

/// The `Call` for [clear_emoji_reactions], for building the request without
/// sending it.
pub fn clear_emoji_reactions_call(
  msg: Message,
  emoji: ReactionEmoji,
) -> Call(Nil) {
  clear_emoji_reactions_id_call(msg.channel_id, msg.id, emoji)
}

/// `clear_emoji_reactions` for a caller who only has the ids.
pub fn clear_emoji_reactions_id(
  api: api.Api,
  channel: id.ChannelId,
  message: id.MessageId,
  emoji: ReactionEmoji,
) -> Result(Nil, api.CallFailure) {
  api.execute(api, clear_emoji_reactions_id_call(channel, message, emoji))
}

/// The `Call` for [clear_emoji_reactions_id], for building the request
/// without sending it.
pub fn clear_emoji_reactions_id_call(
  channel: id.ChannelId,
  message: id.MessageId,
  emoji: ReactionEmoji,
) -> Call(Nil) {
  rest.delete(reactions_at(channel, message, emoji), rest.NoContent(Nil))
}

/// `DELETE .../reactions`, as Delete All Reactions.
pub fn clear_reactions(
  api: api.Api,
  msg: Message,
) -> Result(Nil, api.CallFailure) {
  api.execute(api, clear_reactions_call(msg))
}

/// The `Call` for [clear_reactions], for building the request without sending
/// it.
pub fn clear_reactions_call(msg: Message) -> Call(Nil) {
  clear_reactions_id_call(msg.channel_id, msg.id)
}

/// `clear_reactions` for a caller who only has the ids. Its own bucket, having
/// no emoji to collapse at.
pub fn clear_reactions_id(
  api: api.Api,
  channel: id.ChannelId,
  message: id.MessageId,
) -> Result(Nil, api.CallFailure) {
  api.execute(api, clear_reactions_id_call(channel, message))
}

/// The `Call` for [clear_reactions_id], for building the request without
/// sending it.
pub fn clear_reactions_id_call(
  channel: id.ChannelId,
  message: id.MessageId,
) -> Call(Nil) {
  rest.delete(
    list.append(message_at(channel, message), [seg.lit("reactions")]),
    rest.NoContent(Nil),
  )
}

/// When a message was pinned. Page on with the oldest entry you just read.
pub fn pinned_at(pin: PinnedMessage) -> channel.TimeCursor {
  channel.at_time(pin.pinned_at)
}

/// `GET /channels/{channel.id}/messages/pins`, as Get Channel Pins. Each
/// message wrapped in its pin time; pages backwards through the order they
/// were pinned in.
pub fn pins(
  api: api.Api,
  channel: id.ChannelId,
  before before: Option(channel.TimeCursor),
  limit limit: Option(Int),
) -> Result(PinList, api.CallFailure) {
  api.execute(api, pins_call(channel, before:, limit:))
}

/// The `Call` for [pins], for building the request without sending it.
pub fn pins_call(
  channel: id.ChannelId,
  before before: Option(channel.TimeCursor),
  limit limit: Option(Int),
) -> Call(PinList) {
  rest.get(pins_at(channel), rest.Decoded(pin_list_decoder()))
  |> rest.query(
    list.flatten([
      query.opt("before", before, channel.time_cursor_value),
      query.opt("limit", limit, query.number),
    ]),
  )
}

/// `PUT /channels/{channel.id}/messages/pins/{message.id}`, as Pin Message.
pub fn pin(api: api.Api, msg: Message) -> Result(Nil, api.CallFailure) {
  api.execute(api, pin_call(msg))
}

/// The `Call` for [pin], for building the request without sending it.
pub fn pin_call(msg: Message) -> Call(Nil) {
  pin_id_call(msg.channel_id, msg.id)
}

/// `pin` for a caller who only has the ids.
pub fn pin_id(
  api: api.Api,
  channel: id.ChannelId,
  message: id.MessageId,
) -> Result(Nil, api.CallFailure) {
  api.execute(api, pin_id_call(channel, message))
}

/// The `Call` for [pin_id], for building the request without sending it.
pub fn pin_id_call(channel: id.ChannelId, message: id.MessageId) -> Call(Nil) {
  rest.put(pin_at(channel, message), body.NoBody, rest.NoContent(Nil))
}

/// `DELETE /channels/{channel.id}/messages/pins/{message.id}`, as Unpin
/// Message.
pub fn unpin(api: api.Api, msg: Message) -> Result(Nil, api.CallFailure) {
  api.execute(api, unpin_call(msg))
}

/// The `Call` for [unpin], for building the request without sending it.
pub fn unpin_call(msg: Message) -> Call(Nil) {
  unpin_id_call(msg.channel_id, msg.id)
}

/// `unpin` for a caller who only has the ids.
pub fn unpin_id(
  api: api.Api,
  channel: id.ChannelId,
  message: id.MessageId,
) -> Result(Nil, api.CallFailure) {
  api.execute(api, unpin_id_call(channel, message))
}

/// The `Call` for [unpin_id], for building the request without sending it.
pub fn unpin_id_call(
  channel: id.ChannelId,
  message: id.MessageId,
) -> Call(Nil) {
  rest.delete(pin_at(channel, message), rest.NoContent(Nil))
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
