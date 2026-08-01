//// The driver: runs `glyde/gateway`'s outputs against transport functions you
//// hand it. Nothing here blocks, spawns, sleeps or returns a `Result`.
////
//// Three of the six adapter rules in `glyde/gateway` are kept here: outputs
//// run in order, the shard is committed before any of them runs, and a bot
//// arrives seeded. The other three are on the `Transport` you hand it.

import gleam/list
import gleam/option.{type Option}
import glyde/gateway.{
  type Conn, type Event, type Input, type Notice, type Output, type Session,
  type Shard, type Stamp, type Timer,
}
import glyde/gateway/command.{type Command}
import glyde/gateway/frame.{type Outbound}
import glyde/intents.{type Intents}

/// The six things a shard asks of the outside world. Every function takes the
/// bot's state first and returns it, so a fake one can record every frame.
pub type Transport(state) {
  Transport(
    /// Open a WebSocket to `wss://<host><path>`. Keep the `Conn` and hand it
    /// back on every input from this socket, and do not touch the path.
    open: fn(state, Conn, String, String) -> state,
    /// Write `frame.text` as one text frame. A failed write is
    /// `closed(bot, conn, None)`, never a raise: raising abandons the batch,
    /// heartbeat timer and all. `frame.op` says what it was, for logging, so
    /// no adapter has to parse the payload back.
    send: fn(state, Outbound) -> state,
    /// Write a close frame with this code, then tear the socket down. Only
    /// ever 1000, which ends the session, or 4000, which keeps it resumable.
    close: fn(state, Int) -> state,
    /// Abandon the socket with no close frame. The peer has already gone, or
    /// there was never a socket.
    drop: fn(state) -> state,
    /// Arm a one-shot timer, replacing whatever was armed under the same name.
    /// When it fires, call `timer_fired` with this exact stamp.
    arm: fn(state, Timer, Int, Stamp) -> state,
    /// Cancel a timer. Cancelling one that is not armed is a no-op, and a fire
    /// that beats the cancel is recognised by its stamp and dropped.
    cancel: fn(state, Timer) -> state,
  )
}

/// Performs nothing. The explicit choice for a test that only wants to read
/// the shard, and the only way to build a bot that reaches no socket.
pub fn discarding() -> Transport(state) {
  Transport(
    open: fn(state, _, _, _) { state },
    send: fn(state, _) { state },
    close: fn(state, _) { state },
    drop: fn(state) { state },
    arm: fn(state, _, _, _) { state },
    cancel: fn(state, _) { state },
  )
}

/// How a connection earns the right to send IDENTIFY. Discord meters it per
/// bot, not per connection, so a fleet takes turns.
pub type Slots(state) {
  /// Grant every request immediately. Right for a single-shard bot.
  Solo
  /// Ask a coordinator, `glyde/identify_queue` being one, and call
  /// `slot_granted` when it answers. `release` frees the slot again.
  Fleet(request: fn(state, Conn) -> state, release: fn(state, Conn) -> state)
}

/// The zlib context for `gateway.ZlibStream`. A native mutable resource, so it
/// lives out here rather than in the state machine.
///
/// This, not `Config.compression`, decides the mode: the bot writes the config
/// to match whichever of these it holds. Compression negotiated with nothing
/// to inflate with is a socket whose every frame is unreadable, so it is not
/// something a builder can reach.
pub type Inflater(state) {
  /// No context, and `gateway.NoCompression` with it.
  Plaintext
  /// One context per connection, and `gateway.ZlibStream` with it. `inflate`
  /// answers by calling `inflated`; `reset` starts a fresh one, which every
  /// new connection needs.
  Zlib(
    inflate: fn(state, Conn, Stamp, BitArray) -> state,
    reset: fn(state, Conn) -> state,
  )
}

/// What a handler gives back. Commands go through the machine rather than
/// straight down the socket: they come out of the connection's budget.
pub type Next(state) {
  Next(state: state, commands: List(Command))
}

/// Keep this state and send nothing.
pub fn keep(state: state) -> Next(state) {
  Next(state:, commands: [])
}

/// Send a gateway command once the current batch is done.
pub fn sending(next: Next(state), command: Command) -> Next(state) {
  Next(..next, commands: list.append(next.commands, [command]))
}

/// A handler that keeps every event, newest first, for the "hand the events
/// back to me" shape.
pub fn collecting(events: List(Event), event: Event) -> Next(List(Event)) {
  keep([event, ..events])
}

/// Opaque, unlike the shard inside it: the queue is what stops a handler's
/// command re-entering the machine mid-batch. Read it with `shard` and `state`.
pub opaque type Bot(state) {
  Bot(
    shard: Shard,
    state: state,
    transport: Transport(state),
    slots: Slots(state),
    inflater: Inflater(state),
    handle: fn(state, Event) -> Next(state),
    notice: fn(state, Notice) -> state,
    /// Inputs raised while performing a batch: a granted slot, a failed
    /// inflate, a command a handler asked for. Fed after it, never during.
    queue: List(Input),
  )
}

/// Our choice, and only safe for one shard: two shards seeded the same jitter
/// the same, which is the herd the jitter exists to break up.
const default_seed: Int = 1

/// Default gateway config, no state.
pub fn new(
  token token: String,
  intents intents: Intents,
  transport transport: Transport(Nil),
) -> Bot(Nil) {
  stateful(config: gateway.config(token:, intents:), state: Nil, transport:)
}

/// A bot carrying a state of your own, and the way to the rest of the config:
/// sharding, the tuning numbers. Nothing to remember is `Nil`.
pub fn stateful(
  config config: gateway.Config,
  state state: state,
  transport transport: Transport(state),
) -> Bot(state) {
  from_shard(
    shard: gateway.new(config:, seed: default_seed),
    state:,
    transport:,
  )
}

/// A bot around a shard you built yourself, for a custom seed or for
/// `gateway.resuming` after a process restart.
///
/// The transport is taken here and not attached later, because a bot without
/// one advances its shard and writes to nothing. Pass `discarding()` when that
/// is what you want.
///
/// Compression starts off whatever the config asked for: `with_inflater` is
/// the switch, and it moves both halves together.
pub fn from_shard(
  shard shard: Shard,
  state state: state,
  transport transport: Transport(state),
) -> Bot(state) {
  Bot(
    shard: compressing(shard, gateway.NoCompression),
    state:,
    transport:,
    slots: Solo,
    inflater: Plaintext,
    handle: fn(state, _) { keep(state) },
    notice: fn(state, _) { state },
    queue: [],
  )
}

/// Fold events into the state. Replaces the previous handler.
pub fn on_event(
  bot: Bot(state),
  handle: fn(state, Event) -> Next(state),
) -> Bot(state) {
  Bot(..bot, handle:)
}

/// Watch the diagnostics: a zombie connection, a dropped command, a wait for
/// an identify slot. Never protocol-significant, and where a log line belongs.
pub fn on_notice(
  bot: Bot(state),
  notice: fn(state, Notice) -> state,
) -> Bot(state) {
  Bot(..bot, notice:)
}

/// Take identify slots from a fleet coordinator instead of granting them here.
pub fn with_slots(bot: Bot(state), slots: Slots(state)) -> Bot(state) {
  Bot(..bot, slots:)
}

/// Turn transport compression on, by handing over the context that makes it
/// readable. `Zlib` asks Discord for `zlib-stream`, `Plaintext` goes back to
/// uncompressed: the two are one switch, so neither can be set alone.
pub fn with_inflater(bot: Bot(state), inflater: Inflater(state)) -> Bot(state) {
  let compression = case inflater {
    Plaintext -> gateway.NoCompression
    Zlib(..) -> gateway.ZlibStream
  }
  Bot(..bot, shard: compressing(bot.shard, compression), inflater:)
}

fn compressing(shard: Shard, compression: gateway.Compression) -> Shard {
  gateway.Shard(..shard, config: gateway.Config(..shard.config, compression:))
}

/// Reseed the shard's jitter. Below 2^31, and different for every shard of a
/// fleet.
pub fn with_seed(bot: Bot(state), seed: Int) -> Bot(state) {
  Bot(..bot, shard: gateway.reseed(shard: bot.shard, seed:))
}

pub fn state(bot: Bot(state)) -> state {
  bot.state
}

/// Change your state from outside a handler, for something that did not come
/// from the gateway: a REST response, a tick of your own.
pub fn update(bot: Bot(state), with: fn(state) -> state) -> Bot(state) {
  Bot(..bot, state: with(bot.state))
}

/// The pure core, for calling `gateway.step` directly or reading a phase.
pub fn shard(bot: Bot(state)) -> Shard {
  bot.shard
}

/// The session, if there is one to resume with. Persist it across a process
/// restart and boot the next one with `gateway.resuming`.
pub fn session(bot: Bot(state)) -> Option(Session) {
  gateway.session(bot.shard)
}

/// The connection the bot will hear from. An adapter uses the `Conn` from
/// `Transport.open` instead: synthesising one defeats the staleness check.
pub fn conn(bot: Bot(state)) -> Conn {
  gateway.conn(bot.shard)
}

/// True once the bot has stopped, or hit a close code no reconnect can fix.
/// An adapter's loop exits here.
pub fn is_terminal(bot: Bot(state)) -> Bool {
  gateway.is_terminal(bot.shard)
}

/// Begin. Arms the reconnect timer at zero, so the dial happens on the fire
/// and there is exactly one code path that dials.
pub fn start(bot: Bot(state)) -> Bot(state) {
  feed(bot, gateway.Start)
}

/// The WebSocket is up and the upgrade finished.
pub fn opened(bot: Bot(state), conn: Conn) -> Bot(state) {
  feed(bot, gateway.Opened(conn))
}

/// The WebSocket could not be established, or died before the upgrade
/// finished. An adapter that saw a response status says so: 401 is a dead
/// token, and the shard halts on it instead of redialling.
pub fn open_failed(
  bot: Bot(state),
  conn: Conn,
  failure: gateway.DialFailure,
) -> Bot(state) {
  feed(bot, gateway.OpenFailed(conn, failure))
}

/// A text frame arrived, carrying exactly one gateway payload.
pub fn received(bot: Bot(state), conn: Conn, text: String) -> Bot(state) {
  feed(bot, gateway.Frame(conn, text))
}

/// A binary frame arrived under a compressed transport. A fragment, a payload
/// or several; the core buffers.
pub fn received_bytes(
  bot: Bot(state),
  conn: Conn,
  data: BitArray,
) -> Bot(state) {
  feed(bot, gateway.Bytes(conn, data))
}

/// The answer to an `Inflater.inflate`. `Error` names which way it failed, and
/// no amount of retrying fixes either mid-connection.
pub fn inflated(
  bot: Bot(state),
  conn: Conn,
  stamp: Stamp,
  result: Result(String, gateway.InflateFailure),
) -> Bot(state) {
  feed(bot, gateway.Inflated(conn, stamp, result))
}

/// The socket closed. `None` is a transport that died with no close frame;
/// 1005 and 1006 mean the same thing and normalise to it.
pub fn closed(bot: Bot(state), conn: Conn, code: Option(Int)) -> Bot(state) {
  feed(bot, gateway.Closed(conn, code))
}

/// A timer fired. The stamp must be the one that armed it; anything else is a
/// fire that lost the race with its own cancellation and is dropped.
pub fn timer_fired(bot: Bot(state), timer: Timer, stamp: Stamp) -> Bot(state) {
  feed(bot, gateway.Fired(timer, stamp))
}

/// The fleet coordinator granted this connection its identify slot. Only
/// needed under `Slots.Fleet`.
pub fn slot_granted(bot: Bot(state), conn: Conn) -> Bot(state) {
  feed(bot, gateway.IdentifySlotGranted(conn))
}

/// Send a gateway command. Goes out when the shard is live and has budget, and
/// waits in the shard's own queue otherwise, so it survives a reconnect.
pub fn command(bot: Bot(state), command: Command) -> Bot(state) {
  feed(bot, gateway.Command(command))
}

/// Shut down. Closes with 1000, which ends the session for good rather than
/// leaving one to resume. Terminal, and every later input is ignored.
pub fn stop(bot: Bot(state)) -> Bot(state) {
  feed(bot, gateway.Stop)
}

/// Any input, for something this module has not given a name to.
pub fn feed(bot: Bot(state), input: Input) -> Bot(state) {
  drain(advance(bot, input))
}

/// One input, then every output it produced, then whatever those raised.
/// Terminates: nothing in the queue can produce another of itself.
fn drain(bot: Bot(state)) -> Bot(state) {
  case bot.queue {
    [] -> bot
    [next, ..rest] -> drain(advance(Bot(..bot, queue: rest), next))
  }
}

fn advance(bot: Bot(state), input: Input) -> Bot(state) {
  let gateway.Step(shard:, outputs:) = gateway.step(bot.shard, input)
  // Commit the shard before any output runs. Performing first and storing
  // after loses the new shard to anything an output feeds back.
  list.fold(outputs, Bot(..bot, shard:), perform)
}

fn perform(bot: Bot(state), output: Output) -> Bot(state) {
  case output {
    // The core carries a host as a type and a transport builds a URL out of
    // one, so this is where the two meet.
    gateway.Open(conn, host, path) ->
      set(
        bot,
        bot.transport.open(bot.state, conn, gateway.host_to_string(host), path),
      )

    gateway.Send(payload) -> set(bot, bot.transport.send(bot.state, payload))

    gateway.Close(code) -> set(bot, bot.transport.close(bot.state, code))

    gateway.Drop -> set(bot, bot.transport.drop(bot.state))

    gateway.ArmTimer(timer, in_ms, stamp) ->
      set(bot, bot.transport.arm(bot.state, timer, in_ms, stamp))

    gateway.CancelTimer(timer) ->
      set(bot, bot.transport.cancel(bot.state, timer))

    gateway.RequestIdentifySlot(conn) ->
      case bot.slots {
        Solo -> queue(bot, gateway.IdentifySlotGranted(conn))
        Fleet(request:, release: _) -> set(bot, request(bot.state, conn))
      }

    gateway.ReleaseIdentifySlot(conn) ->
      case bot.slots {
        Solo -> bot
        Fleet(request: _, release:) -> set(bot, release(bot.state, conn))
      }

    gateway.Inflate(conn, stamp, bytes) ->
      case bot.inflater {
        Zlib(inflate:, reset: _) ->
          set(bot, inflate(bot.state, conn, stamp, bytes))
        // Not reachable: `Plaintext` holds the config at `NoCompression` and
        // the core only asks for an inflate under `ZlibStream`. Answered
        // rather than dropped, so a future way in fails instead of hanging.
        Plaintext ->
          queue(
            bot,
            gateway.Inflated(conn, stamp, Error(gateway.NoInflateContext)),
          )
      }

    gateway.ResetInflater(conn) ->
      case bot.inflater {
        Plaintext -> bot
        Zlib(inflate: _, reset:) -> set(bot, reset(bot.state, conn))
      }

    gateway.Emit(event) -> {
      let Next(state:, commands:) = bot.handle(bot.state, event)
      list.fold(commands, Bot(..bot, state:), fn(bot, wanted) {
        queue(bot, gateway.Command(wanted))
      })
    }

    gateway.Note(notice) -> set(bot, bot.notice(bot.state, notice))
  }
}

/// The state a transport call gave back. A value and not a closure: `perform`
/// runs once per output, so this must not cost an allocation.
fn set(bot: Bot(state), state: state) -> Bot(state) {
  Bot(..bot, state:)
}

/// Appended, not prepended: a handler's two commands go out in the order it
/// wrote them.
fn queue(bot: Bot(state), input: Input) -> Bot(state) {
  Bot(..bot, queue: list.append(bot.queue, [input]))
}
