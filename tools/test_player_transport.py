"""Exercise the actual native container player. Fixture calls have no serving authority."""

import asyncio
import base64
import json
import os
import signal
import sys
from pathlib import Path

from aiohttp import web

SENTINEL = "PRIVATE_PISTON_TRANSPORT_SENTINEL"
CALL_ID = "83c39f84-7a4f-4a13-bb46-df4abb36691b"


async def play(binary: Path, destination: Path, scenario: str) -> None:
    destination.mkdir(mode=0o700)
    inference_started = asyncio.Event()
    release_inference = asyncio.Event()
    observed = {}
    completion = '{"mode":"wave","note":"fixture","say":"hold"}'

    async def infer(request: web.Request) -> web.StreamResponse:
        observed["slot"] = request.headers["X-Coworld-Player-Slot"]
        observed["request"] = await request.json()
        assert "temperature" not in observed["request"]
        if scenario in ("partial_stop", "partial_signal"):
            response = web.StreamResponse(status=200, headers={"X-Softmax-Llm-Call-Id": CALL_ID})
            await response.prepare(request)
            await response.write(b"\xff{")
            inference_started.set()
            await release_inference.wait()
            response.force_close()
            return response
        body = {"model": observed["request"]["model"], "content": [{"type": "text", "text": completion}],
                "stop_reason": "end_turn", "sampling_evidence": None,
                "usage": {"input_tokens": 8, "output_tokens": 9}}
        observed["body"] = json.dumps(body).encode()
        inference_started.set()
        return web.Response(body=observed["body"], headers={"X-Softmax-Llm-Call-Id": CALL_ID,
                                                           "Content-Type": "application/json"})

    app = web.Application()
    app.router.add_post("/v1/messages", infer)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    port = site._server.sockets[0].getsockname()[1]
    socket_connected = asyncio.Future()
    release_socket = asyncio.Event()

    async def socket(request: web.Request) -> web.WebSocketResponse:
        ws = web.WebSocketResponse(max_msg_size=16 * 1024 * 1024)
        await ws.prepare(request)
        socket_connected.set_result(ws)
        await ws.send_json({"type": "welcome", "slot": 7})
        await release_socket.wait()
        return ws

    # The fixture retains the websocket in this task while the player owns its HTTP reader.
    websocket_app = web.Application()
    websocket_app.router.add_get("/player", socket)
    websocket_runner = web.AppRunner(websocket_app)
    await websocket_runner.setup()
    websocket_site = web.TCPSite(websocket_runner, "127.0.0.1", 0)
    await websocket_site.start()
    ws_port = websocket_site._server.sockets[0].getsockname()[1]
    env = os.environ.copy()
    env.update(COWORLD_PLAYER_WS_URL=f"ws://127.0.0.1:{ws_port}/player",
               COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{port}", PLAYER_PROMPT="private operator",
               COWORLD_TIMEOUT_SECONDS="12")
    env.pop("COWORLD_LLM_TEMPERATURE", None)
    process = await asyncio.create_subprocess_exec(str(binary), env=env,
                                                  stdout=asyncio.subprocess.PIPE,
                                                  stderr=asyncio.subprocess.PIPE)
    try:
        async with asyncio.timeout(15):
            ws = await socket_connected
            registration = await ws.receive()
            assert registration.data[0] == 0x81
            await ws.send_json({"type": "decision", "decision_id": "d0", "attempt_id": "d0-a0",
                                "view": {"window": {"ball": None}}, "system": "fixture rules", "retry": False,
                                "transport": {"budget_ms": 6000, "cleanup_budget_ms": 2000}})
            started = json.loads((await ws.receive()).data)
            assert started["type"] == "attempt_started"
            initial = started["training_attempt"]
            for field in ("response", "raw_response", "response_headers", "provider_request_id",
                          "response_body_b64", "response_headers_b64", "response_complete",
                          "response_reader_joined", "http_status", "latency_ms", "platform_call_id",
                          "model_identity", "tokenizer_identity", "chat_template_sha256", "input_tokens",
                          "output_tokens", "prompt_token_ids", "sampled_token_ids", "behavior_logprobs", "stop_reason"):
                assert initial[field] is None
            await inference_started.wait()
            if scenario in ("complete", "malformed", "missing_receipt"):
                action = json.loads((await ws.receive()).data)
                assert action["source"] == "llm" and action["action"]["mode"] == "wave"
                evidence = action["training_attempt"]
                assert evidence["platform_call_id"] == CALL_ID
                assert evidence["response_complete"] is True and evidence["response_reader_joined"] is True
                assert base64.b64decode(evidence["response_body_b64"]) == observed["body"]
                assert evidence["raw_response"].encode() == observed["body"]
                assert evidence["response"] == completion
                if scenario == "malformed":
                    await ws.send_str('{"type": "' + SENTINEL)
                else:
                    await ws.send_json({"type": "stop", "decision_id": "d0", "stop_id": "fixture-nonce",
                                        "cleanup_budget_ms": 2000})
            elif scenario == "partial_signal":
                process.send_signal(signal.SIGINT)
            else:
                await ws.send_json({"type": "stop", "decision_id": "d0", "stop_id": "fixture-nonce",
                                    "cleanup_budget_ms": 2000})
            stopped = json.loads((await ws.receive()).data)
            assert stopped["type"] == "stopped" and stopped["worker_status"] == "joined"
            assert stopped["decision_id"] == "d0"
            assert stopped["stop_id"] == (None if scenario in ("partial_signal", "malformed") else "fixture-nonce")
            assert len(stopped["attempts"]) == 1
            record = stopped["attempts"][0]
            assert record["decision_id"] == "d0"
            if scenario.startswith("partial"):
                evidence = record["training_attempt"]
                assert base64.b64decode(evidence["response_body_b64"]) == b"\xff{"
                assert evidence["response_complete"] is False and evidence["response_reader_joined"] is True
                assert evidence["raw_response"] is None and evidence["response"] is None
            assert observed["slot"] == "7"
            if scenario != "missing_receipt":
                await ws.send_json({"type": "evidence_received", "decision_id": "d0", "stop_id": stopped["stop_id"]})
            stdout, stderr = await process.communicate()
            assert process.returncode == (1 if scenario in ("malformed", "missing_receipt") else 0)
            assert SENTINEL.encode() not in stdout + stderr
            (destination / "stdout.txt").write_bytes(stdout)
            (destination / "stderr.txt").write_bytes(stderr)
            (destination / "proof.json").write_text(json.dumps({"scenario": scenario, "returncode": process.returncode,
                                                               "claim": "diagnostic native owner/join/bytes only"}) + "\n")
    finally:
        release_inference.set()
        release_socket.set()
        if process.returncode is None:
            process.kill()
            await process.wait()
        await websocket_runner.cleanup()
        await runner.cleanup()


async def main() -> None:
    binary, output = map(Path, sys.argv[1:3])
    output.mkdir(mode=0o700)
    for scenario in ("complete", "partial_stop", "partial_signal", "malformed", "missing_receipt"):
        await play(binary, output / scenario, scenario)
        print(f"{scenario}: native owner joined; private transport facts retained")


if __name__ == "__main__":
    asyncio.run(main())
