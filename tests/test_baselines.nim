## The bounded-orders / legality assertion on the scripted baselines, and the
## anti-regression pin for the whole physics tuning.
##
## If the delivery pin fails, the THREE BaselineParams numbers are wrong —
## re-run tools/tune_baselines.nim and commit the sweep's pick to
## tools/ci/baseline_tuning.json. THE PHYSICS CONSTANTS DO NOT MOVE.

import
  std/[random, strformat, unicode, unittest],
  ../src/pistonball/[sim, scripts, control, baselines],
  ./helpers

suite "scripted baselines":
  test "500 random states x both baselines emit a LEGAL script":
    var rng = initRand(8675309)
    var game = seatedSim(testConfig())
    for _ in 0 ..< 500:
      game.scrambleState(rng)
      for kind in [blWavebot, blMetronome]:
        let piston = rng.rand(PistonCount - 1)
        let script = scriptedScript(game, kind, piston)
        check validScript(script)
        check script.note.runeLen <= MaxNoteRunes
        check script.say.runeLen <= MaxSayRunes
        check script.mode in {modeWave, modeLift, modeDrop, modeHold,
                              modeCatch, modeRipple}
        check script.blind in {blindHold, blindIdle, blindRipple}
        let command = pistonCommand(game, script, piston)
        check command <= 254'u8

  test "an unknown baseline name is wavebot, which is also the default":
    check parseBaseline("") == blWavebot
    check parseBaseline("nonsense") == blWavebot
    check parseBaseline("METRONOME") == blMetronome
    check parseBaseline(" wavebot ") == blWavebot

  test "twenty wavebots deliver, and beat twenty metronomes":
    var
      delivered = 0
      total = 0'i64
      mixed = 0
      metronomeTotal = 0'i64
    const Seeds = 20
    for i in 1 .. Seeds:
      let seed = i * 7919
      let wave = runScripted(seed, [blWavebot])
      if wave.delivered():
        inc delivered
      total += wave.scoreMilli()
      let metronome = runScripted(seed, [blMetronome])
      metronomeTotal += metronome.scoreMilli()
      let blend = runScripted(seed, [blWavebot, blMetronome])
      if blend.delivered():
        inc mixed
    let
      waveMean = total.float / (1000.0 * Seeds.float)
      metronomeMean = metronomeTotal.float / (1000.0 * Seeds.float)
    echo &"wavebot: {delivered}/{Seeds} delivered, mean {waveMean:.3f}"
    echo &"metronome: mean {metronomeMean:.3f}"
    echo &"10/10 mix: {mixed}/{Seeds} delivered"
    check delivered >= 18
    check waveMean > 60.0
    check metronomeMean < waveMean
    check mixed >= 12
