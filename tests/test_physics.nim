## The ball and the bank: settling, rolling, flicking, and containment.

import
  std/[random, unittest],
  ../src/pistonball/[sim, scripts, control, baselines],
  ./helpers

proc levelSim(height: int32, seed = 1): SimServer =
  result = seatedSim(testConfig(seed))
  result.phase = Playing
  for i in 0 ..< PistonCount:
    result.heights[i] = height
    result.pistonVel[i] = 0
  result.ballX = 4_800_000'i32
  result.ballY = FloorY - height - BallRadius
  result.ballVx = 0
  result.ballVy = 0
  result.spin = 0

proc holdAll(): seq[uint8] =
  result = newSeq[uint8](PistonCount)
  for i in 0 ..< result.len:
    result[i] = 127'u8

suite "pistonball physics":
  test "BallInertia is 1/2 m R^2":
    # m = 6 kg, R = 0.40 m -> 0.5 * 6 * 0.16 = 0.48 kg m^2 = 480 milli-kg m^2.
    check BallInertia == 480'i32
    check (int64(BallMassGrams) * int64(BallRadius) * int64(BallRadius)) div
      2_000_000_000_000'i64 == int64(BallInertia)

  test "a ball dropped onto a flat bank settles, with a sane penetration":
    var game = seatedSim(testConfig())
    game.phase = Playing
    for i in 0 ..< PistonCount:
      game.heights[i] = 0
    game.ballX = 4_800_000'i32
    game.ballY = BallStartY
    for _ in 0 ..< 240:
      game.step(holdAll())
    check abs32(game.ballVy) < 4_000'i32
    # It comes to REST ON the bank: the contact spring holds it within a
    # fraction of a millimetre of the surface and never lets it sink in.
    let penetration = (game.ballY + BallRadius) - FloorY
    check penetration >= 0'i32
    check penetration < 5_000'i32

  test "a ball at rest on a level bank does not drift":
    var game = levelSim(400_000'i32)
    for _ in 0 ..< 480:
      game.step(holdAll())
      check abs32(game.ballVx) < 1_000'i32
    check abs32(game.ballX - 4_800_000'i32) < 200_000'i32

  test "a bank sloping down to the left rolls the ball LEFT, spinning correctly":
    var game = levelSim(0'i32)
    # A real slope, not a step: each column stands 6 cm higher than the one on
    # its left, so the surface under the ball falls away toward the goal. This
    # IS the mechanism — the ball rolls down whatever slope the bank makes.
    for i in 0 ..< PistonCount:
      game.heights[i] = int32(i) * 60_000'i32
    # Sit it on the CENTRE of a column so its taller right-hand neighbour is
    # genuinely in contact: a ball balanced exactly on a column boundary sees
    # only a vertical normal and would sit there for ever, which is the honest
    # behaviour of a bank that has not made a slope under it yet.
    let column = 10
    game.ballX = pistonCentreX(column)
    game.ballY = FloorY - game.heights[column] - BallRadius
    let startX = game.ballX
    # Stop short of the goal wall: past it the episode ENDS and the frozen
    # game-over state says nothing about rolling.
    for _ in 0 ..< 80:
      game.step(holdAll())
    check game.ballX < startX - 200_000'i32
    # Rolling without slipping to the LEFT is counter-clockwise on screen, so
    # spin must be POSITIVE, and its magnitude must match v / R to within 15 %.
    check game.spin > 0
    let rolling = (-int64(game.ballVx) * 652'i64) div int64(BallRadius)
    check rolling > 0
    check abs64(int64(game.spin) - rolling) * 100'i64 <= rolling * 15'i64

  test "a rising head imparts upward velocity to a resting ball":
    var game = levelSim(200_000'i32)
    for _ in 0 ..< 48:
      game.step(holdAll())
    let before = game.ballVy
    var commands = holdAll()
    let column = columnOf(game.ballX)
    for piston in 0 ..< PistonCount:
      let seat = game.seatOfPiston(piston)
      commands[seat] = if piston == column: 254'u8 else: 127'u8
    for _ in 0 ..< 6:
      game.step(commands)
    # +y is DOWN, so "upward" is a fall in ballVy.
    check game.ballVy < before

  test "contacts never stick and the ball never leaves the guard box":
    var rng = initRand(20260825)
    var game = seatedSim(testConfig())
    game.phase = Playing
    for _ in 0 ..< 1800:
      var commands = newSeq[uint8](PistonCount)
      for i in 0 ..< commands.len:
        commands[i] = uint8(rng.rand(254))
      game.step(commands)
      check game.ballX >= GuardMinX and game.ballX <= GuardMaxX
      check game.ballY >= GuardMinY and game.ballY <= GuardMaxY
      check abs32(game.ballVx) <= MaxBallSpeed
      check abs32(game.spin) <= MaxBallSpin
      for record in game.contacts:
        check record.depth >= 0          # a contact pushes, never pulls
        check record.approach >= 0

  test "twenty wavebots never trip the containment guard":
    let game = runScripted(4417231, [blWavebot])
    check game.guardClamps == 0
    check game.endReason in [ReasonComplete, ReasonDeadline]
