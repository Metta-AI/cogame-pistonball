"""Run the real game and twenty native owners against diagnostic HTTP fixtures."""

import asyncio
import base64
import json
import os
import signal
import socket
import sys
import uuid
from pathlib import Path

from aiohttp import ClientSession, web


def free_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


async def main() -> None:
    game, player, destination = map(lambda arg: Path(arg).resolve(), sys.argv[1:4])
    scenario = sys.argv[4] if len(sys.argv) == 5 else "complete"
    assert scenario in ("complete", "large", "TERM", "INT")
    destination.mkdir(mode=0o700)
    action = {"mode": "wave", "trigger_m": 0.2, "lead_ticks": 12,
              "up_m": 1.6, "down_m": 0.0, "idle_m": 0.0, "speed": 1.0,
              "blind": "hold", "note": "diagnostic", "say": ""}
    calls = []
    entered = asyncio.Event()
    release = asyncio.Event()

    async def infer(request: web.Request) -> web.Response:
        body = await request.json()
        assert body["temperature"] == 0.4 if scenario == "large" else "temperature" not in body
        call_id = str(uuid.uuid4())
        entered.set()
        if scenario not in ("complete", "large"):
            partial = web.StreamResponse(status=200, headers={"X-Softmax-Llm-Call-Id": call_id})
            await partial.prepare(request)
            await partial.write(b"\xff{")
            calls.append({"slot": int(request.headers["X-Coworld-Player-Slot"]),
                          "call_id": call_id, "body_b64": base64.b64encode(b"\xff{").decode()})
            await release.wait()
            partial.force_close()
            return partial
        await release.wait()
        response = {"model": body["model"], "content": [{"type": "text", "text": json.dumps(action)}],
                    "usage": {"input_tokens": 100, "output_tokens": 30}, "stop_reason": "end_turn",
                    "sampling_evidence": None}
        if scenario == "large" and int(request.headers["X-Coworld-Player-Slot"]) == 0:
            response["sampling_evidence"] = {"sampling": "full_softmax", "temperature": 0.4,
                "prompt_token_ids": list(range(32768)), "completion_token_ids": [7, 8],
                "behavior_log_probs": None, "stop_reason": "length"}
        raw = json.dumps(response).encode()
        calls.append({"slot": int(request.headers["X-Coworld-Player-Slot"]),
                      "call_id": call_id, "body_b64": base64.b64encode(raw).decode()})
        return web.Response(body=raw, headers={"Content-Type": "application/json",
                                              "X-Softmax-Llm-Call-Id": call_id})

    app = web.Application()
    app.router.add_post("/v1/messages", infer)
    runner = web.AppRunner(app)
    await runner.setup()
    http_port = free_port()
    game_port = free_port()
    await web.TCPSite(runner, "127.0.0.1", http_port).start()
    config = destination / "config.json"
    config.write_text(json.dumps({"seed": 1, "num_agents": 20, "minPlayers": 20,
                                 "maxTicks": 60, "turnTicks": 30, "minBatchSpacingMs": 0,
                                 "gameOverTicks": 2, "fastMode": True,
                                 "players": [{"name": f"PST-{seat + 1:02d}", "token": f"fixture-{seat}"}
                                             for seat in range(20)]}))
    private = destination / "private.jsonl"
    env = os.environ | {"COGAME_CONFIG_URI": config.as_uri(), "COGAME_PORT": str(game_port),
                        "COGAME_SAVE_TRAJECTORY_URI": private.as_uri(),
                        "COGAME_RESULTS_URI": (destination / "results.json").as_uri(),
                        "COGAME_SAVE_REPLAY_URI": (destination / "episode.replay").as_uri(),
                        "COWORLD_EPISODE_ID": "piston-native-diagnostic",
                        "COWORLD_GAME_VERSION": "source-diagnostic",
                        "COWORLD_SOURCE_REVISION": "a" * 40, "COWORLD_TIMEOUT_SECONDS": "75"}
    processes = []
    try:
        game_process = await asyncio.create_subprocess_exec(str(game), env=env,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        processes.append(game_process)
        async with ClientSession() as session:
            async with asyncio.timeout(15):
                while True:
                    # A TCP connection tests actual listening without swallowing
                    # HTTP or private protocol exceptions.
                    probe = socket.socket()
                    try:
                        if probe.connect_ex(("127.0.0.1", game_port)) == 0:
                            break
                    finally:
                        probe.close()
                    await asyncio.sleep(0.05)
            for seat in range(20):
                player_env = os.environ | {"COWORLD_PLAYER_WS_URL":
                    f"ws://127.0.0.1:{game_port}/player?slot={seat}&token=fixture-{seat}",
                    "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{http_port}",
                    "PLAYER_PROMPT": "diagnostic operator", "PLAYER_POLICY_LABEL": "fixture-native",
                    "COWORLD_TIMEOUT_SECONDS": "75"}
                player_env.pop("COWORLD_LLM_TEMPERATURE", None)
                if scenario == "large":
                    player_env["COWORLD_LLM_TEMPERATURE"] = "0.4"
                processes.append(await asyncio.create_subprocess_exec(str(player), env=player_env,
                    stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE))
            assert await asyncio.wait_for(entered.wait(), 15)
            # Joining during the actual HTTP wait must receive the real board.
            async with session.ws_connect(f"http://127.0.0.1:{game_port}/global") as viewer:
                frame = await asyncio.wait_for(viewer.receive(), 5)
                assert frame.type.name == "BINARY" and len(frame.data) > 0
            if scenario in ("complete", "large"):
                release.set()
            else:
                game_process.send_signal(signal.SIGTERM if scenario == "TERM" else signal.SIGINT)
            async with asyncio.timeout(45):
                for index, process in enumerate(processes):
                    stdout, stderr = await process.communicate()
                    (destination / f"owner-{index}.stdout").write_bytes(stdout)
                    (destination / f"owner-{index}.stderr").write_bytes(stderr)
                    assert process.returncode == 0, (index, process.returncode)
        events = [json.loads(line) for line in private.read_text().splitlines()]
        episode = events[-1]
        expected_status = "completed" if scenario in ("complete", "large") else "truncated"
        assert episode["status"] == expected_status and episode["outcome"]["all_player_workers_joined"]
        assert (destination / "results.json").is_file() == (scenario in ("complete", "large"))
        assert (destination / "episode.replay").is_file() == (scenario in ("complete", "large"))
        known = {call["call_id"]: call for call in calls}
        accepted = 0
        for event in events[:-1]:
            for attempt in event["attempts"]:
                if attempt["origin"] == "model":
                    assert attempt["response_reader_joined"]
                    assert attempt["response_complete"] is (scenario in ("complete", "large"))
                    assert attempt["response_body_b64"] == known[attempt["platform_call_id"]]["body_b64"]
            if scenario == "large" and attempt["origin"] == "model" and event["seat"] == "0":
                    assert attempt["prompt_token_ids"] == list(range(32768))
                    assert attempt["sampled_token_ids"] == [7, 8]
                    assert attempt["behavior_logprobs"] is None
            if event["selected_attempt_id"] is not None:
                selected = next(attempt for attempt in event["attempts"]
                                if attempt["attempt_id"] == event["selected_attempt_id"])
                assert selected["parsed_action"] == event["executed_action"]
                accepted += selected["origin"] == "model"
        if scenario in ("complete", "large"):
            assert accepted == len(events) - 1 and accepted >= 20
        else:
            assert accepted == 0
        (destination / "proof.json").write_text(json.dumps({"native_calls": len(calls),
            "accepted_decisions": accepted, "owners": len(processes), "status": expected_status,
            "claim": "synthetic HTTP fixture only; zero authenticated serving receipts"}) + "\n")
        print(f"{scenario}: {accepted} accepted/{len(calls)} calls/all21 owners joined/{expected_status}/mid-HTTP first frame")
    finally:
        release.set()
        for index, process in enumerate(processes):
            if process.returncode is None:
                process.kill()
            if not (destination / f"owner-{index}.stdout").exists():
                stdout, stderr = await process.communicate()
                (destination / f"owner-{index}.stdout").write_bytes(stdout)
                (destination / f"owner-{index}.stderr").write_bytes(stderr)
        await runner.cleanup()


if __name__ == "__main__":
    asyncio.run(main())
