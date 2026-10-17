local t = ...
local area = t.requireTl("gui/pgrace_rail_router/planner/area.tl")
local grid = t.requireTl("gui/pgrace_rail_router/planner/grid.tl")

-- survey.start's box computation before it moved into area.box, kept as the reference.
local function oldBox(stops, cell, margin)
	if #stops == 0 then
		return nil
	end
	local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
	for _, stop in ipairs(stops) do
		minX, maxX = math.min(minX, stop.pos.x), math.max(maxX, stop.pos.x)
		minY, maxY = math.min(minY, stop.pos.y), math.max(maxY, stop.pos.y)
	end
	local pad = math.max(2000.0, margin * math.max(maxX - minX, maxY - minY))
	minX, maxX, minY, maxY = minX - pad, maxX + pad, minY - pad, maxY + pad
	local nx = math.floor((maxX - minX) / cell) + 1
	local ny = math.floor((maxY - minY) / cell) + 1
	while nx * ny > 250000 and cell < 5000.0 do
		cell = cell * 1.25
		nx = math.floor((maxX - minX) / cell) + 1
		ny = math.floor((maxY - minY) / cell) + 1
	end
	return { minX = minX, minY = minY, maxX = maxX, maxY = maxY, cell = cell, nx = nx, ny = ny }
end

local function town(x, y)
	return { id = 1, name = "t", pos = { x = x, y = y } }
end

t.test("area.box: same boxes as survey.start computed before the move", function()
	local cases = {
		{ { town(0, 0) }, 100, 0.25 },
		{ { town(-6492, -6888), town(2292, -3012) }, 100, 0.25 },
		{ { town(-6492, -6888), town(2292, -3012), town(-548, -3744) }, 100, 0.5 },
		{ { town(-30000, -30000), town(30000, 25000) }, 100, 1.0 },
		{ { town(10, 20), town(15, 22) }, 100, 0.25 },
	}
	local seed = 7
	local function rnd()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
	for _ = 1, 30 do
		local stops = {}
		for _ = 1, 1 + math.floor(rnd() * 5) do
			table.insert(stops, town((rnd() - 0.5) * 60000, (rnd() - 0.5) * 60000))
		end
		table.insert(cases, { stops, 100, ({ 0.25, 0.5, 1.0 })[1 + math.floor(rnd() * 3)] })
	end
	for i, case in ipairs(cases) do
		local a, b = area.box(case[1], case[2], case[3]), oldBox(case[1], case[2], case[3])
		for _, k in ipairs({ "minX", "minY", "maxX", "maxY", "cell", "nx", "ny" }) do
			t.eq(a[k], b[k], "case " .. i .. " " .. k)
		end
	end
end)

t.test("area.box: nil without stops or with a non-finite position", function()
	t.eq(area.box({}, 100, 0.25), nil, "no stops")
	t.eq(area.box({ town(0 / 0, 0) }, 100, 0.25), nil, "NaN")
	t.eq(area.box({ town(math.huge, 0) }, 100, 0.25), nil, "inf")
end)

t.test("area.box: a large area gets coarser cells", function()
	local b = area.box({ town(-40000, -40000), town(40000, 40000) }, 100, 0.25)
	t.ok(b.cell > 100, "coarser")
	t.ok(b.nx * b.ny <= 250000, "within MAX_CELLS")
end)

t.test("area.markBox marks the cells nearest the corners and between", function()
	local g = grid.new(0, 0, 100, 10, 10)
	area.markBox(g, 120, 120, 260, 180, g.blocked)
	-- Corners' nearest cells: (120,120) -> (2,2); (260,180) -> (4,3).
	for iy = 1, 10 do
		for ix = 1, 10 do
			local want = ix >= 2 and ix <= 4 and iy >= 2 and iy <= 3
			t.eq(g.blocked[grid.index(g, ix, iy)], want, ix .. "," .. iy)
		end
	end
	local h = grid.new(0, 0, 100, 3, 3)
	area.markBox(h, 1000, 1000, 1100, 1100, h.blocked)
	for i = 1, 9 do
		t.eq(h.blocked[i], false, "outside box skipped")
	end
end)

t.test("area.markCurve with zero tangents follows the chord like markLine", function()
	local g1 = grid.new(0, 0, 100, 20, 20)
	local g2 = grid.new(0, 0, 100, 20, 20)
	area.markLine(g1, { x = 0, y = 0 }, { x = 1500, y = 700 }, g1.road)
	area.markCurve(g2, { x = 0, y = 0 }, { x = 1500, y = 700 }, { x = 1500, y = 700 }, { x = 1500, y = 700 }, g2.road)
	local n = 0
	for i = 1, 400 do
		if g1.road[i] then n = n + 1 end
		t.eq(g2.road[i], g1.road[i], "cell " .. i)
	end
	t.ok(n >= 15, "marked a line of cells")
end)
