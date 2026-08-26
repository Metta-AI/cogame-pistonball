## Claude-backed piston programs. A policy is just a prompt: the game server
## composes the seat's OWN one-metre window plus that seat's PLAYER_PROMPT and
## asks Claude what its piston does for the next 9.4 seconds.
##
## Ported from `coworld-ctf/src/ctf/llm.nim` behaviour for behaviour — the
## credential ladder, the single-model list, the fence-tolerant JSON
## extraction and the rune-boundary truncation are all that file's, because
## they are all scar tissue from real hosted failures.
##
## Pistonball is a SIMULTANEOUS-decision game, so ALL TWENTY seats' calls go
## out as ONE parallel batch per turn (`curly.makeRequests`). Seats are never
## queried sequentially: that is what keeps eight turns inside the wall-clock
## budget with twenty seats.
##
## Credentials, in order of preference:
##   Bedrock sidecar (AWS_ENDPOINT_URL_BEDROCK_RUNTIME + AWS_BEARER_TOKEN_BEDROCK)
##   ANTHROPIC_API_KEY
##   ANTHROPIC_API_KEY_URI
## With none of them the client disables itself and every turn falls back to
## the scripted layer INSTANTLY, with no network wait — which is what lets
## offline certification finish in seconds.

import
  std/[json, os, strutils],
  bitworld/runtime,
  curly,
  ./sim_types, ./scripts

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  LlmTransport* = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl*: Curly
    transport*: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model*: string
    maxOutputTokens*: int
    disabled*: bool
    sendBatch*: proc(batch: RequestBatch, timeoutSeconds: int): ResponseBatch
      {.gcsafe, raises: [].}
      ## The ONE call that leaves the process, behind a seam. `nil` in every
      ## build the server runs: `newLlmClient` never sets it and `sendTurnBatch`
      ## falls through to `curl.makeRequests`. It exists because the turn loop's
      ## contract — twenty seats in ONE batch, one retry and no more, a batch
      ## the throttle cancels, a hung provider that still hands the turn back
      ## inside `turnBudgetMs` — is not observable from outside the process, and
      ## a test that cannot fake the provider can only assert that a
      ## credential-less client does nothing.
    throttled*: bool
      ## The provider answered 429 and there is no other candidate model to
      ## rotate to. Set per turn, cleared by the turn loop: retrying inside
      ## the same turn cannot succeed, so the seat fails fast to the scripted
      ## fallback instead of spending the turn budget — and with TWENTY seats
      ## a pointless retry batch would burn the whole turn.

  LlmError* = object of ValueError

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "pistonball llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order; BEDROCK_MODEL pins
  ## one. There is exactly ONE candidate — haiku — because every sonnet
  ## inference profile times out on every sidecar call (cogame-raid round 2,
  ## 2026-08-23; the paintbot starter's 0.1.2 release recorded 133 consecutive
  ## timeouts against one). With no second candidate a throttle fails fast (see
  ## `LlmClient.throttled`) and the seat plays the scripted fallback for that
  ## turn only.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @["us.anthropic.claude-haiku-4-5-20251001-v1:0"]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "pistonball llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: (if config.model.len > 0: config.model
            else: "claude-haiku-4-5-20251001"),
    maxOutputTokens: max(1, config.maxOutputTokens)
  )
  let
    bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
    bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "pistonball llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel]
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "pistonball llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    ## The exact phrase phase 60 greps the GAME log for, alongside "falling
    ## back" in decide.nim: "LLM provider is unavailable".
    echo "pistonball llm: no credentials — the LLM provider is unavailable; ",
      "every turn is falling back to the scripted layer"

proc requestFor*(
  client: LlmClient, system, user: string
): tuple[url: string, headers: HttpHeaders, body: string] =
  ## One Messages-API request, shaped for whichever transport is live.
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc sendTurnBatch*(
  client: LlmClient, batch: RequestBatch, timeoutSeconds: int
): ResponseBatch =
  ## Issue one turn's whole batch and block until every request has answered
  ## or failed. `curly.makeRequests` unless a `sendBatch` seam is installed.
  if client.sendBatch != nil:
    return client.sendBatch(batch, timeoutSeconds)
  client.curl.makeRequests(batch, timeoutSeconds)

proc textOf*(
  client: LlmClient, response: Response, error, url: string
): string =
  ## The text of one batched reply, or an `LlmError` describing why there is
  ## none. Auth failure disables the client for the rest of the episode;
  ## model-access denial and throttling rotate the Bedrock model for the next
  ## batch instead.
  if error.len > 0:
    raise newException(LlmError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    ## RUNE-safe: this text becomes `fallback.detail` in the replay, and a
    ## provider body is arbitrary bytes. A byte slice can cut a codepoint in
    ## half, and truncateRunes downstream only SHORTENS — it cannot repair a
    ## broken one.
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(LlmError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(
      LlmError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if not client.tryNextBedrockModel("throttled"):
      ## Nothing left to rotate to: a second call this turn would be refused
      ## the same way, so the turn loop must not spend its retry on it.
      client.throttled = true
    raise newException(LlmError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(LlmError, "anthropic error " & $response.code & ": " &
      response.body.truncateRunes(MaxFallbackDetailRunes))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LlmError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LlmError, "reply cut off at max_tokens before any " &
      "JSON: " & result.truncateRunes(160).replace("\n", " "))

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
