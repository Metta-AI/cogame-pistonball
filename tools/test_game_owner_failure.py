"""Failures after listening seal privately and exit only after owned thread join."""

import json
import os
import socket
import subprocess
import sys
from pathlib import Path

binary, output = map(lambda value: Path(value).resolve(), sys.argv[1:3])
output.mkdir(mode=0o700)
for mode in ("initialization", "loop", "replay"):
    destination = output / mode
    destination.mkdir(mode=0o700)
    private = destination / "private.jsonl"
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    env = os.environ | {"COGAME_SAVE_TRAJECTORY_URI": private.as_uri(),
                        "COWORLD_EPISODE_ID": f"piston-owner-{mode}",
                        "COWORLD_GAME_VERSION": "source-diagnostic",
                        "COWORLD_SOURCE_REVISION": "a" * 40}
    command = [str(binary), mode, str(port)]
    if mode == "replay":
        command.append(str(destination / "malformed.replay"))
    process = subprocess.run(command, env=env,
                             capture_output=True, timeout=30)
    (destination / "stdout.log").write_bytes(process.stdout)
    (destination / "stderr.log").write_bytes(process.stderr)
    assert process.returncode != 0
    assert b"game owner failed (" in process.stderr
    if mode != "replay":
        assert b"game owner failed (IOError)" in process.stderr
    assert b"PRIVATE_OWNER_FAILURE_SENTINEL" not in process.stdout + process.stderr
    events = [json.loads(line) for line in private.read_text().splitlines()]
    episode = events[-1]
    assert episode["status"] == "failed"
    if mode in ("initialization", "replay"):
        assert episode["outcome"]["phase"] == "game_owner_initialization"
        if mode == "initialization":
            assert "PRIVATE_OWNER_FAILURE_SENTINEL" in episode["outcome"]["error"]
        else:
            assert episode["outcome"]["error_type"] == "PistonballError"
    else:
        assert episode["outcome"]["owner_failure"]["type"] == "IOError"
        assert episode["outcome"]["all_player_workers_joined"]
        assert episode["outcome"]["execution"]["display_end_tick"] > 0
        assert episode["outcome"]["owner_failure"]["message"]
    with socket.socket() as probe:
        assert probe.connect_ex(("127.0.0.1", port)) != 0
    print(f"{mode}: privateFailed; owned listener closed; main joined then raised")
