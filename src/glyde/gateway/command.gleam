//// The gateway commands a host may send.
////
//// IDENTIFY, RESUME and HEARTBEAT live in `glyde/gateway/frame`: a host that
//// sends one by hand can tear down a session the state machine is holding.

import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None}
import gleam/string
import glyde/field.{Absent, Present}
import glyde/gateway/frame
import glyde/gateway/presence.{type Presence}
import glyde/id.{type Id}
import glyde/wire

/// Something to send on the socket. Each variant is exactly one opcode's `d`.
pub type Command {
  /// op 3.
  UpdatePresence(presence: Presence)

  /// op 4. glyde speaks no voice protocol; a third-party voice stack needs it.
  UpdateVoiceState(
    guild: Id(id.Guild),
    /// `None` disconnects from voice in this guild.
    channel: Option(Id(id.Channel)),
    self_mute: Bool,
    self_deaf: Bool,
  )

  /// op 8. Answers arrive as GUILD_MEMBERS_CHUNK dispatches of up to 1000
  /// members each, handed over as they come rather than reassembled.
  RequestGuildMembers(request: MemberRequest)
}

/// Which members to ask for. Discord takes a name prefix, a list of ids, or
/// the whole list, and each of the three is a different set of keys.
///
/// Every variant takes a `nonce`, which comes back on every chunk and is what
/// matches an answer to the request for it. The chunk carries it as a plain
/// string, so compare with `nonce_to_string`.
pub type MemberRequest {
  /// Every member of the guild. This is the one Discord requires the
  /// GUILD_MEMBERS intent for, and that intent is privileged: an app has to be
  /// approved for it before the answer arrives.
  AllMembers(guild: Id(id.Guild), nonce: Option(Nonce))

  /// Members whose name starts with `prefix`, at most `limit` of them.
  ByPrefix(
    guild: Id(id.Guild),
    prefix: String,
    limit: Limit,
    nonce: Option(Nonce),
  )

  /// Specific members, by id, built with `user_ids`.
  ByIds(guild: Id(id.Guild), users: UserIds, nonce: Option(Nonce))
}

/// Discord's cap on the ids one request may name.
const max_user_ids: Int = 100

/// Discord's cap on a nonce, counted in bytes and not characters.
const max_nonce_bytes: Int = 32

/// Discord's floor on a prefix search: a 0 limit there is the "every member"
/// spelling, which is `AllMembers`.
const min_limit: Int = 1

/// Discord's cap on a prefix search: "requesting a prefix will return a
/// maximum of 100 members", whatever the limit asked for. The same number as
/// `max_user_ids` and a different rule: that one bounds the ids named.
const max_limit: Int = 100

/// Why `nonce` refused. Discord's bound, and it fails quietly on the wire,
/// which is why it is checked here.
pub type NonceError {
  /// Over `max_nonce_bytes`. Discord drops a longer nonce and answers the
  /// chunks without one, so nothing can match them to the request again.
  NonceTooLong(bytes: Int)
}

/// Why `user_ids` refused. Discord's bound, and it fails quietly on the wire
/// too.
pub type UserIdsError {
  /// Over `max_user_ids` ids in one request.
  TooManyUsers(count: Int)
}

/// Why `limit` refused. Both bounds are Discord's, and neither comes back as
/// an error: a 0 asks for something else, and a 500 is answered with 100.
pub type LimitError {
  /// Under `min_limit`. A search that may match nothing is not a search, and
  /// the 0 that asks for every member is `AllMembers`.
  LimitTooSmall(value: Int)
  /// Over `max_limit`. Discord stops at 100 matches, so the rest of the
  /// number is members the host would wait for and never be sent.
  LimitTooLarge(value: Int)
}

/// A nonce Discord will echo. Opaque because the 32-byte bound is the whole
/// point: a longer one is not rejected, it is silently dropped.
pub opaque type Nonce {
  Nonce(String)
}

/// The ids one `ByIds` asks about, at most `max_user_ids` of them. Opaque for
/// the same reason as `Nonce`: a host with more has to send more requests, and
/// only the constructor can say so.
pub opaque type UserIds {
  UserIds(List(Id(id.User)))
}

/// How many members a `ByPrefix` may come back with, `min_limit` to
/// `max_limit`. Opaque so the 0 that means "every member" cannot be written as
/// a search, and so a number Discord will not honour cannot be written at all.
pub opaque type Limit {
  Limit(Int)
}

/// Measured in bytes, because that is what Discord counts. A 32-character
/// nonce with an accent in it is over the limit.
pub fn nonce(text: String) -> Result(Nonce, NonceError) {
  let bytes = string.byte_size(text)
  case bytes > max_nonce_bytes {
    True -> Error(NonceTooLong(bytes:))
    False -> Ok(Nonce(text))
  }
}

/// The text back out. A member chunk echoes the nonce as a plain string, so
/// this is how a host matches an answer to the request that asked for it.
pub fn nonce_to_string(nonce: Nonce) -> String {
  let Nonce(text) = nonce
  text
}

/// An empty list asks about nobody. Discord takes it, and glyde does not
/// invent an id to fill it.
pub fn user_ids(users: List(Id(id.User))) -> Result(UserIds, UserIdsError) {
  let count = list.length(users)
  case count > max_user_ids {
    True -> Error(TooManyUsers(count:))
    False -> Ok(UserIds(users))
  }
}

/// 1 to 100. Refused rather than clamped: a host that wanted 500 members has
/// to know it is only getting 100 of them.
pub fn limit(value: Int) -> Result(Limit, LimitError) {
  case value < min_limit, value > max_limit {
    True, _ -> Error(LimitTooSmall(value:))
    False, True -> Error(LimitTooLarge(value:))
    False, False -> Ok(Limit(value))
  }
}

/// Encode to a complete gateway payload.
pub fn encode(command: Command) -> frame.Outbound {
  case command {
    UpdatePresence(presence: shown) ->
      frame.outbound(frame.OpPresenceUpdate, presence.to_json(shown))

    UpdateVoiceState(guild:, channel:, self_mute:, self_deaf:) ->
      frame.outbound(
        frame.OpVoiceStateUpdate,
        json.object([
          #("guild_id", id.to_json(guild)),
          // A literal null disconnects. Omitting the key means "no change".
          #("channel_id", json.nullable(channel, id.to_json)),
          #("self_mute", json.bool(self_mute)),
          #("self_deaf", json.bool(self_deaf)),
        ]),
      )

    RequestGuildMembers(request:) ->
      frame.outbound(frame.OpRequestGuildMembers, request_to_json(request))
  }
}

fn request_to_json(request: MemberRequest) -> Json {
  case request {
    // An empty query with a limit of 0 is how Discord spells "all of them".
    AllMembers(guild:, nonce:) ->
      wire.object([
        #("guild_id", Present(id.to_json(guild))),
        #("query", Present(json.string(""))),
        #("limit", Present(json.int(0))),
        #("nonce", nonce_field(nonce)),
      ])

    ByPrefix(guild:, prefix:, limit: Limit(limit), nonce:) ->
      wire.object([
        #("guild_id", Present(id.to_json(guild))),
        #("query", Present(json.string(prefix))),
        #("limit", Present(json.int(limit))),
        #("nonce", nonce_field(nonce)),
      ])

    ByIds(guild:, users: UserIds(users), nonce:) ->
      wire.object([
        #("guild_id", Present(id.to_json(guild))),
        // Always an array. Discord also accepts a bare snowflake.
        #("user_ids", Present(json.array(users, id.to_json))),
        // Discord documents `limit` only with `query`; 0 means no limit.
        #("limit", Present(json.int(0))),
        #("nonce", nonce_field(nonce)),
      ])
  }
}

/// Discord answers a null nonce with close 4002, so an unset one is omitted.
fn nonce_field(nonce: Option(Nonce)) -> field.Field(Json) {
  case nonce {
    None -> Absent
    option.Some(Nonce(text)) -> Present(json.string(text))
  }
}
