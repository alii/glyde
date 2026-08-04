import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import glyde/channel
import glyde/field.{Absent, Null, Present}
import glyde/flags
import glyde/id
import glyde/permissions
import glyde/rest/body

fn parse(text: String) -> Result(channel.Channel, json.DecodeError) {
  json.parse(text, channel.decoder())
}

/// Every documented value, one that is not, and the four withdrawn ones cached
/// data can still carry.
pub fn channel_type_round_trips_every_value_test() {
  let known = [
    #(0, channel.GuildText),
    #(1, channel.Dm),
    #(2, channel.GuildVoice),
    #(3, channel.GroupDm),
    #(4, channel.GuildCategory),
    #(5, channel.GuildAnnouncement),
    #(10, channel.AnnouncementThread),
    #(11, channel.PublicThread),
    #(12, channel.PrivateThread),
    #(13, channel.GuildStageVoice),
    #(14, channel.GuildDirectory),
    #(15, channel.GuildForum),
    #(16, channel.GuildMedia),
  ]
  list.each(known, fn(row) {
    let #(wire, variant) = row
    assert channel.channel_type_from_int(wire) == Some(variant)
    assert channel.channel_type_to_int(variant) == wire
  })
}

/// 6 to 9 are withdrawn and 99 is whatever Discord ships next: all `None`.
pub fn unmodelled_channel_types_are_none_test() {
  list.each([6, 7, 8, 9, 17, 99], fn(wire) {
    assert channel.channel_type_from_int(wire) == None
  })
}

pub fn channel_type_encodes_as_its_number_test() {
  assert json.to_string(channel.channel_type_to_json(channel.GuildForum))
    == "15"
}

/// An interaction's partial channel guarantees only these two keys.
pub fn decodes_a_channel_with_only_id_and_type_test() {
  let assert Ok(found) = parse("{\"id\":\"41771983423143937\",\"type\":11}")
  assert id.to_string(found.id) == "41771983423143937"
  assert found.type_ == channel.PublicThread
  assert found.name == None
  assert found.guild_id == None
  assert found.permission_overwrites == None
}

pub fn decodes_a_thread_delete_payload_test() {
  let assert Ok(found) =
    parse("{\"id\":\"3\",\"guild_id\":\"1\",\"parent_id\":\"2\",\"type\":11}")
  assert found.type_ == channel.PublicThread
  assert option.map(found.parent_id, id.to_string) == Some("2")
  assert option.map(found.guild_id, id.to_string) == Some("1")
  assert found.name == None
}

/// A `type` this build has no name for is a glyde bug, so it fails the decode
/// rather than making every caller unwrap.
pub fn an_unmodelled_type_fails_the_decode_test() {
  let assert Error(_) = parse("{\"id\":\"1\",\"type\":99,\"name\":\"lobby\"}")
}

pub fn decodes_a_full_guild_text_channel_test() {
  let assert Ok(found) =
    parse(
      "{\"id\":\"41771983423143937\",\"type\":0,\"guild_id\":\"41771983423143937\",\"position\":6,\"permission_overwrites\":[],\"name\":\"general\",\"topic\":\"24/7 chat\",\"nsfw\":true,\"last_message_id\":\"155117677105512449\",\"rate_limit_per_user\":2,\"parent_id\":\"399942396007890945\",\"last_pin_timestamp\":\"2021-01-01T00:00:00+00:00\",\"flags\":0,\"default_thread_rate_limit_per_user\":10}",
    )
  assert found.type_ == channel.GuildText
  assert found.position == Some(6)
  assert found.permission_overwrites == Some([])
  assert found.name == Some("general")
  assert found.topic == Some("24/7 chat")
  assert found.nsfw == Some(True)
  assert option.map(found.last_message_id, id.to_string)
    == Some("155117677105512449")
  assert found.rate_limit_per_user == Some(2)
  assert found.default_thread_rate_limit_per_user == Some(10)
  assert found.last_pin_timestamp == Some("2021-01-01T00:00:00+00:00")
}

/// Discord nulls these on partial objects rather than omitting them.
pub fn nullable_fields_decode_as_none_test() {
  let assert Ok(nulled) =
    parse(
      "{\"id\":\"1\",\"type\":0,\"name\":null,\"topic\":null,\"last_message_id\":null,\"parent_id\":null,\"last_pin_timestamp\":null,\"rtc_region\":null,\"icon\":null}",
    )
  let assert Ok(absent) = parse("{\"id\":\"1\",\"type\":0}")
  assert nulled.name == absent.name
  assert nulled.topic == absent.topic
  assert nulled.last_message_id == absent.last_message_id
  assert nulled.parent_id == absent.parent_id
  assert nulled.last_pin_timestamp == absent.last_pin_timestamp
  assert nulled.rtc_region == absent.rtc_region
  assert nulled.icon == absent.icon
}

/// Discord writes the same integer field as `2` and as `2.0`.
pub fn whole_numbers_written_as_floats_decode_test() {
  let assert Ok(found) =
    parse(
      "{\"id\":\"1\",\"type\":2.0,\"position\":6.0,\"bitrate\":64000.0,\"user_limit\":0.0,\"rate_limit_per_user\":0.0,\"message_count\":3.0,\"member_count\":2.0,\"total_message_sent\":9.0,\"flags\":2.0}",
    )
  assert found.type_ == channel.GuildVoice
  assert found.position == Some(6)
  assert found.bitrate == Some(64_000)
  assert found.user_limit == Some(0)
  assert found.message_count == Some(3)
  assert found.member_count == Some(2)
  assert found.total_message_sent == Some(9)
  let assert Some(flags) = found.flags
  assert flags.to_int(flags) == 2
}

pub fn decodes_a_voice_channel_test() {
  let assert Ok(found) =
    parse(
      "{\"id\":\"155101607195836416\",\"type\":2,\"guild_id\":\"41771983423143937\",\"name\":\"ROCKET CHEESE\",\"bitrate\":64000,\"user_limit\":0,\"rtc_region\":null,\"video_quality_mode\":2}",
    )
  assert found.type_ == channel.GuildVoice
  assert found.bitrate == Some(64_000)
  // 0 is Discord's "no limit", not "nobody may join".
  assert found.user_limit == Some(0)
  // Null means Discord picks the region, so it reads the same as absent.
  assert found.rtc_region == None
  assert found.video_quality_mode == Some(channel.FullQuality)
}

pub fn decodes_a_group_dm_test() {
  let assert Ok(found) =
    parse(
      "{\"id\":\"319674150115710528\",\"type\":3,\"name\":\"Some test channel\",\"icon\":null,\"owner_id\":\"82198810841029120\",\"application_id\":\"82198898841029120\",\"managed\":true,\"recipients\":[{\"id\":\"82198898848560232\",\"username\":\"test\"}]}",
    )
  assert channel.is_dm(found.type_) == True
  assert option.map(found.owner_id, id.to_string) == Some("82198810841029120")
  assert found.managed == Some(True)
  let assert Some([who]) = found.recipients
  assert who.username == "test"
}

pub fn decodes_a_thread_with_its_metadata_test() {
  let assert Ok(found) =
    parse(
      "{\"id\":\"41771983423143937\",\"type\":11,\"guild_id\":\"41771983423143937\",\"parent_id\":\"41771983423143937\",\"owner_id\":\"41771983423143937\",\"name\":\"don't buy dota-2\",\"message_count\":1,\"member_count\":5,\"total_message_sent\":1,\"rate_limit_per_user\":2,\"thread_metadata\":{\"archived\":false,\"auto_archive_duration\":1440,\"archive_timestamp\":\"2021-04-12T23:40:39.855793+00:00\",\"locked\":false},\"newly_created\":true}",
    )
  assert channel.is_thread(found.type_) == True
  let assert Some(meta) = found.thread_metadata
  assert meta.archived == False
  assert meta.auto_archive_duration == channel.OneDay
  assert meta.archive_timestamp == "2021-04-12T23:40:39.855793+00:00"
  assert meta.locked == False
  assert meta.invitable == None
  assert meta.create_timestamp == None
  assert found.newly_created == Some(True)
  assert found.member_count == Some(5)
}

/// The `member` inside a channel has no `id` and no `user_id`.
pub fn decodes_the_reduced_thread_member_on_a_channel_test() {
  let assert Ok(found) =
    parse(
      "{\"id\":\"1\",\"type\":12,\"member\":{\"flags\":1,\"join_timestamp\":\"2021-04-12T23:40:39.855793+00:00\"}}",
    )
  let assert Some(membership) = found.member
  assert membership.id == None
  assert membership.user_id == None
  assert membership.flags == 1
  assert membership.join_timestamp == "2021-04-12T23:40:39.855793+00:00"
  assert membership.member == None
}

/// The standalone object has both ids; `with_member=true` adds the member.
pub fn decodes_a_standalone_thread_member_test() {
  let assert Ok(membership) =
    json.parse(
      "{\"id\":\"3\",\"user_id\":\"4\",\"join_timestamp\":\"2021-04-12T23:40:39.855793+00:00\",\"flags\":0,\"member\":{\"roles\":[\"5\"],\"joined_at\":\"2020-01-01T00:00:00+00:00\",\"user\":{\"id\":\"4\",\"username\":\"nelly\"}}}",
      channel.thread_member_decoder(),
    )
  assert option.map(membership.id, id.to_string) == Some("3")
  assert option.map(membership.user_id, id.to_string) == Some("4")
  let assert Some(guild_member) = membership.member
  let assert Some(account) = guild_member.user
  assert account.username == "nelly"
}

/// The durations are minute values, not indexes: an index sends 3 for 10080.
pub fn auto_archive_duration_is_a_minute_value_test() {
  let known = [
    #(60, channel.OneHour),
    #(1440, channel.OneDay),
    #(4320, channel.ThreeDays),
    #(10_080, channel.OneWeek),
  ]
  list.each(known, fn(row) {
    let #(minutes, variant) = row
    assert channel.auto_archive_duration_from_int(minutes) == Some(variant)
    assert channel.auto_archive_duration_to_int(variant) == minutes
  })
  // An ordinal would decode to the named variants. It must not.
  list.each([0, 1, 2, 3], fn(ordinal) {
    assert channel.auto_archive_duration_from_int(ordinal) == None
  })
}

/// Discord always sends `auto_archive_duration` on thread metadata, so an
/// unmodelled value is a glyde bug.
pub fn thread_metadata_rejects_unmodelled_duration_test() {
  let assert Error(_) =
    json.parse(
      "{\"archived\":false,\"auto_archive_duration\":9999,\"archive_timestamp\":\"2021-01-01T00:00:00+00:00\",\"locked\":false}",
      channel.thread_metadata_decoder(),
    )
  let assert Error(_) =
    json.parse(
      "{\"archive_timestamp\":\"2021-01-01T00:00:00+00:00\"}",
      channel.thread_metadata_decoder(),
    )
}

pub fn decodes_permission_overwrites_test() {
  let assert Ok(found) =
    parse(
      "{\"id\":\"1\",\"type\":0,\"permission_overwrites\":[{\"id\":\"41771983423143936\",\"type\":0,\"allow\":\"1024\",\"deny\":\"2048\"},{\"id\":\"80351110224678912\",\"type\":1,\"allow\":\"0\",\"deny\":\"0\"}]}",
    )
  let assert Some([role_rule, member_rule]) = found.permission_overwrites
  assert role_rule.type_ == channel.RoleOverwrite
  // An overwrite's allow and deny are not resolved sets, so `contains` is
  // the question, not `allows`.
  assert permissions.contains(role_rule.allow, permissions.ViewChannel) == True
  assert permissions.contains(role_rule.deny, permissions.SendMessages) == True
  assert member_rule.type_ == channel.MemberOverwrite
}

/// The overwrite `id` is a role id or a user id, and only `type_` says which.
pub fn overwrite_accessors_answer_for_one_type_only_test() {
  let role_rule =
    channel.PermissionOverwrite(
      id: id.from_string("1"),
      type_: channel.RoleOverwrite,
      allow: permissions.none(),
      deny: permissions.none(),
    )
  let member_rule =
    channel.PermissionOverwrite(..role_rule, type_: channel.MemberOverwrite)

  assert channel.overwrite_target(role_rule)
    == channel.RoleTarget(id.from_string("1"))
  assert channel.overwrite_target(member_rule)
    == channel.MemberTarget(id.from_string("1"))
}

/// One overwrite whose type this build has no name for is dropped, and the
/// known one beside it survives.
pub fn an_unmodelled_overwrite_type_is_filtered_test() {
  let assert Ok(found) =
    parse(
      "{\"id\":\"1\",\"type\":0,\"permission_overwrites\":[{\"id\":\"9\",\"type\":9,\"allow\":\"0\",\"deny\":\"0\"},{\"id\":\"7\",\"type\":0,\"allow\":\"0\",\"deny\":\"0\"}]}",
    )
  let assert Some([kept]) = found.permission_overwrites
  assert kept.type_ == channel.RoleOverwrite
  assert id.to_string(kept.id) == "7"
}

pub fn overwrite_round_trips_through_json_test() {
  let text =
    "{\"id\":\"41771983423143936\",\"type\":0,\"allow\":\"1024\",\"deny\":\"2048\"}"
  let assert Ok(Some(overwrite)) =
    json.parse(text, channel.permission_overwrite_decoder())
  // The send path, not a bespoke encoder: what Discord sent must go back out
  // through the same shape a caller edits and resends.
  let body = channel.overwrite_from(overwrite)
  assert json.to_string(channel.overwrite_body_to_json(body)) == text
}

pub fn overwrite_type_round_trips_test() {
  assert channel.overwrite_type_from_int(0) == Some(channel.RoleOverwrite)
  assert channel.overwrite_type_from_int(1) == Some(channel.MemberOverwrite)
  assert channel.overwrite_type_from_int(7) == None
}

pub fn video_quality_mode_round_trips_test() {
  assert channel.video_quality_mode_from_int(1) == Some(channel.AutoQuality)
  assert channel.video_quality_mode_from_int(2) == Some(channel.FullQuality)
  assert channel.video_quality_mode_from_int(3) == None
  // 0 is not a mode Discord defines, so it must not fold into Auto.
  assert channel.video_quality_mode_from_int(0) == None
}

/// `app_permissions` belongs to the interaction, not to a channel inside it,
/// so the channel only ever carries the invoking user's `permissions`.
pub fn interaction_resolved_permissions_decode_test() {
  let assert Ok(found) =
    parse(
      "{\"id\":\"1\",\"type\":0,\"permissions\":\"1024\",\"app_permissions\":\"2048\"}",
    )
  let assert Some(theirs) = found.permissions
  assert permissions.to_string(permissions.raw(theirs)) == "1024"
}

pub fn channel_flags_test() {
  let flags = flags.from_int(2)
  assert channel.has_flag(flags, channel.Pinned) == True
  assert channel.has_flag(flags, channel.RequireTag) == False
  assert channel.has_flag(flags.from_int(16), channel.RequireTag) == True
  assert channel.has_flag(
      flags.from_int(32_768),
      channel.HideMediaDownloadOptions,
    )
    == True
  assert channel.has_flag(flags.from_int(2_097_152), channel.IsSpoilerChannel)
    == True
}

/// An interaction's partial channel carries no `flags`, and that is not the
/// same as every flag off: echoing a 0 back on an edit clears the lot.
pub fn absent_flags_stay_unknown_test() {
  let assert Ok(found) = parse("{\"id\":\"1\",\"type\":0}")
  assert found.flags == None

  let assert Ok(off) = parse("{\"id\":\"1\",\"type\":0,\"flags\":0}")
  assert off.flags == Some(channel.no_channel_flags)

  let assert Ok(pinned) = parse("{\"id\":\"1\",\"type\":15,\"flags\":2}")
  let assert Some(flags) = pinned.flags
  assert channel.has_flag(flags, channel.Pinned) == True
}

pub fn channel_flags_are_buildable_test() {
  let both = channel.channel_flags(of: [channel.Pinned, channel.RequireTag])
  assert flags.to_int(both) == 18
  assert flags.to_int(channel.channel_flags(of: [])) == 0

  let dropped = channel.without_flag(both, channel.Pinned)
  assert flags.to_int(dropped) == 16
  // Removing a flag that was never set leaves the bits alone.
  assert channel.without_flag(dropped, channel.Pinned) == dropped

  let added = channel.with_flag(dropped, channel.IsSpoilerChannel)
  assert flags.to_int(added) == 2_097_168
  // Setting a flag twice is not the same as toggling it off.
  assert channel.with_flag(added, channel.IsSpoilerChannel) == added
}

/// Discord asks for every previously set bit to be sent back on an edit.
pub fn unknown_flag_bits_survive_a_round_trip_test() {
  let flags = flags.from_int(2 + 1_073_741_824)
  assert channel.has_flag(flags, channel.Pinned) == True
  assert flags.to_int(flags) == 1_073_741_826
  assert json.to_string(flags.to_json(flags)) == "1073741826"
}

pub fn predicates_test() {
  let of = fn(type_) {
    let assert Ok(found) =
      parse("{\"id\":\"1\",\"type\":" <> int.to_string(type_) <> "}")
    found
  }
  let threads = [10, 11, 12]
  let dms = [1, 3]
  let textable = [0, 1, 2, 3, 5, 10, 11, 12, 13]
  let voice = [2, 13]
  let thread_only = [15, 16]
  let every = [0, 1, 2, 3, 4, 5, 10, 11, 12, 13, 14, 15, 16]

  list.each(every, fn(type_) {
    let found = of(type_)
    assert channel.is_thread(found.type_) == list.contains(threads, type_)
    assert channel.is_dm(found.type_) == list.contains(dms, type_)
    assert channel.is_textable(found.type_) == list.contains(textable, type_)
    assert channel.is_voice(found.type_) == list.contains(voice, type_)
    assert channel.is_thread_only(found.type_)
      == list.contains(thread_only, type_)
  })
}

/// Forum and media channels hold posts, and sending a message to one is a 400.
pub fn forum_and_media_are_not_textable_test() {
  let assert Ok(forum) = parse("{\"id\":\"1\",\"type\":15}")
  let assert Ok(media) = parse("{\"id\":\"1\",\"type\":16}")
  assert channel.is_textable(forum.type_) == False
  assert channel.is_textable(media.type_) == False
  assert channel.is_thread_only(forum.type_) == True
  assert channel.is_thread_only(media.type_) == True
}

/// The archived listings page, so `has_more` answers whether to ask again.
/// Discord omits the key on the last page, which is the same as false.
pub fn thread_list_decodes_has_more_test() {
  let assert Ok(archived) =
    json.parse(
      "{\"threads\":[{\"id\":\"1\",\"type\":11}],\"members\":[{\"id\":\"1\",\"user_id\":\"2\",\"join_timestamp\":\"2021-01-01T00:00:00+00:00\",\"flags\":0}],\"has_more\":true}",
      channel.thread_list_decoder(),
    )
  assert list.length(archived.threads) == 1
  assert list.length(archived.members) == 1
  assert archived.has_more == True

  let assert Ok(last) =
    json.parse("{\"threads\":[],\"members\":[]}", channel.thread_list_decoder())
  assert last.has_more == False
}

/// `GET /guilds/{id}/threads/active` is the whole list, so its answer has no
/// `has_more` field to read as "there is more".
pub fn active_threads_have_no_page_test() {
  let assert Ok(active) =
    json.parse(
      "{\"threads\":[{\"id\":\"1\",\"type\":11}],\"members\":[]}",
      channel.active_threads_decoder(),
    )
  assert list.length(active.threads) == 1
  assert active.members == []
}

/// Discord sends `"threads": null` on some empty listings.
pub fn thread_list_tolerates_nulls_test() {
  let assert Ok(empty) =
    json.parse(
      "{\"threads\":null,\"members\":null}",
      channel.thread_list_decoder(),
    )
  assert empty.threads == []
  assert empty.members == []
  assert empty.has_more == False
}

pub fn a_channel_without_an_id_or_type_fails_test() {
  let assert Error(_) = parse("{\"type\":0}")
  // `type` is required too.
  let assert Error(_) = parse("{\"id\":\"1\"}")
  // Discord sends snowflakes as strings, and a JSON number is not one.
  let assert Error(_) = parse("{\"id\":41771983423143937,\"type\":0}")
}

/// What these tests pin is the JSON document the body carries.
fn payload_json(sent: body.Body) -> String {
  let assert body.Form(payload:, files: _) = sent
  json.to_string(json.object(payload))
}

fn created(value: channel.CreateChannel) -> String {
  payload_json(channel.create_channel_body(value))
}

fn edited(value: channel.EditGuildChannel) -> String {
  payload_json(channel.edit_guild_channel_body(value))
}

fn thread_edited(value: channel.EditThread) -> String {
  payload_json(channel.edit_thread_body(value))
}

/// Discord reads the subject from `type` alone, so a mismatch grants
/// permissions to the wrong subject rather than failing.
pub fn an_overwrite_names_its_own_type_test() {
  assert json.to_string(
      channel.overwrite_body_to_json(
        channel.role_overwrite(id.from_string("1")),
      ),
    )
    == "{\"id\":\"1\",\"type\":0,\"allow\":\"0\",\"deny\":\"0\"}"

  assert json.to_string(
      channel.overwrite_body_to_json(
        channel.member_overwrite(id.from_string("2")),
      ),
    )
    == "{\"id\":\"2\",\"type\":1,\"allow\":\"0\",\"deny\":\"0\"}"
}

/// Discord sends and takes permission bitfields as decimal strings.
pub fn overwrite_permissions_go_out_as_strings_test() {
  let body =
    channel.role_overwrite(id.from_string("1"))
    |> channel.allowing(permissions.new([permissions.SendMessages]))
    |> channel.denying(permissions.new([permissions.ViewChannel]))

  assert json.to_string(channel.overwrite_body_to_json(body))
    == "{\"id\":\"1\",\"type\":0,\"allow\":\"2048\",\"deny\":\"1024\"}"
}

/// A missing bitfield reads as "0", so both are always written and the
/// default is the same value Discord would have used.
pub fn an_untouched_overwrite_grants_and_denies_nothing_test() {
  assert json.to_string(
      channel.overwrite_body_to_json(
        channel.member_overwrite(id.from_string("7")),
      ),
    )
    == "{\"id\":\"7\",\"type\":1,\"allow\":\"0\",\"deny\":\"0\"}"
}

pub fn a_create_needs_only_a_name_test() {
  assert created(channel.create_channel("general")) == "{\"name\":\"general\"}"
}

pub fn a_create_writes_only_what_was_set_test() {
  let body =
    channel.CreateChannel(
      ..channel.create_channel("voice"),
      type_: Some(channel.VoiceChannel),
      bitrate: Some(64_000),
      user_limit: Some(10),
      parent_id: Some(id.from_string("5")),
      nsfw: Some(False),
    )

  assert created(body)
    == "{\"name\":\"voice\",\"type\":2,\"bitrate\":64000,\"user_limit\":10,"
    <> "\"parent_id\":\"5\",\"nsfw\":false}"
}

/// The seven kinds `POST /guilds/{g}/channels` takes, and their wire numbers.
pub fn every_creatable_type_keeps_discords_number_test() {
  let cases = [
    #(channel.TextChannel, 0),
    #(channel.VoiceChannel, 2),
    #(channel.CategoryChannel, 4),
    #(channel.AnnouncementChannel, 5),
    #(channel.StageChannel, 13),
    #(channel.ForumChannel, 15),
    #(channel.MediaChannel, 16),
  ]

  list.each(cases, fn(row) {
    let #(kind, number) = row
    let body =
      channel.CreateChannel(..channel.create_channel("c"), type_: Some(kind))

    assert created(body)
      == "{\"name\":\"c\",\"type\":" <> json.to_string(json.int(number)) <> "}"
  })
}

pub fn a_create_carries_its_overwrites_test() {
  let body =
    channel.CreateChannel(
      ..channel.create_channel("private"),
      permission_overwrites: Some([channel.role_overwrite(id.from_string("1"))]),
    )

  assert created(body)
    == "{\"name\":\"private\",\"permission_overwrites\":"
    <> "[{\"id\":\"1\",\"type\":0,\"allow\":\"0\",\"deny\":\"0\"}]}"
}

/// The wire values are the minute counts themselves; an index earns a 400.
pub fn auto_archive_durations_are_minute_counts_test() {
  let cases = [
    #(channel.OneHour, 60),
    #(channel.OneDay, 1440),
    #(channel.ThreeDays, 4320),
    #(channel.OneWeek, 10_080),
  ]

  list.each(cases, fn(row) {
    let #(duration, minutes) = row
    let body =
      channel.CreateChannel(
        ..channel.create_channel("forum"),
        default_auto_archive_duration: Some(duration),
      )

    assert created(body)
      == "{\"name\":\"forum\",\"default_auto_archive_duration\":"
      <> json.to_string(json.int(minutes))
      <> "}"
  })
}

pub fn video_quality_keeps_discords_numbers_test() {
  let cases = [#(channel.AutoQuality, 1), #(channel.FullQuality, 2)]

  list.each(cases, fn(row) {
    let #(quality, number) = row
    let body =
      channel.CreateChannel(
        ..channel.create_channel("stage"),
        video_quality_mode: Some(quality),
      )

    assert created(body)
      == "{\"name\":\"stage\",\"video_quality_mode\":"
      <> json.to_string(json.int(number))
      <> "}"
  })
}

pub fn settable_flags_keep_discords_bits_test() {
  let cases = [
    #(Some(False), Some(False), 0),
    #(Some(True), None, 16),
    #(None, Some(True), 32_768),
    #(Some(True), Some(True), 32_784),
  ]

  list.each(cases, fn(row) {
    let #(require_tag, hide_media_download_options, bits) = row
    let body =
      channel.CreateChannel(
        ..channel.create_channel("forum"),
        require_tag:,
        hide_media_download_options:,
      )

    assert created(body)
      == "{\"name\":\"forum\",\"flags\":"
      <> json.to_string(json.int(bits))
      <> "}"
  })
}

/// Touching either bit sends the whole bitfield, so a `False` turns the other
/// bit off too.
pub fn a_flag_edit_replaces_the_whole_bitfield_test() {
  let base = channel.edit_guild_channel()

  assert edited(base) == "{}"
  assert edited(channel.EditGuildChannel(..base, require_tag: Some(False)))
    == "{\"flags\":0}"
  assert edited(channel.EditGuildChannel(..base, require_tag: Some(True)))
    == "{\"flags\":16}"
}

pub fn a_thread_pins_and_unpins_through_flags_test() {
  let base = channel.new_edit_thread()

  assert thread_edited(base) == "{}"
  assert thread_edited(channel.EditThread(..base, pinned: Some(True)))
    == "{\"flags\":2}"
  assert thread_edited(channel.EditThread(..base, pinned: Some(False)))
    == "{\"flags\":0}"
}

pub fn an_empty_guild_channel_edit_says_nothing_test() {
  assert edited(channel.edit_guild_channel()) == "{}"
}

pub fn an_empty_thread_edit_says_nothing_test() {
  assert thread_edited(channel.new_edit_thread()) == "{}"
}

/// The only conversion Discord does, and only in a guild with NEWS.
pub fn a_channel_converts_between_text_and_announcement_test() {
  let base = channel.edit_guild_channel()

  assert edited(channel.EditGuildChannel(..base, type_: Some(channel.ToText)))
    == "{\"type\":0}"

  assert edited(
      channel.EditGuildChannel(..base, type_: Some(channel.ToAnnouncement)),
    )
    == "{\"type\":5}"
}

/// `Null` moves the channel to the top level, `Absent` leaves it in its
/// category.
pub fn parent_id_keeps_absent_and_null_apart_test() {
  let base = channel.edit_guild_channel()

  let cases = [
    #(Absent, "{}"),
    #(Null, "{\"parent_id\":null}"),
    #(Present(id.from_string("5")), "{\"parent_id\":\"5\"}"),
  ]

  list.each(cases, fn(row) {
    let #(parent, expected) = row
    assert edited(channel.EditGuildChannel(..base, parent_id: parent))
      == expected
  })
}

/// `Null` and `Present([])` both wipe every overwrite; omitting the key keeps
/// them.
pub fn overwrites_can_be_wiped_or_replaced_test() {
  let base = channel.edit_guild_channel()

  assert edited(channel.EditGuildChannel(..base, permission_overwrites: Null))
    == "{\"permission_overwrites\":null}"

  assert edited(
      channel.EditGuildChannel(..base, permission_overwrites: Present([])),
    )
    == "{\"permission_overwrites\":[]}"

  assert edited(
      channel.EditGuildChannel(
        ..base,
        permission_overwrites: Present([
          channel.member_overwrite(id.from_string("9")),
        ]),
      ),
    )
    == "{\"permission_overwrites\":"
    <> "[{\"id\":\"9\",\"type\":1,\"allow\":\"0\",\"deny\":\"0\"}]}"
}

pub fn clearing_the_region_hands_it_back_to_discord_test() {
  let base = channel.edit_guild_channel()

  assert edited(channel.EditGuildChannel(..base, rtc_region: Null))
    == "{\"rtc_region\":null}"
}

pub fn a_thread_edit_writes_only_thread_fields_test() {
  let body =
    channel.EditThread(
      ..channel.new_edit_thread(),
      name: Some("done"),
      archived: Some(True),
      locked: Some(True),
      rate_limit_per_user: Null,
    )

  assert thread_edited(body)
    == "{\"name\":\"done\",\"archived\":true,\"locked\":true,"
    <> "\"rate_limit_per_user\":null}"
}

/// A PUT replaces the whole overwrite, and the path takes the id the body
/// leaves out, so both come from one value.
pub fn editing_permissions_reuses_the_overwrite_test() {
  let body =
    channel.member_overwrite(id.from_string("42"))
    |> channel.allowing(permissions.new([permissions.ViewChannel]))
    |> channel.denying(permissions.new([permissions.SendMessages]))

  assert payload_json(channel.overwrite_permissions_body(body))
    == "{\"type\":1,\"allow\":\"1024\",\"deny\":\"2048\"}"

  assert channel.overwrite_id(body) == id.from_string("42")
}

/// The array replaces the whole set, so the normal edit reads the channel,
/// changes one entry and sends the rest back as they arrived.
pub fn a_decoded_overwrite_goes_back_out_unchanged_test() {
  let read =
    channel.PermissionOverwrite(
      id: id.from_string("42"),
      type_: channel.MemberOverwrite,
      allow: permissions.new([permissions.ViewChannel]),
      deny: permissions.new([permissions.SendMessages]),
    )

  let body = channel.overwrite_from(read)

  assert json.to_string(channel.overwrite_body_to_json(body))
    == "{\"id\":\"42\",\"type\":1,\"allow\":\"1024\",\"deny\":\"2048\"}"
  assert channel.overwrite_id(body) == id.from_string("42")

  let role =
    channel.overwrite_from(
      channel.PermissionOverwrite(..read, type_: channel.RoleOverwrite),
    )

  assert json.to_string(channel.overwrite_body_to_json(role))
    == "{\"id\":\"42\",\"type\":0,\"allow\":\"1024\",\"deny\":\"2048\"}"
}

/// Discord meters name and topic edits at two per ten minutes and says so in
/// no header, so `api/channel.edit_channel` asks and the payload answers.
pub fn an_edit_knows_whether_it_touches_name_or_topic_test() {
  let base = channel.edit_guild_channel()

  assert !channel.edits_name_or_topic(base)
  assert !channel.edits_name_or_topic(
    channel.EditGuildChannel(..base, nsfw: Present(True)),
  )

  assert channel.edits_name_or_topic(
    channel.EditGuildChannel(..base, name: Some("general")),
  )
  assert channel.edits_name_or_topic(
    channel.EditGuildChannel(..base, topic: Present("ops")),
  )

  // Clearing the topic is still a topic edit.
  assert channel.edits_name_or_topic(
    channel.EditGuildChannel(..base, topic: Null),
  )
}

pub fn editing_permissions_always_states_the_type_test() {
  assert payload_json(
      channel.overwrite_permissions_body(
        channel.role_overwrite(id.from_string("3")),
      ),
    )
    == "{\"type\":0,\"allow\":\"0\",\"deny\":\"0\"}"
}

pub fn a_thread_from_a_message_needs_only_a_name_test() {
  assert payload_json(
      channel.create_thread_from_message_body(
        channel.create_thread_from_message("spin-off"),
      ),
    )
    == "{\"name\":\"spin-off\"}"
}

/// The type is an argument, not an option: Discord's default for an omitted
/// `type` is a private thread today and it has said that will change.
pub fn a_standalone_thread_states_its_type_test() {
  let body =
    channel.CreateThread(
      ..channel.create_thread("standup", channel.AsPublicThread),
      auto_archive_duration: Some(channel.OneDay),
    )

  assert payload_json(channel.create_thread_body(body))
    == "{\"name\":\"standup\",\"type\":11,\"auto_archive_duration\":1440}"
}

pub fn an_invitable_private_thread_test() {
  let body =
    channel.CreateThread(
      ..channel.create_thread("hush", channel.AsPrivateThread),
      invitable: Some(False),
      rate_limit_per_user: Some(30),
    )

  assert payload_json(channel.create_thread_body(body))
    == "{\"name\":\"hush\",\"type\":12,\"invitable\":false,"
    <> "\"rate_limit_per_user\":30}"
}

pub fn an_announcement_thread_test() {
  assert payload_json(
      channel.create_thread_body(channel.create_thread(
        "coverage",
        channel.AsAnnouncementThread,
      )),
    )
    == "{\"name\":\"coverage\",\"type\":10}"
}

/// The two `PATCH /channels/{id}` bodies share a URL and nothing else, so
/// neither encoder can be handed the other's fields.
pub fn the_two_edits_stay_apart_test() {
  let guild =
    channel.EditGuildChannel(
      ..channel.edit_guild_channel(),
      topic: Present("ops"),
    )
  let thread =
    channel.EditThread(..channel.new_edit_thread(), archived: Some(False))

  assert edited(guild) == "{\"topic\":\"ops\"}"
  assert thread_edited(thread) == "{\"archived\":false}"
}
