## 1800 ticks of physics plus 36 000 controller evaluations, bounded.
##
## METRONOME, not wavebot: a blind ripple never delivers, so the episode runs
## the whole 1800-tick budget. Twenty wavebots deliver in about 120 ticks, and
## timing those while printing "1800-tick episode" measures a fifteenth of the
## work the label claims.

import
  std/[times, unittest],
  ../src/pistonball/[sim, baselines],
  ./helpers

suite "performance":
  test "a full episode simulates well inside the frame budget":
    let started = epochTime()
    let game = runScripted(4417231, [blMetronome])
    let elapsed = epochTime() - started
    echo "1800-tick episode + 36000 controller evaluations: ",
      (elapsed * 1000.0).int, " ms"
    # The label is now an assertion: 1800 ticks x 20 pistons of controller.
    check game.tickCount == 1800
    check not game.delivered()
    check elapsed < 60.0
