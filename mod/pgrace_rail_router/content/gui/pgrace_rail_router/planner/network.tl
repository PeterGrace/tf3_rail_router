local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo

local network : PgraceRailRouterNetwork = {}

local type Pt = PgraceRailRouterGeo.Pt
local type Edge = PgraceRailRouterNetwork.Edge
local type Options = PgraceRailRouterNetwork.Options
local type Leg = PgraceRailRouterRoute.Leg
local type Piece = PgraceRailRouterSmooth.Piece

function network.defaults() : Options
	return { offset = 2.5, maxEdge = 250.0, chunkLength = 2000.0, tangent = "circle" }
end

-- The track's height at s metres along the leg (linear between samples), and its grade there (the slope of the
-- sample interval it falls in; at a sample, the mean of the two either side, so edges meeting there agree).
local function heightAt(leg : Leg, s : number) : number, number
	local samples, z = leg.samples, leg.z
	local n = #samples
	if s <= samples[1].s then
		local g = (z[2] - z[1]) / math.max(1e-9, samples[2].s - samples[1].s)
		return z[1], g
	end
	for i = 1, n - 1 do
		local a, b = samples[i].s, samples[i + 1].s
		if s <= b + 1e-9 then
			local g = (z[i + 1] - z[i]) / math.max(1e-9, b - a)
			local h = z[i] + g * (s - a)
			if math.abs(s - b) < 1e-6 and i + 1 < n then
				local g2 = (z[i + 2] - z[i + 1]) / math.max(1e-9, samples[i + 2].s - b)
				return z[i + 1], (g + g2) / 2
			elseif math.abs(s - a) < 1e-6 and i > 1 then
				local g0 = (z[i] - z[i - 1]) / math.max(1e-9, a - samples[i - 1].s)
				return z[i], (g0 + g) / 2
			end
			return h, g
		end
	end
	local g = (z[n] - z[n - 1]) / math.max(1e-9, samples[n].s - samples[n - 1].s)
	return z[n], g
end

-- A point and unit direction on a piece, `d` metres from its start, offset `off` metres to the left.
local function along(piece : Piece, d : number, off : number) : Pt, Pt
	if piece.kind == "arc" then
		local sign = piece.turn >= 0 and 1 or -1
		local start = geo.sub(piece.a, piece.centre)
		local angle = sign * d / piece.radius
		local radial = geo.rotate(start, angle)
		local dir = geo.norm(geo.rotate(radial, sign * math.pi / 2))
		local left : Pt = { x = -dir.y, y = dir.x }
		return geo.add(geo.add(piece.centre, radial), geo.scale(left, off)), dir
	end
	local dir = geo.norm(geo.sub(piece.b, piece.a))
	local left : Pt = { x = -dir.y, y = dir.x }
	return geo.add(geo.add(piece.a, geo.scale(dir, d)), geo.scale(left, off)), dir
end

-- The tangent length for a stretch of `length` metres of centre line on a piece, at offset `off`.
local function tangentLength(piece : Piece, length : number, off : number, rule : string) : number
	if piece.kind ~= "arc" then
		return length
	end
	local sign = piece.turn >= 0 and 1 or -1
	local theta = length / piece.radius
	local r = piece.radius - sign * off
	if rule == "arc" then
		return r * theta
	end
	return 4 * r * math.tan(theta / 4)
end

-- The shortest an edge may be (metres of centre line). The smoother leaves the odd piece shorter than this between
-- two longer ones (0.46 m on the regression maps), and span ends can fall as close to a piece's end; an edge that
-- short is no use to the game.
local MIN_EDGE = 0.5

function network.trackEdges(leg : Leg, legIndex : integer, side : number, options : Options) : {Edge}
	local off = side * options.offset
	local pieces = leg.pieces
	-- Where each piece starts along the leg, and where the leg ends.
	local starts : {number} = {}
	local total = 0.0
	for i, piece in ipairs(pieces) do
		starts[i] = total
		total = total + piece.length
	end
	-- Where edges must break: where one piece meets the next, and the spans' ends.
	local cuts : {number} = {}
	for i = 2, #pieces do
		table.insert(cuts, starts[i])
	end
	for __, span in ipairs(leg.spans) do
		table.insert(cuts, span.s0)
		table.insert(cuts, span.s1)
	end
	table.sort(cuts)
	-- The cuts kept: one within MIN_EDGE of the last kept (or of the leg's end) is dropped. That also drops the second
	-- copy where one span ends and the next starts. A dropped span end moves the span's end to the kept break; a
	-- dropped piece end lets an edge run that far into the next piece, close enough to its own curve.
	local breaks : {number} = { 0.0 }
	for __, c in ipairs(cuts) do
		if c > breaks[#breaks] + MIN_EDGE and c < total - MIN_EDGE then
			table.insert(breaks, c)
		end
	end
	table.insert(breaks, total)
	local function kindAt(s : number) : string
		for __, span in ipairs(leg.spans) do
			if s >= span.s0 - 1e-6 and s < span.s1 - 1e-6 then
				return span.kind
			end
		end
		return "ground"
	end
	local edges : {Edge} = {}
	-- The pieces an edge's start and end lie on; both only move forward, as the edges do.
	local i0, i1 = 1, 1
	for k = 1, #breaks - 1 do
		local a, b = breaks[k], breaks[k + 1]
		-- As many parts as keep edges within maxEdge.
		local parts = math.max(1, math.ceil((b - a) / options.maxEdge - 1e-9))
		for m = 0, parts - 1 do
			local s0, s1 = a + (b - a) * m / parts, a + (b - a) * (m + 1) / parts
			-- The start is on the piece that begins at or before it (the next one where two meet), the end on the
			-- piece that reaches it (the earlier one where two meet).
			while i0 < #pieces and starts[i0 + 1] <= s0 + 1e-6 do
				i0 = i0 + 1
			end
			if i1 < i0 then
				i1 = i0
			end
			while i1 < #pieces and starts[i1] + pieces[i1].length < s1 - 1e-6 do
				i1 = i1 + 1
			end
			local q0, d0 = along(pieces[i0], s0 - starts[i0], off)
			local q1, d1 = along(pieces[i1], s1 - starts[i1], off)
			-- Each piece's share of the edge, at its own rule (an edge only spans two pieces by under MIN_EDGE).
			local tl = 0.0
			for i = i0, i1 do
				local share = math.min(s1, starts[i] + pieces[i].length) - math.max(s0, starts[i])
				if share > 0 then
					tl = tl + tangentLength(pieces[i], share, off, options.tangent)
				end
			end
			local z0, g0 = heightAt(leg, s0)
			local z1, g1 = heightAt(leg, s1)
			table.insert(edges, {
				p0 = { x = q0.x, y = q0.y, z = z0 }, p1 = { x = q1.x, y = q1.y, z = z1 },
				t0 = { x = d0.x * tl, y = d0.y * tl, z = g0 * tl }, t1 = { x = d1.x * tl, y = d1.y * tl, z = g1 * tl },
				kind = kindAt((s0 + s1) / 2), track = side > 0 and 1 or 2, leg = legIndex, s0 = s0, s1 = s1,
			})
		end
	end
	return edges
end

function network.build(plan : PgraceRailRouterRoute.Plan, options : Options) : PgraceRailRouterNetwork.Network
	local net : PgraceRailRouterNetwork.Network = { nodes = {}, edges = {}, chunks = {} }
	for li, leg in ipairs(plan.legs) do
		-- Each track's edges, then grouped by stretch: a chunk takes both tracks' edges between two cut points along
		-- the centre line, so the two tracks of a bridge are in one proposal (one parallel strip, probe P3).
		local tracks : {{Edge}} = { network.trackEdges(leg, li, 1, options), network.trackEdges(leg, li, -1, options) }
		for __, list in ipairs(tracks) do
			local previous : integer = nil
			for __, e in ipairs(list) do
				if previous == nil then
					table.insert(net.nodes, e.p0)
					previous = #net.nodes
				end
				table.insert(net.nodes, e.p1)
				e.node0, e.node1 = previous, #net.nodes
				previous = e.node1
			end
		end
		-- Chunk cut points: after chunkLength of centre line, at the next edge end that isn't inside a bridge or tunnel.
		local left, right = tracks[1], tracks[2]
		local k, startS = 1, 0.0
		while k <= #left do
			local j = k
			while j < #left and (left[j].s1 - startS < options.chunkLength or left[j + 1].kind ~= "ground"
					and left[j].kind ~= "ground") do
				j = j + 1
			end
			local first = #net.edges + 1
			local length = 0.0
			for m = k, j do
				table.insert(net.edges, left[m])
				length = length + (left[m].s1 - left[m].s0)
			end
			-- The right track's edges over the same stretch (the two tracks are cut at the same places).
			for m = k, j do
				table.insert(net.edges, right[m])
				length = length + (right[m].s1 - right[m].s0)
			end
			table.insert(net.chunks, { first = first, last = #net.edges, leg = li, length = length })
			startS = left[j].s1
			k = j + 1
		end
	end
	return net
end

return network
