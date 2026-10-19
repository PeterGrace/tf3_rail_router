# Rail Router Milestone 4c: junctions anywhere along the existing track (design)

Agreed with the player on 2026-10-19. This extends milestone 4b (`2026-10-18-rail-router-existing-stations-design.md`):
its usable stations, junction layout, running directions, signals and builder all carry over unless changed here.

## Why

4b's flat junction needs about 282 m of straight double track past the station (150 m turnouts, 50 m of our
straight). Rail Router's own stations leave 141–195 m before their line curves, so a later line can never join them
and falls back to a new station (4b's first in-game test).

Measured on the 34 regression routes' planned lines (204 station ends, today's planner, 320 m platforms): 10 ends
have room right past the fan; 164 have a straight of 282 m or more further out within 1.5 km (median about 400 m
from the platform end, most 300–800 m); 30 have none. The player expects curves to matter soon on hand-laid lines
too, so both are in this milestone:

- **B:** read on through curves to a straight further out, and put the junction there;
- **A:** put the junction on the curve itself.

## One layout, laid along the track

4b draws the junction in a straight frame: x along the station's axis outward, y across it (left of outward
positive), the existing tracks at y = ±2.5. 4c keeps the same layout (merge, crossing, 30 m approach; 4b "Junction
geometry") and the same frame coordinates, but the frame follows the existing double track: **x is the distance along
its midline** outward from the station end, **y the offset across it**. On a straight this is 4b's frame. B is a
placement on a straight part of a longer stretch; A a placement where the midline curves.

## Reading an end

From the station's end, the analyser (`existing.analyse`) walks the two tracks outward piece by piece, through
curves, up to 1.5 km (as now). The stretch carries on while the tracks stay a **plain double track**:

- exactly two tracks, 4.5–5.5 m apart, checked every 5 m and at each node;
- level with each other across, within 0.3 m;
- on the ground: a bridge or tunnel ends the stretch;
- through plain nodes only (degree 2): any switch ends it, except the station's own fan merges and crossovers
  before the stretch starts (as now), and the tracks must still lead back only to the station's end nodes.

4b's "straight, on a steady grade, within 0.5 m of a straight line" rule goes. The stretch now records:

- **its midline**, every 5 m from its start: position (x, y, z) and unit direction, with x the distance along it;
- each track's existing **nodes** and one-way **signals**, as distances along the midline (projected onto it);
- each track's **pieces** in order, as now, for the cuts.

Running directions (signals, right-hand by default, left-hand not usable) are unchanged.

## Fitting

`junction.fit` keeps its placements and rules: every cut 15 m clear of signals and of the stretch's start, switch
cuts clear of nodes (20 m outward, 3 m behind, or on one within 0.5 m), the crossing node clear of nodes (3 m, or on
one), placements tried every 5 m and at nodes. What's new is the mapping and two checks per placement:

- **Mapping.** A frame point (x, y) maps to the midline's point at x plus y along its left normal there, with the
  midline's height; a frame direction maps by the midline's direction at x. Each junction piece becomes one track
  piece between its two mapped ends: positions, directions and grades (the midline's slope at each end) carried
  over, tangent lengths from the piece's length along the frame. Pieces are never split (a switch's branch must stay
  one piece; P15/P16).
- **Radius:** each mapped piece, sampled along its Hermite curve, is nowhere tighter than **100 m** (about 50 km/h
  at the planner's 2 m/s² lateral acceleration). A branch to the inside of a curve bends tighter than its turnout:
  150 m turnouts on a 220 m curve (the planner's tightest) come to about 90 m, so that side isn't used there.
- **Clearance:** each mapped piece keeps at least 2 m from both existing tracks' centre lines, sampled every 2 m,
  except within the 20 m next to a node it shares with that track (a switch's branch leaves its main track
  gradually).

**Places per end.** Two placements are kept: the nearest wholly on straight midline (direction within 0.5% over the
junction's whole x range), and the nearest overall. Where these are the same, one.

## Planner: choosing the place

Each kept place gives the leg a fixed end (the approach start: its point, direction and height), as 4b's single
junction does. The planner plans the leg from each and keeps the better line:

- **Cheapest:** the lower estimate (track, earthworks, structures, as the plan's estimate);
- **Fastest:** the shorter time, the leg's own plus the shared stretch from the junction's approach start to the
  platform end at the existing track's speed.

A leg with an existing station at both ends tries at most 4 pairs. The extra searches run in the planner's usual
steps (each about as long as a leg search now). The plan's notes say which place was taken where there were two
("Joins the existing line 420 m out from Aloha's platforms").

## Building

- **Cuts on any piece:** a switch or crossing node is cut into an existing piece at any parameter, curved pieces
  included. The split is the general Hermite split at t (the piece converted to its Bézier form and split by de
  Casteljau), replacing the midpoint formula; the cut point's parameter is found by the nearest point on the
  piece to the frame position. As now, the edited `replaceSegment` proposal, then each new piece sent again unedited
  for its node configs.
- **The crossing node** is where our crossing piece meets the existing near track: frame x = c₀ + C, as in 4b,
  mapped onto the track.
- Proposals, chunks, signals, overhead wire and lane repair are as in 4b.

## Stages

Each stage ends with an in-game test.

1. **B: the new reader, placements on straight parts only.** Offline, the analyser runs on the real Rail Router
   line in the kit's `line1` map (Aloha → Mercer Island, its built stations and track). In-game: on the test save
   with Bangor → Imperial Beach built, plan a line through Aloha with "use the existing station" ticked: the first
   in-game flat junction.
2. **Probe P17: cuts on a curve.** On a curve of that line, from a script: a switch with a branch to the outside, one
   to the inside, and a crossing node, each dry-run and built. Answers: does the game take a switch cut into a curved
   piece, at our split; does the crossing work on a curve; how tight a branch passes.
3. **A: placements on curves.** In-game, a line joining a station whose only room is on a curve.

## Testing

- **Unit:** the midline from synthetic pieces (straight, arc, straight then arc, an S-bend); mapping frame points and
  directions onto it; the Hermite split at any t (both halves reproduce the curve); the radius and clearance checks
  (a branch to the inside of a 220 m curve refused, to the outside passed); the two kept places; the planner's choice
  (cheaper estimate, shorter time with the shared stretch).
- **Offline, real track:** the `line1` map's Aloha and Mercer Island stations analysed from their captured pieces:
  each end's stretch runs through the first curve, with the expected place on the straight beyond.
- **Regression:** a route on the `line1` map that stops at Aloha with the existing station: a junction, not a
  fallback. Existing baselines unchanged except where a junction now replaces a fallback (re-recorded with a note).

## Out of scope

- The flying junction (4b-2) stays a later stage; it will use this frame.
- Junctions on bridges or in tunnels, and on single track.
- Moving or removing existing signals.
