## The scoring formula, its sign, and the phase metric.

import
  std/[json, strutils, unittest],
  ../src/pistonball/[sim, roster, baselines],
  ./helpers

proc scoreFor(finalX: int32, ticks: int): float =
  ## The worked examples of the design note, computed the way the sim does.
  let
    progressMilli = (1000'i64 * 100'i64 *
      (int64(BallStartX) - int64(finalX))) div int64(TravelDistance)
    penaltyMilli = 10'i64 * int64(ticks)
  parseFloat(pointsText(progressMilli - penaltyMilli))

proc holdCommands(): seq[uint8] =
  result = newSeq[uint8](PistonCount)
  for i in 0 ..< result.len:
    result[i] = 127'u8

let holds = holdCommands()

suite "scoring":
  test "the six worked examples reproduce to three decimals":
    check scoreFor(1_200_000'i32, 600) == 94.0
    check scoreFor(1_200_000'i32, 1520) == 84.8
    check scoreFor(3_000_000'i32, 1800) == 57.0
    # The design note's table rounds this row; the sim TRUNCATES toward zero
    # (which is what makes leftward and rightward progress exactly opposite),
    # so the milli-point value is 13.888 - 18.000 = -4.112.
    check abs(scoreFor(7_400_000'i32, 1800) - (-4.112)) < 0.0005
    check scoreFor(8_400_000'i32, 1800) == -18.0

  test "progress telescopes: only where the ball ENDED matters":
    var straight = 0'i64
    var wobbly = 0'i64
    var x = int64(BallStartX)
    proc accrue(acc: var int64, previous, current: int64) =
      acc += (1000'i64 * 100'i64 * (previous - current)) div
        int64(TravelDistance)
    # straight: one 4.00 m move left
    accrue(straight, x, x - 4_000_000)
    # wobbly: 6 m left, 3 m back, 1 m left — same finish
    var cursor = x
    accrue(wobbly, cursor, cursor - 6_000_000); cursor -= 6_000_000
    accrue(wobbly, cursor, cursor + 3_000_000); cursor += 3_000_000
    accrue(wobbly, cursor, cursor - 1_000_000); cursor -= 1_000_000
    check cursor == x - 4_000_000
    check straight == wobbly

  test "all twenty scores are bit-identical and win mirrors delivered":
    let game = runScripted(4417231, [blWavebot])
    let results = parseJson(game.playerResultsJson())
    check results["scores"].len == 20
    let first = results["scores"][0]
    for value in results["scores"]:
      check $value == $first
    check results["win"].len == 20
    for value in results["win"]:
      check value.getBool() == results["delivered"].getBool()
    check results["sharedScore"].getFloat() == first.getFloat()

  test "delivering stops the penalty at the delivery tick":
    let game = runScripted(4417231, [blWavebot])
    if game.delivered():
      # The penalty accrues once per PLAYED tick; the lobby ticks before
      # `gameStartTick` are not charged.
      check game.penaltyMilli ==
        10'i64 * int64(game.deliveryTick - game.gameStartTick)
      check game.endRule == EndRuleDelivered
      check game.endReason == ReasonComplete

  test "the phase metric is 1000 permille for a perfect wave and 0 for its inverse":
    var game = seatedSim(testConfig())
    game.phase = Playing
    game.ballX = 4_800_000'i32
    # perfect: behind the ball is fully up, in front is fully down
    for i in 0 ..< PistonCount:
      game.heights[i] =
        if pistonCentreX(i) >= game.ballX: Stroke else: 0'i32
    for _ in 0 ..< 4:
      game.step(holds)
    check game.phasePermille() > 900
    var inverse = seatedSim(testConfig())
    inverse.phase = Playing
    inverse.ballX = 4_800_000'i32
    for i in 0 ..< PistonCount:
      inverse.heights[i] =
        if pistonCentreX(i) >= inverse.ballX: 0'i32 else: Stroke
    for _ in 0 ..< 4:
      inverse.step(holds)
    check inverse.phasePermille() < 100

  test "the score floor is exactly -18.000 for a bank that never moves":
    var game = seatedSim(testConfig())
    game.phase = Playing
    check scoreFor(BallStartX, 1800) == -18.0

  test "an episode that ends RIGHT of the drop point still floors at -18.000":
    # The ball is dropped 2..20 cm left of the guard's right edge (the seeded
    # `startOffsetUm`), so a bank that shoves it back into the right wall ends
    # right of where it started and the raw telescoping sum goes NEGATIVE.
    # Reported progress is clamped at zero, which is what makes the -18.000
    # floor the rules promise true; the accumulator itself is left signed, so
    # backsliding inside a run still costs exactly what it gained.
    let game = runScripted(63352, [blMetronome])
    check game.progressMilli < 0                  # the raw sum really is
    check game.progressPoints() == 0              # …and the report is not
    check game.scoreMilli() >= -18_000
    check game.scoreMilli() == -game.penaltyMilli
    let results = parseJson(game.playerResultsJson())
    check results["progress"].getFloat() == 0.0
    check results["sharedScore"].getFloat() >= -18.0
    for value in results["scores"]:
      check value.getFloat() >= -18.0
