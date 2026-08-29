## The pistonball game server: the mummy HTTP/websocket listener, the seat
## lobby, the decision turn, the deterministic controller, the replay writer
## and the `COGAME_*` artifact contract.
##
## THE DETERMINISM BOUNDARY RUNS THROUGH THIS FILE. The LLM and the controller
## live on the live side of it; only the per-seat COMMAND BYTES below are
## recorded, so the wasm viewer re-derives the whole match from them without
## ever running either.

import
  std/[algorithm, json, locks, monotimes, os, strutils, tables, times],
  bitworld/client as bitworldClient,
  bitworld/runtime,
  bitworld/spriteprotocol,
  mummy,
  ./sim, ./scripts, ./baselines, ./decide,
  ./global, ./broadcast, ./replays, ./replay_runtime, ./events, ./roster,
  ./wire_constants

const
  HealthPath = "/healthz"
  ReplayDataPath = "/replay-data"
  LeagueReplayerPath = "/client/league"
  BroadcastFontPath = "/client/font.ttf"
  WallTextureHorizontalPath = "/client/art/walls/wall_h.jpg"
  WallTextureVerticalPath = "/client/art/walls/wall_v.jpg"
  LockerRoomPath = "/client/art/lockerroom/bg.jpg"
  MaxWsFrameBytes = 900_000
    ## Hosted replay closes any WS frame larger than 1 MiB (sends 1009), so
    ## outbound sprite packets are chunked under a margin below that.
  ShutdownGraceSeconds = 20
    ## `/healthz` and `/global` keep answering this long AFTER the artifacts
    ## are written, then the process exits: the episode runner pings `/global`
    ## with a short deadline after the player pods start, and a fast episode
    ## can already be gone.
  # The designed broadcast replay client, embedded at compile time. Final
  # in-page script order: wire constants, shared chrome, core, page IIFE.
  EmbeddedBroadcastHtml =
    staticRead("../../client/replay_broadcast.html").replace(
      "<!-- CHROME_COMMON -->",
      "<script>" & staticRead("../../client/chrome_common.js") & "</script>"
    ).replace(
      "<!-- BROADCAST_CORE -->",
      "<script>" & staticRead("../../client/broadcast_core.js") & "</script>"
    ).spliceWireConstants()
  BroadcastFont = staticRead("../../data/font.ttf")
  WallTextureHorizontal = staticRead("../../client/art/walls/wall_h.jpg")
  WallTextureVertical = staticRead("../../client/art/walls/wall_v.jpg")
  LockerRoomPlate = staticRead("../../client/art/lockerroom/bg.jpg")

type
  WebSocketAppState = object
    lock: Lock
    config: GameConfig
    replayLoaded: bool
    replayBytes: string
    playerIndices: Table[WebSocket, int]
    playerAddresses: Table[WebSocket, string]
    playerSlots: Table[WebSocket, int]
    playerTokens: Table[WebSocket, string]
    playerReady: Table[WebSocket, bool]
    playerViewers: Table[WebSocket, PlayerViewerState]
    chatMessages: Table[WebSocket, string]
    globalViewers: Table[WebSocket, GlobalViewerState]
    closedSockets: seq[WebSocket]

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

  PendingPlayerJoin = object
    websocket: WebSocket
    address: string
    token: string
    requestedSlot: int
    slotIndex: int

var appState: WebSocketAppState

proc initAppState() =
  initLock(appState.lock)
  appState.playerIndices = initTable[WebSocket, int]()
  appState.playerAddresses = initTable[WebSocket, string]()
  appState.playerSlots = initTable[WebSocket, int]()
  appState.playerTokens = initTable[WebSocket, string]()
  appState.playerReady = initTable[WebSocket, bool]()
  appState.playerViewers = initTable[WebSocket, PlayerViewerState]()
  appState.chatMessages = initTable[WebSocket, string]()
  appState.globalViewers = initTable[WebSocket, GlobalViewerState]()
  appState.closedSockets = @[]
  appState.config = defaultGameConfig()

proc isWebSocketUpgrade(request: Request): bool =
  request.headers["Sec-WebSocket-Key"].len > 0

proc cleanPlayerName(name: string): string =
  result = name.strip()
  for ch in result.mitems:
    if ch.isSpaceAscii:
      ch = '_'

proc playerSlot(request: Request): int =
  let text = request.queryParams.getOrDefault("slot", "").strip()
  if text.len == 0:
    return -1
  try:
    result = parseInt(text)
  except ValueError:
    return MaxPlayers
  if result < 0 or result >= MaxPlayers:
    return MaxPlayers

proc playerToken(request: Request): string =
  request.queryParams.getOrDefault("token", "").strip()

proc playerIdentity(request: Request, slot: int, token: string): string =
  let name = request.queryParams.getOrDefault("name", "").cleanPlayerName()
  if name.len > 0:
    return name
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.config.configuredPlayerName(slot, token)
  if result.len == 0:
    result = "seat-" & (if slot >= 0: $slot else: "auto")

proc hasPlayerCredentialParams(request: Request): bool =
  request.queryParams.getOrDefault("name", "").strip().len > 0 or
    request.queryParams.getOrDefault("slot", "").strip().len > 0 or
    request.queryParams.getOrDefault("token", "").strip().len > 0

proc respondPlain(request: Request, status: int, body: string) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  headers["Connection"] = "close"
  request.respond(status, headers, body)

proc httpHandler(request: Request) =
  if request.path == HealthPath and request.httpMethod == "GET":
    request.respondPlain(200, "healthy")
  elif request.path == WebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let
      slot = request.playerSlot()
      token = request.playerToken()
      identity = request.playerIdentity(slot, token)
    var allowed = true
    {.gcsafe.}:
      withLock appState.lock:
        allowed = appState.config.playerJoinAllowed(identity, slot, token)
    if not allowed:
      # 403 on a bad slot or token, BEFORE the upgrade.
      request.respondPlain(403,
        "Player credentials do not match configured slot " & $slot & ".\n")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerViewers[websocket] = initPlayerViewerState()
        appState.playerAddresses[websocket] = identity
        appState.playerSlots[websocket] = slot
        appState.playerTokens[websocket] = token
        appState.playerIndices[websocket] = 0x7fffffff
        appState.playerReady[websocket] = false
    echo "player connected: ", identity
  elif (request.path == GlobalWebSocketPath or
        request.path == ReplayWebSocketPath) and
      request.httpMethod == "GET" and request.isWebSocketUpgrade():
    if request.hasPlayerCredentialParams():
      request.respondPlain(403,
        "Viewer websocket cannot include player name, slot, or token.\n")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.globalViewers[websocket] = initGlobalViewerState()
  elif request.path == ReplayDataPath and request.httpMethod == "GET":
    var bytes = ""
    {.gcsafe.}:
      withLock appState.lock:
        bytes = appState.replayBytes
    var headers: HttpHeaders
    headers["Content-Type"] = "application/octet-stream"
    headers["Cache-Control"] = "no-cache"
    request.respond((if bytes.len > 0: 200 else: 404), headers, bytes)
  elif request.path == BroadcastFontPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "font/ttf"
    headers["Cache-Control"] = "public, max-age=3600"
    request.respond(200, headers, BroadcastFont)
  elif request.path in [WallTextureHorizontalPath, WallTextureVerticalPath,
      LockerRoomPath] and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "image/jpeg"
    headers["Cache-Control"] = "public, max-age=3600"
    request.respond(200, headers, (
      if request.path == WallTextureHorizontalPath: WallTextureHorizontal
      elif request.path == WallTextureVerticalPath: WallTextureVertical
      else: LockerRoomPlate))
  elif request.path in [
      bitworldClient.ReplayClientRoute,
      bitworldClient.CoworldReplayClientRoute,
      bitworldClient.GlobalClientRoute,
      bitworldClient.CoworldGlobalClientRoute,
      bitworldClient.PlayerClientRoute,
      bitworldClient.CoworldPlayerClientRoute,
      LeagueReplayerPath
    ] and request.httpMethod == "GET":
    # BOTH `/client/` routes serve REAL pages, registered before any catch-all
    # asset route, and NEITHER opens the player socket: the certifier probes
    # them before starting the player pods.
    var headers: HttpHeaders
    headers["Content-Type"] = "text/html; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    request.respond(200, headers, EmbeddedBroadcastHtml)
  else:
    request.respondPlain(200, "pistonball server")

proc websocketHandler(
  websocket: WebSocket, event: WebSocketEvent, message: Message
) =
  case event
  of OpenEvent:
    discard
  of MessageEvent:
    if message.kind == Ping:
      websocket.send(message.data, Pong)
    elif message.kind == BinaryMessage:
      {.gcsafe.}:
        withLock appState.lock:
          if message.data.len == 1 and
              message.data[0].uint8 == SpriteClientReady and
              websocket in appState.playerReady:
            appState.playerReady[websocket] = true
          elif websocket in appState.globalViewers:
            appState.globalViewers[websocket].applyGlobalViewerMessage(
              message.data)
          elif websocket in appState.playerViewers:
            # A seat sends NO inputs: every command byte is computed
            # server-side, so an input mask arriving here is DISCARDED. The
            # one thing a seat may say is its registration chat frame.
            var chatText = ""
            appState.playerViewers[websocket].applyPlayerViewerMessage(
              message.data, chatText)
            if chatText.len > 0:
              appState.chatMessages[websocket] = chatText
  of ErrorEvent, CloseEvent:
    var who = ""
    {.gcsafe.}:
      withLock appState.lock:
        if websocket notin appState.closedSockets:
          appState.closedSockets.add(websocket)
          if websocket in appState.playerAddresses:
            who = appState.playerAddresses[websocket]
    if who.len > 0:
      echo "player disconnected: ", who

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

proc declarePlayerFailure(slot: int, message: string) =
  ## Publishes the game-declared terminal player failure the platform runner
  ## polls for, so a lobby no-show is charged to the seat that caused it
  ## instead of poisoning the whole episode unattributed. Best-effort, and a
  ## no-op outside the platform.
  try:
    writeCogameEnv(
      "COGAME_PLAYER_FAILURE_URI",
      $(%*{"failed_policy_index": slot, "message": message}),
      "application/json")
  except CatchableError as error:
    echo "player-failure declaration failed: ", error.msg

proc parseRegistration*(
  text: string
): tuple[ok: bool, prompt, scripted, policy: string] =
  ## A seat's ONE Sprite v1 chat message, read as its registration:
  ##   {"type":"register","prompt":"…","scripted":"wavebot"|null,"policy":"…"}
  ## Anything that is not that object is not a registration and is dropped.
  result = (false, "", "", "")
  if text.len == 0 or text[0] != '{':
    return
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    return
  if node.kind != JObject or node{"type"}.getStr() != "register":
    return
  result.ok = true
  result.prompt = node{"prompt"}.getStr()
  if not node{"scripted"}.isNil and node{"scripted"}.kind == JString:
    result.scripted = node{"scripted"}.getStr()
  result.policy = node{"policy"}.getStr()

proc comparePendingJoins(a, b: PendingPlayerJoin): int =
  result = cmp(a.slotIndex, b.slotIndex)
  if result == 0:
    result = cmp(a.address, b.address)

proc allPlayersReady(
  sockets: openArray[WebSocket], indices: openArray[int], playerCount: int
): bool =
  var active = 0
  {.gcsafe.}:
    withLock appState.lock:
      for i, websocket in sockets:
        if i >= indices.len or indices[i] < 0 or indices[i] >= playerCount:
          continue
        inc active
        if not appState.playerReady.getOrDefault(websocket, false):
          return false
  active > 0

proc runFrameLimiter(
  previousTick: var MonoTime,
  fastMode: bool,
  sockets: openArray[WebSocket],
  indices: openArray[int],
  playerCount: int
) =
  ## Paces the loop to `TargetFps`, or advances as soon as every seat has
  ## acknowledged the frame when `fastMode` is on — so sim time is not charged
  ## against the wall clock and the DECISION TURNS are the pacing.
  let frameDuration = initDuration(microseconds = 1_000_000 div TargetFps)
  while true:
    let elapsed = getMonoTime() - previousTick
    if elapsed >= frameDuration:
      break
    if fastMode and sockets.allPlayersReady(indices, playerCount):
      break
    let remaining = frameDuration - elapsed
    sleep(max(1, min(2, int(remaining.inMilliseconds))))
  previousTick = getMonoTime()

proc runServerLoop*(
  host = DefaultHost,
  port = DefaultPort,
  initialConfig = defaultGameConfig(),
  saveReplayPath = "",
  loadReplayPath = "",
  runtimeConfig = RuntimeConfig()
) =
  initAppState()
  if saveReplayPath.len > 0 and loadReplayPath.len > 0:
    raise newException(ReplayError, "Cannot save and load a replay together")
  var replayLoaded = loadReplayPath.len > 0
  var replayData =
    if replayLoaded:
      try:
        loadReplay(loadReplayPath)
      except CatchableError as error:
        ## A bad or version-mismatched replay must not kill the server: the
        ## viewer would see a dead socket with no explanation. Serve the empty
        ## lobby and say why.
        echo "replay load failed (serving without replay): ", error.msg
        replayLoaded = false
        ReplayData()
    else:
      ReplayData()
  var initialized =
    if replayLoaded: initReplayRuntime(replayData, runtimeConfig.mismatchQuit)
    else: InitializedReplay()
  var config =
    if replayLoaded: move(initialized.config) else: initialConfig
  var sim =
    if replayLoaded: move(initialized.sim) else: initSimServer(config)
  var replayPlayer =
    if replayLoaded: move(initialized.player) else: initReplayPlayer(ReplayData())
  var broadcastTracker =
    if replayLoaded: move(initialized.tracker) else: initBroadcastTracker()
  var replayWriter = openReplayWriter(
    saveReplayPath, config.configJson(sim.perm, sim.restHeights))
  replayWriter.lastMasks = newSeq[uint8](sim.seatCount())
  for i in 0 ..< replayWriter.lastMasks.len:
    replayWriter.lastMasks[i] = 127'u8
  defer:
    replayWriter.closeReplayWriter()
  appState.replayLoaded = replayLoaded
  appState.config = config
  if replayLoaded:
    appState.replayBytes = readFile(loadReplayPath)

  # Tier-2 event sink. Off unless the platform configured a destination, and
  # file:// ONLY: the dispatcher writes this as a workdir path and the runner
  # uploads the file afterwards, so an http target would mean the contract
  # changed underneath us and the operator needs to know.
  let eventsPath = block:
    let uri = getEnv("COGAME_EVENTS_URI")
    if uri.len == 0: ""
    elif uri.startsWith("file://"): uri[7 .. ^1]
    else:
      raise newException(ValueError,
        "COGAME_EVENTS_URI must be a file:// path, got: " & uri)
  let metricsPath = block:
    let uri = getEnv("COGAME_METRICS_URI")
    if uri.len == 0: ""
    elif uri.startsWith("file://"): uri[7 .. ^1]
    else:
      raise newException(ValueError,
        "COGAME_METRICS_URI must be a file:// path, got: " & uri)
  sim.collectEvents = eventsPath.len > 0
  var collectedEvents: seq[SimEvent] = @[]

  block:
    # Bake the board sprites BEFORE the listener opens: a viewer's
    # first-message clock starts at its successful connect, so nothing may be
    # accepted until every frame the loop will ever build can be assembled
    # instantly.
    let warmStart = getMonoTime()
    warmBoardRenderCaches()
    echo "board render caches baked in ",
      (getMonoTime() - warmStart).inMilliseconds, " ms"

  let httpServer = newServer(httpHandler, websocketHandler, workerThreads = 4)
  var
    serverThread: Thread[ServerThreadArgs]
    serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(serverThread, serverThreadProc,
    ServerThreadArgs(server: serverPtr, address: host, port: port))
  httpServer.waitUntilReady()

  var
    engine = if replayLoaded: DecisionEngine() else: initDecisionEngine(sim)
    lastTurnIndex = -1
    episodeStart = getMonoTime()
    lastTick = getMonoTime()
    noShowDeclared = false
    quitAfterFrame = false
    liveSpeedIndex = 0
    framesPlayed = 0

  while true:
    var
      sockets: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      playerStates: seq[PlayerViewerState] = @[]
      globalViewers: seq[WebSocket] = @[]
      globalStates: seq[GlobalViewerState] = @[]
      replayCommands: seq[char] = @[]
      replaySeekTicks: seq[int] = @[]

    # --- named edit 4: the engine's own wall-clock stop --------------------
    if not replayLoaded and sim.phase != GameOver and
        (getMonoTime() - episodeStart).inSeconds.int >=
          config.wallClockBudgetSeconds:
      echo "wall-clock budget of ", config.wallClockBudgetSeconds,
        "s reached; settling the episode from the ball position at this tick"
      sim.stopForWallClock()
      quitAfterFrame = true

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          # A seat that drops does NOT lose its piston: its script source
          # degrades to `wavebot` and it revives on reconnect. Deleting the
          # roster row would renumber every later seat mid-replay.
          appState.playerIndices.del(websocket)
          appState.playerAddresses.del(websocket)
          appState.playerSlots.del(websocket)
          appState.playerTokens.del(websocket)
          appState.playerReady.del(websocket)
          appState.playerViewers.del(websocket)
          appState.chatMessages.del(websocket)
          appState.globalViewers.del(websocket)
        appState.closedSockets.setLen(0)

        if not replayLoaded:
          var progressed = true
          while progressed:
            progressed = false
            var pending: seq[PendingPlayerJoin] = @[]
            for websocket, index in appState.playerIndices.pairs:
              if index != 0x7fffffff:
                continue
              var join = PendingPlayerJoin(
                websocket: websocket,
                address: appState.playerAddresses.getOrDefault(
                  websocket, "unknown"),
                token: appState.playerTokens.getOrDefault(websocket, ""),
                requestedSlot: appState.playerSlots.getOrDefault(websocket, -1))
              join.slotIndex = sim.resolvePlayerSlot(
                join.address, join.token, join.requestedSlot)
              pending.add(join)
            pending.sort(comparePendingJoins)
            for join in pending:
              # Joins are strictly slot-sequential: a seat whose slot is not
              # the next open one waits for the lower slots.
              if join.slotIndex != sim.nextPlayerSlot():
                continue
              if not sim.canAddPlayer():
                continue
              var seated = -1
              try:
                seated = sim.addPlayer(
                  join.address, join.requestedSlot, join.token)
              except PistonballError:
                continue
              appState.playerIndices[join.websocket] = seated
              appState.playerSlots[join.websocket] = seated
              replayWriter.writeJoin(tickTime(sim.tickCount), seated,
                join.address, join.requestedSlot, join.token)
              progressed = true

          # Registrations that cannot be applied YET are HELD, not dropped.
          # A seat's first registration routinely arrives before its player
          # index exists, and dropping it made a champion play the scripted
          # baseline for a whole episode.
          var held: seq[(WebSocket, string)] = @[]
          for websocket, chatText in appState.chatMessages.pairs:
            let index = appState.playerIndices.getOrDefault(websocket, -1)
            if index < 0 or index >= engine.seats.len:
              if parseRegistration(chatText).ok:
                held.add((websocket, chatText))
              continue
            let registration = parseRegistration(chatText)
            if not registration.ok:
              continue                  ## seats register; they do not chat.
            var policy = engine.seats[index]
            let firstRegistration = not policy.registered
            policy.registered = true
            policy.prompt = registration.prompt.truncateRunes(MaxPromptRunes)
            policy.isLlm = policy.prompt.len > 0
            policy.baseline = parseBaseline(registration.scripted)
            policy.label =
              if registration.policy.len > 0: registration.policy
              elif policy.isLlm: "prompt"
              else: $policy.baseline
            engine.seats[index] = policy
            if index < sim.seatPolicyKind.len:
              sim.seatPolicyKind[index] = engine.policyKind(index)
            # ONE `register` record and one log line per seat: the seat
            # re-sends its registration for the first ~10 s of frames, so
            # recording every copy would put ten identical records in the
            # replay.
            if firstRegistration:
              replayWriter.writeChat(tickTime(sim.tickCount), index,
                registerRecord(index, sim.pistonOfSeat(index),
                  alias(max(0, sim.pistonOfSeat(index))),
                  policy.label, engine.policyKind(index), $policy.baseline))
              echo "seat ", index, " registered: kind=",
                engine.policyKind(index), " baseline=", $policy.baseline
          appState.chatMessages.clear()
          for (websocket, chatText) in held:
            appState.chatMessages[websocket] = chatText

        for websocket, index in appState.playerIndices.pairs:
          sockets.add(websocket)
          playerIndices.add(index)
          playerStates.add(appState.playerViewers.getOrDefault(
            websocket, initPlayerViewerState()))
        for websocket, state in appState.globalViewers.pairs:
          globalViewers.add(websocket)
          globalStates.add(state)
          if state.replaySeekTick >= 0:
            replaySeekTicks.add(state.replaySeekTick)
          for command in state.replayCommands:
            replayCommands.add(command)
          appState.globalViewers[websocket].replayCommands.setLen(0)
          appState.globalViewers[websocket].replaySeekTick = -1

    if not replayLoaded and not noShowDeclared and sim.lobbyJoinTimedOut():
      # A seat that never connects does NOT end the episode. Report the
      # no-show to the platform (lowest missing slot only); the sim's own
      # lobby budget starts the match anyway and that piston plays `wavebot`.
      noShowDeclared = true
      let stuckSlot = sim.nextPlayerSlot()
      declarePlayerFailure(stuckSlot,
        "player slot " & $stuckSlot & " never joined the lobby within " &
        $config.lobbyJoinTimeoutTicks & " lobby ticks (~" &
        $(config.lobbyJoinTimeoutTicks div TargetFps) &
        "s); its piston plays the wavebot baseline")

    var frameEvents = newJArray()
    if replayLoaded:
      frameEvents = replayPlayer.advanceReplayFrame(
        sim, broadcastTracker, replaySeekTicks, replayCommands)
    else:
      for command in replayCommands:
        liveSpeedIndex.applySpeedCommand(command)
      # ------------------------------------------------------------------
      #  Named edit 3: the decision turn, then the control-compiled command
      #  bytes. Only the bytes below are recorded.
      # ------------------------------------------------------------------
      if sim.phase == Playing:
        engine.observe(sim)
        let
          turnTicks = max(1, config.turnTicks)
          turnIndex = sim.gameTicksElapsed() div turnTicks
        # Keyed on the turn INDEX changing, not on `elapsed mod turnTicks == 0`:
        # the phase flips to Playing INSIDE a step, so the first iteration that
        # sees Playing already has one elapsed tick and the modulo test would
        # skip turn 0 entirely — every seat would play the scripted layer for
        # the first 225 ticks and the LLM would never be asked to open.
        if turnIndex != lastTurnIndex:
          lastTurnIndex = turnIndex
          let elapsedSeconds = (getMonoTime() - episodeStart).inSeconds.int
          let records = engine.turn(sim, turnIndex, elapsedSeconds)
          for record in records:
            replayWriter.writeChat(tickTime(sim.tickCount), 0, record)
          for seat in 0 ..< engine.seats.len:
            if not engine.haveScript[seat]:
              continue
            let
              script = engine.scripts[seat]
              piston = max(0, sim.pistonOfSeat(seat))
            case script.source
            of srcLlm: inc sim.llmTurns[min(seat, sim.llmTurns.high)]
            of srcFallback:
              inc sim.fallbackTurns[min(seat, sim.fallbackTurns.high)]
            of srcScripted: discard
            let record = boundedScriptRecord(
              script, turnIndex, seat, piston, alias(piston))
            replayWriter.writeChat(tickTime(sim.tickCount), seat, record)
            sim.pushFeedScript(record)
            sim.emitEvent(Script, source = seat, amount = turnIndex,
              content = script.note)
            if script.say.len > 0:
              sim.holdSay(piston, script.say, sim.tickCount + 60)
          engine.closeTurn()
      # Compile ONE command byte per PISTON, in piston index order 0..19,
      # never seat order — seat order varies with `perm` and the loop must
      # not.
      var commands = newSeq[uint8](sim.seatCount())
      for i in 0 ..< commands.len:
        commands[i] = 127'u8
      for piston in 0 ..< PistonCount:
        let seat = sim.seatOfPiston(piston)
        if seat < 0 or seat >= commands.len:
          continue
        let command = engine.commandFor(sim, piston)
        commands[seat] = command
        replayWriter.writeInputMaskChange(
          tickTime(sim.tickCount), seat, command)
      var faultRule = ""
      try:
        sim.step(commands)
      except SimGuardError as guard:
        echo "pistonball: SIM GUARD tripped at tick ", sim.tickCount, ": ",
          guard.msg
        faultRule = EndRuleSimFault
      except CatchableError as error:
        echo "pistonball: HOST ERROR at tick ", sim.tickCount, ": ", error.msg
        faultRule = EndRuleHostError
      if faultRule.len > 0:
        sim.finishGame(ReasonFault, faultRule)
        quitAfterFrame = true
      replayWriter.writeHash(uint32(sim.tickCount), sim.gameHash())
      if sim.collectEvents:
        for event in sim.events:
          collectedEvents.add(event)
        sim.events.setLen(0)
      sim.stepEvents(broadcastTracker, frameEvents)
      if sim.phase == Playing:
        inc framesPlayed
      if sim.phase == GameOver and sim.gameOverTimer <= 0:
        quitAfterFrame = true

    # --- broadcast --------------------------------------------------------
    if not replayLoaded and config.fastMode:
      {.gcsafe.}:
        withLock appState.lock:
          for websocket in sockets:
            if websocket in appState.playerReady:
              appState.playerReady[websocket] = false
    for i in 0 ..< sockets.len:
      if playerIndices[i] < 0 or playerIndices[i] >= sim.seatCount():
        continue
      var nextState: PlayerViewerState
      let packet = sim.buildSpriteProtocolPlayerUpdates(
        playerIndices[i], playerStates[i], nextState)
      {.gcsafe.}:
        withLock appState.lock:
          if sockets[i] in appState.playerViewers:
            appState.playerViewers[sockets[i]] = nextState
      try:
        if packet.len == 0:
          # ONE binary message per tick is the frame contract — clients count
          # messages to advance — so an empty frame still ships.
          sockets[i].send("", BinaryMessage)
        for chunk in chunkSpritePacket(packet, MaxWsFrameBytes):
          sockets[i].send(blobFromBytes(chunk), BinaryMessage)
      except CatchableError:
        {.gcsafe.}:
          withLock appState.lock:
            if sockets[i] notin appState.closedSockets:
              appState.closedSockets.add(sockets[i])

    for i in 0 ..< globalViewers.len:
      var nextState: GlobalViewerState
      let packet =
        if replayLoaded:
          sim.buildReplayViewerPacket(
            replayPlayer, globalStates[i], nextState, frameEvents)
        else:
          block:
            var body = sim.buildBoardPacket(globalStates[i], nextState)
            if body.len > 0:
              # The JSON chrome channel rides the SAME binary sprite channel
              # as the board — as the label of a reserved never-drawn 1x1
              # sprite — because that is the ONLY channel that survives a
              # hosted replay.
              body.addSprite(BroadcastChromeSpriteId, 1, 1, [0'u8, 0, 0, 0],
                sim.buildStateJson(frameEvents, true,
                  float(playbackSpeed(liveSpeedIndex)), sim.effectiveMaxTicks(),
                  false, false, -1, nextState.selectedPiston))
            body
      if packet.len == 0:
        continue
      try:
        for chunk in chunkSpritePacket(packet, MaxWsFrameBytes):
          globalViewers[i].send(blobFromBytes(chunk), BinaryMessage)
        {.gcsafe.}:
          withLock appState.lock:
            if globalViewers[i] in appState.globalViewers:
              # The websocket thread keeps writing viewer INPUT into this
              # entry while the frame was being built from an earlier
              # snapshot: merge rather than clobber, or a seek landing in
              # between is silently lost.
              let pending = appState.globalViewers[globalViewers[i]]
              var merged = nextState
              merged.mouseX = pending.mouseX
              merged.mouseY = pending.mouseY
              merged.mouseLayer = pending.mouseLayer
              merged.mouseDown = pending.mouseDown
              if pending.clickPending:
                merged.clickPending = true
              if pending.replaySeekTick >= 0:
                merged.replaySeekTick = pending.replaySeekTick
              if pending.replayCommands.len > 0:
                merged.replayCommands.add(pending.replayCommands)
              appState.globalViewers[globalViewers[i]] = merged
      except CatchableError:
        {.gcsafe.}:
          withLock appState.lock:
            if globalViewers[i] notin appState.closedSockets:
              appState.closedSockets.add(globalViewers[i])

    if quitAfterFrame:
      # The `result` control record: the whole results document, written once
      # into the replay chat stream at episode end, so the replay is
      # SELF-SUFFICIENT. Never applied as state at playback (a leading '{'
      # marks a control record), so the hash chain is untouched.
      replayWriter.writeChat(tickTime(sim.tickCount), 0, resultRecord(sim))
      replayWriter.closeReplayWriter()
      if saveReplayPath.len > 0 and fileExists(saveReplayPath):
        echo "Replay written: ", saveReplayPath,
          " (", getFileSize(saveReplayPath), " bytes)"
        runtimeConfig.writeReplay(readFile(saveReplayPath))
      if eventsPath.len > 0:
        # Always written when a sink is configured, even with zero events: the
        # summary row is how a reader tells "this match had none" from "the
        # upload never happened".
        writeFile(eventsPath, collectedEvents.eventsJsonl(sim.tickCount))
        echo "Events written: ", eventsPath, " (", collectedEvents.len,
          " events)"
      if runtimeConfig.resultsUri.len > 0:
        runtimeConfig.writeResults(sim.playerResultsJson() & "\n")
      if metricsPath.len > 0:
        writeFile(metricsPath, $(%*{
          "ticks": sim.tickCount,
          "frames": framesPlayed,
          "reason": sim.endReason,
          "endRule": sim.endRule
        }) & "\n")
      echo "pistonball finished: reason=", sim.endReason, " endRule=",
        sim.endRule, " ticks=", sim.tickCount,
        " score=", pointsText(sim.scoreMilli())
      # --- named edit 5: bounded shutdown grace ---------------------------
      let graceUntil =
        getMonoTime() + initDuration(seconds = ShutdownGraceSeconds)
      while getMonoTime() < graceUntil:
        sleep(200)
      httpServer.close()
      joinThread(serverThread)
      break

    runFrameLimiter(lastTick, not replayLoaded and config.fastMode,
      sockets, playerIndices, sim.seatCount())
