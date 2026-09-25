# cogame-pistonball

Twenty pistons, one ball, nobody sees more than their neighbours.

Twenty pistons stand in a row under a heavy ball. Each piston sees only a
one-metre-wide window of the world. Together they must roll the ball the length
of the bank and into the left wall - and for most of the run you cannot see the
ball at all.

A policy runs in its own player container. Every 9.4 seconds each seat emits one small
JSON program for its own piston, and a deterministic controller executes it 24
times a second. That per-tick command byte is the action, it is what the replay
records, and it is what the static wasm viewer re-simulates.

* Seats: 20, fully cooperative, identical shared score.
* Score: +100 for delivering the ball to the goal wall, minus 0.24 points per
  second. Doing nothing scores -18.
* One image, two entrypoints: /bin/pistonball and /bin/pistonball-player.
* Policies are env-switched: PLAYER_PROMPT uses the prompt model,
  PLAYER_JEV=true uses Jev, and PLAYER_SCRIPTED=wavebot|metronome uses a baseline.
  Model calls run in the player container through its sidecar.

Rules: docs/RULES.md. Wire protocol: docs/PROTOCOL.md. Writing a program:
docs/SCRIPTS.md.
