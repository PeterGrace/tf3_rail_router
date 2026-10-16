local t = ...
local grid = t.requireTl("gui/pgrace_rail_router/planner/grid.tl")
local stations = t.requireTl("gui/pgrace_rail_router/planner/stations.tl")

-- 41 × 41 cells of 100 m centred on the origin.
local function openGrid()
	return grid.new(-2000, -2000, 100, 41, 41)
end

local function runIsClear(g, site, runLength)
	for d = -runLength / 2, runLength / 2, 25 do
		local p = { x = site.centre.x + site.dir.x * d, y = site.centre.y + site.dir.y * d }
		local ix, iy = grid.cellOf(g, p)
		if g.blocked[grid.index(g, ix, iy)] then
			return false
		end
	end
	return true
end

t.test("stations: an empty town centre takes the station", function()
	local site = stations.find(openGrid(), { x = 0, y = 0 }, { x = 1, y = 0 }, 360, 10, 1500)
	t.ok(site ~= nil, "found")
	t.near(site.distance, 0, 1e-9, "at the centre")
	t.near(site.dir.x, 1, 1e-9, "facing the line")
end)

t.test("stations: a built-up centre pushes the station out", function()
	local g = openGrid()
	for iy = 1, 41 do
		for ix = 1, 41 do
			local c = grid.centre(g, ix, iy)
			if math.sqrt(c.x * c.x + c.y * c.y) <= 400 then
				g.blocked[grid.index(g, ix, iy)] = true
			end
		end
	end
	local site = stations.find(g, { x = 0, y = 0 }, { x = 1, y = 0 }, 360, 10, 1500)
	t.ok(site ~= nil, "found")
	t.ok(site.distance > 300, "outside the built-up area: " .. site.distance)
	t.ok(runIsClear(g, site, 360), "run is clear")
end)

t.test("stations: nothing found when everything is built up", function()
	local g = openGrid()
	for i = 1, 41 * 41 do
		g.blocked[i] = true
	end
	t.eq(stations.find(g, { x = 0, y = 0 }, { x = 1, y = 0 }, 360, 10, 1500), nil, "none")
end)

t.test("stations: steep ground is skipped for flat ground", function()
	local g = openGrid()
	-- West of x = 1000 the ground climbs 50 m per cell northwards; east of it, flat.
	for iy = 1, 41 do
		for ix = 1, 30 do
			g.height[grid.index(g, ix, iy)] = 50 * iy
		end
	end
	local site = stations.find(g, { x = 0, y = 0 }, { x = 0, y = 1 }, 360, 10, 1500)
	t.ok(site ~= nil, "found")
	t.ok(site.centre.x >= 1000, "on the flat: x " .. site.centre.x)
end)
