## The decision layer: the per-turn loop that asks all twenty seats what their
## pistons do next, and always has an answer.
##
## Cadence: one turn every `turnTicks` (225 ticks = 9.375 s of sim time), 8
## turns per episode. At each turn the server builds ALL TWENTY seats' request
## bodies and issues them as ONE parallel batch — pistonball is a
## simultaneous-decision game, so querying seats one after another would
## multiply the wall clock by twenty for no gain.
##
## The binding constraint is not latency, it is the Bedrock sidecar's cap of
## 30 requests per minute per episode: twenty requests per batch means a batch
## may start at most every 40 s, so `minBatchSpacingMs` is 45 000 (26.7 rpm).
## That, not the model, is why there are eight turns and why a turn is 9.375 s
## of sim time.
##
## DEGRADE, NEVER HANG. Every wait here is bounded: attempt 1 gets
## `attempt1Ms`, the single retry gets `retryMs`, the inter-batch floor is a
## bounded sleep, and the whole turn is wrapped in a monotonic `turnBudgetMs`
## deadline. A provider throttle with no other candidate model skips the retry
## outright (it cannot land) and fails fast to the scripted layer. On a second
## failure the seat plays the `wavebot` script for that turn and a `fallback`
## record names the cause. No failure mode leaves a piston uncommanded: the
## controller always has a script — this turn's, else last turn's, else
## `wavebot`'s.

import
  std/[json, math, monotimes, os, strutils, times],
  curly,
  ./sim, ./roster, ./scripts, ./control, ./baselines, ./llm

type
  SeatPolicy* = object
    ## What one seat registered as. A seat that registers with neither field —
    ## or never registers at all — is `wavebot`.
    isLlm*: bool
    prompt*: string
    baseline*: Baseline
    label*: string
    registered*: bool

  Sighting* = object
    tick*: int
    dxUm*: int32
    heightUm*: int32
    vxUm*: int32
    vyUm*: int32

  DecisionEngine* = object
    client*: LlmClient
    seats*: seq[SeatPolicy]
    scripts*: seq[PistonScript]
    haveScript*: seq[bool]
    sightings*: seq[seq[Sighting]]
    sightingCounts*: seq[int]
    lastBatchStart*: MonoTime
    batchStarted*: bool
    llmOff*: bool              ## the budget guard fired; scripted from here on
    params*: BaselineParams

const
  MaxSightings* = 4
    ## The first, the last, and up to two evenly spaced intermediates. With
    ## eight decisions per episode this local history is the seat's memory,
    ## and it is the only history it gets.

proc initDecisionEngine*(sim: SimServer): DecisionEngine =
  result.client = newLlmClient(sim.config)
  let seats = sim.seatCount()
  result.seats = newSeq[SeatPolicy](seats)
  result.scripts = newSeq[PistonScript](seats)
  result.haveScript = newSeq[bool](seats)
  result.sightings = newSeq[seq[Sighting]](seats)
  result.sightingCounts = newSeq[int](seats)
  result.params = DefaultBaselineParams
  for i in 0 ..< seats:
    result.seats[i].baseline = blWavebot
    result.seats[i].label = "wavebot"
    result.scripts[i] = defaultScript()

proc policyKind*(engine: DecisionEngine, seat: int): string =
  if seat >= 0 and seat < engine.seats.len and engine.seats[seat].isLlm:
    "llm"
  else:
    "scripted"

proc scriptFor*(
  engine: DecisionEngine, sim: SimServer, seat: int
): PistonScript =
  ## The script the controller runs for one seat: this turn's, else last
  ## turn's, else `wavebot`'s. NO failure mode leaves a piston uncommanded.
  let piston = sim.pistonOfSeat(seat)
  if seat >= 0 and seat < engine.haveScript.len and engine.haveScript[seat]:
    return engine.scripts[seat]
  wavebotScript(sim, max(0, piston), engine.params)

proc commandFor*(
  engine: DecisionEngine, sim: SimServer, piston: int
): uint8 =
  ## The command byte for one PISTON this tick. Called in piston index order
  ## 0 .. 19, never seat order — seat order varies with `perm` and the loop
  ## must not.
  let seat = sim.seatOfPiston(piston)
  if seat < 0:
    return pistonCommand(sim, wavebotScript(sim, piston, engine.params), piston)
  pistonCommand(sim, engine.scriptFor(sim, seat), piston)

# ---------------------------------------------------------------------------
#  Sightings: the seat's own local memory
# ---------------------------------------------------------------------------

proc observe*(engine: var DecisionEngine, sim: SimServer) =
  ## Called once per tick. Records the ball ONLY while it is inside this
  ## seat's own window. Nothing outside the window is ever retained, which is
  ## what makes the locality invariant structural rather than a promise.
  if sim.phase != Playing:
    return
  for seat in 0 ..< engine.seats.len:
    let piston = sim.pistonOfSeat(seat)
    if piston < 0 or not inWindow(piston, sim.ballX):
      continue
    inc engine.sightingCounts[seat]
    engine.sightings[seat].add(Sighting(
      tick: sim.tickCount,
      dxUm: sim.ballX - pistonCentreX(piston),
      heightUm: FloorY - sim.ballY,
      vxUm: sim.ballVx,
      vyUm: -sim.ballVy
    ))
    # Bounded: keep at most one sighting per tick of a turn, and the view
    # builder thins them to four. 225 entries per seat per turn is the cap.
    if engine.sightings[seat].len > 256:
      engine.sightings[seat].delete(0)

proc clearSightings(engine: var DecisionEngine) =
  for seat in 0 ..< engine.sightings.len:
    engine.sightings[seat].setLen(0)
    engine.sightingCounts[seat] = 0

proc thinned(records: seq[Sighting]): seq[Sighting] =
  ## The first, the last, and up to two evenly spaced intermediates.
  if records.len <= MaxSightings:
    return records
  let last = records.len - 1
  result = @[
    records[0],
    records[last div 3],
    records[(2 * last) div 3],
    records[last]
  ]

# ---------------------------------------------------------------------------
#  The per-seat view
# ---------------------------------------------------------------------------

proc r2(value: float): float =
  ## Everything shown to a policy is rounded to 2 decimals.
  round(value * 100.0) / 100.0

proc metres(micro: int32): float = r2(float(micro) / 1_000_000.0)
proc metresPerSecond(perTick: int32): float =
  r2(float(perTick) * float(TargetFps) / 1_000_000.0)
proc degreesPerSecond(spin: int32): float =
  r2(float(spin) * 360.0 * float(TargetFps) / 4096.0)

proc windowView*(
  engine: DecisionEngine, sim: SimServer, seat, turnIndex: int
): JsonNode =
  ## EVERYTHING this seat may legitimately know, and nothing else. One
  ## function builds both the LLM user message and the seat's frame filter;
  ## there is no second path.
  ##
  ## Hidden with no exception: the ball whenever it is outside this window,
  ## any piston height outside `i-2 .. i+2`, the cumulative reward, `bestX`,
  ## the score so far, `perm`, the seed, any other seat's script/note/say, and
  ## every real player name.
  let
    piston = max(0, sim.pistonOfSeat(seat))
    span = windowColumns(piston)
    turns = sim.turnsPerGame()
    elapsed = sim.gameTicksElapsed()
    left = max(0, sim.effectiveMaxTicks() - elapsed)
  var covers = newJArray()
  var heights = newJObject()
  for column in span.first .. span.last:
    covers.add(%column)
    heights[$column] = %metres(sim.heights[column])
  var ball: JsonNode = newJNull()
  if inWindow(piston, sim.ballX):
    ball = %*{
      "dx_m": metres(sim.ballX - pistonCentreX(piston)),
      "height_m": metres(FloorY - sim.ballY),
      "vx_m_s": metresPerSecond(sim.ballVx),
      "vy_m_s": metresPerSecond(-sim.ballVy),
      "spin_deg_s": degreesPerSecond(sim.spin),
      "on_me": sim.contactPistons[piston]
    }
  var sightings = newJArray()
  for record in thinned(engine.sightings[seat]):
    sightings.add(%*{
      "tick": record.tick,
      "dx_m": metres(record.dxUm),
      "height_m": metres(record.heightUm),
      "vx_m_s": metresPerSecond(record.vxUm),
      "vy_m_s": metresPerSecond(record.vyUm)
    })
  result = %*{
    "turn": turnIndex,
    "of": turns,
    "clock": {
      "tick": elapsed,
      "of": sim.effectiveMaxTicks(),
      "left_s": r2(float(left) / float(TargetFps))
    },
    "you": {
      "alias": alias(piston),
      "piston": piston,
      "x_m": metres(pistonCentreX(piston)),
      "height_m": metres(sim.heights[piston]),
      "velocity_m_s": metresPerSecond(sim.pistonVel[piston]),
      "stroke_m": metres(Stroke),
      "max_speed_m_s": metresPerSecond(MaxPistonSpeed),
      "width_m": metres(PistonWidth)
    },
    "window": {
      "half_width_m": metres(WindowHalfWidth),
      "covers_pistons": covers,
      "neighbour_heights_m": heights,
      "ball": ball
    },
    "sightings_count": engine.sightingCounts[seat],
    "sightings": sightings,
    "shared_reward": {
      "last_turn": r2(float(sim.lastTurnRewardMilli) / 1000.0),
      "note": "the whole bank's points over the last 9.4 s; positive means " &
        "the ball moved left"
    },
    "goal": {
      "direction": "left",
      "your_distance_to_goal_m": metres(pistonCentreX(piston) - GoalX),
      "note": "pistons BEHIND the ball (to its right) go UP; pistons IN " &
        "FRONT (to its left) go DOWN"
    }
  }
  if seat < engine.haveScript.len and engine.haveScript[seat]:
    result["your_last_script"] = scriptJson(engine.scripts[seat])
  else:
    result["your_last_script"] = newJNull()

# ---------------------------------------------------------------------------
#  Records
# ---------------------------------------------------------------------------

proc registerRecord*(
  seat, piston: int, alias, policy, kind, baseline: string
): string =
  ## The REDACTED registration record. The seat's prompt is NEVER written:
  ## only the policy label, the kind, and which baseline a scripted seat
  ## picked.
  $(%*{
    "k": "register",
    "seat": seat,
    "alias": alias,
    "piston": piston,
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind,
    "baseline": baseline
  })

proc fallbackRecord*(
  turn, seat, attempt: int, cause, detail: string
): string =
  $(%*{
    "k": "fallback",
    "turn": turn,
    "seat": seat,
    "attempt": attempt,
    "cause": cause,
    "detail": detail.truncateRunes(MaxFallbackDetailRunes)
  })

proc budgetGuardRecord*(turn, remainingSeconds: int): string =
  $(%*{"k": "budget_guard", "turn": turn, "remaining_s": remainingSeconds})

proc resultRecord*(sim: SimServer): string =
  ## The `result` control record — the episode's whole results document,
  ## written once into the replay chat stream at episode end. It is what makes
  ## the replay SELF-SUFFICIENT: without it the outcome exists only at
  ## COGAME_RESULTS_URI, and `tools/replay_summary.py`'s `results` reads `{}`
  ## for a spectator holding the bytes. Embedded verbatim rather than
  ## re-parsed: nothing on the path to the artifact writes may raise.
  "{\"k\":\"result\",\"results\":" & sim.playerResultsJson() & "}"

# ---------------------------------------------------------------------------
#  The turn
# ---------------------------------------------------------------------------

proc installScripted(
  engine: var DecisionEngine, sim: SimServer, seat: int,
  kind: Baseline, source: ScriptSource
) =
  let piston = max(0, sim.pistonOfSeat(seat))
  var script = scriptedScript(sim, kind, piston, engine.params)
  script.source = source
  engine.scripts[seat] = script
  engine.haveScript[seat] = true

proc turn*(
  engine: var DecisionEngine,
  sim: var SimServer,
  turnIndex, elapsedSeconds: int
): seq[string] =
  ## Runs ONE decision turn and installs every seat's script. Returns the
  ## replay chat records this turn produced. NEVER raises: every failure path
  ## ends in a legal script.
  ##
  ## Rolls the turn window over first: `shared_reward.last_turn` — the ONLY
  ## global scalar any seat ever receives — is published here, and every
  ## seat's sighting buffer is cleared once the views have been composed.
  sim.lastTurnRewardMilli =
    (sim.progressMilli - sim.turnStartProgressMilli) -
    (sim.penaltyMilli - sim.turnStartPenaltyMilli)
  sim.turnStartProgressMilli = sim.progressMilli
  sim.turnStartPenaltyMilli = sim.penaltyMilli
  let budget = initDuration(milliseconds = max(1, sim.config.turnBudgetMs))
  ## Throttle state is PER TURN: a 429 on turn k says nothing about turn k+1
  ## (the sidecar's window may have rolled), so the flag is cleared here and
  ## only suppresses this turn's retry.
  engine.client.throttled = false

  # --- budget guard: settle EARLY rather than overrun -----------------------
  if not engine.llmOff:
    let turnSeconds =
      (sim.config.turnBudgetMs + sim.config.minBatchSpacingMs + 999) div 1000
    if elapsedSeconds + 2 * turnSeconds > sim.config.wallClockBudgetSeconds:
      engine.llmOff = true
      result.add(budgetGuardRecord(
        turnIndex,
        max(0, sim.config.wallClockBudgetSeconds - elapsedSeconds)))
      echo "pistonball: budget guard fired at turn ", turnIndex,
        "; remaining turns play scripted"

  # --- which seats need a call? --------------------------------------------
  var open: seq[int]
  for seat in 0 ..< engine.seats.len:
    if engine.seats[seat].isLlm and not engine.llmOff and
        not engine.client.disabled:
      open.add(seat)
    elif engine.seats[seat].isLlm:
      # An LLM seat that CANNOT call the LLM this turn is a FALLBACK, not a
      # scripted policy, and the design's `fallback.cause` enum names both
      # reasons it happens. Recording it is what makes the two countable.
      engine.installScripted(sim, seat, blWavebot, srcFallback)
      let cause = if engine.llmOff: "budget_guard" else: "no_credentials"
      result.add(fallbackRecord(turnIndex, seat, 1, cause,
        "the LLM is unavailable for this turn; playing wavebot"))
      echo "pistonball llm: seat ", seat, " falling back to wavebot (", cause,
        ") on turn ", turnIndex
    else:
      engine.installScripted(sim, seat, engine.seats[seat].baseline,
        srcScripted)

  # --- the rate floor ------------------------------------------------------
  # Twenty requests per batch against a 30-per-minute-per-episode cap: hold
  # the START of consecutive batches `minBatchSpacingMs` apart, which pins the
  # episode at 26.7 req/min. A bounded, stop-interruptible sleep. The cert
  # fixture sets it to 0, so offline runs pay nothing.
  if open.len > 0 and engine.batchStarted and sim.config.minBatchSpacingMs > 0:
    let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < sim.config.minBatchSpacingMs:
      sleep(min(sim.config.minBatchSpacingMs,
        sim.config.minBatchSpacingMs - since))
  if open.len > 0:
    engine.lastBatchStart = getMonoTime()
    engine.batchStarted = true

  # `turnBudgetMs` bounds THIS TURN'S OWN WORK — the two attempts — and is
  # therefore sampled AFTER the rate-floor sleep. Sampling it before would
  # charge the wait to the budget, and since `minBatchSpacingMs` (45 000) is
  # larger than `turnBudgetMs` (20 000) every turn after the first would find
  # the budget already spent and fall back without issuing a request. The
  # budget guard above already reads the turn as spacing + budget.
  let turnStart = getMonoTime()

  # --- up to two PARALLEL batches ------------------------------------------
  var attempt = 0
  while open.len > 0 and attempt < 2:
    if engine.client.disabled:
      break
    if getMonoTime() - turnStart >= budget:
      for seat in open:
        result.add(fallbackRecord(
          turnIndex, seat, attempt + 1, "timeout",
          "per-turn budget exhausted before attempt " & $(attempt + 1)))
      break
    let deadlineMs =
      if attempt == 0: sim.config.attempt1Ms else: sim.config.retryMs
    var batch: RequestBatch
    for seat in open:
      var user = $engine.windowView(sim, seat, turnIndex)
      if attempt > 0:
        user.add("\n\nYour previous reply was not usable. Reply with ONLY " &
          "the JSON object described above, starting with '{'.")
      let request = engine.client.requestFor(
        SystemPrompt, userMessage(engine.seats[seat].prompt, user))
      batch.post(request.url, request.headers, request.body, $seat)
    let started = getMonoTime()
    # curly hands the deadline to CURLOPT_TIMEOUT, whose granularity is WHOLE
    # SECONDS, so this conversion FLOORS — `sim_config.validate` rejects a
    # sub-second value so the floor below is an identity.
    let responses = engine.client.sendTurnBatch(
      batch, max(1, deadlineMs div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int
    var stillOpen: seq[int]
    for position, seat in open:
      var cause = "parse_error"
      try:
        let text = engine.client.textOf(
          responses[position].response, responses[position].error,
          batch[position].url)
        var script = parsePistonScript(
          extractJsonObject(text),
          engine.scripts[seat],
          engine.haveScript[seat])
        script.source = srcLlm
        script.latencyMs = latency
        engine.scripts[seat] = script
        engine.haveScript[seat] = true
      except CatchableError as error:
        if responses[position].error.len > 0:
          cause = (if "timeout" in responses[position].error.toLowerAscii():
                     "timeout" else: "transport_error")
        elif error.msg.startsWith("llm throttled"):
          ## Name the throttle for what it is. Reporting a 429 as
          ## `parse_error` is what made a hosted log unreadable.
          cause = "throttled"
        result.add(fallbackRecord(turnIndex, seat, attempt + 1, cause,
          error.msg))
        echo "pistonball llm: seat ", seat, " attempt ", attempt + 1,
          " failed, falling back if it fails again: ", error.msg
        stillOpen.add(seat)
    open = stillOpen
    inc attempt
    if engine.client.throttled and open.len > 0:
      # FAIL FAST. The only model left answered 429, so the retry batch would
      # be refused the same way: spend the rest of the turn on the scripted
      # layer instead of on a call that cannot land.
      echo "pistonball llm: provider throttled with no other candidate; ",
        open.len, " seat(s) fall back for turn ", turnIndex
      break

  # --- anything still open plays wavebot for this turn ---------------------
  for seat in open:
    engine.installScripted(sim, seat, blWavebot, srcFallback)
    let cause =
      if engine.client.disabled or engine.client.transport == ltNone:
        "no_credentials"
      elif engine.llmOff: "budget_guard"
      elif engine.client.throttled: "throttled"
      else: "parse_error"
    result.add(fallbackRecord(turnIndex, seat, 2, cause,
      "seat fell back to the wavebot script"))
    ## "falling back" is the phrase phase 60 greps the GAME log for.
    echo "pistonball llm: seat ", seat, " falling back to wavebot (", cause,
      ") on turn ", turnIndex

proc closeTurn*(engine: var DecisionEngine) =
  ## Clears every seat's sighting buffer once this turn's views have been
  ## composed, so a seat's memory is exactly "the last 225 ticks of MY window"
  ## and never more.
  engine.clearSightings()
