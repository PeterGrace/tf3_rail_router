local grid = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/grid.tl" as PgraceRailRouterGrid
local modes = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/modes.tl" as PgraceRailRouterModes
local area = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/area.tl" as PgraceRailRouterArea

local survey : PgraceRailRouterSurvey = {}

local type Town = PgraceRailRouterCorridor.Town
local type TrackType = PgraceRailRouterModes.TrackType
local type StructureType = PgraceRailRouterModes.StructureType
local type Grid = PgraceRailRouterGrid.Grid
local type Job = PgraceRailRouterSurvey.Job
local type Bounds = PgraceRailRouterArea.Bounds

local LOG_PREFIX = "[rail_router] "
-- Cells within this distance of a building or other construction are blocked (metres).
local BUILDING_BUFFER = area.BUILDING_BUFFER
-- Buildings and edges are looked up in tiles this wide: a single city-wide lookup took 60 ms in Jam Session, and a
-- 1 km tile's whole work (three lookups and marking what they found) up to 62 ms in-game on a dense 2254 save. At
-- 500 m one lookup returns about a quarter as much; the marking is spread over steps anyway (tileTask).
local TILE = 500.0
-- A terrain tile's side (TERRAIN.size counts these), metres.
local TERRAIN_TILE = 256.0

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
			local catenaryCost : number = nil
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
				if variant ~= nil then
					catenaryCost = variant.cost
				end
			end
			table.insert(result, { name = name, label = label, cost = tpl.cost, speed = speed,
				maxSlopeBuild = tpl.maxSlopeBuild, minCurveRadiusBuild = tpl.minCurveRadiusBuild,
				trackDistance = tpl.trackDistance, yearFrom = yearFrom, yearTo = yearTo, catenary = catenary,
				catenaryYearFrom = catenaryYearFrom, catenaryCost = catenaryCost })
			debugPrint(LOG_PREFIX .. "track type " .. name .. ": label " .. tostring(label) .. ", speed "
				.. tostring(speed) .. ", cost " .. tostring(tpl.cost) .. ", maxSlopeBuild " .. tostring(tpl.maxSlopeBuild)
				.. ", minCurveRadiusBuild " .. tostring(tpl.minCurveRadiusBuild) .. ", years " .. tostring(yearFrom)
				.. "–" .. tostring(yearTo) .. ", catenary " .. tostring(catenary) .. " from "
				.. tostring(catenaryYearFrom) .. ", cost " .. tostring(catenaryCost))
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

-- The bridge ("bridge") or tunnel ("tunnel") types the construction menu lists (menu_category_util.tl
-- getAvailableObjectsSorted: those with a menu category), whatever the year; modes.structureFor picks one. A type that
-- can't be read is logged once and left out.
function survey.structureTypes(which : string) : {StructureType}
	local result : {StructureType} = {}
	local rep = api.res.bridgeTypeRep
	if which == "tunnel" then
		rep = api.res.tunnelTypeRep
	end
	local rail = api.type["enum"].Carrier.RAIL
	for index, name in pairs(rep.getAll()) do
		local ok, err = pcall(function() : boolean
			local ty = rep.get(index)
			if ty == nil or ty.menuCategory == nil or ty.menuCategory.categories == nil
				or #ty.menuCategory.categories == 0 then
				return true
			end
			-- As the menu (construction_react_util.tl makeFilterObjectsFn): rail only if the list names it.
			local carriesRail = false
			for __, c in ipairs(ty.carriers or {}) do
				if c == rail then
					carriesRail = true
				end
			end
			local availability = ty.availability
			table.insert(result, {
				name = name,
				index = index,
				order = ty.menuCategory.categories[1].order or 0,
				cost = ty.cost or 0,
				speedLimit = ty.speedLimit or 0,
				yearFrom = availability ~= nil and availability.yearFrom or 0,
				yearTo = availability ~= nil and availability.yearTo or 0,
				rail = carriesRail,
				-- nil means true.
				autoSelectable = ty.isAutoSelectable ~= false,
			})
			return true
		end)
		if not ok then
			logOnce(which .. tostring(index), which .. " type " .. tostring(name) .. ": " .. tostring(err))
		end
	end
	return result
end

local function isFinite(x : number) : boolean
	return x ~= nil and x == x and x ~= math.huge and x ~= -math.huge
end

function survey.extent() : Bounds
	local ok, bb = pcall(function() : Box2f
		return api.engine.terrain.getBoundingBox()
	end)
	if ok and bb ~= nil then
		local box = bb as Box2f
		local x0, y0, x1, y1 = box.min.x, box.min.y, box.max.x, box.max.y
		if isFinite(x0) and isFinite(y0) and isFinite(x1) and isFinite(y1) and x1 > x0 and y1 > y0 then
			return { minX = x0, minY = y0, maxX = x1, maxY = y1 }
		end
	end
	local ok2, w, h = pcall(function() : number, number
		local terrain = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.TERRAIN) as Engine.Component.Terrain
		return terrain.size.x * TERRAIN_TILE, terrain.size.y * TERRAIN_TILE
	end)
	if ok2 and isFinite(w as number) and isFinite(h as number) and (w as number) > 0 and (h as number) > 0 then
		local hw, hh = 0.5 * (w as number), 0.5 * (h as number)
		return { minX = -hw, minY = -hh, maxX = hw, maxY = hh }
	end
	logOnce("extent", "survey: the map's extent is unknown; the area isn't cut to it")
	return nil
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

-- A row's terrain from column `from` on, until the clock passes budgetUs (at least one cell). The next column to do;
-- past the row's end when it's done. A whole row took up to 35 ms in-game (391 cells, about 90 µs a cell), so rows
-- are cut wherever the frame's budget runs out.
local function surveyRow(job : Job, iy : integer, from : integer, clock : Clock, budgetUs : number) : integer
	local g = job.grid
	local terrain = api.engine.terrain
	local ix = from
	while ix <= g.nx do
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
		ix = ix + 1
		if clock:getTime() >= budgetUs then
			break
		end
	end
	return ix
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

-- Marks one entity a tile's lookup found (of the given kind), once per survey.
local function markFound(job : Job, kind : Engine.ComponentType, entity : Engine.Entity)
	if job.seen[entity] then
		return
	end
	job.seen[entity] = true
	local ok, err = pcall(function() : boolean
		if kind == api.type.ComponentType.BASE_EDGE then
			markEdge(job, entity)
		else
			if kind == api.type.ComponentType.CONSTRUCTION then
				job.constructions = job.constructions + 1
			else
				job.townBuildings = job.townBuildings + 1
			end
			markConstruction(job, entity)
		end
		return true
	end)
	if not ok then
		job.failures = job.failures + 1
		logOnce("mark" .. tostring(kind), "entity " .. tostring(entity) .. ": " .. tostring(err))
	end
end

-- A tile's work, resumable: for each kind in turn, one octree lookup in a call of its own, then marking what it found
-- until the clock passes budgetUs (at least one entity a call). true once the tile is done.
local function tileTask(job : Job, cx : number, cy : number) : function(Clock, number) : boolean
	local kinds : {Engine.ComponentType} = { api.type.ComponentType.CONSTRUCTION, api.type.ComponentType.TOWN_BUILDING,
		api.type.ComponentType.BASE_EDGE }
	local kindIndex = 1
	local found : {Engine.Entity} = nil
	local nextEntity = 1
	return function(clock : Clock, budgetUs : number) : boolean
		local kind = kinds[kindIndex]
		if found == nil then
			local before = clock:getTime()
			-- Covers the tile's corners (half the diagonal is 0.71 tiles).
			found = api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(cx, cy), TILE * 0.75, kind)
			job.slowestQueryUs = math.max(job.slowestQueryUs, math.floor(clock:getTime() - before))
			job.queries = job.queries + 1
			nextEntity = 1
			return false
		end
		local before = clock:getTime()
		while nextEntity <= #found do
			markFound(job, kind, found[nextEntity])
			nextEntity = nextEntity + 1
			if clock:getTime() >= budgetUs then
				break
			end
		end
		job.slowestMarkUs = math.max(job.slowestMarkUs, math.floor(clock:getTime() - before))
		if nextEntity <= #found then
			return false
		end
		found = nil
		kindIndex = kindIndex + 1
		return kindIndex > #kinds
	end
end

function survey.start(stops : {Town}, cell : number, margin : number, bounds ?: Bounds) : Job
	local box = area.box(stops, cell, margin, bounds)
	if box == nil then
		if #stops > 0 then
			logOnce("bounds", "survey: stops have no finite bounds")
		end
		return nil
	end
	local minX, minY, maxX, maxY = box.minX, box.minY, box.maxX, box.maxY
	local nx, ny = box.nx, box.ny
	cell = box.cell
	local job : Job = { box = box, grid = grid.new(minX, minY, cell, nx, ny), tasks = {}, next = 1, seen = {},
		reported = false, constructions = 0, townBuildings = 0, noBox = 0, edges = 0, streetEdges = 0, trackEdges = 0,
		tunnelsSkipped = 0, curveFallbacks = 0, invalidCells = 0, failures = 0, slowestRowUs = 0, slowestQueryUs = 0,
		slowestMarkUs = 0, slowestTaskUs = 0, slowestStepUs = 0, queries = 0, slices = 0, stepCalls = 0, totalUs = 0 }
	for iy = 1, ny do
		local nextCol = 1
		table.insert(job.tasks, function(clock : Clock, budgetUs : number) : boolean
			local before = clock:getTime()
			nextCol = surveyRow(job, iy, nextCol, clock, budgetUs)
			job.slowestRowUs = math.max(job.slowestRowUs, math.floor(clock:getTime() - before))
			return nextCol > nx
		end)
	end
	-- Tiles run to half a cell past maxX/maxY: after coarsening, the last cells' centres can sit close to the edge.
	local tx = minX
	while tx < maxX + cell / 2 do
		local ty = minY
		while ty < maxY + cell / 2 do
			table.insert(job.tasks, tileTask(job, tx + TILE / 2, ty + TILE / 2))
			ty = ty + TILE
		end
		tx = tx + TILE
	end
	debugPrint(LOG_PREFIX .. "survey: " .. nx .. " × " .. ny .. " cells of " .. cell .. " m (" .. minX .. " " .. minY
		.. " to " .. maxX .. " " .. maxY .. (bounds ~= nil and ", cut to the map" or "") .. "), " .. #job.tasks .. " tasks")
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
		.. " ms over " .. job.stepCalls .. " steps, the slowest " .. job.slowestStepUs .. " µs; " .. job.slices
		.. " slices, the slowest " .. job.slowestTaskUs
		.. " µs (terrain " .. job.slowestRowUs .. " µs, octree lookup " .. job.slowestQueryUs .. " µs of "
		.. job.queries .. ", marking " .. job.slowestMarkUs .. " µs); constructions " .. job.constructions .. ", town buildings " .. job.townBuildings
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
		local before = clock:getTime()
		local ok, result = pcall(function() : boolean
			return task(clock, budgetUs)
		end)
		job.slices = job.slices + 1
		job.slowestTaskUs = math.max(job.slowestTaskUs, math.floor(clock:getTime() - before))
		if not ok then
			job.failures = job.failures + 1
			logOnce("task", "survey task: " .. tostring(result))
			job.next = job.next + 1
		elseif result as boolean then
			job.next = job.next + 1
		end
	until clock:getTime() >= budgetUs
	local took = math.floor(clock:getTime())
	job.totalUs = job.totalUs + took
	job.slowestStepUs = math.max(job.slowestStepUs, took)
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
