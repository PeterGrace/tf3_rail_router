# Rail Router Milestone 2: the game's price (dry runs) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** turn a finished plan into the proposals the game would build (two tracks with bridges and tunnels, and one
modular station per stop), dry-run each one, and show the game's own price and any errors in the window. Nothing is
built yet (that is milestone 3).

**Architecture:** a new pure module, `planner/network.tl`, turns each leg's pieces and heights into Hermite edges for
two parallel tracks and groups them into chunks of about 2 km. A second pure module, `planner/stationlayout.tl`, gives a
station's modules and placement. A new engine-side module, `builder.tl`, turns those into `SimpleProposal`s and
dry-runs them one per frame from a join. The window gets a **Check with the game** button that runs the dry runs and
shows the summed price and the errors. A temporary probe module, `probe.tl`, answers the open questions about the
engine (tangent lengths, segment limits, bridge strips, crossings, station modules) in one in-game session before the
builder's numbers are trusted.

**Tech Stack:** Teal (typed Lua) checked against the game's tealdefs with `just check`; plain-Lua unit tests
(`tests/*_test.lua`, `just test`); the game's Lua is 5.2.2 (5.1-like: no `goto`, no `//`, no `math.tointeger`);
in-game Lua runs about 4× slower than desktop Lua; engine calls only from `react.enqueueJoin` joins (main thread).

---

## Before you start

Read these first. They hold the facts this plan relies on:

- `/home/pgrace/repos/tf3_mods/AGENTS.md`, especially: "Teal gotchas" (an unused `local type X = Mod.Y` alias crashes
  the whole UI at load; loop variables are `__`, not `_`), "Building on the map from a script" (dry runs, "never send a
  proposal that didn't dry-run clean", copying positions out of engine data), "Debugging with probes".
- `docs/superpowers/specs/2026-10-16-rail-router-design.md`, sections Architecture, Building, Milestones.
- The research summary for this milestone:
  `/tmp/claude-1000/-home-pgrace-repos-tf3-mods-tf3-rail-router/e4279592-b734-4ff0-b0da-48753f8e339b/scratchpad/m2research/findings.md`
  (track `SegmentAndEntity` fields, bridge and tunnel types, the modular station's slots, probes P1–P7). The base-game
  sources it cites are extracted under the same `m2research/src/` folder.
- Reference code that already builds in-game: Bus Loops' `tf3_bus_loops/mod/pgrace_bus_loops/content/bus_loops/bus_loops_station.lua`
  (`newContext`, `dryRun`, `stationProposal`), and the base game's
  `m2research/src/mission/mission/tasks/auto_builder/track_builder.tl` (a track `SegmentAndEntity` from Lua).

**Workspace:** create a worktree: `git worktree add .worktrees/m2 -b feat/m2-dry-run main` in
`/home/pgrace/repos/tf3_mods/tf3_rail_router`, then `ln -s ../../.tools .worktrees/m2/.tools` (don't commit the link).
The game loads the mod from `.worktrees/play` (main). For the in-game session, repoint the staging symlink to the m2
worktree (AGENTS.md "Worktrees"):

```bash
ln -sfn /home/pgrace/repos/tf3_mods/tf3_rail_router/.worktrees/m2/mod/pgrace_rail_router \
  ~/.local/share/Steam/userdata/12818001/3493540/local/staging_area/pgrace_rail_router
```

and point it back at `.worktrees/play/mod/pgrace_rail_router` after the session.

**Commits:** small, conventional prefixes, every message ending with
`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Don't push.

## File structure

| File | New? | Responsibility |
|---|---|---|
| `mod/pgrace_rail_router/tealdef/gui/pgrace_rail_router/planner/network.d.tl` | new | Types: `Pt3`, `Edge`, `Chunk`, `Network`, `Options`; `network.build`. |
| `mod/pgrace_rail_router/content/gui/pgrace_rail_router/planner/network.tl` | new | Pure: legs → edges for two tracks, split at spans and at the longest edge, tangents, heights, chunks. |
| `mod/pgrace_rail_router/tealdef/gui/pgrace_rail_router/planner/stationlayout.d.tl` | new | Types: `Layout`, `Module`; `stationlayout.layout`. |
| `mod/pgrace_rail_router/content/gui/pgrace_rail_router/planner/stationlayout.tl` | new | Pure: a 2-track through station's modules (slots) and its placement (angle, origin) and end points. |
| `mod/pgrace_rail_router/tealdef/gui/pgrace_rail_router/builder.d.tl` | new | Types: `Check`, `Item`, `Outcome`; `builder.start`, `builder.step`. |
| `mod/pgrace_rail_router/content/gui/pgrace_rail_router/builder.tl` | new | Engine side: proposals from network chunks and station layouts, dry runs one per step, summed price and errors. |
| `mod/pgrace_rail_router/tealdef/gui/pgrace_rail_router/probe.d.tl` | new (temporary) | Types for the probes. |
| `mod/pgrace_rail_router/content/gui/pgrace_rail_router/probe.tl` | new (temporary) | P1–P6 probes, logging `[rail_router] PROBE` lines. Removed before release. |
| `mod/pgrace_rail_router/tealdef/pgrace_rail_router_def.d.tl` | modify | Register the four new `.d.tl` files. |
| `mod/pgrace_rail_router/content/gui/pgrace_rail_router/survey.tl` | modify | `survey.structureTypes()`: bridge and tunnel types as plain data. |
| `mod/pgrace_rail_router/content/gui/pgrace_rail_router/planner/modes.tl` (+ `.d.tl`) | modify | `StructureType` record; `modes.bridgeFor`, `modes.tunnelFor`. |
| `mod/pgrace_rail_router/content/gui/pgrace_rail_router/window.script.tl` | modify | Probe buttons (temporary); **Check with the game** button, progress, price and errors. |
| `tests/network_test.lua`, `tests/stationlayout_test.lua`, `tests/modes_test.lua` | new / modify | Unit tests. |
| `tests/regression_test.lua` | modify | Every regression plan's network is well-formed. |
| `docs/superpowers/specs/2026-10-16-rail-router-design.md` | modify | Probe findings, network and builder sections. |
| `/home/pgrace/repos/tf3_mods/AGENTS.md` (kit repo) | modify | Probe findings that hold for any mod. |

Data the pure modules work on (already in the code, see `planner/route.d.tl`, `planner/smooth.d.tl`):

- `Plan.legs[i]`: `pieces` (2-D straights and arcs: `kind`, `a`, `b`, `length`, arcs also `radius`, `centre`, `turn`
  in radians, positive left), `samples` (`p`, `s` metres along), `z` (track height per sample), `spans` (`kind`
  "ground"/"bridge"/"tunnel", `s0`, `s1`).
- `Plan.stations[i]`: `site.centre`, `site.dir` (unit, direction of travel), `z`.
- `Plan.platformLength` (80, 120, 160, 240 or 320 m).

---

## Part A: the pure network (offline)

### Task 1: `network.tl`: one track's edges along a leg

**Files:**
- Create: `mod/pgrace_rail_router/tealdef/gui/pgrace_rail_router/planner/network.d.tl`
- Create: `mod/pgrace_rail_router/content/gui/pgrace_rail_router/planner/network.tl`
- Modify: `mod/pgrace_rail_router/tealdef/pgrace_rail_router_def.d.tl` (add `require "gui.pgrace_rail_router.planner.network"` after the `planner.arrows` line)
- Test: `tests/network_test.lua`

The edge geometry follows the game's cubic Hermite curves: `p(t) = h00 p0 + h10 t0 + h01 p1 + h11 t1`. For a
straight, both tangents are the chord. For an arc turning by θ at radius R, both tangents have length
`4 R tan(θ/4)` (the best cubic fit to a circle; for small θ it is about `R θ`, the arc length). Probe P1 checks
which length the game's own curves use; `Options.tangent` switches the rule.

- [ ] **Step 1: Write the type definitions**

`mod/pgrace_rail_router/tealdef/gui/pgrace_rail_router/planner/network.d.tl`:

```lua
-- The track a plan builds, as the game's edges: two parallel tracks along each leg, as cubic Hermite curves between
-- nodes, split where a bridge or tunnel starts or ends and wherever a piece is longer than an edge may be, and grouped
-- into chunks for the dry runs (and in milestone 3, building). Pure (no api.*).
global record PgraceRailRouterNetwork
	record Pt3
		x : number
		y : number
		z : number
	end

	record Edge
		-- Indices into Network.nodes.
		node0 : integer
		node1 : integer
		p0 : Pt3
		p1 : Pt3
		-- Hermite tangents (their length is the curve's parameter scale; z is the grade times their length in plan).
		t0 : Pt3
		t1 : Pt3
		-- "ground", "bridge" or "tunnel".
		kind : string
		-- 1: the left track (in the leg's direction of travel), 2: the right.
		track : integer
		leg : integer
		-- Metres along the leg's centre line where the edge starts and ends.
		s0 : number
		s1 : number
	end

	-- A run of edges dry-run (and later built) as one proposal: Network.edges[first .. last].
	record Chunk
		first : integer
		last : integer
		leg : integer
		-- Track metres in it (both tracks).
		length : number
	end

	record Network
		nodes : {Pt3}
		edges : {Edge}
		chunks : {Chunk}
	end

	record Options
		-- Half the distance between the two tracks' centre lines (metres; trackDistance / 2).
		offset : number
		-- The longest an edge may be (metres along the centre line).
		maxEdge : number
		-- About how much centre line goes into one chunk (metres); a bridge or tunnel is never split between two.
		chunkLength : number
		-- "circle" (tangent length 4 R tan(θ/4)) or "arc" (R θ): which the game's curves use (probe P1).
		tangent : string
	end

	-- The defaults: offset 2.5, maxEdge 250, chunkLength 2000, tangent "circle".
	defaults : function() : Options
	-- One track's edges along a leg, `side` +1 for the left track, -1 for the right, without node indices.
	trackEdges : function(leg : PgraceRailRouterRoute.Leg, legIndex : integer, side : number, options : Options) : {Edge}
	-- The whole plan's network.
	build : function(plan : PgraceRailRouterRoute.Plan, options : Options) : Network
end
```

- [ ] **Step 2: Write the failing tests for one track**

`tests/network_test.lua`:

```lua
local t = ...
local network = t.requireTl("gui/pgrace_rail_router/planner/network.tl")

-- A leg along x from (0, 0): pieces as given, flat at height z unless heights are given as {s, z} pairs, spans as
-- {kind, s0, s1}. Samples every 25 m, as route.tl makes them.
local function leg(pieces, spans, heights)
	local total = 0
	for __, p in ipairs(pieces) do
		total = total + p.length
	end
	local samples, z = {}, {}
	local s = 0
	while true do
		table.insert(samples, { p = { x = s, y = 0 }, s = s })
		local h = 10
		if heights then
			for k = 1, #heights - 1 do
				local a, b = heights[k], heights[k + 1]
				if s >= a[1] and s <= b[1] then
					h = a[2] + (b[2] - a[2]) * (s - a[1]) / (b[1] - a[1])
				end
			end
		end
		table.insert(z, h)
		if s >= total then
			break
		end
		s = math.min(total, s + 25)
	end
	local list = {}
	for i, sp in ipairs(spans or { { "ground", 0, total } }) do
		list[i] = { kind = sp[1], s0 = sp[2], s1 = sp[3] }
	end
	return { pieces = pieces, samples = samples, z = z, spans = list, length = total }
end

local function straight(ax, ay, bx, by)
	local l = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
	return { kind = "straight", a = { x = ax, y = ay }, b = { x = bx, y = by }, length = l }
end

-- A left-turning arc of radius r from (ax, ay) heading +x, turning by `turn` radians.
local function arc(ax, ay, r, turn)
	local c = { x = ax, y = ay + r }
	local b = { x = c.x + r * math.sin(turn), y = c.y - r * math.cos(turn) }
	return { kind = "arc", a = { x = ax, y = ay }, b = b, length = r * turn, radius = r, centre = c, turn = turn }
end

local function hermite(e, u)
	local u2, u3 = u * u, u * u * u
	local h00, h10, h01, h11 = 2 * u3 - 3 * u2 + 1, u3 - 2 * u2 + u, -2 * u3 + 3 * u2, u3 - u2
	return {
		x = h00 * e.p0.x + h10 * e.t0.x + h01 * e.p1.x + h11 * e.t1.x,
		y = h00 * e.p0.y + h10 * e.t0.y + h01 * e.p1.y + h11 * e.t1.y,
		z = h00 * e.p0.z + h10 * e.t0.z + h01 * e.p1.z + h11 * e.t1.z,
	}
end

t.test("network: a straight is cut into edges no longer than maxEdge, offset to the left", function()
	local o = network.defaults()
	local edges = network.trackEdges(leg({ straight(0, 0, 600, 0) }), 1, 1, o)
	t.eq(#edges, 3, "600 m in edges of at most 250 m")
	for __, e in ipairs(edges) do
		t.near(e.p0.y, 2.5, 1e-9, "left track 2.5 m to the left")
		t.near(e.t0.x, e.p1.x - e.p0.x, 1e-9, "a straight's tangent is its chord")
		t.near(e.p0.z, 10, 1e-9, "flat")
	end
	t.near(edges[1].p0.x, 0, 1e-9, "starts at the leg's start")
	t.near(edges[3].p1.x, 600, 1e-9, "ends at its end")
	t.near(edges[1].p1.x, edges[2].p0.x, 1e-9, "edges join")
end)

t.test("network: an arc's edges stay on the offset circle", function()
	local o = network.defaults()
	local a = arc(0, 0, 500, math.pi / 2)
	local edges = network.trackEdges(leg({ a }), 1, -1, o)
	t.ok(#edges >= 4, "a 785 m arc in edges of at most 250 m")
	-- The right track (side -1) of a left turn runs on the outside: radius 502.5 about the same centre.
	for __, e in ipairs(edges) do
		for k = 0, 10 do
			local p = hermite(e, k / 10)
			local r = math.sqrt((p.x - a.centre.x) ^ 2 + (p.y - a.centre.y) ^ 2)
			t.near(r, 502.5, 0.05, "on the circle")
		end
	end
end)

t.test("network: edges split where a bridge starts and ends, and carry its kind", function()
	local o = network.defaults()
	local edges = network.trackEdges(leg({ straight(0, 0, 400, 0) },
		{ { "ground", 0, 120 }, { "bridge", 120, 230 }, { "ground", 230, 400 } }), 1, 1, o)
	local kinds = {}
	for __, e in ipairs(edges) do
		table.insert(kinds, ("%s %.0f-%.0f"):format(e.kind, e.s0, e.s1))
	end
	t.eq(table.concat(kinds, ", "), "ground 0-120, bridge 120-230, ground 230-400", "edges")
end)

t.test("network: heights and grades follow the profile, the same either side of a node", function()
	local o = network.defaults()
	local edges = network.trackEdges(leg({ straight(0, 0, 500, 0) }, nil, { { 0, 10 }, { 500, 30 } }), 1, 1, o)
	for __, e in ipairs(edges) do
		t.near(e.p1.z - e.p0.z, 20 * (e.s1 - e.s0) / 500, 1e-6, "height change")
		t.near(e.t0.z / math.sqrt(e.t0.x ^ 2 + e.t0.y ^ 2), 0.04, 1e-6, "4% grade at the start")
		t.near(e.t1.z / math.sqrt(e.t1.x ^ 2 + e.t1.y ^ 2), 0.04, 1e-6, "and at the end")
	end
end)
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `just test 2>&1 | grep -E "network|passed"`
Expected: an error that `planner/network.tl` doesn't exist.

- [ ] **Step 4: Write `network.tl` (one track)**

`mod/pgrace_rail_router/content/gui/pgrace_rail_router/planner/network.tl`:

```lua
local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo

local network : PgraceRailRouterNetwork = {}

local type Pt = PgraceRailRouterGeo.Pt
local type Pt3 = PgraceRailRouterNetwork.Pt3
local type Edge = PgraceRailRouterNetwork.Edge
local type Options = PgraceRailRouterNetwork.Options
local type Leg = PgraceRailRouterRoute.Leg
local type Piece = PgraceRailRouterSmooth.Piece

function network.defaults() : Options
	return { offset = 2.5, maxEdge = 250.0, chunkLength = 2000.0, tangent = "circle" }
end

-- The track's height at s metres along the leg (linear between samples), and its grade there (the slope of the
-- sample interval it falls in; at a sample, the mean of the two either side, so edges meeting there agree).
local function heightAt(leg : Leg, s : number) : number, number
	local samples, z = leg.samples, leg.z
	local n = #samples
	if s <= samples[1].s then
		local g = (z[2] - z[1]) / math.max(1e-9, samples[2].s - samples[1].s)
		return z[1], g
	end
	for i = 1, n - 1 do
		local a, b = samples[i].s, samples[i + 1].s
		if s <= b + 1e-9 then
			local g = (z[i + 1] - z[i]) / math.max(1e-9, b - a)
			local h = z[i] + g * (s - a)
			if math.abs(s - b) < 1e-6 and i + 1 < n then
				local g2 = (z[i + 2] - z[i + 1]) / math.max(1e-9, samples[i + 2].s - b)
				return z[i + 1], (g + g2) / 2
			elseif math.abs(s - a) < 1e-6 and i > 1 then
				local g0 = (z[i] - z[i - 1]) / math.max(1e-9, a - samples[i - 1].s)
				return z[i], (g0 + g) / 2
			end
			return h, g
		end
	end
	local g = (z[n] - z[n - 1]) / math.max(1e-9, samples[n].s - samples[n - 1].s)
	return z[n], g
end

-- A point and unit direction on a piece, `d` metres from its start, offset `off` metres to the left.
local function along(piece : Piece, d : number, off : number) : Pt, Pt
	if piece.kind == "arc" then
		local sign = piece.turn >= 0 and 1 or -1
		local start = geo.sub(piece.a, piece.centre)
		local angle = sign * d / piece.radius
		local radial = geo.rotate(start, angle)
		local dir = geo.norm(geo.rotate(radial, sign * math.pi / 2))
		local left : Pt = { x = -dir.y, y = dir.x }
		return geo.add(geo.add(piece.centre, radial), geo.scale(left, off)), dir
	end
	local dir = geo.norm(geo.sub(piece.b, piece.a))
	local left : Pt = { x = -dir.y, y = dir.x }
	return geo.add(geo.add(piece.a, geo.scale(dir, d)), geo.scale(left, off)), dir
end

-- The tangent length for a stretch of `length` metres of centre line on a piece, at offset `off`.
local function tangentLength(piece : Piece, length : number, off : number, rule : string) : number
	if piece.kind ~= "arc" then
		return length
	end
	local sign = piece.turn >= 0 and 1 or -1
	local theta = length / piece.radius
	local r = piece.radius - sign * off
	if rule == "arc" then
		return r * theta
	end
	return 4 * r * math.tan(theta / 4)
end

function network.trackEdges(leg : Leg, legIndex : integer, side : number, options : Options) : {Edge}
	local off = side * options.offset
	-- Where edges must break besides the pieces' ends: the spans' ends.
	local cuts : {number} = {}
	for __, span in ipairs(leg.spans) do
		table.insert(cuts, span.s0)
		table.insert(cuts, span.s1)
	end
	table.sort(cuts)
	local function kindAt(s : number) : string
		for __, span in ipairs(leg.spans) do
			if s >= span.s0 - 1e-6 and s < span.s1 - 1e-6 then
				return span.kind
			end
		end
		return "ground"
	end
	local edges : {Edge} = {}
	local s = 0.0
	for __, piece in ipairs(leg.pieces) do
		local pieceStart, pieceEnd = s, s + piece.length
		-- This piece's breaks: its ends, the span ends inside it, and as many more as keep edges within maxEdge.
		local breaks : {number} = { pieceStart }
		for __, c in ipairs(cuts) do
			if c > pieceStart + 1e-6 and c < pieceEnd - 1e-6 then
				table.insert(breaks, c)
			end
		end
		table.insert(breaks, pieceEnd)
		for k = 1, #breaks - 1 do
			local a, b = breaks[k], breaks[k + 1]
			local parts = math.max(1, math.ceil((b - a) / options.maxEdge - 1e-9))
			for m = 0, parts - 1 do
				local s0, s1 = a + (b - a) * m / parts, a + (b - a) * (m + 1) / parts
				local q0, d0 = along(piece, s0 - pieceStart, off)
				local q1, d1 = along(piece, s1 - pieceStart, off)
				local tl = tangentLength(piece, s1 - s0, off, options.tangent)
				local z0, g0 = heightAt(leg, s0)
				local z1, g1 = heightAt(leg, s1)
				table.insert(edges, {
					p0 = { x = q0.x, y = q0.y, z = z0 }, p1 = { x = q1.x, y = q1.y, z = z1 },
					t0 = { x = d0.x * tl, y = d0.y * tl, z = g0 * tl }, t1 = { x = d1.x * tl, y = d1.y * tl, z = g1 * tl },
					kind = kindAt((s0 + s1) / 2), track = side > 0 and 1 or 2, leg = legIndex, s0 = s0, s1 = s1,
				})
			end
		end
		s = pieceEnd
	end
	return edges
end

function network.build(plan : PgraceRailRouterRoute.Plan, options : Options) : PgraceRailRouterNetwork.Network
	return { nodes = {}, edges = {}, chunks = {} }
end

return network
```

Note: the height grade in `t.z` uses the grade per metre of **centre line**; on an offset arc the track's own length
differs by the factor r/R (2.5 m against the radius: under 1% above 250 m, 4.5% at the 55 m minimum). Accept it in
this milestone: the dry run reports "Too Much Incline" if it matters (probe P2 records the limit).

- [ ] **Step 5: Run the tests**

Run: `just test 2>&1 | grep -E "network|passed"`
Expected: the four `network:` tests PASS. If "on the circle" fails by more than 0.05 m, check `along`'s rotation sign
for left turns (positive `turn`, centre on the left).

- [ ] **Step 6: Type-check**

Run: `just check 2>&1 | tail -1`
Expected: `0 error(s)`. Every `local type` alias in `network.tl` must be used (AGENTS.md: an unused one crashes the
UI). `tests/runtime_globals_test.lua` checks this.

- [ ] **Step 7: Commit**

```bash
git add mod tests/network_test.lua
git commit -m "feat: network.trackEdges: one track's Hermite edges along a leg, split at spans and the longest edge

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 2: `network.build`: both tracks, shared nodes, chunks

**Files:**
- Modify: `mod/pgrace_rail_router/content/gui/pgrace_rail_router/planner/network.tl` (replace the stub `network.build`)
- Test: `tests/network_test.lua`

- [ ] **Step 1: Write the failing tests**

Append to `tests/network_test.lua`:

```lua
local function plan(legs)
	return { ok = true, legs = legs, stations = {}, platformLength = 160 }
end

t.test("network: both tracks, edges joined through shared nodes", function()
	local net = network.build(plan({ leg({ straight(0, 0, 600, 0) }) }), network.defaults())
	t.eq(#net.edges, 6, "three edges a track")
	t.eq(#net.nodes, 8, "four nodes a track")
	for k = 1, #net.edges - 1 do
		local a, b = net.edges[k], net.edges[k + 1]
		if a.track == b.track then
			t.eq(a.node1, b.node0, "consecutive edges share a node")
		end
	end
	for __, e in ipairs(net.edges) do
		local n0 = net.nodes[e.node0]
		t.near(n0.x, e.p0.x, 1e-9, "node at the edge's start")
		t.near(n0.y, e.p0.y, 1e-9, "node at the edge's start")
	end
end)

t.test("network: chunks of about chunkLength, never splitting a bridge", function()
	local o = network.defaults()
	o.chunkLength = 300
	local l = leg({ straight(0, 0, 1000, 0) },
		{ { "ground", 0, 250 }, { "bridge", 250, 450 }, { "ground", 450, 1000 } })
	local net = network.build(plan({ l }), o)
	t.ok(#net.chunks >= 2, "split into chunks")
	local covered = 0
	for k, c in ipairs(net.chunks) do
		if k > 1 then
			t.eq(c.first, net.chunks[k - 1].last + 1, "chunks follow each other")
		end
		-- A chunk's edges: both tracks over the same stretch of the leg.
		local lo, hi = math.huge, -math.huge
		for i = c.first, c.last do
			lo, hi = math.min(lo, net.edges[i].s0), math.max(hi, net.edges[i].s1)
		end
		t.ok(not (lo > 250 + 1e-6 and lo < 450 - 1e-6), "no chunk starts inside the bridge")
		covered = covered + (c.last - c.first + 1)
	end
	t.eq(covered, #net.edges, "every edge in one chunk")
end)

t.test("network: every leg gets its own chunks", function()
	local net = network.build(plan({ leg({ straight(0, 0, 300, 0) }), leg({ straight(0, 0, 300, 0) }) }),
		network.defaults())
	t.eq(net.chunks[1].leg, 1, "leg 1")
	t.eq(net.chunks[#net.chunks].leg, 2, "leg 2")
end)
```

- [ ] **Step 2: Run them to see them fail**

Run: `just test 2>&1 | grep -E "network|passed"`
Expected: the three new tests FAIL (the stub returns an empty network).

- [ ] **Step 3: Implement `network.build`**

Replace the stub in `network.tl`:

```lua
function network.build(plan : PgraceRailRouterRoute.Plan, options : Options) : PgraceRailRouterNetwork.Network
	local net : PgraceRailRouterNetwork.Network = { nodes = {}, edges = {}, chunks = {} }
	for li, leg in ipairs(plan.legs) do
		-- Each track's edges, then grouped by stretch: a chunk takes both tracks' edges between two cut points along
		-- the centre line, so the two tracks of a bridge are in one proposal (one parallel strip, probe P3).
		local tracks : {{Edge}} = { network.trackEdges(leg, li, 1, options), network.trackEdges(leg, li, -1, options) }
		for __, list in ipairs(tracks) do
			local previous : integer = nil
			for __, e in ipairs(list) do
				if previous == nil then
					table.insert(net.nodes, e.p0)
					previous = #net.nodes
				end
				table.insert(net.nodes, e.p1)
				e.node0, e.node1 = previous, #net.nodes
				previous = e.node1
			end
		end
		-- Chunk cut points: after chunkLength of centre line, at the next edge end that isn't inside a bridge or tunnel.
		local left, right = tracks[1], tracks[2]
		local k, startS = 1, 0.0
		while k <= #left do
			local j = k
			while j < #left and (left[j].s1 - startS < options.chunkLength or left[j + 1].kind ~= "ground"
					and left[j].kind ~= "ground") do
				j = j + 1
			end
			local first = #net.edges + 1
			local length = 0.0
			for m = k, j do
				table.insert(net.edges, left[m])
				length = length + (left[m].s1 - left[m].s0)
			end
			-- The right track's edges over the same stretch (the two tracks are cut at the same places).
			for m = k, j do
				table.insert(net.edges, right[m])
				length = length + (right[m].s1 - right[m].s0)
			end
			table.insert(net.chunks, { first = first, last = #net.edges, leg = li, length = length })
			startS = left[j].s1
			k = j + 1
		end
	end
	return net
end
```

The "never inside a bridge" rule: a chunk keeps growing while the edge it ends on and the next one are both
structures (a bridge or tunnel continues). Because both tracks are cut at the same `s` values (`trackEdges` breaks
at the same pieces, spans and `maxEdge` parts), `left[m]` and `right[m]` cover the same stretch.

- [ ] **Step 4: Run the tests**

Run: `just test 2>&1 | grep -E "network|passed"`
Expected: all seven `network:` tests PASS. If "both tracks" counts differ, check that `trackEdges` gives the same
number of edges for both sides (the cuts don't depend on `side`).

- [ ] **Step 5: Add a regression check**

In `tests/regression_test.lua`, next to the preview-arrow check (search for `arrows.split(leg, 100, 25)`), add, after
loading `local network = t.requireTl("gui/pgrace_rail_router/planner/network.tl")` at the top next to `arrows`:

```lua
			-- The network the dry runs would send: edges join, none longer than allowed, none of zero length.
			local net = network.build(plan, network.defaults())
			for __, e in ipairs(net.edges) do
				local len = math.sqrt((e.p1.x - e.p0.x) ^ 2 + (e.p1.y - e.p0.y) ^ 2)
				t.ok(len > 0.5, ("leg %d: a %.2f m edge at s %.0f"):format(e.leg, len, e.s0))
				t.ok(e.s1 - e.s0 <= network.defaults().maxEdge + 1e-6, "edge within maxEdge")
			end
			t.ok(#net.chunks > 0, "some chunks")
```

Run: `just regress 2>&1 | grep -E "^FAIL|passed"`
Expected: all pass. A failing "a 0.xx m edge" means a span boundary lies within half a metre of a piece end: in
`trackEdges`, skip a cut within 0.5 m of a piece's end (change `1e-6` to `0.5` in the `c > pieceStart + ...`
comparison) and re-run.

- [ ] **Step 6: Commit**

```bash
git add mod tests
git commit -m "feat: network.build: both tracks' edges with shared nodes, in chunks that keep bridges whole

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 3: `stationlayout.tl`: a 2-track through station's modules and placement

**Files:**
- Create: `mod/pgrace_rail_router/tealdef/gui/pgrace_rail_router/planner/stationlayout.d.tl`
- Create: `mod/pgrace_rail_router/content/gui/pgrace_rail_router/planner/stationlayout.tl`
- Modify: `mod/pgrace_rail_router/tealdef/pgrace_rail_router_def.d.tl` (register it)
- Test: `tests/stationlayout_test.lua`

From the research (`findings.md` §3; base `modular_station.script.lua:39-96`): module slots are i across (x = 5 i) and
j along (y = 40 j), each module 40 × 5 m. A 2-track through station: platform at i = 0, tracks at i = 1, 2, platform at
i = 3, for j = s .. e where count = platformLength / 40, k = count − 1, s = −floor(k/2), e = ceil(k/2). Slot ids:
track `8400000 + 1000 i + 10 j`, passenger platform `7400000 + 1000 i + 10 j`. Negative j works because
the id is a plain sum (j = −1 gives 8401000 − 10). The station's local frame: x across, y along; the tracks' centre
lines are at x = 5 and x = 10, so the station's axis is at x = 7.5. Module j spans local y from 40 j − 20 to
40 j + 20, so its track end nodes, at local (5, 40 s − 20), (10, 40 s − 20), (5, 40 e + 20), (10, 40 e + 20)
(`trainstationutil.lua:44-87`), are at the platforms' two ends.

Placement: the world transform is `Mat4f.rotZTransl(a, origin)`, local +y along `dir`:
`a = atan2(−dir.x, dir.y)`, local +x = (dir.y, −dir.x), and
`origin = centre − 7.5 · (dir.y, −dir.x) − 20 · (k mod 2) · dir`: with an odd number of modules (k even) the
platforms run from −40 k/2 − 20 to +40 k/2 + 20, centred on the origin; with an even number (k odd) they run from
40 s − 20 to 40 e + 20, centred 20 m ahead of it, so the origin moves back 20 m. Probe P6 checks this by dry-running a layout and logging its end nodes.

- [ ] **Step 1: Write the type definitions**

`mod/pgrace_rail_router/tealdef/gui/pgrace_rail_router/planner/stationlayout.d.tl`:

```lua
-- A 2-track passenger through station on the base game's modular station: its modules (slot id → module file) and
-- where it goes (rotation and origin for Mat4f.rotZTransl), and its four track ends in world coordinates. Pure.
global record PgraceRailRouterStationLayout
	record Module
		name : string
		variant : integer
	end

	-- One era's module files.
	record Era
		-- e.g. "::/stations/rail/modular_station/platform_passenger_era_c.module"
		platform : string
		-- The station track module for the line's track type (see trackModule).
		track : string
	end

	record Layout
		modules : {integer : Module}
		-- Rotation about z (radians) and the origin of the station's local frame (world, metres).
		angle : number
		origin : PgraceRailRouterGeo.Pt
		-- Track ends: {left track's start, right track's start, left's end, right's end} in the direction of travel
		-- (left/right as network.tl's tracks 1 and 2).
		ends : {PgraceRailRouterGeo.Pt}
	end

	-- Slot ids, as the station script mangles them.
	trackSlot : function(i : integer, j : integer) : integer
	platformSlot : function(i : integer, j : integer) : integer
	-- The station track module for a track template resource name, e.g.
	-- "::/infrastructure/track/standard/standard.street_template" →
	-- "::/trainstation___/infrastructure/track/standard/standard.street_template".
	trackModule : function(template : string) : string
	-- The layout for a site (centre, unit direction of travel) and platform length (a multiple of 40 m).
	layout : function(centre : PgraceRailRouterGeo.Pt, dir : PgraceRailRouterGeo.Pt, platformLength : number,
		era : Era) : Layout
end
```

- [ ] **Step 2: Write the failing tests**

`tests/stationlayout_test.lua`:

```lua
local t = ...
local sl = t.requireTl("gui/pgrace_rail_router/planner/stationlayout.tl")

local ERA = { platform = "P", track = "T" }

t.test("stationlayout: slot ids as the station script mangles them", function()
	t.eq(sl.trackSlot(1, 0), 8401000, "track i=1 j=0")
	t.eq(sl.trackSlot(2, -1), 8401990, "track i=2 j=-1")
	t.eq(sl.platformSlot(3, 2), 7403020, "platform i=3 j=2")
end)

t.test("stationlayout: a 160 m station has 4 modules along on each of its 4 rows", function()
	local l = sl.layout({ x = 0, y = 0 }, { x = 0, y = 1 }, 160, ERA)
	local tracks, platforms = 0, 0
	for __, m in pairs(l.modules) do
		if m.name == "T" then tracks = tracks + 1 elseif m.name == "P" then platforms = platforms + 1 end
	end
	t.eq(tracks, 8, "2 tracks × 4")
	t.eq(platforms, 8, "2 platforms × 4")
	t.ok(l.modules[sl.trackSlot(1, -1)] ~= nil and l.modules[sl.trackSlot(1, 2)] ~= nil, "j from -1 to 2")
end)

t.test("stationlayout: the track ends straddle the site's axis, at the platforms' ends", function()
	-- Facing north (+y): local x is east, so the left track (west) is 2.5 m west of the axis.
	local l = sl.layout({ x = 100, y = 200 }, { x = 0, y = 1 }, 160, ERA)
	t.near(l.angle, 0, 1e-9, "no rotation facing +y")
	t.near(l.ends[1].x, 97.5, 1e-9, "left track start x")
	t.near(l.ends[2].x, 102.5, 1e-9, "right track start x")
	t.near(l.ends[1].y, 200 - 80, 1e-9, "start 80 m behind the centre (half the platforms)")
	t.near(l.ends[3].y, 200 + 80, 1e-9, "end 80 m ahead")
end)

t.test("stationlayout: an odd number of modules is centred too, and turning the site turns the ends", function()
	local l = sl.layout({ x = 0, y = 0 }, { x = 1, y = 0 }, 120, ERA)
	-- Facing east: left is north (+y).
	t.near(l.ends[1].y, 2.5, 1e-9, "left track north of the axis")
	t.near(l.ends[1].x, -60, 1e-9, "half of 120 m behind")
	t.near(l.ends[3].x, 60, 1e-9, "and ahead")
end)
```

- [ ] **Step 3: Run them to see them fail**

Run: `just test 2>&1 | grep -E "stationlayout|passed"`
Expected: an error that `planner/stationlayout.tl` doesn't exist.

- [ ] **Step 4: Write `stationlayout.tl`**

```lua
local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo

local sl : PgraceRailRouterStationLayout = {}

local type Pt = PgraceRailRouterGeo.Pt
local type Layout = PgraceRailRouterStationLayout.Layout
local type Era = PgraceRailRouterStationLayout.Era

-- The station's two tracks' centre lines are at local x = 5 and 10: its axis at 7.5.
local AXIS_X = 7.5
local MODULE_LENGTH = 40.0

function sl.trackSlot(i : integer, j : integer) : integer
	return 8400000 + 1000 * i + 10 * j
end

function sl.platformSlot(i : integer, j : integer) : integer
	return 7400000 + 1000 * i + 10 * j
end

function sl.trackModule(template : string) : string
	return "::/trainstation___" .. template:sub(3)
end

function sl.layout(centre : Pt, dir : Pt, platformLength : number, era : Era) : Layout
	local count = math.max(1, math.floor(platformLength / MODULE_LENGTH + 0.5))
	local k = count - 1
	local s, e = -math.floor(k / 2), math.ceil(k / 2)
	local modules : {integer : PgraceRailRouterStationLayout.Module} = {}
	for j = s, e do
		modules[sl.platformSlot(0, j)] = { name = era.platform, variant = 0 }
		modules[sl.trackSlot(1, j)] = { name = era.track, variant = 0 }
		modules[sl.trackSlot(2, j)] = { name = era.track, variant = 0 }
		modules[sl.platformSlot(3, j)] = { name = era.platform, variant = 0 }
	end
	local localX : Pt = { x = dir.y, y = -dir.x }
	local origin = geo.sub(geo.sub(centre, geo.scale(localX, AXIS_X)), geo.scale(dir, 20 * (k % 2)))
	local function world(x : number, y : number) : Pt
		return geo.add(geo.add(origin, geo.scale(localX, x)), geo.scale(dir, y))
	end
	local y0, y1 = MODULE_LENGTH * s - 20, MODULE_LENGTH * e + 20
	-- Local +x is to the right of dir, so the track at x = 5 is the left of the two (network.tl's track 1).
	return {
		modules = modules,
		angle = math.atan(-dir.x, dir.y),
		origin = origin,
		ends = { world(5, y0), world(10, y0), world(5, y1), world(10, y1) },
	}
end

return sl
```

`math.atan(y, x)` with two arguments is `atan2` in Lua 5.3+, but **in 5.1/5.2 `math.atan` takes one argument**; the
game's Lua is 5.2.2. Use `math.atan2(-dir.x, dir.y)` if it exists, else compute it:

```lua
local function atan2(y : number, x : number) : number
	local f = (math as any as {string : function(number, number) : number}).atan2
	if f ~= nil then
		return f(y, x)
	end
	return math.atan(y, x)
end
```

and use `angle = atan2(-dir.x, dir.y)`. (The test runner's Lua 5.4 has no `math.atan2`, so the fallback runs there.)

- [ ] **Step 5: Run the tests**

Run: `just test 2>&1 | grep -E "stationlayout|passed"`
Expected: all four PASS. If an end is off by exactly 20 m along, the even/odd origin rule is the wrong way round
(try `20 * ((k + 1) % 2)`); probe P6 decides in-game which is right.

- [ ] **Step 6: Type-check and commit**

Run: `just check 2>&1 | tail -1` (expect `0 error(s)`), then:

```bash
git add mod tests/stationlayout_test.lua
git commit -m "feat: stationlayout: a 2-track through station's modules, placement and track ends

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 4: bridge and tunnel types

**Files:**
- Modify: `mod/pgrace_rail_router/tealdef/gui/pgrace_rail_router/planner/modes.d.tl`
- Modify: `mod/pgrace_rail_router/content/gui/pgrace_rail_router/planner/modes.tl`
- Modify: `mod/pgrace_rail_router/content/gui/pgrace_rail_router/survey.tl` (+ its `.d.tl`)
- Test: `tests/modes_test.lua`

The base game picks, for a track, the cheapest bridge type that is available this year, carries rail, may be picked
automatically (`isAutoSelectable ~= false`), and whose `speedLimit` is at least the track's speed; if none is fast
enough, the fastest such type (`construction_react_util.tl:305-349`). Same for tunnels. Do the same. (Rail bridge
speed limits: stone 90, trestle 60, steel 140, concrete 280 km/h; suspension, cable and tied arch are not
auto-selectable. So high-speed track at 350 km/h gets concrete, and the line is capped at 280 km/h on bridges; record
this in the spec's Known issues.)

- [ ] **Step 1: Add the record and functions to `modes.d.tl`**

Inside `global record PgraceRailRouterModes`, add:

```lua
	-- A bridge or tunnel type, as plain data (survey.structureTypes).
	record StructureType
		-- The resource name (bridgeTypeRep / tunnelTypeRep), and its index there (BaseEdge.typeIndex).
		name : string
		index : integer
		cost : number
		-- Metres per second.
		speedLimit : number
		yearFrom : integer
		yearTo : integer
		rail : boolean
		autoSelectable : boolean
	end

	-- The type the game would pick for track of `speed` in `year`: the cheapest available, rail-carrying,
	-- auto-selectable one at least that fast, else the fastest of them; nil if none.
	structureFor : function(types : {StructureType}, speed : number, year : integer) : StructureType
```

- [ ] **Step 2: Write the failing test**

Append to `tests/modes_test.lua`:

```lua
t.test("modes: the bridge picked is the cheapest fast enough, else the fastest", function()
	local function ty(name, cost, kmh, from, auto)
		return { name = name, index = 0, cost = cost, speedLimit = kmh / 3.6, yearFrom = from, yearTo = 0, rail = true,
			autoSelectable = auto ~= false }
	end
	local types = { ty("stone", 50, 90, 0), ty("steel", 120, 140, 1940), ty("concrete", 200, 280, 1970),
		ty("tarch", 900, 350, 2010, false) }
	t.eq(modes.structureFor(types, 80 / 3.6, 2000).name, "stone", "80 km/h")
	t.eq(modes.structureFor(types, 120 / 3.6, 2000).name, "steel", "120 km/h")
	t.eq(modes.structureFor(types, 350 / 3.6, 2050).name, "concrete", "350 km/h: none fast enough, the fastest")
	t.eq(modes.structureFor(types, 120 / 3.6, 1900).name, "stone", "steel not yet available")
end)
```

Run: `just test 2>&1 | grep -E "bridge picked|passed"` → FAIL (`structureFor` is nil).

- [ ] **Step 3: Implement in `modes.tl`**

```lua
function modes.structureFor(types : {StructureType}, speed : number, year : integer) : StructureType
	local cheapest, fastest : StructureType, StructureType = nil, nil
	for __, ty in ipairs(types) do
		local available = (ty.yearFrom <= year) and (ty.yearTo == 0 or year < ty.yearTo)
		if ty.rail and ty.autoSelectable and available then
			if ty.speedLimit >= speed - 1e-6 and (cheapest == nil or ty.cost < cheapest.cost) then
				cheapest = ty
			end
			if fastest == nil or ty.speedLimit > fastest.speedLimit then
				fastest = ty
			end
		end
	end
	return cheapest or fastest
end
```

(add `local type StructureType = PgraceRailRouterModes.StructureType` at the top; it's used, so it's safe.)

Run: `just test 2>&1 | grep -E "bridge picked|passed"` → PASS.

- [ ] **Step 4: Read the types in `survey.tl`**

Add to `survey.d.tl`: `structureTypes : function(rep : string) : {PgraceRailRouterModes.StructureType}` (rep
`"bridge"` or `"tunnel"`). In `survey.tl`:

```lua
function survey.structureTypes(which : string) : {StructureType}
	local result : {StructureType} = {}
	local rep = which == "tunnel" and api.res.tunnelTypeRep or api.res.bridgeTypeRep
	local rail = api.type["enum"].Carrier.RAIL
	for index, name in pairs(rep.getAll()) do
		local ok, ty = pcall(rep.get, index)
		if ok and ty ~= nil then
			local carriesRail = false
			for __, c in ipairs(ty.carriers or {}) do
				if c == rail then
					carriesRail = true
				end
			end
			table.insert(result, { name = name, index = index, cost = ty.cost or 0, speedLimit = ty.speedLimit or 0,
				yearFrom = ty.availability and ty.availability.yearFrom or 0,
				yearTo = ty.availability and ty.availability.yearTo or 0,
				rail = carriesRail, autoSelectable = ty.isAutoSelectable ~= false })
		end
	end
	return result
end
```

Notes: `rep.getAll()` returns `{index: name}` (res.d.tl:38). The tealdef types `carriers` as `{Carrier}`; if the
type-check rejects comparing with the enum value, compare `tostring(c) == tostring(rail)`. Tunnel types may have no
`carriers` or `speedLimit`; the defaults above make every tunnel "rail" only if listed, so probe P2 logs both lists:
if tunnels list no carriers, treat a missing list as carrying everything (`carriesRail = ty.carriers == nil or ...`).

- [ ] **Step 5: Type-check, test, commit**

Run: `just verify 2>&1 | grep -E "error\(s\)|passed"` → `0 error(s)`, all pass.

```bash
git add mod tests/modes_test.lua
git commit -m "feat: the bridge and tunnel type the game would pick for the line's track

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Part B: the builder and the probes (engine side)

### Task 5: `builder.tl`: proposals and one dry run per step

**Files:**
- Create: `mod/pgrace_rail_router/tealdef/gui/pgrace_rail_router/builder.d.tl`
- Create: `mod/pgrace_rail_router/content/gui/pgrace_rail_router/builder.tl`
- Modify: `mod/pgrace_rail_router/tealdef/pgrace_rail_router_def.d.tl` (register it)

Engine code can't be unit-tested; it's verified by `just check` and in-game. Keep the pure parts in Tasks 1–4.

- [ ] **Step 1: Write the type definitions**

`mod/pgrace_rail_router/tealdef/gui/pgrace_rail_router/builder.d.tl`:

```lua
-- Turns a plan into the game's proposals (one per station, one per network chunk) and dry-runs them, one per step
-- from a join (each can take a few hundred milliseconds), summing the game's price and collecting its errors.
global record PgraceRailRouterBuilder
	-- What one proposal is: "station" (index into plan.stations) or "chunk" (index into network.chunks).
	record Item
		kind : string
		index : integer
	end

	record Outcome
		item : Item
		ok : boolean
		cost : integer
		-- The game's error messages (empty when clean), and where (the item's first point), for the window.
		messages : {string}
		x : number
		y : number
		-- Wall time of the dry run (microseconds).
		us : integer
	end

	record Settings
		-- Track template resource name (the electrified variant if chosen).
		track : string
		-- The track's top speed (m/s), for picking bridge and tunnel types.
		speed : number
		year : integer
		bridge : PgraceRailRouterModes.StructureType
		tunnel : PgraceRailRouterModes.StructureType
		era : PgraceRailRouterStationLayout.Era
		network : PgraceRailRouterNetwork.Options
	end

	record Check
		plan : PgraceRailRouterRoute.Plan
		settings : Settings
		net : PgraceRailRouterNetwork.Network
		items : {Item}
		next : integer
		outcomes : {Outcome}
		total : integer
		done : boolean
	end

	start : function(plan : PgraceRailRouterRoute.Plan, settings : Settings) : Check
	-- Dry-runs the next item. Main thread only (a join). Returns true when all are done.
	step : function(check : Check) : boolean
	progress : function(check : Check) : number
	-- The SimpleProposal for a chunk of the network (also used by the probes).
	chunkProposal : function(net : PgraceRailRouterNetwork.Network, first : integer, last : integer,
		settings : Settings) : SimpleProposal
	stationProposal : function(plan : PgraceRailRouterRoute.Plan, index : integer, settings : Settings) : SimpleProposal
	-- A dry run: whether it's clean, the price, the error messages, and its wall time in µs.
	dryRun : function(proposal : SimpleProposal) : boolean, integer, {string}, integer
end
```

- [ ] **Step 2: Write `builder.tl`**

```lua
local network = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/network.tl" as PgraceRailRouterNetwork
local sl = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/stationlayout.tl" as PgraceRailRouterStationLayout

local builder : PgraceRailRouterBuilder = {}

local type Check = PgraceRailRouterBuilder.Check
local type Settings = PgraceRailRouterBuilder.Settings
local type Network = PgraceRailRouterNetwork.Network
local type Pt3 = PgraceRailRouterNetwork.Pt3

local LOG_PREFIX = "[rail_router] "
local STATION_FILE = "::/stations/rail/modular_station/modular_station.con"

local function v3(p : Pt3) : Vec3f
	return api.type.Vec3f.new(p.x, p.y, p.z)
end

local function newContext() : Context
	local context = api.type.Context.new()
	context.player = api.engine.util.getPlayer()
	return context
end

function builder.chunkProposal(net : Network, first : integer, last : integer, settings : Settings) : SimpleProposal
	local proposal = api.type.SimpleProposal.new()
	local template = api.res.streetTemplateRep.get(api.res.streetTemplateRep.find(settings.track))
	local edgeType = api.type["enum"].BaseEdgeType
	-- Node ids in the proposal: new nodes are negative, -1, -2, ...; edges get their own negative ids.
	local nodeIds : {integer : integer} = {}
	local nodes : {NodeAndEntity} = {}
	local function node(index : integer) : integer
		if nodeIds[index] == nil then
			local n = api.type.NodeAndEntity.new()
			n.entity = -(#nodes + 1) - 1000
			n.comp.position = v3(net.nodes[index])
			table.insert(nodes, n)
			nodeIds[index] = n.entity
		end
		return nodeIds[index]
	end
	local edges : {SegmentAndEntity} = {}
	for i = first, last do
		local e = net.edges[i]
		local seg = api.type.SegmentAndEntity.new()
		seg.entity = -(#edges + 1)
		seg.type = 1
		seg.comp.node0 = node(e.node0)
		seg.comp.node1 = node(e.node1)
		seg.comp.position0 = v3(e.p0)
		seg.comp.position1 = v3(e.p1)
		seg.comp.tangent0 = v3(e.t0)
		seg.comp.tangent1 = v3(e.t1)
		if e.kind == "bridge" and settings.bridge ~= nil then
			seg.comp.type = edgeType.BRIDGE
			seg.comp.typeIndex = settings.bridge.index
		elseif e.kind == "tunnel" and settings.tunnel ~= nil then
			seg.comp.type = edgeType.TUNNEL
			seg.comp.typeIndex = settings.tunnel.index
		else
			seg.comp.type = edgeType.NORMAL
			seg.comp.typeIndex = -1
		end
		seg.comp.laneConfigs = template.laneConfigs
		seg.comp.roadTemplate = settings.track
		seg.comp.roadStyle = template.streetStyle
		seg.comp.roadType = api.type["enum"].RoadType.TRACK
		table.insert(edges, seg)
	end
	proposal.streetProposal.nodesToAdd = nodes
	proposal.streetProposal.edgesToAdd = edges
	return proposal
end

function builder.stationProposal(plan : PgraceRailRouterRoute.Plan, index : integer, settings : Settings) : SimpleProposal
	local station = plan.stations[index]
	local layout = sl.layout(station.site.centre, station.site.dir, plan.platformLength, settings.era)
	local modules : {integer : table} = {}
	for slot, m in pairs(layout.modules) do
		modules[slot] = { name = m.name, variant = m.variant }
	end
	local proposal = api.type.SimpleProposal.new()
	local ce = api.type.SimpleProposal.ConstructionEntity.new()
	ce.fileName = STATION_FILE
	ce.params = { modules = modules, year = settings.year, seed = 1 }
	ce.transf = api.type.Mat4f.rotZTransl(layout.angle, api.type.Vec3f.new(layout.origin.x, layout.origin.y, station.z))
	ce.name = station.town.name
	ce.playerEntity = api.engine.util.getPlayer()
	proposal.constructionsToAdd = { ce }
	return proposal
end

function builder.dryRun(proposal : SimpleProposal) : boolean, integer, {string}, integer
	local clock = api.type.Clock.new()
	local ok, data = pcall(api.engine.util.proposal.makeProposalData, proposal as any as Proposal, newContext())
	local us = math.floor(clock:getTime())
	if not ok then
		return false, 0, { "dry run failed: " .. tostring(data) }, us
	end
	local pd = data as ProposalData
	local messages : {string} = {}
	pcall(function() : boolean
		for __, m in ipairs(pd.errorState.messages or {}) do
			table.insert(messages, tostring(m))
		end
		return true
	end)
	local cost = 0
	pcall(function() : boolean
		cost = math.floor(tonumber(pd.costs) or 0)
		return true
	end)
	return #messages == 0, cost, messages, us
end

function builder.start(plan : PgraceRailRouterRoute.Plan, settings : Settings) : Check
	local net = network.build(plan, settings.network)
	local items : {PgraceRailRouterBuilder.Item} = {}
	for i = 1, #plan.stations do
		table.insert(items, { kind = "station", index = i })
	end
	for i = 1, #net.chunks do
		table.insert(items, { kind = "chunk", index = i })
	end
	return { plan = plan, settings = settings, net = net, items = items, next = 1, outcomes = {}, total = 0, done = false }
end

function builder.step(check : Check) : boolean
	if check.done then
		return true
	end
	local item = check.items[check.next]
	local proposal : SimpleProposal
	local x, y : number, number
	if item.kind == "station" then
		proposal = builder.stationProposal(check.plan, item.index, check.settings)
		local c = check.plan.stations[item.index].site.centre
		x, y = c.x, c.y
	else
		local chunk = check.net.chunks[item.index]
		proposal = builder.chunkProposal(check.net, chunk.first, chunk.last, check.settings)
		local p = check.net.edges[chunk.first].p0
		x, y = p.x, p.y
	end
	local ok, cost, messages, us = builder.dryRun(proposal)
	table.insert(check.outcomes, { item = item, ok = ok, cost = cost, messages = messages, x = x, y = y, us = us })
	check.total = check.total + cost
	debugPrint(LOG_PREFIX .. ("dry run %s %d: %s, cost %d, %d µs%s"):format(item.kind, item.index,
		ok and "clean" or "errors", cost, us, #messages > 0 and (": " .. table.concat(messages, "; ")) or ""))
	check.next = check.next + 1
	check.done = check.next > #check.items
	return check.done
end

function builder.progress(check : Check) : number
	return (check.next - 1) / math.max(1, #check.items)
end

return builder
```

Notes for the implementer:
- The tealdef may name the casts differently (`Proposal`, `ProposalData`, `SimpleProposal`, `NodeAndEntity`,
  `SegmentAndEntity`, `Context`); `just check` tells you. AGENTS.md: `makeProposalData` takes only a `SimpleProposal`
  despite the tealdef, hence the `as any as Proposal` cast.
- `typeIndex = -1` on NORMAL edges is a guess (the base track builder sets 1 on its tunnel/normal edges); probe P1
  logs what the game's own normal edges carry: use that.
- Nodes shared between chunks are new nodes in each chunk's proposal: the dry runs are independent. Milestone 3
  will pass the built nodes' entities instead.

- [ ] **Step 3: Type-check**

Run: `just check 2>&1 | tail -3` → `0 error(s)`. Fix the casts it reports.

- [ ] **Step 4: Commit**

```bash
git add mod
git commit -m "feat: builder: proposals for stations and network chunks, dry-run one per step

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 6: the probes (temporary)

**Files:**
- Create: `mod/pgrace_rail_router/tealdef/gui/pgrace_rail_router/probe.d.tl`
- Create: `mod/pgrace_rail_router/content/gui/pgrace_rail_router/probe.tl`
- Modify: `mod/pgrace_rail_router/tealdef/pgrace_rail_router_def.d.tl`, `window.script.tl`

Every probe logs lines starting `[rail_router] PROBE <name>` and runs from a join, one probe per click. Mark the code
`-- PROBE (remove before release)`. The probes are anchored at the camera's look-at point
(`api.gui.camera.getCenter()`), so the player chooses the spot by moving the camera. They use Task 5's real
`builder.chunkProposal` / `stationProposal`, so they test the code that will ship.

| Button | Probe | What it does and logs |
|---|---|---|
| Log track near camera | **P1** | Every `BASE_EDGE` within 300 m of the camera that has a `BASE_EDGE_TRACK` component: `type`, `typeIndex`, `position0/1`, `tangent0/1` and their lengths, the chord, the angle θ between the tangents, the radius R from chord and θ (`chord / (2 sin(θ/2))`), the ratios `|t| / (R θ)` and `|t| / (4 R tan(θ/4))`, `distance` if present (pcall), and the track's `trackType` and its template name (`streetTemplateRep.getName`, pcall). Also `api.engine.system.streetSystem` pieces at each end (`getNodeTrackSegments`). |
| Dry-run test track | **P2, P3** | At the camera, heading east, flat at ground height: double-track straights of 100, 250, 500, 1000, 2000 m (one edge per track: finds the longest edge allowed); a 500 m straight at grades 2, 8, 8.5, 9, 12, 14%; double-track 90° arcs at radii 300, 100, 55, 50, 45, 38 m; a 300 m double-track bridge (BRIDGE edges, the auto bridge type) and a 300 m tunnel at 20 m below ground; the same bridge with `tangent = "arc"` instead of "circle". Each: clean or the messages, cost, µs. |
| Dry-run across a street | **P4** | With the camera over a street: a 300 m double-track straight on the ground crossing it (no shared node), then the same as a bridge 8 m up. Messages, `collisionInfo.collisionEntities` (each entity's components: street, track, building), cost. |
| Dry-run a station | **P6** | A 160 m station (Task 3's layout, facing east at the camera, the era chosen by year as in Task 7) dry-run alone: messages, cost; `api.engine.util.construction.getConstructionResult(STATION_FILE, 4, params)` cost (pcall); the track module name used and whether `api.res.moduleRep.find(name)` finds it (pcall), for each of the three track types. |
| Build test straight (test map only) | **P5** | A 200 m double-track straight at the camera: dry run (must be clean), balance before (`api.engine.util.finance.getPlayersBalance(getPlayer())`), `api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(p, context, false, true), cb)`; in the callback: success, `res.resultProposalData.costs`, balance after, and the built edges' `BASE_EDGE` (re-read after the command) to compare with what was sent. |

P7 (joining track to a built station's end nodes) needs building stations, so it moves to milestone 3's plan.

- [ ] **Step 1: Write `probe.d.tl`**

```lua
-- PROBE (remove before release): one-off engine probes for milestone 2, run from the window's probe buttons.
global record PgraceRailRouterProbe
	-- Each runs once, on the main thread (a join), and logs "[rail_router] PROBE <name> ..." lines.
	logTrack : function()
	dryRunTrack : function(settings : PgraceRailRouterBuilder.Settings)
	dryRunCrossing : function(settings : PgraceRailRouterBuilder.Settings)
	dryRunStation : function(settings : PgraceRailRouterBuilder.Settings)
	buildStraight : function(settings : PgraceRailRouterBuilder.Settings)
end
```

- [ ] **Step 2: Write `probe.tl`**

The shared helpers and P1 and P2 in full; P3–P6 follow the same pattern (a network of edges at the camera, built
with `network.build` on a synthetic one-leg plan, then `builder.chunkProposal` + `builder.dryRun`).

```lua
-- PROBE (remove before release)
local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo
local network = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/network.tl" as PgraceRailRouterNetwork
local builder = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/builder.tl" as PgraceRailRouterBuilder
local sl = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/stationlayout.tl" as PgraceRailRouterStationLayout

local probe : PgraceRailRouterProbe = {}

local type Settings = PgraceRailRouterBuilder.Settings
local type Pt = PgraceRailRouterGeo.Pt

local function log(name : string, text : string)
	debugPrint("[rail_router] PROBE " .. name .. " " .. text)
end

local function camera() : Pt
	local c = api.gui.camera.getCenter()
	return { x = c.x, y = c.y }
end

local function groundAt(p : Pt) : number
	local ok, h = pcall(api.engine.terrain.getHeightAt, api.type.Vec2f.new(p.x, p.y))
	return ok and (h as number) or 0
end

-- A one-leg plan from `a` heading `dir` along the given pieces, at height z0 rising by `grade`, all of `kind`.
local function testPlan(pieces : {PgraceRailRouterSmooth.Piece}, z0 : number, grade : number,
		kind : string) : PgraceRailRouterRoute.Plan
	local total = 0.0
	for __, p in ipairs(pieces) do
		total = total + p.length
	end
	local samples : {PgraceRailRouterSmooth.Sample} = {}
	local z : {number} = {}
	local s = 0.0
	while true do
		table.insert(samples, { p = pieces[1].a, s = s })
		table.insert(z, z0 + grade * s)
		if s >= total then
			break
		end
		s = math.min(total, s + 25)
	end
	local leg = { pieces = pieces, samples = samples, z = z, spans = { { kind = kind, s0 = 0, s1 = total } },
		length = total } as PgraceRailRouterRoute.Leg
	return { ok = true, legs = { leg }, stations = {}, platformLength = 160 } as PgraceRailRouterRoute.Plan
end

local function straight(a : Pt, dir : Pt, length : number) : PgraceRailRouterSmooth.Piece
	return { kind = "straight", a = a, b = geo.add(a, geo.scale(dir, length)), length = length }
end

-- A left arc from a heading dir.
local function leftArc(a : Pt, dir : Pt, radius : number, turn : number) : PgraceRailRouterSmooth.Piece
	local left : Pt = { x = -dir.y, y = dir.x }
	local centre = geo.add(a, geo.scale(left, radius))
	local b = geo.add(centre, geo.rotate(geo.sub(a, centre), turn))
	return { kind = "arc", a = a, b = b, length = radius * turn, radius = radius, centre = centre, turn = turn }
end

local function tryPlan(name : string, plan : PgraceRailRouterRoute.Plan, settings : Settings, options : PgraceRailRouterNetwork.Options)
	local net = network.build(plan, options)
	local ok, cost, messages, us = builder.dryRun(builder.chunkProposal(net, 1, #net.edges, settings))
	log(name, ("%s cost %d %d us edges %d %s"):format(ok and "clean" or "ERRORS", cost, us, #net.edges,
		table.concat(messages, "; ")))
end

function probe.logTrack()
	local c = camera()
	local edges = api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(c.x, c.y), 300,
		api.type.ComponentType.BASE_EDGE)
	for __, e in ipairs(edges) do
		local okT, track = pcall(api.engine.getComponent, e, api.type.ComponentType.BASE_EDGE_TRACK)
		if okT and track ~= nil then
			local edge = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE) as BaseEdge
			local p0, p1, t0, t1 = edge.position0, edge.position1, edge.tangent0, edge.tangent1
			local chord = math.sqrt((p1.x - p0.x) ^ 2 + (p1.y - p0.y) ^ 2)
			local lt0, lt1 = math.sqrt(t0.x ^ 2 + t0.y ^ 2), math.sqrt(t1.x ^ 2 + t1.y ^ 2)
			local theta = math.abs(geo.turnAngle({ x = t0.x, y = t0.y }, { x = t1.x, y = t1.y }))
			local r = theta > 1e-6 and chord / (2 * math.sin(theta / 2)) or math.huge
			local arcRatio = theta > 1e-6 and lt0 / (r * theta) or lt0 / chord
			local circleRatio = theta > 1e-6 and lt0 / (4 * r * math.tan(theta / 4)) or lt0 / chord
			local template = "?"
			pcall(function() : boolean
				template = api.res.streetTemplateRep.getName((track as any as {string : integer}).trackType)
				return true
			end)
			log("P1", ("edge %d type %s typeIndex %s chord %.2f |t0| %.2f |t1| %.2f t0.z %.3f t1.z %.3f theta %.4f R %.1f t/(R theta) %.4f t/(4R tan) %.4f p0 (%.1f %.1f %.1f) p1 (%.1f %.1f %.1f) template %s"):format(
				e, tostring(edge.type), tostring(edge.typeIndex), chord, lt0, lt1, t0.z, t1.z, theta, r, arcRatio, circleRatio,
				p0.x, p0.y, p0.z, p1.x, p1.y, p1.z, template))
		end
	end
	log("P1", "done")
end

function probe.dryRunTrack(settings : Settings)
	local c = camera()
	local east : Pt = { x = 1, y = 0 }
	local z = groundAt(c) + 0.5
	local o = network.defaults()
	o.maxEdge = 100000 -- one edge per track: find the game's own limit
	for __, length in ipairs({ 100, 250, 500, 1000, 2000 }) do
		tryPlan("P2 straight " .. length, testPlan({ straight(c, east, length) }, z, 0, "ground"), settings, o)
	end
	o = network.defaults()
	for __, grade in ipairs({ 0.02, 0.08, 0.085, 0.09, 0.12, 0.14 }) do
		tryPlan(("P2 grade %.3f"):format(grade), testPlan({ straight(c, east, 500) }, z, grade, "ground"), settings, o)
	end
	for __, radius in ipairs({ 300, 100, 55, 50, 45, 38 }) do
		tryPlan("P2 radius " .. radius, testPlan({ leftArc(c, east, radius, math.pi / 2) }, z, 0, "ground"), settings, o)
	end
	tryPlan("P3 bridge 300", testPlan({ straight(c, east, 300) }, z + 10, 0, "bridge"), settings, o)
	tryPlan("P3 tunnel 300", testPlan({ straight(c, east, 300) }, z - 20, 0, "tunnel"), settings, o)
	local arcRule = network.defaults()
	arcRule.tangent = "arc"
	tryPlan("P1 arc rule radius 300", testPlan({ leftArc(c, east, 300, math.pi / 2) }, z, 0, "ground"), settings, arcRule)
	tryPlan("P1 circle rule radius 300", testPlan({ leftArc(c, east, 300, math.pi / 2) }, z, 0, "ground"), settings, o)
	log("P2", "done")
end
```

Write `probe.dryRunCrossing`, `probe.dryRunStation` and `probe.buildStraight` the same way, following the table above:

- `dryRunCrossing`: two `tryPlan` calls (a 300 m straight centred on the camera heading east at ground height + 0.5,
  kind "ground"; the same at +8 m, kind "bridge"); after each, also log `#collisionInfo.collisionEntities` and for each
  entity which of `BASE_EDGE_STREET`, `BASE_EDGE_TRACK`, `TOWN_BUILDING`, `CONSTRUCTION` it has (pcall each
  `getComponent`). For that, make `tryPlan` return the raw `ProposalData` too (call `makeProposalData` directly
  inside the probe rather than through `builder.dryRun`).
- `dryRunStation`: build a one-station plan (`stations = { { town = { name = "Probe" }, site = { centre = c, dir = east,
  distance = 0 }, z = groundAt(c) } }`), then `builder.dryRun(builder.stationProposal(plan, 1, settings))`; log it; then
  `getConstructionResult` and `moduleRep.find` for `sl.trackModule(name)` of each track template from
  `survey.trackTypes()` and their catenary variants.
- `buildStraight`: as `tryPlan` for a 200 m straight; only if clean: log the balance, send the command, and in the
  callback log `success`, `res.resultProposalData.costs` (pcall), the balance again, and for each
  `res.proposal.proposal.addedSegments[i]` its `entity`, then re-read that entity's `BASE_EDGE` and log its positions
  and tangents (AGENTS.md: don't keep components across `sendCommand`; re-read after).

- [ ] **Step 3: Wire the buttons**

Do Task 7 Step 1 (`settingsFor`) first: the probes take the same settings. In `window.script.tl`, below the existing "Capture whole map (probe)" button, add one `builtin.Button` per probe,
each setting a module-level `pendingProbe : string` that the existing `react.onStep` join picks up (as it does for
`captureRef`). In the join: build the `Settings` as the window will for the dry runs (Task 7's `settingsFor`), call the
probe inside `pcall`, log any error with `debugPrint(LOG_PREFIX .. "probe error: " .. tostring(err))`, and clear
`pendingProbe`. Label them exactly as the table's first column ("Probe P1: log track near camera", and so on), with
`-- PROBE (remove before release)` above them.

- [ ] **Step 4: Type-check, test, commit**

Run: `just verify 2>&1 | grep -E "error\(s\)|passed"` → `0 error(s)`, all pass (`runtime_globals_test` checks the new
files for stray runtime reads of mod globals).

```bash
git add mod
git commit -m "chore: probes P1-P6 for the dry runs: track near the camera, test track, crossing, station, one build

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 7: the window's **Check with the game**

**Files:**
- Modify: `mod/pgrace_rail_router/content/gui/pgrace_rail_router/window.script.tl`

- [ ] **Step 1: Settings for the dry runs**

Add the requires at the top of `window.script.tl`, next to the existing ones:

```lua
local builder = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/builder.tl" as PgraceRailRouterBuilder
local network = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/network.tl" as PgraceRailRouterNetwork
local sl = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/stationlayout.tl" as PgraceRailRouterStationLayout
```

(`modes` and `survey` are already required there.) Then add a function next to `planDetail`:

```lua
-- The builder's settings for the window's choices: the track template (its electrified variant when ticked and
-- available), its speed, this year, the bridge and tunnel types the game would pick, and the station era.
local function settingsFor(track : PgraceRailRouterModes.TrackType, electrified : boolean,
		year : integer) : PgraceRailRouterBuilder.Settings
	local name = track.name
	if electrified and track.catenary ~= nil and year >= track.catenaryYearFrom then
		name = track.catenary
	end
	local era = "a"
	if year >= 1990 then
		era = "c"
	elseif year >= 1920 then
		era = "b"
	end
	return {
		track = name, speed = track.speed, year = year,
		bridge = modes.structureFor(survey.structureTypes("bridge"), track.speed, year),
		tunnel = modes.structureFor(survey.structureTypes("tunnel"), track.speed, year),
		era = { platform = "::/stations/rail/modular_station/platform_passenger_era_" .. era .. ".module",
			track = sl.trackModule(name) },
		network = network.defaults(),
	}
end
```

The era years (B from 1920) are from the research's "era C from 1990" and are checked by probe P6's log
(`moduleRep` availability); adjust them there if the log disagrees.

- [ ] **Step 2: State and stepping**

Add `local checkRef = react.useRef(nil)` (holding a `PgraceRailRouterBuilder.Check`) and
`local checkState = react.useState(nil)` (the finished `Check`, for display). Reset both wherever `planState:set(nil)`
is called (a new plan or a changed setting). In the `react.onStep` handler, before the capture branch: if
`checkRef:get() ~= nil`, queue one `safeJoin` that calls `builder.step(check)` inside `pcall` and, when it returns true,
moves it to `checkState` and clears `checkRef`. One item per join: a dry run can take 0.3 s (Bus Loops' station), so
never two in one frame.

- [ ] **Step 3: The button and the result**

In the result section (below "Show on map"), add:

- while no check has run: a button **Check with the game** (`meta = { class = "primary" }` as **Find route**) that
  sets `checkRef` to `builder.start(plan, settingsFor(track, settings.electrified, year))`;
- while it runs: `fill(_("Checking with the game… {done} of {total}"), ...)` from `check.next - 1` and `#check.items`;
- when done: `fill(_("The game's price: {price}"), { price = formatMoney(check.total) })` (the window's own
  `formatMoney`, `window.script.tl:173`, as the "our estimate" line uses), and below it, for
  each outcome with messages (at most 8, then "and N more"): `fill(_("{what}: {messages}"), ...)` where `what` is
  `fill(_("Station {town}"), ...)` or `fill(_("Track near km {km}"), ...)` (km along the route: the chunk's first
  edge's `s0` plus the lengths of the legs before it, divided by 1000, one decimal).

Keep the plan's own estimate line; the player sees both.

- [ ] **Step 4: Type-check, test, commit**

Run: `just verify 2>&1 | grep -E "error\(s\)|passed"` → `0 error(s)`, all pass.

```bash
git add mod
git commit -m "feat: Check with the game: dry-run the plan's stations and track, show the game's price and errors

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Part C: the in-game session, then acting on it

### Task 8: the probe session (the user, in-game)

- [ ] **Step 1: Point the game at the worktree** (the `ln -sfn` command under "Before you start") and ask the user to
restart TF3.

- [ ] **Step 2: Give the user this checklist** (the flat test map, "rail-router-test", with the mod enabled; never
the active save for P5):

1. Build by hand, somewhere open: a straight double track of about 300 m; a curve of about 90°; a short bridge over
   the lake; a short tunnel through a hill. Put the camera over them and click **Probe P1: log track near camera**.
2. Move the camera over flat open ground and click **Probe P2: dry-run test track**.
3. Move the camera over a street outside a town and click **Probe P4: dry-run across a street**.
4. Move the camera over flat open ground and click **Probe P6: dry-run a station**.
5. Over flat open ground on the test map, click **Probe P5: build test straight**, then look at it: does the track
   show where the camera was, as two straight tracks? Note the money before and after.
6. Plan Bangor → Imperial Beach (Cheapest) and click **Check with the game**: how long does it take, does the game
   stutter, and what does it show?
7. Say when done.

- [ ] **Step 3: Read the log**

```bash
grep -h "\[rail_router\] PROBE\|\[rail_router\] dry run" ~/.local/share/Steam/userdata/12818001/3493540/local/crash_dump/stdout.txt | tail -150
```

### Task 9: act on the findings

For each probe, decide and change the code; each is a small commit with a test where the change is in pure code.

- [ ] **P1 (tangent rule):** if the hand-built curve's `t/(4R tan)` is near 1, keep `tangent = "circle"`; if `t/(R theta)`
  is, change `network.defaults().tangent` to `"arc"` and update the arc test's expectation (the "on the circle" test
  allows 0.05 m: with the arc rule, a 90° edge at 250 m strays more; split arcs finer by lowering the edge's angle,
  adding `maxEdgeAngle` to `Options` if needed). Record `typeIndex` on normal edges and set it in
  `builder.chunkProposal`.
- [ ] **P2 (limits):** set `network.defaults().maxEdge` to the longest straight that dry-ran clean (keep a margin:
  the next value below it in the probe's list). Record the build limits for grade and radius in the spec; if the
  game refuses 8.5% (the track's `maxSlopeBuild`) or 55 m, tighten `modes.weights` to what it accepts.
- [ ] **P3 (bridges and tunnels):** if the bridge and tunnel dry-ran clean, nothing to do; if the messages say the two
  tracks' bridges collide, set `comp.distance`-style spacing as the research describes (`BaseEdge.distance =
  trackDistance`) or merge them into one strip as the log suggests, and re-run the probe.
- [ ] **P4 (crossings):** if a ground crossing without a shared node fails ("Collision"), keep crossings as bridges
  in this milestone (they already are where `weights.bridgeRoads`); for Cheapest, mark road crossings as needing a
  bridge in `profile.tl`'s crossing floors and re-record the regression baselines. Level crossings move to milestone 3.
- [ ] **P5 (price):** compare `ProposalData.costs` (dry run), `resultProposalData.costs` (callback) and the balance
  change. If they differ, show the dry run's figure labelled as the game's estimate and note the difference in the spec.
- [ ] **P6 (station):** if the dry run is clean and the logged end nodes (from Task 3's `ends`) match the station the
  game would draw, keep the layout; if the station is off by 20 m along or 7.5 m across, fix `stationlayout.tl`'s
  origin rule (and its tests). If the track module isn't found, log `moduleRep.getAll()` names containing
  "trainstation" and change `trackModule` to match.
- [ ] **Timing:** if a chunk's dry run takes more than about 50 ms in-game, lower `chunkLength` until it doesn't
  (smaller proposals) and say so in the spec; the check stays one dry run per frame.

### Task 10: write it down, then test the shipped behaviour

- [ ] **Step 1: Spec.** In `docs/superpowers/specs/2026-10-16-rail-router-design.md`, add sections "Network
  (`network.tl`)" and "Station layout (`stationlayout.tl`)" describing Tasks 1–3 as built, update "Building
  (`builder.tl`)" with what the probes found (tangent rule, longest edge, limits, bridge strips, crossings, price,
  station modules, timing), and add the bridge speed cap (concrete, 280 km/h, on high-speed lines) to Known issues.
- [ ] **Step 2: Kit notes.** In `/home/pgrace/repos/tf3_mods/AGENTS.md`, under "Building on the map from a script",
  add the findings that hold for any mod (tangent length rule, longest edge, track `SegmentAndEntity` fields that
  worked, how long a track dry run takes). Commit in the kit repo.
- [ ] **Step 3: Remove the probe buttons' P5 build** (it changes the map) but keep the others until milestone 3 is
  planned; commit.
- [ ] **Step 4: Ask the user for the milestone's in-game test:**
  1. On the test map, plan Bangor → Imperial Beach in both modes and click **Check with the game** each time: the
     game's price appears next to our estimate; how far apart are they?
  2. On a big save (PottstownTown, Dover → Camarillo): how long does the check take, and does anything stutter?
  3. Any errors listed: do they point at real problems on the map (screenshot the place)?
- [ ] **Step 5: Merge** `feat/m2-dry-run` into main locally once the user is happy (`git merge --no-ff` in
  `.worktrees/play`), point the staging symlink back at `.worktrees/play/mod/pgrace_rail_router`, and run
  `just verify` and `just regress` there.
