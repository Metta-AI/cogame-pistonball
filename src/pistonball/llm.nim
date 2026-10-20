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
Everyone in the bank gets the SAME score: net leftward progress from the drop
point earns 100 points per 7.20 metres, floored at zero, minus 0.24 points per
second elapsed. Moving right loses progress already earned. Delivery ends the
run and its time penalty; it is not a separate bonus. Doing nothing scores -18.
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
  var idleCost = formatFloat(float(config.maxTicks) * 0.01, ffDecimal, 2)
  idleCost.trimZeros()
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
  let reward = "All twenty pistons receive the same score. Net movement left from the drop " &
    "point earns 100 points per 7.20 metres, with progress floored at zero; subtract " &
    "0.24 points per elapsed second. Moving back right reduces earned progress. " &
    "Delivery stops the run and time penalty without a separate bonus. Doing nothing " &
    "for the full configured run scores -" & idleCost & "."
  let briefing = case selection.selectedVariant
    of pvPlain: bank & "\n\n" & visibility & "\n\n" & motion & "\n\n" & control & "\n\n" & reward
    of pvNumbered:
      "1. Assignment: operate one of 20 solid pistons to carry a heavy ball from the right " &
      "wall to the LEFT wall. Number 0 stands beside the left goal; number 19 is at the " &
      "right start. A piston spans 0.40 m, reaches heights 0.00–1.60 m, and travels at " &
      "no more than 1.92 m/s. Its head lifts the ball without yielding downward to it.\n" &
      "2. Information: sight reaches one metre left and one metre right, or five columns. " &
      "You usually cannot see the ball because it is outside this area. Remember its last " &
      "appearance and consult adjacent heights. Messages cannot reach fellow pistons.\n" &
      "3. Slope: downhill motion carries the ball left when heads behind it (right, larger " &
      "x) rise and heads ahead (left) sink. An early rise blocks the ball with a wall; " &
      "a late rise happens after it has gone past.\n" &
      "4. Execution: supply a program once per " & cadence & " seconds. It governs the following " &
      cadence & " seconds, with deterministic local reactions at 24 Hz. Select the reaction " &
      "timing and movement distance; the controller monitors the window.\n" &
      "5. Reward: every seat shares net leftward travel from the drop, valued at 100 points " &
      "per 7.20 m and bounded below by zero, less 0.24 points each elapsed second. Rightward " &
      "travel gives back progress. Reaching the goal ends time charges, without a delivery " &
      "bonus. A motionless full run earns -" & idleCost & "."
    of pvQuestions:
      "What is my task? Help nineteen other pistons roll a heavy ball LEFT across the bank, " &
      "from its right wall to its left wall. The goal is beside piston 0; the starting end " &
      "is beside piston 19. Your solid head is 0.40 m across, ranges from 0.00 to 1.60 m " &
      "high, and moves at up to 1.92 m/s. It can lift the ball, which cannot force it down.\n" &
      "What information reaches me? Only a five-column window extending one metre in each " &
      "direction. The ball is generally beyond sight; use remembered sightings and nearby " &
      "head heights then. No writing or messages are shared between players.\n" &
      "Which slope works? Gravity rolls the ball downhill: raise the right-hand heads " &
      "behind it at larger x and lower the left-hand heads in front. If you rise before " &
      "the ball arrives, you obstruct it; if you wait until it passes, the lift misses.\n" &
      "How often do I decide? Every " & cadence & " seconds, choose a program lasting " &
      cadence & " seconds. Its deterministic controller checks your view 24 times per second " &
      "and reacts using your chosen timing and travel distances.\n" &
      "What earns points? All players get one score: 100 times net leftward metres since " &
      "the drop divided by 7.20, clamped to at least zero, then reduced by 0.24 per second " &
      "of play. Backtracking right forfeits progress; delivery ends play, not awards a " &
      "bonus. With no movement throughout the run, the result is -" & idleCost & "."
    of pvReordered:
      "SHARED OBJECTIVE: Everyone earns the same result. Count net displacement left of the " &
      "drop at 100 points per 7.20 m, never below zero progress, and deduct 0.24 points " &
      "for each second used. Rightward backtracking reduces that progress. Finishing at " &
      "the left wall stops the clock with no extra award. Inaction until timeout yields -" &
      idleCost & ".\n" &
      "PROGRAM: Your next submission runs for " & cadence & " seconds; submissions are " &
      cadence & " seconds apart. A deterministic controller observes locally at 24 Hz, " &
      "applying the reaction timing and height changes you specify.\n" &
      "VIEW: You see five piston columns, reaching one metre on both sides. Ball sightings " &
      "occur only within that range and are usually unavailable. Last-seen ball information " &
      "and neighbouring heights guide blind periods. Other seats receive none of your text; " &
      "there is no communication channel.\n" &
      "MECHANICS: A downhill path moves the heavy ball LEFT. Elevate the heads behind it " &
      "on the right (larger x), and depress those ahead on the left. Premature elevation " &
      "erects an impassable wall; delayed elevation lets the ball pass first.\n" &
      "LAYOUT: You own one member of a twenty-piston row. The ball starts at the right wall " &
      "near number 19 and must reach the left wall near number 0. Width is 0.40 m per " &
      "piston, height range 0.00–1.60 m, maximum speed 1.92 m/s. Solid heads push the ball " &
      "up; the ball cannot push heads down."
    of pvHeldoutBriefing:
      "Operate your assigned head as part of a twenty-piston team beneath a heavy ball. " &
      "Transport it from the right-hand wall to the LEFT-hand wall. Labels run from 0 at " &
      "the left destination to 19 at the right origin. Each head measures 0.40 m across " &
      "and can travel through 0.00–1.60 m of height at a maximum 1.92 m/s. Heads remain " &
      "solid under the ball: they raise it rather than being depressed by its weight.\n" &
      "Work with restricted sight: five columns within one metre on either side of you. " &
      "Expect the ball to be outside this field most of the time; retain earlier sightings " &
      "and read surrounding head elevations. You have no means of sending text to teammates.\n" &
      "Build a descending route to the left. The ball rolls downhill, so heads on its " &
      "trailing right side, at greater x, should lift while those on its leading left side " &
      "should descend. Lifting prematurely makes a barrier it cannot surmount; lifting " &
      "after passage wastes the opportunity.\n" &
      "Issue one program for each " & cadence & "-second interval. During that interval, " &
      "a deterministic mechanism samples your window 24 times a second and carries out " &
      "your choices of response timing and movement extent.\n" &
      "Judge success by the common team score. Credit net leftward distance from the " &
      "initial drop at a rate of 100 points for 7.20 m, flooring this credit at zero. " &
      "Deduct 0.24 points for every second consumed. Retreating right undoes distance " &
      "credit; arrival ends the run and deductions without adding a bonus. Remaining " &
      "still for the entire allotted duration produces -" & idleCost & " points."
    of pvHeldoutReference:
      "Observation boundary — a radius of one metre to left and right covers five piston " &
      "columns. Only a ball inside that area is reported, so most decisions lack a visible " &
      "ball. Prior sightings and neighbours' elevations remain useful. Written output is " &
      "not delivered to any other player, and players cannot communicate.\n" &
      "Control interval — renew your program at " & cadence & "-second intervals for the " &
      "next interval of the same length. Window-based execution is deterministic at 24 " &
      "updates per second; your program determines when to respond and how much to move.\n" &
      "Physical arrangement — twenty solid heads support a heavy ball, with width 0.40 m " &
      "apiece, height limits 0.00 and 1.60 m, and speed limit 1.92 m/s. They lift the ball " &
      "without being forced downward by it. Index 0 adjoins the left goal wall and index " &
      "19 adjoins the right starting wall. You control one head in this row.\n" &
      "Transport principle — move the ball LEFT by providing a downhill slope: heads to " &
      "its right, behind it at higher x, move upward; heads to its left, ahead of it, move " &
      "downward. Raising before the right moment blocks passage with a wall; raising after " &
      "the right moment finds the ball already beyond you.\n" &
      "Team accounting — all twenty rewards are equal. Convert net metres left of the " &
      "drop position into points using 100/7.20, with a zero minimum for that progress " &
      "component; subtract elapsed seconds times 0.24. Moving right reverses progress " &
      "credit. The goal terminates further play and penalties, with no additional bonus. " &
      "A full-duration stationary ball gives -" & idleCost & "."
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
