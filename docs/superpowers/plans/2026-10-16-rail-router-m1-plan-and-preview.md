# Rail Router Milestone 1 (Survey, Plan, Preview) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A window opened from the mod button that takes two towns, a mode and track settings, lists candidate stops
on the way, plans a double-track route (station sites, grid search, curves, heights), shows its length, bridges,
tunnels, grades and our own cost estimate, and draws it on the map.

**Architecture:** Pure planner modules under `content/gui/pgrace_rail_router/planner/` (no `api.*`, unit-tested in plain
Lua): `geo`, `modes`, `corridor`, `grid`, `stations`, `smooth`, `profile`, `route`. Two engine-side modules:
`survey.tl` (terrain, buildings and edges into a grid, spread over frames) and `preview.tl` (map arrows). The window
(`window.script.tl`) drives both from `react.enqueueJoin` steps with a 6 ms budget per frame, as Jam Session does.

**Tech Stack:** Teal 0.24.8 (type-checked against the game's tealdefs with `just check`), plain-Lua tests
(`just test`), TF3 react GUI.

**Spec:** `docs/superpowers/specs/2026-10-16-rail-router-design.md`. Building (milestones 2 and 3) is **not** in this
plan: it needs probe results first.

**Read before starting:** `../AGENTS.md` (Teal gotchas, the mod-button window, drawing on the map), and
`../tf3_jam_session/mod/pgrace_jam_session/content/gui/pgrace_jam_session/window.script.tl`, which this plan copies
its window, join and map-action patterns from.

**Conventions:**
- Tabs for indentation in `.tl` and `.lua` files, as the rest of the repo.
- Loop variables are `__`, never `_` (it hides `_()` in scripts).
- Every `.tl` module has its type definition in `mod/pgrace_rail_router/tealdef/gui/pgrace_rail_router/...d.tl` and a
  `require` line in `tealdef/pgrace_rail_router_def.d.tl`. `tools/build.py` copies the `.d.tl` files into `content/`;
  never edit those copies.
- `M` below means `mod/pgrace_rail_router`, `C` means `M/content/gui/pgrace_rail_router` and `D` means
  `M/tealdef/gui/pgrace_rail_router`.
- Commit after each task with a conventional prefix and the trailer
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

---

## File map

| File | Responsibility |
|------|----------------|
| `tools/test.lua` | Test runner: adds a `ug_require` shim and `t.near`/`t.ok` |
| `C/planner/geo.tl` | 2D vector helpers |
| `C/planner/modes.tl` | Track type availability, default track, per-mode weights |
| `C/planner/corridor.tl` | Candidate stops within a detour budget; stop order |
| `C/planner/grid.tl` | The survey grid and a resumable 16-direction cheapest-path search |
| `C/planner/stations.tl` | Nearest clear, flat, straight station site to a town centre |
| `C/planner/smooth.tl` | Path simplification, curve fitting (min radius), sampling |
| `C/planner/profile.tl` | Track heights under a grade limit; bridge/tunnel spans |
| `C/planner/route.tl` | Orchestrates the planner into a Plan, step by step |
| `C/survey.tl` | Engine reads: towns, track types, year, and the grid (over frames) |
| `C/preview.tl` | The map action that draws a Plan as arrows |
| `C/window.script.tl` | Mod button, window, settings, progress, results |
| `C/window.res.lua` | Registers the button on `::MainModButtonAreaExtension` |
| `C/window.css.lua` | Window position |
| `tests/*_test.lua` | One test file per pure module |

Removed: the template's `industry_plugin.res.lua`, `pgrace_rail_router.script.tl`, `util.tl`, `util.d.tl` and
`tests/util_test.lua`.

---

### Task 1: Clear out the template and extend the test runner

**Files:**
- Delete: `C/industry_plugin.res.lua`, `C/pgrace_rail_router.script.tl`, `C/util.tl`, `C/util.d.tl`,
  `D/util.d.tl`, `tests/util_test.lua`
- Modify: `M/tealdef/pgrace_rail_router_def.d.tl`, `tools/test.lua`

- [ ] **Step 1: Delete the template's hello-world files**

```bash
cd /home/pgrace/repos/tf3_mods/tf3_rail_router
git rm -q mod/pgrace_rail_router/content/gui/pgrace_rail_router/industry_plugin.res.lua \
  mod/pgrace_rail_router/content/gui/pgrace_rail_router/pgrace_rail_router.script.tl \
  mod/pgrace_rail_router/content/gui/pgrace_rail_router/util.tl \
  mod/pgrace_rail_router/content/gui/pgrace_rail_router/util.d.tl \
  mod/pgrace_rail_router/tealdef/gui/pgrace_rail_router/util.d.tl \
  tests/util_test.lua
```

- [ ] **Step 2: Empty the type registry**

Write `M/tealdef/pgrace_rail_router_def.d.tl` as a single comment line (later tasks add `require` lines):

```teal
-- Registry of the mod's type definitions: one require per .d.tl under tealdef/gui/.
```

- [ ] **Step 3: Add the `ug_require` shim and two assertions to the test runner**

In `tools/test.lua`, after the `function t.eq(...) ... end` block, add:

```lua
function t.near(actual, expected, tolerance, label)
	if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
		error(("%s: expected %s ± %s, got %s"):format(label or "near", tostring(expected), tostring(tolerance),
			tostring(actual)), 2)
	end
end

function t.ok(value, label)
	if not value then
		error((label or "ok") .. ": expected a true value, got " .. tostring(value), 2)
	end
end

-- Pure modules load each other with ug_require "<modId>::/<path>", as in the game. Map that onto requireTl, once
-- per file, so tests can load modules that depend on others.
local loaded = {}
function ug_require(path)
	local prefix = modId .. "::/"
	assert(path:sub(1, #prefix) == prefix, "the test runner only loads this mod's files: " .. path)
	local rel = path:sub(#prefix + 1)
	if loaded[rel] == nil then
		loaded[rel] = t.requireTl(rel)
	end
	return loaded[rel]
end
```

- [ ] **Step 4: Run check and test**

Run: `just check && just test`
Expected: `0 error(s)` from check. `just test` exits non-zero with `0 passed, 0 failed` (the runner fails when
nothing passed); that's expected until Task 2 adds tests.

- [ ] **Step 5: Commit**

```bash
git add -A tools/test.lua mod tests
git commit -m "chore: remove template example, add ug_require shim to tests

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `geo` (2D vectors)

**Files:**
- Create: `D/planner/geo.d.tl`, `C/planner/geo.tl`, `tests/geo_test.lua`
- Modify: `M/tealdef/pgrace_rail_router_def.d.tl`

- [ ] **Step 1: Type definition**

`D/planner/geo.d.tl`:

```teal
-- 2D vector helpers on plain {x, y} tables, in metres. Pure (no api.*).
global record PgraceRailRouterGeo
	record Pt
		x : number
		y : number
	end

	pt : function(x : number, y : number) : Pt
	add : function(a : Pt, b : Pt) : Pt
	sub : function(a : Pt, b : Pt) : Pt
	scale : function(a : Pt, k : number) : Pt
	len : function(a : Pt) : number
	dist : function(a : Pt, b : Pt) : number
	-- The unit vector along a; (0, 0) stays (0, 0).
	norm : function(a : Pt) : Pt
	dot : function(a : Pt, b : Pt) : number
	-- z of the 3D cross product: positive when b points to the left of a.
	cross : function(a : Pt, b : Pt) : number
	-- a turned counter-clockwise by `radians`.
	rotate : function(a : Pt, radians : number) : Pt
	-- The unsigned angle between two directions, 0 to pi.
	turnAngle : function(a : Pt, b : Pt) : number
end
```

Append to `M/tealdef/pgrace_rail_router_def.d.tl`:

```teal
require "gui.pgrace_rail_router.planner.geo"
```

- [ ] **Step 2: Write the failing test**

`tests/geo_test.lua`:

```lua
local t = ...
local geo = t.requireTl("gui/pgrace_rail_router/planner/geo.tl")

t.test("geo: add, sub, scale, dist", function()
	local p = geo.add(geo.pt(1, 2), geo.scale(geo.pt(3, 4), 2))
	t.eq(p.x, 7, "x")
	t.eq(p.y, 10, "y")
	t.near(geo.dist(geo.pt(0, 0), geo.pt(3, 4)), 5, 1e-9, "dist")
	t.eq(geo.sub(geo.pt(5, 5), geo.pt(2, 1)).x, 3, "sub")
end)

t.test("geo: norm keeps a zero vector at zero", function()
	local z = geo.norm(geo.pt(0, 0))
	t.eq(z.x, 0, "x")
	t.eq(z.y, 0, "y")
	t.near(geo.len(geo.norm(geo.pt(3, 4))), 1, 1e-9, "unit")
end)

t.test("geo: cross is positive for a left turn", function()
	t.ok(geo.cross(geo.pt(1, 0), geo.pt(0, 1)) > 0, "left")
	t.ok(geo.cross(geo.pt(1, 0), geo.pt(0, -1)) < 0, "right")
end)

t.test("geo: rotate and turnAngle", function()
	local r = geo.rotate(geo.pt(1, 0), math.pi / 2)
	t.near(r.x, 0, 1e-9, "x")
	t.near(r.y, 1, 1e-9, "y")
	t.near(geo.turnAngle(geo.pt(1, 0), geo.pt(0, 5)), math.pi / 2, 1e-9, "right angle")
	t.near(geo.turnAngle(geo.pt(2, 0), geo.pt(1, 0)), 0, 1e-9, "same direction")
	t.near(geo.turnAngle(geo.pt(1, 0), geo.pt(-1, 0)), math.pi, 1e-9, "reverse")
end)
```

- [ ] **Step 3: Run it to see it fail**

Run: `just test`
Expected: FAIL: `failed to compile` or `cannot open` for `geo.tl` (the module doesn't exist yet).

- [ ] **Step 4: Implement**

`C/planner/geo.tl`:

```teal
local geo : PgraceRailRouterGeo = {}

local type Pt = PgraceRailRouterGeo.Pt

function geo.pt(x : number, y : number) : Pt
	return { x = x, y = y }
end

function geo.add(a : Pt, b : Pt) : Pt
	return { x = a.x + b.x, y = a.y + b.y }
end

function geo.sub(a : Pt, b : Pt) : Pt
	return { x = a.x - b.x, y = a.y - b.y }
end

function geo.scale(a : Pt, k : number) : Pt
	return { x = a.x * k, y = a.y * k }
end

function geo.len(a : Pt) : number
	return math.sqrt(a.x * a.x + a.y * a.y)
end

function geo.dist(a : Pt, b : Pt) : number
	return geo.len(geo.sub(a, b))
end

function geo.norm(a : Pt) : Pt
	local l = geo.len(a)
	if l < 1e-9 then
		return { x = 0, y = 0 }
	end
	return { x = a.x / l, y = a.y / l }
end

function geo.dot(a : Pt, b : Pt) : number
	return a.x * b.x + a.y * b.y
end

function geo.cross(a : Pt, b : Pt) : number
	return a.x * b.y - a.y * b.x
end

function geo.rotate(a : Pt, radians : number) : Pt
	local c, s = math.cos(radians), math.sin(radians)
	return { x = a.x * c - a.y * s, y = a.x * s + a.y * c }
end

function geo.turnAngle(a : Pt, b : Pt) : number
	local c = geo.dot(geo.norm(a), geo.norm(b))
	if c > 1 then
		c = 1
	elseif c < -1 then
		c = -1
	end
	return math.acos(c)
end

return geo
```

- [ ] **Step 5: Run check and test**

Run: `just check && just test`
Expected: `0 error(s)`, then `4 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add -A mod tests
git commit -m "feat: geo vector helpers

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `modes` (track types and mode weights)

**Files:**
- Create: `D/planner/modes.d.tl`, `C/planner/modes.tl`, `tests/modes_test.lua`
- Modify: `M/tealdef/pgrace_rail_router_def.d.tl`

- [ ] **Step 1: Type definition**

`D/planner/modes.d.tl`:

```teal
-- The two planning modes, and the track types' limits. Pure (no api.*).
global record PgraceRailRouterModes
	enum Mode
		"cheapest"
		"fastest"
	end

	-- A base track type (not its catenary variant), read from the game by survey.trackTypes.
	record TrackType
		-- Resource name, e.g. "standard.lua".
		name : string
		-- Display name.
		label : string
		-- Cost per metre of one track.
		cost : number
		-- Top speed, metres per second.
		speed : number
		maxSlopeBuild : number
		minCurveRadiusBuild : number
		-- Distance between parallel tracks, metres.
		trackDistance : number
		-- 0 means no limit.
		yearFrom : integer
		yearTo : integer
	end

	-- What the planner works with. Extra costs are in metres of plain track.
	record Weights
		maxGrade : number
		minRadius : number
		-- Over the grade limit, each step costs 1 + slopePenalty × (grade − maxGrade) / maxGrade times as much.
		slopePenalty : number
		-- Steps over water cost this many times as much (they need a bridge).
		bridgeFactor : number
		-- Extra cost per turn: turnPenalty × (22.5° steps)².
		turnPenalty : number
		roadCrossing : number
		trackCrossing : number
		-- Money per metre of double track.
		costPerMetre : number
		-- Cost estimate: a metre of bridge or tunnel costs this many times a metre on the ground.
		bridgeCostFactor : number
		tunnelCostFactor : number
		-- Track more than this far above the ground is a bridge, more than tunnelBelow below it a tunnel (metres).
		bridgeAbove : number
		tunnelBelow : number
	end

	isAvailable : function(t : TrackType, year : integer) : boolean
	-- Fastest: the fastest available type. Cheapest: the fastest available type up to 60 m/s (so not high-speed),
	-- else the cheapest available. nil if none is available.
	defaultTrack : function(types : {TrackType}, year : integer, mode : Mode) : TrackType
	weights : function(mode : Mode, t : TrackType) : Weights
end
```

Append to the registry:

```teal
require "gui.pgrace_rail_router.planner.modes"
```

- [ ] **Step 2: Write the failing test**

`tests/modes_test.lua`:

```lua
local t = ...
local modes = t.requireTl("gui/pgrace_rail_router/planner/modes.tl")

-- The base game's three track types (base/content/infrastructure/track.zip).
local function track(name, cost, speed, yearFrom)
	return { name = name, label = name, cost = cost, speed = speed, maxSlopeBuild = 0.085, minCurveRadiusBuild = 55,
		trackDistance = 5, yearFrom = yearFrom, yearTo = 0 }
end
local TYPES = {
	track("simple.lua", 60, 27.8, 0),
	track("standard.lua", 180, 44.4, 1930),
	track("high_speed.lua", 540, 97.2, 1980),
}

t.test("modes: availability respects yearFrom and yearTo", function()
	local old = { name = "old", cost = 1, speed = 1, yearFrom = 0, yearTo = 1950 }
	t.ok(modes.isAvailable(old, 1949), "before yearTo")
	t.ok(not modes.isAvailable(old, 1950), "from yearTo on")
	t.ok(not modes.isAvailable(TYPES[2], 1929), "before yearFrom")
	t.ok(modes.isAvailable(TYPES[2], 1930), "from yearFrom on")
end)

t.test("modes: default track by year and mode", function()
	t.eq(modes.defaultTrack(TYPES, 1900, "cheapest").name, "simple.lua", "1900 cheapest")
	t.eq(modes.defaultTrack(TYPES, 1900, "fastest").name, "simple.lua", "1900 fastest")
	t.eq(modes.defaultTrack(TYPES, 1950, "cheapest").name, "standard.lua", "1950 cheapest")
	t.eq(modes.defaultTrack(TYPES, 1990, "cheapest").name, "standard.lua", "1990 cheapest skips high-speed")
	t.eq(modes.defaultTrack(TYPES, 1990, "fastest").name, "high_speed.lua", "1990 fastest")
	t.eq(modes.defaultTrack({}, 1990, "fastest"), nil, "no types")
end)

t.test("modes: cheapest uses the type's limits", function()
	local w = modes.weights("cheapest", TYPES[2])
	t.near(w.maxGrade, 0.085, 1e-9, "grade")
	t.near(w.minRadius, 220, 1e-9, "radius: 4 × 55")
	t.near(w.costPerMetre, 360, 1e-9, "two tracks")
end)

t.test("modes: fastest is flatter and wider", function()
	local w = modes.weights("fastest", TYPES[2])
	t.near(w.maxGrade, 0.025, 1e-9, "grade")
	t.near(w.minRadius, 44.4 * 44.4 / 2, 1e-6, "radius from speed")
	t.near(modes.weights("fastest", TYPES[3]).minRadius, 3000, 1e-9, "capped")
	local c = modes.weights("cheapest", TYPES[2])
	t.ok(w.turnPenalty > c.turnPenalty, "turns cost more")
	t.ok(w.bridgeFactor < c.bridgeFactor, "bridges cost less, relatively")
end)
```

- [ ] **Step 3: Run it to see it fail**

Run: `just test`
Expected: the four `modes:` tests FAIL (module missing); geo tests pass.

- [ ] **Step 4: Implement**

`C/planner/modes.tl`:

```teal
local modes : PgraceRailRouterModes = {}

local type TrackType = PgraceRailRouterModes.TrackType
local type Weights = PgraceRailRouterModes.Weights
local type Mode = PgraceRailRouterModes.Mode

-- Cheapest mode's default skips types faster than this (m/s): high-speed track costs 3× standard.
local CHEAPEST_MAX_SPEED = 60.0
-- Cheapest mode's curves: this many times the type's build minimum.
local CHEAPEST_RADIUS_FACTOR = 4.0
-- Fastest mode's curves: speed² / this (m/s² of sideways acceleration), at least the cheapest radius, at most
-- FASTEST_MAX_RADIUS. Starting values; tuned in milestone 4.
local FASTEST_LATERAL_ACCEL = 2.0
local FASTEST_MAX_RADIUS = 3000.0
local FASTEST_MAX_GRADE = 0.025

function modes.isAvailable(t : TrackType, year : integer) : boolean
	return (t.yearFrom == 0 or year >= t.yearFrom) and (t.yearTo == 0 or year < t.yearTo)
end

function modes.defaultTrack(types : {TrackType}, year : integer, mode : Mode) : TrackType
	local best : TrackType = nil
	for __, t in ipairs(types) do
		if modes.isAvailable(t, year) and (mode == "fastest" or t.speed <= CHEAPEST_MAX_SPEED) then
			if best == nil or t.speed > best.speed then
				best = t
			end
		end
	end
	if best == nil then
		for __, t in ipairs(types) do
			if modes.isAvailable(t, year) and (best == nil or t.cost < best.cost) then
				best = t
			end
		end
	end
	return best
end

function modes.weights(mode : Mode, t : TrackType) : Weights
	local cheapestRadius = t.minCurveRadiusBuild * CHEAPEST_RADIUS_FACTOR
	if mode == "fastest" then
		local radius = math.max(cheapestRadius, t.speed * t.speed / FASTEST_LATERAL_ACCEL)
		return {
			maxGrade = math.min(FASTEST_MAX_GRADE, t.maxSlopeBuild),
			minRadius = math.min(FASTEST_MAX_RADIUS, radius),
			slopePenalty = 1.5,
			bridgeFactor = 3.0,
			turnPenalty = 150.0,
			roadCrossing = 300.0,
			trackCrossing = 400.0,
			costPerMetre = 2 * t.cost,
			bridgeCostFactor = 5.0,
			tunnelCostFactor = 8.0,
			bridgeAbove = 8.0,
			tunnelBelow = 12.0,
		}
	end
	return {
		maxGrade = t.maxSlopeBuild,
		minRadius = cheapestRadius,
		slopePenalty = 3.0,
		bridgeFactor = 6.0,
		turnPenalty = 20.0,
		roadCrossing = 50.0,
		trackCrossing = 400.0,
		costPerMetre = 2 * t.cost,
		bridgeCostFactor = 5.0,
		tunnelCostFactor = 8.0,
		bridgeAbove = 8.0,
		tunnelBelow = 12.0,
	}
end

return modes
```

- [ ] **Step 5: Run check and test**

Run: `just check && just test`
Expected: `0 error(s)`, then `8 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add -A mod tests
git commit -m "feat: planning modes and track type defaults

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `corridor` (candidate stops)

**Files:**
- Create: `D/planner/corridor.d.tl`, `C/planner/corridor.tl`, `tests/corridor_test.lua`
- Modify: `M/tealdef/pgrace_rail_router_def.d.tl`

- [ ] **Step 1: Type definition**

`D/planner/corridor.d.tl`:

```teal
-- Which towns lie on the way between two others, and in what order to visit them. Pure (no api.*).
global record PgraceRailRouterCorridor
	record Town
		-- The town entity.
		id : integer
		name : string
		-- Centre of the town's bounding box.
		pos : PgraceRailRouterGeo.Pt
	end

	record Candidate
		town : Town
		-- Extra straight-line metres to pass through the town's centre.
		detour : number
		-- Where the town projects onto the line from a to b: 0 at a, 1 at b.
		along : number
	end

	-- Towns other than a and b whose detour is at most budget × the direct distance and that lie between them,
	-- sorted from a to b.
	candidates : function(a : Town, b : Town, towns : {Town}, budget : number) : {Candidate}
	-- a, then the picked towns sorted from a to b, then b. a and b are skipped if picked.
	order : function(a : Town, b : Town, picked : {Town}) : {Town}
end
```

Append to the registry:

```teal
require "gui.pgrace_rail_router.planner.corridor"
```

- [ ] **Step 2: Write the failing test**

`tests/corridor_test.lua`:

```lua
local t = ...
local corridor = t.requireTl("gui/pgrace_rail_router/planner/corridor.tl")

local function town(id, name, x, y)
	return { id = id, name = name, pos = { x = x, y = y } }
end

local A = town(1, "A", 0, 0)
local B = town(2, "B", 10000, 0)
local NEAR = town(3, "Near", 5000, 1000)    -- detour about 198 m
local FAR = town(4, "Far", 5000, 4000)      -- detour about 2,806 m
local EARLY = town(5, "Early", 2000, -500)  -- detour about 77 m
local BEHIND = town(6, "Behind", -1000, 0)  -- before A

t.test("corridor: keeps towns within the budget, in order from a to b", function()
	local list = corridor.candidates(A, B, { A, B, NEAR, FAR, EARLY, BEHIND }, 0.15)
	t.eq(#list, 2, "count")
	t.eq(list[1].town.name, "Early", "first")
	t.eq(list[2].town.name, "Near", "second")
	t.near(list[2].detour, 2 * math.sqrt(5000 * 5000 + 1000 * 1000) - 10000, 1e-6, "detour")
	t.near(list[2].along, 0.5, 1e-9, "along")
end)

t.test("corridor: a bigger budget takes more towns", function()
	t.eq(#corridor.candidates(A, B, { NEAR, FAR, EARLY }, 0.3), 3, "count")
end)

t.test("corridor: order puts the picked towns between the ends", function()
	local stops = corridor.order(A, B, { NEAR, EARLY, A })
	t.eq(#stops, 4, "count")
	t.eq(stops[1].name, "A", "1")
	t.eq(stops[2].name, "Early", "2")
	t.eq(stops[3].name, "Near", "3")
	t.eq(stops[4].name, "B", "4")
end)
```

- [ ] **Step 3: Run it to see it fail**

Run: `just test`
Expected: the three `corridor:` tests FAIL (module missing).

- [ ] **Step 4: Implement**

`C/planner/corridor.tl`:

```teal
local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo

local corridor : PgraceRailRouterCorridor = {}

local type Pt = PgraceRailRouterGeo.Pt
local type Town = PgraceRailRouterCorridor.Town
local type Candidate = PgraceRailRouterCorridor.Candidate

-- Where p projects onto the line from a to b: 0 at a, 1 at b (can fall outside 0..1).
local function along(a : Pt, b : Pt, p : Pt) : number
	local ab = geo.sub(b, a)
	local l2 = geo.dot(ab, ab)
	if l2 < 1e-9 then
		return 0
	end
	return geo.dot(geo.sub(p, a), ab) / l2
end

function corridor.candidates(a : Town, b : Town, towns : {Town}, budget : number) : {Candidate}
	local direct = geo.dist(a.pos, b.pos)
	local result : {Candidate} = {}
	for __, town in ipairs(towns) do
		if town.id ~= a.id and town.id ~= b.id then
			local detour = geo.dist(a.pos, town.pos) + geo.dist(town.pos, b.pos) - direct
			local t = along(a.pos, b.pos, town.pos)
			if detour <= budget * direct and t > 0 and t < 1 then
				table.insert(result, { town = town, detour = detour, along = t })
			end
		end
	end
	table.sort(result, function(x : Candidate, y : Candidate) : boolean
		return x.along < y.along
	end)
	return result
end

function corridor.order(a : Town, b : Town, picked : {Town}) : {Town}
	local middle : {Town} = {}
	for __, town in ipairs(picked) do
		if town.id ~= a.id and town.id ~= b.id then
			table.insert(middle, town)
		end
	end
	table.sort(middle, function(x : Town, y : Town) : boolean
		return along(a.pos, b.pos, x.pos) < along(a.pos, b.pos, y.pos)
	end)
	local stops : {Town} = { a }
	for __, town in ipairs(middle) do
		table.insert(stops, town)
	end
	table.insert(stops, b)
	return stops
end

return corridor
```

- [ ] **Step 5: Run check and test**

Run: `just check && just test`
Expected: `0 error(s)`, then `11 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add -A mod tests
git commit -m "feat: candidate stops along the way

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: `grid` (the survey grid and the path search)

**Files:**
- Create: `D/planner/grid.d.tl`, `C/planner/grid.tl`, `tests/grid_test.lua`
- Modify: `M/tealdef/pgrace_rail_router_def.d.tl`

- [ ] **Step 1: Type definition**

`D/planner/grid.d.tl`:

```teal
-- A square-cell grid over the area between the stops (terrain, water, obstacles), and a resumable cheapest-path
-- search over it with 16 move directions. Pure (no api.*).
global record PgraceRailRouterGrid
	record Grid
		-- World position of cell (1, 1)'s centre.
		x0 : number
		y0 : number
		-- Cell size in metres.
		cell : number
		nx : integer
		ny : integer
		-- Per cell, at index (iy - 1) * nx + ix.
		height : {number}
		water : {boolean}
		-- Buildings and other constructions (with a buffer), and points off the map: impassable.
		blocked : {boolean}
		road : {boolean}
		track : {boolean}
	end

	-- A search in progress. The fields other than done, found and expansions are internal.
	record Search
		g : Grid
		w : PgraceRailRouterModes.Weights
		startPt : PgraceRailRouterGeo.Pt
		goalPt : PgraceRailRouterGeo.Pt
		goal : integer
		done : boolean
		found : boolean
		expansions : integer
		heap : {integer}
		heapF : {number}
		cost : {integer : number}
		parent : {integer : integer}
		dir : {integer : integer}
		closed : {integer : boolean}
	end

	-- A flat (height 0), dry, empty grid.
	new : function(x0 : number, y0 : number, cell : number, nx : integer, ny : integer) : Grid
	index : function(g : Grid, ix : integer, iy : integer) : integer
	-- Whether p lies within the grid's cells.
	inside : function(g : Grid, p : PgraceRailRouterGeo.Pt) : boolean
	-- The cell nearest to p, clamped to the grid.
	cellOf : function(g : Grid, p : PgraceRailRouterGeo.Pt) : integer, integer
	centre : function(g : Grid, ix : integer, iy : integer) : PgraceRailRouterGeo.Pt
	-- Ground height at p, interpolated between cell centres (clamped at the edges).
	heightAt : function(g : Grid, p : PgraceRailRouterGeo.Pt) : number
	-- Whether the cell nearest to p is water.
	waterAt : function(g : Grid, p : PgraceRailRouterGeo.Pt) : boolean

	-- Starts a search from `from` to `to`; startDir is the direction the track leaves `from` in (turns are counted
	-- from it).
	startSearch : function(g : Grid, from : PgraceRailRouterGeo.Pt, to : PgraceRailRouterGeo.Pt,
		startDir : PgraceRailRouterGeo.Pt, w : PgraceRailRouterModes.Weights) : Search
	-- Expands up to maxExpansions cells; true once the search is finished (found or not).
	stepSearch : function(s : Search, maxExpansions : integer) : boolean
	-- Rough share of the work done, 0 to 1 (cells expanded / all cells).
	progress : function(s : Search) : number
	-- The path as points from `from` to `to` (cell centres in between); nil if there is none.
	path : function(s : Search) : {PgraceRailRouterGeo.Pt}
end
```

Append to the registry:

```teal
require "gui.pgrace_rail_router.planner.grid"
```

- [ ] **Step 2: Write the failing test**

`tests/grid_test.lua`:

```lua
local t = ...
local grid = t.requireTl("gui/pgrace_rail_router/planner/grid.tl")

local W = { maxGrade = 0.025, minRadius = 500, slopePenalty = 2, bridgeFactor = 6, turnPenalty = 20,
	roadCrossing = 50, trackCrossing = 400, costPerMetre = 360, bridgeCostFactor = 5, tunnelCostFactor = 8,
	bridgeAbove = 8, tunnelBelow = 12 }

local function with(changes)
	local w = {}
	for k, v in pairs(W) do w[k] = v end
	for k, v in pairs(changes) do w[k] = v end
	return w
end

local function run(g, from, to, w, stepSize)
	local s = grid.startSearch(g, from, to, { x = 1, y = 0 }, w or W)
	while not grid.stepSearch(s, stepSize or 1000) do end
	return grid.path(s), s
end

local function cellIndex(g, p)
	local ix, iy = grid.cellOf(g, p)
	return grid.index(g, ix, iy)
end

local function turns(path)
	local count = 0
	for i = 2, #path - 1 do
		local ax, ay = path[i].x - path[i - 1].x, path[i].y - path[i - 1].y
		local bx, by = path[i + 1].x - path[i].x, path[i + 1].y - path[i].y
		if math.abs(ax * by - ay * bx) > 1e-6 then
			count = count + 1
		end
	end
	return count
end

-- 31 × 21 cells of 100 m with a lake over cells x 8..24, y 1..16: open water except along the top five rows.
local function lakeGrid()
	local g = grid.new(0, 0, 100, 31, 21)
	for iy = 1, 16 do
		for ix = 8, 24 do
			g.water[grid.index(g, ix, iy)] = true
		end
	end
	return g
end

t.test("grid: straight on flat ground", function()
	local g = grid.new(0, 0, 100, 21, 11)
	local path = run(g, { x = 0, y = 500 }, { x = 2000, y = 500 })
	t.ok(path ~= nil, "found")
	t.eq(#path, 21, "one point per cell")
	for __, p in ipairs(path) do
		t.near(p.y, 500, 1e-9, "on the line")
	end
end)

t.test("grid: goes through the gap in a wall", function()
	local g = grid.new(0, 0, 100, 21, 21)
	for iy = 1, 21 do
		if iy ~= 17 then
			g.blocked[grid.index(g, 11, iy)] = true
		end
	end
	local path = run(g, { x = 0, y = 1000 }, { x = 2000, y = 1000 })
	t.ok(path ~= nil, "found")
	local throughGap = false
	for __, p in ipairs(path) do
		t.ok(not g.blocked[cellIndex(g, p)], "never on a blocked cell")
		if p.x == 1000 and p.y == 1600 then
			throughGap = true
		end
	end
	t.ok(throughGap, "through the gap")
end)

t.test("grid: goes round a lake rather than bridging it", function()
	local g = lakeGrid()
	local path = run(g, { x = 0, y = 800 }, { x = 3000, y = 800 })
	t.ok(path ~= nil, "found")
	for __, p in ipairs(path) do
		t.ok(not g.water[cellIndex(g, p)], "stays dry")
	end
end)

t.test("grid: bridges the lake when bridges are cheap", function()
	local g = lakeGrid()
	local path = run(g, { x = 0, y = 800 }, { x = 3000, y = 800 }, with({ bridgeFactor = 1.5 }))
	local wet = false
	for __, p in ipairs(path) do
		wet = wet or g.water[cellIndex(g, p)]
	end
	t.ok(wet, "crosses water")
end)

t.test("grid: a high turn penalty gives no more turns", function()
	local low = run(lakeGrid(), { x = 0, y = 800 }, { x = 3000, y = 800 }, with({ turnPenalty = 0 }))
	local high = run(lakeGrid(), { x = 0, y = 800 }, { x = 3000, y = 800 }, with({ turnPenalty = 500 }))
	t.ok(turns(high) <= turns(low), "turns: high " .. turns(high) .. ", low " .. turns(low))
end)

t.test("grid: no path through a solid wall", function()
	local g = grid.new(0, 0, 100, 21, 21)
	for iy = 1, 21 do
		g.blocked[grid.index(g, 11, iy)] = true
	end
	local path, s = run(g, { x = 0, y = 1000 }, { x = 2000, y = 1000 })
	t.eq(path, nil, "no path")
	t.ok(s.done, "finished")
end)

t.test("grid: small steps give the same path as one big step", function()
	local a = run(lakeGrid(), { x = 0, y = 800 }, { x = 3000, y = 800 }, W, 1)
	local b = run(lakeGrid(), { x = 0, y = 800 }, { x = 3000, y = 800 }, W, 100000)
	t.eq(#a, #b, "length")
	for i = 1, #a do
		t.eq(a[i].x, b[i].x, "x " .. i)
		t.eq(a[i].y, b[i].y, "y " .. i)
	end
end)

t.test("grid: heightAt interpolates and clamps", function()
	local g = grid.new(0, 0, 100, 3, 1)
	g.height[1], g.height[2], g.height[3] = 0, 10, 20
	t.near(grid.heightAt(g, { x = 50, y = 0 }), 5, 1e-9, "between 1 and 2")
	t.near(grid.heightAt(g, { x = 150, y = 0 }), 15, 1e-9, "between 2 and 3")
	t.near(grid.heightAt(g, { x = 900, y = 0 }), 20, 1e-9, "clamped")
end)

t.test("grid: inside and cellOf", function()
	local g = grid.new(0, 0, 100, 3, 3)
	t.ok(grid.inside(g, { x = 0, y = 0 }), "corner cell")
	t.ok(not grid.inside(g, { x = -60, y = 0 }), "left of the grid")
	local ix, iy = grid.cellOf(g, { x = 149, y = 260 })
	t.eq(ix, 2, "nearest column")
	t.eq(iy, 3, "row 4 is past the edge: clamped to 3")
end)
```

- [ ] **Step 3: Run it to see it fail**

Run: `just test`
Expected: the nine `grid:` tests FAIL (module missing).

- [ ] **Step 4: Implement**

`C/planner/grid.tl`:

```teal
local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo

local grid : PgraceRailRouterGrid = {}

local type Pt = PgraceRailRouterGeo.Pt
local type Grid = PgraceRailRouterGrid.Grid
local type Search = PgraceRailRouterGrid.Search
local type Weights = PgraceRailRouterModes.Weights

-- The 16 move directions, counter-clockwise from +x, about 22.5° apart (the knight moves are 26.6° off the axes,
-- close enough for counting turns).
local DIRS : {{integer}} = {
	{ 1, 0 }, { 2, 1 }, { 1, 1 }, { 1, 2 }, { 0, 1 }, { -1, 2 }, { -1, 1 }, { -2, 1 },
	{ -1, 0 }, { -2, -1 }, { -1, -1 }, { -1, -2 }, { 0, -1 }, { 1, -2 }, { 1, -1 }, { 2, -1 },
}
-- A single move may turn at most this many 22.5° steps (90°).
local MAX_TURN_STEPS = 4

function grid.new(x0 : number, y0 : number, cell : number, nx : integer, ny : integer) : Grid
	local g : Grid = { x0 = x0, y0 = y0, cell = cell, nx = nx, ny = ny, height = {}, water = {}, blocked = {},
		road = {}, track = {} }
	for i = 1, nx * ny do
		g.height[i] = 0
		g.water[i] = false
		g.blocked[i] = false
		g.road[i] = false
		g.track[i] = false
	end
	return g
end

function grid.index(g : Grid, ix : integer, iy : integer) : integer
	return (iy - 1) * g.nx + ix
end

function grid.inside(g : Grid, p : Pt) : boolean
	local fx = (p.x - g.x0) / g.cell + 1
	local fy = (p.y - g.y0) / g.cell + 1
	return fx >= 0.5 and fx <= g.nx + 0.5 and fy >= 0.5 and fy <= g.ny + 0.5
end

function grid.cellOf(g : Grid, p : Pt) : integer, integer
	local ix = math.floor((p.x - g.x0) / g.cell + 1.5)
	local iy = math.floor((p.y - g.y0) / g.cell + 1.5)
	return math.max(1, math.min(g.nx, ix)), math.max(1, math.min(g.ny, iy))
end

function grid.centre(g : Grid, ix : integer, iy : integer) : Pt
	return { x = g.x0 + (ix - 1) * g.cell, y = g.y0 + (iy - 1) * g.cell }
end

function grid.heightAt(g : Grid, p : Pt) : number
	local fx = math.max(0, math.min(g.nx - 1, (p.x - g.x0) / g.cell))
	local fy = math.max(0, math.min(g.ny - 1, (p.y - g.y0) / g.cell))
	local cx, cy = math.floor(fx), math.floor(fy)
	local tx, ty = fx - cx, fy - cy
	local cx1, cy1 = math.min(cx + 1, g.nx - 1), math.min(cy + 1, g.ny - 1)
	-- Zero-based cell coordinates.
	local function h(x : integer, y : integer) : number
		return g.height[y * g.nx + x + 1]
	end
	local top = h(cx, cy) * (1 - tx) + h(cx1, cy) * tx
	local bottom = h(cx, cy1) * (1 - tx) + h(cx1, cy1) * tx
	return top * (1 - ty) + bottom * ty
end

function grid.waterAt(g : Grid, p : Pt) : boolean
	local ix, iy = grid.cellOf(g, p)
	return g.water[grid.index(g, ix, iy)]
end

-- A binary min-heap on f, with duplicates allowed (stale entries are skipped when popped).
local function push(s : Search, node : integer, f : number)
	local heap, keys = s.heap, s.heapF
	local i = #heap + 1
	heap[i], keys[i] = node, f
	while i > 1 do
		local parent = math.floor(i / 2)
		if keys[parent] <= keys[i] then
			break
		end
		heap[parent], heap[i] = heap[i], heap[parent]
		keys[parent], keys[i] = keys[i], keys[parent]
		i = parent
	end
end

local function pop(s : Search) : integer
	local heap, keys = s.heap, s.heapF
	local n = #heap
	local top = heap[1]
	heap[1], keys[1] = heap[n], keys[n]
	heap[n], keys[n] = nil, nil
	n = n - 1
	local i = 1
	while true do
		local l, r = 2 * i, 2 * i + 1
		local smallest = i
		if l <= n and keys[l] < keys[smallest] then
			smallest = l
		end
		if r <= n and keys[r] < keys[smallest] then
			smallest = r
		end
		if smallest == i then
			break
		end
		heap[smallest], heap[i] = heap[i], heap[smallest]
		keys[smallest], keys[i] = keys[i], keys[smallest]
		i = smallest
	end
	return top
end

local function cellXY(g : Grid, node : integer) : integer, integer
	return (node - 1) % g.nx + 1, math.floor((node - 1) / g.nx) + 1
end

-- Straight-line metres to the goal: no step costs less than its length, so this never overestimates.
local function heuristic(s : Search, node : integer) : number
	local ax, ay = cellXY(s.g, node)
	local gx, gy = cellXY(s.g, s.goal)
	return s.g.cell * math.sqrt((gx - ax) * (gx - ax) + (gy - ay) * (gy - ay))
end

local function nearestDir(d : Pt) : integer
	if geo.len(d) < 1e-9 then
		return 0
	end
	local unit = geo.norm(d)
	local best, bestDot = 0, -math.huge
	for k, v in ipairs(DIRS) do
		local dot = geo.dot(unit, geo.norm({ x = v[1], y = v[2] }))
		if dot > bestDot then
			best, bestDot = k, dot
		end
	end
	return best
end

-- The cost of moving from cell a (at ax, ay) in direction k, or nil if the move isn't allowed.
local function stepCost(s : Search, a : integer, ax : integer, ay : integer, k : integer) : number
	local g, w = s.g, s.w
	local d = DIRS[k]
	local bx, by = ax + d[1], ay + d[2]
	if bx < 1 or bx > g.nx or by < 1 or by > g.ny then
		return nil
	end
	local b = grid.index(g, bx, by)
	if g.blocked[b] then
		return nil
	end
	local overWater = g.water[a] or g.water[b]
	-- A knight move passes between two cells: both must be passable.
	if math.abs(d[1]) + math.abs(d[2]) == 3 then
		local m1 = grid.index(g, ax + math.floor(d[1] / 2), ay + math.floor(d[2] / 2))
		local m2 = grid.index(g, ax + math.ceil(d[1] / 2), ay + math.ceil(d[2] / 2))
		if g.blocked[m1] or g.blocked[m2] then
			return nil
		end
		overWater = overWater or g.water[m1] or g.water[m2]
	end
	local turnSteps = 0
	local prev = s.dir[a] or 0
	if prev ~= 0 then
		turnSteps = math.abs(k - prev)
		if turnSteps > 8 then
			turnSteps = 16 - turnSteps
		end
		if turnSteps > MAX_TURN_STEPS then
			return nil
		end
	end
	local length = g.cell * math.sqrt(d[1] * d[1] + d[2] * d[2])
	local factor = 1.0
	if overWater then
		factor = w.bridgeFactor
	else
		local grade = math.abs(g.height[b] - g.height[a]) / length
		if grade > w.maxGrade then
			factor = 1 + w.slopePenalty * (grade - w.maxGrade) / w.maxGrade
		end
	end
	local cost = length * factor + w.turnPenalty * turnSteps * turnSteps
	if g.road[b] and not g.road[a] then
		cost = cost + w.roadCrossing
	end
	if g.track[b] and not g.track[a] then
		cost = cost + w.trackCrossing
	end
	return cost
end

function grid.startSearch(g : Grid, from : Pt, to : Pt, startDir : Pt, w : Weights) : Search
	local sx, sy = grid.cellOf(g, from)
	local gx, gy = grid.cellOf(g, to)
	local s : Search = { g = g, w = w, startPt = from, goalPt = to, goal = grid.index(g, gx, gy), done = false,
		found = false, expansions = 0, heap = {}, heapF = {}, cost = {}, parent = {}, dir = {}, closed = {} }
	local start = grid.index(g, sx, sy)
	s.cost[start] = 0
	s.dir[start] = nearestDir(startDir)
	push(s, start, heuristic(s, start))
	return s
end

function grid.stepSearch(s : Search, maxExpansions : integer) : boolean
	if s.done then
		return true
	end
	local g = s.g
	local budget = maxExpansions
	while budget > 0 do
		if #s.heap == 0 then
			s.done = true
			return true
		end
		local a = pop(s)
		if not s.closed[a] then
			s.closed[a] = true
			s.expansions = s.expansions + 1
			budget = budget - 1
			if a == s.goal then
				s.done, s.found = true, true
				return true
			end
			local ax, ay = cellXY(g, a)
			for k = 1, #DIRS do
				local c = stepCost(s, a, ax, ay, k)
				if c ~= nil then
					local d = DIRS[k]
					local b = grid.index(g, ax + d[1], ay + d[2])
					local nc = s.cost[a] + c
					if not s.closed[b] and (s.cost[b] == nil or nc < s.cost[b]) then
						s.cost[b], s.parent[b], s.dir[b] = nc, a, k
						push(s, b, nc + heuristic(s, b))
					end
				end
			end
		end
	end
	return false
end

function grid.progress(s : Search) : number
	if s.done then
		return 1
	end
	return math.min(1, s.expansions / (s.g.nx * s.g.ny))
end

function grid.path(s : Search) : {Pt}
	if not s.found then
		return nil
	end
	local g = s.g
	local cells : {integer} = {}
	local node = s.goal
	while node ~= nil do
		table.insert(cells, 1, node)
		node = s.parent[node]
	end
	if #cells < 2 then
		return { s.startPt, s.goalPt }
	end
	local pts : {Pt} = {}
	for i, c in ipairs(cells) do
		local ix, iy = cellXY(g, c)
		pts[i] = grid.centre(g, ix, iy)
	end
	pts[1] = s.startPt
	pts[#pts] = s.goalPt
	return pts
end

return grid
```

- [ ] **Step 5: Run check and test**

Run: `just check && just test`
Expected: `0 error(s)`, then `20 passed, 0 failed`. If "goes round a lake" fails, print the path (`for _, p in ipairs(path) do print(p.x, p.y) end`) before changing any weight: the test map's detour is about 1.7 km against a bridge surcharge of 8.5 km, so the search must avoid the water.

- [ ] **Step 6: Commit**

```bash
git add -A mod tests
git commit -m "feat: survey grid and cheapest-path search

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: `stations` (station sites)

**Files:**
- Create: `D/planner/stations.d.tl`, `C/planner/stations.tl`, `tests/stations_test.lua`
- Modify: `M/tealdef/pgrace_rail_router_def.d.tl`

- [ ] **Step 1: Type definition**

`D/planner/stations.d.tl`:

```teal
-- Where a town's station goes: the nearest spot to its centre with room for a straight, flat run, never on a
-- building (the survey blocks buildings with a buffer). Pure (no api.*).
global record PgraceRailRouterStations
	record Site
		-- Centre of the platforms.
		centre : PgraceRailRouterGeo.Pt
		-- Unit direction of the platforms, in the direction of travel.
		dir : PgraceRailRouterGeo.Pt
		-- Metres from the town's centre.
		distance : number
	end

	-- Searches rings around `town`, nearest first, for a centre where a straight run of `runLength` metres along
	-- `dir` (or up to 30° off it) is inside the grid, dry, unblocked and within `maxRelief` metres of height. nil if
	-- none lies within maxRadius.
	find : function(g : PgraceRailRouterGrid.Grid, town : PgraceRailRouterGeo.Pt, dir : PgraceRailRouterGeo.Pt,
		runLength : number, maxRelief : number, maxRadius : number) : Site
end
```

Append to the registry:

```teal
require "gui.pgrace_rail_router.planner.stations"
```

- [ ] **Step 2: Write the failing test**

`tests/stations_test.lua`:

```lua
local t = ...
local grid = t.requireTl("gui/pgrace_rail_router/planner/grid.tl")
local stations = t.requireTl("gui/pgrace_rail_router/planner/stations.tl")

-- 41 × 41 cells of 100 m centred on the origin.
local function openGrid()
	return grid.new(-2000, -2000, 100, 41, 41)
end

local function runIsClear(g, site, runLength)
	for d = -runLength / 2, runLength / 2, 25 do
		local p = { x = site.centre.x + site.dir.x * d, y = site.centre.y + site.dir.y * d }
		local ix, iy = grid.cellOf(g, p)
		if g.blocked[grid.index(g, ix, iy)] then
			return false
		end
	end
	return true
end

t.test("stations: an empty town centre takes the station", function()
	local site = stations.find(openGrid(), { x = 0, y = 0 }, { x = 1, y = 0 }, 360, 10, 1500)
	t.ok(site ~= nil, "found")
	t.near(site.distance, 0, 1e-9, "at the centre")
	t.near(site.dir.x, 1, 1e-9, "facing the line")
end)

t.test("stations: a built-up centre pushes the station out", function()
	local g = openGrid()
	for iy = 1, 41 do
		for ix = 1, 41 do
			local c = grid.centre(g, ix, iy)
			if math.sqrt(c.x * c.x + c.y * c.y) <= 400 then
				g.blocked[grid.index(g, ix, iy)] = true
			end
		end
	end
	local site = stations.find(g, { x = 0, y = 0 }, { x = 1, y = 0 }, 360, 10, 1500)
	t.ok(site ~= nil, "found")
	t.ok(site.distance > 300, "outside the built-up area: " .. site.distance)
	t.ok(runIsClear(g, site, 360), "run is clear")
end)

t.test("stations: nothing found when everything is built up", function()
	local g = openGrid()
	for i = 1, 41 * 41 do
		g.blocked[i] = true
	end
	t.eq(stations.find(g, { x = 0, y = 0 }, { x = 1, y = 0 }, 360, 10, 1500), nil, "none")
end)

t.test("stations: steep ground is skipped for flat ground", function()
	local g = openGrid()
	-- West of x = 1000 the ground climbs 50 m per cell northwards; east of it, flat.
	for iy = 1, 41 do
		for ix = 1, 30 do
			g.height[grid.index(g, ix, iy)] = 50 * iy
		end
	end
	local site = stations.find(g, { x = 0, y = 0 }, { x = 0, y = 1 }, 360, 10, 1500)
	t.ok(site ~= nil, "found")
	t.ok(site.centre.x >= 1000, "on the flat: x " .. site.centre.x)
end)
```

- [ ] **Step 3: Run it to see it fail**

Run: `just test`
Expected: the four `stations:` tests FAIL (module missing).

- [ ] **Step 4: Implement**

`C/planner/stations.tl`:

```teal
local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo
local grid = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/grid.tl" as PgraceRailRouterGrid

local stations : PgraceRailRouterStations = {}

local type Pt = PgraceRailRouterGeo.Pt
local type Grid = PgraceRailRouterGrid.Grid
local type Site = PgraceRailRouterStations.Site

-- Directions tried at each spot: the wanted one first, then up to 30° either way.
local TURNS : {number} = { 0, math.rad(15), -math.rad(15), math.rad(30), -math.rad(30) }

local function clear(g : Grid, centre : Pt, dir : Pt, runLength : number, maxRelief : number) : boolean
	local step = g.cell / 2
	local lo, hi = math.huge, -math.huge
	local d = -runLength / 2
	while d <= runLength / 2 + 1e-6 do
		local p = geo.add(centre, geo.scale(dir, d))
		if not grid.inside(g, p) then
			return false
		end
		local ix, iy = grid.cellOf(g, p)
		local i = grid.index(g, ix, iy)
		if g.blocked[i] or g.water[i] then
			return false
		end
		local h = grid.heightAt(g, p)
		lo, hi = math.min(lo, h), math.max(hi, h)
		d = d + step
	end
	return hi - lo <= maxRelief
end

function stations.find(g : Grid, town : Pt, dir : Pt, runLength : number, maxRelief : number, maxRadius : number) : Site
	local unit = geo.norm(dir)
	local step = g.cell / 2
	local r = 0.0
	while r <= maxRadius do
		local n : integer = 1
		if r > 0 then
			n = math.floor(math.max(8, 2 * math.pi * r / step))
		end
		for i = 0, n - 1 do
			local angle = 2 * math.pi * i / n
			local centre : Pt = { x = town.x + r * math.cos(angle), y = town.y + r * math.sin(angle) }
			for __, turn in ipairs(TURNS) do
				local d = geo.rotate(unit, turn)
				if clear(g, centre, d, runLength, maxRelief) then
					return { centre = centre, dir = d, distance = r }
				end
			end
		end
		r = r + step
	end
	return nil
end

return stations
```

- [ ] **Step 5: Run check and test**

Run: `just check && just test`
Expected: `0 error(s)`, then `24 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add -A mod tests
git commit -m "feat: station sites near town centres without demolition

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: `smooth` (curves)

**Files:**
- Create: `D/planner/smooth.d.tl`, `C/planner/smooth.tl`, `tests/smooth_test.lua`
- Modify: `M/tealdef/pgrace_rail_router_def.d.tl`

- [ ] **Step 1: Type definition**

`D/planner/smooth.d.tl`:

```teal
-- Turns a jagged grid path into straights and arcs no tighter than a radius, and samples points along them.
-- Pure (no api.*).
global record PgraceRailRouterSmooth
	record Piece
		-- "straight" or "arc"
		kind : string
		a : PgraceRailRouterGeo.Pt
		b : PgraceRailRouterGeo.Pt
		length : number
		-- Arcs only: radius, centre, and the signed turn in radians (positive turns left).
		radius : number
		centre : PgraceRailRouterGeo.Pt
		turn : number
	end

	record Sample
		p : PgraceRailRouterGeo.Pt
		-- Metres along the pieces from their start.
		s : number
	end

	record Result
		pieces : {Piece}
		-- The tightest arc's radius; math.huge without arcs. Below the asked radius only where fixed points left no
		-- room for it.
		minRadius : number
		-- Points dropped to make room for the curves.
		removed : integer
	end

	-- Douglas–Peucker: drops points within `tolerance` metres of the line through their neighbours. Keeps the ends.
	simplify : function(points : {PgraceRailRouterGeo.Pt}, tolerance : number) : {PgraceRailRouterGeo.Pt}
	-- Rounds each corner with an arc of `radius`. Where neighbouring arcs don't fit, a point is dropped (the one with
	-- the gentler turn); points marked in `fixed` (by index) and the two ends are never dropped, and arcs between
	-- them are tightened to fit instead.
	fillet : function(points : {PgraceRailRouterGeo.Pt}, radius : number, fixed : {boolean}) : Result
	-- The point `d` metres along a piece.
	pointAt : function(piece : Piece, d : number) : PgraceRailRouterGeo.Pt
	-- Points every `step` metres or less along the pieces, both ends included.
	sample : function(pieces : {Piece}, step : number) : {Sample}
end
```

Append to the registry:

```teal
require "gui.pgrace_rail_router.planner.smooth"
```

- [ ] **Step 2: Write the failing test**

`tests/smooth_test.lua`:

```lua
local t = ...
local smooth = t.requireTl("gui/pgrace_rail_router/planner/smooth.tl")

local function P(x, y)
	return { x = x, y = y }
end

t.test("smooth: simplify drops points on a straight line", function()
	local pts = smooth.simplify({ P(0, 0), P(100, 0), P(200, 0), P(300, 1), P(400, 0) }, 10)
	t.eq(#pts, 2, "two ends left")
	t.eq(pts[2].x, 400, "last kept")
end)

t.test("smooth: simplify keeps a real corner", function()
	local pts = smooth.simplify({ P(0, 0), P(500, 0), P(1000, 0), P(1000, 500), P(1000, 1000) }, 10)
	t.eq(#pts, 3, "corner kept")
	t.eq(pts[2].x, 1000, "corner x")
	t.eq(pts[2].y, 0, "corner y")
end)

t.test("smooth: a right-angle corner becomes straight, arc, straight", function()
	local r = smooth.fillet({ P(0, 0), P(1000, 0), P(1000, 1000) }, 200, {})
	t.eq(#r.pieces, 3, "pieces")
	t.eq(r.pieces[1].kind, "straight", "1")
	t.near(r.pieces[1].length, 800, 1e-6, "first straight")
	local arc = r.pieces[2]
	t.eq(arc.kind, "arc", "2")
	t.near(arc.radius, 200, 1e-6, "radius")
	t.near(arc.centre.x, 800, 1e-6, "centre x")
	t.near(arc.centre.y, 200, 1e-6, "centre y")
	t.near(arc.turn, math.pi / 2, 1e-9, "left turn")
	t.near(arc.length, 100 * math.pi, 1e-6, "arc length")
	local e = smooth.pointAt(arc, arc.length)
	t.near(e.x, 1000, 1e-6, "arc ends at x")
	t.near(e.y, 200, 1e-6, "arc ends at y")
	t.near(r.pieces[3].length, 800, 1e-6, "last straight")
	t.near(r.minRadius, 200, 1e-6, "min radius")
	t.eq(r.removed, 0, "nothing dropped")
end)

t.test("smooth: a right turn curves the other way", function()
	local r = smooth.fillet({ P(0, 0), P(1000, 0), P(1000, -1000) }, 200, {})
	t.ok(r.pieces[2].turn < 0, "negative turn")
	local e = smooth.pointAt(r.pieces[2], r.pieces[2].length)
	t.near(e.x, 1000, 1e-6, "x")
	t.near(e.y, -200, 1e-6, "y")
end)

t.test("smooth: a jog too short for two curves loses a point", function()
	local r = smooth.fillet({ P(0, 0), P(500, 0), P(550, 50), P(1000, 50) }, 200, {})
	t.eq(r.removed, 1, "one dropped")
	t.near(r.minRadius, 200, 1e-6, "radius kept")
end)

t.test("smooth: fixed points are kept and the arcs tighten", function()
	local fixed = {}
	fixed[2], fixed[3] = true, true
	local r = smooth.fillet({ P(0, 0), P(100, 0), P(100, 100), P(200, 100) }, 200, fixed)
	t.eq(r.removed, 0, "nothing dropped")
	t.near(r.minRadius, 50, 1e-6, "tightened")
end)

t.test("smooth: a straight line is one piece", function()
	local r = smooth.fillet({ P(0, 0), P(100, 0), P(200, 0) }, 200, {})
	t.eq(#r.pieces, 1, "one straight")
	t.near(r.pieces[1].length, 200, 1e-9, "length")
	t.eq(r.minRadius, math.huge, "no arcs")
end)

t.test("smooth: samples cover the pieces", function()
	local straight = smooth.sample(smooth.fillet({ P(0, 0), P(1000, 0) }, 200, {}).pieces, 100)
	t.eq(#straight, 11, "count")
	t.near(straight[11].s, 1000, 1e-9, "last s")
	t.near(straight[11].p.x, 1000, 1e-9, "last x")
	local r = smooth.fillet({ P(0, 0), P(1000, 0), P(1000, 1000) }, 200, {})
	for __, sample in ipairs(smooth.sample({ r.pieces[2] }, 10)) do
		local dx, dy = sample.p.x - 800, sample.p.y - 200
		t.near(math.sqrt(dx * dx + dy * dy), 200, 1e-6, "on the arc")
	end
end)
```

- [ ] **Step 3: Run it to see it fail**

Run: `just test`
Expected: the eight `smooth:` tests FAIL (module missing).

- [ ] **Step 4: Implement**

`C/planner/smooth.tl`:

```teal
local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo

local smooth : PgraceRailRouterSmooth = {}

local type Pt = PgraceRailRouterGeo.Pt
local type Piece = PgraceRailRouterSmooth.Piece
local type Sample = PgraceRailRouterSmooth.Sample
local type Result = PgraceRailRouterSmooth.Result

local function perpDist(p : Pt, a : Pt, b : Pt) : number
	local ab = geo.sub(b, a)
	local l = geo.len(ab)
	if l < 1e-9 then
		return geo.dist(p, a)
	end
	return math.abs(geo.cross(ab, geo.sub(p, a))) / l
end

function smooth.simplify(points : {Pt}, tolerance : number) : {Pt}
	local n = #points
	local keep : {boolean} = {}
	keep[1], keep[n] = true, true
	local stack : {{integer}} = { { 1, n } }
	while #stack > 0 do
		local range = table.remove(stack)
		local i, j = range[1], range[2]
		local worst, worstD = 0, 0.0
		for k = i + 1, j - 1 do
			local d = perpDist(points[k], points[i], points[j])
			if d > worstD then
				worst, worstD = k, d
			end
		end
		if worst > 0 and worstD > tolerance then
			keep[worst] = true
			table.insert(stack, { i, worst })
			table.insert(stack, { worst, j })
		end
	end
	local result : {Pt} = {}
	for k = 1, n do
		if keep[k] then
			table.insert(result, points[k])
		end
	end
	return result
end

local function straight(pieces : {Piece}, a : Pt, b : Pt)
	local length = geo.dist(a, b)
	if length > 1e-6 then
		table.insert(pieces, { kind = "straight", a = a, b = b, length = length })
	end
end

-- Pieces for points whose corner tangents (t) fit, tightening any that overlap between fixed points.
local function build(pts : {Pt}, theta : {number}, t : {number}, removed : integer) : Result
	local n = #pts
	local fit : {number} = {}
	for i = 1, n do
		fit[i] = t[i]
	end
	for i = 1, n - 1 do
		local len = geo.dist(pts[i], pts[i + 1])
		local sum = t[i] + t[i + 1]
		if sum > len and sum > 0 then
			local k = len / sum
			fit[i] = math.min(fit[i], t[i] * k)
			fit[i + 1] = math.min(fit[i + 1], t[i + 1] * k)
		end
	end
	local pieces : {Piece} = {}
	local minRadius = math.huge
	local cur = pts[1]
	for i = 2, n - 1 do
		if theta[i] > 1e-6 then
			local din = geo.norm(geo.sub(pts[i], pts[i - 1]))
			local dout = geo.norm(geo.sub(pts[i + 1], pts[i]))
			local a = geo.sub(pts[i], geo.scale(din, fit[i]))
			local b = geo.add(pts[i], geo.scale(dout, fit[i]))
			local r = fit[i] / math.tan(theta[i] / 2)
			local side = geo.cross(din, dout) > 0 and 1 or -1
			local centre = geo.add(a, geo.scale({ x = -din.y, y = din.x }, side * r))
			straight(pieces, cur, a)
			table.insert(pieces, { kind = "arc", a = a, b = b, length = r * theta[i], radius = r, centre = centre,
				turn = side * theta[i] })
			minRadius = math.min(minRadius, r)
			cur = b
		end
	end
	straight(pieces, cur, pts[n])
	return { pieces = pieces, minRadius = minRadius, removed = removed }
end

function smooth.fillet(points : {Pt}, radius : number, fixed : {boolean}) : Result
	local pts : {Pt} = {}
	local fix : {boolean} = {}
	for i, p in ipairs(points) do
		pts[i] = p
		fix[i] = fixed[i] == true
	end
	fix[1], fix[#pts] = true, true
	local removed = 0
	while true do
		local n = #pts
		local theta : {number} = {}
		local t : {number} = {}
		for i = 1, n do
			theta[i], t[i] = 0, 0
		end
		for i = 2, n - 1 do
			theta[i] = geo.turnAngle(geo.sub(pts[i], pts[i - 1]), geo.sub(pts[i + 1], pts[i]))
			t[i] = radius * math.tan(theta[i] / 2)
		end
		local victim : integer = nil
		for i = 1, n - 1 do
			if t[i] + t[i + 1] > geo.dist(pts[i], pts[i + 1]) + 1e-6 then
				if not fix[i] and not fix[i + 1] then
					victim = theta[i] <= theta[i + 1] and i or i + 1
				elseif not fix[i] then
					victim = i
				elseif not fix[i + 1] then
					victim = i + 1
				end
				if victim ~= nil then
					break
				end
			end
		end
		if victim == nil then
			return build(pts, theta, t, removed)
		end
		table.remove(pts, victim)
		table.remove(fix, victim)
		removed = removed + 1
	end
end

function smooth.pointAt(piece : Piece, d : number) : Pt
	if piece.kind == "arc" then
		local f = piece.length > 0 and d / piece.length or 0
		return geo.add(piece.centre, geo.rotate(geo.sub(piece.a, piece.centre), piece.turn * f))
	end
	local f = piece.length > 0 and d / piece.length or 0
	return geo.add(piece.a, geo.scale(geo.sub(piece.b, piece.a), f))
end

function smooth.sample(pieces : {Piece}, step : number) : {Sample}
	local samples : {Sample} = {}
	local s0 = 0.0
	for __, piece in ipairs(pieces) do
		local m = math.max(1, math.ceil(piece.length / step))
		for j = 0, m - 1 do
			local d = piece.length * j / m
			table.insert(samples, { p = smooth.pointAt(piece, d), s = s0 + d })
		end
		s0 = s0 + piece.length
	end
	if #pieces > 0 then
		local last = pieces[#pieces]
		table.insert(samples, { p = smooth.pointAt(last, last.length), s = s0 })
	end
	return samples
end

return smooth
```

- [ ] **Step 5: Run check and test**

Run: `just check && just test`
Expected: `0 error(s)`, then `32 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add -A mod tests
git commit -m "feat: curve fitting with a minimum radius

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: `profile` (heights, bridges, tunnels)

**Files:**
- Create: `D/planner/profile.d.tl`, `C/planner/profile.tl`, `tests/profile_test.lua`
- Modify: `M/tealdef/pgrace_rail_router_def.d.tl`

- [ ] **Step 1: Type definition**

`D/planner/profile.d.tl`:

```teal
-- Track heights along a route under a grade limit, and where that puts it on bridges or in tunnels. Pure (no api.*).
global record PgraceRailRouterProfile
	record Span
		-- "ground", "bridge" or "tunnel"
		kind : string
		-- Metres along the route.
		s0 : number
		s1 : number
	end

	record Result
		-- Track height per sample.
		z : {number}
		-- Consecutive runs of one kind, covering the route.
		spans : {Span}
		-- Steepest grade between samples.
		maxGrade : number
	end

	-- `s` is metres along the route per sample (increasing), `ground` the ground height and `water` whether it's
	-- water. The track follows the ground as closely as maxGrade allows, and runs straight between the banks over
	-- water. Water, and track more than bridgeAbove over the ground, are bridges; track more than tunnelBelow under
	-- it is a tunnel.
	fit : function(s : {number}, ground : {number}, water : {boolean}, maxGrade : number, bridgeAbove : number,
		tunnelBelow : number) : Result
end
```

Append to the registry:

```teal
require "gui.pgrace_rail_router.planner.profile"
```

- [ ] **Step 2: Write the failing test**

`tests/profile_test.lua`:

```lua
local t = ...
local profile = t.requireTl("gui/pgrace_rail_router/planner/profile.tl")

-- Samples every 25 m over 1 km; ground and water from functions of s.
local function line(groundOf, waterOf)
	local s, ground, water = {}, {}, {}
	for i = 0, 40 do
		s[#s + 1] = i * 25
		ground[#ground + 1] = groundOf(i * 25)
		water[#water + 1] = waterOf ~= nil and waterOf(i * 25) or false
	end
	return s, ground, water
end

-- Neighbouring spans share their boundary; a point on it belongs to the later span.
local function spanAt(result, s)
	for i = #result.spans, 1, -1 do
		local span = result.spans[i]
		if s >= span.s0 and s <= span.s1 then
			return span.kind
		end
	end
end

local function gradesWithin(result, s, limit)
	for i = 2, #s do
		if math.abs(result.z[i] - result.z[i - 1]) / (s[i] - s[i - 1]) > limit + 1e-9 then
			return false
		end
	end
	return true
end

t.test("profile: flat ground is one ground span", function()
	local s, ground, water = line(function() return 0 end)
	local r = profile.fit(s, ground, water, 0.025, 8, 12)
	t.eq(#r.spans, 1, "spans")
	t.eq(r.spans[1].kind, "ground", "kind")
	t.near(r.spans[1].s1, 1000, 1e-9, "covers the route")
	t.near(r.maxGrade, 0, 1e-12, "grade")
end)

t.test("profile: a gentle slope is followed exactly", function()
	local s, ground, water = line(function(x) return 0.01 * x end)
	local r = profile.fit(s, ground, water, 0.025, 8, 12)
	for i = 1, #s do
		t.near(r.z[i], ground[i], 1e-9, "z " .. i)
	end
end)

t.test("profile: a deep valley becomes a bridge", function()
	local s, ground, water = line(function(x) return (x >= 400 and x <= 600) and -40 or 0 end)
	local r = profile.fit(s, ground, water, 0.02, 8, 12)
	t.eq(spanAt(r, 500), "bridge", "middle")
	t.ok(gradesWithin(r, s, 0.02), "grades")
end)

t.test("profile: a ridge becomes a tunnel", function()
	local s, ground, water = line(function(x) return (x >= 400 and x <= 600) and 40 or 0 end)
	local r = profile.fit(s, ground, water, 0.02, 8, 12)
	t.eq(spanAt(r, 500), "tunnel", "middle")
	t.ok(gradesWithin(r, s, 0.02), "grades")
end)

t.test("profile: water is bridged straight between the banks", function()
	local inLake = function(x) return x >= 400 and x <= 600 end
	local s, ground, water = line(function(x) return inLake(x) and -5 or 0 end, inLake)
	local r = profile.fit(s, ground, water, 0.02, 8, 12)
	t.eq(spanAt(r, 400), "bridge", "start of lake")
	t.eq(spanAt(r, 600), "bridge", "end of lake")
	t.near(r.z[21], 0, 1e-9, "deck at bank height mid-lake")
end)
```

- [ ] **Step 3: Run it to see it fail**

Run: `just test`
Expected: the five `profile:` tests FAIL (module missing).

- [ ] **Step 4: Implement**

`C/planner/profile.tl`:

```teal
local profile : PgraceRailRouterProfile = {}

local type Span = PgraceRailRouterProfile.Span
local type Result = PgraceRailRouterProfile.Result

function profile.fit(s : {number}, ground : {number}, water : {boolean}, maxGrade : number, bridgeAbove : number,
		tunnelBelow : number) : Result
	local n = #s
	-- What the track would like to follow: the ground, and over water a straight line between the banks.
	local target : {number} = {}
	local i = 1
	while i <= n do
		if water[i] then
			local j = i
			while j < n and water[j + 1] do
				j = j + 1
			end
			local left : number = nil
			local right : number = nil
			if i > 1 then
				left = ground[i - 1]
			end
			if j < n then
				right = ground[j + 1]
			end
			for k = i, j do
				if left ~= nil and right ~= nil then
					target[k] = left + (right - left) * (s[k] - s[i - 1]) / (s[j + 1] - s[i - 1])
				else
					target[k] = left or right or ground[k]
				end
			end
			i = j + 1
		else
			target[i] = ground[i]
			i = i + 1
		end
	end
	-- Forward then backward, each sample clamped to its neighbour ± the grade limit: afterwards every pair is within
	-- it.
	local z : {number} = {}
	for k = 1, n do
		z[k] = target[k]
	end
	for k = 2, n do
		local limit = maxGrade * (s[k] - s[k - 1])
		z[k] = math.max(z[k - 1] - limit, math.min(z[k - 1] + limit, z[k]))
	end
	for k = n - 1, 1, -1 do
		local limit = maxGrade * (s[k + 1] - s[k])
		z[k] = math.max(z[k + 1] - limit, math.min(z[k + 1] + limit, z[k]))
	end
	local kinds : {string} = {}
	local maxG = 0.0
	for k = 1, n do
		if water[k] or z[k] - ground[k] > bridgeAbove then
			kinds[k] = "bridge"
		elseif ground[k] - z[k] > tunnelBelow then
			kinds[k] = "tunnel"
		else
			kinds[k] = "ground"
		end
		if k > 1 and s[k] > s[k - 1] then
			maxG = math.max(maxG, math.abs(z[k] - z[k - 1]) / (s[k] - s[k - 1]))
		end
	end
	local spans : {Span} = {}
	local start = 1
	for k = 2, n + 1 do
		if k > n or kinds[k] ~= kinds[start] then
			local stop = s[n]
			if k <= n then
				stop = s[k]
			end
			table.insert(spans, { kind = kinds[start], s0 = s[start], s1 = stop })
			start = k
		end
	end
	return { z = z, spans = spans, maxGrade = maxG }
end

return profile
```

- [ ] **Step 5: Run check and test**

Run: `just check && just test`
Expected: `0 error(s)`, then `37 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add -A mod tests
git commit -m "feat: height profile with bridges and tunnels

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: `route` (the planner, step by step)

**Files:**
- Create: `D/planner/route.d.tl`, `C/planner/route.tl`, `tests/route_test.lua`
- Modify: `M/tealdef/pgrace_rail_router_def.d.tl`

- [ ] **Step 1: Type definition**

`D/planner/route.d.tl`:

```teal
-- Plans a double-track line through the stops in order: a station site for each town, then one leg between each
-- pair (grid search, curves, heights). Pure (no api.*); spread over frames with start/step.
global record PgraceRailRouterRoute
	record Input
		grid : PgraceRailRouterGrid.Grid
		-- The towns to stop at, in order along the line.
		stops : {PgraceRailRouterCorridor.Town}
		weights : PgraceRailRouterModes.Weights
		-- Platform length in metres.
		platformLength : number
	end

	record Station
		town : PgraceRailRouterCorridor.Town
		site : PgraceRailRouterStations.Site
		-- Ground height at the station's centre.
		z : number
	end

	record Leg
		pieces : {PgraceRailRouterSmooth.Piece}
		samples : {PgraceRailRouterSmooth.Sample}
		-- Track height at each sample.
		z : {number}
		spans : {PgraceRailRouterProfile.Span}
		length : number
		minRadius : number
		maxGrade : number
	end

	record Summary
		-- Metres of line, platforms included.
		length : number
		bridges : integer
		bridgeLength : number
		tunnels : integer
		tunnelLength : number
		maxGrade : number
		-- The tightest curve's radius in metres; math.huge if the line is straight.
		minRadius : number
		-- Our own price estimate for both tracks (bridges and tunnels included, stations not).
		estimate : number
	end

	record Plan
		ok : boolean
		-- Why the plan failed: "no_stops", "no_site" or "no_path"; nil when ok.
		failure : string
		-- The town for no_site; the two ends of the leg for no_path.
		failureTowns : {string}
		platformLength : number
		stations : {Station}
		legs : {Leg}
		summary : Summary
	end

	-- Work in progress. The fields are internal.
	record Job
		input : Input
		-- "sites", "legs" or "done"
		phase : string
		siteIndex : integer
		legIndex : integer
		search : PgraceRailRouterGrid.Search
		result : Plan
	end

	start : function(input : Input) : Job
	-- One unit of work: a station site, or up to maxExpansions cells of a leg's search. true once the plan is
	-- finished (whether it succeeded or not).
	step : function(job : Job, maxExpansions : integer) : boolean
	-- Share of the work done, 0 to 1.
	progress : function(job : Job) : number
	-- The plan; complete once step has returned true.
	plan : function(job : Job) : Plan
end
```

Append to the registry:

```teal
require "gui.pgrace_rail_router.planner.route"
```

- [ ] **Step 2: Write the failing test**

`tests/route_test.lua`:

```lua
local t = ...
local grid = t.requireTl("gui/pgrace_rail_router/planner/grid.tl")
local route = t.requireTl("gui/pgrace_rail_router/planner/route.tl")

local W = { maxGrade = 0.085, minRadius = 220, slopePenalty = 3, bridgeFactor = 6, turnPenalty = 20,
	roadCrossing = 50, trackCrossing = 400, costPerMetre = 360, bridgeCostFactor = 5, tunnelCostFactor = 8,
	bridgeAbove = 8, tunnelBelow = 12 }

local function town(id, name, x, y)
	return { id = id, name = name, pos = { x = x, y = y } }
end

-- x from -1000 to 7000, y from -1500 to 1500, 100 m cells.
local function flatGrid()
	return grid.new(-1000, -1500, 100, 81, 31)
end

local function run(g, stops)
	local job = route.start({ grid = g, stops = stops, weights = W, platformLength = 160 })
	local steps = 0
	while not route.step(job, 500) do
		steps = steps + 1
		assert(steps < 100000, "runaway")
	end
	return route.plan(job), job
end

local ABC = { town(1, "A", 0, 0), town(2, "B", 3000, 0), town(3, "C", 6000, 0) }

t.test("route: three towns in a row on flat ground", function()
	local plan = run(flatGrid(), ABC)
	t.ok(plan.ok, "ok")
	t.eq(#plan.stations, 3, "stations")
	t.eq(#plan.legs, 2, "legs")
	for _, station in ipairs(plan.stations) do
		t.near(station.site.distance, 0, 1e-9, station.town.name .. " at its centre")
	end
	-- Two legs of 3000 − 160 m between platform ends, plus three platforms.
	t.near(plan.summary.length, 2 * 2840 + 3 * 160, 1, "length")
	t.eq(plan.summary.bridges, 0, "bridges")
	t.eq(plan.summary.tunnels, 0, "tunnels")
	t.near(plan.summary.maxGrade, 0, 1e-9, "grade")
	t.eq(plan.summary.minRadius, math.huge, "straight")
	t.near(plan.summary.estimate, plan.summary.length * 360, 1, "estimate")
end)

t.test("route: a built-up centre moves the station", function()
	local g = flatGrid()
	for iy = 1, 31 do
		for ix = 1, 81 do
			local c = grid.centre(g, ix, iy)
			local dx, dy = c.x - 3000, c.y
			if math.sqrt(dx * dx + dy * dy) <= 300 then
				g.blocked[grid.index(g, ix, iy)] = true
			end
		end
	end
	local plan = run(g, ABC)
	t.ok(plan.ok, "ok")
	t.ok(plan.stations[2].site.distance > 0, "moved")
end)

t.test("route: a wall with no gap means no path", function()
	local g = flatGrid()
	for iy = 1, 31 do
		g.blocked[grid.index(g, 26, iy)] = true -- x = 1500
	end
	local plan = run(g, { ABC[1], ABC[2] })
	t.ok(not plan.ok, "failed")
	t.eq(plan.failure, "no_path", "reason")
	t.eq(plan.failureTowns[1], "A", "from")
	t.eq(plan.failureTowns[2], "B", "to")
end)

t.test("route: no room anywhere means no site", function()
	local g = flatGrid()
	for i = 1, 81 * 31 do
		g.blocked[i] = true
	end
	local plan = run(g, ABC)
	t.eq(plan.failure, "no_site", "reason")
	t.eq(plan.failureTowns[1], "A", "town")
end)

t.test("route: fewer than two stops", function()
	local plan = run(flatGrid(), { ABC[1] })
	t.eq(plan.failure, "no_stops", "reason")
end)

t.test("route: progress runs from 0 to 1", function()
	local job = route.start({ grid = flatGrid(), stops = ABC, weights = W, platformLength = 160 })
	t.near(route.progress(job), 0, 1e-9, "start")
	local last = 0
	while not route.step(job, 50) do
		local p = route.progress(job)
		t.ok(p >= last - 1e-9, "never goes back")
		last = p
	end
	t.near(route.progress(job), 1, 1e-9, "end")
end)
```

- [ ] **Step 3: Run it to see it fail**

Run: `just test`
Expected: the six `route:` tests FAIL (module missing).

- [ ] **Step 4: Implement**

`C/planner/route.tl`:

```teal
local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo
local grid = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/grid.tl" as PgraceRailRouterGrid
local stations = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/stations.tl" as PgraceRailRouterStations
local smooth = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/smooth.tl" as PgraceRailRouterSmooth
local profile = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/profile.tl" as PgraceRailRouterProfile

local route : PgraceRailRouterRoute = {}

local type Pt = PgraceRailRouterGeo.Pt
local type Town = PgraceRailRouterCorridor.Town
local type Input = PgraceRailRouterRoute.Input
local type Station = PgraceRailRouterRoute.Station
local type Leg = PgraceRailRouterRoute.Leg
local type Summary = PgraceRailRouterRoute.Summary
local type Plan = PgraceRailRouterRoute.Plan
local type Job = PgraceRailRouterRoute.Job

-- Straight track before and after each platform, so trains run in line with it (metres).
local APPROACH = 100.0
-- Most height change a station's run may have (metres).
local MAX_STATION_RELIEF = 10.0
-- How far from a town's centre to look for room for its station (metres).
local MAX_STATION_RADIUS = 1500.0
-- Spacing of the height samples along the track (metres).
local SAMPLE_STEP = 25.0
-- Grid paths are simplified to within this share of a cell before the curves are fitted.
local SIMPLIFY_SHARE = 0.75
-- For progress: a station site counts as 1 unit of work, a leg as this many.
local LEG_WEIGHT = 10

-- The direction of travel at stop i: from the previous stop towards the next.
local function stopDir(stops : {Town}, i : integer) : Pt
	local prev = stops[i - 1] or stops[i]
	local next = stops[i + 1] or stops[i]
	return geo.norm(geo.sub(next.pos, prev.pos))
end

-- Where a station's platforms end, and where its straight approach ends, on its leaving side (forward = true) or
-- its arriving side.
local function stationEnds(input : Input, station : Station, forward : boolean) : Pt, Pt
	local sign = forward and 1 or -1
	local half = input.platformLength / 2
	local c, d = station.site.centre, station.site.dir
	return geo.add(c, geo.scale(d, sign * half)), geo.add(c, geo.scale(d, sign * (half + APPROACH)))
end

local function fail(job : Job, failure : string, towns : {string}) : boolean
	job.result.ok = false
	job.result.failure = failure
	job.result.failureTowns = towns
	job.phase = "done"
	return true
end

local function buildLeg(input : Input, a : Station, b : Station, path : {Pt}) : Leg
	local g, w = input.grid, input.weights
	local aEnd = stationEnds(input, a, true)
	local bEnd = stationEnds(input, b, false)
	-- path runs from a's approach to b's; add the platform ends, and keep both approach points so the line leaves
	-- and enters the platforms straight.
	local middle = smooth.simplify(path, g.cell * SIMPLIFY_SHARE)
	local pts : {Pt} = { aEnd }
	for __, p in ipairs(middle) do
		table.insert(pts, p)
	end
	table.insert(pts, bEnd)
	local fixed : {boolean} = {}
	fixed[2], fixed[#pts - 1] = true, true
	local fitted = smooth.fillet(pts, w.minRadius, fixed)
	local samples = smooth.sample(fitted.pieces, SAMPLE_STEP)
	local s : {number} = {}
	local ground : {number} = {}
	local water : {boolean} = {}
	for i, sample in ipairs(samples) do
		s[i] = sample.s
		ground[i] = grid.heightAt(g, sample.p)
		water[i] = grid.waterAt(g, sample.p)
	end
	local fit = profile.fit(s, ground, water, w.maxGrade, w.bridgeAbove, w.tunnelBelow)
	local length = 0.0
	if #s > 0 then
		length = s[#s]
	end
	return { pieces = fitted.pieces, samples = samples, z = fit.z, spans = fit.spans, length = length,
		minRadius = fitted.minRadius, maxGrade = fit.maxGrade }
end

local function summarise(input : Input, plan : Plan) : Summary
	local w = input.weights
	local sum : Summary = { length = 0, bridges = 0, bridgeLength = 0, tunnels = 0, tunnelLength = 0, maxGrade = 0,
		minRadius = math.huge, estimate = 0 }
	for __, leg in ipairs(plan.legs) do
		sum.length = sum.length + leg.length
		sum.maxGrade = math.max(sum.maxGrade, leg.maxGrade)
		sum.minRadius = math.min(sum.minRadius, leg.minRadius)
		for __, span in ipairs(leg.spans) do
			local l = span.s1 - span.s0
			local factor = 1.0
			if span.kind == "bridge" then
				sum.bridges = sum.bridges + 1
				sum.bridgeLength = sum.bridgeLength + l
				factor = w.bridgeCostFactor
			elseif span.kind == "tunnel" then
				sum.tunnels = sum.tunnels + 1
				sum.tunnelLength = sum.tunnelLength + l
				factor = w.tunnelCostFactor
			end
			sum.estimate = sum.estimate + l * w.costPerMetre * factor
		end
	end
	local platforms = #plan.stations * input.platformLength
	sum.length = sum.length + platforms
	sum.estimate = sum.estimate + platforms * w.costPerMetre
	return sum
end

function route.start(input : Input) : Job
	local job : Job = { input = input, phase = "sites", siteIndex = 1, legIndex = 1,
		result = { ok = true, failureTowns = {}, platformLength = input.platformLength, stations = {}, legs = {} } }
	if #input.stops < 2 then
		fail(job, "no_stops", {})
	end
	return job
end

function route.step(job : Job, maxExpansions : integer) : boolean
	local input, plan = job.input, job.result
	if job.phase == "done" then
		return true
	end
	if job.phase == "sites" then
		local i = job.siteIndex
		local town = input.stops[i]
		local site = stations.find(input.grid, town.pos, stopDir(input.stops, i),
			input.platformLength + 2 * APPROACH, MAX_STATION_RELIEF, MAX_STATION_RADIUS)
		if site == nil then
			return fail(job, "no_site", { town.name })
		end
		table.insert(plan.stations, { town = town, site = site, z = grid.heightAt(input.grid, site.centre) })
		job.siteIndex = i + 1
		if job.siteIndex > #input.stops then
			job.phase = "legs"
		end
		return false
	end
	local a, b = plan.stations[job.legIndex], plan.stations[job.legIndex + 1]
	if job.search == nil then
		local __, aApproach = stationEnds(input, a, true)
		local ___, bApproach = stationEnds(input, b, false)
		job.search = grid.startSearch(input.grid, aApproach, bApproach, a.site.dir, b.site.dir, input.weights)
		return false
	end
	if not grid.stepSearch(job.search, maxExpansions) then
		return false
	end
	local path = grid.path(job.search)
	job.search = nil
	if path == nil then
		return fail(job, "no_path", { a.town.name, b.town.name })
	end
	table.insert(plan.legs, buildLeg(input, a, b, path))
	job.legIndex = job.legIndex + 1
	if job.legIndex > #plan.stations - 1 then
		plan.summary = summarise(input, plan)
		job.phase = "done"
		return true
	end
	return false
end

function route.progress(job : Job) : number
	if job.phase == "done" then
		return 1
	end
	local n = #job.input.stops
	local total = n + LEG_WEIGHT * math.max(1, n - 1)
	local done : number = job.siteIndex - 1
	if job.phase == "legs" then
		done = n + LEG_WEIGHT * (job.legIndex - 1)
		if job.search ~= nil then
			done = done + LEG_WEIGHT * grid.progress(job.search)
		end
	end
	return math.min(1, done / total)
end

function route.plan(job : Job) : Plan
	return job.result
end

return route
```

- [ ] **Step 5: Run check and test**

Run: `just check && just test`
Expected: `0 error(s)`, then `43 passed, 0 failed`. If `progress runs from 0 to 1` fails on "never goes back", check that a finished leg (`search = nil`, `legIndex + 1`) counts the same as a search at `progress = 1`.

- [ ] **Step 6: Commit**

```bash
git add -A mod tests
git commit -m "feat: route planner from stops to a full plan

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: `survey` (engine reads)

This module calls the game, so it is only type-checked here; it's verified in-game in Task 13.

**Files:**
- Create: `D/survey.d.tl`, `C/survey.tl`
- Modify: `M/tealdef/pgrace_rail_router_def.d.tl`

- [ ] **Step 1: Type definition**

`D/survey.d.tl`:

```teal
-- Engine reads: the towns, the track types, the year, and a grid of the area around the stops (terrain, water,
-- constructions, roads and track), spread over frames. Call start/step from the main thread (react.enqueueJoin).
global record PgraceRailRouterSurvey
	-- A survey in progress. The fields are internal.
	record Job
		grid : PgraceRailRouterGrid.Grid
		tasks : {function()}
		next : integer
		-- Entities already marked (buildings and edges show up in several tiles).
		seen : {integer : boolean}
	end

	-- Every town with its centre, sorted by name.
	towns : function() : {PgraceRailRouterCorridor.Town}
	-- The base track types (catenary variants left out), slowest first.
	trackTypes : function() : {PgraceRailRouterModes.TrackType}
	year : function() : integer
	-- Sets up a grid with `cell`-metre cells over the stops' bounding box, grown by `margin` × its larger side (at
	-- least 2 km). Cells get coarser if the grid would be too large.
	start : function(stops : {PgraceRailRouterCorridor.Town}, cell : number, margin : number) : Job
	-- Works for about budgetUs microseconds (at least one task); true when done. Each task runs in a pcall: a failed
	-- one is logged once and skipped.
	step : function(job : Job, budgetUs : integer) : boolean
	progress : function(job : Job) : number
	grid : function(job : Job) : PgraceRailRouterGrid.Grid
end
```

Append to the registry:

```teal
require "gui.pgrace_rail_router.survey"
```

- [ ] **Step 2: Implement**

`C/survey.tl`:

```teal
local grid = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/grid.tl" as PgraceRailRouterGrid

local survey : PgraceRailRouterSurvey = {}

local type Pt = PgraceRailRouterGeo.Pt
local type Town = PgraceRailRouterCorridor.Town
local type TrackType = PgraceRailRouterModes.TrackType
local type Grid = PgraceRailRouterGrid.Grid
local type Job = PgraceRailRouterSurvey.Job

local LOG_PREFIX = "[rail_router] "
-- Cells within this distance of a building or other construction are blocked (metres).
local BUILDING_BUFFER = 30.0
-- At least this much room around the stops (metres).
local MIN_MARGIN = 2000.0
-- Larger grids get coarser cells instead (memory and search time).
local MAX_CELLS = 250000
-- Buildings and edges are looked up in tiles this wide, one tile per task: a single city-wide lookup took 60 ms in
-- Jam Session.
local TILE = 1000.0

local logged : {string : boolean} = {}
local function logOnce(key : string, message : string)
	if not logged[key] then
		logged[key] = true
		debugPrint(LOG_PREFIX .. message)
	end
end

local function boundingBox(entity : Engine.Entity) : Engine.Component.BoundingVolume
	return api.engine.getComponent(entity, api.type.ComponentType.BOUNDING_VOLUME) as Engine.Component.BoundingVolume
end

function survey.towns() : {Town}
	local result : {Town} = {}
	api.engine.forEachEntityWithComponent(function(town : Engine.Entity)
		local ok, err = pcall(function() : boolean
			local bv = boundingBox(town)
			if bv ~= nil then
				table.insert(result, { id = town, name = api.engine.util.getEntityName(town),
					pos = { x = 0.5 * (bv.bbox.min.x + bv.bbox.max.x), y = 0.5 * (bv.bbox.min.y + bv.bbox.max.y) } })
			end
			return true
		end)
		if not ok then
			logOnce("town", "town " .. tostring(town) .. ": " .. tostring(err))
		end
	end, api.type.ComponentType.TOWN)
	table.sort(result, function(a : Town, b : Town) : boolean
		return a.name < b.name
	end)
	return result
end

function survey.trackTypes() : {TrackType}
	local result : {TrackType} = {}
	local rep = api.res.streetTemplateRep
	local trackRoad = api.type["enum"].RoadType.TRACK
	for id, name in pairs(rep.getAll()) do
		local ok, err = pcall(function() : boolean
			local tpl = rep.get(id)
			if tpl ~= nil and tpl.roadType == trackRoad and not name:find("catenary", 1, true) then
				local speed = 0.0
				for __, lane in ipairs(tpl.laneConfigs) do
					speed = math.max(speed, lane.speed)
				end
				local label = name
				if tpl.description ~= nil and tpl.description.name ~= nil then
					label = tpl.description.name
				end
				local yearFrom, yearTo = 0, 0
				if tpl.availability ~= nil then
					yearFrom, yearTo = tpl.availability.yearFrom, tpl.availability.yearTo
				end
				table.insert(result, { name = name, label = label, cost = tpl.cost, speed = speed,
					maxSlopeBuild = tpl.maxSlopeBuild, minCurveRadiusBuild = tpl.minCurveRadiusBuild,
					trackDistance = tpl.trackDistance, yearFrom = yearFrom, yearTo = yearTo })
			end
			return true
		end)
		if not ok then
			logOnce("track", "track type " .. tostring(name) .. ": " .. tostring(err))
		end
	end
	table.sort(result, function(a : TrackType, b : TrackType) : boolean
		return a.speed < b.speed
	end)
	return result
end

function survey.year() : integer
	return api.engine.util.getYear()
end

-- Marks the cells whose centres are nearest to the box's corners and everything between (the box is world
-- coordinates). Boxes wholly outside the grid are skipped.
local function markBox(g : Grid, x0 : number, y0 : number, x1 : number, y1 : number, cells : {boolean})
	local half = g.cell / 2
	if x1 < g.x0 - half or y1 < g.y0 - half or x0 > g.x0 + (g.nx - 1) * g.cell + half
			or y0 > g.y0 + (g.ny - 1) * g.cell + half then
		return
	end
	local ax, ay = grid.cellOf(g, { x = x0, y = y0 })
	local bx, by = grid.cellOf(g, { x = x1, y = y1 })
	for iy = ay, by do
		for ix = ax, bx do
			cells[grid.index(g, ix, iy)] = true
		end
	end
end

-- Marks the cells along the straight line from a to b.
local function markLine(g : Grid, a : Pt, b : Pt, cells : {boolean})
	local dx, dy = b.x - a.x, b.y - a.y
	local length = math.sqrt(dx * dx + dy * dy)
	local steps = math.max(1, math.ceil(length / (g.cell / 2)))
	for k = 0, steps do
		local p : Pt = { x = a.x + dx * k / steps, y = a.y + dy * k / steps }
		if grid.inside(g, p) then
			local ix, iy = grid.cellOf(g, p)
			cells[grid.index(g, ix, iy)] = true
		end
	end
end

local function surveyRow(g : Grid, iy : integer)
	local terrain = api.engine.terrain
	for ix = 1, g.nx do
		local c = grid.centre(g, ix, iy)
		local v = api.type.Vec2f.new(c.x, c.y)
		local i = grid.index(g, ix, iy)
		if not terrain.isValidCoordinate(v) then
			g.blocked[i] = true
		else
			g.height[i] = terrain.getHeightAt(v)
			g.water[i] = terrain.isOnWater(v)
		end
	end
end

local function markConstruction(job : Job, entity : Engine.Entity)
	local bv = boundingBox(entity)
	if bv == nil then
		-- Town buildings may have no box of their own: use their construction's.
		local tb = api.engine.getComponent(entity, api.type.ComponentType.TOWN_BUILDING) as Engine.Component.TownBuilding
		if tb ~= nil then
			bv = boundingBox(tb.construction)
		end
	end
	if bv ~= nil then
		markBox(job.grid, bv.bbox.min.x - BUILDING_BUFFER, bv.bbox.min.y - BUILDING_BUFFER,
			bv.bbox.max.x + BUILDING_BUFFER, bv.bbox.max.y + BUILDING_BUFFER, job.grid.blocked)
	end
end

local function markEdge(job : Job, entity : Engine.Entity)
	local edge = api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
	if edge == nil or edge.type == api.type["enum"].BaseEdgeType.TUNNEL then
		return
	end
	local n0 = api.engine.getComponent(edge.node0, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
	local n1 = api.engine.getComponent(edge.node1, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
	if n0 == nil or n1 == nil then
		return
	end
	local street = api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE_STREET)
	local cells = job.grid.track
	if street ~= nil then
		cells = job.grid.road
	end
	markLine(job.grid, { x = n0.position.x, y = n0.position.y }, { x = n1.position.x, y = n1.position.y }, cells)
end

local function surveyTile(job : Job, cx : number, cy : number)
	local centre = api.type.Vec2f.new(cx, cy)
	-- Covers the tile's corners (half the diagonal is 0.71 tiles).
	local radius = TILE * 0.75
	local octree = api.engine.util.octree
	for __, kind in ipairs({ api.type.ComponentType.CONSTRUCTION, api.type.ComponentType.TOWN_BUILDING }) do
		for __, entity in ipairs(octree.findEntitiesInCircle(centre, radius, kind)) do
			if not job.seen[entity] then
				job.seen[entity] = true
				local ok, err = pcall(function() : boolean
					markConstruction(job, entity)
					return true
				end)
				if not ok then
					logOnce("construction", "construction " .. tostring(entity) .. ": " .. tostring(err))
				end
			end
		end
	end
	for __, entity in ipairs(octree.findEntitiesInCircle(centre, radius, api.type.ComponentType.BASE_EDGE)) do
		if not job.seen[entity] then
			job.seen[entity] = true
			local ok, err = pcall(function() : boolean
				markEdge(job, entity)
				return true
			end)
			if not ok then
				logOnce("edge", "edge " .. tostring(entity) .. ": " .. tostring(err))
			end
		end
	end
end

function survey.start(stops : {Town}, cell : number, margin : number) : Job
	local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
	for __, stop in ipairs(stops) do
		minX, maxX = math.min(minX, stop.pos.x), math.max(maxX, stop.pos.x)
		minY, maxY = math.min(minY, stop.pos.y), math.max(maxY, stop.pos.y)
	end
	local pad = math.max(MIN_MARGIN, margin * math.max(maxX - minX, maxY - minY))
	minX, maxX, minY, maxY = minX - pad, maxX + pad, minY - pad, maxY + pad
	local nx = math.floor((maxX - minX) / cell) + 1
	local ny = math.floor((maxY - minY) / cell) + 1
	while nx * ny > MAX_CELLS do
		cell = cell * 1.25
		nx = math.floor((maxX - minX) / cell) + 1
		ny = math.floor((maxY - minY) / cell) + 1
	end
	local job : Job = { grid = grid.new(minX, minY, cell, nx, ny), tasks = {}, next = 1, seen = {} }
	for iy = 1, ny do
		table.insert(job.tasks, function()
			surveyRow(job.grid, iy)
		end)
	end
	local tx = minX
	while tx < maxX do
		local ty = minY
		while ty < maxY do
			local cx, cy = tx + TILE / 2, ty + TILE / 2
			table.insert(job.tasks, function()
				surveyTile(job, cx, cy)
			end)
			ty = ty + TILE
		end
		tx = tx + TILE
	end
	debugPrint(LOG_PREFIX .. "survey: " .. nx .. " × " .. ny .. " cells of " .. cell .. " m, " .. #job.tasks .. " tasks")
	return job
end

function survey.step(job : Job, budgetUs : integer) : boolean
	local clock = api.type.Clock.new()
	repeat
		if job.next > #job.tasks then
			return true
		end
		local task = job.tasks[job.next]
		job.next = job.next + 1
		local ok, err = pcall(function() : boolean
			task()
			return true
		end)
		if not ok then
			logOnce("task", "survey task: " .. tostring(err))
		end
	until clock:getTime() >= budgetUs
	return job.next > #job.tasks
end

function survey.progress(job : Job) : number
	if #job.tasks == 0 then
		return 1
	end
	return (job.next - 1) / #job.tasks
end

function survey.grid(job : Job) : Grid
	return job.grid
end

return survey
```

- [ ] **Step 3: Type-check**

Run: `just check`
Expected: `0 error(s)`. Likely complaints and their fixes, if they come up:
- `Engine.Entity` is not `integer` (in `id = town` or `job.seen[entity]`): cast with `town as integer` /
  `entity as integer`.
- `getAll` returns names typed as something other than `string`: wrap with `tostring(name)`.
- A component type is missing from `api.type.ComponentType` (for example `BASE_NODE`): grep
  `api/tealdef/api/engine.d.tl` for the right name; don't remove the read.

- [ ] **Step 4: Run the tests (nothing should change)**

Run: `just test`
Expected: `43 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add -A mod
git commit -m "feat: survey towns, track types and the area between stops

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: `preview` (the route on the map)

**Files:**
- Create: `D/preview.d.tl`, `C/preview.tl`
- Modify: `M/tealdef/pgrace_rail_router_def.d.tl`

The map-action code is Jam Session's `FlowAction` (window.script.tl lines ~520–660 there), reduced to one drawing.
Read AGENTS.md "Drawing on the map" first: one action key per drawing, `setActiveOwnerOverride` cleared on unmount,
filters at module level, `accessNotificationCacheFn` left nil.

- [ ] **Step 1: Type definition**

`D/preview.d.tl`:

```teal
-- Draws a plan on the map: one static arrow per ~200 m of track (green on the ground, blue on bridges, orange in
-- tunnels) and a white one along each platform, and frames the camera on it once.
global record PgraceRailRouterPreview
	record Params is IRecipeParamWithMeta
		plan : PgraceRailRouterRoute.Plan
		-- Different for each plan: part of the map action's key, so a new plan rebinds it.
		generation : integer
		-- The window's game context (window container and tool stack).
		baseCtx : GameContext
	end

	RouteAction : Recipe<Params>
end
```

Append to the registry:

```teal
require "gui.pgrace_rail_router.preview"
```

- [ ] **Step 2: Implement**

`C/preview.tl`:

```teal
local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local game_react_globals = ug_require "::/gui/main/game_react_globals.tl" as GameReactGlobals
local selector_react_util = ug_require "::/gui/main/selector_react_util.tl" as SelectorReactUtil
local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo

local preview : PgraceRailRouterPreview = {}

local type Plan = PgraceRailRouterRoute.Plan
local type Leg = PgraceRailRouterRoute.Leg
local type Params = PgraceRailRouterPreview.Params
local type FlowData = LayerConfig.CargoFlowRenderableConfig.FlowData

local LOG_PREFIX = "[rail_router] "
local ACTION_KEY = "pgrace_rail_router_route"
-- Arrows are drawn as arcs rising about 6% of their length, so long stretches are split into chords this long.
local CHORD = 200.0
-- Arrows sit this far above the track height, so the ground doesn't hide them (metres).
local LIFT = 3.0
-- Camera framing: distance as a multiple of the route's extent, clamped (focusPosition caps it near 4,055 m).
local CAMERA_FACTOR = 1.2
local CAMERA_MIN = 500.0
local CAMERA_MAX = 4000.0

local GROUND : {number} = { 0.35, 0.8, 0.35 }
local BRIDGE : {number} = { 0.3, 0.6, 1.0 }
local TUNNEL : {number} = { 1.0, 0.6, 0.2 }
local STATION : {number} = { 1.0, 1.0, 1.0 }
local KIND_COLOURS : {string : {number}} = { ground = GROUND, bridge = BRIDGE, tunnel = TUNNEL }

-- The base cargo-flow colours are a gradient with this many stops; ours repeat one colour as often.
local layerColors = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/layers/layer_colors.gres")).data as LayerColors
local GRADIENT_STOPS = math.max(1, #layerColors.CargoFlow.Consumers3D.Actual)

local loggedJoinError : {string : boolean} = {}
-- react.enqueueJoin runs without a pcall, and a join can run just after its recipe unmounted.
local function safeJoin(fn : function(), scope : string)
	react.enqueueJoin(function()
		local ok, err = pcall(function() : boolean
			fn()
			return true
		end)
		if not ok and not loggedJoinError[scope] then
			loggedJoinError[scope] = true
			debugPrint(LOG_PREFIX .. scope .. " error: " .. tostring(err))
		end
	end, scope)
end

local function colours(rgb : {number}) : {Vec4f}
	local list : {Vec4f} = {}
	for i = 1, GRADIENT_STOPS do
		list[i] = api.type.Vec4f.new(rgb[1], rgb[2], rgb[3], 1.0)
	end
	return list
end

local function kindAt(leg : Leg, s : number) : string
	for __, span in ipairs(leg.spans) do
		if s >= span.s0 and s <= span.s1 then
			return span.kind
		end
	end
	return "ground"
end

local function makeLayerConfig(plan : Plan) : LayerConfig
	local passenger = api.res.cargoTypeRep.getPassengerCargoTypeId()
	local flows : {FlowData} = {}
	local function add(ax : number, ay : number, az : number, bx : number, by : number, bz : number, rgb : {number})
		local flow = api.type.LayerConfig.CargoFlowRenderableConfig.FlowData.new()
		flow.from = api.type.Vec3f.new(ax, ay, az + LIFT)
		flow.to = api.type.Vec3f.new(bx, by, bz + LIFT)
		flow.speed = 0
		flow.arrowColors = colours(rgb)
		flow.cargoIconAlpha = 0
		flow.cargoTypes = { passenger }
		table.insert(flows, flow)
	end
	for __, leg in ipairs(plan.legs) do
		local n = #leg.samples
		local i = 1
		while i < n do
			local j = i
			while j < n and leg.samples[j].s - leg.samples[i].s < CHORD do
				j = j + 1
			end
			local p, q = leg.samples[i].p, leg.samples[j].p
			local kind = kindAt(leg, 0.5 * (leg.samples[i].s + leg.samples[j].s))
			add(p.x, p.y, leg.z[i], q.x, q.y, leg.z[j], KIND_COLOURS[kind] or GROUND)
			i = j
		end
	end
	for __, station in ipairs(plan.stations) do
		local half = geo.scale(station.site.dir, plan.platformLength / 2)
		local a, b = geo.sub(station.site.centre, half), geo.add(station.site.centre, half)
		add(a.x, a.y, station.z, b.x, b.y, station.z, STATION)
	end
	local cargoFlow = api.type.LayerConfig.CargoFlowRenderableConfig.new()
	cargoFlow.flowData = flows
	local layerConfig = api.type.LayerConfig.new()
	layerConfig.cargoFlowRenderableConfig = cargoFlow
	return layerConfig
end

-- Main thread only.
local function frameCamera(plan : Plan)
	local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
	local z = 0.0
	for __, station in ipairs(plan.stations) do
		local c = station.site.centre
		minX, maxX = math.min(minX, c.x), math.max(maxX, c.x)
		minY, maxY = math.min(minY, c.y), math.max(maxY, c.y)
		z = z + station.z / #plan.stations
	end
	if #plan.stations == 0 then
		return
	end
	local extent = math.max(maxX - minX, maxY - minY)
	local distance = math.min(CAMERA_MAX, math.max(CAMERA_MIN, extent * CAMERA_FACTOR))
	api.gui.camera.focusPosition(api.type.Vec3f.new(0.5 * (minX + maxX), 0.5 * (minY + maxY), z), distance)
end

-- The renderer API has this, but the type definitions don't. Clearing it with `false` hands the map back.
local record ActiveOwnerApi
	setActiveOwnerOverride : function(ReactRefWrap | boolean)
end

-- The selector reads filters from the game context; the window gets none. Module-level, not hooks: the renderer
-- calls into the action for a moment after our recipe unmounts (AGENTS.md, Jam Session).
local mapFilters : GameContext.Filters = {
	menuFilter = { enabledItems = {}, disabledItems = {}, disabledParams = {} },
	vehicleFilter = { enabledVehicles = {}, disabledVehicles = {} },
	protectedEntities = {},
	selectorEntityFilter = {},
}
local record FiltersRef
	get : function(FiltersRef) : GameContext.Filters
	set : function(FiltersRef, GameContext.Filters)
end
local mapFiltersRef : FiltersRef = {
	get = function(__ : FiltersRef) : GameContext.Filters return mapFilters end,
	set = function(__ : FiltersRef, filters : GameContext.Filters) mapFilters = filters end,
}

-- No accessNotificationCacheFn: a lookup there runs on worker threads and crashed Jam Session twice.
local function mapGameContext(base : GameContext) : GameContext
	return {
		rendererComponent = game_react_globals.getDefaultRendererComponent(),
		windowContainer = base.windowContainer,
		toolStack = base.toolStack,
		filters = mapFiltersRef as any as ReactRefT<GameContext.Filters>,
	} as GameContext
end

local record Cache
	key : string
	action : function() : TreeNodeId
end

preview.RouteAction = react.RegisterRecipe("PgraceRailRouterRouteAction", function(params : Params) : TreeNodeId
	local gameCtx = mapGameContext(params.baseCtx)
	local key = ACTION_KEY .. ":" .. tostring(params.generation)
	local cacheRef : ReactRefT<Cache> = react.useRef(nil)
	local frameRef : ReactRefT<boolean> = react.useRef(false)
	local changed = cacheRef:get() == nil or cacheRef:get().key ~= key
	if changed then
		local ok, layerOrError = pcall(makeLayerConfig, params.plan)
		local action : function() : TreeNodeId = nil
		if ok then
			action = selector_react_util.makeDefaultSelectorAction(gameCtx, layerOrError as LayerConfig)
			frameRef:set(true)
		else
			debugPrint(LOG_PREFIX .. "preview error: " .. tostring(layerOrError))
		end
		cacheRef:set({ key = key, action = action })
	end
	react.onStep(function()
		if frameRef:get() then
			frameRef:set(false)
			safeJoin(function()
				frameCamera(params.plan)
			end, "PgraceRailRouterFrameCamera")
		end
	end)

	local selfRef = react.useAction(gameCtx.rendererComponent, cacheRef:get().action, key)

	local function setOverride(owner : ReactRefWrap | boolean) : boolean
		local rendererComponent = gameCtx.rendererComponent
		if rendererComponent == nil or rendererComponent:hasExpired() then
			return false
		end
		local rc = rendererComponent:get()
		if rc == nil or not rc:getIdentity() then
			return false
		end
		local rcApi = rc:getApi() as any as ActiveOwnerApi
		if rcApi.setActiveOwnerOverride == nil then
			return false
		end
		rcApi.setActiveOwnerOverride(owner)
		return true
	end

	-- Only with an action bound: taking over the map without one would leave it ownerless.
	local function activate()
		if cacheRef:get().action ~= nil then
			setOverride(selfRef)
		end
	end

	react.onMount(activate)
	if changed and selfRef:get() ~= nil then
		activate()
	end
	react.onUnmount(function()
		setOverride(false)
	end)

	return builtin.BoxLayout{ children = {} }
end)

return preview
```

- [ ] **Step 3: Type-check**

Run: `just check`
Expected: `0 error(s)`. If `makeDefaultSelectorAction` wants more arguments, pass `nil` for them (Jam Session passes
`nil` as the third). If the checker rejects the `FlowData` type alias path, find the record's full name with
`grep -n "record CargoFlowRenderableConfig" -B5 "<tf3>/api/tealdef/api/type.d.tl"` and fix the `local type FlowData`
line. If `IRecipeParamWithMeta` or `Recipe<...>` isn't visible from a `.d.tl`, declare `Params` and the recipe
locally in `preview.tl` instead, and export a plain function `routeAction(params) : TreeNodeId` that returns
`RouteAction(params)` wrapped in a `builtin.BoxLayout{ children = { ... } }` (a recipe must return a layout).

- [ ] **Step 4: Commit**

```bash
git add -A mod
git commit -m "feat: draw a planned route on the map

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: The window, button and stylesheet

**Files:**
- Create: `C/window.script.tl`, `C/window.res.lua`, `C/window.css.lua`

- [ ] **Step 1: Register the button**

`C/window.res.lua`:

```lua
function data()
	return {
		type = "react-plugin ::MainModButtonAreaExtension",
		data = {
			filePath = "pgrace_rail_router::/gui/pgrace_rail_router/window.script@RailRouterButton",
		}
	}
end
```

- [ ] **Step 2: Position the window**

`C/window.css.lua` (no size: the window fits its content):

```lua
local ssu = require "::/gui/main/stylesheetutil.lua"

-- Keyed on the window's class: an id selector with a dot didn't apply (Trim the Fat). Docked at the left edge,
-- vertically centred, so the route on the map stays mostly in view.
function data()
	local result = {}
	local a = ssu.makeAdder(result)
	a("Window!pgrace-rail-router", {
		gravity = { 0.0, 0.5 },
		anchorPoint = { 0.0, 0.5 },
		padding = { 0, 0, 0, 16 },
	})
	a("Window!pgrace-rail-router Window::Content", {
		padding = { 8, 12, 12, 12 },
	})
	return result
end
```

- [ ] **Step 3: The window script**

`C/window.script.tl`:

```teal
local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local tool_react_util = ug_require "::/gui/main/tool_react_util.tl" as ToolReactUtil
local game_react_globals = ug_require "::/gui/main/game_react_globals.tl" as GameReactGlobals
local main_mod_button_area = ug_require "::/gui/main/main_mod_button_area.tl" as MainModButtonArea
local modes = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/modes.tl" as PgraceRailRouterModes
local corridor = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/corridor.tl" as PgraceRailRouterCorridor
local route = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/route.tl" as PgraceRailRouterRoute
local survey = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/survey.tl" as PgraceRailRouterSurvey
local preview = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/preview.tl" as PgraceRailRouterPreview

local type Town = PgraceRailRouterCorridor.Town
local type Candidate = PgraceRailRouterCorridor.Candidate
local type TrackType = PgraceRailRouterModes.TrackType
local type Mode = PgraceRailRouterModes.Mode
local type Plan = PgraceRailRouterRoute.Plan
local type ToolParam = ToolReactUtil.IToolParam

local LOG_PREFIX = "[rail_router] "
-- The mod's name, a brand: not translated.
local MOD_NAME = "Rail Router"
local WINDOW_ID = "pgrace_rail_router_window"
local BUTTON_ICON = "::/gui/game_bar/icons/vehicle_train_30.tga"
-- Microseconds of survey or planning work per frame.
local BUDGET_US = 6000
-- Cells a leg's search expands per call between clock checks.
local EXPANSIONS_PER_CALL = 400
local CELL = 100.0
local SURVEY_MARGIN = 0.25
-- Towns adding at most this share of the direct distance are offered as stops.
local DETOUR_BUDGET = 0.15
local PLATFORMS : {integer} = { 80, 120, 160, 240, 320 }

local record Settings
	-- Town entities; -1 for none.
	from : integer
	to : integer
	mode : Mode
	-- Track type name; nil for the mode's default in the current year.
	track : string
	electrified : boolean
	platform : integer
	-- Candidate stops the player unticked, by town id.
	skipped : {integer : boolean}
end

-- Kept between openings until the game restarts or a save is loaded (the window's state starts fresh each time).
local remembered : Settings = { from = -1, to = -1, mode = "cheapest", electrified = true, platform = 160, skipped = {} }

local record GameData
	towns : {Town}
	tracks : {TrackType}
	year : integer
	error : boolean
end

local record Work
	stops : {Town}
	weights : PgraceRailRouterModes.Weights
	platform : integer
	surveyJob : PgraceRailRouterSurvey.Job
	routeJob : PgraceRailRouterRoute.Job
end

local record Progress
	-- "survey" or "plan"
	stage : string
	percent : integer
end

local nextGeneration = 0

local loggedJoinError : {string : boolean} = {}
-- react.enqueueJoin runs without a pcall, and a join can run just after its recipe unmounted (window closed
-- mid-plan): an error there would take down the whole UI.
local function safeJoin(fn : function(), scope : string)
	react.enqueueJoin(function()
		local ok, err = pcall(function() : boolean
			fn()
			return true
		end)
		if not ok and not loggedJoinError[scope] then
			loggedJoinError[scope] = true
			debugPrint(LOG_PREFIX .. scope .. " error: " .. tostring(err))
		end
	end, scope)
end

local function fill(template : string, values : {string : string}) : string
	return (template:gsub("{(%w+)}", function(key : string) : string
		return values[key] or ("{" .. key .. "}")
	end))
end

local function textRow(text : string, class : string) : TreeNodeId
	return builtin.BoxLayout{
		children = {
			builtin.TextView{ meta = { class = class or "font-scale-body" }, text = text },
		},
	}
end

local function formatLength(metres : number) : string
	local ok, text = pcall(api.util.formatLength, metres)
	if ok and text ~= nil then
		return text as string
	end
	return tostring(math.floor(metres + 0.5)) .. " m"
end

local function formatMoney(amount : number) : string
	local ok, text = pcall(api.util.formatMoney, math.floor(amount + 0.5))
	if ok and text ~= nil then
		return text as string
	end
	return tostring(math.floor(amount + 0.5))
end

local function formatPercent(share : number) : string
	return fill(_("{percent}%"), { percent = string.format("%.1f", 100 * share) })
end

local function townById(towns : {Town}, id : integer) : Town
	for __, town in ipairs(towns) do
		if town.id == id then
			return town
		end
	end
	return nil
end

local function trackByName(tracks : {TrackType}, name : string) : TrackType
	for __, track in ipairs(tracks) do
		if track.name == name then
			return track
		end
	end
	return nil
end

local function toInteger(value : integer | number | string) : integer
	local n = tonumber(tostring(value))
	if n == nil then
		return nil
	end
	return math.floor(n)
end

local function labelled(label : string, widget : TreeNodeId) : TreeNodeId
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			builtin.TextView{ meta = { class = "font-scale-body" }, text = label },
			widget,
		},
	}
end

local function townCombo(towns : {Town}, value : integer, onChange : function(integer)) : TreeNodeId
	local items : {TreeNodeId} = {
		builtin.ComboBoxItem{ value = -1, content = builtin.TextView{ text = _("Choose a town") } },
	}
	for __, town in ipairs(towns) do
		table.insert(items, builtin.ComboBoxItem{ value = town.id, content = builtin.TextView{ text = town.name } })
	end
	return builtin.ComboBox{
		value = value,
		items = items,
		onValueChange = function(v : integer | number | string)
			local id = toInteger(v)
			if id ~= nil then
				onChange(id)
			end
		end,
	}
end

local function failureText(plan : Plan) : string
	local towns = plan.failureTowns or {}
	if plan.failure == "no_site" then
		return fill(_("No room for a station near the centre of {town} without demolishing anything."),
			{ town = towns[1] or "?" })
	elseif plan.failure == "no_path" then
		return fill(_("No route found from {from} to {to}."), { from = towns[1] or "?", to = towns[2] or "?" })
	end
	return _("Choose two different towns.")
end

local function resultRows(plan : Plan) : {TreeNodeId}
	local rows : {TreeNodeId} = {}
	local sum = plan.summary
	table.insert(rows, textRow(fill(_("{length} of line · about {cost} for the track (our estimate)"),
		{ length = formatLength(sum.length), cost = formatMoney(sum.estimate) }), "font-scale-body"))
	table.insert(rows, textRow(fill(_("Bridges: {bridges} ({bridgeLength}) · Tunnels: {tunnels} ({tunnelLength})"), {
		bridges = tostring(sum.bridges), bridgeLength = formatLength(sum.bridgeLength),
		tunnels = tostring(sum.tunnels), tunnelLength = formatLength(sum.tunnelLength),
	}), "font-scale-body"))
	local curve = _("no curves")
	if sum.minRadius < math.huge then
		curve = formatLength(sum.minRadius)
	end
	table.insert(rows, textRow(fill(_("Steepest grade {grade} · tightest curve {radius}"),
		{ grade = formatPercent(sum.maxGrade), radius = curve }), "font-scale-body"))
	for __, station in ipairs(plan.stations) do
		table.insert(rows, textRow(fill(_("{town}: station {distance} from the centre"),
			{ town = station.town.name, distance = formatLength(station.site.distance) }), "font-scale-annotation"))
	end
	return rows
end

local record ContentParams
	gameCtx : GameContext
end

local Content = react.RegisterRecipe("PgraceRailRouterContent", function(params : ContentParams) : TreeNodeId
	local dataState = react.useStateLazy(function() : GameData
		local ok, dataOrError = pcall(function() : GameData
			return { towns = survey.towns(), tracks = survey.trackTypes(), year = survey.year(), error = false }
		end)
		if ok then
			return dataOrError as GameData
		end
		debugPrint(LOG_PREFIX .. "read error: " .. tostring(dataOrError))
		return { towns = {}, tracks = {}, year = 0, error = true }
	end)
	local data = dataState:old()
	local settingsState = react.useState(remembered) as ReactStateT<Settings>
	local settings = settingsState:old()
	local planState : ReactStateT<Plan> = react.useState(nil)
	local generationState = react.useState(0) as ReactStateT<integer>
	local showState = react.useState(false) as ReactStateT<boolean>
	local progressState : ReactStateT<Progress> = react.useState(nil)
	local errorState = react.useState(false) as ReactStateT<boolean>
	local workRef : ReactRefT<Work> = react.useRef(nil)
	-- A join is queued and hasn't run yet; at most one at a time.
	local joinQueuedRef : ReactRefT<boolean> = react.useRef(false)

	-- Every settings change drops the shown plan and any work in progress: a plan for other settings would mislead.
	local function update(change : function(Settings))
		local copy : Settings = { from = settings.from, to = settings.to, mode = settings.mode, track = settings.track,
			electrified = settings.electrified, platform = settings.platform, skipped = settings.skipped }
		change(copy)
		remembered = copy
		settingsState:set(copy)
		planState:set(nil)
		showState:set(false)
		workRef:set(nil)
		progressState:set(nil)
		errorState:set(false)
	end

	local fromTown = townById(data.towns, settings.from)
	local toTown = townById(data.towns, settings.to)
	local track = trackByName(data.tracks, settings.track) or modes.defaultTrack(data.tracks, data.year, settings.mode)
	local candidates : {Candidate} = {}
	if fromTown ~= nil and toTown ~= nil and fromTown.id ~= toTown.id then
		candidates = corridor.candidates(fromTown, toTown, data.towns, DETOUR_BUDGET)
	end

	local function findRoute()
		if fromTown == nil or toTown == nil or fromTown.id == toTown.id or track == nil then
			return
		end
		local picked : {Town} = {}
		for __, candidate in ipairs(candidates) do
			if not settings.skipped[candidate.town.id] then
				table.insert(picked, candidate.town)
			end
		end
		workRef:set({ stops = corridor.order(fromTown, toTown, picked), weights = modes.weights(settings.mode, track),
			platform = settings.platform })
		planState:set(nil)
		showState:set(false)
		errorState:set(false)
		progressState:set({ stage = "survey", percent = 0 })
	end

	local function setProgress(stage : string, share : number)
		local percent = math.floor(100 * share)
		local old = progressState:old()
		if old == nil or old.stage ~= stage or old.percent ~= percent then
			progressState:set({ stage = stage, percent = percent })
		end
	end

	-- Engine reads (terrain, octree) and the planner run in joins on the main thread, BUDGET_US per frame, as Jam
	-- Session's scan: the window stays responsive and the game doesn't freeze.
	local function advance(work : Work)
		local clock = api.type.Clock.new()
		if work.surveyJob == nil then
			work.surveyJob = survey.start(work.stops, CELL, SURVEY_MARGIN)
		end
		if work.routeJob == nil then
			if survey.step(work.surveyJob, BUDGET_US) then
				work.routeJob = route.start({ grid = survey.grid(work.surveyJob), stops = work.stops,
					weights = work.weights, platformLength = work.platform })
				setProgress("plan", 0)
			else
				setProgress("survey", survey.progress(work.surveyJob))
			end
			return
		end
		local done = false
		repeat
			done = route.step(work.routeJob, EXPANSIONS_PER_CALL)
		until done or clock:getTime() >= BUDGET_US
		if done then
			nextGeneration = nextGeneration + 1
			generationState:set(nextGeneration)
			planState:set(route.plan(work.routeJob))
			workRef:set(nil)
			progressState:set(nil)
		else
			setProgress("plan", route.progress(work.routeJob))
		end
	end

	react.onStep(function()
		if workRef:get() == nil or joinQueuedRef:get() then
			return
		end
		joinQueuedRef:set(true)
		safeJoin(function()
			joinQueuedRef:set(false)
			local work = workRef:get()
			if work == nil then
				return
			end
			local ok, err = pcall(function() : boolean
				advance(work)
				return true
			end)
			if not ok then
				debugPrint(LOG_PREFIX .. "planning error: " .. tostring(err))
				workRef:set(nil)
				progressState:set(nil)
				errorState:set(true)
			end
		end, "PgraceRailRouterWork")
	end)

	local body : {TreeNodeId} = {}
	if data.error then
		table.insert(body, textRow(_("Error (see log)"), "font-scale-body"))
	end
	table.insert(body, labelled(_("From"), townCombo(data.towns, settings.from, function(id : integer)
		update(function(s : Settings) s.from = id s.skipped = {} end)
	end)))
	table.insert(body, labelled(_("To"), townCombo(data.towns, settings.to, function(id : integer)
		update(function(s : Settings) s.to = id s.skipped = {} end)
	end)))
	table.insert(body, labelled(_("Mode"), builtin.ComboBox{
		value = settings.mode,
		items = {
			builtin.ComboBoxItem{ value = "cheapest", content = builtin.TextView{ text = _("Cheapest") } },
			builtin.ComboBoxItem{ value = "fastest", content = builtin.TextView{ text = _("Fastest") } },
		},
		onValueChange = function(v : integer | number | string)
			-- The default track depends on the mode: a type the player didn't pick follows it.
			update(function(s : Settings) s.mode = tostring(v) as Mode end)
		end,
	}))
	local trackItems : {TreeNodeId} = {}
	for __, t in ipairs(data.tracks) do
		table.insert(trackItems, builtin.ComboBoxItem{ value = t.name, content = builtin.TextView{ text = t.label },
			available = modes.isAvailable(t, data.year) })
	end
	table.insert(body, labelled(_("Track"), builtin.ComboBox{
		value = track ~= nil and track.name or "",
		items = trackItems,
		onValueChange = function(v : integer | number | string)
			update(function(s : Settings) s.track = tostring(v) end)
		end,
	}))
	table.insert(body, builtin.CheckBox{
		label = _("Electrified"),
		value = settings.electrified and 1 or 0,
		onValueChange = function(v : integer)
			update(function(s : Settings) s.electrified = v == 1 end)
		end,
	})
	local platformItems : {TreeNodeId} = {}
	for __, length in ipairs(PLATFORMS) do
		table.insert(platformItems, builtin.ComboBoxItem{ value = length,
			content = builtin.TextView{ text = formatLength(length) } })
	end
	table.insert(body, labelled(_("Platforms"), builtin.ComboBox{
		value = settings.platform,
		items = platformItems,
		onValueChange = function(v : integer | number | string)
			local length = toInteger(v)
			if length ~= nil then
				update(function(s : Settings) s.platform = length end)
			end
		end,
	}))
	if #candidates > 0 then
		table.insert(body, textRow(_("Stops on the way:"), "font-scale-body"))
		for __, candidate in ipairs(candidates) do
			local id = candidate.town.id
			table.insert(body, builtin.CheckBox{
				label = fill(_("{town} (+{detour})"), { town = candidate.town.name, detour = formatLength(candidate.detour) }),
				value = settings.skipped[id] and 0 or 1,
				onValueChange = function(v : integer)
					update(function(s : Settings)
						local skipped : {integer : boolean} = {}
						for k, skip in pairs(s.skipped) do
							skipped[k] = skip
						end
						skipped[id] = v == 0 or nil
						s.skipped = skipped
					end)
				end,
			})
		end
	end
	table.insert(body, builtin.Button{
		content = builtin.TextView{ text = _("Find route") },
		onClick = findRoute,
	})
	if fromTown == nil or toTown == nil or fromTown.id == toTown.id then
		table.insert(body, textRow(_("Choose two different towns."), "font-scale-annotation"))
	elseif track == nil then
		table.insert(body, textRow(_("No track type is available yet."), "font-scale-annotation"))
	end

	local progress = progressState:old()
	if progress ~= nil then
		local template = progress.stage == "survey" and _("Surveying… {percent}%") or _("Planning… {percent}%")
		table.insert(body, textRow(fill(template, { percent = tostring(progress.percent) }), "font-scale-annotation"))
	end
	if errorState:old() then
		table.insert(body, textRow(_("Error (see log)"), "font-scale-body"))
	end
	local plan = planState:old()
	if plan ~= nil then
		if not plan.ok then
			table.insert(body, textRow(failureText(plan), "font-scale-body"))
		else
			for __, row in ipairs(resultRows(plan)) do
				table.insert(body, row)
			end
			table.insert(body, builtin.ToggleButton{
				content = builtin.TextView{ text = _("Show on map") },
				value = showState:old() and 1 or 0,
				onValueChange = function(v : integer)
					showState:set(v == 1)
				end,
			})
			if showState:old() then
				-- A fixed key, so the progress line coming and going above it doesn't remount it.
				table.insert(body, preview.RouteAction{ meta = { localKey = "route" }, plan = plan,
					generation = generationState:old(), baseCtx = params.gameCtx })
			end
		end
	end

	return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = body }
end)

-- The tool machinery only reads gameCtx.windowContainer (and the button its tool stack); the mod-area plugin gets
-- no gameCtx, so build one from the game's defaults.
local function makeToolParam() : ToolParam
	local gameCtx = {
		windowContainer = game_react_globals.getDefaultWindowContainer(),
		toolStack = game_react_globals.getDefaultToolStack(),
	} as GameContext
	return { gameCtx = gameCtx }
end

local RailRouterWindow = react.RegisterWrapperRecipe("PgraceRailRouterWindow", builtin.Window, function(params : ToolReactUtil.IToolWindowParam<ToolParam>) : TreeNodeId
	return builtin.Window{
		meta = { class = "pgrace-rail-router" },
		id = WINDOW_ID,
		title = MOD_NAME,
		closable = true,
		onClose = params.onClose,
		content = Content{
			gameCtx = params.payload ~= nil and params.payload.toolParam ~= nil and params.payload.toolParam.gameCtx
				or makeToolParam().gameCtx,
		},
	}
end)

local RailRouterTool = tool_react_util.registerToolWithWindow("PgraceRailRouter", WINDOW_ID, RailRouterWindow)

local RailRouterButton = react.RegisterPluginRecipe(main_mod_button_area.MainModButtonAreaExtension, "PgraceRailRouterButton", function() : TreeNodeId
	return builtin.BoxLayout{
		children = {
			builtin.ToolButton{
				meta = { tooltip = _("Rail Router: plan a rail line between two towns") },
				toolDefinition = RailRouterTool,
				toolStack = game_react_globals.getDefaultToolStack(),
				content = builtin.ImageView{
					path = BUTTON_ICON,
					scaling = builtin.type.ImageViewScaling.AutoFit,
				},
				showFn = function()
					local ok, err = pcall(function() : boolean
						game_react_globals.getDefaultToolStackApi().push(RailRouterTool, nil, makeToolParam())
						return true
					end)
					if not ok then
						debugPrint(LOG_PREFIX .. "open failed: " .. tostring(err))
					end
				end,
				hideFn = function()
					pcall(function() : boolean
						game_react_globals.getDefaultToolStackApi().pop(RailRouterTool, nil)
						return true
					end)
				end,
			},
		},
	}
end)

debugPrint(LOG_PREFIX .. "script loaded")

return {
	RailRouterButton = RailRouterButton,
}
```

- [ ] **Step 4: Check, test, verify**

Run: `just verify`
Expected: `0 error(s)`, `43 passed, 0 failed`, and the release check passes (no `strings.json` yet, so no translation
errors; translations are milestone 4). Fix type errors in place. Two likely ones:
- `skipped[id] = v == 0 or nil` may not type: write `if v == 0 then skipped[id] = true else skipped[id] = nil end`.
- `ComboBoxItem` `value = length` with `length : integer` against `integer|number|string`: fine; if not, cast
  `length as integer|number|string`.

- [ ] **Step 5: Commit**

```bash
git add -A mod
git commit -m "feat: rail router window with settings, planning and results

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: Install, docs, and the in-game test

**Files:**
- Modify: `README.md`, `M/_metadata/modinfo.json`, `M/_metadata/description.html`
- Delete: `TEMPLATE.md`

- [ ] **Step 1: README, metadata, template note**

Replace `README.md`'s "TODO: what the mod does." with:

```markdown
Pick two towns and Rail Router plans a double-track line between them: stations as close to each town centre as it
can get without demolishing anything, stops in the towns along the way, and track that follows the terrain
(**Cheapest**) or runs straight and flat (**Fastest**). It shows the length, bridges, tunnels, grades and a cost
estimate, and draws the route on the map. Building it with one click comes in a later version.
```

and replace its Layout block's `content/gui/pgrace_rail_router/` lines with:

```
└── content/gui/pgrace_rail_router/
    ├── window.res.lua / window.script.tl / window.css.lua   # mod button and window
    ├── survey.tl                     # engine reads: towns, track types, terrain grid
    ├── preview.tl                    # the route on the map
    └── planner/                      # pure planner modules (unit-tested)
```

In `M/_metadata/modinfo.json`, set:

```json
    "summary": "Plans a rail line between two towns: stations, stops on the way, bridges, tunnels and cost.",
    "description": "Pick two towns and Rail Router plans a double-track line between them, with stations as close to each town centre as possible without demolishing anything. Cheapest or Fastest mode.",
```

In `M/_metadata/description.html`, replace the TODO paragraph and list items with the same content (one sentence,
then Features: Cheapest/Fastest modes, stops on the way, no demolition, preview on the map; How to use: click the
train button at the top left, choose two towns, press Find route, then Show on map). Delete `TEMPLATE.md`.

- [ ] **Step 2: Verify and install**

Run: `just verify && just install`
Expected: verify passes; install reports the symlink in `staging_area/pgrace_rail_router`.

- [ ] **Step 3: Commit**

```bash
git add -A README.md TEMPLATE.md mod
git commit -m "docs: describe milestone 1

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 4: Ask the user for the in-game test**

The agent can't run the game. Give the user this checklist (use a test map, never the active save):

1. Map Editor → Create New Map. Raise a hill and dig a lake between where two towns will go; place three or four
   towns in a rough line, a few km apart. Save it; New Game → Play Map with **Rail Router** enabled.
2. Restart TF3 if it was running. Check the log for `[rail_router] script loaded`:
   `grep -h "\[rail_router\]" ~/.local/share/Steam/userdata/12818001/3493540/local/crash_dump/stdout.txt | tail`
3. A train button appears at the top left; clicking it opens the window at the left edge (and clicking again,
   ✕ and Esc close it).
4. From/To list every town; Track shows the base types with the right names (not keys like `TRACK_STANDARD_NAME`);
   Electrified and Platforms work.
5. With two towns chosen, the towns in between appear under "Stops on the way" with their detours.
6. Find route shows "Surveying… N%" then "Planning… N%" without freezing the game; time it roughly.
7. The result shows length, cost estimate, bridges/tunnels, grade, curve radius and each station's distance from
   its centre.
8. Show on map frames the camera and draws green/blue/orange arrows along the route and white ones on the platforms;
   the route goes round the lake or bridges it, and avoids town buildings. Turning it off restores the map.
9. Switch to Fastest and plan again: wider curves, flatter grades, possibly more bridges and tunnels.
10. Close the window while planning, and while the route is shown: no error, the map is restored.

Then read the log for errors (`grep -h "\[rail_router\]" .../stdout.txt | tail -50`) and the survey line (grid size,
task count) and record anything learned in `../AGENTS.md` (kit repo) and, where it changes the design, in the spec.
```

---

## Self-review notes

- Spec coverage: survey (Task 10), modes (3), grid search with water/slope/buildings/roads/track/turns (5), smoothing
  (7), profile with bridge/tunnel thresholds (8), stations without demolition (6), candidate stops with a 15% budget
  (4, 12), window states (12), preview (11), our cost estimate (9). Dry runs, building and probes are milestones 2
  and 3, planned separately.
- Deviations from the spec, recorded in it: candidate stops are listed before the survey (they only need town
  centres), very wide water isn't banned (bridges are just expensive), every construction is blocked (not only town
  buildings), and the window docks at the left edge.
