## The deterministic controller: bounded, legal, and reproducible.

import
  std/[math, random, unittest],
  ../src/pistonball/[sim, scripts, control, baselines],
  ./helpers

suite "controller":
  test "2000 randomised (state, script) pairs stay inside their bounds":
    var rng = initRand(31337)
    var game = seatedSim(testConfig())
    for _ in 0 ..< 2000:
      game.scrambleState(rng)
      let
        piston = rng.rand(PistonCount - 1)
        script = randomScript(rng)
        command = pistonCommand(game, script, piston)
      check command <= 254'u8
      let velocity = decodePistonCommand(command)
      let limit = int32(
        (int64(MaxPistonSpeed) * int64(script.speed255)) div 255'i64) + 1'i32
      check abs32(velocity) <= limit
      # Applying it can never take a head out of its stroke.
      let after = clampI32(game.heights[piston] + velocity, 0'i32, Stroke)
      check after >= 0 and after <= Stroke

  test "the same (state, script) pair always yields the same byte":
    var rng = initRand(4242)
    var game = seatedSim(testConfig())
    for _ in 0 ..< 200:
      game.scrambleState(rng)
      let
        piston = rng.rand(PistonCount - 1)
        script = randomScript(rng)
      check pistonCommand(game, script, piston) ==
        pistonCommand(game, script, piston)

  test "each mode produces the documented target in its documented case":
    var game = seatedSim(testConfig())
    game.phase = Playing
    let piston = 10
    game.ballVx = 0
    var script = defaultScript()
    script.triggerUm = WindowHalfWidth
    script.leadTicks = 0
    script.upUm = 1_400_000'i32
    script.downUm = 100_000'i32
    script.idleUm = 300_000'i32
    script.speed255 = 255

    # wave: the ball at-or-LEFT-of me means I am BEHIND it (larger x, the side
    # it came from), so I go UP and it rolls off my shoulder.
    game.ballX = pistonCentreX(piston) - 300_000'i32
    script.mode = modeWave
    check targetHeight(game, script, piston) == script.upUm
    # wave: the ball to my RIGHT means I am IN FRONT of it, so I clear the way.
    game.ballX = pistonCentreX(piston) + 300_000'i32
    check targetHeight(game, script, piston) == script.downUm
    # lift / drop / hold do not care which side the ball is on.
    script.mode = modeLift
    check targetHeight(game, script, piston) == script.upUm
    script.mode = modeDrop
    check targetHeight(game, script, piston) == script.downUm
    script.mode = modeHold
    check targetHeight(game, script, piston) == script.idleUm
    # catch: only while the ball is going the WRONG way
    script.mode = modeCatch
    game.ballX = pistonCentreX(piston) - 300_000'i32
    game.ballVx = -50_000'i32
    check targetHeight(game, script, piston) == script.idleUm
    game.ballVx = 50_000'i32
    check targetHeight(game, script, piston) == script.upUm

  test "blind=hold holds and yields cmd 127 when already at target":
    var game = seatedSim(testConfig())
    game.phase = Playing
    let piston = 3
    game.ballX = GuardMaxX                 # far outside piston 3's window
    var script = defaultScript()
    script.blind = blindHold
    script.mode = modeWave
    game.heights[piston] = 700_000'i32
    check not inWindow(piston, game.ballX)
    check targetHeight(game, script, piston) == game.heights[piston]
    check pistonCommand(game, script, piston) == 127'u8

  test "ripple is periodic with period 48 and monotone in the column":
    var game = seatedSim(testConfig())
    game.phase = Playing
    var script = defaultScript()
    script.mode = modeRipple
    script.upUm = 1_200_000'i32
    script.idleUm = 100_000'i32
    for piston in 0 ..< PistonCount:
      game.tickCount = 0
      let a = rippleHeight(script, 0, piston)
      let b = rippleHeight(script, RipplePeriod, piston)
      check a == b
    # The phase offset advances one column at a time, so the wave TRAVELS —
    # asserted on `rippleHeight` itself, by finding each column's CREST inside
    # one period. Column i peaks at 12 + 2.4*i ticks, so the crest walks 2 or
    # 3 ticks to the right per column and laps exactly once across the twenty
    # columns (20 * 2.4 = 48 = one period).
    var previous = -1
    var wraps = 0
    for piston in 0 ..< PistonCount:
      var crest = 0
      var peak = int32.low
      for tick in 0 ..< RipplePeriod:
        let height = rippleHeight(script, tick, piston)
        checkpoint("piston " & $piston & " tick " & $tick)
        check height >= script.idleUm
        check height <= script.upUm
        if height > peak:
          peak = height
          crest = tick
      checkpoint("piston " & $piston & " crest " & $crest)
      check crest == (12 + (24 * piston + 5) div 10) mod RipplePeriod
      if piston > 0:
        check (crest - previous + RipplePeriod) mod RipplePeriod in [2, 3]
        if crest < previous:
          inc wraps
      previous = crest
    check wraps == 1

  test "a non-Playing phase forces cmd 127":
    var game = seatedSim(testConfig())
    var script = defaultScript()
    game.phase = Lobby
    check pistonCommand(game, script, 0) == 127'u8
    game.phase = GameOver
    check pistonCommand(game, script, 0) == 127'u8

  test "the command byte round-trips through its decode":
    for raw in 0 .. 254:
      let velocity = decodePistonCommand(uint8(raw))
      check abs32(velocity) <= MaxPistonSpeed
      check abs(int(encodePistonCommand(velocity)) - raw) <= 1
    # 255 is reserved and repairs to hold.
    check decodePistonCommand(255'u8) == 0'i32
