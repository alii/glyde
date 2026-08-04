//// The Erlang half of `glyde/transport`: `glyde/websocket`, `gleam_httpc`,
//// and the VM's own monotonic clock. The only module in glyde that touches a
//// platform package, which is why the interface is not in here with it.

import gleam/http/request.{type Request}
import gleam/httpc
import glyde/internal/timing
import glyde/transport.{type Answer, type Socket, type Transport}
import glyde/websocket

/// What `glyde.new` starts with. `glyde.with_transport` replaces it.
pub fn default() -> Transport {
  transport.Transport(
    open: dial,
    request: send,
    now: timing.now,
    idle: timing.sleep,
  )
}

/// The dial reaches OTP calls that raise rather than answer, `cacerts_get` on
/// a host with no CA store among them. A raise here would kill the process, so
/// it comes back as a socket that is already ending and reports the reason on
/// its first turn, the same as a refused dial does.
fn dial(url: String) -> Socket {
  case rescue(fn() { websocket.open(url) }) {
    Ok(live) -> over(live)
    Error(reason) -> over(websocket.failed(reason))
  }
}

/// `transport.Socket` hands a socket back from `turn` alone, so the ending
/// socket that a write, a close and a drop each produce goes nowhere and the
/// next `turn` runs on this one. Each discard below says what covers it.
fn over(socket: websocket.Socket) -> Socket {
  transport.Socket(
    // A write that failed has already torn the transport down, so the next
    // `turn` reads that and reports the close. The reason goes with the socket
    // dropped here, and is not missed: the runtime reports one only for a dial
    // that never opened, which a write says this one did.
    send: fn(text) { websocket.live(websocket.send_text(socket, text)) },
    // The frame is out and the transport is down, so the next `turn` reads a
    // closed socket at once rather than waiting out its timeout.
    close: fn(code) {
      let _ = websocket.close(socket, code, "")
      Nil
    },
    // `glyde` forgets the dial in the same step it drops it, so nothing turns
    // this socket again.
    drop: fn() {
      let _ = websocket.drop(socket)
      Nil
    },
    turn: fn(in_ms) {
      // `transport.Socket` promises a turn blocks until the timeout is up. A
      // finished socket answers at once, so waiting it out here is what stops
      // a caller that keeps turning from spinning the CPU.
      case websocket.finished(socket) {
        True -> {
          timing.sleep(in_ms)
          #(over(socket), [])
        }
        False -> {
          let #(socket, events) = websocket.poll(socket, timeout: in_ms)
          #(over(socket), events)
        }
      }
    },
  )
}

/// Milliseconds. Our choice: a REST call blocks the same loop the heartbeat
/// goes out on, so it has to run out well inside a heartbeat interval.
const rest_timeout: Int = 10_000

fn send(built: Request(BitArray)) -> Answer {
  let dispatch = fn() {
    httpc.configure()
    |> httpc.timeout(rest_timeout)
    |> httpc.dispatch_bits(built)
  }

  case rescue(dispatch) {
    Ok(Ok(response)) -> Ok(response)
    Ok(Error(failure)) -> Error(unreachable(failure))
    // `gleam_httpc` raises for any failure it has not modelled, an unfamiliar
    // DNS answer among them. Letting that through would kill the OS process
    // and take a healthy gateway session, its id and its resume state with it.
    Error(raised) -> Error(transport.Other(raised))
  }
}

fn unreachable(failure: httpc.HttpError) -> transport.Unreachable {
  case failure {
    httpc.FailedToConnect(ip4:, ip6:) ->
      transport.ConnectFailed(
        "IPv4 " <> connect_detail(ip4) <> ", IPv6 " <> connect_detail(ip6),
      )
    httpc.ResponseTimeout -> transport.TimedOut
    httpc.InvalidUtf8Response -> transport.Unreadable
  }
}

fn connect_detail(error: httpc.ConnectError) -> String {
  case error {
    httpc.Posix(code:) -> code
    httpc.TlsAlert(code:, detail:) -> code <> ", " <> detail
  }
}

/// Run `attempt` and hand back whatever it raised as words, since a raise from
/// a platform package is the one failure Gleam's types cannot show.
@external(erlang, "glyde_transport_ffi", "rescue")
fn rescue(attempt: fn() -> a) -> Result(a, String)
