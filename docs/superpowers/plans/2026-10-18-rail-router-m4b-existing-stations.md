# Rail Router Milestone 4b: Existing Stations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a stop town that already has a rail station gets no new station. Instead the new line joins that
station's double-track approach with a flat junction, so the lines share its platforms. 4b-2 adds a flying junction
where it fits.

**Architecture:**
- **Two new pure modules:**
  - `planner/junction.tl`: the junction's geometry, plus where it cuts the existing track.
  - `planner/existing.tl`: reads a snapshot of the track around a station and finds its usable approach ends.
- **Engine-side changes:**
  - The survey snapshots stations and track.
  - The route treats such a stop as a fixed point, with no site search, turning or re-siting.
  - The network adds the junction pieces and the cuts.
  - The build splits existing track first, then sends the junction chunk.
- **Probe P15 comes first** and gates Tasks 6–8. It checks splitting live track, track-over-track level crossings,
  and switches into signalled track.

**Tech stack:** Teal (typed Lua) checked against the game's tealdefs (`just check`), plain-Lua unit tests
(`just test`), regression replays (`just regress`). The game embeds Lua 5.2: it has no two-argument `math.atan`, and
`math.tointeger` doesn't exist.

**Conventions (from AGENTS.md):**
- Every module has a `.d.tl` under `tealdef/gui/pgrace_rail_router/`, required from
  `tealdef/pgrace_rail_router_def.d.tl`.
- Don't leave unused `local type X = Mod.Y` aliases; they crash the UI.
- Name loop discards `__`.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Work happens in `.worktrees/m4b` (branch `feat/m4b-existing`). To test in-game, point the staging symlink at it.

Paths below are relative to `mod/pgrace_rail_router/` unless they start with `tests/`, `docs/` or `tools/`.

---

### Task 1: Probe P15 (in-game gate)

**Files:**
- Modify: `content/gui/pgrace_rail_router/probe.tl` (add `probe.junction`)
- Modify: `tealdef/gui/pgrace_rail_router/probe.d.tl`
- Modify: `content/gui/pgrace_rail_router/window.script.tl` (P15 button and dispatch, next to P14)

P15 runs in three stages. Each stage is a separate click of the same button, and `stage` advances in a
module-level variable, so the player can look at the result between clicks.

1. **Stage 1:** build a 400 m straight double track east from the camera, on the ground. Track 1 (north, +y)
   carries a one-way signal at param 0.5 facing west (node1→node0). Track 2 carries one facing east. Use
   `network.build` on a one-leg `testPlan` (P14's helpers) with `opts.fan = nil` and `opts.crossovers = false`.
   Add the signals by setting `e.signals` on the middle edges before `builder.chunkProposal`. Log the built
   pieces' entities and `signalsOn(e)`.
2. **Stage 2:** split track 1's piece under x = 200 at that point, with `replaceSegment(piece)` edited exactly as
   `build.tl`'s `splitStreet`, but for a track piece. Copy the template's `streetEdge`, `playerOwned`, `comp.type`,
   `typeIndex`, `roadTemplate`, `laneConfigs`, `distance` and `comp.objects`, and set `nodeConfigsToAdd = {}`.
   Log the new pieces, and `signalsOn` each one: does the signal survive the split, and on which piece and which
   way?
3. **Stage 3:** a flat junction from the north:
   - our approach at y = +7.5 and +12.5 from x = 300 to 330;
   - our far track merges into existing track 1 (+2.5) at x = 60, with a 110 m S-curve from (170, 12.5) to (60, 2.5);
   - our near track crosses to existing track 2 (−2.5) with a 110 m S-curve from (300, 7.5) to (190, −2.5).

   This needs three cuts: track 1 at x = 60 (switch) and x = 245 (crossing, where the S-curve passes y = 2.5),
   and track 2 at x = 190 (switch). Split both pieces at their cuts, then dry-run the junction pieces (joined to
   the new nodes) and log the result. If it's clean, build them. Log how many pieces meet at the crossing node
   (`getNodeTrackSegments`).

- [ ] **Step 1: Write `probe.junction`.** Reuse `with`, `testPlan`, `straight`, `camera`, `groundAt`, `signalsOn`
  and `log` from `probe.tl`. The S-curve between (x0, y0) and (x1, y1) along the axis is a Hermite with
  p0 = (x0, y0), p1 = (x1, y1), and t0 = t1 = ((x1 − x0), 0, 0). Converting local to world: the camera point plus
  (x, y), since the axis runs east.
- [ ] **Step 2: Declare it** in `probe.d.tl`: `junction : function(settings : PgraceRailRouterBuilder.Settings) : {function()}`,
  with a comment describing the three stages.
- [ ] **Step 3: Wire the P15 button** with the label `"Probe P15: junction into existing track, stage by stage (test map only)"`.
- [ ] **Step 4:** `just check` should report 0 errors, and `just test` should pass. Commit as
  `chore: probe P15 builds a flat junction into an existing signalled double track, stage by stage`.
- [ ] **Step 5 (player):** on the test map, click P15 three times on an empty flat area. Then run a train through
  each route of the junction, and along the existing line over the crossing. Record the findings in the spec's
  "Unknowns" section and in AGENTS.md.
  - **If splitting loses the signal or breaks the line,** Task 8's split must restore signals from the old piece
    (copy `comp.objects` and add `edgeObjectsToAdd` entries).
  - **If the crossing needs a different shape,** adjust Task 2's geometry before going on.

### Task 2: Fix the spec's handedness

**Files:** Modify `docs/superpowers/specs/2026-10-18-rail-router-existing-stations-design.md`, section
"Junction geometry (flat)".

- [ ] **Step 1: Define y as left of outward.**
  - Replace "y runs across it. The new line comes from the +y side" with: "y runs across it, positive to the left
    of outward. The new line comes from either side; the frame is drawn for the +y side and mirrored for −y."
  - Replace the "Order" paragraph with: "With right-hand running on both lines, the existing near track runs the
    same way as our far track, whichever side the line comes from. So our far track always **merges** into the
    existing near track, and our near track always **crosses** to the existing far track. Coming from +y: inward
    trains use the existing near track (+2.5) and our far track (+12.5). An end whose signals show left-hand
    running is not usable."
- [ ] **Step 2: Commit** as `docs: 4b junction frame: y left of outward; merge/cross roles follow right-hand running on both lines`.

### Task 3: Junction geometry (pure)

**Files:**
- Create: `content/gui/pgrace_rail_router/planner/junction.tl`
- Create: `tealdef/gui/pgrace_rail_router/planner/junction.d.tl`
- Modify: `tealdef/pgrace_rail_router_def.d.tl` (add `require "gui.pgrace_rail_router.planner.junction"` after network)
- Test: `tests/junction_test.lua`

The shape (spec "Junction geometry (flat)", as P15 built it): the merge is one S-curve piece from a switch on the
existing near track (+2.5) to our far track (+12.5). The crossing track is two circular arcs of the turnout radius R,
each turning θ = acos(1 − 5 / R) and climbing 5 m over C = R sin θ along x: the inner one from a switch on the existing
far track (−2.5) to the crossing node on the existing near track (+2.5), the outer one from there to our near track
(+7.5). Each is one piece (the game refuses a new piece over existing track unless they share a node). A circular
arc's tangents are as long as the arc (R θ); the S-curve's are its x length.

The interface (`junction.d.tl`):

```teal
-- A flat junction into an existing double track (milestone 4b). Pure. Frame: x along the existing axis outward
-- from the station, y to the left of outward; the existing tracks at y = ±2.5, our line on side `side` (+1: +y).
global record PgraceRailRouterJunction
	-- Where the junction cuts an existing track: which ("near": the track on our side, "far"), how far along the
	-- stretch (metres from its start), and what goes there ("switch" or "crossing").
	record Cut
		track : string
		x : number
		kind : string
	end

	-- A junction piece in the frame, as a Hermite curve: from (x0, y0) to (x1, y1), tangents (tx0, ty0), (tx1, ty1).
	record Piece
		x0 : number
		y0 : number
		x1 : number
		y1 : number
		tx0 : number
		ty0 : number
		tx1 : number
		ty1 : number
		-- "merge" (our far track into the existing near one), "cross in" (the existing far track's switch to the
		-- crossing node), "cross out" (the crossing node to our near track).
		role : string
	end

	record Layout
		-- The start of our approach (the leg's fixed end), metres along the stretch; our tracks there at y = 7.5
		-- side and 12.5 side, running straight outward from it.
		approachX : number
		pieces : {Piece}
		cuts : {Cut}
	end

	-- The S-curve length for a lateral offset at turnout radius r: max(40, 5 × round(√(4 r × offset) / 5)).
	sCurve : function(offset : number, radius : number) : number
	-- The angle (radians) each crossing arc turns at radius r: acos(1 − 5 / r).
	crossAngle : function(radius : number) : number
	-- The x length of each crossing arc at radius r: r sin(crossAngle(r)).
	crossRun : function(radius : number) : number
	-- The junction nearest the stretch's start that fits, keeping every cut CLEAR (15 m) from the existing signals
	-- (x positions along the stretch, per track) and from the stretch's start: nil if none fits within `length`.
	fit : function(length : number, radius : number, side : number, signals : {string : {number}}) : Layout
	-- Total length a junction needs at radius r (no signals in the way): sCurve(10, r) + 2 crossRun(r) + 80.
	needed : function(radius : number) : number
end
```

- [ ] **Step 1: Write the failing tests** (`tests/junction_test.lua`):

```lua
local t = ...
local junction = t.requireTl("gui/pgrace_rail_router/planner/junction.tl")

-- Standard track: R = 300.
local R = 300
local THETA = math.acos(1 - 5 / R)
local C = R * math.sin(THETA)

t.test("junction: S-curve and crossing arcs follow the radius", function()
	t.eq(junction.sCurve(10, 300), 110, "standard, 10 m")
	t.eq(junction.sCurve(10, 600), 155, "high-speed, 10 m")
	t.eq(junction.sCurve(5, 300), 75, "standard, 5 m (as the fans)")
	t.near(math.deg(junction.crossAngle(300)), 10.48, 0.01, "standard: about 10.5 degrees")
	t.near(junction.crossRun(300), 54.54, 0.01, "standard: about 54.5 m")
	t.near(math.deg(junction.crossAngle(600)), 7.40, 0.01, "high-speed: about 7.4 degrees")
	t.near(junction.needed(300), 110 + 2 * C + 80, 1e-9, "S-curve + two arcs + 80")
end)

t.test("junction: from the station out, merge, gap, crossing arcs, approach; cuts where they touch", function()
	local j = junction.fit(400, R, 1, { near = {}, far = {} })
	t.ok(j ~= nil, "fits in 400 m")
	local by = {}
	for __, p in ipairs(j.pieces) do
		by[p.role] = p
	end
	local merge, cin, cout = by["merge"], by["cross in"], by["cross out"]
	t.near(merge.x0, 15, 1e-9, "the merge's switch 15 m out")
	t.near(merge.y0, 2.5, 1e-9, "on the existing near track")
	t.near(merge.x1, 125, 1e-9, "110 m S-curve")
	t.near(merge.y1, 12.5, 1e-9, "to our far track")
	t.near(merge.tx0, 110, 1e-9, "S-curve tangent along x")
	t.near(merge.ty0, 0, 1e-9, "flat at the switch")
	t.near(merge.ty1, 0, 1e-9, "flat at our track")
	t.near(cin.x0, 145, 1e-9, "20 m further out")
	t.near(cin.y0, -2.5, 1e-9, "from the existing far track")
	t.near(cin.x1, 145 + C, 1e-9, "one arc's run")
	t.near(cin.y1, 2.5, 1e-9, "to the crossing node on the near track")
	t.near(cin.ty0, 0, 1e-9, "leaves the far track along it")
	t.near(math.atan(cin.ty1 / cin.tx1), THETA, 1e-9, "crosses at the arc's angle")
	t.near(math.sqrt(cin.tx1 ^ 2 + cin.ty1 ^ 2), R * THETA, 1e-9, "tangent as long as the arc")
	t.near(cout.x0, cin.x1, 1e-9, "the outer arc starts at the crossing node")
	t.near(cout.tx0, cin.tx1, 1e-9, "tangent to the inner arc there (x)")
	t.near(cout.ty0, cin.ty1, 1e-9, "tangent to the inner arc there (y)")
	t.near(cout.x1, 145 + 2 * C, 1e-9, "a second run")
	t.near(cout.y1, 7.5, 1e-9, "to our near track")
	t.near(cout.ty1, 0, 1e-9, "flat at our track")
	t.near(j.approachX, 145 + 2 * C + 30, 1e-9, "30 m of approach")
	local byKind = {}
	for __, c in ipairs(j.cuts) do
		byKind[c.track .. " " .. c.kind] = c.x
	end
	t.near(byKind["near switch"], 15, 1e-9, "merge switch")
	t.near(byKind["far switch"], 145, 1e-9, "crossing track's switch")
	t.near(byKind["near crossing"], 145 + C, 1e-9, "the crossing node where the arcs meet")
end)

t.test("junction: mirrored for a line from the other side", function()
	local j = junction.fit(400, R, -1, { near = {}, far = {} })
	for __, p in ipairs(j.pieces) do
		if p.role == "merge" then
			t.near(p.y0, -2.5, 1e-9, "the near track is at −2.5")
			t.near(p.y1, -12.5, 1e-9, "our far track at −12.5")
		elseif p.role == "cross in" then
			t.near(p.y0, 2.5, 1e-9, "from the far track at +2.5")
			t.ok(p.ty1 < 0, "turning towards −y")
		end
	end
end)

t.test("junction: moves out past existing signals, and fails when it can't fit", function()
	local j = junction.fit(500, R, 1, { near = { 20 }, far = {} })
	t.ok(j ~= nil, "fits further out")
	for __, c in ipairs(j.cuts) do
		if c.track == "near" then
			t.ok(math.abs(c.x - 20) >= 15, "cut " .. c.kind .. " 15 m clear of the signal at 20")
		end
	end
	t.ok(junction.fit(junction.needed(R), R, 1, { near = {}, far = {} }) ~= nil, "exactly the length needed fits")
	t.ok(junction.fit(junction.needed(R) - 1, R, 1, { near = {}, far = {} }) == nil, "1 m less is too short")
end)
```

- [ ] **Step 2:** run `just test`. Expected: FAIL (`junction.tl` not found).
- [ ] **Step 3: Implement** `planner/junction.tl`:

```teal
local junction : PgraceRailRouterJunction = {}

local type Layout = PgraceRailRouterJunction.Layout
local type Piece = PgraceRailRouterJunction.Piece

-- Every cut stays this far from existing signals and from the stretch's start (metres): the clearance our own
-- signals keep from edge ends (a signal 3 m from a node collided with track joined there).
local CLEAR = 15.0
local GAP = 20.0
local APPROACH = 30.0
local STEP = 5.0
-- What each crossing arc climbs: the far track (−2.5) to the crossing node (+2.5), and on to our near track (+7.5).
local CLIMB = 5.0

function junction.sCurve(offset : number, radius : number) : number
	return math.max(40, 5 * math.floor(math.sqrt(4 * radius * offset) / 5 + 0.5))
end

function junction.crossAngle(radius : number) : number
	return math.acos(1 - CLIMB / radius)
end

function junction.crossRun(radius : number) : number
	return radius * math.sin(junction.crossAngle(radius))
end

function junction.needed(radius : number) : number
	return junction.sCurve(10, radius) + 2 * junction.crossRun(radius) + GAP + APPROACH + 2 * CLEAR
end

local function clear(x : number, signals : {number}) : boolean
	for __, s in ipairs(signals) do
		if math.abs(x - s) < CLEAR then
			return false
		end
	end
	return true
end

-- A piece from (x0, y0) to (x1, y1) on side +1, its tangents at angles a0, a1 to x and `len` long; mirrored by side.
local function piece(x0 : number, y0 : number, x1 : number, y1 : number, a0 : number, a1 : number, len : number,
		side : number, role : string) : Piece
	return {
		x0 = x0, y0 = y0 * side, x1 = x1, y1 = y1 * side,
		tx0 = math.cos(a0) * len, ty0 = math.sin(a0) * len * side,
		tx1 = math.cos(a1) * len, ty1 = math.sin(a1) * len * side,
		role = role,
	}
end

function junction.fit(length : number, radius : number, side : number, signals : {string : {number}}) : Layout
	local l = junction.sCurve(10, radius)
	local theta = junction.crossAngle(radius)
	local c = junction.crossRun(radius)
	local arc = radius * theta
	local m = CLEAR
	while m + l + GAP + 2 * c + APPROACH + CLEAR <= length + 1e-9 do
		local c0 = m + l + GAP
		local crossing = c0 + c
		if clear(m, signals.near) and clear(crossing, signals.near) and clear(c0, signals.far) then
			return {
				approachX = c0 + 2 * c + APPROACH,
				pieces = {
					piece(m, 2.5, m + l, 12.5, 0, 0, l, side, "merge"),
					piece(c0, -2.5, crossing, 2.5, 0, theta, arc, side, "cross in"),
					piece(crossing, 2.5, c0 + 2 * c, 7.5, theta, 0, arc, side, "cross out"),
				},
				cuts = {
					{ track = "near", x = m, kind = "switch" },
					{ track = "near", x = crossing, kind = "crossing" },
					{ track = "far", x = c0, kind = "switch" },
				},
			}
		end
		m = m + STEP
	end
	return nil
end

return junction
```

- [ ] **Step 4:** run `just test`. Expected: the four junction tests pass, along with everything else. `just check` clean.
- [ ] **Step 5: Commit** as `feat: junction geometry for joining an existing double track (pure)`.

### Task 4: Reading an existing station's approach (pure)

**Files:**
- Create: `content/gui/pgrace_rail_router/planner/existing.tl`
- Create: `tealdef/gui/pgrace_rail_router/planner/existing.d.tl` (and register it)
- Test: `tests/existing_test.lua`

The snapshot is plain data, which the survey fills in (Task 5) and the tests build by hand:

```teal
global record PgraceRailRouterExisting
	record Piece
		entity : integer
		node0 : integer
		node1 : integer
		p0 : PgraceRailRouterNetwork.Pt3
		p1 : PgraceRailRouterNetwork.Pt3
		t0 : PgraceRailRouterNetwork.Pt3
		t1 : PgraceRailRouterNetwork.Pt3
		-- "ground", "bridge" or "tunnel"
		kind : string
		-- One-way signals only (the survey leaves out two-way path signals, type 0): param along the piece, and +1
		-- facing node0 → node1 trains, −1 the other way.
		signals : {{number}}
	end

	record Snapshot
		pieces : {Piece}
		-- Track pieces per node (entity → count), as streetSystem.getNodeTrackSegments gives.
		degree : {integer : integer}
	end

	-- A station: its platforms' centre and direction (a unit vector; normalised anyway), half their length, and its
	-- track end nodes.
	record Station
		entity : integer
		centre : PgraceRailRouterGeo.Pt
		dir : PgraceRailRouterGeo.Pt
		half : number
		ends : {integer}
	end

	-- A usable end: the straight double-track stretch's start on the two tracks' midline (and its height), its grade
	-- (dz per metre outward: the track at x along the stretch is at z + grade × x, and so is the junction), the unit
	-- outward direction, the stretch's length (metres), each track's pieces along it ("near": the track on our
	-- line's side, "far"), ordered outward, and each track's signals as positions along the stretch (metres from its
	-- start).
	record End
		origin : PgraceRailRouterGeo.Pt
		z : number
		grade : number
		dir : PgraceRailRouterGeo.Pt
		length : number
		pieces : {string : {Piece}}
		signals : {string : {number}}
	end

	-- Both ends: [1] the end at +dir, [-1] the one at −dir; nil where not usable, and why in `why` ("no double
	-- track", "short": none long enough before something that stops the reading, or "left-hand").
	record Result
		ends : {integer : End}
		why : {integer : string}
	end

	-- Each end's first straight (on a steady grade), plain double-track stretch at least junction.needed(radius)
	-- long. Frame: x outward from the platform end, y to the left; the scan starts at the station's end nodes and
	-- reads up to 1.5 km out, 12 m either side. A stretch starts where exactly two straight ground pieces 4.5–5.5 m
	-- apart cross x, their grades within 0.2% of each other. Each track is then walked piece by piece through plain
	-- nodes (degree 2), and the stretch ends at the first node that isn't plain, a bridge or tunnel, a piece that
	-- isn't straight (tangents within 0.5% of the axis sideways and of the grade upward), or where the tracks stop
	-- being the only two, 4.5–5.5 m apart, with midline and height within 0.5 m of the straight line through the
	-- start (checked every 5 m and at each node). Past a short stretch the scan reads on only after a bridge or
	-- tunnel, such a drift, or a crossover; any other switch, the track's end or single track stops it. A stretch's
	-- tracks must also lead back only to the station's end nodes (through the fan's merges and crossovers), so a
	-- stretch past a siding, branch or another line's switch stops the scan too.
	-- `side[k]`: which side of end k our line comes from (+1 left of outward, −1 right; nil +1).
	analyse : function(station : Station, snap : Snapshot, side : {integer : number}, radius : number) : Result
end
```

`side[k]` is which side of end k our line will come from (+1 left of outward, −1 right). The route supplies it
(Task 6). The analyser uses it to label the tracks "near" and "far".

**Algorithm, per end k (±1)** (as built; `existing.tl`):
1. **Frame.** Outward is k × dir (dir normalised). x is the distance along outward from the platform end
   (centre + outward × half), y the distance to the left.
2. **The corridor.** The pieces with |y| ≤ 12 at both ends, x ≤ 1500, and x no further back than the station's end
   nodes on this end (less 1 m), that the end nodes reach over such pieces (a BFS over node → pieces). The scan
   starts at the end nodes' smallest x.
3. **A stretch's start.** Scan x in 5 m steps. A stretch starts where exactly two pieces cross x (a piece starting at
   x counts, one ending there doesn't; y and z along the chord), both "ground", 4.5–5.5 m apart, their chord grades
   (dz/dx outward) within 0.002 of each other. Their mean is the stretch's grade g. Both must be straight at g: each
   tangent's sideways share |t × o| / |t_xy| ≤ 0.005 and |t.z / |t_xy| − g| ≤ 0.005 (t.z taken along outward).
   Until the fan has merged to two tracks nothing starts.
4. **Its tracks must come from the station.** Walking inward from the two start pieces, every way back must end at a
   station end node. A node may merge two inward pieces (the fan), or split towards the station only where one of
   its outward pieces leads across to the other track (a crossover: through plain nodes to a degree-3 node
   4.5–5.5 m across, towards the midline). A piece leaving the corridor (a siding, a branch, another line), a dead
   end or any other switch fails it: the scan stops, `why[k] = "short"`.
5. **Its length.** Each track is walked outward piece by piece through plain (degree 2) nodes. A track ends at a
   switch (degree 3), any other non-plain node, a next piece that leaves the corridor or turns back, a bridge or
   tunnel, or a piece that isn't straight. The stretch ends where the first track does. Then every 5 m and at each
   node on the way, the two tracks must stay the only ones crossing, 4.5–5.5 m apart, with midline within 0.5 m of
   the start's and height within 0.5 m of z_start + g (x − start); where that fails it ends at the point checked before (a drift). Piece lists hold
   each track's pieces that start before the end, ordered outward.
6. **Usable** if the length ≥ `junction.needed(radius)`. If shorter, the scan reads on from its end only if it
   ended at a bridge or tunnel, a drift or a crossover (a switch whose other piece leads across, as in 4); any other
   switch, the track's end or single track stops it. `why[k]` is `"short"` if any stretch was found, else
   `"no double track"`.
7. **Running directions.** For each one-way signal on the stretch's pieces, its direction along outward comes from
   its facing and the piece's direction. Right-hand running wants the track right of outward governing outward
   trains and the left one inward trains. Any signal against that: `why[k] = "left-hand"`, no end.
8. **Near and far.** The near track is the one on `side[k]` (nil: +1). Signal positions are x − start along the
   stretch, per near/far, sorted; those on listed pieces are kept even outside 0..length.

- [ ] **Step 1: Write the failing tests.** Build snapshots in `tests/existing_test.lua` with a helper
  `straightPiece(id, n0, n1, x0, y0, x1, y1)` (z 0, tangents (x1 − x0, y1 − y0, 0), kind "ground", signals {}).
  The cases:
  - **Usable.** A station at (0, 0) facing +x, half 80, end nodes 1 and 2 at (80, ±2.5). From them, a 4-track fan:
    pieces at y = ±2.5 and ±7.5 merging by x = 180. Then a double track y = ±2.5 from x = 180 to 1000 in 100 m
    pieces with degree-2 nodes. Expect end +1 usable, the stretch starting at about 100 m (past the merge switches,
    which have degree 3), length about 820 − 100 m, and near = the +2.5 track when `side[1] = 1`.
  - **Too short.** The double track ends at x = 300 with a switch (a node of degree 3). Expect `why[1] = "short"`.
  - **Left-hand signals.** A one-way signal on the y = −2.5 track facing inward. Expect `why[1] = "left-hand"`.
  - **Not along the axis.** A curving approach: the double track bends off by 20 m within 200 m. Expect `"short"`
    or `"no double track"`.
- [ ] **Step 2:** run `just test`. Expected: FAIL.
- [ ] **Step 3: Implement `existing.analyse`** as the algorithm above, a pure function with no `api.*` calls. Hermite
  points come from `network.hermiteAt` for each piece's sample at x. For simplicity, linearly interpolate along the
  chord p0→p1, since pieces on the stretch are straight.
- [ ] **Step 4:** run `just test`. Expected: PASS.
- [ ] **Step 5: Commit** as `feat: reading an existing station's double-track approach from a track snapshot (pure)`.

### Task 5: The survey finds stations and snapshots their track (engine)

**Files:**
- Modify: `content/gui/pgrace_rail_router/survey.tl`
- Modify: `tealdef/gui/pgrace_rail_router/survey.d.tl`

- [ ] **Step 1: Add `survey.existingStations(town : Town, reach : number) : {PgraceRailRouterExisting.Station}`.**
  - Find constructions within `reach` of `town.pos` with `octree.findEntitiesInCircle(..., CONSTRUCTION)`.
  - Keep those whose `con.stations` is non-empty and that have frozen track edges (BASE_EDGE without
    BASE_EDGE_STREET).
  - Their track ends are the nodes of their frozen edges that aren't frozen nodes, as `builder.trackEnds` finds
    them. Move that function into a shared helper in `survey.tl`, and have `builder.tl` call the survey's.
  - **Centre and direction:** the end nodes split into two groups along the longest axis between them. The centre is
    the midpoint of the two groups' centroids, dir is the unit vector from one to the other, and half is half the
    distance between them.
  - Wrap everything in `pcall` and log per station: `[rail_router] existing station %d in %s: %d ends`.
- [ ] **Step 2: Add `survey.trackSnapshot(centre : Pt, radius : number) : PgraceRailRouterExisting.Snapshot`.**
  - Read every BASE_EDGE without BASE_EDGE_STREET within radius 1700 m, as `markEdge` reads curves.
  - Each piece's signals: for each transport edge k and reversed ∈ {false, true}, call
    `signalSystem.getSignal(EdgeId(piece, k), reversed)`, and keep `SIGNAL_LIST` type 1 (one-way). P14 showed that
    a signal facing node1→node0 trains is found with `reversed = false`, so facing = reversed and +1 or −1. The
    param comes from the signal list's `edgePr` if readable; otherwise use 0.5, which is enough for the clearance
    check (it's conservative per piece).
  - Degree comes from `#streetSystem.getNodeTrackSegments(node)`.
- [ ] **Step 3: Time it** on PottstownTown, the player's third save, which has an existing station. Log
  `snapshot: %d pieces, %d us`. Up to about 100 ms in one frame is fine (see memory: one-off hitches go unnoticed).
- [ ] **Step 4:** `just check`, then commit as `feat: the survey finds stop towns' rail stations and snapshots the track round them`.

### Task 6: The route uses an existing station as a fixed stop

**Files:**
- Modify: `content/gui/pgrace_rail_router/planner/route.tl`
- Modify: `tealdef/gui/pgrace_rail_router/planner/route.d.tl`
- Test: `tests/route_test.lua`

- [ ] **Step 1: Declare.**
  - `Input.existing : {integer : PgraceRailRouterExisting.Result}`, keyed by stop index; nil means no existing
    station.
  - `Input.existingStations : {integer : PgraceRailRouterExisting.Station}`.
  - `Input.radius : number`, the turnout radius.
  - `Station.existing : PgraceRailRouterExisting.Station`, and `Station.junctions : {integer : PgraceRailRouterJunction.Layout}`
    keyed by end (±1). Also `Station.endOf : {boolean : integer}`: forward=true (the leg leaving) and false (the
    leg arriving), mapped to an end ±1.
  - `Plan.notes : {string}`, the fallbacks to report.
- [ ] **Step 2: Sites phase.** When `input.existingStations[i] ~= nil`, check the ends before starting a finder:
  - **Leg in:** the end whose outward points towards the previous stop is `k = sign(dot(prev.pos − centre, dir))`.
  - **Leg out:** the same for the next stop.
  - **In the middle of the route**, the two ends must differ. Each must be usable in `input.existing[i]`, and must
    get a `junction.fit(end.length, input.radius, side, end.signals)` that isn't nil, where side is which side of
    outward the neighbour lies on: `sign(cross(outward, neighbour − origin))`.

  If all hold, insert `{ town, site = { centre, dir, distance }, z, existing = st, junctions = {...}, endOf = {...} }`
  and skip the finder. Otherwise append a note ("The station in X has no room for a junction (needs N m of
  straight double track); a new station was planned.") and run the finder as now.
- [ ] **Step 3: Turning and re-siting skip existing stations.** In the "turn" phase and in `stepResite`, add
  `if station.existing ~= nil then <advance to the next station> end` at the top of each per-station step.
- [ ] **Step 4: `stationEnds` for an existing station.** For an existing station on the leg end `forward`, take
  `k = station.endOf[forward]`, `e = existing end k`, and `j = station.junctions[k]`:
  - `platformEnd = e.origin + e.dir × j.approachX + left(e.dir) × 10 × side`, where left(d) = (−d.y, d.x);
  - `approach = platformEnd + e.dir × JUNCTION_APPROACH` (50 m);
  - return platformEnd, approach, approach, so it has no extension.

  The leg's first (or last) straight piece then runs along our axis, 10 m off the existing one. The heights use
  `e.z + e.grade × x`.
- [ ] **Step 5: Footprints.** `addFootprint` and `takePlatforms` for an existing station add nothing. Its cells are
  already track, which the grid treats as crossings or blocks.
- [ ] **Step 6: Tests** in `tests/route_test.lua`, on a synthetic grid (see that file's helpers) with three stops:
  - **Usable.** The middle stop has an `existingStations` entry and a usable `existing` result at both ends. Expect
    `plan.stations[2].existing ~= nil`, `plan.legs[1]` ending at that station's −1 junction's platformEnd, and
    `plan.legs[2]` starting at its +1 junction's platformEnd.
  - **Fallback.** The same with `why[1] = "short"`. Expect a normal site and one note.
- [ ] **Step 7:** run `just test` and `just regress`. Expected: PASS, with regression figures unchanged (no existing
  stations on those routes).
- [ ] **Step 8: Commit** as `feat: the route joins an existing station at junctions on its approaches instead of siting one`.

### Task 7: Network: junction pieces and existing cuts

**Files:**
- Modify: `content/gui/pgrace_rail_router/planner/network.tl`
- Modify: `tealdef/gui/pgrace_rail_router/planner/network.d.tl`
- Test: `tests/network_test.lua`

- [ ] **Step 1: Declare.**
  - `Edge.track` 4 means a junction piece.
  - `Pt3.existing : {piece : integer, s : number}`: a node to be made by splitting an existing piece at
    parameter s.
  - `Chunk.splits : {{piece : integer, s : {number}}}`: the existing pieces to split before the chunk, with their
    parameters in ascending order.
- [ ] **Step 2: Build the pieces.** In `network.build`, for a leg whose start (or end) station has `existing`:
  - **No fan and no crossovers** at that end, so pass `atStart`/`atEnd` = false for that end to `crossoverPlaces`,
    and skip the fan code for it.
  - **Edges.** For each `j.pieces` entry, make one edge from the frame to the world:
    `world(x, y) = e.origin + e.dir × x + left(e.dir) × y`; every junction node takes z = `e.z + e.grade × x`, and
    tangents `e.dir × tx + left(e.dir) × ty` with z `e.grade × tx`. Never split a piece: the game refuses a new piece
    over existing track unless they share a node (P15). Then a straight edge on our track from each outer piece end
    (the merge's x1 on our far track, the "cross out" piece's x1 on our near track) to the approach start (approachX),
    where the leg's track end nodes sit: the merge joins our far track, the crossing track our near track. The far
    track is whichever of the leg's tracks 1/2 lies further from the existing axis at that end. Edges run in whichever
    direction the leg's chunk needs; reverse a piece by swapping its ends and negating its tangents.
  - **The existing end** becomes a new node carrying `existing = { piece, s }`. Find the piece in
    `e.pieces[near|far]` whose x-range holds the cut, then compute s by linear interpolation along its chord.
  - **The crossing.** The "cross in" and "cross out" pieces share one node, the crossing node, which carries the
    crossing's `existing` cut.
  - **Home signals** on our two approach tracks, 15 m from the approach start, facing inward. Use `addSignal` with
    `forward` according to the edge's direction.
  - Put the junction edges into the leg's first (or last) chunk, and record the chunk's `splits`.
- [ ] **Step 3: Test.** Add a test to `tests/network_test.lua` with a one-leg plan whose start station has
  `existing` (built by hand, as the route would). Expect:
  - 5 junction edges (track 4): the 3 pieces and the 2 straights to the approach start;
  - 3 nodes with `existing` set;
  - the "cross in" and "cross out" edges sharing the crossing node, tangent there;
  - the leg's first chunk listing `splits` for 2 pieces (near, with 2 parameters; far, with 1);
  - no fan edges and no crossovers at that end.
- [ ] **Step 4:** run `just test`. Expected: PASS. Commit as `feat: network junction pieces into existing track, and the splits a chunk needs`.

### Task 8: Check and build (engine; shaped by P15's findings)

**Files:**
- Modify: `content/gui/pgrace_rail_router/build.tl`
- Modify: `content/gui/pgrace_rail_router/builder.tl` and its `.d.tl`

- [ ] **Step 1: Check.** In `builder.step`, a chunk with `splits` whose dry run collides only with the split pieces
  and their nodes counts as clean, plus `junctions += 1` per junction (add `Check.junctions` and
  `Outcome.junctions`). Use the same pattern as level crossings: a `builder.junctionHits(collisions, splits)` pure
  helper with unit tests in `tests/builder_test.lua`. It returns true when every collision's entity is a split
  piece or one of its nodes.
- [ ] **Step 2: Build.** In `build.tl stepChunk`, before the first dry run of a chunk with `splits`, run a state like
  `b.crossings`. For each split, in turn:
  - Read the piece's BASE_EDGE and call `replaceSegment(piece)`.
  - Edit it into pieces at the s values with new nodes. Generalise `splitStreet` to `splitEdge(entity, edge, h, us)`,
    which copies the template's `type` (street 0, or track 1), `distance` and owner, and carries the piece's signal
    objects onto the sub-piece that holds each signal's param, as P15 dictates.
  - Send it, then match the new nodes by place to the network nodes with `existing` set, and set their `entity`.

  After all the splits, the chunk is dry-run and sent as now.
- [ ] **Step 3: Failure.** On failure, use Show and "Retry from here" as now. Splits already made stay (harmless).
- [ ] **Step 4:** `just check` and `just test`, then commit as `feat: the build splits existing track for a junction, then joins it`.

### Task 9: The window

**Files:** Modify `content/gui/pgrace_rail_router/window.script.tl`.

- [ ] **Step 1: Find route.** When the player clicks Find route (main thread), for each picked stop call
  `survey.existingStations(town, 1500)`. Take the station nearest the centre (one per town in 4b-1), then
  `survey.trackSnapshot` and `existing.analyse` with sides from the neighbours. Pass them as
  `Input.existingStations` / `Input.existing`, and `Input.radius = turnoutRadius(track)`.
- [ ] **Step 2: The stop list.** A town with a usable station shows "use the existing station in {town}"
  (ticked by default; `Settings.useExisting : {integer : boolean}`, default true) under its stop line. Unticked,
  it isn't passed.
- [ ] **Step 3: Results.** Show `plan.notes` as text rows. Show "Junctions: {count}" in the plan summary, the check
  and the built line.
- [ ] **Step 4:** `just check`, then commit as `feat: the window offers an existing station per stop and reports junctions`.

### Task 10: Docs and the in-game test

- [ ] **Step 1: Update the spec.** Fill in the Unknowns section with P15's answers and mark 4b-1 done when tested.
  Record the lessons in AGENTS.md.
- [ ] **Step 2: Full check.** Run `just verify` and `just regress`.
- [ ] **Step 3 (player):** on the test map:
  1. Build Bangor → Imperial Beach (Halt 2+2).
  2. Plan a second line with a stop at Aloha, with "use the existing station" ticked.
  3. Check and build it.
  4. Run trains on both lines, through the junction's routes and over the level crossing.
- [ ] **Step 4:** merge `feat/m4b-existing` into main in `.worktrees/play` and point the symlink back.

### 4b-2 (flying junction): a follow-on plan

Once 4b-1 is in, write a separate short plan.

**Design:**
- `junction.fit` also tries a flying layout. The cross piece becomes a ramp up to 9 m over the existing near track,
  a bridge over it, and a ramp down, graded at the mode's limit.
- Its length is 2 × 9 ÷ grade + 2 × the S-curve's share.
- It is used when the stretch is long enough. Otherwise the junction is flat.

**Probe:** P15's stage 3 with a bridge over the crossing point (P8 showed 8 m clears track).

---

## Self-review

- **Spec coverage:**
  - usable stations: Tasks 4 and 5;
  - the window: Task 9;
  - geometry: Tasks 2 and 3;
  - planner: Task 6;
  - network: Task 7;
  - builder and check: Task 8;
  - unknowns: Task 1;
  - testing: Tasks 3, 4, 6 and 7 (units) and 10 (in-game);
  - flying junction: the 4b-2 section.
- **Gaps left on purpose:** Task 4's synthetic snapshots stand in for an extended map capture. Extending the capture
  format with terminals and signals is deferred until a real station fails the analyser, since captures are large
  and the format is shared with the template.
- **Type consistency:** `PgraceRailRouterJunction.Layout` (`approachX`, `pieces`, `cuts`) and
  `PgraceRailRouterExisting.End` (`origin`, `dir`, `length`, `pieces`, `signals`, `z`) are used under the same names
  in Tasks 6–8.
