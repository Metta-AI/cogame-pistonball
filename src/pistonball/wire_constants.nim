## The JS wire-constants block: the handful of engine constants the browser
## chrome must agree with (playback speeds, fps, the chrome sprite id).
##
## Historically each HTML client re-typed these as literals and nothing
## enforced agreement — a retuned `PlaybackSpeeds` would silently desync every
## client. This module renders them ONCE, from the same Nim consts the engine
## runs on; `server.nim` splices the block into every served client page, and
## `tools/gen_wire_constants.nim` emits it for the static wasm bundle.
## Clients read `window.PISTONBALL_WIRE` and keep their old literals only as
## fallbacks for raw `file://` opens of the un-spliced sources.

import std/strutils
import ./sim_types

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for i, value in values:
    if i > 0: result.add ","
    result.add $value
  result.add "]"

const WireConstantsJs* =
  "window.PISTONBALL_WIRE={speeds:" & jsIntArray(PlaybackSpeeds) &
  ",fps:" & $TargetFps &
  ",chromeSpriteId:" & $BroadcastChromeSpriteId &
  ",pistons:" & $PistonCount &
  ",turnTicks:225" &
  "};window.CTF_WIRE=window.PISTONBALL_WIRE;"
  ## `window.CTF_WIRE` is aliased because `client/chrome_common.js` is copied
  ## BYTE-FOR-BYTE from the starter and reads that name. Aliasing keeps the
  ## shared chrome byte-identical instead of forking it for one identifier.

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"
  ## The placeholder the client HTML carries where the block belongs (before
  ## any script that reads the wire constants).

proc spliceWireConstants*(page: string): string =
  ## Replaces the marker with the inline constants script. A page without the
  ## marker passes through unchanged.
  page.replace(WireConstantsMarker,
    "<script>" & WireConstantsJs & "</script>")
