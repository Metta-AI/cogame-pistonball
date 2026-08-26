# Pistonball rules

Twenty pistons stand shoulder to shoulder in a bank across the floor of a long,
shallow box. The ball starts against the right wall. Every piston can push its
head up or let it down, and the ball rolls down whatever slope the bank happens
to be making under it. Get the ball to the left wall.

## The catch

A piston can only see one metre either side of itself - five columns - so for
most of the run you cannot see the ball at all. You have to guess from your last
sighting, from the two neighbours' heights you can see, and from a single number
telling you whether the bank as a whole gained ground. A wave is the only thing
that works, and nobody can see the whole wave.

## Seats

num_agents = 20. One seat = one piston. Seat s drives piston perm[s], where perm
is a permutation of 0..19 drawn once at t = 0 from config.seed. Piston indices
run 0 = leftmost (next to the goal) to 19 = rightmost (where the ball starts).
In-game the cog at piston i is called PST-<i+1> zero-padded to two digits. perm
is written into the replay config JSON and into results.pistons, but it is never
visible to any seat.

## World and units

Everything in the simulation is an integer, because the replay is re-simulated
by the emscripten/wasm32 build of the same module the native server ran and
their per-tick gameHash chain must match bit-for-bit.

| Quantity | Unit |
|---|---|
| Position, length, piston height | micrometres |
| Linear velocity | micrometres per tick |
| Ball angle (angleQ) | 1/16 brad, 0..4095 |
| Angular velocity (spin) | 1/16 brad per tick |
| Force | millinewtons |
| Torque | millinewton-metres |
| Mass | grams |
| Moment of inertia | milli-kg m^2 |
| Shared reward | milli-points |

World box: x in [0, 9 600 000] um (9.60 m), y in [0, 4 800 000] um (4.80 m),
origin top-left, y DOWN. Board render scale: 1 board pixel = 8 000 um, so the
board is 1200 x 600.

View coordinates - the only coordinates a policy or the chrome ever sees - are
metres with the origin at the arena's bottom-left corner, x right, y up:
X = x_um / 1 000 000, Y = (4 400 000 - y_um) / 1 000 000. The floor surface is
Y = 0 and piston heights are Y values directly.

## Geometry

| Part | Extent (um, world frame) |
|---|---|
| Floor surface | y = 4 400 000; below it is the piston housing, art only |
| Ceiling | y = 0 |
| Left wall (the GOAL wall) | x in [0, 800 000], full height |
| Right wall | x in [8 800 000, 9 600 000], full height |
| Piston bank | 20 heads spanning x in [800 000, 8 800 000]; piston i occupies x in [800 000 + 400 000 i, 800 000 + 400 000 (i+1)], centre 1 000 000 + 400 000 i |
| Piston head i | x in [x_i, x_i + 400 000], top surface at y = 4 400 000 - h_i |

Constants:

    PistonWidth       =   400 000 um   (0.40 m)
    Stroke            = 1 600 000 um   (0 .. 1.60 m of travel)
    MaxPistonSpeed    =    80 000 um/tick (1.92 m/s; a full stroke takes 20 ticks)
    BallRadius        =   400 000 um   (0.40 m)
    BallMass          =     6 000 g    (6 kg)
    BallInertia       =       480 milli-kg m^2
    WindowHalfWidth   = 1 000 000 um   (1.00 m)
    GoalX             = 1 200 000 um   (ball centre touching the goal wall)
    BallStartX        = 8 400 000 um
    BallStartY        = 3 400 000 um   (1.00 m above the floor: the ball is DROPPED)
    TravelDistance    = 7 200 000 um   (7.20 m)
    GravityPerSubstep =     4 257 um/tick per substep (9.81 m/s^2 at 96 substeps/s)

At t = 0 every head is set to a small random rest height h_i = 10 000 * k for
k in 0..40 from the same seeded stream that drew perm, and the ball is placed at
(BallStartX, BallStartY) at rest. Those two draws plus perm are the only random
numbers the sim ever takes; nothing is drawn after tick 0.

## Time

TargetFps = ReplayFps = 24. Each tick integrates 4 substeps of 1/96 s. A run is
at most maxTicks = 1800 ticks = 75.0 s of sim time, divided into 8 decision
turns of turnTicks = 225 ticks (9.375 s).

## Resolution order, every tick

1. Turn boundary. If tick mod 225 == 0 and the phase is Playing, the scripts
   collected for the turn become each seat's active script and one `script`
   chat record per seat is written. The script itself is NOT mixed into
   gameHash - the per-tick command bytes it produces are recorded, and those
   are what the viewer replays.
2. Controller compile, in PISTON INDEX ORDER 0..19 (never seat order - seat
   order varies with perm and the loop must not). The controller returns a
   command byte cmd in 0..254, where
   u = ((cmd - 127) * MaxPistonSpeed) div 127 um/tick is the commanded head
   velocity (positive = rising); cmd = 255 is reserved and repairs to 127.
   The byte is written to the replay only when it differs from the seat's last
   recorded byte.
3. Piston kinematics. h_i := clamp(h_i + u_i, 0, Stroke); pistonVel_i is the
   ACHIEVED velocity after clamping. Pistons are KINEMATIC: they move the ball,
   the ball never moves them.
4. Four substeps of 1/96 s, each: gravity; contacts (the ceiling, the left
   wall, the right wall, then every piston head the broadphase returns,
   ascending - a head at extension 0 has its top surface exactly on the floor
   line, so the heads ARE the floor and there is no separate floor surface);
   semi-implicit Euler with air and spin drag and the velocity clamps; the
   pose update; and a containment guard that clamps the centre into
   x in [1 200 000, 8 400 000], y in [400 000, 4 000 000].
5. Progress accounting: progress accrues +100.000 points for the full 7.20 m
   and a symmetric negative for backsliding, and the per-step penalty adds
   0.010 points every tick.
6. Phase accounting: a piston within 1.20 m of the ball is ENGAGED; an engaged
   piston is IN PHASE when it is behind the ball and raised past 0.80 m, or in
   front of it and lowered below 0.60 m.
7. Hash: one gameHash per tick, mixing the tick, the phase, the ball pose and
   motion, every head's extension and achieved velocity, bestX, the two
   accumulators, the guard counter and the perm digest.
8. End checks, in order: ballX <= GoalX ends complete/delivered; the wall-clock
   stop ends deadline/wall_clock; maxTicks ends complete/out_of_time; a tripped
   invariant ends fault/sim_fault.

There is no rescue rule. A bank that jams the ball in a pit of its own making
burns the clock and ends out_of_time with partial credit.

## Scoring

The game is FULLY COOPERATIVE: every seat receives the identical score.

    progress = 100 * (BallStartX - ballFinalX) / TravelDistance
    penalty  = 0.010 * ticksElapsed
    score    = progress - penalty

Higher is better; leftward is positive. Range: score in [-18.000, +100.000).
Delivering the ball ends the episode and therefore stops the penalty; that, and
not a bonus, is the reward for speed.

| Outcome | ticks | final ball X (m) | progress | penalty | score |
|---|---|---|---|---|---|
| Textbook wave, delivered in 25 s | 600 | 1.20 | +100.000 | 6.000 | +94.000 |
| Delivered late after two bounce-backs | 1520 | 1.20 | +100.000 | 15.200 | +84.800 |
| Three-quarters of the way, out of time | 1800 | 3.00 | +75.000 | 18.000 | +57.000 |
| Nudged it a metre and jammed | 1800 | 7.40 | +13.889 | 18.000 | -4.111 |
| Twenty pistons that never moved | 1800 | 8.40 | 0.000 | 18.000 | -18.000 |

The league ranks by the seat's mean results.scores value across its episodes -
its cross-play mean. Elo is wrong for this coworld: with twenty identical
scores every episode is a twenty-way draw and Elo cannot separate anybody.

## End conditions

| reason | endRule | When |
|---|---|---|
| complete | delivered | ballX <= GoalX |
| complete | out_of_time | maxTicks reached with the ball still in play |
| deadline | wall_clock | wallClockBudgetSeconds elapsed first |
| fault | sim_fault | an invariant guard tripped |
| fault | host_error | an unexpected server-side exception |

A seat that never connects does NOT end the episode: the lobby join budget
expires, the no-show is reported to COGAME_PLAYER_FAILURE_URI, its piston is
driven by the wavebot baseline for the whole run, and the run plays to a normal
ending.
