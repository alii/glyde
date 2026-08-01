import gleam/list
import gleam/option.{None, Some}
import glyde/gateway/close

/// Every inbound close code and what it calls for.
fn table() -> List(#(option.Option(Int), close.Disposition)) {
  [
    #(None, close.ReconnectResume),
    #(Some(1000), close.ReconnectResume),
    #(Some(1001), close.ReconnectResume),
    #(Some(1005), close.ReconnectResume),
    #(Some(1006), close.ReconnectResume),
    #(Some(1012), close.ReconnectResume),
    #(Some(4000), close.ReconnectResume),
    #(Some(4001), close.ReconnectResume),
    #(Some(4002), close.ReconnectResume),
    #(Some(4003), close.ReconnectFresh),
    #(Some(4004), close.Fatal(close.BadToken)),
    #(Some(4005), close.ReconnectFresh),
    #(Some(4007), close.ReconnectFresh),
    // We flooded the command budget. Our bug, and the session survives, but
    // the next dial has to wait.
    #(Some(4008), close.ReconnectThrottled),
    #(Some(4009), close.ReconnectFresh),
    #(Some(4010), close.Fatal(close.InvalidShard)),
    #(Some(4011), close.Fatal(close.ShardingRequired)),
    #(Some(4012), close.Fatal(close.InvalidApiVersion)),
    #(Some(4013), close.Fatal(close.InvalidIntents)),
    #(Some(4014), close.Fatal(close.DisallowedIntents)),
  ]
}

pub fn inbound_disposition_table_test() {
  list.each(table(), fn(row) {
    let #(code, expected) = row
    assert close.from_gateway(code) == expected
  })
}

/// A 1000 from Discord leaves the session alive; the 1000 we send is the one
/// that ends it.
pub fn direction_changes_the_meaning_of_1000_test() {
  assert close.from_gateway(Some(1000)) == close.ReconnectResume

  assert close.code(close.Terminal) == 1000
  assert !close.intent_keeps_session(close.Terminal)
}

/// A transport failure with no frame is the documented resume case, as is 1006.
pub fn transport_failure_resumes_test() {
  assert close.from_gateway(None) == close.ReconnectResume
  assert close.from_gateway(None) == close.from_gateway(Some(1006))
}

/// 4006 is a voice code, not a gateway one.
pub fn no_gateway_4006_test() {
  assert close.from_gateway(Some(4006)) == close.ReconnectResume
  assert close.parse(4006) == close.UnknownCode(4006)
  assert close.describe(close.parse(4006)) == "unrecognised close code"
}

/// Identifying spends from a budget of 1000 a day; resuming spends nothing.
pub fn unknown_codes_resume_test() {
  list.each([4100, 4999, 1011, 3000, 5000], fn(code) {
    assert close.from_gateway(Some(code)) == close.ReconnectResume
  })
}

/// 1000 and 1001 are the two codes that end a session when we send them, so an
/// intent that means to keep one must not pick either.
pub fn keeping_the_session_never_sends_a_killing_code_test() {
  list.each([close.Reconnect, close.FreshIdentify, close.Terminal], fn(intent) {
    let code = close.code(intent)
    case close.intent_keeps_session(intent) {
      True -> {
        assert #(intent, code != 1000 && code != 1001) == #(intent, True)
      }
      False -> Nil
    }
  })
}

/// Closing 4000 to reconnect keeps the session; closing 1000 to shut down does
/// not, and a fresh identify throws the session away whatever code went out.
pub fn our_own_close_keeps_its_intent_test() {
  assert close.intent_keeps_session(close.Reconnect)
  assert !close.intent_keeps_session(close.FreshIdentify)
  assert !close.intent_keeps_session(close.Terminal)

  assert close.code(close.Reconnect) == 4000
  assert close.code(close.FreshIdentify) == 4000
  assert close.code(close.Terminal) == 1000
}

pub fn fatal_codes_never_reconnect_test() {
  list.each([4004, 4010, 4011, 4012, 4013, 4014], fn(code) {
    case close.from_gateway(Some(code)) {
      close.Fatal(reason) -> {
        assert close.remedy(reason) != ""
      }
      _ -> panic as "fatal close code was classified as reconnectable"
    }
  })
}

/// The fatal set is written once, inside `CloseCode`, so `parse` and the
/// disposition cannot disagree about which codes it holds.
pub fn parse_marks_exactly_the_fatal_codes_unfixable_test() {
  list.each([4004, 4010, 4011, 4012, 4013, 4014], fn(code) {
    case close.parse(code) {
      close.Unfixable(reason) -> {
        assert close.from_gateway(Some(code)) == close.Fatal(reason)
      }
      _ -> panic as "fatal close code did not parse as unfixable"
    }
  })
}

pub fn session_survives_only_on_resume_test() {
  assert close.session_survives(close.ReconnectResume)
  assert close.session_survives(close.ReconnectThrottled)
  assert !close.session_survives(close.ReconnectFresh)
  assert !close.session_survives(close.Fatal(close.BadToken))
}

pub fn every_known_code_has_a_name_test() {
  list.each(table(), fn(row) {
    case row.0 {
      Some(code) -> {
        assert close.describe(close.parse(code)) != "unrecognised close code"
      }
      None -> Nil
    }
  })
}
