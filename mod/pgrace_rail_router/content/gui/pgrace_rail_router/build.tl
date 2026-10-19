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
	elseif b.phase == "roads" then
		-- The station whose road was being built (b.road runs one past the last once the roads are done).
		item = { kind = "road", index = math.max(1, math.min(b.road, #b.check.plan.stations)) }
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
	-- An existing station the line joins: nothing to build.
	if station.existing ~= nil then
		log(("station %d (%s): the existing station, nothing to build"):format(b.station,
			station.town ~= nil and station.town.name or "?"))
		b.station = b.station + 1
		return
	end
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
	-- The existing track's nodes the junction's pieces join (the switches and the crossing, entities known): sent
	-- again once built, as P15 did, for their lanes.
	local joined : {integer} = {}
	local seen : {integer : boolean} = {}
	for i = first, last do
		local e = net.edges[i]
		if e.whole then
			for __, k in ipairs({ e.node0, e.node1 }) do
				local n = net.nodes[k]
				if n.entity ~= nil and not seen[n.entity] then
					seen[n.entity] = true
					table.insert(joined, n.entity)
				end
			end
		end
	end
	local junctions = builder.junctionCount(net, first, last)
	send(b, proposal, x, y, function(res : WorldBuildProposalCommandData)
		-- Queued first, so an error below still leaves them repaired; from the next step: in a build's callback a node
		-- may list only some of its pieces (AGENTS.md).
		for __, n in ipairs(joined) do
			table.insert(b.repairNodes, n)
		end
		local matched = recordNodes(net, res)
		log(("chunk %d built (%d edges, %d), %d new nodes recorded"):format(b.chunk, last - first + 1, cost, matched))
		if junctions > 0 then
			b.junctions = b.junctions + junctions
			log(("chunk %d: %d junctions built, %d existing nodes to repair"):format(b.chunk, junctions, #joined))
		end
		b.chunk = b.chunk + 1
		b.crossings = nil
		b.splitting = nil
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

-- A track piece from node0 to node1 along h, typed like the one it replaces: copied from the engine's own replacement
-- of it (probe P15, which split signalled track this way). Its signals are listed on it by the caller.
local function trackPiece(node0 : integer, node1 : integer, h : Hermite, template : Proposal.SegmentAndEntity)
		: Proposal.SegmentAndEntity
	local seg = api.type.SegmentAndEntity.new()
	seg.type = 1
	seg.comp.node0, seg.comp.node1 = node0, node1
	seg.comp.position0, seg.comp.position1 = v3(h.p0), v3(h.p1)
	seg.comp.tangent0, seg.comp.tangent1 = v3(h.t0), v3(h.t1)
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

-- How far a signal's model may stand from its piece's curve (metres in plan) for its place to be trusted.
local OBJECT_OFF = 8.0

-- Where an edge object (a signal) is, in the world: its EDGE_OBJECT's transform, if near the piece's curve h, else its
-- param along h; nil and why if neither can be read.
local function objectPlace(obj : integer, h : Hermite) : Pt3, string
	local ok, p, how = pcall(function() : Pt3, string
		local eo = api.engine.getComponent(obj, api.type.ComponentType.EDGE_OBJECT) as Engine.Component.EdgeObject
		if eo == nil then
			return nil, "it has no EDGE_OBJECT"
		end
		local okT, t = pcall(function() : Vec3f
			return eo.transf:getTransl()
		end)
		if okT and t ~= nil then
			local q = p3(t as Vec3f)
			if dist2(network.hermiteAt(h, network.nearestParam(h, { x = q.x, y = q.y })), q) <= OBJECT_OFF then
				return q, "its place"
			end
		end
		local u = tonumber(eo.param as any)
		if u ~= nil and u >= 0 and u <= 1 then
			return network.hermiteAt(h, u), "its param"
		end
		return nil, "neither its place nor its param can be read"
	end)
	if not ok then
		return nil, tostring(p)
	end
	return p as Pt3, how as string
end

-- An edge (street or track) in pieces at parameters us (ascending), new nodes -(k+2)..: the engine's replaceSegment
-- proposal edited (it can't be dry-run: the Bus Loops way, probe P9; for track, probe P15). A street's pieces are typed
-- like the street (Bus Loops), a track's like the engine's own replacement, with its distance and owner, and each of
-- its signals on the piece that holds it, the signal's own entity listed there (P15: the signal survived, on its
-- side). The new nodes need repairing once sent (their lanes). nil and why where the split would be doubtful.
local function splitEdge(entity : integer, edge : Engine.Component.BaseEdge, h : Hermite, us : {number}) : Proposal,
		string
	local isTrack = edge.roadType == api.type["enum"].RoadType.TRACK
	-- The parts; a track's no shorter than MIN_SPLIT_PIECE (a split can't be dry-run, so nothing doubtful is sent).
	local hs, whyParts = builder.splitParts(h, us, isTrack and builder.MIN_SPLIT_PIECE or nil)
	if hs == nil then
		return nil, ("piece %d: %s"):format(entity, tostring(whyParts))
	end
	local rep = api.engine.util.proposal.replaceSegment(entity)
	if rep == nil or rep.proposal == nil or #rep.proposal.addedSegments == 0 then
		return nil, ("piece %d: the game gave no replacement for it"):format(entity)
	end
	local sp = rep.proposal
	local template = sp.addedSegments[1]
	-- A track's signals: which part holds each (the nearest point on each part's own curve), and its param there.
	local lists : {{any}} = {}
	for __ = 1, #hs do
		table.insert(lists, {})
	end
	local objJ : {integer} = {}
	local objU : {number} = {}
	local edgeObjects : {any} = {}
	if isTrack then
		local objs = template.comp.objects or {}
		edgeObjects = (sp.edgeObjectsToAdd or {}) as {any}
		if #edgeObjects > 0 and #edgeObjects ~= #objs then
			return nil, ("piece %d: %d edge objects to add against %d on it"):format(entity, #edgeObjects, #objs)
		end
		for idx, o in ipairs(objs) do
			local okO, a, b = pcall(function() : any, any
				return (o as {any})[1], (o as {any})[2]
			end)
			if not okO or a == nil or b == nil then
				return nil, ("piece %d: its object %d can't be read"):format(entity, idx)
			end
			local at, how = objectPlace(a as integer, h)
			if at == nil then
				return nil, ("piece %d: where its signal %s is isn't known (%s)"):format(entity, tostring(a), how)
			end
			local bestJ, bestU, bestD = builder.partOf(hs, at)
			log(("piece %d: signal %s (from %s) goes on part %d at %.3f, %.1f m off its curve"):format(entity, tostring(a),
				how, bestJ, bestU, bestD))
			objJ[idx], objU[idx] = bestJ, bestU
			table.insert(lists[bestJ], { a, b })
		end
	end
	local k = #us
	local nodes : {Proposal.NodeAndEntity} = {}
	local pieces : {Proposal.SegmentAndEntity} = {}
	local prev = edge.node0 as integer
	for j = 1, #hs do
		local node1 = edge.node1 as integer
		if j <= k then
			local n = api.type.NodeAndEntity.new()
			n.entity = -(k + 1 + j)
			n.comp.position = v3(hs[j].p1)
			table.insert(nodes, n)
			node1 = n.entity as integer
		end
		local seg : Proposal.SegmentAndEntity
		if isTrack then
			seg = trackPiece(prev, node1, hs[j], template)
			if #lists[j] > 0 then
				(seg.comp as any as {string : any}).objects = lists[j]
			end
		else
			seg = streetPiece(prev, node1, hs[j], edge, template)
		end
		seg.entity = -j
		table.insert(pieces, seg)
		prev = node1
	end
	-- The engine's own object entries (none in P15), pointed at the part that now holds each signal.
	for i, eo in ipairs(edgeObjects) do
		if objJ[i] ~= nil then
			local okW, err = pcall(function() : boolean
				local t = eo as {string : any}
				t.edgeEntity = pieces[objJ[i]].entity
				t.param = objU[i]
				return true
			end)
			if not okW then
				return nil, ("piece %d: its edge object %d couldn't be moved: %s"):format(entity, i, tostring(err))
			end
		end
	end
	if #edgeObjects > 0 then
		sp.edgeObjectsToAdd = edgeObjects as any as {Proposal.EdgeObject}
	end
	sp.addedNodes = nodes
	sp.addedSegments = pieces
	sp.nodeConfigsToAdd = {}
	return rep
end

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
		-- Only track on the ground crosses on the level (a bridge's deck over the street crosses it in plan too), and
		-- never a junction's piece, which mustn't be split (its dry run then shows the street in the way).
		local crossed : {PgraceRailRouterNetwork.Crossing} = {}
		if e.kind == "ground" and not e.whole then
			crossed = network.crossings({ p0 = e.p0, p1 = e.p1, t0 = e.t0, t1 = e.t1 }, h)
		end
		for __, c in ipairs(crossed) do
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
	local us : {number} = {}
	for __, sp_ in ipairs(splits) do
		table.insert(us, sp_[3])
	end
	local rep, why = splitEdge(entity, street, h, us)
	local at = network.hermiteAt(h, splits[1][3])
	if rep == nil then
		fail(b, { "a street couldn't be split: " .. tostring(why) }, at.x, at.y)
		return
	end
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

-- Sends one street or track piece again unedited, so the engine works out its lane connections (Bus Loops; P15 for
-- track: a split's new node then has its BASE_NODE_CONFIG). A piece gone already is skipped.
local function stepRepair(b : Build, repair : {integer})
	local seg = table.remove(repair, 1)
	local ok, rep = pcall(function() : Proposal
		if not api.engine.entityExists(seg) then
			return nil
		end
		return api.engine.util.proposal.replaceSegment(seg)
	end)
	if not ok or rep == nil then
		log(("lane repair of piece %d: skipped (%s)"):format(seg, ok and "gone" or ("replaceSegment failed: " .. tostring(rep))))
		return
	end
	b.waiting = true
	api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(rep as Proposal, builder.newContext(), false, true),
		function(__ : WorldBuildProposalCommandData, success : boolean)
			b.waiting = false
			log(("lane repair of piece %d: %s"):format(seg, tostring(success)))
		end)
end

-- The track pieces at each node queued for repair (b.repairNodes), each piece once, onto b.trackRepair.
local function queueNodeRepairs(b : Build)
	local seen : {integer : boolean} = {}
	for __, sg in ipairs(b.trackRepair) do
		seen[sg] = true
	end
	for __, n in ipairs(b.repairNodes) do
		local ok, segs = pcall(function() : {integer}
			local list : {integer} = {}
			for __, sg in ipairs(api.engine.system.streetSystem.getNodeTrackSegments(n)) do
				table.insert(list, sg as integer)
			end
			return list
		end)
		if ok then
			for __, sg in ipairs(segs as {integer}) do
				if not seen[sg] then
					seen[sg] = true
					table.insert(b.trackRepair, sg)
				end
			end
			log(("node %d: %d track pieces to repair"):format(n, #(segs as {integer})))
		else
			log(("node %d: its track pieces can't be read: %s"):format(n, tostring(segs)))
		end
	end
	b.repairNodes = {}
end

-- One existing piece a junction chunk splits (chunk.splits[b.splitting]), at every cut the chunk has on it, in one
-- proposal: the cut nodes then take the new nodes' entities (matched by place), which are repaired next. A piece gone
-- already (a build retried, or carried on, after splitting it) has its cuts joined to the nodes at their places.
local function stepSplit(b : Build, chunk : PgraceRailRouterNetwork.Chunk)
	local net = b.check.net
	local split = chunk.splits[b.splitting]
	local done, why, joinedNow = builder.splitDone(net, b.chunk, split)
	local cuts = builder.cutNodes(net, b.chunk, split.piece)
	local at = cuts[1] or net.edges[chunk.first].p0
	if why ~= nil then
		fail(b, { why }, at.x, at.y)
		return
	end
	if done then
		-- Repaired again only where joined just now (after a game restart; a retry joined them before).
		for __, n in ipairs(joinedNow) do
			table.insert(b.repairNodes, n)
		end
		log(("chunk %d: piece %d was split before; %d of its %d cuts joined to the nodes there now"):format(b.chunk,
			split.piece, #joinedNow, #cuts))
		b.splitting = b.splitting + 1
		return
	end
	local open : {Pt3} = {}
	for __, n in ipairs(cuts) do
		if n.entity == nil then
			table.insert(open, n)
		end
	end
	if #open == 0 then
		b.splitting = b.splitting + 1
		return
	end
	-- The piece as it is now, and each cut on it: at its planned parameter, or where the piece passes its place.
	local edge = api.engine.getComponent(split.piece, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
	local h : Hermite = { p0 = p3(edge.position0), p1 = p3(edge.position1), t0 = p3(edge.tangent0), t1 = p3(edge.tangent1) }
	local us : {number} = {}
	for __, n in ipairs(open) do
		local u = n.existing.s
		if dist2(network.hermiteAt(h, u), n) > NODE_MATCH then
			u = network.nearestParam(h, { x = n.x, y = n.y })
		end
		local q = network.hermiteAt(h, u)
		if dist2(q, n) > NODE_MATCH or math.abs(q.z - n.z) > 1.5 then
			fail(b, { ("the existing track at (%.0f, %.0f) has moved since the route was found (piece %d passes %.1f m away): find the route again")
				:format(n.x, n.y, split.piece, dist2(q, n)) }, n.x, n.y)
			return
		end
		table.insert(us, u)
	end
	table.sort(us)
	local rep, whyNot = splitEdge(split.piece, edge, h, us)
	if rep == nil then
		fail(b, { "the existing track can't be split for the junction: " .. tostring(whyNot) }, at.x, at.y)
		return
	end
	log(("chunk %d: splitting existing piece %d at %d cuts"):format(b.chunk, split.piece, #us))
	send(b, rep, at.x, at.y, function(res : WorldBuildProposalCommandData)
		-- The new nodes, queued for repair first (whatever follows), then read now and matched to the cuts by place;
		-- the cuts take them only if every one is matched.
		local made : {Pt3} = {}
		for __, nd in ipairs(res.proposal.proposal.addedNodes) do
			table.insert(b.repairNodes, nd.entity as integer)
			local p = nodePos(nd.entity as integer)
			if p ~= nil then
				table.insert(made, p)
			end
		end
		local match : {Pt3 : integer} = {}
		for __, n in ipairs(open) do
			local best : Pt3 = nil
			for __, p in ipairs(made) do
				if best == nil or dist2(p, n) < dist2(best, n) then
					best = p
				end
			end
			if best == nil or dist2(best, n) > NODE_MATCH then
				fail(b, { "the existing track's split nodes can't be found" }, n.x, n.y)
				return
			end
			match[n] = best.entity
		end
		for n, entity in pairs(match) do
			n.entity = entity
		end
		log(("chunk %d: existing piece %d split, %d new nodes"):format(b.chunk, split.piece, #made))
		b.splitting = b.splitting + 1
	end)
end

local function stepChunk(b : Build)
	local check = b.check
	local net = check.net
	local chunk = net.chunks[b.chunk]
	local p = net.edges[chunk.first].p0
	local cr = b.crossings
	if cr == nil and b.splitting == nil then
		if builder.builtChunk(net, b.chunk) then
			-- A junction's nodes on the existing track go again for their lanes (in case the build stopped before;
			-- a second repair is harmless).
			local queued = 0
			for i = chunk.first, chunk.last do
				local e = net.edges[i]
				if e.whole then
					for __, k in ipairs({ e.node0, e.node1 }) do
						local n = net.nodes[k]
						if n.existing ~= nil and n.entity ~= nil then
							table.insert(b.repairNodes, n.entity)
							queued = queued + 1
						end
					end
				end
			end
			log(("chunk %d already built%s"):format(b.chunk, queued > 0 and (", %d junction nodes to repair"):format(queued) or ""))
			b.chunk = b.chunk + 1
			return
		end
		-- A junction's cut on no existing piece: nothing is split, the chunk isn't built.
		if chunk.problem ~= nil then
			fail(b, { chunk.problem }, p.x, p.y)
			return
		end
		-- A junction into existing track: its pieces split first, one a step (each sent, then its new nodes repaired).
		if chunk.splits ~= nil and #chunk.splits > 0 then
			log(("chunk %d: %d existing pieces to split for its junctions"):format(b.chunk, #chunk.splits))
			b.splitting = 1
			return
		end
	end
	if b.splitting ~= nil and b.splitting <= #chunk.splits then
		stepSplit(b, chunk)
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
		local function onLevel(street : integer) : boolean
			return builder.crossesOnLevel(net, chunk.first, chunk.last, street)
		end
		if not check.settings.levelCrossings or others > 0
				or builder.levelCrossings(messages, collisions, onLevel) == 0 then
			-- PROBE (remove before release): what it hit, and which edges the game refuses on their own.
			local hits : {string} = {}
			for __, c in ipairs(collisions) do
				table.insert(hits, ("%s %d at (%.0f %.0f)%s"):format(c.what, c.entity, c.x, c.y,
					c.components ~= nil and (" [" .. c.components .. "]") or ""))
			end
			log(("chunk %d dry run: %s; hit %s"):format(b.chunk, table.concat(messages, "; "), table.concat(hits, ", ")))
			pcall(builder.diagnose, net, chunk.first, chunk.last, check.settings)
			fail(b, messages, p.x, p.y)
			return
		end
		log(("chunk %d crosses %d street pieces on the level"):format(b.chunk, #streets))
		b.crossings = { streets = streets, next = 1, cuts = {}, repair = {}, count = 0, nodeTrack = {} }
		return
	end
	if #cr.repair > 0 then
		stepRepair(b, cr.repair)
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

-- Roads ----------------------------------------------------------------------------------------------------------

-- A road from each station's main building to the town's streets, after the track: the game links the building's
-- sidewalks to a road ending in front of it. Never fails the build: a station left without one is listed instead.
-- The road never meets a street at a kink: a corner joint made the game put a no-entry sign on it (every station,
-- 2026-10-18). It continues a dead end straight on, or meets a street square to it as a T, at a node along it or
-- partway along a piece, which is split there first.
-- How far from the entrance a street may be (metres), and how many ways are dry-run.
local ROAD_REACH = 300.0
local ROAD_TRIES = 48
local ROAD_STEP_TRIES = 8
-- A street node this close to the entrance means the road is there already (a build carried on after a restart).
local ROAD_SNAP = 3.0
-- How far behind the building's front a street may be (the cosine of the angle off straight out): one alongside is
-- tried (Mercer Island's nearest dead ends ended beside the station), one behind it isn't.
local ROAD_SQUARE = -0.3
-- A street piece is split for a T no closer than this to its ends (metres; the joint rule for level crossings).
local SPLIT_END = 12.0

local function unit(x : number, y : number) : number, number
	local l = math.sqrt(x * x + y * y)
	if l < 1e-9 then
		return 0, 0
	end
	return x / l, y / l
end

-- Square to a street running (sx, sy), on the entrance's side of p, pointing at p (the way the road arrives).
local function squareArrival(e : Pt3, p : Pt3, sx : number, sy : number) : Pt3
	local px, py = unit(-sy, sx)
	if px * (e.x - p.x) + py * (e.y - p.y) < 0 then
		px, py = -px, -py
	end
	return { x = -px, y = -py, z = 0 }
end

local function isStreet(e : integer) : Engine.Component.BaseEdge
	if api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE_STREET) == nil then
		return nil
	end
	local edge = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
	if edge == nil or edge.type ~= api.type["enum"].BaseEdgeType.NORMAL then
		return nil
	end
	return edge
end

-- Every way to reach the streets within reach of the entrance, nearest first: dead ends straight on, nodes along a
-- street and points partway along a piece square to it. None behind the station, none at a level crossing.
local function roadTargets(e : Pt3, out : Pt3, reach : number) : {PgraceRailRouterBuild.RoadTarget}
	local streets = api.engine.system.streetSystem
	local targets : {PgraceRailRouterBuild.RoadTarget} = {}
	local seen : {integer : boolean} = {}
	local function inFront(p : Pt3) : boolean
		local cx, cy = unit(p.x - e.x, p.y - e.y)
		return dist2(p, e) <= reach and cx * out.x + cy * out.y >= ROAD_SQUARE
	end
	for __, ent in ipairs(api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(e.x, e.y), reach,
			api.type.ComponentType.BASE_EDGE)) do
		local edge = isStreet(ent as integer)
		if edge ~= nil then
			for __, n in ipairs({ edge.node0 as integer, edge.node1 as integer }) do
				if not seen[n] then
					seen[n] = true
					local q = nodePos(n)
					local pieces = streets.getNodeStreetSegments(n)
					if q ~= nil and inFront(q) and #streets.getNodeTrackSegments(n) == 0 then
						local first = isStreet(pieces[1] as integer)
						if first ~= nil and (#pieces == 1 or #pieces == 2) then
							-- The street's way out of the node along its first piece.
							local ax, ay : number, number
							if first.node0 as integer == n then
								ax, ay = unit(-first.tangent0.x, -first.tangent0.y)
							else
								ax, ay = unit(first.tangent1.x, first.tangent1.y)
							end
							local arrive : Pt3
							if #pieces == 1 then
								arrive = { x = -ax, y = -ay, z = 0 }
							else
								arrive = squareArrival(e, q, ax, ay)
							end
							table.insert(targets, { kind = #pieces == 1 and "dead end" or "node", p = q, arrive = arrive,
								node = q, piece = pieces[1] as integer })
						end
					end
				end
			end
			-- The point of the piece nearest the entrance, if it's well clear of its ends.
			local h : Hermite = { p0 = p3(edge.position0), p1 = p3(edge.position1), t0 = p3(edge.tangent0),
				t1 = p3(edge.tangent1) }
			local u = network.nearestParam(h, { x = e.x, y = e.y })
			local p = network.hermiteAt(h, u)
			if dist2(p, h.p0) >= SPLIT_END and dist2(p, h.p1) >= SPLIT_END and inFront(p)
					and #streets.getNodeTrackSegments(edge.node0) == 0 then
				local before = network.hermiteAt(h, math.max(0, u - 0.01))
				local after = network.hermiteAt(h, math.min(1, u + 0.01))
				table.insert(targets, { kind = "split", p = p, arrive = squareArrival(e, p, after.x - before.x,
					after.y - before.y), piece = ent as integer, u = u })
			end
		end
	end
	table.sort(targets, function(x : PgraceRailRouterBuild.RoadTarget, y : PgraceRailRouterBuild.RoadTarget) : boolean
		return dist2(x.p, e) < dist2(y.p, e)
	end)
	return targets
end

-- Whether a street node is within r of p.
local function streetNodeNear(p : Pt3, r : number) : boolean
	for __, ent in ipairs(api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(p.x, p.y), r + 1,
			api.type.ComponentType.BASE_EDGE)) do
		local edge = isStreet(ent as integer)
		if edge ~= nil then
			for __, n in ipairs({ edge.node0 as integer, edge.node1 as integer }) do
				local q = nodePos(n)
				if q ~= nil and dist2(q, p) <= r then
					return true
				end
			end
		end
	end
	return false
end

-- A road from the entrance (leaving it outward) to the target, arriving along t.arrive, joined to t.node, or ending
-- at a new node at t.p (a split's dry run: it collides with that street only), typed like the target's street.
-- t.start is the way the road leaves the entrance; with t.mid it first curves to a point t.mid before the target,
-- on the line it arrives along, then runs straight into it (a dead end close beside the station can't be reached
-- in one curve: Mercer Island, 24 m away).
local function roadProposal(e : Pt3, t : PgraceRailRouterBuild.RoadTarget) : SimpleProposal
	local street = api.engine.getComponent(t.piece, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
	local rep = api.engine.util.proposal.replaceSegment(t.piece)
	if street == nil or rep == nil or #rep.proposal.addedSegments == 0 then
		return nil
	end
	local template = rep.proposal.addedSegments[1]
	-- Edges -1 (and -2), then the nodes: the entrance, the middle point, a new node at a split's point.
	local pieces = (t.mid or 0) > 0 and 2 or 1
	local nodes : {Proposal.NodeAndEntity} = {}
	local function newNode(p : Pt3) : integer
		local n = api.type.NodeAndEntity.new()
		n.entity = -(pieces + #nodes + 1)
		n.comp.position = v3(p)
		table.insert(nodes, n)
		return n.entity
	end
	local entrance = newNode(e)
	local m : Pt3 = nil
	local mid : integer = nil
	if pieces == 2 then
		m = { x = t.p.x - t.arrive.x * t.mid, y = t.p.y - t.arrive.y * t.mid, z = t.p.z }
		mid = newNode(m)
	end
	local far : integer
	if t.node ~= nil then
		far = t.node.entity
	else
		far = newNode(t.p)
	end
	local function curve(a : Pt3, from : Pt3, b : Pt3, into : Pt3) : Hermite
		local l = dist2(a, b)
		local dz = b.z - a.z
		return { p0 = a, p1 = b, t0 = { x = from.x * l, y = from.y * l, z = dz }, t1 = { x = into.x * l, y = into.y * l, z = dz } }
	end
	local segs : {Proposal.SegmentAndEntity} = {}
	if pieces == 1 then
		local seg = streetPiece(entrance, far, curve(e, t.start, t.p, t.arrive), street, template)
		seg.entity = -1
		table.insert(segs, seg)
	else
		local first = streetPiece(entrance, mid, curve(e, t.start, m, t.arrive), street, template)
		first.entity = -1
		local last_ = streetPiece(mid, far, curve(m, t.arrive, t.p, t.arrive), street, template)
		last_.entity = -2
		table.insert(segs, first)
		table.insert(segs, last_)
	end
	local proposal = api.type.SimpleProposal.new()
	proposal.streetProposal.nodesToAdd = nodes
	proposal.streetProposal.edgesToAdd = segs
	return proposal
end

-- The shapes a road may take, cheapest first. First straight roads: out of the building square, or turned by up to
-- 30°, to the first street they meet, as a T there (a straight road looks like a road; curves forced to leave square
-- and arrive along a street made hairpins: Bangor - Imperial Beach, 2026-10-18). Then curves to every target,
-- leaving square or up to 60° off (the road the player built, which the game linked, came in 15° off), and to a
-- dead end also by way of a point ROAD_MIDS before it, none turning more than ROAD_MAX_TURN in all. Each costs its
-- length plus a metre a degree it turns.
local ROAD_RAYS : {number} = { 0, 15, -15, 30, -30 }
local ROAD_TURNS : {number} = { 0, 30, -30, 60, -60 }
local ROAD_MIDS : {number} = { 20, 40 }
local ROAD_MAX_TURN = 120.0
-- A straight road meets a street at least this far off parallel (degrees).
local ROAD_MIN_ANGLE = 30.0

local function turned(out : Pt3, deg : number) : Pt3
	local a = math.rad(deg)
	return { x = out.x * math.cos(a) - out.y * math.sin(a), y = out.x * math.sin(a) + out.y * math.cos(a), z = 0 }
end

-- How far a curve leaving a along `from` and arriving at b along `into` turns in all (degrees).
local function turning(a : Pt3, from : Pt3, b : Pt3, into : Pt3) : number
	local l = dist2(a, b)
	local h : Hermite = { p0 = a, p1 = b, t0 = { x = from.x * l, y = from.y * l, z = 0 }, t1 = { x = into.x * l, y = into.y * l, z = 0 } }
	-- The angle between successive chords (acos of their unit vectors' dot: the game's Lua has no two-argument atan).
	local total = 0.0
	local last = network.hermiteAt(h, 0)
	local px, py = 0.0, 0.0
	for k = 1, 32 do
		local p = network.hermiteAt(h, k / 32)
		local dx, dy = unit(p.x - last.x, p.y - last.y)
		if k > 1 then
			total = total + math.acos(math.max(-1.0, math.min(1.0, px * dx + py * dy)))
		end
		px, py, last = dx, dy, p
	end
	return math.deg(total)
end

-- Straight roads from the entrance: for each ray, the first street piece it meets, well clear of its ends and not
-- too near parallel to it.
local function rayShapes(e : Pt3, out : Pt3, reach : number) : {PgraceRailRouterBuild.RoadTarget}
	local shapes : {PgraceRailRouterBuild.RoadTarget} = {}
	local pieces = api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(e.x, e.y), reach,
		api.type.ComponentType.BASE_EDGE)
	for __, deg in ipairs(ROAD_RAYS) do
		local dir = turned(out, deg)
		local ray : Hermite = { p0 = e, p1 = { x = e.x + dir.x * reach, y = e.y + dir.y * reach, z = e.z },
			t0 = { x = dir.x * reach, y = dir.y * reach, z = 0 }, t1 = { x = dir.x * reach, y = dir.y * reach, z = 0 } }
		local best : PgraceRailRouterBuild.RoadTarget = nil
		local bestS = math.huge
		for __, ent in ipairs(pieces) do
			local edge = isStreet(ent as integer)
			if edge ~= nil and #api.engine.system.streetSystem.getNodeTrackSegments(edge.node0) == 0 then
				local h : Hermite = { p0 = p3(edge.position0), p1 = p3(edge.position1), t0 = p3(edge.tangent0),
					t1 = p3(edge.tangent1) }
				for __, c in ipairs(network.crossings(ray, h)) do
					if c.s < bestS then
						local before = network.hermiteAt(h, math.max(0, c.u - 0.01))
						local after = network.hermiteAt(h, math.min(1, c.u + 0.01))
						local sx, sy = unit(after.x - before.x, after.y - before.y)
						local sine = math.abs(sx * dir.y - sy * dir.x)
						bestS = c.s
						best = nil
						if dist2(c.p, h.p0) >= SPLIT_END and dist2(c.p, h.p1) >= SPLIT_END
								and sine >= math.sin(math.rad(ROAD_MIN_ANGLE)) then
							best = { kind = "split", p = c.p, arrive = dir, piece = ent as integer, u = c.u, start = dir,
								mid = 0, turn = deg, cost = dist2(e, c.p) + math.abs(deg) }
						end
					end
				end
			end
		end
		if best ~= nil then
			table.insert(shapes, best)
		end
	end
	return shapes
end

local function roadShapes(e : Pt3, out : Pt3, reach : number) : {PgraceRailRouterBuild.RoadTarget}
	local shapes = rayShapes(e, out, reach)
	for __, t in ipairs(roadTargets(e, out, reach)) do
		local mids : {number} = { 0 }
		if t.kind == "dead end" then
			for __, d in ipairs(ROAD_MIDS) do
				table.insert(mids, d)
			end
		end
		for __, deg in ipairs(ROAD_TURNS) do
			local start = turned(out, deg)
			for __, mid in ipairs(mids) do
				local into = t.arrive
				local m = mid > 0 and { x = t.p.x - into.x * mid, y = t.p.y - into.y * mid, z = t.p.z } or t.p
				local turn = turning(e, start, m, into)
				if turn <= ROAD_MAX_TURN then
					table.insert(shapes, { kind = t.kind, p = t.p, arrive = into, node = t.node, piece = t.piece, u = t.u,
						start = start, mid = mid, turn = deg, cost = dist2(e, m) + mid + turn })
				end
			end
		end
	end
	table.sort(shapes, function(x : PgraceRailRouterBuild.RoadTarget, y : PgraceRailRouterBuild.RoadTarget) : boolean
		return x.cost < y.cost
	end)
	return shapes
end

-- A split's dry run is good if all it hit is the street to be split (and its nodes).
local function onlyHits(messages : {string}, data : ProposalData, piece : integer, street : Engine.Component.BaseEdge)
		: boolean
	for __, m in ipairs(messages) do
		if m:lower() ~= "collision" then
			return false
		end
	end
	for __, c in ipairs(builder.collisions(data)) do
		if c.entity ~= piece and c.entity ~= street.node0 as integer and c.entity ~= street.node1 as integer then
			return false
		end
	end
	return true
end

local function stepRoad(b : Build)
	local check = b.check
	local station = check.plan.stations[b.road]
	local name = station.town ~= nil and station.town.name or tostring(b.road)
	-- An existing station has its own roads (or not): none of ours.
	if station.existing ~= nil then
		b.road = b.road + 1
		return
	end
	local layout = builder.stationLayout(check.plan, b.road, check.settings)
	local e : Pt3 = { x = layout.entrance.x, y = layout.entrance.y, z = station.z }
	local out : Pt3 = { x = layout.outward.x, y = layout.outward.y, z = 0 }
	local function next_(missing ?: string)
		if missing ~= nil then
			table.insert(b.roadsMissing, name)
			log(("road to station %d (%s): none, %s"):format(b.road, name, missing))
		end
		b.roadTarget = nil
		b.roadShapes = nil
		b.road = b.road + 1
	end
	local function sendRoad(t : PgraceRailRouterBuild.RoadTarget, proposal : SimpleProposal)
		b.waiting = true
		api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(proposal, builder.newContext(), false, true),
			function(res : WorldBuildProposalCommandData, success : boolean)
				pcall(function() : boolean
					b.waiting = false
					if not success then
						next_("the game refused it")
						return true
					end
					b.charged = b.charged + math.floor(tonumber(res.resultProposalData.costs) or 0)
					b.roads = b.roads + 1
					-- The junction's lanes, from the next step: in the callback the node listed only two of its
					-- three pieces, and the junction was left with a no-entry sign (Antelope).
					b.roadJunction = t.node.entity
					log(("road to station %d (%s) built"):format(b.road, name))
					next_()
					return true
				end)
			end)
	end
	-- A split street: now the road to its new node.
	local t = b.roadTarget
	if t ~= nil then
		local proposal = roadProposal(e, t)
		local ok, __, messages = false, 0, {} as {string}
		if proposal ~= nil then
			ok, __, messages = builder.dryRun(proposal)
		end
		log(("road to station %d (%s) to the split's node %d: %s"):format(b.road, name, t.node.entity,
			ok and "clean" or table.concat(messages, "; ")))
		if ok then
			sendRoad(t, proposal)
		else
			next_("the road to the split street wasn't clean")
		end
		return
	end
	if streetNodeNear(e, ROAD_SNAP) then
		log(("road to station %d (%s) already there"):format(b.road, name))
		b.roads = b.roads + 1
		next_()
		return
	end
	-- The shapes to try, nearest target first, ROAD_STEP_TRIES dry runs a step (a few ms each).
	if b.roadShapes == nil then
		b.roadShapes = roadShapes(e, out, ROAD_REACH)
		b.roadNext = 1
	end
	local tried = 0
	while b.roadNext <= #b.roadShapes and b.roadNext <= ROAD_TRIES and tried < ROAD_STEP_TRIES do
		local target = b.roadShapes[b.roadNext]
		b.roadNext = b.roadNext + 1
		local made, proposal = pcall(roadProposal, e, target)
		if made and proposal ~= nil then
			tried = tried + 1
			local ok, cost, messages, __, data = builder.dryRun(proposal as SimpleProposal)
			local street = api.engine.getComponent(target.piece, api.type.ComponentType.BASE_EDGE) as
				Engine.Component.BaseEdge
			if target.kind == "split" and not ok and street ~= nil then
				ok = onlyHits(messages, data, target.piece, street)
			end
			local hits : {string} = {}
			for __, c in ipairs(builder.collisions(data)) do
				table.insert(hits, ("%s %d"):format(c.what, c.entity))
			end
			log(("road to station %d (%s), %s %s (%.0f°%s), %.0f m: %s%s"):format(b.road, name, target.kind,
				target.node ~= nil and tostring(target.node.entity) or tostring(target.piece), target.turn,
				target.mid > 0 and (", by " .. tostring(target.mid) .. " m before") or "", dist2(e, target.p),
				ok and ("clean, " .. tostring(cost)) or table.concat(messages, "; "),
				#hits > 0 and (" (" .. table.concat(hits, ", ") .. ")") or ""))
			if ok and target.kind ~= "split" then
				sendRoad(target, proposal as SimpleProposal)
				return
			elseif ok then
				-- Split the street first; the road goes to the new node on the next step.
				local h : Hermite = { p0 = p3(street.position0), p1 = p3(street.position1), t0 = p3(street.tangent0),
					t1 = p3(street.tangent1) }
				local rep = splitEdge(target.piece, street, h, { target.u })
				if rep == nil then
					next_("the street couldn't be split")
					return
				end
				b.waiting = true
				api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(rep, builder.newContext(), false, true),
					function(res : WorldBuildProposalCommandData, success : boolean)
						pcall(function() : boolean
							b.waiting = false
							local best : Pt3 = nil
							if success then
								for __, n in ipairs(res.proposal.proposal.addedNodes) do
									local p = nodePos(n.entity as integer)
									if p ~= nil and (best == nil or dist2(p, target.p) < dist2(best, target.p)) then
										best = p
									end
								end
							end
							if best == nil or dist2(best, target.p) > NODE_MATCH then
								next_("the street couldn't be split")
								return true
							end
							log(("road to station %d (%s): street %d split at node %d"):format(b.road, name,
								target.piece, best.entity))
							target.node = best
							target.piece = api.engine.system.streetSystem.getNodeStreetSegments(best.entity)[1] as integer
							b.roadTarget = target
							return true
						end)
					end)
				return
			end
		end
	end
	if b.roadNext <= #b.roadShapes and b.roadNext <= ROAD_TRIES then
		return
	end
	next_(#b.roadShapes == 0 and ("no street within %.0f m"):format(ROAD_REACH)
		or ("%d roads tried, none clean"):format(b.roadNext - 1))
end

function build.ownStations(plan : PgraceRailRouterRoute.Plan) : integer
	local n = 0
	for __, station in ipairs(plan.stations) do
		if station.existing == nil then
			n = n + 1
		end
	end
	return n
end

function build.start(check : PgraceRailRouterBuilder.Check) : Build
	log(("start: %d stations (%d ours), %d chunks"):format(#check.plan.stations, build.ownStations(check.plan),
		#check.net.chunks))
	return { check = check, phase = "stations", station = 1, chunk = 1, road = 1, waiting = false, levelCrossings = 0,
		junctions = 0, charged = 0, roads = 0, roadsMissing = {}, roadRepair = {}, repairNodes = {}, trackRepair = {} }
end

-- Track pieces still to repair (a split's or a junction's nodes): worked off even after a failure.
local function repairsPending(b : Build) : boolean
	return #b.repairNodes > 0 or #b.trackRepair > 0
end

local function stepRepairs(b : Build)
	if #b.repairNodes > 0 then
		queueNodeRepairs(b)
	else
		stepRepair(b, b.trackRepair)
	end
end

function build.busy(b : Build) : boolean
	if b.phase == "done" then
		return false
	end
	return b.phase ~= "failed" or b.waiting or repairsPending(b)
end

function build.step(b : Build) : boolean
	if b.phase == "done" then
		return true
	end
	if b.phase == "failed" then
		if not b.waiting and repairsPending(b) then
			local ok, err = pcall(function() : boolean
				stepRepairs(b)
				return true
			end)
			if not ok then
				log("repair after the failure: " .. tostring(err))
				b.repairNodes, b.trackRepair = {}, {}
			end
		end
		return true
	end
	if b.waiting then
		return false
	end
	if b.phase == "stations" and b.station > #b.check.plan.stations then
		b.phase = "track"
	end
	if b.phase == "track" and b.chunk > #b.check.net.chunks and #b.repairNodes == 0 and #b.trackRepair == 0 then
		b.phase = "roads"
	end
	if b.phase == "roads" and b.road > #b.check.plan.stations and #b.roadRepair == 0 and b.roadJunction == nil then
		b.phase = "done"
		log(("done: %d level crossings, %d junctions, roads to %d of %d stations, charged %d"):format(b.levelCrossings,
			b.junctions, b.roads, build.ownStations(b.check.plan), b.charged))
		return true
	end
	local ok, err = pcall(function() : boolean
		if b.phase == "stations" then
			stepStation(b)
		elseif b.phase == "track" then
			-- Track pieces at new or joined nodes go again for their lanes before anything else is built.
			if repairsPending(b) then
				stepRepairs(b)
			else
				stepChunk(b)
			end
		elseif b.roadJunction ~= nil then
			-- Every piece at the junction, the new road among them, sent again unedited for its lanes.
			for __, sg in ipairs(api.engine.system.streetSystem.getNodeStreetSegments(b.roadJunction)) do
				table.insert(b.roadRepair, sg as integer)
			end
			log(("road junction %d: %d pieces to repair"):format(b.roadJunction, #b.roadRepair))
			b.roadJunction = nil
		elseif #b.roadRepair > 0 then
			stepRepair(b, b.roadRepair)
		else
			stepRoad(b)
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
	return (b.station - 1) + (b.chunk - 1) + (b.road - 1), 2 * #check.plan.stations + #check.net.chunks
end

function build.retry(b : Build)
	if b.phase ~= "failed" then
		return
	end
	local kind = b.failure.item.kind
	b.phase = kind == "station" and "stations" or kind == "road" and "roads" or "track"
	b.failure = nil
	b.crossings = nil
	-- Splits already made are found again (their pieces are gone: builder.splitDone).
	b.splitting = nil
	log("retry")
end

return build
