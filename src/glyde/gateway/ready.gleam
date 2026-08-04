//// READY as the protocol reads it: the session, the host to resume on, and
//// who we logged in as.
////
//// `glyde/ready` is the host's view of the same dispatch. This is a
//// separate, tiny decode on purpose, so a bug in that one's tens of kilobytes
//// cannot cost a session.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/list
import gleam/option.{type Option}
import gleam/result
import glyde/id.{type Id}
import glyde/internal/url
import glyde/wire

pub type ReadyPayload {
  ReadyPayload(
    session_id: String,
    /// `resume_gateway_url` reduced to the bare host a RESUME dials. `None`
    /// when there was no host in it, which costs nothing: the configured host
    /// answers a RESUME too, and the session is worth more than the hint.
    resume_host: Option(url.Host),
    user: Id(id.User),
    /// How many guilds READY listed, not the guilds themselves:
    /// `glyde/ready` is the one that decodes them.
    guild_count: Int,
  )
}

/// Why a READY could not be turned into a session.
pub type ReadyRejected {
  /// One of `session_id`, `resume_gateway_url` and `user.id` is missing or the
  /// wrong type.
  MissingReadyFields
}

pub fn describe_rejected(why: ReadyRejected) -> String {
  case why {
    MissingReadyFields ->
      "ready needs session_id, resume_gateway_url and user.id"
  }
}

/// The parts of READY the protocol needs.
pub fn read(data: Dynamic) -> Result(ReadyPayload, ReadyRejected) {
  decode.run(data, decoder())
  |> result.replace_error(MissingReadyFields)
}

fn decoder() -> Decoder(ReadyPayload) {
  use session_id <- decode.field("session_id", decode.string)
  use resume_url <- decode.field("resume_gateway_url", decode.string)
  use user <- decode.subfield(["user", "id"], id.decoder())
  // A guild count is worth less than a session, so unreadable reads as zero.
  use guild_count <- decode.optional_field(
    "guilds",
    0,
    wire.lenient(guild_count_decoder(), 0),
  )
  decode.success(ReadyPayload(
    session_id:,
    resume_host: option.from_result(url.host_of(resume_url)),
    user:,
    guild_count:,
  ))
}

fn guild_count_decoder() -> Decoder(Int) {
  decode.map(decode.list(decode.dynamic), list.length)
}
