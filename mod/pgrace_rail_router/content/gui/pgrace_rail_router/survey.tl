local grid = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/grid.tl" as PgraceRailRouterGrid
local modes = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/modes.tl" as PgraceRailRouterModes
local area = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/area.tl" as PgraceRailRouterArea

local survey : PgraceRailRouterSurvey = {}

local type Town = PgraceRailRouterCorridor.Town
local type TrackType = PgraceRailRouterModes.TrackType
local type Grid = PgraceRailRouterGrid.Grid
local type Job = PgraceRailRouterSurvey.Job

local LOG_PREFIX = "[rail_router] "
-- Cells within this distance of a building or other construction are blocked (metres).
local BUILDING_BUFFER = area.BUILDING_BUFFER
-- Buildings and edges are looked up in tiles this wide, one tile per task: a single city-wide lookup took 60 ms in
-- Jam Session.
local TILE = 1000.0

local logged : {string : boolean} = {}
local function logOnce(key : string, message : string)
	if not logged[key] then
		logged[key] = true
		debugPrint(LOG_PREFIX .. message)
	end
end

local function boundingBox(entity : Engine.Entity) : Engine.Component.BoundingVolume
	return api.engine.getComponent(entity, api.type.ComponentType.BOUNDING_VOLUME) as Engine.Component.BoundingVolume
end

function survey.towns() : {Town}
	local result : {Town} = {}
	local noBox = 0
	api.engine.forEachEntityWithComponent(function(town : Engine.Entity)
		local ok, err = pcall(function() : boolean
			local bv = boundingBox(town)
			if bv ~= nil then
				table.insert(result, { id = town, name = api.engine.util.getEntityName(town),
					pos = { x = 0.5 * (bv.bbox.min.x + bv.bbox.max.x), y = 0.5 * (bv.bbox.min.y + bv.bbox.max.y) } })
			else
				noBox = noBox + 1
			end
			return true
		end)
		if not ok then
			logOnce("town", "town " .. tostring(town) .. ": " .. tostring(err))
		end
	end, api.type.ComponentType.TOWN)
	table.sort(result, function(a : Town, b : Town) : boolean
		return a.name < b.name
	end)
	debugPrint(LOG_PREFIX .. "towns: " .. #result .. " (" .. noBox .. " without a box)")
	return result
end

-- A resource name reduced to its file's base name ("::/infrastructure/track/standard/standard.street_template" and
-- "track/standard.lua" both give "standard"), for matching names written in different forms.
local function baseName(name : string) : string
	local last = name:match("([^/\\:]+)$") or name
	return last:match("^([^%.]+)") or last
end

local function nonEmpty(s : string) : boolean
	return s ~= nil and s ~= ""
end

function survey.trackTypes() : {TrackType}
	local result : {TrackType} = {}
	local rep = api.res.streetTemplateRep
	local trackRoad = api.type["enum"].RoadType.TRACK
	-- First pass: the track templates, and the catenary variants they name.
	local tracks : {integer : StreetTemplate} = {}
	local names : {integer : string} = {}
	local catenaryIds : {integer : boolean} = {}
	local catenaryBases : {string : boolean} = {}
	-- Track template ids by base name, to find a catenaryAdd that rep.find doesn't know in that form.
	local idByBase : {string : integer} = {}
	local anyCatenaryAdd = false
	for id, name in pairs(rep.getAll()) do
		local ok, err = pcall(function() : boolean
			local tpl = rep.get(id)
			if tpl ~= nil and tpl.roadType == trackRoad then
				tracks[id] = tpl
				names[id] = name
				idByBase[baseName(name)] = id
				if nonEmpty(tpl.catenaryAdd) then
					anyCatenaryAdd = true
					local found = rep.find(tpl.catenaryAdd)
					if found ~= nil and found >= 0 then
						catenaryIds[found] = true
					end
					catenaryBases[baseName(tpl.catenaryAdd)] = true
				end
			end
			return true
		end)
		if not ok then
			logOnce("track", "track type " .. tostring(name) .. ": " .. tostring(err))
		end
	end
	-- Second pass: keep the base types. A template is a catenary variant when another one names it as its
	-- catenaryAdd (by id, or by base name if find doesn't know the name's form), or when it has a catenaryRemove.
	-- Without any catenaryAdd at all, fall back on the name.
	local dropped = 0
	local hidden = 0
	for id, tpl in pairs(tracks) do
		local name = names[id]
		local ok, err = pcall(function() : boolean
			local isCatenary : boolean
			if anyCatenaryAdd then
				isCatenary = catenaryIds[id] or catenaryBases[baseName(name)] or nonEmpty(tpl.catenaryRemove)
			else
				isCatenary = nonEmpty(tpl.catenaryRemove) or name:find("catenary", 1, true) ~= nil
			end
			if isCatenary then
				dropped = dropped + 1
				return true
			end
			local yearFrom, yearTo = 0, 0
			if tpl.availability ~= nil then
				yearFrom, yearTo = tpl.availability.yearFrom, tpl.availability.yearTo
			end
			if not modes.isEverBuildable({ name = name, yearFrom = yearFrom, yearTo = yearTo } as TrackType) then
				hidden = hidden + 1
				return true
			end
			local speed = 0.0
			for __, lane in ipairs(tpl.laneConfigs) do
				speed = math.max(speed, lane.speed)
			end
			local label = name
			if tpl.description ~= nil and nonEmpty(tpl.description.name) then
				label = tpl.description.name
			end
			local catenary : string = nil
			local catenaryYearFrom = 0
			if nonEmpty(tpl.catenaryAdd) then
				catenary = tpl.catenaryAdd
				local found = rep.find(catenary)
				local variant : StreetTemplate = nil
				if found ~= nil and found >= 0 then
					variant = tracks[found]
				end
				if variant == nil and idByBase[baseName(catenary)] ~= nil then
					variant = tracks[idByBase[baseName(catenary)]]
				end
				if variant ~= nil and variant.availability ~= nil then
					catenaryYearFrom = variant.availability.yearFrom
				end
			end
			table.insert(result, { name = name, label = label, cost = tpl.cost, speed = speed,
				maxSlopeBuild = tpl.maxSlopeBuild, minCurveRadiusBuild = tpl.minCurveRadiusBuild,
				trackDistance = tpl.trackDistance, yearFrom = yearFrom, yearTo = yearTo, catenary = catenary,
				catenaryYearFrom = catenaryYearFrom })
			debugPrint(LOG_PREFIX .. "track type " .. name .. ": label " .. tostring(label) .. ", speed "
				.. tostring(speed) .. ", cost " .. tostring(tpl.cost) .. ", maxSlopeBuild " .. tostring(tpl.maxSlopeBuild)
				.. ", minCurveRadiusBuild " .. tostring(tpl.minCurveRadiusBuild) .. ", years " .. tostring(yearFrom)
				.. "–" .. tostring(yearTo) .. ", catenary " .. tostring(catenary) .. " from "
				.. tostring(catenaryYearFrom))
			return true
		end)
		if not ok then
			logOnce("track", "track type " .. tostring(name) .. ": " .. tostring(err))
		end
	end
	local how = "by catenaryAdd"
	if not anyCatenaryAdd then
		how = "by name (no template has a catenaryAdd)"
	end
	debugPrint(LOG_PREFIX .. "track types: " .. #result .. " kept, " .. dropped .. " catenary variants dropped " .. how
		.. ", " .. hidden .. " never buildable (depot, industry or station tracks)")
	table.sort(result, function(a : TrackType, b : TrackType) : boolean
		return a.speed < b.speed
	end)
	return result
end

function survey.year() : integer
	local ok, result = pcall(function() : integer
		return api.engine.util.getYear()
	end)
	if not ok then
		logOnce("year", "year: " .. tostring(result))
		return 0
	end
	return result as integer
end

local function surveyRow(job : Job, iy : integer)
	local g = job.grid
	local terrain = api.engine.terrain
	for ix = 1, g.nx do
		local c = grid.centre(g, ix, iy)
		local v = api.type.Vec2f.new(c.x, c.y)
		local i = grid.index(g, ix, iy)
		if not terrain.isValidCoordinate(v) then
			g.blocked[i] = true
			job.invalidCells = job.invalidCells + 1
		else
			g.height[i] = terrain.getHeightAt(v)
			g.water[i] = terrain.isOnWater(v)
		end
	end
end

local function markConstruction(job : Job, entity : Engine.Entity)
	local bv = boundingBox(entity)
	if bv == nil then
		-- Town buildings may have no box of their own: use their construction's.
		local tb = api.engine.getComponent(entity, api.type.ComponentType.TOWN_BUILDING) as Engine.Component.TownBuilding
		if tb ~= nil and tb.construction ~= nil and tb.construction >= 0 and api.engine.entityExists(tb.construction) then
			bv = boundingBox(tb.construction)
		end
	end
	if bv ~= nil then
		area.markBox(job.grid, bv.bbox.min.x - BUILDING_BUFFER, bv.bbox.min.y - BUILDING_BUFFER,
			bv.bbox.max.x + BUILDING_BUFFER, bv.bbox.max.y + BUILDING_BUFFER, job.grid.blocked)
	else
		job.noBox = job.noBox + 1
	end
end

local function isZero(v : Vec3f) : boolean
	return v.x == 0 and v.y == 0 and v.z == 0
end

local function markEdge(job : Job, entity : Engine.Entity)
	local edge = api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
	if edge == nil then
		return
	end
	job.edges = job.edges + 1
	if edge.type == api.type["enum"].BaseEdgeType.TUNNEL then
		job.tunnelsSkipped = job.tunnelsSkipped + 1
		return
	end
	local street = api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE_STREET) as Engine.Component.BaseEdgeStreet
	local cells = job.grid.track
	if street ~= nil then
		cells = job.grid.road
		job.streetEdges = job.streetEdges + 1
	else
		job.trackEdges = job.trackEdges + 1
	end
	-- These fields are unverified on a live component: a read that throws falls back to the nodes.
	local p0, p1, t0, t1 : Vec3f, Vec3f, Vec3f, Vec3f = nil, nil, nil, nil
	local read = pcall(function() : boolean
		p0, p1, t0, t1 = edge.position0, edge.position1, edge.tangent0, edge.tangent1
		return true
	end)
	if read and p0 ~= nil and p1 ~= nil and t0 ~= nil and t1 ~= nil and not (isZero(p0) and isZero(p1)) then
		area.markCurve(job.grid, { x = p0.x, y = p0.y }, { x = t0.x, y = t0.y }, { x = p1.x, y = p1.y },
			{ x = t1.x, y = t1.y }, cells)
		return
	end
	job.curveFallbacks = job.curveFallbacks + 1
	local n0 = api.engine.getComponent(edge.node0, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
	local n1 = api.engine.getComponent(edge.node1, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
	if n0 == nil or n1 == nil then
		return
	end
	area.markLine(job.grid, { x = n0.position.x, y = n0.position.y }, { x = n1.position.x, y = n1.position.y }, cells)
end

local function surveyTile(job : Job, cx : number, cy : number)
	local centre = api.type.Vec2f.new(cx, cy)
	-- Covers the tile's corners (half the diagonal is 0.71 tiles).
	local radius = TILE * 0.75
	local octree = api.engine.util.octree
	for __, kind in ipairs({ api.type.ComponentType.CONSTRUCTION, api.type.ComponentType.TOWN_BUILDING }) do
		for __, entity in ipairs(octree.findEntitiesInCircle(centre, radius, kind)) do
			if not job.seen[entity] then
				job.seen[entity] = true
				if kind == api.type.ComponentType.CONSTRUCTION then
					job.constructions = job.constructions + 1
				else
					job.townBuildings = job.townBuildings + 1
				end
				local ok, err = pcall(function() : boolean
					markConstruction(job, entity)
					return true
				end)
				if not ok then
					job.failures = job.failures + 1
					logOnce("construction", "construction " .. tostring(entity) .. ": " .. tostring(err))
				end
			end
		end
	end
	for __, entity in ipairs(octree.findEntitiesInCircle(centre, radius, api.type.ComponentType.BASE_EDGE)) do
		if not job.seen[entity] then
			job.seen[entity] = true
			local ok, err = pcall(function() : boolean
				markEdge(job, entity)
				return true
			end)
			if not ok then
				job.failures = job.failures + 1
				logOnce("edge", "edge " .. tostring(entity) .. ": " .. tostring(err))
			end
		end
	end
end

function survey.start(stops : {Town}, cell : number, margin : number) : Job
	local box = area.box(stops, cell, margin)
	if box == nil then
		if #stops > 0 then
			logOnce("bounds", "survey: stops have no finite bounds")
		end
		return nil
	end
	local minX, minY, maxX, maxY = box.minX, box.minY, box.maxX, box.maxY
	local nx, ny = box.nx, box.ny
	cell = box.cell
	local job : Job = { grid = grid.new(minX, minY, cell, nx, ny), tasks = {}, next = 1, seen = {}, reported = false,
		constructions = 0, townBuildings = 0, noBox = 0, edges = 0, streetEdges = 0, trackEdges = 0,
		tunnelsSkipped = 0, curveFallbacks = 0, invalidCells = 0, failures = 0, slowestRowUs = 0, slowestTileUs = 0,
		stepCalls = 0, totalUs = 0 }
	for iy = 1, ny do
		table.insert(job.tasks, function()
			local clock = api.type.Clock.new()
			surveyRow(job, iy)
			job.slowestRowUs = math.max(job.slowestRowUs, math.floor(clock:getTime()))
		end)
	end
	-- Tiles run to half a cell past maxX/maxY: after coarsening, the last cells' centres can sit close to the edge.
	local tx = minX
	while tx < maxX + cell / 2 do
		local ty = minY
		while ty < maxY + cell / 2 do
			local cx, cy = tx + TILE / 2, ty + TILE / 2
			table.insert(job.tasks, function()
				local clock = api.type.Clock.new()
				surveyTile(job, cx, cy)
				job.slowestTileUs = math.max(job.slowestTileUs, math.floor(clock:getTime()))
			end)
			ty = ty + TILE
		end
		tx = tx + TILE
	end
	debugPrint(LOG_PREFIX .. "survey: " .. nx .. " × " .. ny .. " cells of " .. cell .. " m, " .. #job.tasks .. " tasks")
	return job
end

local function count(cells : {boolean}, n : integer) : integer
	local result = 0
	for i = 1, n do
		if cells[i] then
			result = result + 1
		end
	end
	return result
end

local function report(job : Job)
	local g = job.grid
	local n = g.nx * g.ny
	debugPrint(LOG_PREFIX .. "survey done: " .. #job.tasks .. " tasks, " .. string.format("%.1f", job.totalUs / 1000)
		.. " ms over " .. job.stepCalls .. " steps, slowest row " .. job.slowestRowUs .. " µs, slowest tile "
		.. job.slowestTileUs .. " µs; constructions " .. job.constructions .. ", town buildings " .. job.townBuildings
		.. ", no box " .. job.noBox .. ", edges " .. job.edges .. " (streets " .. job.streetEdges .. ", track "
		.. job.trackEdges .. ", tunnels skipped " .. job.tunnelsSkipped .. ", straight fallbacks " .. job.curveFallbacks
		.. "), failures " .. job.failures .. "; cells " .. n .. ": blocked " .. count(g.blocked, n) .. ", road "
		.. count(g.road, n) .. ", track " .. count(g.track, n) .. ", water " .. count(g.water, n) .. ", invalid "
		.. job.invalidCells)
end

function survey.step(job : Job, budgetUs : integer) : boolean
	local clock = api.type.Clock.new()
	job.stepCalls = job.stepCalls + 1
	repeat
		if job.next > #job.tasks then
			break
		end
		local task = job.tasks[job.next]
		job.next = job.next + 1
		local ok, err = pcall(function() : boolean
			task()
			return true
		end)
		if not ok then
			job.failures = job.failures + 1
			logOnce("task", "survey task: " .. tostring(err))
		end
	until clock:getTime() >= budgetUs
	job.totalUs = job.totalUs + math.floor(clock:getTime())
	local done = job.next > #job.tasks
	if done and not job.reported then
		job.reported = true
		local ok, err = pcall(function() : boolean
			report(job)
			return true
		end)
		if not ok then
			logOnce("report", "survey report: " .. tostring(err))
		end
	end
	return done
end

function survey.progress(job : Job) : number
	if #job.tasks == 0 then
		return 1
	end
	return (job.next - 1) / #job.tasks
end

function survey.grid(job : Job) : Grid
	return job.grid
end

return survey
