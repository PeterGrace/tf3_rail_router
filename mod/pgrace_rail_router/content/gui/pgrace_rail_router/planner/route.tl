local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo
local grid = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/grid.tl" as PgraceRailRouterGrid
local stations = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/stations.tl" as PgraceRailRouterStations
local smooth = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/smooth.tl" as PgraceRailRouterSmooth
local profile = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/profile.tl" as PgraceRailRouterProfile

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

-- Straight track before and after each platform, so trains run in line with it (metres).
local APPROACH = 100.0
-- Most height change a station's run may have (metres).
local MAX_STATION_RELIEF = 10.0
-- How far from a town's centre to look for room for its station (metres).
local MAX_STATION_RADIUS = 1500.0
-- Work a station's site search does per step (see stations.stepFind; about 1 µs a unit on desktop Lua, 0.6 ms at
-- most for 500 even on steep ground). A whole search, in one step, took up to 41 ms in-game in a big town.
local SITE_WORK_PER_STEP = 500
-- Spacing of the height samples along the track (metres).
local SAMPLE_STEP = 25.0
-- Grid paths are simplified to within this share of a cell before the curves are fitted.
local SIMPLIFY_SHARE = 0.75
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

-- The minimum straight between turns for the full radius (grid.startSearch): 2 · minRadius · tan(11.25°).
local function minStraight(input : Input) : number
	return 2 * input.weights.minRadius * math.tan(math.pi / 16)
end

-- The room to turn beyond a station's approach: for the first turn the leg's search may make there, at full radius.
-- Where the search turns freely (its minimum straight within a cell) that may be anything up to 90°, so room for a
-- 45° turn (minRadius × tan 22.5°); otherwise it is one 22.5° step, so minRadius × tan 11.25°. The longer room cost
-- Fastest dear on the captures: with stations facing the line, 1.24 km straights at R = 3000 m pushed the legs'
-- ends past their turns, into a ridge (a 300 m tunnel) and loops (estimate 23.2–23.5 M against 19.6 M).
local function extensionLength(input : Input) : number
	local r = input.weights.minRadius
	if minStraight(input) <= input.grid.cell + 1e-6 then
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
		other : Station) : Pt, Pt, Pt
	local g = input.grid
	local sign = forward and 1 or -1
	local half = input.platformLength / 2
	local c, d = station.site.centre, station.site.dir
	local platformEnd = geo.add(c, geo.scale(d, sign * half))
	local approach = geo.add(c, geo.scale(d, sign * (half + APPROACH)))
	local own = platformCells(input, station)
	local ext = extensionLength(input)
	if other ~= nil then
		local ahead = sign * geo.dot(geo.sub(other.site.centre, c), d)
		ext = math.min(ext, (ahead - 2 * (half + APPROACH)) / 4)
	end
	while ext > 0 do
		local extension = geo.add(c, geo.scale(d, sign * (half + APPROACH + ext)))
		if straightClear(input, approach, extension, taken, own) then
			return platformEnd, approach, extension
		end
		ext = ext - g.cell / 2
	end
	return platformEnd, approach, approach
end

-- How far a station's room to turn reaches beyond its approach, on one side (metres; see stationEnds).
local function turnRoom(input : Input, station : Station, forward : boolean, taken : {integer : boolean},
		other : Station) : number
	local __, approach, extension = stationEnds(input, station, forward, taken, other)
	return geo.dist(approach, extension)
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

-- Expansions for one step of a search. With turns spaced for a wide radius, an expansion walks a whole straight (up
-- to a dozen cells), so a step gets proportionally fewer: in-game a 150-expansion step at 3 km took 16–21 ms.
local function searchBudget(search : PgraceRailRouterGrid.Search, maxExpansions : integer) : integer
	local longest = 1
	for __, steps in ipairs(search.straightSteps) do
		longest = math.max(longest, steps)
	end
	return math.max(1, math.floor(maxExpansions / longest))
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
local function pathGuard(g : Grid, path : {Pt}) : function(p : Pt, from : integer, to : integer) : boolean
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
		taken : {integer : boolean}) : PgraceRailRouterRoute.Simplified
	local g, w = input.grid, input.weights
	local aEnd, aApproach = stationEnds(input, a, true, taken, b)
	local bEnd, bApproach = stationEnds(input, b, false, taken, a)
	-- Simplifying and filleting are guarded, so the track keeps to the ground the path chose (off water, hillsides
	-- and buildings it went round), checked every quarter cell.
	local clear = pathGuard(g, path)
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
	-- freeA and freeB give up a's or b's extension point: fillet may then drop it like any other.
	local function fit(freeA : boolean, freeB : boolean) : PgraceRailRouterSmooth.Result
		local fixed : {boolean} = {}
		fixed[2], fixed[3], fixed[#pts - 2], fixed[#pts - 1] = true, not freeA, not freeB, true
		return smooth.fillet(pts, w.minRadius, fixed, guard)
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
	local fitted = fit(false, false)
	-- Where the fixed points squeeze an arc below what can be built (an extension pulled back short of a sharp turn),
	-- give up that end's extension: the turn then starts at the approach, or the point after the extension, with
	-- more room. An end that still can't reach the floor keeps its extension (and its tight arc, counted below).
	local tightA, tightB = belowFloor(fitted)
	if tightA or tightB then
		local refit = fit(tightA, tightB)
		local stillA, stillB = belowFloor(refit)
		local freeA, freeB = tightA and not stillA, tightB and not stillB
		if freeA == tightA and freeB == tightB then
			fitted = refit
		elseif freeA or freeB then
			fitted = fit(freeA, freeB)
		end
	end
	return fitted
end

local function finishLeg(input : Input, a : Station, b : Station, fitted : PgraceRailRouterSmooth.Result) : Leg
	local g, w = input.grid, input.weights
	local tight = 0
	for __, piece in ipairs(fitted.pieces) do
		if piece.kind == "arc" and piece.radius < w.minRadius - 1e-6 then
			tight = tight + 1
		end
	end
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
	local fit = profile.fit(s, ground, water, w.maxGrade, w.bridgeAbove, w.tunnelBelow, a.z, b.z, crossing)
	local length = 0.0
	if #s > 0 then
		length = s[#s]
	end
	return { pieces = fitted.pieces, samples = samples, z = fit.z, spans = fit.spans, length = length,
		minRadius = fitted.minRadius, maxGrade = fit.maxGrade, tightCurves = tight, steepEnds = not fit.feasible,
		blockedSamples = blockedSamples, guarded = fitted.guarded }
end

local function summarise(input : Input, plan : Plan) : Summary
	local w = input.weights
	local sum : Summary = { length = 0, bridges = 0, bridgeLength = 0, tunnels = 0, tunnelLength = 0, maxGrade = 0,
		minRadius = math.huge, estimate = 0, tightCurves = 0, steepLegs = 0, blockedSamples = 0, guarded = 0 }
	for __, leg in ipairs(plan.legs) do
		sum.length = sum.length + leg.length
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

function route.start(input : Input) : Job
	local job : Job = { input = input, phase = "sites", siteIndex = 1, legIndex = 1, taken = {}, searchExpansions = 0,
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
				input.platformLength + 2 * APPROACH, MAX_STATION_RELIEF, MAX_STATION_RADIUS, job.taken)
		end
		if not stations.stepFind(job.finder, SITE_WORK_PER_STEP) then
			return false
		end
		local site = job.finder.site
		job.finder = nil
		if site == nil then
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
		-- nothing that leaves room to the stations either side.
		local i = job.siteIndex
		local station = plan.stations[i]
		if job.finder == nil then
			local dir = scoutDir(job, i)
			if dir ~= nil then
				job.others = {}
				for j, other in ipairs(plan.stations) do
					if j ~= i then
						takePlatforms(input, other, job.others)
					end
				end
				job.finder = stations.startFind(input.grid, station.town.pos, dir, input.platformLength + 2 * APPROACH,
					MAX_STATION_RELIEF, math.min(MAX_STATION_RADIUS, station.site.distance + MAX_TURN_MOVE), job.others)
			end
		end
		if job.finder ~= nil then
			if not stations.stepFind(job.finder, SITE_WORK_PER_STEP) then
				return false
			end
			local site, others = job.finder.site, job.others
			job.finder, job.others = nil, nil
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
		end
		job.siteIndex = i + 1
		if job.siteIndex > #plan.stations then
			if job.round < SCOUT_ROUNDS then
				job.phase, job.round, job.scoutIndex, job.scouts = "scout", job.round + 1, 1, {}
			else
				-- The legs keep off every platform (each station's ends less its own).
				job.taken = {}
				for __, other in ipairs(plan.stations) do
					takePlatforms(input, other, job.taken)
				end
				job.phase = "legs"
			end
		end
		return false
	end
	local a, b = plan.stations[job.legIndex], plan.stations[job.legIndex + 1]
	if job.path ~= nil then
		if job.simplified == nil then
			job.simplified = simplifyLeg(input, a, b, job.path, job.taken)
			return false
		end
		if job.fitted == nil then
			job.fitted = fitLeg(input, job.simplified)
			return false
		end
		local leg = finishLeg(input, a, b, job.fitted)
		job.simplified, job.fitted = nil, nil
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
		local aExtension = select(3, stationEnds(input, a, true, job.taken, b))
		local bExtension = select(3, stationEnds(input, b, false, job.taken, a))
		if job.radii == nil then
			job.radii, job.tryIndex, job.searchExpansions = searchRadii(input.weights), 1, 0
		end
		-- After the first try, only a path within reach of the fallback's cost will do.
		local maxCost : number = nil
		if job.tryIndex > 1 then
			maxCost = job.fallbackCost * (1 + MAX_RADIUS_EXTRA)
		end
		-- Where turns are spaced, the lattice of reachable cells and headings is coarse, and a path rarely meets one
		-- exact start and goal: let it leave a's axis, and join b's, anywhere along a run beyond the extension points
		-- (the stations' straights just get longer), up to MAX_END_RUN and never past half way.
		local radius = job.radii[job.tryIndex]
		local run : number = nil
		if 2 * radius * math.tan(math.pi / 16) > input.grid.cell + 1e-6 then
			run = math.min(MAX_END_RUN, geo.dist(aExtension, bExtension) / 2)
		end
		job.search = grid.startSearch(input.grid, aExtension, bExtension, a.site.dir, b.site.dir, input.weights,
			radius, maxCost, run, run)
		return false
	end
	if not grid.stepSearch(job.search, searchBudget(job.search, maxExpansions)) then
		return false
	end
	-- The leg is built on the next step, so no step does both.
	local search = job.search
	local path = grid.path(search)
	job.search = nil
	job.searchExpansions = job.searchExpansions + search.expansions
	local function accept(p : {Pt}, radius : number)
		job.path, job.searchRadius = p, radius
		job.radii, job.fallback = nil, nil
	end
	if job.tryIndex == 1 then
		if path == nil then
			-- The fallback radius turns most freely: no wider one finds a way either.
			job.radii = nil
			return fail(job, "no_path", { a.town.name, b.town.name })
		end
		if #job.radii == 1 then
			accept(path, job.radii[1])
		else
			job.fallback, job.fallbackCost, job.tryIndex = path, search.cost[0], 2
		end
	elseif path ~= nil then
		accept(path, job.radii[job.tryIndex])
	elseif job.tryIndex < #job.radii then
		job.tryIndex = job.tryIndex + 1
	else
		accept(job.fallback, job.radii[1])
	end
	return false
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
		elseif job.path ~= nil then
			done = done + LEG_WEIGHT * SEARCH_SHARE
		else
			done = done + LEG_WEIGHT * SEARCH_SHARE * tried / tries
		end
	end
	return math.min(1, done / total)
end

function route.plan(job : Job) : Plan
	return job.result
end

return route
