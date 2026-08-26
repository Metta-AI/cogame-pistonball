## THE DETERMINISM GATE. If this fails, the physics or a build flag changed —
## fix the code, never the test.

import
  std/[json, math, os, strutils, unittest],
  ../src/pistonball/[sim, baselines],
  ./helpers

const GuardedSources = [
  "src/pistonball/sim.nim",
  "src/pistonball/bank.nim",
  "src/pistonball/trig.nim",
  "src/pistonball/sim_types.nim",
  "src/pistonball/sim_config.nim",
  "src/pistonball/sim_state.nim"
]

proc mutated_tick(length: int): int =
  ## A tick that is definitely inside PLAY, not the lobby.
  max(1, length * 2 div 3)

suite "determinism":
  test "the same seed and command log reproduce the hash chain, twice":
    let recorded = runScriptedRecording(4417231, [blWavebot])
    let first = replayCommandLog(4417231, recorded.commandLog)
    let second = replayCommandLog(4417231, recorded.commandLog)
    check first.len == recorded.commandLog.len
    check first == second

  test "a one-unit change in any command byte changes the final hash":
    let recorded = runScriptedRecording(4417231, [blWavebot], maxTicks = 450)
    let baseline = replayCommandLog(4417231, recorded.commandLog, 450)
    check baseline.len > 0
    # ONE UNIT, not a nudge: a single command byte moved by 1 is a head
    # velocity moved by 80000/127 = 629 um/tick, and the chain must diverge
    # from that tick on. Swept over three ticks and three seats, mid-play
    # (tick 0 is still the lobby, where no command actuates anything), because
    # "any command byte" is the claim.
    for target in [baseline.len div 3, mutated_tick(baseline.len),
                   baseline.len * 2 div 3]:
      for seat in [0, 7, PistonCount - 1]:
        checkpoint("tick " & $target & " seat " & $seat)
        var mutated = recorded.commandLog
        let byte = mutated[target][seat]
        mutated[target][seat] =
          if byte < 254'u8: byte + 1'u8 else: byte - 1'u8
        let after = replayCommandLog(4417231, mutated, 450)
        var diverged = false
        for tick in target ..< min(after.len, baseline.len):
          if after[tick] != baseline[tick]:
            diverged = true
            break
        check diverged

  test "the committed golden fixture still holds":
    # METRONOME, not wavebot: a blind ripple never delivers, so it runs the
    # full 1800 ticks and the fixture pins a hash every 50 ticks across the
    # WHOLE episode instead of the four seconds a textbook wave takes.
    let path = currentSourcePath().parentDir() / "data" / "golden_hashes.json"
    let recorded = runScriptedRecording(4417231, [blMetronome])
    let chain = replayCommandLog(4417231, recorded.commandLog)
    var produced = newJObject()
    var every50 = newJArray()
    for i, hash in chain:
      if (i + 1) mod 50 == 0:
        every50.add(%($hash))
    produced["seed"] = %4417231
    produced["ticks"] = %chain.len
    produced["every50"] = every50
    if not fileExists(path):
      # First run in a fresh checkout writes the fixture so the diff is
      # reviewable; CI always has it committed.
      createDir(path.parentDir())
      writeFile(path, produced.pretty & "\n")
      echo "wrote golden fixture: ", path
    let golden = parseJson(readFile(path))
    check golden["seed"].getInt == 4417231
    check golden["ticks"].getInt == chain.len
    check golden["every50"] == produced["every50"]

  test "the sim sources contain no floating point at all":
    let root = currentSourcePath().parentDir().parentDir()
    # Hand-rolled rather than std/re: the guard must run wherever the tests
    # run, and pulling libpcre in as a RUNTIME dependency of the determinism
    # gate would make the gate itself the flaky thing.
    const Calls = ["sin", "cos", "tan", "arctan", "arcsin", "arccos", "exp",
                   "ln", "log10", "log2", "pow", "sqrt", "hypot", "floor",
                   "ceil", "round"]
    const Types = ["float", "float32", "float64"]
    proc isWordChar(ch: char): bool =
      ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}
    proc hit(text, needle: string, mustCall: bool): bool =
      var start = 0
      while true:
        let at = text.find(needle, start)
        if at < 0:
          return false
        start = at + 1
        if at > 0 and isWordChar(text[at - 1]):
          continue                     # isqrt, tanMag, spin, PistonCount…
        let after = at + needle.len
        if mustCall:
          var probe = after
          while probe < text.len and text[probe] == ' ':
            inc probe
          if probe < text.len and text[probe] == '(':
            return true
        else:
          if after >= text.len or not isWordChar(text[after]):
            return true
    for relative in GuardedSources:
      let source = readFile(root / relative)
      var line = 0
      for text in source.splitLines():
        inc line
        for needle in Calls:
          if hit(text, needle, true):
            checkpoint(relative & ":" & $line & ": " & text)
            fail()
        for needle in Types:
          if hit(text, needle, false):
            checkpoint(relative & ":" & $line & ": " & text)
            fail()
    # And no build script may hand the compiler -ffast-math.
    for script in ["Dockerfile", "Dockerfile.replay-viewer",
                   "replay-viewer/config.nims"]:
      check "-ffast-math" notin readFile(root / script)

  test "SinQ12 re-derives from the standard library, entry by entry":
    for k in 0 ..< TrigSteps:
      let exact = sin(2.0 * PI * float(k) / float(TrigSteps)) * float(TrigOne)
      let expected =
        if exact >= 0: int(floor(exact + 0.5)) else: -int(floor(-exact + 0.5))
      check int(SinQ12[k]) == expected

  test "isqrt is exact below 2^16 and on perfect squares to 2^40":
    for v in 0 .. 65_535:
      let root = isqrt(int64(v))
      check root * root <= int64(v)
      check (root + 1) * (root + 1) > int64(v)
    var n = 1'i64
    while n * n <= (1'i64 shl 40):
      check isqrt(n * n) == n
      check isqrt(n * n - 1) == n - 1
      n = n * 3 div 2 + 1

  test "perm and the rest heights are a pure function of the seed":
    let a = initSimServer(testConfig(777))
    let b = initSimServer(testConfig(777))
    check a.perm == b.perm
    check a.restHeights == b.restHeights
    check a.permDigest == b.permDigest
    let c = initSimServer(testConfig(778))
    check c.perm != a.perm or c.restHeights != a.restHeights
