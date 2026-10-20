import
  std/[json, math, monotimes, os, strutils, sysrand, times],
  bitworld/[runtime, runtime_input, native_http, native_stop, decision_trajectory],
  pistonball/sim,
  pistonball/server,
  pistonball/training_capture

const LegacyFixedSeed* = 4417231
  ## The compiled-in default seed. A config carrying it (or no seed at all)
  ## gets a FRESH random seed: with a public fixed seed the seat -> piston
  ## permutation and the twenty opening rest heights would be pre-computable
  ## by an entrant, which is exactly what the seeded shuffle exists to stop.
  ##
  ## The certification fixture carries exactly this value, and that is the
  ## point rather than a collision: `coworld_manifest_template.json` is a
  ## PUBLIC document, so a seed pinned there is a seed every entrant can read,
  ## and the sentinel is what turns it back into "randomise me". Certification
  ## therefore runs on a fresh seed every time; it asserts an outcome
  ## (twenty seats, a full-length episode, `reason=complete`) that holds for
  ## every seed, not one recorded hash chain. A forensic re-run that really
  ## does need one episode back names any OTHER seed and gets it honoured.

proc seedPinned*(configJson: string): bool =
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

proc stripUnpinnedSeed*(configJson: string): string =
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
  installNativeStopHandlers()
  let processStarted = getMonoTime()
  var episodeDeadline = processStarted + initDuration(seconds = 1200)
  var inputControl: NativeRequestControl
  var inputCaptures: seq[RuntimeInputCapture]
  var runtimeConfig: RuntimeConfig
  try:
    let timeout = parseFloat(getEnv("COWORLD_TIMEOUT_SECONDS", "1200"))
    if classify(timeout) in {fcNan, fcInf, fcNegInf} or timeout <= 0:
      raise newException(PistonballError, "episode timeout must be finite and positive")
    episodeDeadline = processStarted + initDuration(nanoseconds = int64(timeout * 1_000_000_000))
    let inputDeadline = min(episodeDeadline - initDuration(seconds = 5),
      processStarted + initDuration(seconds = 60))
    proc input(value, source: string): string =
      readRuntimeInput(value, source, inputDeadline, inputControl,
        16 * 1024 * 1024, 64 * 1024, inputCaptures)
    runtimeConfig = readRuntimeConfig(input)
  except CatchableError as error:
    let status = if interruptionRequested(): esTruncated else: esFailed
    writeInitializationCheckpoint(status, "runtime_config", $error.name, error.msg,
      episodeDeadline, runtimeInputCapturesJson(inputCaptures))
    if status == esTruncated: quit(0)
    quit("pistonball: runtime configuration rejected (" & $error.name & ")", 1)
  if interruptionRequested():
    writeInitializationCheckpoint(esTruncated, "runtime_config", "stop_requested",
      "process stop requested", episodeDeadline, runtimeInputCapturesJson(inputCaptures))
    quit(0)
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
    writeInitializationCheckpoint(esFailed, "game_config", $error.name, error.msg,
      episodeDeadline, runtimeInputCapturesJson(inputCaptures))
    quit("pistonball: game configuration rejected (" & $error.name & ")", 1)

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
    runtimeConfig,
    episodeDeadline,
    runtimeInputCapturesJson(inputCaptures)
  )
