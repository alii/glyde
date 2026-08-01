//// Permission bitfields, which Discord sends as a decimal string holding 64
//// bits.

import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/list

/// A set of permissions. Bits Discord has not named yet ride along, so a
/// value read off the wire and written back is what arrived.
pub opaque type Permissions {
  Permissions(bits: Int)
}

/// One permission, named after Discord's constant for it.
pub type Permission {
  CreateInstantInvite
  KickMembers
  BanMembers
  Administrator
  ManageChannels
  ManageGuild
  AddReactions
  ViewAuditLog
  PrioritySpeaker
  /// Called Video in the Discord client.
  Stream
  ViewChannel
  SendMessages
  SendTtsMessages
  ManageMessages
  EmbedLinks
  AttachFiles
  ReadMessageHistory
  MentionEveryone
  UseExternalEmojis
  ViewGuildInsights
  Connect
  Speak
  MuteMembers
  DeafenMembers
  MoveMembers
  /// Speak by voice activity rather than push to talk.
  UseVad
  ChangeNickname
  ManageNicknames
  ManageRoles
  ManageWebhooks
  ManageGuildExpressions
  UseApplicationCommands
  RequestToSpeak
  ManageEvents
  ManageThreads
  CreatePublicThreads
  CreatePrivateThreads
  UseExternalStickers
  SendMessagesInThreads
  UseEmbeddedActivities
  /// Time a member out.
  ModerateMembers
  ViewCreatorMonetizationAnalytics
  UseSoundboard
  CreateGuildExpressions
  CreateEvents
  UseExternalSounds
  SendVoiceMessages
  SetVoiceChannelStatus
  SendPolls
  UseExternalApps
  PinMessages
  BypassSlowmode
}

/// Every permission Discord currently documents, in bit order.
pub fn all_permissions() -> List(Permission) {
  [
    CreateInstantInvite,
    KickMembers,
    BanMembers,
    Administrator,
    ManageChannels,
    ManageGuild,
    AddReactions,
    ViewAuditLog,
    PrioritySpeaker,
    Stream,
    ViewChannel,
    SendMessages,
    SendTtsMessages,
    ManageMessages,
    EmbedLinks,
    AttachFiles,
    ReadMessageHistory,
    MentionEveryone,
    UseExternalEmojis,
    ViewGuildInsights,
    Connect,
    Speak,
    MuteMembers,
    DeafenMembers,
    MoveMembers,
    UseVad,
    ChangeNickname,
    ManageNicknames,
    ManageRoles,
    ManageWebhooks,
    ManageGuildExpressions,
    UseApplicationCommands,
    RequestToSpeak,
    ManageEvents,
    ManageThreads,
    CreatePublicThreads,
    CreatePrivateThreads,
    UseExternalStickers,
    SendMessagesInThreads,
    UseEmbeddedActivities,
    ModerateMembers,
    ViewCreatorMonetizationAnalytics,
    UseSoundboard,
    CreateGuildExpressions,
    CreateEvents,
    UseExternalSounds,
    SendVoiceMessages,
    SetVoiceChannelStatus,
    SendPolls,
    UseExternalApps,
    PinMessages,
    BypassSlowmode,
  ]
}

/// The bit number, not its value, from Discord's permissions table. Bit 47 is
/// missing, retired by Discord.
pub fn bit_index(permission: Permission) -> Int {
  case permission {
    CreateInstantInvite -> 0
    KickMembers -> 1
    BanMembers -> 2
    Administrator -> 3
    ManageChannels -> 4
    ManageGuild -> 5
    AddReactions -> 6
    ViewAuditLog -> 7
    PrioritySpeaker -> 8
    Stream -> 9
    ViewChannel -> 10
    SendMessages -> 11
    SendTtsMessages -> 12
    ManageMessages -> 13
    EmbedLinks -> 14
    AttachFiles -> 15
    ReadMessageHistory -> 16
    MentionEveryone -> 17
    UseExternalEmojis -> 18
    ViewGuildInsights -> 19
    Connect -> 20
    Speak -> 21
    MuteMembers -> 22
    DeafenMembers -> 23
    MoveMembers -> 24
    UseVad -> 25
    ChangeNickname -> 26
    ManageNicknames -> 27
    ManageRoles -> 28
    ManageWebhooks -> 29
    ManageGuildExpressions -> 30
    UseApplicationCommands -> 31
    RequestToSpeak -> 32
    ManageEvents -> 33
    ManageThreads -> 34
    CreatePublicThreads -> 35
    CreatePrivateThreads -> 36
    UseExternalStickers -> 37
    SendMessagesInThreads -> 38
    UseEmbeddedActivities -> 39
    ModerateMembers -> 40
    ViewCreatorMonetizationAnalytics -> 41
    UseSoundboard -> 42
    CreateGuildExpressions -> 43
    CreateEvents -> 44
    UseExternalSounds -> 45
    SendVoiceMessages -> 46
    SetVoiceChannelStatus -> 48
    SendPolls -> 49
    UseExternalApps -> 50
    PinMessages -> 51
    BypassSlowmode -> 52
  }
}

/// Why a string is not a permission field. Each carries the text it refused,
/// so a caller logging one does not have to hold on to the input.
pub type ParseError {
  /// Not one or more decimal digits.
  NotDecimal(decimal: String)
  /// Wider than the 64 bits Discord specifies. Keeping the bottom 64 would
  /// grant a set nobody wrote.
  TooWide(decimal: String)
}

/// 2^64 - 1, every bit of the field Discord specifies.
const max_field: Int = 18_446_744_073_709_551_615

/// Rejects anything that is not decimal digits, and anything wider than the
/// 64 bits Discord specifies rather than keeping the bottom of it.
pub fn parse(decimal: String) -> Result(Permissions, ParseError) {
  case decimal, int.parse(decimal) {
    // `int.parse` takes a leading sign, which no bitfield Discord sends has.
    "+" <> _, _ | "-" <> _, _ -> Error(NotDecimal(decimal))
    _, Ok(bits) if bits <= max_field -> Ok(Permissions(bits))
    _, Ok(_) -> Error(TooWide(decimal))
    _, Error(Nil) -> Error(NotDecimal(decimal))
  }
}

/// The bitfield to send, as the decimal string Discord expects.
pub fn to_string(permissions: Permissions) -> String {
  int.to_string(permissions.bits)
}

pub fn none() -> Permissions {
  Permissions(0)
}

pub fn new(granted: List(Permission)) -> Permissions {
  list.fold(granted, none(), add)
}

/// Every permission Discord documents. Discord itself never sends this: a
/// role that can do everything carries Administrator instead.
pub fn all() -> Permissions {
  new(all_permissions())
}

/// Whether the bit is set, and nothing else. This is the honest question for
/// a role's own bits and for either side of a channel overwrite.
pub fn contains(permissions: Permissions, permission: Permission) -> Bool {
  int.bitwise_and(permissions.bits, mask(permission)) != 0
}

/// Whether an *effective* permission set permits this. Administrator grants
/// everything, which is Discord's rule and not a property of the bitfield, so
/// only ask this of a set you have already resolved. On a role's bits or on
/// an overwrite's allow or deny it reads a plain Administrator bit as
/// everything, which no side of an overwrite means.
pub fn allows(permissions: Permissions, permission: Permission) -> Bool {
  contains(permissions, Administrator) || contains(permissions, permission)
}

pub fn add(permissions: Permissions, permission: Permission) -> Permissions {
  Permissions(int.bitwise_or(permissions.bits, mask(permission)))
}

pub fn remove(permissions: Permissions, permission: Permission) -> Permissions {
  Permissions(int.bitwise_and(
    permissions.bits,
    int.bitwise_not(mask(permission)),
  ))
}

pub fn union(a: Permissions, b: Permissions) -> Permissions {
  Permissions(int.bitwise_or(a.bits, b.bits))
}

/// Everything in `a` that is not in `b`, which is what a channel overwrite's
/// deny list does.
pub fn difference(a: Permissions, b: Permissions) -> Permissions {
  Permissions(int.bitwise_and(a.bits, int.bitwise_not(b.bits)))
}

/// In bit order, and only the ones this build names. A bit assigned since is
/// still carried through `to_string` untouched.
pub fn to_list(permissions: Permissions) -> List(Permission) {
  list.filter(all_permissions(), contains(permissions, _))
}

/// Strings only, like an id: Discord always sends a bitfield as a string, so
/// a number in that slot is a malformed payload.
pub fn decoder() -> Decoder(Permissions) {
  use decimal <- decode.then(decode.string)
  case parse(decimal) {
    Ok(permissions) -> decode.success(permissions)
    Error(NotDecimal(_)) -> decode.failure(none(), "Permissions")
    Error(TooWide(_)) -> decode.failure(none(), "Permissions of 64 bits")
  }
}

pub fn to_json(permissions: Permissions) -> Json {
  json.string(to_string(permissions))
}

fn mask(permission: Permission) -> Int {
  int.bitwise_shift_left(1, bit_index(permission))
}
