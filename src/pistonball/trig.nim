## Integer trigonometry and the integer square root: the only two pieces of
## "maths library" the sim is allowed to use.
##
## INTEGER ONLY (see `sim_types.nim`). `SinQ12` is a COMMITTED literal table,
## generated once by `tools/gen_trig_table.nim` and checked in;
## `tests/test_determinism.nim` re-derives every entry from the standard
## library and fails on a single unit of drift. Nothing here calls into libm,
## so the native amd64 server and the wasm32 replay viewer cannot disagree.

const
  TrigSteps* = 256
    ## Quarter-resolution table: 256 samples over one full turn. The sim's
    ## angle unit is 1/16 brad (4096 = one turn), so index = angleQ div 16.
  TrigOne* = 4096
    ## Q12 fixed point: entry k is the sine of 2*pi*k/256, scaled by 4096 and
    ## rounded half away from zero.

  SinQ12*: array[TrigSteps, int32] = [
    0'i32, 101, 201, 301, 401, 501, 601, 700, 799, 897, 995, 1092, 1189,
    1285, 1380, 1474, 1567, 1660, 1751, 1842, 1931, 2019, 2106, 2191,
    2276, 2359, 2440, 2520, 2598, 2675, 2751, 2824, 2896, 2967, 3035,
    3102, 3166, 3229, 3290, 3349, 3406, 3461, 3513, 3564, 3612, 3659,
    3703, 3745, 3784, 3822, 3857, 3889, 3920, 3948, 3973, 3996, 4017,
    4036, 4052, 4065, 4076, 4085, 4091, 4095, 4096, 4095, 4091, 4085,
    4076, 4065, 4052, 4036, 4017, 3996, 3973, 3948, 3920, 3889, 3857,
    3822, 3784, 3745, 3703, 3659, 3612, 3564, 3513, 3461, 3406, 3349,
    3290, 3229, 3166, 3102, 3035, 2967, 2896, 2824, 2751, 2675, 2598,
    2520, 2440, 2359, 2276, 2191, 2106, 2019, 1931, 1842, 1751, 1660,
    1567, 1474, 1380, 1285, 1189, 1092, 995, 897, 799, 700, 601, 501,
    401, 301, 201, 101, 0, -101, -201, -301, -401, -501, -601, -700,
    -799, -897, -995, -1092, -1189, -1285, -1380, -1474, -1567, -1660,
    -1751, -1842, -1931, -2019, -2106, -2191, -2276, -2359, -2440,
    -2520, -2598, -2675, -2751, -2824, -2896, -2967, -3035, -3102,
    -3166, -3229, -3290, -3349, -3406, -3461, -3513, -3564, -3612,
    -3659, -3703, -3745, -3784, -3822, -3857, -3889, -3920, -3948,
    -3973, -3996, -4017, -4036, -4052, -4065, -4076, -4085, -4091,
    -4095, -4096, -4095, -4091, -4085, -4076, -4065, -4052, -4036,
    -4017, -3996, -3973, -3948, -3920, -3889, -3857, -3822, -3784,
    -3745, -3703, -3659, -3612, -3564, -3513, -3461, -3406, -3349,
    -3290, -3229, -3166, -3102, -3035, -2967, -2896, -2824, -2751,
    -2675, -2598, -2520, -2440, -2359, -2276, -2191, -2106, -2019,
    -1931, -1842, -1751, -1660, -1567, -1474, -1380, -1285, -1189,
    -1092, -995, -897, -799, -700, -601, -501, -401, -301, -201, -101
  ]

proc sinQ*(angleQ: int32): int32 =
  ## sin of an angle in 1/16 brad, in Q12. Pure table lookup, no interpolation:
  ## the value only drives the ball's RENDERED highlight, never the solver.
  let idx = ((int(angleQ) div 16) mod TrigSteps + TrigSteps) mod TrigSteps
  SinQ12[idx]

proc cosQ*(angleQ: int32): int32 =
  ## cos of an angle in 1/16 brad, in Q12.
  sinQ(angleQ + 1024'i32)

proc isqrt*(value: int64): int64 =
  ## Integer square root by Newton's method, truncating. The ONLY square root
  ## in the sim (contact distances, tangential magnitudes) and the reason the
  ## contact solver stays bit-identical across builds.
  ## Exhaustively unit-tested below 2^16 and on perfect squares to 2^40.
  if value <= 0:
    return 0
  if value < 4:
    return 1
  var x = value
  var bit = 1'i64
  # Seed with a power of two at half the bit length: cheap, deterministic, and
  # always at or above the true root, which is what makes the descent below
  # monotone.
  while bit * bit <= value and bit < 0x4000_0000'i64:
    bit = bit shl 1
  x = bit
  while true:
    let next = (x + value div x) div 2
    if next >= x:
      break
    x = next
  while x * x > value:
    dec x
  while (x + 1) * (x + 1) <= value:
    inc x
  x

proc clampI32*(value, low, high: int32): int32 =
  ## Saturating clamp on int32 sim quantities.
  if value < low: low
  elif value > high: high
  else: value

proc abs32*(value: int32): int32 =
  if value < 0: -value else: value

proc abs64*(value: int64): int64 =
  if value < 0: -value else: value

proc signOf*(value: int64): int64 =
  if value > 0: 1
  elif value < 0: -1
  else: 0
