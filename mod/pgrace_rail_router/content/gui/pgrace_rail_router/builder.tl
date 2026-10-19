local network = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/network.tl" as PgraceRailRouterNetwork
local sl = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/stationlayout.tl" as PgraceRailRouterStationLayout
local survey = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/survey.tl" as PgraceRailRouterSurvey

local builder : PgraceRailRouterBuilder = {}

local type Check = PgraceRailRouterBuilder.Check
local type Settings = PgraceRailRouterBuilder.Settings
local type Item = PgraceRailRouterBuilder.Item
local type Collision = PgraceRailRouterBuilder.Collision
local type Network = PgraceRailRouterNetwork.Network
local type Pt3 = PgraceRailRouterNetwork.Pt3
local type Plan = PgraceRailRouterRoute.Plan

local LOG_PREFIX = "[rail_router] "
local STATION_FILE = "::/stations/rail/modular_station/modular_station.con"

local logged : {string : boolean} = {}
local function logOnce(key : string, message : string)
	if not logged[key] then
		logged[key] = true
		debugPrint(LOG_PREFIX .. message)
	end
end

-- How far the track may be above or below the street where it crosses it, for a level crossing (metres).
local LEVEL = 1.5

function builder.crossesOnLevel(net : Network, first : integer, last : integer, street : integer) : boolean
	local e = api.engine.getComponent(street, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
	if e == nil then
		return false
	end
	local function pt(v : Vec3f) : Pt3
		return { x = v.x, y = v.y, z = v.z }
	end
	local h : PgraceRailRouterNetwork.Hermite = { p0 = pt(e.position0), p1 = pt(e.position1), t0 = pt(e.tangent0),
		t1 = pt(e.tangent1) }
	for i = first, last do
		local t = net.edges[i]
		if t.kind == "ground" then
			local th : PgraceRailRouterNetwork.Hermite = { p0 = t.p0, p1 = t.p1, t0 = t.t0, t1 = t.t1 }
			for __, c in ipairs(network.crossings(th, h)) do
				if math.abs(network.hermiteAt(th, c.s).z - c.p.z) <= LEVEL then
					return true
				end
			end
		end
	end
	return false
end

local function v3(p : Pt3) : Vec3f
	return api.type.Vec3f.new(p.x, p.y, p.z)
end

function builder.newContext(cleanup ?: boolean) : Context
	local context = api.type.Context.new()
	context.player = api.engine.util.getPlayer()
	if cleanup then
		context.cleanupStreetGraph = true
	end
	return context
end

-- A finite number (not NaN or infinite): anything else in a proposal is malformed.
local function finite(x : number) : boolean
	return x ~= nil and x == x and x ~= math.huge and x ~= -math.huge
end

local function finitePt(p : Pt3) : boolean
	return finite(p.x) and finite(p.y) and finite(p.z)
end

-- A resource id from a repository's find, or -1 (also when find throws).
local function findIn(find : function(string) : integer, name : string) : integer
	local ok, id = pcall(function() : integer
		return find(name)
	end)
	if ok and id ~= nil then
		return id as integer
	end
	return -1
end

local SIGNAL_IDS = -400000000

function builder.chunkProposal(net : Network, first : integer, last : integer, settings : Settings) : SimpleProposal,
		string
	local templateId = findIn(api.res.streetTemplateRep.find, settings.track)
	if templateId < 0 then
		return nil, "track type not found: " .. tostring(settings.track)
	end
	local template = api.res.streetTemplateRep.get(templateId)
	local edgeType = api.type["enum"].BaseEdgeType
	-- Check every edge before making anything: a bridge or tunnel with no type, or a broken number, means no proposal.
	for i = first, last do
		local e = net.edges[i]
		if e.kind == "bridge" and settings.bridge == nil then
			return nil, "no bridge type available"
		elseif e.kind == "tunnel" and settings.tunnel == nil then
			return nil, "no tunnel type available"
		end
		if not (finitePt(e.p0) and finitePt(e.p1) and finitePt(e.t0) and finitePt(e.t1)) then
			return nil, "edge " .. i .. " has a point or tangent that isn't a number"
		end
	end
	-- New entities are numbered -1, -2, ... across edges and nodes, as the game's own proposals do (the base track
	-- builder: edge -1, nodes -3 and -4; Bus Loops' split: edges -1 and -2, node -3): the edges first, then the nodes.
	local edgeCount = last - first + 1
	local nodeIds : {integer : integer} = {}
	local nodes : {Proposal.NodeAndEntity} = {}
	local function node(index : integer) : integer
		local p = net.nodes[index]
		if p.entity ~= nil then
			return p.entity
		end
		if nodeIds[index] == nil then
			local n = api.type.NodeAndEntity.new()
			n.entity = -(edgeCount + #nodes + 1)
			n.comp.position = v3(net.nodes[index])
			table.insert(nodes, n)
			nodeIds[index] = n.entity
		end
		return nodeIds[index]
	end
	local edges : {Proposal.SegmentAndEntity} = {}
	local signals : {SimpleStreetProposal.EdgeObject} = {}
	for i = first, last do
		local e = net.edges[i]
		local seg = api.type.SegmentAndEntity.new()
		seg.entity = -(#edges + 1)
		seg.type = 1
		seg.comp.node0 = node(e.node0)
		seg.comp.node1 = node(e.node1)
		seg.comp.position0 = v3(e.p0)
		seg.comp.position1 = v3(e.p1)
		seg.comp.tangent0 = v3(e.t0)
		seg.comp.tangent1 = v3(e.t1)
		if e.kind == "bridge" then
			seg.comp.type = edgeType.BRIDGE
			seg.comp.typeIndex = settings.bridge.index
		elseif e.kind == "tunnel" then
			seg.comp.type = edgeType.TUNNEL
			seg.comp.typeIndex = settings.tunnel.index
		else
			seg.comp.type = edgeType.NORMAL
			seg.comp.typeIndex = settings.normalTypeIndex
		end
		seg.comp.laneConfigs = template.laneConfigs
		-- The distance between parallel tracks, as the game's own track carries it (probe P1: 5 on a double track the
		-- player built; left at 0, the game took the two tracks for one in their parallel strip, and drew overhead wire
		-- over one of them only).
		-- A crossover (track 0), a fan's piece (3) or a junction's (4) isn't one of a pair: left at 0; a junction's
		-- outer straights are (paired).
		if e.track == 1 or e.track == 2 or e.paired then
			seg.comp.distance = 2 * settings.network.offset
		end
		-- Owned by the player, as the game's own track is (P1: ours had no owner). The constructor isn't in the
		-- tealdefs: used only if it's there.
		local PlayerOwned = (api.type as any as {string : {string : function() : Engine.Component.PlayerOwned}})
			["PlayerOwned"]
		if PlayerOwned ~= nil and PlayerOwned.new ~= nil then
			local owned = PlayerOwned.new()
			owned.player = api.engine.util.getPlayer()
			seg.playerOwned = owned
		else
			logOnce("playerOwned", "api.type.PlayerOwned isn't there: track built without an owner")
		end
		seg.comp.roadTemplate = settings.track
		seg.comp.roadStyle = template.streetStyle
		seg.comp.roadType = api.type["enum"].RoadType.TRACK
		-- One-way signals (Halt 2+2): new edge objects numbered from SIGNAL_IDS down, listed on the edge too (the
		-- Express & Local mod's way; other ids were refused with "Unknown exception").
		if e.signals ~= nil and settings.signal ~= nil then
			local objects : {{integer}} = {}
			for __, sg in ipairs(e.signals) do
				local id = SIGNAL_IDS - #signals
				table.insert(objects, { id, api.type["enum"].EdgeObjectType.SIGNAL as integer })
				local obj = api.type.SimpleStreetProposal.EdgeObject.new()
				obj.edgeEntity = seg.entity
				obj.param = sg.param
				obj.oneWay = true
				-- On the train's right (right-hand running), measured against the edge's own direction.
				obj.left = not sg.forward
				obj.model = settings.signal
				obj.playerEntity = api.engine.util.getPlayer()
				table.insert(signals, obj)
			end
			(seg.comp as any as {string : any}).objects = objects
		end
		table.insert(edges, seg)
	end
	local proposal = api.type.SimpleProposal.new()
	proposal.streetProposal.nodesToAdd = nodes
	proposal.streetProposal.edgesToAdd = edges
	if #signals > 0 then
		proposal.streetProposal.edgeObjectsToAdd = signals
	end
	return proposal
end

local resolved : {string : string} = {}

function builder.resolveModule(name : string) : string
	if name == nil then
		return nil
	end
	if resolved[name] ~= nil then
		return resolved[name] ~= "" and resolved[name] or nil
	end
	local other = name:sub(1, 2) == "::" and name:sub(3) or "::" .. name
	local result = ""
	for __, candidate in ipairs({ name, other }) do
		if findIn(api.res.moduleRep.find, candidate) >= 0 then
			result = candidate
			break
		end
	end
	if result == "" then
		logOnce("module " .. name, "station module not found: " .. name)
	elseif result ~= name then
		logOnce("module " .. name, "station module " .. name .. " found as " .. result)
	end
	resolved[name] = result
	return result ~= "" and result or nil
end

function builder.stationLayout(plan : Plan, index : integer, settings : Settings) : PgraceRailRouterStationLayout.Layout
	local station = plan.stations[index]
	-- Turned so its main building faces the town (the track ends are the same either way).
	local dir = station.site.dir
	if station.town ~= nil and station.town.pos ~= nil then
		dir = sl.facing(station.site.centre, dir, station.town.pos)
	end
	return sl.layout(station.site.centre, dir, plan.platformLength, settings.era, settings.style)
end

function builder.stationProposal(plan : Plan, index : integer, settings : Settings) : SimpleProposal, string
	if findIn(api.res.constructionRep.find, STATION_FILE) < 0 then
		return nil, "station not found: " .. STATION_FILE
	end
	local station = plan.stations[index]
	local layout = builder.stationLayout(plan, index, settings)
	if not (finite(layout.angle) and finite(layout.origin.x) and finite(layout.origin.y) and finite(station.z)) then
		return nil, "the station's place isn't a number"
	end
	local all : {{integer : PgraceRailRouterStationLayout.Module}} = { layout.modules }
	if settings.addons ~= nil then
		table.insert(all, sl.addons(plan.platformLength, settings.addons, settings.style))
	end
	-- Only modules the game knows: a construction script reads each module's metadata, and a missing one is malformed.
	local modules : {integer : table} = {}
	for __, list in ipairs(all) do
		for slot, m in pairs(list) do
			local name = builder.resolveModule(m.name)
			if name == nil then
				return nil, "station module not found: " .. tostring(m.name)
			end
			modules[slot] = { name = name, variant = m.variant }
		end
	end
	local ce = api.type.SimpleProposal.ConstructionEntity.new()
	ce.fileName = STATION_FILE
	ce.params = { modules = modules, year = settings.year, seed = 1 }
	ce.transf = api.type.Mat4f.rotZTransl(layout.angle, api.type.Vec3f.new(layout.origin.x, layout.origin.y, station.z))
	ce.name = station.town ~= nil and station.town.name or "Rail Router"
	ce.playerEntity = api.engine.util.getPlayer()
	local proposal = api.type.SimpleProposal.new()
	proposal.constructionsToAdd = { ce }
	return proposal
end

function builder.levelCrossings(messages : {string}, collisions : {Collision},
		onLevel ?: function(street : integer) : boolean) : integer
	for __, m in ipairs(messages) do
		if m:lower() ~= "collision" then
			return 0
		end
	end
	-- Pieces of street that share a node are one road there: union-find over the nodes, then count the roots. A piece
	-- whose nodes are unknown stands alone (a key of its own, below any entity id).
	local parent : {integer : integer} = {}
	local function root(n : integer) : integer
		while parent[n] ~= nil do
			n = parent[n]
		end
		return n
	end
	-- A node joins the pieces that end at it (it is its own key: entity ids of nodes and pieces don't clash).
	for i, c in ipairs(collisions) do
		if c.what == "street" then
			local ra, rb = root(c.node0 or -i), root(c.node1 or -i)
			if ra ~= rb then
				parent[rb] = ra
			end
		end
	end
	-- Each road hit must be crossed on the level by some piece of it: one the track only runs into is no crossing.
	if onLevel ~= nil then
		local level : {integer : boolean} = {}
		for i, c in ipairs(collisions) do
			if c.what == "street" then
				local r = root(c.node0 or -i)
				level[r] = level[r] or onLevel(c.entity)
			end
		end
		for __, crossed in pairs(level) do
			if not crossed then
				return 0
			end
		end
	end
	local roads : {integer : boolean} = {}
	local count = 0
	for i, c in ipairs(collisions) do
		local key : integer = nil
		if c.what == "street" then
			key = c.node0 or -i
		elseif c.what == "node" then
			key = c.entity
		end
		if key ~= nil then
			local r = root(key)
			if not roads[r] then
				roads[r] = true
				count = count + 1
			end
		end
	end
	return count
end

function builder.junctionHits(collisions : {Collision}, splits : {PgraceRailRouterNetwork.Split}, nodes ?: {integer})
		: boolean, {Collision}
	-- The split pieces, and their nodes: those given, and those of the pieces as the collisions list them.
	local allowed : {integer : boolean} = {}
	for __, sp in ipairs(splits or {}) do
		allowed[sp.piece] = true
	end
	for __, n in ipairs(nodes or {}) do
		allowed[n] = true
	end
	for __, c in ipairs(collisions) do
		if allowed[c.entity] then
			if c.node0 ~= nil then
				allowed[c.node0] = true
			end
			if c.node1 ~= nil then
				allowed[c.node1] = true
			end
		end
	end
	local rest : {Collision} = {}
	for __, c in ipairs(collisions) do
		if not allowed[c.entity] then
			table.insert(rest, c)
		end
	end
	return #collisions > 0 and #rest == 0, rest
end

function builder.checkedEdges(net : Network, first : integer, last : integer) : Network, integer, integer
	local sub : Network = { nodes = net.nodes, edges = {}, chunks = {} }
	local whole, touching = 0, 0
	for i = first, last do
		local e = net.edges[i]
		if e.whole then
			whole = whole + 1
		elseif net.nodes[e.node0].existing ~= nil or net.nodes[e.node1].existing ~= nil then
			touching = touching + 1
		else
			table.insert(sub.edges, e)
		end
	end
	table.insert(sub.chunks, { first = 1, last = #sub.edges, leg = net.edges[first].leg, length = 0 })
	return sub, whole, touching
end

function builder.junctionCount(net : Network, first : integer, last : integer) : integer
	-- A junction's pieces lie before the leg's start (s below 0) or past its end.
	local atStart, atEnd = false, false
	for i = first, last do
		local e = net.edges[i]
		if e.whole then
			if (e.s0 + e.s1) / 2 < 0 then
				atStart = true
			else
				atEnd = true
			end
		end
	end
	return (atStart and 1 or 0) + (atEnd and 1 or 0)
end

local function has(entity : integer, ct : Engine.ComponentType) : boolean
	local ok, comp = pcall(function() : any
		return api.engine.getComponent(entity, ct)
	end)
	return ok and comp ~= nil
end

local function whatIs(entity : integer) : string
	local ct = api.type.ComponentType
	if has(entity, ct.BASE_EDGE_STREET) then
		return "street"
	elseif has(entity, ct.BASE_EDGE) then
		return "track"
	elseif has(entity, ct.BASE_NODE) then
		local segments = 0
		pcall(function() : boolean
			segments = #api.engine.system.streetSystem.getNodeSegments(entity)
			return true
		end)
		return segments >= 3 and "junction" or "node"
	elseif has(entity, ct.TOWN_BUILDING) then
		return "building"
	elseif has(entity, ct.CONSTRUCTION) then
		return "construction"
	end
	return "other"
end

-- The centre of the entity's bounding box, else the middle of its edge's ends; nil where neither can be read.
local function whereIs(entity : integer) : number, number
	local x, y : number, number = nil, nil
	pcall(function() : boolean
		local bv = api.engine.getComponent(entity, api.type.ComponentType.BOUNDING_VOLUME) as Engine.Component.BoundingVolume
		if bv ~= nil then
			x, y = (bv.bbox.min.x + bv.bbox.max.x) / 2, (bv.bbox.min.y + bv.bbox.max.y) / 2
			return true
		end
		local edge = api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
		if edge ~= nil then
			local a = api.engine.getComponent(edge.node0, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
			local b = api.engine.getComponent(edge.node1, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
			x, y = (a.position.x + b.position.x) / 2, (a.position.y + b.position.y) / 2
		end
		return true
	end)
	return x, y
end

function builder.collisions(data : ProposalData) : {Collision}
	local result : {Collision} = {}
	if data == nil then
		return result
	end
	local seen : {integer : boolean} = {}
	pcall(function() : boolean
		for __, d in ipairs(data.collisionInfo.collisionEntities or {}) do
			local e = d.entity as integer
			if e ~= nil and not seen[e] then
				seen[e] = true
				local x, y = whereIs(e)
				local c : Collision = { entity = e, what = whatIs(e), x = x, y = y }
				if c.what == "other" then
					local names : {string} = {}
					for name, ct in pairs(api.type.ComponentType as {string : any}) do
						if type(ct) == "number" and has(e, ct as Engine.ComponentType) then
							table.insert(names, name)
						end
					end
					table.sort(names)
					c.components = table.concat(names, ",")
				end
				pcall(function() : boolean
					local edge = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
					if edge ~= nil then
						c.node0, c.node1 = edge.node0 as integer, edge.node1 as integer
					end
					return true
				end)
				table.insert(result, c)
			end
		end
		return true
	end)
	return result
end

-- Notes (errorState.infos) a dry run gives that the build is then refused for: "Place on Land" came with ground track
-- over a lake's edge (Bangor - Imperial Beach), clean otherwise.
local REFUSING_INFOS : {string : boolean} = { ["Place on Land"] = true }

function builder.dryRun(proposal : SimpleProposal, context ?: Context) : boolean, integer, {string}, integer,
		ProposalData
	local clock = api.type.Clock.new()
	-- makeProposalData takes a SimpleProposal, despite the tealdef (AGENTS.md).
	local ok, data = pcall(function() : ProposalData
		return api.engine.util.proposal.makeProposalData(proposal as any as Proposal, context or builder.newContext())
	end)
	local us = math.floor(clock:getTime())
	if not ok or data == nil then
		return false, 0, { "dry run failed: " .. tostring(data) }, us, nil
	end
	local pd = data as ProposalData
	local messages : {string} = {}
	local read = pcall(function() : boolean
		for __, m in ipairs(pd.errorState.messages or {}) do
			table.insert(messages, tostring(m))
		end
		return true
	end)
	if not read then
		table.insert(messages, "couldn't read the dry run's errors")
	end
	-- Notes the game only refuses on at build time (a clean dry run that the build then refused: track over water).
	pcall(function() : boolean
		for __, m in ipairs(pd.errorState.infos or {}) do
			if REFUSING_INFOS[tostring(m)] then
				table.insert(messages, tostring(m))
			end
		end
		return true
	end)
	local cost = 0
	pcall(function() : boolean
		cost = math.floor(tonumber(pd.costs) or 0)
		return true
	end)
	return #messages == 0, cost, messages, us, pd
end

local PRICE_LENGTH = 100.0

function builder.pricePerMetre(settings : Settings, at : Pt3, dir : PgraceRailRouterGeo.Pt) : number
	local o = settings.network.offset
	local left = { x = -dir.y * o, y = dir.x * o }
	local t : Pt3 = { x = dir.x * PRICE_LENGTH, y = dir.y * PRICE_LENGTH, z = 0 }
	local net : Network = { nodes = {}, edges = {}, chunks = {} }
	for track = 1, 2 do
		local side = track == 1 and 1 or -1
		local p0 : Pt3 = { x = at.x + side * left.x, y = at.y + side * left.y, z = at.z }
		local p1 : Pt3 = { x = p0.x + t.x, y = p0.y + t.y, z = at.z }
		table.insert(net.nodes, p0)
		table.insert(net.nodes, p1)
		table.insert(net.edges, { node0 = #net.nodes - 1, node1 = #net.nodes, p0 = p0, p1 = p1, t0 = t, t1 = t,
			kind = "ground", track = track, leg = 1, s0 = 0, s1 = PRICE_LENGTH })
	end
	local proposal = builder.chunkProposal(net, 1, 2, settings)
	if proposal == nil then
		return nil
	end
	local __, cost = builder.dryRun(proposal)
	if cost == nil or cost <= 0 then
		return nil
	end
	return cost / PRICE_LENGTH
end

function builder.diagnose(net : Network, first : integer, last : integer, settings : Settings)
	pcall(function() : boolean
		local function fmt(p : Pt3) : string
			return ("(%.2f %.2f %.2f%s)"):format(p.x, p.y, p.z, p.entity ~= nil and (" #" .. p.entity) or "")
		end
		-- Edges at each node of the chunk.
		local at : {integer : {integer}} = {}
		for i = first, last do
			for __, n in ipairs({ net.edges[i].node0, net.edges[i].node1 }) do
				at[n] = at[n] or {}
				table.insert(at[n], i)
			end
		end
		local logged = 0
		for i = first, last do
			local e = net.edges[i]
			local proposal = builder.chunkProposal(net, i, i, settings)
			if proposal ~= nil then
				local ok, __, messages = builder.dryRun(proposal)
				if not ok and logged < 12 then
					logged = logged + 1
					debugPrint(LOG_PREFIX .. ("diagnose edge %d (%s, track %d, s %.1f-%.1f): %s; %s -> %s, t0 (%.2f %.2f %.3f) t1 (%.2f %.2f %.3f)")
						:format(i, e.kind, e.track, e.s0, e.s1, table.concat(messages, "; "), fmt(e.p0), fmt(e.p1), e.t0.x, e.t0.y,
						e.t0.z, e.t1.x, e.t1.y, e.t1.z))
				end
			end
		end
		-- The switches (nodes with three edges): those three alone.
		local switches = 0
		for n, list in pairs(at) do
			if #list >= 3 and switches < 6 then
				switches = switches + 1
				local sub : Network = { nodes = net.nodes, edges = {}, chunks = {} }
				for __, i in ipairs(list) do
					table.insert(sub.edges, net.edges[i])
				end
				local proposal = builder.chunkProposal(sub, 1, #sub.edges, settings)
				if proposal ~= nil then
					local ok, __, messages = builder.dryRun(proposal)
					local parts : {string} = {}
					for __, i in ipairs(list) do
						local e = net.edges[i]
						table.insert(parts, ("%d (track %d, s %.1f-%.1f, t0 %.2f %.2f, t1 %.2f %.2f)"):format(i, e.track, e.s0, e.s1,
							e.t0.x, e.t0.y, e.t1.x, e.t1.y))
					end
					debugPrint(LOG_PREFIX .. ("diagnose switch at node %d %s: %s; edges %s"):format(n, fmt(net.nodes[n]),
						ok and "clean" or table.concat(messages, "; "), table.concat(parts, ", ")))
				end
			end
		end
		debugPrint(LOG_PREFIX .. ("diagnose: %d of %d edges refused alone (at most 12 logged), %d switches tried")
			:format(logged, last - first + 1, switches))
		return true
	end)
end

local STATION_FILE_NAME = "modular_station.con"
-- A station's track end matches a network node this close, and a chunk's node an existing track node this close (m).
local END_MATCH = 1.0
local NODE_MATCH = 0.5

local function nodeAt(n : integer) : Pt3
	local node = api.engine.getComponent(n, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
	if node == nil then
		return nil
	end
	return { x = node.position.x, y = node.position.y, z = node.position.z, entity = n }
end

-- The modular station nearest (x, y) within 200 m, or nil.
local function stationNear(x : number, y : number) : integer
	local best : integer = nil
	local bestD = math.huge
	for __, e in ipairs(api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(x, y), 200,
			api.type.ComponentType.CONSTRUCTION)) do
		pcall(function() : boolean
			local con = api.engine.getComponent(e, api.type.ComponentType.CONSTRUCTION) as Engine.Component.Construction
			if con ~= nil and tostring(con.fileName):find(STATION_FILE_NAME, 1, true) ~= nil then
				local bv = api.engine.getComponent(e, api.type.ComponentType.BOUNDING_VOLUME) as Engine.Component.BoundingVolume
				local d = math.sqrt(((bv.bbox.min.x + bv.bbox.max.x) / 2 - x) ^ 2 + ((bv.bbox.min.y + bv.bbox.max.y) / 2 - y) ^ 2)
				if d < bestD then
					best, bestD = e, d
				end
			end
			return true
		end)
	end
	return best
end

local function dist2(a : Pt3, b : Pt3) : number
	return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
end

function builder.builtStation(plan : Plan, i : integer, net : Network) : boolean
	local c = plan.stations[i].site.centre
	local con = stationNear(c.x, c.y)
	if con == nil then
		return false
	end
	local matches : {{Pt3, integer}} = {}
	for __, e in ipairs(survey.trackEnds(con)) do
		for __, n in ipairs(net.nodes) do
			if dist2(n, e) <= END_MATCH and (n.entity == nil or n.entity == e.entity) then
				table.insert(matches, { n, e.entity })
			end
		end
	end
	if #matches < 2 then
		return false
	end
	for __, m in ipairs(matches) do
		m[1].entity = m[2]
	end
	debugPrint(LOG_PREFIX .. ("station %d: construction %d, %d track ends joined"):format(i, con, #matches))
	return true
end

-- An existing track node within NODE_MATCH of p (and 1.5 m in height), or nil.
local function trackNodeAt(p : Pt3) : integer
	local best : integer = nil
	local bestD = NODE_MATCH
	for __, n in ipairs(api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(p.x, p.y), 2,
			api.type.ComponentType.BASE_NODE)) do
		local q = nodeAt(n as integer)
		if q ~= nil and math.abs(q.z - p.z) <= 1.5 and dist2(p, q) <= bestD
				and #api.engine.system.streetSystem.getNodeTrackSegments(n) > 0 then
			best, bestD = n as integer, dist2(p, q)
		end
	end
	return best
end

builder.trackNodeAt = trackNodeAt

function builder.cutNodes(net : Network, c : integer, piece : integer) : {Pt3}
	local chunk = net.chunks[c]
	local list : {Pt3} = {}
	local seen : {Pt3 : boolean} = {}
	for i = chunk.first, chunk.last do
		local e = net.edges[i]
		for __, k in ipairs({ e.node0, e.node1 }) do
			local n = net.nodes[k]
			if n.existing ~= nil and n.existing.piece == piece and not seen[n] then
				seen[n] = true
				table.insert(list, n)
			end
		end
	end
	table.sort(list, function(a : Pt3, b : Pt3) : boolean
		return a.existing.s < b.existing.s
	end)
	return list
end

-- The existing piece as a track edge, or nil where it's gone (a split replaced it) or can't be read.
local function trackPiece(piece : integer) : Engine.Component.BaseEdge
	local ok, edge = pcall(function() : Engine.Component.BaseEdge
		if not api.engine.entityExists(piece) then
			return nil
		end
		local e = api.engine.getComponent(piece, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
		if e == nil or e.roadType ~= api.type["enum"].RoadType.TRACK then
			return nil
		end
		return e
	end)
	if not ok then
		return nil
	end
	return edge as Engine.Component.BaseEdge
end

function builder.splitDone(net : Network, c : integer, split : PgraceRailRouterNetwork.Split) : boolean, string
	local cuts = builder.cutNodes(net, c, split.piece)
	-- Still there: a track piece by that id that passes every open cut's place (ids are reused: P15's new pieces had
	-- ids below the old ones).
	local edge = trackPiece(split.piece)
	if edge ~= nil then
		local h : PgraceRailRouterNetwork.Hermite = { p0 = { x = edge.position0.x, y = edge.position0.y, z = edge.position0.z },
			p1 = { x = edge.position1.x, y = edge.position1.y, z = edge.position1.z },
			t0 = { x = edge.tangent0.x, y = edge.tangent0.y, z = edge.tangent0.z },
			t1 = { x = edge.tangent1.x, y = edge.tangent1.y, z = edge.tangent1.z } }
		local fits = true
		for __, n in ipairs(cuts) do
			if n.entity == nil then
				local q = network.hermiteAt(h, network.nearestParam(h, { x = n.x, y = n.y }))
				if dist2(q, n) > NODE_MATCH or math.abs(q.z - n.z) > 1.5 then
					fits = false
				end
			end
		end
		if fits then
			return false, nil
		end
	end
	for __, n in ipairs(cuts) do
		if n.entity == nil then
			local ok, found = pcall(trackNodeAt, n)
			if not ok or found == nil then
				return true, ("the existing track where a junction meets it (%.0f, %.0f) has changed since the route was found (piece %d is gone, and no node is there): find the route again")
					:format(n.x, n.y, split.piece)
			end
			n.entity = found as integer
		end
	end
	return true, nil
end

function builder.builtChunk(net : Network, c : integer) : boolean
	local chunk = net.chunks[c]
	local found : {Pt3 : integer} = {}
	for i = chunk.first, chunk.last do
		local e = net.edges[i]
		for __, k in ipairs({ e.node0, e.node1 }) do
			local n = net.nodes[k]
			if n.entity == nil and found[n] == nil then
				local entity = trackNodeAt(n)
				if entity == nil then
					return false
				end
				found[n] = entity
			end
		end
	end
	for n, entity in pairs(found) do
		n.entity = entity
	end
	return true
end

function builder.start(plan : Plan, settings : Settings, settingsUs ?: integer) : Check
	local clock = api.type.Clock.new()
	local net = network.build(plan, settings.network)
	local items : {Item} = {}
	for i = 1, #plan.stations do
		table.insert(items, { kind = "station", index = i })
	end
	for i = 1, #net.chunks do
		table.insert(items, { kind = "chunk", index = i })
	end
	debugPrint(LOG_PREFIX .. ("check: %d stations, %d chunks, %d edges; track %s, bridge %s, tunnel %s, year %d; settings %d us, network %d us")
		:format(#plan.stations, #net.chunks, #net.edges, tostring(settings.track),
		settings.bridge ~= nil and settings.bridge.name or "none", settings.tunnel ~= nil and settings.tunnel.name or "none",
		settings.year or 0, settingsUs or 0, math.floor(clock:getTime())))
	return { plan = plan, settings = settings, net = net, items = items, next = 1, outcomes = {}, total = 0,
		failures = 0, crossings = 0, junctions = 0, built = 0, slowestUs = 0, totalUs = 0, done = #items == 0 }
end

function builder.step(check : Check) : boolean
	if check.done then
		return true
	end
	local item = check.items[check.next]
	check.next = check.next + 1
	check.done = check.next > #check.items
	local x, y = 0.0, 0.0
	-- Already built (a build stopped earlier, then the game restarted): not dry-run; Build skips it.
	local builtOk, isBuilt = pcall(function() : boolean
		if item.kind == "station" then
			return builder.builtStation(check.plan, item.index, check.net)
		end
		return builder.builtChunk(check.net, item.index)
	end)
	if builtOk and isBuilt then
		table.insert(check.outcomes, { item = item, ok = true, cost = 0, messages = {}, x = x, y = y, us = 0,
			collisions = {}, crossings = 0, junctions = 0, built = true })
		check.built = check.built + 1
		debugPrint(LOG_PREFIX .. ("dry run %s %d: already built"):format(item.kind, item.index))
		if check.done then
			debugPrint(LOG_PREFIX .. ("check done: %d items, %d already built, %d with errors"):format(#check.items,
				check.built, check.failures))
		end
		return check.done
	end
	local chunk : PgraceRailRouterNetwork.Chunk = nil
	if item.kind == "chunk" then
		chunk = check.net.chunks[item.index]
	end
	-- A junction's splits still to make (one made already, by a build that stopped: its cut nodes are then joined to
	-- the nodes it made), and why the chunk can't be built.
	local splits : {PgraceRailRouterNetwork.Split} = {}
	local problem : string = chunk ~= nil and chunk.problem or nil
	if chunk ~= nil and problem == nil then
		for __, sp in ipairs(chunk.splits or {}) do
			local okDone, done, whyDone = pcall(builder.splitDone, check.net, item.index, sp)
			if not okDone then
				problem = problem or ("couldn't read the existing track: " .. tostring(done))
			elseif whyDone ~= nil then
				problem = problem or whyDone as string
			elseif not done then
				table.insert(splits, sp)
			end
		end
	end
	-- A junction's pieces (`whole`) lie over existing track they don't share a node with until it is split, and the game
	-- refuses that as "Construction Not Possible" (P15: never "Collision"), so the check leaves them out, and any other
	-- edge that ends on one of their cuts; the build dry-runs the whole chunk after the splits.
	local sub : PgraceRailRouterNetwork.Network = check.net
	local leftWhole, leftTouching = 0, 0
	if chunk ~= nil then
		sub, leftWhole, leftTouching = builder.checkedEdges(check.net, chunk.first, chunk.last)
		if leftWhole + leftTouching > 0 then
			debugPrint(LOG_PREFIX .. ("dry run chunk %d: junction pieces not dry-run before the split (%d left out, and %d other edges ending on their cuts)")
				:format(item.index, leftWhole, leftTouching))
		end
	end
	local made, proposal, why = pcall(function() : SimpleProposal, string
		if item.kind == "station" then
			local c = check.plan.stations[item.index].site.centre
			x, y = c.x, c.y
			return builder.stationProposal(check.plan, item.index, check.settings)
		end
		local p = check.net.edges[chunk.first].p0
		x, y = p.x, p.y
		if problem ~= nil then
			return nil, problem
		end
		if #sub.edges == 0 then
			return nil, nil
		end
		return builder.chunkProposal(sub, 1, #sub.edges, check.settings)
	end)
	local ok, cost, messages, us = false, 0, {} as {string}, 0
	local collisions : {Collision} = {}
	local crossings = 0
	local junctions = 0
	if chunk ~= nil then
		junctions = builder.junctionCount(check.net, chunk.first, chunk.last)
	end
	if not made then
		messages = { "couldn't make the proposal: " .. tostring(proposal) }
	elseif proposal == nil and why == nil and problem == nil and chunk ~= nil then
		-- Nothing left to dry-run: the chunk is only a junction's pieces.
		ok = true
	elseif proposal == nil then
		messages = { tostring(why) }
	else
		local data : ProposalData
		ok, cost, messages, us, data = builder.dryRun(proposal as SimpleProposal)
		collisions = builder.collisions(data)
		-- What the junction's splits don't explain: before the split, a junction's node lies on the existing piece,
		-- and the dry run collides with it (and its nodes). Only where every message is a collision.
		local rest = collisions
		if not ok and #splits > 0 then
			local onlyCollisions = #messages > 0
			for __, m in ipairs(messages) do
				if m:lower() ~= "collision" then
					onlyCollisions = false
				end
			end
			if onlyCollisions then
				local nodes : {integer} = {}
				for __, sp in ipairs(splits) do
					pcall(function() : boolean
						local e = api.engine.getComponent(sp.piece, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
						if e ~= nil then
							table.insert(nodes, e.node0 as integer)
							table.insert(nodes, e.node1 as integer)
						end
						return true
					end)
				end
				local all : boolean
				all, rest = builder.junctionHits(collisions, splits, nodes)
				if all then
					ok, messages = true, {}
				end
			end
		end
		if not ok and item.kind == "chunk" and check.settings.levelCrossings and #rest > 0 then
			crossings = builder.levelCrossings(messages, rest, function(street : integer) : boolean
				local okLevel, level = pcall(builder.crossesOnLevel, sub, 1, #sub.edges, street)
				return okLevel and level as boolean
			end)
			local others = 0
			for __, c in ipairs(rest) do
				if c.what ~= "street" and c.what ~= "node" then
					others = others + 1
				end
			end
			if crossings > 0 and others == 0 then
				ok, messages = true, {}
			end
		end
	end
	table.insert(check.outcomes, { item = item, ok = ok, cost = cost, messages = messages, x = x, y = y, us = us,
		collisions = collisions, crossings = crossings, junctions = junctions })
	check.crossings = check.crossings + crossings
	check.junctions = check.junctions + junctions
	check.total = check.total + cost
	check.totalUs = check.totalUs + us
	check.slowestUs = math.max(check.slowestUs, us)
	if not ok then
		check.failures = check.failures + 1
	end
	local extra = ""
	if item.kind == "chunk" then
		extra = (" (%d edges, %.0f m%s)"):format(chunk.last - chunk.first + 1, chunk.length,
			junctions > 0 and (", %d junctions, %d pieces to split"):format(junctions, #splits) or "")
	end
	local hits : {string} = {}
	for __, c in ipairs(collisions) do
		table.insert(hits, ("%s %d at (%.0f %.0f)%s"):format(c.what, c.entity, c.x or 0, c.y or 0,
			c.components ~= nil and (" [" .. c.components .. "]") or ""))
	end
	if not ok and item.kind == "chunk" and #messages > 0 and messages[1] == "Construction Not Possible" then
		builder.diagnose(check.net, chunk.first, chunk.last, check.settings)
	end
	debugPrint(LOG_PREFIX .. ("dry run %s %d%s: %s, cost %d, %d us%s%s"):format(item.kind, item.index, extra,
		ok and (crossings > 0 and ("clean but for %d level crossings"):format(crossings)
			or (#splits > 0 and #collisions > 0) and "clean but for the junction's existing track"
			or leftWhole > 0 and "clean but for the junction's pieces (not dry-run)" or "clean") or "errors", cost,
		us, #messages > 0 and (": " .. table.concat(messages, "; ")) or "",
		#hits > 0 and ("; collided with " .. table.concat(hits, ", ")) or ""))
	if check.done then
		debugPrint(LOG_PREFIX .. ("check done: %d items, %d with errors, %d level crossings, %d junctions, price %d, dry runs %.1f ms, the slowest %d us")
			:format(#check.items, check.failures, check.crossings, check.junctions, check.total, check.totalUs / 1000,
			check.slowestUs))
	end
	return check.done
end

function builder.progress(check : Check) : number
	return (check.next - 1) / math.max(1, #check.items)
end

return builder
