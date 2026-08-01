import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import glyde/client
import glyde/gateway
import glyde/gateway/close
import glyde/gateway/frame
import glyde/testing/adapter

/// The driver glyde ships passes its own conformance suite.
pub fn client_conforms_test() {
  let failures =
    adapter.run_all(adapter.over_client())
    |> list.filter(adapter.failed)
    |> list.map(adapter.describe)

  assert failures == []
}

pub fn every_scenario_ran_test() {
  let names = list.map(adapter.scenarios(), fn(scenario) { scenario.name })

  assert names
    == [
      "self-close echo",
      "handler re-enters",
      "lost ArmTimer",
      "stale fire",
      "peer close resumes",
    ]
}

/// A driver that answers its own close with the connection the shard moved on
/// to, not the one the socket was opened with.
pub fn fabricated_conn_is_caught_test() {
  let broken =
    adapter.Adapter(..adapter.over_client(), feed: fn(bot, input) {
      case input {
        gateway.Closed(_, code) -> client.closed(bot, client.conn(bot), code)
        _ -> client.feed(bot, input)
      }
    })

  assert diverged(adapter.run(scenario("self-close echo"), broken))
}

/// A driver whose timer wrapper treats a zero delay as nothing to arm.
pub fn dropped_zero_delay_arm_is_caught_test() {
  let broken =
    adapter.Adapter(..adapter.over_client(), start: fn(setup: adapter.Setup) {
      let honest = setup.transport
      adapter.over_client().start(
        adapter.Setup(
          ..setup,
          transport: client.Transport(..honest, arm: fn(world, timer, in_ms, s) {
            case in_ms {
              0 -> world
              _ -> honest.arm(world, timer, in_ms, s)
            }
          }),
        ),
      )
    })

  assert diverged(adapter.run(scenario("lost ArmTimer"), broken))
}

/// A driver that invents a stamp instead of echoing the one it was armed with,
/// turning every late firing into a real one.
pub fn invented_stamp_is_caught_test() {
  let broken =
    adapter.Adapter(..adapter.over_client(), feed: fn(bot, input) {
      case input {
        gateway.Fired(timer, _) ->
          client.feed(bot, gateway.Fired(timer, current_stamp(bot, timer)))
        _ -> client.feed(bot, input)
      }
    })

  assert diverged(adapter.run(scenario("stale fire"), broken))
}

fn current_stamp(
  bot: client.Bot(adapter.World),
  timer: gateway.Timer,
) -> gateway.Stamp {
  let stamps = client.shard(bot).stamps
  case timer {
    gateway.Heartbeat -> stamps.heartbeat
    gateway.Handshake -> stamps.handshake
    gateway.Reconnect -> stamps.reconnect
    gateway.Commands -> stamps.commands
  }
}

fn scenario(name: String) -> adapter.Scenario {
  let assert Ok(found) =
    list.find(adapter.scenarios(), fn(scenario) { scenario.name == name })
  found
}

fn diverged(report: adapter.Report) -> Bool {
  case report.verdict {
    adapter.Diverged(..) -> True
    _ -> False
  }
}

/// A beat the world cannot play names the beat rather than picking apart the
/// acts, and carries both traces so the acts that went missing are readable.
pub fn mis_ordered_beat_is_unplayable_test() {
  let lost_arm = scenario("lost ArmTimer")
  // `Connects` before anything has dialled: the first dial waits on a timer.
  let mis_ordered = adapter.Scenario(..lost_arm, beats: [adapter.Connects])

  let report = adapter.run(mis_ordered, adapter.over_client())

  assert report.verdict
    == adapter.Unplayable(
      at: 0,
      beat: adapter.Connects,
      trace: [
        adapter.Disarmed(gateway.Heartbeat),
        adapter.Disarmed(gateway.Handshake),
        adapter.Disarmed(gateway.Commands),
        adapter.Armed(gateway.Reconnect, 0),
      ],
      wanted: lost_arm.expect,
    )

  // The dial the trace stops short of is in the report, not left to be guessed.
  assert string.contains(adapter.describe(report), "  wanted 4: Dialled(")
}

/// An adapter that wires its own transport instead of passing the scripted one
/// through records nothing, so the first `Connects` has no socket to open. The
/// report must not send its author after a script glyde ships and they cannot
/// edit, and must show the acts their adapter never produced.
pub fn silent_transport_is_not_the_script_s_fault_test() {
  let deaf =
    adapter.Adapter(..adapter.over_client(), start: fn(setup: adapter.Setup) {
      adapter.over_client().start(
        adapter.Setup(..setup, transport: client.discarding()),
      )
    })

  let report = adapter.run(scenario("self-close echo"), deaf)
  let text = adapter.describe(report)

  let assert adapter.Unplayable(at:, beat:, trace:, wanted:) = report.verdict
  assert at == 1
  assert beat == adapter.Connects
  assert trace == []
  assert wanted == scenario("self-close echo").expect
  // The zero-delay arm and the dial it never made, which is the whole finding.
  assert string.contains(text, "  wanted 3: Armed(Reconnect, 0)")
  assert string.contains(text, "  wanted 4: Dialled(")
  assert !string.contains(text, "SCRIPT")
}

/// The recorder keeps opcodes, never frames, so a token cannot reach a trace.
pub fn traces_carry_no_token_test() {
  let world =
    adapter.recorder().send(
      adapter.blank(),
      frame.outbound(
        frame.OpIdentify,
        json.object([#("token", json.string("x"))]),
      ),
    )

  assert adapter.acts(world) == [adapter.Wrote(adapter.SentIdentify)]
}

/// The act is named by the opcode the frame was built with, never by reading
/// the text back, so a body the recorder cannot parse is not a thing that can
/// happen.
pub fn acts_are_named_by_the_frames_own_opcode_test() {
  let world =
    adapter.recorder().send(
      adapter.blank(),
      frame.Outbound(op: frame.OpVoiceStateUpdate, text: "not json"),
    )

  assert adapter.acts(world) == [adapter.Wrote(adapter.SentOther(4))]
}

pub fn blank_world_is_empty_test() {
  let world = adapter.blank()

  assert adapter.acts(world) == []
  assert world.socket == None
  assert world.closing == None
}

/// `saw` splits `Reconnecting` out because the delay is the part that matters.
pub fn reconnecting_records_its_delay_test() {
  let world =
    adapter.saw(
      adapter.blank(),
      gateway.Reconnecting(
        in_ms: 577,
        resuming: True,
        why: gateway.PeerClosed(Some(4000)),
      ),
    )

  assert adapter.acts(world) == [adapter.Reconnecting(577, True)]
}

/// `saw` splits `Halted` out too: a scenario has to be able to tell the host
/// asking to stop from Discord refusing the token for good.
pub fn halted_records_which_ending_it_was_test() {
  let assert Ok(fleet) = gateway.sharding(index: 0, count: 1)
  let refused = gateway.Fatal(reason: close.BadToken, shard: fleet)

  assert adapter.acts(adapter.saw(adapter.blank(), gateway.Halted(refused)))
    == [adapter.Halted(refused)]

  assert adapter.acts(adapter.saw(
      adapter.blank(),
      gateway.Halted(gateway.Requested),
    ))
    == [adapter.Halted(gateway.Requested)]
}
