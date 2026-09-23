## Export complete Pistonball games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT EPISODES [FIRST_SEED] [default|sprint]

import std/[json, os, osproc, strutils]
import pistonball/[sim, scripts, baselines, decide, llm]

const OperatorPrompt = "Coordinate the bank using only your own piston's window."

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT EPISODES [FIRST_SEED] [default|sprint]", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: "default"
  if episodes < 10 or firstSeed < 1:
    quit("at least ten episodes and a positive first seed are required", 1)
  if variant notin ["default", "sprint"]:
    quit("variant must be default or sprint", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
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
    var
      engine = initDecisionEngine(sim)
      rows: seq[string]
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
        for seat in 0 ..< PistonCount:
          let piston = sim.pistonOfSeat(seat)
          let view = $engine.windowView(sim, seat, turn)
          let teacher = wavebotScript(sim, piston)
          var completion = scriptJson(teacher)
          completion["note"] = %teacher.note
          completion["say"] = %teacher.say
          let parsed = parsePistonScript(completion, engine.scripts[seat],
            engine.haveScript[seat])
          doAssert parsed.mode == teacher.mode
          doAssert parsed.triggerUm == teacher.triggerUm
          doAssert parsed.leadTicks == teacher.leadTicks
          doAssert parsed.upUm == teacher.upUm
          doAssert parsed.downUm == teacher.downUm
          doAssert parsed.idleUm == teacher.idleUm
          doAssert parsed.speed255 == teacher.speed255
          doAssert parsed.blind == teacher.blind
          rows.add($(%*{
            "episode_id": "pistonball-" & variant & "-" & $seed,
            "seed": "pistonball-" & variant & "-" & $seed,
            "decision_id": turn * PistonCount + seat,
            "prompt": [
              {"role": "system", "content": SystemPrompt},
              {"role": "user", "content": userMessage(OperatorPrompt, view)}
            ],
            "completion": [{"role": "assistant", "content": $completion}],
            "game": "pistonball",
            "action_schema_revision": "piston-script-v1"
          }))
          engine.scripts[seat] = parsed
          engine.haveScript[seat] = true
        engine.closeTurn()
      var commands = newSeq[uint8](PistonCount)
      for piston in 0 ..< PistonCount:
        commands[sim.seatOfPiston(piston)] = engine.commandFor(sim, piston)
      sim.step(commands)
    doAssert rows.len > 0
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "score": float(sim.scoreMilli()) / 1000.0, "win": sim.delivered()})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "pistonball",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-wavebot",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
