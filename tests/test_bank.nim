## The bank's geometry: the twenty x-ranges, the windows, and the broadphase.

import
  std/[random, unittest],
  ../src/pistonball/[sim]

suite "bank geometry":
  test "the twenty piston x-ranges tile the bank exactly":
    check pistonX0(0) == LeftWallX1
    check pistonX1(PistonCount - 1) == RightWallX0
    for i in 0 ..< PistonCount - 1:
      check pistonX1(i) == pistonX0(i + 1)      # no gap, no overlap
      check pistonX1(i) - pistonX0(i) == PistonWidth

  test "centreX matches the table":
    for i in 0 ..< PistonCount:
      check pistonCentreX(i) == 1_000_000'i32 + 400_000'i32 * int32(i)

  test "a window covers exactly i-2 .. i+2, clipped at the ends":
    for i in 0 ..< PistonCount:
      let span = windowColumns(i)
      check span.first == max(0, i - 2)
      check span.last == min(PistonCount - 1, i + 2)
      for column in 0 ..< PistonCount:
        let visible = column >= span.first and column <= span.last
        # The window is +/-1.00 m and the pitch is 0.40 m, so the columns the
        # index arithmetic names are exactly the columns whose CENTRES fall
        # inside it.
        let inside = abs32(pistonCentreX(column) - pistonCentreX(i)) <=
          WindowHalfWidth
        check visible == inside

  test "inWindow agrees with the +/-1.00 m predicate":
    var rng = initRand(99)
    for _ in 0 ..< 5000:
      let
        x = int32(rng.rand(int(WorldWidth)))
        i = rng.rand(PistonCount - 1)
      check inWindow(i, x) == (abs32(x - pistonCentreX(i)) <= WindowHalfWidth)

  test "the broadphase returns every head within BallRadius and no more":
    var rng = initRand(4242)
    for _ in 0 ..< 10_000:
      let x = int32(rng.rand(int(WorldWidth)))
      let span = broadphase(x)
      for i in 0 ..< PistonCount:
        let overlaps = pistonX1(i) >= x - BallRadius and
          pistonX0(i) <= x + BallRadius
        let returned = span.last >= span.first and i >= span.first and
          i <= span.last
        check overlaps == returned
      if span.last >= span.first:
        check span.last - span.first + 1 <= 3

  test "GoalX, BallStartX and TravelDistance are mutually consistent":
    check BallStartX - GoalX == TravelDistance
    check GoalX == LeftWallX1 + BallRadius
    check BallStartX == RightWallX0 - BallRadius

  test "the seeded draws are a pure function of the seed":
    let a = drawEpisode(4417231)
    let b = drawEpisode(4417231)
    check a.perm == b.perm
    check a.restHeights == b.restHeights
    var seen = newSeq[bool](PistonCount)
    for value in a.perm:
      check value >= 0 and int(value) < PistonCount
      check not seen[int(value)]
      seen[int(value)] = true
    for height in a.restHeights:
      check height >= 0 and height <= 400_000'i32
      check height mod 10_000'i32 == 0
