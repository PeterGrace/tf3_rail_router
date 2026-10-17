local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo
local grid = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/grid.tl" as PgraceRailRouterGrid
local stations = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/stations.tl" as PgraceRailRouterStations
local smooth = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/smooth.tl" as PgraceRailRouterSmooth
local profile = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/profile.tl" as PgraceRailRouterProfile
local speed = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/speed.tl" as PgraceRailRouterSpeed

local route : PgraceRailRouterRoute = {}

local type Pt = PgraceRailRouterGeo.Pt
local type Grid = PgraceRailRouterGrid.Grid
local type Town = PgraceRailRouterCorridor.Town
local type Input = PgraceRailRouterRoute.Input
local type Station = PgraceRailRouterRoute.Station
local type Leg = PgraceRailRouterRoute.Leg
local type Summary = PgraceRailRouterRoute.Summary
local type Plan = PgraceRailRouterRoute.Plan
local type Job = PgraceRailRouterRoute.Job
local type LegHeights = PgraceRailRouterRoute.LegHeights

-- Straight track before and after each platform, so trains run in line with it (metres).
local APPROACH = 100.0
-- Most height change a station's run may have (metres).
local MAX_STATION_RELIEF = 10.0
-- How far from a town's centre to look for room for its station (metres).
local MAX_STATION_RADIUS = 1500.0
-- A station site must connect to open country (stations.Exit): over unblocked cells to somewhere this far from its
-- town's centre, farther than any site may be by a kilometre, so a pocket reaching just past the sites' radius
-- doesn't count as a way out. In a big town the first check floods up to about 2,000 cells (spread over steps, and
-- remembered for the town's later sites).
local EXIT_RADIUS = MAX_STATION_RADIUS + 1000.0
-- Work a station's site search does per step (see stations.stepFind; about 1 µs a unit on desktop Lua, 0.6 ms at
-- most for 500 even on steep ground). A whole search, in one step, took up to 41 ms in-game in a big town.
local SITE_WORK_PER_STEP = 500
-- Spacing of the height samples along the track (metres).
local SAMPLE_STEP = 25.0
-- Work a leg's height fit does per step (see profile.step; about 32 units a µs on desktop Lua, so 0.6 ms, about
-- 2.5 ms in-game). Most legs fit in one step; a 10 km leg over 80 m hills takes about 13.
local PROFILE_WORK_PER_STEP = 20000
-- Path points at each end of a leg whose track may cross the stations' footprints (pathGuard): the first few cells
-- off its stations' ends.
local END_POINTS = 3
-- Grid paths are simplified to within this share of a cell before the curves are fitted. At 0.75 a loop the search
-- made with curves at the build minimum, tight round a station's end, was simplified into one corner too sharp for
-- them (the track then cut over a wall); 0.6 keeps it, and on the regression maps gave one sample on a blocked cell
-- fewer and the same estimates within 0.1%.
local SIMPLIFY_SHARE = 0.6
-- How far the ground under the smoothed track may stray from a uniform slope across the grid path it replaces
-- (metres; see pathGuard): more, and it has climbed a hill or dropped into a hollow the search went round, where it
-- would need a tunnel, a bridge or a cutting the search didn't pay for. A starting value, tuned in-game.
local MAX_GROUND_DIFF = 4.0
-- For progress: a station site counts as 1 unit of work, a leg as this many, and a scout (per round) as this many.
local LEG_WEIGHT = 10
local SCOUT_WEIGHT = 2
-- Each station faces along the scouted line: from this far before it on the scout arriving to this far after it on
-- the scout leaving (metres along the paths), or the full radius's minimum straight if longer (see scoutDir; 1.19 km
-- in Fastest at 3 km, which did a little better there than 600 m: 7 tight curves against 9). For Cheapest on the
-- captures, 600 m was the only length with no samples on blocked cells (300, 900 and 1200 m had one each, at a
-- station end where buildings cut its extension short); 300 m was also 3% dearer.
local MIN_SCOUT_AHEAD = 600.0
-- How many times the stations are scouted and turned. A second round on the captures moved stations again without
-- settling: one capture 6% cheaper but with 5 samples on blocked cells, the others little changed, Fastest a tight
-- curve more.
local SCOUT_ROUNDS = 1
-- A turned station may be at most this much farther from its town's centre than its first site (metres): it should
-- face the line, not leave the town for it. (On the captures no station moved farther than that anyway.)
local MAX_TURN_MOVE = 100.0
-- How far a leg's search may move its ends out along the stations' axes, beyond their extension points (metres;
-- only where turns are spaced). It helps little: along a lattice heading the search could already run straight on,
-- so it only matters for stations facing between the 16 headings. On the Fastest captures it took the tight curves
-- from 11 to 10 on one and the estimate down 0.5% on the other; 2000 m was no better.
local MAX_END_RUN = 1000.0
-- Share of a leg's work that is its search; building it is the rest.
local SEARCH_SHARE = 0.99
-- A leg's search with its turns spaced for a wide radius is taken if its path costs at most this share more than the
-- fallback's (turns spaced for the Cheapest radius); otherwise the radius doesn't fit that leg (station ends misaligned
-- or close together, a narrow passage), and the paths that do fit loop or wander: on the captured Fastest map they
-- cost 2.2 to 6 times as much. The limit also stops a hopeless search early, which unlimited took up to 290 ms (86k
-- expansions) to give up. Limits from 10% to 50% gave the same plans there, the lower with half the expansions; a
-- starting value, to tune with more maps.
local MAX_RADIUS_EXTRA = 0.1
-- A leg whose heading swings through more than this (degrees, the arcs' signed turns added up: their widest spread)
-- loops or hooks round, mostly to enter a station from the side it faces away from (Owings Mills on New Game: 236°,
-- the line came down past the station and turned back up into it; South Valley on PottstownTown: 261°). Ordinary
-- legs on the regression maps swing at most 192°.
local SWEEP_LIMIT = 200.0
-- How many finished searches a job keeps (see searchFor).
local SEARCH_CACHE_SIZE = 4
-- With time priced (Fastest), a leg whose curves lose more than this many seconds (speed.tl) has the station nearer
-- its tightest curve re-sited too: mostly a station whose end faces buildings, so the line hooks round into it
-- (Owings Mills on New Game: re-sited, Alliance → Aloha lost 41 s instead of 58 s, and cost 14% less). On the
-- regression maps' Fastest routes, 10 s took the time lost from 672 s to 423 s and the estimates 7% down (20 s: 541 s,
-- 3% down), for about twice the work (re-siting searches 8 directions' legs).
local RESITE_TIME_LOST = 10.0
-- A re-sited station (see Resite) is taken if its two legs cost at least this share less than with its old site.
local RESITE_GAIN = 0.02
-- Re-siting looks this much farther from the town's centre than the old site (metres).
local RESITE_MOVE = 300.0

-- The direction of travel at stop i: from the previous stop towards the next.
local function stopDir(stops : {Town}, i : integer) : Pt
	local prev = stops[i - 1] or stops[i]
	local next = stops[i + 1] or stops[i]
	return geo.norm(geo.sub(next.pos, prev.pos))
end

-- Grid cells (by index) under a station's platforms.
local function platformCells(input : Input, station : Station) : {integer : boolean}
	local g = input.grid
	local cells : {integer : boolean} = {}
	local half = input.platformLength / 2
	local c, dir = station.site.centre, station.site.dir
	local d = -half
	while d <= half + 1e-6 do
		local ix, iy = grid.cellOf(g, geo.add(c, geo.scale(dir, d)))
		cells[grid.index(g, ix, iy)] = true
		d = d + g.cell / 2
	end
	return cells
end

-- Whether the straight from `a` to `b` is inside the grid and every cell it passes through is off blocked cells and
-- other stations' platforms (`taken`, less this station's own `own`).
local function straightClear(input : Input, a : Pt, b : Pt, taken : {integer : boolean},
		own : {integer : boolean}) : boolean
	local g = input.grid
	-- The grid is a rectangle, so a straight with both ends inside is inside.
	if not grid.inside(g, a) or not grid.inside(g, b) then
		return false
	end
	return grid.cellsAlong(g, a, b, function(i : integer) : boolean
		return not (g.blocked[i] or (taken ~= nil and taken[i] and not own[i]))
	end)
end

-- Whether the leg's search can leave (or reach) an extension point, heading out of the station (`out`) within the
-- 90° it may turn at once, other than back along the station (`back`: the far end of its run) and the straight from
-- it: the point sits off its cell's centre, and the search's first (or last) segment from it must be clear.
-- Between buildings it may have no such move where the approach point has one (Pottstown on the third save: the
-- extension 28 m beyond the approach could only be reached across a building's corner, and the leg found no path).
local function leavable(g : Grid, back : Pt, extension : Pt, out : Pt) : boolean
	local straight : {integer : boolean} = {}
	grid.cellsAlong(g, back, extension, function(i : integer) : boolean
		straight[i] = true
		return true
	end)
	local ix, iy = grid.cellOf(g, extension)
	straight[grid.index(g, ix, iy)] = nil
	return #grid.leaveCells(g, extension, out, straight) > 0
end

-- The minimum straight between turns for the full radius (grid.startSearch): 2 · minRadius · tan(11.25°).
local function minStraight(input : Input) : number
	return 2 * input.weights.minRadius * math.tan(math.pi / 16)
end

-- The room to turn beyond a station's approach: for the first turn the leg's search may make there, at full radius.
-- Where the search turns freely (its minimum straight within a cell) that may be anything up to 90°, so room for a
-- 45° turn (minRadius × tan 22.5°); otherwise it is one 22.5° step, so minRadius × tan 11.25°. The longer room cost
-- Fastest dear on the captures: with stations facing the line, 1.24 km straights at R = 3000 m pushed the legs'
-- ends past their turns, into a ridge (a 300 m tunnel) and loops (estimate 23.2–23.5 M against 19.6 M).
local function extensionLength(input : Input, radius : number) : number
	local r = radius or input.weights.minRadius
	if 2 * r * math.tan(math.pi / 16) <= input.grid.cell + 1e-6 then
		return r * math.tan(math.pi / 8)
	end
	return r * math.tan(math.pi / 16)
end

-- Where a station's platforms end, where its straight approach ends, and where the room to turn beyond it ends
-- (extensionLength), on its leaving side (forward = true) or its arriving side.
-- The room to turn takes at most a quarter of the way to the neighbouring station on that side (`other`: the
-- distance ahead along this station's axis, less both stations' platform halves and approaches), so two close
-- stations' rooms don't overlap. Overlapping, the leg's search had to start beyond where it ends and loop back round
-- (Fastest at 3 km on the 54-town map: Temple City to Miami, 1.3 km apart, became a loop that smoothing cut with a
-- 55 m curve over buildings). On the regression maps' Fastest routes a quarter did best: estimates 92.4 M in all
-- against 99.6 M uncapped, 93.2 M at a half and 104.4 M at a third, and samples on blocked cells 4 against 6, 6 and 4.
-- The leg's search starts or ends at the last, and the track runs straight to it, so it is pulled back (half a cell
-- at a time, at most to the approach point) until that straight is inside the grid and clear of blocked cells and
-- other stations' platforms (`taken`). Where it's pulled back, the curve beyond may be tighter than minRadius (and
-- where that's below what can be built, fitLeg gives the extension up).
local function stationEnds(input : Input, station : Station, forward : boolean, taken : {integer : boolean},
		other : Station, radius ?: number) : Pt, Pt, Pt
	local g = input.grid
	local sign = forward and 1 or -1
	local half = input.platformLength / 2
	local c, d = station.site.centre, station.site.dir
	local platformEnd = geo.add(c, geo.scale(d, sign * half))
	local approach = geo.add(c, geo.scale(d, sign * (half + APPROACH)))
	local own = platformCells(input, station)
	local ext = extensionLength(input, radius)
	if other ~= nil then
		local ahead = sign * geo.dot(geo.sub(other.site.centre, c), d)
		ext = math.min(ext, (ahead - 2 * (half + APPROACH)) / 4)
	end
	while ext > 0 do
		local extension = geo.add(c, geo.scale(d, sign * (half + APPROACH + ext)))
		if straightClear(input, approach, extension, taken, own)
				and leavable(g, geo.add(c, geo.scale(d, -sign * (half + APPROACH))), extension, geo.scale(d, sign)) then
			return platformEnd, approach, extension
		end
		ext = ext - g.cell / 2
	end
	return platformEnd, approach, approach
end

-- Where a leg's search starts or ends at a station (its extension point), and its room to turn: how far the
-- extension reaches beyond the approach (grid.startSearch's startRoom and goalRoom).
local function legEnd(input : Input, station : Station, forward : boolean, taken : {integer : boolean},
		other : Station, radius ?: number) : Pt, number
	local __, approach, extension = stationEnds(input, station, forward, taken, other, radius)
	return extension, geo.dist(approach, extension)
end

-- How far a station's room to turn reaches beyond its approach, on one side (metres; see stationEnds).
local function turnRoom(input : Input, station : Station, forward : boolean, taken : {integer : boolean},
		other : Station) : number
	local __, approach, extension = stationEnds(input, station, forward, taken, other)
	return geo.dist(approach, extension)
end

-- Adds the cells (by grid index) under a station's platforms and approaches to `cells`: legs' searches keep off
-- them (their own ends' cells aside), so a line that loops round never crosses a station's track.
local function addFootprint(input : Input, station : Station, cells : {integer : boolean})
	local g = input.grid
	local reach = input.platformLength / 2 + APPROACH
	local c, dir = station.site.centre, station.site.dir
	local d = -reach
	while d <= reach + 1e-6 do
		local ix, iy = grid.cellOf(g, geo.add(c, geo.scale(dir, d)))
		cells[grid.index(g, ix, iy)] = true
		d = d + g.cell / 4
	end
end

-- The plan's stations' footprints (addFootprint), with station i at `site` instead where given.
local function footprints(input : Input, plan : Plan, i : integer, site : Station) : {integer : boolean}
	local cells : {integer : boolean} = {}
	for j, station in ipairs(plan.stations) do
		if j == i then
			addFootprint(input, site, cells)
		else
			addFootprint(input, station, cells)
		end
	end
	return cells
end

-- Adds a station's platform cells (by grid index) to `taken`, so later sites keep off them.
local function takePlatforms(input : Input, station : Station, taken : {integer : boolean})
	for i in pairs(platformCells(input, station)) do
		taken[i] = true
	end
end

-- The curve radii a leg's search tries, in order: the fallback (weights.minSearchRadius) first, then from the full
-- radius halving down while still above it; just the full radius where it is no wider than the fallback.
local function searchRadii(w : PgraceRailRouterModes.Weights) : {number}
	local floor = w.minSearchRadius or w.minRadius
	if w.minRadius <= floor + 1e-6 then
		return { w.minRadius }
	end
	local radii : {number} = { floor }
	local r = w.minRadius
	while r > floor + 1e-6 do
		table.insert(radii, r)
		r = r / 2
	end
	return radii
end

-- The point `d` metres along `path` from its start (or from its end, backwards), or its far end if it's shorter.
local function pointAlong(path : {Pt}, d : number, fromEnd : boolean) : Pt
	local n = #path
	local prev = fromEnd and path[n] or path[1]
	for k = 2, n do
		local p = fromEnd and path[n + 1 - k] or path[k]
		local l = geo.dist(prev, p)
		if l >= d then
			return geo.add(prev, geo.scale(geo.sub(p, prev), d / l))
		end
		d = d - l
		prev = p
	end
	return prev
end

-- The direction the scouted line runs through station i: from `ahead` before it on the scout arriving to `ahead`
-- after it on the scout leaving (from or to the station's centre at the line's ends), where `ahead` is the full
-- radius's minimum straight, or MIN_SCOUT_AHEAD if more: over a shorter stretch, a scout one cell off the station's
-- axis would turn it by 10° or more. nil without a scout.
local function scoutDir(job : Job, i : integer) : Pt
	local ahead = math.max(MIN_SCOUT_AHEAD, minStraight(job.input))
	local centre = job.result.stations[i].site.centre
	local arriving, leaving = job.scouts[i - 1], job.scouts[i]
	local from, to = centre, centre
	if arriving ~= nil then
		from = pointAlong(arriving, ahead, true)
	end
	if leaving ~= nil then
		to = pointAlong(leaving, ahead, false)
	end
	local d = geo.sub(to, from)
	if geo.len(d) < 1e-6 then
		return nil
	end
	return geo.norm(d)
end

-- Whether consecutive stations a and b leave room between them: their platforms and approaches fit, and b lies ahead
-- of a along both their directions.
local function apartEnough(input : Input, a : PgraceRailRouterStations.Site, b : PgraceRailRouterStations.Site) : boolean
	local apart = geo.sub(b.centre, a.centre)
	return geo.len(apart) >= input.platformLength + 2 * APPROACH and geo.dot(apart, a.dir) > 0
		and geo.dot(apart, b.dir) > 0
end

-- Whether the weights price travel time (Fastest): then a leg's search radii are weighed by it.
local function timePriced(w : PgraceRailRouterModes.Weights) : boolean
	return w.timeCost ~= nil and w.timeCost > 0 and w.topSpeed ~= nil and w.lateralAccel ~= nil
end

-- A leg's search, as grid.startSearch, or the same search finished before: re-siting a station searches its current
-- site's legs first, which are the legs' own searches (the leg just built, and the next one). Only searches with no
-- cost limit and no runs along the stations' axes are kept, the last SEARCH_CACHE_SIZE of them.
local function searchFor(job : Job, from : Pt, to : Pt, fromDir : Pt, toDir : Pt, radius : number, maxCost : number,
		run : number, fromRoom : number, toRoom : number, avoid : {integer : boolean}) : PgraceRailRouterGrid.Search
	local key : string = nil
	-- The stations' footprints to keep off are the plan's current ones (re-siting's current site) where the key is used.
	if maxCost == nil and run == nil then
		key = ("%.6f %.6f %.6f %.6f %.9f %.9f %.9f %.9f %.6f %.6f %.6f %d"):format(from.x, from.y, to.x, to.y, fromDir.x,
			fromDir.y, toDir.x, toDir.y, radius, fromRoom, toRoom, job.footprintVersion)
		local hit = job.searchCache[key]
		if hit ~= nil then
			return hit
		end
	end
	local s = grid.startSearch(job.input.grid, from, to, fromDir, toDir, job.input.weights, radius, maxCost, run, run,
		fromRoom, toRoom, APPROACH, avoid)
	if key ~= nil then
		s.cacheKey = key
	end
	return s
end

-- Keeps a finished search for searchFor, if it may be asked for again.
local function keepSearch(job : Job, s : PgraceRailRouterGrid.Search)
	local key = s.cacheKey
	if key == nil or job.searchCache[key] ~= nil then
		return
	end
	job.searchCache[key] = grid.finished(s)
	table.insert(job.searchKeys, key)
	if #job.searchKeys > SEARCH_CACHE_SIZE then
		job.searchCache[table.remove(job.searchKeys, 1)] = nil
	end
end

-- Expansions for one step of a search. With turns spaced for a wide radius, an expansion walks a whole straight (up
-- to a dozen cells), so a step gets proportionally fewer: in-game a 150-expansion step at 3 km took 16–21 ms.
local function searchBudget(search : PgraceRailRouterGrid.Search, maxExpansions : integer) : integer
	local longest = 1
	for __, steps in ipairs(search.straightSteps) do
		longest = math.max(longest, steps)
	end
	return math.max(1, math.floor(maxExpansions / longest))
end

-- The exit check for stop i's town, shared by all its site searches.
local function exitFor(job : Job, i : integer) : PgraceRailRouterStations.Exit
	if job.exits[i] == nil then
		-- A leg arrives at every station but the first, and leaves every one but the last.
		job.exits[i] = { radius = EXIT_RADIUS, known = {}, backward = i > 1, forward = i < #job.input.stops }
	end
	return job.exits[i]
end

-- Moves the turning phase on to the next station, or on to the next round or the legs after the last.
local function nextTurn(job : Job)
	local input, plan = job.input, job.result
	job.siteIndex = job.siteIndex + 1
	if job.siteIndex > #plan.stations then
		if job.round < SCOUT_ROUNDS then
			job.phase, job.round, job.scoutIndex, job.scouts = "scout", job.round + 1, 1, {}
		else
			-- The legs keep off every platform (each station's ends less its own).
			job.taken = {}
			for __, other in ipairs(plan.stations) do
				takePlatforms(input, other, job.taken)
			end
			job.footprint, job.footprintVersion = footprints(input, plan, 0, nil), 1
			job.phase = "legs"
		end
	end
end

-- Arcs in a fitted leg below what the game can build.
local function belowBuild(input : Input, fitted : PgraceRailRouterSmooth.Result) : integer
	local n = 0
	for __, piece in ipairs(fitted.pieces) do
		if piece.kind == "arc" and piece.radius < input.weights.minBuildRadius - 1e-6 then
			n = n + 1
		end
	end
	return n
end

-- Where the first arc below the build minimum starts in a fitted leg; nil if none.
local function belowAt(input : Input, fitted : PgraceRailRouterSmooth.Result) : Pt
	for __, piece in ipairs(fitted.pieces) do
		if piece.kind == "arc" and piece.radius < input.weights.minBuildRadius - 1e-6 then
			return piece.a
		end
	end
	return nil
end

-- Where the tightest arc starts in a fitted leg; nil if none.
local function tightestAt(fitted : PgraceRailRouterSmooth.Result) : Pt
	local best : PgraceRailRouterSmooth.Piece = nil
	for __, piece in ipairs(fitted.pieces) do
		if piece.kind == "arc" and (best == nil or piece.radius < best.radius) then
			best = piece
		end
	end
	return best ~= nil and best.a or nil
end

-- How far a leg's heading swings (degrees): the widest spread of its arcs' signed turns added up from its start.
local function sweepOf(fitted : PgraceRailRouterSmooth.Result) : number
	local heading, lo, hi = 0.0, 0.0, 0.0
	for __, piece in ipairs(fitted.pieces) do
		if piece.kind == "arc" then
			heading = heading + piece.turn
			lo, hi = math.min(lo, heading), math.max(hi, heading)
		end
	end
	return math.deg(hi - lo)
end

-- Starts re-siting station i (the station the current leg arrives at), keeping the leg built so far to go back to.
-- Candidates: its current site, then sites facing each of 8 axes (every 22.5°, the way from the previous stop to
-- the next), each weighed by the cost of the searches for its two legs at the fallback radius.
local function startResite(job : Job, i : integer)
	local plan, input = job.result, job.input
	local station = plan.stations[i]
	local prev, next = plan.stations[i - 1], plan.stations[i + 1]
	local along = geo.sub((next or station).town.pos, (prev or station).town.pos)
	local dirs : {Pt} = {}
	for k = 0, 7 do
		local angle = k * math.pi / 8
		local d : Pt = { x = math.cos(angle), y = math.sin(angle) }
		if geo.dot(d, along) < 0 then
			d = geo.scale(d, -1)
		end
		-- The current axis is the first candidate already.
		if math.abs(geo.dot(d, station.site.dir)) < math.cos(math.pi / 16) then
			table.insert(dirs, d)
		end
	end
	local others : {integer : boolean} = {}
	for j, other in ipairs(plan.stations) do
		if j ~= i then
			takePlatforms(input, other, others)
		end
	end
	job.resited[i] = true
	local stage = "in"
	if prev == nil then
		stage = "out"
	end
	job.resite = { station = i, dirs = dirs, k = 0, site = station.site, stage = stage, inCost = 0, others = others,

		bestCost = math.huge, best = station.site, keep = { path = job.path, simplified = job.simplified,
		fitted = job.fitted, radius = job.searchRadius, cost = job.pathCost } }
	job.path, job.simplified, job.fitted, job.heights = nil, nil, nil, nil
end

-- One step of re-siting (see startResite): part of a candidate's site search, starting or running one of its legs'
-- searches. Ends by taking the cheapest candidate, and has the current leg searched again if that's a new site, or
-- by putting the leg back as it was.
local function stepResite(job : Job, maxExpansions : integer)
	local rs, plan, input = job.resite, job.result, job.input
	local w = input.weights
	local i = rs.station
	local station = plan.stations[i]
	local prev, next = plan.stations[i - 1], plan.stations[i + 1]
	local function nextCandidate()
		rs.k = rs.k + 1
		rs.search, rs.finder, rs.site, rs.avoid = nil, nil, nil, nil
		if rs.k > #rs.dirs then
			job.resite = nil
			if rs.best ~= station.site then
				station.site, station.z = rs.best, grid.heightAt(input.grid, rs.best.centre)
				job.taken = {}
				for __, other in ipairs(plan.stations) do
					takePlatforms(input, other, job.taken)
				end
				job.footprint, job.footprintVersion = footprints(input, plan, 0, nil), job.footprintVersion + 1
				-- The leg is searched again (from its first radius) to the new site; and where the station is the one the
				-- leg leaves from, the leg before it, already built, is built again first.
				job.radii = nil
				if i == job.legIndex and i > 1 then
					table.remove(plan.legs)
					job.legIndex = job.legIndex - 1
				end
			else
				local keep = rs.keep
				job.path, job.simplified, job.fitted = keep.path, keep.simplified, keep.fitted
				job.searchRadius, job.pathCost = keep.radius, keep.cost
			end
			return
		end
		rs.stage, rs.inCost = "site", 0
	end
	if rs.stage == "site" then
		if rs.finder == nil then
			rs.finder = stations.startFind(input.grid, station.town.pos, rs.dirs[rs.k], input.platformLength + 2 * APPROACH,
				MAX_STATION_RELIEF, math.min(MAX_STATION_RADIUS, station.site.distance + RESITE_MOVE), rs.others,
				exitFor(job, i))
		end
		if not stations.stepFind(rs.finder, SITE_WORK_PER_STEP) then
			return
		end
		local site = rs.finder.site
		rs.finder = nil
		if site == nil or (prev ~= nil and not apartEnough(input, prev.site, site))
				or (next ~= nil and not apartEnough(input, site, next.site)) then
			nextCandidate()
			return
		end
		rs.site, rs.stage = site, "in"
		if prev == nil then
			rs.stage = "out"
		end
		return
	end
	local candidate : Station = { town = station.town, site = rs.site, z = station.z }
	-- The legs are weighed by their fallback-radius searches, with rooms to turn sized for it (as the legs' own).
	local radius = w.minSearchRadius or w.minRadius
	if rs.search == nil then
		local from, to, fromDir, toDir : Pt, Pt, Pt, Pt
		local fromRoom, toRoom : number, number
		if rs.stage == "in" then
			from, fromRoom = legEnd(input, prev, true, rs.others, candidate, radius)
			to, toRoom = legEnd(input, candidate, false, rs.others, prev, radius)
			fromDir, toDir = prev.site.dir, rs.site.dir
		else
			from, fromRoom = legEnd(input, candidate, true, rs.others, next, radius)
			to, toRoom = legEnd(input, next, false, rs.others, candidate, radius)
			fromDir, toDir = rs.site.dir, next.site.dir
		end
		-- Only as dear as could still win: a candidate must beat the best so far by RESITE_GAIN, and its two legs
		-- together (the current site's are searched first, with no limit).
		local maxCost : number = nil
		if rs.bestCost < math.huge then
			maxCost = rs.bestCost * (1 - RESITE_GAIN)
			if rs.stage == "out" then
				maxCost = maxCost - rs.inCost
			elseif next ~= nil then
				-- The leg out costs at least its ends' distance apart (no step costs less than its length).
				local outFrom = legEnd(input, candidate, true, rs.others, next, radius)
				local outTo = legEnd(input, next, false, rs.others, candidate, radius)
				maxCost = maxCost - geo.dist(outFrom, outTo)
			end
		end
		if rs.avoid == nil then
			rs.avoid = footprints(input, plan, i, candidate)
		end
		rs.search = searchFor(job, from, to, fromDir, toDir, radius, maxCost, nil, fromRoom, toRoom, rs.avoid)
		return
	end
	if not grid.stepSearch(rs.search, searchBudget(rs.search, maxExpansions)) then
		return
	end
	local search = rs.search
	rs.search = nil
	keepSearch(job, search)
	job.searchExpansions = job.searchExpansions + search.expansions
	if not search.found then
		nextCandidate()
		return
	end
	if rs.stage == "in" then
		rs.inCost = search.cost[0]
		if next ~= nil then
			rs.stage = "out"
			return
		end
	end
	local total = rs.inCost
	if rs.stage == "out" then
		total = total + search.cost[0]
	end
	-- The current site sets the bar; a new one must beat it clearly.
	if rs.k == 0 then
		rs.bestCost = total
	elseif total < rs.bestCost * (1 - RESITE_GAIN) then
		rs.best, rs.bestCost = rs.site, total
	end
	nextCandidate()
end

local function fail(job : Job, failure : string, towns : {string}) : boolean
	job.result.ok = false
	job.result.failure = failure
	job.result.failureTowns = towns
	job.phase = "done"
	return true
end

-- The point nearest to p on the segment a–b.
local function project(p : Pt, a : Pt, b : Pt) : Pt
	local ab = geo.sub(b, a)
	local l2 = geo.dot(ab, ab)
	if l2 < 1e-18 then
		return a
	end
	local f = math.max(0, math.min(1, geo.dot(geo.sub(p, a), ab) / l2))
	return geo.add(a, geo.scale(ab, f))
end

-- Whether track at a point stays on the kind of ground the grid path had, so that smoothing doesn't take it where
-- the search chose not to go. clear(p, from, to) takes q, the point of the path line path[from..to] nearest to p,
-- and is true when p is inside the grid and off blocked cells, over water only where q is, and its ground is within
-- MAX_GROUND_DIFF of the uniform slope across the path at q. That slope comes from the mirror image of p, q' = 2q − p:
-- on any plane the rise from q to p equals the rise from q' to q, so h(p) − 2h(q) + h(q') is zero on a tilted plane
-- (bilinear heights are exact there) and measures only the bend in the ground across the path, at the scale of the
-- offset: a hill beside the path, or the valley side above it. Comparing h(p) with h(q) alone would refuse any
-- offset on a plain incline.
-- Track also keeps off the stations' platforms and approaches (`footprint`), except next to the leg's ends (within
-- END_POINTS path points of them), where it runs into its own stations.
local function pathGuard(g : Grid, path : {Pt}, footprint : {integer : boolean}) : function(p : Pt, from : integer,
		to : integer) : boolean
	local n = #path
	-- The longest step between neighbouring path points: the nearest-point search skips ahead by it.
	local maxGap = 1e-9
	for k = 2, n do
		maxGap = math.max(maxGap, geo.dist(path[k - 1], path[k]))
	end
	-- Checks come in runs along a piece, so the last answer is a good first guess for the next.
	local hint = 1
	local function nearest(p : Pt, from : integer, to : integer) : integer
		from, to = math.max(1, from), math.min(n, to)
		if hint < from or hint > to then
			hint = from
		end
		-- Plain arithmetic rather than geo.dist: this is the guard's inner loop, and geo allocates a table per call.
		local px, py = p.x, p.y
		local h = path[hint]
		local best, bestD = hint, math.sqrt((h.x - px) * (h.x - px) + (h.y - py) * (h.y - py))
		local k = from
		while k <= to do
			local q = path[k]
			local d = math.sqrt((q.x - px) * (q.x - px) + (q.y - py) * (q.y - py))
			if d < bestD then
				best, bestD = k, d
			end
			-- path[k + m] is at least d − m × maxGap from p, so the points up to k + (d − bestD) / maxGap can't be
			-- nearer than best: skip them. Far from p that's most of the path.
			k = k + 1 + math.floor((d - bestD) / maxGap)
		end
		hint = best
		return best
	end
	return function(p : Pt, from : integer, to : integer) : boolean
		if not grid.inside(g, p) then
			return false
		end
		local ix, iy = grid.cellOf(g, p)
		local cell = grid.index(g, ix, iy)
		if g.blocked[cell] then
			return false
		end
		from, to = math.max(1, from), math.min(n, to)
		local k = nearest(p, from, to)
		if footprint ~= nil and footprint[cell] and k > END_POINTS and k <= n - END_POINTS then
			return false
		end
		-- The nearest point of the path line lies on a segment either side of its nearest vertex.
		local q = path[k]
		local qd = geo.dist(p, q)
		for __, m in ipairs({ k - 1, k + 1 }) do
			if m >= from and m <= to then
				local c = project(p, path[k], path[m])
				local cd = geo.dist(p, c)
				if cd < qd then
					q, qd = c, cd
				end
			end
		end
		if g.water[cell] and not grid.waterAt(g, q) then
			return false
		end
		local mirror = geo.sub(geo.scale(q, 2), p)
		local bend = grid.heightAt(g, p) - 2 * grid.heightAt(g, q) + grid.heightAt(g, mirror)
		return math.abs(bend) <= MAX_GROUND_DIFF
	end
end

-- Building a leg takes three steps, so no frame takes them all (in-game one took 14.7 ms): simplifying the path
-- (the guard's checks along each candidate straight are the dearest part), filleting it, and sampling its heights.
local function simplifyLeg(input : Input, a : Station, b : Station, path : {Pt},
		taken : {integer : boolean}, footprint : {integer : boolean}) : PgraceRailRouterRoute.Simplified
	local g, w = input.grid, input.weights
	local aEnd, aApproach = stationEnds(input, a, true, taken, b)
	local bEnd, bApproach = stationEnds(input, b, false, taken, a)
	-- Simplifying and filleting are guarded, so the track keeps to the ground the path chose (off water, hillsides
	-- and buildings it went round), checked every quarter cell.
	local clear = pathGuard(g, path, footprint)
	local step = g.cell / 4
	local function straightOnPath(i : integer, j : integer) : boolean
		local from, to = path[i], path[j]
		local length = geo.dist(from, to)
		local dir = geo.scale(geo.sub(to, from), 1 / math.max(length, 1e-9))
		local d = 0.0
		while true do
			if not clear(geo.add(from, geo.scale(dir, math.min(d, length))), i, j) then
				return false
			end
			if d >= length then
				return true
			end
			d = d + step
		end
	end
	-- path runs from a's extension point to b's; add the platform ends and approach points, and keep all of them
	-- fixed so the line leaves and enters the platforms straight and has room to turn at full radius beyond (unless
	-- that makes a curve the game can't build: see below). (Where an extension point is its approach point, fillet
	-- merges the two.) raw maps each point to the path
	-- point it stands for, for the guard.
	local middle, kept = smooth.simplify(path, g.cell * SIMPLIFY_SHARE, straightOnPath)
	local pts : {Pt} = { aEnd, aApproach }
	local raw : {integer} = { 1, 1 }
	for k, p in ipairs(middle) do
		table.insert(pts, p)
		table.insert(raw, kept[k])
	end
	table.insert(pts, bApproach)
	table.insert(pts, bEnd)
	table.insert(raw, #path)
	table.insert(raw, #path)
	local guard : PgraceRailRouterSmooth.Guard = { step = step, minRadius = w.minBuildRadius,
		clear = function(p : Pt, from : integer, to : integer) : boolean
			return clear(p, raw[from], raw[to])
		end }
	return { pts = pts, guard = guard }
end

local function fitLeg(input : Input, simplified : PgraceRailRouterRoute.Simplified) : PgraceRailRouterSmooth.Result
	local w = input.weights
	local pts, guard = simplified.pts, simplified.guard
	-- freeA and freeB give up a's or b's extension point: the curve there moves to the approach point (the extension
	-- is put on it, and fillet merges the two), with the approach behind it, as the search allows for
	-- (grid.startSearch's rooms).
	local function fit(freeA : boolean, freeB : boolean) : PgraceRailRouterSmooth.Result
		local fixed : {boolean} = {}
		fixed[2], fixed[3], fixed[#pts - 2], fixed[#pts - 1] = true, true, true, true
		local use = pts
		if freeA or freeB then
			use = {}
			for k, p in ipairs(pts) do
				use[k] = p
			end
			if freeA then
				use[3] = pts[2]
			end
			if freeB then
				use[#pts - 2] = pts[#pts - 1]
			end
		end
		return smooth.fillet(use, w.minRadius, fixed, guard)
	end
	-- Whether a's end and b's end have an arc the game can't build (below minBuildRadius) at one of their fixed
	-- points (platform end, approach, extension: the first three points, or the last three).
	local function belowFloor(f : PgraceRailRouterSmooth.Result) : boolean, boolean
		local atA, atB = false, false
		for k, piece in ipairs(f.pieces) do
			local i = f.corners[k]
			if piece.kind == "arc" and i ~= nil and piece.radius < w.minBuildRadius - 1e-6 then
				atA = atA or i <= 3
				atB = atB or i >= #pts - 2
			end
		end
		return atA, atB
	end
	-- Samples on blocked cells in each half of a fitted leg: a corner cut over buildings, where a point next to an
	-- extension was dropped because the curves either side of it wouldn't fit even at the floor.
	local function blockedHalves(f : PgraceRailRouterSmooth.Result) : integer, integer
		local samples = smooth.sample(f.pieces, guard.step)
		local total = #samples > 0 and samples[#samples].s or 0
		local nA, nB = 0, 0
		for __, sample in ipairs(samples) do
			local ix, iy = grid.cellOf(input.grid, sample.p)
			if input.grid.blocked[grid.index(input.grid, ix, iy)] then
				if sample.s <= total / 2 then
					nA = nA + 1
				else
					nB = nB + 1
				end
			end
		end
		return nA, nB
	end
	local fitted = fit(false, false)
	-- Where the fixed points squeeze an arc below what can be built (an extension pulled back short of a sharp turn),
	-- give up that end's extension: the turn then starts at the approach, or the point after the extension, with
	-- more room. An end that still can't reach the floor keeps its extension (and its tight arc, counted below).
	local tightA, tightB = belowFloor(fitted)
	local freedA, freedB = false, false
	if tightA or tightB then
		local refit = fit(tightA, tightB)
		local stillA, stillB = belowFloor(refit)
		local freeA, freeB = tightA and not stillA, tightB and not stillB
		if freeA == tightA and freeB == tightB then
			fitted = refit
		elseif freeA or freeB then
			fitted = fit(freeA, freeB)
		end
		freedA, freedB = freeA, freeB
	end
	-- The search lets a sharp turn at an extension point slide back into the station's straight (grid.startSearch's
	-- rooms), so a curve there that the fixed extension leaves no room for cuts the corner instead. Where that puts
	-- track over buildings near an end, give that extension up too, if it does better.
	local blockedA, blockedB = blockedHalves(fitted)
	if (blockedA > 0 and not freedA) or (blockedB > 0 and not freedB) then
		local refit = fit(freedA or blockedA > 0, freedB or blockedB > 0)
		local againA, againB = blockedHalves(refit)
		local stillA, stillB = belowFloor(refit)
		if againA + againB < blockedA + blockedB and not (stillA and not tightA) and not (stillB and not tightB) then
			fitted = refit
		end
	end
	return fitted
end

-- Samples a fitted leg's ground and starts fitting its heights (profile.start; stepped by route.step).
local function startHeights(input : Input, a : Station, b : Station, fitted : PgraceRailRouterSmooth.Result) : LegHeights
	local g, w = input.grid, input.weights
	local samples = smooth.sample(fitted.pieces, SAMPLE_STEP)
	local s : {number} = {}
	local ground : {number} = {}
	local water : {boolean} = {}
	-- Existing track is always crossed by a bridge, roads only when the mode says so.
	local crossing : {boolean} = {}
	local blockedSamples = 0
	for i, sample in ipairs(samples) do
		s[i] = sample.s
		ground[i] = grid.heightAt(g, sample.p)
		water[i] = grid.waterAt(g, sample.p)
		local ix, iy = grid.cellOf(g, sample.p)
		local cell = grid.index(g, ix, iy)
		if g.blocked[cell] then
			blockedSamples = blockedSamples + 1
		end
		crossing[i] = g.track[cell] or (w.bridgeRoads and g.road[cell]) or false
	end
	local fit = profile.start(s, ground, water, { maxGrade = w.maxGrade, bridgeAbove = w.bridgeAbove,
		tunnelBelow = w.tunnelBelow, bridgeCostFactor = w.bridgeCostFactor, tunnelCostFactor = w.tunnelCostFactor,
		zStart = a.z, zEnd = b.z, crossing = crossing })
	return { fitted = fitted, samples = samples, blockedSamples = blockedSamples, fit = fit }
end

-- Seconds a train stopping at both stations loses to a fitted leg's curves below the mode's radius (speed.tl), from
-- station centre to station centre: half a platform either side of the pieces. 0 without the speed model's weights.
local function legTimeLost(input : Input, fitted : PgraceRailRouterSmooth.Result) : number
	local w = input.weights
	if w.topSpeed == nil or w.lateralAccel == nil then
		return 0
	end
	local half = input.platformLength / 2
	local limits, length = speed.pieceLimits(fitted.pieces, half, w)
	return speed.timeLost(length + 2 * half, limits, w.topSpeed)
end

-- The leg, once its heights are fitted.
local function finishLeg(input : Input, heights : LegHeights) : Leg
	local w = input.weights
	local fitted, samples, fit = heights.fitted, heights.samples, heights.fit.result
	local tight = 0
	for __, piece in ipairs(fitted.pieces) do
		if piece.kind == "arc" and piece.radius < w.minRadius - 1e-6 then
			tight = tight + 1
		end
	end
	local length = 0.0
	if #samples > 0 then
		length = samples[#samples].s
	end
	return { pieces = fitted.pieces, samples = samples, z = fit.z, spans = fit.spans, length = length,
		minRadius = fitted.minRadius, maxGrade = fit.maxGrade, tightCurves = tight, steepEnds = not fit.feasible,
		blockedSamples = heights.blockedSamples, guarded = fitted.guarded, timeLost = legTimeLost(input, fitted) }
end

local function summarise(input : Input, plan : Plan) : Summary
	local w = input.weights
	local sum : Summary = { length = 0, bridges = 0, bridgeLength = 0, tunnels = 0, tunnelLength = 0, maxGrade = 0,
		minRadius = math.huge, estimate = 0, tightCurves = 0, steepLegs = 0, blockedSamples = 0, guarded = 0,
		timeLost = 0 }
	for __, leg in ipairs(plan.legs) do
		sum.length = sum.length + leg.length
		sum.timeLost = sum.timeLost + leg.timeLost
		sum.tightCurves = sum.tightCurves + leg.tightCurves
		sum.blockedSamples = sum.blockedSamples + leg.blockedSamples
		sum.guarded = sum.guarded + leg.guarded
		if leg.steepEnds then
			sum.steepLegs = sum.steepLegs + 1
		end
		sum.maxGrade = math.max(sum.maxGrade, leg.maxGrade)
		sum.minRadius = math.min(sum.minRadius, leg.minRadius)
		for __, span in ipairs(leg.spans) do
			local l = span.s1 - span.s0
			local factor = 1.0
			if span.kind == "bridge" then
				sum.bridges = sum.bridges + 1
				sum.bridgeLength = sum.bridgeLength + l
				factor = w.bridgeCostFactor
			elseif span.kind == "tunnel" then
				sum.tunnels = sum.tunnels + 1
				sum.tunnelLength = sum.tunnelLength + l
				factor = w.tunnelCostFactor
			end
			sum.estimate = sum.estimate + l * w.costPerMetre * factor
		end
	end
	local platforms = #plan.stations * input.platformLength
	sum.length = sum.length + platforms
	sum.estimate = sum.estimate + platforms * w.costPerMetre
	return sum
end

-- After a leg's search try (weighing radii): on to the next radius, or, after the last, the best try taken as the
-- leg (already simplified and filleted).
local function nextTry(job : Job)
	if job.tryIndex < #job.radii then
		job.tryIndex = job.tryIndex + 1
		return
	end
	local best = job.best
	job.path, job.simplified, job.fitted = best.path, best.simplified, best.fitted
	job.searchRadius, job.pathCost = best.radius, best.cost
	job.radii, job.fallback, job.best, job.bestTotal = nil, nil, nil, nil
end

-- A fitted leg that loops, or hooks round into or out of a station, or has a curve the game can't build, or (time
-- priced) loses more than RESITE_TIME_LOST to its curves: perhaps a station faces the wrong way for it. Weigh other
-- directions for one by their legs' costs: the one nearer the curve that can't be built (or for a slow leg, its
-- tightest curve), else the one the leg arrives at; each station once.
local function checkLeg(job : Job, a : Station, b : Station)
	local input = job.input
	local slow = timePriced(input.weights) and legTimeLost(input, job.fitted) > RESITE_TIME_LOST
	if belowBuild(input, job.fitted) == 0 and sweepOf(job.fitted) <= SWEEP_LIMIT and not slow then
		return
	end
	local first, second = job.legIndex + 1, job.legIndex
	local p = belowAt(input, job.fitted)
	if p == nil and slow then
		p = tightestAt(job.fitted)
	end
	if p ~= nil and geo.dist(p, a.site.centre) < geo.dist(p, b.site.centre) then
		first, second = job.legIndex, job.legIndex + 1
	end
	for __, i in ipairs({ first, second }) do
		if not job.resited[i] then
			startResite(job, i)
			return
		end
	end
end

function route.start(input : Input) : Job
	local job : Job = { input = input, phase = "sites", siteIndex = 1, legIndex = 1, taken = {}, searchExpansions = 0,
		exits = {}, turnPending = false, resited = {}, searchCache = {}, searchKeys = {},
		result = { ok = true, failureTowns = {}, platformLength = input.platformLength, stations = {}, legs = {} } }
	if #input.stops < 2 then
		fail(job, "no_stops", {})
	end
	return job
end

function route.step(job : Job, maxExpansions : integer) : boolean
	local input, plan = job.input, job.result
	if job.phase == "done" then
		return true
	end
	if job.phase == "sites" then
		local i = job.siteIndex
		local town = input.stops[i]
		local prev = plan.stations[i - 1]
		if job.finder == nil then
			if prev ~= nil then
				-- Keep the next site off the earlier platforms.
				takePlatforms(input, prev, job.taken)
			end
			job.finder = stations.startFind(input.grid, town.pos, stopDir(input.stops, i),
				input.platformLength + 2 * APPROACH, MAX_STATION_RELIEF, MAX_STATION_RADIUS, job.taken, exitFor(job, i))
		end
		if not stations.stepFind(job.finder, SITE_WORK_PER_STEP) then
			return false
		end
		local site, pocketed = job.finder.site, job.finder.pocketed
		job.finder = nil
		if site == nil then
			-- Clear spots there were, but buildings wall every one in: say so, rather than search legs that can't
			-- leave it (and widen the area, which can't help).
			if pocketed > 0 then
				return fail(job, "no_exit", { town.name })
			end
			return fail(job, "no_site", { town.name })
		end
		if prev ~= nil and not apartEnough(input, prev.site, site) then
			return fail(job, "too_close", { prev.town.name, town.name })
		end
		table.insert(plan.stations, { town = town, site = site, z = grid.heightAt(input.grid, site.centre) })
		job.siteIndex = i + 1
		if job.siteIndex > #input.stops then
			job.phase, job.round, job.scoutIndex, job.scouts = "scout", 1, 1, {}
		end
		return false
	end
	if job.phase == "scout" then
		-- A search between consecutive site centres, free to start and end in any direction, turning as freely as the
		-- Cheapest radius allows: where the line wants to run, whichever way the stations face.
		local i = job.scoutIndex
		if job.search == nil then
			local a, b = plan.stations[i].site.centre, plan.stations[i + 1].site.centre
			local any : Pt = { x = 0, y = 0 }
			local w = input.weights
			job.search = grid.startSearch(input.grid, a, b, any, any, w, w.minSearchRadius or w.minRadius)
			return false
		end
		if not grid.stepSearch(job.search, searchBudget(job.search, maxExpansions)) then
			return false
		end
		-- No scout (no path): the station keeps its direction on that side; the leg's own search reports it.
		job.scouts[i] = grid.path(job.search)
		job.search = nil
		job.scoutIndex = i + 1
		if job.scoutIndex > #plan.stations - 1 then
			job.phase, job.siteIndex = "turn", 1
		end
		return false
	end
	if job.phase == "turn" then
		-- Find station i's site again, facing along the scouted line; keep the old one where that finds nothing, or
		-- nothing that leaves room to the stations either side. The search is stepped like the first one, and the
		-- found site is weighed in a step of its own.
		local i = job.siteIndex
		local station = plan.stations[i]
		if job.turnPending then
			local site, others = job.turnSite, job.others
			job.turnPending, job.turnSite, job.others = false, nil, nil
			local prev, next = plan.stations[i - 1], plan.stations[i + 1]
			-- Nor where buildings cut its room to turn shorter than the first site's, on a side a leg leaves from:
			-- the leg there would have to turn sharply at the approach, in the town.
			local roomy = true
			if site ~= nil then
				local turned : Station = { town = station.town, site = site, z = station.z }
				for __, forward in ipairs({ true, false }) do
					local other = forward and next or prev
					if other ~= nil then
						roomy = roomy and turnRoom(input, turned, forward, others, other)
							>= turnRoom(input, station, forward, others, other) - 1e-6
					end
				end
			end
			if site ~= nil and roomy and (prev == nil or apartEnough(input, prev.site, site))
				and (next == nil or apartEnough(input, site, next.site)) then
				station.site, station.z = site, grid.heightAt(input.grid, site.centre)
			end
			nextTurn(job)
			return false
		end
		if job.finder == nil then
			local dir = scoutDir(job, i)
			if dir == nil then
				nextTurn(job)
				return false
			end
			job.others = {}
			for j, other in ipairs(plan.stations) do
				if j ~= i then
					takePlatforms(input, other, job.others)
				end
			end
			job.finder = stations.startFind(input.grid, station.town.pos, dir, input.platformLength + 2 * APPROACH,
				MAX_STATION_RELIEF, math.min(MAX_STATION_RADIUS, station.site.distance + MAX_TURN_MOVE), job.others,
				exitFor(job, i))
			return false
		end
		if stations.stepFind(job.finder, SITE_WORK_PER_STEP) then
			job.turnSite, job.turnPending, job.finder = job.finder.site, true, nil
		end
		return false
	end
	local a, b = plan.stations[job.legIndex], plan.stations[job.legIndex + 1]
	if job.resite ~= nil then
		stepResite(job, maxExpansions)
		return false
	end
	if job.path ~= nil then
		if job.simplified == nil then
			job.simplified = simplifyLeg(input, a, b, job.path, job.taken, job.footprint)
			return false
		end
		if job.fitted == nil then
			job.fitted = fitLeg(input, job.simplified)
			if job.radii ~= nil then
				-- One of several radii being weighed (time priced): its fitted curves tell what time it loses.
				local t = job.pathCost + input.weights.timeCost * legTimeLost(input, job.fitted)
				if job.best == nil or t < job.bestTotal then
					job.best = { path = job.path, simplified = job.simplified, fitted = job.fitted, radius = job.searchRadius,
						cost = job.pathCost }
					job.bestTotal = t
				end
				job.path, job.simplified, job.fitted = nil, nil, nil
				nextTry(job)
				if job.radii ~= nil then
					return false
				end
			end
			checkLeg(job, a, b)
			return false
		end
		if job.heights == nil then
			job.heights = startHeights(input, a, b, job.fitted)
		end
		if not profile.step(job.heights.fit, PROFILE_WORK_PER_STEP) then
			return false
		end
		local leg = finishLeg(input, job.heights)
		job.simplified, job.fitted, job.heights = nil, nil, nil
		leg.searchRadius, leg.searchExpansions = job.searchRadius, job.searchExpansions
		table.insert(plan.legs, leg)
		job.path = nil
		job.searchRadius, job.searchExpansions = nil, 0
		job.legIndex = job.legIndex + 1
		if job.legIndex > #plan.stations - 1 then
			plan.summary = summarise(input, plan)
			job.phase = "done"
			return true
		end
		return false
	end
	if job.search == nil then
		if job.radii == nil then
			job.radii, job.tryIndex, job.searchExpansions = searchRadii(input.weights), 1, 0
		end
		local radius = job.radii[job.tryIndex]
		-- Each try's ends have room for its own first turn, sized for its own radius: sized for the mode's (597 m at
		-- 3 km), the ends of a leg of a kilometre or two sat so close together, or so far into the next obstacle,
		-- that no wider radius found a way (Alliance → Aloha, Fastest: every leg fell back).
		local aExtension, aRoom = legEnd(input, a, true, job.taken, b, radius)
		local bExtension, bRoom = legEnd(input, b, false, job.taken, a, radius)
		-- After the first try, only a path that could beat the best so far will do: priced with the time it loses, one
		-- costing less than the best's total (no path loses less than nothing); otherwise one within reach of the
		-- fallback's cost.
		local maxCost : number = nil
		if job.tryIndex > 1 then
			if timePriced(input.weights) then
				maxCost = job.bestTotal
			else
				maxCost = job.fallbackCost * (1 + MAX_RADIUS_EXTRA)
			end
		end
		-- Where turns are spaced, the lattice of reachable cells and headings is coarse, and a path rarely meets one
		-- exact start and goal: let it leave a's axis, and join b's, anywhere along a run beyond the extension points
		-- (the stations' straights just get longer), up to MAX_END_RUN and never past half way.
		local run : number = nil
		if 2 * radius * math.tan(math.pi / 16) > input.grid.cell + 1e-6 then
			run = math.min(MAX_END_RUN, geo.dist(aExtension, bExtension) / 2)
		end
		job.search = searchFor(job, aExtension, bExtension, a.site.dir, b.site.dir, radius, maxCost, run, aRoom, bRoom,
			job.footprint)
		return false
	end
	if not grid.stepSearch(job.search, searchBudget(job.search, maxExpansions)) then
		return false
	end
	-- The leg is built on the next step, so no step does both.
	local search = job.search
	local path = grid.path(search)
	job.search = nil
	keepSearch(job, search)
	job.searchExpansions = job.searchExpansions + search.expansions
	local function accept(p : {Pt}, radius : number, cost : number)
		job.path, job.searchRadius, job.pathCost = p, radius, cost
		job.radii, job.fallback = nil, nil
	end
	local weighing = timePriced(input.weights) and #job.radii > 1
	if weighing then
		-- Every radius is tried, and each path found is built (simplified and filleted, on the next steps) and weighed
		-- by its cost and the time its curves lose; the least total is taken (see the fitted step).
		if path ~= nil then
			job.path, job.searchRadius, job.pathCost = path, job.radii[job.tryIndex], search.cost[0]
		elseif job.tryIndex == 1 then
			job.radii = nil
			if search.enclosed then
				return fail(job, "no_exit", { a.town.name })
			end
			return fail(job, "no_path", { a.town.name, b.town.name })
		else
			nextTry(job)
			if job.radii == nil then
				-- The last radius found nothing: the best so far is built already; it still has its curves checked.
				checkLeg(job, a, b)
			end
		end
		return false
	end
	if job.tryIndex == 1 then
		if path == nil then
			-- The fallback radius turns most freely: no wider one finds a way either.
			job.radii = nil
			if search.enclosed then
				-- Walled in inside the area (past what the site check looks at): a wider area can't help.
				return fail(job, "no_exit", { a.town.name })
			end
			return fail(job, "no_path", { a.town.name, b.town.name })
		end
		if #job.radii == 1 then
			accept(path, job.radii[1], search.cost[0])
		else
			job.fallback, job.fallbackCost, job.tryIndex = path, search.cost[0], 2
		end
	elseif path ~= nil then
		accept(path, job.radii[job.tryIndex], search.cost[0])
	elseif job.tryIndex < #job.radii then
		job.tryIndex = job.tryIndex + 1
	else
		accept(job.fallback, job.radii[1], job.fallbackCost)
	end
	return false
end

function route.stepKind(job : Job) : string
	if job.phase ~= "legs" then
		return job.phase
	end
	if job.resite ~= nil then
		return "resite"
	end
	if job.path ~= nil then
		if job.simplified == nil then
			return "simplify"
		elseif job.fitted == nil then
			return "fit"
		end
		return "heights"
	end
	return "search"
end

function route.progress(job : Job) : number
	if job.phase == "done" then
		return 1
	end
	local n = #job.input.stops
	-- Per round: a scout per leg, and turning each station (one unit each).
	local round = SCOUT_WEIGHT * (n - 1) + n
	local scouting = n + SCOUT_ROUNDS * round
	local total = scouting + LEG_WEIGHT * math.max(1, n - 1)
	local done : number = job.siteIndex - 1
	if job.phase == "scout" then
		done = n + (job.round - 1) * round + SCOUT_WEIGHT * (job.scoutIndex - 1)
		if job.search ~= nil then
			done = done + SCOUT_WEIGHT * grid.progress(job.search)
		end
	elseif job.phase == "turn" then
		done = n + (job.round - 1) * round + SCOUT_WEIGHT * (n - 1) + job.siteIndex - 1
	elseif job.phase == "legs" then
		done = scouting + LEG_WEIGHT * (job.legIndex - 1)
		-- Each of the leg's tries has an equal share of its search; one that succeeds takes the rest.
		local tries = job.radii ~= nil and #job.radii or 1
		local tried = job.radii ~= nil and job.tryIndex - 1 or 0
		if job.search ~= nil then
			done = done + LEG_WEIGHT * SEARCH_SHARE * (tried + grid.progress(job.search)) / tries
		elseif job.path ~= nil and job.radii ~= nil then
			-- A try being built to be weighed.
			done = done + LEG_WEIGHT * SEARCH_SHARE * (tried + 1) / tries
		elseif job.path ~= nil then
			done = done + LEG_WEIGHT * SEARCH_SHARE
		else
			done = done + LEG_WEIGHT * SEARCH_SHARE * tried / tries
		end
	end
	-- Re-siting a station builds legs again (the one before it too, where it is the one the leg leaves from): the
	-- share shown holds where it was until the work catches up, rather than fall back.
	job.shown = math.max(job.shown or 0, math.min(1, done / total))
	return job.shown
end

function route.plan(job : Job) : Plan
	return job.result
end

return route
