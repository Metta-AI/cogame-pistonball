## The deterministic controller: one function, evaluated once per tick per
## piston, that compiles a 225-tick policy script into this tick's command
## byte.
##
## Both LLM scripts and scripted-baseline scripts are compiled by this same
## code, so the two policy kinds are strictly comparable and a baseline is
## legal by construction.
##
## The controller sits OUTSIDE the determinism boundary — the replay records
## the BYTES it produces, never the logic that produced them — so it may use
## floating point, and `global.nim`/the pixie bakes may too. Nothing in here
## enters `gameHash`.
##
## Its only inputs are this seat's own script, this seat's own window and the
## tick. It contains no path planning, no ball tracking across turns and no
## knowledge of any other seat's script; `tests/test_locality.nim` asserts the
## signature cannot see more.

import
  std/math,
  ./sim, ./scripts

const
  RipplePeriod* = 48       ## ticks; a 2.0 s travelling wave.
  CatchVxUm* = 8_333       ## +0.20 m/s: the ball is going the WRONG way.

proc rippleHeight*(script: PistonScript, tick, piston: int): int32 =
  ## The open-loop travelling wave: period 48 ticks, phase advancing one
  ## column every 2.4 ticks. Blind by construction — it never looks at the
  ## ball — which is exactly what makes `metronome` a different SHAPE of
  ## policy rather than a weaker copy of `wavebot`.
  let
    phase = float(tick) / float(RipplePeriod) - float(piston) / float(PistonCount)
    wave = sin(2.0 * PI * phase)
    lift = if wave > 0.0: wave else: 0.0
    span = float(script.upUm - script.idleUm)
  var height = float(script.idleUm) + span * lift
  if height < 0.0: height = 0.0
  if height > float(Stroke): height = float(Stroke)
  int32(height)

proc targetHeight*(
  sim: SimServer, script: PistonScript, piston: int
): int32 =
  ## The height this piston is trying to reach this tick, from the design
  ## note's mode table. `vis` is "the ball centre is inside MY window" and
  ## nothing else: a piston that cannot see the ball has only `blind` to go on.
  if script.mode == modeRipple:
    return rippleHeight(script, sim.tickCount, piston)
  let visible = inWindow(piston, sim.ballX)
  if not visible:
    if script.blind == blindHold:
      return sim.heights[piston]
    if script.blind == blindIdle:
      return script.idleUm
    return rippleHeight(script, sim.tickCount, piston)
  let
    dx = int64(sim.ballX) - int64(pistonCentreX(piston))
    lead = int64(sim.ballVx) * int64(script.leadTicks)
    dxp = dx + lead
    within = abs(dxp) <= int64(script.triggerUm)
  case script.mode
  of modeWave:
    if within and dxp <= 0: script.upUm
    elif within: script.downUm
    else: script.idleUm
  of modeLift:
    if within: script.upUm else: script.idleUm
  of modeDrop:
    if within: script.downUm else: script.idleUm
  of modeHold:
    script.idleUm
  of modeCatch:
    if int64(sim.ballVx) > CatchVxUm and dxp <= 0 and within: script.upUm
    else: script.idleUm
  of modeRipple:
    rippleHeight(script, sim.tickCount, piston)

proc pistonCommand*(
  sim: SimServer, script: PistonScript, piston: int
): uint8 =
  ## THE command byte for one piston this tick: `0 .. 254`, where
  ## `u = ((cmd - 127) * MaxPistonSpeed) div 127` micrometres per tick is the
  ## commanded head velocity (positive = rising). Any phase other than
  ## `Playing` forces 127 (hold).
  if sim.phase != Playing:
    return 127'u8
  if piston < 0 or piston >= PistonCount:
    return 127'u8
  let
    target = targetHeight(sim, script, piston)
    limit = (int64(MaxPistonSpeed) * int64(script.speed255)) div 255'i64
  var delta = int64(target) - int64(sim.heights[piston])
  if delta > limit: delta = limit
  if delta < -limit: delta = -limit
  encodePistonCommand(int32(delta))
