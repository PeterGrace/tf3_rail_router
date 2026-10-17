local t = ...
local grid = t.requireTl("gui/pgrace_rail_router/planner/grid.tl")

local W = { maxGrade = 0.025, minRadius = 220, slopePenalty = 2, bridgeFactor = 6, turnPenalty = 20,
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

-- The cells cellsAlong visits, as a set and in visiting order.
local function along(g, a, b)
	local set, order = {}, {}
	grid.cellsAlong(g, a, b, function(i)
		t.ok(not set[i], "cell " .. i .. " visited once")
		set[i] = true
		table.insert(order, i)
		return true
	end)
	return set, order
end

t.test("grid: cellsAlong catches a cell whose corner the segment clips between samples", function()
	local g = grid.new(0, 0, 100, 4, 4)
	-- x + y = 101 cuts the corner of the cell round (100, 100) at (50.5, 50.5); points every quarter cell along it
	-- all fall in the cells round (0, 100) and (100, 0).
	local set = along(g, { x = 21, y = 80 }, { x = 81, y = 20 })
	t.ok(set[grid.index(g, 2, 2)], "the clipped cell")
	t.ok(set[grid.index(g, 1, 2)] and set[grid.index(g, 2, 1)], "the cells it runs through")
	t.ok(not set[grid.index(g, 1, 1)], "not the cell it passes beside")
end)

t.test("grid: cellsAlong counts every cell at a corner it passes through exactly", function()
	local g = grid.new(0, 0, 100, 4, 4)
	local set = along(g, { x = 20, y = 80 }, { x = 80, y = 20 })
	for __, c in ipairs({ { 1, 1 }, { 1, 2 }, { 2, 1 }, { 2, 2 } }) do
		t.ok(set[grid.index(g, c[1], c[2])], "cell " .. c[1] .. "," .. c[2])
	end
end)

t.test("grid: cellsAlong stops when told to", function()
	local g = grid.new(0, 0, 100, 10, 1)
	local seen = 0
	local result = grid.cellsAlong(g, { x = 0, y = 0 }, { x = 900, y = 0 }, function(i)
		seen = seen + 1
		return i < 4
	end)
	t.eq(result, false, "stopped")
	t.eq(seen, 4, "at the fourth cell")
	t.eq(grid.cellsAlong(g, { x = 900, y = 0 }, { x = 0, y = 0 }, function() return true end), true, "ran through")
end)

-- Whether the segment a–b meets the closed square of half-side h round c (Liang–Barsky clipping).
local function meets(a, b, c, h)
	local t0, t1 = 0, 1
	local d = { x = b.x - a.x, y = b.y - a.y }
	for __, axis in ipairs({ "x", "y" }) do
		local lo, hi = c[axis] - h - 1e-7, c[axis] + h + 1e-7
		if math.abs(d[axis]) < 1e-12 then
			if a[axis] < lo or a[axis] > hi then
				return false
			end
		else
			local u0, u1 = (lo - a[axis]) / d[axis], (hi - a[axis]) / d[axis]
			if u0 > u1 then
				u0, u1 = u1, u0
			end
			t0, t1 = math.max(t0, u0), math.min(t1, u1)
			if t0 > t1 then
				return false
			end
		end
	end
	return true
end

t.test("grid: cellsAlong visits exactly the cells a segment meets, in order", function()
	local g = grid.new(-500, -300, 100, 12, 9)
	local seed = 12345
	local function rnd()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
	local function pt()
		-- Some points snapped to cell edges and centres, so edges and corners get hit exactly.
		local x, y = -550 + rnd() * 1200, -350 + rnd() * 900
		if rnd() < 0.3 then
			x, y = math.floor(x / 50 + 0.5) * 50, math.floor(y / 50 + 0.5) * 50
		end
		return { x = x, y = y }
	end
	for n = 1, 500 do
		local a, b = pt(), pt()
		if n % 7 == 0 then
			b.y = a.y
		elseif n % 11 == 0 then
			b.x = a.x
		end
		local set, order = along(g, a, b)
		for iy = 1, g.ny do
			for ix = 1, g.nx do
				local i = grid.index(g, ix, iy)
				t.eq(set[i] == true, meets(a, b, grid.centre(g, ix, iy), 50),
					("case %d, cell %d,%d"):format(n, ix, iy))
			end
		end
		-- In order: the projections of the visited cells' centres onto a→b never go back by more than a cell's
		-- diagonal.
		local dx, dy = b.x - a.x, b.y - a.y
		local len = math.max(1e-9, math.sqrt(dx * dx + dy * dy))
		local prev = -math.huge
		for __, i in ipairs(order) do
			local c = grid.centre(g, (i - 1) % g.nx + 1, math.floor((i - 1) / g.nx) + 1)
			local s = ((c.x - a.x) * dx + (c.y - a.y) * dy) / len
			t.ok(s > prev - 100 * math.sqrt(2), "case " .. n .. " in order")
			prev = math.max(prev, s)
		end
	end
end)

-- The direction index (1..16, as in grid.tl) of a move between neighbouring path points, cell size 100 m.
local DIRS = { { 1, 0 }, { 2, 1 }, { 1, 1 }, { 1, 2 }, { 0, 1 }, { -1, 2 }, { -1, 1 }, { -2, 1 },
	{ -1, 0 }, { -2, -1 }, { -1, -1 }, { -1, -2 }, { 0, -1 }, { 1, -2 }, { 1, -1 }, { 2, -1 } }
local function dirOf(a, b)
	local dx, dy = math.floor((b.x - a.x) / 100 + 0.5), math.floor((b.y - a.y) / 100 + 0.5)
	for k, d in ipairs(DIRS) do
		if d[1] == dx and d[2] == dy then
			return k
		end
	end
	error(("not a move: (%d, %d)"):format(dx, dy))
end

local function steps(a, b)
	local t = math.abs(a - b)
	return t > 8 and 16 - t or t
end

local function dist(a, b)
	return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
end

t.test("grid: with a wide radius, turns are single steps spaced for the curves", function()
	-- A long open field, the goal 3 km to the side of the start's heading: the path has to bend twice.
	local g = grid.new(0, 0, 100, 121, 41)
	local radius = 1000
	local L = 2 * radius * math.tan(math.pi / 16)
	local from, to = { x = 500, y = 500 }, { x = 11500, y = 3500 }
	local path, s = run(g, from, to, with({ minRadius = radius, turnPenalty = 150 }))
	t.ok(path ~= nil, "found")
	t.eq(s.radius, radius, "spaced for the weights' radius")
	local lastTurn, turns = nil, 0
	for i = 2, #path - 1 do
		local before, after = dirOf(path[i - 1], path[i]), dirOf(path[i], path[i + 1])
		if before ~= after then
			turns = turns + 1
			t.eq(steps(before, after), 1, "one 22.5° step at point " .. i)
			if lastTurn ~= nil then
				local along = 0
				for k = lastTurn + 1, i do
					along = along + dist(path[k - 1], path[k])
				end
				t.ok(along >= L - 1e-6, ("turns at points %d and %d are %.0f m apart, under %.0f"):format(lastTurn, i,
					along, L))
			end
			lastTurn = i
		end
	end
	t.ok(turns >= 2, "turns: " .. turns)
end)

-- 30 × 20 cells with random buildings, water, roads and heights (a fixed sequence), the two end cells clear.
local function clutteredGrid()
	local seed = 7
	local function rnd()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
	local g = grid.new(0, 0, 100, 30, 20)
	for i = 1, 30 * 20 do
		g.blocked[i] = rnd() < 0.2
		g.water[i] = rnd() < 0.1
		g.road[i] = rnd() < 0.1
		g.height[i] = math.floor(rnd() * 30)
	end
	g.blocked[grid.index(g, 1, 10)] = false
	g.blocked[grid.index(g, 30, 10)] = false
	return g
end

t.test("grid: a radius whose minimum straight fits in a cell prices each corner by its curve's room", function()
	-- The path, cost and work, recorded when corners started being priced (before that: 10192.07 and 2931
	-- expansions for both radii, the path through 3,7 4,8 5,7 7,6 8,5 10,6): every move may still turn, but a corner
	-- costs the straight its curve at the search's radius would lack, so the wider radius costs more.
	local expected = "0,9 1,8 2,7 2,6 3,5 4,5 5,5 6,5 8,6 10,7 11,7 12,6 13,5 14,5 15,5 17,4 18,4 19,5 20,6 21,7 22,7 "
		.. "23,8 24,9 25,10 26,11 27,11 28,10 29,9"
	for __, case in ipairs({ { 220, 11006.0843625812777, 2825 }, { 250, 11254.6125000051343, 2862 } }) do
		local radius = case[1]
		local path, s = run(clutteredGrid(), { x = 0, y = 900 }, { x = 2900, y = 900 },
			with({ minRadius = radius, minBuildRadius = 55 }))
		local cells = {}
		for __, p in ipairs(path) do
			table.insert(cells, ("%d,%d"):format(p.x / 100, p.y / 100))
		end
		t.eq(table.concat(cells, " "), expected, radius .. ": path")
		t.near(s.cost[0], case[2], 1e-6, radius .. ": cost")
		t.eq(s.expansions, case[3], radius .. ": expansions")
	end
end)

-- tan(θ / 2) of the turn at path[i], and the lengths of the segments either side.
local function corner(path, i)
	local a = segment(path, i - 1)
	local b = segment(path, i)
	local la, lb = math.sqrt(a.x * a.x + a.y * a.y), math.sqrt(b.x * b.x + b.y * b.y)
	return math.tan(angleBetween(a, b) / 2), la, lb
end

-- Whether every corner between two cell centres has room for its curve at radius r in half of each segment beside it
-- (the other half is the next corner's).
local function cornersFit(path, r)
	for i = 3, #path - 2 do
		local tanHalf, la, lb = corner(path, i)
		if r * tanHalf > math.min(la, lb) / 2 + 1e-6 then
			return false, ("corner %d at (%.0f, %.0f): %.1f m of curve, %.1f m of straight"):format(i, path[i].x,
				path[i].y, r * tanHalf, math.min(la, lb) / 2)
		end
	end
	return true
end

t.test("grid: corners are spaced for curves of the build minimum", function()
	-- Random cluttered grids: whatever the path does, no corner is closer to the next than the curves at the build
	-- minimum need. (A 90° turn between two straight moves needs 55 m of straight either side: more than half a cell,
	-- so it takes a diagonal or a knight move on one side, or two 45° turns.)
	for seed = 1, 20 do
		local rnd = (function()
			local x = seed * 7919
			return function()
				x = (x * 1103515245 + 12345) % 2147483648
				return x / 2147483648
			end
		end)()
		local g = grid.new(0, 0, 100, 30, 20)
		for i = 1, 30 * 20 do
			g.blocked[i] = rnd() < 0.25
		end
		g.blocked[grid.index(g, 1, 10)] = false
		g.blocked[grid.index(g, 30, 10)] = false
		for __, build in ipairs({ 55, 70 }) do
			local path = run(g, { x = 0, y = 900 }, { x = 2900, y = 900 }, with({ minBuildRadius = build }), 1000,
				EAST, { x = 0, y = 0 })
			if path ~= nil then
				local ok, why = cornersFit(path, build)
				t.ok(ok, ("seed %d, build minimum %d: %s"):format(seed, build, tostring(why)))
			end
		end
	end
end)

t.test("grid: a curve at a start or goal point needs the station's straight behind it", function()
	-- The goal 500 m due north of the start, which heads east; the goal is to be entered heading north. With no
	-- straight behind the start point or beyond the goal point (no room, no approach), neither may turn: the path
	-- leaves heading east and arrives heading north. With a 100 m approach behind each, the curves there may use it.
	local g = grid.new(0, 0, 100, 21, 21)
	local north = { x = 0, y = 1 }
	local from, to = { x = 1000, y = 1000 }, { x = 1000, y = 1500 }
	local function search(approach)
		local s = grid.startSearch(g, from, to, EAST, north, with({ minBuildRadius = 55 }), nil, nil, nil, nil, 0, 0,
			approach)
		while not grid.stepSearch(s, 1000) do end
		return grid.path(s), s
	end
	local straight = search(0)
	t.ok(straight ~= nil, "found")
	t.near(angleBetween(segment(straight, 1), EAST), 0, 1e-6, "leaves heading east")
	t.near(angleBetween(segment(straight, #straight - 1), north), 0, 1e-6, "arrives heading north")
	local turning = search(100)
	t.ok(turning ~= nil, "found")
	t.ok(angleBetween(segment(turning, 1), EAST) > 1e-6, "turns at once")
end)

t.test("grid: a U-turn too tight for the build minimum is no path, not a hook", function()
	-- A corridor two cells wide (y = 500 and 600) running east to a dead end at x = 1500: arriving at (1000, 500)
	-- heading west means turning round at the dead end, between track centres 100 m apart, a 50 m radius at most.
	local g = grid.new(0, 0, 100, 21, 12)
	for iy = 1, 12 do
		for ix = 1, 21 do
			local c = grid.centre(g, ix, iy)
			g.blocked[grid.index(g, ix, iy)] = not ((c.y == 500 or c.y == 600) and c.x <= 1500)
		end
	end
	local west = { x = -1, y = 0 }
	local hook = run(g, { x = 100, y = 500 }, { x = 1000, y = 500 }, W, 1000, EAST, west)
	t.ok(hook ~= nil, "turning freely, the old search hooked round in the corridor")
	local path, s = run(g, { x = 100, y = 500 }, { x = 1000, y = 500 }, with({ minBuildRadius = 55 }), 1000, EAST, west)
	t.eq(path, nil, "no path")
	t.ok(s.done, "finished")
end)

t.test("grid: a loop round to a goal behind pays for its tight curves", function()
	-- Arriving heading south at a goal due north: the path loops round. Its corners fit the build minimum, and its
	-- cost is more than its length and turn penalties: the straight its curves at 220 m lack is charged.
	local g = grid.new(0, 0, 100, 21, 21)
	local south = { x = 0, y = -1 }
	local path, s = run(g, { x = 1000, y = 1000 }, { x = 1000, y = 1800 }, with({ minBuildRadius = 55 }), 1000, EAST,
		south)
	t.ok(path ~= nil, "found")
	local ok, why = cornersFit(path, 55)
	t.ok(ok, tostring(why))
	local length, penalties = 0, 0
	for i = 1, #path - 1 do
		local d = segment(path, i)
		length = length + math.sqrt(d.x * d.x + d.y * d.y)
	end
	local headings = { EAST }
	for i = 1, #path - 1 do
		table.insert(headings, segment(path, i))
	end
	table.insert(headings, south)
	for i = 1, #headings - 1 do
		local n = math.floor(angleBetween(headings[i], headings[i + 1]) / (math.pi / 8) + 0.5)
		penalties = penalties + W.turnPenalty * n * n
	end
	t.ok(s.cost[0] > length + penalties + 100, ("cost %.0f, length %.0f, turn penalties %.0f"):format(s.cost[0],
		length, penalties))
end)

t.test("grid: the radius can be given apart from the weights", function()
	local wide = with({ minRadius = 1000 })
	local a, sa = run(clutteredGrid(), { x = 0, y = 900 }, { x = 2900, y = 900 }, wide)
	local s = grid.startSearch(clutteredGrid(), { x = 0, y = 900 }, { x = 2900, y = 900 }, EAST, EAST, wide, 220)
	while not grid.stepSearch(s, 1000) do end
	t.eq(s.radius, 220, "radius")
	t.near(s.cost[0], 11006.0843625812777, 1e-6, "as with the Cheapest radius")
	t.ok(a == nil or sa.cost[0] >= s.cost[0] - 1e-9, "the wide radius never finds a cheaper path")
end)

t.test("grid: with a wide radius, a walled-off goal still fails in the fill, and maxCost cuts the search short", function()
	local g = grid.new(0, 0, 100, 21, 21)
	for iy = 1, 21 do
		g.blocked[grid.index(g, 11, iy)] = true
	end
	local path, s = run(g, { x = 0, y = 1000 }, { x = 2000, y = 1000 }, with({ minRadius = 3000 }))
	t.eq(path, nil, "no path")
	t.eq(s.expansions, 0, "no expansions")
	-- An open field: the straight path costs 2000, so a limit below that finds nothing.
	local open = grid.new(0, 0, 100, 21, 21)
	local capped = grid.startSearch(open, { x = 0, y = 1000 }, { x = 2000, y = 1000 }, EAST, EAST,
		with({ minRadius = 3000 }), nil, 1900)
	while not grid.stepSearch(capped, 1000) do end
	t.eq(grid.path(capped), nil, "nothing under the limit")
	local fits = grid.startSearch(open, { x = 0, y = 1000 }, { x = 2000, y = 1000 }, EAST, EAST,
		with({ minRadius = 3000 }), nil, 2100)
	while not grid.stepSearch(fits, 1000) do end
	t.near(fits.cost[0], 2000, 1e-6, "found under a higher one")
end)

t.test("grid: with a wide radius, the finish can come part-way along a turn's straight", function()
	-- Heading east to a goal two cells to the side and forty along, arriving heading east-north-east (2, 1). With
	-- R = 2000 (L ≈ 796 m) a turn onto (2, 1) runs on for 4 knight steps, and one turn there puts the goal on its
	-- second step: the search stops there rather than wind its way to the goal with three turns.
	local g = grid.new(0, 0, 100, 61, 21)
	local from, to = { x = 500, y = 500 }, { x = 4500, y = 700 }
	local s = grid.startSearch(g, from, to, EAST, { x = 2, y = 1 }, with({ minRadius = 2000 }))
	while not grid.stepSearch(s, 1000) do end
	local path = grid.path(s)
	t.ok(path ~= nil, "found")
	t.eq(s.finishSteps, 2, "finished part-way, after 2 steps")
	t.eq(s.finishDir, 2, "heading (2, 1)")
	t.eq(path[#path].x, 4500, "ends at the goal")
	t.eq(path[#path].y, 700, "ends at the goal")
	t.eq(dirOf(path[#path - 1], path[#path]), 2, "arrives heading (2, 1)")
	t.eq(dirOf(path[#path - 2], path[#path - 1]), 2, "after one knight step")
	t.eq(dirOf(path[#path - 3], path[#path - 2]), 1, "from the east-bound straight")
end)

t.test("grid: the path's off-centre ends don't cut a blocked cell's corner", function()
	-- From (40, 20), off its cell's centre, north-east to (760, 780): the diagonal to the cell centre (100, 100) would
	-- clip the blocked cell round (100, 0); so would the last segment, from (700, 700) into the goal, the blocked cell
	-- round (700, 800).
	local g = grid.new(0, 0, 100, 10, 10)
	g.blocked[grid.index(g, 2, 1)] = true
	g.blocked[grid.index(g, 8, 9)] = true
	local ne = { x = 1, y = 1 }
	local from, to = { x = 40, y = 20 }, { x = 760, y = 780 }
	local path = run(g, from, to, W, 1000, ne, ne)
	t.ok(path ~= nil, "found")
	for i = 2, #path do
		t.ok(grid.cellsAlong(g, path[i - 1], path[i], function(c)
			return not g.blocked[c]
		end), ("segment %d clear: (%.0f, %.0f) to (%.0f, %.0f)"):format(i - 1, path[i - 1].x, path[i - 1].y,
			path[i].x, path[i].y))
	end
end)

t.test("grid: a knight move doesn't hop over a ridge one cell wide", function()
	-- A wall of 100 m high cells across the middle row, open at the far west end: the search must go round, not
	-- step over it from one side to the other between cell centres.
	local g = grid.new(0, 0, 100, 21, 11)
	for ix = 4, 21 do
		g.height[grid.index(g, ix, 6)] = 100
	end
	local path = run(g, { x = 1500, y = 0 }, { x = 1500, y = 1000 }, with({ minRadius = 220 }))
	t.ok(path ~= nil, "found")
	for __, p in ipairs(path) do
		local ix = math.floor(p.x / 100 + 0.5) + 1
		local iy = math.floor(p.y / 100 + 0.5) + 1
		t.ok(not (iy == 6 and ix >= 4), ("never on the wall (%d, %d)"):format(ix, iy))
	end
	t.ok(path[1].x > 0 and math.min(table.unpack((function() local xs = {} for __, p in ipairs(path) do xs[#xs + 1] = p.x end return xs end)())) <= 300, "went round the west end")
end)

t.test("grid: the ends may move out along the stations' axes, short of anything in the way", function()
	-- An open field, both stations' axes 12° north of east (between the 16 headings), R = 2000 m, runs of 1000 m.
	local g = grid.new(0, 0, 100, 81, 31)
	local dir = { x = math.cos(math.rad(12)), y = math.sin(math.rad(12)) }
	local from, to = { x = 500, y = 500 }, { x = 7000, y = 2000 }
	-- A building on the start's axis 450 m out: the start may not move past it.
	g.blocked[grid.index(g, grid.cellOf(g, { x = from.x + 450 * dir.x, y = from.y + 450 * dir.y }))] = true
	local s = grid.startSearch(g, from, to, dir, dir, with({ minRadius = 2000 }), nil, nil, 1000, 1000)
	while not grid.stepSearch(s, 1000) do end
	local path = grid.path(s)
	t.ok(path ~= nil, "found")
	local function onAxis(p, o, sign, label)
		local dx, dy = p.x - o.x, p.y - o.y
		local along = sign * (dx * dir.x + dy * dir.y)
		t.near(dx * dir.y - dy * dir.x, 0, 1e-6, label .. " on the axis")
		t.ok(along >= -1e-6 and along <= 1000 + 1e-6, label .. " within the run: " .. along)
		return along
	end
	t.ok(onAxis(path[1], from, 1, "start") < 350, "the start stops short of the building")
	onAxis(path[#path], to, -1, "goal")
	for i = 2, #path do
		t.ok(grid.cellsAlong(g, path[i - 1], path[i], function(c)
			return not g.blocked[c]
		end), "segment " .. (i - 1) .. " clear")
	end
	-- Without runs, the path starts and ends at the asked points.
	local fixed = grid.startSearch(g, from, to, dir, dir, with({ minRadius = 2000 }))
	while not grid.stepSearch(fixed, 1000) do end
	local p = grid.path(fixed)
	t.ok(p == nil or (p[1] == from and p[#p] == to), "fixed ends")
	t.ok(p == nil or fixed.cost[0] >= s.cost[0] - 1e-6, "runs never cost more")
end)

t.test("grid: a grid's searches share its store, one at a time, and find what they would alone", function()
	-- A wall with a gap, searched one way and back on one grid, then each on a grid of its own.
	local function walled()
		local g = grid.new(0, 0, 100, 31, 21)
		for iy = 1, 21 do
			if iy ~= 5 then
				g.blocked[grid.index(g, 16, iy)] = true
			end
		end
		return g
	end
	local WEST = { x = -1, y = 0 }
	local shared = walled()
	local there, sThere = run(shared, { x = 200, y = 1500 }, { x = 2800, y = 1500 }, W)
	local back, sBack = run(shared, { x = 2800, y = 500 }, { x = 200, y = 1800 }, W, 7, WEST, WEST)
	local alone, sAlone = run(walled(), { x = 2800, y = 500 }, { x = 200, y = 1800 }, W, 7, WEST, WEST)
	t.ok(there ~= nil and back ~= nil, "both found")
	t.near(sBack.cost[0], sAlone.cost[0], 1e-9, "the second search's cost as alone")
	t.eq(#back, #alone, "and its path")
	for i = 1, #back do
		t.ok(back[i].x == alone[i].x and back[i].y == alone[i].y, "point " .. i)
	end
	t.ok(grid.path(grid.finished(sBack)) ~= nil, "a finished copy keeps its path")
	-- The first search's store is the second's now: it can't be stepped on or its path taken.
	t.ok(not pcall(grid.path, sThere), "an older search's path is refused")
	local older = grid.startSearch(shared, { x = 200, y = 1500 }, { x = 2800, y = 1500 }, EAST, EAST, W)
	grid.startSearch(shared, { x = 200, y = 300 }, { x = 2800, y = 300 }, EAST, EAST, W)
	t.ok(not pcall(grid.stepSearch, older, 10), "an older search can't go on")
end)
