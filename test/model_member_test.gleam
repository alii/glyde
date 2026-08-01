import gleam/json
import gleam/list
import gleam/option.{None, Some}
import glyde/flags
import glyde/id
import glyde/model/member
import glyde/permissions

fn parse(text: String) -> Result(member.GuildMember, json.DecodeError) {
  json.parse(text, member.decoder())
}

/// The shape `GET /guilds/{id}/members/{id}` returns, which is the only one
/// that carries every field.
pub fn decodes_a_rest_member_test() {
  let assert Ok(who) =
    parse(
      "{\"user\":{\"id\":\"80351110224678912\",\"username\":\"nelly\"},\"nick\":\"NOT NELLY\",\"avatar\":\"ffff\",\"banner\":null,\"roles\":[\"41771983423143936\"],\"joined_at\":\"2015-04-26T06:26:56.936000+00:00\",\"premium_since\":null,\"deaf\":false,\"mute\":true,\"flags\":0,\"pending\":false}",
    )
  let assert Some(account) = who.user
  assert account.username == "nelly"
  assert who.nick == Some("NOT NELLY")
  assert who.avatar == Some("ffff")
  assert who.banner == None
  assert list.map(who.roles, id.to_string) == ["41771983423143936"]
  assert who.joined_at == Some("2015-04-26T06:26:56.936000+00:00")
  assert who.deaf == Some(False)
  assert who.mute == Some(True)
  assert who.pending == Some(False)
  assert who.permissions == None
}

/// Interaction resolved data drops `user` and both of `deaf` and `mute`, so
/// requiring either fails every context-menu command.
pub fn decodes_an_interaction_resolved_member_test() {
  let assert Ok(who) =
    parse(
      "{\"nick\":null,\"roles\":[],\"joined_at\":\"2021-01-01T00:00:00.000000+00:00\",\"premium_since\":null,\"flags\":0,\"pending\":false,\"permissions\":\"104324673\"}",
    )
  assert who.user == None
  assert who.deaf == None
  assert who.mute == None
  let assert Some(perms) = who.permissions
  assert permissions.to_string(perms) == "104324673"
  assert permissions.contains(perms, permissions.ViewChannel) == True
}

/// GUILD_MEMBER_UPDATE omits `flags` despite the reference page marking it
/// required, and `None` keeps that apart from every flag being off: a cache
/// merging this update must not clear a flag the payload never mentioned.
pub fn decodes_a_guild_member_update_test() {
  let assert Ok(who) =
    parse(
      "{\"user\":{\"id\":\"1\"},\"roles\":[\"2\"],\"joined_at\":\"2021-01-01T00:00:00+00:00\",\"nick\":null,\"pending\":false}",
    )
  assert who.flags == None
  assert who.deaf == None
  assert who.mute == None

  let assert Ok(cleared) =
    parse("{\"user\":{\"id\":\"1\"},\"roles\":[\"2\"],\"flags\":0}")
  assert cleared.flags == Some(member.no_member_flags)
}

/// A guest was invited to one channel and never joined the guild, so Discord
/// sends a null `joined_at`.
pub fn a_guest_has_no_join_date_test() {
  let assert Ok(guest) = parse("{\"roles\":[],\"joined_at\":null}")
  assert guest.joined_at == None
}

/// `roles` is the only field all five wire shapes carry, but a partial can
/// still null it, and an empty list is the honest answer.
pub fn roles_tolerates_absent_and_null_test() {
  let cases = ["{}", "{\"roles\":null}", "{\"roles\":[]}"]
  list.each(cases, fn(text) {
    let assert Ok(who) = parse(text)
    assert who.roles == []
  })
}

/// Absence would read as "not pending", which is a different claim from "the
/// payload did not say", so this one is not defaulted.
pub fn pending_stays_unknown_when_absent_test() {
  let assert Ok(quiet) = parse("{\"roles\":[]}")
  assert quiet.pending == None

  let assert Ok(loud) = parse("{\"roles\":[],\"pending\":true}")
  assert loud.pending == Some(True)
}

pub fn member_flag_bits_test() {
  let table = [
    #(member.DidRejoin, 1),
    #(member.CompletedOnboarding, 2),
    #(member.BypassesVerification, 4),
    #(member.StartedOnboarding, 8),
    #(member.IsGuest, 16),
    #(member.StartedHomeActions, 32),
    #(member.CompletedHomeActions, 64),
    #(member.AutomodQuarantinedUsername, 128),
    #(member.DmSettingsUpsellAcknowledged, 512),
    #(member.AutomodQuarantinedGuildTag, 1024),
  ]
  list.each(table, fn(row) {
    let #(flag, bit) = row
    assert member.has_flag(flags.from_int(bit), flag) == True
    assert member.has_flag(flags.from_int(0), flag) == False
  })
}

/// Bit 8 is a hole in Discord's table, so indexing the variants by position
/// puts `DmSettingsUpsellAcknowledged` on 256.
pub fn bit_256_belongs_to_no_named_flag_test() {
  let flags = flags.from_int(256)
  let named = [
    member.DidRejoin,
    member.CompletedOnboarding,
    member.BypassesVerification,
    member.StartedOnboarding,
    member.IsGuest,
    member.StartedHomeActions,
    member.CompletedHomeActions,
    member.AutomodQuarantinedUsername,
    member.DmSettingsUpsellAcknowledged,
    member.AutomodQuarantinedGuildTag,
  ]
  list.each(named, fn(flag) {
    assert member.has_flag(flags, flag) == False
  })
  assert flags.to_int(flags) == 256
}

pub fn unknown_flag_bits_survive_test() {
  let assert Ok(who) = parse("{\"roles\":[],\"flags\":2097153}")
  let assert Some(flags) = who.flags
  assert flags.to_int(flags) == 2_097_153
  assert member.has_flag(flags, member.DidRejoin) == True
}

/// The PATCH member endpoint takes a flags value the caller has to build, so
/// the named bits have to be reachable without hand-computing an integer.
pub fn member_flags_are_buildable_test() {
  let both =
    member.member_flags(of: [member.DidRejoin, member.BypassesVerification])
  assert flags.to_int(both) == 5
  assert flags.to_int(member.member_flags(of: [])) == 0

  let dropped = member.without_flag(both, member.DidRejoin)
  assert flags.to_int(dropped) == 4
  // Removing a flag that was never set leaves the bits alone.
  assert member.without_flag(dropped, member.DidRejoin) == dropped

  let added = member.with_flag(dropped, member.IsGuest)
  assert flags.to_int(added) == 20
  // Setting a flag twice is not the same as toggling it off.
  assert member.with_flag(added, member.IsGuest) == added
}

/// Nickname first, then the account's display name, then its username.
pub fn display_name_prefers_the_nickname_test() {
  let table = [
    #(
      "{\"roles\":[],\"nick\":\"Nick\",\"user\":{\"id\":\"1\",\"username\":\"name\",\"global_name\":\"Global\"}}",
      Some("Nick"),
    ),
    #(
      "{\"roles\":[],\"nick\":null,\"user\":{\"id\":\"1\",\"username\":\"name\",\"global_name\":\"Global\"}}",
      Some("Global"),
    ),
    #(
      "{\"roles\":[],\"user\":{\"id\":\"1\",\"username\":\"name\",\"global_name\":null}}",
      Some("name"),
    ),
    // No user at all: interaction resolved data and a partial message member.
    #("{\"roles\":[]}", None),
    // A webhook author has no username either, and "" is not a name.
    #("{\"roles\":[],\"user\":{\"id\":\"1\"}}", None),
  ]
  list.each(table, fn(row) {
    let #(text, expected) = row
    let assert Ok(who) = parse(text)
    assert member.display_name(who) == expected
  })
}

/// The member's permissions are channel-scoped and only an interaction sends
/// them. A malformed one must fail rather than decode as empty.
pub fn a_malformed_permission_field_fails_test() {
  let assert Error(_) = parse("{\"roles\":[],\"permissions\":\"not a number\"}")
  let assert Error(_) = parse("{\"roles\":[],\"permissions\":104324673}")
}

pub fn a_timeout_expiry_is_the_string_discord_sent_test() {
  let assert Ok(muted) =
    parse(
      "{\"roles\":[],\"communication_disabled_until\":\"2099-01-01T00:00:00+00:00\"}",
    )
  assert muted.communication_disabled_until == Some("2099-01-01T00:00:00+00:00")

  let assert Ok(free) =
    parse("{\"roles\":[],\"communication_disabled_until\":null}")
  assert free.communication_disabled_until == None
}
