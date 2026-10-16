local grid = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/grid.tl" as PgraceRailRouterGrid

local survey : PgraceRailRouterSurvey = {}

local type Pt = PgraceRailRouterGeo.Pt
local type Town = PgraceRailRouterCorridor.Town
local type TrackType = PgraceRailRouterModes.TrackType
local type Grid = PgraceRailRouterGrid.Grid
local type Job = PgraceRailRouterSurvey.Job

local LOG_PREFIX = "[rail_router] "
-- Cells within this distance of a building or other construction are blocked (metres).
local BUILDING_BUFFER = 30.0
-- At least this much room around the stops (metres).
local MIN_MARGIN = 2000.0
-- Larger grids get coarser cells instead (memory and search time).
local MAX_CELLS = 250000
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
	api.engine.forEachEntityWithComponent(function(town : Engine.Entity)
		local ok, err = pcall(function() : boolean
			local bv = boundingBox(town)
			if bv ~= nil then
				table.insert(result, { id = town, name = api.engine.util.getEntityName(town),
					pos = { x = 0.5 * (bv.bbox.min.x + bv.bbox.max.x), y = 0.5 * (bv.bbox.min.y + bv.bbox.max.y) } })
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
	return result
end

function survey.trackTypes() : {TrackType}
	local result : {TrackType} = {}
	local rep = api.res.streetTemplateRep
	local trackRoad = api.type["enum"].RoadType.TRACK
	for id, name in pairs(rep.getAll()) do
		local ok, err = pcall(function() : boolean
			local tpl = rep.get(id)
			if tpl ~= nil and tpl.roadType == trackRoad and not name:find("catenary", 1, true) then
				local speed = 0.0
				for __, lane in ipairs(tpl.laneConfigs) do
					speed = math.max(speed, lane.speed)
				end
				local label = name
				if tpl.description ~= nil and tpl.description.name ~= nil then
					label = tpl.description.name
				end
				local yearFrom, yearTo = 0, 0
				if tpl.availability ~= nil then
					yearFrom, yearTo = tpl.availability.yearFrom, tpl.availability.yearTo
				end
				table.insert(result, { name = name, label = label, cost = tpl.cost, speed = speed,
					maxSlopeBuild = tpl.maxSlopeBuild, minCurveRadiusBuild = tpl.minCurveRadiusBuild,
					trackDistance = tpl.trackDistance, yearFrom = yearFrom, yearTo = yearTo })
			end
			return true
		end)
		if not ok then
			logOnce("track", "track type " .. tostring(name) .. ": " .. tostring(err))
		end
	end
	table.sort(result, function(a : TrackType, b : TrackType) : boolean
		return a.speed < b.speed
	end)
	return result
end

function survey.year() : integer
	return api.engine.util.getYear()
end

-- Marks the cells whose centres are nearest to the box's corners and everything between (the box is world
-- coordinates). Boxes wholly outside the grid are skipped.
local function markBox(g : Grid, x0 : number, y0 : number, x1 : number, y1 : number, cells : {boolean})
	local half = g.cell / 2
	if x1 < g.x0 - half or y1 < g.y0 - half or x0 > g.x0 + (g.nx - 1) * g.cell + half
			or y0 > g.y0 + (g.ny - 1) * g.cell + half then
		return
	end
	local ax, ay = grid.cellOf(g, { x = x0, y = y0 })
	local bx, by = grid.cellOf(g, { x = x1, y = y1 })
	for iy = ay, by do
		for ix = ax, bx do
			cells[grid.index(g, ix, iy)] = true
		end
	end
end

-- Marks the cells along the straight line from a to b.
local function markLine(g : Grid, a : Pt, b : Pt, cells : {boolean})
	local dx, dy = b.x - a.x, b.y - a.y
	local length = math.sqrt(dx * dx + dy * dy)
	local steps = math.max(1, math.ceil(length / (g.cell / 2)))
	for k = 0, steps do
		local p : Pt = { x = a.x + dx * k / steps, y = a.y + dy * k / steps }
		if grid.inside(g, p) then
			local ix, iy = grid.cellOf(g, p)
			cells[grid.index(g, ix, iy)] = true
		end
	end
end

local function surveyRow(g : Grid, iy : integer)
	local terrain = api.engine.terrain
	for ix = 1, g.nx do
		local c = grid.centre(g, ix, iy)
		local v = api.type.Vec2f.new(c.x, c.y)
		local i = grid.index(g, ix, iy)
		if not terrain.isValidCoordinate(v) then
			g.blocked[i] = true
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
		if tb ~= nil then
			bv = boundingBox(tb.construction)
		end
	end
	if bv ~= nil then
		markBox(job.grid, bv.bbox.min.x - BUILDING_BUFFER, bv.bbox.min.y - BUILDING_BUFFER,
			bv.bbox.max.x + BUILDING_BUFFER, bv.bbox.max.y + BUILDING_BUFFER, job.grid.blocked)
	end
end

local function markEdge(job : Job, entity : Engine.Entity)
	local edge = api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
	if edge == nil or edge.type == api.type["enum"].BaseEdgeType.TUNNEL then
		return
	end
	local n0 = api.engine.getComponent(edge.node0, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
	local n1 = api.engine.getComponent(edge.node1, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
	if n0 == nil or n1 == nil then
		return
	end
	local street = api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE_STREET) as Engine.Component.BaseEdgeStreet
	local cells = job.grid.track
	if street ~= nil then
		cells = job.grid.road
	end
	markLine(job.grid, { x = n0.position.x, y = n0.position.y }, { x = n1.position.x, y = n1.position.y }, cells)
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
				local ok, err = pcall(function() : boolean
					markConstruction(job, entity)
					return true
				end)
				if not ok then
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
				logOnce("edge", "edge " .. tostring(entity) .. ": " .. tostring(err))
			end
		end
	end
end

function survey.start(stops : {Town}, cell : number, margin : number) : Job
	local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
	for __, stop in ipairs(stops) do
		minX, maxX = math.min(minX, stop.pos.x), math.max(maxX, stop.pos.x)
		minY, maxY = math.min(minY, stop.pos.y), math.max(maxY, stop.pos.y)
	end
	local pad = math.max(MIN_MARGIN, margin * math.max(maxX - minX, maxY - minY))
	minX, maxX, minY, maxY = minX - pad, maxX + pad, minY - pad, maxY + pad
	local nx = math.floor((maxX - minX) / cell) + 1
	local ny = math.floor((maxY - minY) / cell) + 1
	while nx * ny > MAX_CELLS do
		cell = cell * 1.25
		nx = math.floor((maxX - minX) / cell) + 1
		ny = math.floor((maxY - minY) / cell) + 1
	end
	local job : Job = { grid = grid.new(minX, minY, cell, nx, ny), tasks = {}, next = 1, seen = {} }
	for iy = 1, ny do
		table.insert(job.tasks, function()
			surveyRow(job.grid, iy)
		end)
	end
	local tx = minX
	while tx < maxX do
		local ty = minY
		while ty < maxY do
			local cx, cy = tx + TILE / 2, ty + TILE / 2
			table.insert(job.tasks, function()
				surveyTile(job, cx, cy)
			end)
			ty = ty + TILE
		end
		tx = tx + TILE
	end
	debugPrint(LOG_PREFIX .. "survey: " .. nx .. " × " .. ny .. " cells of " .. cell .. " m, " .. #job.tasks .. " tasks")
	return job
end

function survey.step(job : Job, budgetUs : integer) : boolean
	local clock = api.type.Clock.new()
	repeat
		if job.next > #job.tasks then
			return true
		end
		local task = job.tasks[job.next]
		job.next = job.next + 1
		local ok, err = pcall(function() : boolean
			task()
			return true
		end)
		if not ok then
			logOnce("task", "survey task: " .. tostring(err))
		end
	until clock:getTime() >= budgetUs
	return job.next > #job.tasks
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
