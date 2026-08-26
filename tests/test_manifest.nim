## The manifest is the contract with the platform. `results_schema` is
## `additionalProperties: false` and the certifier rejects any unknown field,
## so adding or removing a key in `playerResultsJson` means editing
## `coworld_manifest_template.json` in the SAME commit.

import
  std/[json, os, sets, strutils, unittest],
  ../src/pistonball/[sim, roster, baselines],
  ./helpers

let root = currentSourcePath().parentDir().parentDir()
let manifest = parseJson(readFile(root / "coworld_manifest_template.json"))

suite "the manifest":
  test "num_agents is 20 in EVERY variant and in the certification fixture":
    check manifest["variants"].len == 2
    for variant in manifest["variants"]:
      check variant["game_config"]["num_agents"].getInt == 20
      check variant["id"].getStr().len > 0
      check variant["name"].getStr().len > 0
      check variant["description"].getStr().len > 0
      check variant["game_config"]["players"].len == 20
      check variant["game_config"]["slots"].len == 20
      check variant["game_config"]["minPlayers"].getInt == 20
    check manifest["certification"]["game_config"]["num_agents"].getInt == 20
    check manifest["certification"]["players"].len == 20
    check manifest["certification"]["game_config"]["players"].len == 20
    check manifest["certification"]["game_config"]["slots"].len == 20

  test "every declared player entry occupies at least one certification slot":
    var declared = initHashSet[string]()
    for entry in manifest["player"]:
      declared.incl(entry["id"].getStr())
    var seated = initHashSet[string]()
    for entry in manifest["certification"]["players"]:
      seated.incl(entry["player_id"].getStr())
    for id in declared:
      check id in seated

  test "results_schema keys == playerResultsJson keys, arrays bounded 20/20":
    let game = runScripted(4417231, [blWavebot], maxTicks = 450)
    let produced = parseJson(game.playerResultsJson())
    let schema = manifest["game"]["results_schema"]
    check schema["additionalProperties"].getBool() == false
    var schemaKeys = initHashSet[string]()
    for key, _ in schema["properties"].pairs:
      schemaKeys.incl(key)
    var producedKeys = initHashSet[string]()
    for key, _ in produced.pairs:
      producedKeys.incl(key)
    check schemaKeys == producedKeys
    check schemaKeys.len == 25
    for key, definition in schema["properties"].pairs:
      if definition["type"].getStr() == "array":
        check definition["minItems"].getInt == 20
        check definition["maxItems"].getInt == 20
    for name in ["names", "scores", "win", "reason", "endRule", "delivered",
                 "sharedScore", "progress"]:
      var required = false
      for entry in schema["required"]:
        if entry.getStr() == name:
          required = true
      check required

  test "the end enums are closed and match the sim's constants":
    let schema = manifest["game"]["results_schema"]["properties"]
    var reasons: seq[string]
    for entry in schema["reason"]["enum"]:
      reasons.add(entry.getStr())
    check reasons == @[ReasonComplete, ReasonDeadline, ReasonFault]
    var rules: seq[string]
    for entry in schema["endRule"]["enum"]:
      rules.add(entry.getStr())
    check rules == @[EndRuleDelivered, EndRuleOutOfTime, EndRuleWallClock,
                     EndRuleSimFault, EndRuleHostError]

  test "every array in config_schema declares minItems and maxItems":
    let schema = manifest["game"]["config_schema"]
    check schema["additionalProperties"].getBool() == false
    for key, definition in schema["properties"].pairs:
      if definition{"type"}.getStr() == "array":
        checkpoint(key)
        check definition.hasKey("minItems")
        check definition.hasKey("maxItems")

  test "config_schema covers every field sim_config.update reads":
    let source = readFile(root / "src" / "pistonball" / "sim_config.nim")
    let schema = manifest["game"]["config_schema"]["properties"]
    for line in source.splitLines():
      let trimmed = line.strip()
      if not trimmed.startsWith("node.readConfig"):
        continue
      let open = trimmed.find('"')
      let close = trimmed.find('"', open + 1)
      if open < 0 or close < 0:
        continue
      let key = trimmed[open + 1 ..< close]
      if key == "numAgents":
        continue                   # the camelCase alias of num_agents
      checkpoint(key)
      check schema.hasKey(key)

  test "the game block is shaped the way the CLI expects":
    check manifest["game"]["name"].getStr() == "pistonball"
    check manifest["game"]["owner"].getStr().len > 0
    check manifest["game"]["replay_viewer"]["bundle"].getStr() ==
      "static-replay-viewer"
    check not manifest.hasKey("version")
    check not manifest["game"].hasKey("display_name")
    check manifest["tags"].len >= 3
    check manifest["episode_timeout_minutes"].getInt == 20
    check manifest["game"]["runnable"]["image"].getStr() == "{{PISTONBALL_IMAGE}}"
    check manifest["game"]["runnable"]["run"][0].getStr() == "/bin/pistonball"
    check manifest["game"]["runnable"]["env"]["ANTHROPIC_API_KEY_URI"].getStr() ==
      "secret://coworld/pistonball/anthropic_api_key"
    check manifest["player"][0]["run"][0].getStr() == "/bin/pistonball-player"
    check manifest["player"][0]["image"].getStr() == "{{PISTONBALL_IMAGE}}"

  test "BOTH protocols are objects, and every doc page is non-empty text":
    for key in ["player", "global"]:
      let node = manifest["game"]["protocols"][key]
      check node["type"].getStr() == "text"
      check node["value"].getStr().len > 200
    check manifest["game"]["docs"]["readme"]["type"].getStr() == "text"
    check manifest["game"]["docs"]["readme"]["value"].getStr().len > 200
    check manifest["game"]["docs"]["pages"].len == 3
    for page in manifest["game"]["docs"]["pages"]:
      check page["id"].getStr().len > 0
      check page["title"].getStr().len > 0
      check page["content"]["type"].getStr() == "text"
      check page["content"]["value"].getStr().len > 200

  test "the secret namespace equals game.name, and compose agrees on the image":
    let name = manifest["game"]["name"].getStr()
    check "secret://coworld/" & name & "/anthropic_api_key" ==
      manifest["game"]["runnable"]["env"]["ANTHROPIC_API_KEY_URI"].getStr()
    let compose = readFile(root / "compose.yaml")
    check "  " & name & ":" in compose
    check "image: coworld-" & name & ":latest" in compose
    # the placeholder is derived from the COMPOSE SERVICE NAME
    check "{{" & name.toUpperAscii() & "_IMAGE}}" ==
      manifest["game"]["runnable"]["image"].getStr()

  test "every variant settles inside 60 % of episodeTimeoutSeconds":
    let timeoutSeconds = manifest["episode_timeout_minutes"].getInt * 60
    for variant in manifest["variants"]:
      let config = variant["game_config"]
      check config["wallClockBudgetSeconds"].getInt <=
        (timeoutSeconds * 60) div 100
      check config["attempt1Ms"].getInt + config["retryMs"].getInt <=
        config["turnBudgetMs"].getInt
      check config["maxTicks"].getInt mod config["turnTicks"].getInt == 0

  test "every manifest game_config is accepted by the sim's own parser":
    for variant in manifest["variants"]:
      var config = defaultGameConfig()
      config.update($variant["game_config"])
      check config.numAgents == 20
    var certification = defaultGameConfig()
    certification.update($manifest["certification"]["game_config"])
    check certification.numAgents == 20
    check certification.maxTicks == 900
    check certification.minBatchSpacingMs == 0

  test "tools/ci/policies.json is pistonball's own set, correctly shaped":
    let policies = parseJson(readFile(root / "tools" / "ci" / "policies.json"))
    check policies.len == 4
    var prompts = 0
    var scripted = 0
    var owned = 0
    for policy in policies:
      check policy["name"].getStr().startsWith("pistonball-")
      check "bullwhip" notin policy["name"].getStr()
      check policy["run"].getStr() == "/bin/pistonball-player"
      if policy["env"].hasKey("PLAYER_PROMPT"):
        inc prompts
        check policy["env"]["PLAYER_PROMPT"].getStr().len > 200
      if policy["env"].hasKey("PLAYER_SCRIPTED"):
        inc scripted
        check parseBaseline(policy["env"]["PLAYER_SCRIPTED"].getStr()) in
          {blWavebot, blMetronome}
      if policy.hasKey("player"):
        inc owned
        check policy["player"].getStr() ==
          "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"
    check prompts == 2
    check scripted == 2
    check owned == 1
