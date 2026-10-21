# Rail Router 4c stage 3: junctions on curves, and the choice between two places — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A junction into an existing station's double track may sit on a curve (spec placement "A"), each junction end
keeps up to two places (the nearest on straight midline, the nearest overall), and the planner plans the leg from each
and keeps the better line.

**Architecture:** A new pure module `planner/placement.tl` maps a junction layout through a midline frame and judges
it (tightest branch radius, room for our approach straight): `placement.accept` is the `accept` predicate
`junction.fit` already takes. `route.tl`'s `existingStop` fits each end twice (straight-only, then any) and keeps both
places on the station; the leg loop runs its usual search/simplify/fillet once per combination of its two ends'
places (at most 4) and keeps the best before fitting heights. Building needs nothing new: P17 showed the stage 1
builder (general Hermite split, frame-mapped pieces) builds junctions on a 220 m curve from either side.

**Tech Stack:** Teal (typed Lua; the game runs Lua 5.2), plain-Lua test runner (`just test`), regression routes on the
kit's maps (`just regress`).

---

## Read first

- Spec: `docs/superpowers/specs/2026-10-19-rail-router-junctions-along-the-track-design.md`, sections "Fitting",
  "Planner: choosing the place", "As built: stage 1", "What P17 found".
- `/home/pgrace/repos/tf3_mods/AGENTS.md` "Teal gotchas" (no unused `local type X = Mod.Y` alias, loop discards `__`,
  `c and a or b` with nil `a`, Lua 5.2 in-game).
- `planner/junction.tl` (`fit`, its `accept` argument, the 2 m `besideClear` rule), `planner/midline.d.tl`,
  `planner/route.tl` (`rayRoom`, `junctionEnds`, `onStraight`, `existingStop`, `leadIn`, the leg loop in
  `route.step` from `local a, b = plan.stations[job.legIndex]` down).

## Conventions every task follows

- Work in `/home/pgrace/repos/tf3_mods/tf3_rail_router/.worktrees/m4c` (branch `feat/m4c-curves`). Never `cd` to the
  main checkout; never bare `git stash`.
- Paths below are relative to `mod/pgrace_rail_router/content/gui/pgrace_rail_router/` for `.tl` files; type
  definitions are edited in `mod/pgrace_rail_router/tealdef/gui/pgrace_rail_router/...` (the `.d.tl` beside the `.tl`
  is a copy `just check` writes).
- After every edit: `just check` (must print `0 error(s)`); before each commit `just test` (all pass).
- Commits end with a blank line then `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Match the surrounding style: tabs, full-sentence comments where the code isn't obvious, `__` for discards.

## File map

- Create `planner/placement.tl`, `tealdef/.../planner/placement.d.tl`, `tests/placement_test.lua`.
- Modify `tealdef/pgrace_rail_router_def.d.tl` (register placement).
- Modify `planner/route.tl` and `tealdef/.../planner/route.d.tl` (rayRoom via placement; places; the choice).
- Modify `tests/route_test.lua`, `tests/regression_test.lua`.
- Modify the spec (as built: stage 3).

---

### Task 1: `placement.tl`, a layout mapped and judged in a frame

**Files:**
- Create: `planner/placement.tl`, `tealdef/gui/pgrace_rail_router/planner/placement.d.tl`, `tests/placement_test.lua`
- Modify: `tealdef/pgrace_rail_router_def.d.tl` (add `require "gui.pgrace_rail_router.planner.placement"` after
  the midline line)

- [ ] **Step 1: the type definitions**

`tealdef/gui/pgrace_rail_router/planner/placement.d.tl`:

```teal
-- A junction layout (PgraceRailRouterJunction.Layout) laid along an existing double track's midline frame, and
-- judged there (milestone 4c stage 3). Pure.
global record PgraceRailRouterPlacement
	record Options
		-- The tightest radius a mapped junction piece may have (metres).
		minRadius : number
		-- How far our straight past the approach start must run beside the track (route.tl's JUNCTION_STRAIGHT).
		straight : number
		-- Our tracks' midline's offset from the existing midline at the approach start (route.tl's JUNCTION_OFFSET).
		offset : number
		-- How much closer than `offset` the existing midline may come to our straight's ray (route.tl's RAY_SLACK).
		slack : number
		-- How far away it may get (a grid cell).
		cell : number
	end

	-- A frame piece as a world Hermite: its ends through midline.world, its tangents through midline.vector, as
	-- network.junctionEdges maps them.
	mapPiece : function(f : PgraceRailRouterMidline.Frame, p : PgraceRailRouterJunction.Piece)
		: PgraceRailRouterNetwork.Hermite
	-- The tightest radius along a Hermite's plan curve (64 samples, curvature of the cubic); math.huge if straight.
	tightest : function(h : PgraceRailRouterNetwork.Hermite) : number
	-- How far our straight, starting at frame (approachX, offset × side) along the frame's direction there, may run
	-- (metres along it): it ends at the first sample past the approach start whose midline comes within offset − slack
	-- of the ray, or lies more than `cell` from it on the far side, or lies no further along than the one before; else
	-- at the last sample.
	rayRoom : function(f : PgraceRailRouterMidline.Frame, approachX : number, side : number, offset : number,
		slack : number, cell : number) : number
	-- junction.fit's accept for placements anywhere on the stretch, curves included: every mapped piece no tighter
	-- than minRadius, and our straight past the approach start with rayRoom ≥ straight.
	accept : function(f : PgraceRailRouterMidline.Frame, side : number, o : Options)
		: function(PgraceRailRouterJunction.Layout) : boolean
end
```

Add `require "gui.pgrace_rail_router.planner.placement"` to `tealdef/pgrace_rail_router_def.d.tl` after the midline
line.

- [ ] **Step 2: the failing tests**

`tests/placement_test.lua` (the runner loads every `tests/*_test.lua`; see `tests/junction_test.lua` for `t`):

```lua
local t = ...
local placement = t.requireTl("gui/pgrace_rail_router/planner/placement.tl")
local midline = t.requireTl("gui/pgrace_rail_router/planner/midline.tl")
local junction = t.requireTl("gui/pgrace_rail_router/planner/junction.tl")

-- A midline: `straight` m along +x, then a left arc of radius r through `deg` degrees, then `tail` m straight.
local function track(straight, r, deg, tail)
	local pts = {}
	for x = 0, straight, 1 do
		pts[#pts + 1] = { x = x, y = 0, z = 0 }
	end
	local th = math.rad(deg)
	local n = math.ceil(r * th)
	for i = 1, n do
		local a = th * i / n
		pts[#pts + 1] = { x = straight + r * math.sin(a), y = r * (1 - math.cos(a)), z = 0 }
	end
	local ex, ey = straight + r * math.sin(th), r * (1 - math.cos(th))
	for s = 1, tail do
		pts[#pts + 1] = { x = ex + s * math.cos(th), y = ey + s * math.sin(th), z = 0 }
	end
	return midline.fromPoints(pts, midline.STEP)
end

local O = { minRadius = 100, straight = 50, offset = 10, slack = 0.5, cell = 100 }

t.test("placement: a frame piece maps onto a straight frame unchanged", function()
	local f = midline.line({ x = 0, y = 0 }, { x = 1, y = 0 }, 0, 0, 500)
	local h = placement.mapPiece(f, { x0 = 10, y0 = 2.5, x1 = 120, y1 = 12.5, tx0 = 110, ty0 = 0, tx1 = 110, ty1 = 0,
		role = "merge" })
	t.near(h.p0.x, 10, 1e-9, "p0 x")
	t.near(h.p0.y, 2.5, 1e-9, "p0 y")
	t.near(h.p1.y, 12.5, 1e-9, "p1 y")
	t.near(h.t0.x, 110, 1e-9, "t0 along")
	t.near(h.t1.y, 0, 1e-9, "t1 across")
end)

t.test("placement: tightest radius of an arc and a straight", function()
	-- A quarter circle of radius 200 as a Hermite (tangent length 4 r tan(θ/4)).
	local r, l = 200, 4 * 200 * math.tan(math.pi / 8)
	local h = { p0 = { x = 0, y = 0, z = 0 }, p1 = { x = r, y = r, z = 0 }, t0 = { x = l, y = 0, z = 0 },
		t1 = { x = 0, y = l, z = 0 } }
	t.near(placement.tightest(h), r, r * 0.02, "about 200 m")
	local s = { p0 = { x = 0, y = 0, z = 0 }, p1 = { x = 100, y = 0, z = 0 }, t0 = { x = 100, y = 0, z = 0 },
		t1 = { x = 100, y = 0, z = 0 } }
	t.eq(placement.tightest(s), math.huge, "straight")
end)

t.test("placement: our straight runs on beside a curve away from us, and stops where it curves towards us", function()
	local f = track(100, 220, 70, 300)
	-- Approach start at x = 150, on the arc. Our side −1 (right, the curve's outside): the track turns away, so the
	-- straight runs far; side +1 (inside): the track comes back across our straight within about 46 m.
	t.ok(placement.rayRoom(f, 150, -1, 10, 0.5, 100) >= 50, "outside: room for 50 m")
	t.ok(placement.rayRoom(f, 150, 1, 10, 0.5, 100) < 50, "inside: under 50 m")
	-- Past the arc (it ends at 100 + 268.8), the inside has room again.
	t.ok(placement.rayRoom(f, 400, 1, 10, 0.5, 100) >= 50, "inside, on the straight beyond: room")
end)

t.test("placement: accept takes a junction on a 220 m curve from the outside, its pieces 100 m or wider", function()
	local f = track(100, 220, 70, 300)
	local ok = placement.accept(f, -1, O)
	local j = junction.fit(f.length - 50, 300, -1, { near = {}, far = {} }, nil, ok)
	t.ok(j ~= nil, "fits")
	local first = math.huge
	for __, c in ipairs(j.cuts) do
		first = math.min(first, c.x)
	end
	t.ok(first < 100 + 268.8, ("the first cut (%.1f) is on the curve"):format(first))
	for __, p in ipairs(j.pieces) do
		t.ok(placement.tightest(placement.mapPiece(f, p)) >= 100, p.role .. " no tighter than 100 m")
	end
end)

t.test("placement: a branch tighter than the floor is refused", function()
	local f = track(100, 220, 70, 300)
	local strict = { minRadius = 1000, straight = 50, offset = 10, slack = 0.5, cell = 100 }
	local j = junction.fit(f.length - 50, 300, -1, { near = {}, far = {} }, nil, placement.accept(f, -1, strict))
	-- Only a placement wholly on the straight tail (its S-curves 300 m-ish there, but the fit's turnouts at 300 m
	-- are still under 1000 m): none.
	t.ok(j == nil, "no placement with every piece 1000 m or wider")
end)
```

- [ ] **Step 3: run them, see them fail**

Run: `just test 2>&1 | grep -E "placement|passed"`
Expected: an error loading `placement.tl` (module missing), or FAILs.

- [ ] **Step 4: the module**

`planner/placement.tl`:

```teal
local midline = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/midline.tl" as PgraceRailRouterMidline

local placement : PgraceRailRouterPlacement = {}

local type Hermite = PgraceRailRouterNetwork.Hermite
local type Frame = PgraceRailRouterMidline.Frame
local type Layout = PgraceRailRouterJunction.Layout

function placement.mapPiece(f : Frame, p : PgraceRailRouterJunction.Piece) : Hermite
	return { p0 = midline.world(f, p.x0, p.y0), p1 = midline.world(f, p.x1, p.y1),
		t0 = midline.vector(f, p.x0, p.tx0, p.ty0), t1 = midline.vector(f, p.x1, p.tx1, p.ty1) }
end

local SAMPLES = 64

function placement.tightest(h : Hermite) : number
	local best = math.huge
	for i = 0, SAMPLES do
		local t = i / SAMPLES
		-- First and second derivatives of the cubic Hermite in plan.
		local d1a, d1b, d1c, d1d = 6 * t * t - 6 * t, 3 * t * t - 4 * t + 1, -6 * t * t + 6 * t, 3 * t * t - 2 * t
		local d2a, d2b, d2c, d2d = 12 * t - 6, 6 * t - 4, -12 * t + 6, 6 * t - 2
		local dx = d1a * h.p0.x + d1b * h.t0.x + d1c * h.p1.x + d1d * h.t1.x
		local dy = d1a * h.p0.y + d1b * h.t0.y + d1c * h.p1.y + d1d * h.t1.y
		local ex = d2a * h.p0.x + d2b * h.t0.x + d2c * h.p1.x + d2d * h.t1.x
		local ey = d2a * h.p0.y + d2b * h.t0.y + d2c * h.p1.y + d2d * h.t1.y
		local cross = math.abs(dx * ey - dy * ex)
		if cross > 1e-9 then
			best = math.min(best, (dx * dx + dy * dy) ^ 1.5 / cross)
		end
	end
	return best
end

function placement.rayRoom(f : Frame, approachX : number, side : number, offset : number, slack : number,
		cell : number) : number
	local start = midline.world(f, approachX, offset * side)
	local __, out = midline.at(f, approachX)
	local d = 0.0
	for i = math.floor(approachX / f.step) + 2, #f.pts do
		local p = f.pts[i]
		local rx, ry = p.x - start.x, p.y - start.y
		local along = rx * out.x + ry * out.y
		-- The midline's offset from the ray towards our side: −offset where they run parallel.
		local across = (out.x * ry - out.y * rx) * side
		if across > -(offset - slack) or across < -cell or along <= d then
			break
		end
		d = along
	end
	return d
end

function placement.accept(f : Frame, side : number, o : PgraceRailRouterPlacement.Options) : function(Layout) : boolean
	return function(j : Layout) : boolean
		for __, p in ipairs(j.pieces) do
			if placement.tightest(placement.mapPiece(f, p)) < o.minRadius then
				return false
			end
		end
		return placement.rayRoom(f, j.approachX, side, o.offset, o.slack, o.cell) >= o.straight - 1e-6
	end
end

return placement
```

The `rayRoom` loop is `route.tl`'s `rayRoom` body, moved (Task 2 makes route call it). Check that the three `local
type` aliases are all used (they are: Hermite, Frame, Layout); `tests/runtime_globals_test.lua` fails otherwise.

- [ ] **Step 5: run the tests**

Run: `just check 2>&1 | tail -1 && just test 2>&1 | grep -E "^FAIL|passed"`
Expected: `0 error(s)`, no FAIL. If "a branch tighter than the floor" finds a placement, read its pieces' radii and
correct the test's reasoning rather than the module (on the 300 m tail the turnouts are 300 m class, so 1000 m must
refuse every placement).

- [ ] **Step 6: commit**

```bash
git add mod/pgrace_rail_router tests/placement_test.lua
git commit -m "feat: placement.tl maps a junction layout along a frame and judges its radius and approach room"
```

---

### Task 2: route's rayRoom through placement (no behaviour change)

**Files:** Modify `planner/route.tl` (`rayRoom`, about line 361).

- [ ] **Step 1:** add `local placement = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/placement.tl" as PgraceRailRouterPlacement`
beside route.tl's other `ug_require`s, and replace `rayRoom`'s body after the cache check with:

```teal
	local e, j, side = station.ends[k], station.junctions[k], station.sides[k]
	local d = placement.rayRoom(e.frame, j.approachX, side, JUNCTION_OFFSET, RAY_SLACK, input.grid.cell)
	station.rays[k] = d
	return d
```

Keep the function's comment (shorten the loop description to "see placement.rayRoom").

- [ ] **Step 2:** `just check`, `just test`, then `just regress` (about 30 s): every baseline unchanged.
- [ ] **Step 3:** commit `refactor: route's rayRoom is placement.rayRoom`.

---

### Task 3: two places per junction end

**Files:** Modify `planner/route.tl` (`existingStop`), `tealdef/.../planner/route.d.tl` (Station), `tests/route_test.lua`.

The station keeps, per junction end, its places nearest first: the nearest placement anywhere (`placement.accept`,
curves included) and, if different, the nearest wholly on straight midline (`onStraight`, stage 1's). `ends`,
`junctions` and `before` hold the place in use (the first, until the leg loop chooses).

- [ ] **Step 1: the type.** In `route.d.tl`, inside `record PgraceRailRouterRoute` add:

```teal
	-- One place a junction end may use (milestone 4c stage 3): the stretch it's on, the junction fitted there, the
	-- frames of the stretches before it (as Station.before), and whether it lies on curved midline.
	record Place
		stretch : PgraceRailRouterExisting.End
		junction : PgraceRailRouterJunction.Layout
		before : {PgraceRailRouterMidline.Frame}
		curved : boolean
	end
```

and in `record Station`, after `before`:

```teal
		-- Per junction end, its places, nearest first (one or two; see route.tl's existingStop): ends, junctions
		-- and before hold the one in use.
		places : {integer : {Place}}
```

and update the `ends`/`junctions` comment ("the nearest of the end's stretches with room for it on a straight part"
becomes "the place in use, see places").

- [ ] **Step 2: the failing tests** (in `tests/route_test.lua`, after the stage 1 curvedStation tests; `curvedStation`
builds 150 m straight past the platforms, a 300 m-radius left curve of `deg` degrees in 4 pieces, then 600 m straight):

```lua
t.test("route: an end whose curve has room keeps two places, the nearer on the curve (milestone 4c stage 3)", function()
	-- 90°: the curve is 471 m long, room for a junction on it; the straight tail has room too.
	local station, snap, curveEnd = curvedStation(3000, 90)
	local plan = runExisting({ town(2, "B", 3000, 0), town(3, "C", 3600, -1500) }, 1, station, snap)
	t.ok(plan.ok, "ok: " .. tostring(plan.failure))
	local b = plan.stations[1]
	local places = b.places[1]
	t.eq(#places, 2, "two places")
	t.ok(places[1].curved, "the first on the curve")
	t.ok(not places[2].curved, "the second on the straight")
	t.ok(places[1].junction.approachX + #places[1].before * 1e6 < places[2].junction.approachX + #places[2].before * 1e6,
		"nearest first")
	local first = math.huge
	for __, c in ipairs(places[1].junction.cuts) do
		first = math.min(first, c.x)
	end
	t.ok(first < curveEnd, "its first cut on the curve")
end)

t.test("route: where the nearest place is on the straight, there's one place", function()
	-- 10°: the curve is 52 m, no room on it.
	local station, snap = curvedStation(3000, 10)
	local plan = runExisting({ town(2, "B", 3000, 0), town(3, "C", 6000, 300) }, 1, station, snap)
	t.ok(plan.ok, "ok: " .. tostring(plan.failure))
	t.eq(#plan.stations[1].places[1], 1, "one place")
	t.ok(not plan.stations[1].places[1][1].curved, "on the straight")
end)
```

Check the towns' sides against `curvedStation`'s geometry before running (the curve turns left, +y; with C at
y = −1500 our side is the right, the curve's outside); adjust a town's position if a test fails for a reason other
than the missing feature, and say so in the commit message.

- [ ] **Step 3:** `just test 2>&1 | grep -E "^FAIL|passed"`: the two new tests fail (`places` is nil).

- [ ] **Step 4: implement.** In `route.tl`, near the other constants add:

```teal
-- The tightest a junction piece laid along a curve may be (spec "Fitting"): about 50 km/h at 2 m/s². P17's branches
-- on a 220 m curve with 300 m turnouts came to 102–123 m.
local MIN_BRANCH_RADIUS = 100.0
```

Replace the stretch loop in `existingStop` (from `-- The nearest stretch with room for a junction on a straight
part` to `ends[k], junctions[k], before[k] = e, j, passed`) with:

```teal
			-- The nearest placement anywhere on the end's stretches (curves included: placement.accept), and the nearest
			-- wholly on straight midline (onStraight), each with the frames of the stretches before it.
			local opts : PgraceRailRouterPlacement.Options = { minRadius = MIN_BRANCH_RADIUS, straight = JUNCTION_STRAIGHT,
				offset = JUNCTION_OFFSET, slack = RAY_SLACK, cell = input.grid.cell }
			local any, straight : Place, Place = nil, nil
			local passed : {PgraceRailRouterMidline.Frame} = {}
			local function copy() : {PgraceRailRouterMidline.Frame}
				local c : {PgraceRailRouterMidline.Frame} = {}
				for i, fr in ipairs(passed) do
					c[i] = fr
				end
				return c
			end
			for __, s in ipairs(result.stretches[k] or {}) do
				local length = s.length - JUNCTION_STRAIGHT
				if any == nil then
					local j = junction.fit(length, input.radius, sides[k], s.signals, s.nodes,
						placement.accept(s.frame, sides[k], opts))
					if j ~= nil then
						any = { stretch = s, junction = j, before = copy(), curved = not onStraight(s)(j) }
					end
				end
				if straight == nil then
					local j = junction.fit(length, input.radius, sides[k], s.signals, s.nodes, onStraight(s))
					if j ~= nil then
						straight = { stretch = s, junction = j, before = copy(), curved = false }
					end
				end
				if any ~= nil and straight ~= nil then
					break
				end
				table.insert(passed, s.frame)
			end
			if any == nil then
				return nil, note(("has no room for a junction at its %s end within %g km"):format(neighbours[forward].name,
					existing.REACH / 1000))
			end
			local list : {Place} = { any }
			if straight ~= nil and (straight.stretch ~= any.stretch
					or math.abs(straight.junction.approachX - any.junction.approachX) > 1e-6) then
				table.insert(list, straight)
			end
			places[k] = list
			ends[k], junctions[k], before[k] = any.stretch, any.junction, any.before
			z, n = z + any.stretch.z, n + 1
```

Notes for this step:
- Add `local type Place = PgraceRailRouterRoute.Place` near route.tl's other aliases (it's used, so it's safe), and
  declare `local places : {integer : {Place}} = {}` beside `local before ...`, and pass `places = places` in the
  `station` table literal.
- `RAY_SLACK` and `JUNCTION_OFFSET` are route.tl constants already (rayRoom used them).
- The "no room" note no longer mentions the straight it needs: update the existing test at `tests/route_test.lua`
  ("an existing station with no room for a junction falls back...") to the new text, `"The station in B has no room
  for a junction at its C end within 1.5 km; a new station was planned."` (check `existing.REACH`'s value; 1500 gives
  `1.5`).
- `result.longestStraight` is then unused by route.tl; leave `existing.tl` as it is.

- [ ] **Step 5:** `just check`, `just test`: all pass, including the stage 1 tests (with curves allowed, a place on the
curve may now come first: the stage 1 test "a junction goes on the straight past an existing line's first curve"
uses a 40° curve of 209 m, too short for a junction, so it still has one place, on the straight; if a stage 1 test
now finds a curve place, read why before changing the test).

- [ ] **Step 6:** `just regress`. Baselines may change where a curve place now comes first (the line1 map's Aloha:
its ends' stretches run through curves). Don't re-record yet: Task 4 makes the leg choose, which changes them again.
Note which routes changed in the commit message.

- [ ] **Step 7:** commit `feat: each junction end keeps its nearest place on a curve and its nearest on a straight`.

---

### Task 4: the leg chooses between its ends' places

**Files:** Modify `planner/route.tl` (leg loop, `nextLeg`), `tealdef/.../planner/route.d.tl` (Job), `tests/route_test.lua`.

How it works: when a leg starts (no search, no path, no `job.placing`), the combinations of its two ends' places are
listed (the leaving station `a` at `a.endOf[true]`, the arriving `b` at `b.endOf[false]`; an end without places, or a
station of ours, counts as one). With one combination nothing changes. With more, each combination in turn is put in
place (`setPlace`) and the leg runs its usual search, radius tries, simplify and fillet; when it would go on to its
heights, the combination is weighed instead, and the next one starts. After the last, the best is put back with its
path, simplified and fitted leg, and the leg carries on to its heights.

Weighing (spec "Planner: choosing the place"):
- **Cheapest** (`not timePriced(w)`): the search cost (`job.pathCost`). The spec says the plan's estimate; the search
  cost prices the same things (track, earthworks, structures) and is what the radius tries already weigh, and the
  estimate needs the heights fitted first (a whole extra profile per combination). Say so in the spec's as-built.
- **Fastest**: the time from platform end to platform end: the leg's length at `w.topSpeed` plus `legTimeLost`, plus
  each junction end's shared stretch (the existing track from the platform end to the junction's approach start) at
  `w.topSpeed`; ties (within 0.5 s) by search cost.

- [ ] **Step 1: Job fields** in `route.d.tl` `record Job` (internal):

```teal
		-- The leg's places being weighed (milestone 4c stage 3; nil when its ends have one combination): each
		-- combination (the leaving station's place index, the arriving one's), the one being tried, and the best so far
		-- with its leg as found.
		placing : Placing
```

and a record in `PgraceRailRouterRoute`:

```teal
	record Placing
		combos : {{integer}}
		index : integer
		best : integer
		bestScore : number
		bestCost : number
		path : {PgraceRailRouterGeo.Pt}
		simplified : Simplified
		fitted : PgraceRailRouterSmooth.Result
		radius : number
		cost : number
		chosen : boolean
	end
```

(`Simplified` is `PgraceRailRouterRoute.Simplified`, already declared in route.d.tl; match the field types `Job.path`,
`Job.simplified`, `Job.fitted` already use.)

- [ ] **Step 2: the failing tests:**

```lua
t.test("route: Cheapest takes the place whose leg costs less (milestone 4c stage 3)", function()
	-- 90° curve: places on the curve and on the straight tail. C beyond the curve's outside, south-east: the leg from
	-- the curve place runs straight off towards it; from the tail (heading north) it must turn back.
	local station, snap = curvedStation(3000, 90)
	local plan = runExisting({ town(2, "B", 3000, 0), town(3, "C", 3600, -1500) }, 1, station, snap)
	t.ok(plan.ok, "ok: " .. tostring(plan.failure))
	local b = plan.stations[1]
	t.eq(#b.places[1], 2, "two places weighed")
	t.ok(b.junctions[1] == b.places[1][1].junction, "the curve place taken")
	local found = false
	for __, n in ipairs(plan.notes) do
		found = found or n:find("Joins the existing line", 1, true) ~= nil
	end
	t.ok(found, "a note says where it joins")
end)

t.test("route: the leg's place is the straight one when the town lies beyond it", function()
	local station, snap = curvedStation(3000, 90)
	-- C far north, past the tail (which heads +y after a 90° left curve): the straight place leaves towards it.
	local plan = runExisting({ town(2, "B", 3000, 0), town(3, "C", 3100, 4000) }, 1, station, snap)
	t.ok(plan.ok, "ok: " .. tostring(plan.failure))
	local b = plan.stations[1]
	t.eq(#b.places[1], 2, "two places weighed")
	t.ok(b.junctions[1] == b.places[1][2].junction, "the straight place taken")
end)

t.test("route: with time priced, the place is chosen by time, shared track included", function()
	local station, snap = curvedStation(3000, 90)
	local plan = runExisting({ town(2, "B", 3000, 0), town(3, "C", 3600, -1500) }, 1, station, snap,
		{ weights = withWeights({ timeCost = 1, topSpeed = 40, lateralAccel = 1 }) })
	t.ok(plan.ok, "ok: " .. tostring(plan.failure))
	t.eq(#plan.stations[1].places[1], 2, "two places weighed")
end)
```

`withWeights` and `town` exist in route_test.lua; check `withWeights`' signature and the side of C (our side must be
the one the town lies on, which existingStop works out) before relying on the expected place; if the geometry makes
the other place cheaper for a sound reason, move C rather than weaken the assertion.

- [ ] **Step 3:** run, see the first two fail (`places` length 2 but the first place always taken, no note).

- [ ] **Step 4: implement.** In `route.tl`:

```teal
-- Puts place `idx` of station's end k in use (milestone 4c stage 3): its stretch, junction and the frames before it,
-- the end's ray measured again, and the footprints and free cells that follow the station's track redone.
local function setPlace(job : Job, station : Station, k : integer, idx : integer)
	local place = station.places[k][idx]
	station.ends[k], station.junctions[k], station.before[k] = place.stretch, place.junction, place.before
	if station.rays ~= nil then
		station.rays[k] = nil
	end
	local input, plan = job.input, job.result
	job.footprint, job.footprintVersion = footprints(input, plan, 0, nil), job.footprintVersion + 1
	job.alongFree = alongFreeCells(input, plan)
end

-- The number of places a leg's end has: a junction end's places, else 1.
local function placeCount(station : Station, k : integer) : integer
	if k == nil or station.places == nil or station.places[k] == nil then
		return 1
	end
	return #station.places[k]
end

-- The existing track a train runs from station's platform end to its junction at end k's approach start (metres).
local function sharedLength(station : Station, k : integer) : number
	local spans, x = leadIn(station, k)
	local d = station.junctions[k].approachX - x
	for __, s in ipairs(spans) do
		d = d + s.x1 - s.x0
	end
	return math.max(0, d - station.existing.half)
end

-- How far the platform end is from the junction's approach start, for the plan's note (whole metres).
local function placeNote(station : Station, k : integer) : string
	return ("Joins the existing line %d m out from %s's platforms."):format(math.floor(sharedLength(station, k) + 0.5),
		station.town.name)
end

-- The leg as found weighed against the best of its ends' places so far (see the plan's Task 4): true while more
-- combinations remain (the next is put in place, the leg searched again), false once the best is back in place.
local function weighPlace(job : Job, a : Station, b : Station) : boolean
	local input, pl = job.input, job.placing
	local w = input.weights
	local score = job.pathCost
	if timePriced(w) then
		local __, length = speed.pieceLimits(job.fitted.pieces, halfOf(input, a), w)
		local shared = 0.0
		if placeCount(a, a.endOf[true]) > 1 then
			shared = shared + sharedLength(a, a.endOf[true])
		end
		if placeCount(b, b.endOf[false]) > 1 then
			shared = shared + sharedLength(b, b.endOf[false])
		end
		score = (length + shared) / w.topSpeed + legTimeLost(input, job.fitted, a, b)
	end
	local better = pl.best == nil or score < pl.bestScore - (timePriced(w) and 0.5 or 0)
		or (timePriced(w) and math.abs(score - pl.bestScore) <= 0.5 and job.pathCost < pl.bestCost)
	if better then
		pl.best, pl.bestScore, pl.bestCost = pl.index, score, job.pathCost
		pl.path, pl.simplified, pl.fitted, pl.radius, pl.cost = job.path, job.simplified, job.fitted, job.searchRadius,
			job.pathCost
	end
	local function use(index : integer)
		local c = pl.combos[index]
		if placeCount(a, a.endOf[true]) > 1 then
			setPlace(job, a, a.endOf[true], c[1])
		end
		if placeCount(b, b.endOf[false]) > 1 then
			setPlace(job, b, b.endOf[false], c[2])
		end
	end
	if pl.index < #pl.combos then
		pl.index = pl.index + 1
		use(pl.index)
		job.path, job.simplified, job.fitted, job.searchRadius, job.pathCost = nil, nil, nil, nil, nil
		job.searchExpansions = job.searchExpansions or 0
		return true
	end
	use(pl.best)
	job.path, job.simplified, job.fitted, job.searchRadius, job.pathCost = pl.path, pl.simplified, pl.fitted, pl.radius,
		pl.cost
	pl.chosen = true
	if placeCount(a, a.endOf[true]) > 1 then
		table.insert(job.result.notes, placeNote(a, a.endOf[true]))
	end
	if placeCount(b, b.endOf[false]) > 1 then
		table.insert(job.result.notes, placeNote(b, b.endOf[false]))
	end
	return false
end
```

Wire it into `route.step`'s leg section:

1. At the leg's start, right before `if job.search == nil then` (the block that sets `job.radii`), add:

```teal
	if job.placing == nil and job.search == nil and job.radii == nil then
		local na, nb = placeCount(a, a.endOf[true]), placeCount(b, b.endOf[false])
		if na * nb > 1 then
			local combos : {{integer}} = {}
			for ia = 1, na do
				for ib = 1, nb do
					table.insert(combos, { ia, ib })
				end
			end
			job.placing = { combos = combos, index = 1 }
			if na > 1 then
				setPlace(job, a, a.endOf[true], 1)
			end
			if nb > 1 then
				setPlace(job, b, b.endOf[false], 1)
			end
		end
	end
```

2. In the `if job.path ~= nil then` branch, right before `if job.heights == nil then`, add:

```teal
		if job.placing ~= nil and not job.placing.chosen and job.resite == nil then
			if weighPlace(job, a, b) then
				return false
			end
		end
```

3. In `nextLeg`, set `job.placing = nil` before moving on.

4. `checkLeg` may start re-siting the leg's other station (one of ours) during a combination; that re-site
   runs once (`job.resited`) and replaces the leg's path, which then reaches the weigh point again: no special
   handling, but a test run must show no runaway (the tests' 100000-step guard).

5. `leg.searchExpansions` keeps summing all combinations' expansions (it reports work done).

- [ ] **Step 5:** `just check`, `just test`: all pass.

- [ ] **Step 6: progress.** `route.progress` must never go back (a test checks it for radius tries: "weighing every
radius, progress never goes back"). Run that test; if a placing combination resets the leg's share of progress,
make `route.progress` count a leg under weighing by `(index − 1 + its own fraction) / #combos` within the leg's
share. Add a test like the radius one with `curvedStation(3000, 90)` if `route.progress` needed a change.

- [ ] **Step 7: commit** `feat: a leg plans from each of its ends' places and keeps the cheaper (or faster) line`.

---

### Task 5: real maps: regression routes with a junction on a curve

**Files:** Modify `tests/regression_test.lua` (and baselines it records), `docs/...spec`.

- [ ] **Step 1: scan.** Write a scratch script (in the session scratchpad, not the repo) on `tools/replaylib.lua`:
for each of the kit maps with Rail Router lines (`../maps/rail-router-test-5x14km-line1.map`,
`../maps/rail-router-test-5x14km-junction.map`), each Rail Router station (`replaylib.existingFromMap`, as the
existing regression route "Antelope → Imperial Beach via Aloha" uses it) and each end, list its places (curved or
not, the approach start's distance from the platform end) as `existingStop` finds them (plan a one-leg route from the
station towards a town on that side with `replaylib.planOnMap{ existing = {...} }`, and read
`plan.stations[i].places`). Report the list in the task's summary.

- [ ] **Step 2: routes.** Add one or two regression routes (by the file's pattern) where the chosen place is on a
curve: a route stopping at such a station with `existing = { "<town>" }`. Each asserts (besides the file's usual
invariants and figures) that the station's end used has `places`, and the junction in use lies on curved midline:
`midline.straightUntil(e.frame, firstCut, 0.005) < j.approachX + 50`. Record their baselines.

- [ ] **Step 3:** re-record baselines that Tasks 3–4 changed (the Aloha route), each with a comment saying why (a
place on the curve was cheaper / the leg's place changed), and only after reading the new plan's figures: more tight
curves, steeper grades or a much higher estimate on a changed route is a bug to look at, not a baseline.

- [ ] **Step 4:** `just test`, `just regress` pass; commit `test: regression routes with a junction on a curve`.

---

### Task 6: docs and the in-game test

- [ ] **Step 1:** In the spec, add "As built: stage 3": placement.accept (radius floor 100 m, approach room; the
spec's clearance check left out: P17's mapped pieces matched the built curve within 0.03 m, and junction.fit's 2 m
node rule covers the joints), the two places, Cheapest weighed by search cost (why), Fastest by time with the shared
stretch, the note text, and the regression routes added. Commit `docs: 4c stage 3 as built`.
- [ ] **Step 2 (controller):** `just verify`, `just regress`; the staging symlink already points at this worktree;
give the player the checklist: from Task 5's scan, a route on their current junction-map save (or a fresh one with
line 1 built) whose existing station's only (or chosen) junction place is on a curve; Find route (expect the note
"Joins the existing line N m out"), Check, Build, screenshot, run a train through it both ways.
