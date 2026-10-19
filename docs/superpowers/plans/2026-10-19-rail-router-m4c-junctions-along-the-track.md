# Rail Router 4c: junctions along the track — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a new line join an existing station's double track beyond its first curve (stage 1, "B"), then probe cuts on curved track (stage 2, P17). Stage 3 ("A", placements on curves and the planner's choice between two places) gets its own short plan once P17 has answered, as 4b-2 does.

**Architecture:** A new pure module, `planner/midline.tl`, is the junction's frame: a sampled midline with x along it and y across it, mapping frame points and vectors to the world and back. 4b's straight frame (`End.origin`, `dir`, `z`, `grade`) becomes `midline.line(...)`, and every consumer goes through the frame (no behaviour change, baselines identical). Then the analyser reads a stretch through curves and builds its midline from the two tracks, and the planner places the junction only where the midline is straight.

**Tech Stack:** Teal 0.24.8 (type-checked against the game's tealdefs), plain Lua 5.4 tests (`tools/test.lua`), `just check` / `just test` / `just verify` / `just regress`.

**Spec:** `docs/superpowers/specs/2026-10-19-rail-router-junctions-along-the-track-design.md`.

---

## Conventions every task follows

- Work in `/home/pgrace/repos/tf3_mods/tf3_rail_router/.worktrees/m4c` (branch `feat/m4c-curves`).
- Code lives in `mod/pgrace_rail_router/content/gui/pgrace_rail_router/`; its types in
  `mod/pgrace_rail_router/tealdef/gui/pgrace_rail_router/` (`.d.tl`, the canonical definitions; `tools/build.py`
  copies them next to the code, never edit the copies). A new module is also registered in
  `tealdef/pgrace_rail_router_def.d.tl` (one `require` line, as the others).
- `just check` after every edit (type-check), `just test` for the unit tests, `just regress` (about 30 s, all maps)
  before each commit that touches the planner. Regress timing failures ("slowest step N ms, budget 10") are machine
  load when they move between routes from run to run; route figures and invariants must pass.
- Teal/Lua rules (AGENTS.md): game Lua is 5.2 (no `goto`, no `math.tointeger`, no two-argument `math.atan`); loop
  discards are `__`, never `_`; no unused `local type X = Mod.Y` alias (it crashes the game's UI); `c and a or b` only
  when `a` can't be nil.
- Comments: as the surrounding code, full sentences explaining why; match its density.
- Commits: conventional prefixes, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## File map

- Create `planner/midline.tl` + `tealdef/.../planner/midline.d.tl`: the frame (Task 1).
- Modify `planner/existing.tl` + `.d.tl`: `End.frame` (Task 2), reading through curves and `Result.stretches`
  (Task 4), `existing.stationFromEnds` moved here from `survey.tl` (Task 3).
- Modify `planner/route.tl`: frame consumers (Task 2), straight placements over all stretches (Task 5).
- Modify `planner/network.tl`: `junctionEdges` through the frame (Task 2).
- Modify `planner/junction.tl` + `.d.tl`: an `accept` predicate in `fit` (Task 5).
- Modify `survey.tl`: use `existing.stationFromEnds` (Task 3).
- Modify `tools/replaylib.lua`: existing stations from a map capture (Task 3).
- Tests: `tests/midline_test.lua` (new), `tests/existing_test.lua`, `tests/route_test.lua`,
  `tests/network_test.lua`, `tests/regression_test.lua`.
- Modify `probe.tl` + `probe.d.tl`, `window.script.tl`: probe P17 (Task 7).
- Docs: the spec, `AGENTS.md` in the kit (Task 6, Task 8).

---

## Stage 1 (B)

### Task 1: The midline frame

**Files:**
- Create: `mod/pgrace_rail_router/tealdef/gui/pgrace_rail_router/planner/midline.d.tl`
- Create: `mod/pgrace_rail_router/content/gui/pgrace_rail_router/planner/midline.tl`
- Modify: `mod/pgrace_rail_router/tealdef/pgrace_rail_router_def.d.tl` (register it)
- Test: `tests/midline_test.lua`

- [ ] **Step 1: Write the type definitions**

```teal
-- The frame a junction is laid out in (milestone 4c): a sampled midline of an existing double track, x the distance
-- along it from its start, y the offset across it (to the left of the direction of increasing x). Pure.
global record PgraceRailRouterMidline
	-- The spacing a read stretch's midline is sampled at (metres).
	STEP : number

	record Frame
		-- Samples: pts[i] at x = (i − 1) × step, with its unit direction (in plan) and grade (dz per metre along).
		pts : {PgraceRailRouterNetwork.Pt3}
		dirs : {PgraceRailRouterGeo.Pt}
		grades : {number}
		step : number
		-- x of the last sample.
		length : number
	end

	-- A straight frame: from `origin` (height z) along the unit `dir`, on a steady grade, `length` long. Two samples,
	-- so it maps exactly as 4b's straight frame did.
	line : function(origin : PgraceRailRouterGeo.Pt, dir : PgraceRailRouterGeo.Pt, z : number, grade : number,
		length : number) : Frame
	-- A frame through `pts` (a polyline, in order, at least two points), resampled every `step` metres along it
	-- (the last sample at its end); each sample's direction and grade from its neighbours.
	fromPoints : function(pts : {PgraceRailRouterNetwork.Pt3}, step : number) : Frame
	-- The midline's point (height included) and unit direction at x. Between samples: interpolated (the direction
	-- renormalised). Before 0 or past `length`: extended straight along the end sample's direction and grade.
	at : function(f : Frame, x : number) : PgraceRailRouterNetwork.Pt3, PgraceRailRouterGeo.Pt
	-- The grade at x (the sample segment's; the end samples' outside).
	grade : function(f : Frame, x : number) : number
	-- The world point at frame (x, y): the midline's point at x, y along its left normal, at the midline's height.
	world : function(f : Frame, x : number, y : number) : PgraceRailRouterNetwork.Pt3
	-- A frame vector (tx along, ty across) at x in the world, its rise tx × grade(x).
	vector : function(f : Frame, x : number, tx : number, ty : number) : PgraceRailRouterNetwork.Pt3
	-- A world point's frame (x, y): its nearest point on the midline (extended straight past both ends).
	project : function(f : Frame, p : PgraceRailRouterGeo.Pt) : number, number
	-- How far the midline runs on from x0 while its direction stays within `tol` (the sine of the angle) of the
	-- direction at x0: the x where it first turns further (interpolated between samples), or `length`.
	straightUntil : function(f : Frame, x0 : number, tol : number) : number
end
```

Register it: add `require "gui.pgrace_rail_router.planner.midline"` to `tealdef/pgrace_rail_router_def.d.tl`
beside the other planner modules.

- [ ] **Step 2: Write the failing tests** (`tests/midline_test.lua`)

```lua
local t = ...
local midline = t.requireTl("gui/pgrace_rail_router/planner/midline.tl")

-- An arc of radius r turning left from (0, 0) heading +x, sampled every metre, at height z0 + g × s.
local function arc(r, len, z0, g)
	local pts = {}
	for s = 0, len do
		local a = s / r
		pts[#pts + 1] = { x = r * math.sin(a), y = r * (1 - math.cos(a)), z = z0 + g * s }
	end
	return pts
end

t.test("midline: a line maps as 4b's straight frame", function()
	local f = midline.line({ x = 10, y = 20 }, { x = 0.6, y = 0.8 }, 5, 0.01, 300)
	local p = midline.world(f, 100, 7.5)
	t.near(p.x, 10 + 0.6 * 100 - 0.8 * 7.5, 1e-9, "x") t.near(p.y, 20 + 0.8 * 100 + 0.6 * 7.5, 1e-9, "y")
	t.near(p.z, 5 + 0.01 * 100, 1e-9, "z")
	local v = midline.vector(f, 40, 50, 5)
	t.near(v.x, 0.6 * 50 - 0.8 * 5, 1e-9, "vx") t.near(v.y, 0.8 * 50 + 0.6 * 5, 1e-9, "vy") t.near(v.z, 0.5, 1e-9, "vz")
	local x, y = midline.project(f, p)
	t.near(x, 100, 1e-9, "project x") t.near(y, 7.5, 1e-9, "project y")
	t.near(midline.straightUntil(f, 0, 0.005), 300, 1e-9, "straight all the way")
end)

t.test("midline: a line extends straight past both ends", function()
	local f = midline.line({ x = 0, y = 0 }, { x = 1, y = 0 }, 0, 0.02, 100)
	local p = midline.world(f, -50, 2)
	t.near(p.x, -50, 1e-9, "back x") t.near(p.y, 2, 1e-9, "y") t.near(p.z, -1, 1e-9, "z on the grade")
	local x = midline.project(f, { x = 160, y = 0 })
	t.near(x, 160, 1e-9, "projected past the end")
end)

t.test("midline: from points along an arc follows the arc", function()
	local r = 220
	local f = midline.fromPoints(arc(r, 200, 3, 0.01), midline.STEP)
	t.near(f.step, 5, 1e-9, "step") t.ok(math.abs(f.length - 200) < 0.1, "length along the polyline")
	for __, s in ipairs({ 0, 37, 100, 163, 200 }) do
		local p, d = midline.at(f, s)
		local a = s / r
		t.near(p.x, r * math.sin(a), 0.05, "x at " .. s) t.near(p.y, r * (1 - math.cos(a)), 0.05, "y at " .. s)
		t.near(p.z, 3 + 0.01 * s, 1e-3, "z at " .. s)
		t.near(d.x, math.cos(a), 0.01, "dir x at " .. s) t.near(d.y, math.sin(a), 0.01, "dir y at " .. s)
	end
	-- 7.5 m to the left of the midline is the inner circle, radius r − 7.5.
	local q = midline.world(f, 100, 7.5)
	t.near(math.sqrt(q.x ^ 2 + (q.y - r) ^ 2), r - 7.5, 0.05, "offset to the inside")
	local x, y = midline.project(f, q)
	t.near(x, 100, 0.1, "project back x") t.near(y, 7.5, 0.05, "project back y")
end)

t.test("midline: straightUntil stops where the midline turns", function()
	local pts = {}
	for s = 0, 150 do
		pts[#pts + 1] = { x = s, y = 0, z = 0 }
	end
	for __, p in ipairs(arc(220, 150, 0, 0)) do
		if p.x > 0 then
			pts[#pts + 1] = { x = 150 + p.x, y = p.y, z = 0 }
		end
	end
	local f = midline.fromPoints(pts, midline.STEP)
	local until_ = midline.straightUntil(f, 0, 0.005)
	-- sin(θ) = 0.005 after s = 220 × 0.005 = 1.1 m of arc; the samples smooth the corner by a step or so.
	t.ok(until_ > 145 and until_ < 160, "the straight ends at the curve: " .. until_)
	t.ok(midline.straightUntil(f, 200, 0.005) < 210, "on the curve it turns at once")
end)
```

- [ ] **Step 3: Run the tests; they fail**

Run: `just test 2>&1 | grep -E "midline|passed"`
Expected: FAIL (module not found).

- [ ] **Step 4: Write the module** (`planner/midline.tl`)

```teal
local midline : PgraceRailRouterMidline = {}

local type Frame = PgraceRailRouterMidline.Frame
local type Pt = PgraceRailRouterGeo.Pt
local type Pt3 = PgraceRailRouterNetwork.Pt3

midline.STEP = 5.0

function midline.line(origin : Pt, dir : Pt, z : number, grade : number, length : number) : Frame
	return {
		pts = { { x = origin.x, y = origin.y, z = z },
			{ x = origin.x + dir.x * length, y = origin.y + dir.y * length, z = z + grade * length } },
		dirs = { { x = dir.x, y = dir.y }, { x = dir.x, y = dir.y } },
		grades = { grade, grade },
		step = length, length = length,
	}
end

local function unit(x : number, y : number) : Pt
	local d = math.sqrt(x * x + y * y)
	if d < 1e-12 then
		return { x = 1, y = 0 }
	end
	return { x = x / d, y = y / d }
end

function midline.fromPoints(pts : {Pt3}, step : number) : Frame
	-- Resample by arc length (in plan).
	local out : {Pt3} = { { x = pts[1].x, y = pts[1].y, z = pts[1].z } }
	local want, run = step, 0.0
	for i = 2, #pts do
		local a, b = pts[i - 1], pts[i]
		local l = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
		while l > 1e-12 and run + l >= want - 1e-9 do
			local u = (want - run) / l
			table.insert(out, { x = a.x + (b.x - a.x) * u, y = a.y + (b.y - a.y) * u, z = a.z + (b.z - a.z) * u })
			want = want + step
		end
		run = run + l
	end
	local last = pts[#pts]
	local length = (#out - 1) * step
	if run - length > 1e-6 then
		-- The end, short of a whole step: kept at x = length + its own distance by stretching the last step.
		table.insert(out, { x = last.x, y = last.y, z = last.z })
		length = run
	end
	local n = #out
	local dirs : {Pt} = {}
	local grades : {number} = {}
	for i = 1, n do
		local a, b = out[math.max(1, i - 1)], out[math.min(n, i + 1)]
		dirs[i] = unit(b.x - a.x, b.y - a.y)
		local l = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
		grades[i] = l > 1e-12 and (b.z - a.z) / l or 0
	end
	-- Samples are `step` apart but the last, which may be nearer (at x = length; see `segment`).
	local f : Frame = { pts = out, dirs = dirs, grades = grades, step = step, length = length }
	return f
end

-- The segment holding x (1 .. #pts − 1) and the fraction along it (outside [0, 1] beyond the ends).
local function segment(f : Frame, x : number) : integer, number
	local n = #f.pts
	local i = math.floor(x / f.step) + 1
	if i < 1 then
		i = 1
	elseif i > n - 1 then
		i = n - 1
	end
	local x0 = (i - 1) * f.step
	local x1 = i == n - 1 and f.length or i * f.step
	return i, (x - x0) / (x1 - x0)
end

function midline.at(f : Frame, x : number) : Pt3, Pt
	local n = #f.pts
	if x <= 0 or x >= f.length then
		local k = x <= 0 and 1 or n
		local d = x <= 0 and x or x - f.length
		local p, dir = f.pts[k], f.dirs[k]
		return { x = p.x + dir.x * d, y = p.y + dir.y * d, z = p.z + f.grades[k] * d }, { x = dir.x, y = dir.y }
	end
	local i, u = segment(f, x)
	local a, b = f.pts[i], f.pts[i + 1]
	local da, db = f.dirs[i], f.dirs[i + 1]
	return { x = a.x + (b.x - a.x) * u, y = a.y + (b.y - a.y) * u, z = a.z + (b.z - a.z) * u },
		unit(da.x + (db.x - da.x) * u, da.y + (db.y - da.y) * u)
end

function midline.grade(f : Frame, x : number) : number
	if x <= 0 then
		return f.grades[1]
	elseif x >= f.length then
		return f.grades[#f.grades]
	end
	local i = segment(f, x)
	local a, b = f.pts[i], f.pts[i + 1]
	local l = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
	return l > 1e-12 and (b.z - a.z) / l or f.grades[i]
end

function midline.world(f : Frame, x : number, y : number) : Pt3
	local p, d = midline.at(f, x)
	return { x = p.x - d.y * y, y = p.y + d.x * y, z = p.z }
end

function midline.vector(f : Frame, x : number, tx : number, ty : number) : Pt3
	local __, d = midline.at(f, x)
	return { x = d.x * tx - d.y * ty, y = d.y * tx + d.x * ty, z = midline.grade(f, x) * tx }
end

function midline.project(f : Frame, p : Pt) : number, number
	local n = #f.pts
	local bestX, bestY, bestD = 0.0, 0.0, math.huge
	for i = 1, n - 1 do
		local a, b = f.pts[i], f.pts[i + 1]
		local x0 = (i - 1) * f.step
		local x1 = i == n - 1 and f.length or i * f.step
		local ex, ey = b.x - a.x, b.y - a.y
		local l2 = ex * ex + ey * ey
		local u = l2 > 1e-12 and ((p.x - a.x) * ex + (p.y - a.y) * ey) / l2 or 0
		-- Clamped between samples, except past the midline's two ends, where it runs on straight.
		if (u < 0 and i > 1) then
			u = 0
		elseif u > 1 and i < n - 1 then
			u = 1
		end
		local qx, qy = a.x + ex * u, a.y + ey * u
		local d = (p.x - qx) ^ 2 + (p.y - qy) ^ 2
		if d < bestD then
			local l = math.sqrt(l2)
			bestD = d
			bestX = x0 + (x1 - x0) * u
			bestY = l > 1e-12 and ((p.y - qy) * ex - (p.x - qx) * ey) / l or 0
		end
	end
	return bestX, bestY
end

function midline.straightUntil(f : Frame, x0 : number, tol : number) : number
	local __, d0 = midline.at(f, x0)
	local i = segment(f, math.max(0, x0))
	local prevX, prevS = x0, 0.0
	for k = i + 1, #f.pts do
		local x = k == #f.pts and f.length or (k - 1) * f.step
		local d = f.dirs[k]
		local s = math.abs(d0.x * d.y - d0.y * d.x)
		if s > tol then
			-- Between the last sample within it and this one.
			return prevX + (x - prevX) * (tol - prevS) / (s - prevS)
		end
		prevX, prevS = x, s
	end
	return f.length
end

return midline
```

- [ ] **Step 5: Run the tests; they pass**

Run: `just check && just test 2>&1 | grep -E "FAIL|midline|passed"`
Expected: the four midline tests PASS, nothing else fails.

- [ ] **Step 6: Commit**

```bash
git add mod tests/midline_test.lua
git commit -m "feat: the junction's frame as a sampled midline (planner/midline.tl)"
```

### Task 2: Every junction consumer goes through the frame

No behaviour change: on today's straight stretches the frame is `midline.line`, which maps exactly as before. All
regression baselines must stay as they are.

**Files:**
- Modify: `tealdef/.../planner/existing.d.tl` (`End.frame`), `planner/existing.tl` (`readEnd`)
- Modify: `planner/network.tl` (`junctionEdges`, lines ~624–770)
- Modify: `planner/route.tl` (`junctionEnds` ~340, `stationEnds` ~375, `runRoom` ~437, `addFootprint` ~470–510,
  `alongFreeCells` ~535–565)
- Test: `tests/existing_test.lua`

- [ ] **Step 1: Failing test** — append to `tests/existing_test.lua`:

```lua
t.test("existing: a usable end carries its frame, a line along the stretch", function()
	local midline = t.requireTl("gui/pgrace_rail_router/planner/midline.tl")
	local st, snap = plain()
	local r = existing.analyse(st, snap, { [1] = 1, [-1] = 1 }, R)
	local e = r.ends[1]
	t.ok(e.frame ~= nil, "a frame")
	local p = midline.world(e.frame, 50, 0)
	t.near(p.x, e.origin.x + e.dir.x * 50, 1e-9, "x along the stretch") t.near(p.y, e.origin.y + e.dir.y * 50, 1e-9, "y")
	t.near(p.z, e.z + e.grade * 50, 1e-9, "z on its grade")
	t.near(e.frame.length, e.length, 1e-9, "as long as the stretch")
end)
```

(`plain()` is the file's existing helper returning a station and snapshot with a straight double track past the
fan; check its return shape where it's defined, around line 89, and adapt the call.)

- [ ] **Step 2: Run; it fails** (`e.frame` nil).

- [ ] **Step 3: Add the field and set it.** In `existing.d.tl`'s `End` record add:

```teal
		-- The stretch's frame (milestone 4c): x along its midline from its start, y to the left. Every use of the
		-- stretch's geometry goes through it; on a straight stretch it is midline.line(origin, dir, z, grade, length).
		frame : PgraceRailRouterMidline.Frame
```

In `existing.tl`, `require` midline at the top (`local midline = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/midline.tl" as PgraceRailRouterMidline`)
and at the end of `readEnd`, before `return e, nil`:

```teal
	e.frame = midline.line(e.origin, e.dir, e.z, e.grade, e.length)
```

- [ ] **Step 4: Network.** In `junctionEdges` replace the four local helpers with frame calls, keeping their names
so the body barely changes:

```teal
	local f = e.frame
	local function world(x : number, y : number) : Pt3
		return midline.world(f, x, y)
	end
	-- A frame vector (tx along, ty across) at frame x, in the world.
	local function vec(x : number, tx : number, ty : number) : Pt3
		return midline.vector(f, x, tx, ty)
	end
	local function frameY(p : Pt3) : number
		local __, y = midline.project(f, p)
		return y
	end
	local function frameX(p : Pt3) : number
		local x = midline.project(f, p)
		return x
	end
```

Drop the now unused `left`. Update every `vec(...)` call to pass the x it applies at:
- `add(from, mid, x, pairX, vec(x, pairX - x, 0), vec(pairX, pairX - x, 0))`
- `add(from, n, x, j.approachX, vec(x, d, 0), vec(j.approachX, d, 0)).paired = true`
- `add(a, b, pc.x0, pc.x1, vec(pc.x0, pc.tx0, pc.ty0), vec(pc.x1, pc.tx1, pc.ty1)).whole = true`

Add the `midline` require to `network.tl`. Fix the header comment of `junctionEdges` ("taken from the frame (x along
e.dir from e.origin…") to "taken from the stretch's frame (e.frame)".

- [ ] **Step 5: Route.** Add the `midline` require to `route.tl`, then:

`junctionEnds`:

```teal
local function junctionEnds(input : Input, station : Station, forward : boolean) : Pt, Pt, Pt, number, number
	local k = station.endOf[forward]
	local e, j = station.ends[k], station.junctions[k]
	local x, a = j.approachX, JUNCTION_STRAIGHT
	local p = midline.world(e.frame, x, JUNCTION_OFFSET * station.sides[k])
	local __, out = midline.at(e.frame, x)
	local platformEnd : Pt = { x = p.x, y = p.y }
	local approach = geo.add(platformEnd, geo.scale(out, a))
	return platformEnd, approach, out, p.z, p.z + midline.grade(e.frame, x) * a
end
```

`runRoom`:

```teal
	local e = station.ends[station.endOf[forward]]
	local x = midline.project(e.frame, extension)
	return math.max(0, e.length - x)
```

`addFootprint`, the junction part: replace `left`, `x = -geo.dot(geo.sub(e.origin, c), e.dir)` and the point
computation with the frame:

```teal
		for k, e in pairs(station.ends) do
			-- In the stretch's frame (x along its midline from its start, y across): from back at the station's centre
			-- out to where our straight may reach (its approach, room to turn at the full radius, and run, and a cell more).
			local back = midline.project(e.frame, c)
			local x = back
			local reach = station.junctions[k].approachX + JUNCTION_STRAIGHT + extensionLength(input, nil) + MAX_END_RUN
				+ g.cell
			local far = math.min(reach, existing.REACH - back + station.existing.half)
			reach = math.min(e.length, reach)
			local side = station.sides[k]
			while x <= math.max(reach, far) + 1e-6 do
				local y = x <= reach + 1e-6 and 2.5 or -(2.5 + g.cell / 2)
				while y >= -(2.5 + g.cell) - 1e-6 do
					local q = midline.world(e.frame, x, y * side)
					local p : Pt = { x = q.x, y = q.y }
					if grid.inside(g, p) then
						local ix, iy = grid.cellOf(g, p)
						cells[grid.index(g, ix, iy)] = true
					end
					y = y - g.cell / 4
				end
				x = x + g.cell / 4
			end
		end
```

(`midline.project(e.frame, c)` returns the station centre's x, negative: the same value as the old
`-geo.dot(geo.sub(e.origin, c), e.dir)` on a straight frame. `far` used `existing.REACH - dot(origin − c, dir)`,
which is `existing.REACH + back`… check the sign against the old line before replacing: the old expression is
`existing.REACH - geo.dot(geo.sub(e.origin, c), e.dir) + half`, and `geo.dot(geo.sub(e.origin, c), e.dir) = -back`,
so it is `existing.REACH + back + half`. Use that.)

`alongFreeCells`: give `band` a frame instead of an origin and direction:

```teal
	local function band(f : PgraceRailRouterMidline.Frame, x0 : number, x1 : number)
		local x = x0
		while x <= x1 + 1e-6 do
			local y = -12.0
			while y <= 12.0 + 1e-6 do
				local q = midline.world(f, x, y)
				local p : Pt = { x = q.x, y = q.y }
				if grid.inside(g, p) then
					local ix, iy = grid.cellOf(g, p)
					cells[grid.index(g, ix, iy)] = true
				end
				y = y + math.min(6.0, g.cell / 4)
			end
			x = x + g.cell / 4
		end
	end
```

and call it as `band(midline.line(st.centre, dir, 0, 0, 2 * st.half), -st.half, st.half)` for the platforms (a line
from the centre: x from −half to half; the line is extended back past its start by `midline.at`), and
`band(e.frame, midline.project(e.frame, st.centre), e.length)` for each stretch.

Any other use of `e.origin`, `e.dir` or `e.grade` in `route.tl` (grep `\.origin\|e\.dir\|\.grade`) goes through the
frame the same way; `e.dir` as "the outward direction at the stretch's start" may stay where it means exactly that.

- [ ] **Step 6: Run everything**

Run: `just verify 2>&1 | grep -E "error\(s\)|passed"` then `just regress 2>&1 | grep -A1 "^FAIL\|passed"`.
Expected: 0 errors; all unit tests pass; regress passes with **no baseline changed** (only timing failures that move
between runs are acceptable).

- [ ] **Step 7: Commit**

```bash
git add mod tests
git commit -m "refactor: junctions, footprints and runs go through the stretch's frame (End.frame)"
```

### Task 3: Existing stations from a map capture (offline)

Offline tests need the existing station and its snapshot from a whole-map capture, as the window reads them in-game.

**Files:**
- Modify: `planner/existing.tl` + `.d.tl` (add `existing.stationFromEnds`), `survey.tl` (use it; delete its local
  `stationOf` and `MIN_STATION_SPAN`)
- Modify: `tools/replaylib.lua` (`lib.existingFromMap`, and `planOnMap` option `existing`)
- Test: `tests/existing_test.lua`, `tests/regression_test.lua`

- [ ] **Step 1: Move `stationOf` into the pure module.** In `existing.d.tl`:

```teal
	-- A station from its track end nodes (survey.trackEnds in-game, a map capture offline): the two groups of ends
	-- either side of the middle of the farthest pair, their centres giving the platforms' centre, direction (first
	-- group to second) and half-length. nil and why where the ends are fewer than two or closer than 20 m.
	stationFromEnds : function(entity : integer, ends : {PgraceRailRouterNetwork.Pt3}) : Station, string
```

Cut `survey.tl`'s `stationOf` (lines ~649–694, with `MIN_STATION_SPAN` and its comment) into `existing.tl` as
`existing.stationFromEnds`, unchanged but for its name; make `survey.tl` call `existing.stationFromEnds(entity, ends)`
(require `existing.tl` in `survey.tl` if it isn't yet). `ends` entries carry `entity` (`Pt3` has an optional
`entity`).

- [ ] **Step 2: `lib.existingFromMap(map, townKey)` in `tools/replaylib.lua`.** Returns `station, snapshot` (or nil
and why) for the rail station nearest the town's centre within 1500 m:

```lua
	-- An existing rail station from a whole-map capture, as the window reads it in-game (survey.existingStations,
	-- trackSnapshot): the station construction nearest the town (within `reach`, default 1500 m) with track pieces
	-- inside its box; its end nodes are its track pieces' nodes that only one piece inside the box reaches (each
	-- station track's two extremes), stationFromEnds then gives its centre, direction and half-length. The snapshot
	-- is every track piece within half + existing.REACH + 100 m of its centre, ground unless the capture marks a
	-- bridge or tunnel, with no signals (captures don't record them; right-hand running is assumed).
	function lib.existingFromMap(map, townKey, reach)
		reach = reach or 1500
		local towns = maplib.towns(map)
		local town = assert(lib.findTown(towns, townKey), "no town " .. tostring(townKey))
		local best, bestD
		for _, o in ipairs(map.objects) do
			if o.file and o.file:match("station") and o.file:match("rail") then
				local cx, cy = (o.min.x + o.max.x) / 2, (o.min.y + o.max.y) / 2
				local d = math.sqrt((cx - town.pos.x) ^ 2 + (cy - town.pos.y) ^ 2)
				if d <= reach and (not bestD or d < bestD) then
					best, bestD = o, d
				end
			end
		end
		if not best then
			return nil, "no rail station within reach"
		end
		local function inBox(p)
			return p.x >= best.min.x - 1 and p.x <= best.max.x + 1 and p.y >= best.min.y - 1 and p.y <= best.max.y + 1
		end
		local count, at = {}, {}
		for _, e in ipairs(map.edges) do
			if e.kind == "t" and inBox(e.p0) and inBox(e.p1) then
				for _, nd in ipairs({ { e.node0, e.p0 }, { e.node1, e.p1 } }) do
					count[nd[1]] = (count[nd[1]] or 0) + 1
					at[nd[1]] = nd[2]
				end
			end
		end
		local ends = {}
		for n, c in pairs(count) do
			if c == 1 then
				ends[#ends + 1] = { x = at[n].x, y = at[n].y, z = at[n].z, entity = n }
			end
		end
		table.sort(ends, function(a, b) return a.entity < b.entity end)
		local st, why = existing.stationFromEnds(best.id, ends)
		if not st then
			return nil, why
		end
		st.box = { minX = best.min.x, minY = best.min.y, maxX = best.max.x, maxY = best.max.y }
		local r = st.half + existing.REACH + 100
		local pieces, degree = {}, {}
		for _, e in ipairs(map.edges) do
			if e.kind == "t" then
				degree[e.node0] = (degree[e.node0] or 0) + 1
				degree[e.node1] = (degree[e.node1] or 0) + 1
				local mx, my = (e.p0.x + e.p1.x) / 2, (e.p0.y + e.p1.y) / 2
				if math.sqrt((mx - st.centre.x) ^ 2 + (my - st.centre.y) ^ 2) <= r then
					pieces[#pieces + 1] = { entity = e.id, node0 = e.node0, node1 = e.node1, p0 = e.p0, p1 = e.p1,
						t0 = e.t0, t1 = e.t1, kind = e.structure or "ground", signals = {} }
				end
			end
		end
		return st, { pieces = pieces, degree = degree }
	end
```

Before using them, check the capture's field names in `tools/maplib.lua` and `../template/docs/map-capture-format.md`
(objects: `id`, `kind`, `file`, `min`/`max`; edges: `kind` "t" for track, `node0`/`node1`, `p0`/`p1`/`t0`/`t1`, and
how bridges and tunnels are marked) and adapt the code to them; `existing` is
`ug_require("pgrace_rail_router::/gui/pgrace_rail_router/planner/existing.tl")` as the other planner modules are
loaded in replaylib.

In `lib.planOnMap`, accept `opts.existing` (a list of town names whose existing station to use): for each such stop
(by index in the planned stops), `existingFromMap`; pass `existingStations`, `snapshots`, `radius = 150`
(the window's JUNCTION_RADIUS) and `bareApproach = network.bareApproach(network.turnoutLength(turnout))` (turnout
radius by track speed as the window's `turnoutRadius`: < 30 → 150, < 60 → 300, else 600) to `route.start` through
`runPlan` (add the parameters it needs).

- [ ] **Step 3: Tests.** In `tests/existing_test.lua` (skip with a message when `../maps` is missing, as
`regression_test.lua` does via its `findMapsDir`):

```lua
t.test("existing: line1 map: Aloha's station reads as Rail Router built it (offline, from the capture)", function()
	local maps = t.mapsDir and t.mapsDir() -- use regression_test's findMapsDir logic if t has no helper
	if not maps then
		return t.skip("no ../maps")
	end
	local lib = dofile("tools/replaylib.lua")(".")
	local map = lib.maplib.load(maps .. "/rail-router-test-5x14km-line1.map")
	local st, snap = lib.existingFromMap(map, "Aloha")
	t.ok(st ~= nil, "a station")
	t.near(st.half, 160, 1, "320 m platforms")
	t.ok(#st.ends >= 4, "its track ends")
	local r = existing.analyse(st, snap, { [1] = 1, [-1] = 1 }, 150)
	-- Today (straight stretches only) neither end has room: its line curves 141–195 m past the fan.
	t.ok(r.ends[1] == nil and r.ends[-1] == nil, "no straight stretch long enough yet")
	t.ok((r.longest[1] or 0) > 100 and (r.longest[-1] or 0) > 100, "the straights past the fans were read")
end)
```

Adapt the map-folder lookup to what the test runner offers (look at how `regression_test.lua` finds `../maps` and
reuse it; move `findMapsDir` into a shared helper only if that is a small change). This test is rewritten in Task 4,
when the reading goes through curves.

- [ ] **Step 4: Run** `just verify` and `just regress`: all pass, no baseline changed.

- [ ] **Step 5: Commit**

```bash
git add mod tools tests
git commit -m "feat: existing stations from a map capture, for offline tests (replaylib.existingFromMap)"
```

### Task 4: The analyser reads through curves

The heart of stage 1. Use the most capable model.

**Files:**
- Modify: `planner/existing.tl` (`stretchAt`, `walk`, `readEnd`, `existing.analyse`), `.d.tl` (`Result.stretches`)
- Test: `tests/existing_test.lua`

**What changes (spec "Reading an end"):**

1. **Where a stretch starts** stays as now: scanning outward on the station's axis for the first x where exactly two
   ground pieces cross, 4.5–5.5 m apart, both straight along the axis there (`straight` with the pair's grade), and
   the tracks behind lead only to the station (`fromStation`).
2. **Walking:** each track is walked through plain nodes (degree 2) whatever the pieces' shape. A walk ends at a
   switch ("crossover" if `crossover` says so, else "stop"), a dead end or a piece that turns back ("stop"), a bridge
   or tunnel ("structure"), or once it has gone more than `REACH` from the station's platform end (measured along
   the track). `straight` no longer ends a walk; the corridor is no longer used for walking (it remains for
   `fromStation` near the station): take the next piece at a node from the snapshot's pieces at that node (build a
   node → pieces index of the whole snapshot once per `analyse`).
3. **The midline:** sample each track's pieces in order along their Hermite curves (`network.hermiteAt`, every
   metre or so: n = ceil(chord / 1) samples per piece), giving two polylines, left and right (left of outward at
   the start). Walk the left polyline in steps of 1 m along it; at each point find the nearest point on the right
   polyline (search forward from the previous match only). The pair holds while:
   - their distance is 4.5–5.5 m;
   - their heights differ by at most 0.3 m;
   - the match lies roughly across (the direction from the left point to the right one is within 0.2 of
     perpendicular to the left track's direction: |cos| ≤ 0.2);
   - no other snapshot track piece (not one of the two tracks' pieces, and not one sharing a node with them at a
     switch the walk ended at) comes within 12 m of the midpoint, checked every 5 m (sample other pieces once into a
     point list with their piece id, bucket them by 25 m grid cell, and look in the neighbouring cells).
   The stretch ends at the last midpoint where all four held, or where either track's walk ended (project that
   end onto the midline), whichever is first; its reason as the walk's, or "drift" for a failed pair check.
4. **The frame:** `midline.fromPoints(midpoints, midline.STEP)`, the midpoints' heights the two tracks' mean.
5. **The End** (in `readEnd`): `origin`, `dir`, `z` and `grade` describe the stretch's start (as now: the start
   point, the outward axis direction, the start height, the first 5 m's grade); `length` is `frame.length`; `frame`
   the new frame; nodes and signals projected onto it (`midline.project`, x from the stretch's start); pieces per
   track in order, as now. Left-hand signals as now.
6. **Which stretches:** `existing.analyse` returns, per end, every stretch at least `junction.needed(radius)` long
   that the scan reaches, in order, as `result.stretches[k]` (a list of End), and keeps `result.ends[k]` as the first
   of them (so callers that read `ends` keep working); `longest` and `why` as now. Reading on after a stretch
   follows the tracks, not the station's axis (which no longer follows the track): past a "structure" end, carry on walking both tracks through the structure's pieces (counting them as
   plain) and start a new midline after them; past a "crossover", carry on through the crossover's switch along the
   track's line (the piece whose far end stays within 1 m of the track's line, as `crossover` already decides) and
   start a new midline after the crossover's far switch. Stop at REACH.

Add to `Result` in `existing.d.tl`:

```teal
		-- Per end, every stretch long enough (junction.needed), nearest first, through curves (milestone 4c); ends[k]
		-- is the first.
		stretches : {integer : {End}}
```

**Tests** (`tests/existing_test.lua`; reuse the file's `builder()` snapshot helper; add an arc piece helper):

```lua
-- A piece along an arc: from angle a0 to a1 (radians, CCW positive) on a circle centre (cx, cy), radius r; tangents
-- by the 4R·tan(θ/4) rule the game's curves follow.
local function arcPiece(id, n0, n1, cx, cy, r, a0, a1)
	local th = a1 - a0
	local k = 4 * r * math.tan(th / 4) / r
	local function pt(a) return { x = cx + r * math.cos(a), y = cy + r * math.sin(a), z = 0 } end
	local function tg(a) return { x = -math.sin(a) * r * k * (th > 0 and 1 or 1), y = math.cos(a) * r * k, z = 0 } end
	return { entity = id, node0 = n0, node1 = n1, p0 = pt(a0), p1 = pt(a1), t0 = tg(a0), t1 = tg(a1),
		kind = "ground", signals = {} }
end
```

(Check the tangent sign for a negative θ against `network.hermiteAt` in a quick test; the helper must give a curve
that stays on the circle within a few cm.)

Write these tests, each building a station with the file's existing fan helper and then:

1. **"a stretch carries on through a curve"**: 150 m straight past the fan, then both tracks on concentric 300 m arcs
   (radius 300 ± 2.5) turning 40°, then 400 m straight. One stretch; its length ≈ 150 + 300 × 0.698 + 400 (within
   5 m); `midline.at(frame, 150 + 300 * 0.349)` lies on the circle of radius 300 (within 0.3 m).
2. **"tracks drifting apart end the stretch"**: the right track's arc 4 m wider than the left's. The stretch ends
   where the gap passes 5.5 m.
3. **"a third track beside the stretch ends it"**: a single track piece 9 m off the midline from x = 400 to 500. The
   stretch ends near 400 (within 10 m).
4. **"a bridge ends a stretch and the next starts past it"**: as the existing bridge test, but with a curve before
   the bridge: two stretches in `stretches[1]`, the second starting past the bridge.
5. **"stretches list every long one, ends[k] the first"**: two long stretches split by a crossover pair.
6. Update the existing tests whose meaning changed: "a double track bending off the axis is not a straight
   stretch", "a piece bulging sideways…", "a change of grade ends the stretch at the kink", "a hump between level
   ends…" now read on (the stretch continues; assert the frame follows the bend or grade instead). Keep "tracks on
   different grades are not a double track" (heights differ by more than 0.3 m).
7. Rewrite Task 3's line1 test: Aloha's ends each have a stretch through the first curve, at least 600 m long, whose
   frame turns by more than 10° somewhere (`midline.straightUntil(frame, 0, 0.005) < frame.length`).

- [ ] **Step 1:** write the arc helper and test 1; run; it fails.
- [ ] **Step 2:** implement walking (2), the midline (3) and the frame (4, 5); test 1 passes.
- [ ] **Step 3:** tests 2 and 3; make them pass.
- [ ] **Step 4:** `stretches` and reading on (6); tests 4 and 5.
- [ ] **Step 5:** update the changed tests (item 6) and the line1 test (item 7).
- [ ] **Step 6:** `just verify`, `just regress`. Baselines may change only where an existing station is used (none of
  today's regression routes use one, so none should). Commit:

```bash
git add mod tests
git commit -m "feat: an existing station's stretch reads on through curves, with its midline as the frame"
```

### Task 5: Junctions placed on straight parts, over every stretch

**Files:**
- Modify: `planner/junction.tl` + `.d.tl` (`fit`'s `accept`), `planner/route.tl` (`existingStop`, `stationEnds`)
- Test: `tests/route_test.lua`, `tests/existing_test.lua` (junction fit)

- [ ] **Step 1: `junction.fit` takes an optional predicate.** In `junction.d.tl` add a parameter
`accept ?: function(Layout) : boolean` after `nodes`, documented: "a placement that fits is returned only if `accept`
(when given) takes it; otherwise the search goes on outward". In `junction.tl`, build the `Layout` into a local and
return it only when `accept == nil or accept(layout)`.

- [ ] **Step 2: Failing route test** (`tests/route_test.lua`; reuse its existing-station helpers, e.g. the one around
line 917 that builds a station with a snapshot): a station whose line runs 150 m straight past the fan, curves 40°
at radius 300, then runs 600 m straight. Plan a leg to it with `existingStations`. Assert: the plan joins it at a
junction (no fallback note), `station.junctions[k].approachX` lies on the far straight
(`midline.straightUntil` from the junction's first cut reaches past `approachX + 50`), and the junction's first cut
is past the curve.

- [ ] **Step 3: `existingStop` tries every stretch.** Replace the single `result.ends[k]` + `junction.fit` with a
loop over `result.stretches[k]` (nearest first), keeping the first that fits with a straight predicate:

```teal
-- A junction's placement lies wholly on straight midline (milestone 4c stage 1): from its first cut to the end of our
-- straight past its approach (JUNCTION_STRAIGHT), the midline's direction stays within STRAIGHT_TOL of the first
-- cut's.
local STRAIGHT_TOL = 0.005
local function onStraight(e : PgraceRailRouterExisting.End) : function(PgraceRailRouterJunction.Layout) : boolean
	return function(j : PgraceRailRouterJunction.Layout) : boolean
		local first = math.huge
		for __, c in ipairs(j.cuts) do
			first = math.min(first, c.x)
		end
		return midline.straightUntil(e.frame, first, STRAIGHT_TOL) >= j.approachX + JUNCTION_STRAIGHT - 1e-6
	end
end
```

and in `existingStop`, where it now reads `local e = result.ends[k]` … `junction.fit(...)`:

```teal
			local e, j : PgraceRailRouterExisting.End, PgraceRailRouterJunction.Layout = nil, nil
			for __, s in ipairs(result.stretches[k] or {}) do
				j = junction.fit(s.length - JUNCTION_STRAIGHT, input.radius, sides[k], s.signals, s.nodes, onStraight(s))
				if j ~= nil then
					e = s
					break
				end
			end
```

Keep the notes for "left-hand" and "no double track" as they are; where no stretch gives a fit, the note becomes:
"has no room for a junction at its X end (needs N m of straight double track within 1.5 km; the longest straight is
M m)", with M the longest straight run found (`midline.straightUntil` over each stretch's samples: the largest
`straightUntil(f, x, tol) − x` with x stepped by `midline.STEP`; add it to `Result` as `longestStraight[k]` in
existing.tl, or compute it here). Update `route_test.lua`'s expectations for the old wording (grep "longest is").

- [ ] **Step 4: Our straight past the junction stays on straight midline.** In `stationEnds`, the junction branch
caps the extension at the stretch's end; cap it also at the straight's end:

```teal
		local straightEnd = midline.straightUntil(station.ends[k].frame, station.junctions[k].approachX, STRAIGHT_TOL)
		local ext = math.min(extensionLength(input, radius),
			station.ends[k].length - station.junctions[k].approachX - JUNCTION_STRAIGHT,
			straightEnd - station.junctions[k].approachX - JUNCTION_STRAIGHT)
```

- [ ] **Step 5: Run** the new route test (passes), `just verify`, `just regress`.

- [ ] **Step 6: Regression route.** In `tests/regression_test.lua`, add a route on `TEST_LINE1_MAP` that stops at
Aloha with its existing station (`existing = { "Aloha" }`, through `planOnMap`'s new option; pick the town pair so
the line passes through Aloha, e.g. Antelope → Bangor via Aloha, or what the map allows: list towns with
`lua tools/replay.lua --map ../maps/rail-router-test-5x14km-line1.map --list`). Expect: the plan joins Aloha at a
junction (no "a new station was planned" note), and the network builds it with no chunk problems
(`network.build`). Record its baseline figures as the other routes do (run once, copy the printed figures, with a
comment saying they were recorded for 4c stage 1).

- [ ] **Step 7: Commit**

```bash
git add mod tests
git commit -m "feat: junctions on the straight past an existing line's first curve (4c stage 1)"
```

### Task 6: Stage 1 docs and the in-game test

- [ ] **Step 1:** In the spec, add "As built (stage 1)" notes: what changed from the design (e.g. the reading-on
rules past structures and crossovers), and the offline result on the line1 map (where Aloha's junction went, how far
out).
- [ ] **Step 2:** `just verify`, `just regress`; commit `docs: 4c stage 1 as built`.
- [ ] **Step 3 (controller, not a subagent):** repoint the staging symlink at this worktree
(`ln -sfn <worktree>/mod/pgrace_rail_router <staging_area>/pgrace_rail_router`) and give the player the checklist:
restart, load the test save with Bangor → Imperial Beach built, plan a line stopping at Aloha with "Use the existing
station in Aloha" ticked, Find route (expect the joins row, no fallback note), Check (clean, 0 stations charged for
Aloha, "1 junction" in the log), Build, screenshot the junction from above, run trains through it both ways, click
its switches and the crossing node.

## Stage 2 (P17)

### Task 7: Probe P17, cuts on a curve

**Files:**
- Modify: `probe.tl` + `probe.d.tl`, `window.script.tl` (a P17 button beside P15/P16 in the probes list)

P17 is P15 (`probe.junction`, read it first: its three stages, one per click) on a curve. Copy its structure into
`probe.curveJunction(settings)`:

1. **Stage 1:** a double track east of the camera: 100 m straight, then a 220 m-radius arc (the planner's tightest)
   turning 30° to the left, then 100 m straight, built as P15 builds its track (one-way signals at the far end of
   each track as P15 does).
2. **Stage 2:** on the arc's middle piece, the junction from the **outside** of the curve (the right side, since the
   curve turns left): a merge switch into the near (outer) track and a crossing node on it, the crossing track's
   switch on the far track, laid out with `junction.fit` in a `midline.fromPoints` frame of the arc's midline (the
   frame from points sampled on the built track), mapped with `midline.world`/`vector` as `network.junctionEdges`
   does. Dry-run, log every piece's tightest radius (sample its Hermite curve), the dry run's errors and price, and
   build if clean.
3. **Stage 3:** the same from the **inside** of the curve, on a fresh copy of stage 1's track 300 m further east
   (build it first in the same stage).

Log lines `[rail_router] PROBE P17 ...` with each split (piece, parameter), each new piece (ends, tangents, tightest
radius), the dry run's messages, and whether it built. Mark everything `-- PROBE (remove before release)`.

- [ ] **Step 1:** implement stage 1; `just check`.
- [ ] **Step 2:** stages 2 and 3; `just check`, `just test`.
- [ ] **Step 3:** commit `feat: probe P17, a flat junction cut into curved track`.
- [ ] **Step 4 (controller):** the player runs P17 on the flat test map (New Game → Play Map, the empty map): one
click per stage, screenshots, then the log is read: does a switch cut into a curved piece build; does the crossing
node on a curve build; which branch radii passed.

### Task 8: Record P17, plan stage 3

- [ ] **Step 1:** Write P17's findings into the spec ("What P17 found") and `AGENTS.md` in the kit (under "Track from
a script"), and commit both.
- [ ] **Step 2 (controller):** write the stage 3 plan (`docs/superpowers/plans/…-m4c-stage3.md`): placements on
curves (the `accept` predicate becomes the radius and clearance checks), the two kept places per end, and the
planner's choice between them, sized by what P17 showed.
