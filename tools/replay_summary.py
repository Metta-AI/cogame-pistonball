#!/usr/bin/env python3
"""Print one strict-UTF-8 JSON summary of a pistonball `.replay` file.

Python 3 standard library only: no Nim, no Docker, no coworld CLI. This is the
forensics tool a spectator holding the bytes can run, and it is the phase-60
substitute for the "replay is valid JSON" check that a JSON-replay game gets
for free:

    curl -sSL "$replay_url" -o /tmp/ep.replay
    python3 tools/replay_summary.py /tmp/ep.replay > /tmp/ep.json
    jq -e . /tmp/ep.json >/dev/null
    jq -r '.protocol, .results.reason, .results.endRule' /tmp/ep.json
    jq -r '[.scripts[]|select(.source=="llm")]|length, .fallbacks' /tmp/ep.json

The embedded config JSON is recovered by BRACE MATCHING from the first `{`,
which is what makes the tool robust to a header field being added later.
"""

import json
import struct
import sys
import zlib

MAGIC = b"COWLDPST"

TICK_HASH_RECORD = 0x01
INPUT_RECORD = 0x02
JOIN_RECORD = 0x03
LEAVE_RECORD = 0x04
CHAT_RECORD = 0x05
DEBUG_SPRITE_RECORD = 0x06


class Reader:
    def __init__(self, data):
        self.data = data
        self.offset = 0

    def take(self, count):
        if self.offset + count > len(self.data):
            raise ValueError("replay truncated at byte %d" % self.offset)
        chunk = self.data[self.offset:self.offset + count]
        self.offset += count
        return chunk

    def u8(self):
        return self.take(1)[0]

    def u16(self):
        return struct.unpack("<H", self.take(2))[0]

    def i16(self):
        return struct.unpack("<h", self.take(2))[0]

    def u32(self):
        return struct.unpack("<I", self.take(4))[0]

    def u64(self):
        return struct.unpack("<Q", self.take(8))[0]

    def text(self):
        length = self.u16()
        return self.take(length).decode("utf-8", "replace")

    def blob(self):
        length = self.u32()
        return self.take(length)


def decompress_if_needed(raw):
    if raw.startswith(MAGIC):
        return raw
    for wbits in (31, 15, -15):
        try:
            return zlib.decompress(raw, wbits)
        except zlib.error:
            continue
    return raw


def brace_match(text, start):
    """The outermost balanced {...} beginning at `start`, string-aware."""
    depth = 0
    in_string = False
    escaped = False
    for i in range(start, len(text)):
        ch = text[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    raise ValueError("config JSON is not balanced")


def summarize(path):
    raw = decompress_if_needed(open(path, "rb").read())
    if not raw.startswith(MAGIC):
        raise ValueError("not a pistonball replay: magic is %r" % raw[:8])
    reader = Reader(raw)
    reader.take(len(MAGIC))
    reader.u16()                       # format version
    game_name = reader.text()
    game_version = reader.text()
    reader.u64()                       # recorded-at, milliseconds
    config_text = reader.text()
    config_start = config_text.find("{")
    if config_start < 0:
        raise ValueError("no config JSON in the replay header")
    config = json.loads(brace_match(config_text, config_start))

    joins = []
    scripts = []
    registers = []
    fallbacks = 0
    budget_guards = 0
    results = {}
    tick_count = 0
    input_records = 0

    while reader.offset < len(raw):
        kind = reader.u8()
        if kind == TICK_HASH_RECORD:
            tick = reader.u32()
            reader.u64()
            tick_count = max(tick_count, tick)
        elif kind == INPUT_RECORD:
            reader.u32()
            reader.u8()
            reader.u8()
            input_records += 1
        elif kind == JOIN_RECORD:
            reader.u32()
            player = reader.u8()
            name = reader.text()
            slot = reader.i16()
            reader.text()
            joins.append({"player": player, "name": name, "slot": slot})
        elif kind == LEAVE_RECORD:
            reader.u32()
            reader.u8()
        elif kind == CHAT_RECORD:
            reader.u32()
            reader.u8()
            message = reader.text()
            if not message.startswith("{"):
                continue
            try:
                record = json.loads(message)
            except ValueError:
                continue
            key = record.get("k")
            if key == "script":
                scripts.append(record)
            elif key == "register":
                registers.append(record)
            elif key == "fallback":
                fallbacks += 1
            elif key == "budget_guard":
                budget_guards += 1
            elif key == "result":
                results = record.get("results", {})
        elif kind == DEBUG_SPRITE_RECORD:
            reader.u32()
            reader.u8()
            reader.blob()
        else:
            raise ValueError("unknown replay record type %d at byte %d" %
                             (kind, reader.offset - 1))

    return {
        "protocol": config.get("protocol", "pistonball/v1"),
        "gameName": game_name,
        "gameVersion": game_version,
        "seed": config.get("seed"),
        "names": [entry.get("name", "") for entry in config.get("players", [])],
        "aliases": [entry.get("alias", "") for entry in config.get("slots", [])],
        "pistons": config.get("perm", []),
        "policyKinds": [entry.get("kind", "") for entry in registers],
        "tickCount": tick_count,
        "inputRecords": input_records,
        "joins": len(joins),
        "registers": len(registers),
        "scripts": scripts,
        "fallbacks": fallbacks,
        "budgetGuards": budget_guards,
        "results": results,
    }


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: replay_summary.py <path/to/episode.replay>\n")
        return 2
    summary = summarize(argv[1])
    # ensure_ascii=False so the output is genuinely UTF-8 and a strict parser
    # actually exercises the encoding rather than an escaped ASCII shadow of it.
    sys.stdout.write(json.dumps(summary, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
