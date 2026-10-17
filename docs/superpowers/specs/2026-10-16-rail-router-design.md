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
| Stops on the way | Candidate towns within a 15% detour budget are listed, pre-ticked; unticking re-plans.     |
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

- **Corridor:** the box around the chosen towns, plus a 25% margin (at least 2 km). If a leg's grid search finds no
  path, the window starts the work over (survey and plan) with the margin doubled, up to twice (0.25 → 0.5 → 1.0),
  showing "Widening the search… N%"; only then is "No route found" shown. The grid coarsens past 250,000 cells, so
  a wider margin costs resolution rather than memory.
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
- a turn penalty per change of direction.

The search state is (cell, arriving direction), so turn costs are exact and the result is optimal for the cost
model (checked against an exact reference on random grids). It arrives at each station's approach in the platform's
direction.

**Turns spaced for the radius.** A 22.5° turn rounded at radius R takes R·tan(11.25°) of straight on each side of its
corner, so consecutive turns need L = 2·R·tan(11.25°) (≈ 0.4 R) between them. Where L is no more than a cell (Cheapest,
R = 4 × the build minimum), any move may turn by up to 90°, as before. Otherwise the moves are long edges: from a state
(cell, direction) the search may go one step straight on, or turn by one 22.5° step and carry on straight for
ceil(L / step length) steps (every cell on the way checked and costed as single steps are), after which it may turn
again. The state space stays (cell, direction), so the search is still optimal for this model and the heuristic still
admissible. The start may turn at once (the station's extension gives room behind it); passing through the goal cell
part-way along a turn's straight finishes there only heading the platform's way, and a state at the goal may make one
last single-step turn onto it. The path's first and last segments run from and to the asked points, off their cells'
centres, so they are checked for blocked cells on their own (a diagonal past a blocked cell's corner would cut it).

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
tight curves. Cost on the captured Fastest map (4 legs, R = 3000 m): about twice the expansions of the free-turning
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
the plan's summary counts these, and the log shows it.

### Height profile (`profile.tl`)

Fits the track's height to the terrain under the grade limit, smoothing forwards and backwards. Where the track is
more than 8 m above the ground it becomes a bridge, and more than 12 m below a tunnel. These thresholds are starting
values, tuned in-game.

**Crossings:** samples over existing track, and over roads in Fastest mode (`Weights.bridgeRoads`), are bridges and
are never merged away. The track there is lifted to at least 7 m above the ground, ramping up and down within the
grade limit; the station heights pinned at a leg's ends win if a crossing is too close to them. In Cheapest mode
roads are crossed on the level.

The grade clamp runs both ways (start first, and end first) from the same target and the two results are averaged, so
a ridge or valley is cut symmetrically instead of leaning towards one end; the average keeps the grade limit, the pins
and the crossing floors.

### Stations (`stations.tl`)

For each town, search outward in rings from the centre for a spot where a straight run (the platform length plus 100 m
of approach at each end) is clear of blocked, water, road and track cells, checked every quarter cell and at both ends
of the run. Every station is a through station with 2 tracks, both ends connected.

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

**Room to turn beyond the approach** (the leg's search starts and ends there): enough for the search's first turn at
full radius. Where the search turns freely (Cheapest) that may be anything up to 90°, so room for 45°
(R·tan 22.5°, 91 m at 220 m); where it spaces its turns, one 22.5° step (R·tan 11.25°, 597 m at 3 km). The longer
room (1.24 km at 3 km) cost Fastest dear once the stations faced the line: it pushed the legs' ends past their turns,
into a ridge (a 300 m tunnel) and loops (estimate 23.2–23.5 M against 19.6 M on the captured map).

### Candidate stops (`corridor.tl`)

A town between the two ends is a candidate if routing through its centre adds at most 15% to the direct length. The
window lists each candidate with its added detour.

## Window (`window.script.tl`)

States:

1. **Set up:** From/To dropdowns (towns sorted by name), Mode, Track, Electrified, Platform, the candidate stops as a
   ticked list with the added detour for each ("+3.1 km"), and **Find route**.
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
- `profile`: grades stay under the limit; a valley becomes a bridge, a ridge a tunnel; a crossing a bridge with 7 m
  of clearance.
- `stations`: the chosen spot is clear (of buildings, water, roads and track) and as near the centre as possible.
- `corridor`: the detour budget includes and excludes the right towns.

**In-game:** on a flat test map (Map Editor → Create New Map) with a hill, a lake and a few towns, never the active
save until the end.

## Milestones

Each ends with one in-game test by the user.

1. **Survey, plan and preview:** the window, the route on the map, our own cost estimate.
2. **Probes:** track and station proposals, dry-run only; the game's real price in the window.
3. **Build:** stations, then track chunks, with Retry.
4. **Tuning and polish:** thresholds and weights from real maps, translations, release.

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
  the buildings (the guard gives up at the floor). None on the captures with the chosen settings, but neighbouring
  ones (D = 300, 900 or 1200 m, or two scouting rounds) gave 1 to 5 samples on blocked cells, all at such an end.

## Out of scope for version 1

Signals; creating lines or buying trains; routes that join existing track; terminus stations; single track.
