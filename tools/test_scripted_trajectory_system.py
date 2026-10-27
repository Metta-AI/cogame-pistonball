"""Run real twenty-seat episodes and verify game-owned teacher/fallback evidence."""

import asyncio
import hashlib
import json
import os
import socket
import subprocess
import sys
from pathlib import Path

from coworld.decision_trajectory import export_complete_episodes, read_trajectory_jsonl


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


async def play(game, player, output, baseline, seed, admission_delay=0):
    output.mkdir(mode=0o700, parents=True)
    port = free_port()
    config = json.loads(Path("coworld_manifest_template.json").read_text())[
        "certification"
    ]["game_config"]
    config.update(
        seed=seed,
        players=[{"name": f"PST-{seat + 1:02d}"} for seat in range(20)],
        tokens=[f"test-{seat}" for seat in range(20)],
    )
    config_path = output / "config.json"
    config_path.write_text(json.dumps(config))
    private = output / "private.jsonl"
    revision = (
        await asyncio.to_thread(
            subprocess.check_output, ["git", "rev-parse", "HEAD"], text=True
        )
    ).strip()
    clean = {
        key: value
        for key, value in os.environ.items()
        if key
        not in {
            "ANTHROPIC_API_KEY",
            "OPENAI_API_KEY",
            "OPENROUTER_API_KEY",
            "COWORLD_LLM_ENDPOINT",
            "PLAYER_PROMPT",
            "COWORLD_LLM_MODEL",
        }
    }
    env = clean | {
        "COGAME_CONFIG_URI": config_path.as_uri(),
        "COGAME_PORT": str(port),
        "COGAME_SAVE_TRAJECTORY_URI": private.as_uri(),
        "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
        "COGAME_SAVE_REPLAY_URI": (output / "episode.replay").as_uri(),
        "COWORLD_EPISODE_ID": f"piston-teacher-system-{seed}",
        "COWORLD_GAME_VERSION": "system-proof",
        "COWORLD_SOURCE_REVISION": revision,
        "COWORLD_TIMEOUT_SECONDS": "120",
    }
    processes = []
    try:
        processes.append(
            await asyncio.create_subprocess_exec(
                str(game),
                env=env,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
        )
        async with asyncio.timeout(30):
            while True:
                with socket.socket() as probe:
                    if probe.connect_ex(("127.0.0.1", port)) == 0:
                        break
                await asyncio.sleep(0.05)
        for seat in range(20):
            if seat == 19 and admission_delay:
                await asyncio.sleep(admission_delay)
            player_env = clean | {
                "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={seat}&token=test-{seat}",
                "PLAYER_SCRIPTED": baseline,
                "COWORLD_TIMEOUT_SECONDS": "120",
            }
            if baseline == "fallback":
                player_env["PLAYER_PROMPT"] = (
                    "No endpoint: must remain fallback evidence."
                )
            processes.append(
                await asyncio.create_subprocess_exec(
                    str(player),
                    env=player_env,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
            )
        async with asyncio.timeout(125):
            for index, process in enumerate(processes):
                stdout, stderr = await process.communicate()
                (output / f"owner-{index}.stdout").write_bytes(stdout)
                (output / f"owner-{index}.stderr").write_bytes(stderr)
                assert process.returncode == 0, (index, process.returncode)
        canonical = output / "canonical.jsonl"
        export_complete_episodes(read_trajectory_jsonl(private), canonical)
        record = json.loads(canonical.read_text())
        assert record["episode"]["status"] == "completed"
        assert record["decisions"]
        outcome = record["episode"]["outcome"]
        execution = outcome["execution"]
        playing_ticks = execution["end_tick"] - execution["start_tick"]
        if outcome["endRule"] == "out_of_time":
            assert playing_ticks == config["maxTicks"], (
                playing_ticks,
                config["maxTicks"],
            )
        origins = set()
        for decision in record["decisions"]:
            if baseline == "fallback":
                assert decision["action_status"] == "fallback"
                assert decision["selected_attempt_id"] is None
                assert all(
                    attempt["origin"] != "teacher" for attempt in decision["attempts"]
                )
                continue
            assert decision["action_status"] == "accepted"
            selected = next(
                attempt
                for attempt in decision["attempts"]
                if attempt["attempt_id"] == decision["selected_attempt_id"]
            )
            origins.add(selected["origin"])
            assert selected["origin"] == "teacher"
            assert selected["policy"] == baseline + "-private-view-v1"
            assert selected["parsed_action"] == decision["executed_action"]
            assert json.loads(selected["response"]) == decision["executed_action"]
            assert (
                json.loads(selected["prompt"][0]["content"]) == decision["observation"]
            )
            assert selected["platform_call_id"] is None
        proof = {
            "seed": seed,
            "baseline": baseline,
            "decisions": len(record["decisions"]),
            "origins": sorted(origins),
            "native_calls": 0,
            "scores": json.loads((output / "results.json").read_text())["scores"],
            "admission_delay_seconds": admission_delay,
            "start_tick": execution["start_tick"],
            "playing_ticks": playing_ticks,
            "controls_sha256": hashlib.sha256(
                execution["controls_b64"].encode()
            ).hexdigest(),
        }
        (output / "proof.json").write_text(json.dumps(proof, indent=2) + "\n")
        print(json.dumps(proof), flush=True)
        return proof
    finally:
        for process in processes:
            if process.returncode is None:
                process.kill()
            await process.wait()


async def main():
    game, player, output = (Path(value).resolve() for value in sys.argv[1:])
    proofs = {}
    for seed, baseline in [(703, "wavebot"), (704, "metronome"), (705, "fallback")]:
        proofs[baseline] = await play(game, player, output / baseline, baseline, seed)
    delayed = await play(
        game, player, output / "delayed-metronome", "metronome", 704, 0.5
    )
    assert delayed["start_tick"] != proofs["metronome"]["start_tick"]
    assert delayed["playing_ticks"] == proofs["metronome"]["playing_ticks"]
    assert delayed["scores"] == proofs["metronome"]["scores"]
    assert delayed["controls_sha256"] == proofs["metronome"]["controls_sha256"]


if __name__ == "__main__":
    asyncio.run(main())
