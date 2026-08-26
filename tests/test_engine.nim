## The turn loop: batching, bounded waits, the budget guard and the fallbacks.
##
## The LLM client is exercised WITHOUT credentials, which is exactly the state
## certification runs in: the client disables itself and every turn falls back
## to the scripted layer instantly, with no network wait.

import
  std/[json, os, strutils, times, unittest],
  ../src/pistonball/[sim, roster, scripts, control, baselines, decide, llm],
  ./helpers

proc llmEngine(game: SimServer): DecisionEngine =
  result = initDecisionEngine(game)
  for seat in 0 ..< result.seats.len:
    result.seats[seat].isLlm = true
    result.seats[seat].registered = true
    result.seats[seat].prompt = "be the shoulder the ball rolls off"
    result.seats[seat].label = "prompt"

suite "the decision turn":
  setup:
    delEnv("ANTHROPIC_API_KEY")
    delEnv("ANTHROPIC_API_KEY_URI")
    delEnv("AWS_BEARER_TOKEN_BEDROCK")
    delEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME")

  test "with no credentials every one of the twenty seats falls back in ONE turn":
    var game = seatedSim(testConfig())
    game.phase = Playing
    var engine = llmEngine(game)
    check engine.client.disabled
    let records = engine.turn(game, 0, 0)
    var seatsSeen: seq[int]
    for record in records:
      let node = parseJson(record)
      if node["k"].getStr() == "fallback":
        check node["cause"].getStr() == "no_credentials"
        seatsSeen.add(node["seat"].getInt)
    check seatsSeen.len == 20
    for seat in 0 ..< 20:
      check seat in seatsSeen
      check engine.haveScript[seat]
      check engine.scripts[seat].source == srcFallback
      check validScript(engine.scripts[seat])

  test "a turn with no credentials costs no wall clock at all":
    var game = seatedSim(testConfig())
    game.phase = Playing
    var engine = llmEngine(game)
    let started = epochTime()
    for turn in 0 ..< 8:
      discard engine.turn(game, turn, 0)
    check epochTime() - started < 2.0

  test "the budget guard fires and the run finishes on the scripted layer":
    var game = seatedSim(testConfig())
    game.phase = Playing
    var engine = llmEngine(game)
    # elapsed + 2 * (turnBudget + spacing) > wallClockBudget
    let records = engine.turn(game, 0, game.config.wallClockBudgetSeconds - 5)
    var guarded = false
    for record in records:
      if parseJson(record)["k"].getStr() == "budget_guard":
        guarded = true
    check guarded
    check engine.llmOff
    for seat in 0 ..< 20:
      check engine.haveScript[seat]

  test "attempt1Ms + retryMs fit inside turnBudgetMs, and none is sub-second":
    let config = defaultGameConfig()
    check config.attempt1Ms + config.retryMs <= config.turnBudgetMs
    check config.attempt1Ms >= 1000
    check config.retryMs >= 1000
    # curly's deadline granularity is WHOLE SECONDS, so a sub-second value is
    # not the deadline it claims to be — sim_config rejects one.
    var bad = defaultGameConfig()
    expect PistonballError:
      bad.update("{\"attempt1Ms\": 500}")

  test "every wait settles inside 60 % of episodeTimeoutSeconds":
    let config = defaultGameConfig()
    # 8 turns, one batch each, spaced minBatchSpacingMs apart, plus one turn's
    # own hard cap, plus the lobby, the physics and the artifact write.
    let turns = config.maxTicks div config.turnTicks
    let worstMs = (turns - 1) * config.minBatchSpacingMs + config.turnBudgetMs
    let lobbySeconds = config.lobbyJoinTimeoutTicks div TargetFps
    let total = worstMs div 1000 + lobbySeconds + 1 + 20
    check total < config.wallClockBudgetSeconds
    check config.wallClockBudgetSeconds <= (60 * 1200) div 100

  test "a seat with a script keeps it; a seat without one plays wavebot":
    var game = seatedSim(testConfig())
    game.phase = Playing
    var engine = initDecisionEngine(game)
    check not engine.haveScript[3]
    let fallback = engine.scriptFor(game, 3)
    check fallback.mode == modeWave           # wavebot's shape
    var mine = defaultScript()
    mine.mode = modeCatch
    engine.scripts[3] = mine
    engine.haveScript[3] = true
    check engine.scriptFor(game, 3).mode == modeCatch

  test "a scripted seat never produces a fallback record":
    var game = seatedSim(testConfig())
    game.phase = Playing
    var engine = initDecisionEngine(game)
    for seat in 0 ..< engine.seats.len:
      engine.seats[seat].baseline = blMetronome
    let records = engine.turn(game, 0, 0)
    check records.len == 0
    for seat in 0 ..< 20:
      check engine.scripts[seat].source == srcScripted
      check engine.scripts[seat].mode == modeRipple

  test "the wall-clock stop yields deadline/wall_clock and still scores":
    var game = seatedSim(testConfig())
    game.phase = Playing
    for _ in 0 ..< 60:
      game.step(newSeq[uint8](PistonCount))
    game.stopForWallClock()
    check game.phase == GameOver
    check game.endReason == ReasonDeadline
    check game.endRule == EndRuleWallClock
    let results = parseJson(game.playerResultsJson())
    check results["reason"].getStr() == "deadline"
    check results["endRule"].getStr() == "wall_clock"
    check results["scores"].len == 20

  test "a tripped invariant is a SimGuardError, not a crash":
    var game = seatedSim(testConfig())
    game.phase = Playing
    game.guardClamps = int32(MaxGuardClamps + 1)
    expect SimGuardError:
      game.step(newSeq[uint8](PistonCount))

  test "the shared-reward delta is the ONLY global scalar, and it rolls per turn":
    var game = seatedSim(testConfig())
    game.phase = Playing
    var engine = initDecisionEngine(game)
    game.progressMilli = 8000
    game.penaltyMilli = 1580
    discard engine.turn(game, 1, 0)
    check game.lastTurnRewardMilli == 6420
    game.progressMilli = 9000
    game.penaltyMilli = 4000
    discard engine.turn(game, 2, 0)
    check game.lastTurnRewardMilli == (9000 - 8000) - (4000 - 1580)
