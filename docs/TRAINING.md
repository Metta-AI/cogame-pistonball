# Metta post-training data

The exporter writes private candidate episodes from complete twenty-seat games.
It requires a clean committed checkout and preserves published game budgets.
Every action passes through the production reply parser and controller.

```sh
nimby sync nimby.lock
nim r -d:release --path:src tools/export_posttrain.nim \
  /tmp/pistonball-default 10 1 default mixed 42
nim r -d:release --path:src tools/export_posttrain.nim \
  /tmp/pistonball-sprint 10 1 sprint canonical 0
```

Outputs are `trajectories.jsonl` and `manifest.json`, created exclusively with
mode 0600. Each decision records exact prompts, hashes, teacher provenance,
parsed and executed actions, and a terminal marker. Episode records contain
final outcomes and participant scores. Natural early delivery remains valid.

These files are candidates, not ready-to-train datasets. The shared Coworld SDK
and application importer own independent review, deduplication, and splitting.
Group every wording and game variant by `seed_family` (`pistonball-SEED`).
The exporter rejects held-out wordings and never creates train/validation files.

## Prompt diversity

Bank `pistonball-rules-v1` has five training introductions: `canonical`, `plain`,
`numbered`, `questions`, and `reordered`. `heldout-briefing` and
`heldout-reference` are reserved for evaluation. All share identical mechanics,
privacy rules, strategy hints, and response schema. Canonical text is unchanged.

Set game configuration `promptVariant` and nonnegative `promptSeed`.
`mixed` requires an explicit seed and selects `promptSeed % 5` without consuming
simulation randomness. Selection stays fixed throughout the episode and retries.
Defaults select canonical wording. Use the same game seed, seats, policies,
model settings, and budgets when comparing wordings. Report complete-game scores,
invalid responses, retries, fallbacks, and failures; these checks do not establish
post-training stability or stronger play.

The bridge accepts an optional third argument `text` for native JSON scripts.
Numeric mode retains its existing eight action heads and 66 features.
Reset accepts `promptVariant`, `promptSeed`, and `split` (default `train`).
Held-out wording is rejected for training. Decisions include exact system/user
SHA-256 hashes in `semantic_view.prompt_template`.

```sh
python3 tools/test_prompt_games.py /tmp/pistonball-train-bridge
python3 tools/test_source_prompts.py /tmp/pistonball-exporter /tmp/source-panel \
  --baseline-root /path/to/original-checkout --baseline-binary /tmp/original-exporter
```

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
control, scoring, and replay. Upload a prompt policy with
`--use-bedrock --bedrock-model anthropic/claude-haiku-4.5`.

## Private native evidence

Set `PISTONBALL_HOST_TRACE_PATH` on the game and
`PISTONBALL_ATTEMPT_TRACE_DIR` on each player. Set `PISTONBALL_SOURCE_REVISION`
on both to the qualified commit. Use new destinations for every episode.
The host records private views, attempt identifiers, parser outcomes, selected
attempts, executed scripts, and final results. Each player records its actual
request body, exact prompts and hashes, response headers/status/body, and reply.
Join by `attempt_id`; provider call identifiers remain in response headers.
Operator guidance stays in player artifacts and never enters host evidence,
public replay, or results. Evidence write failures are fatal.

```sh
python3 tools/test_native_prompts.py /tmp/pistonball /tmp/pistonball-player \
  /tmp/native-proof COMMIT --wording questions --mode retry
```

The native harness uses a deterministic local HTTP provider and all twenty real
players under published settings. It verifies request-to-action joins, private
operator guidance, final results, and replay. It is not a model-quality evaluation.
