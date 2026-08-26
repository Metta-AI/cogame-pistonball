## 1800 ticks of physics plus 36 000 controller evaluations, bounded.

import
  std/[times, unittest],
  ../src/pistonball/[sim, baselines],
  ./helpers

suite "performance":
  test "a full episode simulates well inside the frame budget":
    let started = epochTime()
    let game = runScripted(4417231, [blWavebot])
    let elapsed = epochTime() - started
    echo "1800-tick episode + 36000 controller evaluations: ",
      (elapsed * 1000.0).int, " ms"
    check game.tickCount > 0
    check elapsed < 60.0
