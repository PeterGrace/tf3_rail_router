local t = ...
local grid = t.requireTl("gui/pgrace_rail_router/planner/grid.tl")
local route = t.requireTl("gui/pgrace_rail_router/planner/route.tl")

local W = { maxGrade = 0.085, minRadius = 220, minBuildRadius = 55, slopePenalty = 3, bridgeFactor = 6, turnPenalty = 20,
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
	t.near(plan.summary.estimate, plan.summary.length * 360, 1, "estimate")
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
	t.ok(plan.legs[1].guarded > 0, "guarded")
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
			t.ok(leg.z[i] >= 7 - 1e-9, "clearance at " .. sample.s .. ": " .. leg.z[i])
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
	-- A's approach ends at x = 180; with a 1500 m radius the room to turn would run on to x = 801. A building in the
	-- cell at x = 450..550 on the line, 300 m beyond the approach.
	g.blocked[grid.index(g, 16, 16)] = true
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
	t.ok(route.plan(job).ok, "ok")
	t.ok(start ~= nil, "searched")
	-- The leg's search starts where the straight from the approach ends: before the building, and clear all the way.
	t.ok(start.x < 450, "search starts before the building: x " .. start.x)
	t.ok(start.x > 180 - 1e-6, "and not behind the approach: x " .. start.x)
	for x = 180, start.x, 5 do
		t.ok(not g.blocked[grid.index(g, grid.cellOf(g, { x = x, y = 0 }))], "straight clear at x " .. x)
	end
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
	t.ok(leg.guarded > 0, "guarded " .. leg.guarded)
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
	t.ok(plan.legs[1].guarded > 0, "guarded")
end)

t.test("route: on flat open ground the guard changes nothing", function()
	-- y from -1500 to 3500, so C's station fits. Pieces and lengths from before the guard.
	local g = grid.new(-1000, -1500, 100, 81, 51)
	local stops = { town(1, "A", 0, 0), town(2, "B", 3000, 0), town(3, "C", 4500, 1500) }
	local before = { [220] = { { 5, 2854.558372 }, { 7, 2009.573552 } },
		[1000] = { { 7, 2881.384564 }, { 5, 2023.974285 } } }
	for radius, legs in pairs(before) do
		local plan = run(g, stops, 160, withWeights({ minRadius = radius }))
		t.ok(plan.ok, "ok")
		t.eq(plan.summary.guarded, 0, radius .. ": guarded")
		for k, leg in ipairs(plan.legs) do
			t.eq(#leg.pieces, legs[k][1], radius .. ": leg " .. k .. " pieces")
			t.near(leg.length, legs[k][2], 1e-3, radius .. ": leg " .. k .. " length")
			t.near(leg.minRadius, radius, 1e-6, radius .. ": leg " .. k .. " radius")
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
			for k, leg in ipairs(plan.legs) do
				local ref = flat.legs[k]
				t.eq(#leg.pieces, #ref.pieces, label .. ": leg " .. k .. " pieces")
				t.near(leg.length, ref.length, 1e-6, label .. ": leg " .. k .. " length")
				t.eq(leg.minRadius, ref.minRadius, label .. ": leg " .. k .. " radius")
			end
		end
	end
end)
