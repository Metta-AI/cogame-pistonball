## Hashing, events and the lobby clock.
##
## INTEGER ONLY (see `sim_types.nim`). `gameHash` is the integrity chain the
## replay viewer checks every tick, so what it mixes — and the ORDER it mixes
## it in — is a wire contract: changing either invalidates every recorded
## replay and must come with a `GameVersion` bump.

import
  ./sim_types

proc mixHash*(state: var uint64, value: int64) =
  ## One FNV-1a style round. Inlined by hand rather than pulled from a hashing
  ## library so the arithmetic is identical on amd64 and wasm32.
  state = state xor cast[uint64](value)
  state = state * 1099511628211'u64
  state = state xor (state shr 29)

proc gameHash*(sim: SimServer): uint64 =
  ## The per-tick integrity hash. Mixes ONLY simulation state: the tick, the
  ## phase, the ball's pose and motion, every head's extension and achieved
  ## velocity, the progress accumulators, the containment-guard counter and
  ## the seat -> piston digest. It never mixes FX, notes, `say`, feed text or
  ## policy labels — those are presentation and would make an identical match
  ## hash differently depending on what the model happened to write.
  result = 1469598103934665603'u64
  result.mixHash(int64(sim.tickCount))
  result.mixHash(int64(ord(sim.phase)))
  result.mixHash(int64(sim.ballX))
  result.mixHash(int64(sim.ballY))
  result.mixHash(int64(sim.ballVx))
  result.mixHash(int64(sim.ballVy))
  result.mixHash(int64(sim.angleQ))
  result.mixHash(int64(sim.spin))
  for value in sim.heights:
    result.mixHash(int64(value))
  for value in sim.pistonVel:
    result.mixHash(int64(value))
  result.mixHash(int64(sim.bestX))
  result.mixHash(sim.progressMilli)
  result.mixHash(sim.penaltyMilli)
  result.mixHash(int64(sim.guardClamps))
  result.mixHash(sim.permDigest)

proc emitEvent*(
  sim: var SimServer,
  kind: SimEventKind,
  source = -1,
  amount = 0,
  x = 0,
  y = 0,
  content = ""
) =
  ## Records one tier-2 analysis event. Gated on `collectEvents` so a live
  ## server nobody is analysing pays nothing, and never mixed into
  ## `gameHash` — nothing here can affect determinism.
  if not sim.collectEvents:
    return
  sim.events.add(SimEvent(
    tick: sim.tickCount,
    kind: kind,
    source: source,
    amount: amount,
    x: x,
    y: y,
    content: content
  ))

proc lobbyIsStarting*(sim: SimServer): bool =
  ## True once enough seats are in for the start countdown to run.
  sim.players.len >= sim.config.minPlayers

proc lobbyStartTicksRemaining*(sim: SimServer): int =
  ## Ticks left before the lobby starts the match.
  if not sim.lobbyIsStarting() or sim.config.startWaitTicks <= 0:
    return 0
  if sim.startWaitTimer > 0:
    sim.startWaitTimer
  else:
    sim.config.startWaitTicks

proc lobbyStartSecondsRemaining*(sim: SimServer): int =
  ## Whole seconds left in the lobby countdown, for the chrome.
  (sim.lobbyStartTicksRemaining() + TargetFps - 1) div TargetFps

proc lobbyJoinTimedOut*(sim: SimServer): bool =
  ## True when the lobby has waited out its join budget with seats missing.
  ## A no-show does NOT end the episode: the caller reports it and plays on
  ## with that piston driven by the scripted baseline.
  sim.phase == Lobby and
    sim.config.lobbyJoinTimeoutTicks > 0 and
    sim.lobbyTicks >= sim.config.lobbyJoinTimeoutTicks and
    sim.players.len < sim.config.numAgents

proc nextPlayerSlot*(sim: SimServer): int =
  ## Joins are strictly slot-sequential, so the seat the lobby is waiting on
  ## is exactly this one.
  sim.players.len

proc canAddPlayer*(sim: SimServer): bool =
  sim.players.len < sim.config.numAgents

proc progressPoints*(sim: SimServer): int64 =
  ## Progress in milli-points. +100.000 points for the full 7.20 m.
  sim.progressMilli

proc scoreMilli*(sim: SimServer): int64 =
  ## The one shared score, in milli-points: progress minus the time penalty.
  sim.progressMilli - sim.penaltyMilli

proc delivered*(sim: SimServer): bool =
  sim.deliveryTick >= 0

proc phasePermille*(sim: SimServer): int =
  ## Bank-wide in-phase permille: how much of the engaged time the whole bank
  ## spent on the right side of the ball. The idea's "who's out of phase"
  ## measure, aggregated.
  var engaged = 0'i64
  var inPhase = 0'i64
  for i in 0 ..< sim.engagedTicks.len:
    engaged += int64(sim.engagedTicks[i])
    inPhase += int64(sim.inPhaseTicks[i])
  if engaged <= 0:
    return 0
  int((inPhase * 1000) div engaged)

proc seatInPhasePermille*(sim: SimServer, piston: int): int =
  if piston < 0 or piston >= sim.engagedTicks.len:
    return 0
  if sim.engagedTicks[piston] <= 0:
    return 0
  int((int64(sim.inPhaseTicks[piston]) * 1000) div int64(sim.engagedTicks[piston]))
