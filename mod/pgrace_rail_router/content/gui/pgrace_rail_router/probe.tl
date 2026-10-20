-- PROBE (remove before release): the milestone 2 engine probes (see probe.d.tl). Every engine read is in a pcall;
-- they use builder.chunkProposal, stationProposal and dryRun, so they test the code that will ship.
local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo
local network = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/network.tl" as PgraceRailRouterNetwork
local modes = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/modes.tl" as PgraceRailRouterModes
local sl = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/stationlayout.tl" as PgraceRailRouterStationLayout
local survey = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/survey.tl" as PgraceRailRouterSurvey
local builder = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/builder.tl" as PgraceRailRouterBuilder
local midline = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/midline.tl" as PgraceRailRouterMidline
local junction = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/junction.tl" as PgraceRailRouterJunction

local probe : PgraceRailRouterProbe = {}

local type Settings = PgraceRailRouterBuilder.Settings
local type Pt = PgraceRailRouterGeo.Pt
local type Plan = PgraceRailRouterRoute.Plan
local type Leg = PgraceRailRouterRoute.Leg
local type Piece = PgraceRailRouterSmooth.Piece
local type Options = PgraceRailRouterNetwork.Options

local MODULE_DIR = "::/stations/rail/modular_station/"

local function log(name : string, text : string)
	debugPrint("[rail_router] PROBE " .. name .. " " .. text)
end

-- Runs fn, logging an error under the probe's name instead of throwing.
local function guarded(name : string, fn : function()) : function()
	return function()
		local ok, err = pcall(function() : boolean
			fn()
			return true
		end)
		if not ok then
			log(name, "ERROR " .. tostring(err))
		end
	end
end

local function camera() : Pt
	local c = api.gui.camera.getCenter()
	return { x = c.x, y = c.y }
end

local function groundAt(p : Pt) : number
	local ok, h = pcall(function() : number
		return api.engine.terrain.getHeightAt(api.type.Vec2f.new(p.x, p.y))
	end)
	if ok and h ~= nil then
		return h as number
	end
	return 0
end

local function fmtV(v : Vec3f) : string
	return ("(%.2f %.2f %.2f)"):format(v.x, v.y, v.z)
end

-- A settings copy with some fields changed.
local function with(settings : Settings, change : function(Settings)) : Settings
	local copy : Settings = {
		track = settings.track, speed = settings.speed, year = settings.year, bridge = settings.bridge,
		tunnel = settings.tunnel, normalTypeIndex = settings.normalTypeIndex, era = settings.era, addons = settings.addons,
		network = settings.network,
	}
	change(copy)
	return copy
end

-- A one-leg plan along the given pieces, at height z0 at the start rising by `grade`, all of one kind of span.
local function testPlan(pieces : {Piece}, z0 : number, grade : number, kind : string) : Plan
	local total = 0.0
	for __, p in ipairs(pieces) do
		total = total + p.length
	end
	-- network.tl reads only the samples' s and the heights; p is the start, unused.
	local samples : {PgraceRailRouterSmooth.Sample} = {}
	local z : {number} = {}
	local s = 0.0
	while true do
		table.insert(samples, { p = pieces[1].a, s = s })
		table.insert(z, z0 + grade * s)
		if s >= total then
			break
		end
		s = math.min(total, s + 25)
	end
	local leg : Leg = { pieces = pieces, samples = samples, z = z, spans = { { kind = kind, s0 = 0, s1 = total } },
		length = total }
	return { ok = true, legs = { leg }, stations = {}, platformLength = 160 }
end

local function straight(a : Pt, dir : Pt, length : number) : Piece
	return { kind = "straight", a = a, b = geo.add(a, geo.scale(dir, length)), length = length }
end

-- A left arc from a heading dir.
local function leftArc(a : Pt, dir : Pt, radius : number, turn : number) : Piece
	local left : Pt = { x = -dir.y, y = dir.x }
	local centre = geo.add(a, geo.scale(left, radius))
	local b = geo.add(centre, geo.rotate(geo.sub(a, centre), turn))
	return { kind = "arc", a = a, b = b, length = radius * turn, radius = radius, centre = centre, turn = turn }
end

-- Which of street, track, town building, construction an entity is.
local function describe(entity : integer) : string
	local kinds : {string} = {}
	local function has(name : string, ct : Engine.ComponentType) : boolean
		local ok, comp = pcall(function() : any
			return api.engine.getComponent(entity, ct)
		end)
		if ok and comp ~= nil then
			table.insert(kinds, name)
			return true
		end
		return false
	end
	if has("edge", api.type.ComponentType.BASE_EDGE) and not has("street", api.type.ComponentType.BASE_EDGE_STREET) then
		table.insert(kinds, "track")
	end
	has("town building", api.type.ComponentType.TOWN_BUILDING)
	has("construction", api.type.ComponentType.CONSTRUCTION)
	has("node", api.type.ComponentType.BASE_NODE)
	return tostring(entity) .. " [" .. table.concat(kinds, ",") .. "]"
end

-- Dry-runs a plan's whole network as one proposal and logs the outcome; returns the ProposalData (nil if none).
local function tryPlan(name : string, plan : Plan, settings : Settings, options : Options) : ProposalData
	local net = network.build(plan, options)
	local proposal, why = builder.chunkProposal(net, 1, #net.edges, settings)
	if proposal == nil then
		log(name, "NOT MADE " .. tostring(why))
		return nil
	end
	local ok, cost, messages, us, data = builder.dryRun(proposal)
	local longest = 0.0
	for __, e in ipairs(net.edges) do
		longest = math.max(longest, e.s1 - e.s0)
	end
	log(name, ("%s cost %d %d us edges %d (longest %.1f m) %s"):format(ok and "clean" or "ERRORS", cost, us,
		#net.edges, longest, table.concat(messages, "; ")))
	return data
end

-- Logs a dry run's collision entities (at most 20).
local function logCollisions(name : string, data : ProposalData)
	if data == nil then
		return
	end
	local ok, err = pcall(function() : boolean
		local list = data.collisionInfo.collisionEntities or {}
		local described : {string} = {}
		for i, d in ipairs(list) do
			if i > 20 then
				break
			end
			table.insert(described, describe(d.entity))
		end
		log(name, ("collisions %d: %s"):format(#list, table.concat(described, " ")))
		return true
	end)
	if not ok then
		log(name, "collisions unreadable: " .. tostring(err))
	end
end

-- P1 -------------------------------------------------------------------------------------------------------------

local function logEdge(e : integer)
	local edge = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
	if edge == nil then
		return
	end
	local isTrack = false
	pcall(function() : boolean
		isTrack = edge.roadType == api.type["enum"].RoadType.TRACK
		return true
	end)
	if not isTrack then
		return
	end
	local p0, p1, t0, t1 = edge.position0, edge.position1, edge.tangent0, edge.tangent1
	local chord = math.sqrt((p1.x - p0.x) ^ 2 + (p1.y - p0.y) ^ 2)
	local lt0, lt1 = math.sqrt(t0.x ^ 2 + t0.y ^ 2), math.sqrt(t1.x ^ 2 + t1.y ^ 2)
	local theta = math.abs(geo.turnAngle({ x = t0.x, y = t0.y }, { x = t1.x, y = t1.y }))
	local r = theta > 1e-6 and chord / (2 * math.sin(theta / 2)) or math.huge
	local arcRatio = theta > 1e-6 and lt0 / (r * theta) or lt0 / math.max(1e-9, chord)
	local circleRatio = theta > 1e-6 and lt0 / (4 * r * math.tan(theta / 4)) or lt0 / math.max(1e-9, chord)
	local distance, owner, strips, lanes = "?", "none", "?", "?"
	pcall(function() : boolean
		distance = tostring(edge.distance)
		return true
	end)
	pcall(function() : boolean
		local po = api.engine.getComponent(e, api.type.ComponentType.PLAYER_OWNED) as Engine.Component.PlayerOwned
		if po ~= nil then
			owner = tostring(po.player)
		end
		return true
	end)
	pcall(function() : boolean
		local list = api.engine.system.baseParallelStripSystem.getStrips(e)
		local parts : {string} = {}
		for __, st in ipairs(list) do
			local entity = st as integer
			local desc = tostring(entity)
			pcall(function() : boolean
				local strip = api.engine.getComponent(entity, api.type.ComponentType.BASE_PARALLEL_STRIP) as Engine.Component.BaseParallelStrip
				local groups : {string} = {}
				for __, g in ipairs(strip.rangeGroups) do
					local ranges : {string} = {}
					for __, r in ipairs(g) do
						table.insert(ranges, ("%d[%.2f-%.2f]"):format(r.edge, r.bounds[1], r.bounds[2]))
					end
					table.insert(groups, "{" .. table.concat(ranges, " ") .. "}")
				end
				desc = desc .. ":" .. #strip.rangeGroups .. " groups " .. table.concat(groups, " ")
				return true
			end)
			table.insert(parts, desc)
		end
		strips = tostring(#list) .. " (" .. table.concat(parts, "; ") .. ")"
		return true
	end)
	pcall(function() : boolean
		lanes = tostring(#edge.laneConfigs)
		return true
	end)
	local ends : {string} = {}
	for __, n in ipairs({ edge.node0, edge.node1 }) do
		local count = "?"
		pcall(function() : boolean
			count = tostring(#api.engine.system.streetSystem.getNodeTrackSegments(n))
			return true
		end)
		table.insert(ends, tostring(n) .. ":" .. count)
	end
	log("P1", ("edge %d type %s typeIndex %s distance %s template %s style %s lanes %s owner %s strips %s nodes %s"):format(
		e, tostring(edge.type), tostring(edge.typeIndex), distance, tostring(edge.roadTemplate), tostring(edge.roadStyle),
		lanes, owner, strips, table.concat(ends, " ")))
	log("P1", ("edge %d chord %.2f |t0| %.2f |t1| %.2f t0.z %.3f t1.z %.3f theta %.4f R %.1f t/(R theta) %.4f t/(4R tan) %.4f p0 %s p1 %s t0 %s t1 %s"):format(
		e, chord, lt0, lt1, t0.z, t1.z, theta, r, arcRatio, circleRatio, fmtV(p0), fmtV(p1), fmtV(t0), fmtV(t1)))
end

function probe.logTrack() : {function()}
	local c = camera()
	return { guarded("P1", function()
		local edges = api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(c.x, c.y), 300,
			api.type.ComponentType.BASE_EDGE)
		log("P1", ("camera (%.1f %.1f): %d edges within 300 m"):format(c.x, c.y, #edges))
		for __, e in ipairs(edges) do
			local ok, err = pcall(function() : boolean
				logEdge(e)
				return true
			end)
			if not ok then
				log("P1", "edge " .. tostring(e) .. " ERROR " .. tostring(err))
			end
		end
		log("P1", "done")
	end) }
end

-- P2, P3 ---------------------------------------------------------------------------------------------------------

local function logStructures(which : string, tracks : {PgraceRailRouterModes.TrackType}, year : integer)
	local types = survey.structureTypes(which)
	local rep = which == "tunnel" and api.res.tunnelTypeRep or api.res.bridgeTypeRep
	for __, ty in ipairs(types) do
		local found = "?"
		local raw = "?"
		pcall(function() : boolean
			found = tostring(rep.find(ty.name))
			return true
		end)
		pcall(function() : boolean
			raw = tostring((rep.get(ty.index) as any as {string : any}).isAutoSelectable)
			return true
		end)
		log("P2", ("%s %s index %d (find %s) order %d speedLimit %.2f rail %s autoSelectable %s (raw %s) years %d-%d cost %.1f")
			:format(which, ty.name, ty.index, found, ty.order, ty.speedLimit, tostring(ty.rail), tostring(ty.autoSelectable),
			raw, ty.yearFrom, ty.yearTo, ty.cost))
	end
	for __, t in ipairs(tracks) do
		local pick = modes.structureFor(types, t.speed, year)
		log("P2", ("%s for %s (%.2f m/s) in %d: %s"):format(which, t.name, t.speed, year,
			pick ~= nil and (pick.name .. " index " .. pick.index) or "none"))
	end
end

function probe.dryRunTrack(settings : Settings, tracks : {PgraceRailRouterModes.TrackType}) : {function()}
	local c = camera()
	local east : Pt = { x = 1, y = 0 }
	local z = groundAt(c) + 0.5
	local tasks : {function()} = {}
	table.insert(tasks, guarded("P2", function()
		log("P2", ("camera (%.1f %.1f) ground %.2f; track %s, year %d, bridge %s, tunnel %s, normal typeIndex %d")
			:format(c.x, c.y, z - 0.5, settings.track, settings.year,
			settings.bridge ~= nil and settings.bridge.name or "none", settings.tunnel ~= nil and settings.tunnel.name or "none",
			settings.normalTypeIndex))
		logStructures("bridge", tracks, settings.year)
		logStructures("tunnel", tracks, settings.year)
	end))
	-- A flat profile: the edges follow it whatever their length, so with no longest edge each track is one edge.
	local one = network.defaults()
	one.maxEdge = 100000
	for __, length in ipairs({ 100, 250, 500, 1000, 2000 }) do
		table.insert(tasks, guarded("P2", function()
			tryPlan("P2 straight " .. length, testPlan({ straight(c, east, length) }, z, 0, "ground"), settings, one)
		end))
	end
	local o = network.defaults()
	for __, grade in ipairs({ 0.02, 0.08, 0.085, 0.09, 0.12, 0.14 }) do
		table.insert(tasks, guarded("P2", function()
			tryPlan(("P2 grade %.3f"):format(grade), testPlan({ straight(c, east, 500) }, z, grade, "ground"), settings, o)
		end))
	end
	for __, radius in ipairs({ 300, 100, 55, 50, 45, 38 }) do
		table.insert(tasks, guarded("P2", function()
			tryPlan("P2 radius " .. radius, testPlan({ leftArc(c, east, radius, math.pi / 2) }, z, 0, "ground"), settings, o)
		end))
	end
	table.insert(tasks, guarded("P3", function()
		tryPlan("P3 bridge 300", testPlan({ straight(c, east, 300) }, z + 10, 0, "bridge"), settings, o)
	end))
	table.insert(tasks, guarded("P3", function()
		tryPlan("P3 tunnel 300", testPlan({ straight(c, east, 300) }, z - 20, 0, "tunnel"), settings, o)
	end))
	local arcRule = network.defaults()
	arcRule.tangent = "arc"
	table.insert(tasks, guarded("P1", function()
		tryPlan("P1 arc rule radius 300", testPlan({ leftArc(c, east, 300, math.pi / 2) }, z, 0, "ground"), settings, arcRule)
	end))
	table.insert(tasks, guarded("P1", function()
		tryPlan("P1 circle rule radius 300", testPlan({ leftArc(c, east, 300, math.pi / 2) }, z, 0, "ground"), settings, o)
	end))
	table.insert(tasks, function()
		log("P2", "done")
	end)
	return tasks
end

-- P4 -------------------------------------------------------------------------------------------------------------

function probe.dryRunCrossing(settings : Settings) : {function()}
	local c = camera()
	local east : Pt = { x = 1, y = 0 }
	local start = geo.add(c, { x = -150, y = 0 })
	local ground = groundAt(c)
	local o = network.defaults()
	return {
		guarded("P4", function()
			log("P4", ("camera (%.1f %.1f) ground %.2f"):format(c.x, c.y, ground))
			logCollisions("P4 ground", tryPlan("P4 ground", testPlan({ straight(start, east, 300) }, ground + 0.5, 0,
				"ground"), settings, o))
		end),
		guarded("P4", function()
			logCollisions("P4 bridge", tryPlan("P4 bridge 8 m", testPlan({ straight(start, east, 300) }, ground + 8, 0,
				"bridge"), settings, o))
			log("P4", "done")
		end),
	}
end

-- P8 -------------------------------------------------------------------------------------------------------------

-- The nearest track or street edge to the camera, as the point on its chord closest to the camera, its direction and
-- height there.
local record Crossed
	p : Pt
	dir : Pt
	z : number
	entity : integer
end

local P8_HEIGHTS : {number} = { 6, 7, 8, 9, 10, 11, 12, 14 }

-- The plain (not bridge or tunnel) track or street edge nearest p within 200 m, at the point of its chord nearest p;
-- nil if none.
local function nearest(p : Pt, kind : string) : Crossed
	local found : Crossed = nil
	local best = math.huge
	local edges = api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(p.x, p.y), 200,
		api.type.ComponentType.BASE_EDGE)
	for __, e in ipairs(edges) do
		pcall(function() : boolean
			local edge = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
			local isTrack = edge.roadType == api.type["enum"].RoadType.TRACK
			if edge.type ~= api.type["enum"].BaseEdgeType.NORMAL or (isTrack and "track" or "street") ~= kind then
				return true
			end
			local n0 = api.engine.getComponent(edge.node0, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
			local n1 = api.engine.getComponent(edge.node1, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
			local a : Pt = { x = n0.position.x, y = n0.position.y }
			local b : Pt = { x = n1.position.x, y = n1.position.y }
			local ab = geo.sub(b, a)
			local len = geo.len(ab)
			if len < 1 then
				return true
			end
			local t = math.max(0, math.min(1, geo.dot(geo.sub(p, a), ab) / (len * len)))
			local q = geo.add(a, geo.scale(ab, t))
			local d = geo.len(geo.sub(p, q))
			if d < best then
				best = d
				found = { p = q, dir = geo.scale(ab, 1 / len), z = n0.position.z + t * (n1.position.z - n0.position.z),
					entity = e }
			end
			return true
		end)
	end
	return found
end

function probe.bridgeClearance(settings : Settings) : {function()}
	local c = camera()
	local found : {string : Crossed} = {}
	local o = network.defaults()
	local tasks : {function()} = {}
	table.insert(tasks, guarded("P8", function()
		log("P8", ("camera (%.1f %.1f)"):format(c.x, c.y))
		for __, kind in ipairs({ "track", "street" }) do
			local f = nearest(c, kind)
			found[kind] = f
			if f ~= nil then
				log("P8", ("nearest %s: edge %d, %.0f m away at (%.1f %.1f), height %.2f, ground %.2f"):format(kind,
					f.entity, geo.len(geo.sub(c, f.p)), f.p.x, f.p.y, f.z, groundAt(f.p)))
			else
				log("P8", "no " .. kind .. " within 200 m")
			end
		end
	end))
	for __, kind in ipairs({ "track", "street" }) do
		for __, h in ipairs(P8_HEIGHTS) do
			table.insert(tasks, guarded("P8", function()
				local f = found[kind]
				if f == nil then
					return
				end
				-- Square across it, 300 m centred on the crossing point, a bridge throughout.
				local across : Pt = { x = -f.dir.y, y = f.dir.x }
				local start = geo.add(f.p, geo.scale(across, -150))
				local name = ("P8 %s +%.0f m"):format(kind, h)
				logCollisions(name, tryPlan(name, testPlan({ straight(start, across, 300) }, f.z + h, 0, "bridge"),
					settings, o))
			end))
		end
	end
	table.insert(tasks, function()
		log("P8", "done")
	end)
	return tasks
end

-- P13 ------------------------------------------------------------------------------------------------------------

function probe.stationStreets() : {function()}
	return { guarded("P13", function()
		local c = camera()
		local station : integer = nil
		local bestD = math.huge
		for __, e in ipairs(api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(c.x, c.y), 300,
				api.type.ComponentType.CONSTRUCTION)) do
			local con = api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION) as Engine.Component.Construction
			if con ~= nil and tostring(con.fileName):find("modular_station.con", 1, true) ~= nil then
				local m = con.transf
				local d = math.sqrt((m[13] - c.x) ^ 2 + (m[14] - c.y) ^ 2)
				if d < bestD then
					station, bestD = e, d
				end
			end
		end
		if station == nil then
			log("P13", "no modular station within 300 m of the camera")
			return
		end
		local con = api.engine.getComponent(station, api.type.ComponentType.CONSTRUCTION) as Engine.Component.Construction
		local m = con.transf
		local ox, oy, oz = m[13], m[14], m[15]
		-- Local x and y axes in the world (columns 1 and 2).
		local xx, xy, yx, yy = m[1], m[2], m[5], m[6]
		local function toLocal(v : Vec3f) : string
			local dx, dy = v.x - ox, v.y - oy
			return ("(%.2f %.2f %.2f)"):format(dx * xx + dy * xy, dx * yx + dy * yy, v.z - oz)
		end
		local function dirLocal(v : Vec3f) : string
			return ("(%.2f %.2f %.2f)"):format(v.x * xx + v.y * xy, v.x * yx + v.y * yy, v.z)
		end
		log("P13", ("station %d at (%.1f %.1f %.1f), local x (%.3f %.3f), local y (%.3f %.3f), %.0f m from the camera")
			:format(station, ox, oy, oz, xx, xy, yx, yy, bestD))
		pcall(function() : boolean
			for slot, mod in pairs((con.params as any as {string : {integer : {string : any}}}).modules) do
				local name = tostring(mod.name)
				if name:find("building", 1, true) ~= nil or name:find("stairs", 1, true) ~= nil then
					log("P13", ("module slot %s %s"):format(tostring(slot), name))
				end
			end
			return true
		end)
		local frozen : {integer : boolean} = {}
		for __, n in ipairs(con.frozenNodes) do
			frozen[n as integer] = true
		end
		for __, e in ipairs(con.frozenEdges) do
			if api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE_STREET) ~= nil then
				log("P13", ("frozen street edge %d"):format(e as integer))
			end
		end
		local count = 0
		for __, e in ipairs(api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(ox, oy), 200,
				api.type.ComponentType.BASE_EDGE)) do
			if api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE_STREET) ~= nil then
				local edge = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
				local function nodeInfo(n : integer) : string
					local segs = api.engine.system.streetSystem.getNodeSegments ~= nil
						and #(api.engine.system.streetSystem as any as {string : function(integer) : {integer}})
							.getNodeSegments(n) or -1
					return ("%d%s(%d pieces)"):format(n, frozen[n] and " frozen " or " ", segs)
				end
				log("P13", ("street %d %s: %s -> %s, t0 %s t1 %s, nodes %s / %s, type %s"):format(e as integer,
					tostring(edge.roadTemplate), toLocal(edge.position0), toLocal(edge.position1), dirLocal(edge.tangent0),
					dirLocal(edge.tangent1), nodeInfo(edge.node0 as integer), nodeInfo(edge.node1 as integer),
					tostring(edge.type)))
				count = count + 1
			end
		end
		log("P13", ("done: %d street pieces within 200 m"):format(count))
	end) }
end

-- P14 ------------------------------------------------------------------------------------------------------------

-- A built edge's signals as the game has them: for each of its transport edges, the signal each way and its type.
local function signalsOn(entity : integer) : string
	local parts : {string} = {}
	local tn = api.engine.getComponent(entity, api.type.ComponentType.TRANSPORT_NETWORK) as {string : any}
	local count = tn ~= nil and #(tn.edges as {any}) or 1
	for k = 0, count - 1 do
		for __, reversed in ipairs({ false, true }) do
			local ok, text = pcall(function() : string
				local id = api.engine.system.signalSystem.getSignal(api.type.EdgeId.new(entity, k), reversed)
				if id == nil or id.entity == nil or (id.entity as integer) < 0 then
					return nil
				end
				local list = api.engine.getComponent(id.entity, api.type.ComponentType.SIGNAL_LIST) as {string : any}
				local sig = (list.signals as {{string : any}})[id.index + 1]
				return ("edge %d %s: signal %d type %s"):format(k, reversed and "reversed" or "forward", id.entity as integer,
					tostring(sig ~= nil and sig.type))
			end)
			if ok and text ~= nil then
				table.insert(parts, text as string)
			end
		end
	end
	return #parts > 0 and table.concat(parts, "; ") or "no signals"
end

function probe.halt(settings : Settings) : {function()}
	local c = camera()
	local east : Pt = { x = 1, y = 0 }
	local ground = groundAt(c)
	local era = sl.eraLetter(settings.year)
	local opts : Options = {}
	for k, v in pairs(settings.network as {string : any}) do
		(opts as {string : any})[k] = v
	end
	opts.fan = network.turnoutLength(300)
	opts.blockSpacing = 200
	opts.chunkLength = 100000
	local s = with(settings, function(copy : Settings)
		copy.addons = { building = MODULE_DIR .. "main_building_1_era_" .. era .. ".module",
			stairs = MODULE_DIR .. "addon_platform_passenger_stairs_era_" .. era .. ".module" }
		copy.style = "halt"
		copy.network = opts
	end)
	s.levelCrossings = settings.levelCrossings
	-- The station at the camera facing east, a 600 m line off its east end.
	local plan = testPlan({ straight(geo.add(c, geo.scale(east, 80)), east, 600) }, ground, 0, "ground")
	plan.stations = { { town = { id = -1, name = "Probe", pos = { x = c.x, y = c.y - 200 } },
		site = { centre = c, dir = east, distance = 0 }, z = ground } }
	return { guarded("P14", function()
		-- Which signal resource name the game knows.
		local letter = settings.year < 1950 and "a" or "c"
		for __, name in ipairs({ "::/infrastructure/signal/signal_path_" .. letter .. ".con",
				"::/infrastructure/signal/signal_path_" .. letter .. ".mdl",
				"infrastructure/signal/signal_path_" .. letter .. ".con" }) do
			local okM, m = pcall(function() : integer return api.res.modelRep.find(name) end)
			local okC, con = pcall(function() : integer return api.res.constructionRep.find(name) end)
			log("P14", ("signal %s: modelRep %s, constructionRep %s"):format(name, tostring(okM and m), tostring(okC and con)))
			if s.signal == nil and ((okM and m as integer >= 0) or (okC and con as integer >= 0)) then
				s.signal = name
			end
		end
		s.signal = s.signal or "::/infrastructure/signal/signal_path_" .. letter .. ".con"
		log("P14", "using signal " .. s.signal)
		local net = network.build(plan, opts)
		local fans, crossovers, marks = 0, 0, 0
		for __, e in ipairs(net.edges) do
			fans = fans + (e.track == 3 and 1 or 0)
			crossovers = crossovers + (e.track == 0 and 1 or 0)
			for __, sg in ipairs(e.signals or {}) do
				marks = marks + 1
				local at = network.hermiteAt({ p0 = e.p0, p1 = e.p1, t0 = e.t0, t1 = e.t1 }, sg.param)
				log("P14", ("planned signal on track %d edge (%.1f %.1f)->(%.1f %.1f) at %.2f (%.1f %.1f), facing %s"):format(
					e.track, e.p0.x - c.x, e.p0.y - c.y, e.p1.x - c.x, e.p1.y - c.y, sg.param, at.x - c.x, at.y - c.y,
					sg.forward and "node0->node1" or "node1->node0"))
			end
		end
		log("P14", ("network: %d edges, %d chunks, %d fan pieces, %d crossovers, %d signals"):format(#net.edges,
			#net.chunks, fans, crossovers, marks))
		local station, why = builder.stationProposal(plan, 1, s)
		if station == nil then
			log("P14", "no station proposal: " .. tostring(why))
			return
		end
		local ok, cost, messages = builder.dryRun(station)
		log("P14", ("station dry run: %s, %d"):format(ok and "clean" or table.concat(messages, "; "), cost))
		if not ok then
			return
		end
		api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(station, builder.newContext(), false, true),
			function(__ : any, success : boolean)
				guarded("P14", function()
					log("P14", "station built: " .. tostring(success))
					if not success then
						return
					end
					log("P14", "station joined: " .. tostring(builder.builtStation(plan, 1, net)))
					local joined = 0
					for __, n in ipairs(net.nodes) do
						joined = joined + (n.entity ~= nil and 1 or 0)
					end
					log("P14", ("%d network nodes joined to the station's track ends"):format(joined))
					local chunk = net.chunks[1]
					local proposal, whyNot = builder.chunkProposal(net, chunk.first, chunk.last, s)
					if proposal == nil then
						log("P14", "no line proposal: " .. tostring(whyNot))
						return
					end
					local okL, costL, messagesL, __, data = builder.dryRun(proposal)
					local hits : {string} = {}
					for __, h in ipairs(builder.collisions(data)) do
						table.insert(hits, ("%s %d"):format(h.what, h.entity))
					end
					log("P14", ("line dry run: %s, %d %s"):format(okL and "clean" or table.concat(messagesL, "; "), costL,
						table.concat(hits, ", ")))
					if not okL then
						return
					end
					api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(proposal, builder.newContext(), false, true),
						function(res : WorldBuildProposalCommandData, built : boolean)
							guarded("P14", function()
								log("P14", "line built: " .. tostring(built))
								if not built then
									return
								end
								for __, seg in ipairs(res.proposal.proposal.addedSegments) do
									local e = seg.entity as integer
									local edge = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE) as
										Engine.Component.BaseEdge
									if edge ~= nil and #(edge.objects or {}) > 0 then
										log("P14", ("built edge %d (%.1f %.1f)->(%.1f %.1f), %d objects: %s"):format(e,
											edge.position0.x - c.x, edge.position0.y - c.y, edge.position1.x - c.x,
											edge.position1.y - c.y, #edge.objects, signalsOn(e)))
									end
								end
								log("P14", "done")
							end)()
						end)
				end)()
			end)
	end) }
end

-- P15 ------------------------------------------------------------------------------------------------------------
-- A flat junction into existing signalled double track (milestone 4b), in three stages, one click each. The local
-- frame is x east and y north from the origin (the camera at stage 1).

local type Hermite = PgraceRailRouterNetwork.Hermite
local type Pt3 = PgraceRailRouterNetwork.Pt3

local record P15Piece
	entity : integer
	node0 : integer
	node1 : integer
	h : Hermite
	objects : integer
	-- 1 the left (north) track, 2 the right, 0 neither.
	track : integer
end

local record P15Cut
	track : integer
	x : number
end

local record P15State
	origin : Pt
	z : number
	off : number
	-- Where stage 1 put the signal on track 1.
	signalPt : Pt
	pieces : {P15Piece}
	-- Which track a piece is on (P17: by its own frame); nil: by y = ±off from the origin (P15).
	classify : function(Hermite) : integer
end

local p15Stage = 1
local p15 : P15State = { z = 0, off = 2.5, pieces = {} }
-- The probe whose state the shared helpers below (rel, trackOf, splitTrack, repairNodes, ...) use, and log under.
local cur : P15State = p15
local tag = "P15"
-- PROBE (remove before release): P17 runs too; a failed callback frees it as well.
local p17Busy = false

local function v3of(p : Pt3) : Vec3f
	return api.type.Vec3f.new(p.x, p.y, p.z)
end

local function p3of(v : Vec3f) : Pt3
	return { x = v.x, y = v.y, z = v.z }
end

-- A point relative to the origin, as text.
local function rel(p : Pt3) : string
	if cur.origin == nil then
		return ("(%.1f %.1f %.1f)"):format(p.x, p.y, p.z)
	end
	return ("(%.1f %.1f %.1f)"):format(p.x - cur.origin.x, p.y - cur.origin.y, p.z)
end

local function trackOf(h : Hermite) : integer
	if cur.classify ~= nil then
		return cur.classify(h)
	end
	local o = cur.origin
	for __, t in ipairs({ 1, 2 }) do
		local y = o.y + (t == 1 and cur.off or -cur.off)
		if math.abs(h.p0.y - y) < 0.6 and math.abs(h.p1.y - y) < 0.6 then
			return t
		end
	end
	return 0
end

-- Every plain track piece around the line, read fresh.
local function scanPieces() : {P15Piece}
	local list : {P15Piece} = {}
	local o = p15.origin
	local found = api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(o.x + 200, o.y), 300,
		api.type.ComponentType.BASE_EDGE)
	for __, e in ipairs(found) do
		pcall(function() : boolean
			local edge = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
			if edge == nil or edge.roadType ~= api.type["enum"].RoadType.TRACK
					or edge.type ~= api.type["enum"].BaseEdgeType.NORMAL then
				return true
			end
			local h : Hermite = { p0 = p3of(edge.position0), p1 = p3of(edge.position1), t0 = p3of(edge.tangent0),
				t1 = p3of(edge.tangent1) }
			table.insert(list, { entity = e as integer, node0 = edge.node0 as integer, node1 = edge.node1 as integer,
				h = h, objects = #(edge.objects or {}), track = trackOf(h) })
			return true
		end)
	end
	table.sort(list, function(a : P15Piece, b : P15Piece) : boolean
		return math.min(a.h.p0.x, a.h.p1.x) < math.min(b.h.p0.x, b.h.p1.x)
	end)
	p15.pieces = list
	return list
end

local function logPiece(p : P15Piece)
	local ok, text = pcall(function() : string
		return signalsOn(p.entity)
	end)
	log(tag, ("piece %d track %d nodes %d/%d %s -> %s, %d objects: %s"):format(p.entity, p.track, p.node0, p.node1,
		rel(p.h.p0), rel(p.h.p1), p.objects, ok and text as string or "signalsOn failed"))
end

local function logTracks(list : {P15Piece})
	for __, p in ipairs(list) do
		if p.track ~= 0 then
			logPiece(p)
		end
	end
end

-- The pieces a build or split proposal added, as the game has them now.
local function logAdded(what : string, res : WorldBuildProposalCommandData)
	local sp = res.proposal.proposal
	for __, n in ipairs(sp.addedNodes) do
		local ok, pos = pcall(function() : Vec3f
			return (api.engine.getComponent(n.entity, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode).position
		end)
		log(tag, ("%s: new node %d at %s"):format(what, n.entity as integer, ok and rel(p3of(pos as Vec3f)) or "?"))
	end
	for __, seg in ipairs(sp.addedSegments) do
		local e = seg.entity as integer
		local edge = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
		if edge == nil then
			log(tag, ("%s: new piece %d has no BASE_EDGE"):format(what, e))
		else
			local h : Hermite = { p0 = p3of(edge.position0), p1 = p3of(edge.position1), t0 = p3of(edge.tangent0),
				t1 = p3of(edge.tangent1) }
			logPiece({ entity = e, node0 = edge.node0 as integer, node1 = edge.node1 as integer, h = h,
				objects = #(edge.objects or {}), track = trackOf(h) })
		end
	end
end

-- The node (entity, position) of any piece's end within 0.5 m of a point.
local function findNodeAt(list : {P15Piece}, x : number, y : number) : integer, Pt3
	for __, p in ipairs(list) do
		for k = 1, 2 do
			local pos = k == 1 and p.h.p0 or p.h.p1
			if (pos.x - x) ^ 2 + (pos.y - y) ^ 2 < 0.25 then
				return k == 1 and p.node0 or p.node1, pos
			end
		end
	end
	return nil, nil
end

-- The piece of a track holding x, metres east of the probe's origin (pieces are in world coordinates).
local function findPiece(list : {P15Piece}, track : integer, x : number) : P15Piece
	x = x + p15.origin.x
	for __, p in ipairs(list) do
		if p.track == track and math.min(p.h.p0.x, p.h.p1.x) <= x and x <= math.max(p.h.p0.x, p.h.p1.x) then
			return p
		end
	end
	return nil
end

-- A track piece from node0 to node1 along h, typed like the one it replaces. Objects (the signals) are listed on it
-- by the caller.
local function trackPiece(node0 : integer, node1 : integer, h : Hermite, template : Proposal.SegmentAndEntity)
		: Proposal.SegmentAndEntity
	local seg = api.type.SegmentAndEntity.new()
	seg.type = 1
	seg.comp.node0, seg.comp.node1 = node0, node1
	seg.comp.position0, seg.comp.position1 = v3of(h.p0), v3of(h.p1)
	seg.comp.tangent0, seg.comp.tangent1 = v3of(h.t0), v3of(h.t1)
	seg.comp.type = template.comp.type
	seg.comp.typeIndex = template.comp.typeIndex
	seg.comp.laneConfigs = template.comp.laneConfigs
	seg.comp.roadType = template.comp.roadType
	seg.comp.roadTemplate = template.comp.roadTemplate
	seg.comp.roadStyle = template.comp.roadStyle
	seg.comp.distance = template.comp.distance
	if template.streetEdge ~= nil then
		seg.streetEdge = template.streetEdge
	end
	if template.playerOwned ~= nil then
		seg.playerOwned = template.playerOwned
	end
	return seg
end

-- A piece shorter than this (metres, in plan) is never made by a split: the game refuses switches next to short edges
-- (P12) and a split can't be dry-run, so the guard is ours.
local MIN_PIECE = 10.0

local function chord(h : Hermite) : number
	return math.sqrt((h.p1.x - h.p0.x) ^ 2 + (h.p1.y - h.p0.y) ^ 2)
end

-- A track piece in pieces at parameters us (ascending), new nodes -(k+2)..: the engine's replaceSegment proposal
-- edited, as build.tl splits a street. objectAt are the world places of the piece's signals (in the order of the
-- template's objects); each signal goes on the sub-piece that holds its place. Returns nil, after logging why,
-- when the split would be unsafe: a split can't be dry-run, so nothing doubtful is sent.
local function splitTrack(piece : P15Piece, us : {number}, objectAt : {Pt}) : Proposal
	-- The sub-pieces first, and the guards on them.
	local hs : {Hermite} = {}
	local rest = piece.h
	local restU = 0.0
	for __, u in ipairs(us) do
		if u < 0.02 or u > 0.98 then
			log(tag, ("REFUSED split of %d: parameter %.4f is outside 0.02..0.98"):format(piece.entity, u))
			return nil
		end
		local here, after = network.splitHermite(rest, (u - restU) / (1 - restU))
		table.insert(hs, here)
		rest, restU = after, u
	end
	table.insert(hs, rest)
	for j, sh in ipairs(hs) do
		if chord(sh) < MIN_PIECE then
			log(tag, ("REFUSED split of %d: sub-piece %d would be %.1f m (under %.0f m)"):format(piece.entity, j,
				chord(sh), MIN_PIECE))
			return nil
		end
	end
	local rep = api.engine.util.proposal.replaceSegment(piece.entity)
	local sp = rep.proposal
	local template = sp.addedSegments[1]
	local objs = template.comp.objects or {}
	local edgeObjects = (sp.edgeObjectsToAdd or {}) as {any}
	log(tag, ("replaceSegment(%d): %d added segments, %d added nodes, %d removed segments, %d edge objects to add, %d node configs, template objects %d"):format(
		piece.entity, #sp.addedSegments, #sp.addedNodes, #(sp.removedSegments or {}), #edgeObjects,
		#(sp.nodeConfigsToAdd or {}), #objs))
	if #edgeObjects > 0 and #edgeObjects ~= #objs then
		log(tag, ("REFUSED split of %d: %d edge objects to add against %d objects on the piece"):format(piece.entity,
			#edgeObjects, #objs))
		return nil
	end
	-- What the engine says about the objects, to compare with what we send.
	for i, eo in ipairs(edgeObjects) do
		local okE, text = pcall(function() : string
			local t = eo as {string : any}
			return ("edgeEntity %s param %s model %s left %s"):format(tostring(t.edgeEntity), tostring(t.param),
				tostring(t.model), tostring(t.left))
		end)
		log(tag, ("edgeObjectsToAdd[%d]: %s"):format(i, okE and text as string or "unreadable: " .. tostring(text)))
	end
	for __, field in ipairs({ "new2oldEdgeObjects", "old2newEdgeObjects" }) do
		pcall(function() : boolean
			local m = (sp as any as {string : any})[field] as {any : any}
			local parts : {string} = {}
			if m ~= nil then
				for from, to in pairs(m) do
					local list : {string} = {}
					if type(to) == "table" then
						for __, x in ipairs(to as {any}) do
							table.insert(list, tostring(x))
						end
					else
						table.insert(list, tostring(to))
					end
					table.insert(parts, tostring(from) .. " -> " .. table.concat(list, ","))
				end
			end
			log(tag, ("%s: %s"):format(field, #parts > 0 and table.concat(parts, "; ") or "empty"))
			return true
		end)
	end
	-- Which sub-piece holds each signal (the nearest point on each sub-piece's own curve), and its parameter there.
	local objJ : {integer} = {}
	local objU : {number} = {}
	local lists : {{any}} = {}
	for __ = 1, #hs do
		table.insert(lists, {})
	end
	for idx, o in ipairs(objs) do
		local okO, a, b = pcall(function() : any, any
			return (o as {any})[1], (o as {any})[2]
		end)
		if not okO or a == nil or b == nil then
			log(tag, ("REFUSED split of %d: object %d isn't a readable {entity, type} pair (%s, %s)"):format(piece.entity,
				idx, tostring(a), tostring(b)))
			return nil
		end
		local at = objectAt[idx] or objectAt[1]
		if at == nil then
			log(tag, ("REFUSED split of %d: object %d has no known place"):format(piece.entity, idx))
			return nil
		end
		local bestJ, bestD, bestU = 1, math.huge, 0.0
		for j, sh in ipairs(hs) do
			local u = network.nearestParam(sh, at)
			local q = network.hermiteAt(sh, u)
			local d = (q.x - at.x) ^ 2 + (q.y - at.y) ^ 2
			if d < bestD then
				bestJ, bestD, bestU = j, d, u
			end
		end
		log(tag, ("object %d (entity %s, type %s) goes on sub-piece %d at param %.3f, %.2f m off its curve"):format(idx,
			tostring(a), tostring(b), bestJ, bestU, math.sqrt(bestD)))
		objJ[idx], objU[idx] = bestJ, bestU
		table.insert(lists[bestJ], { a, b })
	end
	local nodes : {Proposal.NodeAndEntity} = {}
	local pieces : {Proposal.SegmentAndEntity} = {}
	local prev = piece.node0
	local k = #us
	for j = 1, #hs do
		local node1 = piece.node1
		if j <= k then
			local n = api.type.NodeAndEntity.new()
			n.entity = -(k + 1 + j)
			n.comp.position = v3of(hs[j].p1)
			table.insert(nodes, n)
			node1 = n.entity as integer
		end
		local seg = trackPiece(prev, node1, hs[j], template)
		seg.entity = -j
		if #lists[j] > 0 then
			(seg.comp as any as {string : any}).objects = lists[j]
		end
		table.insert(pieces, seg)
		prev = node1
	end
	-- The engine's own object entries, pointed at the sub-piece that now holds each signal, so the proposal agrees
	-- with itself.
	for i, eo in ipairs(edgeObjects) do
		if objJ[i] ~= nil then
			local okW, err = pcall(function() : boolean
				local t = eo as {string : any}
				t.edgeEntity = pieces[objJ[i]].entity
				t.param = objU[i]
				return true
			end)
			log(tag, ("edgeObjectsToAdd[%d] rewritten to edge %d param %.3f: %s"):format(i, pieces[objJ[i]].entity,
				objU[i], okW and "ok" or tostring(err)))
			if not okW then
				log(tag, ("REFUSED split of %d: edge object %d couldn't be rewritten"):format(piece.entity, i))
				return nil
			end
		end
	end
	-- The list read from the proposal may be a copy: hand the rewritten one back.
	if #edgeObjects > 0 then
		sp.edgeObjectsToAdd = edgeObjects as any as {Proposal.EdgeObject}
	end
	sp.addedNodes = nodes
	sp.addedSegments = pieces
	sp.nodeConfigsToAdd = {}
	return rep
end

local p15Busy = false

local function sendProposal(proposal : any, done : function(WorldBuildProposalCommandData, boolean))
	api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(proposal as SimpleProposal, builder.newContext(), false, true),
		function(res : WorldBuildProposalCommandData, success : boolean)
			local ok, err = pcall(function() : boolean
				done(res, success)
				return true
			end)
			if not ok then
				log(tag, "ERROR " .. tostring(err))
				p15Busy = false
				p17Busy = false
			end
		end)
end

local function p15Done(stage : integer, ok : boolean)
	p15Busy = false
	if ok then
		p15Stage = stage % 3 + 1
		log("P15", ("stage %d finished; the next click runs stage %d"):format(stage, p15Stage))
	else
		log("P15", ("stage %d did not finish: click again to retry stage %d"):format(stage, stage))
	end
end

local function hasConfig(node : integer) : string
	local ok, c = pcall(function() : any
		return api.engine.getComponent(node, api.type.ComponentType.BASE_NODE_CONFIG)
	end)
	return (ok and c ~= nil) and "has a BASE_NODE_CONFIG" or ("NO BASE_NODE_CONFIG" .. (ok and "" or " (read failed)"))
end

-- A split leaves its new nodes without lane connections (nodeConfigsToAdd is emptied). Sends the engine's own,
-- unedited replaceSegment for each track piece at the nodes, one at a time (build.tl's stepRepair for streets), and
-- logs whether each node has its config before and after.
local function repairNodes(what : string, nodes : {integer}, done : function())
	for __, n in ipairs(nodes) do
		log(tag, ("%s: node %d before repair: %s"):format(what, n, hasConfig(n)))
	end
	local queue : {integer} = {}
	local seen : {integer : boolean} = {}
	for __, n in ipairs(nodes) do
		local ok, segs = pcall(function() : {any}
			return api.engine.system.streetSystem.getNodeTrackSegments(n) as {any}
		end)
		if ok then
			for __, sg in ipairs(segs as {any}) do
				local e = sg as integer
				if not seen[e] then
					seen[e] = true
					table.insert(queue, e)
				end
			end
		else
			log(tag, ("%s: getNodeTrackSegments(%d) failed: %s"):format(what, n, tostring(segs)))
		end
	end
	local function step()
		local seg = table.remove(queue, 1)
		if seg == nil then
			for __, n in ipairs(nodes) do
				log(tag, ("%s: node %d after repair: %s"):format(what, n, hasConfig(n)))
			end
			return done()
		end
		if not api.engine.entityExists(seg) then
			log(tag, ("%s: piece %d is gone: skipped"):format(what, seg))
			return step()
		end
		local ok, rep = pcall(function() : Proposal
			return api.engine.util.proposal.replaceSegment(seg)
		end)
		if not ok or rep == nil then
			log(tag, ("%s: repair of piece %d: replaceSegment failed: %s"):format(what, seg, tostring(rep)))
			return step()
		end
		sendProposal(rep, function(__ : WorldBuildProposalCommandData, success : boolean)
			log(tag, ("%s: repair of piece %d: %s"):format(what, seg, tostring(success)))
			step()
		end)
	end
	step()
end

-- What a split sent: log it, then repair the nodes it made.
local function afterSplit(what : string, res : WorldBuildProposalCommandData, done : function())
	logAdded(what, res)
	local ids : {integer} = {}
	for __, n in ipairs(res.proposal.proposal.addedNodes) do
		table.insert(ids, n.entity as integer)
	end
	repairNodes(what, ids, done)
end

-- Stage 1: 400 m of double track east of the camera, a one-way signal on each track at x = 300.
local function p15Build(settings : Settings)
	local c = camera()
	p15.origin = c
	p15.z = groundAt(c)
	p15.off = settings.network.offset
	local east : Pt = { x = 1, y = 0 }
	local opts : Options = {}
	for k, v in pairs(settings.network as {string : any}) do
		(opts as {string : any})[k] = v
	end
	opts.fan = nil
	opts.crossovers = false
	opts.chunkLength = 100000
	-- One 400 m piece per track: no node on track 2 near stage 3's crossing at x = 200 (with two 200 m pieces, the
	-- crossing beside track 2's node at x = 200 was refused, one at x = 245 wasn't).
	opts.maxEdge = 1000
	local s = with(settings, function(copy : Settings)
		copy.network = opts
		copy.signal = "::/infrastructure/signal/signal_path_" .. (settings.year < 1950 and "a" or "c") .. ".con"
	end)
	local plan = testPlan({ straight(c, east, 400) }, p15.z, 0, "ground")
	local net = network.build(plan, opts)
	for __, e in ipairs(net.edges) do
		if (e.track == 1 or e.track == 2) and e.s0 <= 300 and 300 <= e.s1 then
			local u = (300 - e.s0) / (e.s1 - e.s0)
			e.signals = { { param = u, forward = e.track == 2 } }
			log("P15", ("signal on track %d edge s %.1f..%.1f at %.3f, facing %s"):format(e.track, e.s0, e.s1, u,
				e.track == 2 and "east (node0->node1)" or "west (node1->node0)"))
		end
	end
	p15.signalPt = { x = c.x + 300, y = c.y + p15.off }
	local proposal, why = builder.chunkProposal(net, 1, #net.edges, s)
	if proposal == nil then
		log("P15", "no proposal: " .. tostring(why))
		return p15Done(1, false)
	end
	local ok, cost, messages, __, data = builder.dryRun(proposal)
	log("P15", ("stage 1 dry run: %s, %d"):format(ok and "clean" or table.concat(messages, "; "), cost))
	logCollisions("P15", data)
	if not ok then
		return p15Done(1, false)
	end
	sendProposal(proposal, function(res : WorldBuildProposalCommandData, success : boolean)
		log("P15", "stage 1 built: " .. tostring(success))
		if not success then
			return p15Done(1, false)
		end
		logAdded("stage 1", res)
		log("P15", "tracks as scanned:")
		logTracks(scanPieces())
		p15Done(1, true)
	end)
end

-- Stage 2: split track 1 at x = 100, then the piece with the signal at x = 270 (clear of stage 3's crossing at 200 and the signal at 300). A
-- cut that already has a node (a retry) is skipped: a second split there would make a ~0 m piece.
local function p15Split()
	local o = p15.origin
	if o == nil then
		log("P15", "no origin: run stage 1 first")
		return p15Done(2, false)
	end
	local function second()
		local list = scanPieces()
		if findNodeAt(list, o.x + 270, o.y + p15.off) ~= nil then
			log("P15", "split 2 skipped: a node is already at x = 270")
			logTracks(list)
			return p15Done(2, true)
		end
		local b : P15Piece = nil
		for __, p in ipairs(list) do
			if p.track == 1 and p.objects > 0 then
				b = p
			end
		end
		if b == nil then
			log("P15", "after split 1 no track 1 piece carries an object: the signal was lost")
			return p15Done(2, false)
		end
		log("P15", ("the signal piece is now %d"):format(b.entity))
		local u2 = network.nearestParam(b.h, { x = o.x + 270, y = o.y + p15.off })
		log("P15", ("split 2: piece %d at param %.4f"):format(b.entity, u2))
		local rep = splitTrack(b, { u2 }, { p15.signalPt })
		if rep == nil then
			return p15Done(2, false)
		end
		sendProposal(rep, function(res2 : WorldBuildProposalCommandData, success2 : boolean)
			log("P15", "split 2 sent: " .. tostring(success2))
			if not success2 then
				return p15Done(2, false)
			end
			afterSplit("split 2", res2, function()
				log("P15", "tracks after both splits:")
				logTracks(scanPieces())
				p15Done(2, true)
			end)
		end)
	end
	local list = scanPieces()
	if findNodeAt(list, o.x + 100, o.y + p15.off) ~= nil then
		log("P15", "split 1 skipped: a node is already at x = 100")
		return second()
	end
	local a = findPiece(list, 1, 100)
	if a == nil then
		log("P15", "no track 1 piece under x = 100")
		return p15Done(2, false)
	end
	local u = network.nearestParam(a.h, { x = o.x + 100, y = o.y + p15.off })
	log("P15", ("split 1: piece %d at param %.4f (x = 100)"):format(a.entity, u))
	local rep = splitTrack(a, { u }, a.objects > 0 and { p15.signalPt } or {})
	if rep == nil then
		return p15Done(2, false)
	end
	sendProposal(rep, function(res : WorldBuildProposalCommandData, success : boolean)
		log("P15", "split 1 sent: " .. tostring(success))
		if not success then
			return p15Done(2, false)
		end
		afterSplit("split 1", res, second)
	end)
end

-- The length of the main-track piece that runs east from a switch node (the branch's side), logged.
local function branchSide(list : {P15Piece}, what : string, node : integer)
	local best : number = nil
	for __, p in ipairs(list) do
		if p.track ~= 0 and (p.node0 == node or p.node1 == node) then
			local other = p.node0 == node and p.h.p1 or p.h.p0
			local here = p.node0 == node and p.h.p0 or p.h.p1
			if other.x > here.x then
				best = chord(p.h)
			end
		end
	end
	log("P15", ("%s: main piece on the branch's side is %s m (the game wants over 16.6)"):format(what,
		best ~= nil and ("%.1f"):format(best) or "not found"))
end

-- Stage 3, step 2: with every cut made, one proposal of the new track.
-- Stage 3's crossing track: its angle to track 1 at the crossing (degrees). It is one circular arc off track 2's
-- switch into the crossing node and its mirror out of it, so each piece that lies over an existing track shares a node
-- with it (the game refuses a piece over track it isn't joined to: a node of ours 1.5 m beside track 2 was refused).
local CROSS_ANGLE = 12.0

-- The length along x of each of the crossing track's arcs: each climbs 2 * off.
local function crossRun() : number
	return 2 * p15.off / math.tan(math.rad(CROSS_ANGLE) / 2)
end

-- Where the crossing track leaves track 2.
local function crossSwitchX() : number
	return 200 - crossRun()
end

local function p15Junction(settings : Settings)
	local o = p15.origin
	local off = p15.off
	local list = scanPieces()
	local n1, p1 = findNodeAt(list, o.x + 60, o.y + off)
	local n4, p4 = findNodeAt(list, o.x + crossSwitchX(), o.y - off)
	local n5, p5 = findNodeAt(list, o.x + 200, o.y + off)
	if n1 == nil or n4 == nil or n5 == nil then
		log("P15", ("cut nodes missing: x=60 %s, track 2 switch %s, x=200 %s"):format(tostring(n1), tostring(n4), tostring(n5)))
		return p15Done(3, false)
	end
	log("P15", ("cut nodes: x=60 -> %d, track 2 switch -> %d, crossing x=200 -> %d"):format(n1, n4, n5))
	branchSide(list, "switch at x=60 (track 1)", n1)
	branchSide(list, "switch on track 2", n4)
	local z = p1.z
	local function at(x : number, y : number, node ?: integer) : Pt3
		return { x = o.x + x, y = o.y + y, z = z, entity = node }
	end
	-- The crossing track: an arc from track 2's switch into the crossing node at CROSS_ANGLE, the mirror arc out of
	-- it onto our near track's line, then straight on.
	local theta = math.rad(CROSS_ANGLE)
	local run = crossRun()
	local radius = run / math.sin(theta)
	local cx = 200.0
	local nodes : {Pt3} = {
		{ x = p1.x, y = p1.y, z = p1.z, entity = n1 },
		at(170, 5 * off),
		at(330, 5 * off),
		{ x = p4.x, y = p4.y, z = p4.z, entity = n4 },
		{ x = p5.x, y = p5.y, z = p5.z, entity = n5 },
		at(cx + run, 3 * off),
		at(330, 3 * off),
	}
	log("P15", ("crossing track: %.1f degrees at the crossing, arcs of radius %.0f m over %.1f m; its switch at x = %.1f"):format(
		CROSS_ANGLE, radius, run, p4.x - o.x))
	local function dir(dx : number) : Pt3
		return { x = dx, y = 0, z = 0 }
	end
	local edges : {PgraceRailRouterNetwork.Edge} = {}
	local function add(a_ : integer, b_ : integer, h : Hermite)
		table.insert(edges, { node0 = a_, node1 = b_, p0 = h.p0, p1 = h.p1, t0 = h.t0, t1 = h.t1, kind = "ground", track = 0,
			leg = 1, s0 = 0, s1 = 0 })
	end
	-- A circular arc's tangents are as long as the arc (R theta).
	local arc = radius * theta
	local slant : Pt3 = { x = math.cos(theta) * arc, y = math.sin(theta) * arc, z = 0 }
	-- All edges run east from their first node, as they leave an existing node there.
	add(1, 2, { p0 = nodes[1], p1 = nodes[2], t0 = dir(nodes[2].x - nodes[1].x), t1 = dir(nodes[2].x - nodes[1].x) })
	add(2, 3, { p0 = nodes[2], p1 = nodes[3], t0 = dir(nodes[3].x - nodes[2].x), t1 = dir(nodes[3].x - nodes[2].x) })
	add(4, 5, { p0 = nodes[4], p1 = nodes[5], t0 = dir(arc), t1 = slant })
	add(5, 6, { p0 = nodes[5], p1 = nodes[6], t0 = slant, t1 = dir(arc) })
	add(6, 7, { p0 = nodes[6], p1 = nodes[7], t0 = dir(nodes[7].x - nodes[6].x), t1 = dir(nodes[7].x - nodes[6].x) })
	local net : PgraceRailRouterNetwork.Network = { nodes = nodes, edges = edges, chunks = {} }
	for __, part in ipairs({ { "merge only", 1, 2 }, { "crossing track only", 3, 5 },
			{ "switch to crossing node only", 3, 3 } }) do
		local pr, whyNot = builder.chunkProposal(net, part[2] as integer, part[3] as integer, settings)
		if pr == nil then
			log("P15", ("%s: no proposal: %s"):format(part[1], tostring(whyNot)))
		else
			local okP, costP, messagesP, ___, dataP = builder.dryRun(pr)
			local hits : {string} = {}
			for __, h in ipairs(builder.collisions(dataP)) do
				table.insert(hits, ("%s %d"):format(h.what, h.entity))
			end
			log("P15", ("%s dry run: %s, %d %s"):format(part[1], okP and "clean" or table.concat(messagesP, "; "), costP,
				table.concat(hits, ", ")))
		end
	end
	local proposal, why = builder.chunkProposal(net, 1, #edges, settings)
	if proposal == nil then
		log("P15", "no junction proposal: " .. tostring(why))
		return p15Done(3, false)
	end
	local ok, cost, messages, __, data = builder.dryRun(proposal)
	log("P15", ("junction dry run: %s, %d"):format(ok and "clean" or table.concat(messages, "; "), cost))
	for __, h in ipairs(builder.collisions(data)) do
		log("P15", ("collision: %s %d"):format(h.what, h.entity))
	end
	if not ok then
		return p15Done(3, false)
	end
	sendProposal(proposal, function(res : WorldBuildProposalCommandData, success : boolean)
		log("P15", "junction built: " .. tostring(success))
		if not success then
			return p15Done(3, false)
		end
		logAdded("junction", res)
		for __, pair in ipairs({ { "x=60 switch", n1 }, { "track 2 switch", n4 }, { "x=200 crossing", n5 } }) do
			local okS, segs = pcall(function() : {any}
				return api.engine.system.streetSystem.getNodeTrackSegments(pair[2] as integer) as {any}
			end)
			if okS then
				local ids : {string} = {}
				for __, sgm in ipairs(segs as {any}) do
					table.insert(ids, tostring(sgm))
				end
				log("P15", ("node %s (%d): %d track pieces: %s"):format(pair[1] as string, pair[2] as integer,
					#(segs as {any}), table.concat(ids, " ")))
			else
				log("P15", ("node %s: getNodeTrackSegments failed: %s"):format(pair[1] as string, tostring(segs)))
			end
		end
		-- The existing nodes now have a branch: the engine's own proposal for each piece there gives the lanes.
		repairNodes("junction", { n1, n4, n5 }, function()
			log("P15", "tracks after the junction:")
			for __, p in ipairs(scanPieces()) do
				logPiece(p)
			end
			p15Done(3, true)
		end)
	end)
end

-- Stage 3: cut the existing tracks where the junction meets them (one proposal per piece, one after another), then
-- build the junction. Cuts that already have a node are skipped, so a retry carries on.
local function p15Cuts(settings : Settings)
	local o = p15.origin
	if o == nil then
		log("P15", "no origin: run stage 1 first")
		return p15Done(3, false)
	end
	-- The crossing is at track 1's existing node at x = 200 (stage 1's piece end), so no cut there. The crossing
	-- track's switch is on track 2 where its arc onto the crossing line begins (x ≈ 153.5): from x = 180, 20 m short of
	-- the next node, the
	-- branch was refused ("Construction Not Possible"; it had pulled only 0.6 m clear of the main track there).
	local wanted : {P15Cut} = { { track = 1, x = 60 }, { track = 1, x = 200 }, { track = 2, x = crossSwitchX() } }
	local function nextCut(attempt : integer)
		if attempt > 8 then
			log("P15", "too many cuts")
			return p15Done(3, false)
		end
		local list = scanPieces()
		local pending : {P15Cut} = {}
		for __, c in ipairs(wanted) do
			if findNodeAt(list, o.x + c.x, o.y + (c.track == 1 and p15.off or -p15.off)) == nil then
				table.insert(pending, c)
			end
		end
		if #pending == 0 then
			return p15Junction(settings)
		end
		local piece = findPiece(list, pending[1].track, pending[1].x)
		if piece == nil then
			log("P15", ("no track %d piece holds x = %.0f"):format(pending[1].track, pending[1].x))
			return p15Done(3, false)
		end
		local us : {number} = {}
		for __, c in ipairs(pending) do
			local same = findPiece(list, c.track, c.x)
			if same ~= nil and same.entity == piece.entity then
				local u = network.nearestParam(piece.h, { x = o.x + c.x, y = o.y + (c.track == 1 and p15.off or -p15.off) })
				log("P15", ("cut: piece %d at param %.4f (x = %.0f, track %d)"):format(piece.entity, u, c.x, c.track))
				table.insert(us, u)
			end
		end
		table.sort(us)
		local rep = splitTrack(piece, us, piece.objects > 0 and { p15.signalPt } or {})
		if rep == nil then
			return p15Done(3, false)
		end
		sendProposal(rep, function(res : WorldBuildProposalCommandData, success : boolean)
			log("P15", "cut sent: " .. tostring(success))
			if not success then
				return p15Done(3, false)
			end
			afterSplit("cut", res, function()
				nextCut(attempt + 1)
			end)
		end)
	end
	nextCut(1)
end

function probe.junction(settings : Settings) : {function()}
	return { function()
		if p15Busy then
			log("P15", "busy: a stage is still running, click again when it has finished")
			return
		end
		p15Busy = true
		cur, tag = p15, "P15"
		local stage = p15Stage
		log("P15", ("stage %d"):format(stage))
		local ok, err = pcall(function() : boolean
			if stage == 1 then
				p15Build(settings)
			elseif stage == 2 then
				p15Split()
			else
				p15Cuts(settings)
			end
			return true
		end)
		if not ok then
			log("P15", "ERROR " .. tostring(err))
			p15Busy = false
		end
	end }
end

-- P16 ------------------------------------------------------------------------------------------------------------

-- P16: the game's own shallow crossing, copied. A track the player drew across a double track at 6.5° became a
-- diamond at each track: a straight crossing track through a node on each, four pieces there, each pair straight
-- on (P1, 2026-10-18). So: a 360 m double track east of the camera, both its tracks split where a straight track at
-- 6.5° crosses them, and that track built through the two nodes, dry-run with the spacing 0 (as our junction's
-- pieces) and 5 (as the game's), and built if one is clean. Uses P15's split and repair helpers and state.
local P16_ANGLE = 6.5

function probe.trackCrossing(settings : Settings) : {function()}
	return { guarded("P16", function()
		cur, tag = p15, "P15"
		local c = camera()
		local east : Pt = { x = 1, y = 0 }
		local ground = groundAt(c)
		p15.origin, p15.z, p15.off = c, ground, 2.5
		local opts : Options = {}
		for k, v in pairs(settings.network as {string : any}) do
			(opts as {string : any})[k] = v
		end
		opts.fan, opts.crossovers, opts.chunkLength, opts.maxEdge = nil, false, 100000, 250
		local s = with(settings, function(copy : Settings) copy.network = opts end)
		local net = network.build(testPlan({ straight(c, east, 360) }, ground, 0, "ground"), opts)
		local proposal, why = builder.chunkProposal(net, 1, #net.edges, s)
		if proposal == nil then
			log("P16", "no proposal: " .. tostring(why))
			return
		end
		local ok, __, messages = builder.dryRun(proposal)
		log("P16", "double track dry run: " .. (ok and "clean" or table.concat(messages, "; ")))
		if not ok then
			return
		end
		-- The crossing line: through (180, 0) at P16_ANGLE, from x = 60 to x = 300.
		local a = math.rad(P16_ANGLE)
		local slope = math.tan(a)
		local function onLine(x : number) : Pt3
			return { x = c.x + x, y = c.y + (x - 180) * slope, z = ground }
		end
		local x1 = 180 + 2.5 / slope
		local x2 = 180 - 2.5 / slope
		log("P16", ("crossing at %.1f degrees: track 1 (y = 2.5) at x = %.1f, track 2 (y = -2.5) at x = %.1f"):format(
			P16_ANGLE, x1, x2))
		local function split(track : integer, x : number, done : function())
			local list = scanPieces()
			if findNodeAt(list, c.x + x, c.y + (track == 1 and 2.5 or -2.5)) ~= nil then
				return done()
			end
			local piece = findPiece(list, track, x)
			if piece == nil then
				log("P16", ("no track %d piece at x = %.1f"):format(track, x))
				return
			end
			local u = network.nearestParam(piece.h, { x = c.x + x, y = c.y + (track == 1 and 2.5 or -2.5) })
			local rep = splitTrack(piece, { u }, {})
			if rep == nil then
				log("P16", "split refused")
				return
			end
			sendProposal(rep, function(res : WorldBuildProposalCommandData, success : boolean)
				log("P16", ("split of track %d at x = %.1f: %s"):format(track, x, tostring(success)))
				if success then
					afterSplit("P16 split", res, done)
				end
			end)
		end
		local function crossing()
			local list = scanPieces()
			local n1, q1 = findNodeAt(list, c.x + x1, c.y + 2.5)
			local n2, q2 = findNodeAt(list, c.x + x2, c.y - 2.5)
			if n1 == nil or n2 == nil then
				log("P16", ("crossing nodes missing: %s %s"):format(tostring(n1), tostring(n2)))
				return
			end
			local pts : {Pt3} = { onLine(60), { x = q2.x, y = q2.y, z = q2.z, entity = n2 },
				{ x = q1.x, y = q1.y, z = q1.z, entity = n1 }, onLine(300) }
			local winner : SimpleProposal = nil
			for __, track in ipairs({ 0, 1 }) do
				local edges : {PgraceRailRouterNetwork.Edge} = {}
				for i = 1, 3 do
					local p, q = pts[i], pts[i + 1]
					local t : Pt3 = { x = q.x - p.x, y = q.y - p.y, z = 0 }
					table.insert(edges, { node0 = i, node1 = i + 1, p0 = p, p1 = q, t0 = t, t1 = t, kind = "ground",
						track = track, leg = 1, s0 = 0, s1 = 0 })
				end
				local cross : PgraceRailRouterNetwork.Network = { nodes = pts, edges = edges, chunks = {} }
				local pr = builder.chunkProposal(cross, 1, 3, s)
				if pr ~= nil then
					local okC, costC, messagesC, ___, dataC = builder.dryRun(pr)
					local hits : {string} = {}
					for __, h in ipairs(builder.collisions(dataC)) do
						table.insert(hits, ("%s %d"):format(h.what, h.entity))
					end
					log("P16", ("crossing track through both nodes, spacing %s: %s, %d %s"):format(track == 1 and "5" or "0",
						okC and "clean" or table.concat(messagesC, "; "), costC, table.concat(hits, ", ")))
					if okC and winner == nil then
						winner = pr
					end
				end
			end
			if winner == nil then
				log("P16", "no clean crossing: nothing more built")
				return
			end
			sendProposal(winner, function(res : WorldBuildProposalCommandData, success : boolean)
				log("P16", "crossing built: " .. tostring(success))
				if success then
					logAdded("P16 crossing", res)
					for __, n in ipairs({ n1, n2 }) do
						log("P16", ("  node %d: %d track pieces"):format(n,
							#api.engine.system.streetSystem.getNodeTrackSegments(n)))
					end
				end
			end)
		end
		sendProposal(proposal, function(__ : WorldBuildProposalCommandData, built : boolean)
			log("P16", "double track built: " .. tostring(built))
			if built then
				split(1, x1, function() split(2, x2, crossing) end)
			end
		end)
	end) }
end

-- P17 ------------------------------------------------------------------------------------------------------------
-- PROBE (remove before release): P15 on a curve (milestone 4c, stage 2): does the game take a flat junction cut into
-- curved double track? Three stages, one click each: 1 builds a curved double track east of the camera; 2 lays a
-- junction from the curve's outside (junction.fit in a midline frame read from the built track, mapped as
-- network.junctionEdges maps one), all three cuts on the arc's pieces, splits the tracks there and builds it; 3 builds
-- a copy of stage 1's track P17_SHIFT m further east and does the same from the inside. Uses P15's split and repair
-- helpers (they log under "P17" while it runs).

-- The track: P17_STRAIGHT1 m east, a left arc of P17_RADIUS (the planner's tightest) through P17_TURN degrees, then
-- P17_STRAIGHT2 m. The arc must hold a 300 m junction's cuts (the merge's switch to the crossing: 185 m), so it
-- turns 70° (269 m): 30° at 220 m is only 115 m.
local P17_STRAIGHT1 = 100.0
local P17_RADIUS = 220.0
local P17_TURN = 70.0
local P17_STRAIGHT2 = 150.0
-- The longest edge: the arc in 4 pieces of 17.5° (67 m; the player's curves had 17° edges, P1), the straights in
-- 50 m pieces.
local P17_EDGE = 70.0
-- The one-way signals, metres along the centre line: 120 m into the last straight (20 m into its third piece), clear
-- of the junction's span and 15 m and more from every piece end.
local P17_SIGNAL_S = P17_STRAIGHT1 + P17_RADIUS * math.rad(P17_TURN) + 120
local P17_TOTAL = P17_STRAIGHT1 + P17_RADIUS * math.rad(P17_TURN) + P17_STRAIGHT2
-- The junction's turnout radius (standard track's, as the planner fits them), and stage 3's copy's shift east.
local P17_JUNCTION_RADIUS = 300.0
local P17_SHIFT = 300.0
-- The built midline: track 1 sampled every so many metres, each sample paired with track 2's nearest point.
local P17_SAMPLE = 2.0
-- A cut lies on a curved piece: one whose ends' directions differ by more than this (degrees), at least P17_INSIDE
-- metres from both its ends (splitTrack refuses a sub-piece under 10 m). On this track that puts the merge's switch
-- at x = 130 (arc piece 1), the far switch at 260 (arc piece 3) and the crossing at 314.6 (arc piece 4).
local P17_CURVED = 2.0
local P17_INSIDE = 12.0

local record P17Cut
	-- 1 or 2: which existing track; "switch" or "crossing"; its x in the frame; the point on the track.
	track : integer
	kind : string
	x : number
	p : Pt3
end

local record P17Copy
	origin : Pt
	z : number
	-- The planned centre line as a frame: sorts scanned pieces onto their tracks.
	design : PgraceRailRouterMidline.Frame
	-- The signal's place on track 1 and on track 2.
	signalPts : {Pt}
	built : boolean
	-- The frame read from the built track, the junction fitted in it, and its cuts (in the layout's order), once
	-- fitted: a retry carries on with them.
	frame : PgraceRailRouterMidline.Frame
	layout : PgraceRailRouterJunction.Layout
	cuts : {P17Cut}
end

local p17Stage = 1
local p17Copies : {P17Copy} = {}
local p17State : P15State = { z = 0, off = 2.5, pieces = {} }

-- The planned centre line's point and unit direction at s metres along it.
local function p17Centre(o : Pt, s : number) : Pt, Pt
	local turn = math.rad(P17_TURN)
	local arcLen = P17_RADIUS * turn
	if s <= P17_STRAIGHT1 then
		return { x = o.x + s, y = o.y }, { x = 1, y = 0 }
	end
	if s <= P17_STRAIGHT1 + arcLen then
		local a = (s - P17_STRAIGHT1) / P17_RADIUS
		return { x = o.x + P17_STRAIGHT1 + P17_RADIUS * math.sin(a), y = o.y + P17_RADIUS * (1 - math.cos(a)) },
			{ x = math.cos(a), y = math.sin(a) }
	end
	local d = s - P17_STRAIGHT1 - arcLen
	local dir : Pt = { x = math.cos(turn), y = math.sin(turn) }
	return { x = o.x + P17_STRAIGHT1 + P17_RADIUS * math.sin(turn) + dir.x * d,
		y = o.y + P17_RADIUS * (1 - math.cos(turn)) + dir.y * d }, dir
end

local function p17Pieces(o : Pt) : {Piece}
	local east : Pt = { x = 1, y = 0 }
	local a = straight(o, east, P17_STRAIGHT1)
	local turn = math.rad(P17_TURN)
	local b = leftArc(a.b, east, P17_RADIUS, turn)
	return { a, b, straight(b.b, { x = math.cos(turn), y = math.sin(turn) }, P17_STRAIGHT2) }
end

local function p17NewCopy(o : Pt, off : number) : P17Copy
	local pts : {Pt3} = {}
	local z = groundAt(o)
	local s = 0.0
	while true do
		local p = p17Centre(o, s)
		table.insert(pts, { x = p.x, y = p.y, z = z })
		if s >= P17_TOTAL then
			break
		end
		s = math.min(P17_TOTAL, s + 5)
	end
	local sp, dir = p17Centre(o, P17_SIGNAL_S)
	local left : Pt = { x = -dir.y, y = dir.x }
	return { origin = o, z = z, design = midline.fromPoints(pts, midline.STEP), built = false,
		signalPts = { geo.add(sp, geo.scale(left, off)), geo.add(sp, geo.scale(left, -off)) } }
end

-- Points the shared helpers at a copy: its origin for rel, its design frame for trackOf, "P17" for their logs.
local function p17Use(copy : P17Copy, off : number)
	p17State.origin, p17State.z, p17State.off = copy.origin, copy.z, off
	p17State.classify = function(h : Hermite) : integer
		local track = 0
		for k, q in ipairs({ h.p0, network.hermiteAt(h, 0.5), h.p1 }) do
			local x, y = midline.project(copy.design, { x = q.x, y = q.y })
			if x < -1 or x > P17_TOTAL + 1 then
				return 0
			end
			local t = 0
			if math.abs(y - off) < 0.6 then
				t = 1
			elseif math.abs(y + off) < 0.6 then
				t = 2
			end
			if t == 0 or (k > 1 and t ~= track) then
				return 0
			end
			track = t
		end
		return track
	end
	cur, tag = p17State, "P17"
end

-- The angle (degrees) between two plan vectors, ignoring which way each points if `undirected`.
local function angleOf(a : Pt3, b : Pt3, undirected : boolean) : number
	local la, lb = math.sqrt(a.x ^ 2 + a.y ^ 2), math.sqrt(b.x ^ 2 + b.y ^ 2)
	if la < 1e-9 or lb < 1e-9 then
		return 0
	end
	local c = (a.x * b.x + a.y * b.y) / (la * lb)
	if undirected then
		c = math.abs(c)
	end
	return math.deg(math.acos(math.max(-1, math.min(1, c))))
end

-- How far a piece turns end to end (degrees).
local function turnOf(h : Hermite) : number
	return angleOf(h.t0, h.t1, false)
end

-- A Hermite curve's tightest radius in plan (51 samples, from the curvature of the cubic), and the parameter there;
-- math.huge for a straight.
local function tightest(h : Hermite) : number, number
	local best, at = math.huge, 0.0
	for k = 0, 50 do
		local s = k / 50
		local d00, d10, d01, d11 = 6 * s * s - 6 * s, 3 * s * s - 4 * s + 1, -6 * s * s + 6 * s, 3 * s * s - 2 * s
		local e00, e10, e01, e11 = 12 * s - 6, 6 * s - 4, -12 * s + 6, 6 * s - 2
		local dx = d00 * h.p0.x + d10 * h.t0.x + d01 * h.p1.x + d11 * h.t1.x
		local dy = d00 * h.p0.y + d10 * h.t0.y + d01 * h.p1.y + d11 * h.t1.y
		local ddx = e00 * h.p0.x + e10 * h.t0.x + e01 * h.p1.x + e11 * h.t1.x
		local ddy = e00 * h.p0.y + e10 * h.t0.y + e01 * h.p1.y + e11 * h.t1.y
		local v = math.sqrt(dx * dx + dy * dy)
		local cross = math.abs(dx * ddy - dy * ddx)
		if v > 1e-9 and cross > 1e-12 then
			local r = v ^ 3 / cross
			if r < best then
				best, at = r, s
			end
		end
	end
	return best, at
end

local function fmtR(h : Hermite) : string
	local r, at = tightest(h)
	if r > 1e6 then
		return "straight"
	end
	return ("%.1f m at param %.2f"):format(r, at)
end

local function fmtT(t : Pt3) : string
	return ("(%.2f %.2f %.2f)"):format(t.x, t.y, t.z)
end

-- Every plain track piece of a copy, read fresh, track set by its design frame (0: not one of its two tracks), in
-- order along it.
local function p17Scan(copy : P17Copy) : {P15Piece}
	local list : {P15Piece} = {}
	local mid = p17Centre(copy.origin, P17_TOTAL / 2)
	local found = api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(mid.x, mid.y), 350,
		api.type.ComponentType.BASE_EDGE)
	for __, e in ipairs(found) do
		pcall(function() : boolean
			local edge = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
			if edge == nil or edge.roadType ~= api.type["enum"].RoadType.TRACK
					or edge.type ~= api.type["enum"].BaseEdgeType.NORMAL then
				return true
			end
			local h : Hermite = { p0 = p3of(edge.position0), p1 = p3of(edge.position1), t0 = p3of(edge.tangent0),
				t1 = p3of(edge.tangent1) }
			table.insert(list, { entity = e as integer, node0 = edge.node0 as integer, node1 = edge.node1 as integer,
				h = h, objects = #(edge.objects or {}), track = trackOf(h) })
			return true
		end)
	end
	local key : {integer : number} = {}
	for __, p in ipairs(list) do
		local q = network.hermiteAt(p.h, 0.5)
		key[p.entity] = midline.project(copy.design, { x = q.x, y = q.y })
	end
	table.sort(list, function(a : P15Piece, b : P15Piece) : boolean
		return key[a.entity] < key[b.entity]
	end)
	return list
end

local function p17LogTracks(list : {P15Piece})
	for __, p in ipairs(list) do
		if p.track ~= 0 then
			logPiece(p)
			log("P17", ("  piece %d: %.1f m, turns %.1f degrees, tightest radius %s"):format(p.entity, chord(p.h),
				turnOf(p.h), fmtR(p.h)))
		end
	end
end

local function p17Done(stage : integer, ok : boolean)
	p17Busy = false
	if ok then
		p17Stage = stage % 3 + 1
		log("P17", ("stage %d finished; the next click runs stage %d"):format(stage, p17Stage))
	else
		log("P17", ("stage %d did not finish: click again to retry stage %d"):format(stage, stage))
	end
end

-- A copy's double track, with a one-way signal on each track at P17_SIGNAL_S (as P15's stage 1 builds its own).
local function p17BuildTrack(copy : P17Copy, settings : Settings, done : function(boolean))
	local opts : Options = {}
	for k, v in pairs(settings.network as {string : any}) do
		(opts as {string : any})[k] = v
	end
	opts.fan = nil
	opts.crossovers = false
	opts.chunkLength = 100000
	opts.maxEdge = P17_EDGE
	local s = with(settings, function(c : Settings)
		c.network = opts
		c.signal = "::/infrastructure/signal/signal_path_" .. (settings.year < 1950 and "a" or "c") .. ".con"
	end)
	local net = network.build(testPlan(p17Pieces(copy.origin), copy.z, 0, "ground"), opts)
	for __, e in ipairs(net.edges) do
		local h : Hermite = { p0 = e.p0, p1 = e.p1, t0 = e.t0, t1 = e.t1 }
		log("P17", ("planned edge track %d s %.1f..%.1f %s -> %s, turns %.1f degrees, tightest radius %s"):format(
			e.track, e.s0, e.s1, rel(e.p0), rel(e.p1), turnOf(h), fmtR(h)))
		if (e.track == 1 or e.track == 2) and e.s0 <= P17_SIGNAL_S and P17_SIGNAL_S <= e.s1 then
			local u = (P17_SIGNAL_S - e.s0) / (e.s1 - e.s0)
			e.signals = { { param = u, forward = e.track == 2 } }
			log("P17", ("signal on track %d edge s %.1f..%.1f at %.3f"):format(e.track, e.s0, e.s1, u))
		end
	end
	local proposal, why = builder.chunkProposal(net, 1, #net.edges, s)
	if proposal == nil then
		log("P17", "no track proposal: " .. tostring(why))
		return done(false)
	end
	local ok, cost, messages, __, data = builder.dryRun(proposal)
	log("P17", ("track dry run: %s, %d"):format(ok and "clean" or table.concat(messages, "; "), cost))
	logCollisions("P17", data)
	if not ok then
		return done(false)
	end
	sendProposal(proposal, function(res : WorldBuildProposalCommandData, success : boolean)
		log("P17", "track built: " .. tostring(success))
		if not success then
			return done(false)
		end
		copy.built = true
		logAdded("track", res)
		log("P17", "tracks as scanned:")
		p17LogTracks(p17Scan(copy))
		done(true)
	end)
end

-- The piece of `track` whose frame-x range holds x, and its parameter where its curve is at x (bisected, as
-- network.junctionEdges finds a cut).
local function p17PieceAt(f : PgraceRailRouterMidline.Frame, list : {P15Piece}, track : integer, x : number)
		: P15Piece, number
	local function frameX(p : Pt3) : number
		local fx = midline.project(f, { x = p.x, y = p.y })
		return fx
	end
	for __, p in ipairs(list) do
		if p.track == track then
			local xa, xb = frameX(p.h.p0), frameX(p.h.p1)
			if math.abs(xb - xa) > 1e-9 and x >= math.min(xa, xb) - 1e-6 and x <= math.max(xa, xb) + 1e-6 then
				local lo, hi = 0.0, 1.0
				local rising = xb > xa
				for __ = 1, 60 do
					local m = (lo + hi) / 2
					if (frameX(network.hermiteAt(p.h, m)) < x) == rising then
						lo = m
					else
						hi = m
					end
				end
				return p, (lo + hi) / 2
			end
		end
	end
	return nil, 0
end

-- The midline read from the built track: track 1 sampled every P17_SAMPLE m, each sample's midpoint with track 2's
-- nearest point. nil, why if the tracks can't be read.
local function p17Midline(copy : P17Copy, list : {P15Piece}) : PgraceRailRouterMidline.Frame, string
	local t1, t2 : {P15Piece}, {P15Piece} = {}, {}
	for __, p in ipairs(list) do
		if p.track == 1 then
			table.insert(t1, p)
		elseif p.track == 2 then
			table.insert(t2, p)
		end
	end
	if #t1 == 0 or #t2 == 0 then
		return nil, ("track pieces found: %d on track 1, %d on track 2"):format(#t1, #t2)
	end
	local pts : {Pt3} = {}
	local worst = 0.0
	for __, p in ipairs(t1) do
		local xa = midline.project(copy.design, { x = p.h.p0.x, y = p.h.p0.y })
		local xb = midline.project(copy.design, { x = p.h.p1.x, y = p.h.p1.y })
		local n = math.max(1, math.ceil(chord(p.h) / P17_SAMPLE))
		for k = 0, n do
			local s = k / n
			if xb < xa then
				s = 1 - s
			end
			local q = network.hermiteAt(p.h, s)
			local best : Pt3 = nil
			local bestD = math.huge
			for __, p2 in ipairs(t2) do
				local r = network.hermiteAt(p2.h, network.nearestParam(p2.h, { x = q.x, y = q.y }))
				local d = (r.x - q.x) ^ 2 + (r.y - q.y) ^ 2
				if d < bestD then
					best, bestD = r, d
				end
			end
			local last = pts[#pts]
			local m : Pt3 = { x = (q.x + best.x) / 2, y = (q.y + best.y) / 2, z = (q.z + best.z) / 2 }
			if bestD < 36 and (last == nil or (m.x - last.x) ^ 2 + (m.y - last.y) ^ 2 > 0.25) then
				table.insert(pts, m)
				worst = math.max(worst, math.abs(math.sqrt(bestD) - 2 * p17State.off))
			end
		end
	end
	if #pts < 2 then
		return nil, "fewer than two midline samples"
	end
	local f = midline.fromPoints(pts, midline.STEP)
	-- How far the built tracks are from ±off in the frame (sampled at their pieces' quarter points).
	local dev = 0.0
	for __, p in ipairs(list) do
		if p.track ~= 0 then
			for __, s in ipairs({ 0.25, 0.5, 0.75 }) do
				local q = network.hermiteAt(p.h, s)
				local __, y = midline.project(f, { x = q.x, y = q.y })
				dev = math.max(dev, math.abs(math.abs(y) - p17State.off))
			end
		end
	end
	log("P17", ("built midline: %d samples, frame %.1f m long, tracks %.3f m off their spacing at worst, %.3f m off +-%.1f in the frame"):format(
		#pts, f.length, worst, dev, p17State.off))
	return f
end

-- Fits the junction on side `side` (+1 inside the left curve, -1 outside) with every cut inside a curved piece, and
-- keeps its frame, layout and cuts on the copy. false if none fits.
local function p17Fit(copy : P17Copy, list : {P15Piece}, side : number) : boolean
	local f, why = p17Midline(copy, list)
	if f == nil then
		log("P17", "no midline: " .. tostring(why))
		return false
	end
	local nearT = side > 0 and 1 or 2
	local farT = 3 - nearT
	local function trackNo(which : string) : integer
		return which == "near" and nearT or farT
	end
	local function fx(p : Pt) : number
		local x = midline.project(f, p)
		return x
	end
	local nodes : {string : {number}} = { near = {}, far = {} }
	for __, p in ipairs(list) do
		if p.track ~= 0 then
			local key = p.track == nearT and "near" or "far"
			table.insert(nodes[key], fx({ x = p.h.p0.x, y = p.h.p0.y }))
			table.insert(nodes[key], fx({ x = p.h.p1.x, y = p.h.p1.y }))
		end
	end
	local signals : {string : {number}} = { near = { fx(copy.signalPts[nearT]) }, far = { fx(copy.signalPts[farT]) } }
	log("P17", ("fitting at radius %.0f, side %.0f (near track %d): signals near %.1f far %.1f"):format(
		P17_JUNCTION_RADIUS, side, nearT, signals.near[1], signals.far[1]))
	local function onCurve(j : PgraceRailRouterJunction.Layout) : boolean
		for __, c in ipairs(j.cuts) do
			local p, s = p17PieceAt(f, list, trackNo(c.track), c.x)
			if p == nil or turnOf(p.h) < P17_CURVED or s * chord(p.h) < P17_INSIDE
					or (1 - s) * chord(p.h) < P17_INSIDE then
				return false
			end
		end
		return true
	end
	local j = junction.fit(f.length, P17_JUNCTION_RADIUS, side, signals, nodes, onCurve)
	if j == nil then
		log("P17", "no junction fits with all its cuts on curved pieces")
		return false
	end
	log("P17", ("junction fitted: approach at x = %.1f"):format(j.approachX))
	for __, pc in ipairs(j.pieces) do
		log("P17", ("  frame piece %s: (%.1f %.1f) -> (%.1f %.1f), tangents (%.1f %.1f) (%.1f %.1f)"):format(pc.role,
			pc.x0, pc.y0, pc.x1, pc.y1, pc.tx0, pc.ty0, pc.tx1, pc.ty1))
	end
	local cuts : {P17Cut} = {}
	for __, c in ipairs(j.cuts) do
		local t = trackNo(c.track)
		local p, s = p17PieceAt(f, list, t, c.x)
		local at = network.hermiteAt(p.h, s)
		local ideal = midline.world(f, c.x, c.track == "near" and 2.5 * side or -2.5 * side)
		log("P17", ("cut %s on the %s track (%d) at x = %.1f: piece %d (%.1f m, turns %.1f degrees, radius %s) param %.4f at %s, %.3f m off the frame's track line"):format(
			c.kind, c.track, t, c.x, p.entity, chord(p.h), turnOf(p.h), fmtR(p.h), s, rel(at),
			math.sqrt((at.x - ideal.x) ^ 2 + (at.y - ideal.y) ^ 2)))
		table.insert(cuts, { track = t, kind = c.kind, x = c.x, p = { x = at.x, y = at.y, z = at.z } })
	end
	copy.frame, copy.layout, copy.cuts = f, j, cuts
	return true
end

-- The track piece holding a point (within 0.6 m of its curve, not at its ends), and the parameter there.
local function p17PieceHolding(list : {P15Piece}, track : integer, p : Pt3) : P15Piece, number
	local best : P15Piece = nil
	local bestU, bestD = 0.0, 0.36
	for __, pc in ipairs(list) do
		if pc.track == track then
			local u = network.nearestParam(pc.h, { x = p.x, y = p.y })
			local q = network.hermiteAt(pc.h, u)
			local d = (q.x - p.x) ^ 2 + (q.y - p.y) ^ 2
			if d < bestD and u > 0.001 and u < 0.999 then
				best, bestU, bestD = pc, u, d
			end
		end
	end
	return best, bestU
end

-- The existing track's direction at a node (the tangent of a track piece there), and that piece; nil if none.
local function p17TrackDir(list : {P15Piece}, node : integer) : Pt3, integer
	for __, p in ipairs(list) do
		if p.track ~= 0 then
			if p.node0 == node then
				return p.h.t0, p.entity
			elseif p.node1 == node then
				return p.h.t1, p.entity
			end
		end
	end
	return nil, nil
end

-- With every cut made: the junction's pieces as network.junctionEdges maps them (each piece's ends and tangents
-- through the frame, a straight on from each end on our tracks to the approach), dry-run, built if clean.
local function p17Junction(copy : P17Copy, settings : Settings, side : number, done : function(boolean))
	local f, j = copy.frame, copy.layout
	local list = p17Scan(copy)
	local nodes : {Pt3} = {}
	local cutNode : {integer} = {}
	local switches : {integer : boolean} = {}
	local entities : {integer} = {}
	for ci, c in ipairs(copy.cuts) do
		local n, q = findNodeAt(list, c.p.x, c.p.y)
		if n == nil then
			log("P17", ("no node at the %s cut on track %d (x = %.1f)"):format(c.kind, c.track, c.x))
			return done(false)
		end
		table.insert(nodes, { x = q.x, y = q.y, z = q.z, entity = n })
		cutNode[ci] = #nodes
		table.insert(entities, n)
		if c.kind == "switch" then
			switches[n] = true
		end
		log("P17", ("cut node: %s on track %d -> %d at %s"):format(c.kind, c.track, n, rel(q)))
	end
	local function cutAt(x : number, y : number) : integer
		for ci, c in ipairs(j.cuts) do
			if math.abs(c.x - x) < 1e-6 and math.abs(y) < 5 and (c.track == "near") == (y * side > 0) then
				return cutNode[ci]
			end
		end
		return nil
	end
	local function newNode(p : Pt3) : integer
		table.insert(nodes, p)
		return #nodes
	end
	local function world(x : number, y : number) : Pt3
		return midline.world(f, x, y)
	end
	local function vec(x : number, tx : number, ty : number) : Pt3
		return midline.vector(f, x, tx, ty)
	end
	local edges : {PgraceRailRouterNetwork.Edge} = {}
	local roles : {string} = {}
	-- Each frame piece's edges, first..last (its straights on, then the piece), for dry runs of their own.
	local groups : {{any}} = {}
	local function add(a : integer, b : integer, x0 : number, x1 : number, t0 : Pt3, t1 : Pt3, role : string)
			: PgraceRailRouterNetwork.Edge
		local pa, pb = nodes[a], nodes[b]
		local e : PgraceRailRouterNetwork.Edge = { node0 = a, node1 = b, p0 = { x = pa.x, y = pa.y, z = pa.z },
			p1 = { x = pb.x, y = pb.y, z = pb.z }, t0 = t0, t1 = t1, kind = "ground", track = 4, leg = 1,
			s0 = x0 - j.approachX, s1 = x1 - j.approachX }
		table.insert(edges, e)
		table.insert(roles, role)
		return e
	end
	local pairX = -math.huge
	for __, pc in ipairs(j.pieces) do
		pairX = math.max(pairX, pc.x1)
	end
	for __, pc in ipairs(j.pieces) do
		local first = #edges + 1
		local a = cutAt(pc.x0, pc.y0)
		if a == nil then
			log("P17", ("piece %s doesn't start on a cut"):format(pc.role))
			return done(false)
		end
		local b = cutAt(pc.x1, pc.y1)
		if b == nil then
			b = newNode(world(pc.x1, pc.y1))
			local from, x = b, pc.x1
			if pairX - x > 0.5 then
				local m = newNode(world(pairX, pc.y1))
				add(from, m, x, pairX, vec(x, pairX - x, 0), vec(pairX, pairX - x, 0), pc.role .. " straight")
				from, x = m, pairX
			end
			local d = j.approachX - x
			add(from, newNode(world(j.approachX, pc.y1)), x, j.approachX, vec(x, d, 0), vec(j.approachX, d, 0),
				pc.role .. " straight on").paired = true
		end
		add(a, b, pc.x0, pc.x1, vec(pc.x0, pc.tx0, pc.ty0), vec(pc.x1, pc.tx1, pc.ty1), pc.role).whole = true
		table.insert(groups, { pc.role, first, #edges })
	end
	for i, e in ipairs(edges) do
		local h : Hermite = { p0 = e.p0, p1 = e.p1, t0 = e.t0, t1 = e.t1 }
		log("P17", ("new piece %d (%s): %s -> %s, tangents %s %s, %.1f m, turns %.1f degrees, tightest radius %s"):format(
			i, roles[i], rel(e.p0), rel(e.p1), fmtT(e.t0), fmtT(e.t1), chord(h), turnOf(h), fmtR(h)))
		for k = 1, 2 do
			local n = nodes[k == 1 and e.node0 or e.node1]
			if n.entity ~= nil then
				local dir, piece = p17TrackDir(list, n.entity)
				if dir ~= nil then
					log("P17", ("  at node %d (%s): %.2f degrees off the existing track (piece %d)"):format(n.entity,
						switches[n.entity] and "switch" or "crossing", angleOf(k == 1 and e.t0 or e.t1, dir, true), piece))
				end
			end
		end
	end
	local function dryRunAll(net : PgraceRailRouterNetwork.Network, what : string) : SimpleProposal
		local proposal, why = builder.chunkProposal(net, 1, #net.edges, settings)
		if proposal == nil then
			log("P17", ("%s: no proposal: %s"):format(what, tostring(why)))
			return nil
		end
		local ok, cost, messages, us, data = builder.dryRun(proposal)
		log("P17", ("%s dry run: %s, price %d, %d us"):format(what, ok and "clean" or table.concat(messages, "; "), cost,
			us))
		pcall(function() : boolean
			local infos : {string} = {}
			for __, m in ipairs(data.errorState.infos or {}) do
				table.insert(infos, tostring(m))
			end
			log("P17", ("%s infos: %s"):format(what, #infos > 0 and table.concat(infos, "; ") or "none"))
			return true
		end)
		for __, h in ipairs(builder.collisions(data)) do
			log("P17", ("%s collision: %s %d"):format(what, h.what, h.entity))
		end
		logCollisions("P17", data)
		if not ok then
			for __, g in ipairs(groups) do
				local pr = builder.chunkProposal(net, g[2] as integer, g[3] as integer, settings)
				if pr ~= nil then
					local okP, costP, messagesP = builder.dryRun(pr)
					log("P17", ("  %s: %s only: %s, %d"):format(what, g[1] as string,
						okP and "clean" or table.concat(messagesP, "; "), costP))
				end
			end
			return nil
		end
		return proposal
	end
	local net : PgraceRailRouterNetwork.Network = { nodes = nodes, edges = edges, chunks = {} }
	local proposal = dryRunAll(net, "junction")
	if proposal == nil then
		-- The same with each switch's tangent turned onto the existing track's direction there.
		local snapped : {PgraceRailRouterNetwork.Edge} = {}
		for __, e in ipairs(edges) do
			local c : PgraceRailRouterNetwork.Edge = { node0 = e.node0, node1 = e.node1, p0 = e.p0, p1 = e.p1, t0 = e.t0,
				t1 = e.t1, kind = e.kind, track = e.track, leg = e.leg, s0 = e.s0, s1 = e.s1, paired = e.paired,
				whole = e.whole }
			for k = 1, 2 do
				local n = nodes[k == 1 and e.node0 or e.node1]
				if n.entity ~= nil and switches[n.entity] then
					local dir = p17TrackDir(list, n.entity)
					local t = k == 1 and c.t0 or c.t1
					if dir ~= nil then
						local ld = math.sqrt(dir.x ^ 2 + dir.y ^ 2)
						local lt = math.sqrt(t.x ^ 2 + t.y ^ 2)
						local sign = (dir.x * t.x + dir.y * t.y) < 0 and -1 or 1
						local s : Pt3 = { x = dir.x / ld * lt * sign, y = dir.y / ld * lt * sign, z = t.z }
						if k == 1 then
							c.t0 = s
						else
							c.t1 = s
						end
					end
				end
			end
			table.insert(snapped, c)
		end
		proposal = dryRunAll({ nodes = nodes, edges = snapped, chunks = {} }, "junction, switch tangents on the track")
	end
	if proposal == nil then
		return done(false)
	end
	sendProposal(proposal, function(res : WorldBuildProposalCommandData, success : boolean)
		log("P17", "junction built: " .. tostring(success))
		if not success then
			return done(false)
		end
		logAdded("junction", res)
		for __, n in ipairs(entities) do
			local okS, segs = pcall(function() : {any}
				return api.engine.system.streetSystem.getNodeTrackSegments(n) as {any}
			end)
			log("P17", ("node %d: %s track pieces"):format(n, okS and tostring(#(segs as {any})) or "unreadable"))
		end
		repairNodes("junction", entities, function()
			log("P17", "tracks after the junction:")
			p17LogTracks(p17Scan(copy))
			done(true)
		end)
	end)
end

-- Splits the existing pieces at the copy's cuts, one piece per proposal (re-scanned each time; cuts that already
-- have a node are skipped, so a retry carries on), then builds the junction.
local function p17Cuts(copy : P17Copy, settings : Settings, side : number, done : function(boolean))
	local function nextCut(attempt : integer)
		if attempt > 8 then
			log("P17", "too many cuts")
			return done(false)
		end
		local list = p17Scan(copy)
		local pending : {P17Cut} = {}
		for __, c in ipairs(copy.cuts) do
			if findNodeAt(list, c.p.x, c.p.y) == nil then
				table.insert(pending, c)
			end
		end
		if #pending == 0 then
			return p17Junction(copy, settings, side, done)
		end
		local piece = p17PieceHolding(list, pending[1].track, pending[1].p)
		if piece == nil then
			log("P17", ("no track %d piece holds the %s cut at x = %.1f"):format(pending[1].track, pending[1].kind,
				pending[1].x))
			return done(false)
		end
		local us : {number} = {}
		for __, c in ipairs(pending) do
			local same, u = p17PieceHolding(list, c.track, c.p)
			if same ~= nil and same.entity == piece.entity then
				local q = network.hermiteAt(piece.h, u)
				log("P17", ("split: piece %d (turns %.1f degrees) at param %.4f for the %s cut at x = %.1f on track %d, %.3f m off the piece's curve"):format(
					piece.entity, turnOf(piece.h), u, c.kind, c.x, c.track, math.sqrt((q.x - c.p.x) ^ 2 + (q.y - c.p.y) ^ 2)))
				table.insert(us, u)
			end
		end
		table.sort(us)
		local rep = splitTrack(piece, us, piece.objects > 0 and { copy.signalPts[piece.track] } or {})
		if rep == nil then
			return done(false)
		end
		sendProposal(rep, function(res : WorldBuildProposalCommandData, success : boolean)
			log("P17", "split sent: " .. tostring(success))
			if not success then
				return done(false)
			end
			afterSplit("cut", res, function()
				nextCut(attempt + 1)
			end)
		end)
	end
	nextCut(1)
end

-- Fits (once) and builds the junction on a copy.
local function p17JunctionOn(copy : P17Copy, settings : Settings, side : number, done : function(boolean))
	if copy.layout == nil then
		local list = p17Scan(copy)
		log("P17", "tracks before the junction:")
		p17LogTracks(list)
		if not p17Fit(copy, list, side) then
			return done(false)
		end
	end
	p17Cuts(copy, settings, side, done)
end

function probe.curveJunction(settings : Settings) : {function()}
	return { function()
		if p17Busy then
			log("P17", "busy: a stage is still running, click again when it has finished")
			return
		end
		p17Busy = true
		local stage = p17Stage
		local off = settings.network.offset
		log("P17", ("stage %d"):format(stage))
		local ok, err = pcall(function() : boolean
			if stage == 1 then
				local copy = p17NewCopy(camera(), off)
				p17Copies = { copy }
				p17Use(copy, off)
				log("P17", ("track from the camera (%.1f %.1f), ground %.2f: %.0f m east, a %.0f m left arc through %.0f degrees, %.0f m on"):format(
					copy.origin.x, copy.origin.y, copy.z, P17_STRAIGHT1, P17_RADIUS, P17_TURN, P17_STRAIGHT2))
				p17BuildTrack(copy, settings, function(built : boolean) p17Done(1, built) end)
			elseif p17Copies[1] == nil or not p17Copies[1].built then
				log("P17", "no track: run stage 1 first")
				p17Done(1, false)
				p17Stage = 1
			elseif stage == 2 then
				p17Use(p17Copies[1], off)
				log("P17", "junction from the curve's outside (side -1)")
				p17JunctionOn(p17Copies[1], settings, -1, function(built : boolean) p17Done(2, built) end)
			else
				if p17Copies[2] == nil then
					local o = p17Copies[1].origin
					p17Copies[2] = p17NewCopy({ x = o.x + P17_SHIFT, y = o.y }, off)
				end
				local copy = p17Copies[2]
				p17Use(copy, off)
				local function inside()
					log("P17", "junction from the curve's inside (side +1)")
					p17JunctionOn(copy, settings, 1, function(built : boolean) p17Done(3, built) end)
				end
				if copy.built then
					inside()
				else
					log("P17", ("second track %.0f m further east, ground %.2f"):format(P17_SHIFT, copy.z))
					p17BuildTrack(copy, settings, function(built : boolean)
						if built then
							inside()
						else
							p17Done(3, false)
						end
					end)
				end
			end
			return true
		end)
		if not ok then
			log("P17", "ERROR " .. tostring(err))
			p17Busy = false
		end
	end }
end

-- P6 -------------------------------------------------------------------------------------------------------------

local function moduleLookup(name : string) : string
	local found = "?"
	pcall(function() : boolean
		local plain = name:sub(1, 2) == "::" and name:sub(3) or name
		found = ("%s: find %s, without :: %s"):format(name, tostring(api.res.moduleRep.find(name)),
			tostring(api.res.moduleRep.find(plain)))
		return true
	end)
	return found
end

function probe.dryRunStation(settings : Settings, tracks : {PgraceRailRouterModes.TrackType}) : {function()}
	local c = camera()
	local east : Pt = { x = 1, y = 0 }
	local ground = groundAt(c)
	local plan : Plan = { ok = true, legs = {}, platformLength = 160,
		stations = { { town = { id = -1, name = "Probe", pos = c }, site = { centre = c, dir = east, distance = 0 },
			z = ground } } }
	local era = sl.eraLetter(settings.year)
	local building = MODULE_DIR .. "main_building_1_era_" .. era .. ".module"
	local stairs = MODULE_DIR .. "addon_platform_passenger_stairs_era_" .. era .. ".module"
	local roof = MODULE_DIR .. "platform_passenger_roof_era_" .. era .. ".module"
	local variants : {{string, PgraceRailRouterStationLayout.Addons}} = {
		{ "platforms and tracks only", nil },
		{ "with main building and stairs", { building = building, stairs = stairs } },
		{ "with main building, stairs and roofs", { building = building, stairs = stairs, roof = roof } },
	}
	local tasks : {function()} = {}
	table.insert(tasks, guarded("P6", function()
		local layout = sl.layout(c, east, 160, settings.era)
		local ends : {string} = {}
		for __, p in ipairs(layout.ends) do
			table.insert(ends, ("(%.1f %.1f)"):format(p.x, p.y))
		end
		log("P6", ("camera (%.1f %.1f) ground %.2f year %d era %s angle %.4f origin (%.2f %.2f) ends %s")
			:format(c.x, c.y, ground, settings.year, era, layout.angle, layout.origin.x, layout.origin.y,
			table.concat(ends, " ")))
		-- The module names, in both forms, for every era and track type.
		for __, letter in ipairs({ "a", "b", "c" }) do
			for __, base in ipairs({ "platform_passenger_era_", "main_building_1_era_",
					"addon_platform_passenger_stairs_era_", "platform_passenger_roof_era_" }) do
				log("P6", "module " .. moduleLookup(MODULE_DIR .. base .. letter .. ".module"))
			end
		end
		for __, t in ipairs(tracks) do
			log("P6", "track module " .. moduleLookup(sl.trackModule(t.name)))
			if t.catenary ~= nil then
				log("P6", "track module " .. moduleLookup(sl.trackModule(t.catenary)))
			end
		end
	end))
	for __, v in ipairs(variants) do
		table.insert(tasks, guarded("P6", function()
			local s = with(settings, function(copy : Settings) copy.addons = v[2] end)
			local proposal, why = builder.stationProposal(plan, 1, s)
			if proposal == nil then
				log("P6", v[1] .. ": NOT MADE " .. tostring(why))
				return
			end
			local ok, cost, messages, us, data = builder.dryRun(proposal)
			log("P6", ("%s: %s cost %d %d us %s"):format(v[1], ok and "clean" or "ERRORS", cost, us,
				table.concat(messages, "; ")))
			logCollisions("P6 " .. v[1], data)
			if data ~= nil then
				pcall(function() : boolean
					local bb = data.toAddData[1].boundingVolume.bbox
					-- The station faces east: its length along the axis is the box's extent in x.
					log("P6", ("%s: bbox %s %s, length along the axis %.1f m (platforms asked for %.0f m)"):format(v[1],
						fmtV(bb.min), fmtV(bb.max), bb.max.x - bb.min.x, plan.platformLength))
					return true
				end)
			end
		end))
	end
	table.insert(tasks, function()
		log("P6", "done")
	end)
	return tasks
end

return probe
