//// IDENTIFY (op 2): the config it carries and the frame it becomes.
////
//// Separate from `frame` so the wire envelope stays about the envelope, and
//// so `Sharding`, `LargeThreshold` and `Properties` are found where they are
//// configured, not in among the opcode tables.

import gleam/bool
import gleam/int
import gleam/json
import gleam/option.{type Option}
import glyde/field.{Present}
import glyde/gateway/frame.{type Outbound, SendIdentify, outbound}
import glyde/gateway/presence.{type Presence}
import glyde/intents.{type Intents}
import glyde/token
import glyde/wire

/// Discord's rule, not ours: IDENTIFY's `large_threshold` is 50 to 250.
const min_large_threshold: Int = 50

const max_large_threshold: Int = 250

/// One shard's place in the fleet, sent as `[index, count]`. Opaque because
/// `index` is 0-based and must be below `count`: `sharding` is the only thing
/// that can make one, so a fleet the gateway would answer with close 4010
/// cannot be built at all. Labelled and not a pair, because swapping the two
/// is also 4010 and takes a restart to spot.
pub opaque type Sharding {
  Sharding(index: Int, count: Int)
}

/// Why a fleet was refused. Both are configuration mistakes that no reconnect
/// fixes, so they are caught before a shard exists.
pub type ShardingError {
  /// A fleet has at least one shard in it.
  EmptyFleet(count: Int)
  /// `index` is 0-based, so shard 16 of 16 is not a shard.
  IndexOutOfRange(index: Int, count: Int)
}

/// `sharding(index: 0, count: 1)` is an unsharded bot, which Discord reads as
/// sending no shard array at all.
pub fn sharding(
  index index: Int,
  count count: Int,
) -> Result(Sharding, ShardingError) {
  use <- bool.guard(when: count < 1, return: Error(EmptyFleet(count:)))
  use <- bool.guard(
    when: index < 0 || index >= count,
    return: Error(IndexOutOfRange(index:, count:)),
  )
  Ok(Sharding(index:, count:))
}

/// The one fleet that needs no checking, and the default a bot connects with.
pub fn unsharded() -> Sharding {
  Sharding(index: 0, count: 1)
}

/// This shard's 0-based place in the fleet.
pub fn shard_index(sharding: Sharding) -> Int {
  sharding.index
}

/// How many shards the fleet has.
pub fn shard_count(sharding: Sharding) -> Int {
  sharding.count
}

/// Guild size above which Discord sends an offline member list. Opaque so the
/// clamp happens once, where the value is made, rather than again wherever it
/// is written.
pub opaque type LargeThreshold {
  LargeThreshold(value: Int)
}

/// Clamped rather than refused: a value outside Discord's range is a number
/// to correct, not a connection to fail.
pub fn large_threshold(value: Int) -> LargeThreshold {
  LargeThreshold(int.clamp(
    value,
    min: min_large_threshold,
    max: max_large_threshold,
  ))
}

pub fn large_threshold_value(threshold: LargeThreshold) -> Int {
  threshold.value
}

/// IDENTIFY's `properties` object. Analytics only; Discord acts on none of
/// them. The `$os` spelling is deprecated, so these go out unprefixed.
pub type Properties {
  Properties(os: String, browser: String, device: String)
}

/// Everything IDENTIFY puts on the wire.
pub type Identity {
  Identity(
    token: token.Token,
    intents: Intents,
    properties: Properties,
    large_threshold: LargeThreshold,
    shard: Sharding,
    /// What the bot looks like the moment it connects. Op 3 sends the same
    /// object once it is live.
    presence: Option(Presence),
  )
}

pub fn identify(identity: Identity) -> Outbound {
  let data =
    wire.object([
      #("token", Present(json.string(token.reveal(identity.token)))),
      #(
        "properties",
        Present(
          json.object([
            #("os", json.string(identity.properties.os)),
            #("browser", json.string(identity.properties.browser)),
            #("device", json.string(identity.properties.device)),
          ]),
        ),
      ),
      // per-payload zlib is unsupported; stream compression is negotiated in the URL
      #("compress", Present(json.bool(False))),
      #(
        "large_threshold",
        Present(json.int(large_threshold_value(identity.large_threshold))),
      ),
      #(
        "shard",
        Present(
          json.preprocessed_array([
            json.int(identity.shard.index),
            json.int(identity.shard.count),
          ]),
        ),
      ),
      #("intents", Present(intents.to_json(identity.intents))),
      // Discord answers `"presence": null` with close 4002, so the key is omitted.
      #("presence", wire.put(wire.opt(identity.presence), presence.to_json)),
    ])
  outbound(SendIdentify, data)
}
