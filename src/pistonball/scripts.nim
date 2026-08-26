## The piston-program schema: what a policy (LLM or scripted) may say, how a
## reply is parsed TOLERANTLY, and how an illegal reply is REPAIRED rather
## than rejected.
##
## Both policy kinds emit the SAME object, so the two are strictly comparable
## and one validator covers both — that is what makes the bounded-orders test
## in `tests/test_baselines.nim` meaningful.
##
## RUNE DISCIPLINE. Every cap in this file is measured in RUNES (Unicode
## codepoints) and every truncation lands on a rune boundary (`runeLen` /
## `runeSubStr`). Slicing a string by BYTE index anywhere on the path to the
## replay is forbidden: a byte-truncated multi-byte character renders fine in
## a browser and then fails a strict UTF-8 parser, which is exactly the class
## of bug that makes a replay unreadable to everything except the one viewer
## that happened to be lenient.
##
## The script is stored in INTEGERS (micrometres, ticks, 0..255) so a record
## round-trips exactly; the controller that consumes it sits outside the
## determinism boundary and may do as it likes.

import
  std/[json, math, strutils, unicode],
  ./sim_types

type
  Mode* = enum
    ## A closed enum. An unrecognised mode repairs to last turn's mode, else
    ## `wave`, so a piston is never left uncommanded.
    modeWave = "wave"
    modeLift = "lift"
    modeDrop = "drop"
    modeHold = "hold"
    modeCatch = "catch"
    modeRipple = "ripple"

  Blind* = enum
    ## What a piston does while it cannot see the ball.
    blindHold = "hold"
    blindIdle = "idle"
    blindRipple = "ripple"

  ScriptSource* = enum
    srcLlm = "llm"
    srcScripted = "scripted"
    srcFallback = "fallback"

  PistonScript* = object
    note*: string          ## <= MaxNoteRunes, the policy's own line.
    mode*: Mode
    triggerUm*: int32      ## 0 .. WindowHalfWidth.
    leadTicks*: int        ## 0 .. 24.
    upUm*, downUm*, idleUm*: int32   ## 0 .. Stroke.
    speed255*: int         ## 0 .. 255, a fraction of MaxPistonSpeed.
    blind*: Blind
    say*: string           ## <= MaxSayRunes, spectators only.
    source*: ScriptSource
    latencyMs*: int

  ScriptError* = object of ValueError

const
  DefaultTriggerUm* = WindowHalfWidth
  DefaultLeadTicks* = 6
  DefaultUpUm* = 1_450_000'i32
  DefaultDownUm* = 100_000'i32
  DefaultIdleUm* = 250_000'i32
  DefaultSpeed255* = 255

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single
  ## place any recorded string is shortened.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc sanitizeNote*(text: string): string =
  ## The policy's own line as it reaches the replay and the match feed.
  ## Newlines collapse to spaces so one record stays one line.
  ##
  ## `strutils.strip` is QUALIFIED, and it runs BEFORE the rune cut. `unicode`
  ## is imported here for `runeLen`/`runeSubStr`, and its own `strip` treats
  ## U+00A0 as a space — which on a byte-level trailing sequence chews the last
  ## byte off a multi-byte codepoint and leaves exactly the half-character this
  ## whole file exists to prevent.
  strutils.strip(text.replace("\n", " ").replace("\r", " "))
    .truncateRunes(MaxNoteRunes)

proc sanitizeSay*(text: string): string =
  ## A piston's spectator line: capped at MaxSayRunes on a RUNE boundary
  ## first, then stripped of control characters. Doing it in that order means
  ## the rune cut never leaves half a codepoint behind. Braces are excluded
  ## deliberately: the replay chat stream tells a control record from a plain
  ## line by a leading '{'.
  ##
  ## The strip is QUALIFIED and runs FIRST, before the rune cut: see
  ## `sanitizeNote`.
  result = ""
  for rune in strutils.strip(text).truncateRunes(MaxSayRunes).runes:
    let value = int(rune)
    if value < 32 or value == ord('{') or value == ord('}'):
      continue
    result.add($rune)

proc defaultScript*(): PistonScript =
  PistonScript(
    note: "",
    mode: modeWave,
    triggerUm: DefaultTriggerUm,
    leadTicks: DefaultLeadTicks,
    upUm: DefaultUpUm,
    downUm: DefaultDownUm,
    idleUm: DefaultIdleUm,
    speed255: DefaultSpeed255,
    blind: blindHold,
    say: "",
    source: srcScripted,
    latencyMs: 0
  )

proc parseMode*(text: string, fallback: Mode): Mode =
  ## Tolerant: case-insensitive, surrounding whitespace and hyphens
  ## normalised. Anything still unknown keeps the caller's fallback.
  let key = text.strip().toLowerAscii().replace("-", "_").replace(" ", "")
  for value in Mode:
    if $value == key:
      return value
  fallback

proc parseBlind*(text: string, fallback: Blind): Blind =
  let key = text.strip().toLowerAscii().replace("-", "_").replace(" ", "")
  for value in Blind:
    if $value == key:
      return value
  fallback

proc extractJsonObject*(text: string): JsonNode =
  ## The outermost balanced `{...}` in a model reply, tolerating markdown
  ## fences and any prose the model prefixed or suffixed. Falls back to
  ## first-brace..last-brace when the scan finds no balanced pair, which is
  ## what recovers a reply whose braces sit inside a quoted string.
  var
    depth = 0
    start = -1
    inString = false
    escaped = false
  for i, ch in text:
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      continue
    case ch
    of '"': inString = true
    of '{':
      if depth == 0: start = i
      inc depth
    of '}':
      if depth > 0:
        dec depth
        if depth == 0 and start >= 0:
          try:
            return parseJson(text[start .. i])
          except CatchableError:
            start = -1
    else: discard
  let
    first = text.find('{')
    last = text.rfind('}')
  if first < 0 or last <= first:
    var head = text.strip()
    if head.runeLen > 160:
      head = head.truncateRunes(160) & "..."
    raise newException(
      ScriptError, "no JSON object in reply: " & head.replace("\n", " "))
  parseJson(text[first .. last])

proc readNumber(node: JsonNode): tuple[ok: bool, value: float] =
  ## One numeric field: an int, a finite float, or a numeric string. Anything
  ## non-finite or unparseable reports `ok = false` so the caller applies the
  ## schema's documented default rather than inventing a value.
  if node.isNil:
    return (false, 0.0)
  case node.kind
  of JInt:
    (true, float(node.getBiggestInt()))
  of JFloat:
    let value = node.getFloat()
    if value != value or value > 1.0e9 or value < -1.0e9: (false, 0.0)
    else: (true, value)
  of JString:
    try:
      let text = node.getStr().strip().strip(chars = {'%', 'm', ' '})
      (true, parseFloat(text))
    except CatchableError:
      (false, 0.0)
  of JBool:
    (true, if node.getBool(): 1.0 else: 0.0)
  else:
    (false, 0.0)

proc readMetres(node: JsonNode, fallbackUm: int32, maxUm: int32): int32 =
  ## A `_m` field in metres, quantised to micrometres and clamped.
  ## CENTIMETRES are accepted too: a value above 10 for a field whose legal
  ## range tops out at 1.6 is a model that answered in cm, and dividing by
  ## 100 recovers the intent instead of clamping it to the ceiling.
  let read = readNumber(node)
  if not read.ok:
    return fallbackUm
  var metres = read.value
  if metres > 10.0:
    metres = metres / 100.0
  var micro = int64(round(metres * 1_000_000.0))
  if micro < 0: micro = 0
  if micro > int64(maxUm): micro = int64(maxUm)
  int32(micro)

proc readUnit(node: JsonNode, fallback255: int): int =
  ## A 0..1 fraction, quantised to 0..255. Integer PERCENTAGES are accepted:
  ## a value above 1 for a 0..1 field is a model that answered in percent.
  let read = readNumber(node)
  if not read.ok:
    return fallback255
  var unit = read.value
  if unit > 1.0:
    unit = unit / 100.0
  if unit < 0.0: unit = 0.0
  if unit > 1.0: unit = 1.0
  var scaled = int(round(unit * 255.0))
  if scaled < 0: scaled = 0
  if scaled > 255: scaled = 255
  scaled

proc readTrigger(node: JsonNode, fallbackUm: int32): int32 =
  ## `trigger_m` is a 0..1 metre distance: percentages are accepted the same
  ## way the unit fields are, and the result is clamped into the window.
  let read = readNumber(node)
  if not read.ok:
    return fallbackUm
  var metres = read.value
  if metres > 10.0:
    metres = metres / 100.0
  var micro = int64(round(metres * 1_000_000.0))
  if micro < 0: micro = 0
  if micro > int64(WindowHalfWidth): micro = int64(WindowHalfWidth)
  int32(micro)

proc readTicks(node: JsonNode, fallback: int): int =
  let read = readNumber(node)
  if not read.ok:
    return fallback
  var ticks = int(round(read.value))
  if ticks < 0: ticks = 0
  if ticks > 24: ticks = 24
  ticks

proc parsePistonScript*(
  payload: JsonNode,
  previous: PistonScript,
  hadPrevious: bool
): PistonScript =
  ## Turns one parsed reply into a legal script, REPAIRING every field the
  ## schema bounds rather than rejecting the reply. Raises `ScriptError` only
  ## when NO usable field can be recovered — that is the one condition the
  ## retry and then the scripted fallback exist for.
  if payload.isNil or payload.kind != JObject:
    raise newException(ScriptError, "reply is not a JSON object")
  var usable = 0
  for key in ["mode", "trigger_m", "lead_ticks", "up_m", "down_m", "idle_m",
              "speed", "blind"]:
    if not payload{key}.isNil:
      inc usable
  if usable == 0:
    raise newException(ScriptError, "reply carried no script field")
  let base = if hadPrevious: previous else: defaultScript()
  result = defaultScript()
  result.note = sanitizeNote(payload{"note"}.getStr())
  result.say = sanitizeSay(payload{"say"}.getStr())
  result.mode = parseMode(payload{"mode"}.getStr(), base.mode)
  result.blind = parseBlind(payload{"blind"}.getStr(), blindHold)
  result.triggerUm = readTrigger(payload{"trigger_m"}, DefaultTriggerUm)
  result.leadTicks = readTicks(payload{"lead_ticks"}, DefaultLeadTicks)
  result.upUm = readMetres(payload{"up_m"}, DefaultUpUm, Stroke)
  result.downUm = readMetres(payload{"down_m"}, DefaultDownUm, Stroke)
  result.idleUm = readMetres(payload{"idle_m"}, DefaultIdleUm, Stroke)
  result.speed255 = readUnit(payload{"speed"}, DefaultSpeed255)
  result.source = srcLlm

proc metresText*(micro: int32): string =
  ## A micrometre quantity as a 2-decimal metre string, built from integers so
  ## a record never carries a platform-dependent float rendering.
  let
    negative = micro < 0
    value = (if negative: -int64(micro) else: int64(micro))
    whole = value div 1_000_000
    hundredths = (value mod 1_000_000) div 10_000
  var text = $whole & "." & (if hundredths < 10: "0" else: "") & $hundredths
  if negative:
    text = "-" & text
  text

proc unitText*(speed255: int): string =
  ## A 0..255 speed as a 2-decimal 0..1 string.
  let hundredths = (speed255 * 100 + 127) div 255
  if hundredths >= 100: "1.00"
  else: "0." & (if hundredths < 10: "0" else: "") & $hundredths

proc scriptJson*(script: PistonScript): JsonNode =
  ## The script fields, exactly as the reply schema names them.
  %*{
    "mode": $script.mode,
    "trigger_m": parseFloat(metresText(script.triggerUm)),
    "lead_ticks": script.leadTicks,
    "up_m": parseFloat(metresText(script.upUm)),
    "down_m": parseFloat(metresText(script.downUm)),
    "idle_m": parseFloat(metresText(script.idleUm)),
    "speed": parseFloat(unitText(script.speed255)),
    "blind": $script.blind
  }

proc scriptRecord*(
  script: PistonScript, turn, seat, piston: int, alias: string
): JsonNode =
  ## The replay chat record for one turn's script. Re-applied at playback into
  ## NON-HASHED sim fields only: it drives the broadcast feed and
  ## `tools/replay_summary.py` and can never affect the simulation.
  result = %*{
    "k": "script",
    "turn": turn,
    "seat": seat,
    "alias": alias,
    "piston": piston,
    "source": $script.source,
    "latency_ms": script.latencyMs,
    "note": script.note,
    "say": script.say
  }
  let fields = scriptJson(script)
  for key, value in fields.pairs:
    result[key] = value

proc boundedScriptRecord*(
  script: PistonScript, turn, seat, piston: int, alias: string
): string =
  ## The serialized script record, guaranteed <= MaxScriptRecordRunes. The
  ## note is the only unbounded-in-practice field, so it is the one that
  ## shrinks; the cut still lands on a rune boundary. NEVER cut the serialized
  ## string — that would emit broken JSON, which is the exact failure the rune
  ## rule exists to prevent.
  var trimmed = script
  result = $trimmed.scriptRecord(turn, seat, piston, alias)
  var guard = 0
  while result.runeLen > MaxScriptRecordRunes and guard < 12:
    inc guard
    let keep = max(0, trimmed.note.runeLen - max(8, trimmed.note.runeLen div 2))
    trimmed.note = trimmed.note.truncateRunes(keep)
    trimmed.say = trimmed.say.truncateRunes(max(0, trimmed.say.runeLen - 2))
    result = $trimmed.scriptRecord(turn, seat, piston, alias)

proc validScript*(script: PistonScript): bool =
  ## The reply-schema legality predicate, shared by the tolerant parser's
  ## tests and the scripted baselines' bounded-orders assertion.
  script.triggerUm >= 0 and script.triggerUm <= WindowHalfWidth and
    script.leadTicks >= 0 and script.leadTicks <= 24 and
    script.upUm >= 0 and script.upUm <= Stroke and
    script.downUm >= 0 and script.downUm <= Stroke and
    script.idleUm >= 0 and script.idleUm <= Stroke and
    script.speed255 >= 0 and script.speed255 <= 255 and
    script.note.runeLen <= MaxNoteRunes and
    script.say.runeLen <= MaxSayRunes
