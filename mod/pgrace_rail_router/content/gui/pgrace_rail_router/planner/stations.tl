local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo
local grid = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/grid.tl" as PgraceRailRouterGrid

local stations : PgraceRailRouterStations = {}

local type Pt = PgraceRailRouterGeo.Pt
local type Grid = PgraceRailRouterGrid.Grid
local type Site = PgraceRailRouterStations.Site

-- Directions tried at each spot: the wanted one first, then up to 30° either way.
local TURNS : {number} = { 0, math.rad(15), -math.rad(15), math.rad(30), -math.rad(30) }

-- Distances along the run to sample its heights at, from end to end: every quarter cell, and always both ends
-- exactly.
local function offsets(g : Grid, runLength : number) : {number}
	local half = runLength / 2
	local step = g.cell / 4
	local ds : {number} = {}
	local d = -half
	while d < half - 1e-6 do
		table.insert(ds, d)
		d = d + step
	end
	table.insert(ds, half)
	return ds
end

-- Whether the run is inside, and every cell it passes through dry and clear (no building, road or track), and then
-- (the dearer test, done only for runs that pass) flat.
local function clear(g : Grid, centre : Pt, dir : Pt, runLength : number, maxRelief : number,
		taken : {integer : boolean}) : boolean
	local half = runLength / 2
	local a : Pt = { x = centre.x - dir.x * half, y = centre.y - dir.y * half }
	local b : Pt = { x = centre.x + dir.x * half, y = centre.y + dir.y * half }
	-- The grid is a rectangle, so a run with both ends inside is inside.
	if not grid.inside(g, a) or not grid.inside(g, b) then
		return false
	end
	local free = grid.cellsAlong(g, a, b, function(i : integer) : boolean
		return not (g.blocked[i] or g.water[i] or g.road[i] or g.track[i] or (taken ~= nil and taken[i]))
	end)
	if not free then
		return false
	end
	local ds = offsets(g, runLength)
	local lo, hi = math.huge, -math.huge
	for __, d in ipairs(ds) do
		local h = grid.heightAt(g, { x = centre.x + dir.x * d, y = centre.y + dir.y * d })
		if h < lo then
			lo = h
		end
		if h > hi then
			hi = h
		end
		if hi - lo > maxRelief then
			return false
		end
	end
	return true
end

function stations.find(g : Grid, town : Pt, dir : Pt, runLength : number, maxRelief : number, maxRadius : number,
		taken ?: {integer : boolean}) : Site
	local unit = geo.norm(dir)
	local step = g.cell / 2
	local r = 0.0
	while r <= maxRadius do
		local n : integer = 1
		if r > 0 then
			n = math.floor(math.max(8, 2 * math.pi * r / step))
		end
		for i = 0, n - 1 do
			-- Each ring starts on the line ahead, so of equally near spots the one along the line wins.
			local offset = geo.rotate(unit, 2 * math.pi * i / n)
			local centre : Pt = { x = town.x + r * offset.x, y = town.y + r * offset.y }
			for __, turn in ipairs(TURNS) do
				local d = geo.rotate(unit, turn)
				if clear(g, centre, d, runLength, maxRelief, taken) then
					return { centre = centre, dir = d, distance = r }
				end
			end
		end
		r = r + step
	end
	return nil
end

return stations
