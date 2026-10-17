local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo
local grid = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/grid.tl" as PgraceRailRouterGrid

local stations : PgraceRailRouterStations = {}

local type Pt = PgraceRailRouterGeo.Pt
local type Grid = PgraceRailRouterGrid.Grid
local type Site = PgraceRailRouterStations.Site
local type Finder = PgraceRailRouterStations.Finder

-- Directions tried at each spot: the wanted one first, then up to 30° either way.
local TURNS : {number} = { 0, math.rad(15), -math.rad(15), math.rad(30), -math.rad(30) }

-- Work, for spreading a search over steps (stepFind): looking at a spot, or at a run's ends, counts 1; walking a
-- run's cells, or sampling its heights, this much more. Each unit took about 1 µs on desktop Lua: a spot whose
-- centre is on a building 0.7 µs, steep ground where all 5 runs are walked and sampled about 28 µs (26 units).
local RUN_WORK = 4

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

-- Whether the cell at p is dry and clear (no building, road, track or taken platform).
local function cellFree(f : Finder, p : Pt) : boolean
	local ix, iy = grid.cellOf(f.g, p)
	return f.free(grid.index(f.g, ix, iy))
end

-- Whether the run is inside, and every cell it passes through dry and clear, and then (the dearer test, done only for
-- runs that pass) flat. Its two end cells are looked at first: in a built-up town most runs end on a building, and
-- that is found without walking the run.
local function clear(f : Finder, centre : Pt, dir : Pt) : boolean
	local g = f.g
	f.work = f.work + 1
	local half = f.runLength / 2
	local a : Pt = { x = centre.x - dir.x * half, y = centre.y - dir.y * half }
	local b : Pt = { x = centre.x + dir.x * half, y = centre.y + dir.y * half }
	-- The grid is a rectangle, so a run with both ends inside is inside.
	if not grid.inside(g, a) or not grid.inside(g, b) then
		return false
	end
	if not cellFree(f, a) or not cellFree(f, b) then
		return false
	end
	f.work = f.work + RUN_WORK
	if not grid.cellsAlong(g, a, b, f.free) then
		return false
	end
	f.work = f.work + RUN_WORK
	local runLength, maxRelief = f.runLength, f.maxRelief
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

-- Spots on the ring of radius r: one at the centre, else one every half cell round it (at least 8).
local function ringSpots(g : Grid, r : number) : integer
	if r > 0 then
		return math.floor(math.max(8, 2 * math.pi * r / (g.cell / 2)))
	end
	return 1
end

function stations.startFind(g : Grid, town : Pt, dir : Pt, runLength : number, maxRelief : number,
		maxRadius : number, taken ?: {integer : boolean}) : Finder
	local unit = geo.norm(dir)
	local dirs : {Pt} = {}
	for __, turn in ipairs(TURNS) do
		table.insert(dirs, geo.rotate(unit, turn))
	end
	return { g = g, town = town, unit = unit, dirs = dirs, runLength = runLength, maxRelief = maxRelief,
		maxRadius = maxRadius, r = 0, n = ringSpots(g, 0), i = 0, done = false, work = 0,
		free = function(i : integer) : boolean
			return not (g.blocked[i] or g.water[i] or g.road[i] or g.track[i] or (taken ~= nil and taken[i]))
		end }
end

function stations.stepFind(f : Finder, maxWork : integer) : boolean
	f.work = 0
	while not f.done and f.work < maxWork do
		if f.i >= f.n then
			f.r = f.r + f.g.cell / 2
			f.n, f.i = ringSpots(f.g, f.r), 0
		end
		if f.r > f.maxRadius then
			f.done = true
			break
		end
		-- Each ring starts on the line ahead, so of equally near spots the one along the line wins.
		local offset = geo.rotate(f.unit, 2 * math.pi * f.i / f.n)
		local centre : Pt = { x = f.town.x + f.r * offset.x, y = f.town.y + f.r * offset.y }
		f.i = f.i + 1
		f.work = f.work + 1
		-- Every run passes through its centre: a spot on a building is passed over without trying any direction.
		if grid.inside(f.g, centre) and cellFree(f, centre) then
			for __, d in ipairs(f.dirs) do
				if clear(f, centre, d) then
					f.site, f.done = { centre = centre, dir = d, distance = f.r }, true
					break
				end
			end
		end
	end
	return f.done
end

function stations.find(g : Grid, town : Pt, dir : Pt, runLength : number, maxRelief : number, maxRadius : number,
		taken ?: {integer : boolean}) : Site
	local f = stations.startFind(g, town, dir, runLength, maxRelief, maxRadius, taken)
	while not stations.stepFind(f, 1000000) do
	end
	return f.site
end

return stations
