## An END-TO-END episode that writes a replay, and the replay that reads it
## back: the recorded command bytes must reproduce EVERY recorded hash.

import
  std/[json, os, osproc, strutils, tables, unicode, unittest],
  ../src/pistonball/[sim, scripts, control, baselines, decide, events, replays,
                     roster, broadcast],
  ./helpers

proc recordEpisode(path: string, seed = 4417231, maxTicks = 900): SimServer =
  ## A full twenty-seat scripted episode, written through the SAME writer the
  ## server uses, with a non-ASCII `say` and a non-ASCII policy label so the
  ## UTF-8 path is real rather than nominal.
  var config = testConfig(seed, maxTicks)
  var game = initSimServer(config)
  game.collectEvents = true            # what the server does with an events path
  var writer = openReplayWriter(
    path, config.configJson(game.perm, game.restHeights))
  writer.lastMasks = newSeq[uint8](game.seatCount())
  for i in 0 ..< writer.lastMasks.len:
    writer.lastMasks[i] = 127'u8
  for seat in 0 ..< PistonCount:
    let name = if seat == 0: "d\u00e4vey-\u00fc" else: "policy-" & $seat
    discard game.addPlayer(name, seat, "", trusted = true)
    writer.writeJoin(tickTime(game.tickCount), seat, name, seat, "")
    writer.writeChat(tickTime(game.tickCount), seat, registerRecord(
      seat, game.pistonOfSeat(seat), alias(max(0, game.pistonOfSeat(seat))),
      "b\u00e4seline", "scripted", "wavebot"))
  var turn = 0
  var guard = 0
  while game.phase != GameOver and guard < maxTicks + 16:
    inc guard
    if game.phase == Playing and
        game.gameTicksElapsed() div config.turnTicks != turn - 1:
      for seat in 0 ..< PistonCount:
        let piston = max(0, game.pistonOfSeat(seat))
        var script = wavebotScript(game, piston)
        script.say = "up behind it \u2014 \u00fcber"
        # Seat 0 plays the LLM and seat 1 falls back, so the recorded stream
        # carries all three `source` values a real episode can produce.
        script.source =
          if seat == 0: srcLlm
          elif seat == 1: srcFallback
          else: srcScripted
        let record = boundedScriptRecord(
          script, turn, seat, piston, alias(piston))
        writer.writeChat(tickTime(game.tickCount), seat, record)
        game.pushFeedScript(record)
        game.holdSay(piston, script.say, game.tickCount + 60)
      inc turn
    let commands = scriptedCommands(game, [blWavebot])
    for seat in 0 ..< commands.len:
      writer.writeInputMaskChange(tickTime(game.tickCount), seat, commands[seat])
    game.step(commands)
    writer.writeHash(uint32(game.tickCount), game.gameHash())
  writer.writeChat(tickTime(game.tickCount), 0, resultRecord(game))
  writer.closeReplayWriter()
  game

suite "the replay":
  test "a recorded episode re-simulates to every recorded hash":
    let path = getTempDir() / "pistonball-test.replay"
    let live = recordEpisode(path)
    check fileExists(path)
    check getFileSize(path) > 0
    let data = parseReplayBytes(readFile(path))
    check data.gameName == GameName
    check data.gameVersion == GameVersion
    check data.hashes.len > 0
    check data.inputs.len > 0

    var runtime = initReplayPlayer(data)
    runtime.mismatchQuit = true
    var config = defaultGameConfig()
    config.update(data.configJson)
    var replaySim = initSimServer(config)
    while replaySim.tickCount < runtime.replayMaxTick() and
        runtime.hashIndex < data.hashes.len:
      runtime.stepReplay(replaySim)
    check not runtime.hashValidationFailed
    check runtime.hashMismatchTick == -1
    check runtime.hashIndex == data.hashes.len
    check replaySim.gameHash() == live.gameHash()
    check replaySim.ballX == live.ballX

  test "the embedded config decodes strictly and carries the whole table":
    let path = getTempDir() / "pistonball-test.replay"
    discard recordEpisode(path)
    let data = parseReplayBytes(readFile(path))
    let config = parseJson(data.configJson)
    check config["seed"].getInt == 4417231
    check config["perm"].len == PistonCount
    check config["restHeightsUm"].len == PistonCount
    check config["geometry"]["pistonCount"].getInt == PistonCount
    check config["geometry"]["strokeUm"].getInt == int(Stroke)
    check config["geometry"]["goalXUm"].getInt == int(GoalX)
    check config["protocol"].getStr() == "pistonball/v1"
    check config["players"].len == PistonCount

  test "the record stream carries the whole vocabulary, once each":
    let path = getTempDir() / "pistonball-test.replay"
    let live = recordEpisode(path)
    let data = parseReplayBytes(readFile(path))
    var registers = 0
    var scriptsPerTurn = initCountTable[int]()
    var results = 0
    for chat in data.chats:
      if chat.message.len == 0 or chat.message[0] != '{':
        continue
      let node = parseJson(chat.message)
      case node["k"].getStr()
      of "register": inc registers
      of "script":
        check chat.message.runeLen <= MaxScriptRecordRunes
        scriptsPerTurn.inc(node["turn"].getInt)
      of "result": inc results
      else: discard
    check registers == PistonCount
    check results == 1
    check scriptsPerTurn.len >= 1
    for _, count in scriptsPerTurn:
      check count == PistonCount
    check live.endReason in [ReasonComplete, ReasonDeadline]
    check live.endRule in [EndRuleDelivered, EndRuleOutOfTime,
                           EndRuleWallClock]
    # The tier-2 stream carries the two events a real wave must produce: the
    # ball is HANDED OFF from column to column, and a rising head LAUNCHES it.
    # An episode with neither is one where nothing touched the ball.
    var kinds = initCountTable[string]()
    for event in live.events:
      kinds.inc(event.kind.key())
      check event.tick >= 0
      check event.tick <= live.tickCount
    checkpoint($kinds)
    check kinds["handoff"] >= 1
    check kinds["launch"] >= 1

  test "the endcard's per-seat llm/fallback counts survive the replay":
    # The live server tallies these as it decides; a replay has only the
    # records. Without the recount the endcard's LLM/FB column reads 0/0 for
    # every seat, including the LLM ones.
    let path = getTempDir() / "pistonball-test.replay"
    discard recordEpisode(path)
    let data = parseReplayBytes(readFile(path))
    var turnsPerSeat = 0
    for chat in data.chats:
      if chat.message.len > 0 and chat.message[0] == '{':
        let node = parseJson(chat.message)
        if node["k"].getStr() == "script" and node["seat"].getInt == 0:
          inc turnsPerSeat
    check turnsPerSeat >= 1

    var runtime = initReplayPlayer(data)
    runtime.mismatchQuit = true
    var config = defaultGameConfig()
    config.update(data.configJson)
    var replaySim = initSimServer(config)
    while replaySim.tickCount < runtime.replayMaxTick() and
        runtime.hashIndex < data.hashes.len:
      runtime.stepReplay(replaySim)
    check replaySim.llmTurns[0] == turnsPerSeat
    check replaySim.fallbackTurns[0] == 0
    check replaySim.fallbackTurns[1] == turnsPerSeat
    check replaySim.llmTurns[1] == 0
    check replaySim.llmTurns[2] == 0        # a scripted seat counts as neither
    check replaySim.fallbackTurns[2] == 0

    # …and they reach the endcard, which reads them off the state frame.
    let roster = parseJson(replaySim.buildStateJson(
      newJArray(), false, 1, runtime.replayMaxTick(), false, true, -1, -1))
    check roster["roster"][0]["llm"].getInt == turnsPerSeat
    check roster["roster"][0]["fb"].getInt == 0
    check roster["roster"][1]["fb"].getInt == turnsPerSeat

    # A seek rewinds the counters with the chat cursor: landing on the last
    # tick from a keyframe must not double-count the turns it replayed.
    var seeker = initReplayPlayer(data)
    var seekSim = initSimServer(config)
    seeker.buildReplayKeyframes(seekSim)
    seeker.seekReplay(seekSim, seeker.replayMaxTick())
    check seekSim.llmTurns[0] == turnsPerSeat
    check seekSim.fallbackTurns[1] == turnsPerSeat

  test "1/2x is a replay-only crawl the chrome can see":
    # The fleet-wide half speed: command '5' selects ReplayHalfSpeedIndex, the
    # chrome's `sp` reads 0.5, and the step budget spends one tick every OTHER
    # frame. `replaySpeed` stays an integer 1 so the LIVE loop, which indexes
    # PlaybackSpeeds, can never be dragged below real time.
    var replay = ReplayPlayer()
    replay.speedIndex = 0
    applySpeedCommand(replay.speedIndex, '5')
    check replay.speedIndex == ReplayHalfSpeedIndex
    check replay.replayDisplaySpeed() == 0.5
    check replay.replaySpeed() == 1

    replay.skipLulls = false
    replay.halfPhase = false
    check replay.replayStepBudget(0) == 0      # even frame: nothing spent
    replay.halfPhase = true
    check replay.replayStepBudget(0) == 1      # odd frame: one tick

    # 1/2x is the FLOOR of the '-' ramp, and '+' climbs straight back to 1x.
    applySpeedCommand(replay.speedIndex, '+')
    check replay.speedIndex == 0
    applySpeedCommand(replay.speedIndex, '-')
    check replay.speedIndex == ReplayHalfSpeedIndex
    applySpeedCommand(replay.speedIndex, '-')
    check replay.speedIndex == ReplayHalfSpeedIndex

    # Every other speed still reports its own integer, so the chip the chrome
    # lights up is the one the engine is actually running.
    for (command, want) in [('1', 1.0), ('2', 2.0), ('3', 3.0), ('4', 4.0),
                            ('8', 8.0), ('6', 16.0)]:
      checkpoint($command)
      applySpeedCommand(replay.speedIndex, command)
      check replay.replayDisplaySpeed() == want

  test "the half-speed parity counts frames, and '5' rides the command path":
    # applyReplayCommand is what the viewer's keystrokes and speed chips reach,
    # so '5' has to be in ITS dispatch set too — not just applySpeedCommand's.
    var config = testConfig()
    var sim = initSimServer(config)
    var replay = ReplayPlayer()
    replay.speedIndex = 3
    replay.applyReplayCommand(sim, '5')
    check replay.speedIndex == ReplayHalfSpeedIndex

    # The parity flips once per advanceReplayPlayback frame, whatever else the
    # frame did, so half speed is exactly half of real time.
    replay.playing = false
    let before = replay.halfPhase
    replay.advanceReplayPlayback(sim, proc () = discard, proc () = discard)
    check replay.halfPhase != before
    replay.advanceReplayPlayback(sim, proc () = discard, proc () = discard)
    check replay.halfPhase == before

  test "tools/replay_summary.py parses under a STRICT UTF-8 JSON parser":
    let path = getTempDir() / "pistonball-test.replay"
    discard recordEpisode(path)
    let root = currentSourcePath().parentDir().parentDir()
    let script = root / "tools" / "replay_summary.py"
    let checker = getTempDir() / "pistonball-strict-check.py"
    writeFile(checker, """
import json, subprocess, sys
raw = subprocess.check_output([sys.executable, sys.argv[1], sys.argv[2]])
summary = json.loads(raw.decode("utf-8"))
assert summary["protocol"] == "pistonball/v1", summary["protocol"]
assert summary["gameName"] == "pistonball"
assert len(summary["pistons"]) == 20
assert summary["registers"] == 20
assert summary["tickCount"] > 0
assert summary["results"]["reason"] in ("complete", "deadline")
assert len(summary["results"]["scores"]) == 20
print("ok")
""")
    let outcome = execCmdEx(
      "python3 " & checker & " " & script & " " & path)
    checkpoint(outcome.output)
    check outcome.exitCode == 0
