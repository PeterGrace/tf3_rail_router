# Rail Router: design

Mod id `pgrace_rail_router`. The player picks two towns, and the mod plans a double-track rail line between them,
with stations in the chosen towns along the way, shows it on the map with the game's cost, and builds it with one
click.

## Decisions

| Topic            | Decision                                                                                   |
|------------------|--------------------------------------------------------------------------------------------|
| Scope            | Plan, preview and build (one-click Build).                                                 |
| Modes            | **Cheapest** (follows the terrain) and **Fastest** (wide curves, flat grades).             |
| Entry point      | A window opened from the mod button area (like Trim the Fat and Jam Session).              |
| Track layout     | Double track. Every station is a 2-track through station. No signals.                     |
| Stops on the way | Towns within a 15% detour are listed; those fitting a 15% budget together come pre-ticked. |
| Station placement| Always best effort **without demolishing anything**: nearest clear spot to the town centre. |
| Settings         | Track type, electrified, platform length, defaulting to the best available.               |
| Route search     | Grid search over a cost grid, then curve smoothing, then a height profile.                 |
| Cost shown       | The game's own price, from a dry run of the actual proposals.                              |

Town layout and reputation are never sacrificed: the track and the stations avoid town buildings (30 m buffer) and only
cross streets.

## Architecture

```
content/gui/pgrace_rail_router/
├── window.script.tl     UI: mod button, window, settings, results, Show/Build
├── survey.tl            engine reads → plain data: terrain/water grid, town
│                        centres, building footprints, existing track and roads
├── planner/             PURE (no api.*), unit-tested
│   ├── grid.tl            cost grid + 16-direction cheapest-path search
│   ├── corridor.tl        picks candidate towns along the way (detour budget)
│   ├── smooth.tl          jagged path → straights + arcs ≥ min radius
│   ├── profile.tl         heights under the grade limit → bridge/tunnel spans
│   ├── stations.tl        nearest clear straight spot to each town centre
│   └── modes.tl           Cheapest/Fastest weights; track type → limits
├── preview.tl           draws the route on the map (chain of static arrows)
└── builder.tl           plan → proposals → dry run → build
```

Data flow:

1. The player picks the towns, the mode and the settings. `corridor` lists the candidate stops straight away (it
   only needs town centres); the player ticks the ones they want and presses **Find route**.
2. `survey` samples the area around the chosen stops over several frames (`react.enqueueJoin` steps, 6 ms of work
   per frame, measured with `api.type.Clock`), showing "Surveying… N%".
3. The planner runs: `stations` → `grid` → `smooth` → `profile`, producing a **Plan**.
4. `builder` dry-runs the Plan and reports the game's cost and any errors.
5. **Show on map** draws the Plan, and **Build** sends it once the dry run is clean.

The **Plan** is plain data: a list of stations (position, direction, length) and a list of track pieces (straight or
arc geometry, heights at both ends, and kind: ground, bridge or tunnel). Everything from the survey output to the Plan
is pure, so it can be tested end to end on artificial maps.

## Survey (`survey.tl`)

- **Corridor:** the box around the chosen towns, plus a 25% margin (at least 2 km), cut to the map's extent (the
  terrain's bounding box, else TERRAIN.size × 256 m) whole cells at a time. If a leg's grid search finds no path,
  the window starts the work over (survey and plan) with the margin doubled, up to twice (0.25 → 0.5 → 1.0), while
  that gives a bigger box, showing "Widening the search… N%"; only then is "No route found" shown. A station walled
  in by buildings ("no_exit", below) never retries. The grid coarsens past 250,000 cells, so a wider margin costs
  resolution rather than memory. (Uncut, margin 1.0 on a 16 km map had 121,684 of 148,580 cells off the map.)
- **Spread over frames:** every task stops at the frame's budget and carries on in the next: a row's terrain
  mid-row, a 500 m tile's octree lookups one per call and the marking of what they found in slices. On a dense 2254
  save a whole row took 35 ms in-game and a 1 km tile 62 ms. The log's summary gives the slowest slice of each
  kind.
- **Per 100 m cell:** `api.engine.terrain.getHeightAt` and `isOnWater` at the cell centre.
- **Buildings and other constructions:** `octree.findEntitiesInCircle(..., CONSTRUCTION / TOWN_BUILDING)` over the
  corridor in ~1 km tiles; mark cells within 30 m of any of them (town buildings, stations, industries, depots) as
  blocked.
- **Existing roads and track:** `BASE_EDGE_STREET` and `BASE_EDGE_TRACK` entities in the corridor; mark the cells they
  cross.
- **Towns:** all towns with their centre positions (for the dropdowns and the candidate stops).
- **Limits for the track type:** read from the track's `.street_template` data (`cost`, `maxSlopeBuild`,
  `minCurveRadiusBuild`, the lane speed, `trackDistance`, the availability years).

## Planner

### Modes and track types (`modes.tl`)

|                      | Cheapest                          | Fastest                                         |
|----------------------|-----------------------------------|-------------------------------------------------|
| Minimum curve radius | `minCurveRadiusBuild` × 4         | the radius for the line speed (≈ 1,500 m+ for high-speed) |
| Maximum grade        | the type's `maxSlopeBuild`        | 2.5%                                            |
| Bridges and tunnels  | expensive                         | cheap relative to detours                       |
| Turn penalty         | low                               | high                                            |
| Road crossings       | level crossing                    | bridge                                          |

Defaults: the best track type available in the current year (high-speed in Fastest mode once it's unlocked),
electrified once catenary is available, 160 m platforms.

### Grid search (`grid.tl`)

The cheapest path over the 100 m cells with 16 move directions, between consecutive station approach points. Each
step costs its length × the sum of:

- the base cost per metre (the track type's `cost`);
- slope: grades over the limit cost extra, and grades far beyond it are priced as a cutting or a tunnel;
- water: priced as a bridge (wide water is not banned, just expensive);
- town buildings: impassable;
- existing roads: crossing allowed (priced per mode, above);
- existing track: crossed only by a bridge, never through a junction (the height profile makes the bridge);
- a turn penalty per change of direction;
- where every move may turn (below), the straight a corner's curve lacks.

The search state is (cell, arriving direction), so turn costs are exact and the result is optimal for the cost
model (checked against an exact reference on random grids). It arrives at each station's approach in the platform's
direction. Legs keep off the stations' platforms and approaches (all stations', but for their own end cells), so a
line that goes round never crosses a station's track.

**Turns spaced for the radius.** A 22.5° turn rounded at radius R takes R·tan(11.25°) of straight on each side of its
corner, so consecutive turns need L = 2·R·tan(11.25°) (≈ 0.4 R) between them. Where L is more than a cell (Fastest's
wide radii) the moves are long edges: from a state (cell, direction) the search may go one step straight on, or turn
by one 22.5° step and carry on straight for ceil(L / step length) steps (every cell on the way checked and costed as
single steps are), after which it may turn again. The state space stays (cell, direction), so the search is still
optimal for this model and the heuristic still admissible. The start may turn at once (the station's extension gives
room behind it); passing through the goal cell part-way along a turn's straight finishes there only heading the
platform's way, and a state at the goal may make one last single-step turn onto it. The path's first and last segments
run from and to the asked points, off their cells' centres, so they are checked for blocked cells on their own (a
diagonal past a blocked cell's corner would cut it).

**Corners priced by their curves' room.** Where L is no more than a cell (Cheapest, R = 4 × the build minimum, and the
fallback radius of Fastest legs and of the scouts) any move may turn by up to 90°. That used to be free of any spacing,
so a path could turn 90° every 100 m (a hook into a station sweeping 270° in a few cells), which the track can't follow
even at the build minimum, and smoothing then cut corners over buildings or curved below it. Now a curve turning θ at
radius R takes R·tan(θ/2) of straight either side of its corner, and a corner between two cell moves has half of each
to itself (the other half is the next corner's):

- a turn whose curve at the build minimum doesn't fit there is not made (90° between two straight moves needs 55 m a
  side, more than half a cell: it takes a diagonal or knight move on one side, or two 45° turns);
- the straight its curve at the search's radius lacks costs a metre of plain track per metre (`SHORTFALL_FACTOR`):
  about the track a path with room for the curve would take, so a hook pays roughly what a curve of that radius round
  it would cost.

The cost of a corner depends only on the two moves either side of it, so the state space stays (cell, direction),
with one table lookup per move. Next to the leg's ends, off their cells' centres, corners are priced as the path really
runs, from the end point itself: the start point's corner together with the next one, sharing the straight between
them, the station's room to turn behind it (or the approach where there's none), or, with room to turn, at the
approach point instead with the approach behind it (smoothing then gives the extension up: below); the goal's alike.
The state a start's first move reaches is a state of its own, so the start's corner is priced on its next move
exactly; at the goal the corner before is priced again as it turns onto the goal point, for any more it costs (so
there the model looks one corner back, from the state's own direction only: optimal away from the leg's last corner).

Options measured on the regression set (31 routes, re-siting on unless said; base: 386.1 M estimate in all, 16
samples on blocked cells, a 54 m curve, 4 routes with a leg sweeping over 200°, 1.54 M expansions, 10.6 s):

- spacing turns strictly for the search's radius (220 m: one 22.5° step a move): 13 of 31 routes found no path. Towns
  need sharper turns than that at stations;
- at most 3 steps a move (spacing for the build minimum, no pricing): 9 failed, mostly legs whose stations face
  buildings (the old search turned 90° at the station's end);
- the turn of the previous corner in the state (5 × the states; each corner checked against the one before for the
  build minimum, the shortfall for the search's radius charged): 0 failed, 2 samples on blocked cells, estimate +3%,
  but 3.3 M expansions and 2.7 × the time;
- corners priced by halves (chosen): 1.23 M expansions, 9.4 s, estimate 396.0 M (+2.6%: paths that cut corners or
  curved below the build minimum no longer count), no curve below the build minimum, 1 sample on a blocked cell, 3
  routes over 200°. The shortfall factor: 0 (only the build minimum) gave 396.3 M, 2 gave 401.8 M and 4 408.8 M.

**Ends along the stations' axes.** Where turns are spaced, a leg's search may start anywhere on the ray beyond station
A's extension point along its direction, and finish anywhere on the ray before B's (one point per cell, up to 1 km and
never past half way, stopping at blocked, water, road or track cells, each costing its straight); the station's
straight is then just longer. It helps little: along one of the 16 headings the search could already run straight
on, so it matters only for stations facing between them.

A leg is built over three steps (simplify, fillet, heights), so no frame does all three.

**Radius fallback.** A Fastest leg is searched first with turns spaced for the Cheapest radius (the fallback; if that
finds nothing, the plan fails "no_path"), then for the mode's radius, halving while above the Cheapest one, until a
path costs at most 10% more than the fallback's; if none does, the fallback's path is taken. A radius that doesn't fit
(station ends misaligned or close together, a passage too narrow) otherwise finds a loop or a wide detour, or nothing
after a long search; the cost limit ends those searches early. The radius used is recorded per leg (`searchRadius`, in
the log and the replay tool); smoothing still aims for the full radius, so a leg searched with a smaller one may have
tight curves. Cost on the captured Fastest map (4 legs, R = 3000 m): about twice the expansions of the one-step
search (7,400 against 3,900; about 45 ms against 28 ms offline), Cheapest unchanged. Known cost (plain Lua, desktop): a 500 × 500 grid with 15% clutter took about 1.6 s and 35 MB in Cheapest
mode and about 6 s and 90 MB in Fastest mode, spread over frames. If that's too slow in-game, weight the heuristic
(f = g + 1.2·h) in Fastest mode, giving up exact optimality that smoothing hides anyway.

### Smoothing (`smooth.tl`)

Turns the grid path into straights and arcs, every arc at least the mode's minimum radius, keeping the direction at
each station end.

**Guard:** simplifying and filleting are checked against the ground the grid path chose, every quarter cell: track
must stay inside the grid and off blocked cells, may be over water only where the nearest point of the path line is,
and its ground must be within 4 m (a starting value, tuned in-game) of a uniform slope across the path there (taken
from the ground at that path point and at the mirror image of the track point, so a plain incline never trips it). A
straight that fails keeps an extra path point, a point whose removal would leave a failing straight is kept, and an
arc that fails has its radius halved until it passes; the floor for both is the track type's build minimum radius (a
point whose curves wouldn't fit at the floor is dropped anyway: a cut corner beats an unbuildable curve). `guarded` in
the plan's summary counts these, and the log shows it. Away from a leg's first and last three path points the track
also keeps off the stations' platforms and approaches.

A point is not dropped where that would leave a corner whose curves don't fit even at the floor: on a tight loop over
open ground, dropping points for room at the full radius folded the loop into one corner (a 13 m curve over a wall).
The path is simplified to within 0.6 of a cell (0.75 folded such a loop into one sharp corner before filleting).

**Station ends.** Where the curve at an extension point can't be built (below the build minimum), or the track near
an end crosses blocked cells (a corner cut there), the extension is given up: it is put on the approach point, so the
curve starts there, with the approach behind it, as the search allowed for. A refit that crosses fewer blocked cells
is taken.

### Height profile (`profile.tl`)

Fits the track's height to the terrain under the grade limit, as cheaply as it can. Where the track is more than 8 m
above the ground it becomes a bridge, and more than 12 m below a tunnel. These thresholds are starting values, tuned
in-game.

**Crossings:** samples over existing track, and over roads in Fastest mode (`Weights.bridgeRoads`), are bridges and
are never merged away. The track there is lifted to at least 7 m above the ground, ramping up and down within the
grade limit; the station heights pinned at a leg's ends win if a crossing is too close to them. In Cheapest mode
roads are crossed on the level.

**Cheapest heights:** a dynamic programme (Viterbi) over evenly spaced nodes along the leg (at most 25 m apart) and
heights on a grid: per node and height, the cheapest way there from the start within the grade limit. The grid step
is the grade's rise between nodes split into whole steps of at most 0.5 m (0.3125 m at Fastest's 2.5%, 0.425 m at
8.5%), so the steepest climb is exactly a whole number of steps. A metre of track costs (in metres of plain track):

- on the ground (within 8 m above or 12 m below it): 1, plus 0.05 per metre of cut or fill. The game charges nothing
  for earthworks; the term keeps the track at the ground where leaving it saves nothing (else it could ride anywhere
  in the band for free), and makes big embankments and cuttings pay their way (8 m of fill is 1.4, still far below a
  bridge);
- a bridge (above that, over water, or over a crossing): `bridgeCostFactor` (5), and a tunnel `tunnelCostFactor` (8),
  each plus 0.002 per metre of height, so a deck keeps low, a tunnel shallow, and over water the deck near the line
  between the banks.

Each node tries only a band of heights: between the lowest the ground allows at the grade limit and the highest the
ground and the crossings' floors need (a cheapest track never leaves those envelopes: clipping it to them only
brings it nearer the ground), and within the pins' reach. The grid track is then interpolated to the samples, each
sample moved up to a grid step towards the ground (so a track that can follow the ground does so exactly), clamped to
the grade and the pins, and lifted back to the crossings' floors. When the pins are too far apart in height, the
search aims for the nearest height the start can reach and the end's pin is put back at the last sample (that grade
breaks the limit, and the leg is flagged). Runs shorter than 75 m are merged into their neighbours afterwards, which
the search doesn't know about.

This replaced a grade clamp run both ways and averaged, which lifted the track over flat ground on its way into a
ridge it tunnelled through anyway (NewGame2, Cornelius → Perth Amboy, Fastest: a 301 m bridge over flat ground before
a 766 m tunnel). On the regression routes Fastest estimates fell by up to 27% (5% over the set), and none rose.

**Work:** about a height × predecessor pair per unit, 32 units a microsecond on desktop Lua. A leg's fit is spread
over `route.step`s of 20,000 units (0.6 ms desktop, about 2.5 ms in-game); the regression legs took one or two, a
10 km leg over 80 m hills (about 250,000 units, 7 ms) 13.

### Stations (`stations.tl`)

For each town, search outward in rings from the centre for a spot where a straight run (the platform length plus 100 m
of approach at each end) is clear of blocked, water, road and track cells, checked every quarter cell and at both ends
of the run. Every station is a through station with 2 tracks, both ends connected.

The search is spread over `route.step` calls (`stations.startFind`/`stepFind`), about 500 µs of desktop work per step
at most: out to 1.5 km it passes some 3,000 spots of up to 5 runs each, and one big town's site took 41 ms in one
step in-game. A spot whose centre cell is taken is passed over, and a run's end cells are looked at before its cells
are walked, so a built-up town is cheap (4.4 ms → 0.5 ms for the slowest site on the Ames–Bridgeport capture).

**A way out.** A clear run is no use if no leg can reach it: buildings and their 30 m buffer can wall in an open
spot (Pottstown on PottstownTown: 18 cells with no way out), or one end of it. So each site's centre cell must
connect over unblocked cells (the search's moves) to a cell 2.5 km from the town's centre (a kilometre past the
farthest site) or to the grid's edge, remembered per town; and each end a leg uses (arriving at every station but
the first, leaving every one but the last) must too, starting as the leg's search would (from the end point itself,
within 90° of the platform's direction) and never back along the run. The floods are stepped with the site search.
A town with clear spots but none that connects fails **no_exit** ("There's no way out of the station site in X:
buildings surround it. Try another stop."), as does a leg whose search finds its start closed off inside the grid; a
wider area can't help either. A station's room to turn is also pulled back where the search couldn't leave its end
point (off its cell's centre, between two buildings' corners).

**Facing the line** (`route.tl`). The first sites face from the previous stop to the next. Then each leg is scouted:
a search between the two site centres, free to start and end in any direction and turning as freely as the Cheapest
radius allows (with the mode's costs). Each station's direction is then taken from the scouts: from the point D before
it on the arriving scout to the point D after it on the leaving one (from or to its centre at the line's ends), with
D = 600 m or the full radius's minimum straight if longer (1.19 km at 3 km: over a shorter stretch, a scout one cell
off the axis turns the station 10° or more). Its site is found again facing that way, at most one cell farther from
the town than the first; if there is none, or it leaves no room to the stations either side, or buildings cut its
room to turn (below) shorter than the first site's on a side a leg leaves from, the first site stays.
One round; a second moved stations again without settling. Scouts are searches like the legs', stepped through
`route.step`, and count towards the progress.

**Re-siting by the legs.** The scouts run between site centres free of the stations' directions, so a station can
still face a way its leg can only enter by hooking round (Owings Mills on New Game: the line came down past the station
and turned back up into it, with an 8 m curve). After each leg is fitted, if its heading swings more than 200° (the
widest spread of its arcs' signed turns; ordinary legs on the regression maps reach 192°) or it has a curve below the
build minimum, the station nearer the trouble (else the one it arrives at) is weighed again, once: its site against
sites facing 8 axes, within 300 m more of the town, by the costs of the fallback-radius searches for its two legs. A
site 2% cheaper replaces it, and the legs either side are built again. The searches price a hook's tight curves
(Grid search), so the comparison is fair, but a hook still happens where every site within reach faces badly.
Re-siting is still worth it: without it the regression set's estimates were 4% higher (Dover → Camarillo, Fastest
29%) and as many routes hooked. It runs less often than before (8 stations on the set against 11), and cheaper: the
current site's two legs are the legs' own searches, kept (the last 4 finished searches without a cost limit, by
their inputs), and a candidate's leg in is cut off once it costs more than the best less the straight distance of its
leg out.

**Room to turn beyond the approach** (the leg's search starts and ends there): enough for the search's first turn at
full radius. Where every move may turn (Cheapest) that may be anything up to 90°, so room for 45°
(R·tan 22.5°, 91 m at 220 m); where it spaces its turns, one 22.5° step (R·tan 11.25°, 597 m at 3 km). The longer
room (1.24 km at 3 km) cost Fastest dear once the stations faced the line: it pushed the legs' ends past their turns,
into a ridge (a 300 m tunnel) and loops (estimate 23.2–23.5 M against 19.6 M on the captured map).

### Candidate stops (`corridor.tl`)

A town between the two ends is a candidate if routing through its centre adds at most 15% to the direct length. The
window lists each candidate with its added detour.

The 15% budget is for the **whole line**, not each town: judged one by one, a wide corridor of towns all pass (10 of
them between Ames and Bridgeport, 9.6 km apart, on a big save), and the line through all of them zigzags across the
corridor (stations there came out facing apart, "too close"). So the towns ticked by default (`corridor.select`) are
chosen by **cheapest insertion**: start with the straight line from A to B, and repeatedly put in the candidate whose
best place in the line adds the least length, at that place, while the whole line stays within 115% of the direct
distance. The player can tick or untick any candidate.

The ticked towns are put in order the same way (`corridor.order`), with no limit: each inserted where it adds least,
the cheapest first. Ordering by where the towns project onto the line from A to B made a zigzag of towns on both
sides of it. For the default towns this gives the order `select` built.

## Window (`window.script.tl`)

States:

1. **Set up:** From/To dropdowns (towns sorted by name), Mode, Track, Electrified, Platform, the candidate stops as a
   list of check boxes with each town's own detour ("+3.1 km"), and **Find route**. The towns `corridor.select` picks
   are ticked by default; the player's ticks and unticks are kept as overrides of that default (until From or To
   changes) and remembered between openings like the other settings.
2. **Surveying… N%**, then **Planning… N%**. Changing any setting cancels the work.
3. **Result:**
   - length, the game's cost, bridges and tunnels (count and length), maximum grade, minimum radius, and each
     station's distance from its town centre;
   - **Show on map**;
   - **Build**, enabled only after a clean dry run; otherwise the game's error messages are listed.

The window is built like Jam Session's (`tool_react_util.registerToolWithWindow`, a `ToolButton` on
`::MainModButtonAreaExtension`), docked at the left edge by a mod stylesheet keyed on its class, and sized to its
content.

## Preview (`preview.tl`)

Static cargo-flow arrows (`FlowData`, speed 0) along the track as chords of about 100 m between height samples, each
coloured by the kind of span it covers (green ground, blue bridge, orange tunnel), plus one white arrow along each
station's platforms in the direction of travel. They're drawn through a map action (`useAction` +
`setActiveOwnerOverride`, as in Jam Session, with `accessNotificationCacheFn` left nil). When the preview is turned
on, the camera moves to the route once, showing as much of it as the maximum zoom-out allows.

## Building (`builder.tl`)

1. **Stations first:** one proposal per station (`::/stations/rail/modular_station/modular_station.con`, tracks = 2,
   the chosen length), each dry-run clean before it's sent.
2. **Then the track**, in chunks of about 2 km: two parallel edges `trackDistance` (5 m) apart, joined to each other
   and to the stations' end nodes. Each chunk is dry-run before it's sent, and its callback starts the next.
3. **On a failed dry run**, stop. The window shows what was built and what failed, and offers **Retry from here**.
   Nothing already built is rolled back.
4. Track type and electrification come from the settings. No signals, lines or vehicles.

Rules carried over from Bus Loops: never send a proposal that didn't dry-run clean; copy positions out of engine data;
don't keep engine components across a `sendCommand`.

**Probes before the builder is written:**

- how a track `SegmentAndEntity` carries its track type and the bridge/tunnel flag (the tealdef shows no `trackEdge`);
- the modular station's slots and modules for a 2-track passenger through station;
- where the station's track end nodes are, so the main line can join them.

## Testing

**Unit tests** (`just test`), on artificial maps:

- `grid`: a straight line on flat ground; going round a lake when that's cheaper than a bridge; a bridge when going
  round is too long; impassable buildings; Fastest choosing a straighter path than Cheapest on the same map.
- `smooth`: every arc is at least the minimum radius, and the end directions are kept.
- `profile`: grades stay under the limit (also on rough random ground and unevenly spaced samples); a valley becomes
  one bridge, a ridge one tunnel, a hill within the grade neither; a crossing a bridge with 7 m of clearance; flat
  ground before a ridge that's tunnelled isn't bridged; a fit spread over steps gives the same heights.
- `stations`: the chosen spot is clear (of buildings, water, roads and track) and as near the centre as possible;
  a clear spot walled in by buildings, or whose leaving end is a dead end, is refused for the next one out.
- `corridor`: the detour budget includes and excludes the right towns; the default stops fit the budget together and
  no town left out would; ticked towns are ordered by cheapest insertion, not projection.

**In-game:** on a flat test map (Map Editor → Create New Map) with a hill, a lake and a few towns, never the active
save until the end.

## Milestones

Each ends with one in-game test by the user.

1. **Survey, plan and preview:** the window, the route on the map, our own cost estimate.
2. **Probes:** track and station proposals, dry-run only; the game's real price in the window.
3. **Build:** stations, then track chunks, with Retry.
4. **Station styles and signals:** a "Station style" setting: Simple 2-track (the default) or **Halt 2+2**, the layout
   of the Express & Local Rail Stations mod (`express_local_stations_1`): platform, local, express, express, local,
   platform on the base modular station, with track fans at both ends that split the 2-track line onto the four
   station tracks, so expresses run through on the middle pair while stopping trains use the outer pair. We build the
   station and the fans ourselves (no dependency on that mod; its `el_fans.lua` and `el_signals.script.lua` are the
   reference for fan geometry and signal placement), plus one-way path signals so each track runs one way. Needs:
   turnouts and joining track (new after M3), longer and wider station sites (about 30 m wide, a few hundred metres
   of straight for the fans at each end), and signals, which version 1 leaves out. To probe then: whether that mod's
   game script also signals our fans when it's installed.
   **Use existing stations** (decided with the player, 2026-10-16): where a town on the route already has a rail
   station, the line uses it instead of placing a new one: the window offers "use the existing station in <town>"
   (ticked by default), and the legs run to that station's free track ends, joining them (the same joins as the
   fans). Needs: finding a town's rail stations and their free track ends and directions, deciding whether one is
   usable (a through station with an end free on the side the line comes from; a terminus only at the line's ends),
   and planning a leg to a fixed end instead of a site. First test case: Pottstown on the player's third save,
   "PottstownTown" (`maps/pottstowntown-16x16km.map`), whose existing station boxed in the new site the planner
   looked for.
5. **Tuning and polish:** thresholds and weights from real maps, translations, release.

## Known issues after milestone 1 (to settle with in-game data)

- **Curves near station ends can be tight.** The search spaces its turns for the radius, and the stations face the
  scouted line, so in open country and round lakes, hills and buildings the path leaves room for full-radius curves.
  On the second Fastest capture without Mercer Island (10 tight curves) two legs still fall back to the Cheapest
  search radius: Bangor → Antelope has to swing round the end of a ridge in an S that a 3 km radius can't make in the
  1.1 km between the stations' extension points, and Aloha's site is hemmed in by its town on the side the line
  arrives from (47 m of room to turn, at its first site and turned alike), so the line turns in the town. Looking up
  to 300 m further out for a site with full room (tried) fixed Aloha's leg (searched at 1500 m) but moved other
  stations for the worse (6 tight curves instead of 4 on the other Fastest capture, and one leg 13% dearer).
  What's left on the first captured Fastest map (R = 3000 m; 7 tight curves, the tightest 263 m; since then 4, the
  station-room rule keeping Aloha's roomy first site):
  - a stop the line doubles back through (Bangor → Mercer Island → Antelope turns about 135° at Mercer Island): no
    direction suits both legs, and both fall back to the Cheapest search radius (263 m and 572 m at its ends);
  - two stations too close for their offset (Mercer Island and Antelope both face north, 1.7 km apart sideways and
    1.9 km along): an S-bend at 687 m;
  - (gone with the room rule: Aloha's turned site, hemmed in on its leaving side, 429 m; and Antelope → Aloha round
    the lake at a 1500 m search radius, 1187 m and 2529 m. That leg now crosses the lake straight at 3000 m.)
  The smoothing guard still tightens curves where a path searched at a smaller radius turns close to an obstacle.
- **A curve at a cut-short station end can cross buildings.** Where buildings cut a station's room to turn short and
  the line turns sharply at its approach, the curve there may only be tightened to the build minimum and still clip
  the buildings (the guard gives up at the floor). Since corners are priced by their curves' room, one sample on the
  regression set (Bossier City → Ashland, Cheapest, at Ashland's arriving end; 17 before, on 5 routes).
- **Hooks where no site faces well.** Corners priced by their curves' room give a hook its true cost, but a hook is
  still the cheapest buildable line where every site within reach of a town faces badly: Alliance → Aloha, Cheapest,
  loops into Owings Mills (sweep 438°; the west-facing site the old search took can only be left towards Aloha by a
  curve below the build minimum), and Dover → Camarillo swings 230° (both modes). Better sites need the scouts to see
  the stations' directions (a scout through each stop, straight along its platforms), not a cheaper turn model.
- **Small changes move stations.** The scouts and the station turning are sensitive: Alliance → Aloha, Fastest, came
  out 29% dearer with the turn pricing (long bridges over the lake before Owings Mills): Turlock's turned site moved,
  and no leg hooked or curved below the build minimum any more to set off the re-siting that had turned Owings Mills
  west.

## Out of scope for version 1

Signals, Halt 2+2 stations and using existing stations (milestone 4); creating lines or buying trains; routes that join
other existing track; terminus stations; single track.
