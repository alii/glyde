//// A harness for driving a sans-IO state machine, and for running every
//// ordering of a set of inputs against an invariant.
////
//// It drives any machine of the shape state plus input gives a new state and a
//// list of outputs, which is glyde's three and any of yours built the same way.
////
//// ```gleam
//// let gw = fn(shard, input) {
////   let gateway.Step(shard:, outputs:) = gateway.step(shard, input)
////   #(shard, outputs)
//// }
////
//// let inputs = [zombie_beat, peer_close, late_resumed]
//// assert testing.every_ordering(gw, shard, inputs, fn(run) {
////     list.count(run.outputs, is_open) <= 1
////   })
////   == Ok(testing.Held)
//// ```
////
//// Hold time still across a permutation run: a machine that reads a clock out
//// of its own state sees timestamped inputs out of time order otherwise.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// A state machine this harness can drive: one input, a new state and whatever
/// it emitted on the way. Timer wiring is a separate `Timers`, and classifying
/// an output is an argument to `without_notes`.
pub type Machine(state, input, output) =
  fn(state, input) -> #(state, List(output))

/// Where a machine ended up and everything it emitted getting there.
pub type Run(state, output) {
  Run(state: state, outputs: List(output))
}

/// Fold the inputs through the machine, keeping every output in the order it
/// came out.
pub fn drive(
  machine: Machine(state, input, output),
  state: state,
  inputs: List(input),
) -> Run(state, output) {
  let #(state, reversed) =
    list.fold(inputs, #(state, []), fn(acc, input) {
      let #(state, seen) = acc
      let #(state, outputs) = machine(state, input)
      #(state, list.fold(outputs, seen, fn(seen, output) { [output, ..seen] }))
    })
  Run(state:, outputs: list.reverse(reversed))
}

/// Drop the diagnostics, so a table row asserts the protocol effects and
/// nothing else.
///
/// `is_note` is True for outputs that are diagnostics and never
/// protocol-significant. `fn(_) { False }` for a machine that emits none.
pub fn without_notes(
  is_note: fn(output) -> Bool,
  outputs: List(output),
) -> List(output) {
  list.filter(outputs, fn(output) { !is_note(output) })
}

/// The most inputs the runners below will permute. Eight is 40 320 orderings
/// and nine is nine times that, so eight is our choice.
pub const max_permuted: Int = 8

/// Every ordering of `items`: the identity first, then by the position each
/// item held. The order is part of this module's contract, so it is enumerated
/// here rather than delegated to stdlib, which promises no order.
///
/// `n` items give `n!` orderings, and unlike the runners this refuses nothing.
pub fn orderings(items: List(a)) -> List(List(a)) {
  permute(items)
}

/// Pick each item as the head in turn and recurse on the rest, giving
/// lexicographic order by original position with the identity first.
fn permute(items: List(a)) -> List(List(a)) {
  case items {
    [] -> [[]]
    _ ->
      list.index_map(items, fn(head, i) {
        let rest = list.append(list.take(items, i), list.drop(items, i + 1))
        list.map(permute(rest), fn(tail) { [head, ..tail] })
      })
      |> list.flatten
  }
}

/// Why both runners refuse a set of inputs, rather than hang on it.
pub type TooMany {
  /// `n!` orderings of this many inputs is not a test, it is a hang.
  TooManyToPermute(inputs: Int)
}

/// What every ordering of a set of inputs did to an invariant.
pub type Verdict(state, input, output) {
  /// Every ordering satisfied it.
  Held

  /// One did not, and here it is.
  Broke(
    /// The full ordering. Hand it back to `drive` to reproduce.
    ordering: List(input),
    /// The shortest prefix of `ordering` that already broke the invariant.
    /// Empty means the starting state was already failing.
    broke_after: List(input),
    /// The run of `broke_after`.
    run: Run(state, output),
  )
}

/// Every ordering of `inputs`, or the refusal both runners answer with.
fn permutable(inputs: List(input)) -> Result(List(List(input)), TooMany) {
  let count = list.length(inputs)
  case count > max_permuted {
    True -> Error(TooManyToPermute(count))
    False -> Ok(orderings(inputs))
  }
}

/// Run every ordering of `inputs` from `state`, checking `invariant` on the
/// starting state and after every input.
///
/// It must be a safety property. A liveness one is false at the start, so every
/// ordering comes back `Broke(broke_after: [])`.
///
/// The shortest break is reported, and among equals the earliest ordering.
pub fn every_ordering(
  machine: Machine(state, input, output),
  state: state,
  inputs: List(input),
  invariant: fn(Run(state, output)) -> Bool,
) -> Result(Verdict(state, input, output), TooMany) {
  use orderings <- result.map(permutable(inputs))

  list.fold(orderings, Held, fn(best, ordering) {
    case first_break(machine, state, ordering, invariant) {
      None -> best
      Some(#(broke_after, run)) ->
        case best {
          Held -> Broke(ordering:, broke_after:, run:)
          // A tie keeps `best`, so the earliest ordering wins.
          Broke(broke_after: shortest, ..) ->
            case list.length(broke_after) < list.length(shortest) {
              True -> Broke(ordering:, broke_after:, run:)
              False -> best
            }
        }
    }
  })
}

/// The shortest prefix of `ordering` whose run fails `invariant`. An empty
/// answer means the starting state failed.
fn first_break(
  machine: Machine(state, input, output),
  state: state,
  ordering: List(input),
  invariant: fn(Run(state, output)) -> Bool,
) -> Option(#(List(input), Run(state, output))) {
  break_loop(machine, Run(state:, outputs: []), ordering, [], invariant)
}

fn break_loop(
  machine: Machine(state, input, output),
  run: Run(state, output),
  remaining: List(input),
  taken: List(input),
  invariant: fn(Run(state, output)) -> Bool,
) -> Option(#(List(input), Run(state, output))) {
  case invariant(run) {
    False -> Some(#(list.reverse(taken), run))
    True ->
      case remaining {
        [] -> None
        [input, ..rest] -> {
          let #(state, outputs) = machine(run.state, input)
          let run = Run(state:, outputs: list.append(run.outputs, outputs))
          break_loop(machine, run, rest, [input, ..taken], invariant)
        }
      }
  }
}

/// One distinct result, and every ordering that produced it.
pub type Outcome(input, observation) {
  Outcome(observed: observation, orderings: List(List(input)))
}

/// Run every ordering of `inputs` and group them by what `observe` makes of
/// each run.
///
/// One group means every ordering converged, which is the question an invariant
/// cannot answer: you have to have thought of a failure to assert against it.
///
/// Groups come out in first-seen order and orderings within a group in
/// enumeration order. Grouping is by `==` on the observation.
pub fn outcomes(
  machine: Machine(state, input, output),
  state: state,
  inputs: List(input),
  observe: fn(Run(state, output)) -> observation,
) -> Result(List(Outcome(input, observation)), TooMany) {
  use orderings <- result.map(permutable(inputs))

  orderings
  |> list.fold([], fn(groups, ordering) {
    group(groups, ordering, observe(drive(machine, state, ordering)))
  })
  |> list.reverse
  |> list.map(fn(outcome) {
    Outcome(..outcome, orderings: list.reverse(outcome.orderings))
  })
}

/// Newest group first and newest ordering first, both undone by the caller. A
/// linear scan, because a `Dict` has no specified iteration order.
fn group(
  groups: List(Outcome(input, observation)),
  ordering: List(input),
  observed: observation,
) -> List(Outcome(input, observation)) {
  case list.any(groups, fn(outcome) { outcome.observed == observed }) {
    False -> [Outcome(observed:, orderings: [ordering]), ..groups]
    True ->
      list.map(groups, fn(outcome) {
        case outcome.observed == observed {
          True -> Outcome(..outcome, orderings: [ordering, ..outcome.orderings])
          False -> outcome
        }
      })
  }
}

/// How a test wants the machine's timer outputs recognised.
///
/// Without this a test writes `Fired(Reconnect, Stamp(1))` by hand, and a
/// guessed stamp is dropped as stale while the test asserts the silence.
///
/// ```gleam
/// let timers =
///   testing.Timers(effect: fn(output) {
///     case output {
///       gateway.ArmTimer(timer:, in_ms:, stamp:) ->
///         Some(testing.Arms(
///           timer:,
///           in_ms:,
///           fires: gateway.Fired(timer, stamp),
///         ))
///       gateway.CancelTimer(timer) -> Some(testing.Cancels(timer))
///       _ -> None
///     }
///   })
/// ```
pub type Timers(input, output, timer) {
  Timers(
    /// What this output does to the timer table, if it touches it at all.
    effect: fn(output) -> Option(TimerEffect(input, timer)),
  )
}

/// What one output does to the timer table. One or the other: a single output
/// arms a timer or cancels one, and there is no way to say both.
pub type TimerEffect(input, timer) {
  /// A timer the machine asked for, and the input that firing it delivers.
  Arms(timer: timer, in_ms: Int, fires: input)
  Cancels(timer: timer)
}

/// A timer waiting to fire, at an absolute time on the clock.
pub type Armed(input, timer) {
  Armed(timer: timer, at_ms: Int, fires: input)
}

/// For a machine that arms nothing. The clock then only tracks time.
pub fn no_timers() -> Timers(input, output, timer) {
  Timers(effect: fn(_) { None })
}

/// The time, the state, what the machine has emitted, and the timers it is
/// waiting on. Time moves only when you move it, and never backwards.
///
/// `Timers` is passed to `feed` and `advance` rather than stored here: a record
/// holding a closure cannot be compared against a literal.
pub type Clock(state, input, output, timer) {
  Clock(
    now_ms: Int,
    state: state,
    /// Everything emitted since the clock was made, or since `flush`.
    outputs: List(output),
    /// Waiting timers, soonest first. Two due at the same instant fire in the
    /// order they were armed.
    armed: List(Armed(input, timer)),
  )
}

/// Timers one `advance` fires before it gives up. Our choice: far above any
/// real chain of deadlines, far below a hang.
pub const max_firings: Int = 1000

/// `advance` gave up: `fired` timers went off and `still_due` were due before
/// the deadline, which is a machine re-arming a zero delay.
///
/// The clock is the one the firing stopped on, so time has not reached the
/// deadline and nothing armed is in the past.
pub type Stall(state, input, output, timer) {
  Stalled(clock: Clock(state, input, output, timer), fired: Int, still_due: Int)
}

/// A clock at zero holding `state`, with nothing armed.
pub fn clock(state: state) -> Clock(state, input, output, timer) {
  Clock(now_ms: 0, state:, outputs: [], armed: [])
}

/// Deliver one input at the current time, then apply whatever its outputs
/// said about timers.
pub fn feed(
  machine: Machine(state, input, output),
  timers: Timers(input, output, timer),
  clock: Clock(state, input, output, timer),
  input: input,
) -> Clock(state, input, output, timer) {
  let #(state, outputs) = machine(clock.state, input)
  let armed =
    list.fold(outputs, clock.armed, fn(armed, output) {
      retime(timers, clock.now_ms, armed, output)
    })
  Clock(..clock, state:, outputs: list.append(clock.outputs, outputs), armed:)
}

/// Deliver several inputs at the current time, in order.
pub fn feed_all(
  machine: Machine(state, input, output),
  timers: Timers(input, output, timer),
  clock: Clock(state, input, output, timer),
  inputs: List(input),
) -> Clock(state, input, output, timer) {
  list.fold(inputs, clock, fn(clock, input) {
    feed(machine, timers, clock, input)
  })
}

/// Move time forward, firing every timer that comes due, soonest first.
///
/// A timer armed while advancing and still due before the new time fires in
/// the same call, as a real event loop does. `by_ms` below zero is zero.
///
/// `Error(Stalled(..))` once `max_firings` have gone off with more still due,
/// which is a machine re-arming a zero delay.
pub fn advance(
  machine: Machine(state, input, output),
  timers: Timers(input, output, timer),
  clock: Clock(state, input, output, timer),
  by_ms: Int,
) -> Result(
  Clock(state, input, output, timer),
  Stall(state, input, output, timer),
) {
  fire_until(machine, timers, clock, clock.now_ms + int.max(0, by_ms), 0)
}

/// Move time to the soonest armed deadline and fire it, along with anything
/// else due at that instant. No change when nothing is armed.
pub fn advance_to_next(
  machine: Machine(state, input, output),
  timers: Timers(input, output, timer),
  clock: Clock(state, input, output, timer),
) -> Result(
  Clock(state, input, output, timer),
  Stall(state, input, output, timer),
) {
  case clock.armed {
    [] -> Ok(clock)
    [next, ..] -> advance(machine, timers, clock, next.at_ms - clock.now_ms)
  }
}

/// When `timer` is next due, as an absolute time on this clock.
pub fn armed_at(
  clock: Clock(state, input, output, timer),
  timer: timer,
) -> Option(Int) {
  clock.armed
  |> list.find_map(fn(entry) {
    case entry.timer == timer {
      True -> Ok(entry.at_ms)
      False -> Error(Nil)
    }
  })
  |> option.from_result
}

/// Forget the outputs so far, so the next assertion covers only what the next
/// inputs produce. Time, state and armed timers are untouched.
pub fn flush(
  clock: Clock(state, input, output, timer),
) -> Clock(state, input, output, timer) {
  Clock(..clock, outputs: [])
}

fn fire_until(
  machine: Machine(state, input, output),
  timers: Timers(input, output, timer),
  clock: Clock(state, input, output, timer),
  deadline: Int,
  fired: Int,
) -> Result(
  Clock(state, input, output, timer),
  Stall(state, input, output, timer),
) {
  case clock.armed {
    [] -> Ok(Clock(..clock, now_ms: deadline))
    [next, ..rest] ->
      case next.at_ms <= deadline, fired < max_firings {
        False, _ -> Ok(Clock(..clock, now_ms: deadline))
        // The cap is spent with one still due, so time stops here rather than
        // stepping over a deadline it never fired.
        True, False ->
          Error(Stalled(
            clock:,
            fired:,
            still_due: list.count(clock.armed, fn(entry) {
              entry.at_ms <= deadline
            }),
          ))
        True, True -> {
          // Spent before it is delivered, so a machine that re-arms on fire
          // replaces nothing and one that does not is left with nothing.
          let stepped = Clock(..clock, now_ms: next.at_ms, armed: rest)
          fire_until(
            machine,
            timers,
            feed(machine, timers, stepped, next.fires),
            deadline,
            fired + 1,
          )
        }
      }
  }
}

fn retime(
  timers: Timers(input, output, timer),
  now_ms: Int,
  armed: List(Armed(input, timer)),
  output: output,
) -> List(Armed(input, timer)) {
  case timers.effect(output) {
    Some(Arms(timer:, in_ms:, fires:)) ->
      armed
      |> disarm(timer)
      |> schedule(Armed(timer:, at_ms: now_ms + in_ms, fires:))
    Some(Cancels(timer)) -> disarm(armed, timer)
    None -> armed
  }
}

fn disarm(
  armed: List(Armed(input, timer)),
  timer: timer,
) -> List(Armed(input, timer)) {
  list.filter(armed, fn(entry) { entry.timer != timer })
}

/// Soonest first, and after anything already due at the same instant, so ties
/// fire in the order they were armed.
fn schedule(
  armed: List(Armed(input, timer)),
  entry: Armed(input, timer),
) -> List(Armed(input, timer)) {
  case armed {
    [] -> [entry]
    [first, ..rest] ->
      case first.at_ms > entry.at_ms {
        True -> [entry, first, ..rest]
        False -> [first, ..schedule(rest, entry)]
      }
  }
}
