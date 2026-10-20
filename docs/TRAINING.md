# Pistonball prompt diversity and training

The `pistonball-rules-v3` bank offers five complete training presentations and two
evaluation-only presentations. Wording and section order vary the bank geometry,
local visibility, downhill rolling, program timing, and shared reward explanations.
Action syntax, strategy hints, and privacy rules stay fixed. Alternate presentations
use independent phrasing. Every wording, including canonical, explains net progress
credit and elapsed-time deductions; delivery stops the run without a separate bonus.
Sprint states an 8.3-second program cadence and -12 idle score, derived from its
existing configuration; gameplay budgets do not change.

Configure `promptVariant` and `promptSeed`. Mixed selection requires an explicit
nonnegative seed, resolves modulo five, and stays fixed throughout the game.
The server sends the complete rendered rules to the ordinary player using the
existing decision protocol. Simulation randomness and the decision engine are unchanged.

The bridge accepts `text` for native JSON scripts; numeric mode retains eight action
heads and 66 features. Training resets reject held-out wording. Bridge and export
metadata retain selection plus exact system/user message hashes.

```sh
python3 tools/test_prompt_games.py BRIDGE
export_posttrain PRIVATE_OUTPUT 10 1 default mixed 0
export_posttrain PRIVATE_OUTPUT 10 1 sprint mixed 0
```

Original train/validation JSONL and manifests are retained. Every fifth scenario is
validation; wording cycles separately inside each split. All variants share scenario
families named `pistonball-SEED`. Episode IDs include requested selection, resolved wording, and prompt seed
so matched exports cannot collide. Every row comes from the native parser and controller,
with simultaneous observations frozen before scripts are installed. Natural early
delivery remains valid. Export from clean committed source and review content before
training. Held-out wording cannot enter source exports.

Compare canonical and mixed training with fixed game seeds, seats, policies, decoder
settings, and game budgets. Report scores, invalid replies, retries, and failures by
wording. Scripted parity does not demonstrate resistance to training collapse.

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
