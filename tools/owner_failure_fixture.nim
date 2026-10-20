## Real owned listener/initialization and loop I/O failures; no simulation edits.
import std/[json, monotimes, os, strutils, times]
import bitworld/[native_stop, runtime]
import pistonball/[server, sim, replays]

when isMainModule:
  installNativeStopHandlers()
  let args = commandLineParams()
  doAssert args.len in [2, 3]
  var config = defaultGameConfig()
  config.seed = 1
  config.minPlayers = 0
  config.startWaitTicks = 0
  config.minBatchSpacingMs = 0
  var loadPath = ""
  let path = case args[0]
    of "initialization": "/proc/PRIVATE_OWNER_FAILURE_SENTINEL/replay"
    of "loop": "/dev/full"
    of "replay":
      doAssert args.len == 3
      loadPath = args[2]
      var writer = openReplayWriter(loadPath, "{\"PRIVATE_OWNER_FAILURE_SENTINEL\"")
      writer.closeReplayWriter()
      ""
    else: raise newException(ValueError, "unknown owner failure fixture")
  runServerLoop("127.0.0.1", parseInt(args[1]), config, path, loadPath,
    RuntimeConfig(), getMonoTime() + initDuration(seconds = 25), newJArray())
