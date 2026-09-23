# Metta post-training data

The native simulator and published `wavebot` policy can export supervised
examples for both certified variants:

```sh
nimby sync nimby.lock
nim r -d:release --path:src tools/export_posttrain.nim \
  /tmp/pistonball-default 10 1 default
nim r -d:release --path:src tools/export_posttrain.nim \
  /tmp/pistonball-sprint 10 1 sprint
```

Each run reads its exact manifest variant config and plays complete seeded,
twenty-seat games. The exporter records the hosted system prompt, each seat's
one-metre window, and a `wavebot` script that round-trips through the game's
reply parser. Splits are by game seed. The manifest records source revision,
variant, scores, wins, and row counts. Existing output directories are never
overwritten.

Train either output with Metta post-training:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/pistonball-default \
  --output /tmp/pistonball-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

The local 10-game default and sprint exports each contained 160 training and
40 validation examples, with 10/10 deliveries. All 400 examples fit a
4096-token model context. A one-step CPU optimizer smoke reduced held-out loss
from 5.5833 to 5.5089 (default) and 5.5254 to 5.4587 (sprint). This distills
the scripted teacher; it does not establish stronger league play.

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
