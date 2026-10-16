# Rail Router M1 fixes (after the first in-game test)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task.

**Goal:** fix the two planner problems the in-game test showed: curves that cut across ground the grid search
avoided (a lake shore bridged, the end of a hill tunnelled, buildings crossed), and the one-sided profile over ridges
and valleys.

**Architecture:** both fixes stay in the pure planner (`content/gui/pgrace_rail_router/planner/`), unit-tested with
`just test`. Type definitions live in `tealdef/gui/pgrace_rail_router/planner/*.d.tl` (canonical; `just check` copies
them next to the sources).

**Tech stack:** Teal, checked with `just check`; plain-Lua tests in `tests/*_test.lua` (`t.test`, `t.eq`, `t.near`,
`t.ok`, `t.requireTl`); `just verify` runs everything. The game's Lua is 5.1-like: no `goto`, no `//`, no
`math.tointeger`; name unused loop variables `__`.

## In-game evidence

- Cheapest, Bangor → Imperial Beach: the route follows a lake shore but a 122 m bridge cuts across a bay of it.
- Cheapest with Mercer Island unticked: the route clips the end of a ring-shaped hill: a 268 m tunnel (orange) and then
  bridges (blue) down the far side, where going a little further round was flat.
- Every route shows "the curves cut across buildings in places".

Cause: `route.buildLeg` simplifies the grid path with Douglas–Peucker at 0.75 cell (75 m), and `smooth.fillet` drops
points whose arcs don't fit; neither looks at the ground, so the smoothed line strays up to 75 m and more from the
path the search chose, into water, hills and buildings.

## Task 1: balanced height profile (`profile.tl`)

The grade clamp runs forward then backward. Over a ridge the forward pass lags below the ground on the way up (a
tunnel on the near side) and above it on the way down (a viaduct on the far side); over a valley the reverse. Run
the clamp both ways (forward-then-backward and backward-then-forward, each with the same targets and pins) and take
the average of the two results. Both are within the grade limit, keep the pins and keep the crossing floors, so their
average does too. Tests: a symmetric ridge with equal pins gives a symmetric profile (z[k] ≈ z[n+1−k]) and one
centred tunnel; a symmetric valley one centred bridge; all existing profile tests still pass.

## Task 2: smoothing that keeps to the ground the search chose (`smooth.tl`, `route.tl`)

Give simplification and filleting a guard that rejects a smoothed line straying onto worse ground than the grid path
it replaces:

- `smooth.simplify(points, tolerance, clear?)` also returns the kept points' indices. With `clear(i, j)` given, a
  range is collapsed to its straight only when `clear(i, j)` is true; otherwise it's split (at the worst point, or the
  middle when every point is within tolerance).
- `smooth.fillet(points, radius, fixed, guard?)`, `guard = { step, clear = function(p, from, to) }`: a point is only
  dropped when the straight between its kept neighbours is clear (sampled every `step`); otherwise it's kept and the
  arcs around it are tightened instead. After building, an arc that isn't clear has its corner's radius halved and
  the pieces are rebuilt, until all are clear or the radius is below `step`. `from`/`to` are indices into `points`:
  the stretch of input the checked piece replaces.
- In `route.buildLeg`, `clear(p, from, to)` compares p with the nearest raw grid-path point in that range: p must be
  inside the grid and not blocked, may be over water only where that path point is, and its ground must be within
  4 m of that point's ground.

Tests: a path along a lake shore with a bay gives no samples over water and no bridge; a path round the end of a hill
gives no tunnel; a path on flat open ground is smoothed exactly as before (no extra points, no tighter curves).
Build time per leg stays a few milliseconds on a 15 km leg.
