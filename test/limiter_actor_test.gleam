import gleam/erlang/process
import gleam/http
import glyde/internal/limiter_actor.{Granted}
import glyde/internal/timing
import glyde/rest/limiter
import glyde/rest/route

fn a_route() -> route.Route {
  route.new(http.Post, "channels/1/messages", route.NoMajor, route.NoSublimit)
}

pub fn a_permit_is_granted_at_once_when_the_bucket_is_free_test() {
  let name = process.new_name("test_limiter")
  let assert Ok(started) = limiter_actor.start(name, timing.now, fn(_) { Nil })

  let assert Granted(ticket) =
    limiter_actor.acquire(started.data, a_route(), False)
  limiter_actor.settle(started.data, ticket, limiter.Opaque)
  process.send_exit(started.pid)
}

pub fn tickets_are_unique_across_callers_test() {
  let name = process.new_name("test_limiter")
  let assert Ok(started) = limiter_actor.start(name, timing.now, fn(_) { Nil })

  let assert Granted(a) = limiter_actor.acquire(started.data, a_route(), False)
  limiter_actor.settle(started.data, a, limiter.Opaque)
  let assert Granted(b) = limiter_actor.acquire(started.data, a_route(), False)
  limiter_actor.settle(started.data, b, limiter.Opaque)
  assert a != b
  process.send_exit(started.pid)
}
