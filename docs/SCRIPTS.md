# Writing a piston program

You are ONE piston in a bank of twenty. Every 9.4 seconds you set your piston's
PROGRAM for the next 9.4 seconds, and a deterministic controller runs it 24
times a second, watching your window for you. You choose WHEN to act and HOW
FAR to move; it does the reacting.

## The fields

| Field | Meaning |
|---|---|
| mode | which rule the controller runs |
| trigger_m | how near the ball must be before I act |
| lead_ticks | aim at where the ball will be in this many ticks |
| up_m | my raised height |
| down_m | my lowered height |
| idle_m | where I sit when the rule does not apply |
| speed | fraction of my 1.92 m/s I use to get there |
| blind | what I do while I cannot see the ball |
| note | your reasoning, for the spectator feed |
| say | one line for the spectator feed; no other piston ever sees it |

## The modes

With dx = ball x minus my centre, vx the ball's x velocity and
dxp = dx + vx * lead_ticks:

* wave - ball within trigger_m and at-or-LEFT-of me (dxp <= 0, so I am BEHIND
  it, on the side it came from): up_m; within trigger_m and to my RIGHT (I am
  IN FRONT of it): down_m; otherwise idle_m. The only mode that both lifts
  behind the ball and clears the way in front of it.
* lift - ball anywhere in my window within trigger_m: up_m, else idle_m.
* drop - ball anywhere in my window within trigger_m: down_m, else idle_m.
* hold - always idle_m.
* catch - up_m ONLY when the ball is rolling RIGHT (the wrong way, vx above
  +0.20 m/s) and is at-or-LEFT-of me within trigger_m, so my head is the wall
  it runs into; otherwise idle_m.
* ripple - a 2 s travelling wave along the bank, blind, ignores the ball.

While the ball is outside your window the `blind` field decides: hold keeps
your current height, idle goes to idle_m, ripple runs the travelling wave.

## The mechanism

The ball rolls DOWNHILL. To send it left, the pistons BEHIND it (to its RIGHT,
larger x) go UP and the pistons IN FRONT of it (to its LEFT) go DOWN. Raise too
early and you build a wall it cannot climb; raise too late and it has already
rolled past you. Timing is the whole game.

A stranded raised piston five columns ahead of the ball is a wall the whole
bank then has to fight, which is why `blind: "idle"` with a low idle_m is
usually better than `blind: "hold"` for pistons in the left half of the bank.

## The two shipped baselines

* wavebot - mode wave, trigger_m 1.00, lead_ticks 6, up_m 1.45, down_m 0.10,
  idle_m 0.25, speed 1.00, blind hold. Twenty of these converge on a travelling
  wave with no communication at all.
* metronome - mode ripple, up_m 1.20, down_m 0.10, idle_m 0.10, speed 0.80,
  blind ripple. A blind travelling wave that never looks at the ball.

Both are legal by construction: they emit the identical object an LLM does and
are compiled by the identical controller.
