//// The built-in adapter, at what needs no peer: a dial that is refused before
//// a packet goes out still has to honour the `transport.Socket` contract.

import gleam/option.{Some}
import glyde/internal/timing
import glyde/transport
import glyde/transport/erlang as erlang_transport

/// `ws://` is turned away before anything is dialled, so this touches no
/// network. The close it owes comes out of the first turn.
fn finished() -> transport.Socket {
  let socket = erlang_transport.default().open("ws://gateway.discord.gg/")
  let #(socket, events) = socket.turn(0)
  let assert [transport.Closed(1006, "", Some(transport.TransportFailed(_)))] =
    events
  socket
}

/// `turn` promises to block until the socket says something or the timeout
/// passes. A finished socket never says anything, so without a wait of its own
/// a runtime that keeps turning one spins a core flat.
pub fn turning_a_finished_socket_waits_out_the_timeout_test() {
  let socket = finished()

  let before = timing.now()
  let #(_socket, events) = socket.turn(50)

  assert events == []
  assert timing.now() - before >= 50
}

/// The wait is the timeout it was given, not a fixed one: a caller with a
/// deadline sooner than that must not be held past it.
pub fn a_finished_socket_waits_no_longer_than_asked_test() {
  let socket = finished()

  let before = timing.now()
  let #(_socket, _) = socket.turn(0)

  assert timing.now() - before < 1000
}
