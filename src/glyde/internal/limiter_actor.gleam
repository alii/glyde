//// The pure `rest/limiter` behind an actor, so any process can ask for a
//// permit and block until one is granted.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Monitor, type Name, type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import glyde/rest/limiter.{type Limiter, type Outcome, type Refusal, type Ticket}
import glyde/rest/route.{type Route}

pub type Message {
  /// Ask for a permit. The reply arrives once the limiter says go, which may
  /// be at once or after a wait the actor times itself.
  Acquire(route: Route, retry: Bool, caller: Pid, reply: Subject(Verdict))
  /// Report what one sent request came back as.
  Settle(ticket: Ticket, outcome: Outcome)
  /// A caller went away. Its ticket is freed so the bucket is not stuck.
  CallerDown(process.Down)
  Tick
}

pub type Verdict {
  Granted(Ticket)
  Refused(Refusal)
}

type State {
  State(
    limiter: Limiter,
    next: Int,
    waiting: Dict(Ticket, Subject(Verdict)),
    /// Granted but not yet settled. If the caller dies here the ticket must
    /// be abandoned or a probing bucket is stranded forever.
    inflight: Dict(Pid, Ticket),
    monitors: Dict(Ticket, Monitor),
    /// The next armed Tick, so N acquires on one bucket do not arm N timers.
    wake_at: Option(Int),
    now: fn() -> Int,
    self: Subject(Message),
    report: fn(limiter.Notice) -> Nil,
  )
}

pub fn start(
  name: Name(Message),
  now: fn() -> Int,
  report: fn(limiter.Notice) -> Nil,
) -> actor.StartResult(Subject(Message)) {
  actor.new_with_initialiser(1000, fn(self) {
    let selector =
      process.new_selector()
      |> process.select(self)
      |> process.select_monitors(CallerDown)
    State(
      limiter: limiter.new(limiter.defaults()),
      next: 0,
      waiting: dict.new(),
      inflight: dict.new(),
      monitors: dict.new(),
      wake_at: None,
      now:,
      self:,
      report:,
    )
    |> actor.initialised
    |> actor.selecting(selector)
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.named(name)
  |> actor.start
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Acquire(route:, retry:, caller:, reply:) -> {
      let ticket = limiter.Ticket(state.next)
      let monitor = process.monitor(caller)
      let state =
        State(
          ..state,
          next: state.next + 1,
          waiting: dict.insert(state.waiting, ticket, reply),
          inflight: dict.insert(state.inflight, caller, ticket),
          monitors: dict.insert(state.monitors, ticket, monitor),
        )
      let input = case retry {
        False -> limiter.Submit(ticket:, route:)
        // Front of the queue, so a retry is not reordered behind newer work.
        True -> limiter.Retry(ticket:, route:)
      }
      feed(state, input)
    }
    Settle(ticket:, outcome:) -> {
      let state = forget(state, ticket)
      feed(state, limiter.Settled(ticket, outcome))
    }
    CallerDown(process.ProcessDown(pid:, ..)) ->
      case dict.get(state.inflight, pid) {
        Ok(ticket) -> {
          let state = forget(state, ticket)
          feed(state, limiter.Abandoned(ticket))
        }
        Error(_) -> actor.continue(state)
      }
    CallerDown(_) -> actor.continue(state)
    Tick -> feed(State(..state, wake_at: None), limiter.Tick)
  }
}

fn forget(state: State, ticket: Ticket) -> State {
  case dict.get(state.monitors, ticket) {
    Ok(monitor) -> process.demonitor_process(monitor)
    Error(_) -> Nil
  }
  State(
    ..state,
    waiting: dict.delete(state.waiting, ticket),
    monitors: dict.delete(state.monitors, ticket),
    inflight: dict.filter(state.inflight, fn(_, t) { t != ticket }),
  )
}

fn feed(state: State, input: limiter.Input) -> actor.Next(State, Message) {
  let #(limiter, outputs) =
    limiter.step(state.limiter, now_ms: state.now(), input:)
  let state = State(..state, limiter:)
  actor.continue(list.fold(outputs, state, apply))
}

fn apply(state: State, output: limiter.Output) -> State {
  case output {
    limiter.Send(ticket) -> answer(state, ticket, Granted(ticket))
    limiter.Refuse(ticket, why) -> {
      let state = forget(state, ticket)
      answer(state, ticket, Refused(why))
    }
    limiter.Wake(in_ms) -> {
      let due = state.now() + in_ms
      case state.wake_at {
        Some(at) if at <= due -> state
        _ -> {
          let _ = process.send_after(state.self, in_ms, Tick)
          State(..state, wake_at: Some(due))
        }
      }
    }
    limiter.Note(notice) -> {
      state.report(notice)
      state
    }
  }
}

fn answer(state: State, ticket: Ticket, verdict: Verdict) -> State {
  case dict.get(state.waiting, ticket) {
    Ok(reply) -> {
      process.send(reply, verdict)
      State(..state, waiting: dict.delete(state.waiting, ticket))
    }
    Error(_) -> state
  }
}

/// Block until the limiter grants a permit for `route` or refuses it. The
/// caller is a handler process of its own, so waiting here holds up nothing
/// but this one call.
pub fn acquire(
  limiter: Subject(Message),
  route: Route,
  retry: Bool,
) -> Verdict {
  let caller = process.self()
  process.call_forever(limiter, Acquire(route:, retry:, caller:, reply: _))
}

pub fn settle(
  limiter: Subject(Message),
  ticket: Ticket,
  outcome: Outcome,
) -> Nil {
  process.send(limiter, Settle(ticket:, outcome:))
}
