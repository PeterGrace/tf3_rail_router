# Rail Router Milestone 4b: using existing stations (design)

Agreed with the player on 2026-10-18. This extends the main design (`2026-10-16-rail-router-design.md`).

## Goal

Where a town on the route already has a rail station, the new line can run into that station instead of
placing its own. The existing station is usually already on other lines, so the new line **branches into the
existing double track outside the station**, and the lines share its platforms. Lines can then grow into one
network.

The player chose these, in order:
- **Branch into the existing tracks.** Don't widen the station, and don't build an interchange beside it.
- **Any double track.** Player-built track counts, not only lines Rail Router built.
- **A flat junction, or a flying one where it fits.**

## Staging

Each step ends with an in-game test.

1. **Probe P15.** Splitting existing track, a track-over-track level crossing, and a switch into signalled track,
   all from a script (see "Unknowns").
2. **4b-1:** finding the stations, the window option, and the flat junction.
3. **4b-2:** the flying junction where the straight stretch is long enough. Otherwise the junction stays flat.
4. **Junctions on curves (later, its own milestone and probe):** a junction that follows the existing line into its
   curve. Needed for stations Rail Router built (see "First in-game test").

## What the player sees

- Before planning, each stop town is checked for a usable rail station (below). A town that has one shows
  **"use the existing station in X"** in the stop list, ticked by default. Unticked, the stop gets its own Halt 2+2
  station as now.
- If an existing station turns out not to fit, the stop falls back to a new station. This happens when the
  approach is too short for a junction, or when the legs can't reach opposite ends. The window then says why:
  "The station in X has no room for a junction (needs N m of straight double track); a new station was planned."
- The plan's summary and the check count the junctions ("Junctions: 2"). The built line's summary does too.

## Usable stations

A station is usable if all of these hold:
- It's a construction with rail station terminals, within 1.5 km of the town's centre (the station-site reach).
- It's a **through station**. Track leaves both ends of its platforms.
- At an end the line uses, the track running out from the platforms becomes a plain **double track**: two parallel
  tracks 4.5–5.5 m apart. This counts only past the station's own switches, which also means past its fans if it
  is a Halt 2+2.
- That double track then runs **straight, on the ground, with no switches**, for at least the junction's length
  (below).
- The stretch must be **straight in 3D**: on the ground, on a steady grade, within 0.5 m of the straight line
  through its start (the junction is built on that line).
- Signals on that straight stretch are allowed. We never move or remove them. The junction's points must stay at
  least 15 m from them, the same clearance as our own signals.

**Running directions.** Each existing track's direction comes from its one-way signals, read through
`signalSystem.getSignal` as Rail Doctor does. A track with no one-way signals is taken as right-hand running for the
line's direction. If the two tracks' signals point the same way, the end is not usable.

A record per usable end, `ExistingStation.ends[k]`, holds:
- the point where the straight stretch starts and its direction outward;
- its length;
- each track's offset from the axis and the direction it runs;
- the entities of the existing pieces along the stretch;
- the positions of its signals.

## Junction geometry (flat)

The frame for one junction:
- **x** runs along the existing axis, outward from the station.
- **y** runs across it, positive to the left of outward. The new line comes from either side; the frame is drawn
  for the +y side and mirrored for −y.
- The existing tracks sit at y = ±2.5. "Near" means the existing track at +2.5.

The pieces, from the station outward:
1. **The merge.** Our far track, at y = +12.5, joins the existing near track (+2.5) with an S-curve: a switch on
   the near track at x = m. Its length is L₁₀ = max(40, √(4 R × 10)), where R is the turnout radius
   (`turnoutLength` for a 10 m offset: standard track 110 m).
2. **The crossing.** Further out than the merge, our near track, at y = +7.5, runs in to the existing far track
   (−2.5) as two circular arcs of the turnout radius R, each turning θ = acos(1 − 5 / R) and climbing 5 m over
   C = R sin θ along x (standard track: θ = 10.5°, C = 55 m). The inner arc leaves a switch on the far track at
   x = c₀ and ends at the **crossing node**, a node cut into the existing near track at x = c₀ + C. The outer arc
   leaves that node, tangent to the inner one, and ends on our near track's line at x = c₁ = c₀ + 2C. Each arc is
   one piece: the game refuses a new piece over existing track unless they share a node (P15). The crossing's x
   range lies wholly outside the merge's, so our far track (+12.5, straight there) is never crossed, and by the time
   the merge brings our far track down across y = +7.5, our near track has already left.
3. **Our approach.** Two parallel tracks at y = +7.5 and +12.5, straight for 30 m, then the leg proper.

**Order.** With right-hand running on both lines, the existing near track runs the same way as our far track,
whichever side the line comes from. So our far track always **merges** into the existing near track, and our near
track always **crosses** to the existing far track. Coming from +y: inward trains use the existing near track
(+2.5) and our far track (+12.5); outward trains leave on the existing far track (−2.5) and turn off onto our near
track (+7.5). Coming from −y it mirrors: the existing near track (−2.5) and our far track (−12.5) carry outward
trains, and inward trains come off our near track (−7.5) and cross to the existing far track (+2.5). An end whose
signals show left-hand running is not usable.

The crossing sits further out than the merge, so the two never cross each other. Both connections face the
station: trains from our line can only run into it, and trains reach our line only from it (P15).

**Length needed:** 15 m clear of the station's last switch or signal, plus L₁₀ for the merge, plus 20 m between,
plus 2C for the crossing, plus 30 m of approach, plus 15 m of signal clearance. On standard track that is
110 + 109 + 80 = 299 m. On high-speed track, with R = 600, L₁₀ = 155 and 2C = 155, it is 390 m.

**Signals of ours** (as built):
- one one-way signal on each of our two approach tracks, 15 m out from the approach start (and at least 15 m from
  any node), each facing its own track's trains, with or without Halt 2+2; none on the junction pieces;
- at our own stations, starters and home signals as now, and blocks every so many metres from the junction's
  signals on.

**Existing nodes.** The junction keeps clear of the existing track's nodes (its pieces' ends): a switch cut has no
node within 20 m outward of it (the game refuses a switch whose main track on the branch side is 16.6 m or shorter)
or 3 m behind it, unless one is within 0.5 m, which then is the switch; the crossing has no node within 3 m unless
one is at its very place, which then is the crossing node. The fit also tries the placements that put a cut on a
node.

**Overhead wire.** Where our two tracks run side by side beyond the junction pieces (from the crossing's outer end
to the approach start), the two straights are a parallel pair and carry the pair's `distance`, as our line's
tracks do; the junction pieces carry 0.

The existing line's signals are left alone. Path signals reserve the route through the junction, so trains on
the two lines wait for each other at the level crossing.

## Flying junction (4b-2)

The crossing track runs over the existing near track on a bridge, 9 m above it (the planner's CLEARANCE). Its ramps
are graded at the mode's grade limit, so the crossing piece becomes longer: 2 × 9 m ÷ grade, plus the bridge. That
is about 2 × 360 m at 2.5% (Fastest) and 2 × 106 m at 8.5% (Cheapest).

It is used where the straight stretch is long enough. Otherwise the junction is flat. The merge stays as it is.

## Planner

- **Survey.** Read each stop town's stations. For each end, follow the track from the platform ends through the
  station's switches until a plain double track begins, then measure its straight, switch-free stretch and read its
  signals. The result is `ExistingStation` records, as pure data. The map capture is extended with station
  terminals and signals, so this can be tested offline.
- **Choosing ends.** For a stop with an existing station:
  - A station in the middle of the route uses the end facing the previous town for the leg in, and the end facing
    the next town for the leg out. These must be different ends, so the line runs through the station.
  - A station at an end of the line uses the end facing its one neighbour.
  - If the needed ends aren't usable, the stop falls back to a new station.
- **Legs.** The leg's fixed end is the junction's approach start, at x = junction length out from the station end,
  on y = +10 (the axis of our two tracks), facing along x. It replaces the site's platform end. As at a station of
  ours, an approach straight (the planner's approach length) and a room to turn follow it along x; the junction is
  fitted so that the approach lies along the straight stretch, and the room to turn and the search's run along the
  axis (beside the existing track, so the leg may leave the stretch anywhere along it) stop at the stretch's end.
  The grid search ends there, as it does at a station's approach today.
  - **The existing line's cells.** The survey marks them as track, which the search otherwise crosses (a crossing,
    bridged) and runs along for free. Along the stretches used, from the station's centre out as far as our
    straight and run may reach, the cells from our side's track across to a cell beyond the far track are kept off as
    a station's footprint is (but for the leg's own end cells, along its run), so the leg leaves the existing line
    sideways, on our side. Past the stretch's end, the cells from half a cell beyond the far track out stay kept off
    as far as the snapshot reads, so the leg doesn't come round the far side and cross the line. Moving from track
    cell to track cell costs as a bridge (but along the stations' own track), and fitted curves may not run along
    track cells the path didn't use for more than two cells.
  - **Crossings in the profile.** Round an existing station (within the snapshot's reach) a sample crosses track
    only within 6 m of a snapshot piece's curve, so our straight beside a stretch, and a leg passing the stretch's
    end where a 100 m cell overhangs it, stay on the ground; farther out, the cells decide as before.
- **No station of ours** is placed at that stop, and it gets no road.

## Network

- Junction pieces are edges, as the fans are: `Edge.track` 4 for a junction piece. Their ends that land on existing
  track are marked as **cuts in existing pieces**: `{piece entity, parameter, kind}`, where kind is "switch" or
  "crossing". The edge's end node there is filled in after the split.
- Junction pieces go in the chunk with the leg's end that they join.

## Builder

**Before a chunk with junction pieces**, split each affected existing piece at its cuts, sorted along it, as for
level crossings:
- Edit the engine's `replaceSegment` proposal into pieces with new nodes, keeping the piece's track type, its
  `distance`, its owner and its signals.
- Send it. It can't be dry-run, as with the street splits.
- Record the new nodes by place.

The level-crossing point becomes a node where four pieces meet.

**Then the chunk**, joined to those nodes, is dry-run and sent. Our home signals are part of the chunk.

**The check** dry-runs the junction chunk before any split, **without its junction pieces**: a new piece lying over
existing track it shares no node with is refused as "Construction Not Possible" (P15), so they can't be dry-run until
the track is split. Any other edge ending on a cut is left out too. The rest is dry-run as any chunk: level
crossings aside, any collision (with the existing track too) is an error. So the check can't see a junction's own refusal: that only shows at build time, when the whole chunk is
dry-run after the splits.

**A failure** stops the build with Show and "Retry from here", as now. A split already made is harmless: it leaves
extra nodes on the existing track.

## Unknowns, for probe P15 (test map)

P15 builds a short straight double track with one-way signals, places a train on it if the player likes, and then:
1. Splits one of its pieces from the script, keeping its signal, and logs whether the signal survives and stays on
   its side.
2. Builds a flat junction into it, with a switch on each track and a level crossing over the near one. It logs the
   dry run, the build, the pieces at the crossing node, and whether the game drew a track crossing.

The player then runs a train through each route of the junction, and along the existing line across the
crossing.

### What P15 and P16 found (2026-10-18, in-game)

- **Splitting existing track:** the engine's `replaceSegment` proposal, edited into pieces, works on signalled track
  and the signal survives on its piece. The new node has no `BASE_NODE_CONFIG`; sending each piece at it again,
  unedited (`replaceSegment`), gives it one.
- **A new piece may lie over existing track only where the two share a node.** Every refusal fitted this: a crossing
  piece starting at a node of ours 1.5 m beside track 2, and a branch running 0.6 m beside a track piece beyond a
  joint 20 m from its switch. So a switch's branch must stay one piece until it is clear of the track it left, and the
  crossing track must be one piece from its switch into the crossing node. No crossing is made where the track has no
  node, at any angle (10° to 90°), even with `cleanupStreetGraph`.
- **The crossing:** a node on the crossed track with four pieces, the crossing track's two pieces tangent to each
  other there. The game's own tool makes straight pieces (P16 copied it at 6.5°); P15's two circular arcs, 12° at the
  crossing, radius 228 m over 47.6 m each, also built.
- **The built junction:** switch on track 1 at x = 60 with a single 110 m S-curve to +12.5; switch on track 2 at
  x = 152.4; crossing at x = 200. Both connections face the station (west): a train off our line can only turn
  towards the station, as designed.
- **Junction geometry, revised:** the crossing is two circular arcs meeting at the crossing node (see "Junction
  geometry"), at the turnout radius rather than P15's 12°, so the crossing angle is 7.4° to 14.8° by track type;
  P16's 6.5° built, so all are within what the game accepts. Its switch keeps the 16.6 m rule and the 15 m signal
  clearance like any other.

### First in-game test (2026-10-19)

- **Rail Router's own stations can't take a flat junction.** Past Aloha's fan, its line runs 141 m (north) and 195 m
  (south) of straight double track, crossovers included, before curving; the stations' 225 m approach is all the
  straight the planner gives them. A junction needed 524 m on Standard track (299 m for 300 m turnouts, and our 225 m
  approach beside the existing line). Now it uses 150 m turnouts whatever the track and 50 m of our straight
  (`route.tl` JUNCTION_STRAIGHT; none gave curves tighter than the radius with the stops in line): about 282 m. 4b-1
  joins long straight lines (hand-built main lines); Rail Router's stations fall back with the "no room" note.
- **Rejected:** a 250 m straight past every station of ours, so later lines could join (23 of 37 regression routes got
  worse: loops, tight curves, a stall); and squeezing the junction (100 m turnouts, no margins: about 187 m, still
  short at Aloha's north end).
- **Found on the way, older than 4b:** a station's main building over streets in the next 100 m cell (Bangor), and a
  bridge crossing a line at a shallow angle dipping below 8 m over it in cells not marked track. Both now check the
  streets' and track's own points (`Grid.streets`, `Grid.tracks`). Also: an existing station within reach of two
  towns was offered to both (now only the nearer), and captures now record the station approach.

## Testing

- **Unit tests:**
  - junction geometry: the pieces' ends, offsets and tangents, the order set by the running directions, mirroring,
    and the length needed;
  - choosing ends;
  - falling back when the stretch is too short.
- **Offline:** survey records from the extended capture. PottstownTown's existing station is the first case (its
  station boxed in the new site in milestone 1). We also need a test map line built by Rail Router, captured after
  the build.
- **In-game, 4b-1:** on the test map, build Bangor → Imperial Beach. Then plan a second line that stops at one of
  its stations, for example a new town pair through Aloha. Build it and run trains on both lines.

## Out of scope

- Single-track lines, termini, approaches with switches or curves where the junction would go, and left-hand
  running beyond what the signals show.
- Changing the existing station or its signals.
