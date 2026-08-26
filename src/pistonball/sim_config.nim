## GameConfig lifecycle: defaults, the runtime JSON update, and the resolved
## config JSON that goes into the replay header.
##
## INTEGER ONLY (see `sim_types.nim`): every knob this file reads is an int, a
## bool or a string, so a config can never smuggle a non-integer into a hashed
## quantity.

import
  std/[json, strutils],
  ./sim_types, ./bank

proc defaultGameConfig*(): GameConfig =
  ## The shipped defaults. Every one of these is also declared in
  ## `coworld_manifest_template.json`'s `game.config_schema`; a field that is
  ## not in the schema is not settable, and `tests/test_manifest.nim` asserts
  ## the two lists agree.
  GameConfig(
    seed: 4417231,
    numAgents: PistonCount,
    minPlayers: PistonCount,
    maxTicks: 1800,
    maxGames: 1,
    turnTicks: 225,
    turnBudgetMs: 20000,
    attempt1Ms: 12000,
    retryMs: 6000,
    minBatchSpacingMs: 45000,
    wallClockBudgetSeconds: 660,
    lobbyJoinTimeoutTicks: 1800,
    startWaitTicks: 24,
    gameOverTicks: 72,
    speed: 1,
    fastMode: true,
    showPlayerLabels: false,
    closedRoster: false,
    model: "",
    maxOutputTokens: 900,
    windowHalfWidthUm: int(WindowHalfWidth),
    strokeUm: int(Stroke),
    maxPistonSpeedUm: int(MaxPistonSpeed),
    ballRadiusUm: int(BallRadius),
    ballMassGrams: int(BallMassGrams),
    stepPenaltyMilli: 10,
    slots: @[]
  )

proc readConfigInt(node: JsonNode, key: string, target: var int) =
  ## Reads one integer knob. A JSON string holding digits is accepted (hosted
  ## configs have shipped both); anything else is left alone.
  let value = node{key}
  if value.isNil:
    return
  case value.kind
  of JInt:
    target = int(value.getBiggestInt())
  of JString:
    try:
      target = parseInt(value.getStr().strip())
    except ValueError:
      discard
  else:
    discard

proc readConfigBool(node: JsonNode, key: string, target: var bool) =
  let value = node{key}
  if value.isNil:
    return
  case value.kind
  of JBool: target = value.getBool()
  of JInt: target = value.getBiggestInt() != 0
  else: discard

proc readConfigString(node: JsonNode, key: string, target: var string) =
  let value = node{key}
  if not value.isNil and value.kind == JString:
    target = value.getStr()

proc ensureSlots(config: var GameConfig, count: int) =
  while config.slots.len < count:
    config.slots.add(SlotConfig(alias: alias(config.slots.len)))
  for i in 0 ..< config.slots.len:
    if config.slots[i].alias.len == 0:
      config.slots[i].alias = alias(i)

proc validate(config: GameConfig) =
  ## Rejects a config that could not produce a legal episode. Raised before a
  ## single tick runs, so a bad variant fails fast with a readable message
  ## instead of half an episode of nonsense.
  if config.numAgents != PistonCount:
    raise newException(PistonballError,
      "num_agents must be " & $PistonCount & " (the bank is exactly " &
      $PistonCount & " pistons); got " & $config.numAgents)
  if config.turnTicks <= 0:
    raise newException(PistonballError, "turnTicks must be positive")
  if config.maxTicks <= 0:
    raise newException(PistonballError, "maxTicks must be positive")
  if config.maxTicks mod config.turnTicks != 0:
    raise newException(PistonballError,
      "maxTicks must be a whole number of turns")
  if config.attempt1Ms + config.retryMs > config.turnBudgetMs:
    raise newException(PistonballError,
      "attempt1Ms + retryMs must fit inside turnBudgetMs")
  if config.attempt1Ms < 1000 or config.retryMs < 1000:
    # curly hands the deadline to CURLOPT_TIMEOUT, whose granularity is WHOLE
    # SECONDS, so a sub-second value is not the deadline it claims to be.
    raise newException(PistonballError,
      "attempt1Ms and retryMs must be at least 1000 ms")
  if config.wallClockBudgetSeconds <= 0:
    raise newException(PistonballError,
      "wallClockBudgetSeconds must be positive")

proc update*(config: var GameConfig, jsonText: string) =
  ## Applies one runtime config JSON document.
  if jsonText.len == 0:
    config.ensureSlots(config.numAgents)
    config.validate()
    return
  var node: JsonNode
  try:
    node = parseJson(jsonText)
  except CatchableError as error:
    raise newException(PistonballError,
      "Could not parse config JSON: " & error.msg)
  if node.kind != JObject:
    raise newException(PistonballError, "Config must be a JSON object.")

  node.readConfigInt("seed", config.seed)
  node.readConfigInt("num_agents", config.numAgents)
  node.readConfigInt("numAgents", config.numAgents)
  node.readConfigInt("minPlayers", config.minPlayers)
  node.readConfigInt("maxTicks", config.maxTicks)
  node.readConfigInt("maxGames", config.maxGames)
  node.readConfigInt("turnTicks", config.turnTicks)
  node.readConfigInt("turnBudgetMs", config.turnBudgetMs)
  node.readConfigInt("attempt1Ms", config.attempt1Ms)
  node.readConfigInt("retryMs", config.retryMs)
  node.readConfigInt("minBatchSpacingMs", config.minBatchSpacingMs)
  node.readConfigInt("wallClockBudgetSeconds", config.wallClockBudgetSeconds)
  node.readConfigInt("lobbyJoinTimeoutTicks", config.lobbyJoinTimeoutTicks)
  node.readConfigInt("startWaitTicks", config.startWaitTicks)
  node.readConfigInt("gameOverTicks", config.gameOverTicks)
  node.readConfigInt("speed", config.speed)
  node.readConfigInt("maxOutputTokens", config.maxOutputTokens)
  node.readConfigInt("windowHalfWidthUm", config.windowHalfWidthUm)
  node.readConfigInt("strokeUm", config.strokeUm)
  node.readConfigInt("maxPistonSpeedUm", config.maxPistonSpeedUm)
  node.readConfigInt("ballRadiusUm", config.ballRadiusUm)
  node.readConfigInt("ballMassGrams", config.ballMassGrams)
  node.readConfigInt("stepPenaltyMilli", config.stepPenaltyMilli)
  node.readConfigBool("fastMode", config.fastMode)
  node.readConfigBool("showPlayerLabels", config.showPlayerLabels)
  node.readConfigBool("closedRoster", config.closedRoster)
  node.readConfigString("model", config.model)

  let
    players = node{"players"}
    slots = node{"slots"}
    tokens = node{"tokens"}
  var declared = config.numAgents
  if not players.isNil and players.kind == JArray:
    declared = max(declared, players.len)
  if not slots.isNil and slots.kind == JArray:
    declared = max(declared, slots.len)
  config.ensureSlots(declared)
  if not players.isNil and players.kind == JArray:
    for i in 0 ..< players.len:
      if i < config.slots.len and players[i].kind == JObject:
        config.slots[i].name = players[i]{"name"}.getStr()
  if not slots.isNil and slots.kind == JArray:
    for i in 0 ..< slots.len:
      if i < config.slots.len and slots[i].kind == JObject:
        let given = slots[i]{"alias"}.getStr()
        if given.len > 0:
          config.slots[i].alias = given
  if not tokens.isNil and tokens.kind == JArray:
    for i in 0 ..< tokens.len:
      if i < config.slots.len and tokens[i].kind == JString:
        config.slots[i].token = tokens[i].getStr()
  config.validate()

proc configuredPlayerName*(config: GameConfig, slot: int, token: string): string =
  ## The roster name for one join, resolved from the config alone.
  if slot >= 0 and slot < config.slots.len and config.slots[slot].name.len > 0:
    return config.slots[slot].name
  if token.len > 0:
    for entry in config.slots:
      if entry.token == token and entry.name.len > 0:
        return entry.name
  ""

proc playerJoinAllowed*(
  config: GameConfig, address: string, slot: int, token: string
): bool =
  ## Whether one websocket may take `slot`. A configured slot with a token
  ## demands exactly that token; a closed roster refuses anything outside it.
  if slot >= MaxPlayers:
    return false
  if slot >= config.slots.len:
    return not config.closedRoster
  if slot >= 0 and config.slots[slot].token.len > 0 and
      token != config.slots[slot].token:
    return false
  true

proc configJson*(config: GameConfig, perm: seq[int32],
                 restHeights: seq[int32]): string =
  ## The RESOLVED config, written into the replay header. It carries the seed,
  ## the seat -> piston map, the twenty rest heights, the whole geometry and
  ## physics table and the REAL policy names, so the static viewer needs
  ## nothing but the bytes.
  var
    players = newJArray()
    slotNodes = newJArray()
    tokens = newJArray()
  for entry in config.slots:
    players.add(%*{"name": entry.name})
    slotNodes.add(%*{"alias": entry.alias})
    tokens.add(%entry.token)
  var permNode = newJArray()
  for value in perm:
    permNode.add(%int(value))
  var restNode = newJArray()
  for value in restHeights:
    restNode.add(%int(value))
  var node = %*{
    "protocol": "pistonball/v1",
    "gameName": GameName,
    "gameVersion": GameVersion,
    "seed": config.seed,
    "num_agents": config.numAgents,
    "minPlayers": config.minPlayers,
    "maxTicks": config.maxTicks,
    "maxGames": config.maxGames,
    "turnTicks": config.turnTicks,
    "turnBudgetMs": config.turnBudgetMs,
    "attempt1Ms": config.attempt1Ms,
    "retryMs": config.retryMs,
    "minBatchSpacingMs": config.minBatchSpacingMs,
    "wallClockBudgetSeconds": config.wallClockBudgetSeconds,
    "lobbyJoinTimeoutTicks": config.lobbyJoinTimeoutTicks,
    "startWaitTicks": config.startWaitTicks,
    "gameOverTicks": config.gameOverTicks,
    "speed": config.speed,
    "fastMode": config.fastMode,
    "showPlayerLabels": config.showPlayerLabels,
    "closedRoster": config.closedRoster,
    "maxOutputTokens": config.maxOutputTokens,
    "stepPenaltyMilli": config.stepPenaltyMilli,
    "perm": permNode,
    "restHeightsUm": restNode,
    "players": players,
    "slots": slotNodes,
    "tokens": tokens
  }
  node["geometry"] = parseJson(geometryJson())
  $node
