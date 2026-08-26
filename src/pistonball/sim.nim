## The pistonball simulation core: the piston bank, the ball, and the step
## loop of the design note's "Resolution order".
##
## INTEGER ONLY (see `sim_types.nim`). Every product or quotient of two sim
## quantities is computed in `int64` and narrowed with an explicit truncating
## `div` — Nim's `div` truncates toward zero, so the arithmetic is symmetric
## under negation, which is what makes leftward and rightward progress exactly
## opposite.

import
  ./sim_types, ./trig, ./bank, ./sim_config, ./sim_state

export sim_types, trig, bank, sim_config, sim_state

const
  LaunchApproachUm* = 41_667'i32
    ## 1.0 m/s of approach speed: the threshold a head hitting the ball has to
    ## clear to count as a LAUNCH (a beat, an FX puff, a feed line).
  GuardEpsilonUm* = 50_000'i32
    ## A containment correction smaller than 5 cm is the ball resting against
    ## a wall, not a tunnelling escape, and does not count toward the
    ## step-8 fault check. Without this a bank that never moves the ball ends
    ## `fault` instead of scoring the honest -18.000.

proc decodePistonCommand*(command: uint8): int32 =
  ## One command byte to a commanded head velocity in um/tick.
  ## `cmd = 255` is reserved and repairs to 127 (hold) on read, so a corrupt
  ## byte can never actuate.
  let raw = if command == 255'u8: 127 else: int(command)
  int32((int64(raw - 127) * int64(MaxPistonSpeed)) div 127'i64)

proc encodePistonCommand*(velocity: int32): uint8 =
  ## The inverse, clamped into 0..254.
  var scaled = (int64(velocity) * 127'i64) div int64(MaxPistonSpeed)
  var value = 127'i64 + scaled
  if value < 0: value = 0
  if value > 254: value = 254
  uint8(value)

proc seatOfPiston*(sim: SimServer, piston: int): int =
  ## Which SEAT drives piston `piston` (the inverse of `perm`).
  for seat in 0 ..< sim.perm.len:
    if int(sim.perm[seat]) == piston:
      return seat
  -1

proc pistonOfSeat*(sim: SimServer, seat: int): int =
  if seat < 0 or seat >= sim.perm.len:
    return -1
  int(sim.perm[seat])

proc initSimServer*(config: GameConfig): SimServer =
  ## Builds a fresh episode. The two seeded draws below (the seat -> piston
  ## permutation and the twenty rest heights) are the ONLY random numbers the
  ## sim ever takes; nothing is drawn after tick 0.
  result.config = config
  result.phase = Lobby
  result.tickCount = 0
  result.gameStartTick = 0
  result.deliveryTick = -1
  result.endReason = ""
  result.endRule = ""
  let draws = drawEpisode(config.seed)
  result.perm = draws.perm
  result.restHeights = draws.restHeights
  result.permDigest = permDigestOf(draws.perm)
  result.heights = newSeq[int32](PistonCount)
  result.pistonVel = newSeq[int32](PistonCount)
  for i in 0 ..< PistonCount:
    result.heights[i] = draws.restHeights[i]
  result.ballX = BallStartX - draws.startOffsetUm
  result.ballY = BallStartY
  result.ballVx = 0
  result.ballVy = 0
  result.angleQ = 0
  result.spin = 0
  result.bestX = result.ballX
  result.lastBounceBackBest = result.ballX
  result.progressMilli = 0
  result.penaltyMilli = 0
  result.stallCount = 0
  result.maxStallTicks = 0
  result.bounceBacks = 0
  result.guardClamps = 0
  result.supportColumn = int32(columnOf(result.ballX))
  result.engagedTicks = newSeq[int32](PistonCount)
  result.inPhaseTicks = newSeq[int32](PistonCount)
  result.touches = newSeq[int32](PistonCount)
  result.contactPistons = newSeq[bool](PistonCount)
  result.prevContactPistons = newSeq[bool](PistonCount)
  let seats = if config.numAgents > 0: config.numAgents else: PistonCount
  result.seatNames = newSeq[string](seats)
  result.seatPolicyKind = newSeq[string](seats)
  result.llmTurns = newSeq[int](seats)
  result.fallbackTurns = newSeq[int](seats)
  result.says = newSeq[string](PistonCount)
  result.sayUntil = newSeq[int](PistonCount)
  result.gameEventLoggingEnabled = true

proc addPlayer*(
  sim: var SimServer,
  address: string,
  slot: int,
  token: string,
  trusted = false
): int =
  ## Seats one connection. Joins are strictly slot-sequential: a seat whose
  ## resolved slot is not the next open one waits, which is what the server's
  ## held-registration table exists to survive.
  if sim.players.len >= sim.config.numAgents:
    raise newException(PistonballError, "roster is full")
  if not trusted and not sim.config.playerJoinAllowed(address, slot, token):
    raise newException(PistonballError, "player credentials rejected")
  let seat = sim.players.len
  sim.players.add(Player(
    address: address,
    joinOrder: seat,
    seat: seat,
    token: token,
    piston: sim.pistonOfSeat(seat),
    connected: true
  ))
  if seat < sim.seatNames.len and sim.seatNames[seat].len == 0:
    sim.seatNames[seat] = address
  seat

proc removePlayerAt*(sim: var SimServer, index: int) =
  ## Drops one roster row. A seat that disconnects mid-run keeps its piston:
  ## the LIVE server never calls this during play (its script source degrades
  ## to `wavebot` and revives on reconnect); playback calls it only for a
  ## recorded leave.
  if index < 0 or index >= sim.players.len:
    return
  sim.players.delete(index)
  for i in 0 ..< sim.players.len:
    sim.players[i].joinOrder = i
    sim.players[i].seat = i

proc resolvePlayerSlot*(
  sim: SimServer, address, token: string, requestedSlot: int
): int =
  ## The slot one pending connection resolves to.
  if requestedSlot >= 0:
    return requestedSlot
  if token.len > 0:
    for i, entry in sim.config.slots:
      if entry.token == token:
        return i
  sim.players.len

proc ballViewX*(x: int32): int64 =
  ## World micrometres to VIEW centimetres (metres * 100), the only unit a
  ## policy or the chrome ever sees on the x axis.
  int64(x) div 10_000

proc ballViewY*(y: int32): int64 =
  ## World micrometres (y DOWN) to VIEW centimetres above the floor.
  (int64(FloorY) - int64(y)) div 10_000

# ---------------------------------------------------------------------------
#  Contacts
# ---------------------------------------------------------------------------

type
  ContactResult = object
    hit: bool
    depth: int32       ## penetration in um.
    nx, ny: int32      ## outward unit normal, Q12.
    surfaceVy: int32   ## the surface's own velocity, um/tick, +y is DOWN.
    piston: int32      ## -1 for a wall or the ceiling.

proc discVsRect(
  bx, by, x0, y0, x1, y1: int32
): tuple[hit: bool, depth, nx, ny: int32] =
  ## Closest-point disc-vs-axis-aligned-rectangle test, entirely in integers.
  ## Returns the penetration and the OUTWARD unit normal in Q12. A centre
  ## strictly inside the rectangle is pushed straight up, which is the only
  ## direction that cannot wedge the ball deeper into the bank.
  var
    cx = bx
    cy = by
  if cx < x0: cx = x0
  if cx > x1: cx = x1
  if cy < y0: cy = y0
  if cy > y1: cy = y1
  let
    dx = int64(bx) - int64(cx)
    dy = int64(by) - int64(cy)
    distSq = dx * dx + dy * dy
  if distSq == 0:
    return (true, int32(BallRadius) + (by - y0), 0'i32, -4096'i32)
  let dist = isqrt(distSq)
  if dist >= int64(BallRadius):
    return (false, 0'i32, 0'i32, 0'i32)
  let
    nx = int32((dx * 4096'i64) div dist)
    ny = int32((dy * 4096'i64) div dist)
  (true, int32(int64(BallRadius) - dist), nx, ny)

proc gatherContacts(sim: SimServer): seq[ContactResult] =
  ## The fixed contact order of the design note: the CEILING, the LEFT wall,
  ## the RIGHT wall, then every piston head the broadphase returns, ascending.
  ##
  ## There is no separate FLOOR surface. The bank spans the whole playable
  ## width and a head at extension 0 has its top surface exactly on the floor
  ## line, so the heads ARE the floor; testing both would double the normal
  ## force under a resting ball and halve its resting penetration.
  result = @[]
  block ceiling:
    let probe = discVsRect(sim.ballX, sim.ballY,
      0'i32, -WorldHeight, WorldWidth, CeilingY)
    if probe.hit:
      result.add(ContactResult(hit: true, depth: probe.depth,
        nx: probe.nx, ny: probe.ny, surfaceVy: 0, piston: -1))
  block leftWall:
    let probe = discVsRect(sim.ballX, sim.ballY,
      -WorldWidth, -WorldHeight, LeftWallX1, WorldHeight)
    if probe.hit:
      result.add(ContactResult(hit: true, depth: probe.depth,
        nx: probe.nx, ny: probe.ny, surfaceVy: 0, piston: -1))
  block rightWall:
    let probe = discVsRect(sim.ballX, sim.ballY,
      RightWallX0, -WorldHeight, WorldWidth * 2, WorldHeight)
    if probe.hit:
      result.add(ContactResult(hit: true, depth: probe.depth,
        nx: probe.nx, ny: probe.ny, surfaceVy: 0, piston: -1))
  let span = broadphase(sim.ballX)
  if span.last >= span.first:
    for i in span.first .. span.last:
      let top = headTopY(sim.heights[i])
      let probe = discVsRect(sim.ballX, sim.ballY,
        pistonX0(i), top, pistonX1(i), WorldHeight)
      if probe.hit:
        result.add(ContactResult(hit: true, depth: probe.depth,
          nx: probe.nx, ny: probe.ny,
          surfaceVy: -sim.pistonVel[i], piston: int32(i)))

proc substep(sim: var SimServer) =
  ## One 1/96 s substep: gravity, contacts, semi-implicit Euler, pose, guard.
  # 1. gravity (+y is DOWN).
  sim.ballVy += GravityPerSubstep

  # 2. contacts.
  var
    forceX = 0'i64
    forceY = 0'i64
    torque = 0'i64
  for contact in sim.gatherContacts():
    let
      relVx = int64(sim.ballVx)
      relVy = int64(sim.ballVy) - int64(contact.surfaceVy)
      normalVel = (relVx * int64(contact.nx) + relVy * int64(contact.ny)) div 4096
    var approach = -normalVel
    if approach < 0:
      approach = 0
    var normalForce =
      ContactStiffness * int64(contact.depth) + ContactDamping * approach
    if normalForce < 0:
      normalForce = 0
    if normalForce > MaxNormalForce:
      normalForce = MaxNormalForce
    # The contact point relative to the centre, and the tangential velocity
    # there: the sliding part of the relative velocity plus the spin's own
    # surface velocity. This is what makes the ball ROLL instead of slide, and
    # it is what lets a rising head flick it.
    let
      rx = (-int64(contact.nx) * int64(BallRadius)) div 4096
      ry = (-int64(contact.ny) * int64(BallRadius)) div 4096
      spinVx = (int64(sim.spin) * ry) div 652
      spinVy = (-int64(sim.spin) * rx) div 652
      slideX = relVx - (normalVel * int64(contact.nx)) div 4096
      slideY = relVy - (normalVel * int64(contact.ny)) div 4096
      tanX = slideX + spinVx
      tanY = slideY + spinVy
      tanMag = isqrt(tanX * tanX + tanY * tanY)
    var tangentX = 0'i64
    var tangentY = 0'i64
    if tanMag > 0:
      var magnitude = (FrictionNum * normalForce) div FrictionDen
      let viscous = tanMag * FrictionViscous
      if viscous < magnitude:
        magnitude = viscous
      tangentX = -(magnitude * tanX) div tanMag
      tangentY = -(magnitude * tanY) div tanMag
    forceX += (normalForce * int64(contact.nx)) div 4096 + tangentX
    forceY += (normalForce * int64(contact.ny)) div 4096 + tangentY
    torque += (tangentX * ry - tangentY * rx) div 1_000_000
    sim.contacts.add(ContactRecord(
      surface: contact.piston,
      depth: contact.depth,
      approach: int32(approach),
      slip: int32(tanMag)))
    if contact.piston >= 0:
      sim.contactPistons[int(contact.piston)] = true

  # 3. integrate (semi-implicit Euler), then drag.
  let
    massDen = int64(BallMassGrams) * int64(SubSteps) * int64(TargetFps) *
      int64(TargetFps)
    deltaVx = (forceX * 1_000_000'i64) div massDen
    deltaVy = (forceY * 1_000_000'i64) div massDen
  var
    vx = int64(sim.ballVx) + deltaVx
    vy = int64(sim.ballVy) + deltaVy
  vx -= (vx * AirDragNum) div AirDragDen
  vy -= (vy * AirDragNum) div AirDragDen
  var spin = int64(sim.spin) +
    (torque * TorqueScale) div (int64(BallInertia) * TorqueDen)
  spin -= (spin * SpinDragNum) div SpinDragDen
  if vx > int64(MaxBallSpeed): vx = int64(MaxBallSpeed)
  if vx < -int64(MaxBallSpeed): vx = -int64(MaxBallSpeed)
  if vy > int64(MaxBallSpeed): vy = int64(MaxBallSpeed)
  if vy < -int64(MaxBallSpeed): vy = -int64(MaxBallSpeed)
  if spin > int64(MaxBallSpin): spin = int64(MaxBallSpin)
  if spin < -int64(MaxBallSpin): spin = -int64(MaxBallSpin)
  sim.ballVx = int32(vx)
  sim.ballVy = int32(vy)
  sim.spin = int32(spin)

  # 4. pose. Both integrations divide by SubSteps, never by a literal: `spin`
  # is 1/16 brad PER TICK (that is the unit the rolling relation
  # `spin = -vx * 652 / R` is written in), so the drawn angle must advance by
  # exactly `spin` over the whole tick, whatever the substep count is.
  sim.ballX += sim.ballVx div int32(SubSteps)
  sim.ballY += sim.ballVy div int32(SubSteps)
  sim.angleQ = int32(
    (int64(sim.angleQ) + int64(sim.spin) div int64(SubSteps) + 4096) mod 4096)

  # 5. containment guard.
  var clamped = false
  if sim.ballX < GuardMinX:
    if GuardMinX - sim.ballX > GuardEpsilonUm: clamped = true
    sim.ballX = GuardMinX
    if sim.ballVx < 0: sim.ballVx = 0
  elif sim.ballX > GuardMaxX:
    if sim.ballX - GuardMaxX > GuardEpsilonUm: clamped = true
    sim.ballX = GuardMaxX
    if sim.ballVx > 0: sim.ballVx = 0
  if sim.ballY < GuardMinY:
    if GuardMinY - sim.ballY > GuardEpsilonUm: clamped = true
    sim.ballY = GuardMinY
    if sim.ballVy < 0: sim.ballVy = 0
  elif sim.ballY > GuardMaxY:
    if sim.ballY - GuardMaxY > GuardEpsilonUm: clamped = true
    sim.ballY = GuardMaxY
    if sim.ballVy > 0: sim.ballVy = 0
  if clamped:
    inc sim.guardClamps

# ---------------------------------------------------------------------------
#  The step
# ---------------------------------------------------------------------------

proc finishGame*(sim: var SimServer, reason, rule: string) =
  ## Ends the episode with a legal (reason, endRule) pair and freezes the
  ## score at this tick.
  if sim.phase == GameOver:
    return
  sim.phase = GameOver
  sim.endReason = reason
  sim.endRule = rule
  sim.gameOverTimer = sim.config.gameOverTicks
  sim.emitEvent(PhaseChange, content = rule)

proc startGame(sim: var SimServer) =
  sim.phase = Playing
  # The FIRST tick that will actually be played, not the lobby tick that
  # flipped the phase: `gameTicksElapsed` is what the turn clock, the penalty
  # accounting and the spectator start tick are all measured against.
  sim.gameStartTick = sim.tickCount + 1
  sim.emitEvent(PhaseChange, content = "playing")

proc checkInvariants(sim: SimServer) =
  ## The step-8 guard set. A trip ends the episode `fault`/`sim_fault` with a
  ## partial replay, never a silent non-zero exit.
  for i in 0 ..< PistonCount:
    if sim.heights[i] < 0 or sim.heights[i] > Stroke:
      raise newException(SimGuardError,
        "piston " & $i & " height out of range: " & $sim.heights[i])
  if abs32(sim.ballVx) > MaxBallSpeed or abs32(sim.ballVy) > MaxBallSpeed:
    raise newException(SimGuardError, "ball velocity exceeded its clamp")
  if abs32(sim.spin) > MaxBallSpin:
    raise newException(SimGuardError, "ball spin exceeded its clamp")
  if sim.angleQ < 0 or sim.angleQ > 4095:
    raise newException(SimGuardError, "ball angle out of range")
  if int(sim.guardClamps) > MaxGuardClamps:
    raise newException(SimGuardError,
      "containment guard fired " & $sim.guardClamps & " times")

proc step*(sim: var SimServer, commands: openArray[uint8]) =
  ## Advances the simulation by one tick. `commands` is indexed by SEAT — the
  ## same index the replay's input records carry — and the loop maps it to
  ## piston order through `perm`, so the recorded action log and the loop
  ## agree by construction.
  sim.contacts.setLen(0)
  case sim.phase
  of Lobby:
    inc sim.lobbyTicks
    # A seat that never connects does NOT end the episode. The lobby's own
    # join budget starts the match anyway once it expires, and the missing
    # seat's piston is driven by the `wavebot` baseline for the whole run.
    # The rule lives HERE, in the sim, so playback re-derives it from the
    # recorded joins instead of depending on a live-server decision.
    let forced = sim.config.lobbyJoinTimeoutTicks > 0 and
      sim.lobbyTicks >= sim.config.lobbyJoinTimeoutTicks and
      sim.players.len > 0
    if sim.lobbyIsStarting() or forced:
      if sim.config.startWaitTicks <= 0:
        sim.startGame()
      else:
        if sim.startWaitTimer <= 0:
          sim.startWaitTimer = sim.config.startWaitTicks
        dec sim.startWaitTimer
        if sim.startWaitTimer <= 0:
          sim.startGame()
    inc sim.tickCount
    return
  of GameOver:
    if sim.gameOverTimer > 0:
      dec sim.gameOverTimer
    inc sim.tickCount
    return
  of Playing:
    discard

  # --- 3. piston kinematics ------------------------------------------------
  # Pistons are KINEMATIC: they move the ball, the ball never moves them.
  for piston in 0 ..< PistonCount:
    let seat = sim.seatOfPiston(piston)
    var command = 127'u8
    if seat >= 0 and seat < commands.len:
      command = commands[seat]
    let previous = sim.heights[piston]
    var height = int64(previous) + int64(decodePistonCommand(command))
    if height < 0: height = 0
    if height > int64(Stroke): height = int64(Stroke)
    sim.heights[piston] = int32(height)
    sim.pistonVel[piston] = sim.heights[piston] - previous

  # --- 4. four substeps ----------------------------------------------------
  let previousX = sim.ballX
  for i in 0 ..< PistonCount:
    sim.prevContactPistons[i] = sim.contactPistons[i]
    sim.contactPistons[i] = false
  for _ in 0 ..< SubSteps:
    sim.substep()

  # --- 5. progress accounting ---------------------------------------------
  let delta = int64(previousX) - int64(sim.ballX)
  sim.progressMilli += (1000'i64 * 100'i64 * delta) div int64(TravelDistance)
  sim.penaltyMilli += int64(sim.config.stepPenaltyMilli)
  if sim.ballX < sim.bestX:
    sim.bestX = sim.ballX
    sim.lastBounceBackBest = sim.bestX
    sim.stallCount = 0
  else:
    inc sim.stallCount
    if sim.stallCount > sim.maxStallTicks:
      sim.maxStallTicks = sim.stallCount
    if sim.stallCount mod int32(StallTicks) == 0:
      sim.emitEvent(Stall, amount = int(sim.stallCount))
  if sim.ballX > sim.bestX + BounceBackUm and
      sim.lastBounceBackBest == sim.bestX:
    sim.lastBounceBackBest = sim.bestX - 1
    inc sim.bounceBacks
    sim.emitEvent(BounceBack, amount = int(sim.ballX - sim.bestX))

  # --- 6. phase accounting (the "who's out of phase" measure) --------------
  for i in 0 ..< PistonCount:
    let offset = sim.ballX - pistonCentreX(i)
    if abs32(offset) <= EngagedHalfWidth:
      inc sim.engagedTicks[i]
      let wantUp = pistonCentreX(i) >= sim.ballX
      let inPhase =
        if wantUp: sim.heights[i] >= InPhaseUpHeight
        else: sim.heights[i] <= InPhaseDownHeight
      if inPhase:
        inc sim.inPhaseTicks[i]
    if sim.contactPistons[i] and not sim.prevContactPistons[i]:
      inc sim.touches[i]

  # Support column + launch/wall events (presentation only, never hashed).
  var support = -1
  var deepest = 0'i32
  for record in sim.contacts:
    if record.surface >= 0 and record.depth >= deepest:
      deepest = record.depth
      support = int(record.surface)
    if record.surface >= 0 and record.approach > LaunchApproachUm:
      sim.emitEvent(Launch, source = int(record.surface),
        amount = int(record.approach))
  if support >= 0 and int32(support) != sim.supportColumn:
    sim.supportColumn = int32(support)
    sim.emitEvent(Handoff, source = support)
  if sim.tickCount > 48 and sim.ballX >= GuardMaxX:
    sim.emitEvent(WallTouch)

  inc sim.tickCount

  # --- 8. end checks, in this order ----------------------------------------
  if sim.ballX <= GoalX:
    sim.deliveryTick = sim.tickCount
    sim.emitEvent(Delivered, amount = sim.tickCount)
    sim.finishGame(ReasonComplete, EndRuleDelivered)
    return
  if sim.config.maxTicks > 0 and sim.tickCount >= sim.config.maxTicks:
    sim.finishGame(ReasonComplete, EndRuleOutOfTime)
    return
  sim.checkInvariants()

proc stopForWallClock*(sim: var SimServer) =
  ## The engine's own hard stop. Scores the state as it stands and writes a
  ## complete replay up to this tick.
  sim.finishGame(ReasonDeadline, EndRuleWallClock)

proc holdSay*(sim: var SimServer, piston: int, text: string, untilTick: int) =
  ## Parks one piston's spectator line. Never hashed: `say` is one-way to the
  ## feed and the bubble band and can never reach another seat.
  if piston < 0 or piston >= sim.says.len:
    return
  sim.says[piston] = text
  sim.sayUntil[piston] = untilTick

proc pushFeedScript*(sim: var SimServer, record: string) =
  ## Parks one `script` record for the broadcast feed. Bounded so a long
  ## episode cannot grow the frame without limit.
  sim.feedScripts.add(record)
  while sim.feedScripts.len > 40:
    sim.feedScripts.delete(0)
