## The broadcast channel: state deltas to events, and the one state JSON the
## chrome reads.
##
## Events are DERIVED from the difference between two sim steps rather than
## recorded, so they cost no replay bytes and are identical live and in
## replay. Nothing here enters `gameHash`.

import
  std/[json, strutils],
  ./sim, ./roster

type
  BroadcastTracker* = object
    ## Per-connection snapshot used to diff one sim step against the previous.
    initialized*: bool
    prevTick*: int
    prevPhase*: GamePhase
    prevBestX*: int32
    prevSupport*: int32
    prevBounceBacks*: int32
    prevStallBuckets*: int
    prevDelivered*: bool
    prevWallTouch*: bool
    prevTurn*: int
    launchedThisTurn*: bool
    saidTurn*: seq[int]

proc initBroadcastTracker*(): BroadcastTracker =
  result.prevSupport = -1
  result.prevTurn = -1
  result.saidTurn = newSeq[int](PistonCount)
  for i in 0 ..< PistonCount:
    result.saidTurn[i] = -1

proc resync*(tracker: var BroadcastTracker, sim: SimServer) =
  ## Re-anchors the tracker after a seek or a loop, so a jump never emits a
  ## storm of phantom events for the ticks it skipped.
  tracker.initialized = true
  tracker.prevTick = sim.tickCount
  tracker.prevPhase = sim.phase
  tracker.prevBestX = sim.bestX
  tracker.prevSupport = sim.supportColumn
  tracker.prevBounceBacks = sim.bounceBacks
  tracker.prevStallBuckets = int(sim.stallCount) div StallTicks
  tracker.prevDelivered = sim.delivered()
  tracker.prevWallTouch = sim.ballX >= GuardMaxX
  tracker.prevTurn = sim.gameTicksElapsed() div max(1, sim.config.turnTicks)
  tracker.launchedThisTurn = false
  if tracker.saidTurn.len < PistonCount:
    tracker.saidTurn = newSeq[int](PistonCount)
    for i in 0 ..< PistonCount:
      tracker.saidTurn[i] = -1

proc metres2*(micro: int32): float =
  ## World micrometres as a 2-decimal metre value for the chrome.
  parseFloat(metresText2(micro))

proc stepEvents*(
  sim: SimServer, tracker: var BroadcastTracker, events: JsonNode
) =
  ## Derives this step's broadcast events. Called once per stepped tick by
  ## both the live loop and the replay runtime, so the story a spectator is
  ## told is identical either way.
  if not tracker.initialized:
    tracker.resync(sim)
    return
  let turn = sim.gameTicksElapsed() div max(1, sim.config.turnTicks)
  if sim.phase != tracker.prevPhase:
    events.add(%*{"k": "phase", "t": sim.tickCount, "ph": $sim.phase})
    if sim.phase == GameOver:
      events.add(%*{"k": "gameover", "t": sim.tickCount,
        "reason": sim.endReason, "endRule": sim.endRule,
        "score": parseFloat(pointsText(sim.scoreMilli()))})
  if sim.supportColumn != tracker.prevSupport and sim.supportColumn >= 0:
    events.add(%*{"k": "handoff", "t": sim.tickCount,
      "piston": int(sim.supportColumn)})
  # LAUNCH: a head hit the ball at more than 1.0 m/s of approach. Only the
  # FIRST per turn becomes a beat — a beat per impact would bury the scrubber.
  var launch = -1
  var launchSpeed = 0'i32
  for record in sim.contacts:
    if record.surface >= 0 and record.approach > 41_667'i32 and
        record.approach > launchSpeed:
      launch = int(record.surface)
      launchSpeed = record.approach
  if launch >= 0:
    let first = turn != tracker.prevTurn or not tracker.launchedThisTurn
    events.add(%*{"k": "launch", "t": sim.tickCount, "piston": launch,
      "speed": parseFloat(metresText2(
        int32(int64(launchSpeed) * int64(TargetFps)))),
      "beat": first})
    tracker.launchedThisTurn = true
  if sim.bounceBacks != tracker.prevBounceBacks:
    events.add(%*{"k": "bounce_back", "t": sim.tickCount,
      "given": metres2(sim.ballX - sim.bestX)})
  let stallBuckets = int(sim.stallCount) div StallTicks
  if stallBuckets > tracker.prevStallBuckets and stallBuckets > 0:
    events.add(%*{"k": "stall", "t": sim.tickCount,
      "seconds": int(sim.stallCount) div TargetFps})
  let wallTouch = sim.ballX >= GuardMaxX
  if wallTouch and not tracker.prevWallTouch and sim.tickCount > 48:
    events.add(%*{"k": "wall_touch", "t": sim.tickCount})
  if sim.delivered() and not tracker.prevDelivered:
    events.add(%*{"k": "delivered", "t": sim.tickCount,
      "seconds": sim.tickCount div TargetFps})
  if turn != tracker.prevTurn:
    if tracker.prevTurn >= 0:
      events.add(%*{"k": "turn_end", "t": sim.tickCount,
        "turn": tracker.prevTurn, "of": sim.turnsPerGame()})
    tracker.launchedThisTurn = false
  # SAY: one event per piston per turn, so a line held for 2.5 s of playback
  # does not re-fire on every frame.
  for piston in 0 ..< PistonCount:
    if sim.says[piston].len == 0 or sim.sayUntil[piston] < sim.tickCount:
      continue
    if tracker.saidTurn[piston] == turn:
      continue
    tracker.saidTurn[piston] = turn
    events.add(%*{"k": "say", "t": sim.tickCount, "piston": piston,
      "alias": alias(piston), "say": sim.says[piston]})
  tracker.prevTick = sim.tickCount
  tracker.prevPhase = sim.phase
  tracker.prevBestX = sim.bestX
  tracker.prevSupport = sim.supportColumn
  tracker.prevBounceBacks = sim.bounceBacks
  tracker.prevStallBuckets = stallBuckets
  tracker.prevDelivered = sim.delivered()
  tracker.prevWallTouch = wallTouch
  tracker.prevTurn = turn

proc progressPermille(sim: SimServer): int =
  ## How far along the 7.20 m journey the ball is, in permille.
  let travelled = int64(BallStartX) - int64(sim.ballX)
  int((travelled * 1000) div int64(TravelDistance))

proc rosterJson(sim: SimServer): JsonNode =
  ## The spectator roster: REAL policy names, in seat order. Spectator side
  ## only — no player stream ever carries this.
  result = newJArray()
  for seat in 0 ..< sim.seatCount():
    let piston = max(0, sim.pistonOfSeat(seat))
    result.add(%*{
      "s": seat,
      "name": sim.spectatorName(seat),
      "team": "bank",
      "alias": alias(piston),
      "piston": piston,
      "kind": (if seat < sim.seatPolicyKind.len and
                  sim.seatPolicyKind[seat].len > 0:
                 sim.seatPolicyKind[seat] else: "scripted"),
      "inphase": sim.seatInPhasePermille(piston),
      "touches": (if piston < sim.touches.len: int(sim.touches[piston]) else: 0),
      "llm": (if seat < sim.llmTurns.len: sim.llmTurns[seat] else: 0),
      "fb": (if seat < sim.fallbackTurns.len: sim.fallbackTurns[seat] else: 0)
    })

proc pistonsJson(sim: SimServer): JsonNode =
  result = newJArray()
  for piston in 0 ..< PistonCount:
    let
      offset = sim.ballX - pistonCentreX(piston)
      engaged = abs32(offset) <= EngagedHalfWidth
      wantUp = pistonCentreX(piston) >= sim.ballX
      inPhase =
        if wantUp: sim.heights[piston] >= InPhaseUpHeight
        else: sim.heights[piston] <= InPhaseDownHeight
    result.add(%*{
      "h": metres2(sim.heights[piston]),
      "u": metres2(sim.pistonVel[piston] * int32(TargetFps)),
      "want": (if not engaged: "idle" elif wantUp: "up" else: "down"),
      "off": engaged and not inPhase
    })

proc buildStateJson*(
  sim: SimServer,
  events: JsonNode,
  playing: bool,
  speed: int,
  maxTick: int,
  looping: bool,
  transportEnabled: bool,
  mismatchTick: int,
  selectedPiston: int,
  leadSeries: seq[seq[int]] = @[],
  startTick = 0,
  endHoldSeconds = 0,
  skipLulls = false,
  fastForwarding = false,
  lullSpans: seq[array[2, int]] = @[],
  beatEvents: JsonNode = nil
): string =
  ## Assembles the broadcast chrome frame from the current board state plus
  ## the events accumulated across this playback frame. Board-derived STATE is
  ## always present, so even a frame reached by a seek hydrates the scorebug
  ## and the end card with no events at all.
  ##
  ## Keys above `pb` are the STARTER's and are consumed by the byte-identical
  ## `chrome_common.js`; everything pistonball-specific lives under `pb` and
  ## `scripts` and is consumed only by the appended game block.
  var teams = newJObject()
  teams["bank"] = %*{
    "score": parseFloat(pointsText(sim.scoreMilli())),
    "progress": progressPermille(sim),
    "phase": sim.phasePermille(),
    "delivered": sim.delivered(),
    "bounceBacks": int(sim.bounceBacks),
    "policies": sim.seatCount()
  }
  var state = %*{
    "t": sim.tickCount,
    "mt": sim.effectiveMaxTicks(),
    "ph": ($sim.phase).toLowerAscii,
    "lob": sim.lobbyStartSecondsRemaining(),
    "pl": playing,
    "sp": speed,
    "mx": maxTick,
    "st": startTick,
    "lp": looping,
    "sk": skipLulls,
    "ff": fastForwarding,
    "en": transportEnabled,
    "mm": mismatchTick,
    "bs": 1,
    "pov": selectedPiston,
    "teams": teams,
    "roster": rosterJson(sim),
    "events": (if events.isNil: newJArray() else: events),
    "turn": sim.gameTicksElapsed() div max(1, sim.config.turnTicks),
    "turns": sim.turnsPerGame(),
    "turnTicks": sim.config.turnTicks
  }
  var ball = %*{
    "x": metres2(sim.ballX),
    "y": metres2(FloorY - sim.ballY),
    "vx": metres2(sim.ballVx * int32(TargetFps)),
    "vy": metres2(-sim.ballVy * int32(TargetFps)),
    "spin": float(int64(sim.spin) * 360'i64 * int64(TargetFps)) / 4096.0,
    "r": metres2(BallRadius),
    "column": columnOf(sim.ballX)
  }
  var bubbles = newJArray()
  for piston in 0 ..< PistonCount:
    if sim.says[piston].len > 0 and sim.sayUntil[piston] >= sim.tickCount:
      bubbles.add(%*{"piston": piston, "say": sim.says[piston],
        "until": sim.sayUntil[piston]})
  state["pb"] = %*{
    "ball": ball,
    "pistons": pistonsJson(sim),
    "arena": {
      "w": metres2(WorldWidth), "h": metres2(WorldHeight),
      "floor": 0.0,
      "left": metres2(LeftWallX1), "right": metres2(RightWallX0),
      "goalx": metres2(GoalX), "startx": metres2(BallStartX),
      "stroke": metres2(Stroke), "pitch": metres2(PistonWidth)
    },
    "best": metres2(sim.bestX),
    "progressPct": progressPermille(sim),
    "phasePermille": sim.phasePermille(),
    "reward": {
      "progress": parseFloat(pointsText(sim.progressMilli)),
      "penalty": parseFloat(pointsText(-sim.penaltyMilli)),
      "score": parseFloat(pointsText(sim.scoreMilli()))
    },
    "bubbles": bubbles
  }
  # The policy lines. This is where a spectator SEES the LLM playing: the
  # `note` and `say` each seat issued, live and in replay from one source.
  if sim.feedScripts.len > 0:
    var records = newJArray()
    for record in sim.feedScripts:
      try:
        records.add(parseJson(record))
      except CatchableError:
        discard
    state["scripts"] = records
  if leadSeries.len > 0:
    var teamNames = newJArray()
    teamNames.add(%"ball")
    var pts = newJArray()
    for point in leadSeries:
      var row = newJArray()
      for value in point:
        row.add(%value)
      pts.add(row)
    state["lead"] = %*{"teams": teamNames, "pts": pts}
  if not beatEvents.isNil and beatEvents.len > 0:
    state["beats"] = beatEvents
  if lullSpans.len > 0:
    var spans = newJArray()
    for span in lullSpans:
      spans.add(%*[span[0], span[1]])
    state["lulls"] = spans
  if sim.phase == GameOver:
    state["over"] = %*{
      "winner": (if sim.delivered(): "bank" else: ""),
      "draw": false,
      "timeLimit": sim.endRule == EndRuleOutOfTime,
      "endRule": sim.endRule,
      "reason": sim.endReason,
      "score": parseFloat(pointsText(sim.scoreMilli())),
      "ticks": sim.tickCount,
      "teams": {"bank": {"prog": progressPermille(sim)}}
    }
    if endHoldSeconds > 0:
      state["hold"] = %endHoldSeconds
  $state
