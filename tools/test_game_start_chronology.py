"""A real native player's finished first-start cannot acquire engine credit."""

import asyncio
import base64
import json
import os
import socket
import sys
from pathlib import Path

from aiohttp import ClientSession, WSMsgType, web


async def main() -> None:
    game, player, output = map(lambda value: Path(value).resolve(), sys.argv[1:])
    output.mkdir(mode=0o700)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    config = output / "config.json"
    config.write_text(json.dumps({"seed": 1, "num_agents": 20, "minPlayers": 1,
        "maxTicks": 30, "turnTicks": 30, "minBatchSpacingMs": 0,
        "gameOverTicks": 2, "fastMode": True,
        "players": [{"name": f"PST-{seat + 1:02d}", "token": "chronology-fixture"}
                    for seat in range(20)]}))
    private = output / "private.jsonl"
    game_env = os.environ | {"COGAME_CONFIG_URI": config.as_uri(),
        "COGAME_PORT": str(port), "COGAME_SAVE_TRAJECTORY_URI": private.as_uri(),
        "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
        "COWORLD_EPISODE_ID": "piston-start-chronology-fixture",
        "COWORLD_GAME_VERSION": "source-diagnostic", "COWORLD_SOURCE_REVISION": "a" * 40,
        "COWORLD_TIMEOUT_SECONDS": "40"}
    game_process = await asyncio.create_subprocess_exec(str(game), env=game_env,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    processes = [game_process]
    observed_starts = []
    app = web.Application()

    async def inference(request: web.Request) -> web.Response:
        body = await request.json()
        return web.json_response({"model": body["model"], "content": [{"type": "text",
            "text": '{"mode":"hold","note":"","say":""}'}],
            "usage": {"input_tokens": 2, "output_tokens": 4}, "stop_reason": "end_turn",
            "sampling_evidence": None})

    async def proxy(request: web.Request) -> web.WebSocketResponse:
        downstream = web.WebSocketResponse(max_msg_size=16 * 1024 * 1024)
        await downstream.prepare(request)
        async with ClientSession() as session:
            async with session.ws_connect(
                    f"http://127.0.0.1:{port}/player?slot=0&token=chronology-fixture",
                    max_msg_size=16 * 1024 * 1024) as upstream:
                async def relay(source, destination, mutate: bool) -> None:
                    async for frame in source:
                        if frame.type == WSMsgType.BINARY:
                            await destination.send_bytes(frame.data)
                        elif frame.type == WSMsgType.TEXT:
                            payload = json.loads(frame.data)
                            if mutate and payload["type"] == "attempt_started":
                                payload["training_attempt"]["response_complete"] = False
                                observed_starts.append(payload)
                            await destination.send_json(payload)
                        else:
                            raise ValueError("Unexpected fixture websocket frame")
                owners = [asyncio.create_task(relay(downstream, upstream, True)),
                          asyncio.create_task(relay(upstream, downstream, False))]
                try:
                    done, _ = await asyncio.wait(owners, return_when=asyncio.FIRST_COMPLETED)
                    for owner in done:
                        owner.result()
                finally:
                    for owner in owners:
                        owner.cancel()
                    await asyncio.gather(*owners, return_exceptions=True)
        return downstream

    app.router.add_post("/v1/messages", inference)
    app.router.add_get("/player", proxy)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    proxy_port = site._server.sockets[0].getsockname()[1]
    try:
        async with asyncio.timeout(10):
            while True:
                with socket.socket() as probe:
                    if probe.connect_ex(("127.0.0.1", port)) == 0:
                        break
                await asyncio.sleep(0.02)
        player_env = os.environ | {"COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{proxy_port}/player",
            "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{proxy_port}",
            "PLAYER_PROMPT": "chronology fixture", "COWORLD_TIMEOUT_SECONDS": "40"}
        processes.append(await asyncio.create_subprocess_exec(str(player), env=player_env,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE))
        async with asyncio.timeout(45):
            for index, process in enumerate(processes):
                stdout, stderr = await process.communicate()
                (output / f"owner-{index}.stdout").write_bytes(stdout)
                (output / f"owner-{index}.stderr").write_bytes(stderr)
        assert observed_starts
        events = [json.loads(line) for line in private.read_text().splitlines()]
        episode = events[-1]
        assert episode["status"] == "truncated"
        assert not episode["outcome"]["all_player_workers_joined"]
        assert not (output / "results.json").exists()
        rejections = episode["outcome"]["rejected_player_frames"]
        assert any("first model start must precede observed response facts" in record["error"]
                   and json.loads(base64.b64decode(record["body_b64"]))["type"] == "attempt_started"
                   for record in rejections)
        assert all(attempt["origin"] != "model" or not attempt["accepted"]
                   for event in events[:-1] for attempt in event["attempts"])
        (output / "proof.json").write_text(json.dumps({"forged_starts": len(observed_starts),
            "status": episode["status"], "claim": "synthetic wire chronology only; zero serving authority"}) + "\n")
        print("Observed false on first native start: privately rejected, no labels or public success")
    finally:
        for process in processes:
            if process.returncode is None:
                process.kill()
            await process.wait()
        await runner.cleanup()


if __name__ == "__main__":
    asyncio.run(main())
