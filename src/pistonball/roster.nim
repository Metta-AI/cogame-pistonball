## The roster and the results document.
##
## `playerResultsJson` must equal the manifest's `results_schema` KEY FOR KEY:
## that schema is `additionalProperties: false` and the certifier rejects any
## unknown field, so adding or removing a key here means editing
## `coworld_manifest_template.json` in the same commit.
## `tests/test_manifest.nim` is the enforcement.
##
## TWO NAME SPACES. `names` are the REAL policy names and are spectator-side
## only; `aliases` are the in-game `PST-nn` names every seat may see. Nothing
## a seat receives ever carries a real name.

import
  std/[json, strutils],
  ./sim

proc pointsText*(milli: int64): string =
  ## Milli-points as a 3-decimal string, built from integers so two seats'
  ## scores are textually identical before they are ever parsed as numbers.
  let
    negative = milli < 0
    value = (if negative: -milli else: milli)
    whole = value div 1000
    frac = value mod 1000
  var text = $whole & "." & align($frac, 3, '0')
  if negative:
    text = "-" & text
  text

proc metresText2*(micro: int32): string =
  ## A world micrometre quantity as a 2-decimal metre string.
  let
    negative = micro < 0
    value = (if negative: -int64(micro) else: int64(micro))
    whole = value div 1_000_000
    hundredths = (value mod 1_000_000) div 10_000
  var text = $whole & "." & align($hundredths, 2, '0')
  if negative:
    text = "-" & text
  text

proc spectatorName*(sim: SimServer, seat: int): string =
  ## The REAL policy name for one seat, for the results document and the
  ## chrome roster. Never reaches a player stream.
  if seat >= 0 and seat < sim.seatNames.len and sim.seatNames[seat].len > 0:
    return sim.seatNames[seat]
  if seat >= 0 and seat < sim.players.len:
    return sim.players[seat].address
  "seat " & $seat

proc playerResultsJson*(sim: SimServer): string =
  ## The episode's whole results document. Every per-seat array is in SEAT
  ## order and has exactly `num_agents` entries; `scores` holds twenty copies
  ## of ONE number, because the game is fully cooperative and every seat
  ## receives the identical score.
  let
    seats = sim.seatCount()
    scoreMilliValue = sim.scoreMilli()
    sharedScore = parseFloat(pointsText(scoreMilliValue))
    delivered = sim.delivered()
  var
    names = newJArray()
    aliases = newJArray()
    pistons = newJArray()
    policyKinds = newJArray()
    scores = newJArray()
    wins = newJArray()
    inPhase = newJArray()
    touches = newJArray()
    llmTurns = newJArray()
    fallbackTurns = newJArray()
  for seat in 0 ..< seats:
    let piston = sim.pistonOfSeat(seat)
    names.add(%sim.spectatorName(seat))
    aliases.add(%alias(max(0, piston)))
    pistons.add(%piston)
    policyKinds.add(%(
      if seat < sim.seatPolicyKind.len and sim.seatPolicyKind[seat].len > 0:
        sim.seatPolicyKind[seat]
      else:
        "scripted"))
    scores.add(%sharedScore)
    wins.add(%delivered)
    inPhase.add(%sim.seatInPhasePermille(max(0, piston)))
    touches.add(%(
      if piston >= 0 and piston < sim.touches.len: int(sim.touches[piston])
      else: 0))
    llmTurns.add(%(if seat < sim.llmTurns.len: sim.llmTurns[seat] else: 0))
    fallbackTurns.add(%(
      if seat < sim.fallbackTurns.len: sim.fallbackTurns[seat] else: 0))
  let node = %*{
    "names": names,
    "aliases": aliases,
    "pistons": pistons,
    "policyKinds": policyKinds,
    "scores": scores,
    "win": wins,
    "sharedScore": sharedScore,
    "progress": parseFloat(pointsText(sim.progressMilli)),
    "timePenalty": parseFloat(pointsText(sim.penaltyMilli)),
    "delivered": delivered,
    "deliveryTicks": (if delivered: sim.deliveryTick else: 0),
    "finalTick": sim.tickCount,
    "ballStartX": parseFloat(metresText2(BallStartX)),
    "ballFinalX": parseFloat(metresText2(sim.ballX)),
    "bestX": parseFloat(metresText2(sim.bestX)),
    "bounceBacks": int(sim.bounceBacks),
    "stallTicks": int(sim.maxStallTicks),
    "phasePermille": sim.phasePermille(),
    "inPhasePermille": inPhase,
    "touches": touches,
    "llmTurns": llmTurns,
    "fallbackTurns": fallbackTurns,
    "reason": (if sim.endReason.len > 0: sim.endReason else: ReasonComplete),
    "endRule": (if sim.endRule.len > 0: sim.endRule else: EndRuleOutOfTime),
    "seed": sim.config.seed
  }
  $node
