//// The close-code table, written from Discord's documentation rather than
//// from the implementation. Rules the docs are silent on say so.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import glyde/gateway/close.{
  DisallowedIntents, Fatal, FreshIdentify, InvalidApiVersion, InvalidIntents,
  InvalidShard, Reconnect, ReconnectFresh, ReconnectResume, ReconnectThrottled,
  ShardingRequired, Terminal, Unfixable,
}

/// Every close code Discord documents, one per row, so a change to the
/// unknown-code rule cannot drag a documented one along with it.
fn inbound_table() -> List(#(Option(Int), close.Disposition)) {
  [
    // Discord lists "disconnected but receives no close code" as resumable.
    #(None, ReconnectResume),
    // 1005 is "no status received", which normalises to the same thing.
    #(Some(1005), ReconnectResume),
    #(Some(1006), ReconnectResume),
    // A 1000 Discord sends us resumes. The docs' "your session will be
    // invalidated" sentence opens "when you close the connection".
    #(Some(1000), ReconnectResume),
    #(Some(1001), ReconnectResume),
    #(Some(1011), ReconnectResume),
    #(Some(1012), ReconnectResume),
    #(Some(4000), ReconnectResume),
    #(Some(4001), ReconnectResume),
    #(Some(4002), ReconnectResume),
    // Discord's own description of 4003 ends "or this session has been
    // invalidated", so the session cannot be resumed.
    #(Some(4003), ReconnectFresh),
    #(Some(4004), Fatal(close.BadToken)),
    // Undocumented. A second IDENTIFY on one connection leaves the session
    // ambiguous, so glyde starts clean, as it does for 4003.
    #(Some(4005), ReconnectFresh),
    // There is no gateway 4006: the table jumps 4005 to 4007 and 4006 is a
    // voice code, so it falls to the unknown-code rule.
    #(Some(4006), ReconnectResume),
    // Discord: "Reconnect and start a new session."
    #(Some(4007), ReconnectFresh),
    // Rate limited. The session survives it, but the next dial has to wait:
    // how long is the gateway's choice, that it must wait is this one's.
    #(Some(4008), ReconnectThrottled),
    // Discord: "Reconnect and start a new one." A resume buys a guaranteed
    // INVALID_SESSION round trip.
    #(Some(4009), ReconnectFresh),
    #(Some(4010), Fatal(InvalidShard)),
    #(Some(4011), Fatal(ShardingRequired)),
    #(Some(4012), Fatal(InvalidApiVersion)),
    #(Some(4013), Fatal(InvalidIntents)),
    #(Some(4014), Fatal(DisallowedIntents)),
    // Unknown 4xxx resumes. Resume costs zero IDENTIFYs per iteration where
    // fresh costs one, and op 9 is Discord's own downgrade mechanism.
    #(Some(4015), ReconnectResume),
    #(Some(4099), ReconnectResume),
    #(Some(4999), ReconnectResume),
    #(Some(5000), ReconnectResume),
    #(Some(3000), ReconnectResume),
  ]
}

/// Every documented code classifies as the table says, one assertion per row.
pub fn inbound_disposition_table_test() {
  list.each(inbound_table(), fn(row) {
    let #(code, expected) = row
    // The code travels into the assertion so a failure names the row.
    assert #(code, close.from_gateway(code)) == #(code, expected)
  })
}

/// A transport failure with no frame is a resume, the same as the 1006 a
/// transport that synthesises one would report.
pub fn transport_failure_resumes_test() {
  assert close.from_gateway(None) == ReconnectResume
  assert close.from_gateway(None) == close.from_gateway(Some(1006))
}

/// A close we initiate is decided before the frame goes out, and it is the
/// intent, not the code, that says whether the session is still ours.
pub fn self_initiated_closes_carry_their_intent_test() {
  assert close.code(Terminal) == 1000
  assert close.code(Reconnect) == 4000
  assert close.code(FreshIdentify) == 4000

  assert close.intent_keeps_session(Reconnect)
  // 4000 leaves the session resumable at Discord's end. We drop it anyway.
  assert !close.intent_keeps_session(FreshIdentify)
  assert !close.intent_keeps_session(Terminal)
}

/// The docs' invalidation rule covers only the close we initiate, so a 1000 we
/// sent and a 1000 Discord sent must not mean the same thing.
pub fn the_same_code_differs_by_direction_test() {
  assert close.code(Terminal) == 1000
  assert !close.intent_keeps_session(Terminal)

  assert close.session_survives(close.from_gateway(Some(1000)))
}

/// Callers branch on the session outcome, so it is asserted rather than
/// trusted to follow from the disposition.
pub fn session_survival_follows_the_disposition_test() {
  assert close.session_survives(ReconnectResume)
  // A flood costs us the queued commands and a wait, not the session.
  assert close.session_survives(ReconnectThrottled)
  assert !close.session_survives(ReconnectFresh)
  assert !close.session_survives(Fatal(close.BadToken))
}

/// Every code documented as session-destroying reports the session gone.
pub fn no_documented_resume_loses_its_session_test() {
  list.each(inbound_table(), fn(row) {
    let #(code, expected) = row
    let survives = close.session_survives(close.from_gateway(code))
    let want = expected == ReconnectResume || expected == ReconnectThrottled
    assert #(code, survives) == #(code, want)
  })
}

/// Discord marks exactly six codes as not reconnectable. Too few reconnect-
/// loops against a misconfiguration; too many kill a bot on a recoverable error.
pub fn exactly_six_codes_are_fatal_test() {
  list.each([4004, 4010, 4011, 4012, 4013, 4014], fn(code) {
    assert #(code, is_fatal(code)) == #(code, True)
  })
}

pub fn no_other_code_is_fatal_test() {
  list.each([4000, 4001, 4002, 4003, 4005, 4007, 4008, 4009], fn(code) {
    assert #(code, is_fatal(code)) == #(code, False)
  })
}

/// An unrecognised code from a proxy must not kill the bot.
pub fn unknown_codes_are_never_fatal_test() {
  list.each(
    [1000, 1001, 1005, 1006, 1011, 1012, 3000, 4006, 4099, 4999, 5000],
    fn(code) {
      assert #(code, is_fatal(code)) == #(code, False)
    },
  )
}

/// The sampled tests above would still pass if a seventh fatal code were added
/// outside their lists, so this sweeps the whole code space.
pub fn the_fatal_set_is_exactly_six_codes_test() {
  let fatal_count =
    int.range(from: 0, to: 65_536, with: 0, run: fn(acc, code) {
      case is_fatal(code) {
        True -> acc + 1
        False -> acc
      }
    })

  assert fatal_count == 6
}

fn is_fatal(code: Int) -> Bool {
  case close.from_gateway(Some(code)) {
    Fatal(_) -> True
    _ -> False
  }
}

/// `parse` and the disposition are two matches on one type, so the codes that
/// parse as unfixable and the codes that stop the bot are one set, written
/// once. Adding a fatal code cannot land in only one of them.
pub fn the_unfixable_codes_are_the_fatal_codes_test() {
  let disagreements =
    int.range(from: 0, to: 65_536, with: 0, run: fn(acc, code) {
      let unfixable = case close.parse(code) {
        Unfixable(_) -> True
        _ -> False
      }
      case unfixable == is_fatal(code) {
        True -> acc
        False -> acc + 1
      }
    })

  assert disagreements == 0
}

/// 4013 is a bit Discord does not know and 4014 is a privileged intent that
/// needs switching on, so a shared message sends the operator to the wrong place.
pub fn intent_failures_are_told_apart_test() {
  assert close.remedy(InvalidIntents) != close.remedy(DisallowedIntents)
  assert close.describe(close.parse(4013)) != close.describe(close.parse(4014))
}

/// The 4014 fix is a checkbox in the developer portal, and nothing about the
/// close code says so.
pub fn the_4014_remedy_points_at_the_portal_test() {
  let text = close.remedy(DisallowedIntents)

  assert string.contains(text, "portal")
  assert text != ""
}

/// A fatal reason with no remedy stops the bot with no way to find out why.
pub fn every_fatal_reason_has_a_remedy_test() {
  list.each(
    [
      close.BadToken,
      InvalidShard,
      ShardingRequired,
      InvalidApiVersion,
      InvalidIntents,
      DisallowedIntents,
    ],
    fn(reason) {
      assert close.remedy(reason) != ""
    },
  )
}

/// 1000 and 1001 are the two codes that end a session when we send them, and
/// glyde picks 4000 to drop a socket precisely because it is neither. Three
/// rows, not a sweep of 65 536: `code` is the only way to pick a close code we
/// send, so there are exactly three that can go out.
pub fn only_a_terminal_close_sends_a_session_ending_code_test() {
  list.each([Reconnect, FreshIdentify, Terminal], fn(intent) {
    let code = close.code(intent)
    let ends = code == 1000 || code == 1001
    assert #(intent, ends) == #(intent, intent == Terminal)
  })
}

/// A panic here takes the whole shard down on a code a proxy invented, so all
/// 65 536 codes have to return a disposition.
pub fn the_classifier_is_total_over_every_close_code_test() {
  let counted =
    int.range(from: 0, to: 65_536, with: 0, run: fn(acc, code) {
      case close.from_gateway(Some(code)) {
        ReconnectResume | ReconnectThrottled | ReconnectFresh | Fatal(_) ->
          acc + 1
      }
    })

  assert counted == 65_536
}

/// `describe` is the logging path, so a partial one crashes the bot while it
/// reports why it disconnected.
pub fn describe_is_total_test() {
  let named =
    int.range(from: 0, to: 65_536, with: 0, run: fn(acc, code) {
      case close.describe(close.parse(code)) {
        "" -> acc
        _ -> acc + 1
      }
    })

  assert named == 65_536
}

/// An undocumented code falls to the catch-all rather than inventing a name.
pub fn documented_codes_are_named_test() {
  list.each(
    [1000, 1001, 1005, 1006, 1012, 4000, 4001, 4002, 4003, 4004],
    fn(code) {
      assert #(code, close.describe(close.parse(code)) == unnamed())
        == #(code, False)
    },
  )
}

/// 4006 is not a gateway code, and a name here is how a reader comes to believe
/// the gateway table is contiguous.
pub fn code_4006_has_no_gateway_name_test() {
  assert close.describe(close.parse(4006)) == unnamed()
}

/// What `describe` says about a code it does not know.
fn unnamed() -> String {
  close.describe(close.parse(65_535))
}
// Voice reuses these numbers differently: voice 4011 is "server not found",
// gateway 4011 is "sharding required" and fatal. Voice needs its own type.

// A fatal 4010 or 4011 reports which shard tuple Discord rejected, but from
// `gateway.Halt`, not from a close code. Tested in `gateway_test`.
