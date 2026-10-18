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
│   ├── speed.tl           a train's run between stops; time tight curves lose
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
| Travel time          | not priced                        | a second lost to tight curves = 50 m of track   |

Defaults: the best track type available in the current year (high-speed in Fastest mode once it's unlocked),
electrified once catenary is available, 160 m platforms.

### Speed model (`speed.tl`)

How long a train takes over a leg, and how much of that its curves below the mode's radius cost. Every station is a
stop, so the run starts and ends at a standstill at the station centres. The train accelerates at 0.5 m/s² and, once
its power runs short, at 12 W/kg ÷ v (an ICE 1: two 4,790 kW power cars with 200 kN of tractive effort each, about
800 t), and brakes at 1 m/s² (the ICE 1's data says 2.5; a starting value). A curve of radius R allows
sqrt(2 m/s² · R); the line is planned for what the mode's radius allows (`Weights.topSpeed`, at most the track's
speed: 77 m/s at 3 km). The run is worked out every 10 m, forward for acceleration and backward for braking.
`timeLost` is the run with the curves' limits less the run without them.

Such a train needs about 13 km to reach 77 m/s, so on legs of a few kilometres it never does: a 4.5 km leg peaks at
about 42 m/s, where curves of 900 m or more cost nothing, and a tight curve next to a station costs little (the train
is slow there anyway). Each leg reports `timeLost`, the plan's summary the sum, and the regression routes are held to
it. Fastest prices it at `Weights.timeCost` = 50 m of plain track a second (`FASTEST_TIME_COST`; on the regression
maps, before slow legs' stations were re-sited, 20 gave 704 s lost over the Fastest routes, 50 672 s, 100 663 s with a
quarter more search work, 200 614 s but estimates 7% up and nearly twice the work); Cheapest doesn't price it.

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

A leg is built over several steps (simplify; fillet, one fillet a step, up to four: see Smoothing's station ends;
heights, over one step or more), so no step does more than one of them.

**Memory.** The game's Lua is 5.2 (the executable says so), whose incremental collector pays a step's garbage
collection debt, work in proportion to what was allocated, at its next allocation, over the game's whole heap. A step
that allocates megabytes at once is a hitch in-game that the desktop, timing steps with the collector held off, never
shows: Alliance → Aloha's in-game capture (New Game, 2154) logged a 48.7 ms legs step where its slowest desktop step
was about 3 ms (min of three runs; in-game is usually 2–4 × the desktop). A search's states used to be kept in hash
tables of its own, and each doubled within a step as the search grew, two at a time (up to 1.5 MB in one step; 49.6 MB
over that plan). Now the grid has one store (`grid.Store`), made by its first search and reused by every later one:
in pages of 16 cells along a row (256 states), made where a search first goes, each state's cost and parent stamped
with the id of the search that set them (so nothing is cleared between searches), plus the heap and the reachability
fill's stamps and queue. Only the latest search may step or give its path (an older one errors); a finished search's
copy (`grid.finished`, the search cache) keeps its own. Plans are byte-identical. With the guard in plain numbers
too (Smoothing), that plan allocated 14.6 MB, at most about 300 KB in a step (a new row's pages); 26 MB since
re-siting weighs time (more of it). Its slowest step is 1.4 ms on the desktop (min of three runs), 2.0 ms in a Lua
5.2.2 built from source (3.0 ms before; 4.5 ms with a collector kept cycling over a 160 MB heap, 2.1 ms now). The regression
set holds every step to 768 KB (`STEP_ALLOC_KB`; the most is about 600 KB, re-siting building a candidate's leg).
`route.stepKind` names what each step does; the window logs the slowest step per kind and the most one allocated,
and the replay tool prints both.

**Search radii, weighed by time.** A Fastest leg is searched first with turns spaced for the Cheapest radius (the
fallback; if that finds nothing, the plan fails "no_path"), then for the mode's radius, halving while above the
Cheapest one (3000, 1500, 750, 375 m at 3 km). Each try's ends have the stations' rooms to turn sized for its own
radius (below). Every path found is built (simplified and filleted, a step each) and weighed: its search cost plus
`timeCost` × the seconds its fitted curves lose (Speed model); the least total is the leg. A try's search stops once
every path left costs more than the best total so far (no path loses less than nothing), which also ends early the
searches of a radius that doesn't fit (station ends misaligned or close together, a passage too narrow), which would
otherwise find a loop or a wide detour, or nothing after a long search. Without `timeCost` (and so in tests with older
weights), the first try within 10% of the fallback's cost is taken. The radius used is recorded per leg
(`searchRadius`, in the log and the replay tool); smoothing still aims for the full radius, so a leg searched with a
smaller one may have tight curves.

The rooms used to be sized for the mode's radius at every try (597 m beyond the approach at 3 km): on legs of 1–5 km
the ends then sat so close together, or so far into the next obstacle, that no wider radius found a way. On New
Game's Alliance → Aloha every leg fell back, and a 375 m try failed where a plan with a 375 m target planned its
legs 1 and 4 at 375. The fallback's own rooms sized for it (91 m) also made Fastest's lines cheaper and faster (time
lost 672 s against 826 s over the Fastest routes, estimates 307 M against 331 M); re-siting's searches size theirs
the same way.

Weighing the tries by an estimate from the grid path (each corner rounded as widely as the straights either side
allow) changed little: the estimate missed the curves the smoothing guard tightens, and the 10% rule did as well.
Weighing the fitted legs is what made the time count. Tried and dropped: letting a spaced search turn freely at its
ends, or within 300–800 m of them (where a station's end faces buildings, one 22.5° step either side of its axis is no
way out): at best 2% less time lost over the set, but up to 3 samples on blocked cells and up to 75% more search
work. Pricing the
time inside the free-turning search was not tried: its corners only know the half moves either side of them, so
every corner of a gentle curve would be priced as a sharp one. Cost on the captured Fastest map (4 legs, R = 3000 m): about twice the expansions of the one-step
search (7,400 against 3,900; about 45 ms against 28 ms offline), Cheapest unchanged. Weighing every radius and
re-siting slow legs' stations (below) about doubled Fastest's planning work on the regression maps (4.5 s to 9.6 s
desktop over its 15 routes). The slowest single step was about 7 ms (fitting a leg's curves, every fillet in one
step); with a fillet a step and the guard allocation-free it is about 2 ms (min of three runs; a long leg's fillet on
Dover → Camarillo, or a re-siting step), Lua 5.2 on the desktop about 1.5 × that. Known cost (plain Lua, desktop): a 500 × 500 grid with 15% clutter took about 1.6 s and 35 MB in Cheapest
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
is taken. Each fillet (the first, the refits) has a step of its own (`route.Fitting`): all in one step took 4.7 ms on
the desktop on a long leg.

**Cost.** The guard is asked thousands of times per leg, so it, the simplifier's straights and the blocked-sample
count work in plain numbers, with no point made per check (`smooth.pointAtXY`, a reused probe point): a fit step
allocated up to 856 KB before, 275 KB at most now. Fillet doesn't check an arc again that is the same as when it was
last found clear (only its neighbours were tightened since), which took the slowest fillet from 2.2 ms to 1.6 ms.

### Height profile (`profile.tl`)

Fits the track's height to the terrain under the grade limit, as cheaply as it can. Where the track is more than 8 m
above the ground it becomes a bridge, and more than 12 m below a tunnel. These thresholds are starting values, tuned
in-game.

**Crossings:** samples over existing track, road junctions (nodes joining three or more pieces, and 30 m round them:
a level crossing can't go through one; the grid search prices crossing one as crossing track), and over roads in
Fastest mode (`Weights.bridgeRoads`), are bridges and
are never merged away. The track there is lifted to at least 9 m above the ground, ramping up and down within the
grade limit (probe P8: a double-track bridge square across existing track collided with it 7 m above, rail to rail,
and was clean from 8 m; over a street 6 m was clean); the station heights pinned at a leg's ends win if a crossing is too close to them. In Cheapest mode
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
site 2% cheaper replaces it, and the legs either side are built again (in Fastest the legs are weighed by cost and
time: below). The searches price a hook's tight curves
(Grid search), so the comparison is fair, but a hook still happens where every site within reach faces badly.
Re-siting is still worth it: without it the regression set's estimates were 4% higher (Dover → Camarillo, Fastest
29%) and as many routes hooked. In Fastest, a leg whose curves lose more than 10 s (`RESITE_TIME_LOST`; Speed model)
has the station nearer its tightest curve weighed again too: mostly one whose end faces buildings, so the line hooks
round into it. Owings Mills on New Game was such a station; re-sited on the bay's east shore, facing west, Alliance →
Aloha lost 41 s to its curves instead of 58 s and cost 14% less. Over the Fastest routes 10 s took the time lost from
672 s to 423 s and the estimates 7% down (20 s: 541 s, 3%), for about twice the work. It runs less often than before (8 stations on the set against 11), and cheaper: the
current site's two legs are the legs' own searches, kept (the last 4 finished searches without a cost limit, by
their inputs), and a candidate's leg in is cut off once it costs more than the best less the straight distance of its
leg out.

**Re-siting weighs time in Fastest.** By cost alone, re-siting moved stations for legs that cost a little less and
lost far more time: on Alliance → Aloha on New Game in 2154 (an in-game capture) Turlock was moved for a leg out 5%
cheaper that lost 56 s to its curves. With time priced, a candidate's legs are now weighed the way the legs
themselves are built: every search radius tried (each try's rooms sized for it, its search cut off at the best so
far), each path found built (simplified, filleted) and weighed by its search cost plus `timeCost` × the seconds its
curves lose, the least total taken. The current site's legs that are already built are weighed as built (the leg just
built, and where the station is the one that leg leaves from, the leg before it, by its `searchCost` and
`timeLost`), and a candidate must also lose no more time over its two legs than the current site. Variants measured
on the regression set (Fastest, 423 s lost before):

- the candidates' legs at the fallback radius alone, by cost plus time: candidates beat current sites whose legs had
  taken a wider radius once built (Bangor → Imperial Beach via Antelope, Aloha: 0 s became 15 s);
- every radius tried, the current site's built legs as built, by cost plus time: 423 s, estimates 1.5% up
  (Alliance → Aloha 41 s to 21 s, but Adelanto → Deltona 13 s to 28 s and 22% dearer: its new site's leg out took
  the 3 km radius, few turns and so a low search cost, but lost 19 s at the station ends);
- the same, and no more time lost (chosen): 398 s (−6%), estimates 1.3% up, tight curves 230 to 235. Alliance →
  Aloha 41 s to 21 s (Hemet faces west), Elkhart → Fernley 55 s to 43 s, Dover → Camarillo 130 s to 128 s; worse:
  Englewood → Weston 7 s to 13 s (35% dearer: cost alone moved Sulphur for a leg out that lost 28 s, then re-siting
  Weston mended that leg; weighing a station's two legs can't see that), Bangor → Imperial Beach via 0 s to 4 s.
  Cheapest is unchanged (byte-identical plans).

The capture itself is unchanged, 91 s lost, 56 s on Turlock → Owings Mills: the leg threads a bay studded with
buildings and hooks round into Owings Mills. Of Owings Mills' sites within reach, the one west-facing site whose leg in
is fast (6 s) can't be left towards Aloha (its leaving end is walled in: the leg out's search dies after 2
expansions, though the site's way-out check passed), and the others lose 62–67 s; Turlock's sites all lose 48 s or
more on that leg. Forcing each candidate site in turn, the best whole line lost 82 s.

**Room to turn beyond the approach** (the leg's search starts and ends there): enough for the search's first turn at
its radius (each of a Fastest leg's tries has its own; the stations' turning checks size it for the mode's). Where every move may turn (Cheapest) that may be anything up to 90°, so room for 45°
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
   - **Check with the game** (milestone 2): dry-runs the stations and the track, one proposal per frame, and shows
     the game's price (track and stations), the level crossings, and each problem with what it ran into and a
     **Show** button that moves the camera there;
   - **Build** (milestone 3), enabled only after a clean check.

The window is built like Jam Session's (`tool_react_util.registerToolWithWindow`, a `ToolButton` on
`::MainModButtonAreaExtension`), docked at the left edge by a mod stylesheet keyed on its class, and sized to its
content.

## Preview (`preview.tl`)

Static cargo-flow arrows (`FlowData`, speed 0) along the track as chords of about 100 m between height samples, each
coloured by the kind of span it covers (green ground, blue bridge, orange tunnel), plus one white arrow along each
station's platforms in the direction of travel. They're drawn through a map action (`useAction` +
`setActiveOwnerOverride`, as in Jam Session, with `accessNotificationCacheFn` left nil). When the preview is turned
on, the camera moves to the route once, showing as much of it as the maximum zoom-out allows.

## Network (`network.tl`)

The track a plan builds, as the game's edges (pure). Each leg becomes two tracks 2.5 m either side of its centre
line, as cubic Hermite edges between nodes:

- **Tangents:** an arc's tangent length is 4R·tan(θ/4) ("circle"; "arc", Rθ, is the alternative). The game's own
  curves (probe P1) were within 1.3% of both on 17° edges, so either is fine at the planner's angles.
- **Edges** end at every span boundary (ground, bridge, tunnel), are at most 250 m along the centre line, and are
  split further wherever the cubic strays more than 0.25 m from the height profile or steeper than the grade; each
  node's grade comes from the profile around it. None is shorter than 0.5 m.
- **Chunks** of about 1 km of centre line (both tracks) are one dry run each, never splitting a bridge or tunnel.
  Probe P2: a 1 km double-track piece took 12 ms to dry-run, 2 km about 49 ms.

## Station layout (`stationlayout.tl`)

The base modular station (`::/stations/rail/modular_station/modular_station.con`) as module slots (pure): two tracks
(`8400000 + 1000 i + 10 j`) between two platforms (`7400000 + 1000 i + 10 j`), 40 m modules along the platform length,
the era's platform and track modules (era B from 1950, C from 1990), optionally the main building, stairs and roofs.
The construction is placed at the site's centre turned to its direction; its track ends are at the platform ends.
Probe P6: every module resolves, a 160 m station dry-runs clean (4.43 million in 2020 with the building), and its
bounding box is 180 m long, 10 m past each platform end, inside the 100 m approaches the planner keeps clear.

## Building (`builder.tl`)

**Milestone 2 (done): Check with the game.** One proposal per station, then one per network chunk, each dry-run on
its own (`makeProposalData` with a `SimpleProposal`), one per frame from a join. Track edges are `SegmentAndEntity`
with the track template, its lane configs and style, `type` NORMAL (typeIndex -1, as the game's own plain track,
probe P1), BRIDGE or TUNNEL (typeIndex: the type `modes.structureFor` picks, as the track tool would); new entities
are numbered edges −1…−E, then nodes. A proposal isn't made where a template, module or structure type is missing.

What the probes found:
- **Limits** (P2): the game allowed a 12% grade and refused 14%; allowed a 45 m radius and refused 38 m. The planner's
  own limits are well inside both.
- **Bridges and tunnels** (P3): 300 m of each, double track, dry-ran clean.
- **Crossings** (P4, P8): track on the ground across a street collides with it (a level crossing has to split the
  street: milestone 3), so in Cheapest a chunk whose only collisions are streets counts its level crossings instead
  of an error (pieces of street sharing a node are one crossing). A bridge needs 8 m over track, 6 m over a street.
- **Price** (P5): a built 200 m straight was charged exactly the dry run's price (99,408). Plain track costs its
  listed price per metre; electrified 1.3× that, though its template lists the same. So when a plan is done a 100 m
  straight is dry-run at its first station, plain and electrified, and our estimate is scaled by that price. The
  estimate leaves out the platforms' track (the stations' price has it): on Bangor → Imperial Beach it then came
  within about 1.5% of the game's track price.
- **Timing:** Bangor → Imperial Beach (15 km, 5 stations, 16 chunks): 0.4 s of dry runs over 21 frames; stations
  30 ms each but the first about 100 ms, chunks 3–40 ms.

**Milestone 3: Build** (`build.tl`). After a clean check, **Build** builds the line one command at a time, each
waiting for the game's callback before the next:

1. **Stations first**, each dry-run again just before it's sent (the map may have changed since the check). Once
   built, its free track ends (the nodes of its frozen edges with one track piece; probe P10: they aren't among its
   frozen nodes) are matched to the network's nodes within 1 m: they're exactly where `stationlayout` puts them.
2. **Then the track, chunk by chunk** from the first station. A chunk joins the node entities already there (a
   station's ends, the previous chunk's far ends: `Pt3.entity`); new track can't start with a node of its own on an
   existing one (P11: "Construction Not Possible"), and its tangents must follow the track it joins. After a chunk is
   built, its new nodes' entities are recorded by place, for the next chunk.
3. **Level crossings** (P9): where a chunk's dry run collides only with streets, each crossed street is split at the
   points where the track crosses it (the engine's `replaceSegment` proposal edited into pieces, as Bus Loops splits
   a street; it can't be dry-run), then each piece at the new nodes is sent again unedited (`replaceSegment`) so the
   engine works out its lane connections, then the chunk, cut at the crossings and joined to the new nodes, is
   dry-run and sent. A crossing within 3 m of an existing street node uses that node. A bus route over P9's crossing
   worked.
4. **On a failure** (a dry run that isn't clean, a refused command), stop. The window shows what failed and where
   (**Show**), and offers **Retry from here**. Nothing already built is rolled back; a street split before a chunk
   that then fails keeps its extra nodes, which is harmless.
5. Track type and electrification come from the settings. No signals, lines or vehicles.

Rules carried over from Bus Loops: never send a proposal that didn't dry-run clean (the street split is the one
exception, a shape the engine made); copy positions out of engine data; don't keep engine components across a
`sendCommand`.

## Testing

**Unit tests** (`just test`), on artificial maps:

- `grid`: a straight line on flat ground; going round a lake when that's cheaper than a bridge; a bridge when going
  round is too long; impassable buildings; Fastest choosing a straighter path than Cheapest on the same map.
- `smooth`: every arc is at least the minimum radius, and the end directions are kept.
- `speed`: a short run's time matches the formula; a long run cruises; a limit costs time mid-leg, less near a stop,
  nothing above the speed reached, and two close limits slow the train once.
- `route`: with time priced, a wider radius whose curves lose less time is taken through a chicane when time is worth a
  lot, and the cheapest when it isn't; progress never goes back while radii are weighed and stations re-sited.
- `grid`: a grid's searches share its store, one at a time, and find what they would alone; an older search can't
  be stepped or give its path once a newer one has started.
- `profile`: grades stay under the limit (also on rough random ground and unevenly spaced samples); a valley becomes
  one bridge, a ridge one tunnel, a hill within the grade neither; a crossing a bridge with 9 m of clearance; flat
  ground before a ridge that's tunnelled isn't bridged; a fit spread over steps gives the same heights.
- `stations`: the chosen spot is clear (of buildings, water, roads and track) and as near the centre as possible;
  a clear spot walled in by buildings, or whose leaving end is a dead end, is refused for the next one out.
- `network`, `stationlayout`, `builder`: edges split at spans, within the longest edge, following the heights and
  grade; chunks never split a bridge; station slots and placement; level crossings counted from a dry run's
  collisions.
- `corridor`: the detour budget includes and excludes the right towns; the default stops fit the budget together and
  no town left out would; ticked towns are ordered by cheapest insertion, not projection.

**In-game:** on a flat test map (Map Editor → Create New Map) with a hill, a lake and a few towns, never the active
save until the end.

## Milestones

Each ends with one in-game test by the user.

1. **Survey, plan and preview:** the window, the route on the map, our own cost estimate.
2. **Probes:** track and station proposals, dry-run only; the game's real price in the window. Done 2026-10-17:
   Bangor → Imperial Beach checks clean.
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

- **Tight curves are counted against the mode's radius, not the speed reached.** On the regression maps Fastest's legs
  are 1–5 km between stops, where a high-speed train never gets near 77 m/s, so most of the 230 curves below 3 km
  (Fastest routes) cost no time; the planner weighs time lost (Speed model), and the regression set holds it per route.
  The figures below (tight curves on the captures) are from before that.
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
  west. (Re-siting slow legs' stations turned it west again: leg 3 now runs north over land.)
- **The regression set's samples on blocked cells:** 2 now (Bossier City → Ashland, Cheapest; Gardner → Herndon,
  Fastest), each a straight or a curve held at the build minimum grazing a building buffer's corner between the
  guard's checks. (Dover → Camarillo, Fastest, lost its one when re-siting weighed time.)
- **Re-siting sees one station's two legs.** It can't foresee that re-siting the next station mends a leg out
  (Englewood → Weston, Fastest: see Re-siting weighs time), and the station's way-out check is weaker than a leg's
  search (Owings Mills' west-facing site on the 2154 capture passes it, but no leg can leave it). Re-siting is also
  most of Fastest's planning work: on the 2154 capture 191,000 of its expansions (132,000 before it weighed time; one
  candidate's leg in ran 68,000 before giving up). In-game that plan took 3.4 s over 798 frames.
- **Bridges cap high-speed lines at 280 km/h.** The builder takes the bridge type the game's track tool would
  (`modes.structureFor`): the slowest auto-selectable rail type at least as fast as the track, else the fastest. The
  only base type faster than concrete (280 km/h) is the tied arch (350), which isn't auto-selectable, so a 350 km/h
  line gets concrete bridges. The base tunnels set no speed limit at all; the tool's rule then takes the first in the
  menu (rock, `tunnel_a`), whatever the year.

- **The first station's dry run takes about 100 ms** (the others about 30 ms), a hitch in that frame.
- **Bridges and tunnels are priced at 5× and 8× plain track** in the planner (search and height fit), where the game
  charged about 1.8× and 3× (P3, 300 m on flat ground). The estimate's scale comes from plain track only; tuning
  these factors (milestone 5) would move the plans.

## Out of scope for version 1

Signals, Halt 2+2 stations and using existing stations (milestone 4); creating lines or buying trains; routes that join
other existing track; terminus stations; single track.
