//// READY, the first dispatch on a fresh session.
////
//// The host-facing view, and nothing the connection reads.
//// `glyde/gateway/ready` takes `session_id` and `resume_gateway_url` off the
//// same payload with its own small decode, so a bug in the tens of kilobytes
//// here cannot cost a session.

import gleam/dynamic/decode.{type Decoder}
import gleam/option.{type Option, None}
import glyde/flags.{type Flags}
import glyde/gateway.{type Sharding}
import glyde/id
import glyde/model/user.{type CurrentUser}
import glyde/wire

/// The two application fields READY sends, not the full REST object.
pub type PartialApplication {
  PartialApplication(id: id.ApplicationId, flags: ApplicationFlags)
}

pub type ApplicationFlags =
  Flags(ApplicationFlag)

/// The privileged-intent flags are the ones a bot reads here. Discord's
/// application-flags table gives each of those intents two bits, and either
/// one means it is on: the plain bit is approval for a bot in 100 or more
/// servers, the `Limited` bit is the Bot-page toggle a bot under 100 servers
/// sets itself. With neither, IDENTIFY asking for that intent closes the
/// socket with 4014.
pub type ApplicationFlag {
  AutoModerationRuleCreateBadge
  GatewayPresence
  GatewayPresenceLimited
  GatewayGuildMembers
  GatewayGuildMembersLimited
  VerificationPendingGuildLimit
  Embedded
  GatewayMessageContent
  GatewayMessageContentLimited
  ApplicationCommandBadge
}

/// Discord's application-flags table: 1 << 6, 1 << 12 through 1 << 19, and
/// 1 << 23.
fn application_flag_bit(flag: ApplicationFlag) -> Int {
  case flag {
    AutoModerationRuleCreateBadge -> 64
    GatewayPresence -> 4096
    GatewayPresenceLimited -> 8192
    GatewayGuildMembers -> 16_384
    GatewayGuildMembersLimited -> 32_768
    VerificationPendingGuildLimit -> 65_536
    Embedded -> 131_072
    GatewayMessageContent -> 262_144
    GatewayMessageContentLimited -> 524_288
    ApplicationCommandBadge -> 8_388_608
  }
}

pub fn has_flag(bits: ApplicationFlags, flag: ApplicationFlag) -> Bool {
  flags.has_bit(bits, application_flag_bit(flag))
}

pub type Ready {
  Ready(
    /// Should be 10. Anything else means the gateway URL lost its `?v=`.
    version: Int,
    /// The bot's own user, and the only user object that carries `email`.
    me: CurrentUser,
    /// Every guild the bot is in, all unavailable until their GUILD_CREATE.
    guilds: List(id.GuildId),
    /// Opaque, not a snowflake.
    session_id: String,
    /// Reconnect here, not to the cached `GET /gateway` url.
    resume_gateway_url: String,
    /// Absent unless IDENTIFY sent a shard tuple.
    shard: Option(Sharding),
    /// Documented as required, and often missing.
    application: Option(PartialApplication),
  )
}

pub fn decoder() -> Decoder(Ready) {
  use version <- wire.int_field("v", 0)
  use account <- decode.field("user", user.current_user_decoder())
  use guilds <- wire.list_field("guilds", guild_stub_decoder())
  use session_id <- decode.field("session_id", decode.string)
  use resume_gateway_url <- decode.field("resume_gateway_url", decode.string)
  use shard <- decode.optional_field("shard", None, shard_decoder())
  // Soft, not strict: neither field here is one the connection reads, so
  // failing would hand the host `event.Raw` and lose its own user, its guild
  // list and its application over a field it may not have asked for.
  use application <- wire.soft_field(
    "application",
    partial_application_decoder(),
  )
  decode.success(Ready(
    version:,
    me: account,
    guilds:,
    session_id:,
    resume_gateway_url:,
    shard:,
    application:,
  ))
}

/// READY's guild entries are `{id, unavailable: true}`, and the flag never
/// varies.
fn guild_stub_decoder() -> Decoder(id.GuildId) {
  decode.field("id", id.decoder(), decode.success)
}

/// `flags` is required, not defaulted: a 0 reads as "no privileged intents
/// enabled", which is a claim we cannot make from a payload that never said.
/// Failing sends the whole object through `soft_field` to `None` instead.
pub fn partial_application_decoder() -> Decoder(PartialApplication) {
  use application_id <- decode.field("id", id.decoder())
  use flag_bits <- decode.field("flags", wire.integer())
  decode.success(PartialApplication(
    id: application_id,
    flags: flags.from_int(flag_bits),
  ))
}

/// `[index, count]` exactly, and a pair the gateway would refuse with close
/// 4010 is worth no more than none. Taking the first two of a longer array
/// would misassign the shard, which shows up as missing events.
fn shard_decoder() -> Decoder(Option(Sharding)) {
  use values <- decode.then(
    decode.one_of(decode.list(wire.integer()), or: [decode.success([])]),
  )
  case values {
    [index, count] ->
      decode.success(option.from_result(gateway.sharding(index:, count:)))
    _ -> decode.success(None)
  }
}
