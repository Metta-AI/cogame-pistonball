## The replay codec wrapper: keyframes, the incremental precompute scan, lull
## spans, story beats, seek/speed/transport commands and the per-tick hash
## check.
##
## The replay is the starter's BINARY format with pistonball's magic
## (`COWLDPST`). The static wasm viewer parses exactly this format, and a JSON
## replay would mean rewriting this file, `replay_runtime.nim`,
## `static_replay_worker.js` and the whole seek/keyframe machinery.
##
## Two named edits from the starter's copy: `serializeReplaySim` /
## `deserializeReplaySim` cover pistonball's sim fields (the ball pose, the
## twenty heights and achieved velocities, the accumulators and the per-piston
## counters), and the magic/game name/version are pistonball's.

import
  std/json,
  flatty,
  bitworld/replays as replayCodec,
  ./sim, ./broadcast

export replayCodec
export PlaybackSpeeds

const
  ReplayKeyframeTicks* = 100
  ReplayEndHoldSeconds* = 10
    ## How long a looping replay holds on its final game-over frame (real
    ## seconds) before restarting, so the end segment is readable instead of
    ## flashing for one frame.
  LullLeadTicks* = 2 * ReplayFps
  MinLullTicks* = 6 * ReplayFps
  LullSpeedBoost* = 8
  MaxLullTicksPerFrame* = 64
  SeekTicksPerFrame* = 240
    ## Per-frame cap on the re-simulation a SEEK may do (10 s of sim time), so
    ## a scrub past the keyframed prefix converges a slice per frame instead
    ## of stalling the viewer for seconds.
  PistonballReplayMagic* = "COWLDPST"
  PistonballReplayFormatVersion = 1'u16
  PistonballReplaySpec* = ReplaySpec(
    magic: PistonballReplayMagic,
    formatVersion: PistonballReplayFormatVersion,
    gameName: GameName,
    gameVersion: GameVersion,
    joinKind: rjkNameSlotToken,
    allowChat: true,
    allowCompressed: true,
    hashOrder: rhoStop
  )

type
  ReplayKeyframe* = object
    tick*: int
    simBytes*: string
    joinIndex*, leaveIndex*, chatIndex*, inputIndex*, hashIndex*: int
    masks*: seq[uint8]
    hashValidationFailed*: bool
    hashMismatchTick*: int

  ReplayScan* = ref object
    ## The in-flight whole-match precompute walk: a second sim + player
    ## stepped from tick 0 that derives keyframes, the journey series, the
    ## story beats and the lull spans without touching the on-screen playback
    ## state.
    sim: SimServer
    builder: ReplayPlayer
    beatTracker: BroadcastTracker
    beatTicks: seq[int]
    lastLead: int
    interval: int
    maxTick: int

  ReplayPlayer* = object
    data*: ReplayData
    joinIndex*, leaveIndex*, chatIndex*, inputIndex*, hashIndex*: int
    masks*: seq[uint8]
    playing*, looping*: bool
    speedIndex*: int
    mismatchQuit*: bool
    hashValidationFailed*: bool
    hashMismatchTick*: int
    keyframes*: seq[ReplayKeyframe]
    startTick*: int
    leadSeries*: seq[seq[int]]
      ## [tick, progressPermille] change-points across the WHOLE match,
      ## precomputed on the deterministic keyframe walk so the momentum graph
      ## draws its full-timeline shape at once instead of accumulating.
    endHoldFrames*: int
    pendingSeekTick*: int
    skipLulls*: bool
    lullSpans*: seq[array[2, int]]
    beatEvents*: JsonNode
    scan: ReplayScan
    scanDone: bool

proc tickTime*(tick: int): uint32 =
  ## A simulation tick as replay milliseconds.
  replayCodec.tickTime(tick, ReplayFps)

proc writeInputMaskChange*(
  replayWriter: var ReplayWriter, time: uint32, seat: int, command: uint8
) =
  ## Writes one replay input record when a SEAT's command byte changes.
  ##
  ## Lives here rather than in `server.nim` because the command log IS the
  ## replay's action stream: the test that proves the recorded bytes
  ## re-simulate to the identical hash chain has to write it exactly the way
  ## the server does, and two copies of this would be two chances to drift.
  ##
  ## The starter's press/release wrapper (`writeInputFrameMasks`) is DELETED,
  ## not ported: its repeated-press logic is BUTTON semantics and would
  ## corrupt a value byte.
  if seat < 0 or seat >= replayWriter.lastMasks.len:
    return
  if replayWriter.lastMasks[seat] == command:
    return
  replayWriter.writeInput(ReplayInput(
    time: time, player: uint8(seat), keys: command))
  replayWriter.lastMasks[seat] = command

proc openReplayWriter*(path, configJson: string): ReplayWriter =
  replayCodec.openReplayWriter(path, configJson, PistonballReplaySpec)

proc parseReplayBytes*(bytes: string): ReplayData =
  replayCodec.parseReplayBytes(bytes, PistonballReplaySpec)

proc loadReplay*(path: string): ReplayData =
  replayCodec.loadReplay(path, PistonballReplaySpec)

proc serializeReplaySim*(sim: SimServer): string =
  ## Serializes one simulation state for a replay keyframe. Pistonball's board
  ## is a fixed geometry table with no baked map, so — unlike the starter —
  ## nothing has to be set aside first: the whole sim is a few kilobytes.
  ## The static geometry and `perm` are already in the config JSON.
  sim.toFlatty()

proc deserializeReplaySim*(bytes: string): SimServer =
  bytes.fromFlatty(SimServer)

proc initReplayPlayer*(data: ReplayData): ReplayPlayer =
  result.data = data
  result.masks = @[]
  result.playing = true
  result.looping = true
  result.speedIndex = 0
  result.skipLulls = true
  result.hashMismatchTick = -1
  result.pendingSeekTick = -1
  result.startTick = -1

proc replaySpeed*(replay: ReplayPlayer): int =
  PlaybackSpeeds[clamp(replay.speedIndex, 0, PlaybackSpeeds.high)]

proc replayMaxTick*(replay: ReplayPlayer): int =
  if replay.data.hashes.len == 0:
    return 0
  int(replay.data.hashes[^1].tick)

proc replayStartTick*(replay: ReplayPlayer): int =
  ## The first tick a spectator should watch: the moment the match leaves the
  ## lobby (never negative, never past the end).
  clamp(max(0, replay.startTick), 0, replay.replayMaxTick())

proc resetReplay*(replay: var ReplayPlayer) =
  replay.joinIndex = 0
  replay.leaveIndex = 0
  replay.chatIndex = 0
  replay.inputIndex = 0
  replay.hashIndex = 0
  replay.hashValidationFailed = false
  replay.hashMismatchTick = -1
  replay.masks = @[]

proc saveReplayKeyframe(
  replay: ReplayPlayer, sim: SimServer
): ReplayKeyframe =
  ReplayKeyframe(
    tick: sim.tickCount,
    simBytes: serializeReplaySim(sim),
    joinIndex: replay.joinIndex,
    leaveIndex: replay.leaveIndex,
    chatIndex: replay.chatIndex,
    inputIndex: replay.inputIndex,
    hashIndex: replay.hashIndex,
    masks: replay.masks,
    hashValidationFailed: replay.hashValidationFailed,
    hashMismatchTick: replay.hashMismatchTick
  )

proc restoreReplayKeyframe(
  replay: var ReplayPlayer, sim: var SimServer, keyframe: ReplayKeyframe
) =
  let logging = sim.gameEventLoggingEnabled
  var restored = deserializeReplaySim(keyframe.simBytes)
  restored.gameEventLoggingEnabled = logging
  sim = move(restored)
  replay.joinIndex = keyframe.joinIndex
  replay.leaveIndex = keyframe.leaveIndex
  replay.chatIndex = keyframe.chatIndex
  replay.inputIndex = keyframe.inputIndex
  replay.hashIndex = keyframe.hashIndex
  replay.masks = keyframe.masks
  replay.hashValidationFailed = keyframe.hashValidationFailed
  replay.hashMismatchTick = keyframe.hashMismatchTick

proc replayKeyframeIndex(replay: ReplayPlayer, tick: int): int =
  for i, keyframe in replay.keyframes:
    if keyframe.tick > tick:
      break
    result = i

proc ensureReplaySeat(replay: var ReplayPlayer, seat: int) =
  while replay.masks.len <= seat:
    replay.masks.add(127'u8)   ## an unseen seat HOLDS, it does not slam down.

proc applyReplayEvents(replay: var ReplayPlayer, sim: var SimServer) =
  ## Applies this tick's recorded joins, leaves, command bytes and chat.
  let time = tickTime(sim.tickCount)
  while replay.leaveIndex < replay.data.leaves.len and
      replay.data.leaves[replay.leaveIndex].time <= time:
    let leave = replay.data.leaves[replay.leaveIndex]
    if int(leave.player) < 0 or int(leave.player) >= sim.players.len:
      raise newException(ReplayError, "Replay player leave is invalid")
    sim.removePlayerAt(int(leave.player))
    ## A leave does NOT shift the command arrays: the pistons are fixed for
    ## the whole episode and the recorded bytes are indexed BY SEAT, so
    ## deleting a row would silently re-point every later byte at the wrong
    ## piston for the rest of playback.
    inc replay.leaveIndex

  while replay.joinIndex < replay.data.joins.len and
      replay.data.joins[replay.joinIndex].time <= time:
    let join = replay.data.joins[replay.joinIndex]
    if int(join.player) != sim.players.len:
      raise newException(ReplayError, "Replay player join order is invalid")
    discard sim.addPlayer(join.name, join.slot, join.token, trusted = true)
    replay.ensureReplaySeat(int(join.player))
    inc replay.joinIndex

  while replay.inputIndex < replay.data.inputs.len and
      replay.data.inputs[replay.inputIndex].time <= time:
    let input = replay.data.inputs[replay.inputIndex]
    replay.ensureReplaySeat(int(input.player))
    replay.masks[int(input.player)] = input.keys
    inc replay.inputIndex

  while replay.chatIndex < replay.data.chats.len and
      replay.data.chats[replay.chatIndex].time <= time:
    let chat = replay.data.chats[replay.chatIndex]
    ## Pistonball CONTROL records (register / script / fallback /
    ## budget_guard / result) ride the chat stream as JSON objects and are NOT
    ## in-game speech: the live server never applied them as state either, so
    ## applying them here would move the hash chain.
    if chat.message.len > 0 and chat.message[0] == '{':
      sim.pushFeedScript(chat.message)
      try:
        let node = parseJson(chat.message)
        if node{"k"}.getStr() == "script":
          let
            piston = node{"piston"}.getInt(-1)
            say = node{"say"}.getStr()
          if piston >= 0 and say.len > 0:
            sim.holdSay(piston, say, sim.tickCount + 60)
      except CatchableError:
        discard
    inc replay.chatIndex

proc replayCommands(replay: var ReplayPlayer, seats: int): seq[uint8] =
  result = newSeq[uint8](seats)
  for seat in 0 ..< seats:
    replay.ensureReplaySeat(seat)
    result[seat] = replay.masks[seat]

proc checkReplayHash(replay: var ReplayPlayer, sim: SimServer) =
  ## Checks the recorded hash for the current tick. ONE divergent bit is
  ## caught at the tick it happens and surfaced as `mismatchTick`.
  if replay.hashValidationFailed:
    if sim.tickCount >= replay.replayMaxTick():
      replay.playing = false
    return
  if replay.hashIndex >= replay.data.hashes.len:
    replay.playing = false
    return
  let expected = replay.data.hashes[replay.hashIndex]
  if int(expected.tick) < sim.tickCount:
    let message = "Replay hash tick is missing at tick " & $sim.tickCount & "."
    if replay.mismatchQuit:
      raise newException(ReplayError, message)
    echo message
    replay.hashValidationFailed = true
    replay.hashMismatchTick = sim.tickCount
    return
  if int(expected.tick) > sim.tickCount:
    return
  let hash = sim.gameHash()
  if hash != expected.hash:
    let message =
      "Replay hash mismatch at tick " & $sim.tickCount &
        "; expected " & $expected.hash & ", got " & $hash & "."
    if replay.mismatchQuit:
      raise newException(ReplayError, message)
    echo message
    replay.hashValidationFailed = true
    replay.hashMismatchTick = sim.tickCount
    return
  inc replay.hashIndex

proc stepReplay*(replay: var ReplayPlayer, sim: var SimServer) =
  ## Advances replay by one simulation tick, from the RECORDED command bytes.
  replay.applyReplayEvents(sim)
  let commands = replay.replayCommands(max(sim.players.len, sim.seatCount()))
  sim.step(commands)
  replay.checkReplayHash(sim)

proc buildLullSpans*(
  beatTicks: seq[int], startTick, maxTick: int
): seq[array[2, int]] =
  ## The quiet spans between beats, keeping `LullLeadTicks` of context on both
  ## sides and dropping spans shorter than `MinLullTicks`: skipping a short
  ## breather is more jarring than watching it.
  var prevBeat = startTick
  for i in 0 .. beatTicks.len:
    let nextBeat =
      if i < beatTicks.len: beatTicks[i]
      else: maxTick + LullLeadTicks + 1
    let
      a = prevBeat + LullLeadTicks + 1
      b = min(nextBeat - LullLeadTicks - 1, maxTick)
    if b - a + 1 >= MinLullTicks:
      result.add([a, b])
    if i < beatTicks.len:
      prevBeat = nextBeat

proc journeyLead(sim: SimServer): int =
  ## The momentum series' metric: how far along the journey the ball is, in
  ## permille. Repurposes the starter's per-team lead series to the ONE curve
  ## a cooperative game has.
  let travelled = int64(BallStartX) - int64(sim.ballX)
  int((travelled * 1000) div int64(TravelDistance))

proc scanComplete*(replay: ReplayPlayer): bool =
  ## True once the precompute walk has finished: `leadSeries`, `beatEvents`
  ## and `lullSpans` hold the whole match and the lead chrome may ship.
  replay.scanDone

proc advanceReplayScan*(replay: var ReplayPlayer, maxTicks: int)

proc initReplayScan*(
  replay: var ReplayPlayer, initialSim: SimServer,
  interval = ReplayKeyframeTicks
) =
  ## Starts the whole-match precompute walk. It advances via
  ## `advanceReplayScan` — a bounded slice per presentation frame in the
  ## hosted viewer — so the first pixel is not held hostage to it.
  replay.keyframes = @[]
  replay.leadSeries = @[]
  replay.lullSpans = @[]
  replay.beatEvents = newJArray()
  replay.scanDone = false
  var scan = ReplayScan(interval: max(interval, 1))
  scan.sim = initialSim
  scan.sim.gameEventLoggingEnabled = false
  scan.builder = initReplayPlayer(replay.data)
  scan.builder.looping = false
  scan.builder.mismatchQuit = replay.mismatchQuit
  scan.maxTick = scan.builder.replayMaxTick()
  replay.keyframes.add(scan.builder.saveReplayKeyframe(scan.sim))
  scan.lastLead = journeyLead(scan.sim)
  replay.leadSeries.add(@[scan.sim.tickCount, scan.lastLead])
  scan.beatTracker = initBroadcastTracker()
  scan.beatTracker.resync(scan.sim)
  replay.startTick =
    if scan.sim.phase == Playing: scan.sim.gameStartTick else: -1
  replay.scan = scan
  ## An empty recording has nothing to walk: finalize immediately rather than
  ## spending a frame in a fictitious in-flight state.
  replay.advanceReplayScan(0)

proc advanceReplayScan*(replay: var ReplayPlayer, maxTicks: int) =
  ## Advances the precompute walk by up to `maxTicks` simulation ticks. No-op
  ## once finished.
  if replay.scan == nil:
    return
  let scan = replay.scan
  var stepsLeft = maxTicks
  while stepsLeft > 0 and scan.builder.playing and
      scan.sim.tickCount < scan.maxTick:
    try:
      scan.builder.stepReplay(scan.sim)
    except CatchableError as error:
      ## A malformed record would otherwise re-raise from this same tick on
      ## every subsequent frame — the walk's cursor cannot advance past it.
      ## With `mismatchQuit` the raise is the diagnostic mode's whole point,
      ## so it propagates; otherwise finalize on the walked prefix and let the
      ## DISPLAY path surface the same defect when playback reaches that tick.
      if replay.mismatchQuit:
        raise
      echo "replay scan stopped at tick ", scan.sim.tickCount, ": ", error.msg
      scan.builder.playing = false
      break
    if replay.startTick < 0 and scan.sim.phase == Playing:
      replay.startTick = scan.sim.gameStartTick
    let lead = journeyLead(scan.sim)
    if lead != scan.lastLead:
      replay.leadSeries.add(@[scan.sim.tickCount, lead])
      scan.lastLead = lead
    var stepBeats = newJArray()
    scan.sim.stepEvents(scan.beatTracker, stepBeats)
    for event in stepBeats:
      let kind = event{"k"}.getStr()
      ## The scrubber's up-front timeline. `handoff` is NOT a beat: it fires
      ## up to twenty times and would bury the scrubber.
      if kind == "bounce_back" or kind == "stall" or kind == "delivered" or
          kind == "gameover" or (kind == "launch" and event{"beat"}.getBool()):
        replay.beatEvents.add(event)
      if kind != "say" and kind != "handoff":
        if scan.beatTicks.len == 0 or scan.beatTicks[^1] != scan.sim.tickCount:
          scan.beatTicks.add(scan.sim.tickCount)
    if scan.sim.tickCount mod scan.interval == 0 or
        scan.sim.tickCount == scan.maxTick:
      replay.keyframes.add(scan.builder.saveReplayKeyframe(scan.sim))
    dec stepsLeft
  if scan.builder.playing and scan.sim.tickCount < scan.maxTick:
    return                              # more slices to come.
  if replay.leadSeries.len == 0 or
      replay.leadSeries[^1][0] != scan.sim.tickCount:
    replay.leadSeries.add(@[scan.sim.tickCount, scan.lastLead])
  replay.lullSpans = buildLullSpans(
    scan.beatTicks, replay.replayStartTick(), scan.maxTick)
  replay.scan = nil
  replay.scanDone = true

proc replayScanTicksPerFrame*(sim: SimServer): int =
  ## Deterministic scan slice per presentation frame (frame-counted, no clock
  ## reads — machine speed must not change what any frame contains).
  96

proc buildReplayKeyframes*(
  replay: var ReplayPlayer, initialSim: SimServer,
  interval = ReplayKeyframeTicks
) =
  ## Runs the whole precompute walk synchronously (tests and offline tools).
  replay.initReplayScan(initialSim, interval)
  replay.advanceReplayScan(int.high)

proc isLullTick*(replay: ReplayPlayer, tick: int): bool =
  for span in replay.lullSpans:
    if tick < span[0]:
      return false
    if tick <= span[1]:
      return true
  false

proc replayStepBudget*(replay: ReplayPlayer, tick: int): int =
  let speed = replay.replaySpeed()
  if replay.skipLulls and replay.isLullTick(tick):
    return min(speed * LullSpeedBoost, MaxLullTicksPerFrame)
  speed

proc seekReplay*(replay: var ReplayPlayer, sim: var SimServer, tick: int) =
  ## Seeks playback to a target tick, synchronously.
  if replay.keyframes.len > 0:
    replay.restoreReplayKeyframe(
      sim, replay.keyframes[replay.replayKeyframeIndex(tick)])
  else:
    let logging = sim.gameEventLoggingEnabled
    sim = initSimServer(sim.config)
    sim.gameEventLoggingEnabled = logging
    replay.resetReplay()
  while sim.tickCount < tick and replay.hashIndex < replay.data.hashes.len:
    replay.stepReplay(sim)

proc convergeSeek*(replay: var ReplayPlayer, sim: var SimServer): bool =
  ## Walks a pending seek up to `SeekTicksPerFrame` ticks closer to its
  ## target. Returns true when it moved the sim.
  if replay.pendingSeekTick < 0:
    return false
  var stepped = 0
  while sim.tickCount < replay.pendingSeekTick and
      replay.hashIndex < replay.data.hashes.len and
      stepped < SeekTicksPerFrame:
    replay.stepReplay(sim)
    inc stepped
  if sim.tickCount >= replay.pendingSeekTick or
      replay.hashIndex >= replay.data.hashes.len:
    replay.pendingSeekTick = -1
  stepped > 0

proc beginSeek*(replay: var ReplayPlayer, sim: var SimServer, tick: int) =
  ## Starts a BOUNDED seek: land on the newest keyframe at or before `tick`
  ## (instant, which is what makes a scrubber click visible in the very next
  ## frame) and record the target; convergence happens a slice per frame.
  let target = clamp(tick, replay.replayStartTick(), replay.replayMaxTick())
  if replay.keyframes.len > 0:
    replay.restoreReplayKeyframe(
      sim, replay.keyframes[replay.replayKeyframeIndex(target)])
  else:
    let logging = sim.gameEventLoggingEnabled
    sim = initSimServer(sim.config)
    sim.gameEventLoggingEnabled = logging
    replay.resetReplay()
  replay.pendingSeekTick = target

proc applyReplaySeek*(
  replay: var ReplayPlayer, sim: var SimServer, tick: int
) =
  replay.playing = false
  replay.beginSeek(sim, tick)

proc applySpeedCommand*(speedIndex: var int, command: char) =
  case command
  of '+', '=': speedIndex = min(speedIndex + 1, PlaybackSpeeds.high)
  of '-', '_': speedIndex = max(speedIndex - 1, 0)
  of '1': speedIndex = 0
  of '2': speedIndex = 1
  of '3': speedIndex = 2
  of '4': speedIndex = 3
  of '8': speedIndex = 4
  of '6': speedIndex = 5
  else: discard

proc cancelEndHold*(replay: var ReplayPlayer) =
  ## Cancels the end-of-replay hold. Callers cancel after any manual seek — a
  ## scrub off the final frame leaves the end segment.
  replay.endHoldFrames = 0

proc applyReplayCommand*(
  replay: var ReplayPlayer, sim: var SimServer, command: char
) =
  case command
  of ' ': replay.playing = not replay.playing
  of 'p': replay.playing = true
  of 'P': replay.playing = false
  of '+', '=', '-', '_', '1', '2', '3', '4', '8', '6':
    applySpeedCommand(replay.speedIndex, command)
  of ',', '<':
    replay.playing = false
    replay.pendingSeekTick = -1
    replay.seekReplay(sim, replay.replayStartTick())
  of 'b':
    replay.playing = false
    replay.beginSeek(sim, max(replay.replayStartTick(), sim.tickCount - 1))
  of 'e':
    replay.playing = false
    replay.beginSeek(sim, replay.replayMaxTick())
  of 'r': replay.looping = not replay.looping
  of 'f': replay.skipLulls = not replay.skipLulls
  of '.', '>':
    replay.playing = false
    replay.beginSeek(sim, sim.tickCount + ReplayFps * 5)
  else: discard

proc endHoldSecondsLeft*(replay: ReplayPlayer): int =
  if replay.endHoldFrames <= 0: 0
  else: (replay.endHoldFrames + ReplayFps - 1) div ReplayFps

proc advanceReplayPlayback*(
  replay: var ReplayPlayer,
  sim: var SimServer,
  onStep: proc () {.closure.},
  onJump: proc () {.closure.}
) =
  ## Advances one real-time playback frame. A seek the viewer asked for OWNS
  ## the frame: converging it takes priority over the background precompute
  ## walk and over playback, so the first frame after a click already moves.
  if replay.pendingSeekTick >= 0:
    if replay.convergeSeek(sim):
      onJump()
    return
  replay.advanceReplayScan(sim.replayScanTicksPerFrame())
  if replay.playing and replay.endHoldFrames > 0:
    replay.endHoldFrames = 0
    replay.seekReplay(sim, replay.replayStartTick())
    onJump()
  if replay.playing:
    replay.endHoldFrames = 0
    var stepsTaken = 0
    while replay.playing and
        stepsTaken < replay.replayStepBudget(sim.tickCount):
      replay.stepReplay(sim)
      onStep()
      inc stepsTaken
    if replay.looping and not replay.playing:
      replay.endHoldFrames = ReplayEndHoldSeconds * ReplayFps
  elif replay.endHoldFrames > 0:
    dec replay.endHoldFrames
    if replay.endHoldFrames == 0 and replay.looping:
      replay.seekReplay(sim, replay.replayStartTick())
      replay.playing = true
      onJump()

proc playbackSpeed*(speedIndex: int): int =
  PlaybackSpeeds[clamp(speedIndex, 0, PlaybackSpeeds.high)]
