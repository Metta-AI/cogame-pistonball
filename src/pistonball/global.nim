## The board renderer: a side view of the machine shop, composed as Sprite v1
## objects over sprites baked once at startup with pixie.
##
## Rendering sits OUTSIDE the determinism boundary — nothing here enters
## `gameHash` — so this module may use floating point freely.
##
## Art provenance: every pixel is baked from what the repo already ships
## (`client/art/walls/wall_h.jpg`, `client/art/walls/wall_v.jpg` and
## `data/font.ttf`). No solid-colour placeholders, no TODO assets, no
## downloaded art.
##
## TWO NAME SPACES. Board labels carry only `PST-nn`. The spectator stream
## reaches the chrome roster through the state JSON (`broadcast.nim`), which
## is where the real policy names live; a PLAYER stream never carries one.

import
  std/[math, os, strutils, tables],
  pixie,
  bitworld/spriteprotocol,
  ./sim

const
  BoardPxUm* = 8_000            ## world micrometres per board pixel.
  FloorRow* = int(FloorY) div BoardPxUm          ## 550
  LeftWallPx* = int(LeftWallX1) div BoardPxUm    ## 100
  RightWallPx* = int(RightWallX0) div BoardPxUm  ## 1100
  PistonPx* = int(PistonWidth) div BoardPxUm     ## 50
  BallPx* = (int(BallRadius) * 2) div BoardPxUm  ## 100
  HeadCapPx* = 16
  RodPx* = int(Stroke) div BoardPxUm + HeadCapPx ## 216
  BallFrames* = 32
  BubbleBandTop* = 19           ## the reserved speech band, in board rows:
  BubbleBandBottom* = 106       ## Y in [3.55, 4.25] m. Bubbles NEVER sit
                                ## relative to a piston head.
  MaxBubbles* = 3
  BubblePlateHeight* = 34       ## every speech plate, whatever its text.
  BubbleSlotStride* = (BubbleBandBottom - BubbleBandTop - BubblePlateHeight) div
    (MaxBubbles - 1)
    ## Slot pitch, derived so the LAST plate's BOTTOM edge lands on the band's
    ## bottom rather than 5 rows past it: three 34-row plates do not fit inside
    ## an 87-row band at a pitch of band/3, and "the band is reserved" has to be
    ## true of the plates, not of their top-left corners.

  ## --- sprite ids ---------------------------------------------------------
  BandSpriteBase* = 100
  BandCount* = 6
  BandRows* = MapHeight div BandCount
  DarkBandSpriteBase* = 110
  HousingSpriteId* = 120
  DarkHousingSpriteId* = 121
  HousingRows* = MapHeight - FloorRow
  RodSpriteId* = 200
  HeadSpriteBase* = 210         ## +0 idle, +1 in phase, +2 out of phase, +3 own
  BallSpriteBase* = 300
  RailSpriteId* = 400
  TrailSpriteId* = 410
  PuffSpriteId* = 411
  BubbleSpriteBase* = 500

  ## --- object ids ---------------------------------------------------------
  BandObjectBase* = 1
  RodObjectBase* = 20
  HeadObjectBase* = 60
  BallObjectId* = 100
  TrailObjectBase* = 110
  HousingObjectId* = 130
  RailObjectId* = 131
  PuffObjectBase* = 140
  BubbleObjectBase* = 160

type
  GlobalViewerState* = object
    ## Per-connection render state. Plain value type so the server can hold
    ## one per socket and swap it wholesale.
    initialized*: bool
    spriteDefs*: seq[int]
    objectIds*: seq[int]
    bubbleText*: seq[string]
    momentumSent*: bool
    selectedPiston*: int
    mouseX*, mouseY*, mouseLayer*: int
    mouseDown*, clickPending*: bool
    scrubbing*: bool
    replaySeekTick*: int
    replayCommands*: seq[char]

  PlayerViewerState* = object
    ## Per-seat render state for a PLAYER stream.
    initialized*: bool
    spriteDefs*: seq[int]
    objectIds*: seq[int]
    chatText*: string

proc initGlobalViewerState*(): GlobalViewerState =
  result.replaySeekTick = -1
  result.selectedPiston = -1
  result.mouseLayer = MapLayerId
  result.bubbleText = newSeq[string](MaxBubbles)

proc initPlayerViewerState*(): PlayerViewerState =
  discard

proc gameDir*(): string =
  ## The directory the shipped assets resolve against.
  getCurrentDir()

# ---------------------------------------------------------------------------
#  Baking
# ---------------------------------------------------------------------------

var
  bakedBands: seq[seq[uint8]]
  bakedDarkBands: seq[seq[uint8]]
  bakedHousing: seq[uint8]
  bakedDarkHousing: seq[uint8]
  bakedRod: seq[uint8]
  bakedHeads: seq[seq[uint8]]
  bakedBall: seq[seq[uint8]]
  bakedRail: seq[uint8]
  bakedTrail: seq[uint8]
  bakedPuff: seq[uint8]
  bakedBubbles: Table[string, tuple[width, height: int, pixels: seq[uint8]]]
  typefaceCache: Typeface
  bakesReady = false

proc boardTypeface(): Typeface =
  if typefaceCache.isNil:
    typefaceCache = readTypeface(gameDir() / "data" / "font.ttf")
  typefaceCache

proc straightRgba(image: Image): seq[uint8] =
  ## Straight-alpha RGBA bytes for the Sprite v1 protocol (pixie stores
  ## premultiplied).
  result = newSeq[uint8](image.width * image.height * 4)
  for i in 0 ..< image.width * image.height:
    let c = image.data[i].rgba()
    result[i * 4] = c.r
    result[i * 4 + 1] = c.g
    result[i * 4 + 2] = c.b
    result[i * 4 + 3] = c.a

proc put(image: Image, x, y: int, r, g, b, a: uint8) =
  if x < 0 or y < 0 or x >= image.width or y >= image.height:
    return
  image.data[y * image.width + x] = rgbx(
    uint8(int(r) * int(a) div 255),
    uint8(int(g) * int(a) div 255),
    uint8(int(b) * int(a) div 255),
    a)

proc blendPixel(image: Image, x, y: int, r, g, b: uint8, alpha: float) =
  if x < 0 or y < 0 or x >= image.width or y >= image.height or alpha <= 0.0:
    return
  let
    existing = image.data[y * image.width + x].rgba()
    weight = min(1.0, alpha)
    inv = 1.0 - weight
  image.put(x, y,
    uint8(float(existing.r) * inv + float(r) * weight),
    uint8(float(existing.g) * inv + float(g) * weight),
    uint8(float(existing.b) * inv + float(b) * weight),
    max(existing.a, uint8(255.0 * weight)))

proc loadTexture(path: string): Image =
  ## A shipped JPEG, or a flat plate if the asset is missing (the wasm bundle
  ## preloads `data/` but not `client/`, so the viewer bake must not depend on
  ## a file that is not there).
  try:
    readImage(path)
  except CatchableError:
    var fallback = newImage(64, 64)
    for y in 0 ..< 64:
      for x in 0 ..< 64:
        let shade = uint8(96 + ((x xor y) and 15))
        fallback.put(x, y, shade, shade, uint8(int(shade) - 6), 255)
    fallback

proc bakeBoard(): Image =
  ## The static machine shop: the shop interior, the riveted housing under the
  ## floor line, the goal wall on the left with its chevrons and lamp, the
  ## steel plate on the right, and a vignette.
  result = newImage(MapWidth, MapHeight)
  let
    concrete = loadTexture(gameDir() / "client" / "art" / "walls" / "wall_h.jpg")
    plate = loadTexture(gameDir() / "client" / "art" / "walls" / "wall_v.jpg")
  # Shop interior: a cool vertical gradient with faint horizontal shelving.
  for y in 0 ..< FloorRow:
    let t = float(y) / float(FloorRow)
    for x in 0 ..< MapWidth:
      var
        r = uint8(26.0 + 16.0 * t)
        g = uint8(29.0 + 18.0 * t)
        b = uint8(35.0 + 20.0 * t)
      if y mod 96 == 0:
        r = uint8(int(r) + 10); g = uint8(int(g) + 10); b = uint8(int(b) + 12)
      result.put(x, y, r, g, b, 255)
  # Housing: the concrete plate under the floor line, tiled from the shipped
  # wall texture. The texture is used for its GRAIN, not its colour: it is
  # flattened to luminance and lifted onto a concrete base, because the source
  # plate has dark alcoves in it and a raw tile paints them straight through
  # as holes in the machine bed.
  for y in FloorRow ..< MapHeight:
    for x in 0 ..< MapWidth:
      let
        src = concrete.data[
          (y mod concrete.height) * concrete.width + (x mod concrete.width)].rgba()
        grain = (int(src.r) * 30 + int(src.g) * 59 + int(src.b) * 11) div 100
      result.put(x, y,
        uint8(38 + grain * 44 div 100),
        uint8(36 + grain * 43 div 100),
        uint8(32 + grain * 40 div 100), 255)
    # Rivet line just under the floor.
    if y == FloorRow + 3:
      var x = 8
      while x < MapWidth:
        result.put(x, y, 190, 186, 170, 255)
        result.put(x + 1, y, 120, 116, 104, 255)
        x += 24
  # The floor line itself: a bright machined edge.
  for x in 0 ..< MapWidth:
    result.put(x, FloorRow, 176, 170, 150, 255)
    result.put(x, FloorRow + 1, 92, 88, 78, 255)
  # Left GOAL wall with chevrons and a lamp; right wall as a steel plate. Both
  # take the shipped plate's GRAIN and none of its colour, for the same reason
  # the housing does — the source is a lit dungeon wall, and a raw tile puts
  # torches in a machine shop.
  for y in 0 ..< MapHeight:
    for x in 0 ..< LeftWallPx:
      let
        src = plate.data[
          (y mod plate.height) * plate.width + (x mod plate.width)].rgba()
        grain = (int(src.r) * 30 + int(src.g) * 59 + int(src.b) * 11) div 100
      var
        r = 44 + grain * 40 div 100
        g = 42 + grain * 39 div 100
        b = 38 + grain * 36 div 100
      if ((x + y) div 14) mod 2 == 0 and y > 120:
        # The goal wall is painted with hazard chevrons: this end of the box is
        # the one the bank is trying to reach.
        r = min(255, r + 92)
        g = min(255, g + 64)
        b = max(0, b - 14)
      result.put(x, y, uint8(r), uint8(g), uint8(b), 255)
    for x in RightWallPx ..< MapWidth:
      let
        src = plate.data[
          (y mod plate.height) * plate.width + (x mod plate.width)].rgba()
        grain = (int(src.r) * 30 + int(src.g) * 59 + int(src.b) * 11) div 100
      result.put(x, y,
        uint8(32 + grain * 34 div 100),
        uint8(34 + grain * 35 div 100),
        uint8(40 + grain * 38 div 100), 255)
  # The goal lamp.
  for y in 40 .. 78:
    for x in 26 .. 74:
      let
        dx = float(x - 50) / 24.0
        dy = float(y - 59) / 19.0
        d = dx * dx + dy * dy
      if d <= 1.0:
        result.blendPixel(x, y, 250, 214, 120, 0.55 * (1.0 - d))
  # Vignette.
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      let
        dx = (float(x) / float(MapWidth) - 0.5) * 2.0
        dy = (float(y) / float(MapHeight) - 0.5) * 2.0
        d = dx * dx + dy * dy
      if d > 0.55:
        result.blendPixel(x, y, 0, 0, 0, min(0.42, (d - 0.55) * 0.5))
  # The board caption, in the shipped face.
  let
    face = boardTypeface()
    font = newFont(face)
  font.size = 22
  font.paint = newPaint(SolidPaint)
  font.paint.color = color(0.85, 0.82, 0.72, 0.30)
  result.fillText(font, "PISTONBALL - ROLL IT LEFT",
    translate(vec2(float32(LeftWallPx + 18), 18.0'f32)))

proc bakeRod(): seq[uint8] =
  ## The polished rod between a head and its housing.
  var image = newImage(PistonPx, RodPx)
  for y in 0 ..< RodPx:
    for x in 0 ..< PistonPx:
      let
        centre = abs(float(x) - float(PistonPx - 1) / 2.0) / (float(PistonPx) / 2.0)
        shine = 1.0 - centre * centre
      if centre > 0.62:
        continue
      let base = 96.0 + 92.0 * shine
      image.put(x, y, uint8(base), uint8(base * 0.98), uint8(base * 0.92), 255)
  straightRgba(image)

proc bakeHead(tintR, tintG, tintB: uint8, rim: bool): seq[uint8] =
  ## One piston head cap. `rim` draws the out-of-phase warning light.
  var image = newImage(PistonPx, HeadCapPx)
  for y in 0 ..< HeadCapPx:
    for x in 0 ..< PistonPx:
      let
        top = float(y) / float(HeadCapPx)
        shade = 1.05 - 0.5 * top
      var
        r = float(tintR) * shade
        g = float(tintG) * shade
        b = float(tintB) * shade
      if y == 0 or y == 1:
        r = min(255.0, r + 70.0); g = min(255.0, g + 70.0); b = min(255.0, b + 62.0)
      if x == 0 or x == PistonPx - 1:
        r = r * 0.55; g = g * 0.55; b = b * 0.55
      image.put(x, y, uint8(min(255.0, r)), uint8(min(255.0, g)),
        uint8(min(255.0, b)), 255)
  if rim:
    for x in 0 ..< PistonPx:
      image.put(x, HeadCapPx - 1, 236, 70, 52, 255)
      image.put(x, HeadCapPx - 2, 180, 44, 34, 255)
  straightRgba(image)

proc bakeBallFrame(frame: int): seq[uint8] =
  ## A shaded steel sphere with a rotating specular highlight and a rim light,
  ## so ROLLING reads as rolling.
  var image = newImage(BallPx, BallPx)
  let
    radius = float(BallPx) / 2.0
    angle = 2.0 * PI * float(frame) / float(BallFrames)
  for y in 0 ..< BallPx:
    for x in 0 ..< BallPx:
      let
        dx = (float(x) + 0.5 - radius) / radius
        dy = (float(y) + 0.5 - radius) / radius
        d = dx * dx + dy * dy
      if d > 1.0:
        continue
      let
        z = sqrt(max(0.0, 1.0 - d))
        lambert = max(0.12, 0.42 * (-dx) + 0.62 * (-dy) + 0.5 * z)
      var shade = 60.0 + 150.0 * lambert
      # Two banded marks that turn with the ball: the whole point of the spin.
      let mark = cos(angle + arctan2(dy, dx) * 2.0)
      if mark > 0.72:
        shade = shade * 0.55
      # Specular.
      let
        sx = dx + 0.42 * cos(angle)
        sy = dy + 0.42 * sin(angle)
        s = sx * sx + sy * sy
      if s < 0.10:
        shade = min(255.0, shade + 150.0 * (1.0 - s / 0.10))
      let alpha = if d > 0.93: uint8(255.0 * (1.0 - d) / 0.07) else: 255'u8
      image.put(x, y, uint8(min(255.0, shade)), uint8(min(255.0, shade * 0.99)),
        uint8(min(255.0, shade * 0.94)), alpha)
  straightRgba(image)

proc bakeRail(): seq[uint8] =
  ## The best-x ghost rail: a thin dashed vertical marker.
  var image = newImage(2, MapHeight)
  for y in 0 ..< MapHeight:
    if (y div 8) mod 2 == 0:
      image.put(0, y, 232, 196, 92, 150)
      image.put(1, y, 232, 196, 92, 90)
  straightRgba(image)

proc bakeDot(size: int, r, g, b: uint8, peak: float): seq[uint8] =
  var image = newImage(size, size)
  let radius = float(size) / 2.0
  for y in 0 ..< size:
    for x in 0 ..< size:
      let
        dx = (float(x) + 0.5 - radius) / radius
        dy = (float(y) + 0.5 - radius) / radius
        d = sqrt(dx * dx + dy * dy)
      if d <= 1.0:
        image.put(x, y, r, g, b, uint8(255.0 * peak * (1.0 - d)))
  straightRgba(image)

proc bubbleSlotY*(slot: int): int =
  ## The top row of speech slot `slot`. Every plate, top edge to bottom edge,
  ## lies inside [BubbleBandTop, BubbleBandBottom].
  BubbleBandTop + slot * BubbleSlotStride

proc bubblePlateX*(piston, width: int): int =
  ## The left column of a plate spoken by `piston`: centred over its head, then
  ## slid inside the walls. Never positioned relative to the head's HEIGHT.
  result = LeftWallPx + piston * PistonPx + PistonPx div 2 - width div 2
  if result < LeftWallPx + 4:
    result = LeftWallPx + 4
  if result + width > RightWallPx - 4:
    result = RightWallPx - 4 - width

proc bakeBubble*(text: string): tuple[width, height: int, pixels: seq[uint8]] =
  ## A speech plate sized from the text, drawn in the shipped face. The band
  ## it lives in is reserved (see `BubbleBandTop`), so a full-cap 48-rune line
  ## can never be drawn outside the frame.
  if bakedBubbles.hasKey(text):
    return bakedBubbles[text]
  let
    face = boardTypeface()
    font = newFont(face)
  font.size = 20
  let
    bounds = font.layoutBounds(text)
    width = min(MapWidth - 40, max(60, int(ceil(bounds.x)) + 26))
    height = BubblePlateHeight
  var image = newImage(width, height)
  for y in 0 ..< height:
    for x in 0 ..< width:
      let edge = x == 0 or y == 0 or x == width - 1 or y == height - 1
      if edge:
        image.put(x, y, 232, 224, 206, 210)
      else:
        image.put(x, y, 18, 16, 14, 205)
  font.paint = newPaint(SolidPaint)
  font.paint.color = color(0.95, 0.93, 0.86, 1.0)
  image.fillText(font, text, translate(vec2(12.0'f32, 5.0'f32)))
  result = (width, height, straightRgba(image))
  if bakedBubbles.len > 512:
    bakedBubbles.clear()
  bakedBubbles[text] = result

proc warmBoardRenderCaches*() =
  ## Bakes every static sprite BEFORE the listener opens. A viewer's
  ## first-message clock starts at its successful connect, so nothing may be
  ## accepted until every frame the loop will ever build can be assembled
  ## instantly.
  if bakesReady:
    return
  let board = bakeBoard()
  let full = straightRgba(board)
  bakedBands = @[]
  bakedDarkBands = @[]
  for band in 0 ..< BandCount:
    let
      y0 = band * BandRows
      bytes = MapWidth * BandRows * 4
    var slice = newSeq[uint8](bytes)
    var dark = newSeq[uint8](bytes)
    for i in 0 ..< bytes:
      slice[i] = full[y0 * MapWidth * 4 + i]
    for pixel in 0 ..< MapWidth * BandRows:
      dark[pixel * 4] = uint8(int(slice[pixel * 4]) * 16 div 100)
      dark[pixel * 4 + 1] = uint8(int(slice[pixel * 4 + 1]) * 16 div 100)
      dark[pixel * 4 + 2] = uint8(int(slice[pixel * 4 + 2]) * 18 div 100)
      dark[pixel * 4 + 3] = slice[pixel * 4 + 3]
    bakedBands.add(slice)
    bakedDarkBands.add(dark)
  # The housing strip is emitted a SECOND time, above the rods: a rod is a
  # polished shaft that disappears into the machine bed, and a bed drawn only
  # in the background band would have every rod painted over it down to the
  # bottom of the frame.
  block:
    let bytes = MapWidth * HousingRows * 4
    bakedHousing = newSeq[uint8](bytes)
    bakedDarkHousing = newSeq[uint8](bytes)
    for i in 0 ..< bytes:
      bakedHousing[i] = full[FloorRow * MapWidth * 4 + i]
    for pixel in 0 ..< MapWidth * HousingRows:
      bakedDarkHousing[pixel * 4] = uint8(int(bakedHousing[pixel * 4]) * 16 div 100)
      bakedDarkHousing[pixel * 4 + 1] =
        uint8(int(bakedHousing[pixel * 4 + 1]) * 16 div 100)
      bakedDarkHousing[pixel * 4 + 2] =
        uint8(int(bakedHousing[pixel * 4 + 2]) * 18 div 100)
      bakedDarkHousing[pixel * 4 + 3] = bakedHousing[pixel * 4 + 3]
  bakedRod = bakeRod()
  bakedHeads = @[
    bakeHead(126, 128, 134, false),   # not engaged
    bakeHead(86, 168, 106, false),    # engaged, in phase
    bakeHead(196, 96, 78, true),      # engaged, OUT of phase
    bakeHead(226, 196, 108, false)    # the seat's own head
  ]
  bakedBall = @[]
  for frame in 0 ..< BallFrames:
    bakedBall.add(bakeBallFrame(frame))
  bakedRail = bakeRail()
  bakedTrail = bakeDot(18, 210, 214, 224, 0.5)
  bakedPuff = bakeDot(34, 236, 224, 190, 0.7)
  bakesReady = true

proc bandPixels*(band: int): seq[uint8] =
  ## One baked background band. Exported for the art probes in tools/.
  warmBoardRenderCaches()
  bakedBands[band]

proc housingPixels*(): seq[uint8] =
  ## The baked housing strip. Exported for the art probes in tools/.
  warmBoardRenderCaches()
  bakedHousing

# ---------------------------------------------------------------------------
#  Emission
# ---------------------------------------------------------------------------

proc defineSprite(
  packet: var seq[uint8], defs: var seq[int],
  id, width, height: int, pixels: seq[uint8], label = ""
) =
  ## Emits a sprite definition once per connection.
  if id in defs:
    return
  defs.add(id)
  packet.addSprite(id, width, height, pixels, label)

proc headSpriteFor(sim: SimServer, piston, ownPiston: int): int =
  if piston == ownPiston:
    return HeadSpriteBase + 3
  let offset = sim.ballX - pistonCentreX(piston)
  if abs32(offset) > EngagedHalfWidth:
    return HeadSpriteBase
  let wantUp = pistonCentreX(piston) >= sim.ballX
  let inPhase =
    if wantUp: sim.heights[piston] >= InPhaseUpHeight
    else: sim.heights[piston] <= InPhaseDownHeight
  if inPhase: HeadSpriteBase + 1 else: HeadSpriteBase + 2

proc ballFrameFor(sim: SimServer): int =
  ## The baked rotation frame for the ball's current angle.
  let idx = (int(sim.angleQ) * BallFrames) div 4096
  ((idx mod BallFrames) + BallFrames) mod BallFrames

proc bubbleLines(sim: SimServer): seq[tuple[piston: int, text: string]] =
  ## At most three bubbles: the three pistons NEAREST THE BALL that emitted a
  ## non-empty line this turn.
  var candidates: seq[tuple[distance: int, piston: int, text: string]]
  for piston in 0 ..< PistonCount:
    if sim.says[piston].len == 0 or sim.sayUntil[piston] < sim.tickCount:
      continue
    candidates.add((
      abs(int(sim.ballX) - int(pistonCentreX(piston))),
      piston,
      sim.says[piston]))
  for i in 0 ..< candidates.len:
    for j in i + 1 ..< candidates.len:
      if candidates[j].distance < candidates[i].distance:
        let swapped = candidates[i]
        candidates[i] = candidates[j]
        candidates[j] = swapped
  for i in 0 ..< min(MaxBubbles, candidates.len):
    result.add((candidates[i].piston, candidates[i].text))

proc addBoard(
  sim: SimServer,
  packet: var seq[uint8],
  defs: var seq[int],
  ids: var seq[int],
  firstColumn, lastColumn: int,
  showBall: bool,
  ownPiston: int,
  dark: bool
) =
  ## The shared board emission for both stream kinds. A PLAYER stream passes a
  ## five-column window, `showBall` false while the ball is outside it, and
  ## `dark` true so everything it may not see reads as unlit shop.
  warmBoardRenderCaches()
  for band in 0 ..< BandCount:
    let id = (if dark: DarkBandSpriteBase else: BandSpriteBase) + band
    packet.defineSprite(defs, id, MapWidth, BandRows,
      (if dark: bakedDarkBands[band] else: bakedBands[band]))
    packet.addObject(BandObjectBase + band, 0, band * BandRows, -3000,
      MapLayerId, id)
    ids.add(BandObjectBase + band)
  packet.defineSprite(defs, RodSpriteId, PistonPx, RodPx, bakedRod)
  for i in 0 ..< 4:
    packet.defineSprite(defs, HeadSpriteBase + i, PistonPx, HeadCapPx,
      bakedHeads[i])
  for piston in firstColumn .. lastColumn:
    if piston < 0 or piston >= PistonCount:
      continue
    let
      x = LeftWallPx + piston * PistonPx
      headTop = FloorRow - int(sim.heights[piston]) div BoardPxUm - HeadCapPx
    packet.addObject(RodObjectBase + piston, x, headTop + HeadCapPx, -200,
      MapLayerId, RodSpriteId)
    ids.add(RodObjectBase + piston)
    packet.addObject(HeadObjectBase + piston, x, headTop, -100,
      MapLayerId, headSpriteFor(sim, piston, ownPiston))
    ids.add(HeadObjectBase + piston)
  block housing:
    let id = (if dark: DarkHousingSpriteId else: HousingSpriteId)
    packet.defineSprite(defs, id, MapWidth, HousingRows,
      (if dark: bakedDarkHousing else: bakedHousing))
    # Between the rods (-200) and the heads (-100): the shafts run behind the
    # bed, the heads and the ball stand in front of it.
    packet.addObject(HousingObjectId, 0, FloorRow, -150, MapLayerId, id)
    ids.add(HousingObjectId)
  if showBall:
    packet.defineSprite(defs, RailSpriteId, 2, MapHeight, bakedRail)
    packet.defineSprite(defs, TrailSpriteId, 18, 18, bakedTrail)
    let frame = ballFrameFor(sim)
    packet.defineSprite(defs, BallSpriteBase + frame, BallPx, BallPx,
      bakedBall[frame])
    let
      bx = int(sim.ballX) div BoardPxUm - BallPx div 2
      by = int(sim.ballY) div BoardPxUm - BallPx div 2
    # A short motion trail behind the ball.
    for step in 1 .. 4:
      let
        tx = bx + BallPx div 2 - 9 - (int(sim.ballVx) * step * 3) div BoardPxUm
        ty = by + BallPx div 2 - 9 - (int(sim.ballVy) * step * 3) div BoardPxUm
      packet.addObject(TrailObjectBase + step, tx, ty, -60, MapLayerId,
        TrailSpriteId)
      ids.add(TrailObjectBase + step)
    packet.addObject(BallObjectId, bx, by, 0, MapLayerId,
      BallSpriteBase + frame)
    ids.add(BallObjectId)

proc buildSpriteProtocolPlayerUpdates*(
  sim: SimServer,
  seat: int,
  state: PlayerViewerState,
  nextState: var PlayerViewerState
): seq[uint8] =
  ## One seat's per-tick frame, filtered by the SAME window predicate
  ## `windowView` uses: the housing and floor, the five heads `i-2 .. i+2`,
  ## this seat's own head highlighted, and the ball ONLY while its centre is
  ## inside the +/-1.00 m window. Everything else is dark.
  nextState = state
  var ids: seq[int]
  if not nextState.initialized:
    result.addU8(SpriteMessageClearObjects)
    result.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
    result.addViewport(MapLayerId, MapWidth, MapHeight)
    nextState.initialized = true
    nextState.spriteDefs = @[]
  let piston = sim.pistonOfSeat(seat)
  if piston < 0:
    nextState.objectIds = ids
    return
  let span = windowColumns(piston)
  sim.addBoard(result, nextState.spriteDefs, ids, span.first, span.last,
    inWindow(piston, sim.ballX), piston, true)
  for objectId in state.objectIds:
    if objectId notin ids:
      result.addDeleteObject(objectId)
  nextState.objectIds = ids

proc applyPlayerViewerMessage*(
  state: var PlayerViewerState, message: string, chatText: var string
) =
  ## A seat sends NO inputs — every command byte is computed server-side — so
  ## an input mask arriving here is DISCARDED. The one thing a seat may say is
  ## its registration chat frame.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientChatMessage:
      chatText.add(item.text)
    else:
      discard

proc applyGlobalViewerMessage*(
  state: var GlobalViewerState, message: string
) =
  ## Applies one or more global protocol client messages.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientMouseMoveMessage:
      state.mouseX = item.x
      state.mouseY = item.y
      state.mouseLayer = (if item.hasLayer: item.layer else: MapLayerId)
    of SpriteClientMouseButtonMessage:
      if item.button == 0x01'u8:
        state.mouseDown = item.down
        if state.mouseDown:
          state.clickPending = true
        else:
          state.scrubbing = false
    of SpriteClientChatMessage:
      # Whole-string commands are intercepted before the legacy char-by-char
      # transport path, so a multi-digit tick is never mangled into speed
      # keystrokes.
      if item.text.startsWith("s:"):
        let tick = try: parseInt(item.text[2 .. ^1]) except ValueError: -1
        if tick >= 0:
          state.replaySeekTick = tick
      elif item.text.startsWith("p:"):
        let piston = try: parseInt(item.text[2 .. ^1]) except ValueError: -2
        if piston >= -1:
          state.selectedPiston = piston
      else:
        state.replayCommands.add(item.text)
    else:
      discard

proc buildBoardPacket*(
  sim: SimServer,
  state: GlobalViewerState,
  nextState: var GlobalViewerState
): seq[uint8] =
  ## The spectator board: perfect information. The per-seat stream is the
  ## window-filtered one.
  nextState = state
  nextState.replayCommands.setLen(0)
  nextState.replaySeekTick = -1
  var ids: seq[int]
  if not nextState.initialized:
    result.addU8(SpriteMessageClearObjects)
    result.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
    result.addViewport(MapLayerId, MapWidth, MapHeight)
    nextState.initialized = true
    nextState.spriteDefs = @[]
  sim.addBoard(result, nextState.spriteDefs, ids, 0, PistonCount - 1,
    true, nextState.selectedPiston, false)
  # The best-x ghost rail: a spectator sees instantly when the ball is giving
  # ground.
  result.defineSprite(nextState.spriteDefs, RailSpriteId, 2, MapHeight,
    bakedRail)
  result.addObject(RailObjectId, int(sim.bestX) div BoardPxUm, 0, -50,
    MapLayerId, RailSpriteId)
  ids.add(RailObjectId)
  # Impact FX: a dust puff wherever a head is hitting the ball hard.
  result.defineSprite(nextState.spriteDefs, PuffSpriteId, 34, 34, bakedPuff)
  var puff = 0
  for record in sim.contacts:
    if puff >= 4 or record.surface < 0:
      continue
    if record.approach < 41_667'i32:
      continue
    let x = LeftWallPx + int(record.surface) * PistonPx + PistonPx div 2 - 17
    result.addObject(PuffObjectBase + puff, x,
      FloorRow - int(sim.heights[int(record.surface)]) div BoardPxUm - 34,
      40, MapLayerId, PuffSpriteId)
    ids.add(PuffObjectBase + puff)
    inc puff
  # Speech: at most three, in the RESERVED band at the top of the arena, never
  # positioned relative to a piston head.
  let bubbles = sim.bubbleLines()
  while nextState.bubbleText.len < MaxBubbles:
    nextState.bubbleText.add("")
  for slot in 0 ..< MaxBubbles:
    if slot >= bubbles.len:
      continue
    let
      text = bubbles[slot].text
      baked = bakeBubble(text)
      spriteId = BubbleSpriteBase + slot
    if nextState.bubbleText[slot] != text:
      nextState.bubbleText[slot] = text
      # A changed line REDEFINES the slot's sprite: the client keys sprites by
      # id, so re-defining is how the plate's pixels are replaced.
      var index = -1
      for i in 0 ..< nextState.spriteDefs.len:
        if nextState.spriteDefs[i] == spriteId:
          index = i
          break
      if index >= 0:
        nextState.spriteDefs.delete(index)
    result.defineSprite(nextState.spriteDefs, spriteId, baked.width,
      baked.height, baked.pixels)
    let
      x = bubblePlateX(bubbles[slot].piston, baked.width)
      y = bubbleSlotY(slot)
    result.addObject(BubbleObjectBase + slot, x, y, 120, MapLayerId, spriteId)
    ids.add(BubbleObjectBase + slot)
  for objectId in state.objectIds:
    if objectId notin ids:
      result.addDeleteObject(objectId)
  nextState.objectIds = ids

proc chunkSpritePacket*(packet: seq[uint8], maxBytes: int): seq[seq[uint8]] =
  ## Splits one packet into websocket-frame-sized chunks AT MESSAGE
  ## BOUNDARIES. The hosted replay viewer closes any frame over 1 MiB, and the
  ## client accumulates sprite/object state across binary messages, so N
  ## chunks are equivalent to one packet.
  if packet.len == 0:
    return @[]
  var
    offset = 0
    current: seq[uint8]
  while offset < packet.len:
    let size = spriteMessageBytes(packet, offset)
    if size <= 0:
      current.add(packet[offset ..< packet.len])
      break
    if current.len > 0 and current.len + size > maxBytes:
      result.add(current)
      current = @[]
    for i in offset ..< min(packet.len, offset + size):
      current.add(packet[i])
    offset += size
  if current.len > 0:
    result.add(current)
