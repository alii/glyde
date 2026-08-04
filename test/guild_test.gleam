import gleam/json
import gleam/list
import gleam/option.{None, Some}
import glyde/flags
import glyde/guild
import glyde/id
import glyde/permissions

fn parse(text: String) -> Result(guild.Guild, json.DecodeError) {
  json.parse(text, guild.decoder())
}

/// One unexpected null in field 31 must not lose the other 46.
pub fn decodes_the_two_required_fields_alone_test() {
  let assert Ok(bare) = parse("{\"id\":\"2\",\"owner_id\":\"3\"}")
  assert id.to_string(bare.id) == "2"
  assert id.to_string(bare.owner_id) == "3"
  assert bare.name == ""
  assert bare.afk_timeout == 300
  assert bare.preferred_locale == "en-US"
  assert bare.verification_level == guild.NoVerification
  assert bare.premium_tier == guild.NoTier
  assert bare.roles == []
  assert bare.emojis == []
  assert bare.features == []
}

pub fn requires_id_and_owner_id_test() {
  let assert Error(_) = parse("{\"owner_id\":\"3\"}")
  let assert Error(_) = parse("{\"id\":\"2\"}")
}

/// The twelve fields Discord documents as required and then sends as null.
pub fn tolerates_null_on_every_documented_required_field_test() {
  let assert Ok(sparse) =
    parse(
      "{\"id\":\"2\",\"owner_id\":\"3\",\"icon\":null,\"splash\":null,\"discovery_splash\":null,\"afk_channel_id\":null,\"application_id\":null,\"system_channel_id\":null,\"rules_channel_id\":null,\"vanity_url_code\":null,\"description\":null,\"banner\":null,\"public_updates_channel_id\":null,\"safety_alerts_channel_id\":null}",
    )
  assert sparse.icon == None
  assert sparse.splash == None
  assert sparse.discovery_splash == None
  assert sparse.afk_channel_id == None
  assert sparse.application_id == None
  assert sparse.system_channel_id == None
  assert sparse.rules_channel_id == None
  assert sparse.vanity_url_code == None
  assert sparse.description == None
  assert sparse.banner == None
  assert sparse.public_updates_channel_id == None
  assert sparse.safety_alerts_channel_id == None
}

/// Discord sends `"roles": null` on some partial objects.
pub fn null_collections_decode_as_empty_test() {
  let assert Ok(nulled) =
    parse(
      "{\"id\":\"2\",\"owner_id\":\"3\",\"roles\":null,\"emojis\":null,\"features\":null}",
    )
  assert nulled.roles == []
  assert nulled.emojis == []
  assert nulled.features == []
}

pub fn decodes_a_rest_guild_test() {
  let assert Ok(server) =
    parse(
      "{\"id\":\"197038439483310086\",\"name\":\"Discord Testers\",\"icon\":\"f64c482b807da4f539cff778d174971c\",\"description\":\"The official place\",\"splash\":null,\"discovery_splash\":null,\"features\":[\"COMMUNITY\",\"NEWS\",\"VANITY_URL\"],\"emojis\":[],\"banner\":\"9b6439a7de04f1d26af92f84ac9e1e4a\",\"owner_id\":\"73193882359173120\",\"application_id\":null,\"region\":null,\"afk_channel_id\":null,\"afk_timeout\":300,\"system_channel_id\":null,\"widget_enabled\":true,\"widget_channel_id\":null,\"verification_level\":3,\"roles\":[],\"default_message_notifications\":1,\"mfa_level\":1,\"explicit_content_filter\":2,\"max_presences\":40000,\"max_members\":250000,\"vanity_url_code\":\"discord-testers\",\"premium_tier\":3,\"premium_subscription_count\":33,\"system_channel_flags\":0,\"preferred_locale\":\"en-US\",\"rules_channel_id\":\"441688182833020939\",\"public_updates_channel_id\":\"281283303326089216\",\"safety_alerts_channel_id\":\"281283303326089216\",\"nsfw_level\":0,\"premium_progress_bar_enabled\":false}",
    )
  assert server.name == "Discord Testers"
  assert server.verification_level == guild.HighVerification
  assert server.default_message_notifications == guild.OnlyMentions
  assert server.explicit_content_filter == guild.FilterAllMembers
  assert server.mfa_level == guild.ElevatedMfa
  assert server.premium_tier == guild.Tier3
  assert server.nsfw_level == guild.DefaultNsfwLevel
  assert server.premium_subscription_count == Some(33)
  assert server.max_presences == Some(40_000)
  assert server.widget_enabled == Some(True)
  assert server.vanity_url_code == Some("discord-testers")
  assert server.premium_progress_bar_enabled == False
}

/// `GET /users/@me/guilds` is the only source of `owner` and `permissions`,
/// and its `permissions` excludes channel overwrites.
pub fn a_user_guilds_entry_carries_owner_and_permissions_test() {
  let assert Ok(mine) =
    json.parse(
      "{\"id\":\"80351110224678912\",\"name\":\"1337 Krew\",\"icon\":\"8342729096ea3675442027381ff50dfe\",\"owner\":true,\"permissions\":\"36953089\",\"features\":[\"COMMUNITY\"]}",
      guild.user_guild_decoder(),
    )
  assert id.to_string(mine.id) == "80351110224678912"
  assert mine.name == "1337 Krew"
  assert mine.owner == True
  let assert Some(granted) = mine.permissions
  assert permissions.to_string(granted) == "36953089"
  assert mine.features == ["COMMUNITY"]
}

/// The payload that carries `owner` never carries `owner_id`, so the full
/// guild decoder is the wrong one to reach for.
pub fn a_user_guilds_entry_is_not_a_guild_test() {
  let body =
    "{\"id\":\"80351110224678912\",\"name\":\"1337 Krew\",\"owner\":true,\"permissions\":\"36953089\"}"
  let assert Error(_) = parse(body)
  let assert Ok(_) = json.parse(body, guild.user_guild_decoder())
}

/// `with_counts=true` is the only way to get the counts, and it answers with
/// both, so a payload carrying one of them is no counts at all.
pub fn a_user_guilds_entry_counts_are_optional_test() {
  let cases = [
    "{\"id\":\"1\",\"name\":\"a\"}",
    "{\"id\":\"1\",\"name\":\"a\",\"approximate_member_count\":3}",
    "{\"id\":\"1\",\"name\":\"a\",\"approximate_presence_count\":2}",
  ]
  list.each(cases, fn(text) {
    let assert Ok(without) = json.parse(text, guild.user_guild_decoder())
    assert without.counts == None
    assert without.owner == False
  })

  let assert Ok(with) =
    json.parse(
      "{\"id\":\"1\",\"name\":\"a\",\"approximate_member_count\":3,\"approximate_presence_count\":2}",
      guild.user_guild_decoder(),
    )
  assert with.counts == Some(guild.ApproximateCounts(members: 3, presences: 2))
}

/// Discord adds feature strings at every product launch.
pub fn features_stay_open_strings_test() {
  let assert Ok(server) =
    parse(
      "{\"id\":\"2\",\"owner_id\":\"3\",\"features\":[\"COMMUNITY\",\"SOMETHING_DISCORD_SHIPPED_YESTERDAY\"]}",
    )
  assert guild.has_feature(server.features, guild.feature_community) == True
  assert guild.has_feature(
      server.features,
      "SOMETHING_DISCORD_SHIPPED_YESTERDAY",
    )
    == True
  assert guild.has_feature(server.features, guild.feature_discoverable) == False
}

/// `None` is REST, where the question does not apply; a `GatewayCreate` with
/// empty lists is a gateway create with nothing visible.
pub fn gateway_create_fields_are_absent_not_empty_test() {
  let assert Ok(from_rest) = parse("{\"id\":\"2\",\"owner_id\":\"3\"}")
  assert from_rest.gateway_create == None

  let assert Ok(from_gateway) =
    parse(
      "{\"id\":\"2\",\"owner_id\":\"3\",\"joined_at\":\"2021-01-01T00:00:00+00:00\",\"large\":false,\"member_count\":2,\"voice_states\":[],\"members\":[],\"channels\":[],\"threads\":[]}",
    )
  assert from_gateway.gateway_create
    == Some(
      guild.GatewayCreate(
        joined_at: "2021-01-01T00:00:00+00:00",
        large: False,
        member_count: 2,
        voice_states: [],
        members: [],
        channels: [],
        threads: [],
      ),
    )
}

/// GUILD_CREATE voice states are partial and carry no `guild_id`.
pub fn a_guild_create_carries_partial_voice_states_test() {
  let assert Ok(server) =
    parse(
      "{\"id\":\"2\",\"owner_id\":\"3\",\"joined_at\":\"2021-01-01T00:00:00+00:00\",\"voice_states\":[{\"channel_id\":\"9\",\"user_id\":\"4\",\"session_id\":\"abc\"}],\"channels\":[{\"id\":\"9\",\"type\":2,\"name\":\"General\"}],\"members\":[{\"roles\":[],\"joined_at\":\"2021-01-01T00:00:00+00:00\"}]}",
    )
  let assert Some(created) = server.gateway_create
  let assert [speaking] = created.voice_states
  assert speaking.guild_id == None
  assert id.to_string(speaking.user_id) == "4"
  let assert [room] = created.channels
  assert room.name == Some("General")
  let assert [who] = created.members
  assert who.roles == []
  // The keys this payload leaves out do not un-make the block.
  assert created.threads == []
}

/// `joined_at` is what says this is a GUILD_CREATE. Without it there is no
/// instant to report, and inventing one hands the caller a timestamp to fail
/// to parse.
pub fn the_gateway_block_needs_a_joined_at_test() {
  let assert Ok(server) =
    parse("{\"id\":\"2\",\"owner_id\":\"3\",\"member_count\":2,\"large\":true}")
  assert server.gateway_create == None

  let assert Ok(joined) =
    parse(
      "{\"id\":\"2\",\"owner_id\":\"3\",\"joined_at\":\"2021-01-01T00:00:00+00:00\"}",
    )
  let assert Some(created) = joined.gateway_create
  assert created.joined_at == "2021-01-01T00:00:00+00:00"
  assert created.member_count == 0
  assert created.channels == []
}

pub fn verification_level_round_trips_test() {
  let cases = [
    #(0, guild.NoVerification),
    #(1, guild.LowVerification),
    #(2, guild.MediumVerification),
    #(3, guild.HighVerification),
    #(4, guild.VeryHighVerification),
  ]
  list.each(cases, fn(pair) {
    let #(wire, variant) = pair
    assert guild.verification_level_from_int(wire) == variant
    assert guild.verification_level_to_int(variant) == wire
  })
  assert guild.verification_level_from_int(9)
    == guild.UnknownVerificationLevel(9)
  assert guild.verification_level_to_int(guild.UnknownVerificationLevel(9)) == 9
}

pub fn message_notification_level_round_trips_test() {
  assert guild.message_notification_level_from_int(0) == guild.AllMessages
  assert guild.message_notification_level_from_int(1) == guild.OnlyMentions
  assert guild.message_notification_level_from_int(4)
    == guild.UnknownMessageNotificationLevel(4)
  assert guild.message_notification_level_to_int(guild.OnlyMentions) == 1
  assert guild.message_notification_level_to_int(
      guild.UnknownMessageNotificationLevel(4),
    )
    == 4
}

pub fn explicit_content_filter_round_trips_test() {
  assert guild.explicit_content_filter_from_int(0) == guild.FilterDisabled
  assert guild.explicit_content_filter_from_int(1)
    == guild.FilterMembersWithoutRoles
  assert guild.explicit_content_filter_from_int(2) == guild.FilterAllMembers
  assert guild.explicit_content_filter_from_int(8)
    == guild.UnknownExplicitContentFilterLevel(8)
  assert guild.explicit_content_filter_to_int(guild.FilterAllMembers) == 2
  assert guild.explicit_content_filter_to_int(
      guild.UnknownExplicitContentFilterLevel(8),
    )
    == 8
}

pub fn mfa_level_round_trips_test() {
  assert guild.mfa_level_from_int(0) == guild.NoMfa
  assert guild.mfa_level_from_int(1) == guild.ElevatedMfa
  assert guild.mfa_level_from_int(5) == guild.UnknownMfaLevel(5)
  assert guild.mfa_level_to_int(guild.ElevatedMfa) == 1
  assert guild.mfa_level_to_int(guild.UnknownMfaLevel(5)) == 5
}

pub fn nsfw_level_round_trips_test() {
  let cases = [
    #(0, guild.DefaultNsfwLevel),
    #(1, guild.ExplicitNsfwLevel),
    #(2, guild.SafeNsfwLevel),
    #(3, guild.AgeRestrictedNsfwLevel),
  ]
  list.each(cases, fn(pair) {
    let #(wire, variant) = pair
    assert guild.nsfw_level_from_int(wire) == variant
    assert guild.nsfw_level_to_int(variant) == wire
  })
  assert guild.nsfw_level_from_int(7) == guild.UnknownNsfwLevel(7)
  assert guild.nsfw_level_to_int(guild.UnknownNsfwLevel(7)) == 7
}

pub fn premium_tier_round_trips_test() {
  let cases = [
    #(0, guild.NoTier),
    #(1, guild.Tier1),
    #(2, guild.Tier2),
    #(3, guild.Tier3),
  ]
  list.each(cases, fn(pair) {
    let #(wire, variant) = pair
    assert guild.premium_tier_from_int(wire) == variant
    assert guild.premium_tier_to_int(variant) == wire
  })
  assert guild.premium_tier_from_int(4) == guild.UnknownPremiumTier(4)
  assert guild.premium_tier_to_int(guild.UnknownPremiumTier(4)) == 4
}

/// An unknown enum value must not sink the whole guild.
pub fn an_unknown_enum_value_does_not_fail_the_guild_test() {
  let assert Ok(future) =
    parse(
      "{\"id\":\"2\",\"owner_id\":\"3\",\"verification_level\":9,\"nsfw_level\":7,\"premium_tier\":4,\"mfa_level\":5}",
    )
  assert future.verification_level == guild.UnknownVerificationLevel(9)
  assert future.nsfw_level == guild.UnknownNsfwLevel(7)
  assert future.premium_tier == guild.UnknownPremiumTier(4)
  assert future.mfa_level == guild.UnknownMfaLevel(5)
}

/// All six flags are suppressions, so a set bit hides a notice.
pub fn system_channel_flags_name_all_six_bits_test() {
  let cases = [
    #(guild.SuppressJoinNotifications, 1),
    #(guild.SuppressPremiumSubscriptions, 2),
    #(guild.SuppressGuildReminderNotifications, 4),
    #(guild.SuppressJoinNotificationReplies, 8),
    #(guild.SuppressRoleSubscriptionPurchaseNotifications, 16),
    #(guild.SuppressRoleSubscriptionPurchaseNotificationReplies, 32),
  ]
  list.each(cases, fn(pair) {
    let #(flag, bit) = pair
    assert guild.has_flag(flags.from_int(bit), flag) == True
    assert guild.has_flag(flags.from_int(0), flag) == False
  })
}

pub fn system_channel_flags_keep_unnamed_bits_test() {
  let future = flags.from_int(1 + 64)
  assert flags.to_int(future) == 65
  assert guild.has_flag(future, guild.SuppressJoinNotifications) == True
  assert guild.has_flag(future, guild.SuppressPremiumSubscriptions) == False
}

pub fn has_system_channel_flag_reads_the_guild_test() {
  let assert Ok(quiet) =
    parse("{\"id\":\"2\",\"owner_id\":\"3\",\"system_channel_flags\":3}")
  assert guild.has_system_channel_flag(quiet, guild.SuppressJoinNotifications)
    == True
  assert guild.has_system_channel_flag(
      quiet,
      guild.SuppressPremiumSubscriptions,
    )
    == True
  assert guild.has_system_channel_flag(
      quiet,
      guild.SuppressGuildReminderNotifications,
    )
    == False
}

/// An available guild may still carry `"unavailable": false`, so GUILD_CREATE
/// has to read the value.
pub fn guild_create_branches_on_the_unavailable_value_test() {
  let assert Ok(down) =
    json.parse(
      "{\"id\":\"41771983423143937\",\"unavailable\":true}",
      guild.maybe_available_decoder(),
    )
  assert down == guild.OfflineGuild(id.from_string("41771983423143937"))

  let assert Ok(guild.AvailableGuild(up)) =
    json.parse(
      "{\"id\":\"2\",\"owner_id\":\"3\",\"name\":\"up\",\"unavailable\":false}",
      guild.maybe_available_decoder(),
    )
  assert up.name == "up"
}

/// A guild that is available often omits the key entirely.
pub fn guild_create_treats_an_absent_key_as_available_test() {
  let assert Ok(guild.AvailableGuild(up)) =
    json.parse(
      "{\"id\":\"2\",\"owner_id\":\"3\",\"name\":\"up\"}",
      guild.maybe_available_decoder(),
    )
  assert up.name == "up"
}

/// A two-key unavailable stub must not be run through the 47-field decoder.
pub fn an_unavailable_stub_never_falls_through_test() {
  let assert Error(_) =
    json.parse("{\"id\":\"1\",\"unavailable\":true}", guild.decoder())
  let assert Ok(guild.OfflineGuild(_)) =
    json.parse(
      "{\"id\":\"1\",\"unavailable\":true}",
      guild.maybe_available_decoder(),
    )
}

/// In GUILD_DELETE the key being present means an outage and absent means the
/// bot left. The value is always true, so reading it says nothing.
pub fn guild_delete_branches_on_the_key_being_present_test() {
  let assert Ok(outage) =
    json.parse("{\"id\":\"1\",\"unavailable\":true}", guild.departure_decoder())
  assert outage == guild.GuildOutage(id.from_string("1"))

  let assert Ok(removed) =
    json.parse("{\"id\":\"1\"}", guild.departure_decoder())
  assert removed == guild.GuildGone(id.from_string("1"))
}

/// A present null, and a present false, still count as present.
pub fn a_present_null_unavailable_still_means_outage_test() {
  let assert Ok(from_null) =
    json.parse("{\"id\":\"1\",\"unavailable\":null}", guild.departure_decoder())
  assert from_null == guild.GuildOutage(id.from_string("1"))

  let assert Ok(from_false) =
    json.parse(
      "{\"id\":\"1\",\"unavailable\":false}",
      guild.departure_decoder(),
    )
  assert from_false == guild.GuildOutage(id.from_string("1"))
}

/// The id read moved in here with the presence read, and it is required: a
/// GUILD_DELETE without one is a decode error, not a departure.
pub fn a_departure_needs_an_id_test() {
  let assert Error(_) =
    json.parse("{\"unavailable\":true}", guild.departure_decoder())
}

pub fn ban_carries_an_optional_reason_test() {
  let assert Ok(with_reason) =
    json.parse(
      "{\"reason\":\"spam\",\"user\":{\"id\":\"1\",\"username\":\"nelly\"}}",
      guild.ban_decoder(),
    )
  assert with_reason.reason == Some("spam")
  assert with_reason.user.username == "nelly"

  let assert Ok(without_reason) =
    json.parse("{\"reason\":null,\"user\":{\"id\":\"1\"}}", guild.ban_decoder())
  assert without_reason.reason == None
}

/// Discord writes the same integer field as `2` and as `2.0`.
pub fn a_whole_number_written_as_a_float_still_decodes_test() {
  let assert Ok(server) =
    parse(
      "{\"id\":\"2\",\"owner_id\":\"3\",\"afk_timeout\":60.0,\"max_members\":250000.0,\"premium_tier\":2.0}",
    )
  assert server.afk_timeout == 60
  assert server.max_members == Some(250_000)
  assert server.premium_tier == guild.Tier2
}

pub fn enums_encode_as_their_wire_numbers_test() {
  assert json.to_string(guild.premium_tier_to_json(guild.Tier3)) == "3"
  assert json.to_string(guild.nsfw_level_to_json(guild.UnknownNsfwLevel(7)))
    == "7"
  assert json.to_string(guild.verification_level_to_json(
      guild.VeryHighVerification,
    ))
    == "4"
}
