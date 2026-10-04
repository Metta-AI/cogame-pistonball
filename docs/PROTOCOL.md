# Pistonball wire protocol

## The player socket

    GET /player?slot=<N>&token=<T>

A bad slot or token is refused with 403 BEFORE the websocket upgrade.

The server sends a text `welcome` with the authenticated native player slot.
The container registers once through Sprite v1 chat:

    {"type":"register", "kind":"prompt"|"scripted", "prompt":"<private guidance>",
     "scripted":"wavebot"|"metronome"|null, "policy":"<free label>"}

Admission closes when play starts. The server freezes the registration before
seating the player. Operator guidance and full model evidence stay in private
trajectories; public replay registrations contain neither.

A text `decision` carries string `decision_id` and `attempt_id`, `seat`, the
private `view`, system rules, `retry`, and
`transport={budget_ms,cleanup_budget_ms}`. Transport budgets are separate from
the model observation. The ordinary turn budget is 20,000 ms: the first call
uses at most 12,000 ms and one retry at most 6,000 ms, both clipped to that
same turn deadline. Ordinary temperature remains omitted; an explicit
`COWORLD_LLM_TEMPERATURE` must be finite and between zero and two.

The native container emits `attempt_started` before opening its owned HTTP
request. Its `training_attempt` has exact prompt/request/decoder fields and
null response facts. An `action` echoes the issued identifiers, proposed JSON,
and the same attempt's actual response bytes, headers, model, call identifier,
and joined-reader evidence. The engine checks response-to-action equality.
Ordinary parser repairs still execute, but repaired proposals have fallback
status and cannot supply accepted model targets. Player assertions never
establish teacher or platform receipt authority.

At completion or interruption, the engine sends `stop` with the latest
`decision_id`, an unpredictable `stop_id`, and remaining `cleanup_budget_ms`.
Every admitted owner must cancel and join its HTTP worker, including owners
whose sockets disconnected. `stopped` echoes the nonce and identifier,
`worker_status="joined"`, and all retained `{decision_id,training_attempt}`
records. Older-operation bytes are retained against their original issued
identity. The game sends `evidence_received` after validating those facts;
the container requires that receipt before closing. A self-initiated stop
uses a null nonce and earns no engine stop-acknowledgement credit.

The game freezes private evidence admission before sealing its trajectory.
Unresolved ownership produces private truncation and withholds public results.
One absolute cleanup deadline covers private sealing and subsequent public
artifact writes. The player sends Sprite v1 Ready (0x85) after binary frames.

Each seat's socket receives one binary Sprite v1 frame per tick, filtered by
the SAME window predicate the LLM view uses: the housing and floor, the five
piston heads i-2 .. i+2, this seat's own head highlighted, and the ball only
while its centre is inside the +/-1.00 m window. Everything else is dark. Board
labels carry only PST-nn.

## The per-seat view

One function builds both the seat's frame filter and the LLM user message.
Numbers are rounded to 2 decimals, in view coordinates (metres, origin
bottom-left, y up) and degrees per second.

    {"turn": 3, "of": 8,
     "clock": {"tick": 675, "of": 1800, "left_s": 46.9},
     "you": {"alias": "PST-08", "piston": 7, "x_m": 3.80,
             "height_m": 0.92, "velocity_m_s": 0.00,
             "stroke_m": 1.60, "max_speed_m_s": 1.92, "width_m": 0.40},
     "window": {"half_width_m": 1.00, "covers_pistons": [5, 6, 7, 8, 9],
                "neighbour_heights_m": {"5": 0.10, "6": 1.44, "7": 0.92,
                                        "8": 0.31, "9": 0.00},
                "ball": {"dx_m": -0.34, "height_m": 1.31, "vx_m_s": -2.14,
                         "vy_m_s": 0.22, "spin_deg_s": -310.0, "on_me": true}},
     "sightings_count": 41,
     "sightings": [{"tick": 611, "dx_m": 0.98, "height_m": 0.55,
                    "vx_m_s": -1.90, "vy_m_s": 0.05}],
     "shared_reward": {"last_turn": 6.42, "note": "..."},
     "goal": {"direction": "left", "your_distance_to_goal_m": 2.60,
              "note": "..."},
     "your_last_script": {...}}

window.ball is null whenever the ball is outside the window, and sightings is
[] when the seat saw nothing at all last turn - which is the common case.
Hidden with no exception: the ball's absolute position whenever it is outside
the window, the cumulative reward, bestX, the score so far, any piston height
outside i-2 .. i+2, which entrant holds any other piston, any other seat's
script or note or say, perm, the seed, and every real player name.

## The reply schema

    {"note": "<=160 runes",
     "mode": "wave"|"lift"|"drop"|"hold"|"catch"|"ripple",
     "trigger_m": 0.0..1.0,
     "lead_ticks": 0..24,
     "up_m": 0.0..1.6,
     "down_m": 0.0..1.6,
     "idle_m": 0.0..1.6,
     "speed": 0.0..1.0,
     "blind": "hold"|"idle"|"ripple",
     "say": "<=48 runes"}

Parsing is TOLERANT: markdown fences are stripped, the outermost balanced
{...} is taken if the model prefixed prose, numeric strings are accepted,
integer percentages are divided by 100, centimetres are divided by 100, and
mode/blind are matched case-insensitively. Every bounded field is REPAIRED
rather than rejected. Only when no object with at least one usable field can be
recovered do the single retry and then the scripted fallback fire. Every
truncation lands on a RUNE boundary, never a byte boundary.

## The global socket

    GET /global      spectator snapshot, one binary Sprite v1 frame per tick

The board is perfect information. The broadcast chrome JSON rides the SAME
binary sprite channel as the board, as the label of a reserved never-drawn 1x1
sprite (id 4090), because that is the only channel that survives a hosted
replay.

Other routes: GET /healthz, GET /client/global, GET /client/player,
GET /client/replay (all three serve real pages and none opens the player
socket), GET /replay-data.

## The replay

The replay is the binary COWLDPST format: magic + format version + game
name/version header, the RESOLVED config JSON (seed, perm, every geometry and
physics constant, the twenty rest heights, the roster with real names), then
the record stream - joins, leaves, per-tick input-change records (the command
bytes), chat records (register / script / fallback / budget_guard / result) and
ONE gameHash per tick.

The static wasm viewer re-steps the sim from the recorded command bytes and
compares gameHash against the recorded hash every tick, so one divergent bit is
caught at the tick it happens.

tools/replay_summary.py (Python 3 stdlib only) prints one strict-UTF-8 JSON
object describing any .replay file.
