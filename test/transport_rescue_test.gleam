//// `gleam_httpc` raises for any httpc failure it has not modelled. Out of
//// `glyde.run` that kills the OS process and takes a live gateway session, its
//// id and its resume state with it, so the raise stops in the transport.

import gleam/http
import gleam/http/request
import glyde/transport
import glyde/transport/erlang as erlang_transport
import glyde/websocket

/// A bracketed IPv6 host with a port is a URI Erlang rejects before a packet
/// goes out, so this touches no network. `gleam_httpc` has no variant for it.
pub fn an_unmodelled_httpc_failure_is_an_answer_not_a_crash_test() {
  let built =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_scheme(http.Http)
    |> request.set_host("::1")
    |> request.set_port(1)
    |> request.set_path("/")
    |> request.set_body(<<>>)

  let assert Error(transport.Other(_)) =
    erlang_transport.default().request(built)
}

/// The dial reaches OTP calls that raise rather than answer, `cacerts_get` on
/// a host with no CA store among them. That raise is rescued into this socket,
/// so it has to honour the same contract a refused dial does: no writes, the
/// reason, then one close.
pub fn a_dial_that_raised_comes_back_as_an_ending_socket_test() {
  let socket =
    websocket.failed("error: badarg at {public_key,cacerts_get,0,[]}")

  assert websocket.live(socket) == False

  let #(socket, events) = websocket.poll(socket, timeout: 0)

  assert events
    == [
      transport.Failed("error: badarg at {public_key,cacerts_get,0,[]}"),
      transport.Closed(1006, ""),
    ]
  assert websocket.finished(socket)
}
