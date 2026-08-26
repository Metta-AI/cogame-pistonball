## The websocket contract and the two name spaces.
##
## Importing `server` here is also the compile gate on the whole serving path:
## the embedded client page, the wire-constant splice and the static assets are
## all `staticRead` at compile time.

import
  std/[json, os, strutils, unicode, unittest],
  ../src/pistonball/[sim, scripts, baselines, decide, global, broadcast,
                     roster, server, wire_constants],
  ./helpers

suite "the server contract":
  test "a registration frame is parsed; anything else is not a registration":
    let good = parseRegistration(
      "{\"type\":\"register\",\"prompt\":\"roll it left\"," &
      "\"scripted\":null,\"policy\":\"swell\"}")
    check good.ok
    check good.prompt == "roll it left"
    check good.scripted == ""
    check good.policy == "swell"
    let scripted = parseRegistration(
      "{\"type\":\"register\",\"prompt\":\"\",\"scripted\":\"metronome\"," &
      "\"policy\":\"filler\"}")
    check scripted.ok
    check scripted.scripted == "metronome"
    check parseBaseline(scripted.scripted) == blMetronome
    check not parseRegistration("hello everyone").ok
    check not parseRegistration("{\"type\":\"shout\",\"text\":\"hi\"}").ok
    check not parseRegistration("").ok

  test "a prompt over 4000 runes is TRUNCATED, never rejected":
    var long = ""
    for _ in 0 ..< 5000:
      long.add("\u00e9")                 # a two-byte rune, so bytes != runes
    let registration = parseRegistration(
      $(%*{"type": "register", "prompt": long, "policy": "long"}))
    check registration.ok
    let stored = registration.prompt.truncateRunes(MaxPromptRunes)
    check stored.runeLen == MaxPromptRunes
    check stored.validateUtf8() == -1

  test "the register record is REDACTED: the prompt never reaches the replay":
    let record = registerRecord(0, 13, alias(13), "swell", "llm", "wavebot")
    check "prompt" notin record
    let node = parseJson(record)
    check node["k"].getStr() == "register"
    check node["alias"].getStr() == "PST-14"
    check node["kind"].getStr() == "llm"
    check node["policy"].getStr().runeLen <= MaxPolicyLabelRunes

  test "a policy label over its cap is cut on a RUNE boundary":
    var label = ""
    for _ in 0 ..< 200:
      label.add("\u00fc")
    let node = parseJson(registerRecord(1, 2, alias(2), label, "llm", "wavebot"))
    check node["policy"].getStr().runeLen == MaxPolicyLabelRunes
    check node["policy"].getStr().validateUtf8() == -1

  test "a bad slot or token is refused by the config, before any upgrade":
    var config = defaultGameConfig()
    config.update("")
    config.slots[3].token = "secret"
    config.closedRoster = true
    check config.playerJoinAllowed("someone", 3, "secret")
    check not config.playerJoinAllowed("someone", 3, "wrong")
    check not config.playerJoinAllowed("someone", 99, "")
    check not config.playerJoinAllowed("someone", 25, "")

  test "TWO NAME SPACES: the chrome roster has real names, the board does not":
    var game = seatedSim(testConfig())
    game.phase = Playing
    for seat in 0 ..< game.seatCount():
      game.seatNames[seat] = "REALNAME" & $seat
    let state = game.buildStateJson(newJArray(), true, 1, 1800, false, true,
      -1, -1)
    check "REALNAME0" in state             # spectator side: yes
    let node = parseJson(state)
    check node["roster"].len == PistonCount
    for row in node["roster"]:
      check row["alias"].getStr().startsWith("PST-")
    # and the results document carries them too
    let results = parseJson(game.playerResultsJson())
    check results["names"].len == PistonCount
    check results["aliases"][0].getStr().startsWith("PST-")
    # but a PLAYER frame carries no name at all
    for seat in 0 ..< game.seatCount():
      var before = initPlayerViewerState()
      var after: PlayerViewerState
      let packet = buildSpriteProtocolPlayerUpdates(game, seat, before, after)
      var text = ""
      for value in packet:
        if value >= 32'u8 and value < 127'u8:
          text.add(char(value))
      check "REALNAME" notin text

  test "the wire constants splice, and carry the engine's own numbers":
    check WireConstantsJs.startsWith("window.PISTONBALL_WIRE={")
    check "fps:24" in WireConstantsJs
    check "chromeSpriteId:4090" in WireConstantsJs
    check "pistons:20" in WireConstantsJs
    let page = spliceWireConstants(
      "<html><!-- WIRE_CONSTANTS --></html>")
    check "window.PISTONBALL_WIRE" in page
    check WireConstantsMarker notin page

  test "the artifact contract names the URIs the runner sets":
    let source = readFile(
      currentSourcePath().parentDir().parentDir() /
      "src" / "pistonball" / "server.nim")
    for name in ["COGAME_PLAYER_FAILURE_URI", "COGAME_EVENTS_URI",
                 "COGAME_METRICS_URI"]:
      check name in source
    # /healthz and both /client/ routes are registered, and neither client
    # route opens the player socket.
    check "\"/healthz\"" in source
    check "GlobalClientRoute" in source
    check "PlayerClientRoute" in source
    check "ReplayDataPath" in source
