import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import glyde/permissions.{
  type Permission, AddReactions, Administrator, AttachFiles, BanMembers,
  BypassSlowmode, ChangeNickname, Connect, CreateEvents, CreateGuildExpressions,
  CreateInstantInvite, CreatePrivateThreads, CreatePublicThreads, DeafenMembers,
  EmbedLinks, KickMembers, ManageChannels, ManageEvents, ManageGuild,
  ManageGuildExpressions, ManageMessages, ManageNicknames, ManageRoles,
  ManageThreads, ManageWebhooks, MentionEveryone, ModerateMembers, MoveMembers,
  MuteMembers, PinMessages, PrioritySpeaker, ReadMessageHistory, RequestToSpeak,
  SendMessages, SendMessagesInThreads, SendPolls, SendTtsMessages,
  SendVoiceMessages, SetVoiceChannelStatus, Speak, Stream,
  UseApplicationCommands, UseEmbeddedActivities, UseExternalApps,
  UseExternalEmojis, UseExternalSounds, UseExternalStickers, UseSoundboard,
  UseVad, ViewAuditLog, ViewChannel, ViewCreatorMonetizationAnalytics,
  ViewGuildInsights,
}

/// Discord's permissions table. Bit 47 is a gap: the permission that held it
/// was retired.
fn table() -> List(#(Permission, Int)) {
  [
    #(CreateInstantInvite, 0),
    #(KickMembers, 1),
    #(BanMembers, 2),
    #(Administrator, 3),
    #(ManageChannels, 4),
    #(ManageGuild, 5),
    #(AddReactions, 6),
    #(ViewAuditLog, 7),
    #(PrioritySpeaker, 8),
    #(Stream, 9),
    #(ViewChannel, 10),
    #(SendMessages, 11),
    #(SendTtsMessages, 12),
    #(ManageMessages, 13),
    #(EmbedLinks, 14),
    #(AttachFiles, 15),
    #(ReadMessageHistory, 16),
    #(MentionEveryone, 17),
    #(UseExternalEmojis, 18),
    #(ViewGuildInsights, 19),
    #(Connect, 20),
    #(Speak, 21),
    #(MuteMembers, 22),
    #(DeafenMembers, 23),
    #(MoveMembers, 24),
    #(UseVad, 25),
    #(ChangeNickname, 26),
    #(ManageNicknames, 27),
    #(ManageRoles, 28),
    #(ManageWebhooks, 29),
    #(ManageGuildExpressions, 30),
    #(UseApplicationCommands, 31),
    #(RequestToSpeak, 32),
    #(ManageEvents, 33),
    #(ManageThreads, 34),
    #(CreatePublicThreads, 35),
    #(CreatePrivateThreads, 36),
    #(UseExternalStickers, 37),
    #(SendMessagesInThreads, 38),
    #(UseEmbeddedActivities, 39),
    #(ModerateMembers, 40),
    #(ViewCreatorMonetizationAnalytics, 41),
    #(UseSoundboard, 42),
    #(CreateGuildExpressions, 43),
    #(CreateEvents, 44),
    #(UseExternalSounds, 45),
    #(SendVoiceMessages, 46),
    #(SetVoiceChannelStatus, 48),
    #(SendPolls, 49),
    #(UseExternalApps, 50),
    #(PinMessages, 51),
    #(BypassSlowmode, 52),
  ]
}

pub fn bit_index_matches_discords_table_test() {
  list.each(table(), fn(row) {
    let #(permission, bit) = row
    assert permissions.bit_index(permission) == bit
  })
}

pub fn all_permissions_is_the_table_in_bit_order_test() {
  let bits = list.map(table(), fn(row) { row.1 })
  assert permissions.all_permissions() == list.map(table(), fn(row) { row.0 })
  assert list.sort(bits, int.compare) == bits
  assert list.unique(bits) == bits
  assert list.length(bits) == 52
}

pub fn parse_table_test() {
  let cases = [
    #("0", []),
    #("1", [CreateInstantInvite]),
    #("8", [Administrator]),
    #("3072", [ViewChannel, SendMessages]),
    #("117824", [
      AddReactions, ViewChannel, SendMessages, EmbedLinks, AttachFiles,
      ReadMessageHistory,
    ]),
    // Bits 48 to 52, each on its own.
    #("281474976710656", [SetVoiceChannelStatus]),
    #("562949953421312", [SendPolls]),
    #("1125899906842624", [UseExternalApps]),
    #("2251799813685248", [PinMessages]),
    #("4503599627370496", [BypassSlowmode]),
    // The lowest bit and the highest one together.
    #("4503599627370497", [CreateInstantInvite, BypassSlowmode]),
    #("4503599627372544", [SendMessages, BypassSlowmode]),
  ]
  list.each(cases, fn(row) {
    let #(decimal, granted) = row
    let assert Ok(parsed) = permissions.parse(decimal)
    assert parsed == permissions.new(granted)
    assert permissions.to_list(parsed)
      == list.filter(permissions.all_permissions(), list.contains(granted, _))
  })
}

pub fn parse_reads_every_permission_at_once_test() {
  assert permissions.parse("8866461766385663") == Ok(permissions.all())
  assert permissions.to_list(permissions.all()) == permissions.all_permissions()
}

/// A decimal that halved to itself would loop forever.
pub fn parse_accepts_leading_zeros_test() {
  assert permissions.parse("0008") == Ok(permissions.new([Administrator]))
  assert permissions.parse("00") == Ok(permissions.none())
}

pub fn parse_rejects_anything_that_is_not_a_decimal_test() {
  let bad = ["", "8a", "-8", "+8", "8.0", " 8", "8 ", "0x8", "١٢٣"]
  list.each(bad, fn(decimal) {
    assert permissions.parse(decimal) == Error(permissions.NotDecimal(decimal))
  })
}

/// Discord specifies 64 bits, and truncating a wider field grants what nobody
/// did. The two rejections are told apart, so a caller can say which happened.
pub fn parse_rejects_a_field_wider_than_64_bits_test() {
  // 2^64 - 1: every bit on, which fits.
  let assert Ok(full) = permissions.parse("18446744073709551615")
  assert permissions.to_string(full) == "18446744073709551615"
  assert permissions.to_list(full) == permissions.all_permissions()

  // 2^64 and up is not a permission field.
  let too_wide = ["18446744073709551616", "99999999999999999999999"]
  list.each(too_wide, fn(decimal) {
    assert permissions.parse(decimal) == Error(permissions.TooWide(decimal))
  })
}

/// A bot that edits a role must not strip a permission it has never heard of.
pub fn unknown_bits_survive_a_round_trip_test() {
  // Bit 47, retired. Bit 60, never assigned.
  let unknown = ["140737488355328", "1152921504606846976"]
  list.each(unknown, fn(decimal) {
    let assert Ok(granted) = permissions.parse(decimal)
    assert permissions.to_list(granted) == []
    assert permissions.to_string(granted) == decimal
  })

  // Bit 60 alongside a permission we do know.
  let assert Ok(mixed) = permissions.parse("1153484454560268288")
  assert permissions.to_list(mixed) == [SendPolls]
  assert permissions.contains(mixed, SendPolls)
  assert permissions.to_string(mixed) == "1153484454560268288"
}

pub fn to_string_table_test() {
  let cases = [
    #([], "0"),
    #([CreateInstantInvite], "1"),
    #([Administrator], "8"),
    #([ViewChannel, SendMessages], "3072"),
    #([SendPolls], "562949953421312"),
    #([BypassSlowmode], "4503599627370496"),
    #([CreateInstantInvite, BypassSlowmode], "4503599627370497"),
  ]
  list.each(cases, fn(row) {
    let #(granted, expected) = row
    assert permissions.to_string(permissions.new(granted)) == expected
  })
  assert permissions.to_string(permissions.all()) == "8866461766385663"
}

pub fn round_trips_every_permission_on_its_own_test() {
  list.each(permissions.all_permissions(), fn(permission) {
    let granted = permissions.new([permission])
    assert permissions.parse(permissions.to_string(granted)) == Ok(granted)
    assert permissions.to_list(granted) == [permission]
  })
}

/// A high bit next to bit 0, where each bit on its own already round trips.
pub fn round_trips_the_high_bits_test() {
  // Bits 0, 49 and 52.
  let granted =
    permissions.new([SendPolls, BypassSlowmode, CreateInstantInvite])
  let decimal = permissions.to_string(granted)
  assert decimal == "5066549580791809"
  assert permissions.parse(decimal) == Ok(granted)

  // Bit 60 and bit 0.
  let assert Ok(bit_60) = permissions.parse("1152921504606846977")
  assert permissions.to_list(bit_60) == [CreateInstantInvite]
  assert permissions.to_string(bit_60) == "1152921504606846977"

  // Bit 63 and bit 0, the widest a permission field goes.
  let assert Ok(bit_63) = permissions.parse("9223372036854775809")
  assert permissions.to_list(bit_63) == [CreateInstantInvite]
  assert permissions.to_string(bit_63) == "9223372036854775809"
}

pub fn add_and_remove_test() {
  let granted =
    permissions.none()
    |> permissions.add(SendMessages)
    |> permissions.add(BypassSlowmode)
  assert permissions.to_string(granted) == "4503599627372544"

  assert permissions.remove(granted, BypassSlowmode)
    == permissions.new([SendMessages])
  assert permissions.remove(granted, SendMessages)
    == permissions.new([BypassSlowmode])

  assert permissions.remove(granted, BanMembers) == granted
  assert permissions.add(granted, SendMessages) == granted
}

/// Bit 31 is the top of the low half and bit 63 the top of the high one,
/// where clearing a bit is the step that goes wrong if a half stops being 32
/// bits wide.
pub fn clearing_the_top_bit_of_a_half_test() {
  let dropped = permissions.remove(permissions.all(), UseApplicationCommands)
  assert !permissions.contains(dropped, UseApplicationCommands)
  assert permissions.contains(dropped, ManageGuildExpressions)
  assert permissions.contains(dropped, RequestToSpeak)
  assert permissions.to_string(dropped) == "8866459618902015"

  // Bit 63 and bit 0, with bit 0 taken back off.
  let assert Ok(top) = permissions.parse("9223372036854775809")
  let alone =
    permissions.difference(top, permissions.new([CreateInstantInvite]))
  assert permissions.to_string(alone) == "9223372036854775808"
}

/// The two halves of resolving a channel overwrite.
pub fn union_and_difference_test() {
  let base = permissions.new([ViewChannel, SendMessages, BypassSlowmode])
  let allow = permissions.new([SendPolls, ViewChannel])
  let deny = permissions.new([SendMessages, BypassSlowmode])

  assert permissions.union(base, allow)
    == permissions.new([ViewChannel, SendMessages, SendPolls, BypassSlowmode])
  assert permissions.difference(base, deny) == permissions.new([ViewChannel])

  // Order does not change a union.
  assert permissions.union(base, allow) == permissions.union(allow, base)
  assert permissions.union(base, permissions.none()) == base
  assert permissions.difference(base, permissions.none()) == base
  assert permissions.difference(base, base) == permissions.none()
}

/// Administrator granting everything is a Discord rule, not a bitfield one, so
/// `allows` knows it and `to_list` does not.
pub fn administrator_grants_everything_test() {
  let admin = permissions.new([Administrator])
  list.each(permissions.all_permissions(), fn(permission) {
    assert permissions.allows(permissions.effective(admin), permission)
  })
  assert permissions.to_list(admin) == [Administrator]
  assert permissions.to_string(admin) == "8"
}

/// The rule only holds for a set that has been resolved. On a role's own bits
/// or on one side of an overwrite, a set Administrator bit means Administrator
/// and nothing else, which is what `contains` answers.
pub fn contains_does_not_apply_the_administrator_rule_test() {
  let admin = permissions.new([Administrator])
  assert permissions.contains(admin, Administrator)
  assert !permissions.contains(admin, BanMembers)
  assert !permissions.contains(admin, ViewChannel)

  // A deny of Administrator denies Administrator, not everything.
  let deny = permissions.new([Administrator, SendMessages])
  assert permissions.contains(deny, SendMessages)
  assert !permissions.contains(deny, BanMembers)
}

pub fn contains_is_false_for_a_permission_that_is_not_there_test() {
  let granted = permissions.new([ViewChannel, SendMessages])
  assert permissions.contains(granted, SendMessages)
  assert !permissions.contains(granted, BanMembers)
  assert !permissions.contains(permissions.none(), ViewChannel)

  // Without Administrator the two questions have the same answer.
  assert permissions.allows(permissions.effective(granted), SendMessages)
  assert !permissions.allows(permissions.effective(granted), BanMembers)
}

pub fn decodes_from_a_json_string_test() {
  let assert Ok(granted) =
    json.parse(
      "{\"permissions\":\"562949953421312\"}",
      decode.at(["permissions"], permissions.decoder()),
    )
  assert granted == permissions.new([SendPolls])
}

/// Discord sends permissions as strings, so a number is refused, not rounded.
pub fn refuses_a_json_number_test() {
  let decoded =
    json.parse(
      "{\"permissions\":562949953421312}",
      decode.at(["permissions"], permissions.decoder()),
    )
  let assert Error(_) = decoded
}

pub fn refuses_a_string_that_is_not_a_decimal_test() {
  let decoded =
    json.parse(
      "{\"permissions\":\"all of them\"}",
      decode.at(["permissions"], permissions.decoder()),
    )
  let assert Error(_) = decoded
}

pub fn refuses_null_test() {
  let decoded =
    json.parse(
      "{\"permissions\":null}",
      decode.at(["permissions"], permissions.decoder()),
    )
  let assert Error(_) = decoded
}

pub fn encodes_as_a_json_string_test() {
  let granted = permissions.new([SendPolls])
  assert json.to_string(permissions.to_json(granted)) == "\"562949953421312\""
}
