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

`junction.fit` keeps its placements and rules: every cut 15 m clear of the stretch's start (and, since the second
in-game test, the whole junction 15 m clear of signals), switch
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

## As built: stage 1 (2026-10-19)

- **Reading:** a stretch starts as in 4b (two straight ground pieces across the station's axis past its fan), then
  each track is walked through plain nodes whatever their shape. At a facing switch the walk follows the branch that
  isn't a crossover leg (exactly one must be); anything else (a branch, a dead end, a node with four pieces) stops it.
  The two walks are paired every 2 m (gap 4.5–5.5 m, heights within 0.3 m, square across, both on the ground, no
  other track within 12 m across, except pieces joined to ours at a switch, and bridges or tunnels more than 6 m above
  or below). Past a crossover, a bridge or tunnel, or a drift, the reading carries on to the next stretch.
- **Placement:** every stretch long enough, nearest first, is tried; the junction must lie on straight midline from
  its first cut to 50 m past its approach start (direction within 0.5%). Our straight past the approach (the leg's
  run and room to turn) runs on while it stays at least the start's distance less 0.5 m from the existing track and
  within a grid cell of it: it stops where the line curves towards our side, and runs on where it curves away (the
  plan's stricter cap at the straight's end turned one test plan from 0 to 4 tight curves).
- **Footprint:** when the junction is on a later stretch, the track out to it (earlier stretches, and straight gaps
  between them) is banded too (`Station.before`).
- **Offline, line1 map (Aloha, Rail Router's own Halt 2+2):** its 4 tracks merge to 2 about 207–266 m from the
  centre, then crossovers at about 255–382 m cut the double track short (29 m and 66 m stretches); from 382 m each
  end reads one stretch of about 1276 m through its curve. Junctions: the −1 end's approach starts 347 m from the
  platform end, the +1 end's 397 m, both on the straight past the curve. Regression route Antelope → Imperial Beach
  via Aloha joins both ends; the network builds with no chunk problems.
- **Cost:** reading a station's two ends takes 3–8 ms on the desktop (about 4× in-game, once per plan) and allocates
  about 1.1 MB in that step (accepted: a one-off hitch).
- **Captures have no signals,** so offline runs assume right-hand running and no signal clearances; in-game reads
  the station's one-way signals.
- **Linked legs** (below) were added after the in-game test: a leg between two existing stations already joined by
  track is left out instead of duplicated.

## Linked legs (added after stage 1's in-game test)

The player built Aloha → Antelope → Mercer Island, then planned Antelope → Imperial Beach via Aloha with both
existing stations ticked. The planner put a junction just outside Antelope and laid a new double track beside the
existing Antelope–Aloha line to a second junction outside Aloha: nothing asked whether the two stations were already
connected.

- **The rule (agreed with the player):** when two consecutive stops are both joined at existing stations, and a
  train can already run from one to the other on existing track (no reversing) by a path at most 1.5 times
  (`LINK_DETOUR`) the straight distance between the stations' centres, the leg between them is linked: no scout, no
  search, no track, and no junction at either station's end facing the other. The plan says "Uses the existing line
  between A and B (3.2 km)". Otherwise the leg is planned as before.
- **Measuring (window, `survey.trackLink`):** for each consecutive pair of stops with existing stations offered, one
  `api.engine.util.pathfinding.findPathNodeToNode` query (TRAIN) from every terminal's vehicle node of one station
  construction to every one of the other's. It follows the track's geometry and ignores one-way signals (Rail
  Doctor). The path's length is the sum of its pieces' chords, each piece once; no path, or none readable, is no link.
  The entries are read defensively (`.edgeId`, `[1]`, the entry itself); in-game they were pairs, read by `[1]`
  (Antelope → Aloha: 114 entries, 97 pieces, 5625 m against about 4420 m between the centres). Entries that aren't
  track pieces (6 there, node entries (switches by each station), which add no length inside their constructions) are accepted only before
  the first piece and after the last; one between pieces is no link. A probe line logs each query, with each unread
  entry's index, entity and components, to confirm that.
- **Planning (`route.tl`, pure):** the 1.5× check is the planner's (`Input.links` carries the raw length). Before any
  station is placed, the linkable legs are settled (`resolveLinks`): each station touching one is read with that side
  left out (as at a line's end); a station that can't be used then (its other end has no room for a junction, say)
  gets a station of ours, so its links are dropped and its neighbours read again. A station whose legs are all linked
  uses no end at all (it faces the way from the previous stop to the next, at the ground's height). Linked stations
  aren't checked for being too close together. If every leg is linked, the plan fails with `nothing_to_build`
  ("Nothing to build: existing track already runs between A and B").
- **A linked leg** (`Leg.linked`) has no pieces, samples or spans: its length (the existing path's) counts in the
  line's length, not in the estimate; `network.build` gives it no edges and no chunk, so the preview, the check and
  the builder skip it.
- **Offline:** `replaylib.planOnMap` takes `links = { [leg] = metres }` (captures hold no train paths); no regression
  route uses it yet.

## Second in-game test (2026-10-20)

The player built Bangor → Aloha via Antelope, then planned Mercer Island → Aloha via Antelope. Two faults:

- **Antelope had no south fan pieces** (network `stretches()` dropped a fan's merge cut 0.24 m from a sample), so its
  south end read as mixed track and the planner built a new station. Fixed; a scan of 140 station ends on the
  regression maps finds none without a fan, and every regression route now also builds with Halt 2+2's fans.
- **Aloha's cross-in piece was refused at build time** ("Construction Not Possible", no collisions), alone too, after
  both existing pieces were split. Line 1's block signals stood about 19 m inside its span (far switch at x 265,
  crossing at 303, signals at 285), clear of every cut, which was all `junction.fit` checked. Now both tracks' signals
  must lie 15 m clear of the junction's whole span, the merge's switch to the cross-out piece's end. Not proven
  (captures hold no signals), but it was the only piece refused and the only one over a signal.

- **Result:** the plan reused line 1 between Antelope and Aloha and joined Antelope's south end with a junction
  (merge switch about 330 m out from the platforms), built first time; trains ran through it both ways. Map:
  `maps/rail-router-test-5x14km-junction.map`.

## What P17 found (2026-10-20)

- **Cuts on curves build:** both switches and the crossing node were split into 17.5° arc pieces of a 220 m curve
  (the general Hermite split), each within 0.001 m of the curve, and the game took every split and its lane repair.
- **The crossing pieces on the curve dry-run clean** on their own (cross in, cross out, from the outside).
- **A junction piece must pass the existing track's nodes at least about 1.5 m beside it:** the merge (110 m
  S-curve) was refused ("Construction Not Possible", no collisions) passing its own track's joint 27.5 m past the
  switch 1.32 m beside it; the same merge 90 m long (1.97 m) and shorter were clean, and the cross-in passed a joint
  1.60 m beside it. This holds on straights too (it may be what refused Aloha's cross-in in the first test).
  `junction.fit` now keeps every piece 2 m from every node and cut of both tracks but its own ends.
- **Whole junctions on the curve build, from either side:** with that rule, `junction.fit` at radius 300 put all three
  cuts on arc pieces (merge switch x 130, far switch 260, crossing 314.5, 0.03 m or less off the built curve), and
  both junctions dry-ran clean and built (outside about 98,600, inside about 92,900, standard catenary, flat).
- **Branch radii on a 220 m curve with 300 m turnouts:** outside, merge 102.5 m and cross out 110 m (the pieces turning
  against the curve); inside, merge 113 m and cross in 123 m. None came near the game's limit (45 m), and all pass the
  spec's 100 m floor, so neither side has to be ruled out on the planner's tightest curve; the 100 m check stays,
  for tighter turnouts or curves.
- **Mapping is enough:** the frame-mapped tangents met the existing track within 0.01° at the switches; the variant
  with snapped tangents was never needed.

## As built: stage 3 (2026-10-20)

- **Placements on curves** (`planner/placement.tl`, `placement.accept` as `junction.fit`'s accept): our straight past
  the approach start must have its 50 m beside the track (`rayRoom`, checked first: on a curve's inside the track
  comes back across a straight laid off it within about 46 m), and no mapped piece may be tighter than 100 m unless
  it is no tighter than the same piece on straight track (the merge S-curve of 150 m turnouts is 94 m as one cubic
  even on a straight). The spec's separate 2 m clearance from the existing tracks' lines is left out: P17's mapped
  pieces matched the built curve within 0.03 m, and `junction.fit`'s 2 m node rule covers the joints.
- **Two places per end:** one fit per stretch finds both the nearest placement anywhere and the nearest on straight
  midline (a straight placement counts as "anywhere" too). Placements often straddle a curve's end (first cut on the
  curve, approach past it). Each place's approach straight is checked for buildings when the station is read; places
  that fail are dropped.
- **The choice:** each combination of the leg's ends' places (at most 4) runs the leg's whole search, radius tries,
  fillet and heights; combinations are compared first by arcs below the build minimum, then steep ends, then blocked
  samples, then **Cheapest: the leg's estimate** (as the spec says; weighing by search cost instead picked a place
  whose leg ran 14 m beside another line and bridged it 7.3 m clear, under the 7.5 m floor, since crossing clearance
  is measured from the grid's coarse ground: a follow-up), **Fastest: the time platform to platform**, shared existing
  track included, ties within 0.5 s by estimate. A combination with no path is skipped. Notes "Joins the existing line
  N m out from X's platforms." come from the places finally used.
- **Offline (kit maps):** on line1, Bangor's north end and Aloha's south end have curve places; on the junction map,
  Mercer Island's north end. Regression routes: Mercer Island → Imperial Beach, Fastest (junction map; joins on the
  curve's outside, first cut 125 m along, approach 327 m), and Bangor → Antelope, Cheapest (line1; 2 tight curves, the
  first an 86 m turn back 49 m past the approach: both of Bangor's places point away from Antelope).

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
- **The wye (next milestone, 4d, agreed 2026-10-20):** a junction faces the station it serves, so after
  Mercer Island → Antelope joined line 1 south of Antelope, a Mercer Island → Bangor train would have to reverse.
  The other side of the triangle needs junctions on line 1 between stations, facing either way; it will use this
  frame and layout.
