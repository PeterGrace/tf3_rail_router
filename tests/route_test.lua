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

t.test("route: track cutting across an obstacle is counted", function()
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
	t.ok(plan.legs[1].blockedSamples > 0, "counted " .. plan.legs[1].blockedSamples)
	t.eq(plan.summary.blockedSamples, plan.legs[1].blockedSamples, "summary")
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
