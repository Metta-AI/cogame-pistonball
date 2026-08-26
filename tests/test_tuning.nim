## The shipped baseline defaults still equal the sweep's recorded pick.

import
  std/[json, os, unittest],
  ../src/pistonball/[sim, baselines]

suite "baseline tuning":
  test "DefaultBaselineParams equals tools/ci/baseline_tuning.json":
    let root = currentSourcePath().parentDir().parentDir()
    let recorded = parseJson(readFile(root / "tools" / "ci" /
      "baseline_tuning.json"))["wavebot"]
    check recorded["leadTicks"].getInt == DefaultBaselineParams.leadTicks
    check recorded["upUm"].getInt == int(DefaultBaselineParams.upUm)
    check recorded["idleUm"].getInt == int(DefaultBaselineParams.idleUm)

  test "the swept values are inside their legal ranges":
    check DefaultBaselineParams.leadTicks >= 0
    check DefaultBaselineParams.leadTicks <= 24
    check DefaultBaselineParams.upUm >= 0
    check DefaultBaselineParams.upUm <= Stroke
    check DefaultBaselineParams.idleUm >= 0
    check DefaultBaselineParams.idleUm <= Stroke
