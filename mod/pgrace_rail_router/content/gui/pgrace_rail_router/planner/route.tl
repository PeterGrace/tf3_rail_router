local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo
local grid = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/grid.tl" as PgraceRailRouterGrid
local stations = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/stations.tl" as PgraceRailRouterStations
local smooth = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/smooth.tl" as PgraceRailRouterSmooth
local profile = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/profile.tl" as PgraceRailRouterProfile

local route : PgraceRailRouterRoute = {}

local type Pt = PgraceRailRouterGeo.Pt
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
-- Spacing of the height samples along the track (metres).
local SAMPLE_STEP = 25.0
-- Grid paths are simplified to within this share of a cell before the curves are fitted.
local SIMPLIFY_SHARE = 0.75
-- For progress: a station site counts as 1 unit of work, a leg as this many.
local LEG_WEIGHT = 10
-- Share of a leg's work that is its search; building it is the rest.
local SEARCH_SHARE = 0.99

-- The direction of travel at stop i: from the previous stop towards the next.
local function stopDir(stops : {Town}, i : integer) : Pt
	local prev = stops[i - 1] or stops[i]
	local next = stops[i + 1] or stops[i]
	return geo.norm(geo.sub(next.pos, prev.pos))
end

-- Where a station's platforms end, where its straight approach ends, and where the room to turn beyond it ends
-- (minRadius × tan 22.5°: a 45° turn at full radius), on its leaving side (forward = true) or its arriving side.
-- The leg's search starts or ends at the last, so it is pulled back (half a cell at a time, at most to the
-- approach point) while it lies outside the grid or on a blocked cell.
local function stationEnds(input : Input, station : Station, forward : boolean) : Pt, Pt, Pt
	local g = input.grid
	local sign = forward and 1 or -1
	local half = input.platformLength / 2
	local c, d = station.site.centre, station.site.dir
	local platformEnd = geo.add(c, geo.scale(d, sign * half))
	local approach = geo.add(c, geo.scale(d, sign * (half + APPROACH)))
	local ext = input.weights.minRadius * math.tan(math.pi / 8)
	while ext > 0 do
		local extension = geo.add(c, geo.scale(d, sign * (half + APPROACH + ext)))
		if grid.inside(g, extension) then
			local ix, iy = grid.cellOf(g, extension)
			if not g.blocked[grid.index(g, ix, iy)] then
				return platformEnd, approach, extension
			end
		end
		ext = ext - g.cell / 2
	end
	return platformEnd, approach, approach
end

-- Adds a station's platform cells (by grid index) to `taken`, so later sites keep off them.
local function takePlatforms(input : Input, station : Station, taken : {integer : boolean})
	local g = input.grid
	local half = input.platformLength / 2
	local c, dir = station.site.centre, station.site.dir
	local d = -half
	while d <= half + 1e-6 do
		local ix, iy = grid.cellOf(g, geo.add(c, geo.scale(dir, d)))
		taken[grid.index(g, ix, iy)] = true
		d = d + g.cell / 2
	end
end

local function fail(job : Job, failure : string, towns : {string}) : boolean
	job.result.ok = false
	job.result.failure = failure
	job.result.failureTowns = towns
	job.phase = "done"
	return true
end

local function buildLeg(input : Input, a : Station, b : Station, path : {Pt}) : Leg
	local g, w = input.grid, input.weights
	local aEnd, aApproach = stationEnds(input, a, true)
	local bEnd, bApproach = stationEnds(input, b, false)
	-- path runs from a's extension point to b's; add the platform ends and approach points, and keep all of them
	-- fixed so the line leaves and enters the platforms straight and has room to turn at full radius beyond.
	-- (Where an extension point is its approach point, fillet merges the two.)
	local middle = smooth.simplify(path, g.cell * SIMPLIFY_SHARE)
	local pts : {Pt} = { aEnd, aApproach }
	for __, p in ipairs(middle) do
		table.insert(pts, p)
	end
	table.insert(pts, bApproach)
	table.insert(pts, bEnd)
	local fixed : {boolean} = {}
	fixed[2], fixed[3], fixed[#pts - 2], fixed[#pts - 1] = true, true, true, true
	local fitted = smooth.fillet(pts, w.minRadius, fixed)
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
	local blockedSamples = 0
	for i, sample in ipairs(samples) do
		s[i] = sample.s
		ground[i] = grid.heightAt(g, sample.p)
		water[i] = grid.waterAt(g, sample.p)
		local ix, iy = grid.cellOf(g, sample.p)
		local cell = grid.index(g, ix, iy)
		if g.blocked[cell] or g.track[cell] then
			blockedSamples = blockedSamples + 1
		end
	end
	local fit = profile.fit(s, ground, water, w.maxGrade, w.bridgeAbove, w.tunnelBelow, a.z, b.z)
	local length = 0.0
	if #s > 0 then
		length = s[#s]
	end
	return { pieces = fitted.pieces, samples = samples, z = fit.z, spans = fit.spans, length = length,
		minRadius = fitted.minRadius, maxGrade = fit.maxGrade, tightCurves = tight, steepEnds = not fit.feasible,
		blockedSamples = blockedSamples }
end

local function summarise(input : Input, plan : Plan) : Summary
	local w = input.weights
	local sum : Summary = { length = 0, bridges = 0, bridgeLength = 0, tunnels = 0, tunnelLength = 0, maxGrade = 0,
		minRadius = math.huge, estimate = 0, tightCurves = 0, steepLegs = 0, blockedSamples = 0 }
	for __, leg in ipairs(plan.legs) do
		sum.length = sum.length + leg.length
		sum.tightCurves = sum.tightCurves + leg.tightCurves
		sum.blockedSamples = sum.blockedSamples + leg.blockedSamples
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
	local job : Job = { input = input, phase = "sites", siteIndex = 1, legIndex = 1, taken = {},
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
		if prev ~= nil then
			-- Keep the next site off the earlier platforms.
			takePlatforms(input, prev, job.taken)
		end
		local site = stations.find(input.grid, town.pos, stopDir(input.stops, i),
			input.platformLength + 2 * APPROACH, MAX_STATION_RELIEF, MAX_STATION_RADIUS, job.taken)
		if site == nil then
			return fail(job, "no_site", { town.name })
		end
		if prev ~= nil then
			local apart = geo.sub(site.centre, prev.site.centre)
			if geo.len(apart) < input.platformLength + 2 * APPROACH or geo.dot(apart, prev.site.dir) <= 0
				or geo.dot(apart, site.dir) <= 0 then
				return fail(job, "too_close", { prev.town.name, town.name })
			end
		end
		table.insert(plan.stations, { town = town, site = site, z = grid.heightAt(input.grid, site.centre) })
		job.siteIndex = i + 1
		if job.siteIndex > #input.stops then
			job.phase = "legs"
		end
		return false
	end
	local a, b = plan.stations[job.legIndex], plan.stations[job.legIndex + 1]
	if job.path ~= nil then
		table.insert(plan.legs, buildLeg(input, a, b, job.path))
		job.path = nil
		job.legIndex = job.legIndex + 1
		if job.legIndex > #plan.stations - 1 then
			plan.summary = summarise(input, plan)
			job.phase = "done"
			return true
		end
		return false
	end
	if job.search == nil then
		local aExtension = select(3, stationEnds(input, a, true))
		local bExtension = select(3, stationEnds(input, b, false))
		job.search = grid.startSearch(input.grid, aExtension, bExtension, a.site.dir, b.site.dir, input.weights)
		return false
	end
	if not grid.stepSearch(job.search, maxExpansions) then
		return false
	end
	-- The leg is built on the next step, so no step does both.
	job.path = grid.path(job.search)
	job.search = nil
	if job.path == nil then
		return fail(job, "no_path", { a.town.name, b.town.name })
	end
	return false
end

function route.progress(job : Job) : number
	if job.phase == "done" then
		return 1
	end
	local n = #job.input.stops
	local total = n + LEG_WEIGHT * math.max(1, n - 1)
	local done : number = job.siteIndex - 1
	if job.phase == "legs" then
		done = n + LEG_WEIGHT * (job.legIndex - 1)
		if job.search ~= nil then
			done = done + LEG_WEIGHT * SEARCH_SHARE * grid.progress(job.search)
		elseif job.path ~= nil then
			done = done + LEG_WEIGHT * SEARCH_SHARE
		end
	end
	return math.min(1, done / total)
end

function route.plan(job : Job) : Plan
	return job.result
end

return route
