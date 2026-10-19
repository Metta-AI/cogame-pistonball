## Prompt inference in the ordinary player container.

import
  std/[json, os, strutils],
  curly,
  ./sim_types, ./scripts, ./prompts

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"

type
  LlmTransport* = enum
    ltNone, ltSidecar, ltAnthropic

  LlmClient* = ref object
    curl*: Curly
    transport*: LlmTransport
    apiKey: string
    sidecarEndpoint: string
    model*: string
    maxOutputTokens*: int
    disabled*: bool
    throttled*: bool
      ## A 429 ends this seat's attempt without retrying the same turn.

  LlmError* = object of ValueError

proc resolveApiKey(): string =
  getEnv("ANTHROPIC_API_KEY").strip()

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: (if config.model.len > 0: config.model
            else: "claude-haiku-4-5-20251001"),
    maxOutputTokens: max(1, config.maxOutputTokens)
  )
  let sidecarEndpoint = getEnv("COWORLD_LLM_ENDPOINT").strip()
  if sidecarEndpoint.len > 0:
    result.transport = ltSidecar
    result.sidecarEndpoint = sidecarEndpoint.strip(chars = {'/'}, leading = false)
    result.model = getEnv("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5")
    result.curl = newCurly()
    echo "pistonball llm: sidecar transport, model ", result.model
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
  client: LlmClient, system, user: string, slot: int
): tuple[url: string, headers: HttpHeaders, body: string] =
  ## One Messages-API request, shaped for whichever transport is live.
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  if client.transport == ltSidecar and slot >= 0:
    headers["X-Coworld-Player-Slot"] = $slot
  headers["content-type"] = "application/json"
  body["model"] = %client.model
  if client.transport == ltSidecar:
    result.url = client.sidecarEndpoint & "/v1/messages"
  else:
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    result.url = AnthropicUrl
  headers["anthropic-version"] = AnthropicVersion
  result.headers = headers
  result.body = $body

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
    client.disabled = true
    raise newException(
      LlmError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
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
const CanonicalIntroduction = """
You are ONE piston in a bank of twenty standing side by side under a heavy ball.
The bank's job is to roll the ball LEFT, from the right wall to the left wall.
"""

const Rules = """
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
"""

const ReplyRules = """Reply with a single JSON object and NOTHING else. Your reply MUST begin with '{'.
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

proc systemPrompt*(selection: PromptSelection, config: GameConfig): string =
  let cadence = formatFloat(float(config.turnTicks) / 24.0, ffDecimal, 1)
  let idleCost = formatFloat(float(config.maxTicks) * 0.01, ffDecimal, 0)
  if selection.selectedVariant == pvCanonical:
    return CanonicalIntroduction & Rules.replace("9.4", cadence).replace("-18.", "-" & idleCost & ".") & ReplyRules
  let bank = "You control one piston in a row of twenty beneath a heavy ball. Together, " &
    "move the ball LEFT from the right wall to the left wall. Piston 0 borders the left " &
    "goal; piston 19 is at the right starting end. Each piston is 0.40 metres wide and " &
    "moves between 0.00 and 1.60 metres high at up to 1.92 metres/second. Pistons lift " &
    "the ball and cannot be pushed down by it."
  let visibility = "Your window extends one metre to either side, covering five piston columns. " &
    "The ball is visible only inside that window and is absent most of the time. Use your " &
    "last sighting and neighbouring piston heights while it is unseen. You cannot talk to " &
    "other pistons, and they never receive anything you write."
  let motion = "The ball rolls downhill. To move it left, raise pistons BEHIND it, on its " &
    "RIGHT at larger x, and lower pistons IN FRONT, on its LEFT. Raising early creates " &
    "a wall the ball cannot climb; raising late misses it after it passes. Timing matters."
  let control = "Set your program every " & cadence & " seconds for the next " & cadence &
    " seconds. A deterministic controller watches your window and runs the program 24 " &
    "times each second. Choose when to react and how far to move; the controller executes those reactions."
  let reward = "All twenty pistons receive the same score: +100 for delivery to the left wall, " &
    "minus 0.24 points per second spent. Doing nothing for the full configured run scores -" & idleCost & "."
  let briefing = case selection.selectedVariant
    of pvPlain: bank & "\n\n" & visibility & "\n\n" & motion & "\n\n" & control & "\n\n" & reward
    of pvNumbered: "1. Bank\n" & bank & "\n2. Visibility\n" & visibility & "\n3. Rolling\n" & motion & "\n4. Program\n" & control & "\n5. Shared score\n" & reward
    of pvQuestions: "What are we trying to achieve?\n" & bank & "\nHow are we scored?\n" & reward & "\nWhat can I see?\n" & visibility & "\nHow do I move the ball?\n" & motion & "\nWhen do I act?\n" & control
    of pvReordered: "TEAM SCORE\n" & reward & "\nPROGRAM TIMING\n" & control & "\nINFORMATION\n" & visibility & "\nROLLING\n" & motion & "\nBANK\n" & bank
    of pvHeldoutBriefing: "Read the assignment.\n" & bank & "\nAccount for limited sight.\n" & visibility & "\nPlan the slope.\n" & motion & "\nSchedule the controller.\n" & control & "\nEvaluate the outcome.\n" & reward
    of pvHeldoutReference: "Visibility reference: " & visibility & "\nScoring reference: " & reward & "\nMotion reference: " & motion & "\nTiming reference: " & control & "\nGeometry reference: " & bank
    of pvCanonical, pvMixed: raise newException(ValueError, "alternate wording must resolve")
  briefing & "\n\n" & ReplyRules

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
