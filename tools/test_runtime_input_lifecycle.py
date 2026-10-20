"""Initialization owners join before private sealing; upload failures stay loud."""

import base64
import http.server
import json
import os
import signal
import socket
import ssl
import subprocess
import sys
import threading
from pathlib import Path


game = Path(sys.argv[1]).resolve()
root = Path(sys.argv[2]).resolve()
root.mkdir(mode=0o700)
https = len(sys.argv) == 4 and sys.argv[3] == "https"
if https:
    certificate = root / "fixture-ca.pem"
    key = root / "fixture-key.pem"
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", str(key), "-out", str(certificate), "-days", "1",
                    "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost"],
                   check=True, capture_output=True)
    key.chmod(0o600)
    certificate.chmod(0o600)
for mode in ("status", "TERM", "INT", "upload_failure", "player_failure"):
    output = root / mode
    output.mkdir(mode=0o700)
    entered = threading.Event()
    release = threading.Event()
    uploads = []
    raw = b'{"PRIVATE_CONFIG_SENTINEL"'
    partial = mode in ("TERM", "INT")
    if mode == "player_failure":
        raw = json.dumps({"seed": 1, "num_agents": 20, "minPlayers": 20,
                          "maxTicks": 30, "turnTicks": 30, "fastMode": True,
                          "lobbyJoinTimeoutTicks": 1, "startWaitTicks": 0}).encode()

    class Fixture(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200 if partial or mode == "player_failure" else 503)
            self.send_header("Content-Length", str(len(raw) + (100 if partial else 0)))
            self.end_headers()
            self.wfile.write(raw)
            self.wfile.flush()
            entered.set()
            if partial:
                release.wait(3)

        def do_PUT(self):
            uploads.append(self.rfile.read(int(self.headers["Content-Length"])))
            self.send_response(503)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def log_message(self, *_args):
            pass

    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        if https:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(certificate, key)
            server.socket = context.wrap_socket(server.socket, server_side=True)
        endpoint = f"{'https' if https else 'http'}://{'localhost' if https else '127.0.0.1'}:{server.server_port}"
        owner = threading.Thread(target=server.serve_forever)
        owner.start()
        destination = output / "private.jsonl"
        env = os.environ | {
            "COGAME_CONFIG_URI": f"{endpoint}/config",
            "COGAME_SAVE_TRAJECTORY_URI": (
                f"{endpoint}/private"
                if mode == "upload_failure" else destination.as_uri()
            ),
            "COGAME_RESULTS_URI": (output / "results").as_uri(),
            "COGAME_SAVE_REPLAY_URI": (output / "replay").as_uri(),
            "COWORLD_EPISODE_ID": f"pistonball-runtime-{mode}",
            "COWORLD_GAME_VERSION": "source-diagnostic",
            "COWORLD_SOURCE_REVISION": "a" * 40,
            "COWORLD_TIMEOUT_SECONDS": "45",
        }
        if https:
            env["SSL_CERT_FILE"] = str(certificate)
        if mode == "player_failure":
            env["COGAME_PLAYER_FAILURE_URI"] = f"{endpoint}/failure"
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                env["COGAME_PORT"] = str(listener.getsockname()[1])
        process = subprocess.Popen([str(game)], env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        try:
            if partial:
                assert entered.wait(2)
                process.send_signal(signal.SIGTERM if mode == "TERM" else signal.SIGINT)
            stdout, stderr = process.communicate(timeout=10 if mode == "player_failure" else 3)
            (output / "stdout.log").write_text(stdout)
            (output / "stderr.log").write_text(stderr)
            assert process.returncode == (1 if mode == "upload_failure" else 0 if partial else 1)
            assert "PRIVATE_CONFIG_SENTINEL" not in stdout + stderr
            if mode == "upload_failure":
                assert len(uploads) == 1
                lines = uploads[0].decode().splitlines()
            else:
                assert destination.stat().st_mode & 0o777 == 0o600
                lines = destination.read_text().splitlines()
            assert len(lines) == 1
            episode = json.loads(lines[0])
            assert episode["event_type"] == "episode"
            assert episode["status"] == ("truncated" if partial else "failed")
            if mode == "player_failure":
                assert len(uploads) == 1
                assert json.loads(uploads[0])["failed_policy_index"] == 0
                assert episode["outcome"]["owner_failure"]["type"] == "IOError"
                assert episode["outcome"]["all_player_workers_joined"]
            captures = episode["outcome"]["runtime_inputs"]
            assert len(captures) == 1
            transport = captures[0]["transport"]
            assert transport["response_reader_joined"] is True
            assert transport["response_complete"] is (not partial)
            retained = base64.b64decode(transport["response_body_b64"], validate=True)
            assert raw.startswith(retained) if partial else retained == raw
            assert not (output / "results").exists() and not (output / "replay").exists()
            print(mode, "joined/private-only", flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=3)
            release.set()
            server.shutdown()
            owner.join(timeout=3)
            assert not owner.is_alive()
