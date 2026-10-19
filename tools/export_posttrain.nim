## Stream complete private candidate matches; shared review owns training admission.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT MATCHES [FIRST_SEED] [VARIANT] [PROMPT_VARIANT] [PROMPT_SEED]

import std/[json, os, osproc, strutils]
import pistonball/[sim, scripts, baselines, decide, llm, prompts, evidence, roster]

const OperatorPrompt = "Coordinate the bank using only your own piston's window."

proc main() =
  let args = commandLineParams()
  if args.len notin 2 .. 6:
    quit("usage: export_posttrain OUTPUT MATCHES [FIRST_SEED] [VARIANT] [PROMPT_VARIANT] [PROMPT_SEED]", 1)
  let output = args[0]
  let matches = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: "default"
  var promptConfig = newJObject()
  if args.len >= 5: promptConfig["promptVariant"] = %args[4]
  if args.len == 6: promptConfig["promptSeed"] = %parseInt(args[5])
  let selection = promptSelection(promptConfig)
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    quit("held-out wording cannot enter training sources", 1)
  if matches < 10 or firstSeed < 1:
    quit("at least ten matches and a positive first seed are required", 1)
  if variant notin ["default", "sprint"]:
    quit("variant must be default or sprint", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit qualified source before exporting private candidates"
  let head = execCmdEx("git rev-parse HEAD")
  doAssert head.exitCode == 0
  let sourceRevision = head.output.strip()
  writePrivate(output / "trajectories.jsonl", "")
  let stream = open(output / "trajectories.jsonl", fmAppend)
  defer: stream.close()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var runs = newJArray()
  for seed in firstSeed ..< firstSeed + matches:
    let family = "pistonball-" & $seed
    let episode = family & "-" & variant & "-" & $selection.selectedVariant & "-" & $selection.seed
    var config = defaultGameConfig()
    config.update($variantConfig)
    config.seed = seed
    var sim = initSimServer(config)
    for seat in 0 ..< PistonCount:
      discard sim.addPlayer("policy-" & $seat, seat, "", trusted = true)
    let idle = newSeq[uint8](PistonCount)
    while sim.phase != Playing: sim.step(idle)
    var
      engine = initDecisionEngine(sim, selection)
      decisions = 0
      pending = newJArray()
      lastTurn = -1
    while sim.phase != GameOver:
      engine.observe(sim)
      let turn = sim.gameTicksElapsed() div config.turnTicks
      if turn != lastTurn:
        lastTurn = turn
        sim.lastTurnRewardMilli =
          (sim.progressMilli - sim.turnStartProgressMilli) -
          (sim.penaltyMilli - sim.turnStartPenaltyMilli)
        sim.turnStartProgressMilli = sim.progressMilli
        sim.turnStartPenaltyMilli = sim.penaltyMilli
        for record in pending: stream.writeLine($record)
        pending = newJArray()
        for seat in 0 ..< PistonCount:
          let view = engine.windowView(sim, seat, turn)
          let teacher = wavebotScript(sim, sim.pistonOfSeat(seat))
          let completion = teacher.scriptAction()
          let parsed = parsePistonScript(extractJsonObject($completion),
            engine.scripts[seat], engine.haveScript[seat])
          let executed = parsed.scriptAction()
          doAssert completion == executed
          let system = systemPrompt(selection)
          let user = userMessage(OperatorPrompt, $view)
          let messages = %*[{"role": "system", "content": system},
            {"role": "user", "content": user}]
          var observation = copy(view)
          observation["prompt_template"] = selection.promptMetadata(system, user)
          let attemptId = $decisions & "-teacher"
          pending.add(%*{
            "schema_version": "1", "event_type": "decision", "episode_id": episode,
            "decision_id": $(turn * PistonCount + seat), "decision_index": decisions,
            "game": "pistonball", "game_version": "source-" & sourceRevision,
            "source_revision": sourceRevision, "seat": $seat, "visibility": "private",
            "observation": observation, "prompt": messages,
            "attempts": [{"attempt_id": attemptId, "policy": "scripted-wavebot",
              "origin": "teacher", "inference_mode": "text_action", "prompt": messages,
              "response": $completion, "parsed_action": completion, "accepted": true,
              "request": newJNull(), "platform_call_id": newJNull(),
              "behavior_logprobs": newJNull(), "rejection_reason": newJNull()}],
            "selected_attempt_id": attemptId, "executed_action": executed,
            "action_status": "accepted", "fallback_origin": newJNull(), "terminal": false
          })
          inc decisions
          engine.scripts[seat] = parsed
          engine.haveScript[seat] = true
        engine.closeTurn()
      var commands = newSeq[uint8](PistonCount)
      for piston in 0 ..< PistonCount:
        commands[sim.seatOfPiston(piston)] = engine.commandFor(sim, piston)
      sim.step(commands)
    doAssert decisions > 0
    let outcome = parseJson(sim.playerResultsJson())
    doAssert outcome["reason"].getStr() == ReasonComplete
    for record in pending:
      record["terminal"] = %true
      stream.writeLine($record)
    var participants = newJObject()
    for seat in 0 ..< PistonCount:
      participants[$seat] = %*{"score": outcome["scores"][seat]}
    stream.writeLine($(%*{
      "schema_version": "1", "event_type": "episode", "episode_id": episode,
      "seed_family": family, "game": "pistonball", "game_version": "source-" & sourceRevision,
      "source_revision": sourceRevision, "status": "completed",
      "outcome": outcome, "participant_outcomes": participants
    }))
    runs.add(%*{"seed": seed, "decisions": decisions,
      "score": float(sim.scoreMilli()) / 1000.0, "win": sim.delivered()})
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "pistonball",
    "variant": variant,
    "source_revision": sourceRevision,
    "prompt_configuration": selection.selectionMetadata(),
    "teacher": "scripted-wavebot",
    "operator_prompt": OperatorPrompt,
    "split_authority": "shared Coworld SDK and application importer by seed_family",
    "runs": runs
  }) & "\n")
  echo "complete private games=", matches

when isMainModule:
  main()
