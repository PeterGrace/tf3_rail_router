# Rail Router route quality (after the second in-game test)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fastest mode gives a short, smooth line (no curves tighter than its radius except where the ground forces
it), stations face the way the line runs, and no false "curves cut across buildings" warning.

**Tools:** `tools/replay.lua <capture> [out.ppm] [key=value...]` replays a plan from a capture of the player's map and
prints its figures (length, estimate, bridges, tunnels, tight curves, min radius, blocked samples, guarded, per-leg
tight arcs and blocked samples); with an output path it draws the map (convert to PNG with ImageMagick `convert`).
Captures of the test map (Bangor → Imperial Beach) are in
`/tmp/claude-1000/-home-pgrace-repos-tf3-mods-tf3-rail-router/e4279592-b734-4ff0-b0da-48753f8e339b/scratchpad/cap/`:
`fastest.cap` (high-speed, all stops), `cheapest.cap` (standard, all stops), `cheapest_nomercer.cap`.

Baseline (commit e7d485e):

| Capture            | Length  | Estimate   | Bridges | Tunnels | Tight | Min radius | Blocked | Guarded |
|--------------------|---------|------------|---------|---------|-------|------------|---------|---------|
| fastest            | 16835 m | 21,365,110 | 737 m   | 0       | 11    | 115        | 1       | 6       |
| cheapest           | 15122 m | 5,619,351  | 122 m   | 0       | 5     | 57         | 1       | 3       |
| cheapest_nomercer  | 13400 m | 4,966,253  | 99 m    | 0       | 3     | 71         | 3       | 3       |

## Task A: exact clearance, and the build-radius floor near stations

1. `stations.tl` `clear` and `route.tl` `straightClear` sample every quarter cell, so a run can clip the corner of a
   blocked cell between samples (the blocked samples above are all at station ends). Check every cell the segment
   passes through instead (a grid traversal, e.g. Amanatides–Woo), keeping the other tests (water, road, track,
   taken, inside, relief) as they are.
2. Arcs between fixed points (platform end, approach, extension) are tightened by `smooth.build` without a floor;
   a prototype run gave a 14 m arc. Never let a leg's arc go below `weights.minBuildRadius`: where the fixed points
   force it, give up the extension point (unfix it so fillet may drop it, or shorten it) and refit; only if that
   still can't reach the floor, keep it and count it as tight. Test both.

## Task B: a curve-aware search (`grid.tl`)

The search moves in 22.5° steps between 100 m cells, so in Fastest (radius up to 3 km) its path has kinks no curve
of that radius fits; smoothing then either cuts corners (now refused by the guard) or leaves tight curves. Make the
search respect the radius: a move that turns (by one 22.5° step; no bigger turns in one move when this applies) must
be followed by a straight of at least `2 · minRadius · tan(11.25°)` (≈ 0.4 R) in the new direction before the next
turn, so consecutive arcs fit. Model it as long edges: from state (cell, dir), the successors are one step straight
on, or a one-step turn followed by the whole minimum straight (every cell on it checked and costed as now). The
state space stays (cell, direction), so the search stays optimal for this model. When the minimum straight is one
cell or less (Cheapest), behaviour must be exactly as now. Handle the ends: the start may turn only as the model
allows from startDir; the finish may be reached part-way along a straight (reaching the goal cell in an allowed
direction finishes). If no path is found, retry the leg with the radius halved (down to the Cheapest radius) before
reporting no_path, and log it. Measure on all three captures (before/after table) and on the grid tests; keep the
existing grid tests passing (update only those that encode the old turning, with reasons).

## Task C: stations that face the line (`route.tl`)

Each station faces from the previous town to the next, which forced the Fastest route round the lake to approach
Aloha from the south-west. After the sites are found, scout each leg with a search between the two site centres
with free start and end directions; take each station's direction from its scout paths (from the point ~D metres
before it on the incoming path to the point ~D after it on the outgoing one; one side at the ends), find its site
again with that direction (keeping the old site if none is found), and plan the legs as now. Prototype figures
(D = 600 and 1200, old search): cheapest 15.1 → 14.8–15.0 km and tight 5 → 1–2; fastest 16.8 → 15.9–16.3 km but
tight curves unchanged (that's Task B's job). Choose D from the measurements. Progress and step budgets must still
spread the work over frames.
