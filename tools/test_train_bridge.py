"""Play both certified Pistonball variants through the numeric protocol."""

import json
import random
import subprocess
import sys
from pathlib import Path


def play(binary: Path, variant: str, teacher: bool) -> None:
    manifest = Path(__file__).resolve().parent.parent / "coworld_manifest_template.json"
    process = subprocess.Popen(
        [str(binary), str(manifest), variant],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert process.stdin is not None and process.stdout is not None
    rng = random.Random(17)

    def request(payload: dict) -> dict:
        process.stdin.write(json.dumps(payload) + "\n")
        process.stdin.flush()
        return json.loads(process.stdout.readline())

    try:
        observation = request({"kind": "reset", "seed": f"pistonball-{variant}-{teacher}", "players": 20})
        widths = set()
        decisions = 0
        while observation["kind"] == "decision":
            encoding = request({"kind": "encode"})
            assert encoding["decision_id"] == observation["decision_id"]
            widths.add(len(encoding["values"]))
            heads = encoding["action_heads"]
            assert [len(head["choices"]) for head in heads] == [6, 101, 25, 161, 161, 161, 256, 3]
            for head in heads:
                assert observation["action_schema"]["properties"][head["name"]]["enum"] == head["choices"]
            view = observation["semantic_view"]
            assert "seed" not in view and "your_last_script" in view
            assert len(view["window"]["covers_pistons"]) <= 5
            assert len(view["sightings"]) <= 4
            if teacher:
                action = json.loads(request({"kind": "teacher"})["response"])
            else:
                action = {head["name"]: rng.choice(head["choices"]) for head in heads}
            result = request(
                {"kind": "step", "decision_id": observation["decision_id"], "response": json.dumps(action)}
            )
            assert result["kind"] == "accepted" and result["action"] == action
            observation = result["observation"]
            decisions += 1
            assert decisions <= 400
        assert observation["kind"] == "terminal"
        assert set(observation["scores"]) == {str(i) for i in range(20)}
        assert len(set(observation["scores"].values())) == 1
        assert len(set(observation["utilities"].values())) == 1
        assert -1 <= observation["utilities"]["0"] <= 1
        assert widths == {66}
        print(variant, "teacher" if teacher else "random", decisions, widths.pop(), "features")
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0


def check_simultaneous_views(binary: Path) -> None:
    manifest = Path(__file__).resolve().parent.parent / "coworld_manifest_template.json"
    next_views = []
    for mode in ("wave", "hold"):
        process = subprocess.Popen(
            [str(binary), str(manifest), "default"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        assert process.stdin is not None and process.stdout is not None

        def request(payload: dict) -> dict:
            process.stdin.write(json.dumps(payload) + "\n")
            process.stdin.flush()
            return json.loads(process.stdout.readline())

        request({"kind": "reset", "seed": "pistonball-simultaneous", "players": 20})
        action = {"mode": mode, "trigger_cm": 100, "lead_ticks": 6,
                  "up_cm": 145, "down_cm": 10, "idle_cm": 25,
                  "speed255": 255, "blind": "hold"}
        next_views.append(request(
            {"kind": "step", "decision_id": 0, "response": json.dumps(action)}
        )["observation"]["semantic_view"])
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0
    assert next_views[0] == next_views[1]


if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    check_simultaneous_views(binary)
    for variant in ("default", "sprint"):
        for teacher in (True, False):
            play(binary, variant, teacher)
