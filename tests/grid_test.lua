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

local EAST = { x = 1, y = 0 }

local function run(g, from, to, w, stepSize, startDir, goalDir)
	local s = grid.startSearch(g, from, to, startDir or EAST, goalDir or EAST, w or W)
	while not grid.stepSearch(s, stepSize or 1000) do end
	return grid.path(s), s
end

local function cellIndex(g, p)
	local ix, iy = grid.cellOf(g, p)
	return grid.index(g, ix, iy)
end

local function turnCost(path)
	local cost = 0
	for i = 2, #path - 1 do
		local ax, ay = path[i].x - path[i - 1].x, path[i].y - path[i - 1].y
		local bx, by = path[i + 1].x - path[i].x, path[i + 1].y - path[i].y
		local angle = math.abs(math.atan2 and math.atan2(ax * by - ay * bx, ax * bx + ay * by)
			or math.atan(ax * by - ay * bx, ax * bx + ay * by))
		local steps = math.floor(angle / (math.pi / 8) + 0.5)
		cost = cost + steps * steps
	end
	return cost
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

t.test("grid: a high turn penalty gives gentler turns overall", function()
	local low = run(lakeGrid(), { x = 0, y = 800 }, { x = 3000, y = 800 }, with({ turnPenalty = 0 }))
	local high = run(lakeGrid(), { x = 0, y = 800 }, { x = 3000, y = 800 }, with({ turnPenalty = 500 }))
	t.ok(turnCost(high) <= turnCost(low), "turn cost: high " .. turnCost(high) .. ", low " .. turnCost(low))
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

local function angleBetween(a, b)
	local c = (a.x * b.x + a.y * b.y) / (math.sqrt(a.x * a.x + a.y * a.y) * math.sqrt(b.x * b.x + b.y * b.y))
	return math.acos(math.max(-1, math.min(1, c)))
end

local function segment(path, i)
	return { x = path[i + 1].x - path[i].x, y = path[i + 1].y - path[i].y }
end

t.test("grid: arrives in the asked direction", function()
	local g = grid.new(0, 0, 100, 21, 21)
	local west = { x = -1, y = 0 }
	local path = run(g, { x = 1000, y = 1000 }, { x = 1000, y = 1800 }, W, 1000, EAST, west)
	t.ok(path ~= nil, "found")
	t.ok(angleBetween(segment(path, 1), EAST) <= math.pi / 2 + 1e-6, "leaves within 90° of the start direction")
	t.ok(angleBetween(segment(path, #path - 1), west) <= math.pi / 2 + 1e-6, "arrives within 90° of the goal direction")
	-- Arriving southwards at a goal due north means looping round past it: without the goal direction the path
	-- would arrive heading north.
	local south = { x = 0, y = -1 }
	local loop = run(g, { x = 1000, y = 1000 }, { x = 1000, y = 1800 }, W, 1000, EAST, south)
	t.ok(loop ~= nil, "found the loop")
	t.ok(angleBetween(segment(loop, #loop - 1), south) <= math.pi / 2 + 1e-6, "arrives heading south")
end)

t.test("grid: a blocked goal fails at once", function()
	local g = grid.new(0, 0, 100, 21, 21)
	g.blocked[cellIndex(g, { x = 2000, y = 1000 })] = true
	local s = grid.startSearch(g, { x = 0, y = 1000 }, { x = 2000, y = 1000 }, EAST, EAST, W)
	t.ok(s.done, "done after startSearch")
	t.ok(grid.stepSearch(s, 1), "stepSearch reports done")
	t.eq(s.expansions, 0, "no expansions")
	t.eq(grid.path(s), nil, "no path")
end)

t.test("grid: a walled-in goal fails at once", function()
	local g = grid.new(0, 0, 100, 21, 21)
	-- The goal cell (16, 11) is free, inside a closed ring of blocked cells (knight moves can't jump it either).
	for iy = 10, 12 do
		for ix = 15, 17 do
			if ix ~= 16 or iy ~= 11 then
				g.blocked[grid.index(g, ix, iy)] = true
			end
		end
	end
	local s = grid.startSearch(g, { x = 0, y = 1000 }, { x = 1500, y = 1000 }, EAST, EAST, W)
	-- The reachability fill runs first, one cell per unit of budget: 21 × 21 cells fit in one call.
	t.ok(grid.stepSearch(s, 21 * 21), "done after the fill")
	t.eq(s.expansions, 0, "no expansions")
	t.eq(grid.path(s), nil, "no path")
end)

t.test("grid: no move turns more than 90°", function()
	for __, w in ipairs({ W, with({ turnPenalty = 0 }), with({ bridgeFactor = 1.5 }) }) do
		local path = run(lakeGrid(), { x = 0, y = 800 }, { x = 3000, y = 800 }, w)
		t.ok(path ~= nil, "found")
		for i = 1, #path - 2 do
			local angle = angleBetween(segment(path, i), segment(path, i + 1))
			t.ok(angle <= math.pi / 2 + 1e-6, "turn at point " .. (i + 1) .. ": " .. math.deg(angle) .. "°")
		end
	end
end)

t.test("grid: progress rises steadily to 1", function()
	local g = lakeGrid()
	local s = grid.startSearch(g, { x = 0, y = 800 }, { x = 3000, y = 800 }, EAST, EAST, W)
	t.near(grid.progress(s), 0, 1e-9, "starts at 0")
	local last, steps = 0, 0
	while not grid.stepSearch(s, 20) do
		local p = grid.progress(s)
		t.ok(p >= last, "never falls")
		last, steps = p, steps + 1
	end
	t.ok(steps > 3, "several steps")
	t.near(grid.progress(s), 1, 1e-9, "ends at 1")
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

t.test("grid: a path doesn't follow a road when there's room beside it", function()
	-- A road along the direct line (y = 500), free ground either side.
	local g = grid.new(0, 0, 100, 21, 11)
	for ix = 1, 21 do
		g.road[grid.index(g, ix, 6)] = true
	end
	local path = run(g, { x = 0, y = 500 }, { x = 2000, y = 500 })
	t.ok(path ~= nil, "found")
	local onRoad = 0
	for __, p in ipairs(path) do
		if g.road[cellIndex(g, p)] then
			onRoad = onRoad + 1
		end
	end
	t.ok(onRoad <= 4, "mostly off the road: " .. onRoad .. " of " .. #path .. " points on it")
end)
