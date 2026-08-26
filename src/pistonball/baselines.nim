## The two scripted baselines. Both emit the SAME script object on the SAME
## 225-tick cadence as an LLM seat, so their output is legal by construction
## and directly comparable, and both are pure functions of the observation a
## seat would receive.
##
## `wavebot` is the certification player, the per-turn fallback, and the
## default for a seat that registers with neither env var.
##
## The three tunables below are a `BaselineParams` object rather than
## literals because they were CHOSEN by a grid sweep, not guessed:
## `tools/tune_baselines.nim` plays the twenty-seat episode over a bounded
## matrix of them and prints the table, `tools/ci/baseline_tuning.json`
## records the sweep's pick, and `tests/test_tuning.nim` asserts the shipped
## defaults still equal it. THE PHYSICS CONSTANTS ARE NOT SWEPT: if twenty
## `wavebot`s cannot deliver, these three numbers are wrong, not the sim.

import
  std/strutils,
  ./sim, ./scripts

type
  Baseline* = enum
    blWavebot = "wavebot"
    blMetronome = "metronome"

  BaselineParams* = object
    leadTicks*: int      ## how far ahead of the ball wavebot aims.
    upUm*: int32         ## wavebot's raised height.
    idleUm*: int32       ## wavebot's parked height.

const
  DefaultBaselineParams* = BaselineParams(
    leadTicks: 6,
    upUm: 1_450_000'i32,
    idleUm: 250_000'i32
  )

proc parseBaseline*(text: string): Baseline =
  ## Tolerant, and never fails: an unknown name is `wavebot`, which is also
  ## what a seat that names nothing plays.
  let key = text.strip().toLowerAscii()
  for value in Baseline:
    if $value == key:
      return value
  blWavebot

proc wavebotSay(sim: SimServer, piston: int): string =
  ## One of four fixed lines, selected by whether the ball is in the window
  ## and which way it is going. Spectators only.
  if not inWindow(piston, sim.ballX):
    return "watching my patch"
  if sim.ballVx > 0:
    return "it is coming back - catching"
  if sim.ballX >= pistonCentreX(piston):
    return "up behind it"
  "flat and out of the way"

proc metronomeSay(sim: SimServer, piston: int): string =
  if (sim.tickCount div 225 + piston) mod 2 == 0:
    return "keeping the beat"
  "ripple rolling through"

proc wavebotScript*(
  sim: SimServer, piston: int, params = DefaultBaselineParams
): PistonScript =
  ## Lift behind the ball, clear the way in front of it. Twenty of these
  ## converge on a travelling wave with NO communication at all, which is the
  ## behaviour the whole coworld is about — and the anti-regression pin of the
  ## physics tuning (`tests/test_baselines.nim`).
  result = defaultScript()
  result.mode = modeWave
  result.triggerUm = WindowHalfWidth
  result.leadTicks = params.leadTicks
  result.upUm = params.upUm
  result.downUm = 100_000'i32
  result.idleUm = params.idleUm
  result.speed255 = 255
  result.blind = blindHold
  result.note = "lift behind, clear in front"
  result.say = wavebotSay(sim, piston)
  result.source = srcScripted

proc metronomeScript*(sim: SimServer, piston: int): PistonScript =
  ## A blind two-second ripple that never looks at the ball. Sometimes it
  ## walks the ball a long way and sometimes it fights itself, which gives the
  ## ladder a spread and gives a champion a bad neighbour to cope with.
  result = defaultScript()
  result.mode = modeRipple
  result.triggerUm = WindowHalfWidth
  result.leadTicks = 0
  result.upUm = 1_200_000'i32
  result.downUm = 100_000'i32
  result.idleUm = 100_000'i32
  result.speed255 = 204          ## 0.80 of MaxPistonSpeed.
  result.blind = blindRipple
  result.note = "two-second ripple, blind"
  result.say = metronomeSay(sim, piston)
  result.source = srcScripted

proc scriptedScript*(
  sim: SimServer, kind: Baseline, piston: int,
  params = DefaultBaselineParams
): PistonScript =
  ## The published script for one baseline on one piston.
  case kind
  of blWavebot: wavebotScript(sim, piston, params)
  of blMetronome: metronomeScript(sim, piston)
