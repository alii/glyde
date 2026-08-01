//// Who a message is allowed to ping.
////
//// Leaving the field off is not neutral: Discord parses and delivers every
//// mention in the content, so a bot echoing user input pings @everyone the
//// moment somebody types it. `none()` is the safe value.
////
//// `parse` and the id lists are mutually exclusive per kind, so
//// `{"parse":["users"],"users":["1"]}` is a 400. Each kind is one three-state
//// value here, so the pair does not exist to be built.

import gleam/json.{type Json}
import gleam/list
import glyde/field.{type Field, Absent, Present}
import glyde/id
import glyde/wire

pub opaque type AllowedMentions {
  AllowedMentions(
    everyone: Bool,
    /// Max 100 ids.
    users: Targets(id.User),
    /// Max 100 ids.
    roles: Targets(id.Role),
    replied_user: Bool,
  )
}

/// What one kind of mention is allowed to reach. Discord takes exactly one of
/// the three: no key, the kind in `parse`, or an id list. Two at once is the
/// 400 this type removes.
type Targets(kind) {
  NoTargets
  AllMentioned
  These(List(id.Id(kind)))
}

/// Send-only, so no unknown tail: a value Discord does not know is a 400.
type MentionKind {
  EveryoneMentions
  RoleMentions
  UserMentions
}

/// Ping nobody. The safe default for anything that echoes user input.
pub fn none() -> AllowedMentions {
  AllowedMentions(
    everyone: False,
    users: NoTargets,
    roles: NoTargets,
    replied_user: False,
  )
}

/// Ping everything the content mentions, as Discord does with no field at all.
/// That includes the author of a replied-to message, which is the one thing an
/// absent field does not leave off. `ping_reply` turns it back down.
pub fn all() -> AllowedMentions {
  AllowedMentions(
    everyone: True,
    users: AllMentioned,
    roles: AllMentioned,
    replied_user: True,
  )
}

/// Ping only these ids, and no @everyone or @here.
pub fn only(
  users users: List(id.UserId),
  roles roles: List(id.RoleId),
) -> AllowedMentions {
  AllowedMentions(
    everyone: False,
    users: These(users),
    roles: These(roles),
    replied_user: False,
  )
}

/// Allow @everyone and @here, plus these ids. A listed user is pinged even if
/// they have muted @everyone.
pub fn everyone_plus(
  users users: List(id.UserId),
  roles roles: List(id.RoleId),
) -> AllowedMentions {
  AllowedMentions(
    everyone: True,
    users: These(users),
    roles: These(roles),
    replied_user: False,
  )
}

/// Independent of the rest: a reply notifies the author even when the content
/// mentions nobody.
pub fn ping_reply(mentions: AllowedMentions, enabled: Bool) -> AllowedMentions {
  AllowedMentions(..mentions, replied_user: enabled)
}

/// The `allowed_mentions` entry for an edit, written only when the edit
/// touches `content` or `components`, which are what Discord re-parses
/// mentions from. Sending it otherwise breaks suppressing embeds on somebody
/// else's message, which Discord refuses it on.
pub fn mention_policy(
  mentions: AllowedMentions,
  content content: Field(a),
  components components: Field(b),
) -> Field(Json) {
  case field.is_absent(content) && field.is_absent(components) {
    True -> Absent
    False -> Present(to_json(mentions))
  }
}

pub fn to_json(mentions: AllowedMentions) -> Json {
  wire.object([
    // Always written: an empty array suppresses everything, so omitting the
    // key would mean the opposite.
    #("parse", Present(json.array(parse(mentions), mention_kind_to_json))),
    #("roles", ids(mentions.roles)),
    #("users", ids(mentions.users)),
    #("replied_user", Present(json.bool(mentions.replied_user))),
  ])
}

/// The kinds Discord should read out of the content. A kind with an id list
/// is never in here, which is the whole rule.
fn parse(mentions: AllowedMentions) -> List(MentionKind) {
  list.flatten([
    parsed(mentions.users, UserMentions),
    parsed(mentions.roles, RoleMentions),
    case mentions.everyone {
      True -> [EveryoneMentions]
      False -> []
    },
  ])
}

fn parsed(targets: Targets(kind), name: MentionKind) -> List(MentionKind) {
  case targets {
    AllMentioned -> [name]
    NoTargets | These(_) -> []
  }
}

fn mention_kind_to_string(kind: MentionKind) -> String {
  case kind {
    EveryoneMentions -> "everyone"
    RoleMentions -> "roles"
    UserMentions -> "users"
  }
}

fn mention_kind_to_json(kind: MentionKind) -> Json {
  json.string(mention_kind_to_string(kind))
}

/// Left out when empty: Discord reads `[]` and a missing key the same way.
fn ids(targets: Targets(kind)) -> Field(Json) {
  case targets {
    NoTargets | AllMentioned | These([]) -> Absent
    These(values) -> Present(json.array(values, id.to_json))
  }
}
