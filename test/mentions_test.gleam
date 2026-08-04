import gleam/dynamic/decode
import gleam/json
import gleam/list
import glyde/id
import glyde/mentions

fn encode(value: mentions.AllowedMentions) -> String {
  json.to_string(mentions.to_json(value))
}

/// Omitting `parse` asks for Discord's default, which pings every mention in
/// the content, so the empty array has to be written.
pub fn none_sends_an_empty_parse_array_test() {
  assert encode(mentions.none()) == "{\"parse\":[],\"replied_user\":false}"
}

/// The exact inverse of `none()`, reply ping included: with no field at all
/// Discord pings the author of a replied-to message.
pub fn all_names_every_kind_test() {
  assert encode(mentions.all())
    == "{\"parse\":[\"users\",\"roles\",\"everyone\"],\"replied_user\":true}"
}

pub fn only_lists_the_ids_and_parses_nothing_test() {
  let value =
    mentions.only(users: [id.from_string("1")], roles: [id.from_string("2")])

  assert encode(value)
    == "{\"parse\":[],\"roles\":[\"2\"],\"users\":[\"1\"],\"replied_user\":false}"
}

pub fn everyone_plus_keeps_everyone_alongside_the_ids_test() {
  let value = mentions.everyone_plus(users: [id.from_string("1")], roles: [])

  assert encode(value)
    == "{\"parse\":[\"everyone\"],\"users\":[\"1\"],\"replied_user\":false}"
}

/// An empty list and an omitted key mean the same thing to Discord.
pub fn empty_id_lists_are_omitted_test() {
  assert encode(mentions.only(users: [], roles: []))
    == "{\"parse\":[],\"replied_user\":false}"
}

pub fn ping_reply_is_independent_of_parse_test() {
  assert encode(mentions.ping_reply(mentions.none(), True))
    == "{\"parse\":[],\"replied_user\":true}"

  assert encode(mentions.ping_reply(mentions.all(), False))
    == "{\"parse\":[\"users\",\"roles\",\"everyone\"],\"replied_user\":false}"
}

pub fn ping_reply_is_idempotent_test() {
  let once = mentions.ping_reply(mentions.none(), True)
  assert encode(mentions.ping_reply(once, True)) == encode(once)
}

type Body {
  Body(parse: List(String), roles: List(String), users: List(String))
}

fn read(value: mentions.AllowedMentions) -> Body {
  let decoder = {
    use parse <- decode.optional_field("parse", [], decode.list(decode.string))
    use roles <- decode.optional_field("roles", [], decode.list(decode.string))
    use users <- decode.optional_field("users", [], decode.list(decode.string))
    decode.success(Body(parse:, roles:, users:))
  }

  let assert Ok(body) = json.parse(encode(value), decoder)
  body
}

/// `{"parse":["users"],"users":["1"]}` is a documented 400, which is why the
/// type is opaque.
pub fn no_constructor_can_pair_a_kind_with_its_id_list_test() {
  let users = [id.from_string("1"), id.from_string("2")]
  let roles = [id.from_string("3")]

  let every_shape = [
    mentions.none(),
    mentions.all(),
    mentions.only(users: users, roles: roles),
    mentions.only(users: users, roles: []),
    mentions.only(users: [], roles: roles),
    mentions.everyone_plus(users: users, roles: roles),
    mentions.everyone_plus(users: [], roles: []),
    mentions.ping_reply(mentions.all(), True),
    mentions.ping_reply(mentions.only(users: users, roles: roles), True),
  ]

  list.each(every_shape, fn(value) {
    let body = read(value)
    assert !{ list.contains(body.parse, "users") && body.users != [] }
    assert !{ list.contains(body.parse, "roles") && body.roles != [] }
  })
}

/// `everyone` is the one parse kind Discord allows beside an id list.
pub fn everyone_may_be_parsed_alongside_an_id_list_test() {
  let body =
    read(mentions.everyone_plus(users: [id.from_string("1")], roles: []))

  assert list.contains(body.parse, "everyone")
  assert body.users == ["1"]
}
