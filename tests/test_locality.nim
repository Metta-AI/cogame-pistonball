## THE NO-MORE-THAN-YOUR-NEIGHBOURS INVARIANT.
##
## A seat's observation is built by exactly ONE function, `windowView`, and it
## contains nothing outside that seat's own +/-1.00 m window except the clock
## and one scalar shared-reward delta.

import
  std/[json, random, strutils, unittest],
  bitworld/spriteprotocol,
  ../src/pistonball/[sim, scripts, control, baselines, decide, global],
  ./helpers

suite "locality":
  test "the ball appears IFF its centre is inside this seat's window":
    var rng = initRand(20260826)
    var game = seatedSim(testConfig())
    var engine = initDecisionEngine(game)
    for _ in 0 ..< 200:
      game.scrambleState(rng)
      for seat in 0 ..< game.seatCount():
        let
          piston = game.pistonOfSeat(seat)
          view = engine.windowView(game, seat, 0)
          visible = abs32(game.ballX - pistonCentreX(piston)) <= WindowHalfWidth
        check (view["window"]["ball"].kind != JNull) == visible

  test "exactly the columns i-2 .. i+2 are reported, and no others":
    var rng = initRand(101)
    var game = seatedSim(testConfig())
    var engine = initDecisionEngine(game)
    for _ in 0 ..< 200:
      game.scrambleState(rng)
      for seat in 0 ..< game.seatCount():
        let
          piston = game.pistonOfSeat(seat)
          span = windowColumns(piston)
          view = engine.windowView(game, seat, 0)
        var reported: seq[int]
        for key, _ in view["window"]["neighbour_heights_m"].pairs:
          reported.add(parseInt(key))
        check reported.len == span.last - span.first + 1
        for column in reported:
          check column >= span.first and column <= span.last

  test "the composed message carries no other seat's script and no global state":
    var game = seatedSim(testConfig())
    game.phase = Playing
    var engine = initDecisionEngine(game)
    # Give every seat a DISTINCTIVE note and say, then prove seat 0's message
    # contains none of them.
    for seat in 0 ..< game.seatCount():
      var script = defaultScript()
      script.note = "secret-note-" & $seat
      script.say = "secret-say-" & $seat
      script.mode = modeCatch
      engine.scripts[seat] = script
      engine.haveScript[seat] = true
    game.progressMilli = 12_345
    game.penaltyMilli = 678
    game.bestX = 2_222_222'i32
    let message = $engine.windowView(game, 0, 3)
    for seat in 1 ..< game.seatCount():
      check "secret-note-" & $seat notin message
      check "secret-say-" & $seat notin message
    check "bestX" notin message
    check "2.22" notin message
    check "progressMilli" notin message
    check "perm" notin message
    check "seed" notin message
    check $game.config.seed notin message
    # Its OWN last script is legitimately there.
    check "your_last_script" in message

  test "no real player name reaches a seat's message":
    var game = seatedSim(testConfig())
    game.phase = Playing
    for seat in 0 ..< game.seatCount():
      game.seatNames[seat] = "REALNAME" & $seat
    var engine = initDecisionEngine(game)
    for seat in 0 ..< game.seatCount():
      let message = $engine.windowView(game, seat, 1)
      check "REALNAME" notin message
      check "policy-" notin message

  test "the seat's board frame carries the same window and no more":
    var rng = initRand(55)
    var game = seatedSim(testConfig())
    game.phase = Playing
    for _ in 0 ..< 50:
      game.scrambleState(rng)
      for seat in 0 ..< game.seatCount():
        var state = initPlayerViewerState()
        var next: PlayerViewerState
        let packet = buildSpriteProtocolPlayerUpdates(game, seat, state, next)
        check packet.len > 0
        let
          piston = game.pistonOfSeat(seat)
          span = windowColumns(piston)
        var heads: seq[int]
        for item in spritePacketObjects(packet):
          if item.id >= HeadObjectBase and item.id < HeadObjectBase + PistonCount:
            heads.add(item.id - HeadObjectBase)
        for column in heads:
          check column >= span.first and column <= span.last
        let hasBall = BallObjectId in spritePacketObjectIds(packet)
        check hasBall == inWindow(piston, game.ballX)

  test "the controller's inputs are structurally limited to one seat":
    # `pistonCommand(sim, script, piston)` takes ONE script and ONE index: it
    # has no way to reach another seat's script, and the target it computes
    # is a pure function of this piston's own window.
    var game = seatedSim(testConfig())
    game.phase = Playing
    game.ballX = pistonCentreX(0)
    var script = defaultScript()
    script.blind = blindIdle
    let far = 15
    check not inWindow(far, game.ballX)
    let before = pistonCommand(game, script, far)
    game.ballX = pistonCentreX(1)          # still outside piston 15's window
    check not inWindow(far, game.ballX)
    check pistonCommand(game, script, far) == before
