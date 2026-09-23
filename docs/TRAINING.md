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
