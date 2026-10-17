local mapformat = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/mapformat.tl" as PgraceRailRouterMapFormat

local mapcapture : PgraceRailRouterMapCapture = {
	DEFAULT_TAG = "[rail_router] MAP",
	TILE = 1000.0,
}

local type Job = PgraceRailRouterMapCapture.Job
local type Options = PgraceRailRouterMapCapture.Options
local type Vec3 = PgraceRailRouterMapFormat.Vec3
local type Obj = PgraceRailRouterMapFormat.Obj
local type Edge = PgraceRailRouterMapFormat.Edge

-- A terrain tile's side (TERRAIN.size counts these), metres.
local TERRAIN_TILE = 256.0
-- The probe for the map's edge gives up this far from the centre (metres).
local PROBE_LIMIT = 200000.0

local KIND_CONSTRUCTION = 1
local KIND_TOWN_BUILDING = 2
local KIND_EDGE = 3

local logged : {string : boolean} = {}

local function isFinite(x : number) : boolean
	return x ~= nil and x == x and x ~= math.huge and x ~= -math.huge
end

local function emit(job : Job, line : string)
	debugPrint(job.tag .. " " .. line)
end

local function count(job : Job, key : string)
	job.counts[key] = (job.counts[key] or 0) + 1
end

local function fail(job : Job, kind : string, err : any)
	count(job, "failures")
	if not logged[kind] then
		logged[kind] = true
		debugPrint(job.logPrefix .. "map capture: " .. kind .. ": " .. tostring(err))
	end
end

local function vec3(v : Vec3f) : Vec3
	return { x = v.x, y = v.y, z = v.z }
end

local function boundingBox(entity : Engine.Entity) : Engine.Component.BoundingVolume
	return api.engine.getComponent(entity, api.type.ComponentType.BOUNDING_VOLUME) as Engine.Component.BoundingVolume
end

-- The TERRAIN component and where it was found: on the world entity, else the first entity that has one.
local function findTerrain() : Engine.Component.Terrain, string
	local ok, comp = pcall(function() : Engine.Component.Terrain
		return api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.TERRAIN) as Engine.Component.Terrain
	end)
	if ok and comp ~= nil then
		return comp as Engine.Component.Terrain, "world"
	end
	local found : Engine.Entity = nil
	pcall(function() : boolean
		api.engine.forEachEntityWithComponent(function(e : Engine.Entity)
			if found == nil then
				found = e
			end
		end, api.type.ComponentType.TERRAIN)
		return true
	end)
	if found ~= nil then
		local ok2, comp2 = pcall(function() : Engine.Component.Terrain
			return api.engine.getComponent(found, api.type.ComponentType.TERRAIN) as Engine.Component.Terrain
		end)
		if ok2 and comp2 ~= nil then
			return comp2 as Engine.Component.Terrain, "entity " .. tostring(found)
		end
	end
	return nil, "none"
end

local function isValid(x : number, y : number) : boolean
	return api.engine.terrain.isValidCoordinate(api.type.Vec2f.new(x, y))
end

-- How far from the centre along (dx, dy) the map stays valid: 256 m steps out, then halving down to 1 m.
local function probeEdge(dx : number, dy : number) : number
	if not isValid(0, 0) then
		return nil
	end
	local inside, outside = 0.0, TERRAIN_TILE
	while isValid(dx * outside, dy * outside) do
		inside = outside
		outside = outside + TERRAIN_TILE
		if outside > PROBE_LIMIT then
			return nil
		end
	end
	while outside - inside > 1 do
		local mid = 0.5 * (inside + outside)
		if isValid(dx * mid, dy * mid) then
			inside = mid
		else
			outside = mid
		end
	end
	return inside
end

-- The map's extent (world metres) and how it was found: the terrain's bounding box, else TERRAIN.size × 256 m
-- round the centre, else probing isValidCoordinate outward from the centre.
local function readExtent(terrain : Engine.Component.Terrain) : number, number, number, number, string
	local ok, bb = pcall(function() : Box2f
		return api.engine.terrain.getBoundingBox()
	end)
	if ok and bb ~= nil then
		local box = bb as Box2f
		local x0, y0, x1, y1 = box.min.x, box.min.y, box.max.x, box.max.y
		if isFinite(x0) and isFinite(y0) and isFinite(x1) and isFinite(y1) and x1 > x0 and y1 > y0 then
			return x0, y0, x1, y1, "bbox"
		end
	end
	if terrain ~= nil then
		local ok2, w, h = pcall(function() : number, number
			return terrain.size.x * TERRAIN_TILE, terrain.size.y * TERRAIN_TILE
		end)
		if ok2 and isFinite(w as number) and isFinite(h as number) and (w as number) > 0 and (h as number) > 0 then
			local hw, hh = 0.5 * (w as number), 0.5 * (h as number)
			return -hw, -hh, hw, hh, "tiles"
		end
	end
	local ok3, east, west, north, south = pcall(function() : number, number, number, number
		return probeEdge(1, 0), probeEdge(-1, 0), probeEdge(0, 1), probeEdge(0, -1)
	end)
	if ok3 and east ~= nil and west ~= nil and north ~= nil and south ~= nil then
		return -(west as number), -(south as number), east as number, north as number, "probe"
	end
	return nil, nil, nil, nil, "none"
end

local function writeTerrain(job : Job, terrain : Engine.Component.Terrain, source : string)
	emit(job, mapformat.terrain("component", source))
	local reads : {{string, function() : string}} = {
		{ "size", function() : string return tostring(terrain.size.x) .. " " .. tostring(terrain.size.y) end },
		{ "baseResolution", function() : string
			local r = terrain.baseResolution
			return tostring(r.x) .. " " .. tostring(r.y) .. " " .. tostring(r.z)
		end },
		{ "waterLevel", function() : string return tostring(terrain.waterLevel) end },
		{ "offsetZ", function() : string return tostring(terrain.offsetZ) end },
		{ "baseLevels", function() : string return tostring(terrain.baseLevels) end },
		{ "highLevels", function() : string return tostring(terrain.highLevels) end },
	}
	for __, read in ipairs(reads) do
		if terrain ~= nil then
			local ok, value = pcall(read[2])
			if ok and value ~= nil then
				emit(job, mapformat.terrain(read[1], value as string))
			end
		end
	end
	-- The terrain API's own resolution reads (not on the component).
	local ok, value = pcall(function() : string
		local r = api.engine.terrain.getBaseResolution()
		return tostring(r.x) .. " " .. tostring(r.y) .. " " .. tostring(r.z)
	end)
	if ok then
		emit(job, mapformat.terrain("apiBaseResolution", value as string))
	end
	ok, value = pcall(function() : string
		local r = api.engine.terrain.getHighResolution()
		return tostring(r.x) .. " " .. tostring(r.y) .. " " .. tostring(r.z)
	end)
	if ok then
		emit(job, mapformat.terrain("apiHighResolution", value as string))
	end
end

-- isValidCoordinate just inside and just outside the extent's corners, as a check on the extent.
local function checkExtent(x0 : number, y0 : number, x1 : number, y1 : number) : string
	local ok, result = pcall(function() : string
		local inside, outside = 0, 0
		for __, c in ipairs({ { x0, y0, 1, 1 }, { x1, y0, -1, 1 }, { x0, y1, 1, -1 }, { x1, y1, -1, -1 } }) do
			if isValid(c[1] + c[3], c[2] + c[4]) then
				inside = inside + 1
			end
			if not isValid(c[1] - c[3], c[2] - c[4]) then
				outside = outside + 1
			end
		end
		return "corners valid 1 m inside " .. tostring(inside) .. "/4, invalid 1 m outside " .. tostring(outside) .. "/4"
	end)
	if ok then
		return result as string
	end
	return "check failed: " .. tostring(result)
end

local function writeDates(job : Job)
	local ok, value = pcall(function() : string
		return os.date("!%Y-%m-%dT%H:%M:%SZ") as string
	end)
	if ok and value ~= nil then
		emit(job, mapformat.meta("captured", value as string))
	end
	ok, value = pcall(function() : string
		return tostring(api.engine.util.getYear())
	end)
	if ok then
		emit(job, mapformat.meta("gameYear", value as string))
	end
	ok, value = pcall(function() : string
		local gt = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME) as Engine.Component.GameTime
		local d = api.engine.util.getCalendarDate(gt.gameTime)
		return string.format("%04d-%02d-%02d", d.year, d.month, d.day)
	end)
	if ok then
		emit(job, mapformat.meta("gameDate", value as string))
	end
end

local function writeTowns(job : Job)
	api.engine.forEachEntityWithComponent(function(town : Engine.Entity)
		local ok, err = pcall(function() : boolean
			local bv = boundingBox(town)
			if bv == nil then
				count(job, "townsWithoutBox")
				return true
			end
			emit(job, mapformat.town({ id = town, name = api.engine.util.getEntityName(town) or "",
				x0 = bv.bbox.min.x, y0 = bv.bbox.min.y, x1 = bv.bbox.max.x, y1 = bv.bbox.max.y }))
			count(job, "town")
			return true
		end)
		if not ok then
			fail(job, "town", err)
		end
	end, api.type.ComponentType.TOWN)
end

-- A construction's kind from its file name (cheap, and good enough to tell the main kinds apart).
local function classify(file : string) : string
	if file == nil then
		return "other"
	end
	local f = file:lower()
	if f:find("station", 1, true) then
		return "station"
	elseif f:find("industr", 1, true) then
		return "industry"
	elseif f:find("depot", 1, true) then
		return "depot"
	elseif f:find("building", 1, true) then
		return "building"
	end
	return "other"
end

local function writeObject(job : Job, entity : Engine.Entity, kind : integer)
	local o : Obj = { id = entity, kind = "other", boxSource = "none", construction = -1, town = -1 }
	local tb = api.engine.getComponent(entity, api.type.ComponentType.TOWN_BUILDING) as Engine.Component.TownBuilding
	if kind == KIND_TOWN_BUILDING then
		o.kind = "townbuilding"
	else
		local con = api.engine.getComponent(entity, api.type.ComponentType.CONSTRUCTION) as Engine.Component.Construction
		if con ~= nil then
			local okFile, file = pcall(function() : string
				return tostring(con.fileName)
			end)
			if okFile then
				o.file = file as string
			end
		end
		o.kind = classify(o.file)
	end
	if tb ~= nil then
		o.construction = tb.construction or -1
		o.town = tb.town or -1
	end
	-- As survey.markConstruction: the entity's own box, else (town buildings) its construction's.
	local bv = boundingBox(entity)
	if bv ~= nil then
		o.boxSource = "own"
	elseif tb ~= nil and tb.construction ~= nil and tb.construction >= 0 and api.engine.entityExists(tb.construction) then
		bv = boundingBox(tb.construction)
		if bv ~= nil then
			o.boxSource = "con"
		end
	end
	if bv ~= nil then
		o.min = vec3(bv.bbox.min)
		o.max = vec3(bv.bbox.max)
	else
		count(job, "noBox")
	end
	emit(job, mapformat.obj(o))
	count(job, "obj")
end

local function isZero(v : Vec3f) : boolean
	return v.x == 0 and v.y == 0 and v.z == 0
end

local function writeEdge(job : Job, entity : Engine.Entity)
	local edge = api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
	if edge == nil then
		count(job, "noEdge")
		return
	end
	local e : Edge = { id = entity, kind = "t", edgeType = "?", node0 = edge.node0, node1 = edge.node1 }
	if api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE_STREET) ~= nil then
		e.kind = "s"
	end
	local types = api.type["enum"].BaseEdgeType
	if edge.type == types.NORMAL then
		e.edgeType = "n"
	elseif edge.type == types.BRIDGE then
		e.edgeType = "b"
	elseif edge.type == types.TUNNEL then
		e.edgeType = "u"
	end
	-- As survey.markEdge: the edge's own curve, else a straight line between its nodes.
	local p0, p1, t0, t1 : Vec3f, Vec3f, Vec3f, Vec3f = nil, nil, nil, nil
	local read = pcall(function() : boolean
		p0, p1, t0, t1 = edge.position0, edge.position1, edge.tangent0, edge.tangent1
		return true
	end)
	if read and p0 ~= nil and p1 ~= nil and t0 ~= nil and t1 ~= nil and not (isZero(p0) and isZero(p1)) then
		e.p0, e.p1, e.t0, e.t1 = vec3(p0), vec3(p1), vec3(t0), vec3(t1)
	else
		count(job, "straight")
		local n0 = api.engine.getComponent(edge.node0, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
		local n1 = api.engine.getComponent(edge.node1, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
		if n0 == nil or n1 == nil then
			count(job, "noNodes")
			return
		end
		e.p0, e.p1 = vec3(n0.position), vec3(n1.position)
	end
	local okTemplate, template = pcall(function() : string
		return tostring(edge.roadTemplate)
	end)
	if okTemplate and template ~= "nil" then
		e.template = template as string
	end
	emit(job, mapformat.edge(e))
	count(job, "edge")
end

local function writeRowChunk(job : Job)
	local iy, ix0 = job.nextRow, job.nextCol
	local n = math.min(mapformat.CHUNK, job.nx - ix0 + 1)
	-- Move on first: a chunk that throws is skipped, not retried for ever.
	job.nextCol = ix0 + n
	if job.nextCol > job.nx then
		job.nextCol = 1
		job.nextRow = iy + 1
	end
	job.chunksDone = job.chunksDone + 1
	local terrain = api.engine.terrain
	local heights : {number} = {}
	local flags : {string} = {}
	local y = job.y0 + (iy - 1) * job.spacing
	for k = 0, n - 1 do
		local v = api.type.Vec2f.new(job.x0 + (ix0 + k - 1) * job.spacing, y)
		local flag = mapformat.LAND
		if not terrain.isValidCoordinate(v) then
			flag = mapformat.OFF
			count(job, "off")
		elseif terrain.isOnWater(v) then
			flag = mapformat.WATER
			count(job, "water")
		end
		heights[k + 1] = terrain.getHeightAt(v)
		flags[k + 1] = flag
	end
	emit(job, mapformat.row(iy, ix0, heights, flags))
	count(job, "r")
end

local function lookUp(job : Job)
	local tile = job.tiles[job.nextTile]
	local kind = job.nextKind
	job.nextKind = kind + 1
	if job.nextKind > 3 then
		job.nextKind = 1
		job.nextTile = job.nextTile + 1
	end
	job.lookupsDone = job.lookupsDone + 1
	local types = { api.type.ComponentType.CONSTRUCTION, api.type.ComponentType.TOWN_BUILDING,
		api.type.ComponentType.BASE_EDGE }
	-- Covers the tile's corners (half the diagonal is 0.71 tiles).
	local found = api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(tile[1], tile[2]),
		mapcapture.TILE * 0.75, types[kind])
	for __, entity in ipairs(found) do
		if not job.seen[entity] then
			job.seen[entity] = true
			table.insert(job.pending, entity)
			table.insert(job.pendingKind, kind)
		end
	end
end

local function writeNextEntity(job : Job)
	local entity, kind = job.pending[job.pendingHead], job.pendingKind[job.pendingHead]
	job.pendingHead = job.pendingHead + 1
	if not api.engine.entityExists(entity) then
		count(job, "gone")
		return
	end
	if kind == KIND_EDGE then
		writeEdge(job, entity)
	else
		writeObject(job, entity, kind)
	end
end

local function hasPending(job : Job) : boolean
	return job.pendingHead <= #job.pending
end

local function terrainLeft(job : Job) : boolean
	return job.nextRow <= job.ny
end

local function lookupsLeft(job : Job) : boolean
	return job.nextTile <= #job.tiles
end

function mapcapture.start(opts : Options) : Job
	opts = opts or {}
	local job : Job = { tag = opts.tag or mapcapture.DEFAULT_TAG, logPrefix = opts.logPrefix or "[rail_router] ",
		spacing = mapformat.SPACING, nextRow = 1, nextCol = 1, chunksTotal = 0, chunksDone = 0, tiles = {},
		nextTile = 1, nextKind = 1, lookupsDone = 0, pending = {}, pendingKind = {}, pendingHead = 1, seen = {},
		counts = { r = 0, town = 0, track = 0, obj = 0, edge = 0, failures = 0 }, finished = false, lastProgress = 0,
		stepCalls = 0, totalUs = 0, slowestUs = 0, clock = api.type.Clock.new() }
	local terrain, terrainSource = findTerrain()
	local x0, y0, x1, y1, source = readExtent(terrain)
	if x0 == nil then
		debugPrint(job.logPrefix .. "map capture: couldn't find the map's extent")
		return nil
	end
	local spacing = job.spacing
	job.x0, job.y0 = x0, y0
	job.nx = math.floor((x1 - x0) / spacing + 1e-6) + 1
	job.ny = math.floor((y1 - y0) / spacing + 1e-6) + 1
	job.chunksTotal = job.ny * math.ceil(job.nx / mapformat.CHUNK)
	local tx = x0
	while tx < x1 do
		local ty = y0
		while ty < y1 do
			table.insert(job.tiles, { tx + mapcapture.TILE / 2, ty + mapcapture.TILE / 2 })
			ty = ty + mapcapture.TILE
		end
		tx = tx + mapcapture.TILE
	end

	emit(job, mapformat.begin())
	writeDates(job)
	if opts.meta ~= nil then
		for k, v in pairs(opts.meta) do
			emit(job, mapformat.meta(k, v))
		end
	end
	emit(job, mapformat.extent(x0, y0, x1, y1, source))
	emit(job, mapformat.meta("extentCheck", checkExtent(x0, y0, x1, y1)))
	writeTerrain(job, terrain, terrainSource)
	emit(job, mapformat.grid(spacing, x0, y0, job.nx, job.ny))
	local ok, err = pcall(function() : boolean
		writeTowns(job)
		return true
	end)
	if not ok then
		fail(job, "towns", err)
	end
	for __, track in ipairs(opts.tracks or {}) do
		local okTrack, errTrack = pcall(function() : boolean
			emit(job, mapformat.track(track))
			count(job, "track")
			return true
		end)
		if not okTrack then
			fail(job, "track", errTrack)
		end
	end
	debugPrint(job.logPrefix .. "map capture: extent " .. string.format("%.0f %.0f %.0f %.0f", x0, y0, x1, y1) .. " ("
		.. source .. "), " .. job.nx .. " × " .. job.ny .. " points of " .. spacing .. " m, " .. job.chunksTotal
		.. " terrain lines, " .. #job.tiles .. " tiles")
	return job
end

local function finish(job : Job)
	job.finished = true
	emit(job, mapformat.finish({ r = job.counts.r, town = job.counts.town, track = job.counts.track,
		obj = job.counts.obj, edge = job.counts.edge, failures = job.counts.failures }))
	local parts : {string} = {}
	local keys : {string} = {}
	for k in pairs(job.counts) do
		table.insert(keys, k)
	end
	table.sort(keys)
	for __, k in ipairs(keys) do
		table.insert(parts, k .. " " .. tostring(job.counts[k]))
	end
	debugPrint(job.logPrefix .. "map capture done: " .. table.concat(parts, ", ") .. "; "
		.. string.format("%.1f", job.totalUs / 1000) .. " ms of work over " .. job.stepCalls .. " frames, "
		.. string.format("%.1f", job.clock:getTime() / 1e6) .. " s in all, slowest task " .. job.slowestUs .. " µs")
end

function mapcapture.step(job : Job, budgetUs : integer) : boolean
	if job.finished then
		return true
	end
	local clock = api.type.Clock.new()
	job.stepCalls = job.stepCalls + 1
	repeat
		local before = clock:getTime()
		local kind : string
		local ok, err : boolean, any
		if hasPending(job) then
			kind = "entity"
			ok, err = pcall(function() : boolean
				writeNextEntity(job)
				return true
			end)
		elseif terrainLeft(job) then
			kind = "terrain"
			ok, err = pcall(function() : boolean
				writeRowChunk(job)
				return true
			end)
		elseif lookupsLeft(job) then
			kind = "lookup"
			ok, err = pcall(function() : boolean
				lookUp(job)
				return true
			end)
		else
			break
		end
		if not ok then
			fail(job, kind, err)
		end
		job.slowestUs = math.max(job.slowestUs, math.floor(clock:getTime() - before))
	until clock:getTime() >= budgetUs
	job.totalUs = job.totalUs + math.floor(clock:getTime())
	if not (hasPending(job) or terrainLeft(job) or lookupsLeft(job)) then
		local ok, err = pcall(function() : boolean
			finish(job)
			return true
		end)
		if not ok then
			job.finished = true
			fail(job, "finish", err)
		end
	end
	return job.finished
end

function mapcapture.progress(job : Job) : number
	if job.finished then
		return 1
	end
	local entitiesDone = job.pendingHead - 1
	local total = job.chunksTotal + #job.tiles * 3 + #job.pending
	local share = 0.0
	if total > 0 then
		share = (job.chunksDone + job.lookupsDone + entitiesDone) / total
	end
	share = math.max(job.lastProgress, math.min(0.99, share))
	job.lastProgress = share
	return share
end

function mapcapture.done(job : Job) : boolean
	return job.finished
end

return mapcapture
