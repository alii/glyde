import gleam/int
import gleam/list
import gleam/option.{None, Some}
import glyde/testing.{type Machine, type Run}

// A miniature of the gateway's connection lifecycle. `guarded` drops a
// handshake from an abandoned connection, `phase_only` does not.

type Timer {
  Retry
  Beat
}

type Phase {
  Live(conn: Int)
  Waiting
}

type Toy {
  Toy(
    phase: Phase,
    conn: Int,
    /// The arming each timer is on. A firing from an older one is stale.
    /// `-1` means the timer is not armed.
    retry: Int,
    beat: Int,
    next_stamp: Int,
  )
}

type In {
  /// The peer said something on `conn`.
  Frame(conn: Int)
  /// The heartbeat went unanswered. Tear the socket down.
  Zombie
  /// `conn` finished its handshake.
  Ready(conn: Int)
  Fired(timer: Timer, stamp: Int)
}

type Out {
  Dial(conn: Int)
  Shut(conn: Int)
  Arm(timer: Timer, in_ms: Int, stamp: Int)
  Cancel(timer: Timer)
  Note(String)
}

fn connected() -> Toy {
  Toy(phase: Live(1), conn: 1, retry: -1, beat: 0, next_stamp: 1)
}

fn is_note(output: Out) -> Bool {
  case output {
    Note(_) -> True
    _ -> False
  }
}

fn guarded() -> Machine(Toy, In, Out) {
  fn(toy, input) { step(toy, input, guard_ready: True) }
}

fn phase_only() -> Machine(Toy, In, Out) {
  fn(toy, input) { step(toy, input, guard_ready: False) }
}

fn step(
  toy: Toy,
  input: In,
  guard_ready guard_ready: Bool,
) -> #(Toy, List(Out)) {
  case input {
    // A frame proves the connection is alive, so the beat starts over.
    Frame(conn) ->
      case conn == toy.conn {
        False -> #(toy, [Note("stale frame")])
        True -> {
          let stamp = toy.next_stamp
          #(Toy(..toy, beat: stamp, next_stamp: stamp + 1), [
            Arm(Beat, 40, stamp),
          ])
        }
      }

    Zombie ->
      case toy.phase {
        Live(conn) if conn == toy.conn -> {
          let stamp = toy.next_stamp
          #(
            Toy(
              ..toy,
              phase: Waiting,
              conn: toy.conn + 1,
              retry: stamp,
              next_stamp: stamp + 1,
            ),
            [Shut(conn), Arm(Retry, 1000, stamp)],
          )
        }
        _ -> #(toy, [Note("nothing to tear down")])
      }

    // The one difference: `phase_only` cancels the retry that was already armed.
    Ready(conn) ->
      case guard_ready && conn != toy.conn {
        True -> #(toy, [Note("stale ready")])
        False -> {
          let stamp = toy.next_stamp
          #(
            Toy(
              ..toy,
              phase: Live(conn),
              retry: -1,
              beat: stamp,
              next_stamp: stamp + 1,
            ),
            [Cancel(Retry), Arm(Beat, 40, stamp)],
          )
        }
      }

    Fired(Retry, stamp) ->
      case stamp == toy.retry {
        False -> #(toy, [Note("stale retry")])
        True -> #(Toy(..toy, retry: -1), [Dial(toy.conn)])
      }

    Fired(Beat, stamp) ->
      case stamp == toy.beat {
        False -> #(toy, [Note("stale beat")])
        True -> {
          let next = toy.next_stamp
          #(Toy(..toy, beat: next, next_stamp: next + 1), [
            Arm(Beat, 40, next),
          ])
        }
      }
  }
}

fn timers() -> testing.Timers(In, Out, Timer) {
  testing.Timers(effect: fn(output) {
    case output {
      Arm(timer:, in_ms:, stamp:) ->
        Some(testing.Arms(timer:, in_ms:, fires: Fired(timer, stamp)))
      Cancel(timer) -> Some(testing.Cancels(timer))
      _ -> None
    }
  })
}

/// Live on a connection it has already abandoned means no socket and nothing
/// scheduled.
fn never_live_on_abandoned(run: Run(Toy, Out)) -> Bool {
  case run.state.phase {
    Live(conn) -> conn == run.state.conn
    Waiting -> True
  }
}

/// What has to agree across orderings, which is not the stamp counter: that
/// differs with how many timers an ordering armed.
fn destination(run: Run(Toy, Out)) -> #(Phase, Int) {
  #(run.state.phase, run.state.conn)
}

/// The three inputs of the ordering hazard, written in the order that hides
/// it. Fed straight through, this machine looks correct.
fn hazard() -> List(In) {
  [Ready(1), Zombie, Frame(1)]
}

pub fn drive_folds_and_keeps_output_order_test() {
  let run = testing.drive(guarded(), connected(), [Zombie, Frame(1)])

  assert run.outputs == [Shut(1), Arm(Retry, 1000, 1), Note("stale frame")]
  assert run.state == Toy(Waiting, conn: 2, retry: 1, beat: 0, next_stamp: 2)
}

pub fn drive_over_nothing_changes_nothing_test() {
  let run = testing.drive(guarded(), connected(), [])

  assert run == testing.Run(state: connected(), outputs: [])
}

pub fn without_notes_leaves_the_protocol_effects_test() {
  let run = testing.drive(guarded(), connected(), [Zombie, Frame(1), Ready(1)])

  assert testing.without_notes(is_note, run.outputs)
    == [Shut(1), Arm(Retry, 1000, 1)]
}

pub fn notes_are_assertable_on_their_own_test() {
  let run = testing.drive(guarded(), connected(), [Zombie, Frame(1), Ready(1)])

  assert testing.notes(is_note, run.outputs)
    == [Note("stale frame"), Note("stale ready")]
}

pub fn a_machine_with_no_diagnostics_strips_nothing_test() {
  let counter = fn(n, i) { #(n + i, [n]) }
  let none_are_notes = fn(_) { False }
  let run = testing.drive(counter, 0, [1, 2])

  assert testing.without_notes(none_are_notes, run.outputs) == run.outputs
  assert testing.notes(none_are_notes, run.outputs) == []
}

pub fn orderings_are_lexicographic_by_position_test() {
  assert testing.orderings([1, 2, 3])
    == [[1, 2, 3], [1, 3, 2], [2, 1, 3], [2, 3, 1], [3, 1, 2], [3, 2, 1]]
}

pub fn orderings_of_nothing_is_one_empty_ordering_test() {
  assert testing.orderings([]) == [[]]
  assert testing.orderings(["a"]) == [["a"]]
  assert testing.orderings(["a", "b"]) == [["a", "b"], ["b", "a"]]
}

pub fn the_identity_ordering_comes_first_test() {
  let items = [1, 2, 3, 4, 5]
  let assert [first, ..] = testing.orderings(items)

  assert first == items
}

pub fn there_are_factorially_many_test() {
  let table = [
    #(0, 1),
    #(1, 1),
    #(2, 2),
    #(3, 6),
    #(4, 24),
    #(5, 120),
    #(6, 720),
  ]

  list.each(table, fn(row) {
    let #(size, expected) = row
    assert list.length(testing.orderings(list.repeat(Nil, size))) == expected
  })
}

pub fn every_ordering_is_a_rearrangement_test() {
  let items = [1, 2, 3, 4]

  list.each(testing.orderings(items), fn(ordering) {
    assert list.sort(ordering, by: int.compare) == items
  })
}

pub fn a_correct_guard_holds_in_every_ordering_test() {
  assert testing.every_ordering(
      guarded(),
      connected(),
      hazard(),
      never_live_on_abandoned,
    )
    == testing.Held
}

/// Driven straight through, the broken machine looks fine.
pub fn the_ordering_that_hides_the_bug_passes_on_its_own_test() {
  let run = testing.drive(phase_only(), connected(), hazard())

  assert never_live_on_abandoned(run)
}

pub fn every_ordering_finds_it_and_names_it_test() {
  assert testing.every_ordering(
      phase_only(),
      connected(),
      hazard(),
      never_live_on_abandoned,
    )
    == testing.Broke(
      ordering: [Zombie, Ready(1), Frame(1)],
      broke_after: [Zombie, Ready(1)],
      run: testing.drive(phase_only(), connected(), [Zombie, Ready(1)]),
    )
}

/// Three of the six orderings break, and the one reported is the one that
/// needed the fewest inputs rather than the first the enumeration reached.
pub fn the_shortest_break_is_the_one_reported_test() {
  let assert testing.Broke(ordering:, broke_after:, ..) =
    testing.every_ordering(
      phase_only(),
      connected(),
      hazard(),
      never_live_on_abandoned,
    )

  assert list.length(broke_after) < list.length(ordering)

  let breaking =
    testing.orderings(hazard())
    |> list.filter(fn(candidate) {
      !never_live_on_abandoned(testing.drive(
        phase_only(),
        connected(),
        candidate,
      ))
    })

  assert list.length(breaking) == 3
}

pub fn a_starting_state_that_already_fails_breaks_after_nothing_test() {
  let broken = Toy(..connected(), phase: Live(9))

  assert testing.every_ordering(
      guarded(),
      broken,
      [Frame(1), Zombie],
      never_live_on_abandoned,
    )
    == testing.Broke(
      ordering: [Frame(1), Zombie],
      broke_after: [],
      run: testing.Run(state: broken, outputs: []),
    )
}

/// A liveness property is false before anything happens, which is why
/// `every_ordering` asks for a safety property.
pub fn a_liveness_invariant_breaks_before_it_starts_test() {
  let eventually_torn_down = fn(run: Run(Toy, Out)) {
    list.any(run.outputs, fn(output) {
      case output {
        Shut(_) -> True
        _ -> False
      }
    })
  }

  let assert testing.Broke(broke_after:, run:, ..) =
    testing.every_ordering(
      guarded(),
      connected(),
      hazard(),
      eventually_torn_down,
    )

  assert broke_after == []
  assert run == testing.Run(state: connected(), outputs: [])
}

pub fn an_invariant_that_always_holds_needs_no_inputs_test() {
  assert testing.every_ordering(guarded(), connected(), [], fn(_) { True })
    == testing.Held
}

pub fn the_runner_refuses_more_inputs_than_it_can_permute_test() {
  let too_many = list.repeat(Frame(1), testing.max_permuted + 1)

  assert testing.every_ordering(
      guarded(),
      connected(),
      too_many,
      never_live_on_abandoned,
    )
    == testing.Refused(testing.TooManyToPermute(testing.max_permuted + 1))
}

pub fn the_cap_itself_runs_test() {
  let inputs = list.repeat(Frame(1), testing.max_permuted)

  assert testing.every_ordering(guarded(), connected(), inputs, fn(_) { True })
    == testing.Held
}

pub fn every_ordering_converges_when_the_guard_is_right_test() {
  let assert Ok(groups) =
    testing.outcomes(guarded(), connected(), hazard(), destination)

  assert groups
    == [
      testing.Outcome(
        observed: #(Waiting, 2),
        orderings: testing.orderings(hazard()),
      ),
    ]
}

/// Convergence catches the bug with no invariant written down first.
pub fn a_broken_guard_makes_the_orderings_disagree_test() {
  let assert Ok(groups) =
    testing.outcomes(phase_only(), connected(), hazard(), destination)

  assert list.map(groups, fn(group) { group.observed })
    == [#(Waiting, 2), #(Live(1), 2)]

  let assert [settled, wedged] = groups
  assert list.length(settled.orderings) == 3
  assert wedged.orderings
    == [
      [Zombie, Ready(1), Frame(1)],
      [Zombie, Frame(1), Ready(1)],
      [Frame(1), Zombie, Ready(1)],
    ]
}

/// The stamp counter depends on how many timers an ordering armed, so the
/// caller picks what has to agree.
pub fn a_finer_observation_can_disagree_without_a_bug_test() {
  let assert Ok(groups) =
    testing.outcomes(guarded(), connected(), hazard(), testing.final_state)

  assert list.length(groups) > 1
}

pub fn outcomes_refuses_the_same_size_the_runner_does_test() {
  let too_many = list.repeat(Frame(1), testing.max_permuted + 1)

  assert testing.outcomes(guarded(), connected(), too_many, destination)
    == Error(testing.TooManyToPermute(testing.max_permuted + 1))
}

pub fn outcomes_of_no_inputs_is_one_empty_ordering_test() {
  let assert Ok(groups) =
    testing.outcomes(guarded(), connected(), [], destination)

  assert groups == [testing.Outcome(observed: #(Live(1), 1), orderings: [[]])]
}

fn started() -> testing.Clock(Toy, In, Out, Timer) {
  testing.clock(connected())
}

/// Why `Timers` is passed beside the machine and not stored in the clock: a
/// clock is plain data, so a whole state is one assertion against a literal.
pub fn a_clock_is_a_value_you_can_write_down_test() {
  let clock = testing.feed(guarded(), timers(), started(), Zombie)

  assert clock
    == testing.Clock(
      now_ms: 0,
      state: Toy(Waiting, conn: 2, retry: 1, beat: 0, next_stamp: 2),
      outputs: [Shut(1), Arm(Retry, 1000, 1)],
      armed: [testing.Armed(timer: Retry, at_ms: 1000, fires: Fired(Retry, 1))],
    )
}

pub fn a_new_clock_is_at_zero_with_nothing_armed_test() {
  let clock = started()

  assert clock.now_ms == 0
  assert clock.armed == []
  assert clock.outputs == []
}

pub fn feeding_arms_what_the_outputs_asked_for_test() {
  let clock = testing.feed(guarded(), timers(), started(), Zombie)

  assert clock.outputs == [Shut(1), Arm(Retry, 1000, 1)]
  assert testing.armed_at(clock, Retry) == Some(1000)
  assert testing.armed_at(clock, Beat) == None
}

pub fn arming_a_timer_replaces_the_arming_before_it_test() {
  let clock =
    testing.feed_all(guarded(), timers(), started(), [Ready(1), Fired(Beat, 1)])

  assert testing.armed_at(clock, Beat) == Some(40)
  assert list.length(clock.armed) == 1
}

pub fn cancelling_disarms_test() {
  let clock =
    testing.feed_all(guarded(), timers(), started(), [Zombie, Ready(2)])

  assert testing.armed_at(clock, Retry) == None
  assert testing.armed_at(clock, Beat) == Some(40)
}

/// A test writing the firing by hand has to guess the stamp, and a wrong guess
/// is dropped as stale and passes for the wrong reason.
pub fn a_fired_timer_carries_the_stamp_it_was_armed_with_test() {
  let assert Ok(clock) =
    testing.feed(guarded(), timers(), started(), Zombie)
    |> testing.flush
    |> testing.advance(guarded(), timers(), _, 1000)

  assert clock.now_ms == 1000
  assert clock.outputs == [Dial(2)]
}

pub fn a_stamp_the_machine_did_not_hand_out_is_stale_test() {
  let clock =
    testing.feed_all(guarded(), timers(), started(), [Zombie, Fired(Retry, 99)])

  assert testing.notes(is_note, clock.outputs) == [Note("stale retry")]
}

pub fn advancing_short_of_a_deadline_fires_nothing_test() {
  let assert Ok(clock) =
    testing.feed(guarded(), timers(), started(), Zombie)
    |> testing.flush
    |> testing.advance(guarded(), timers(), _, 999)

  assert clock.now_ms == 999
  assert clock.outputs == []
  assert testing.armed_at(clock, Retry) == Some(1000)
}

pub fn advancing_to_next_lands_on_the_deadline_test() {
  let assert Ok(clock) =
    testing.feed(guarded(), timers(), started(), Ready(1))
    |> testing.flush
    |> testing.advance_to_next(guarded(), timers(), _)

  assert clock.now_ms == 40
  assert clock.outputs == [Arm(Beat, 40, 2)]
  assert testing.armed_at(clock, Beat) == Some(80)
}

pub fn advancing_to_next_with_nothing_armed_changes_nothing_test() {
  let clock = testing.feed(guarded(), timers(), started(), Frame(9))

  assert testing.advance_to_next(guarded(), timers(), clock) == Ok(clock)
}

/// A timer re-armed while advancing and still due inside the window fires in
/// the same call, the way an event loop drains its heap.
pub fn one_advance_drains_a_chain_of_deadlines_test() {
  let assert Ok(clock) =
    testing.feed(guarded(), timers(), started(), Ready(1))
    |> testing.flush
    |> testing.advance(guarded(), timers(), _, 100)

  assert clock.now_ms == 100
  assert clock.outputs == [Arm(Beat, 40, 2), Arm(Beat, 40, 3)]
  assert testing.armed_at(clock, Beat) == Some(120)
}

/// The retry is armed first, at 1000, and the beat second, at 40. Firing
/// order follows the deadline and not the arming.
pub fn deadlines_fire_soonest_first_test() {
  let clock =
    testing.feed_all(guarded(), timers(), started(), [Zombie, Frame(2)])

  assert testing.armed_at(clock, Retry) == Some(1000)
  assert testing.armed_at(clock, Beat) == Some(40)

  let assert Ok(clock) =
    testing.advance(guarded(), timers(), testing.flush(clock), 45)

  assert clock.now_ms == 45
  assert clock.outputs == [Arm(Beat, 40, 3)]
  assert testing.armed_at(clock, Retry) == Some(1000)
}

/// Two timers due at the same instant fire in the order they were armed,
/// which is the only rule that makes an output list assertable at all.
pub fn deadlines_that_tie_fire_in_arming_order_test() {
  let stopwatch = fn(fired: List(Timer), input) {
    case input {
      Fired(timer, _) -> #([timer, ..fired], [])
      _ -> #(fired, [Arm(Retry, 50, 1), Arm(Beat, 50, 2)])
    }
  }
  let assert Ok(clock) =
    testing.feed(stopwatch, timers(), testing.clock([]), Zombie)
    |> testing.advance(stopwatch, timers(), _, 50)

  assert clock.state == [Beat, Retry]
}

pub fn time_never_runs_backwards_test() {
  let assert Ok(clock) =
    testing.feed(guarded(), timers(), started(), Zombie)
    |> testing.advance(guarded(), timers(), _, -5000)

  assert clock.now_ms == 0
  assert testing.armed_at(clock, Retry) == Some(1000)
}

pub fn flush_forgets_the_outputs_and_nothing_else_test() {
  let before = testing.feed(guarded(), timers(), started(), Zombie)
  let after = testing.flush(before)

  assert after.outputs == []
  assert after.state == before.state
  assert after.now_ms == before.now_ms
  assert after.armed == before.armed
}

/// A machine that re-arms a zero delay would spin forever, and a suite that
/// hangs names nothing. The overrun is an `Error`, so a caller cannot thread
/// the clock on as if the advance had finished.
pub fn a_zero_delay_loop_overruns_instead_of_hanging_test() {
  let spinner = fn(n, _) { #(n + 1, [Arm(Beat, 0, 0)]) }
  let assert Error(testing.Stalled(clock:, fired:, still_due:)) =
    testing.feed(spinner, timers(), testing.clock(0), Frame(1))
    |> testing.advance(spinner, timers(), _, 10)

  // The count says the advance gave up rather than finished, without the
  // caller having to compare the clock against the one it handed in.
  assert fired == testing.max_firings
  assert still_due == 1

  assert clock.state > 1000
  // Time stopped where the firing did, so nothing is left armed in the past.
  assert clock.now_ms == 0
  assert testing.armed_at(clock, Beat) == Some(0)
}

pub fn a_machine_that_arms_nothing_still_keeps_time_test() {
  let counter = fn(n, i) { #(n + i, []) }
  let assert Ok(clock) =
    testing.feed(counter, testing.no_timers(), testing.clock(0), 5)
    |> testing.advance(counter, testing.no_timers(), _, 1000)

  assert clock.now_ms == 1000
  assert clock.state == 5
  assert clock.armed == []
}
