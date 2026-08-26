## Tolerant parsing, the repair table, and the RUNE discipline.

import
  std/[json, strutils, unicode, unittest],
  ../src/pistonball/[sim, scripts]

proc parsed(text: string, previous = defaultScript(), had = false): PistonScript =
  parsePistonScript(extractJsonObject(text), previous, had)

suite "the reply schema":
  test "prose-prefixed and fenced JSON are both recovered":
    let a = parsed("Sure! Here is my program:\n```json\n" &
      "{\"mode\":\"lift\",\"up_m\":1.2}\n```\nHope that helps.")
    check a.mode == modeLift
    check a.upUm == 1_200_000'i32

  test "percentages and centimetres are accepted":
    let a = parsed("{\"mode\":\"wave\",\"speed\":80,\"trigger_m\":50," &
      "\"up_m\":145,\"down_m\":15}")
    check a.speed255 == 204                     # 0.80 * 255
    check a.triggerUm == 500_000'i32            # 50 % of a metre
    check a.upUm == 1_450_000'i32               # 145 cm
    check a.downUm == 150_000'i32               # 15 cm

  test "numeric strings are accepted":
    let a = parsed("{\"mode\":\"wave\",\"lead_ticks\":\"7\",\"up_m\":\"1.30\"}")
    check a.leadTicks == 7
    check a.upUm == 1_300_000'i32

  test "an unknown mode keeps LAST turn's mode, else wave":
    var previous = defaultScript()
    previous.mode = modeCatch
    check parsed("{\"mode\":\"zigzag\",\"up_m\":1.0}", previous, true).mode ==
      modeCatch
    check parsed("{\"mode\":\"zigzag\",\"up_m\":1.0}").mode == modeWave

  test "an unknown blind repairs to hold":
    check parsed("{\"mode\":\"wave\",\"blind\":\"teleport\"}").blind == blindHold

  test "absent and out-of-range fields take the documented defaults":
    let a = parsed("{\"mode\":\"wave\"}")
    check a.triggerUm == DefaultTriggerUm
    check a.leadTicks == DefaultLeadTicks
    check a.upUm == DefaultUpUm
    check a.downUm == DefaultDownUm
    check a.idleUm == DefaultIdleUm
    check a.speed255 == DefaultSpeed255
    let b = parsed("{\"mode\":\"wave\",\"lead_ticks\":900,\"up_m\":-4," &
      "\"speed\":-1,\"trigger_m\":9.5}")
    check b.leadTicks == 24
    check b.upUm == 0'i32
    check b.speed255 == 0
    check b.triggerUm == WindowHalfWidth
    check validScript(b)

  test "a 300-character note is cut to 160 RUNES":
    var long = ""
    for _ in 0 ..< 300:
      long.add("x")
    let a = parsed("{\"mode\":\"wave\",\"note\":\"" & long & "\"}")
    check a.note.runeLen == MaxNoteRunes

  test "a say whose 48th and 49th characters are a 4-byte emoji cuts on the RUNE boundary":
    var say = ""
    for _ in 0 ..< 47:
      say.add("a")
    say.add("\xF0\x9F\x9B\xA0")          # U+1F6E0, four bytes
    say.add("\xF0\x9F\x9B\xA0")
    let a = parsed("{\"mode\":\"wave\",\"say\":" & escapeJson(say) & "}")
    check a.say.runeLen <= MaxSayRunes
    check a.say.validateUtf8() == -1     # still valid UTF-8: no half codepoint
    # And the whole record round-trips through a strict JSON parser.
    let record = boundedScriptRecord(a, 3, 4, 9, alias(9))
    check record.runeLen <= MaxScriptRecordRunes
    let node = parseJson(record)
    check node["say"].getStr().runeLen <= MaxSayRunes
    check node["k"].getStr() == "script"

  test "a reply with no usable field is rejected, which is what the retry is for":
    expect ScriptError:
      discard parsed("{\"note\":\"thinking about it\"}")
    expect ScriptError:
      discard parsed("I would rather not answer.")

  test "the record never exceeds its rune cap even with a full note and say":
    var script = defaultScript()
    script.note = repeat("n", MaxNoteRunes)
    script.say = repeat("s", MaxSayRunes)
    let record = boundedScriptRecord(script, 7, 19, 19, alias(19))
    check record.runeLen <= MaxScriptRecordRunes
    discard parseJson(record)

  test "metresText and unitText render from integers only":
    check metresText(1_450_000'i32) == "1.45"
    check metresText(0'i32) == "0.00"
    check metresText(60_000'i32) == "0.06"
    check unitText(255) == "1.00"
    check unitText(0) == "0.00"
    check unitText(204) == "0.80"
