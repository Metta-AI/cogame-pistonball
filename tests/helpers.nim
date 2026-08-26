## Shared test helpers: a full scripted episode, run headless.

import
  std/[json, os, random],
  ../src/pistonball/[sim, scripts, control, baselines, decide, replays, roster]

proc testConfig*(seed = 4417231, maxTicks = 1800): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.maxTicks = maxTicks
  # `maxTicks` must be a whole number of turns; a short test episode gets one
  # long turn rather than a config the validator would refuse.
  result.turnTicks = if maxTicks mod 225 == 0: 225 else: maxTicks
  result.minPlayers = 1
  result.startWaitTicks = 0
  result.lobbyJoinTimeoutTicks = 1
  result.gameOverTicks = 0
  result.minBatchSpacingMs = 0
  result.update("")

proc seatedSim*(config: GameConfig, seats = PistonCount): SimServer =
  result = initSimServer(config)
  for seat in 0 ..< seats:
    discard result.addPlayer("policy-" & $seat, seat, "", trusted = true)

proc scriptedCommands*(
  game: SimServer, kinds: openArray[Baseline],
  params = DefaultBaselineParams
): seq[uint8] =
  ## One command byte per SEAT, compiled in PISTON index order.
  result = newSeq[uint8](game.seatCount())
  for i in 0 ..< result.len:
    result[i] = 127'u8
  for piston in 0 ..< PistonCount:
    let seat = game.seatOfPiston(piston)
    if seat < 0 or seat >= result.len:
      continue
    let kind = kinds[seat mod max(1, kinds.len)]
    result[seat] = pistonCommand(
      game, scriptedScript(game, kind, piston, params), piston)

proc runScripted*(
  seed: int, kinds: openArray[Baseline], maxTicks = 1800,
  params = DefaultBaselineParams
): SimServer =
  ## A whole twenty-seat scripted episode, headless and deterministic.
  var game = seatedSim(testConfig(seed, maxTicks))
  var guard = 0
  while game.phase != GameOver and guard < maxTicks + 16:
    inc guard
    let commands = scriptedCommands(game, kinds, params)
    game.step(commands)
  game

proc runScriptedRecording*(
  seed: int, kinds: openArray[Baseline], maxTicks = 1800
): tuple[game: SimServer, commandLog: seq[seq[uint8]]] =
  ## The same episode, keeping every tick's command bytes so a second run can
  ## be driven from the LOG rather than from the controller.
  var game = seatedSim(testConfig(seed, maxTicks))
  var log: seq[seq[uint8]]
  var guard = 0
  while game.phase != GameOver and guard < maxTicks + 16:
    inc guard
    let commands = scriptedCommands(game, kinds)
    log.add(commands)
    game.step(commands)
  (game, log)

proc replayCommandLog*(
  seed: int, log: seq[seq[uint8]], maxTicks = 1800
): seq[uint64] =
  ## Re-simulates from a recorded command log and returns the hash chain.
  var game = seatedSim(testConfig(seed, maxTicks))
  for commands in log:
    game.step(commands)
    result.add(game.gameHash())

proc randomScript*(rng: var Rand): PistonScript =
  result = defaultScript()
  result.mode = Mode(rng.rand(ord(Mode.high)))
  result.blind = Blind(rng.rand(ord(Blind.high)))
  result.triggerUm = int32(rng.rand(int(WindowHalfWidth)))
  result.leadTicks = rng.rand(24)
  result.upUm = int32(rng.rand(int(Stroke)))
  result.downUm = int32(rng.rand(int(Stroke)))
  result.idleUm = int32(rng.rand(int(Stroke)))
  result.speed255 = rng.rand(255)

proc scrambleState*(game: var SimServer, rng: var Rand) =
  ## Puts the sim into an arbitrary but LEGAL state, for the randomised
  ## controller and locality sweeps.
  game.phase = Playing
  game.ballX = int32(GuardMinX + rng.rand(int(GuardMaxX - GuardMinX)))
  game.ballY = int32(GuardMinY + rng.rand(int(GuardMaxY - GuardMinY)))
  game.ballVx = int32(rng.rand(2 * int(MaxBallSpeed)) - int(MaxBallSpeed))
  game.ballVy = int32(rng.rand(2 * int(MaxBallSpeed)) - int(MaxBallSpeed))
  game.spin = int32(rng.rand(2 * int(MaxBallSpin)) - int(MaxBallSpin))
  game.angleQ = int32(rng.rand(4095))
  for i in 0 ..< PistonCount:
    game.heights[i] = int32(rng.rand(int(Stroke)))
    game.pistonVel[i] = 0

proc writeTempReplay*(name, bytes: string): string =
  result = getTempDir() / name
  writeFile(result, bytes)

proc jsonOf*(text: string): JsonNode =
  parseJson(text)
