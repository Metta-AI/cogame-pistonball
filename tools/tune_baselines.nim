## The scripted-baseline grid sweep.
##
## THE THREE TUNABLES ARE SWEPT; THE PHYSICS CONSTANTS ARE NOT. If twenty
## `wavebot`s cannot deliver the ball, these three numbers are wrong, not the
## sim. Run it, read the table, and commit the winning row to
## `tools/ci/baseline_tuning.json` — `tests/test_tuning.nim` re-asserts that
## the shipped `DefaultBaselineParams` still equal it.
##
##   nim c -d:release -r --path:src tools/tune_baselines.nim

import
  std/[strformat, strutils],
  ../src/pistonball/[sim, scripts, control, baselines]

proc playEpisode(seed: int, params: BaselineParams): tuple[
    delivered: bool, scoreMilli: int64, ticks: int] =
  var config = defaultGameConfig()
  config.seed = seed
  config.minPlayers = 1
  config.startWaitTicks = 0
  config.lobbyJoinTimeoutTicks = 1
  config.update("")
  var game = initSimServer(config)
  discard game.addPlayer("sweep", 0, "", trusted = true)
  var commands = newSeq[uint8](game.seatCount())
  while game.phase != GameOver and game.tickCount < config.maxTicks + 8:
    for i in 0 ..< commands.len:
      commands[i] = 127'u8
    for piston in 0 ..< PistonCount:
      let seat = game.seatOfPiston(piston)
      if seat < 0 or seat >= commands.len:
        continue
      commands[seat] = pistonCommand(
        game, wavebotScript(game, piston, params), piston)
    game.step(commands)
  (game.delivered(), game.scoreMilli(), game.tickCount)

when isMainModule:
  const Seeds = 20
  echo "lead up_m idle_m | delivered/", Seeds, " | mean score | mean ticks"
  var best = DefaultBaselineParams
  var bestScore = low(int64)
  for lead in [3, 6, 9, 12]:
    for upUm in [1_200_000'i32, 1_350_000'i32, 1_450_000'i32, 1_600_000'i32]:
      for idleUm in [0'i32, 100_000'i32, 250_000'i32, 400_000'i32]:
        let params = BaselineParams(
          leadTicks: lead, upUm: upUm, idleUm: idleUm)
        var
          delivered = 0
          total = 0'i64
          ticks = 0
        for seed in 1 .. Seeds:
          let outcome = playEpisode(seed * 7919, params)
          if outcome.delivered:
            inc delivered
          total += outcome.scoreMilli
          ticks += outcome.ticks
        let mean = total div Seeds
        echo &"{lead:>4} {upUm:>7} {idleUm:>6} | {delivered:>2}/{Seeds} | " &
          &"{mean.float / 1000.0:>10.3f} | {ticks div Seeds:>6}"
        if mean > bestScore:
          bestScore = mean
          best = params
  echo ""
  echo "pick: leadTicks=", best.leadTicks, " upUm=", best.upUm,
    " idleUm=", best.idleUm, " mean=", bestScore.float / 1000.0
  echo "commit this row to tools/ci/baseline_tuning.json"
