## The bank: fixed geometry, the seeded per-episode draws, and the contact
## broadphase.
##
## INTEGER ONLY (see `sim_types.nim`). The geometry table below is the same
## every episode; only `perm` (which seat drives which piston) and the twenty
## small rest heights are drawn, once, at t = 0, from `config.seed`. The sim
## draws no random numbers after tick 0.

import
  std/random,
  ./sim_types

proc pistonX1*(index: int): int32 =
  ## Right edge of piston `index`.
  pistonX0(index) + PistonWidth

proc headTopY*(height: int32): int32 =
  ## World y of a head's TOP SURFACE for a given extension (y is DOWN).
  FloorY - height

proc columnOf*(x: int32): int =
  ## The piston column whose x-range contains `x`, clamped to the bank.
  if x <= LeftWallX1:
    return 0
  if x >= RightWallX0:
    return PistonCount - 1
  let idx = int((x - LeftWallX1) div PistonWidth)
  if idx < 0: 0
  elif idx >= PistonCount: PistonCount - 1
  else: idx

proc windowColumns*(index: int): tuple[first, last: int] =
  ## The columns piston `index`'s +/-1.00 m window covers: `index-2 .. index+2`
  ## clipped at the ends of the bank. The window is 1.00 m and the pitch is
  ## 0.40 m, so it is always five columns wide in the middle of the bank.
  ## `tests/test_bank.nim` pins it.
  (max(0, index - 2), min(PistonCount - 1, index + 2))

proc inWindow*(index: int, x: int32): bool =
  ## True when world x is inside piston `index`'s observation window.
  let dx = x - pistonCentreX(index)
  (if dx < 0: -dx else: dx) <= WindowHalfWidth

proc broadphase*(ballX: int32): tuple[first, last: int] =
  ## Every head whose x-range comes within `BallRadius` of the ball's x, and
  ## no more: at most three, ascending. `tests/test_bank.nim` checks it
  ## against a brute-force scan over 10 000 randomised ball positions.
  var
    first = PistonCount
    last = -1
  let
    lo = ballX - BallRadius
    hi = ballX + BallRadius
  for i in 0 ..< PistonCount:
    if pistonX1(i) >= lo and pistonX0(i) <= hi:
      if i < first: first = i
      if i > last: last = i
  (first, last)

proc permDigestOf*(perm: seq[int32]): int64 =
  ## A cheap order-sensitive digest of the seat -> piston map, mixed into
  ## `gameHash` so a replay recorded under one permutation cannot validate
  ## against another.
  var digest = 1469598103934665603'u64
  for value in perm:
    digest = digest xor uint64(value)
    digest = digest * 1099511628211'u64
  cast[int64](digest)

proc drawEpisode*(
  seed: int
): tuple[perm: seq[int32], restHeights: seq[int32], startOffsetUm: int32] =
  ## The episode's only two random draws, both at t = 0 from one dedicated
  ## stream:
  ##
  ## * `perm` — a Fisher-Yates shuffle of 0..19. Seat `s` drives piston
  ##   `perm[s]`. This is the idea's anti-collusion clause: slot order carries
  ##   no information a colluding pair could key on, because the asymmetry
  ##   between "next to the goal" and "next to the ball" is resampled every
  ##   episode.
  ## * `restHeights` — twenty heads at `10_000 * k` micrometres for
  ##   `k` in 0..40, i.e. a slightly rough floor, so no two episodes open
  ##   identically.
  ## * `startOffsetUm` — 2..20 cm of lateral offset for the drop point, left
  ##   of the right wall. NOT decoration: `BallStartX` sits exactly on the
  ##   boundary between columns 18 and 19, and a disc whose centre is exactly
  ##   on a head's edge sees a PURELY VERTICAL normal — it balances on the
  ##   corner and the bank can lift it for ever without ever pushing it
  ##   sideways. The offset puts the drop point inside a column, where a
  ##   rising neighbour's corner is a real lateral push, and it varies with
  ##   the seed for the same reason the rest heights do.
  var stream = initRand(seed)
  var perm = newSeq[int32](PistonCount)
  for i in 0 ..< PistonCount:
    perm[i] = int32(i)
  for i in countdown(PistonCount - 1, 1):
    let j = stream.rand(i)
    let swapped = perm[i]
    perm[i] = perm[j]
    perm[j] = swapped
  var rest = newSeq[int32](PistonCount)
  for i in 0 ..< PistonCount:
    rest[i] = int32(10_000 * stream.rand(40))
  let offset = int32(20_000 + 10_000 * stream.rand(18))
  (perm, rest, offset)

proc geometryJson*(): string =
  ## The whole geometry + physics table, embedded in the replay's config JSON
  ## so the viewer never has to agree with the server about a constant by
  ## recompiling. Hand-rolled rather than std/json so this module stays
  ## import-clean for the determinism grep.
  "{\"worldWidthUm\":" & $WorldWidth &
  ",\"worldHeightUm\":" & $WorldHeight &
  ",\"floorYUm\":" & $FloorY &
  ",\"leftWallX1Um\":" & $LeftWallX1 &
  ",\"rightWallX0Um\":" & $RightWallX0 &
  ",\"pistonCount\":" & $PistonCount &
  ",\"pistonWidthUm\":" & $PistonWidth &
  ",\"strokeUm\":" & $Stroke &
  ",\"maxPistonSpeedUm\":" & $MaxPistonSpeed &
  ",\"ballRadiusUm\":" & $BallRadius &
  ",\"ballMassGrams\":" & $BallMassGrams &
  ",\"ballInertia\":" & $BallInertia &
  ",\"windowHalfWidthUm\":" & $WindowHalfWidth &
  ",\"goalXUm\":" & $GoalX &
  ",\"ballStartXUm\":" & $BallStartX &
  ",\"ballStartYUm\":" & $BallStartY &
  ",\"travelDistanceUm\":" & $TravelDistance &
  ",\"gravityPerSubstepUm\":" & $GravityPerSubstep &
  ",\"contactStiffness\":" & $ContactStiffness &
  ",\"contactDamping\":" & $ContactDamping &
  ",\"frictionNum\":" & $FrictionNum &
  ",\"frictionDen\":" & $FrictionDen &
  ",\"frictionViscous\":" & $FrictionViscous &
  ",\"airDragNum\":" & $AirDragNum &
  ",\"airDragDen\":" & $AirDragDen &
  ",\"spinDragNum\":" & $SpinDragNum &
  ",\"spinDragDen\":" & $SpinDragDen &
  ",\"maxBallSpeedUm\":" & $MaxBallSpeed &
  ",\"maxBallSpin\":" & $MaxBallSpin &
  ",\"substeps\":" & $SubSteps & "}"
