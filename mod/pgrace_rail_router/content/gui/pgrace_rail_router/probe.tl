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

-- P5 -------------------------------------------------------------------------------------------------------------

-- The typeIndex the game's own plain track edges carry near p (the most common one), or nil if none are near.
local function nearbyNormalTypeIndex(p : Pt) : integer
	local counts : {integer : integer} = {}
	local edges = api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(p.x, p.y), 1000,
		api.type.ComponentType.BASE_EDGE)
	for __, e in ipairs(edges) do
		pcall(function() : boolean
			local edge = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
			if edge ~= nil and edge.roadType == api.type["enum"].RoadType.TRACK
					and edge.type == api.type["enum"].BaseEdgeType.NORMAL then
				counts[edge.typeIndex] = (counts[edge.typeIndex] or 0) + 1
			end
			return true
		end)
	end
	local best : integer = nil
	for index, n in pairs(counts) do
		log("P5", ("nearby plain track edges with typeIndex %d: %d"):format(index, n))
		if best == nil or n > counts[best] then
			best = index
		end
	end
	return best
end

local function balance() : string
	local ok, b = pcall(function() : integer
		return api.engine.util.finance.getPlayersBalance(api.engine.util.getPlayer())
	end)
	return ok and tostring(b) or "?"
end

function probe.buildStraight(settings : Settings) : {function()}
	local c = camera()
	local east : Pt = { x = 1, y = 0 }
	local ground = groundAt(c)
	return { guarded("P5", function()
		local s = settings
		local nearby = nearbyNormalTypeIndex(c)
		if nearby ~= nil and nearby ~= settings.normalTypeIndex then
			log("P5", ("using the nearby track's typeIndex %d instead of %d"):format(nearby, settings.normalTypeIndex))
			s = with(settings, function(copy : Settings) copy.normalTypeIndex = nearby end)
		end
		local net = network.build(testPlan({ straight(c, east, 200) }, ground + 0.5, 0, "ground"), network.defaults())
		local proposal, why = builder.chunkProposal(net, 1, #net.edges, s)
		if proposal == nil then
			log("P5", "NOT MADE " .. tostring(why))
			return
		end
		local ok, cost, messages, us, data = builder.dryRun(proposal)
		log("P5", ("camera (%.1f %.1f) ground %.2f; dry run %s cost %d %d us edges %d %s"):format(c.x, c.y, ground,
			ok and "clean" or "ERRORS", cost, us, #net.edges, table.concat(messages, "; ")))
		-- Never send a proposal that didn't dry-run clean: a malformed one is an uncatchable crash (AGENTS.md).
		if not ok then
			log("P5", "not built: the dry run wasn't clean")
			return
		end
		-- Nor one that collides with anything (unreadable counts as colliding).
		local collisions = -1
		pcall(function() : boolean
			collisions = #(data.collisionInfo.collisionEntities or {})
			return true
		end)
		if collisions ~= 0 then
			logCollisions("P5", data)
			log("P5", "not built: collisions " .. (collisions < 0 and "unreadable" or tostring(collisions)))
			return
		end
		for i, e in ipairs(net.edges) do
			log("P5", ("sent edge %d: p0 (%.2f %.2f %.2f) p1 (%.2f %.2f %.2f) t0 (%.2f %.2f %.3f) t1 (%.2f %.2f %.3f)")
				:format(i, e.p0.x, e.p0.y, e.p0.z, e.p1.x, e.p1.y, e.p1.z, e.t0.x, e.t0.y, e.t0.z, e.t1.x, e.t1.y, e.t1.z))
		end
		log("P5", "balance before " .. balance())
		local context = api.type.Context.new()
		context.player = api.engine.util.getPlayer()
		api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(proposal, context, false, true),
			function(res : WorldBuildProposalCommandData, success : boolean)
				local okCb, err = pcall(function() : boolean
					local charged = "?"
					pcall(function() : boolean
						charged = tostring(res.resultProposalData.costs)
						return true
					end)
					log("P5", ("built: success %s, charged %s, balance after %s"):format(tostring(success), charged,
						balance()))
					if not success then
						pcall(function() : boolean
							for __, m in ipairs(res.resultProposalData.errorState.messages or {}) do
								log("P5", "error " .. tostring(m))
							end
							return true
						end)
						return true
					end
					-- Entity ids only; the components are read again now, after the command (AGENTS.md).
					local entities : {integer} = {}
					pcall(function() : boolean
						for __, seg in ipairs(res.proposal.proposal.addedSegments) do
							table.insert(entities, seg.entity)
						end
						return true
					end)
					for __, e in ipairs(entities) do
						pcall(function() : boolean
							logEdge(e)
							return true
						end)
					end
					log("P5", "done (" .. #entities .. " edges built)")
					return true
				end)
				if not okCb then
					log("P5", "callback ERROR " .. tostring(err))
				end
			end)
	end) }
end

return probe
