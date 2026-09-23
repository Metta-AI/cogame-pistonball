## Persistent JSONL bridge for Metta RL and native PufferLib.
## nim c -d:release --path:src -o:pistonball-train-bridge tools/train_bridge.nim

import std/[json, os]
import pistonball/[sim, scripts, baselines, decide, llm]

const
  OperatorPrompt = "Coordinate the bank using only your own piston's window."
  Variants = ["default", "sprint"]
  Modes = ["wave", "lift", "drop", "hold", "catch", "ripple"]
  Blinds = ["hold", "idle", "ripple"]
  Fields = ["mode", "trigger_cm", "lead_ticks", "up_cm", "down_cm",
    "idle_cm", "speed255", "blind"]

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32) + 1

proc heads(): JsonNode =
  result = newJArray()
  for name in Fields:
    var choices = newJArray()
    case name
    of "mode":
      for value in Modes: choices.add(%value)
    of "blind":
      for value in Blinds: choices.add(%value)
    else:
      let high = case name
        of "trigger_cm": 100
        of "lead_ticks": 24
        of "speed255": 255
        else: 160
      for value in 0 .. high: choices.add(%value)
    result.add(%*{"name": name, "choices": choices})

proc number(node: JsonNode): float =
  case node.kind
  of JInt: node.getInt().float
  of JFloat: node.getFloat()
  else: raise newException(ValueError, "expected numeric observation")

proc values(view: JsonNode, variant: string): JsonNode =
  result = newJArray()
  for name in Variants: result.add(%(if variant == name: 1 else: 0))
  for field in ["turn", "of"]: result.add(%view[field].number())
  for field in ["tick", "of", "left_s"]:
    result.add(%view["clock"][field].number())
  let me = view["you"]
  for field in ["piston", "x_m", "height_m", "velocity_m_s", "stroke_m",
      "max_speed_m_s", "width_m"]:
    result.add(%me[field].number())
  let window = view["window"]
  result.add(%window["half_width_m"].number())
  let heights = window["neighbour_heights_m"]
  for offset in -2 .. 2:
    let key = $(me["piston"].getInt() + offset)
    result.add(%(if heights.hasKey(key): heights[key].number() else: 0.0))
  let ball = window["ball"]
  result.add(%(if ball.kind == JNull: 0 else: 1))
  for field in ["dx_m", "height_m", "vx_m_s", "vy_m_s", "spin_deg_s"]:
    result.add(%(if ball.kind == JNull: 0.0 else: ball[field].number()))
  result.add(%(if ball.kind != JNull and ball["on_me"].getBool(): 1 else: 0))
  result.add(%view["sightings_count"].number())
  let sightings = view["sightings"]
  doAssert sightings.len <= 4
  for index in 0 ..< 4:
    if index < sightings.len:
      for field in ["tick", "dx_m", "height_m", "vx_m_s", "vy_m_s"]:
        result.add(%sightings[index][field].number())
    else:
      for _ in 0 ..< 5: result.add(%0)
  result.add(%view["shared_reward"]["last_turn"].number())
  result.add(%view["goal"]["your_distance_to_goal_m"].number())
  let last = view["your_last_script"]
  result.add(%(if last.kind == JNull: 0 else: 1))
  if last.kind == JNull:
    for _ in 0 ..< 15: result.add(%0)
  else:
    for name in Modes:
      result.add(%(if last["mode"].getStr() == name: 1 else: 0))
    for field in ["trigger_m", "lead_ticks", "up_m", "down_m", "idle_m",
        "speed"]:
      result.add(%last[field].number())
    for name in Blinds:
      result.add(%(if last["blind"].getStr() == name: 1 else: 0))

proc action(script: PistonScript): JsonNode =
  %*{"mode": $script.mode, "trigger_cm": int(script.triggerUm) div 10_000,
    "lead_ticks": script.leadTicks, "up_cm": int(script.upUm) div 10_000,
    "down_cm": int(script.downUm) div 10_000,
    "idle_cm": int(script.idleUm) div 10_000,
    "speed255": script.speed255, "blind": $script.blind}

proc hostedScript(candidate: JsonNode): JsonNode =
  %*{"mode": candidate["mode"],
    "trigger_m": candidate["trigger_cm"].getInt().float / 100.0,
    "lead_ticks": candidate["lead_ticks"],
    "up_m": candidate["up_cm"].getInt().float / 100.0,
    "down_m": candidate["down_cm"].getInt().float / 100.0,
    "idle_m": candidate["idle_cm"].getInt().float / 100.0,
    "speed": candidate["speed255"].getInt().float / 255.0,
    "blind": candidate["blind"]}

proc decision(view: JsonNode, seat, id: int): JsonNode =
  var properties = newJObject()
  var required = newJArray()
  for head in heads():
    let name = head["name"].getStr()
    properties[name] = %*{"enum": head["choices"]}
    required.add(%name)
  %*{"kind": "decision", "game": "pistonball", "decision_id": id,
    "seat": seat, "engine_seat": seat, "turn": view["turn"],
    "semantic_view": view, "inbox": [],
    "messages": [{"role": "system", "content": SystemPrompt},
      {"role": "user", "content": userMessage(OperatorPrompt, $view)}],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": properties,
      "required": required}, "typed_question": newJNull()}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2: quit("usage: pistonball-train-bridge MANIFEST VARIANT", 1)
  let variant = args[1]
  doAssert variant in Variants
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant: variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var game: SimServer
  var engine: DecisionEngine
  var views: array[PistonCount, JsonNode]
  var seat = 0
  var turn = 0
  var id = 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == PistonCount
      var config = defaultGameConfig()
      config.update($variantConfig)
      config.seed = seedOf(request["seed"].getStr())
      game = initSimServer(config)
      for actor in 0 ..< PistonCount:
        discard game.addPlayer("policy-" & $actor, actor, "", trusted = true)
      let idle = newSeq[uint8](PistonCount)
      while game.phase != Playing: game.step(idle)
      engine = DecisionEngine(
        seats: newSeq[SeatPolicy](PistonCount),
        scripts: newSeq[PistonScript](PistonCount),
        haveScript: newSeq[bool](PistonCount),
        sightings: newSeq[seq[Sighting]](PistonCount),
        sightingCounts: newSeq[int](PistonCount),
        params: DefaultBaselineParams)
      for actor in 0 ..< PistonCount:
        engine.scripts[actor] = defaultScript()
      engine.observe(game)
      turn = 0
      for actor in 0 ..< PistonCount:
        views[actor] = engine.windowView(game, actor, turn)
      seat = 0
      id = 0
      response = views[seat].decision(seat, id)
    of "encode":
      doAssert game.phase != GameOver
      response = %*{"decision_id": id,
        "values": views[seat].values(variant), "action_heads": heads()}
    of "teacher":
      doAssert game.phase != GameOver
      response = %*{"response": $action(wavebotScript(game,
        game.pistonOfSeat(seat)))}
    of "step":
      doAssert game.phase != GameOver and request["decision_id"].getInt() == id
      let candidate = parseJson(request["response"].getStr())
      for head in heads():
        doAssert candidate[head["name"].getStr()] in head["choices"]
      engine.scripts[seat] = parsePistonScript(candidate.hostedScript(),
        engine.scripts[seat], engine.haveScript[seat])
      engine.haveScript[seat] = true
      inc id
      inc seat
      var observation: JsonNode
      if seat < PistonCount:
        observation = views[seat].decision(seat, id)
      else:
        engine.closeTurn()
        while game.phase != GameOver:
          var commands = newSeq[uint8](PistonCount)
          for piston in 0 ..< PistonCount:
            commands[game.seatOfPiston(piston)] = engine.commandFor(game, piston)
          game.step(commands)
          engine.observe(game)
          let nextTurn = game.gameTicksElapsed() div game.config.turnTicks
          if game.phase == Playing and nextTurn != turn:
            turn = nextTurn
            game.lastTurnRewardMilli =
              (game.progressMilli - game.turnStartProgressMilli) -
              (game.penaltyMilli - game.turnStartPenaltyMilli)
            game.turnStartProgressMilli = game.progressMilli
            game.turnStartPenaltyMilli = game.penaltyMilli
            break
        if game.phase == GameOver:
          let score = float(game.scoreMilli()) / 1000.0
          var scores = newJObject()
          var utilities = newJObject()
          for actor in 0 ..< PistonCount:
            scores[$actor] = %score
            utilities[$actor] = %clamp(score / 100.0, -1.0, 1.0)
          observation = %*{"kind": "terminal", "scores": scores,
            "utilities": utilities}
        else:
          seat = 0
          for actor in 0 ..< PistonCount:
            views[actor] = engine.windowView(game, actor, turn)
          observation = views[seat].decision(seat, id)
      response = %*{"kind": "accepted", "action": candidate,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
