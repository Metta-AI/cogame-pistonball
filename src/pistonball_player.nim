## Ordinary container player owns native inference and joins before STOP acknowledgement.
import std/[atomics, json, locks, math, monotimes, options, os, strutils, times]
import bitworld/[decision_trajectory, native_http, native_stop, native_websocket,
  spriteprotocol]
import pistonball/[llm, scripts, sim_config, sim_types]

type PlayerCall = object
  socket: ptr NativeWebSocket
  decisionId, attemptId, observation, systemPrompt, operatorPrompt, policy: string
  deadline: MonoTime
  slot: int
  retry: bool

var
  worker: Thread[void]
  jobs: Channel[PlayerCall]
  busy, cancelPending: Atomic[bool]
  evidenceLock: Lock
  activeControl: ptr NativeRequestControl
  workerEvidence: string

initLock(evidenceLock)

proc cancelDecision() =
  cancelPending.store(true)
  withLock evidenceLock:
    if activeControl != nil: activeControl[].cancelNativeRequest()

proc retainEvidence(call: PlayerCall, attempt: DecisionAttempt) {.gcsafe.} =
  let record = %*{"decision_id": call.decisionId,
    "training_attempt": attempt.attemptEvidenceJson()}
  {.gcsafe.}:
    withLock evidenceLock:
      var records = if workerEvidence.len > 0: parseJson(workerEvidence) else: newJArray()
      var replaced = false
      for index in 0 ..< records.len:
        if records[index]["training_attempt"]["attempt_id"] == %attempt.attemptId:
          records.elems[index] = record
          replaced = true
          break
      if not replaced: records.add(record)
      workerEvidence = $records

proc runDecision(call: PlayerCall, client: LlmClient) {.gcsafe.} =
  var control: NativeRequestControl
  {.gcsafe.}:
    withLock evidenceLock:
      activeControl = control.addr
      if cancelPending.load(): control.cancelNativeRequest()
  defer:
    {.gcsafe.}:
      withLock evidenceLock: activeControl = nil
    busy.store(false)
  var reply = %*{"type": "action", "decision_id": call.decisionId,
    "attempt_id": call.attemptId, "source": "fallback",
    "training_attempt": newJNull()}
  if client.disabled:
    reply["cause"] = %"no_endpoint"
  else:
    let started = proc(attempt: DecisionAttempt) {.gcsafe.} =
      call.retainEvidence(attempt)
      let sent = call.socket[].sendNativeText($ %*{
        "type": "attempt_started", "decision_id": call.decisionId,
        "attempt_id": call.attemptId, "training_attempt": attempt.attemptEvidenceJson()}, call.deadline)
      if sent.kind != wsReady:
        raise newException(LlmError, "private attempt start was not delivered")
    var user = userMessage(call.operatorPrompt, call.observation)
    if call.retry:
      user.add("\n\nYour previous reply was unusable. Return only JSON.")
    client.throttled = false
    try:
      let text = client.call(call.systemPrompt, user, call.deadline, call.slot,
        call.attemptId, call.policy, control, started)
      reply["action"] = extractJsonObject(text)
      reply["source"] = %"llm"
    except ScriptError:
      reply["cause"] = %"parse_error"
      client.lastAttempt.rejectionReason = some("model response did not contain a JSON proposal")
    except CatchableError:
      reply["cause"] = %(if client.throttled: "throttled" else: "transport_error")
      client.lastAttempt.rejectionReason = some("native completion rejected")
    reply["training_attempt"] = client.lastAttempt.attemptEvidenceJson()
    call.retainEvidence(client.lastAttempt)
  if interruptionRequested() or control.nativeRequestCanceled(): return
  discard call.socket[].sendNativeText($reply, call.deadline)

proc runWorker() {.gcsafe.} =
  let client = newLlmClient(defaultGameConfig())
  while not interruptionRequested():
    let received = jobs.tryRecv()
    if received.dataAvailable:
      runDecision(received.msg, client)
    else:
      sleep(5)

proc stopAndAcknowledge(socket: NativeWebSocket, decisionId, stopId: JsonNode,
    cleanupDeadline: MonoTime): bool =
  requestNativeStop()
  cancelDecision()
  joinThread(worker)
  var attempts = newJArray()
  withLock evidenceLock:
    if workerEvidence.len > 0: attempts = parseJson(workerEvidence)
  let sent = socket.sendCleanupText($ %*{"type": "stopped",
    "decision_id": decisionId, "stop_id": stopId,
    "worker_status": "joined", "attempts": attempts}, cleanupDeadline)
  if sent.kind != wsReady: return false
  while getMonoTime() < cleanupDeadline:
    let received = socket.receiveCleanupText(cleanupDeadline)
    if received.kind != wsMessage: return false
    let frame = parseJson(received.data)
    if frame["type"].getStr() == "evidence_received" and
        frame["decision_id"] == decisionId and frame["stop_id"] == stopId:
      return true
  false

when isMainModule:
  installNativeStopHandlers()
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0: quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let prompt = getEnv("PLAYER_PROMPT").truncateRunes(MaxPromptRunes)
  let scripted = getEnv("PLAYER_SCRIPTED").strip()
  let kind = if prompt.strip().len > 0: "prompt" else: "scripted"
  let baseline = if scripted.len > 0: scripted else: "wavebot"
  let policy = getEnv("PLAYER_POLICY_LABEL", if kind == "prompt": "prompt" else: baseline)
    .truncateRunes(MaxPolicyLabelRunes)
  let timeout = getEnv("COWORLD_TIMEOUT_SECONDS", "1200").parseFloat()
  if timeout <= 0 or classify(timeout) in {fcNan, fcInf, fcNegInf}:
    raise newException(ValueError, "player timeout must be finite and positive")
  let started = getMonoTime()
  let deadline = started + initDuration(nanoseconds = int64(timeout * 1_000_000_000))
  let connectDeadline = min(deadline, started + initDuration(seconds = 120))
  var socket: NativeWebSocket
  while getMonoTime() < connectDeadline and not interruptionRequested():
    let connection = connectNativeWebSocket(url,
      min(connectDeadline, getMonoTime() + initDuration(milliseconds = 500)), 16 * 1024 * 1024)
    case connection.kind
    of wsReady:
      socket = connection.socket
      break
    of wsInterrupted: quit(0)
    of wsMessage, wsClosed:
      raise newException(ValueError, "invalid player connection state")
    of wsDeadline, wsFailure: discard
    sleep(5)
  if socket == nil:
    if interruptionRequested(): quit(0)
    raise newException(ValueError, "player connection deadline expired")
  var decisionId = newJNull()
  var slot = -1
  var cleanupBudgetMs = 0
  var joined = false
  var registered = false
  jobs.open()
  createThread(worker, runWorker)
  try:
    while getMonoTime() < deadline:
      if interruptionRequested(): break
      let received = socket.receiveNativeMessage(min(deadline,
        getMonoTime() + initDuration(milliseconds = 50)))
      case received.kind
      of wsDeadline, wsInterrupted: continue
      of wsClosed: break
      of wsMessage: discard
      else: raise newException(ValueError, "player transport failed")
      if received.messageKind.get() == wsmBinary:
        let ready = sendNativeBinary(socket, $char(SpriteClientReady), deadline)
        if ready.kind != wsReady: break
        continue
      let payload = parseJson(received.data)
      case payload["type"].getStr()
      of "welcome":
        if registered: raise newException(ValueError, "duplicate player welcome")
        slot = payload["slot"].getInt()
        if slot < 0: raise newException(ValueError, "invalid player slot")
        let registration = $ %*{"type": "register", "policy": policy,
          "prompt": prompt, "kind": kind,
          "scripted": (if kind == "scripted": %baseline else: newJNull())}
        let sent = socket.sendNativeBinary(blobFromSpriteChat(registration), deadline)
        if sent.kind != wsReady: raise newException(ValueError, "player registration failed")
        registered = true
      of "decision":
        if not registered or kind != "prompt":
          raise newException(ValueError, "decision was not issued to a prompt player")
        let receivedAt = getMonoTime()
        let issuedId = payload["decision_id"]
        let attemptId = payload["attempt_id"]
        if issuedId.kind != JString or issuedId.getStr().len == 0 or
            attemptId.kind != JString or attemptId.getStr().len == 0:
          raise newException(ValueError, "decision and attempt identities must be nonempty strings")
        let budgetMs = payload["transport"]["budget_ms"].getInt()
        cleanupBudgetMs = payload["transport"]["cleanup_budget_ms"].getInt()
        if budgetMs <= 0 or cleanupBudgetMs < 0:
          raise newException(ValueError, "invalid decision transport budget")
        let decisionDeadline = min(deadline, receivedAt + initDuration(milliseconds = budgetMs))
        if busy.load(): cancelDecision()
        while busy.load() and getMonoTime() < decisionDeadline and not interruptionRequested():
          sleep(5)
        if interruptionRequested(): break
        if busy.load(): raise newException(ValueError, "previous request owner did not join")
        decisionId = issuedId
        cancelPending.store(false)
        busy.store(true)
        jobs.send(PlayerCall(socket: socket.addr, decisionId: issuedId.getStr(),
          attemptId: attemptId.getStr(), observation: $payload["view"],
          systemPrompt: payload["system"].getStr(), operatorPrompt: prompt,
          policy: policy, retry: payload["retry"].getBool(), slot: slot,
          deadline: decisionDeadline))
      of "stop":
        let stopId = payload["stop_id"]
        if stopId.kind != JString or stopId.getStr().len == 0 or
            payload["decision_id"] != decisionId:
          raise newException(ValueError, "stop does not identify the latest issued operation")
        let stopBudget = payload["cleanup_budget_ms"].getInt()
        if stopBudget < 0: raise newException(ValueError, "invalid cleanup budget")
        joined = true
        if not stopAndAcknowledge(socket, decisionId, stopId,
            min(deadline, getMonoTime() + initDuration(milliseconds = stopBudget))):
          raise newException(ValueError, "private stop evidence was not confirmed")
        break
      of "final": break
      of "turn", "state", "evidence_received": discard
      else: raise newException(ValueError, "unknown player packet")
  finally:
    var confirmed = true
    try:
      if not joined:
        confirmed = stopAndAcknowledge(socket, decisionId, newJNull(),
          min(deadline, getMonoTime() + initDuration(milliseconds = cleanupBudgetMs)))
    finally:
      jobs.close()
      closeNativeWebSocket(socket)
    if decisionId.kind == JString and not confirmed:
      raise newException(ValueError, "private interrupted evidence was not confirmed")
