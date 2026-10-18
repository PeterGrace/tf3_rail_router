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

-- A street in pieces at parameters us (ascending), new nodes -k-1..: the engine's replaceSegment proposal edited
-- (it can't be dry-run: the Bus Loops way, probe P9). Its lanes need repairing once sent.
local function splitStreet(entity : integer, street : Engine.Component.BaseEdge, h : Hermite, us : {number}) : Proposal
	local rep = api.engine.util.proposal.replaceSegment(entity)
	local sp = rep.proposal
	local template = sp.addedSegments[1]
	local nodes : {Proposal.NodeAndEntity} = {}
	local pieces : {Proposal.SegmentAndEntity} = {}
	local rest = h
	local restU = 0.0
	local prev = street.node0 as integer
	local k = #us
	for j, u in ipairs(us) do
		local here, after = network.splitHermite(rest, (u - restU) / (1 - restU))
		local n = api.type.NodeAndEntity.new()
		n.entity = -(k + 1 + j)
		n.comp.position = v3(here.p1)
		table.insert(nodes, n)
		local piece = streetPiece(prev, n.entity, here, street, template)
		piece.entity = -j
		table.insert(pieces, piece)
		prev, rest, restU = n.entity, after, u
	end
	local last_ = streetPiece(prev, street.node1 as integer, rest, street, template)
	last_.entity = -(k + 1)
	table.insert(pieces, last_)
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
		-- Only track on the ground crosses on the level (a bridge's deck over the street crosses it in plan too).
		local crossed : {PgraceRailRouterNetwork.Crossing} = {}
		if e.kind == "ground" then
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
	local rep = splitStreet(entity, street, h, us)
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
local function stepRepair(b : Build, repair : {integer})
	local seg = table.remove(repair, 1)
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
		local function onLevel(street : integer) : boolean
			return builder.crossesOnLevel(net, chunk.first, chunk.last, street)
		end
		if not check.settings.levelCrossings or others > 0
				or builder.levelCrossings(messages, collisions, onLevel) == 0 then
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
local ROAD_TRIES = 16
-- A street node this close to the entrance means the road is there already (a build carried on after a restart).
local ROAD_SNAP = 3.0
-- How far behind the building's front a street may be (the cosine of the angle off straight out): one alongside is
-- tried (Mercer Island's nearest dead ends ended beside the station), one behind it isn't.
local ROAD_SQUARE = -0.3
-- A street piece is split for a T no closer than this to its ends (metres; the joint rule for level crossings).
local SPLIT_END = 12.0

-- PROBE (remove before release): a node's lane connections (BASE_NODE_CONFIG), as Bus Loops logged them.
local function laneConnections(node : integer) : string
	local ok, n = pcall(function() : integer
		local c = api.engine.getComponent(node, api.type.ComponentType.BASE_NODE_CONFIG) as {string : any}
		if c == nil then
			return -1
		end
		return #(c.laneConnections as {any})
	end)
	if not ok then
		return "unreadable"
	end
	return n as integer < 0 and "none" or tostring(n)
end

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
local function roadProposal(e : Pt3, out : Pt3, t : PgraceRailRouterBuild.RoadTarget) : SimpleProposal
	local street = api.engine.getComponent(t.piece, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
	local rep = api.engine.util.proposal.replaceSegment(t.piece)
	if street == nil or rep == nil or #rep.proposal.addedSegments == 0 then
		return nil
	end
	local l = dist2(e, t.p)
	local dz = t.p.z - e.z
	local h : Hermite = { p0 = e, p1 = t.p, t0 = { x = out.x * l, y = out.y * l, z = dz },
		t1 = { x = t.arrive.x * l, y = t.arrive.y * l, z = dz } }
	local nodes : {Proposal.NodeAndEntity} = {}
	local n = api.type.NodeAndEntity.new()
	n.entity = -2
	n.comp.position = v3(e)
	table.insert(nodes, n)
	local far = -3
	if t.node ~= nil then
		far = t.node.entity
	else
		local m = api.type.NodeAndEntity.new()
		m.entity = -3
		m.comp.position = v3(t.p)
		table.insert(nodes, m)
	end
	local seg = streetPiece(-2, far, h, street, rep.proposal.addedSegments[1])
	seg.entity = -1
	local proposal = api.type.SimpleProposal.new()
	proposal.streetProposal.nodesToAdd = nodes
	proposal.streetProposal.edgesToAdd = { seg }
	return proposal
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
	local layout = builder.stationLayout(check.plan, b.road, check.settings)
	local e : Pt3 = { x = layout.entrance.x, y = layout.entrance.y, z = station.z }
	local out : Pt3 = { x = layout.outward.x, y = layout.outward.y, z = 0 }
	local function next_(missing ?: string)
		if missing ~= nil then
			table.insert(b.roadsMissing, name)
			log(("road to station %d (%s): none, %s"):format(b.road, name, missing))
		end
		b.roadTarget = nil
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
		local proposal = roadProposal(e, out, t)
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
	local targets = roadTargets(e, out, ROAD_REACH)
	local tried = 0
	for __, target in ipairs(targets) do
		if tried >= ROAD_TRIES then
			break
		end
		local made, proposal = pcall(roadProposal, e, out, target)
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
			log(("road to station %d (%s), %s %s, %.0f m: %s%s"):format(b.road, name, target.kind,
				target.node ~= nil and tostring(target.node.entity) or tostring(target.piece), dist2(e, target.p),
				ok and ("clean, " .. tostring(cost)) or table.concat(messages, "; "),
				#hits > 0 and (" (" .. table.concat(hits, ", ") .. ")") or ""))
			if ok and target.kind ~= "split" then
				sendRoad(target, proposal as SimpleProposal)
				return
			elseif ok then
				-- Split the street first; the road goes to the new node on the next step.
				local h : Hermite = { p0 = p3(street.position0), p1 = p3(street.position1), t0 = p3(street.tangent0),
					t1 = p3(street.tangent1) }
				local rep = splitStreet(target.piece, street, h, { target.u })
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
	next_(#targets == 0 and ("no street within %.0f m"):format(ROAD_REACH)
		or ("%d roads tried, none clean"):format(tried))
end

function build.start(check : PgraceRailRouterBuilder.Check) : Build
	log(("start: %d stations, %d chunks"):format(#check.plan.stations, #check.net.chunks))
	return { check = check, phase = "stations", station = 1, chunk = 1, road = 1, waiting = false, levelCrossings = 0,
		charged = 0, roads = 0, roadsMissing = {}, roadRepair = {} }
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
		b.phase = "roads"
	end
	if b.phase == "roads" and b.road > #b.check.plan.stations and #b.roadRepair == 0 and b.roadJunction == nil
			and b.roadRepaired == nil then
		b.phase = "done"
		log(("done: %d level crossings, roads to %d of %d stations, charged %d"):format(b.levelCrossings, b.roads,
			#b.check.plan.stations, b.charged))
		return true
	end
	local ok, err = pcall(function() : boolean
		if b.phase == "stations" then
			stepStation(b)
		elseif b.phase == "track" then
			stepChunk(b)
		elseif b.roadJunction ~= nil then
			-- Every piece at the junction, the new road among them, sent again unedited for its lanes.
			for __, sg in ipairs(api.engine.system.streetSystem.getNodeStreetSegments(b.roadJunction)) do
				table.insert(b.roadRepair, sg as integer)
				local edge = api.engine.getComponent(sg, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
				if edge ~= nil then
					log(("road junction %d: piece %d, nodes %d (%s lane connections) / %d (%s)"):format(b.roadJunction,
						sg as integer, edge.node0 as integer, laneConnections(edge.node0 as integer), edge.node1 as integer,
						laneConnections(edge.node1 as integer)))
				end
			end
			log(("road junction %d: %d pieces to repair"):format(b.roadJunction, #b.roadRepair))
			b.roadRepaired = b.roadJunction
			b.roadJunction = nil
		elseif #b.roadRepair == 0 and b.roadRepaired ~= nil then
			log(("road junction %d after the repair: %s lane connections"):format(b.roadRepaired,
				laneConnections(b.roadRepaired)))
			for __, sg in ipairs(api.engine.system.streetSystem.getNodeStreetSegments(b.roadRepaired)) do
				local edge = api.engine.getComponent(sg, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
				if edge ~= nil then
					log(("road junction %d after: piece %d, nodes %d (%s) / %d (%s)"):format(b.roadRepaired, sg as integer,
						edge.node0 as integer, laneConnections(edge.node0 as integer), edge.node1 as integer,
						laneConnections(edge.node1 as integer)))
				end
			end
			b.roadRepaired = nil
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
	b.phase = b.failure.item.kind == "station" and "stations" or "track"
	b.failure = nil
	b.crossings = nil
	log("retry")
end

return build
