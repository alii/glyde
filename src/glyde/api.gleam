//// What a handler is given to make REST calls with, and the executor the
//// endpoint helpers call. Lives here rather than in `glyde` so noun modules
//// can import it without a cycle.

import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/result
import glyde/internal/limiter_actor
import glyde/rest.{type Call}
import glyde/rest/error
import glyde/rest/headers
import glyde/rest/limiter
import glyde/rest/route.{type Route}
import glyde/transport

/// Built by `glyde.start` and passed to every spawned handler.
pub opaque type Api {
  Api(
    limiter: Subject(limiter_actor.Message),
    rest: rest.Config,
    request: fn(Request(BitArray)) -> transport.Answer,
  )
}

@internal
pub fn new(
  limiter: Subject(limiter_actor.Message),
  rest: rest.Config,
  request: fn(Request(BitArray)) -> transport.Answer,
) -> Api {
  Api(limiter:, rest:, request:)
}

/// Why a REST call did not produce an answer. Discord answered and said no,
/// nothing answered at all, or the limiter would not let it go.
pub type CallFailure {
  /// Discord answered, with a non-2xx or a body its own decoder would not
  /// take. `glyde/rest/error` is where the questions about it live. A 429 has
  /// already been waited out and retried before it arrives here.
  Refused(rest.Failure)
  /// The request never got an answer: no route to the host, a timeout, a proxy
  /// speaking something that is not HTTP.
  Unreachable(transport.Unreachable)
  /// Never sent, and waiting would not help: the limiter will not send it at
  /// all. In practice the invalid-request budget is spent.
  Withheld(limiter.Refusal)
}

pub fn describe_failure(failure: CallFailure) -> String {
  case failure {
    Refused(refusal) -> error.describe(refusal)
    Unreachable(reason) -> transport.describe(reason)
    Withheld(limiter.InvalidBudgetSpent) ->
      "not sent, the invalid-request budget is spent"
    Withheld(limiter.Backlogged) -> "not sent, too many calls waiting"
    Withheld(limiter.DuplicateTicket) -> "not sent, duplicate ticket"
  }
}

/// Sends per call. The first 429 teaches the limiter the bucket, so the second
/// is timed right; a third covers a global and a route limit landing together.
const max_attempts: Int = 3

/// Send one call and wait for the answer. Blocks this handler process, which
/// is its own and holds up nothing else. A 429 is waited out and retried.
pub fn execute(api: Api, call: Call(a)) -> Result(a, CallFailure) {
  let built = rest.request_bytes(api.rest, call)
  use response <- result.try(attempt(api, built, rest.route(call), 1))
  rest.response(
    call,
    status: response.status,
    headers: response.headers,
    body: response.body,
  )
  |> result.map_error(Refused)
}

fn attempt(api: Api, built: Request(BitArray), route: Route, tries: Int) {
  case limiter_actor.acquire(api.limiter, route, tries > 1) {
    limiter_actor.Refused(why) -> Error(Withheld(why))
    limiter_actor.Granted(ticket) ->
      case api.request(built) {
        Error(reason) -> {
          limiter_actor.settle(api.limiter, ticket, limiter.Opaque)
          Error(Unreachable(reason))
        }
        Ok(got) -> {
          let body = case got.status {
            429 -> bit_array.to_string(got.body) |> result.unwrap("")
            _ -> ""
          }
          let outcome =
            headers.outcome(status: got.status, headers: got.headers, body:)
          limiter_actor.settle(api.limiter, ticket, outcome)
          case got.status == 429 && tries < max_attempts {
            True -> attempt(api, built, route, tries + 1)
            False -> Ok(got)
          }
        }
      }
  }
}
