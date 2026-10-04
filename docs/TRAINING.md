# Pistonball training

The canonical exporter produces complete private trajectory events. It does
not create train/validation datasets or authorize source content.

```sh
nim c -d:release --path:src -o:/tmp/pistonball-export tools/export_posttrain.nim
/tmp/pistonball-export /tmp/pistonball-default 20 1 default source-<commit>
/tmp/pistonball-export /tmp/pistonball-sprint 20 1 sprint source-<commit>
```

All five exporter arguments are required. Each episode uses the declared
variant configuration and the new `wavebot-private-view-v1` teacher. The
teacher consumes the same rounded private `windowView` as the live scripted
baseline. Exact subpixel simulator state is not a teacher input. The ordinary
parser installs each response; trajectories retain every actual one-byte
control per tick and the resulting state hashes and terminal outcomes.

Convert raw events with the current Metta SDK:

```python
from pathlib import Path
from coworld.decision_trajectory import read_trajectory_jsonl, export_complete_episodes

raw = Path("/tmp/pistonball-default/trajectories.jsonl")
complete = Path("/tmp/pistonball-complete.jsonl")
export_complete_episodes(read_trajectory_jsonl(raw), complete)
```

An independent reviewer must bind source and teacher review to the exact
complete-episode file. Import only with that reviewer-provided authority:

```python
from metta_posttrain.hosted import HostedImportAuthority, export_hosted

authority = HostedImportAuthority.model_validate_json(
    Path("/tmp/reviewer-provided-authority.json").read_bytes()
)
export_hosted(
    complete, Path("/tmp/pistonball-reviewed-dataset"),
    target_policy="wavebot-private-view-v1", authority=authority,
)
```

The shared importer assigns whole seed families to training or validation.
Default and Sprint with the same seed use one `pistonball-<seed>` family.
Existing output paths are never overwritten. Private corpora are not public
replays, Docker assets, or automatically authorized model training data.

Historical exports used the raw simulator teacher and local modulo splits.
Their reported losses and deliveries belong to that earlier, unspecified
source and profile. They do not qualify this private-view profile or establish
model strength. Keep archived corpus bytes unchanged.

## Numeric training

The persistent bridge covers Default and Sprint. It exposes 66 fixed numeric
features from the exact `windowView` seen by each piston. Local ball sightings,
neighbour heights, shared last-turn reward, and the seat's own last script are
included. The bridge snapshots all twenty views before applying any scripts.
Eight factorized heads encode mode, trigger distance, lead ticks, three height
targets, speed, and blind behavior. Distances use centimetre steps; the
production reply parser, controller, and simulator execute each action. Every
seat receives the same game score and a bounded utility for learning.

```sh
nim c -d:release --path:src -o:/tmp/pistonball-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/pistonball-train-bridge
```

From Metta, use `recipes.external.coworld_metta_rl.train` or
`recipes.external.coworld.train` with command
`["/tmp/pistonball-train-bridge", "<source>/coworld_manifest_template.json", "default"]`
and `players=20`. Replace `default` with `sprint` for the second variant.
Set a finite timestep limit for either trainer.

## Hosted player policies

The numeric bridge is for training. Ordinary players receive the private
`windowView` and return a complete PistonScript through the player socket.
Prompt policies request `/v1/messages`. The game owns parsing, fallback,
control, scoring, and replay. The platform supplies `COWORLD_LLM_ENDPOINT` and the native model identity.
Provider credentials are not a player configuration contract.
