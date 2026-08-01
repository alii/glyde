//// Only what needs no peer: the close codes, and the events a dial that never
//// connected still owes the caller.

import gleam/dynamic.{type Dynamic}
import gleam/list
import glyde/transport
import glyde/websocket

pub fn close_code_is_1000_and_the_private_range_test() {
  assert websocket.close_code(1000) |> ok
  assert websocket.close_code(3000) |> ok
  assert websocket.close_code(4000) |> ok
  assert websocket.close_code(4999) |> ok

  assert websocket.close_code(1001) == Error(1001)
  assert websocket.close_code(1005) == Error(1005)
  assert websocket.close_code(1006) == Error(1006)
  assert websocket.close_code(2999) == Error(2999)
  assert websocket.close_code(5000) == Error(5000)
  assert websocket.close_code(0) == Error(0)
  assert websocket.close_code(-1) == Error(-1)
}

fn ok(made: Result(websocket.CloseCode, Int)) -> Bool {
  case made {
    Ok(_) -> True
    Error(_) -> False
  }
}

/// Refused before a socket is opened, so this touches no network.
fn undiallable() -> #(String, websocket.Socket) {
  let key = "undiallable"
  let _ = remember(key, [])
  #(key, websocket.open("ws://gateway.discord.gg/"))
}

/// The dial has already failed and the caller has still heard nothing.
pub fn open_reports_nothing_until_the_first_turn_test() {
  let #(key, socket) = undiallable()
  assert recall(key) == []
  assert !websocket.finished(socket)
}

pub fn a_failed_dial_arrives_as_failed_then_closed_test() {
  let #(key, socket) = undiallable()
  let socket = websocket.turn(socket, timeout: 0, report: collect(key))

  let assert [transport.Failed(reason), transport.Closed(code, "")] =
    list.reverse(recall(key))
  assert code == 1006
  assert reason == "bad url: only wss is supported: ws://gateway.discord.gg/"
  assert websocket.finished(socket)
}

/// Turning a finished socket is how a reader loop learns it should stop.
pub fn turning_a_finished_socket_reports_nothing_test() {
  let #(key, socket) = undiallable()
  let socket = websocket.turn(socket, timeout: 0, report: collect(key))
  let _ = remember(key, [])

  let socket = websocket.turn(socket, timeout: 0, report: collect(key))
  let socket = websocket.turn(socket, timeout: 0, report: collect(key))
  assert recall(key) == []
  assert websocket.finished(socket)
}

/// None of them raises, and none of them puts the socket back up.
pub fn a_socket_that_never_connected_refuses_every_write_test() {
  let #(_, socket) = undiallable()
  let assert Ok(bye) = websocket.close_code(1000)
  let assert Ok(resumable) = websocket.close_code(4000)

  assert !websocket.live(socket)
  assert !websocket.live(websocket.send_text(socket, "hi"))
  assert !websocket.live(websocket.send_bytes(socket, <<1, 2, 3>>))
  assert !websocket.live(websocket.close(socket, bye, "bye"))
  assert !websocket.live(websocket.close(socket, resumable, ""))
  assert !websocket.live(websocket.drop(socket))
}

/// Refusing a write must not eat the close the caller is still owed.
pub fn a_refused_write_still_owes_the_close_test() {
  let #(key, socket) = undiallable()
  let socket = websocket.send_text(socket, "hi")
  let socket = websocket.drop(socket)
  let socket = websocket.turn(socket, timeout: 0, report: collect(key))

  let assert [transport.Failed(_), transport.Closed(1006, "")] =
    list.reverse(recall(key))
  assert websocket.finished(socket)
}

/// A callback has nowhere to put what it is handed, so the process dictionary
/// stands in for a mutable cell. A test is the one place that is not a mistake.
fn collect(key: String) -> fn(transport.Event) -> Nil {
  fn(event) {
    let _ = remember(key, [event, ..recall(key)])
    Nil
  }
}

@external(erlang, "erlang", "put")
fn remember(key: String, events: List(transport.Event)) -> Dynamic

/// Newest first. Safe only after a `remember`: a missing key answers with an
/// atom, not a list.
@external(erlang, "erlang", "get")
fn recall(key: String) -> List(transport.Event)
