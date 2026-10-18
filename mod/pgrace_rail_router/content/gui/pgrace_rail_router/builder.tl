local network = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/network.tl" as PgraceRailRouterNetwork
local sl = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/stationlayout.tl" as PgraceRailRouterStationLayout

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
		seg.comp.roadTemplate = settings.track
		seg.comp.roadStyle = template.streetStyle
		seg.comp.roadType = api.type["enum"].RoadType.TRACK
		table.insert(edges, seg)
	end
	local proposal = api.type.SimpleProposal.new()
	proposal.streetProposal.nodesToAdd = nodes
	proposal.streetProposal.edgesToAdd = edges
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

function builder.stationProposal(plan : Plan, index : integer, settings : Settings) : SimpleProposal, string
	if findIn(api.res.constructionRep.find, STATION_FILE) < 0 then
		return nil, "station not found: " .. STATION_FILE
	end
	local station = plan.stations[index]
	-- Turned so its main building faces the town (the track ends are the same either way).
	local dir = station.site.dir
	if station.town ~= nil and station.town.pos ~= nil then
		dir = sl.facing(station.site.centre, dir, station.town.pos)
	end
	local layout = sl.layout(station.site.centre, dir, plan.platformLength, settings.era)
	if not (finite(layout.angle) and finite(layout.origin.x) and finite(layout.origin.y) and finite(station.z)) then
		return nil, "the station's place isn't a number"
	end
	local all : {{integer : PgraceRailRouterStationLayout.Module}} = { layout.modules }
	if settings.addons ~= nil then
		table.insert(all, sl.addons(plan.platformLength, settings.addons))
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

function builder.levelCrossings(messages : {string}, collisions : {Collision}) : integer
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
		failures = 0, crossings = 0, slowestUs = 0, totalUs = 0, done = #items == 0 }
end

function builder.step(check : Check) : boolean
	if check.done then
		return true
	end
	local item = check.items[check.next]
	check.next = check.next + 1
	check.done = check.next > #check.items
	local x, y = 0.0, 0.0
	local made, proposal, why = pcall(function() : SimpleProposal, string
		if item.kind == "station" then
			local c = check.plan.stations[item.index].site.centre
			x, y = c.x, c.y
			return builder.stationProposal(check.plan, item.index, check.settings)
		end
		local chunk = check.net.chunks[item.index]
		local p = check.net.edges[chunk.first].p0
		x, y = p.x, p.y
		return builder.chunkProposal(check.net, chunk.first, chunk.last, check.settings)
	end)
	local ok, cost, messages, us = false, 0, {} as {string}, 0
	local collisions : {Collision} = {}
	local crossings = 0
	if not made then
		messages = { "couldn't make the proposal: " .. tostring(proposal) }
	elseif proposal == nil then
		messages = { tostring(why) }
	else
		local data : ProposalData
		ok, cost, messages, us, data = builder.dryRun(proposal as SimpleProposal)
		collisions = builder.collisions(data)
		if not ok and item.kind == "chunk" and check.settings.levelCrossings then
			crossings = builder.levelCrossings(messages, collisions)
			local others = 0
			for __, c in ipairs(collisions) do
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
		collisions = collisions, crossings = crossings })
	check.crossings = check.crossings + crossings
	check.total = check.total + cost
	check.totalUs = check.totalUs + us
	check.slowestUs = math.max(check.slowestUs, us)
	if not ok then
		check.failures = check.failures + 1
	end
	local extra = ""
	if item.kind == "chunk" then
		local chunk = check.net.chunks[item.index]
		extra = (" (%d edges, %.0f m)"):format(chunk.last - chunk.first + 1, chunk.length)
	end
	local hits : {string} = {}
	for __, c in ipairs(collisions) do
		table.insert(hits, ("%s %d at (%.0f %.0f)%s"):format(c.what, c.entity, c.x or 0, c.y or 0,
			c.components ~= nil and (" [" .. c.components .. "]") or ""))
	end
	debugPrint(LOG_PREFIX .. ("dry run %s %d%s: %s, cost %d, %d us%s%s"):format(item.kind, item.index, extra,
		ok and (crossings > 0 and ("clean but for %d level crossings"):format(crossings) or "clean") or "errors", cost,
		us, #messages > 0 and (": " .. table.concat(messages, "; ")) or "",
		#hits > 0 and ("; collided with " .. table.concat(hits, ", ")) or ""))
	if check.done then
		debugPrint(LOG_PREFIX .. ("check done: %d items, %d with errors, %d level crossings, price %d, dry runs %.1f ms, the slowest %d us")
			:format(#check.items, check.failures, check.crossings, check.total, check.totalUs / 1000, check.slowestUs))
	end
	return check.done
end

function builder.progress(check : Check) : number
	return (check.next - 1) / math.max(1, #check.items)
end

return builder
