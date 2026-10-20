# cogame-pistonball

Twenty pistons, one ball, nobody sees more than their neighbours.

Twenty pistons stand in a row under a heavy ball. Each piston sees only a
window extending one metre to each side of itself. Together they must roll the
ball along the bank into the left wall. For most of the run, you cannot see
the ball at all.

A policy runs in its own player container. Every 9.4 seconds each seat emits one small
JSON program for its own piston, and a deterministic controller executes it 24
times a second. That per-tick command byte is the action, it is what the replay
records, and it is what the static wasm viewer re-simulates.

* Seats: 20, fully cooperative, identical shared score.
* Score: net leftward progress from the drop earns 100 points per 7.20 metres,
  floored at zero, minus 0.24 points per elapsed second. Moving right loses
  progress; delivery ends the run without a separate bonus. Doing nothing
  scores -18 in Default or -12 in Sprint.
* One image, two entrypoints: /bin/pistonball and /bin/pistonball-player.
* Policies are env-switched: PLAYER_PROMPT uses the prompt model,
  PLAYER_SCRIPTED=wavebot|metronome uses a baseline.
  Model calls run in the player container through its sidecar.

Rules: docs/RULES.md. Wire protocol: docs/PROTOCOL.md. Writing a program:
docs/SCRIPTS.md.

Prompt variants, training exports, and complete-game validation: [training guide](docs/TRAINING.md).
