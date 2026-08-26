import
  std/[json, os, sysrand],
  bitworld/runtime,
  pistonball/sim,
  pistonball/server

const LegacyFixedSeed = 4417231
  ## The compiled-in default seed. A config carrying it (or no seed at all)
  ## gets a FRESH random seed: with a public fixed seed the seat -> piston
  ## permutation and the twenty opening rest heights would be pre-computable
  ## by an entrant, which is exactly what the seeded shuffle exists to stop.

proc seedPinned(configJson: string): bool =
  ## True when the runtime config explicitly pins a seed other than the
  ## default sentinel (fixture recordings, forensic re-runs, certification).
  if configJson.len == 0:
    return false
  try:
    let node = parseJson(configJson)
    node.kind == JObject and node.hasKey("seed") and
      node["seed"].getInt != LegacyFixedSeed
  except CatchableError:
    false  # config.update reports the real parse error.

proc randomSeed(): int =
  ## A crypto-random 31-bit seed from the OS.
  var buf: array[4, byte]
  if not urandom(buf):
    raise newException(PistonballError, "OS entropy source unavailable")
  (int(buf[0]) shl 24 or int(buf[1]) shl 16 or
    int(buf[2]) shl 8 or int(buf[3])) and 0x7FFF_FFFF

proc stripUnpinnedSeed(configJson: string): string =
  ## Drops the sentinel seed from an unpinned config so it cannot clobber the
  ## randomized seed injected before `config.update`.
  if configJson.len == 0:
    return configJson
  try:
    let node = parseJson(configJson)
    if node.kind == JObject and node.hasKey("seed"):
      node.delete("seed")
    $node
  except CatchableError:
    configJson

when isMainModule:
  let runtimeConfig =
    try:
      readRuntimeConfig()
    except CatchableError as error:
      # A clean message and a non-zero exit, never a traceback: the runner
      # reports this verbatim.
      quit("pistonball: bad runtime configuration: " & error.msg, 1)
  let localReplayPath =
    if runtimeConfig.replayUri.len > 0:
      getTempDir() / ("pistonball-replay-" & $getCurrentProcessId() & ".replay")
    else:
      ""

  var config = defaultGameConfig()
  try:
    if seedPinned(runtimeConfig.config):
      config.update(runtimeConfig.config)
    else:
      ## Randomize BEFORE parsing: `config.update` is where the seed-derived
      ## draws are resolved, so the randomized seed must already be in place.
      config.seed = randomSeed()
      config.update(stripUnpinnedSeed(runtimeConfig.config))
      echo "seed not pinned; randomized"
  except CatchableError as error:
    quit("pistonball: " & error.msg, 1)

  echo "pistonball config: host=", runtimeConfig.host,
    " port=", runtimeConfig.port,
    " seed=", config.seed,
    " num_agents=", config.numAgents,
    " maxTicks=", config.maxTicks,
    " turnTicks=", config.turnTicks,
    " wallClockBudgetSeconds=", config.wallClockBudgetSeconds,
    " fastMode=", config.fastMode

  let loadReplayPath =
    if runtimeConfig.replayMode:
      let path = getTempDir() / ("pistonball-load-replay-" &
        $getCurrentProcessId() & ".replay")
      writeFile(path, runtimeConfig.replay)
      path
    else:
      ""

  echo "starting pistonball on ", runtimeConfig.host, ":", runtimeConfig.port
  runServerLoop(
    runtimeConfig.host,
    runtimeConfig.port,
    config,
    localReplayPath,
    loadReplayPath,
    runtimeConfig
  )
