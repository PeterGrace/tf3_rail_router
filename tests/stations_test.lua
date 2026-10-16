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
	-- Heights blend over the last steep cell, so the run may sit a few metres short of x = 1000.
	t.ok(site.centre.x > 950, "on the flat: x " .. site.centre.x)
	local lo, hi = math.huge, -math.huge
	for d = -180, 180, 10 do
		local h = grid.heightAt(g, { x = site.centre.x + site.dir.x * d, y = site.centre.y + site.dir.y * d })
		lo, hi = math.min(lo, h), math.max(hi, h)
	end
	t.ok(hi - lo <= 10 + 1e-6, "relief " .. (hi - lo))
end)

local function fill(g, field, inDisc)
	for iy = 1, g.ny do
		for ix = 1, g.nx do
			if inDisc(grid.centre(g, ix, iy)) then
				g[field][grid.index(g, ix, iy)] = true
			end
		end
	end
end

t.test("stations: water rejects a site", function()
	local g = openGrid()
	fill(g, "water", function(c) return math.sqrt(c.x * c.x + c.y * c.y) <= 400 end)
	local site = stations.find(g, { x = 0, y = 0 }, { x = 1, y = 0 }, 360, 10, 1500)
	t.ok(site ~= nil, "found")
	t.ok(site.distance > 300, "off the water: " .. site.distance)
	for d = -180, 180, 25 do
		local p = { x = site.centre.x + site.dir.x * d, y = site.centre.y + site.dir.y * d }
		t.ok(not grid.waterAt(g, p), "dry at " .. d)
	end
end)

t.test("stations: a turned run is used when straight is blocked", function()
	local g = openGrid()
	-- The cells at x = ±200 on the line block the straight run and the 15° ones; a 30° run passes them.
	g.blocked[grid.index(g, 19, 21)] = true
	g.blocked[grid.index(g, 23, 21)] = true
	local site = stations.find(g, { x = 0, y = 0 }, { x = 1, y = 0 }, 360, 10, 1500)
	t.ok(site ~= nil, "found")
	t.near(site.distance, 0, 1e-9, "at the centre")
	t.ok(math.abs(site.dir.y) > 0.1, "turned: dir " .. site.dir.x .. ", " .. site.dir.y)
	t.ok(runIsClear(g, site, 360), "run is clear")
end)

t.test("stations: nothing beyond maxRadius", function()
	local g = openGrid()
	fill(g, "blocked", function(c) return math.sqrt((c.x - 1200) * (c.x - 1200) + c.y * c.y) > 350 end)
	t.eq(stations.find(g, { x = 0, y = 0 }, { x = 1, y = 0 }, 360, 10, 800), nil, "none within 800 m")
	local site = stations.find(g, { x = 0, y = 0 }, { x = 1, y = 0 }, 360, 10, 1500)
	t.ok(site ~= nil and site.distance > 800, "found further out")
end)

-- Every 5 m, ends included: whether any cell under the run is blocked, water, road or track.
local function runIsFree(g, site, runLength)
	local half = runLength / 2
	local d = -half
	while true do
		local p = { x = site.centre.x + site.dir.x * d, y = site.centre.y + site.dir.y * d }
		local i = grid.index(g, grid.cellOf(g, p))
		if g.blocked[i] or g.water[i] or g.road[i] or g.track[i] then
			return false, d
		end
		if d >= half then
			return true
		end
		d = math.min(half, d + 5)
	end
end

t.test("stations: a road crossing the town centre pushes the site off it", function()
	local g = openGrid()
	fill(g, "road", function(c) return math.abs(c.x) < 50 end)
	local site = stations.find(g, { x = 0, y = 0 }, { x = 1, y = 0 }, 360, 10, 1500)
	t.ok(site ~= nil, "found")
	t.ok(site.distance > 0, "moved: " .. site.distance)
	local free, at = runIsFree(g, site, 360)
	t.ok(free, "off the road (hit at " .. tostring(at) .. ")")
end)

t.test("stations: existing track pushes the site off it", function()
	local g = openGrid()
	fill(g, "track", function(c) return math.abs(c.x) < 50 end)
	local site = stations.find(g, { x = 0, y = 0 }, { x = 1, y = 0 }, 360, 10, 1500)
	t.ok(site ~= nil, "found")
	local free, at = runIsFree(g, site, 360)
	t.ok(free, "off the track (hit at " .. tostring(at) .. ")")
end)

t.test("stations: the run's very ends are checked", function()
	local g = openGrid()
	-- The cell at x = 150..250 on the line: a 340 m run from the centre ends at x = 170, inside it.
	g.blocked[grid.index(g, 23, 21)] = true
	local site = stations.find(g, { x = 0, y = 0 }, { x = 1, y = 0 }, 340, 10, 1500)
	t.ok(site ~= nil, "found")
	local free, at = runIsFree(g, site, 340)
	t.ok(free, "run is clear to its ends (hit at " .. tostring(at) .. ")")
end)
