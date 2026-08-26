## Pistonball sim types and constants.
##
## INTEGER ONLY. This module, together with `bank.nim`, `trig.nim`,
## `sim_config.nim`, `sim_state.nim` and `sim.nim`, contains no floating point
## of any kind: the replay is re-simulated by the emscripten/wasm32 build of
## the same code the native amd64 server ran, and the per-tick `gameHash`
## chain has to match bit-for-bit. Integers make that true by construction
## instead of by an argument about two musl builds agreeing.
## `tests/test_determinism.nim` greps this file (and the other five) and fails
## on any hit.
##
## Nim's `int` is 64-bit natively and 32-BIT under `--cpu:wasm32`, so every
## stored sim field is explicitly `int32`/`int64`, and every product of two sim
## quantities is computed in `int64` and narrowed with an explicit truncating
## `div`.

const
  GameName* = "pistonball"
  GameVersion* = "1"
    ## GV1 (first rules): TWENTY PISTONS, ONE BALL, ROLL IT LEFT.
    ## Prepend-only changelog: say what a new number MEANS and what it
    ## obsoletes, and keep the `GVnn (short rule name): HEADLINE` shape so two
    ## independent claims on one number are distinguishable at a glance.

  TargetFps* = 24            ## wall-clock pacing of the live loop.
  ReplayFps* = 24            ## replay millisecond conversion. Kept equal.
  SubSteps* = 16
    ## Physics substeps per tick (1/384 s each). The contact spring is stiff —
    ## 150 mN per micrometre against a 6 kg ball is an undamped period of
    ## about one TICK — and a semi-implicit integrator only behaves while
    ## `omega * dt` stays well under 1. At the design note's four substeps the
    ## step is 1.65 of that and the ball simply bounced off the bank forever;
    ## at sixteen it is 0.41 and the same spring settles in a few substeps
    ## with a coefficient of restitution under 0.1. The stiffness is what the
    ## design pins; the step is what had to move to integrate it.
    ##
    ## What the ball actually rests at is 0 .. 65 um of penetration, not the
    ## 392 um the spring alone would hold it at (150 mN/um against a 6 kg
    ## weight on this timebase), because the pose update truncates
    ## `v div SubSteps`: a vertical speed under 16 um/tick moves the ball zero
    ## micrometres, so it rides one substep of gravity, 1064/16 = 66 um, above
    ## the static equilibrium. Measured at every stroke and pinned by
    ## `tests/test_physics.nim`.
  PlaybackSpeeds* = [1, 2, 3, 4, 8, 16]

  PistonCount* = 20          ## the bank is exactly twenty heads. Not a knob.
  MaxPlayers* = 20

  ## --- board render -------------------------------------------------------
  MapWidth* = 1200           ## board pixels; 1 board px = 8000 um.
  MapHeight* = 600
  WorldPerPixel* = 8_000'i32

  ## --- world box (micrometres, origin top-left, y DOWN) -------------------
  WorldWidth* = 9_600_000'i32
  WorldHeight* = 4_800_000'i32
  FloorY* = 4_400_000'i32    ## the floor surface; below it is housing art.
  CeilingY* = 0'i32
  LeftWallX1* = 800_000'i32  ## the goal wall spans x in [0, 800000].
  RightWallX0* = 8_800_000'i32

  ## --- geometry -----------------------------------------------------------
  PistonWidth* = 400_000'i32
  Stroke* = 1_600_000'i32
  MaxPistonSpeed* = 80_000'i32     ## um/tick (1.92 m/s).
  BallRadius* = 400_000'i32
  BallMassGrams* = 6_000'i32
  BallInertia* = 480'i32           ## milli-kg*m^2, = 1/2 m R^2.
  WindowHalfWidth* = 1_000_000'i32
  GoalX* = 1_200_000'i32
  BallStartX* = 8_400_000'i32
  BallStartY* = 3_400_000'i32
  TravelDistance* = 7_200_000'i32
  GravityPerSubstep* = 1_064'i32   ## um/tick per substep (9.81 m/s^2 at 384 Hz).

  ## --- contact solver -----------------------------------------------------
  ## PER-SUBSTEP coefficients, on the 384 Hz substep clock (`SubSteps = 16`).
  ## Only `GravityPerSubstep` was rescaled when the substep count went 4 -> 16,
  ## because gravity is the one quantity whose per-TICK value is fixed by
  ## physics. The three coefficients below kept the design note's 96 Hz
  ## numbers, so per TICK they are about four times the note's: the torque
  ## gain behaves like a rotational inertia of ~120 rather than
  ## `BallInertia = 480`, and a tick of air drag is `(1 - 8/4096)^16 = 0.969`
  ## rather than `^4 = 0.992`. That is deliberate and it is LOAD-BEARING, not
  ## an oversight left in place: the whole tuning was measured against these
  ## values, and dividing them by four (28_294 -> 7_074, 8 -> 2, 12 -> 3, which
  ## is the exact per-tick rescale) makes the ball so much livelier that the
  ## certification fixture's nineteen metronomes DELIVER — 4 of 24 seeds
  ## measured, one in 53 ticks — and a fixture that short is the frozen-replay
  ## failure the metronome fleet exists to avoid (`844697a`). Treat the four
  ## numbers as one tuned set: changing any of them re-tunes the game and
  ## invalidates `tests/data/golden_hashes.json`.
  ContactStiffness* = 150'i64      ## mN per um of penetration.
  ContactDamping* = 28'i64         ## mN per (um/tick) of approach.
  MaxNormalForce* = 60_000_000'i64 ## mN.
  FrictionNum* = 614'i64           ## Coulomb mu = 0.60 in 1/1024ths.
  FrictionDen* = 1024'i64
  FrictionViscous* = 150'i64       ## mN per (um/tick) of tangential slip.
  AirDragNum* = 8'i64              ## per SUBSTEP; 16 of them per tick.
  AirDragDen* = 4096'i64
  SpinDragNum* = 12'i64            ## per SUBSTEP; 16 of them per tick.
  SpinDragDen* = 4096'i64
  MaxBallSpeed* = 250_000'i32      ## um/tick (6.0 m/s).
  MaxBallSpin* = 300'i32           ## 1/16 brad per tick.
  TorqueScale* = 28_294'i64        ## mN*m -> 1/16 brad per tick, PER SUBSTEP.
  TorqueDen* = 100_000'i64

  ## --- containment guard --------------------------------------------------
  ## The box the ball centre is clamped into every substep. It exists to make
  ## a TUNNELLING artefact bounded, not to hold the ball off the bank, so the
  ## vertical bounds carry 0.2 m of slack past the resting geometry: a ball
  ## sitting on a head at extension 0 has its centre at y = 4 000 000, and a
  ## guard set exactly there would undo the contact penetration every substep
  ## and the bank would never touch the ball at all.
  GuardMinX* = 1_200_000'i32
  GuardMaxX* = 8_400_000'i32
  GuardMinY* = 200_000'i32
  GuardMaxY* = 4_300_000'i32
  MaxGuardClamps* = 8

  ## --- progress / phase ---------------------------------------------------
  BounceBackUm* = 400_000'i32
  StallTicks* = 240
  EngagedHalfWidth* = 1_200_000'i32
  InPhaseUpHeight* = 800_000'i32
  InPhaseDownHeight* = 600_000'i32

  ## --- rune caps (every one measured in RUNES, never bytes) ---------------
  MaxNoteRunes* = 160
  MaxSayRunes* = 48
  MaxPolicyLabelRunes* = 48
  MaxFallbackDetailRunes* = 200
  MaxScriptRecordRunes* = 700
  MaxPromptRunes* = 4000

  ## --- routes -------------------------------------------------------------
  WebSocketPath* = "/player"
  GlobalWebSocketPath* = "/global"
  ReplayWebSocketPath* = "/replay"

  ## --- sprite protocol layers (bitworld ids) ------------------------------
  MapLayerId* = 0
  MapLayerType* = 0
  ZoomableLayerFlag* = 1
  UiLayerFlag* = 2
  BroadcastChromeSpriteId* = 4090

  ## --- end reasons / rules (closed enums; results_schema mirrors them) ----
  ReasonComplete* = "complete"
  ReasonDeadline* = "deadline"
  ReasonFault* = "fault"
  EndRuleDelivered* = "delivered"
  EndRuleOutOfTime* = "out_of_time"
  EndRuleWallClock* = "wall_clock"
  EndRuleSimFault* = "sim_fault"
  EndRuleHostError* = "host_error"

type
  PistonballError* = object of CatchableError
  SimGuardError* = object of PistonballError
    ## A sim invariant tripped. Ends the episode `fault`/`sim_fault` with a
    ## partial replay rather than crashing the process.

  GamePhase* = enum
    Lobby = "lobby"
    Playing = "playing"
    GameOver = "gameover"

  SlotConfig* = object
    alias*: string
    name*: string
    token*: string

  GameConfig* = object
    seed*: int
    numAgents*: int
    minPlayers*: int
    maxTicks*: int
    maxGames*: int
    turnTicks*: int
    turnBudgetMs*: int
    attempt1Ms*: int
    retryMs*: int
    minBatchSpacingMs*: int
    wallClockBudgetSeconds*: int
    lobbyJoinTimeoutTicks*: int
    startWaitTicks*: int
    gameOverTicks*: int
    speed*: int
    fastMode*: bool
    showPlayerLabels*: bool
    closedRoster*: bool
    model*: string
    maxOutputTokens*: int
    windowHalfWidthUm*: int
    strokeUm*: int
    maxPistonSpeedUm*: int
    ballRadiusUm*: int
    ballMassGrams*: int
    stepPenaltyMilli*: int
    slots*: seq[SlotConfig]

  Player* = object
    ## One seat's roster row. Twenty of these, one per piston-driving seat.
    address*: string           ## the REAL policy name (spectator side only).
    joinOrder*: int
    seat*: int
    token*: string
    piston*: int               ## perm[seat]: which head this seat drives.
    connected*: bool

  SimEventKind* = enum
    Handoff
    Launch
    BounceBack
    Stall
    WallTouch
    Script
    PhaseChange
    Delivered

  SimEvent* = object
    tick*: int
    kind*: SimEventKind
    source*: int
    amount*: int
    x*, y*: int
    content*: string

  ContactRecord* = object
    ## One resolved contact this tick, for events and FX. Never hashed.
    surface*: int32            ## -1 wall/floor/ceiling, else the piston index.
    depth*: int32
    approach*: int32
    slip*: int32

  SimServer* = object
    ## The whole hashed simulation state plus its non-hashed presentation
    ## sidecars. Serialized wholesale into replay keyframes by flatty, so
    ## every field must stay a plain value type.
    config*: GameConfig
    phase*: GamePhase
    tickCount*: int
    gameStartTick*: int
    gameOverTimer*: int
    startWaitTimer*: int
    lobbyTicks*: int
    players*: seq[Player]

    ## --- hashed physics state --------------------------------------------
    ballX*, ballY*: int32
    ballVx*, ballVy*: int32
    angleQ*: int32
    spin*: int32
    heights*: seq[int32]
    pistonVel*: seq[int32]
    restHeights*: seq[int32]
    perm*: seq[int32]
    bestX*: int32
    progressMilli*: int64
    penaltyMilli*: int64
    stallCount*: int32
    maxStallTicks*: int32
    bounceBacks*: int32
    guardClamps*: int32
    deliveryTick*: int
    permDigest*: int64

    ## --- hashed-but-derived accounting ------------------------------------
    engagedTicks*: seq[int32]
    inPhaseTicks*: seq[int32]
    touches*: seq[int32]
    lastBounceBackBest*: int32
    contactPistons*: seq[bool]
    prevContactPistons*: seq[bool]
    supportColumn*: int32

    ## --- non-hashed presentation ------------------------------------------
    endReason*: string
    endRule*: string
    seatNames*: seq[string]
    seatPolicyKind*: seq[string]
    llmTurns*: seq[int]
    fallbackTurns*: seq[int]
    lastTurnRewardMilli*: int64
    turnStartProgressMilli*: int64
    turnStartPenaltyMilli*: int64
    feedScripts*: seq[string]
    says*: seq[string]
    sayUntil*: seq[int]
    contacts*: seq[ContactRecord]
    events*: seq[SimEvent]
    collectEvents*: bool
    gameEventLoggingEnabled*: bool

proc seatCount*(sim: SimServer): int =
  ## The number of SEATS the episode is configured for (20).
  if sim.config.numAgents > 0: sim.config.numAgents else: PistonCount

proc pistonX0*(index: int): int32 =
  ## Left edge of piston `index`, in world micrometres.
  LeftWallX1 + PistonWidth * int32(index)

proc pistonCentreX*(index: int): int32 =
  ## Centre of piston `index`, in world micrometres.
  LeftWallX1 + PistonWidth * int32(index) + PistonWidth div 2

proc effectiveMaxTicks*(sim: SimServer): int =
  ## The tick budget the transport bar measures against.
  if sim.config.maxTicks > 0: sim.config.maxTicks else: 1800

proc gameTicksElapsed*(sim: SimServer): int =
  ## Ticks since the match left the lobby.
  max(0, sim.tickCount - sim.gameStartTick)

proc turnsPerGame*(sim: SimServer): int =
  ## How many decision turns this episode's tick budget buys.
  let turnTicks = max(1, sim.config.turnTicks)
  max(1, sim.effectiveMaxTicks() div turnTicks)

proc alias*(index: int): string =
  ## The ANONYMOUS in-game name of piston `index`: PST-01 .. PST-20. It names
  ## a POSITION ON THE BOARD, which every seat legitimately knows, and never
  ## an entrant.
  let n = index + 1
  if n < 10: "PST-0" & $n else: "PST-" & $n
