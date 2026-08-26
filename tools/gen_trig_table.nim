## Regenerates the committed integer sine table in src/pistonball/trig.nim.
##
## The table is CHECKED IN rather than computed at startup because the sim must
## not call into libm at all: the native amd64 server and the wasm32 replay
## viewer would then have to agree about rounding, which is exactly the class
## of disagreement the integer sim exists to rule out.
## `tests/test_determinism.nim` re-derives every entry and fails on one unit of
## drift, so running this tool and pasting its output is a checkable operation.
import std/[math, strutils]

const Steps = 256
const One = 4096

when isMainModule:
  var values: seq[string]
  for k in 0 ..< Steps:
    let exact = sin(2.0 * PI * float(k) / float(Steps)) * float(One)
    let rounded =
      if exact >= 0: int(floor(exact + 0.5))
      else: -int(floor(-exact + 0.5))
    values.add($rounded)
  echo "  SinQ12*: array[TrigSteps, int32] = ["
  var line = "   "
  for i, value in values:
    let piece = (if i == 0: value & "'i32" else: value) &
      (if i == values.high: "" else: ",")
    if line.len + piece.len + 1 > 74:
      echo line
      line = "   "
    line.add(" ")
    line.add(piece)
  if line.strip().len > 0:
    echo line
  echo "  ]"
