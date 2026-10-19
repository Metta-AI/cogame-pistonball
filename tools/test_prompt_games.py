"""Compare complete published games through the real JSONL bridge."""

import argparse
import hashlib
import json
import subprocess
from pathlib import Path

VARIANTS = ("default", "sprint")
WORDINGS = ("canonical", "plain", "numbered", "questions", "reordered", "heldout-briefing", "heldout-reference")


def play(binary: Path, manifest: Path, variant: str, text_mode: bool, wording: str, prompt_seed: int, seed: int) -> str:
    command = [str(binary), str(manifest), variant]
    if text_mode:
        command.append("text")
    process = subprocess.Popen(
        command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True
    )
    input_stream, output_stream = process.stdin, process.stdout
    assert input_stream is not None and output_stream is not None
    fingerprint = hashlib.sha256()

    def request(payload: dict) -> dict:
        input_stream.write(json.dumps(payload) + "\n")
        input_stream.flush()
        return json.loads(output_stream.readline())

    def record(value: dict) -> None:
        fingerprint.update(json.dumps(value, sort_keys=True).encode())

    try:
        observation = request(
            {
                "kind": "reset",
                "players": 20,
                "seed": f"pistonball-{seed}",
                "split": "validation",
                "promptVariant": wording,
                "promptSeed": prompt_seed,
            }
        )
        selected = WORDINGS[prompt_seed % 5] if wording == "mixed" else wording
        decisions = 0
        turns = set()
        system_bytes = None
        while observation["kind"] == "decision":
            view = observation["semantic_view"]
            metadata = view.pop("prompt_template")
            system, user = [m["content"] for m in observation["messages"]]
            assert metadata == {
                "bank": "pistonball-rules-v1",
                "selection": wording,
                "variant": selected,
                "seed": prompt_seed,
                "system_sha256": hashlib.sha256(system.encode()).hexdigest(),
                "user_sha256": hashlib.sha256(user.encode()).hexdigest(),
            }
            if system_bytes is None:
                system_bytes = system
            assert system == system_bytes
            observation["messages"][0]["content"] = system[system.index("Piston 0 is at the far left") :]
            turns.add(view["turn"])
            assert len(view["window"]["covers_pistons"]) <= 5
            assert len(view["sightings"]) <= 4
            assert not {"other_scripts", "score", "bestX", "cumulative_reward"} & view.keys()
            assert not {"seed", "perm", "variant"} & view.keys()
            record(observation)
            record(request({"kind": "encode"}))
            proposal = request({"kind": "teacher"})
            record(proposal)
            response = request(
                {"kind": "step", "decision_id": observation["decision_id"], "response": proposal["response"]}
            )
            assert response["kind"] == "accepted"
            record(response["action"])
            observation = response["observation"]
            decisions += 1
            assert decisions <= 160
        assert observation["kind"] == "terminal" and turns and turns <= set(range(8))
        assert set(observation["scores"]) == {str(i) for i in range(20)}
        assert len(set(observation["scores"].values())) == 1
        record(observation)
        return fingerprint.hexdigest()
    finally:
        input_stream.close()
        output_stream.close()
        assert process.wait(timeout=10) == 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    manifest = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"
    count = 0
    for variant in VARIANTS:
        for text_mode in (False, True):
            for seed in (1, 7):
                canonical = play(args.binary.resolve(), manifest, variant, text_mode, "canonical", 0, seed)
                count += 1
                selections = [(w, 0) for w in WORDINGS[1:]] + [("mixed", i) for i in range(5)]
                for wording, prompt_seed in selections:
                    assert (
                        play(args.binary.resolve(), manifest, variant, text_mode, wording, prompt_seed, seed)
                        == canonical
                    )
                    count += 1
                print(variant, "text" if text_mode else "numeric", seed, "12 complete games PASS", flush=True)
    for wording in ("heldout-briefing", "heldout-reference"):
        reset = {"kind": "reset", "players": 20, "seed": "heldout-guard", "promptVariant": wording}
        if wording == "heldout-reference":
            reset["split"] = "train"
        rejected = subprocess.run(
            [str(args.binary.resolve()), str(manifest), "default", "text"],
            check=False,
            input=json.dumps(reset) + "\n",
            text=True,
            capture_output=True,
            timeout=10,
        )
        assert rejected.returncode != 0 and "held-out wording" in rejected.stderr
    print(count, "complete games PASS", flush=True)


if __name__ == "__main__":
    main()
