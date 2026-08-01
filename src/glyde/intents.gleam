//// Gateway intents: the IDENTIFY bitfield that decides which events Discord
//// delivers.
////
//// Three are privileged and need switching on in the developer portal first.
//// Asking for one you have not enabled closes the connection with 4014; a bit
//// Discord has not assigned closes it with 4013, which is why this is opaque.

import gleam/int
import gleam/json.{type Json}
import gleam/list

pub opaque type Intents {
  Intents(bits: Int)
}

pub type Intent {
  Guilds
  GuildMembers
  GuildModeration
  GuildExpressions
  GuildIntegrations
  GuildWebhooks
  GuildInvites
  GuildVoiceStates
  GuildPresences
  GuildMessages
  GuildMessageReactions
  GuildMessageTyping
  DirectMessages
  DirectMessageReactions
  DirectMessageTyping
  MessageContent
  GuildScheduledEvents
  AutoModerationConfiguration
  AutoModerationExecution
  GuildMessagePolls
  DirectMessagePolls
}

/// Every intent Discord currently defines, in bit order. A new variant has to
/// be added here by hand; nothing in the compiler catches an omission, so
/// `every_bit_is_pinned_test` counts this list against the bit table.
pub fn all_intents() -> List(Intent) {
  [
    Guilds,
    GuildMembers,
    GuildModeration,
    GuildExpressions,
    GuildIntegrations,
    GuildWebhooks,
    GuildInvites,
    GuildVoiceStates,
    GuildPresences,
    GuildMessages,
    GuildMessageReactions,
    GuildMessageTyping,
    DirectMessages,
    DirectMessageReactions,
    DirectMessageTyping,
    MessageContent,
    GuildScheduledEvents,
    AutoModerationConfiguration,
    AutoModerationExecution,
    GuildMessagePolls,
    DirectMessagePolls,
  ]
}

/// The bit number, not its value, from Discord's gateway intents table.
/// Discord has assigned nothing to bits 17 to 19 or 22 to 23, and asking for
/// one of those closes the connection with 4013.
pub fn bit_index(intent: Intent) -> Int {
  case intent {
    Guilds -> 0
    GuildMembers -> 1
    GuildModeration -> 2
    GuildExpressions -> 3
    GuildIntegrations -> 4
    GuildWebhooks -> 5
    GuildInvites -> 6
    GuildVoiceStates -> 7
    GuildPresences -> 8
    GuildMessages -> 9
    GuildMessageReactions -> 10
    GuildMessageTyping -> 11
    DirectMessages -> 12
    DirectMessageReactions -> 13
    DirectMessageTyping -> 14
    MessageContent -> 15
    GuildScheduledEvents -> 16
    AutoModerationConfiguration -> 20
    AutoModerationExecution -> 21
    GuildMessagePolls -> 24
    DirectMessagePolls -> 25
  }
}

/// Bit 25 is the highest Discord assigns, well under the 2^53 where the two
/// targets' bitwise ops part company.
fn mask(intent: Intent) -> Int {
  int.bitwise_shift_left(1, bit_index(intent))
}

/// Enable these in the developer portal before asking for them. Above 100
/// servers they also need Discord's approval.
pub fn privileged() -> List(Intent) {
  list.filter(all_intents(), is_privileged)
}

/// Exhaustive with no wildcard on purpose. A privileged intent Discord adds
/// later would otherwise read as unprivileged here, `all_unprivileged` would
/// ask for it, and the connection glyde promised would work closes with 4014.
pub fn is_privileged(intent: Intent) -> Bool {
  case intent {
    GuildMembers | GuildPresences | MessageContent -> True
    Guilds
    | GuildModeration
    | GuildExpressions
    | GuildIntegrations
    | GuildWebhooks
    | GuildInvites
    | GuildVoiceStates
    | GuildMessages
    | GuildMessageReactions
    | GuildMessageTyping
    | DirectMessages
    | DirectMessageReactions
    | DirectMessageTyping
    | GuildScheduledEvents
    | AutoModerationConfiguration
    | AutoModerationExecution
    | GuildMessagePolls
    | DirectMessagePolls -> False
  }
}

pub fn new(intents: List(Intent)) -> Intents {
  list.fold(intents, Intents(0), add)
}

/// No intents. Ungated events still arrive, READY and INTERACTION_CREATE
/// among them, so this is right for a slash-command bot.
pub fn none() -> Intents {
  Intents(0)
}

/// Everything, privileged included. Discord refuses the connection with 4014
/// unless all three are enabled in the portal.
pub fn all() -> Intents {
  new(all_intents())
}

/// Everything that does not need portal setup.
pub fn all_unprivileged() -> Intents {
  new(list.filter(all_intents(), fn(i) { !is_privileged(i) }))
}

pub fn add(intents: Intents, intent: Intent) -> Intents {
  Intents(int.bitwise_or(intents.bits, mask(intent)))
}

pub fn remove(intents: Intents, intent: Intent) -> Intents {
  Intents(int.bitwise_and(intents.bits, int.bitwise_not(mask(intent))))
}

pub fn contains(intents: Intents, intent: Intent) -> Bool {
  int.bitwise_and(intents.bits, mask(intent)) != 0
}

pub fn union(a: Intents, b: Intents) -> Intents {
  Intents(int.bitwise_or(a.bits, b.bits))
}

/// In bit order, and only the intents this build names. A bit assigned since
/// is still carried through `to_int` untouched.
pub fn to_list(intents: Intents) -> List(Intent) {
  list.filter(all_intents(), contains(intents, _))
}

/// The privileged intents in this set, to name in an error message when
/// Discord answers with 4014.
pub fn privileged_in(intents: Intents) -> List(Intent) {
  list.filter(to_list(intents), is_privileged)
}

/// The bitfield for IDENTIFY. Discord wants a number here, unlike a
/// permission set, which it sends and takes as a decimal string.
pub fn to_int(intents: Intents) -> Int {
  intents.bits
}

pub fn to_json(intents: Intents) -> Json {
  json.int(intents.bits)
}
