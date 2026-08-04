import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import glyde/gateway/command
import glyde/gateway/frame
import glyde/gateway/presence
import glyde/id

fn guild() -> id.GuildId {
  id.from_string("41771983423143937")
}

fn channel() -> id.ChannelId {
  id.from_string("155101607195836416")
}

fn user() -> id.UserId {
  id.from_string("80351110224678912")
}

/// Every nonce in a test goes through the check, because there is no other way
/// to make one.
fn nonce(text: String) -> option.Option(command.Nonce) {
  let assert Ok(nonce) = command.nonce(text)
  Some(nonce)
}

fn ids(users: List(id.UserId)) -> command.UserIds {
  let assert Ok(users) = command.user_ids(users)
  users
}

/// Same as the nonce: a limit exists only if the check passed.
fn limit(value: Int) -> command.Limit {
  let assert Ok(limit) = command.limit(value)
  limit
}

/// The text a command serialises to. The opcode rides on the `Outbound`
/// beside it, and these tests read it back off the wire form.
fn encoded(wanted: command.Command) -> String {
  frame.outbound_text(command.encode(wanted))
}

/// An op 3 payload with only the activities varying.
fn presenting(activities: String) -> String {
  "{\"op\":3,\"d\":{\"since\":null,\"activities\":["
  <> activities
  <> "],\"status\":\"online\",\"afk\":false}}"
}

fn with_activity(activity: presence.Activity) -> String {
  encoded(
    command.UpdatePresence(presence.Presence(
      status: presence.Online,
      activities: [activity],
      afk: False,
    )),
  )
}

// Update Presence, op 3

pub fn a_bare_status_encodes_test() {
  assert encoded(command.UpdatePresence(presence.new(presence.Online)))
    == presenting("")
}

pub fn presence_defaults_to_nothing_happening_test() {
  assert presence.new(presence.Idle(None))
    == presence.Presence(
      status: presence.Idle(None),
      activities: [],
      afk: False,
    )
}

/// Discord's five status strings. `dnd` is the one nobody guesses.
pub fn the_status_strings_test() {
  let table = [
    #(presence.Online, "online"),
    #(presence.Idle(None), "idle"),
    #(presence.DoNotDisturb, "dnd"),
    #(presence.Invisible, "invisible"),
    #(presence.Offline, "offline"),
  ]
  list.each(table, fn(row) {
    let #(status, wire) = row
    assert encoded(command.UpdatePresence(presence.new(status)))
      == "{\"op\":3,\"d\":{\"since\":null,\"activities\":[],\"status\":\""
      <> wire
      <> "\",\"afk\":false}}"
  })
}

/// Discord's numbers, and 4 sits out of order between Watching and Competing.
pub fn the_activity_types_test() {
  let table = [
    #(presence.Playing("a game"), "{\"name\":\"a game\",\"type\":0}"),
    #(
      presence.Streaming("a stream", "https://twitch.tv/glyde"),
      "{\"name\":\"a stream\",\"type\":1,\"url\":\"https://twitch.tv/glyde\"}",
    ),
    #(presence.Listening("a song"), "{\"name\":\"a song\",\"type\":2}"),
    #(presence.Watching("a film"), "{\"name\":\"a film\",\"type\":3}"),
    #(presence.Competing("a race"), "{\"name\":\"a race\",\"type\":5}"),
    #(
      presence.CustomStatus("out to lunch"),
      "{\"name\":\"Custom Status\",\"type\":4,\"state\":\"out to lunch\"}",
    ),
  ]
  list.each(table, fn(row) {
    let #(activity, encoded) = row
    assert with_activity(activity) == presenting(encoded)
  })
}

/// Discord rejects the payload if an unused activity field is sent as null.
pub fn unset_activity_fields_vanish_test() {
  assert with_activity(presence.Playing("a game"))
    == presenting("{\"name\":\"a game\",\"type\":0}")
}

/// Type 4 shows `state` and needs a `name` it never displays.
pub fn a_custom_status_carries_its_text_in_state_test() {
  assert with_activity(presence.CustomStatus("out to lunch"))
    == presenting(
      "{\"name\":\"Custom Status\",\"type\":4,\"state\":\"out to lunch\"}",
    )
}

pub fn several_activities_keep_their_order_test() {
  assert encoded(
      command.UpdatePresence(presence.Presence(
        status: presence.Online,
        activities: [presence.Playing("first"), presence.Watching("second")],
        afk: False,
      )),
    )
    == presenting(
      "{\"name\":\"first\",\"type\":0},{\"name\":\"second\",\"type\":3}",
    )
}

/// `since` is milliseconds, and only an idle client has one to send.
pub fn since_is_a_millisecond_timestamp_test() {
  assert encoded(
      command.UpdatePresence(presence.Presence(
        status: presence.Idle(since: Some(1_726_000_000_123)),
        activities: [],
        afk: True,
      )),
    )
    == "{\"op\":3,\"d\":{\"since\":1726000000123,\"activities\":[],\"status\":\"idle\",\"afk\":true}}"
}

/// The key is on the wire whatever the status is. Which statuses may fill it
/// is the type's job now: only `Idle` has a `since` to give.
pub fn the_since_key_is_always_sent_test() {
  let table = [
    presence.Online,
    presence.Idle(None),
    presence.DoNotDisturb,
    presence.Invisible,
    presence.Offline,
  ]
  list.each(table, fn(status) {
    assert string.contains(
      encoded(command.UpdatePresence(presence.new(status))),
      "\"since\":null",
    )
  })
}

/// IDENTIFY's `presence` field is this same object, through the same encoder.
pub fn the_presence_encoder_is_shared_with_identify_test() {
  let shown =
    presence.Presence(
      status: presence.DoNotDisturb,
      activities: [presence.Listening("the radio")],
      afk: False,
    )
  assert encoded(command.UpdatePresence(shown))
    == "{\"op\":3,\"d\":" <> json.to_string(presence.to_json(shown)) <> "}"
}

// Update Voice State, op 4

pub fn joining_a_voice_channel_test() {
  assert encoded(command.UpdateVoiceState(
      guild: guild(),
      channel: Some(channel()),
      self_mute: False,
      self_deaf: True,
    ))
    == "{\"op\":4,\"d\":{\"guild_id\":\"41771983423143937\",\"channel_id\":\"155101607195836416\",\"self_mute\":false,\"self_deaf\":true}}"
}

/// A null channel is the disconnect; omitting the key leaves things alone.
pub fn a_null_channel_is_the_disconnect_test() {
  assert encoded(command.UpdateVoiceState(
      guild: guild(),
      channel: None,
      self_mute: False,
      self_deaf: False,
    ))
    == "{\"op\":4,\"d\":{\"guild_id\":\"41771983423143937\",\"channel_id\":null,\"self_mute\":false,\"self_deaf\":false}}"
}

// Request Guild Members, op 8

/// The whole member list is its own request, and it is the only one that puts
/// an empty query and a limit of 0 on the wire.
pub fn requesting_every_member_test() {
  assert encoded(command.RequestGuildMembers(
      guild: guild(),
      nonce: None,
      select: command.All,
    ))
    == "{\"op\":8,\"d\":{\"guild_id\":\"41771983423143937\",\"query\":\"\",\"limit\":0}}"
}

pub fn requesting_members_by_prefix_test() {
  assert encoded(command.RequestGuildMembers(
      guild: guild(),
      nonce: nonce("page-1"),
      select: command.ByPrefix(prefix: "al", limit: limit(10)),
    ))
    == "{\"op\":8,\"d\":{\"guild_id\":\"41771983423143937\",\"query\":\"al\",\"limit\":10,\"nonce\":\"page-1\"}}"
}

/// Discord accepts a bare snowflake too, and one shape is enough.
pub fn requesting_one_member_by_id_test() {
  assert encoded(command.RequestGuildMembers(
      guild: guild(),
      nonce: None,
      select: command.ByIds(users: ids([user()])),
    ))
    == "{\"op\":8,\"d\":{\"guild_id\":\"41771983423143937\",\"user_ids\":[\"80351110224678912\"],\"limit\":0}}"
}

pub fn requesting_several_members_by_id_test() {
  assert encoded(command.RequestGuildMembers(
      guild: guild(),
      nonce: nonce("chunk-7"),
      select: command.ByIds(
        users: ids([user(), id.from_string("53908099506183680")]),
      ),
    ))
    == "{\"op\":8,\"d\":{\"guild_id\":\"41771983423143937\",\"user_ids\":[\"80351110224678912\",\"53908099506183680\"],\"limit\":0,\"nonce\":\"chunk-7\"}}"
}

/// An empty list asks for nobody, and glyde does not invent one.
pub fn an_empty_id_list_stays_empty_test() {
  assert encoded(command.RequestGuildMembers(
      guild: guild(),
      nonce: None,
      select: command.ByIds(users: ids([])),
    ))
    == "{\"op\":8,\"d\":{\"guild_id\":\"41771983423143937\",\"user_ids\":[],\"limit\":0}}"
}

/// Discord answers a null nonce with a 4002 close.
pub fn an_unset_nonce_is_left_out_test() {
  let table = [
    command.All,
    command.ByPrefix(prefix: "a", limit: limit(1)),
    command.ByIds(users: ids([user()])),
  ]
  list.each(table, fn(select) {
    let encoded =
      encoded(command.RequestGuildMembers(guild: guild(), nonce: None, select:))
    assert !string.contains(encoded, "nonce")
  })
}

// Bytes

/// An unescaped quote inside user text would break the frame.
pub fn quotes_in_user_text_are_escaped_test() {
  assert encoded(command.RequestGuildMembers(
      guild: guild(),
      nonce: None,
      select: command.ByPrefix(prefix: "a\"b\\c\nd", limit: limit(1)),
    ))
    == "{\"op\":8,\"d\":{\"guild_id\":\"41771983423143937\",\"query\":\"a\\\"b\\\\c\\nd\",\"limit\":1}}"
}

// Bounds

/// Over 32 bytes Discord drops the nonce and answers the chunks without one,
/// so the request can never be matched to its answer. Refused, not truncated.
pub fn a_nonce_is_capped_at_32_bytes_test() {
  let assert Ok(_) = command.nonce(string.repeat("a", 32))
  assert command.nonce(string.repeat("a", 33))
    == Error(command.NonceTooLong(bytes: 33))
}

/// Discord counts bytes, so 17 two-byte characters are over a limit 17
/// characters are not.
pub fn the_nonce_bound_counts_bytes_test() {
  let assert Ok(_) = command.nonce(string.repeat("é", 16))
  assert command.nonce(string.repeat("é", 17))
    == Error(command.NonceTooLong(bytes: 34))
}

/// 100 ids is Discord's cap on one request. A host with more has to chunk.
pub fn a_request_names_at_most_100_ids_test() {
  let assert Ok(_) = command.user_ids(list.repeat(user(), 100))
  assert command.user_ids(list.repeat(user(), 101))
    == Error(command.TooManyUsers(count: 101))
}

/// A prefix search starts at 1: the 0 that Discord reads as "every member" is
/// `All`, and a search for nothing is a request nobody meant to send.
pub fn a_prefix_search_asks_for_at_least_one_member_test() {
  let assert Ok(_) = command.limit(1)
  assert command.limit(0) == Error(command.LimitTooSmall(value: 0))
  assert command.limit(-1) == Error(command.LimitTooSmall(value: -1))
}

/// Discord answers a prefix search with 100 matches at most, and says nothing
/// about the ones it left out. Refused here rather than quietly truncated.
pub fn a_prefix_search_stops_at_100_members_test() {
  let assert Ok(_) = command.limit(100)
  assert command.limit(101) == Error(command.LimitTooLarge(value: 101))
}

/// Discord counts a nonce in bytes and silently drops one over 32, so the
/// encoder has to put the bytes on the wire unchanged.
pub fn a_multibyte_nonce_survives_encoding_test() {
  let encoded =
    encoded(command.RequestGuildMembers(
      guild: guild(),
      nonce: nonce("café"),
      select: command.ByIds(users: ids([user()])),
    ))
  assert string.contains(encoded, "\"nonce\":\"café\"")
}

/// A chunk echoes the nonce as a plain string, so the opaque one has to come
/// back out for a host to tell which request it is holding the answer to.
pub fn a_nonce_reads_back_as_the_text_it_was_built_from_test() {
  let assert Ok(sent) = command.nonce("chunk-7")
  assert command.nonce_to_string(sent) == "chunk-7"
}
