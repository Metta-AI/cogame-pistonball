## Static assertions over the browser chrome. The chrome is the STARTER's, not
## a lookalike: a page written from scratch that reuses the starter's ids is a
## rewrite and fails review.

import
  std/[os, parseutils, strutils, unittest],
  crunchy,
  ../src/pistonball/[sim]

const StarterChromeSha256 =
  "7ace7287e0d19bf0fddb2362c55e4d76dfb44adcd4fbc8d1743b0557ced72f7c"
    ## sha256 of `client/chrome_common.js` in Metta-AI/coworld-ctf, the starter
    ## this repo's chrome was taken from. The file is copied BYTE-FOR-BYTE and
    ## the one identifier it needs (`window.CTF_WIRE`) is aliased in
    ## `wire_constants.nim` rather than edited into the shared chrome, so this
    ## digest is a constant, not a moving target: a diff here is either an
    ## unrecorded fork of the shared chrome or a starter bump, and both need
    ## saying out loud.

const StarterCoreSha256 =
  "172c4680129d608fd687cfd86436b675eef32c8652be6afe5f3189dd20c5aa9c"
    ## sha256 of the starter's `client/broadcast_core.js`. Ours is that file
    ## with `CTF_WIRE` renamed to `PISTONBALL_WIRE` and nothing else, so
    ## undoing the rename must reproduce this digest exactly.

proc hex(digest: array[32, uint8]): string =
  for value in digest:
    result.add(toHex(int(value), 2).toLowerAscii())

let
  root = currentSourcePath().parentDir().parentDir()
  page = readFile(root / "client" / "replay_broadcast.html")
  chrome = readFile(root / "client" / "chrome_common.js")
  core = readFile(root / "client" / "broadcast_core.js")
  staticReplay = readFile(root / "replay-viewer" / "static_replay.js")
  viewerConfig = readFile(root / "replay-viewer" / "config.nims")

# ---------------------------------------------------------------------------
#  Enough CSS reading to check a LAYOUT, not just the presence of a rule.
# ---------------------------------------------------------------------------

proc ruleBody(selector: string, last = false, required = true): string =
  ## The declarations of the rule introduced by `selector`. `last` picks the
  ## pistonball override where the starter's base rule shares the selector.
  let at = if last: page.rfind(selector) else: page.find(selector)
  if at < 0:
    doAssert not required, "no CSS rule for " & selector
    return ""
  let open = page.find('{', at)
  page[open + 1 ..< page.find('}', open)]

proc declaration(body, property: string): string =
  for part in body.split(';'):
    let colon = part.find(':')
    if colon > 0 and part[0 ..< colon].strip() == property:
      return part[colon + 1 .. ^1].strip()
  ""

proc units(value: string): seq[float] =
  ## Every `calc(N * var(--u))` length in a declaration, in `--u` units.
  var at = 0
  while true:
    let start = value.find("calc(", at)
    if start < 0:
      return
    var number: float
    let read = parseFloat(value, number, start + 5)
    doAssert read > 0, value
    result.add(number)
    at = start + 5 + read

proc spanTexts(markup: string): seq[string] =
  var at = 0
  while true:
    let open = markup.find("<span>", at)
    if open < 0:
      return
    let close = markup.find("</span>", open)
    doAssert close > open, markup
    result.add(markup[open + len("<span>") ..< close])
    at = close

suite "the broadcast chrome":
  test "chrome_common.js is the starter's file, unedited":
    # Byte-for-byte, and PINNED: substring checks cannot tell a copy from a
    # rewrite that happens to contain the same three strings.
    check hex(sha256(chrome)) == StarterChromeSha256
    check "window.ChromeCommon = function (ctx)" in chrome
    check "window.CTF_WIRE || {}" in chrome
    check "pistonball" notin chrome
    check chrome.len > 30_000

  test "relayout() and the three CSS variables are the starter's":
    check "function relayout()" in page
    check "--hudscale" in page
    check "--topband" in page
    check "--band" in page
    check "Math.max(0.5, Math.min(1.6, boardW / 760))" in page
    check "stage.classList.toggle('tiny', boardW <= 620)" in page

  test "the endcard stops at the transport band and every seek dismisses it":
    check "bottom: var(--band" in page
    check "$('endcard').classList.remove('on')" in page

  test "every endcard column header FITS the column it labels":
    # The header grid and each row grid are SEPARATE elements, so the columns
    # have to be fixed widths for the two to line up — which makes "does the
    # header fit?" arithmetic, and checkable here. At the starter's inherited
    # 7.5u/0.12em they did not fit: TOUCHES and LLM/FB ran past their cells
    # and overprinted their neighbours on the endcard.
    const
      HeadGlyphEm = 0.7
        ## Upper bound on ONE uppercase glyph of the fine font, in ems. The
        ## header is uppercased by `text-transform`, and caps are the widest
        ## thing it can be asked to draw.
      NameGlyphEm = 0.6
        ## …and on one glyph of the pixel row font, which is the mixed-case
        ## policy name.
      MinNameChars = 7.0
        ## `.ec-row .pcell .pname` refuses to shrink below `7ch`, so a name
        ## column narrower than that clips a short policy name.
    let
      baseRow = ruleBody("#endcard .ec-thead,\n#endcard .ec-row {")
      bankRow = ruleBody(
        "#endcard #ec-rows-bank .ec-thead,\n#endcard #ec-rows-bank .ec-row {")
      bankHead = ruleBody("#endcard #ec-rows-bank .ec-thead {", required = false)
      baseHead = ruleBody("#endcard .ec-thead {")
      columns = units(bankRow.declaration("grid-template-columns"))
      cellGap = units(baseRow.declaration("gap"))[0]
      rowFont = units(ruleBody("#endcard .ec-row {", last = true)
        .declaration("font-size"))[0]
    # The header draws at its own size and tracking if this table sets one,
    # else at the starter's.
    var
      headFontText = bankHead.declaration("font-size")
      headTrackingText = bankHead.declaration("letter-spacing")
    if headFontText.len == 0:
      headFontText = baseHead.declaration("font-size")
    if headTrackingText.len == 0:
      headTrackingText = baseHead.declaration("letter-spacing")
    let
      headFont = units(headFontText)[0]
      headTracking = parseFloat(headTrackingText.replace("em", ""))
    let start = page.find("var thead = ")
    check start > 0
    let labels = spanTexts(page[start ..< page.find(';', start)])
    check labels == @["Policy", "Piston", "In phase", "Touches", "LLM/FB"]
    # The first column is the `1fr` name cell; the other four are fixed.
    check columns.len == labels.len - 1
    for i in 1 ..< labels.len:
      let needed = float(labels[i].len) * headFont * HeadGlyphEm +
        float(labels[i].len - 1) * headTracking * headFont
      checkpoint(labels[i].toUpperAscii & " needs " & $needed &
        "u and has " & $columns[i - 1] & "u")
      check needed <= columns[i - 1]
    # …and the fixed columns are not paid for out of the name column: the card
    # is two of these tables side by side inside its own padding.
    let
      cardWidth = units(ruleBody("#endcard .ec-team {", last = true)
        .declaration("width"))[0]
      cardPadX = units(ruleBody("#endcard .ec-team {").declaration("padding"))[1]
      tableGap = units(
        ruleBody("#endcard #ec-rows-bank {").declaration("column-gap"))[0]
      tableWidth = (cardWidth - 2 * cardPadX - tableGap) / 2
    var nameWidth = tableWidth - float(columns.len) * cellGap
    for column in columns:
      nameWidth -= column
    checkpoint("name column " & $nameWidth & "u")
    check nameWidth >= MinNameChars * rowFont * NameGlyphEm

  test "the kept chrome elements are all present":
    for id in ["viewport", "stage", "board", "lightpool", "grain",
               "lockerroom", "chrome", "scorebug", "plates-l", "plates-r",
               "clock", "clock-time", "clock-caption", "mmwarn", "bannerlane",
               "killfeed", "transport", "btn-play", "btn-back", "btn-fwd",
               "btn-end", "btn-restart", "btn-loop", "btn-skip",
               "btn-spoilers", "speedchips", "scrub", "scrub-fill",
               "scrub-head", "scrub-win", "momentum", "lulls", "tick-clock",
               "ffwd-chip", "ffwd-mini", "win-chip", "endcard", "ec-headline",
               "ec-how", "ec-wincond", "ec-teams", "ec-replay", "status"]:
      checkpoint(id)
      check ("id=\"" & id & "\"") in page

  test "#viewpanel, #fpv and #povBadge are ABSENT":
    # The arena is fixed and the 1200x600 board always fits the frame, so the
    # zoom bar and minimap exist only for a board larger than the frame; and
    # the seats drive pistons, not cameras.
    for id in ["viewpanel", "minimap", "minimap-canvas", "zoombar", "zoom-out",
               "zoom-in", "zoom-slider", "zoom-read", "fpv", "fpv-canvas",
               "fpv-hud", "fpv-name", "fpv-hp", "fpv-gear", "fpv-map",
               "fpv-map-canvas", "fpv-cap", "fpv-grip", "povBadge"]:
      checkpoint(id)
      check ("id=\"" & id & "\"") notin page

  test "every beat kind the sim emits has a CSS rule, and markers are buttons":
    for kind in ["launch", "bounce_back", "stall", "delivered", "over"]:
      checkpoint(kind)
      check (".beat-marker." & kind) in page
    check "el.className = 'beat-marker ' + kind" in page
    check "document.createElement('button')" in page
    check "el.setAttribute('aria-label', label)" in page
    check "el.title = label" in page

  test "the 360 px rules are present":
    check ".plate-name {" in page
    check "flex: 1 1 auto;" in page
    check "min-width: 3.2em;" in page
    check "#stage.tiny" in page

  test "the game block is one IIFE and declares no top-level name":
    check "PISTONBALL additions to the inherited coworld-ctf chrome" in page
    check "window.PistonballChrome = {" in page
    # Every builder is pb-prefixed so it can never shadow the chrome alias
    # block's hoisted declarations.
    for name in ["pbFrame", "pbEvent", "pbBeat", "pbFeed", "pbRenderPlates",
                 "pbRenderBank", "pbRenderJourney", "pbRenderEndcard"]:
      checkpoint(name)
      check ("function " & name & "(") in page
    for alias in ["markBeat", "renderClock", "renderTransport", "esc", "fmt",
                  "teamCol", "rosterName", "setVerdict", "recordMomentum"]:
      checkpoint(alias)
      check ("function " & alias & "(") notin
        page[page.find("PISTONBALL additions") .. ^1]

  test "broadcast_core.js differs from the starter's copy in ONE identifier":
    check "window.PISTONBALL_WIRE" in core
    check "window.CTF_WIRE" notin core
    # "Exactly one identifier" is checkable rather than assertable: undo the
    # rename and the file must hash back to the starter's copy, byte for byte.
    check hex(sha256(core.replace("window.PISTONBALL_WIRE",
      "window.CTF_WIRE"))) == StarterCoreSha256

  test "static_replay.js sets both machine-readable markers":
    check "data-replay-loaded" in staticReplay
    check "data-replay-error" in staticReplay
    check "window.PistonballStaticReplay" in staticReplay
    check "static_replay_worker.js" in staticReplay

  test "config.nims carries NO MODULARIZE and NO EXPORT_NAME":
    # The link flags and the JS bootstrap are a matched pair: the shell waits
    # on Module.onRuntimeInitialized, so a modularized build would hang for
    # ever with every file present and 200 (cogame-lantern, 2026-08-23).
    check "MODULARIZE" notin viewerConfig
    check "EXPORT_NAME" notin viewerConfig
    check "ENVIRONMENT=web,worker,node" in viewerConfig
    check "ABORTING_MALLOC=1" in viewerConfig
    check "useMalloc" in viewerConfig
    check "_pistonball_load_replay" in viewerConfig
    check "_pistonball_frame" in viewerConfig

  test "no ctf_/CTF_/paintball identifier survives outside the shared chrome":
    for path in ["client/replay_broadcast.html", "client/broadcast_core.js",
                 "replay-viewer/static_replay.js",
                 "replay-viewer/static_replay_worker.js",
                 "replay-viewer/pistonball_replay.nim",
                 "src/pistonball.nim", "src/pistonball_player.nim"]:
      checkpoint(path)
      let source = readFile(root / path)
      check "ctf_" notin source
      check "CTF_" notin source
      check "paintball" notin source
    for name in walkDirRec(root / "src" / "pistonball"):
      checkpoint(name)
      let source = readFile(name)
      check "ctf_" notin source
      check "paintball" notin source
      if name.endsWith("wire_constants.nim"):
        # The ONE exception, and it is deliberate: `chrome_common.js` is
        # copied BYTE-FOR-BYTE from the starter and reads `window.CTF_WIRE`,
        # so the wire block aliases that name rather than forking the shared
        # chrome for one identifier.
        check "window.CTF_WIRE=window.PISTONBALL_WIRE" in source
      else:
        check "CTF_" notin source
