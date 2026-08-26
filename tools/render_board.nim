## Renders one frame of a recorded replay to a PNG, so the board art can be
## LOOKED AT without a browser, an emscripten toolchain or a CI round.
##
##   nim c -d:release -r --path:src tools/render_board.nim <replay> [frame] [out.png]
##
## It composites exactly what the wire carries — the sprite definitions and
## the object placements `buildBoardPacket` emits, in z order — so what it
## draws is what the viewer draws, not a second renderer that can drift.

import
  std/[os, strutils, tables],
  pixie, supersnappy,
  bitworld/spriteprotocol,
  ../src/pistonball/[sim, broadcast, global, replays, replay_runtime]

when isMainModule:
  if paramCount() < 1:
    quit("usage: render_board <replay> [frame] [out.png]", 1)
  let
    path = paramStr(1)
    frames = if paramCount() >= 2: parseInt(paramStr(2)) else: 220
    outPath = if paramCount() >= 3: paramStr(3) else: "board.png"
  var initialized = initReplayRuntime(
    parseReplayBytes(readFile(path)), mismatchQuit = false,
    gameEventLoggingEnabled = false)
  var
    game = move(initialized.sim)
    replay = move(initialized.player)
    tracker = move(initialized.tracker)
    viewer = initGlobalViewerState()
    sprites = initTable[int, tuple[w, h: int, px: seq[uint8]]]()
    objects = initTable[int, SpritePacketObject]()

  proc ingest(packet: seq[uint8]) =
    for message in packet.parseSpritePacket():
      case message.kind
      of spkSprite:
        sprites[message.sprite.id] = (message.sprite.width,
          message.sprite.height, uncompress(message.sprite.compressedPixels))
      of spkObject: objects[message.objectDef.id] = message.objectDef
      of spkDeleteObject: objects.del(message.objectId)
      of spkClearObjects: objects.clear()
      else: discard

  proc build(): seq[uint8] =
    var next: GlobalViewerState
    result = game.buildBoardPacket(viewer, next)
    viewer = next

  ingest(build())
  for _ in 0 ..< frames:
    discard replay.advanceReplayFrame(game, tracker, [], [])
    ingest(build())

  var image = newImage(MapWidth, MapHeight)
  var ids: seq[int]
  for id in objects.keys:
    ids.add(id)
  for i in 0 ..< ids.len:
    for j in i + 1 ..< ids.len:
      if objects[ids[j]].z < objects[ids[i]].z:
        let swapped = ids[i]
        ids[i] = ids[j]
        ids[j] = swapped
  for id in ids:
    let placement = objects[id]
    if placement.spriteId notin sprites:
      continue
    let sprite = sprites[placement.spriteId]
    for y in 0 ..< sprite.h:
      for x in 0 ..< sprite.w:
        let
          index = (y * sprite.w + x) * 4
          alpha = sprite.px[index + 3]
        if alpha == 0:
          continue
        let
          px = placement.x + x
          py = placement.y + y
        if px < 0 or py < 0 or px >= MapWidth or py >= MapHeight:
          continue
        let
          under = image.data[py * MapWidth + px].rgba()
          weight = alpha.float / 255.0
        image.data[py * MapWidth + px] = rgbx(
          uint8(float(under.r) * (1 - weight) + float(sprite.px[index]) * weight),
          uint8(float(under.g) * (1 - weight) + float(sprite.px[index + 1]) * weight),
          uint8(float(under.b) * (1 - weight) + float(sprite.px[index + 2]) * weight),
          255)
  image.writeFile(outPath)
  echo "wrote ", outPath, " at tick ", game.tickCount,
    " (", objects.len, " objects, ", sprites.len, " sprites)"
