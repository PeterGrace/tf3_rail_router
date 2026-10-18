local network = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/network.tl" as PgraceRailRouterNetwork
local builder = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/builder.tl" as PgraceRailRouterBuilder

local build : PgraceRailRouterBuild = {}

local type Build = PgraceRailRouterBuild.Build
local type Network = PgraceRailRouterNetwork.Network
local type Pt3 = PgraceRailRouterNetwork.Pt3
local type Hermite = PgraceRailRouterNetwork.Hermite
local type Cut = PgraceRailRouterNetwork.Cut

local LOG_PREFIX = "[rail_router] build "
-- A node a built chunk added is matched to a network node this close (metres).
local NODE_MATCH = 0.5
-- A crossing this close to an existing street node uses the node, not a split (metres): within network.cut's 1 m,
-- since the track then runs through the node (Bangor - Imperial Beach crossed 1.81 m from one, and the cut refused
-- it). A node joins one track at most: two tracks through one node would join them.
local NODE_SNAP = 0.5

local function log(text : string)
	debugPrint(LOG_PREFIX .. text)
end

local function v3(p : Pt3) : Vec3f
	return api.type.Vec3f.new(p.x, p.y, p.z)
end

local function p3(v : Vec3f) : Pt3
	return { x = v.x, y = v.y, z = v.z }
end

local function dist2(a : Pt3, b : Pt3) : number
	return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
end

local function nodePos(node : integer) : Pt3
	local n = api.engine.getComponent(node, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
	if n == nil then
		return nil
	end
	return { x = n.position.x, y = n.position.y, z = n.position.z, entity = node }
end

local function fail(b : Build, messages : {string}, x : number, y : number)
	local item : PgraceRailRouterBuilder.Item
	if b.phase == "stations" then
		item = { kind = "station", index = b.station }
	else
		item = { kind = "chunk", index = b.chunk }
	end
	b.failure = { item = item, messages = messages, x = x, y = y }
	b.phase = "failed"
	b.waiting = false
	log(("%s %d failed: %s"):format(item.kind, item.index, table.concat(messages, "; ")))
end

-- Sends a command; on success onBuilt(res) (in a pcall: an error fails the build), else the build fails with the
-- game's messages.
local function send(b : Build, proposal : any, x : number, y : number,
		onBuilt : function(WorldBuildProposalCommandData))
	b.waiting = true
	local cmd = api.cmd.makeWorldBuildProposalCmd(proposal as SimpleProposal, builder.newContext(), false, true)
	api.cmd.sendCommand(cmd, function(res : WorldBuildProposalCommandData, success : boolean)
		local ok, err = pcall(function() : boolean
			b.waiting = false
			if not success then
				local messages : {string} = {}
				pcall(function() : boolean
					for __, m in ipairs(res.resultProposalData.errorState.messages or {}) do
						table.insert(messages, tostring(m))
					end
					return true
				end)
				pcall(function() : boolean
					local es = res.resultProposalData.errorState
					log(("refused: critical %s, messages %d, warnings %s, infos %s"):format(tostring(es.critical),
						#(es.messages or {}), table.concat(es.warnings or {}, "; "), table.concat(es.infos or {}, "; ")))
					local hits : {string} = {}
					for __, c in ipairs(builder.collisions(res.resultProposalData)) do
						table.insert(hits, ("%s %d%s"):format(c.what, c.entity,
							c.components ~= nil and (" [" .. c.components .. "]") or ""))
					end
					log("refused: collisions " .. table.concat(hits, ", "))
					return true
				end)
				-- PROBE (remove before release): the water level, from any entity with a TERRAIN or WATER_MESH component.
				pcall(function() : boolean
					for __, kind in ipairs({ "TERRAIN", "WATER_MESH" }) do
						local ct = (api.type.ComponentType as {string : Engine.ComponentType})[kind]
						if ct ~= nil then
							api.engine.forEachEntityWithComponent(function(e : integer)
								local comp = api.engine.getComponent(e, ct) as {string : any}
								log(("refused: %s entity %d, waterLevel %s"):format(kind, e, tostring(comp ~= nil and comp.waterLevel)))
							end, ct)
						end
					end
					return true
				end)
				if #messages == 0 then
					messages = { "the game refused it" }
				end
				fail(b, messages, x, y)
				return true
			end
			pcall(function() : boolean
				b.charged = b.charged + math.floor(tonumber(res.resultProposalData.costs) or 0)
				return true
			end)
			onBuilt(res)
			return true
		end)
		if not ok then
			fail(b, { "after building: " .. tostring(err) }, x, y)
		end
	end)
end

-- Stations -------------------------------------------------------------------------------------------------------

local function stepStation(b : Build)
	local check = b.check
	local station = check.plan.stations[b.station]
	local c = station.site.centre
	-- Built before (a build that stopped, then the game restarted): join to it and go on.
	if builder.builtStation(check.plan, b.station, check.net) then
		log(("station %d already built"):format(b.station))
		b.station = b.station + 1
		return
	end
	local proposal, why = builder.stationProposal(check.plan, b.station, check.settings)
	if proposal == nil then
		fail(b, { tostring(why) }, c.x, c.y)
		return
	end
	local ok, cost, messages = builder.dryRun(proposal)
	if not ok then
		fail(b, messages, c.x, c.y)
		return
	end
	log(("station %d (%s): dry run clean, %d"):format(b.station, station.town ~= nil and station.town.name or "?", cost))
	send(b, proposal, c.x, c.y, function()
		if not builder.builtStation(check.plan, b.station, check.net) then
			fail(b, { "the station built can't be found, or its track ends aren't where they were planned" }, c.x, c.y)
			return
		end
		log(("station %d built"):format(b.station))
		b.station = b.station + 1
	end)
end

-- Track ----------------------------------------------------------------------------------------------------------

-- After a chunk is built: the entities of the nodes it added, matched to the network's nodes without one.
local function recordNodes(net : Network, res : WorldBuildProposalCommandData) : integer
	local added : {Pt3} = {}
	for __, n in ipairs(res.proposal.proposal.addedNodes) do
		local p = nodePos(n.entity as integer)
		if p ~= nil then
			table.insert(added, p)
		end
	end
	local matched = 0
	for __, n in ipairs(net.nodes) do
		if n.entity == nil then
			for __, a in ipairs(added) do
				if dist2(n, a) <= NODE_MATCH then
					n.entity = a.entity
					matched = matched + 1
					break
				end
			end
		end
	end
	return matched
end

local function sendChunk(b : Build, net : Network, first : integer, last : integer, x : number, y : number)
	local proposal, why = builder.chunkProposal(net, first, last, b.check.settings)
	if proposal == nil then
		fail(b, { tostring(why) }, x, y)
		return
	end
	local ok, cost, messages, __, data = builder.dryRun(proposal)
	if not ok then
		builder.diagnose(net, first, last, b.check.settings)
		fail(b, messages, x, y)
		return
	end
	local hits : {string} = {}
	for __, c in ipairs(builder.collisions(data)) do
		table.insert(hits, ("%s %d%s"):format(c.what, c.entity, c.components ~= nil and (" [" .. c.components .. "]") or ""))
	end
	if #hits > 0 then
		log(("chunk %d: dry run clean, but lists %s"):format(b.chunk, table.concat(hits, ", ")))
	end
	send(b, proposal, x, y, function(res : WorldBuildProposalCommandData)
		local matched = recordNodes(net, res)
		log(("chunk %d built (%d edges, %d), %d new nodes recorded"):format(b.chunk, last - first + 1, cost, matched))
		b.chunk = b.chunk + 1
		b.crossings = nil
	end)
end

-- A street piece from node0 to node1 along h, typed like the street it replaces (Bus Loops' split).
local function streetPiece(node0 : integer, node1 : integer, h : Hermite, street : Engine.Component.BaseEdge,
		template : Proposal.SegmentAndEntity) : Proposal.SegmentAndEntity
	local seg = api.type.SegmentAndEntity.new()
	seg.type = 0
	seg.comp.node0, seg.comp.node1 = node0, node1
	seg.comp.position0, seg.comp.position1 = v3(h.p0), v3(h.p1)
	seg.comp.tangent0, seg.comp.tangent1 = v3(h.t0), v3(h.t1)
	seg.comp.type = street.type
	seg.comp.typeIndex = street.typeIndex
	seg.comp.laneConfigs = street.laneConfigs
	seg.comp.roadType = street.roadType
	seg.comp.roadTemplate = street.roadTemplate
	seg.comp.roadStyle = street.roadStyle
	seg.streetEdge = template.streetEdge
	seg.playerOwned = template.playerOwned
	return seg
end

local function addCut(cuts : {integer : {Cut}}, edge : integer, s : number, node : Pt3)
	cuts[edge] = cuts[edge] or {}
	table.insert(cuts[edge], { s = s, node = node })
end

-- The closest a level crossing may be to a joint between two pieces of street: the game refused 7 m (P9) and took
-- 9.5 m; the planner keeps 10 m (grid.JOINT_CLEARANCE), and its 100 m cells let 9.8 m through.
local JOINT_MIN = 9.5

-- One crossed street: where the chunk's edges cross it; near an end node, that node is used; elsewhere the street is
-- split (sent; its lanes are then repaired before the next street).
local function stepStreet(b : Build, first : integer, last : integer)
	local cr = b.crossings
	local net = b.check.net
	local entity = cr.streets[cr.next]
	cr.next = cr.next + 1
	local street = api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
	if street == nil then
		return
	end
	local h : Hermite = { p0 = p3(street.position0), p1 = p3(street.position1), t0 = p3(street.tangent0),
		t1 = p3(street.tangent1) }
	local ends = { nodePos(street.node0 as integer), nodePos(street.node1 as integer) }
	local splits : {{integer, number, number}} = {}
	for i = first, last do
		local e = net.edges[i]
		for __, c in ipairs(network.crossings({ p0 = e.p0, p1 = e.p1, t0 = e.t0, t1 = e.t1 }, h)) do
			local snapped = false
			for __, n in ipairs(ends) do
				if not snapped and n ~= nil and dist2(n, c.p) <= NODE_SNAP
						and (cr.nodeTrack[n.entity] == nil or cr.nodeTrack[n.entity] == e.track) then
					cr.nodeTrack[n.entity] = e.track
					addCut(cr.cuts, i, c.s, n)
					cr.count = cr.count + 1
					snapped = true
				end
			end
			if not snapped then
				for __, n in ipairs(ends) do
					if n ~= nil and dist2(n, c.p) < JOINT_MIN then
						fail(b, { ("a level crossing %.1f m from a road joint (the game refuses them closer than about %.1f m)")
							:format(dist2(n, c.p), JOINT_MIN) }, c.p.x, c.p.y)
						return
					end
				end
				table.insert(splits, { i, c.s, c.u })
			end
		end
	end
	if #splits == 0 then
		return
	end
	table.sort(splits, function(x : {integer, number, number}, y : {integer, number, number}) : boolean
		return x[3] < y[3]
	end)
	-- The street in pieces at each split, new nodes -k-1..: the engine's replaceSegment proposal edited (it can't
	-- be dry-run: the Bus Loops way, probe P9).
	local rep = api.engine.util.proposal.replaceSegment(entity)
	local sp = rep.proposal
	local template = sp.addedSegments[1]
	local nodes : {Proposal.NodeAndEntity} = {}
	local pieces : {Proposal.SegmentAndEntity} = {}
	local rest = h
	local restU = 0.0
	local prev = street.node0 as integer
	local k = #splits
	for j, sp_ in ipairs(splits) do
		local here, after = network.splitHermite(rest, (sp_[3] - restU) / (1 - restU))
		local n = api.type.NodeAndEntity.new()
		n.entity = -(k + 1 + j)
		n.comp.position = v3(here.p1)
		table.insert(nodes, n)
		local piece = streetPiece(prev, n.entity, here, street, template)
		piece.entity = -j
		table.insert(pieces, piece)
		prev, rest, restU = n.entity, after, sp_[3]
	end
	local last_ = streetPiece(prev, street.node1 as integer, rest, street, template)
	last_.entity = -(k + 1)
	table.insert(pieces, last_)
	sp.addedNodes = nodes
	sp.addedSegments = pieces
	sp.nodeConfigsToAdd = {}
	local at = network.hermiteAt(h, splits[1][3])
	send(b, rep, at.x, at.y, function(res : WorldBuildProposalCommandData)
		-- The new nodes, matched to the splits by place.
		local made : {Pt3} = {}
		for __, n in ipairs(res.proposal.proposal.addedNodes) do
			local p = nodePos(n.entity as integer)
			if p ~= nil then
				table.insert(made, p)
			end
		end
		for __, sp_ in ipairs(splits) do
			local want = network.hermiteAt(h, sp_[3])
			local best : Pt3 = nil
			for __, p in ipairs(made) do
				if best == nil or dist2(p, want) < dist2(best, want) then
					best = p
				end
			end
			if best == nil or dist2(best, want) > NODE_MATCH then
				fail(b, { "the street split's nodes can't be found" }, want.x, want.y)
				return
			end
			addCut(cr.cuts, sp_[1], sp_[2], best)
			cr.count = cr.count + 1
			-- A piece between two new nodes is at both: send it once.
			for __, sg in ipairs(api.engine.system.streetSystem.getNodeStreetSegments(best.entity)) do
				local seen = false
				for __, r in ipairs(cr.repair) do
					seen = seen or r == sg as integer
				end
				if not seen then
					table.insert(cr.repair, sg as integer)
				end
			end
		end
		log(("street %d split at %d crossings"):format(entity, #splits))
	end)
end

-- Sends one street piece again unedited, so the engine works out its lane connections (Bus Loops).
local function stepRepair(b : Build)
	local cr = b.crossings
	local seg = table.remove(cr.repair, 1)
	local ok, rep = pcall(function() : Proposal
		return api.engine.util.proposal.replaceSegment(seg)
	end)
	if not ok or rep == nil then
		log(("lane repair of street %d: replaceSegment failed: %s"):format(seg, tostring(rep)))
		return
	end
	b.waiting = true
	api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(rep as Proposal, builder.newContext(), false, true),
		function(__ : WorldBuildProposalCommandData, success : boolean)
			b.waiting = false
			log(("lane repair of street %d: %s"):format(seg, tostring(success)))
		end)
end

local function stepChunk(b : Build)
	local check = b.check
	local net = check.net
	local chunk = net.chunks[b.chunk]
	local p = net.edges[chunk.first].p0
	local cr = b.crossings
	if cr == nil and builder.builtChunk(net, b.chunk) then
		log(("chunk %d already built"):format(b.chunk))
		b.chunk = b.chunk + 1
		return
	end
	if cr == nil then
		local proposal, why = builder.chunkProposal(net, chunk.first, chunk.last, check.settings)
		if proposal == nil then
			fail(b, { tostring(why) }, p.x, p.y)
			return
		end
		local ok, __, messages, ___, data = builder.dryRun(proposal)
		if ok then
			sendChunk(b, net, chunk.first, chunk.last, p.x, p.y)
			return
		end
		local collisions = builder.collisions(data)
		local streets : {integer} = {}
		local others = 0
		for __, c in ipairs(collisions) do
			if c.what == "street" then
				table.insert(streets, c.entity)
			elseif c.what ~= "node" then
				others = others + 1
			end
		end
		if not check.settings.levelCrossings or builder.levelCrossings(messages, collisions) == 0 or others > 0 then
			fail(b, messages, p.x, p.y)
			return
		end
		log(("chunk %d crosses %d street pieces on the level"):format(b.chunk, #streets))
		b.crossings = { streets = streets, next = 1, cuts = {}, repair = {}, count = 0, nodeTrack = {} }
		return
	end
	if #cr.repair > 0 then
		stepRepair(b)
	elseif cr.next <= #cr.streets then
		stepStreet(b, chunk.first, chunk.last)
	else
		-- Every street split: the chunk cut at the crossings, joined to their nodes.
		local cutNet = network.cut(net, chunk.first, chunk.last, cr.cuts)
		log(("chunk %d: %d crossings, %d edges after cutting"):format(b.chunk, cr.count, #cutNet.edges))
		-- Each road crossed is two joints, one per track.
		b.levelCrossings = b.levelCrossings + math.floor((cr.count + 1) / 2)
		sendChunk(b, cutNet, 1, #cutNet.edges, p.x, p.y)
	end
end

function build.start(check : PgraceRailRouterBuilder.Check) : Build
	log(("start: %d stations, %d chunks"):format(#check.plan.stations, #check.net.chunks))
	return { check = check, phase = "stations", station = 1, chunk = 1, waiting = false, levelCrossings = 0,
		charged = 0 }
end

function build.step(b : Build) : boolean
	if b.phase == "done" or b.phase == "failed" then
		return true
	end
	if b.waiting then
		return false
	end
	if b.phase == "stations" and b.station > #b.check.plan.stations then
		b.phase = "track"
	end
	if b.phase == "track" and b.chunk > #b.check.net.chunks then
		b.phase = "done"
		log(("done: %d level crossings, charged %d"):format(b.levelCrossings, b.charged))
		return true
	end
	local ok, err = pcall(function() : boolean
		if b.phase == "stations" then
			stepStation(b)
		else
			stepChunk(b)
		end
		return true
	end)
	if not ok then
		fail(b, { tostring(err) }, 0, 0)
	end
	return b.phase == "done" or b.phase == "failed"
end

function build.progress(b : Build) : integer, integer
	local check = b.check
	return (b.station - 1) + (b.chunk - 1), #check.plan.stations + #check.net.chunks
end

function build.retry(b : Build)
	if b.phase ~= "failed" then
		return
	end
	b.phase = b.failure.item.kind == "station" and "stations" or "track"
	b.failure = nil
	b.crossings = nil
	log("retry")
end

return build
