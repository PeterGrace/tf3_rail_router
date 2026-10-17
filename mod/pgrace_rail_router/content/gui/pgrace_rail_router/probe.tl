-- PROBE (remove before release): the milestone 2 engine probes (see probe.d.tl). Every engine read is in a pcall;
-- they use builder.chunkProposal, stationProposal and dryRun, so they test the code that will ship.
local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo
local network = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/network.tl" as PgraceRailRouterNetwork
local modes = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/modes.tl" as PgraceRailRouterModes
local sl = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/stationlayout.tl" as PgraceRailRouterStationLayout
local survey = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/survey.tl" as PgraceRailRouterSurvey
local builder = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/builder.tl" as PgraceRailRouterBuilder

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
		strips = tostring(#api.engine.system.baseParallelStripSystem.getStrips(e))
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

-- Milestone 3 probes -----------------------------------------------------------------------------------------------

local type Network = PgraceRailRouterNetwork.Network
local type Pt3 = PgraceRailRouterNetwork.Pt3

local STATION_FILE = "::/stations/rail/modular_station/modular_station.con"

local function segmentCounts(node : integer) : string
	local all, track = -1, -1
	pcall(function() : boolean
		all = #api.engine.system.streetSystem.getNodeSegments(node)
		track = #api.engine.system.streetSystem.getNodeTrackSegments(node)
		return true
	end)
	return ("node %d: %d pieces, %d track"):format(node, all, track)
end

local function nodePos(node : integer) : Pt3
	local n = api.engine.getComponent(node, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
	if n == nil then
		return nil
	end
	return { x = n.position.x, y = n.position.y, z = n.position.z, entity = node }
end

-- Straight double (or single) track from each start along dir: one edge each, `length` long, flat at the start's
-- height. A start with an entity is joined, not added.
local function straightNet(starts : {Pt3}, dir : Pt, length : number) : Network
	local net : Network = { nodes = {}, edges = {}, chunks = {} }
	local t : Pt3 = { x = dir.x * length, y = dir.y * length, z = 0 }
	for i, a in ipairs(starts) do
		table.insert(net.nodes, a)
		table.insert(net.nodes, { x = a.x + t.x, y = a.y + t.y, z = a.z })
		table.insert(net.edges, { node0 = #net.nodes - 1, node1 = #net.nodes, p0 = a, p1 = net.nodes[#net.nodes],
			t0 = t, t1 = t, kind = "ground", track = i, leg = 1, s0 = 0, s1 = length })
	end
	return net
end

-- Dry-runs a proposal in the given context and logs it; true if clean.
local function tryProposal(name : string, proposal : SimpleProposal, context : Context) : boolean, ProposalData
	local ok, cost, messages, us, data = builder.dryRun(proposal, context)
	local extra = ""
	pcall(function() : boolean
		local n = 0
		for __ in pairs(data.old2new or {}) do
			n = n + 1
		end
		extra = (" old2new %d, auto-removed %d"):format(n, #(data.collisionInfo.buildingEntities or {}))
		return true
	end)
	log(name, ("%s cost %d %d us%s %s"):format(ok and "clean" or "ERRORS", cost, us, extra, table.concat(messages, "; ")))
	logCollisions(name, data)
	return ok, data
end

-- Sends a proposal that dry-ran clean in this context, and logs what was built: each added edge (street or track, its
-- nodes and theirs pieces) and node. then(res) runs after, on success.
local function build(name : string, proposal : SimpleProposal, context : Context,
		andThen : function(WorldBuildProposalCommandData))
	api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(proposal, context, false, true),
		function(res : WorldBuildProposalCommandData, success : boolean)
			local okCb, err = pcall(function() : boolean
				local charged = "?"
				pcall(function() : boolean
					charged = tostring(res.resultProposalData.costs)
					return true
				end)
				log(name, ("built: success %s, charged %s"):format(tostring(success), charged))
				if not success then
					return true
				end
				local removed = 0
				pcall(function() : boolean
					removed = #(res.proposal.proposal.removedSegments or {})
					return true
				end)
				log(name, ("removed %d edges"):format(removed))
				local segs : {integer} = {}
				local nodes : {integer} = {}
				pcall(function() : boolean
					for __, seg in ipairs(res.proposal.proposal.addedSegments) do
						table.insert(segs, seg.entity)
					end
					for __, n in ipairs(res.proposal.proposal.addedNodes) do
						table.insert(nodes, n.entity)
					end
					return true
				end)
				for __, e in ipairs(segs) do
					pcall(function() : boolean
						local edge = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
						local street = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE_STREET) ~= nil
						log(name, ("added edge %d (%s): %s; %s"):format(e, street and "street" or "track",
							segmentCounts(edge.node0 as integer), segmentCounts(edge.node1 as integer)))
						return true
					end)
				end
				for __, n in ipairs(nodes) do
					log(name, "added " .. segmentCounts(n))
				end
				if andThen ~= nil then
					andThen(res)
				end
				return true
			end)
			if not okCb then
				log(name, "callback ERROR " .. tostring(err))
			end
		end)
end

-- P9: a level crossing ---------------------------------------------------------------------------------------------

function probe.levelCrossing(settings : Settings) : {function()}
	local c = camera()
	local street : Crossed = nil
	local proposal : SimpleProposal = nil
	local results : {string : boolean} = {}
	local tasks : {function()} = {}
	table.insert(tasks, guarded("P9", function()
		street = nearest(c, "street")
		if street == nil then
			log("P9", ("camera (%.1f %.1f): no street within 200 m"):format(c.x, c.y))
			return
		end
		log("P9", ("camera (%.1f %.1f): street edge %d at (%.1f %.1f) height %.2f"):format(c.x, c.y, street.entity,
			street.p.x, street.p.y, street.z))
		local across : Pt = { x = -street.dir.y, y = street.dir.x }
		local start = geo.add(street.p, geo.scale(across, -150))
		local net = network.build(testPlan({ straight(start, across, 300) }, street.z, 0, "ground"), network.defaults())
		local why : string
		proposal, why = builder.chunkProposal(net, 1, #net.edges, settings)
		if proposal == nil then
			log("P9", "NOT MADE " .. tostring(why))
		end
	end))
	for __, v in ipairs({ { "plain", false }, { "cleanupStreetGraph", true } }) do
		table.insert(tasks, guarded("P9", function()
			if proposal ~= nil then
				results[v[1] as string] = tryProposal("P9 " .. (v[1] as string), proposal, builder.newContext(v[2] as boolean))
			end
		end))
	end
	table.insert(tasks, guarded("P9", function()
		if proposal == nil then
			return
		end
		-- Build the first variant that dry-ran clean (test map only).
		for __, v in ipairs({ { "plain", false }, { "cleanupStreetGraph", true } }) do
			if results[v[1] as string] then
				log("P9", "building the " .. (v[1] as string) .. " variant")
				build("P9", proposal, builder.newContext(v[2] as boolean), function()
					log("P9", "done")
				end)
				return
			end
		end
		log("P9", "done (nothing clean to build)")
	end))
	return tasks
end

-- P10: build a station ---------------------------------------------------------------------------------------------

local function stationNear(p : Pt) : integer
	local best : integer = nil
	local bestD = math.huge
	local found = api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(p.x, p.y), 300,
		api.type.ComponentType.CONSTRUCTION)
	for __, e in ipairs(found) do
		pcall(function() : boolean
			local con = api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION) as Engine.Component.Construction
			if con ~= nil and tostring(con.fileName):find("modular_station.con", 1, true) ~= nil then
				local bv = api.engine.getComponent(e, api.type.ComponentType.BOUNDING_VOLUME) as Engine.Component.BoundingVolume
				local cx, cy = (bv.bbox.min.x + bv.bbox.max.x) / 2, (bv.bbox.min.y + bv.bbox.max.y) / 2
				local d = math.sqrt((cx - p.x) ^ 2 + (cy - p.y) ^ 2)
				if d < bestD then
					best, bestD = e, d
				end
			end
			return true
		end)
	end
	return best
end

-- The station's free track ends: its frozen nodes with one track piece.
local function freeEnds(station : integer) : {Pt3}
	local ends : {Pt3} = {}
	local con = api.engine.getComponent(station, api.type.ComponentType.CONSTRUCTION) as Engine.Component.Construction
	for __, node in ipairs(con.frozenNodes or {}) do
		local n = node as integer
		local track = -1
		pcall(function() : boolean
			track = #api.engine.system.streetSystem.getNodeTrackSegments(n)
			return true
		end)
		local p = nodePos(n)
		log("P10", ("frozen %s at (%.2f %.2f %.2f)"):format(segmentCounts(n), p.x, p.y, p.z))
		if track == 1 then
			table.insert(ends, p)
		end
	end
	return ends
end

function probe.buildStation(settings : Settings) : {function()}
	local c = camera()
	local east : Pt = { x = 1, y = 0 }
	local ground = groundAt(c)
	local plan : Plan = { ok = true, legs = {}, platformLength = 160,
		stations = { { town = { id = -1, name = "Probe", pos = c }, site = { centre = c, dir = east, distance = 0 },
			z = ground } } }
	return { guarded("P10", function()
		local layout = sl.layout(c, east, 160, settings.era)
		for i, p in ipairs(layout.ends) do
			log("P10", ("planned track end %d at (%.2f %.2f)"):format(i, p.x, p.y))
		end
		local proposal, why = builder.stationProposal(plan, 1, settings)
		if proposal == nil then
			log("P10", "NOT MADE " .. tostring(why))
			return
		end
		local context = builder.newContext()
		if not tryProposal("P10", proposal, context) then
			log("P10", "not built: the dry run wasn't clean")
			return
		end
		build("P10", proposal, context, function()
			local station = stationNear(c)
			log("P10", "station construction " .. tostring(station))
			if station ~= nil then
				freeEnds(station)
			end
			log("P10", "done")
		end)
	end) }
end

-- P11: join track to a station's ends, then a second chunk onwards ------------------------------------------------

function probe.joinStation(settings : Settings) : {function()}
	local c = camera()
	return { guarded("P11", function()
		local station = stationNear(c)
		if station == nil then
			log("P11", "no modular station within 300 m of the camera")
			return
		end
		local ends = freeEnds(station)
		log("P11", ("station %d: %d free track ends"):format(station, #ends))
		if #ends < 2 then
			return
		end
		-- The station's axis: between its two farthest-apart ends. Take the two ends on the +axis side.
		local a, b = ends[1], ends[2]
		local far = 0.0
		for i = 1, #ends do
			for j = i + 1, #ends do
				local d = math.sqrt((ends[i].x - ends[j].x) ^ 2 + (ends[i].y - ends[j].y) ^ 2)
				if d > far then
					far, a, b = d, ends[i], ends[j]
				end
			end
		end
		local axis = geo.scale(geo.sub({ x = a.x, y = a.y }, { x = b.x, y = b.y }), 1 / far)
		local mid : Pt = { x = (a.x + b.x) / 2, y = (a.y + b.y) / 2 }
		local side : {Pt3} = {}
		for __, e in ipairs(ends) do
			if geo.dot(geo.sub({ x = e.x, y = e.y }, mid), axis) > 0 then
				table.insert(side, e)
			end
		end
		log("P11", ("axis (%.3f %.3f), %d ends on its + side"):format(axis.x, axis.y, #side))
		-- Variant b first, for the log only: new nodes at the ends' places, cleanupStreetGraph merging them.
		local loose : {Pt3} = {}
		for __, e in ipairs(side) do
			table.insert(loose, { x = e.x, y = e.y, z = e.z })
		end
		local pb = builder.chunkProposal(straightNet(loose, axis, 100), 1, #side, settings)
		if pb ~= nil then
			tryProposal("P11 new nodes, cleanup", pb, builder.newContext(true))
		end
		local net = straightNet(side, axis, 100)
		local proposal, why = builder.chunkProposal(net, 1, #side, settings)
		if proposal == nil then
			log("P11", "NOT MADE " .. tostring(why))
			return
		end
		local context = builder.newContext()
		if not tryProposal("P11 joined to the ends", proposal, context) then
			log("P11", "not built: the dry run wasn't clean")
			return
		end
		build("P11 chunk A", proposal, context, function(res : WorldBuildProposalCommandData)
			for __, e in ipairs(side) do
				log("P11", "station end after: " .. segmentCounts(e.entity))
			end
			-- Chunk B from chunk A's far ends: the added edges' nodes that aren't the station's.
			local starts : {Pt3} = {}
			for __, seg in ipairs(res.proposal.proposal.addedSegments) do
				local edge = api.engine.getComponent(seg.entity, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
				for __, n in ipairs({ edge.node0 as integer, edge.node1 as integer }) do
					local isEnd = false
					for __, e in ipairs(side) do
						isEnd = isEnd or e.entity == n
					end
					if not isEnd then
						table.insert(starts, nodePos(n))
					end
				end
			end
			log("P11", ("chunk B from %d nodes"):format(#starts))
			local pB = builder.chunkProposal(straightNet(starts, axis, 100), 1, #starts, settings)
			if pB == nil or not tryProposal("P11 chunk B", pB, context) then
				log("P11", "done (chunk B not built)")
				return
			end
			build("P11 chunk B", pB, context, function()
				for __, n in ipairs(starts) do
					log("P11", "chunk A end after B: " .. segmentCounts(n.entity))
				end
				log("P11", "done")
			end)
		end)
	end) }
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
