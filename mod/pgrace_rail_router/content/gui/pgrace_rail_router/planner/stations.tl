local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo
local grid = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/grid.tl" as PgraceRailRouterGrid

local stations : PgraceRailRouterStations = {}

local type Pt = PgraceRailRouterGeo.Pt
local type Grid = PgraceRailRouterGrid.Grid
local type Site = PgraceRailRouterStations.Site
local type Finder = PgraceRailRouterStations.Finder
local type Exit = PgraceRailRouterStations.Exit
local type Flood = PgraceRailRouterStations.Flood

-- Directions tried at each spot: the wanted one first, then up to 30° either way.
local TURNS : {number} = { 0, math.rad(15), -math.rad(15), math.rad(30), -math.rad(30) }

-- Work, for spreading a search over steps (stepFind): looking at a spot, or at a run's ends, counts 1; walking a
-- run's cells, or sampling its heights, this much more. Each unit took about 1 µs on desktop Lua: a spot whose
-- centre is on a building 0.7 µs, steep ground where all 5 runs are walked and sampled about 28 µs (26 units).
local RUN_WORK = 4
-- Work per cell the exit flood takes (16 neighbours looked at, a heap push or two): about 2 µs on desktop Lua.
local FLOOD_WORK = 2

-- The grid search's 16 moves: the flood that checks a site's way out must allow the same moves, or it would pass
-- sites the search can't leave (or refuse ones it can).
local DIRS = grid.DIRS

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

-- The flood's heap: cells by their distance from the town's centre, farthest first, so in open country it heads
-- straight out and a way out is found in a few cells; a pocket is filled whole either way.
local function floodPush(fl : Flood, cell : integer, key : number)
	local heap, keys = fl.heap, fl.keys
	local n = #heap + 1
	heap[n], keys[n] = cell, key
	while n > 1 do
		local parent = n // 2
		if keys[parent] >= keys[n] then
			break
		end
		heap[parent], heap[n] = heap[n], heap[parent]
		keys[parent], keys[n] = keys[n], keys[parent]
		n = parent
	end
end

local function floodPop(fl : Flood) : integer
	local heap, keys = fl.heap, fl.keys
	local top = heap[1]
	local n = #heap
	heap[1], keys[1] = heap[n], keys[n]
	heap[n], keys[n] = nil, nil
	n = n - 1
	local i = 1
	while true do
		local l, r = 2 * i, 2 * i + 1
		local best = i
		if l <= n and keys[l] > keys[best] then
			best = l
		end
		if r <= n and keys[r] > keys[best] then
			best = r
		end
		if best == i then
			break
		end
		heap[best], heap[i] = heap[i], heap[best]
		keys[best], keys[i] = keys[i], keys[best]
		i = best
	end
	return top
end

local function townDistance(f : Finder, cell : integer) : number
	local g = f.g
	local x = g.x0 + ((cell - 1) % g.nx) * g.cell
	local y = g.y0 + ((cell - 1) // g.nx) * g.cell
	return math.sqrt((x - f.town.x) ^ 2 + (y - f.town.y) ^ 2)
end

-- Starts the flood for a check (see Check).
local function startFlood(f : Finder, check : PgraceRailRouterStations.Check)
	local cell = check.cell
	local fl : Flood = { heap = {}, keys = {}, seen = { [cell] = true }, cells = { cell }, excluded = check.excluded }
	if check.pt == nil then
		floodPush(fl, cell, townDistance(f, cell))
	else
		-- From an end, the leg leaves (or arrives) as its search would: from the end point itself, heading out of the
		-- station within 90°.
		for __, b in ipairs(grid.leaveCells(f.g, check.pt, check.out, check.excluded)) do
			if not fl.seen[b] then
				fl.seen[b] = true
				table.insert(fl.cells, b)
				floodPush(fl, b, townDistance(f, b))
			end
		end
	end
	f.flood = fl
end

-- Floods on from the cells queued until there's a way out (a cell farther than exit.radius from the town's centre,
-- or on the grid's edge), the pocket is filled with none, or the step's work is done. true and whether there's a way
-- out once it has ended. A flood with nothing excluded is the plain question "does this cell connect?": its answer
-- holds for every cell it reached, so it's remembered (exit.known), and a cell known to connect ends it at once. With
-- cells excluded, only "boxed in" carries over (a cell walled in with nothing excluded is walled in with more).
local function stepFlood(f : Finder, maxWork : integer) : boolean, boolean
	local g, fl, exit = f.g, f.flood, f.exit
	local nx, ny, blocked, known, excluded = g.nx, g.ny, g.blocked, exit.known, fl.excluded
	local function finish(out : boolean) : boolean, boolean
		if excluded == nil then
			for __, c in ipairs(fl.cells) do
				known[c] = out
			end
		end
		f.flood = nil
		return true, out
	end
	while #fl.heap > 0 do
		if f.work >= maxWork then
			return false, false
		end
		f.work = f.work + FLOOD_WORK
		local a = floodPop(fl)
		local ax = (a - 1) % nx + 1
		local ay = (a - 1) // nx + 1
		-- The grid's edge counts as a way out: what lies beyond is unknown, and a wider area may go on from there.
		if (excluded == nil and known[a] == true) or townDistance(f, a) > exit.radius or ax == 1 or ax == nx
				or ay == 1 or ay == ny then
			return finish(true)
		end
		for k = 1, #DIRS do
			local d = DIRS[k]
			local dx, dy = d[1], d[2]
			local bx, by = ax + dx, ay + dy
			if bx >= 1 and bx <= nx and by >= 1 and by <= ny then
				local b = (by - 1) * nx + bx
				if not fl.seen[b] and not blocked[b] and known[b] ~= false and not (excluded ~= nil and excluded[b]) then
					local open = true
					-- A knight move passes between two cells: both must be passable (as grid's flood fill).
					if dx * dx + dy * dy == 5 then
						open = not blocked[(ay + math.floor(dy / 2) - 1) * nx + ax + math.floor(dx / 2)]
							and not blocked[(ay + math.ceil(dy / 2) - 1) * nx + ax + math.ceil(dx / 2)]
					end
					if open then
						fl.seen[b] = true
						table.insert(fl.cells, b)
						floodPush(fl, b, townDistance(f, b))
					end
				end
			end
		end
	end
	return finish(false)
end

function stations.startFind(g : Grid, town : Pt, dir : Pt, runLength : number, maxRelief : number,
		maxRadius : number, taken ?: {integer : boolean}, exit ?: Exit) : Finder
	local unit = geo.norm(dir)
	local dirs : {Pt} = {}
	for __, turn in ipairs(TURNS) do
		table.insert(dirs, geo.rotate(unit, turn))
	end
	local finder : Finder = { g = g, town = town, unit = unit, dirs = dirs, runLength = runLength, maxRelief = maxRelief,
		maxRadius = maxRadius, r = 0, n = ringSpots(g, 0), i = 0, done = false, work = 0, pocketed = 0,
		free = function(i : integer) : boolean
			return not (g.blocked[i] or g.water[i] or g.road[i] or g.track[i] or (taken ~= nil and taken[i]))
		end }
	if exit ~= nil then
		if exit.known == nil then
			exit.known = {}
		end
		finder.exit = exit
	end
	return finder
end

-- The way-out checks for a clear site (see Exit): its centre cell connects at all (remembered per town), then each
-- end a leg uses connects without going back through the station's own cells. nil if one is already known to fail.
local function checksFor(f : Finder, site : Site) : {PgraceRailRouterStations.Check}
	local g, exit = f.g, f.exit
	local checks : {PgraceRailRouterStations.Check} = {}
	local centre = grid.index(g, grid.cellOf(g, site.centre))
	local known = exit.known[centre]
	if known == false then
		return nil
	elseif known == nil then
		table.insert(checks, { cell = centre })
	end
	local half = f.runLength / 2
	local a : Pt = { x = site.centre.x - site.dir.x * half, y = site.centre.y - site.dir.y * half }
	local b : Pt = { x = site.centre.x + site.dir.x * half, y = site.centre.y + site.dir.y * half }
	local run : {integer : boolean} = {}
	grid.cellsAlong(g, a, b, function(i : integer) : boolean
		run[i] = true
		return true
	end)
	-- From an end, the leg's search (turning freely at its fallback radius) may go any way but back along the run.
	local back : Pt = { x = -site.dir.x, y = -site.dir.y }
	for __, e in ipairs({ { exit.backward, a, back }, { exit.forward, b, site.dir } }) do
		if e[1] as boolean ~= false then
			local p = e[2] as Pt
			local cell = grid.index(g, grid.cellOf(g, p))
			local excluded : {integer : boolean} = {}
			for i in pairs(run) do
				if i ~= cell then
					excluded[i] = true
				end
			end
			excluded[cell] = true
			table.insert(checks, { cell = cell, excluded = excluded, pt = p, out = e[3] as Pt })
		end
	end
	return checks
end

-- Takes the next way-out check of the site being weighed, or the site itself once they have all passed.
local function nextCheck(f : Finder)
	f.checkIndex = f.checkIndex + 1
	local check = f.checks[f.checkIndex]
	if check == nil then
		f.site, f.done = f.candidate, true
		f.checks, f.candidate = nil, nil
		return
	end
	startFlood(f, check)
end

function stations.stepFind(f : Finder, maxWork : integer) : boolean
	f.work = 0
	while not f.done and f.work < maxWork do
		if f.flood ~= nil then
			local ended, out = stepFlood(f, maxWork)
			if not ended then
				break
			end
			if out then
				nextCheck(f)
			else
				-- Boxed in: this site is no use. Where it was the centre that's walled in, so is every run at the
				-- spot; otherwise another direction may leave by another way.
				f.pocketed = f.pocketed + 1
				if f.checks[f.checkIndex].excluded == nil then
					f.spot = nil
				end
				f.checks, f.candidate = nil, nil
			end
		elseif f.spot ~= nil then
			-- Try the spot's runs in turn, from the next one not yet tried.
			local centre = f.spot
			local d = f.dirs[f.di]
			f.di = f.di + 1
			if f.di > #f.dirs then
				f.spot = nil
			end
			if clear(f, centre, d) then
				local site : Site = { centre = centre, dir = d, distance = f.r }
				if f.exit == nil then
					f.site, f.done = site, true
				else
					-- A clear run is no use if the line can't get out to it: in a town, buildings and their buffers
					-- can wall in an open spot, or one end of it (Pottstown's sites on the third save).
					local checks = checksFor(f, site)
					if checks == nil then
						f.pocketed = f.pocketed + 1
						f.spot = nil
					else
						f.checks, f.checkIndex, f.candidate = checks, 0, site
						nextCheck(f)
					end
				end
			end
		else
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
				f.spot, f.di = centre, 1
			end
		end
	end
	return f.done
end

function stations.find(g : Grid, town : Pt, dir : Pt, runLength : number, maxRelief : number, maxRadius : number,
		taken ?: {integer : boolean}, exit ?: Exit) : Site
	local f = stations.startFind(g, town, dir, runLength, maxRelief, maxRadius, taken, exit)
	while not stations.stepFind(f, 1000000) do
	end
	return f.site
end

return stations
