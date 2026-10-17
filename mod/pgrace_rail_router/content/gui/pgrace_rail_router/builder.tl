local network = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/network.tl" as PgraceRailRouterNetwork
local sl = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/stationlayout.tl" as PgraceRailRouterStationLayout

local builder : PgraceRailRouterBuilder = {}

local type Check = PgraceRailRouterBuilder.Check
local type Settings = PgraceRailRouterBuilder.Settings
local type Item = PgraceRailRouterBuilder.Item
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

local function newContext() : Context
	local context = api.type.Context.new()
	context.player = api.engine.util.getPlayer()
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
	local layout = sl.layout(station.site.centre, station.site.dir, plan.platformLength, settings.era)
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

function builder.dryRun(proposal : SimpleProposal) : boolean, integer, {string}, integer, ProposalData
	local clock = api.type.Clock.new()
	-- makeProposalData takes a SimpleProposal, despite the tealdef (AGENTS.md).
	local ok, data = pcall(function() : ProposalData
		return api.engine.util.proposal.makeProposalData(proposal as any as Proposal, newContext())
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
	local cost = 0
	pcall(function() : boolean
		cost = math.floor(tonumber(pd.costs) or 0)
		return true
	end)
	return #messages == 0, cost, messages, us, pd
end

function builder.start(plan : Plan, settings : Settings) : Check
	local net = network.build(plan, settings.network)
	local items : {Item} = {}
	for i = 1, #plan.stations do
		table.insert(items, { kind = "station", index = i })
	end
	for i = 1, #net.chunks do
		table.insert(items, { kind = "chunk", index = i })
	end
	debugPrint(LOG_PREFIX .. ("check: %d stations, %d chunks, %d edges; track %s, bridge %s, tunnel %s, year %d")
		:format(#plan.stations, #net.chunks, #net.edges, tostring(settings.track),
		settings.bridge ~= nil and settings.bridge.name or "none", settings.tunnel ~= nil and settings.tunnel.name or "none",
		settings.year or 0))
	return { plan = plan, settings = settings, net = net, items = items, next = 1, outcomes = {}, total = 0,
		failures = 0, slowestUs = 0, totalUs = 0, done = #items == 0 }
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
	if not made then
		messages = { "couldn't make the proposal: " .. tostring(proposal) }
	elseif proposal == nil then
		messages = { tostring(why) }
	else
		ok, cost, messages, us = builder.dryRun(proposal as SimpleProposal)
	end
	table.insert(check.outcomes, { item = item, ok = ok, cost = cost, messages = messages, x = x, y = y, us = us })
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
	debugPrint(LOG_PREFIX .. ("dry run %s %d%s: %s, cost %d, %d us%s"):format(item.kind, item.index, extra,
		ok and "clean" or "errors", cost, us, #messages > 0 and (": " .. table.concat(messages, "; ")) or ""))
	if check.done then
		debugPrint(LOG_PREFIX .. ("check done: %d items, %d with errors, price %d, dry runs %.1f ms, the slowest %d us")
			:format(#check.items, check.failures, check.total, check.totalUs / 1000, check.slowestUs))
	end
	return check.done
end

function builder.progress(check : Check) : number
	return (check.next - 1) / math.max(1, #check.items)
end

return builder
