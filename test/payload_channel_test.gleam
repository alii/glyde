import gleam/json
import gleam/list
import gleam/option.{Some}
import glyde/field.{Absent, Null, Present}
import glyde/id
import glyde/model/channel as model
import glyde/payload/channel
import glyde/permissions
import glyde/rest/body

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
    #([], 0),
    #([channel.RequireTag], 16),
    #([channel.HideMediaDownloadOptions], 32_768),
    #([channel.RequireTag, channel.HideMediaDownloadOptions], 32_784),
  ]

  list.each(cases, fn(row) {
    let #(flags, bits) = row
    let body =
      channel.CreateChannel(
        ..channel.create_channel("forum"),
        flags: Some(flags),
      )

    assert created(body)
      == "{\"name\":\"forum\",\"flags\":"
      <> json.to_string(json.int(bits))
      <> "}"
  })
}

/// The list is the whole bitfield, so dropping a flag turns it off rather than
/// leaving what was already there.
pub fn a_flag_edit_replaces_the_whole_bitfield_test() {
  let base = channel.edit_guild_channel()

  assert edited(base) == "{}"
  assert edited(channel.EditGuildChannel(..base, flags: Some([])))
    == "{\"flags\":0}"
  assert edited(
      channel.EditGuildChannel(..base, flags: Some([channel.RequireTag])),
    )
    == "{\"flags\":16}"
}

pub fn a_thread_pins_and_unpins_through_flags_test() {
  let base = channel.edit_thread()

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
  assert thread_edited(channel.edit_thread()) == "{}"
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
      ..channel.edit_thread(),
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
    model.PermissionOverwrite(
      id: id.from_string("42"),
      type_: model.MemberOverwrite,
      allow: permissions.new([permissions.ViewChannel]),
      deny: permissions.new([permissions.SendMessages]),
    )

  let assert Ok(body) = channel.overwrite_from(read)

  assert json.to_string(channel.overwrite_body_to_json(body))
    == "{\"id\":\"42\",\"type\":1,\"allow\":\"1024\",\"deny\":\"2048\"}"
  assert channel.overwrite_id(body) == id.from_string("42")

  let assert Ok(role) =
    channel.overwrite_from(
      model.PermissionOverwrite(..read, type_: model.RoleOverwrite),
    )

  assert json.to_string(channel.overwrite_body_to_json(role))
    == "{\"id\":\"42\",\"type\":0,\"allow\":\"1024\",\"deny\":\"2048\"}"
}

/// A type added after this build cannot be sent back: Discord reads `type` to
/// decide what the id means, so guessing applies the overwrite to someone.
pub fn an_unknown_overwrite_type_cannot_be_sent_back_test() {
  let read =
    model.PermissionOverwrite(
      id: id.from_string("7"),
      type_: model.UnknownOverwriteType(9),
      allow: permissions.none(),
      deny: permissions.none(),
    )

  assert channel.overwrite_from(read) == Error(9)
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
      ..channel.create_thread("standup", channel.PublicThread),
      auto_archive_duration: Some(channel.OneDay),
    )

  assert payload_json(channel.create_thread_body(body))
    == "{\"name\":\"standup\",\"type\":11,\"auto_archive_duration\":1440}"
}

pub fn an_invitable_private_thread_test() {
  let body =
    channel.CreateThread(
      ..channel.create_thread("hush", channel.PrivateThread),
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
        channel.AnnouncementThread,
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
    channel.EditThread(..channel.edit_thread(), archived: Some(False))

  assert edited(guild) == "{\"topic\":\"ops\"}"
  assert thread_edited(thread) == "{\"archived\":false}"
}
