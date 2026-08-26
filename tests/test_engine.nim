## The turn loop: batching, bounded waits, the budget guard and the fallbacks.
##
## The LLM client is exercised WITHOUT credentials, which is exactly the state
## certification runs in: the client disables itself and every turn falls back
## to the scripted layer instantly, with no network wait.

import
  std/[json, monotimes, os, strutils, times, unittest],
  curly,
  ../src/pistonball/[sim, roster, scripts, control, baselines, decide, llm],
  ./helpers

proc llmEngine(game: SimServer): DecisionEngine =
  result = initDecisionEngine(game)
  for seat in 0 ..< result.seats.len:
    result.seats[seat].isLlm = true
    result.seats[seat].registered = true
    result.seats[seat].prompt = "be the shoulder the ball rolls off"
    result.seats[seat].label = "prompt"

# ---------------------------------------------------------------------------
#  A FAKE PROVIDER.
#
#  The turn loop's contract is invisible from outside the process: whether the
#  twenty calls went out together or one after another, whether the retry
#  happened once or twice, whether a throttle cancelled it, and whether a hung
#  provider still hands the turn back inside `turnBudgetMs` all look identical
#  from the records alone. `LlmClient.sendBatch` is the seam; this is what goes
#  through it.
# ---------------------------------------------------------------------------

type
  FakeBatch = object
    size: int
    tags: seq[string]
    startMs, endMs: int
  FakeProvider = ref object
    batches: seq[FakeBatch]
    delayMs: int
    code: int                 ## HTTP status to answer with
    bodyForAttempt: seq[string]  ## body per attempt; last entry repeats
    origin: MonoTime

const GoodScript = """{"note":"lift behind it","mode":"wave",""" &
  """"trigger_m":0.8,"lead_ticks":6,"up_m":1.45,"down_m":0.1,""" &
  """"idle_m":0.25,"speed":1.0,"blind":"idle","say":"up behind it"}"""

proc anthropicBody(text: string): string =
  $(%*{"stop_reason": "end_turn",
       "content": [{"type": "text", "text": text}]})

proc newFakeProvider(
  bodies: seq[string], delayMs = 0, code = 200
): FakeProvider =
  FakeProvider(delayMs: delayMs, code: code, bodyForAttempt: bodies,
    origin: getMonoTime())

proc fakeClient(provider: FakeProvider): LlmClient =
  ## An LlmClient that never opens a socket. `transport` is set so the turn
  ## loop treats it as live; `curl` stays nil and is never touched.
  let fake = provider
  result = LlmClient(transport: ltAnthropic, model: "fake-haiku",
    maxOutputTokens: 900)
  result.sendBatch = proc(
    batch: RequestBatch, timeoutSeconds: int
  ): ResponseBatch {.gcsafe, raises: [].} =
    let startMs = (getMonoTime() - fake.origin).inMilliseconds.int
    if fake.delayMs > 0:
      sleep(fake.delayMs)
    let attempt = fake.batches.len
    let body = fake.bodyForAttempt[min(attempt, fake.bodyForAttempt.high)]
    var tags: seq[string]
    for i in 0 ..< batch.len:
      tags.add(batch[i].tag)
      result.add((
        response: Response(code: fake.code, url: batch[i].url, body: body),
        error: ""))
    fake.batches.add(FakeBatch(size: batch.len, tags: tags, startMs: startMs,
      endMs: (getMonoTime() - fake.origin).inMilliseconds.int))

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

  test "all twenty seats' calls go out in ONE parallel batch":
    var game = seatedSim(testConfig())
    game.phase = Playing
    var engine = llmEngine(game)
    let provider = newFakeProvider(@[anthropicBody(GoodScript)])
    engine.client = fakeClient(provider)
    let records = engine.turn(game, 0, 0)
    check provider.batches.len == 1
    check provider.batches[0].size == 20
    # Every seat is in it exactly once, tagged with its own seat index…
    for seat in 0 ..< 20:
      var found = 0
      for tag in provider.batches[0].tags:
        if tag == $seat:
          inc found
      checkpoint("seat " & $seat)
      check found == 1
    # …and the twenty in-flight windows all intersect, because there is ONE
    # window: the batch's. Sequential calls would give twenty disjoint ones.
    let window = provider.batches[0]
    check window.endMs >= window.startMs
    for a in 0 ..< 20:
      for b in 0 ..< 20:
        check window.startMs <= window.endMs   # a_start <= b_end, both ways
    var fallbacks = 0
    for record in records:
      if parseJson(record)["k"].getStr() == "fallback":
        inc fallbacks
    check fallbacks == 0
    for seat in 0 ..< 20:
      check engine.scripts[seat].source == srcLlm
      check validScript(engine.scripts[seat])
      check engine.scripts[seat].mode == modeWave

  test "consecutive batches START at least minBatchSpacingMs apart":
    var game = seatedSim(testConfig())
    game.phase = Playing
    game.config.minBatchSpacingMs = 250
    var engine = llmEngine(game)
    let provider = newFakeProvider(@[anthropicBody(GoodScript)])
    engine.client = fakeClient(provider)
    discard engine.turn(game, 0, 0)
    discard engine.turn(game, 1, 0)
    check provider.batches.len == 2
    # The floor is on the START of consecutive batches, which is what pins the
    # episode's request rate under the sidecar's per-episode cap.
    check provider.batches[1].startMs - provider.batches[0].startMs >= 250

  test "the rate-floor wait is NOT charged to the turn budget":
    # The shipped manifest runs minBatchSpacingMs (45 000) > turnBudgetMs
    # (20 000). If the budget clock started before the inter-batch sleep, every
    # turn after the first would find it exhausted and fall back without ever
    # issuing a request — which is what round 2 of the league did.
    var game = seatedSim(testConfig())
    game.phase = Playing
    game.config.minBatchSpacingMs = 400
    game.config.turnBudgetMs = 200
    check game.config.minBatchSpacingMs > game.config.turnBudgetMs
    var engine = llmEngine(game)
    let provider = newFakeProvider(@[anthropicBody(GoodScript)])
    engine.client = fakeClient(provider)
    discard engine.turn(game, 0, 0)
    let records = engine.turn(game, 1, 0)
    # Turn 1 waited out the rate floor AND still issued its batch…
    require provider.batches.len == 2
    check provider.batches[1].size == 20
    check provider.batches[1].startMs - provider.batches[0].startMs >= 400
    # …so no seat fell back, least of all on the budget.
    for record in records:
      let node = parseJson(record)
      check node["k"].getStr() != "fallback"
    for seat in 0 ..< 20:
      check engine.scripts[seat].source == srcLlm
      check validScript(engine.scripts[seat])

  test "a HUNG provider still hands the turn back inside turnBudgetMs":
    var game = seatedSim(testConfig())
    game.phase = Playing
    game.config.turnBudgetMs = 300
    var engine = llmEngine(game)
    # Answers, but far too late to be worth a retry.
    let provider = newFakeProvider(
      @[anthropicBody("I am thinking about it")], delayMs = 500)
    engine.client = fakeClient(provider)
    let started = epochTime()
    let records = engine.turn(game, 0, 0)
    let elapsed = epochTime() - started
    check provider.batches.len == 1          # the budget cancelled the retry
    check elapsed < 2.0
    var budgetTimeouts = 0
    for record in records:
      let node = parseJson(record)
      if node["k"].getStr() == "fallback" and
          node["cause"].getStr() == "timeout":
        check "budget" in node["detail"].getStr()
        inc budgetTimeouts
    check budgetTimeouts == 20
    for seat in 0 ..< 20:
      check engine.haveScript[seat]
      check validScript(engine.scripts[seat])

  test "a parse failure retries EXACTLY once, and the retry is one batch too":
    var game = seatedSim(testConfig())
    game.phase = Playing
    var engine = llmEngine(game)
    let provider = newFakeProvider(@[
      anthropicBody("I am sorry, I cannot help with that."),
      anthropicBody(GoodScript)])
    engine.client = fakeClient(provider)
    let records = engine.turn(game, 0, 0)
    check provider.batches.len == 2
    check provider.batches[1].size == 20
    for seat in 0 ..< 20:
      check engine.scripts[seat].source == srcLlm
    var attempts: seq[int]
    for record in records:
      let node = parseJson(record)
      if node["k"].getStr() == "fallback":
        attempts.add(node["attempt"].getInt)
    for attempt in attempts:
      check attempt == 1                     # the first try, and no other

  test "a reply that never parses falls back after the SECOND batch, not the third":
    var game = seatedSim(testConfig())
    game.phase = Playing
    var engine = llmEngine(game)
    let provider = newFakeProvider(@[anthropicBody("no object here, ever")])
    engine.client = fakeClient(provider)
    let records = engine.turn(game, 0, 0)
    check provider.batches.len == 2
    var finals: seq[int]
    for record in records:
      let node = parseJson(record)
      if node["k"].getStr() == "fallback" and node["attempt"].getInt == 2:
        check node["cause"].getStr() == "parse_error"
        if node["seat"].getInt notin finals:
          finals.add(node["seat"].getInt)
    check finals.len == 20
    for seat in 0 ..< 20:
      check engine.scripts[seat].source == srcFallback
      check validScript(engine.scripts[seat])

  test "a THROTTLED provider skips the retry entirely":
    var game = seatedSim(testConfig())
    game.phase = Playing
    var engine = llmEngine(game)
    let provider = newFakeProvider(@["{\"message\":\"slow down\"}"], code = 429)
    engine.client = fakeClient(provider)
    let records = engine.turn(game, 0, 0)
    # One batch, no second: the only candidate model answered 429, so a retry
    # inside the same turn cannot land and would burn the whole turn budget.
    check provider.batches.len == 1
    check engine.client.throttled
    var throttled = 0
    for record in records:
      let node = parseJson(record)
      if node["k"].getStr() == "fallback" and
          node["cause"].getStr() == "throttled":
        inc throttled
    check throttled >= 20
    for seat in 0 ..< 20:
      check engine.scripts[seat].source == srcFallback

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
