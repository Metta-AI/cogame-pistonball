## Export complete Pistonball episodes as canonical private trajectories.
## Usage: export_posttrain OUTPUT EPISODES FIRST_SEED VARIANT GAME_VERSION

import std/[base64, json, options, os, osproc, strutils]
import bitworld/decision_trajectory
import pistonball/[sim, scripts, baselines, decide, llm, roster, training_capture]

proc flushMacros(trajectory: DecisionTrajectory, macros: var seq[StagedMacro],
    endTick: int, terminal: bool) =
  for issued in macros.mitems: issued.endTick = endTick
  trajectory.recordMacros(macros, terminal)
  macros.setLen(0)

const OperatorPrompt = "Coordinate the bank using only your own piston's window."

when isMainModule:
  let args = commandLineParams()
  if args.len != 5:
    quit("usage: export_posttrain OUTPUT EPISODES FIRST_SEED VARIANT GAME_VERSION", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let firstSeed = parseInt(args[2])
  let variant = args[3]
  let gameVersion = args[4]
  doAssert gameVersion.len > 0
  if episodes < 10 or firstSeed < 1:
    quit("at least ten episodes and a positive first seed are required", 1)
  if variant notin ["default", "sprint"]:
    quit("variant must be default or sprint", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  setFilePermissions(output, {fpUserRead, fpUserWrite, fpUserExec})
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var trajectoryRows: seq[string]
  var runs = newJArray()
  for seed in firstSeed ..< firstSeed + episodes:
    var config = defaultGameConfig()
    config.update($variantConfig)
    config.seed = seed
    var sim = initSimServer(config)
    for seat in 0 ..< PistonCount:
      discard sim.addPlayer("policy-" & $seat, seat, "", trusted = true)
    let idle = newSeq[uint8](PistonCount)
    while sim.phase != Playing:
      sim.step(idle)
    let startTick = sim.tickCount
    let trajectory = newDecisionTrajectory("pistonball-" & variant & "-" & $seed,
      "pistonball-" & $seed, "pistonball", gameVersion, sourceRevision)
    var engine = initDecisionEngine(sim)
    var pending: seq[StagedMacro]
    var lastTurn = -1
    var decisions = 0
    var controls = ""
    var hashes = newJArray()
    hashes.add(%($sim.gameHash()))
    while sim.phase != GameOver:
      engine.observe(sim)
      let turn = sim.gameTicksElapsed() div config.turnTicks
      if turn != lastTurn:
        trajectory.flushMacros(pending, sim.tickCount, false)
        lastTurn = turn
        sim.lastTurnRewardMilli =
          (sim.progressMilli - sim.turnStartProgressMilli) -
          (sim.penaltyMilli - sim.turnStartPenaltyMilli)
        sim.turnStartProgressMilli = sim.progressMilli
        sim.turnStartPenaltyMilli = sim.penaltyMilli
        for seat in 0 ..< PistonCount:
          let view = engine.windowView(sim, seat, turn)
          let teacher = wavebotScript(view)
          let completion = appliedScriptAction(teacher)
          let parsed = parsePistonScript(completion, engine.scripts[seat],
            engine.haveScript[seat])
          doAssert scriptJson(parsed) == scriptJson(teacher)
          doAssert parsed.note == teacher.note and parsed.say == teacher.say
          let decisionId = $turn & "-" & $seat
          var attempt = newDecisionAttempt(decisionId & "-teacher",
            PrivateViewTeacher, aoTeacher)
          attempt.prompt = %*[
            {"role": "system", "content": SystemPrompt},
            {"role": "user", "content": userMessage(OperatorPrompt, $view)}]
          attempt.response = %($completion)
          attempt.parsedAction = completion
          attempt.accepted = true
          engine.scripts[seat] = parsed
          engine.haveScript[seat] = true
          pending.add(StagedMacro(decisionId: decisionId, seat: seat, turn: turn,
            startTick: sim.tickCount, observation: view, action: completion,
            attempts: @[attempt], selected: some(attempt.attemptId), status: asAccepted))
          inc decisions
        engine.closeTurn()
      var commands = newSeq[uint8](PistonCount)
      for piston in 0 ..< PistonCount:
        commands[sim.seatOfPiston(piston)] = engine.commandFor(sim, piston)
      for command in commands:
        controls.add(char(command))
      for issued in pending.mitems:
        issued.controls.add(char(commands[issued.seat]))
      sim.step(commands)
      hashes.add(%($sim.gameHash()))
    trajectory.flushMacros(pending, sim.tickCount, true)
    doAssert decisions > 0
    doAssert controls.len == (sim.tickCount - startTick) * PistonCount
    let outcome = parseJson(sim.playerResultsJson())
    outcome["engine_version"] = %GameVersion
    outcome["execution"] = %*{
      "start_tick": startTick, "end_tick": sim.tickCount,
      "tick_hz": TargetFps, "seat_count": PistonCount,
      "control_encoding": "u8-tick-major-seat-order",
      "controls_b64": encode(controls), "state_hashes": hashes}
    var participants = newJObject()
    for seat in 0 ..< PistonCount:
      participants[$seat] = outcome["scores"][seat]
    trajectory.finish(esCompleted, outcome, participants)
    trajectoryRows.add(trajectory.eventsJsonl().strip())
    runs.add(%*{"seed": seed, "decisions": decisions,
      "start_tick": startTick, "end_tick": sim.tickCount,
      "control_bytes": controls.len, "score": outcome["sharedScore"],
      "delivered": outcome["delivered"]})
  writePrivate(output / "trajectories.jsonl", trajectoryRows.join("\n") & "\n")
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "pistonball", "variant": variant,
    "source_revision": sourceRevision, "game_version": gameVersion,
    "teacher": PrivateViewTeacher, "operator_prompt": OperatorPrompt,
    "complete_episodes": episodes, "runs": runs}) & "\n")
  echo "complete_episodes=", episodes
