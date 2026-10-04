## Native sidecar inference owned by the ordinary player container.
## Omitted ordinary temperature remains omitted; sampling needs an explicit value.

import std/[base64, json, math, monotimes, options, os, sets, strutils, tables]
import bitworld/[decision_trajectory, native_http]
from std/unicode import validateUtf8
import ./sim_types, ./scripts

const AnthropicVersion = "2023-06-01"

type
  LlmError* = object of ValueError
  LlmClient* = ref object
    sidecarEndpoint: string
    model*: string
    maxOutputTokens*: int
    temperature*: Option[float]
    disabled*: bool
    throttled*: bool
    lastAttempt*: DecisionAttempt
    attempts*: seq[DecisionAttempt]

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(model: getEnv("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5"),
    maxOutputTokens: max(1, config.maxOutputTokens))
  result.sidecarEndpoint = getEnv("COWORLD_LLM_ENDPOINT").strip().strip(
    chars = {'/'}, leading = false)
  result.disabled = result.sidecarEndpoint.len == 0
  let explicitTemperature = getEnv("COWORLD_LLM_TEMPERATURE").strip()
  if explicitTemperature.len > 0:
    let temperature = parseFloat(explicitTemperature)
    if classify(temperature) in {fcNan, fcInf, fcNegInf} or
        temperature < 0 or temperature > 2:
      raise newException(LlmError, "COWORLD_LLM_TEMPERATURE must be finite and in 0..2")
    result.temperature = some(temperature)

proc requestFor*(client: LlmClient, system, user: string,
    slot: int): tuple[url: string, headers: HttpHeaders, body: string] =
  if slot < 0:
    raise newException(LlmError, "native inference requires the issued player slot")
  if client.disabled:
    raise newException(LlmError, "native inference endpoint is not configured")
  result.url = client.sidecarEndpoint & "/v1/messages"
  result.headers["content-type"] = "application/json"
  result.headers["anthropic-version"] = AnthropicVersion
  result.headers["X-Coworld-Player-Slot"] = $slot
  var body = %*{"model": client.model, "max_tokens": client.maxOutputTokens,
    "system": system, "messages": [{"role": "user", "content": user}]}
  if client.temperature.isSome: body["temperature"] = %client.temperature.get()
  result.body = $body

proc textOf*(client: LlmClient, response: NativeHttpResponse): string =
  client.lastAttempt.latencyMs = response.latencyMs
  client.lastAttempt.responseReaderJoined = response.responseReaderJoined
  let observedResponse = response.httpStatus.isSome or response.headerBytes.len > 0 or response.bodyBytes.len > 0
  if observedResponse:
    client.lastAttempt.responseBodyB64 = some(encode(response.bodyBytes))
    client.lastAttempt.responseHeadersB64 = some(encode(response.headerBytes))
    client.lastAttempt.responseComplete = some(response.transferComplete)
    client.lastAttempt.httpStatus = response.httpStatus
    if validateUtf8(response.bodyBytes) == -1:
      client.lastAttempt.rawResponse = %response.bodyBytes
  if validateUtf8(response.headerBytes) != -1:
    raise newException(LlmError, "received HTTP headers are not valid UTF-8")
  var responseHeaders: HttpHeaders
  var receivedHeaders = initTable[string, string]()
  var identityHeaders = initHashSet[string]()
  for line in response.headerBytes.splitLines():
    if line.startsWith("HTTP/"):
      responseHeaders.setLen(0)
      receivedHeaders.clear()
      identityHeaders.clear()
    elif line.len > 0:
      let colon = line.find(':')
      if colon <= 0:
        raise newException(LlmError, "invalid received HTTP header")
      let name = line[0 ..< colon]
      let value = line[colon + 1 .. ^1].strip()
      let normalized = name.toLowerAscii()
      if normalized in ["request-id", "x-request-id", "x-softmax-llm-call-id",
          "x-coworld-checkpoint-sha256", "x-coworld-tokenizer-sha256",
          "x-coworld-chat-template-sha256"]:
        if normalized in identityHeaders:
          raise newException(LlmError, "duplicate received identity header")
        identityHeaders.incl(normalized)
      responseHeaders.add((name, value))
      receivedHeaders[name] = value
  if observedResponse:
    client.lastAttempt.responseHeaders = some(receivedHeaders)
  if responseHeaders.contains("request-id") and responseHeaders.contains("x-request-id") and
      responseHeaders["request-id"] != responseHeaders["x-request-id"]:
    raise newException(LlmError, "conflicting received request identity headers")
  for key in ["request-id", "x-request-id"]:
    if responseHeaders.contains(key):
      client.lastAttempt.providerRequestId = some(responseHeaders[key])
      break
  for (header, field) in [
      ("x-softmax-llm-call-id", "call"),
      ("x-coworld-checkpoint-sha256", "model"),
      ("x-coworld-tokenizer-sha256", "tokenizer"),
      ("x-coworld-chat-template-sha256", "template")]:
    if responseHeaders[header].len > 0:
      case field
      of "call":
        let identity = responseHeaders[header]
        if identity.len != 36:
          raise newException(LlmError, "received platform call identity is not a UUID")
        for index, character in identity:
          if index in [8, 13, 18, 23]:
            if character != '-':
              raise newException(LlmError, "received platform call identity is not a UUID")
          elif character notin {'0'..'9', 'a'..'f', 'A'..'F'}:
            raise newException(LlmError, "received platform call identity is not a UUID")
        client.lastAttempt.platformCallId = some(identity)
      of "model": client.lastAttempt.modelIdentity = some(responseHeaders[header])
      of "tokenizer": client.lastAttempt.tokenizerIdentity = some(responseHeaders[header])
      else: client.lastAttempt.chatTemplateSha256 = some(responseHeaders[header])
  if response.kind != nhComplete:
    raise newException(LlmError, "native transport " & $response.kind)
  let status = response.httpStatus.get()
  if status == 401 or status == 403:
    client.disabled = true
    raise newException(LlmError, "native inference auth failed (" & $status & ")")
  if status == 429:
    client.throttled = true
    raise newException(LlmError, "native inference throttled (429)")
  if status < 200 or status >= 300:
    raise newException(LlmError, "native inference error " & $status)
  let payload = parseJson(response.bodyBytes)
  if payload.kind != JObject or payload["model"].kind != JString or
      payload["content"].kind != JArray:
    raise newException(LlmError, "native response violates the completion schema")
  client.lastAttempt.model = some(payload["model"].getStr())
  case payload["stop_reason"].kind
  of JString: client.lastAttempt.stopReason = some(payload["stop_reason"].getStr())
  of JNull: discard
  else: raise newException(LlmError, "native stop reason must be text or null")
  if payload.hasKey("usage") and payload["usage"].kind != JNull:
    let usage = payload["usage"]
    if usage.kind != JObject or usage["input_tokens"].kind != JInt or
        usage["output_tokens"].kind != JInt or usage["input_tokens"].getInt() < 0 or
        usage["output_tokens"].getInt() < 0:
      raise newException(LlmError, "native usage must contain nonnegative integer counts")
    client.lastAttempt.inputTokens = some(usage["input_tokens"].getInt())
    client.lastAttempt.outputTokens = some(usage["output_tokens"].getInt())
  if payload.hasKey("sampling_evidence") and payload["sampling_evidence"].kind != JNull:
    let sampling = payload["sampling_evidence"]
    if sampling.kind != JObject or sampling["prompt_token_ids"].kind != JArray or
        sampling["completion_token_ids"].kind != JArray or sampling["stop_reason"].kind != JString:
      raise newException(LlmError, "native sampling evidence violates the token schema")
    if not client.lastAttempt.request.hasKey("temperature"):
      raise newException(LlmError, "sampling evidence requires an explicitly requested temperature")
    let requestTemperature = client.lastAttempt.request["temperature"].getFloat()
    if not sampling.hasKey("sampling") or sampling["sampling"].kind != JString:
      raise newException(LlmError, "native sampling evidence requires its declared mode")
    case sampling["sampling"].getStr()
    of "full_softmax_temperature_one":
      if requestTemperature != 1 or sampling.hasKey("temperature"):
        raise newException(LlmError, "unit sampling differs from the original request temperature")
    of "full_softmax":
      if not sampling.hasKey("temperature") or sampling["temperature"].kind notin {JInt, JFloat}:
        raise newException(LlmError, "tempered sampling requires an explicit temperature")
      let temperature = sampling["temperature"].getFloat()
      if classify(temperature) in {fcNan, fcInf, fcNegInf} or temperature <= 0 or
          temperature > 2 or temperature != requestTemperature:
        raise newException(LlmError, "tempered sampling differs from the original request temperature")
    else:
      raise newException(LlmError, "unsupported native sampling mode")
    var promptIds, sampledIds: seq[int]
    var probabilities: seq[float]
    for token in sampling["prompt_token_ids"]:
      if token.kind != JInt or token.getInt() < 0:
        raise newException(LlmError, "native prompt token IDs must be nonnegative integers")
      promptIds.add(token.getInt())
    for token in sampling["completion_token_ids"]:
      if token.kind != JInt or token.getInt() < 0:
        raise newException(LlmError, "native sampled token IDs must be nonnegative integers")
      sampledIds.add(token.getInt())
    if sampling["behavior_log_probs"].kind != JNull:
      if sampling["behavior_log_probs"].kind != JArray:
        raise newException(LlmError, "native draw probabilities must be an array or null")
      for probability in sampling["behavior_log_probs"]:
        if probability.kind notin {JInt, JFloat} or
            classify(probability.getFloat()) in {fcNan, fcInf, fcNegInf} or probability.getFloat() > 0:
          raise newException(LlmError, "native draw probabilities must be finite nonpositive numbers")
        probabilities.add(probability.getFloat())
      if probabilities.len != sampledIds.len:
        raise newException(LlmError, "native draw probabilities must match sampled token IDs")
    client.lastAttempt.promptTokenIds = some(promptIds)
    client.lastAttempt.sampledTokenIds = some(sampledIds)
    if sampling["behavior_log_probs"].kind != JNull:
      client.lastAttempt.behaviorLogprobs = some(probabilities)
    client.lastAttempt.stopReason = some(sampling["stop_reason"].getStr())
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LlmError, "native inference refusal")
  for contentBlock in payload["content"]:
    if contentBlock.kind != JObject or contentBlock["type"].kind != JString:
      raise newException(LlmError, "native content block violates the completion schema")
    if contentBlock["type"].getStr() == "text":
      if contentBlock["text"].kind != JString:
        raise newException(LlmError, "native text content must be text")
      result.add(contentBlock["text"].getStr())
  client.lastAttempt.response = %result
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LlmError, "native reply ended before a JSON action")

proc call*(client: LlmClient, system, user: string, deadline: MonoTime,
    slot: int, attemptId, policy: string, control: var NativeRequestControl,
    beforeCall: proc(attempt: DecisionAttempt) {.closure, gcsafe.}): string =
  let request = client.requestFor(system, user, slot)
  client.lastAttempt = newDecisionAttempt(attemptId, policy, aoModel)
  client.lastAttempt.prompt = %*[{"role": "system", "content": system},
    {"role": "user", "content": user}]
  client.lastAttempt.request = parseJson(request.body)
  client.lastAttempt.model = some(client.model)
  client.lastAttempt.decoder = %*{"max_tokens": client.maxOutputTokens}
  if client.temperature.isSome:
    client.lastAttempt.decoder["temperature"] = %client.temperature.get()
  defer: client.attempts.add(client.lastAttempt)
  beforeCall(client.lastAttempt)
  let response = performNativePost(request.url, request.headers, request.body,
    deadline, control)
  client.textOf(response)

## The system prompt is the design note's, word for word, with ONE deliberate
## difference: the `wave` and `catch` clauses say the ball is
## "at-or-LEFT-of me", where design.md:520-527 says "at-or-right-of me".
##
## The note's prompt block is the internally inconsistent one, and everything
## else in the repo agrees with the text below. The controller fires both
## clauses on `dxp <= 0` — ball at or left of my centre — at `control.nim:65`
## and `control.nim:75`; the note's own controller table (design.md:602,607)
## says the same; so does its phase rule (design.md:268, "UP when
## centreX_i >= ballX"); so does `docs/SCRIPTS.md`. A prompt that told the
## model the opposite of what the controller does would make every LLM seat
## worse than the baseline it is measured against, in a way no test could
## see, because a script is legal whichever way it points.
const SystemPrompt* = """
You are ONE piston in a bank of twenty standing side by side under a heavy ball.
The bank's job is to roll the ball LEFT, from the right wall to the left wall.
Piston 0 is at the far left, next to the goal; piston 19 is at the far right,
where the ball starts. Each piston is 0.40 m wide and can raise its head from
0.00 m to 1.60 m at up to 1.92 m/s. Pistons are solid: they lift the ball, the
ball never pushes them down.
YOU CAN ONLY SEE ONE METRE EITHER SIDE OF YOURSELF. That is five piston columns.
You see the ball only while it is inside that window - most of the time it is
not, and you have to act on your last sighting and on your neighbours' heights.
You cannot talk to anyone and nobody sees anything you write.
THE MECHANISM: the ball rolls DOWNHILL. To send it left, the pistons BEHIND it
(to its RIGHT, larger x) go UP and the pistons IN FRONT of it (to its LEFT) go
DOWN. Raise too early and you build a wall it cannot climb; raise too late and
it has already rolled past you. Timing is the whole game.
Every 9.4 seconds you set your piston's PROGRAM for the next 9.4 seconds. A
deterministic controller runs it 24 times a second, watching your window for
you: you choose WHEN to act and HOW FAR to move, it does the reacting.
Everyone in the bank gets the SAME score: +100 for delivering the ball to the
left wall, minus 0.24 points for every second the run takes. Doing nothing
scores -18.
Reply with a single JSON object and NOTHING else. Your reply MUST begin with '{'.
Schema:
{"note":"<=160 chars, your reasoning",
 "mode":"wave"|"lift"|"drop"|"hold"|"catch"|"ripple",
   // wave   : ball within trigger_m and at-or-LEFT-of me (I am BEHIND it,
   //          on the side it came from) -> up_m; within trigger_m and to my
   //          RIGHT (I am IN FRONT of it) -> down_m; else idle_m
   // lift   : ball anywhere in my window -> up_m, else idle_m
   // drop   : ball anywhere in my window -> down_m, else idle_m
   // hold   : always idle_m
   // catch  : up_m ONLY when the ball is rolling RIGHT (the wrong way) and is
   //          at-or-LEFT-of me within trigger_m, so my head is the wall it
   //          runs into; otherwise idle_m
   // ripple : a 2 s travelling wave along the bank, blind, ignores the ball
 "trigger_m":0.0..1.0,   // how near the ball must be before I act
 "lead_ticks":0..24,     // aim at where the ball will be in this many ticks
 "up_m":0.0..1.6,        // my raised height
 "down_m":0.0..1.6,      // my lowered height
 "idle_m":0.0..1.6,      // where I sit when the rule does not apply
 "speed":0.0..1.0,       // fraction of my 1.92 m/s I use to get there
 "blind":"hold"|"idle"|"ripple",  // what I do while I cannot see the ball
 "say":"<=48 chars"}     // spectators only; no other piston ever sees it
"""

proc operatorBlock*(prompt: string): string =
  ## The seat's own PLAYER_PROMPT, under a heading that tells the model how
  ## much weight it carries. Never echoed into the replay or the results.
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" &
    prompt.truncateRunes(MaxPromptRunes) & "\n\n"

proc userMessage*(operatorPrompt: string, viewJson: string): string =
  ## The user message: the operator's guidance, a blank line, then the seat's
  ## own window. The window is built server-side by `windowView` (decide.nim)
  ## and is the ONLY thing the model is told about the world.
  operatorBlock(operatorPrompt) & viewJson
