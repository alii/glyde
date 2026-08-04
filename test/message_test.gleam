import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set
import gleam/string
import glyde/attachment
import glyde/channel
import glyde/component
import glyde/embed
import glyde/emoji
import glyde/field.{Absent, Null, Present}
import glyde/flags
import glyde/id
import glyde/mentions
import glyde/message.{
  type Message, IntNonce, StringNonce, UnknownMessageType, UnknownReference,
}
import glyde/rest/body

/// The smallest payload Discord actually sends for a message.
fn defaults() -> List(#(String, String)) {
  [
    #("id", "\"1000\""),
    #("channel_id", "\"2000\""),
    #(
      "author",
      "{\"id\":\"3000\",\"username\":\"bob\",\"discriminator\":\"0\"}",
    ),
    #("content", "\"hi\""),
    #("timestamp", "\"2024-01-01T00:00:00.000000+00:00\""),
    #("edited_timestamp", "null"),
    #("tts", "false"),
    #("mention_everyone", "false"),
    #("mentions", "[]"),
    #("mention_roles", "[]"),
    #("attachments", "[]"),
    #("embeds", "[]"),
    #("pinned", "false"),
    #("type", "0"),
  ]
}

/// `overrides` applied by key, so a key appears exactly once. Splicing them
/// onto the end would emit the key twice and let the reader pick.
fn msg(overrides: List(#(String, String))) -> String {
  let overridden = list.map(overrides, fn(pair) { pair.0 })
  let kept =
    list.filter(defaults(), fn(pair) { !list.contains(overridden, pair.0) })
  let rendered =
    list.map(list.append(kept, overrides), fn(pair) {
      "\"" <> pair.0 <> "\":" <> pair.1
    })
  "{" <> string.join(rendered, ",") <> "}"
}

fn parse(text: String) -> Result(Message, json.DecodeError) {
  json.parse(text, message.decoder())
}

fn decode_msg(overrides: List(#(String, String))) -> Message {
  let assert Ok(value) = parse(msg(overrides))
  value
}

/// Absent means Discord never fetched the replied-to message; null means it
/// was deleted.
pub fn referenced_message_keeps_absent_and_null_apart_test() {
  assert decode_msg([]).referenced_message == Absent
  assert decode_msg([#("referenced_message", "null")]).referenced_message
    == Null

  let nested = decode_msg([#("referenced_message", msg([]))])
  let assert Present(inner) = nested.referenced_message
  assert inner.id == id.from_string("1000")
  assert inner.content == "hi"
}

/// The exact shape Discord sends after the replied-to message is deleted.
pub fn deleted_reply_target_decodes_rather_than_failing_test() {
  let assert Ok(value) =
    parse(
      msg([
        #("type", "19"),
        #("referenced_message", "null"),
        #("message_reference", "{\"message_id\":\"9\",\"channel_id\":\"2000\"}"),
      ]),
    )
  assert value.referenced_message == Null
  assert message.referenced(value) == None
  assert value.type_ == message.ReplyMessage
}

/// For callers who do not care why it is missing.
pub fn referenced_collapses_all_three_states_test() {
  assert message.referenced(decode_msg([])) == None
  assert message.referenced(decode_msg([#("referenced_message", "null")]))
    == None

  let nested = decode_msg([#("referenced_message", msg([]))])
  let assert Some(inner) = message.referenced(nested)
  assert inner.id == id.from_string("1000")
}

/// The recursion is real: a reply to a reply nests.
pub fn referenced_message_nests_test() {
  let inner = msg([#("id", "\"7\"")])
  let middle = msg([#("id", "\"8\""), #("referenced_message", inner)])
  let assert Ok(outer) =
    parse(msg([#("id", "\"9\""), #("referenced_message", middle)]))
  let assert Present(second) = outer.referenced_message
  let assert Present(third) = second.referenced_message
  assert outer.id == id.from_string("9")
  assert second.id == id.from_string("8")
  assert third.id == id.from_string("7")
  assert third.referenced_message == Absent
}

pub fn minimal_message_decodes_test() {
  let value = decode_msg([])
  assert value.id == id.from_string("1000")
  assert value.channel_id == id.from_string("2000")
  assert value.guild_id == None
  assert value.author.username == "bob"
  assert value.member == None
  assert value.content == "hi"
  assert value.edited_timestamp == None
  assert value.tts == False
  assert value.mentions == []
  assert value.reactions == []
  assert value.nonce == None
  assert value.webhook_id == None
  assert value.type_ == message.DefaultMessage
  assert value.flags == message.no_flags
  assert value.message_reference == None
  assert value.thread == None
  assert value.components == []
  assert value.sticker_items == []
  assert value.position == None
}

/// Without the MESSAGE_CONTENT intent these arrive empty, not absent.
pub fn missing_message_content_intent_yields_empty_not_an_error_test() {
  let assert Ok(value) =
    parse(
      "{\"id\":\"1\",\"channel_id\":\"2\",\"author\":{\"id\":\"3\"},"
      <> "\"content\":\"\",\"timestamp\":\"t\",\"edited_timestamp\":null,"
      <> "\"attachments\":[],\"embeds\":[],\"components\":[],\"type\":0}",
    )
  assert value.content == ""
  assert value.embeds == []
  assert value.attachments == []
  assert value.components == []
}

/// Discord sends an explicit null for these on partial and cached payloads.
pub fn explicit_nulls_do_not_fail_the_message_test() {
  let nullable = [
    "embeds", "attachments", "components", "mentions", "mention_roles",
    "reactions", "sticker_items", "mention_channels", "guild_id", "member",
    "webhook_id", "application_id", "flags", "nonce", "position", "thread",
    "message_reference", "content", "pinned", "tts", "mention_everyone",
    "timestamp", "type",
  ]
  let nulls = list.map(nullable, fn(key) { #(key, "null") })
  list.each(nulls, fn(override) {
    let assert Ok(_) = parse(msg([override]))
    Nil
  })
}

pub fn null_arrays_become_empty_test() {
  let value =
    decode_msg([
      #("embeds", "null"),
      #("reactions", "null"),
      #("components", "null"),
    ])
  assert value.embeds == []
  assert value.reactions == []
  assert value.components == []
}

/// `author.bot` is true for every bot, so `webhook_id` is the documented test.
pub fn webhook_author_decodes_and_is_detected_test() {
  let assert Ok(value) =
    parse(
      "{\"id\":\"1\",\"channel_id\":\"2\",\"webhook_id\":\"55\","
      <> "\"author\":{\"id\":\"55\",\"username\":\"Hook\",\"avatar\":null},"
      <> "\"content\":\"x\",\"timestamp\":\"t\",\"edited_timestamp\":null,"
      <> "\"attachments\":[],\"embeds\":[],\"type\":0}",
    )
  assert value.webhook_id == Some(id.from_string("55"))
  assert message.is_from_webhook(value)
  assert value.author.username == "Hook"
  assert value.author.discriminator == "0"
  assert value.author.bot == False
}

pub fn an_ordinary_bot_is_not_a_webhook_test() {
  let value =
    decode_msg([#("author", "{\"id\":\"3\",\"username\":\"b\",\"bot\":true}")])
  assert value.author.bot
  assert !message.is_from_webhook(value)
}

pub fn gateway_extras_decode_test() {
  let value =
    decode_msg([
      #("guild_id", "\"4000\""),
      #("member", "{\"nick\":\"Bobby\",\"roles\":[\"5\"]}"),
    ])
  assert value.guild_id == Some(id.from_string("4000"))
  let assert Some(member) = value.member
  assert member.nick == Some("Bobby")
  // The gateway member has no `user` key: the author is the sibling field.
  assert member.user == None
}

/// A number past 2^53-1 cannot be held exactly, `wire.integer` refuses it,
/// and `decode.optional_field` passes that failure up: without a total nonce
/// decoder one oversized nonce takes the whole message down.
pub fn an_oversized_nonce_costs_the_nonce_and_not_the_message_test() {
  let value = decode_msg([#("nonce", "12345678901234567890")])
  // `None`, not a variant of its own: `Nonce` is also what a create sends.
  assert value.nonce == None
  assert value.content == "hi"
}

/// Discord echoes back whatever was sent, so both spellings arrive.
pub fn nonce_accepts_a_string_or_an_integer_test() {
  assert decode_msg([#("nonce", "\"abc\"")]).nonce == Some(StringNonce("abc"))
  assert decode_msg([#("nonce", "42")]).nonce == Some(IntNonce(42))
  assert decode_msg([]).nonce == None
}

pub fn nonce_encodes_back_to_what_it_was_test() {
  assert json.to_string(message.nonce_to_json(StringNonce("abc"))) == "\"abc\""
  assert json.to_string(message.nonce_to_json(IntNonce(42))) == "42"
}

/// The live range is 0 to 46 with holes at 13, 30, 33 to 35, 40 to 43 and 45.
/// Indexing this enum by position maps a third of it to the wrong value.
fn message_type_holes() -> set.Set(Int) {
  set.from_list([13, 30, 33, 34, 35, 40, 41, 42, 43, 45])
}

pub fn message_type_round_trips_across_the_whole_range_test() {
  let holes = message_type_holes()
  int.range(from: 0, to: 47, with: Nil, run: fn(_, wire) {
    let decoded = message.message_type_from_int(wire)
    case set.contains(holes, wire) {
      True -> {
        assert decoded == UnknownMessageType(wire)
      }
      False -> {
        assert decoded != UnknownMessageType(wire)
      }
    }
    assert message.message_type_to_int(decoded) == wire
  })
}

pub fn unknown_message_type_survives_test() {
  assert message.message_type_from_int(9999) == UnknownMessageType(9999)
  assert message.message_type_to_int(UnknownMessageType(9999)) == 9999
  assert decode_msg([#("type", "9999")]).type_ == UnknownMessageType(9999)
}

pub fn named_message_types_match_the_wire_test() {
  let rows = [
    #(0, message.DefaultMessage),
    #(6, message.ChannelPinnedMessage),
    #(7, message.UserJoin),
    #(12, message.ChannelFollowAdd),
    #(18, message.ThreadCreated),
    #(19, message.ReplyMessage),
    #(20, message.ChatInputCommand),
    #(21, message.ThreadStarterMessage),
    #(23, message.ContextMenuCommand),
    #(31, message.StageTopic),
    #(32, message.GuildApplicationPremiumSubscription),
    #(44, message.PurchaseNotification),
    #(46, message.PollResult),
  ]
  list.each(rows, fn(row) {
    let #(wire, expected) = row
    assert message.message_type_from_int(wire) == expected
    assert message.message_type_to_int(expected) == wire
  })
}

/// A wrong guess costs a 400 that reads like a permissions bug.
pub fn is_deletable_table_test() {
  let undeletable = [
    message.RecipientAdd,
    message.RecipientRemove,
    message.Call,
    message.ChannelNameChange,
    message.ChannelIconChange,
    message.ThreadStarterMessage,
    UnknownMessageType(9999),
  ]
  let deletable = [
    message.DefaultMessage, message.ReplyMessage, message.ChatInputCommand,
    message.ChannelPinnedMessage, message.UserJoin, message.PollResult,
  ]
  list.each(undeletable, fn(value) {
    assert !message.is_deletable(value)
  })
  list.each(deletable, fn(value) {
    assert message.is_deletable(value)
  })
}

pub fn message_flags_decode_and_report_test() {
  let value = decode_msg([#("flags", "68")])
  assert message.has_flag(value.flags, message.Ephemeral)
  assert message.has_flag(value.flags, message.SuppressEmbeds)
  assert !message.has_flag(value.flags, message.Crossposted)
  assert flags.to_int(value.flags) == 68
}

pub fn absent_flags_are_no_flags_test() {
  assert decode_msg([]).flags == message.no_flags
  assert flags.to_int(message.no_flags) == 0
}

pub fn message_flags_builds_from_a_list_test() {
  let flags = message.message_flags([message.Ephemeral, message.SuppressEmbeds])
  assert flags.to_int(flags) == 68
}

/// Edit Message says to include every bit already set, including the ones this
/// build cannot name.
pub fn editing_flags_preserves_bits_this_build_cannot_name_test() {
  let future_bit = 1_048_576
  let flags = flags.from_int(future_bit + 64)
  assert message.has_flag(flags, message.Ephemeral)

  let added = message.with_flag(flags, message.SuppressEmbeds)
  assert flags.to_int(added) == future_bit + 68

  let removed = message.without_flag(added, message.Ephemeral)
  assert flags.to_int(removed) == future_bit + 4
  assert !message.has_flag(removed, message.Ephemeral)
}

/// Clearing an unset flag never produces a negative intermediate.
pub fn without_flag_is_a_no_op_when_the_flag_is_unset_test() {
  let flags = flags.from_int(64)
  assert message.without_flag(flags, message.Crossposted) == flags
  assert flags.to_int(message.without_flag(message.no_flags, message.Loading))
    == 0
}

pub fn every_flag_bit_round_trips_test() {
  let flags = [
    #(message.Crossposted, 1),
    #(message.IsCrosspost, 2),
    #(message.SuppressEmbeds, 4),
    #(message.SourceMessageDeleted, 8),
    #(message.Urgent, 16),
    #(message.HasThread, 32),
    #(message.Ephemeral, 64),
    #(message.Loading, 128),
    #(message.FailedToMentionSomeRolesInThread, 256),
    #(message.SuppressNotifications, 4096),
    #(message.IsVoiceMessage, 8192),
    #(message.HasSnapshot, 16_384),
    #(message.IsComponentsV2, 32_768),
  ]
  list.each(flags, fn(row) {
    let #(flag, bit) = row
    let built = message.with_flag(message.no_flags, flag)
    assert flags.to_int(built) == bit
    assert message.has_flag(built, flag)
    assert message.has_flag(flags.from_int(bit), flag)
  })
}

pub fn message_flags_encode_as_an_integer_test() {
  assert json.to_string(flags.to_json(flags.from_int(68))) == "68"
}

/// Absent means DEFAULT, not unknown.
pub fn absent_message_reference_type_means_default_test() {
  let value =
    decode_msg([
      #("message_reference", "{\"message_id\":\"9\",\"channel_id\":\"2\"}"),
    ])
  assert value.message_reference
    == Some(message.MessageReference(
      type_: message.DefaultReference,
      message_id: Some(id.from_string("9")),
      channel_id: Some(id.from_string("2")),
      guild_id: None,
    ))
}

pub fn forward_reference_decodes_test() {
  let value =
    decode_msg([#("message_reference", "{\"type\":1,\"message_id\":\"9\"}")])
  let assert Some(reference) = value.message_reference
  assert reference.type_ == message.ForwardReference
}

/// CHANNEL_FOLLOW_ADD and THREAD_CREATED reference a channel and carry no
/// message id, so requiring one is wrong.
pub fn message_reference_without_a_message_id_decodes_test() {
  let value =
    decode_msg([
      #("type", "12"),
      #("message_reference", "{\"channel_id\":\"2\",\"guild_id\":\"4\"}"),
    ])
  let assert Some(reference) = value.message_reference
  assert reference.message_id == None
  assert reference.channel_id == Some(id.from_string("2"))
  assert reference.guild_id == Some(id.from_string("4"))
}

pub fn message_reference_type_round_trips_test() {
  let rows = [
    #(0, message.DefaultReference),
    #(1, message.ForwardReference),
    #(99, UnknownReference(99)),
  ]
  list.each(rows, fn(row) {
    let #(wire, expected) = row
    assert message.message_reference_type_from_int(wire) == expected
    assert message.message_reference_type_to_int(expected) == wire
  })
}

pub fn reaction_decodes_test() {
  let value =
    decode_msg([
      #(
        "reactions",
        "[{\"count\":3,\"count_details\":{\"burst\":1,\"normal\":2},"
          <> "\"me\":true,\"me_burst\":false,\"emoji\":{\"id\":null,\"name\":\"🔥\"},"
          <> "\"burst_colors\":[\"ff0000\"]}]",
      ),
    ])
  let assert [reaction] = value.reactions
  assert reaction.count == 3
  assert reaction.count_details
    == message.ReactionCountDetails(burst: 1, normal: 2)
  assert reaction.me
  assert !reaction.me_burst
  assert reaction.emoji.kind == emoji.Unicode("🔥")
  assert reaction.burst_colors == ["ff0000"]
}

/// A cached or replayed payload lacks the super-reaction fields.
pub fn reaction_without_the_super_reaction_fields_decodes_test() {
  let value =
    decode_msg([
      #(
        "reactions",
        "[{\"count\":1,\"me\":false,\"emoji\":{\"id\":null,\"name\":\"👍\"}}]",
      ),
    ])
  let assert [reaction] = value.reactions
  assert reaction.count_details
    == message.ReactionCountDetails(burst: 0, normal: 0)
  assert reaction.me_burst == False
  assert reaction.burst_colors == []
}

/// A null `count_details` is the same nothing as an absent one. It used to
/// sink the whole message, because only absence was defaulted.
pub fn reaction_with_a_null_count_details_decodes_test() {
  let value =
    decode_msg([
      #(
        "reactions",
        "[{\"count\":1,\"count_details\":null,\"me\":false,"
          <> "\"emoji\":{\"id\":null,\"name\":\"👍\"}}]",
      ),
    ])
  let assert [reaction] = value.reactions
  assert reaction.count_details
    == message.ReactionCountDetails(burst: 0, normal: 0)
}

/// A custom emoji deleted since the reaction was added arrives with a null
/// name.
pub fn reaction_on_a_deleted_custom_emoji_decodes_test() {
  let value =
    decode_msg([
      #("reactions", "[{\"count\":1,\"emoji\":{\"id\":\"77\",\"name\":null}}]"),
    ])
  let assert [reaction] = value.reactions
  assert reaction.emoji.kind
    == emoji.Custom(id: id.from_string("77"), name: None)
}

/// Discord splices `member` into each element of `mentions` rather than
/// sending a parallel array.
pub fn mentions_carry_their_spliced_member_test() {
  let value =
    decode_msg([
      #(
        "mentions",
        "[{\"id\":\"9\",\"username\":\"amy\","
          <> "\"member\":{\"nick\":\"Ames\",\"roles\":[\"5\"]}},"
          <> "{\"id\":\"10\",\"username\":\"zed\"}]",
      ),
    ])
  let assert [first, second] = value.mentions
  assert first.user.username == "amy"
  let assert Some(member) = first.member
  assert member.nick == Some("Ames")
  assert second.user.username == "zed"
  assert second.member == None
  assert message.mentioned_users(value) == [first.user, second.user]
}

pub fn mention_roles_and_everyone_decode_test() {
  let value =
    decode_msg([
      #("mention_everyone", "true"),
      #("mention_roles", "[\"7\",\"8\"]"),
    ])
  assert value.mention_everyone
  assert value.mention_roles == [id.from_string("7"), id.from_string("8")]
}

/// Crossposted messages only, and only from public text channels.
pub fn mention_channels_decode_test() {
  let value =
    decode_msg([
      #(
        "mention_channels",
        "[{\"id\":\"5\",\"guild_id\":\"6\",\"type\":0,\"name\":\"general\"}]",
      ),
    ])
  assert value.mention_channels
    == [
      message.ChannelMention(
        id: id.from_string("5"),
        guild_id: id.from_string("6"),
        type_: channel.GuildText,
        name: "general",
      ),
    ]
}

pub fn sticker_items_decode_test() {
  let value =
    decode_msg([
      #(
        "sticker_items",
        "[{\"id\":\"11\",\"name\":\"wave\",\"format_type\":1}]",
      ),
    ])
  assert value.sticker_items
    == [
      message.StickerItem(
        id: id.from_string("11"),
        name: "wave",
        format_type: message.PngSticker,
      ),
    ]
}

pub fn thread_and_position_decode_test() {
  let value =
    decode_msg([
      #("position", "4"),
      #("thread", "{\"id\":\"12\",\"type\":11,\"name\":\"chat\"}"),
    ])
  assert value.position == Some(4)
  assert value.thread != None
}

pub fn attachments_and_embeds_decode_test() {
  let value =
    decode_msg([
      #(
        "attachments",
        "[{\"id\":\"13\",\"filename\":\"a.png\",\"size\":10,"
          <> "\"url\":\"u\",\"proxy_url\":\"p\"}]",
      ),
      #("embeds", "[{\"title\":\"t\"},{\"type\":\"link\"}]"),
    ])
  assert list.length(value.attachments) == 1
  assert list.length(value.embeds) == 2
}

pub fn components_decode_test() {
  let value =
    decode_msg([
      #(
        "components",
        "[{\"type\":1,\"components\":"
          <> "[{\"type\":2,\"style\":1,\"custom_id\":\"a\",\"label\":\"A\"}]}]",
      ),
    ])
  assert list.length(value.components) == 1
}

/// The message belongs to another bot, so an unmodelled component must not
/// sink it.
pub fn a_components_v2_message_from_another_bot_decodes_test() {
  let value =
    decode_msg([
      #("flags", "32768"),
      #("components", "[{\"type\":17,\"accent_color\":1}]"),
    ])
  assert list.length(value.components) == 1
  assert message.has_flag(value.flags, message.IsComponentsV2)
}

/// Discord writes the same integer field as `2` and as `2.0`.
pub fn integer_fields_accept_both_json_number_spellings_test() {
  let plain =
    decode_msg([#("type", "19"), #("flags", "64"), #("position", "4")])
  let decimal =
    decode_msg([#("type", "19.0"), #("flags", "64.0"), #("position", "4.0")])
  assert plain.type_ == message.ReplyMessage
  assert decimal.type_ == message.ReplyMessage
  assert flags.to_int(decimal.flags) == 64
  assert decimal.position == Some(4)
  assert plain == decimal
}

/// The docs claim MESSAGE_UPDATE carries a full message. Unfurling a link
/// sends four keys.
pub fn message_decoder_rejects_a_partial_update_test() {
  let assert Error(_) =
    parse(
      "{\"id\":\"1\",\"channel_id\":\"2\",\"guild_id\":\"3\",\"embeds\":[]}",
    )
}

pub fn update_decoder_accepts_the_partial_the_message_decoder_rejects_test() {
  let assert Ok(value) =
    json.parse(
      "{\"id\":\"1\",\"channel_id\":\"2\",\"guild_id\":\"3\","
        <> "\"embeds\":[{\"title\":\"unfurled\"}]}",
      message.update_decoder(),
    )
  assert value.id == id.from_string("1")
  assert value.channel_id == id.from_string("2")
  assert value.guild_id == Some(id.from_string("3"))
  assert value.message == None
}

pub fn update_decoder_returns_the_full_message_when_there_is_one_test() {
  let assert Ok(value) = json.parse(msg([]), message.update_decoder())
  let assert Some(inner) = value.message
  assert inner.content == "hi"
  assert value.id == id.from_string("1000")
}

/// A full update that no longer fits is a bug report, not a partial. Deciding
/// on a failed decode instead files a Discord change as an embed unfurl.
pub fn update_decoder_refuses_a_full_message_that_stopped_fitting_test() {
  let assert Error(_) =
    json.parse(
      "{\"id\":\"1\",\"channel_id\":\"2\",\"author\":{\"id\":\"3\"},\"embeds\":[\"nope\"]}",
      message.update_decoder(),
    )

  let assert Error(_) =
    json.parse(
      "{\"id\":\"1\",\"channel_id\":\"2\",\"author\":\"nope\"}",
      message.update_decoder(),
    )
}

/// A DM update has no `guild_id`.
pub fn update_decoder_handles_a_dm_test() {
  let assert Ok(value) =
    json.parse(
      "{\"id\":\"1\",\"channel_id\":\"2\",\"content\":\"edited\"}",
      message.update_decoder(),
    )
  assert value.guild_id == None
  assert value.message == None
}

pub fn pin_list_decodes_test() {
  let assert Ok(value) =
    json.parse(
      "{\"items\":[{\"pinned_at\":\"2024-01-02T00:00:00+00:00\",\"message\":"
        <> msg([])
        <> "}],\"has_more\":true}",
      message.pin_list_decoder(),
    )
  let assert message.PinList(items: [pin], has_more: True) = value
  assert pin.pinned_at == "2024-01-02T00:00:00+00:00"
  assert pin.message.id == id.from_string("1000")
}

pub fn empty_pin_list_decodes_test() {
  let assert Ok(value) =
    json.parse("{\"items\":[]}", message.pin_list_decoder())
  assert value == message.PinList(items: [], has_more: False)
}

/// The exported enum codecs are the copies nothing else exercises.
pub fn the_standalone_message_codecs_are_wired_to_their_own_ladder_test() {
  let assert Ok(reply) = json.parse("19", message.message_type_decoder())
  assert reply == message.ReplyMessage
  assert json.to_string(message.message_type_to_json(reply)) == "19"

  let assert Ok(forward) =
    json.parse("1", message.message_reference_type_decoder())
  assert forward == message.ForwardReference
  assert json.to_string(message.message_reference_type_to_json(forward)) == "1"

  let assert Ok(flags) = json.parse("4", flags.decoder())
  assert flags.to_int(flags) == 4
  assert json.to_string(flags.to_json(flags)) == "4"
}

/// A whole number spelled as a JSON float decodes; a fractional one does not.
pub fn the_standalone_message_codecs_take_a_whole_float_test() {
  assert json.parse("19.0", message.message_type_decoder())
    == Ok(message.ReplyMessage)
  assert json.parse("1.0", message.message_reference_type_decoder())
    == Ok(message.ForwardReference)
  assert json.parse("4.0", flags.decoder()) == Ok(flags.from_int(4))

  assert json.parse("19.5", message.message_type_decoder()) |> result.is_error
}

/// A caller echoing a message back must not drop an unknown value to zero.
pub fn an_unknown_message_enum_round_trips_test() {
  let assert Ok(kind) = json.parse("999", message.message_type_decoder())
  assert kind == UnknownMessageType(999)
  assert json.to_string(message.message_type_to_json(kind)) == "999"

  let assert Ok(reference) =
    json.parse("7", message.message_reference_type_decoder())
  assert reference == UnknownReference(7)
  assert json.to_string(message.message_reference_type_to_json(reference))
    == "7"
}

fn created(payload: message.Draft) -> String {
  payload_json(message.to_body(payload))
}

fn edited(payload: message.Edit) -> String {
  payload_json(message.edit_body(payload))
}

/// What these tests pin is the `payload_json` document. With files that body
/// goes out as multipart, and the fields are the same either way.
fn payload_json(sent: body.Body) -> String {
  let assert body.Form(payload:, files: _) = sent
  json.to_string(json.object(payload))
}

pub fn an_empty_create_is_an_empty_object_test() {
  assert created(message.new()) == "{}"
}

/// A body carrying `"embeds":null,"tts":false` says something about fields the
/// caller never touched.
pub fn plain_text_carries_nothing_else_test() {
  assert created(message.text("hello")) == "{\"content\":\"hello\"}"
}

pub fn a_reply_writes_the_reference_test() {
  let body =
    message.text("hello")
    |> message.allowed_mentions(mentions.none())
    |> message.reply_to(id.from_string("5"))

  assert created(body)
    == "{\"content\":\"hello\","
    <> "\"allowed_mentions\":{\"parse\":[],\"replied_user\":false},"
    <> "\"message_reference\":{\"type\":0,\"message_id\":\"5\",\"fail_if_not_exists\":true}}"
}

/// `glyde.reply` sets the reference last, on a message the handler has
/// already built, so it has to leave the rest of it alone.
pub fn reply_to_keeps_what_was_set_before_it_test() {
  let card = embed.new() |> embed.title("card")
  let before = message.text("hi") |> message.embed(card) |> message.tts
  let after = message.reply_to(before, id.from_string("5"))

  assert after.content == Some("hi")
  assert after.embeds == [card]
  assert after.tts
  assert string.starts_with(
    created(after),
    created(before) |> string.drop_end(1),
  )
}

/// The one create Discord accepts with nothing but a reference.
pub fn a_forward_needs_a_channel_test() {
  let body =
    message.new()
    |> message.forward_of(id.from_string("5"), from: id.from_string("9"))

  assert created(body)
    == "{\"message_reference\":{\"type\":1,\"message_id\":\"5\",\"channel_id\":\"9\"}}"
}

pub fn a_reply_may_name_its_channel_and_guild_test() {
  let reference =
    message.Reply(
      message_id: id.from_string("5"),
      channel_id: Some(id.from_string("9")),
      guild_id: Some(id.from_string("7")),
      fail_if_not_exists: False,
    )

  assert json.to_string(message.reference_to_json(reference))
    == "{\"type\":0,\"message_id\":\"5\",\"channel_id\":\"9\",\"guild_id\":\"7\","
    <> "\"fail_if_not_exists\":false}"
}

pub fn a_file_becomes_an_attachments_entry_test() {
  let chart =
    attachment.described(
      attachment.file(filename: "chart.png", content_type: "image/png", data: <<
        1,
      >>),
      "a chart",
    )

  let body = message.text("see attached") |> message.attach(chart)

  assert created(body)
    == "{\"content\":\"see attached\","
    <> "\"attachments\":[{\"id\":0,\"filename\":\"chart.png\",\"description\":\"a chart\"}]}"
}

/// The wire format follows the files: JSON without, multipart with, and the
/// caller never picks.
pub fn attaching_a_file_makes_the_body_multipart_test() {
  let assert Ok(boundary) = body.boundary("glyde")
  let content_type = fn(payload) {
    let #(header, _) = body.encode(message.to_body(payload), boundary:)
    header
  }
  let chart =
    attachment.file(filename: "chart.png", content_type: "image/png", data: <<
      1,
    >>)

  assert content_type(message.text("hi")) == Some("application/json")
  assert content_type(message.text("hi") |> message.attach(chart))
    == Some("multipart/form-data; boundary=\"glyde\"")
}

/// One row per setter, each from `new()`, so the expected string is that
/// setter's whole effect and nothing else's.
pub fn each_setter_writes_its_own_key_test() {
  let card = embed.new() |> embed.title("t")
  let row = case component.rows([component.button("ok", "OK")]) {
    [row] -> row
    _ -> panic as "one button is one row"
  }

  let cases = [
    #(message.new() |> message.content("hi"), "{\"content\":\"hi\"}"),
    #(
      message.new() |> message.embed(card) |> message.embed(card),
      "{\"embeds\":[{\"title\":\"t\"},{\"title\":\"t\"}]}",
    ),
    #(
      message.new() |> message.component(row),
      "{\"components\":"
        <> json.to_string(json.array([row], component.to_json))
        <> "}",
    ),
    #(
      message.new()
        |> message.sticker(id.from_string("1"))
        |> message.sticker(id.from_string("2")),
      "{\"sticker_ids\":[\"1\",\"2\"]}",
    ),
    #(
      message.new() |> message.allowed_mentions(mentions.none()),
      "{\"allowed_mentions\":{\"parse\":[],\"replied_user\":false}}",
    ),
    #(message.new() |> message.tts, "{\"tts\":true}"),
    #(message.new() |> message.suppress_embeds, "{\"flags\":4}"),
    #(message.new() |> message.silent, "{\"flags\":4096}"),
    // The two named flags share one field, so they have to stack.
    #(
      message.new() |> message.suppress_embeds |> message.silent,
      "{\"flags\":4100}",
    ),
  ]

  list.each(cases, fn(row) {
    let #(body, expected) = row
    assert created(body) == expected
  })
}

/// An empty array is an absence on a create; on an edit it is an instruction.
pub fn empty_lists_are_omitted_on_a_create_test() {
  let body =
    message.Draft(
      ..message.new(),
      embeds: [],
      components: [],
      sticker_ids: [],
      files: [],
    )

  assert created(body) == "{}"
}

pub fn booleans_are_only_written_when_true_test() {
  let cases = [
    #(message.Draft(..message.new(), tts: False), "{}"),
    #(message.Draft(..message.new(), tts: True), "{\"tts\":true}"),
  ]

  list.each(cases, fn(row) {
    let #(body, expected) = row
    assert created(body) == expected
  })
}

/// Discord ignores `enforce_nonce` without a nonce, and `NoNonce` is the only
/// way to say "no nonce", so the inert pair cannot be built at all.
pub fn enforcement_without_a_nonce_is_not_written_test() {
  assert created(message.Draft(..message.new(), nonce: message.NoNonce)) == "{}"
}

/// Zero flags is Discord's default, so writing it says nothing.
pub fn no_flags_is_not_written_test() {
  assert created(message.Draft(..message.new(), flags: message.no_flags))
    == "{}"
}

pub fn set_flags_are_written_as_the_bitfield_test() {
  let flags = message.message_flags(of: [message.SuppressEmbeds])

  assert created(message.Draft(..message.new(), flags: flags))
    == "{\"flags\":4}"
}

pub fn a_nonce_goes_out_ahead_of_the_body_test() {
  let body =
    message.Draft(
      ..message.text("hi"),
      nonce: message.UseNonce(message.StringNonce("abc"), enforce: True),
    )

  assert created(body)
    == "{\"content\":\"hi\",\"nonce\":\"abc\",\"enforce_nonce\":true}"
}

/// A nonce exists so a retried POST does not post twice, so the plain
/// constructor is the enforcing one.
pub fn a_nonce_enforces_itself_by_default_test() {
  let body = message.with_nonce(message.text("hi"), message.StringNonce("abc"))

  assert created(body)
    == "{\"content\":\"hi\",\"nonce\":\"abc\",\"enforce_nonce\":true}"
}

/// Discord echoes the nonce on MESSAGE_CREATE either way, so opting out of the
/// dedup takes its own constructor.
pub fn a_correlation_nonce_can_opt_out_of_the_dedup_test() {
  let body =
    message.with_correlation_nonce(
      message.text("hi"),
      message.StringNonce("abc"),
    )

  assert created(body) == "{\"content\":\"hi\",\"nonce\":\"abc\"}"
}

pub fn sticker_ids_are_written_as_an_array_test() {
  let body =
    message.Draft(..message.new(), sticker_ids: [
      id.from_string("1"),
      id.from_string("2"),
    ])

  assert created(body) == "{\"sticker_ids\":[\"1\",\"2\"]}"
}

pub fn components_are_handed_to_the_component_encoder_test() {
  let rows = component.rows([component.button("confirm", "Confirm")])
  let body = message.Draft(..message.new(), components: rows)
  let encoded = json.to_string(json.array(rows, component.to_json))

  assert created(body) == "{\"components\":" <> encoded <> "}"
}

pub fn an_empty_embed_is_an_empty_object_test() {
  assert json.to_string(embed.to_json(embed.new())) == "{}"
}

pub fn an_embed_image_is_reduced_to_its_url_test() {
  let value =
    embed.new()
    |> embed.image("attachment://chart.png")
    |> embed.thumbnail("https://example.com/t.png")

  assert json.to_string(embed.to_json(value))
    == "{\"image\":{\"url\":\"attachment://chart.png\"},"
    <> "\"thumbnail\":{\"url\":\"https://example.com/t.png\"}}"
}

pub fn a_full_embed_keeps_discords_field_order_test() {
  let value =
    embed.Embed(
      ..embed.new()
      |> embed.title("Report")
      |> embed.description("Q3")
      |> embed.url("https://example.com")
      |> embed.timestamp("2024-01-01T00:00:00.000Z")
      |> embed.color(5_814_783)
      |> embed.image("https://example.com/i.png")
      |> embed.author("glyde")
      |> embed.field("n", "v", inline: True),
      footer: Some(embed.EmbedFooter(
        text: "footer",
        icon_url: Some("https://example.com/f.png"),
        proxy_icon_url: None,
      )),
    )

  assert json.to_string(embed.to_json(value))
    == "{\"title\":\"Report\",\"description\":\"Q3\",\"url\":\"https://example.com\","
    <> "\"timestamp\":\"2024-01-01T00:00:00.000Z\",\"color\":5814783,"
    <> "\"footer\":{\"text\":\"footer\",\"icon_url\":\"https://example.com/f.png\"},"
    <> "\"image\":{\"url\":\"https://example.com/i.png\"},"
    <> "\"author\":{\"name\":\"glyde\"},"
    <> "\"fields\":[{\"name\":\"n\",\"value\":\"v\",\"inline\":true}]}"
}

/// One `Embed` type both ways: the receive-only fields are dropped by
/// `to_json`, so a value read off the wire posts back without a conversion.
pub fn a_received_embed_drops_receive_only_fields_on_send_test() {
  let assert Ok(received) =
    json.parse(
      "{\"title\":\"t\",\"type\":\"rich\",\"video\":{\"url\":\"v\"},"
        <> "\"provider\":{\"name\":\"YouTube\"},\"flags\":32,"
        <> "\"image\":{\"url\":\"i\",\"proxy_url\":\"p\",\"height\":10,\"width\":20}}",
      embed.decoder(),
    )
  assert received.type_ == Some(embed.Rich)
  assert received.provider == Some(embed.EmbedProvider(Some("YouTube"), None))
  assert json.to_string(embed.to_json(received))
    == "{\"title\":\"t\",\"image\":{\"url\":\"i\"}}"
}

/// An embed that arrived with `inline` set goes back out the same.
pub fn an_embed_field_always_states_inline_test() {
  let value =
    embed.Embed(..embed.new(), fields: [
      embed.EmbedField(name: "n", value: "v", inline: False),
    ])

  assert json.to_string(embed.to_json(value))
    == "{\"fields\":[{\"name\":\"n\",\"value\":\"v\",\"inline\":false}]}"
}

/// A flags-only edit carrying the policy is refused on another app's message,
/// which is how suppressing embeds on someone else's message breaks.
pub fn the_policy_rides_with_content_and_components_test() {
  let base = message.new_edit(mentions.none())
  let policy = "\"allowed_mentions\":{\"parse\":[],\"replied_user\":false}"
  let suppress = message.message_flags(of: [message.SuppressEmbeds])

  let cases = [
    #(
      message.Edit(..base, content: Present("@everyone hi")),
      "{\"content\":\"@everyone hi\"," <> policy <> "}",
    ),
    #(
      message.Edit(..base, components: Present([])),
      "{" <> policy <> ",\"components\":[]}",
    ),
    #(message.Edit(..base, flags: Present(suppress)), "{\"flags\":4}"),
    // Presence decides it: an edit to "" is still an edit to the content.
    #(
      message.Edit(..base, content: Present("")),
      "{\"content\":\"\"," <> policy <> "}",
    ),
    #(
      message.Edit(..base, content: Null),
      "{\"content\":null," <> policy <> "}",
    ),
  ]

  list.each(cases, fn(row) {
    let #(body, expected) = row
    assert edited(body) == expected
  })
}

/// The rule governs whether the key is written, never what goes in it.
pub fn the_caller_s_policy_is_never_rewritten_test() {
  let body =
    message.Edit(
      ..message.new_edit(mentions.all() |> mentions.ping_reply(True)),
      content: Present("hi"),
    )

  assert edited(body)
    == "{\"content\":\"hi\",\"allowed_mentions\":"
    <> "{\"parse\":[\"users\",\"roles\",\"everyone\"],\"replied_user\":true}}"
}

/// Discord does not re-parse mentions on a PATCH that changes neither the
/// content nor the components.
pub fn an_edit_that_changes_nothing_says_nothing_test() {
  assert edited(message.new_edit(mentions.all())) == "{}"
}

pub fn the_documented_edit_test() {
  let body =
    message.Edit(
      ..message.new_edit(mentions.none()),
      content: Present("new"),
      embeds: Null,
      attachments: attachment.SetAttachments(
        keep: [attachment.keep(id.from_string("77"))],
        add: [],
      ),
    )

  assert edited(body)
    == "{\"content\":\"new\",\"embeds\":null,"
    <> "\"allowed_mentions\":{\"parse\":[],\"replied_user\":false},"
    <> "\"attachments\":[{\"id\":\"77\"}]}"
}

/// `Present([])` empties the list and `Null` nulls it. With IS_COMPONENTS_V2
/// set Discord wants `embeds` reset to `[]` specifically.
pub fn the_three_states_of_an_edited_list_test() {
  let base = message.new_edit(mentions.none())

  let cases = [
    #(Absent, "{}"),
    #(Null, "{\"embeds\":null}"),
    #(Present([]), "{\"embeds\":[]}"),
  ]

  list.each(cases, fn(row) {
    let #(embeds, expected) = row
    assert edited(message.Edit(..base, embeds: embeds)) == expected
  })
}

pub fn stripping_the_components_sends_an_empty_array_test() {
  let body =
    message.Edit(..message.new_edit(mentions.none()), components: Present([]))

  assert edited(body)
    == "{\"allowed_mentions\":{\"parse\":[],\"replied_user\":false},"
    <> "\"components\":[]}"
}

pub fn edited_flags_go_out_as_the_bitfield_test() {
  let body =
    message.Edit(
      ..message.new_edit(mentions.none()),
      flags: Present(message.message_flags(of: [message.SuppressEmbeds])),
    )

  assert edited(body) == "{\"flags\":4}"
}

/// Omitting the array keeps the existing attachments; an empty one clears them.
pub fn keeping_attachments_omits_the_key_test() {
  assert edited(message.new_edit(mentions.none())) == "{}"
}

pub fn an_empty_array_deletes_all_attachments_test() {
  let body =
    message.Edit(
      ..message.new_edit(mentions.none()),
      attachments: attachment.SetAttachments(keep: [], add: []),
    )

  assert edited(body) == "{\"attachments\":[]}"
}

pub fn an_edit_can_keep_one_attachment_and_add_another_test() {
  let added =
    attachment.file(filename: "new.png", content_type: "image/png", data: <<2>>)

  let body =
    message.Edit(
      ..message.new_edit(mentions.none()),
      attachments: attachment.SetAttachments(
        keep: [attachment.keep(id.from_string("77"))],
        add: [added],
      ),
    )

  assert edited(body)
    == "{\"attachments\":[{\"id\":\"77\"},{\"id\":0,\"filename\":\"new.png\"}]}"

  assert message.edit_files(body) == [added]
}

pub fn keeping_attachments_uploads_nothing_test() {
  assert message.edit_files(message.new_edit(mentions.none())) == []
  assert message.edit_files(
      message.Edit(
        ..message.new_edit(mentions.none()),
        attachments: attachment.SetAttachments(keep: [], add: []),
      ),
    )
    == []
}

pub fn bulk_delete_lists_the_ids_test() {
  let body =
    message.BulkDelete(messages: [id.from_string("1"), id.from_string("2")])

  assert payload_json(message.bulk_delete_body(body))
    == "{\"messages\":[\"1\",\"2\"]}"
}

/// The last payload type in this module that could not reach its endpoint.
pub fn bulk_delete_has_a_body_test() {
  let ids = [id.from_string("1"), id.from_string("2")]

  assert message.bulk_delete_body(message.BulkDelete(messages: ids))
    == body.json([#("messages", json.array(ids, id.to_json))])
}

/// The smallest message Discord sends, with `extra` keys spliced in, each
/// written with its trailing comma.
fn received(content: String, extra: String) -> message.Message {
  let text =
    "{\"id\":\"1000\",\"channel_id\":\"2000\","
    <> "\"author\":{\"id\":\"3000\",\"username\":\"bob\",\"discriminator\":\"0\"},"
    <> "\"content\":"
    <> json.to_string(json.string(content))
    <> ",\"timestamp\":\"2024-01-01T00:00:00.000000+00:00\","
    <> "\"edited_timestamp\":null,\"tts\":true,\"mention_everyone\":false,"
    <> "\"mentions\":[],\"mention_roles\":[],\"pinned\":false,"
    <> extra
    <> "\"type\":0}"
  let assert Ok(value) = json.parse(text, message.decoder())
  value
}

/// Echoing a message back: what a create can say survives, and what only a
/// received message has (attachment URLs, the reply pointer, nonce, tts) does
/// not.
pub fn from_carries_what_a_create_can_set_test() {
  let heard =
    received(
      "hello",
      "\"attachments\":[{\"id\":\"13\",\"filename\":\"a.png\",\"size\":10,"
        <> "\"url\":\"u\",\"proxy_url\":\"p\"}],"
        <> "\"embeds\":[{\"type\":\"rich\",\"title\":\"t\",\"description\":\"d\","
        <> "\"provider\":{\"name\":\"x\"},\"video\":{\"url\":\"v\"},"
        <> "\"thumbnail\":{\"url\":\"th\",\"proxy_url\":\"pth\",\"width\":5},"
        <> "\"footer\":{\"text\":\"f\",\"proxy_icon_url\":\"pf\"},"
        <> "\"fields\":[{\"name\":\"n\",\"value\":\"v\",\"inline\":true}]}],"
        <> "\"sticker_items\":[{\"id\":\"11\",\"name\":\"wave\",\"format_type\":1}],"
        <> "\"message_reference\":{\"message_id\":\"9\",\"channel_id\":\"2000\"},"
        <> "\"nonce\":\"abc\","
        // SUPPRESS_EMBEDS | HAS_THREAD | SUPPRESS_NOTIFICATIONS | IS_VOICE_MESSAGE
        <> "\"flags\":"
        <> string.inspect(4 + 32 + 4096 + 8192)
        <> ",",
    )

  assert created(message.redraft(heard))
    == "{\"content\":\"hello\","
    <> "\"embeds\":[{\"title\":\"t\",\"description\":\"d\","
    <> "\"footer\":{\"text\":\"f\"},\"thumbnail\":{\"url\":\"th\"},"
    <> "\"fields\":[{\"name\":\"n\",\"value\":\"v\",\"inline\":true}]}],"
    <> "\"sticker_ids\":[\"11\"],"
    <> "\"flags\":4100}"
}

pub fn from_carries_components_and_components_v2_test() {
  let heard =
    received(
      "",
      "\"components\":[{\"type\":10,\"id\":1,\"content\":\"# hi\"}],"
        <> "\"flags\":32768,",
    )
  let echoed = message.redraft(heard)

  assert echoed.components == heard.components
  assert created(echoed)
    == "{\"components\":[{\"content\":\"# hi\",\"id\":1,\"type\":10}],"
    <> "\"flags\":32768}"
}

/// Without MESSAGE_CONTENT the content arrives as "", and a create that sends
/// `"content":""` beside nothing else is a 400.
pub fn from_omits_empty_content_test() {
  let echoed = message.redraft(received("", ""))

  assert echoed.content == None
  assert created(echoed) == "{}"
}
