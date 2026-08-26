## An END-TO-END episode that writes a replay, and the replay that reads it
## back: the recorded command bytes must reproduce EVERY recorded hash.

import
  std/[json, os, osproc, strutils, tables, unicode, unittest],
  ../src/pistonball/[sim, scripts, control, baselines, decide, events, replays,
                     roster],
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
