## The pistonball game server: the mummy HTTP/websocket listener, the seat
## lobby, the decision turn, the deterministic controller, the replay writer
## and the `COGAME_*` artifact contract.
##
## THE DETERMINISM BOUNDARY RUNS THROUGH THIS FILE. Player decisions and the
## controller live on the live side of it; only the per-seat COMMAND BYTES below are
## recorded, so the wasm viewer re-derives the whole match from them without
## ever running either.

import
  std/[algorithm, base64, json, locks, monotimes, options, os, sets, strutils, sysrand, tables, times],
  bitworld/client as bitworldClient,
  bitworld/runtime,
  bitworld/decision_trajectory,
  bitworld/native_stop,
  bitworld/artifact_runtime,
  bitworld/spriteprotocol,
  mummy,
  ./sim, ./scripts, ./baselines, ./decide, ./llm,
  ./global, ./broadcast, ./replays, ./replay_runtime, ./events, ./roster,
  ./attempt_evidence, ./training_capture,
  ./wire_constants

const
  HealthPath = "/healthz"
  ReplayDataPath = "/replay-data"
  LeagueReplayerPath = "/client/league"
  BroadcastFontPath = "/client/font.ttf"
  WallTextureHorizontalPath = "/client/art/walls/wall_h.jpg"
  WallTextureVerticalPath = "/client/art/walls/wall_v.jpg"
  LockerRoomPath = "/client/art/lockerroom/bg.jpg"
  MaxIncomingEvidenceBytes = 16 * 1024 * 1024
  MaxQueuedEvidenceBytes = 64 * 1024 * 1024
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
  ReceivedPlayerFrame = object
    body: string
    receivedAt: MonoTime

  IssuedDecision = object
    socket: WebSocket
    seat, turn: int
    view, operatorPrompt, policy: string
    retry: bool
    issuedAt, deadline: MonoTime

  PlayerFrameKind = enum
    pfIgnored, pfObserved, pfAction, pfRejected

  PlayerFrameResult = object
    kind: PlayerFrameKind
    decisionId: string
    reply: BatchReply

  WebSocketAppState = object
    lock: Lock
    config: GameConfig
    replayLoaded: bool
    replayBytes: string
    playerIndices: Table[WebSocket, int]
    playerAddresses: Table[WebSocket, string]
    playerSlots: Table[WebSocket, int]
    playerTokens: Table[WebSocket, string]
    operatorPrompts: Table[WebSocket, string]
    policyLabels: Table[WebSocket, string]
    playerReady: Table[WebSocket, bool]
    playerViewers: Table[WebSocket, PlayerViewerState]
    chatMessages: Table[WebSocket, string]
    actionMessages: Table[WebSocket, seq[ReceivedPlayerFrame]]
    nativeStarts: Table[string, JsonNode]
    nativeFinished: Table[string, JsonNode]
    issuedDecisions: Table[string, IssuedDecision]
    latestDecisions: Table[WebSocket, string]
    disconnected, acknowledged: HashSet[WebSocket]
    stopId: string
    stopIssuedAt, acknowledgementDeadline: MonoTime
    nextDecisionId: int
    queuedEvidenceBytes: int
    protocolFailure: bool
    protocolError, finalFrames, rejectedFrames: JsonNode
    rejectedFrameBytes: int
    started, stopping, finished: bool
    globalViewers: Table[WebSocket, GlobalViewerState]
    closedSockets: seq[WebSocket]

  GameOwnerArgs = object
    server: Server
    initialConfig: GameConfig
    saveReplayPath, loadReplayPath: string
    runtimeConfig: RuntimeConfig
    episodeDeadline: MonoTime
    runtimeInputs: JsonNode
    failed: bool
    failureType: array[128, char]
    failureTypeLen: int

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
  appState.operatorPrompts = initTable[WebSocket, string]()
  appState.policyLabels = initTable[WebSocket, string]()
  appState.playerReady = initTable[WebSocket, bool]()
  appState.playerViewers = initTable[WebSocket, PlayerViewerState]()
  appState.chatMessages = initTable[WebSocket, string]()
  appState.actionMessages = initTable[WebSocket, seq[ReceivedPlayerFrame]]()
  appState.protocolError = newJNull()
  appState.finalFrames = newJArray()
  appState.rejectedFrames = newJArray()
  appState.nativeStarts = initTable[string, JsonNode]()
  appState.nativeFinished = initTable[string, JsonNode]()
  appState.issuedDecisions = initTable[string, IssuedDecision]()
  appState.latestDecisions = initTable[WebSocket, string]()
  appState.disconnected = initHashSet[WebSocket]()
  appState.acknowledged = initHashSet[WebSocket]()
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
    var websocket: WebSocket
    {.gcsafe.}:
      withLock appState.lock:
        var allowed = not appState.started and not appState.stopping and not appState.finished and
          appState.config.playerJoinAllowed(identity, slot, token)
        for admitted in appState.playerSlots.values:
          if slot >= 0 and admitted == slot: allowed = false
        if not allowed:
          request.respondPlain(403, "Player admission is closed or credentials differ.\n")
          return
        websocket = request.upgradeToWebSocket()
        appState.playerViewers[websocket] = initPlayerViewerState()
        appState.playerAddresses[websocket] = identity
        appState.playerSlots[websocket] = slot
        appState.playerTokens[websocket] = token
        appState.playerIndices[websocket] = 0x7fffffff
        appState.playerReady[websocket] = false
    websocket.send($ %*{"type": "welcome", "protocol": "pistonball.player.v2",
      "slot": slot}, TextMessage)
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
            if chatText.len > 0 and not appState.started and
                not appState.stopping and not appState.finished:
              appState.chatMessages[websocket] = chatText
    elif message.kind == TextMessage:
      {.gcsafe.}:
        withLock appState.lock:
          if websocket in appState.playerIndices and not appState.finished:
            if appState.queuedEvidenceBytes + message.data.len > MaxQueuedEvidenceBytes:
              if not appState.protocolFailure:
                appState.protocolError = %*{"kind": "evidence_queue_limit", "received_bytes": message.data.len,
                  "prefix_b64": encode(message.data[0 ..< min(message.data.len, 4096)]),
                  "prefix_complete": message.data.len <= 4096}
              appState.protocolFailure = true
              appState.disconnected.incl(websocket)
              requestNativeStop()
            else:
              inc appState.queuedEvidenceBytes, message.data.len
              appState.actionMessages.mgetOrPut(websocket, @[]).add(
                ReceivedPlayerFrame(body: message.data, receivedAt: getMonoTime()))
  of ErrorEvent, CloseEvent:
    var who = ""
    {.gcsafe.}:
      withLock appState.lock:
        appState.disconnected.incl(websocket)
        if websocket notin appState.closedSockets:
          appState.closedSockets.add(websocket)
          if websocket in appState.playerAddresses:
            who = appState.playerAddresses[websocket]
    if who.len > 0:
      echo "player disconnected: ", who

proc declarePlayerFailure(slot: int, message: string, deadline: MonoTime) =
  ## Publish a real lobby no-show within the original process deadline.
  let destination = getEnv("COGAME_PLAYER_FAILURE_URI")
  if destination.len == 0: return
  writeCogameArtifact(destination,
    $(%*{"failed_policy_index": slot, "message": message}),
    "application/json", "pistonball player failure", deadline)

proc parseRegistration*(
  text: string
): tuple[ok: bool, kind, scripted, policy, prompt: string] =
  ## A seat's ONE Sprite v1 chat message, read as its registration:
  ##   {"type":"register","prompt":"…","scripted":"wavebot"|null,"policy":"…"}
  ## Anything that is not that object is not a registration and is dropped.
  result = (false, "", "", "", "")
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
  result.kind = node{"kind"}.getStr()
  if result.kind notin ["prompt", "external", "scripted"]:
    result.ok = false
    return
  if not node{"scripted"}.isNil and node{"scripted"}.kind == JString:
    result.scripted = node{"scripted"}.getStr()
  result.policy = node{"policy"}.getStr()
  result.prompt = node{"prompt"}.getStr()

proc retainNativeEvidence(socket: WebSocket, id: string, evidence: JsonNode,
    first: bool, receivedAt: MonoTime): DecisionAttempt =
  if not appState.issuedDecisions.hasKey(id):
    raise newException(ValueError, "native evidence has no issued decision")
  let issue = appState.issuedDecisions[id]
  if issue.socket != socket or receivedAt < issue.issuedAt:
    raise newException(ValueError, "native evidence differs from authenticated issued seat")
  result = readAttemptEvidence(evidence)
  if result.attemptId != id & "-native":
    raise newException(ValueError, "attempt differs from issued identity")
  if result.origin in {aoTeacher, aoHuman}: result.origin = aoUnknown
  let facts = result.attemptEvidenceJson()
  if result.origin == aoModel:
    if appState.nativeFinished.hasKey(id):
      validateNativeProgress(appState.nativeFinished[id], facts)
    elif appState.nativeStarts.hasKey(id):
      validateNativeProgress(appState.nativeStarts[id], facts)
    elif first:
      validateNativeStart(result)
      validateNativeRequest(result, issue.view, issue.operatorPrompt, issue.policy, issue.retry)
      appState.nativeStarts[id] = facts
    else:
      raise newException(ValueError, "native completion has no recorded request start")
  elif first:
    raise newException(ValueError, "request start must identify a native model call")
  appState.nativeFinished[id] = facts

proc parsePlayerFrame(socket: WebSocket, frame: ReceivedPlayerFrame): PlayerFrameResult =
  ## The existing player JSON domain boundary also handles shutdown facts.
  ## Invalid old control frames never mutate the current action's result.
  result.reply.origin = aoUnknown
  try:
    let payload = parseJson(frame.body)
    let frameType = payload["type"].getStr()
    if frameType == "stopped":
      {.gcsafe.}:
        withLock appState.lock:
          for retained in payload["attempts"]:
            discard retainNativeEvidence(socket, retained["decision_id"].getStr(),
              retained["training_attempt"], false, frame.receivedAt)
          let latest = if appState.latestDecisions.hasKey(socket):
            %appState.latestDecisions[socket] else: newJNull()
          if payload["worker_status"].getStr() != "joined":
            raise newException(ValueError, "player worker did not join")
          for id, issue in appState.issuedDecisions:
            if issue.socket == socket and appState.nativeStarts.hasKey(id) and
                readAttemptEvidence(appState.nativeFinished[id]).responseReaderJoined != some(true):
              raise newException(ValueError, "player has unresolved native request ownership")
          if socket notin appState.disconnected:
            socket.send($ %*{"type": "evidence_received",
              "decision_id": payload["decision_id"], "stop_id": payload["stop_id"]}, TextMessage)
            if payload["decision_id"] == latest and payload["stop_id"] == %appState.stopId and
                appState.stopping and frame.receivedAt >= appState.stopIssuedAt and
                frame.receivedAt < appState.acknowledgementDeadline:
              appState.acknowledged.incl(socket)
      result.kind = pfObserved
      return
    if frameType notin ["attempt_started", "action"]: return
    result.decisionId = payload["decision_id"].getStr()
    {.gcsafe.}:
      withLock appState.lock:
        if not appState.issuedDecisions.hasKey(result.decisionId):
          raise newException(ValueError, "player frame has no issued decision")
        let issue = appState.issuedDecisions[result.decisionId]
        if issue.socket != socket or frame.receivedAt < issue.issuedAt:
          raise newException(ValueError, "player frame differs from authenticated issued seat")
        let evidence = payload["training_attempt"]
        if evidence.kind != JNull:
          let attempt = retainNativeEvidence(socket, result.decisionId, evidence,
            frameType == "attempt_started", frame.receivedAt)
          if payload["attempt_id"].getStr() != attempt.attemptId:
            raise newException(ValueError, "action attempt differs from issued identity")
          result.reply.evidence = some(attempt)
        elif frameType == "attempt_started":
          raise newException(ValueError, "native start has no request evidence")
        if frameType == "attempt_started" or frame.receivedAt >= issue.deadline:
          result.kind = pfObserved
          return
    if payload.hasKey("action") and payload["action"].kind == JObject:
      if result.reply.evidence.isSome and result.reply.evidence.get().origin == aoModel:
        validateNativeAction(result.reply.evidence.get(), payload["action"])
        result.reply.origin = aoModel
      result.reply.ok = true
      result.reply.action = $payload["action"]
    else:
      result.reply.error = "player returned a fallback"
      result.reply.cause = payload["cause"].getStr()
    result.kind = pfAction
  except CatchableError as error:
    {.gcsafe.}:
      withLock appState.lock:
        if appState.rejectedFrameBytes + frame.body.len <= MaxQueuedEvidenceBytes:
          appState.rejectedFrames.add(%*{"body_b64": encode(frame.body),
            "error_type": $error.name, "error": error.msg})
          inc appState.rejectedFrameBytes, frame.body.len
        else:
          appState.protocolFailure = true
          requestNativeStop()
    result.kind = pfRejected
    result.reply.cause = "parse_error"
    result.reply.error = "invalid player response"

proc sendPlayerFrame(socket: WebSocket, data: string): bool =
  try:
    socket.send(data, TextMessage)
    result = true
  except CatchableError:
    {.gcsafe.}:
      withLock appState.lock: appState.disconnected.incl(socket)

proc stopPlayers(cleanupDeadline: MonoTime): bool =
  var nonce: array[16, byte]
  if not urandom(nonce):
    raise newException(PistonballError, "OS stop nonce source unavailable")
  var stopId = ""
  for value in nonce: stopId.add(toHex(value, 2).toLowerAscii())
  var targets: seq[WebSocket]
  {.gcsafe.}:
    withLock appState.lock:
      appState.stopping = true
      appState.stopId = stopId
      appState.stopIssuedAt = getMonoTime()
      appState.acknowledgementDeadline = cleanupDeadline - initDuration(seconds = 1)
      for socket in appState.playerSlots.keys: targets.add(socket)
  for socket in targets:
    var frame: JsonNode
    var connected: bool
    {.gcsafe.}:
      withLock appState.lock:
        let latest = if appState.latestDecisions.hasKey(socket):
          %appState.latestDecisions[socket] else: newJNull()
        frame = %*{"type": "stop", "decision_id": latest, "stop_id": stopId,
          "cleanup_budget_ms": max(0, int((appState.acknowledgementDeadline - getMonoTime()).inMilliseconds))}
        connected = socket notin appState.disconnected
    if connected: discard sendPlayerFrame(socket, $frame)
  while getMonoTime() < cleanupDeadline - initDuration(seconds = 1):
    for socket in targets:
      var queued: seq[ReceivedPlayerFrame]
      {.gcsafe.}:
        withLock appState.lock:
          if appState.actionMessages.hasKey(socket):
            queued = appState.actionMessages[socket]
            for frame in queued: dec appState.queuedEvidenceBytes, frame.body.len
            appState.actionMessages[socket] = @[]
      for frame in queued: discard parsePlayerFrame(socket, frame)
    result = true
    {.gcsafe.}:
      withLock appState.lock:
        for socket in targets:
          if socket notin appState.acknowledged: result = false
    if result: return
    sleep(5)

proc freezePlayerEvidence() =
  var finalFrames: seq[tuple[socket: WebSocket, frame: ReceivedPlayerFrame]]
  {.gcsafe.}:
    withLock appState.lock:
      appState.finished = true
      for socket, queued in appState.actionMessages:
        for frame in queued:
          finalFrames.add((socket, frame))
      appState.actionMessages.clear()
      appState.queuedEvidenceBytes = 0
  for pending in finalFrames:
    let parsed = parsePlayerFrame(pending.socket, pending.frame)
    {.gcsafe.}:
      withLock appState.lock:
        appState.finalFrames.add(%*{"body_b64": encode(pending.frame.body),
          "parse_kind": $parsed.kind})
        if parsed.kind == pfRejected: appState.protocolFailure = true

proc publishGlobalFrames(sim: var SimServer, replayPlayer: var ReplayPlayer,
    replayLoaded: bool, liveSpeedIndex: int, frameEvents: JsonNode) =
  var globalViewers: seq[WebSocket]
  var globalStates: seq[GlobalViewerState]
  {.gcsafe.}:
    withLock appState.lock:
      for socket, state in appState.globalViewers:
        if socket notin appState.disconnected:
          globalViewers.add(socket)
          globalStates.add(state)
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


proc playerBatch(
  seatSockets: seq[WebSocket], seatConnected: seq[bool],
  publishWaiting: proc() {.closure, gcsafe.}
): BatchFn =
  result = proc(calls: seq[BatchCall], deadline: MonoTime): seq[BatchReply]
      {.closure, gcsafe.} =
    result = newSeq[BatchReply](calls.len)
    var requestNumber: int
    let issuedAt = getMonoTime()
    {.gcsafe.}:
      withLock appState.lock:
        inc appState.nextDecisionId
        requestNumber = appState.nextDecisionId
        for call in calls:
          if seatConnected[call.seat]:
            let socket = seatSockets[call.seat]
            let id = $requestNumber & "-seat-" & $call.seat
            appState.issuedDecisions[id] = IssuedDecision(socket: socket, seat: call.seat, turn: call.turn,
              view: call.view, retry: call.retry, issuedAt: issuedAt, deadline: deadline,
              operatorPrompt: appState.operatorPrompts[socket], policy: appState.policyLabels[socket])
            appState.latestDecisions[socket] = id
    for position, call in calls:
      let requestId = $requestNumber & "-seat-" & $call.seat
      result[position].seat = call.seat
      result[position].origin = aoUnknown
      if not seatConnected[call.seat]:
        result[position].cause = "transport_error"
        result[position].error = "player disconnected"
        continue
      let frame = %*{
        "type": "decision", "decision_id": requestId,
        "attempt_id": requestId & "-native", "seat": call.seat,
        "view": parseJson(call.view), "system": SystemPrompt,
        "retry": call.retry, "transport": {"budget_ms":
          max(0, int((deadline - getMonoTime()).inMilliseconds)), "cleanup_budget_ms": 5000}}
      if not sendPlayerFrame(seatSockets[call.seat], $frame):
        result[position].cause = "transport_error"
        result[position].error = "player transport send failed"
    var lastPublish = getMonoTime() - initDuration(seconds = 1)
    while getMonoTime() < deadline and not interruptionRequested():
      if (getMonoTime() - lastPublish).inMilliseconds >= 100:
        publishWaiting()
        lastPublish = getMonoTime()
      var pending = false
      for position, call in calls:
        if result[position].ok or result[position].error.len > 0:
          continue
        let requestId = $requestNumber & "-seat-" & $call.seat
        var raw = ""
        var receivedAt: MonoTime
        {.gcsafe.}:
          withLock appState.lock:
            let socket = seatSockets[call.seat]
            if appState.actionMessages.hasKey(socket) and appState.actionMessages[socket].len > 0:
              let frame = appState.actionMessages[socket][0]
              appState.actionMessages[socket].delete(0)
              dec appState.queuedEvidenceBytes, frame.body.len
              raw = frame.body
              receivedAt = frame.receivedAt
        if raw.len == 0:
          pending = true
          continue
        let parsed = parsePlayerFrame(seatSockets[call.seat],
          ReceivedPlayerFrame(body: raw, receivedAt: receivedAt))
        if parsed.decisionId != requestId or parsed.kind in {pfIgnored, pfObserved}:
          pending = true
          continue
        result[position] = parsed.reply
        result[position].seat = call.seat
      if not pending:
        break
      sleep(10)
    for reply in result.mitems:
      if not reply.ok and reply.error.len == 0:
        reply.cause = "timeout"
        reply.error = "player response timed out"

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

proc runGameOwnerLoop(
  httpServer: Server,
  initialConfig: GameConfig,
  saveReplayPath, loadReplayPath: string,
  runtimeConfig: RuntimeConfig,
  episodeDeadline: MonoTime,
  runtimeInputs: JsonNode
) =
  var initializedOwner = false
  defer:
    if not initializedOwner:
      let failure = getCurrentException()
      doAssert failure != nil
      writeInitializationCheckpoint(esFailed, "game_owner_initialization",
        $failure.name, failure.msg, episodeDeadline, runtimeInputs)
  if saveReplayPath.len > 0 and loadReplayPath.len > 0:
    raise newException(ReplayError, "Cannot save and load a replay together")
  var replayLoaded = loadReplayPath.len > 0
  var replayData =
    if replayLoaded: loadReplay(loadReplayPath)
    else: ReplayData()
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
  let replayBytes = if replayLoaded: readFile(loadReplayPath) else: ""
  {.gcsafe.}:
    withLock appState.lock:
      appState.replayLoaded = replayLoaded
      appState.config = config
      appState.replayBytes = replayBytes

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
  let trajectory = if not replayLoaded and getEnv(CogameSaveTrajectoryUriEnv).len > 0:
    some(newDecisionTrajectory(getEnv("COWORLD_EPISODE_ID"), "pistonball-" & $config.seed,
      "pistonball", getEnv("COWORLD_GAME_VERSION"), getEnv("COWORLD_SOURCE_REVISION")))
    else: none(DecisionTrajectory)
  var pendingMacros, completedMacros: seq[StagedMacro]
  var actualControls = ""
  var actualHashes = newJArray()
  var executionStartTick = -1
  var executionEndTick = -1
  var finalizationStarted = false
  proc sealPrivate(status: EpisodeStatus, allJoined: bool, cleanupDeadline: MonoTime,
      failureDetails: JsonNode) =
    if trajectory.isSome:
      for issued in pendingMacros.mitems: issued.endTick = max(issued.startTick, executionEndTick)
      completedMacros.add(pendingMacros)
      pendingMacros.setLen(0)
      {.gcsafe.}:
        withLock appState.lock:
          for issued in completedMacros.mitems:
            var native: seq[tuple[started: MonoTime, facts: DecisionAttempt]]
            for id, issue in appState.issuedDecisions:
              if issue.seat == issued.seat and issue.turn == issued.turn and
                  appState.nativeFinished.hasKey(id):
                var facts = readAttemptEvidence(appState.nativeFinished[id])
                for parsed in issued.attempts:
                  if parsed.attemptId == facts.attemptId:
                    facts.parsedAction = parsed.parsedAction
                    facts.accepted = parsed.accepted
                    facts.rejectionReason = parsed.rejectionReason
                native.add((issue.issuedAt, facts))
            native.sort(proc(a, b: tuple[started: MonoTime, facts: DecisionAttempt]): int =
              cmp(a.started, b.started))
            if native.len > 0:
              issued.attempts.setLen(0)
              for retained in native: issued.attempts.add(retained.facts)
            elif issued.attempts.len == 0:
              var local = newDecisionAttempt(issued.decisionId & "-local",
                "engine-scripted", if issued.status == asFallback: aoFallback else: aoUnknown)
              if issued.status == asAccepted:
                local.response = %($issued.action)
                local.parsedAction = issued.action
                local.accepted = true
                issued.selected = some(local.attemptId)
              issued.attempts.add(local)
            if issued.status != asAccepted: issued.selected = none(string)
      trajectory.get().recordMacros(completedMacros, true)
      let outcome = if status == esCompleted: parseJson(sim.playerResultsJson()) else: newJObject()
      outcome["engine_version"] = %GameVersion
      outcome["owner_failure"] = failureDetails
      outcome["runtime_inputs"] = runtimeInputs
      {.gcsafe.}:
        withLock appState.lock:
          outcome["protocol_error"] = appState.protocolError
          outcome["final_player_frames"] = appState.finalFrames
          outcome["rejected_player_frames"] = appState.rejectedFrames
      outcome["all_player_workers_joined"] = %allJoined
      outcome["execution"] = %*{"control_encoding": "u8-tick-major-seat-order",
        "start_tick": executionStartTick, "end_tick": executionEndTick,
        "display_end_tick": sim.tickCount, "tick_hz": TargetFps,
        "seat_count": sim.seatCount(), "controls_b64": encode(actualControls), "state_hashes": actualHashes}
      var participants = newJNull()
      if status == esCompleted:
        participants = newJArray()
        for seat in 0 ..< sim.seatCount():
          participants.add(%*{"seat": $seat, "score": outcome["scores"][seat]})
      trajectory.get().finish(status, outcome, participants)
      trajectory.get().writePrivateEpisode(cleanupDeadline)

  defer:
    if not replayLoaded and not finalizationStarted:
      finalizationStarted = true
      requestNativeStop()
      let cleanupDeadline = min(episodeDeadline, getMonoTime() + initDuration(seconds = 5))
      let allJoined = stopPlayers(cleanupDeadline)
      freezePlayerEvidence()
      let failure = getCurrentException()
      doAssert failure != nil
      sealPrivate(esFailed, allJoined, cleanupDeadline,
        %*{"type": $failure.name, "message": failure.msg, "stack": failure.getStackTrace()})
  initializedOwner = true
  sim.collectEvents = eventsPath.len > 0
  var collectedEvents: seq[SimEvent] = @[]


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
    if not replayLoaded and (interruptionRequested() or
        getMonoTime() >= episodeDeadline - initDuration(seconds = 5)):
      quitAfterFrame = true

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
              if not appState.chatMessages.hasKey(join.websocket) or
                  not parseRegistration(appState.chatMessages[join.websocket]).ok:
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
            if not firstRegistration: continue
            appState.operatorPrompts[websocket] = registration.prompt
            appState.policyLabels[websocket] = registration.policy
            policy.registered = true
            policy.isLlm = registration.kind in ["prompt", "external"]
            policy.baseline = parseBaseline(registration.scripted)
            policy.label =
              if registration.policy.len > 0: registration.policy
              elif policy.isLlm: registration.kind
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
          if websocket in appState.disconnected: continue
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
        "s); its piston plays the wavebot baseline", episodeDeadline)

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
        {.gcsafe.}:
          withLock appState.lock: appState.started = true
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
          if trajectory.isSome:
            for issued in pendingMacros.mitems: issued.endTick = sim.tickCount
            completedMacros.add(pendingMacros)
            pendingMacros.setLen(0)
          lastTurnIndex = turnIndex
          var seatSockets = newSeq[WebSocket](engine.seats.len)
          var seatConnected = newSeq[bool](engine.seats.len)
          for i, seat in playerIndices:
            if seat >= 0 and seat < engine.seats.len:
              seatSockets[seat] = sockets[i]
              seatConnected[seat] = true
          proc publishWaiting() {.gcsafe.} =
            {.cast(gcsafe).}:
              publishGlobalFrames(sim, replayPlayer, false, liveSpeedIndex, newJArray())
          engine.batch = playerBatch(seatSockets, seatConnected, publishWaiting)
          let elapsedSeconds = (getMonoTime() - episodeStart).inSeconds.int
          let records = engine.turn(sim, turnIndex, elapsedSeconds)
          if trajectory.isSome:
            for seat in 0 ..< engine.seats.len:
              let installed = engine.phaseInstalled[seat]
              let action = if installed: appliedScriptAction(engine.scripts[seat]) else: newJNull()
              let status = if not installed: asMissing
                elif engine.scripts[seat].source == srcFallback: asFallback
                else: asAccepted
              pendingMacros.add(StagedMacro(decisionId: $turnIndex & "-" & $seat,
                seat: seat, turn: turnIndex, startTick: sim.tickCount,
                observation: engine.phaseViews[seat], action: action, status: status,
                attempts: engine.phaseAttempts[seat], selected: engine.phaseSelected[seat]))
          if interruptionRequested(): quitAfterFrame = true
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
      if not interruptionRequested() and not quitAfterFrame:
        let wasPlaying = sim.phase == Playing
        if trajectory.isSome and wasPlaying:
          if executionStartTick < 0:
            executionStartTick = sim.tickCount
            actualHashes.add(%($sim.gameHash()))
        let tickBeforeStep = sim.tickCount
        var faultRule = ""
        try:
          sim.step(commands)
        except SimGuardError as guard:
          echo "pistonball: SIM GUARD tripped at tick ", sim.tickCount, ": ",
            guard.msg
          faultRule = EndRuleSimFault
        if faultRule.len > 0:
          sim.finishGame(ReasonFault, faultRule)
          quitAfterFrame = true
        replayWriter.writeHash(uint32(sim.tickCount), sim.gameHash())
        if trajectory.isSome and wasPlaying and sim.tickCount > tickBeforeStep:
          doAssert sim.tickCount == tickBeforeStep + 1
          for command in commands: actualControls.add(char(command))
          for issued in pendingMacros.mitems:
            issued.controls.add(char(commands[issued.seat]))
          executionEndTick = sim.tickCount
          actualHashes.add(%($sim.gameHash()))
          if sim.phase == GameOver:
            for issued in pendingMacros.mitems: issued.endTick = executionEndTick
            completedMacros.add(pendingMacros)
            pendingMacros.setLen(0)
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

    publishGlobalFrames(sim, replayPlayer, replayLoaded, liveSpeedIndex, frameEvents)

    if quitAfterFrame:
      finalizationStarted = true
      let cleanupDeadline = min(episodeDeadline, getMonoTime() + initDuration(seconds = 5))
      let allJoined = stopPlayers(cleanupDeadline)
      freezePlayerEvidence()
      var protocolFailed: bool
      {.gcsafe.}:
        withLock appState.lock: protocolFailed = appState.protocolFailure
      let status = if protocolFailed or sim.endReason == ReasonFault: esFailed
        elif interruptionRequested() or not allJoined or sim.phase != GameOver: esTruncated
        else: esCompleted
      if status != esCompleted: requestNativeStop()
      sealPrivate(status, allJoined, cleanupDeadline, newJNull())
      {.gcsafe.}:
        withLock appState.lock: appState.finished = true
      if status == esCompleted:
        replayWriter.writeChat(tickTime(sim.tickCount), 0, resultRecord(sim))
        replayWriter.closeReplayWriter()
        if saveReplayPath.len > 0 and fileExists(saveReplayPath):
          writeCogameArtifact(runtimeConfig.replayUri, readFile(saveReplayPath),
            "application/octet-stream", "pistonball replay", cleanupDeadline)
        if eventsPath.len > 0:
          writeFile(eventsPath, collectedEvents.eventsJsonl(sim.tickCount))
        if runtimeConfig.resultsUri.len > 0:
          writeCogameArtifact(runtimeConfig.resultsUri, sim.playerResultsJson() & "\n",
            "application/json", "pistonball results", cleanupDeadline)
        if metricsPath.len > 0:
          writeFile(metricsPath, $(%*{"ticks": sim.tickCount, "frames": framesPlayed,
            "reason": sim.endReason, "endRule": sim.endRule}) & "\n")
      echo "pistonball finished: reason=", sim.endReason, " endRule=",
        sim.endRule, " ticks=", sim.tickCount,
        " score=", pointsText(sim.scoreMilli())
      # --- named edit 5: bounded shutdown grace ---------------------------
      let graceUntil =
        min(episodeDeadline, getMonoTime() + initDuration(seconds = ShutdownGraceSeconds))
      while status == esCompleted and not interruptionRequested() and getMonoTime() < graceUntil:
        sleep(200)
      break

    runFrameLimiter(lastTick, not replayLoaded and config.fastMode,
      sockets, playerIndices, sim.seatCount())

proc gameOwner(args: ptr GameOwnerArgs) {.thread.} =
  try:
    # The owner exclusively mutates rendering/simulation state; callbacks use
    # appState.lock. The argument storage lives until the main thread joins.
    {.cast(gcsafe).}:
      runGameOwnerLoop(args.server, args.initialConfig, args.saveReplayPath,
        args.loadReplayPath, args.runtimeConfig, args.episodeDeadline, args.runtimeInputs)
  except CatchableError as error:
    # Details were sealed privately during unwinding. This fixed-size result
    # has one writer; main reads it only after joining the owner.
    args.failed = true
    let name = $error.name
    args.failureTypeLen = min(name.len, args.failureType.len)
    for index in 0 ..< args.failureTypeLen: args.failureType[index] = name[index]
  finally:
    requestNativeStop()
    args.server.close()

proc runServerLoop*(host: string, port: int, initialConfig: GameConfig,
    saveReplayPath, loadReplayPath: string, runtimeConfig: RuntimeConfig,
    episodeDeadline: MonoTime, runtimeInputs: JsonNode) =
  initAppState()
  appState.config = initialConfig
  appState.replayLoaded = loadReplayPath.len > 0
  if loadReplayPath.len > 0: appState.replayBytes = readFile(loadReplayPath)
  # Bake real frame assets before a socket can start its first-frame clock.
  warmBoardRenderCaches()
  let httpServer = newServer(httpHandler, websocketHandler, workerThreads = 4,
    maxMessageLen = MaxIncomingEvidenceBytes)
  var args = GameOwnerArgs(server: httpServer, initialConfig: initialConfig,
    saveReplayPath: saveReplayPath, loadReplayPath: loadReplayPath,
    runtimeConfig: runtimeConfig, episodeDeadline: episodeDeadline, runtimeInputs: runtimeInputs)
  var owner: Thread[ptr GameOwnerArgs]
  var ownerStarted = false
  let argumentStorage = addr args
  proc onReady(server: Server) {.gcsafe.} =
    createThread(owner, gameOwner, argumentStorage)
    ownerStarted = true
  try:
    httpServer.serve(Port(port), host, onReady)
  finally:
    requestNativeStop()
    if ownerStarted:
      joinThread(owner)
    elif loadReplayPath.len == 0:
      let failure = getCurrentException()
      doAssert failure != nil
      writeInitializationCheckpoint(esFailed, "listener", $failure.name, failure.msg,
        episodeDeadline, runtimeInputs)
  if args.failed:
    var name = ""
    for index in 0 ..< args.failureTypeLen: name.add(args.failureType[index])
    raise newException(PistonballError, "game owner failed (" & name & ")")
