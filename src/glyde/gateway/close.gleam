//// Gateway close codes and what to do about them.
////
//// Main gateway only. Voice reuses the numbers for other things: voice 4014 is
//// a disconnected call, gateway 4014 is a bot that must never reconnect.
////
//// A close we send has no disposition here. The decision was made before the
//// frame went out, and it travels as an `Intent`: `code` picks the number,
//// `intent_keeps_session` says what we still hold. `from_gateway` answers only
//// for closes we did not choose, and the echo of our own close never reaches
//// it, because the state machine has already moved on from that connection.

import gleam/option.{type Option, None, Some}
import glyde/websocket/sendcode

/// The RFC-range-checked code that goes on the wire. Aliased so callers that
/// already reason about closes need not name a second module.
pub type SendCode =
  sendcode.SendCode

/// A close code Discord can send. Every number this module reasons about is
/// named here, so `parse` is the only table of numbers and everything else
/// matches on the name.
pub type CloseCode {
  /// From Discord this still leaves the session resumable. The rule that 1000
  /// ends a session is about closes we send.
  NormalClosure
  GoingAway
  /// The peer closed with no code in the frame.
  NoStatusReceived
  /// The socket died without a close frame.
  AbnormalClosure
  ServiceRestart
  UnknownError
  UnknownOpcode
  /// We sent something Discord could not read.
  DecodeError
  /// A command before IDENTIFY, or a session Discord has invalidated.
  NotAuthenticated
  /// A second IDENTIFY on one connection.
  AlreadyAuthenticated
  InvalidSeq
  /// We flooded the command budget.
  RateLimited
  SessionTimedOut
  /// A code no reconnect can fix. The fatal set lives in one variant so the
  /// same six numbers cannot be listed twice and drift apart.
  Unfixable(reason: Reason)
  /// Not a gateway code, including anything Discord adds after this list.
  UnknownCode(code: Int)
}

/// Why the connection can never succeed as configured.
pub type Reason {
  /// The bot token is wrong.
  BadToken
  /// The shard id or shard count in IDENTIFY was invalid.
  InvalidShard
  /// Too many guilds for one connection. The bot has to shard.
  ShardingRequired
  /// The gateway version in the URL is not supported.
  InvalidApiVersion
  /// The intents bitfield contained a bit Discord does not recognise.
  InvalidIntents
  /// The intents included a privileged one that is not enabled for this
  /// application. Enable it in the developer portal.
  DisallowedIntents
}

/// What we mean to happen when we close the connection ourselves.
pub type Intent {
  /// Drop this socket, keep the session, resume on the next one.
  Reconnect
  /// Drop the session too and identify from scratch.
  FreshIdentify
  /// Shut down for good.
  Terminal
}

/// What to do next.
pub type Disposition {
  /// Open a new connection and resume. Missed events get replayed.
  ReconnectResume

  /// Resume, but wait before redialling and throw the queued commands away.
  /// Discord closes a command flood with 4008, and redialling straight into
  /// the same backlog earns the next one.
  ReconnectThrottled

  /// Open a new connection and identify from scratch. The session is gone, so
  /// a resume would only earn an INVALID_SESSION.
  ReconnectFresh

  /// Stop. Reconnecting cannot fix this.
  Fatal(Reason)
}

/// Classify a raw close code.
pub fn parse(code: Int) -> CloseCode {
  case code {
    1000 -> NormalClosure
    1001 -> GoingAway
    1005 -> NoStatusReceived
    1006 -> AbnormalClosure
    1012 -> ServiceRestart
    4000 -> UnknownError
    4001 -> UnknownOpcode
    4002 -> DecodeError
    4003 -> NotAuthenticated
    4004 -> Unfixable(BadToken)
    4005 -> AlreadyAuthenticated
    4007 -> InvalidSeq
    4008 -> RateLimited
    4009 -> SessionTimedOut
    4010 -> Unfixable(InvalidShard)
    4011 -> Unfixable(ShardingRequired)
    4012 -> Unfixable(InvalidApiVersion)
    4013 -> Unfixable(InvalidIntents)
    4014 -> Unfixable(DisallowedIntents)
    other -> UnknownCode(other)
  }
}

/// Decide what to do about a connection Discord closed. `None` is a transport
/// that died with no close frame, which Discord documents as resumable.
///
/// Resume by default. A wrong resume costs one INVALID_SESSION round trip, a
/// wrong identify spends from a budget of 1000 a day.
pub fn from_gateway(code: Option(Int)) -> Disposition {
  case code {
    None -> ReconnectResume
    Some(code) -> disposition(parse(code))
  }
}

fn disposition(code: CloseCode) -> Disposition {
  case code {
    Unfixable(reason) -> Fatal(reason)

    // 4003 ends "or this session has been invalidated", 4005 leaves the
    // session ambiguous, and Discord documents the other two as "reconnect and
    // start a new one".
    NotAuthenticated | AlreadyAuthenticated | InvalidSeq | SessionTimedOut ->
      ReconnectFresh

    RateLimited -> ReconnectThrottled

    // Everything else leaves the session alive, a 1000 from Discord included.
    NormalClosure
    | GoingAway
    | NoStatusReceived
    | AbnormalClosure
    | ServiceRestart
    | UnknownError
    | UnknownOpcode
    | DecodeError
    | UnknownCode(_) -> ReconnectResume
  }
}

/// The code to send for an intent. 1000 tells Discord the session is over and
/// marks the bot offline; anything else leaves it resumable, and 4000 reads as
/// "unknown error".
pub fn code(intent: Intent) -> SendCode {
  case intent {
    Terminal -> sendcode.shutdown
    Reconnect | FreshIdentify -> sendcode.resume
  }
}

/// Whether we still hold a session after closing with this intent. Not a
/// property of the code: `FreshIdentify` sends a code Discord would let us
/// resume with and throws the session away anyway.
pub fn intent_keeps_session(intent: Intent) -> Bool {
  case intent {
    Reconnect -> True
    FreshIdentify | Terminal -> False
  }
}

/// Discord's name for a code, for logs and error messages.
pub fn describe(code: CloseCode) -> String {
  case code {
    NormalClosure -> "normal closure"
    GoingAway -> "going away"
    NoStatusReceived -> "no status received"
    AbnormalClosure -> "abnormal closure"
    ServiceRestart -> "service restart"
    UnknownError -> "unknown error"
    UnknownOpcode -> "unknown opcode"
    DecodeError -> "decode error"
    NotAuthenticated -> "not authenticated"
    AlreadyAuthenticated -> "already authenticated"
    InvalidSeq -> "invalid seq"
    RateLimited -> "rate limited"
    SessionTimedOut -> "session timed out"
    Unfixable(BadToken) -> "authentication failed"
    Unfixable(InvalidShard) -> "invalid shard"
    Unfixable(ShardingRequired) -> "sharding required"
    Unfixable(InvalidApiVersion) -> "invalid API version"
    Unfixable(InvalidIntents) -> "invalid intents"
    Unfixable(DisallowedIntents) -> "disallowed intents"
    UnknownCode(_) -> "unrecognised close code"
  }
}

/// What an operator should do about a fatal close.
pub fn remedy(reason: Reason) -> String {
  case reason {
    BadToken -> "check the bot token"
    InvalidShard -> "check the shard id and shard count"
    ShardingRequired ->
      "the bot is in too many guilds for one connection, shard it"
    InvalidApiVersion ->
      "the gateway version glyde requested is no longer supported"
    InvalidIntents ->
      "the intents bitfield contains a bit Discord does not know"
    DisallowedIntents -> "enable the privileged intents in the developer portal"
  }
}

/// Whether a close leaves the session usable, for a caller that only wants to
/// know "can I resume".
pub fn session_survives(disposition: Disposition) -> Bool {
  case disposition {
    ReconnectResume | ReconnectThrottled -> True
    ReconnectFresh -> False
    Fatal(_) -> False
  }
}
