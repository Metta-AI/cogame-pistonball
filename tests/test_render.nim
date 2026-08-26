## THE REAL RENDERER'S TEXT PATH.
##
## Model text reaches a spectator through exactly one production path: `say`
## strings are baked into speech plates by `bakeBubble` (pixie, `data/font.ttf`
## at size 20) and blitted as Sprite v1 sprites by the wasm build of
## `global.nim`. The browser never draws them with `fillText`, so
## `viewer_smoke.mjs --strict-text-bounds` cannot see them: the bundle run
## reports `canvas text: 0 drawn`, which the checklist itself says "means the
## check covered nothing".
##
## This file is where that path IS covered, in the language it is written in.
## It bakes full-cap strings through the production proc and measures the
## PIXELS it produced: the glyphs have to be there, and they have to be inside
## the plate, and the plate has to be inside the reserved band and inside the
## board. A caption with nowhere to go — cogchemists, 2026-08-24 — fails here.

import
  std/[unicode, unittest],
  ../src/pistonball/[sim, global]

proc capped(seed: string, runes: int): string =
  ## Exactly `runes` codepoints, ending on a 4-byte one, so the cap is proved
  ## to be measured in RUNES and the last glyph is the awkward kind.
  var text = seed.toRunes()
  let filler = "abcdefghijklmnopqrstuvwxyz ".toRunes()
  var i = 0
  while text.len < runes - 1:
    text.add(filler[i mod filler.len])
    inc i
  while text.len > runes - 1:
    discard text.pop()
  text.add("\u{1F6E0}".toRunes()[0])
  $text

proc widest(runes: int): string =
  ## The widest 48 runes a `say` can legally be: the caps are counted in runes,
  ## so "WWW…" is the worst case the plate must still hold.
  for _ in 0 ..< runes:
    result.add("W")

type Ink = object
  any: bool
  minX, maxX, minY, maxY: int

proc inkOf(baked: tuple[width, height: int, pixels: seq[uint8]]): Ink =
  ## Where the GLYPHS are. The plate is a 1 px light border around a dark
  ## interior (18, 16, 14), and the text is painted light on top of it, so any
  ## bright interior pixel is ink.
  result = Ink(minX: baked.width, maxX: -1, minY: baked.height, maxY: -1)
  for y in 1 ..< baked.height - 1:
    for x in 1 ..< baked.width - 1:
      let at = (y * baked.width + x) * 4
      if baked.pixels[at] > 120'u8 and baked.pixels[at + 3] > 40'u8:
        result.any = true
        if x < result.minX: result.minX = x
        if x > result.maxX: result.maxX = x
        if y < result.minY: result.minY = y
        if y > result.maxY: result.maxY = y

suite "the board renderer's text":
  test "a full-cap say is drawn, and drawn INSIDE its plate":
    for text in [capped("up behind it - lifting now ", MaxSayRunes),
                 widest(MaxSayRunes),
                 capped("it is coming back - catching ", MaxSayRunes),
                 "u"]:
      checkpoint(text)
      let baked = bakeBubble(text)
      # The width formula clamps at MapWidth - 40, and pixie CLIPS at the image
      # edge: a plate that hits the clamp is a caption silently cut in half.
      check baked.width < MapWidth - 40
      check baked.height == BubblePlateHeight
      check baked.pixels.len == baked.width * baked.height * 4
      let ink = inkOf(baked)
      check ink.any                       # something was actually drawn
      check ink.minX >= 8                 # the 12 px inset, minus a hair
      check ink.maxX <= baked.width - 3   # …and clear of the right border
      check ink.minY >= 1
      check ink.maxY <= baked.height - 2

  test "every speech slot's plate lies inside the reserved band":
    # The band is reserved so a plate can never overlap a piston head or fall
    # off the frame. That has to be true of the whole PLATE, not of its top
    # left corner: three 34-row plates at a pitch of band/3 put the third one
    # five rows past the band's bottom edge.
    for slot in 0 ..< MaxBubbles:
      let top = bubbleSlotY(slot)
      checkpoint("slot " & $slot & " top " & $top)
      check top >= BubbleBandTop
      check top + BubblePlateHeight <= BubbleBandBottom
      check top + BubblePlateHeight <= MapHeight
    check bubbleSlotY(1) > bubbleSlotY(0)     # slots never overlap
    check bubbleSlotY(1) - bubbleSlotY(0) >= BubblePlateHeight div 2

  test "a full-cap plate stays between the walls at every piston":
    let baked = bakeBubble(widest(MaxSayRunes))
    for piston in 0 ..< PistonCount:
      let x = bubblePlateX(piston, baked.width)
      checkpoint("piston " & $piston & " x " & $x & " w " & $baked.width)
      check x >= LeftWallPx
      check x + baked.width <= RightWallPx
      check x >= 0
      check x + baked.width <= MapWidth
