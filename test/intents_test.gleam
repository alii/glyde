import gleam/json
import gleam/list
import glyde/intents

/// The totals Discord's docs work out, recomputed from the bit table.
pub fn known_totals_test() {
  assert intents.to_int(intents.none()) == 0
  assert intents.to_int(intents.all()) == 53_608_447
  assert intents.to_int(intents.all_unprivileged()) == 53_575_421
  assert intents.to_int(intents.new(intents.privileged())) == 33_026
}

pub fn docs_examples_test() {
  // From the gateway docs: intents 5 is GUILDS | GUILD_MODERATION.
  assert intents.to_int(intents.new([intents.Guilds, intents.GuildModeration]))
    == 5
  // And 513 is GUILDS | GUILD_MESSAGES.
  assert intents.to_int(intents.new([intents.Guilds, intents.GuildMessages]))
    == 513
}

/// Bits 17, 18, 19, 22 and 23 are unassigned and sending one earns a 4013 close.
pub fn no_intent_uses_an_unassigned_bit_test() {
  let unassigned = [17, 18, 19, 22, 23]
  let used = list.map(intents.all_intents(), intents.bit_index)
  list.each(unassigned, fn(gap) {
    assert !list.contains(used, gap)
  })
}

/// Every other test here survives two intents swapping bits, so pin each one:
/// the bit number, and the mask that number turns into.
pub fn every_bit_is_pinned_test() {
  let expected = [
    #(intents.Guilds, 0, 1),
    #(intents.GuildMembers, 1, 2),
    #(intents.GuildModeration, 2, 4),
    #(intents.GuildExpressions, 3, 8),
    #(intents.GuildIntegrations, 4, 16),
    #(intents.GuildWebhooks, 5, 32),
    #(intents.GuildInvites, 6, 64),
    #(intents.GuildVoiceStates, 7, 128),
    #(intents.GuildPresences, 8, 256),
    #(intents.GuildMessages, 9, 512),
    #(intents.GuildMessageReactions, 10, 1024),
    #(intents.GuildMessageTyping, 11, 2048),
    #(intents.DirectMessages, 12, 4096),
    #(intents.DirectMessageReactions, 13, 8192),
    #(intents.DirectMessageTyping, 14, 16_384),
    #(intents.MessageContent, 15, 32_768),
    #(intents.GuildScheduledEvents, 16, 65_536),
    #(intents.AutoModerationConfiguration, 20, 1_048_576),
    #(intents.AutoModerationExecution, 21, 2_097_152),
    #(intents.GuildMessagePolls, 24, 16_777_216),
    #(intents.DirectMessagePolls, 25, 33_554_432),
  ]

  list.each(expected, fn(row) {
    let #(intent, index, mask) = row
    assert intents.bit_index(intent) == index
    assert intents.to_int(intents.new([intent])) == mask
  })

  // An intent missing from `all_intents` compiles and silently never subscribes.
  assert list.length(intents.all_intents()) == list.length(expected)
  assert intents.all_intents() == list.map(expected, fn(row) { row.0 })
}

pub fn every_bit_is_distinct_test() {
  let bits = list.map(intents.all_intents(), intents.bit_index)
  assert list.length(list.unique(bits)) == list.length(bits)
}

/// `privileged` used to be its own list beside the bit table, so a fourth
/// privileged intent could be added to one and not the other.
pub fn privileged_is_a_slice_of_all_intents_test() {
  assert intents.privileged()
    == [intents.GuildMembers, intents.GuildPresences, intents.MessageContent]
  assert list.filter(intents.all_intents(), intents.is_privileged)
    == intents.privileged()
}

pub fn to_list_is_in_bit_order_test() {
  let set =
    intents.new([
      intents.DirectMessagePolls,
      intents.GuildMessages,
      intents.Guilds,
    ])

  assert intents.to_list(set)
    == [intents.Guilds, intents.GuildMessages, intents.DirectMessagePolls]
  assert intents.to_list(intents.all()) == intents.all_intents()
  assert intents.to_list(intents.none()) == []
}

pub fn add_is_idempotent_test() {
  let once = intents.new([intents.Guilds])
  let twice = intents.add(once, intents.Guilds)
  assert once == twice
}

pub fn remove_clears_only_that_bit_test() {
  let set = intents.all()
  let without = intents.remove(set, intents.DirectMessagePolls)
  assert intents.to_int(without) == 53_608_447 - 33_554_432
  assert !intents.contains(without, intents.DirectMessagePolls)
  assert intents.contains(without, intents.Guilds)
}

pub fn contains_test() {
  let set = intents.new([intents.Guilds, intents.MessageContent])
  assert intents.contains(set, intents.Guilds)
  assert intents.contains(set, intents.MessageContent)
  assert !intents.contains(set, intents.GuildMembers)
}

pub fn union_test() {
  let a = intents.new([intents.Guilds])
  let b = intents.new([intents.GuildMessages])
  assert intents.union(a, b)
    == intents.new([intents.Guilds, intents.GuildMessages])
}

pub fn privileged_in_names_what_needs_the_portal_test() {
  let set =
    intents.new([intents.Guilds, intents.MessageContent, intents.GuildMembers])
  assert intents.privileged_in(set)
    == [intents.GuildMembers, intents.MessageContent]
  assert intents.privileged_in(intents.new([intents.Guilds])) == []
}

pub fn serialises_as_a_number_test() {
  let set = intents.new([intents.Guilds, intents.GuildMessages])
  assert json.to_string(intents.to_json(set)) == "513"
}
