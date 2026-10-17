local t = ...
local grid = t.requireTl("gui/pgrace_rail_router/planner/grid.tl")
local route = t.requireTl("gui/pgrace_rail_router/planner/route.tl")

local W = { maxGrade = 0.085, minRadius = 220, minBuildRadius = 55, minSearchRadius = 220, slopePenalty = 3, bridgeFactor = 6, turnPenalty = 20,
	roadCrossing = 50, trackCrossing = 400, costPerMetre = 360, bridgeCostFactor = 5, tunnelCostFactor = 8,
	bridgeAbove = 8, tunnelBelow = 12 }

local function town(id, name, x, y)
	return { id = id, name = name, pos = { x = x, y = y } }
end

-- x from -1000 to 7000, y from -1500 to 1500, 100 m cells.
local function flatGrid()
	return grid.new(-1000, -1500, 100, 81, 31)
end

local function run(g, stops, platformLength, weights)
	local job = route.start({ grid = g, stops = stops, weights = weights or W, platformLength = platformLength or 160 })
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
	t.near(plan.summary.estimate, 2 * 2840 * 360, 1, "estimate: the legs, not the platforms (the stations' track)")
	t.eq(plan.summary.tightCurves, 0, "no tight curves")
	t.eq(plan.summary.blockedSamples, 0, "nothing in the way")
	t.eq(plan.summary.steepLegs, 0, "no steep legs")
	for __, leg in ipairs(plan.legs) do
		t.eq(leg.tightCurves, 0, "leg tight curves")
		t.eq(leg.blockedSamples, 0, "leg blocked samples")
		t.eq(leg.steepEnds, false, "leg steep ends")
	end
end)

t.test("route: trains leave and enter the platforms straight before turning", function()
	-- y from -1500 to 3500, so C's station fits.
	local g = grid.new(-1000, -1500, 100, 81, 51)
	-- B's platforms point from A towards C, so both legs must turn.
	local plan = run(g, { town(1, "A", 0, 0), town(2, "B", 3000, 0), town(3, "C", 4500, 1500) })
	t.ok(plan.ok, "ok")
	for k, leg in ipairs(plan.legs) do
		local first, last = leg.pieces[1], leg.pieces[#leg.pieces]
		t.eq(first.kind, "straight", "leg " .. k .. " leaves straight")
		t.ok(first.length >= 100 - 1e-6, "leg " .. k .. " leaving straight " .. first.length)
		t.eq(last.kind, "straight", "leg " .. k .. " arrives straight")
		t.ok(last.length >= 100 - 1e-6, "leg " .. k .. " arriving straight " .. last.length)
		t.eq(leg.tightCurves, 0, "leg " .. k .. " tight curves")
		local arcs = 0
		for __, piece in ipairs(leg.pieces) do
			if piece.kind == "arc" then
				arcs = arcs + 1
			end
		end
		t.ok(arcs > 0, "leg " .. k .. " turns")
	end
	t.eq(plan.summary.tightCurves, 0, "summary tight curves")
end)

t.test("route: stations too close together fail", function()
	local plan = run(flatGrid(), { town(1, "A", 0, 0), town(2, "B", 250, 0) }, 200)
	t.ok(not plan.ok, "failed")
	t.eq(plan.failure, "too_close", "reason")
	t.eq(plan.failureTowns[1], "A", "first")
	t.eq(plan.failureTowns[2], "B", "second")
end)

t.test("route: the track meets the stations' heights", function()
	-- Ground rising 1 m per 100 m eastwards.
	local g = flatGrid()
	for iy = 1, 31 do
		for ix = 1, 81 do
			g.height[grid.index(g, ix, iy)] = grid.centre(g, ix, iy).x / 100
		end
	end
	local plan = run(g, { ABC[1], ABC[2] })
	t.ok(plan.ok, "ok")
	local leg = plan.legs[1]
	t.near(leg.z[1], plan.stations[1].z, 1e-9, "leaves at A's height")
	t.near(leg.z[#leg.z], plan.stations[2].z, 1e-9, "arrives at B's height")
	t.eq(leg.steepEnds, false, "feasible")
end)

t.test("route: the curves keep off buildings the search went round", function()
	local g = flatGrid()
	-- A wall from the bottom edge to y = 250 at x = 2500..2700: the line has to go round its top.
	for iy = 1, 31 do
		for ix = 1, 81 do
			local c = grid.centre(g, ix, iy)
			if c.x >= 2500 and c.x <= 2700 and c.y <= 250 then
				g.blocked[grid.index(g, ix, iy)] = true
			end
		end
	end
	local wide = {}
	for k, v in pairs(W) do
		wide[k] = v
	end
	wide.minRadius = 1500
	local plan = run(g, { town(1, "A", 0, 0), town(2, "B", 5000, 0) }, 160, wide)
	t.ok(plan.ok, "ok")
	-- The old smoothing cut the wall's corner (and counted the samples there).
	t.eq(plan.legs[1].blockedSamples, 0, "blocked samples")
	t.eq(plan.summary.blockedSamples, 0, "summary")
	-- Before the search spaced its turns for the radius, the guard had to hold the curves to its path here; now the
	-- path leaves room for the full radius on its own, but for one curve at A: the scout (turning as freely as the
	-- Cheapest radius allows) climbs round the wall by knight moves, so A faces 26.6° north of east, more than the
	-- 1500 m line needs, and turns back at a little under the radius.
	t.eq(plan.legs[1].searchRadius, 1500, "searched at the full radius")
	t.ok(plan.legs[1].tightCurves <= 1, "tight curves: " .. plan.legs[1].tightCurves)
	t.ok(plan.legs[1].minRadius >= 1300, "radius " .. plan.legs[1].minRadius)
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

t.test("route: a leg is built in a step of its own, after its search", function()
	local job = route.start({ grid = flatGrid(), stops = ABC, weights = W, platformLength = 160 })
	local done = false
	while not done do
		local legs = #job.result.legs
		local searching = job.search ~= nil
		done = route.step(job, 50)
		if #job.result.legs > legs then
			t.ok(not searching, "the step that built a leg didn't also search")
		end
	end
	t.eq(#job.result.legs, 2, "legs")
end)

t.test("route: a second station facing back towards the first is too close", function()
	-- B's platforms point from A towards C, which lies back past A.
	local plan = run(flatGrid(), { town(1, "A", 2000, 0), town(2, "B", 5000, 0), town(3, "C", 0, 0) })
	t.eq(plan.failure, "too_close", "reason")
	t.eq(plan.failureTowns[1], "A", "first")
	t.eq(plan.failureTowns[2], "B", "second")
end)

t.test("route: planning leaves the grid unchanged", function()
	local g = flatGrid()
	local n = 81 * 31
	for i = 1, n do
		g.blocked[i] = (i % 97 == 0) or false
	end
	local before = {}
	for i = 1, n do
		before[i] = g.blocked[i]
	end
	local function same(label)
		for i = 1, n do
			if g.blocked[i] ~= before[i] then
				error(label .. ": cell " .. i .. " was " .. tostring(before[i]) .. ", is " .. tostring(g.blocked[i]))
			end
		end
	end
	-- Cancelled after two steps (two sites placed), then a full run.
	local job = route.start({ grid = g, stops = ABC, weights = W, platformLength = 160 })
	route.step(job, 500)
	route.step(job, 500)
	same("cancelled")
	run(g, ABC)
	same("finished")
end)

local function withWeights(changes)
	local w = {}
	for k, v in pairs(W) do
		w[k] = v
	end
	for k, v in pairs(changes) do
		w[k] = v
	end
	return w
end

-- An existing line (or road) running north-south across the whole grid at x = 1500.
local function crossedGrid(field)
	local g = flatGrid()
	for iy = 1, 31 do
		g[field][grid.index(g, 26, iy)] = true
	end
	return g
end

t.test("route: existing track is crossed by a bridge", function()
	local plan = run(crossedGrid("track"), { ABC[1], ABC[2] })
	t.ok(plan.ok, "ok")
	t.ok(plan.summary.bridges >= 1, "bridges " .. plan.summary.bridges)
	t.eq(plan.summary.blockedSamples, 0, "not counted as blocked")
	t.ok(plan.summary.maxGrade <= W.maxGrade + 1e-9, "grade " .. plan.summary.maxGrade)
	local leg = plan.legs[1]
	for i, sample in ipairs(leg.samples) do
		local ix, iy = grid.cellOf(crossedGrid("track"), sample.p)
		if ix == 26 then
			t.ok(leg.z[i] >= 9 - 1e-9, "clearance at " .. sample.s .. ": " .. leg.z[i])
		end
	end
end)

t.test("route: roads are bridged only when the weights say so", function()
	local level = run(crossedGrid("road"), { ABC[1], ABC[2] }, 160, withWeights({ bridgeRoads = false }))
	t.ok(level.ok, "ok level")
	t.eq(level.summary.bridges, 0, "level crossing")
	local bridged = run(crossedGrid("road"), { ABC[1], ABC[2] }, 160, withWeights({ bridgeRoads = true }))
	t.ok(bridged.ok, "ok bridged")
	t.ok(bridged.summary.bridges >= 1, "bridges " .. bridged.summary.bridges)
end)

t.test("route: the straight beyond a station's approach stops short of a building", function()
	local g = flatGrid()
	-- A's approach ends 180 m out; with a 1500 m radius the room to turn would run on to 801 m. A building in the
	-- cell at x = 250..350, y = -50..50, just beyond the approach. (The scouted line steps a cell aside to pass it,
	-- so A may turn by a few degrees; its axis still meets the building's cell.)
	g.blocked[grid.index(g, 14, 16)] = true
	local job = route.start({ grid = g, stops = { town(1, "A", 0, 0), town(2, "B", 5000, 0) },
		weights = withWeights({ minRadius = 1500 }), platformLength = 160 })
	local start = nil
	local steps = 0
	while not route.step(job, 500) do
		if job.path ~= nil and start == nil then
			start = job.path[1]
		end
		steps = steps + 1
		assert(steps < 100000, "runaway")
	end
	local plan = route.plan(job)
	t.ok(plan.ok, "ok")
	t.ok(start ~= nil, "searched")
	local c, d = plan.stations[1].site.centre, plan.stations[1].site.dir
	t.ok(math.abs(d.y) < 0.2, ("A faces about east: (%.2f, %.2f)"):format(d.x, d.y))
	-- The leg's search starts on A's axis, where the straight from the approach ends: short of the building's cell,
	-- and clear all the way.
	local along = (start.x - c.x) * d.x + (start.y - c.y) * d.y
	local across = (start.x - c.x) * d.y - (start.y - c.y) * d.x
	t.near(across, 0, 1e-6, "on A's axis")
	t.ok(along >= 180 - 1e-6, "not behind the approach: " .. along)
	t.ok(along < 250 / d.x, "pulled back short of the building: " .. along)
	t.ok(grid.cellsAlong(g, { x = c.x + 180 * d.x, y = c.y + 180 * d.y }, start, function(i)
		return not g.blocked[i]
	end), "straight clear")
end)

-- A disc of the flat grid around (3000, -300), 1100 m across the radius, set by `mark(g, i)`: the line from A (0, 0)
-- to B (6000, 0) has to go round its northern edge.
local function roundGrid(mark)
	local g = flatGrid()
	for iy = 1, 31 do
		for ix = 1, 81 do
			local c = grid.centre(g, ix, iy)
			local dx, dy = c.x - 3000, c.y + 300
			if math.sqrt(dx * dx + dy * dy) <= 1100 then
				mark(g, grid.index(g, ix, iy))
			end
		end
	end
	return g
end

local function countKind(leg, kind)
	local n = 0
	for __, span in ipairs(leg.spans) do
		if span.kind == kind then
			n = n + 1
		end
	end
	return n
end

t.test("route: the curves keep to the lake shore the search followed", function()
	local g = roundGrid(function(g, i)
		g.water[i] = true
	end)
	-- A wide radius made the old smoothing cut 600 m across the lake's edge on a bridge.
	local plan = run(g, { town(1, "A", 0, 0), town(2, "B", 6000, 0) }, 160, withWeights({ minRadius = 1000 }))
	t.ok(plan.ok, "ok")
	local leg = plan.legs[1]
	for __, sample in ipairs(leg.samples) do
		t.ok(not grid.waterAt(g, sample.p), ("dry at (%.0f, %.0f)"):format(sample.p.x, sample.p.y))
	end
	t.eq(countKind(leg, "bridge"), 0, "no bridge")
	-- The guard used to tighten the curves along the shore; the search now leaves room for the full radius.
	t.eq(leg.searchRadius, 1000, "searched at the full radius")
	t.eq(leg.tightCurves, 0, "no tight curves")
	t.eq(plan.summary.guarded, leg.guarded, "summary")
end)

t.test("route: the curves go round the end of a steep hill, not through it", function()
	local g = roundGrid(function(g, i)
		g.height[i] = 60
	end)
	local job = route.start({ grid = g, stops = { town(1, "A", 0, 0), town(2, "B", 6000, 0) },
		weights = withWeights({ minRadius = 600 }), platformLength = 160 })
	local path = nil
	while not route.step(job, 500) do
		path = job.path or path
	end
	local plan = route.plan(job)
	t.ok(plan.ok, "ok")
	-- The path's knight moves pass between hill and plain cells, so the path itself climbs a little way up the
	-- hill's edge (bilinear heights): the track may go no higher than that.
	local pathTop = 0
	for k = 2, #path do
		for f = 0, 1, 0.05 do
			local p = { x = path[k - 1].x + (path[k].x - path[k - 1].x) * f,
				y = path[k - 1].y + (path[k].y - path[k - 1].y) * f }
			pathTop = math.max(pathTop, grid.heightAt(g, p))
		end
	end
	t.ok(pathTop <= 30 + 1e-6, "the path keeps to the hill's foot: " .. pathTop)
	for __, sample in ipairs(plan.legs[1].samples) do
		t.ok(grid.heightAt(g, sample.p) <= pathTop + 1e-6,
			("no higher than the path at (%.0f, %.0f)"):format(sample.p.x, sample.p.y))
	end
	t.eq(countKind(plan.legs[1], "tunnel"), 0, "no tunnel")
	-- The guard used to tighten the curves round the hill's end; the search now leaves room for the full radius.
	t.eq(plan.legs[1].searchRadius, 600, "searched at the full radius")
	t.eq(plan.legs[1].tightCurves, 0, "no tight curves")
end)

t.test("route: on flat open ground the guard changes nothing", function()
	-- y from -1500 to 3500, so C's station fits. Pieces and lengths with the stations facing the scouted line, and
	-- (at 1000 m) the legs' ends free to move out along the stations' axes (from before the guard, with the stations
	-- facing town to town: 2854.558372 and 2009.573552 m at 220 m, 2881.384564 and 2023.974285 m at 1000 m).
	local g = grid.new(-1000, -1500, 100, 81, 51)
	local stops = { town(1, "A", 0, 0), town(2, "B", 3000, 0), town(3, "C", 4500, 1500) }
	local before = { [220] = { { 5, 2869.190062 }, { 7, 2002.722075 } },
		[1000] = { { 7, 2892.308693 }, { 5, 1997.910660 } } }
	for radius, legs in pairs(before) do
		local plan = run(g, stops, 160, withWeights({ minRadius = radius }))
		t.ok(plan.ok, "ok")
		t.eq(plan.summary.guarded, 0, radius .. ": guarded")
		for k, leg in ipairs(plan.legs) do
			t.eq(#leg.pieces, legs[k][1], radius .. ": leg " .. k .. " pieces")
			t.near(leg.length, legs[k][2], 1e-3, radius .. ": leg " .. k .. " length")
			-- A leg's ends lie off their cells' centres, and a station may face between the 16 headings (B here faces
			-- 22.5°), so the first turn off its axis can be a little more than a 22.5° step, and its curve a little
			-- under the radius (977 m at 1000 m, leg 2).
			t.ok(leg.minRadius >= 0.97 * radius - 1e-6, radius .. ": leg " .. k .. " radius " .. leg.minRadius)
			t.eq(leg.guarded, 0, radius .. ": leg " .. k .. " guarded")
		end
	end
end)

t.test("route: a plain incline isn't mistaken for an obstacle", function()
	-- Ground tilted across the line (north-south), so the stations still find level runs; the grade limit is high
	-- enough that the search never sees a slope. The track should be just what it is on flat ground.
	local stops = { town(1, "A", 0, 0), town(2, "B", 3000, 0), town(3, "C", 6000, 1000) }
	for __, radius in ipairs({ 220, 1000, 3000 }) do
		local w = withWeights({ minRadius = radius, maxGrade = 0.2 })
		local flat = run(flatGrid(), stops, 160, w)
		t.ok(flat.ok, "flat ok")
		for __, slope in ipairs({ 0.04, 0.08, -0.08 }) do
			local label = ("radius %d, slope %.2f"):format(radius, slope)
			local g = flatGrid()
			for iy = 1, 31 do
				for ix = 1, 81 do
					g.height[grid.index(g, ix, iy)] = 100 + slope * grid.centre(g, ix, iy).y
				end
			end
			local plan = run(g, stops, 160, w)
			t.ok(plan.ok, label .. ": ok")
			t.eq(plan.summary.guarded, 0, label .. ": guarded")
			-- Turned to face the scouted line, a station's run may climb more than 10 m across the slope: then it
			-- turns less (15° off the line), and its legs differ from the flat ground's. Compare where the stations
			-- match.
			local same = true
			for k, station in ipairs(plan.stations) do
				local ref = flat.stations[k].site
				same = same and math.abs(station.site.dir.x - ref.dir.x) < 1e-9
					and math.abs(station.site.dir.y - ref.dir.y) < 1e-9
					and math.abs(station.site.centre.x - ref.centre.x) < 1e-9
					and math.abs(station.site.centre.y - ref.centre.y) < 1e-9
			end
			if not same then
				t.ok(math.abs(slope) > 0.05, label .. ": only the steeper slopes move a station")
			end
			for k, leg in ipairs(same and plan.legs or {}) do
				local ref = flat.legs[k]
				t.eq(#leg.pieces, #ref.pieces, label .. ": leg " .. k .. " pieces")
				t.near(leg.length, ref.length, 1e-6, label .. ": leg " .. k .. " length")
				t.eq(leg.minRadius, ref.minRadius, label .. ": leg " .. k .. " radius")
			end
		end
	end
end)

-- A two-town line, A (0, 0) to B (5000, 0), with a wall in the column round x = 300 from the bottom of the grid up to
-- row `top` (y = −1500 + 100 (top − 1)): A's room to turn is pulled back from x = 271 to 221 (a 41 m straight past its
-- approach at x = 180), and the line has to turn sharply north there.
local function walledStart(top, extra)
	local g = flatGrid()
	for iy = 1, top do
		g.blocked[grid.index(g, 14, iy)] = true
	end
	if extra then
		extra(g)
	end
	-- The scouted line climbs north past the wall, so A would turn to face it and the sharp turn these tests are
	-- about would go away: keep the sites found facing town to town (east), to test the extension rules alone.
	local job = route.start({ grid = g, stops = { town(1, "A", 0, 0), town(2, "B", 5000, 0) }, weights = W,
		platformLength = 160 })
	local first, steps = nil, 0
	while not route.step(job, 500) do
		if job.phase == "scout" and first == nil then
			first = {}
			for k, station in ipairs(job.result.stations) do
				first[k] = station.site
			end
		elseif job.phase == "legs" and first ~= nil then
			job.taken, job.footprint = {}, {}
			for k, station in ipairs(job.result.stations) do
				station.site = first[k]
				local c, d = station.site.centre, station.site.dir
				for o = -80, 80, 50 do
					job.taken[grid.index(g, grid.cellOf(g, { x = c.x + d.x * o, y = c.y + d.y * o }))] = true
				end
				-- The legs keep off the platforms and approaches (80 + 100 m either side of the centre).
				for o = -180, 180, 25 do
					job.footprint[grid.index(g, grid.cellOf(g, { x = c.x + d.x * o, y = c.y + d.y * o }))] = true
				end
			end
			first = nil
			-- Nor re-sited when a leg comes out with a curve below the build minimum.
			job.resited = { true, true }
		end
		steps = steps + 1
		assert(steps < 100000, "runaway")
	end
	local plan = route.plan(job)
	t.near(plan.stations[1].site.dir.x, 1, 1e-9, "A faces east")
	return plan
end

t.test("route: a sharp turn just past a short extension gives the extension up rather than build too tight", function()
	-- Kept, the 41 m straight left room for a 33 m curve only.
	local plan = walledStart(17)
	t.ok(plan.ok, "ok")
	local leg = plan.legs[1]
	t.ok(leg.minRadius >= W.minBuildRadius - 1e-6, "no curve below the build minimum: " .. leg.minRadius)
	t.eq(leg.blockedSamples, 0, "off the wall")
	-- The platforms stay straight: the turn starts after their end.
	local first = leg.pieces[1]
	t.eq(first.kind, "straight", "leaves straight")
	t.near(first.a.x, 80, 1e-6, "from the platform end")
	t.ok(first.length > 0, "straight " .. first.length)
end)

t.test("route: a turn with no room at the floor where the extension ends is made where it fits", function()
	-- A second wall across the cells round (100..300, 200) would turn the line back west 100 m past A's extension: a
	-- 140° turn there, which at the build minimum needs more than the 100 m of approach behind it (the search used to
	-- take it, and the curve came out below the build minimum). The search prices its corners by the room their curves
	-- have, so it goes where they fit: here round the station's far end, clear of its platforms and approaches, with
	-- curves tighter than the mode's radius but buildable.
	local plan = walledStart(20, function(g)
		for ix = 12, 14 do
			g.blocked[grid.index(g, ix, 18)] = true
		end
	end)
	t.ok(plan.ok, "ok")
	local leg = plan.legs[1]
	t.ok(leg.minRadius >= W.minBuildRadius - 1e-6, "buildable: " .. leg.minRadius)
	t.ok(leg.tightCurves >= 1, "counted")
	t.eq(leg.blockedSamples, 0, "off the walls")
	-- Going round, the track keeps off A's platforms and approaches (within 180 m of its centre along the line and
	-- 50 m across it), past the first few hundred metres where it leaves them.
	for __, sample in ipairs(leg.samples) do
		if sample.s > 400 then
			t.ok(not (math.abs(sample.p.x) <= 180 and math.abs(sample.p.y) <= 50),
				("over the station at (%.0f, %.0f), %.0f m along"):format(sample.p.x, sample.p.y, sample.s))
		end
	end
	-- The platforms stay straight: the curve starts at their end at the earliest.
	local first = leg.pieces[1]
	t.near(first.a.x, 80, 1e-6, "from the platform end")
	t.near(first.a.y, 0, 1e-6, "from the platform end")
	if first.kind == "arc" then
		t.near(first.a.x - first.centre.x, 0, 1e-6, "the curve leaves along the platforms")
	end
end)

t.test("route: a passage too narrow for the full radius falls back to a smaller one rather than fail", function()
	-- Everything blocked but a corridor one cell wide: along y = 0, up at x = 2500 to y = 500, along it to x = 3500,
	-- and back down to y = 0 and on to B. Its right-angle corners fit only the free turns of a radius whose minimum
	-- straight is no longer than a cell.
	local g = flatGrid()
	for iy = 1, 31 do
		for ix = 1, 81 do
			local c = grid.centre(g, ix, iy)
			local open = (c.y == 0 and (c.x <= 2500 or c.x >= 3500))
				or (c.y == 500 and c.x >= 2500 and c.x <= 3500)
				or ((c.x == 2500 or c.x == 3500) and c.y >= 0 and c.y <= 500)
			g.blocked[grid.index(g, ix, iy)] = not open
		end
	end
	local job = route.start({ grid = g, stops = { town(1, "A", 0, 0), town(2, "B", 6000, 0) },
		weights = withWeights({ minRadius = 1000 }), platformLength = 160 })
	local last = 0
	while not route.step(job, 50) do
		local p = route.progress(job)
		t.ok(p >= last - 1e-9, "progress never goes back, through the retries")
		last = p
	end
	local plan = route.plan(job)
	t.ok(plan.ok, "ok")
	local leg = plan.legs[1]
	-- 1000 (L ≈ 398 m) and 500 (199 m) find nothing; 250 (99 m) turns freely.
	t.eq(leg.searchRadius, 250, "search radius")
	t.ok(leg.searchExpansions > 0, "expansions counted")
	-- Smoothing still aims for 1000 m: the corners can't take it, so the curves are tight, held to the corridor.
	t.ok(leg.tightCurves > 0, "tight curves: " .. leg.tightCurves)
	t.ok(leg.guarded > 0, "guarded: " .. leg.guarded)
	t.eq(leg.blockedSamples, 0, "in the corridor")
end)

t.test("route: a leg's search radius is the full radius on open ground", function()
	local plan = run(flatGrid(), { ABC[1], ABC[2] }, 160, withWeights({ minRadius = 1000 }))
	t.ok(plan.ok, "ok")
	t.eq(plan.legs[1].searchRadius, 1000, "full radius")
	local cheapest = run(flatGrid(), { ABC[1], ABC[2] })
	t.eq(cheapest.legs[1].searchRadius, 220, "Cheapest: its own radius, one try")
end)

-- Grid cells under each station's platforms, by index (every quarter cell along them).
local function platformSet(g, station, platformLength)
	local cells = {}
	local c, d = station.site.centre, station.site.dir
	for s = -platformLength / 2, platformLength / 2, 25 do
		cells[grid.index(g, grid.cellOf(g, { x = c.x + d.x * s, y = c.y + d.y * s }))] = true
	end
	return cells
end

t.test("route: an end station faces the way the line leaves it, not straight at the next town", function()
	-- A wall east of A, from the grid's bottom edge up to y = 600: the line leaves A north-eastwards round its top.
	local g = flatGrid()
	for iy = 1, 31 do
		for ix = 1, 81 do
			local c = grid.centre(g, ix, iy)
			if c.x >= 700 and c.x <= 900 and c.y <= 600 then
				g.blocked[grid.index(g, ix, iy)] = true
			end
		end
	end
	local job = route.start({ grid = g, stops = { town(1, "A", 0, 0), town(2, "B", 5000, 0) }, weights = W,
		platformLength = 160 })
	local scoutSteps, last = 0, 0
	while not route.step(job, 50) do
		if job.phase == "scout" then
			scoutSteps = scoutSteps + 1
		end
		local p = route.progress(job)
		t.ok(p >= last - 1e-9, "progress never goes back")
		last = p
	end
	local plan = route.plan(job)
	t.ok(plan.ok, "ok")
	t.ok(scoutSteps > 2, "the scout's search is spread over steps: " .. scoutSteps)
	local dir = plan.stations[1].site.dir
	t.ok(dir.y > 0.25, ("A turned towards the line: (%.2f, %.2f)"):format(dir.x, dir.y))
	t.eq(plan.legs[1].blockedSamples, 0, "off the wall")
	t.eq(plan.summary.tightCurves, 0, "no tight curves")
end)

t.test("route: a middle station faces along the line through it", function()
	-- Water everywhere south of y = 800 between x = 600 and x = 2400, and north of y = -800 between x = 3600 and
	-- x = 5400: the line from A (0, 0) climbs north-east to pass the first, crosses B (3000, 0) heading south-east and
	-- passes south of the second, on to C (6000, 0). Facing A to C (east), B would make both legs bend sharply.
	local g = flatGrid()
	for iy = 1, 31 do
		for ix = 1, 81 do
			local c = grid.centre(g, ix, iy)
			if (c.x >= 600 and c.x <= 2400 and c.y <= 800) or (c.x >= 3600 and c.x <= 5400 and c.y >= -800) then
				g.water[grid.index(g, ix, iy)] = true
			end
		end
	end
	local plan = run(g, ABC, 160, withWeights({ bridgeFactor = 100 }))
	t.ok(plan.ok, "ok")
	local dir = plan.stations[2].site.dir
	t.ok(dir.y < -0.25, ("B faces south-east: (%.2f, %.2f)"):format(dir.x, dir.y))
	t.eq(plan.summary.blockedSamples, 0, "nothing in the way")
	-- No two stations' platforms share a cell.
	local seen = {}
	for k, station in ipairs(plan.stations) do
		for i in pairs(platformSet(g, station, 160)) do
			t.ok(seen[i] == nil, "station " .. k .. " on station " .. tostring(seen[i]) .. "'s platforms")
			seen[i] = k
		end
	end
end)

t.test("route: a station turned to face the line keeps its room to turn", function()
	-- As above, a wall east of A that the line climbs round, and a building just beyond the approach on the axis A
	-- would turn to (north-east), which would cut its room to turn to nothing.
	local g = flatGrid()
	for iy = 1, 31 do
		for ix = 1, 81 do
			local c = grid.centre(g, ix, iy)
			if c.x >= 700 and c.x <= 900 and c.y <= 600 then
				g.blocked[grid.index(g, ix, iy)] = true
			end
		end
	end
	g.blocked[grid.index(g, grid.cellOf(g, { x = 200, y = 100 }))] = true
	local job = route.start({ grid = g, stops = { town(1, "A", 0, 0), town(2, "B", 5000, 0) }, weights = W,
		platformLength = 160 })
	local start = nil
	while not route.step(job, 500) do
		start = start or job.path and job.path[1]
	end
	local plan = route.plan(job)
	t.ok(plan.ok, "ok")
	local c, d = plan.stations[1].site.centre, plan.stations[1].site.dir
	local along = (start.x - c.x) * d.x + (start.y - c.y) * d.y
	-- The platform's half, the approach, and the full room to turn at 220 m (220 × tan 22.5°).
	t.near(along, 80 + 100 + 220 * math.tan(math.pi / 8), 1e-6, ("A's room to turn, facing (%.2f, %.2f)"):format(d.x,
		d.y))
	t.eq(plan.summary.blockedSamples, 0, "nothing in the way")
end)

t.test("route: a station site far from a built-up centre is searched over several steps", function()
	-- y from -2500 to 2500: A's centre is built up for 900 m around, so its site lies past it.
	local g = grid.new(-3000, -2500, 100, 101, 51)
	for iy = 1, g.ny do
		for ix = 1, g.nx do
			local c = grid.centre(g, ix, iy)
			if math.sqrt(c.x * c.x + c.y * c.y) <= 900 then
				g.blocked[grid.index(g, ix, iy)] = true
			end
		end
	end
	local job = route.start({ grid = g, stops = { town(1, "A", 0, 0), town(2, "B", 6000, 0) }, weights = W,
		platformLength = 160 })
	local siteSteps = 0
	while job.phase == "sites" do
		route.step(job, 500)
		siteSteps = siteSteps + 1
	end
	t.ok(siteSteps > 3, "spread over steps: " .. siteSteps)
	local plan = route.plan(job)
	t.ok(#plan.stations == 2, "both sited")
	t.ok(plan.stations[1].site.distance > 800, "A's site past the built-up centre: " .. plan.stations[1].site.distance)
end)

t.test("route: close stations' rooms to turn don't overlap, so the leg between them swings across instead of looping", function()
	-- Fastest at 3 km wants 597 m of room to turn beyond each approach. B and C are 1.36 km apart, both facing east,
	-- 400 m apart sideways: uncapped, C's room to turn started west of where B's ended, and the leg looped back with a
	-- 57 m curve (Temple City to Miami on the 54-town map did the same over buildings).
	local fastest = {}
	for k, v in pairs(W) do
		fastest[k] = v
	end
	fastest.minRadius, fastest.maxGrade, fastest.turnPenalty = 3000, 0.025, 150
	local g = grid.new(-2000, -1500, 100, 101, 41)
	local plan = run(g, { town(1, "A", -1500, 0), town(2, "B", 0, 0), town(3, "C", 1300, 400), town(4, "D", 2800, 400) },
		160, fastest)
	t.ok(plan.ok, "ok")
	local leg = plan.legs[2]
	t.ok(leg.minRadius >= 500, "B to C swings across: min radius " .. leg.minRadius)
	t.ok(leg.length < 1300, "and doesn't loop: " .. leg.length .. " m")
end)

-- Blocks a ring of cells from r0 to r1 round (cx, cy).
local function ring(g, cx, cy, r0, r1)
	for iy = 1, g.ny do
		for ix = 1, g.nx do
			local c = grid.centre(g, ix, iy)
			local r = math.sqrt((c.x - cx) ^ 2 + (c.y - cy) ^ 2)
			if r >= r0 and r <= r1 then
				g.blocked[grid.index(g, ix, iy)] = true
			end
		end
	end
end

t.test("route: a station isn't put in a clear spot that buildings wall in", function()
	-- A's centre is open, inside a ring of buildings 600 to 900 m out: the site must be outside it.
	local g = grid.new(-3000, -2500, 100, 111, 51)
	ring(g, 0, 0, 600, 900)
	local plan = run(g, { town(1, "A", 0, 0), town(2, "B", 6000, 0) })
	t.ok(plan.ok, "plans: " .. tostring(plan.failure))
	t.ok(plan.stations[1].site.distance >= 900, "A's site outside the ring: " .. plan.stations[1].site.distance)
end)

t.test("route: a town whose every clear spot is walled in fails no_exit, not no_path", function()
	-- A ring 1.6 to 1.9 km out: every spot within the site search's 1.5 km is inside it.
	local g = grid.new(-3000, -3000, 100, 111, 61)
	ring(g, 0, 0, 1600, 1900)
	local plan = run(g, { town(1, "A", 0, 0), town(2, "B", 6000, 0) })
	t.ok(not plan.ok, "fails")
	t.eq(plan.failure, "no_exit", "reason")
	t.eq(plan.failureTowns[1], "A", "town")
	t.eq(#plan.legs, 0, "no leg searched")
end)

t.test("route: a leg whose start is walled in, beyond the site's reach, fails no_exit for that town", function()
	-- A wall round A's half of the grid, 2.5 to 2.8 km out (beyond what the site check looks at): the leg's search
	-- finds its region closed off inside the grid, so a wider area can't help.
	local g = grid.new(-4000, -4000, 100, 141, 81)
	ring(g, 0, 0, 2500, 2800)
	local plan = run(g, { town(1, "A", 0, 0), town(2, "B", 6000, 0) })
	t.ok(not plan.ok, "fails")
	t.eq(plan.failure, "no_exit", "reason")
	t.eq(plan.failureTowns[1], "A", "town")
end)

t.test("route: the turning phase's steps stay within the site search's work budget", function()
	local g = grid.new(-3000, -2500, 100, 111, 51)
	ring(g, 0, 0, 600, 900)
	ring(g, 3000, 0, 500, 800)
	local job = route.start({ grid = g, stops = { town(1, "A", 0, 0), town(2, "B", 3000, 0), town(3, "C", 6000, 0) },
		weights = W, platformLength = 160 })
	local turnSteps, most = 0, 0
	while not route.step(job, 500) do
		if job.phase == "turn" and job.finder ~= nil then
			turnSteps = turnSteps + 1
			most = math.max(most, job.finder.work)
		end
	end
	t.ok(route.plan(job).ok, "plans")
	t.ok(turnSteps > 0, "turning searched")
	t.ok(most <= 500 + 5 * 9 + 2, "most work in a turning step " .. most)
end)

-- Plans A to B on open ground with B's site forced, at the start of the legs, to face `dir` (as if the turning had
-- kept a first site facing the wrong way). With resite false, B is never re-sited.
local function forcedB(dir, resite)
	local g = grid.new(-2000, -3000, 100, 91, 61)
	local job = route.start({ grid = g, stops = { town(1, "A", 0, 0), town(2, "B", 5000, 0) }, weights = W,
		platformLength = 160 })
	local forced = false
	while not route.step(job, 500) do
		if job.phase == "legs" and not forced then
			forced = true
			local b = job.result.stations[2]
			b.site = { centre = b.site.centre, dir = dir, distance = b.site.distance }
			job.taken = {}
			for __, station in ipairs(job.result.stations) do
				local c, d = station.site.centre, station.site.dir
				for o = -80, 80, 50 do
					job.taken[grid.index(g, grid.cellOf(g, { x = c.x + d.x * o, y = c.y + d.y * o }))] = true
				end
			end
			if not resite then
				job.resited = { true, true }
			end
		end
	end
	return route.plan(job)
end

local function sweep(leg)
	local h, lo, hi = 0, 0, 0
	for __, piece in ipairs(leg.pieces) do
		if piece.kind == "arc" then
			h = h + piece.turn
			lo, hi = math.min(lo, h), math.max(hi, h)
		end
	end
	return math.deg(hi - lo)
end

t.test("route: a station facing back the way the line comes is re-sited, so the leg doesn't hook round into it", function()
	-- B faces west, towards A: the line from A has to pass B and turn right round to enter it.
	local west = { x = -1, y = 0 }
	local hooked = forcedB(west, false)
	t.ok(hooked.ok, "plans")
	-- Turning right round: 180° and more, or a hairpin below the build minimum.
	t.ok(sweep(hooked.legs[1]) >= 170 or hooked.legs[1].minRadius < W.minBuildRadius,
		"without re-siting it hooks: " .. sweep(hooked.legs[1]) .. "°, " .. hooked.legs[1].minRadius .. " m")
	local plan = forcedB(west, true)
	t.ok(plan.ok, "plans")
	t.ok(plan.stations[2].site.dir.x > 0.5, "B faces along the line: " .. plan.stations[2].site.dir.x)
	t.ok(sweep(plan.legs[1]) < 90, "no hook: " .. sweep(plan.legs[1]))
	t.ok(plan.legs[1].minRadius >= W.minBuildRadius, "buildable: " .. plan.legs[1].minRadius)
	t.ok(plan.legs[1].length < hooked.legs[1].length, "shorter")
end)

t.test("route: a station facing the right way is kept when its leg is fine", function()
	local plan = forcedB({ x = 1, y = 0 }, true)
	t.ok(plan.ok, "plans")
	t.near(plan.stations[2].site.dir.x, 1, 1e-9, "unchanged")
end)

-- Fastest-like weights at 1500 m: the speed model, and a second lost worth `timeCost` metres of plain track.
local function timed(timeCost)
	return withWeights({ minRadius = 1500, lateralAccel = 2, topSpeed = math.sqrt(2 * 1500), timeCost = timeCost })
end

-- A chicane: a wall up from the bottom edge to y = 600 at x = 2000..2100, and one down from the top to y = -600 at
-- x = 2900..3000, so the line from A to B must weave between them.
local function chicane()
	local g = flatGrid()
	for iy = 1, 31 do
		for ix = 1, 81 do
			local c = grid.centre(g, ix, iy)
			if (c.x >= 2000 and c.x <= 2100 and c.y <= 600) or (c.x >= 2900 and c.x <= 3000 and c.y >= -600) then
				g.blocked[grid.index(g, ix, iy)] = true
			end
		end
	end
	return g
end

t.test("route: with time priced, a leg's radius is weighed by the time its curves lose", function()
	local AB = { town(1, "A", 0, 0), town(2, "B", 6000, 0) }
	-- Time worth next to nothing: the cheapest try wins, a 375 m weave (about a minute lost).
	local cheap = run(chicane(), AB, 160, timed(1e-6))
	-- Time worth a lot: a wider weave, a little dearer, loses less.
	local fast = run(chicane(), AB, 160, timed(1000))
	t.ok(cheap.ok and fast.ok, "ok")
	local slow, quick = cheap.legs[1], fast.legs[1]
	t.ok(quick.timeLost < slow.timeLost - 5, ("time lost %.1f s against %.1f s"):format(quick.timeLost, slow.timeLost))
	t.ok(quick.searchRadius > slow.searchRadius, ("radius %.0f against %.0f"):format(quick.searchRadius,
		slow.searchRadius))
	t.near(fast.summary.timeLost, quick.timeLost, 1e-9, "summary")
	t.eq(fast.legs[1].blockedSamples, 0, "between the walls")
	-- A straight leg loses nothing.
	local straight = run(flatGrid(), { ABC[1], ABC[2] }, 160, timed(50))
	t.near(straight.legs[1].timeLost, 0, 1e-9, "straight")
end)

t.test("route: weighing every radius, progress never goes back", function()
	local job = route.start({ grid = chicane(), stops = { town(1, "A", 0, 0), town(2, "B", 6000, 0) },
		weights = timed(50), platformLength = 160 })
	local last = 0
	while not route.step(job, 50) do
		local p = route.progress(job)
		t.ok(p >= last - 1e-9, ("progress %.4f after %.4f"):format(p, last))
		last = p
	end
	t.ok(route.plan(job).ok, "ok")
end)
