## Static assertions over the browser chrome. The chrome is the STARTER's, not
## a lookalike: a page written from scratch that reuses the starter's ids is a
## rewrite and fails review.

import
  std/[os, strutils, unittest],
  ../src/pistonball/[sim]

let
  root = currentSourcePath().parentDir().parentDir()
  page = readFile(root / "client" / "replay_broadcast.html")
  chrome = readFile(root / "client" / "chrome_common.js")
  core = readFile(root / "client" / "broadcast_core.js")
  staticReplay = readFile(root / "replay-viewer" / "static_replay.js")
  viewerConfig = readFile(root / "replay-viewer" / "config.nims")

suite "the broadcast chrome":
  test "chrome_common.js is the starter's file, unedited":
    # Byte-for-byte: the ONLY identifier it needs is aliased in the wire
    # constants block rather than edited into the shared chrome.
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
