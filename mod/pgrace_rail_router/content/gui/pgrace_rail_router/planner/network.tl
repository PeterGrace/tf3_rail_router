local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo
local midline = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/midline.tl" as PgraceRailRouterMidline

local network : PgraceRailRouterNetwork = {}

local type Pt = PgraceRailRouterGeo.Pt
local type Edge = PgraceRailRouterNetwork.Edge
local type Options = PgraceRailRouterNetwork.Options
local type Leg = PgraceRailRouterRoute.Leg
local type Piece = PgraceRailRouterSmooth.Piece

local type Hermite = PgraceRailRouterNetwork.Hermite
local type Pt3 = PgraceRailRouterNetwork.Pt3

local function lerp3(a : Pt3, b : Pt3, s : number) : Pt3
	return { x = a.x + (b.x - a.x) * s, y = a.y + (b.y - a.y) * s, z = a.z + (b.z - a.z) * s }
end

function network.hermiteAt(h : Hermite, s : number) : Pt3
	local s2, s3 = s * s, s * s * s
	local h00, h10, h01, h11 = 2 * s3 - 3 * s2 + 1, s3 - 2 * s2 + s, -2 * s3 + 3 * s2, s3 - s2
	return { x = h00 * h.p0.x + h10 * h.t0.x + h01 * h.p1.x + h11 * h.t1.x,
		y = h00 * h.p0.y + h10 * h.t0.y + h01 * h.p1.y + h11 * h.t1.y,
		z = h00 * h.p0.z + h10 * h.t0.z + h01 * h.p1.z + h11 * h.t1.z }
end

function network.splitHermite(h : Hermite, s : number) : Hermite, Hermite
	-- Bézier control points: p0, p0 + t0/3, p1 - t1/3, p1.
	local b0 = h.p0
	local b1 : Pt3 = { x = h.p0.x + h.t0.x / 3, y = h.p0.y + h.t0.y / 3, z = h.p0.z + h.t0.z / 3 }
	local b2 : Pt3 = { x = h.p1.x - h.t1.x / 3, y = h.p1.y - h.t1.y / 3, z = h.p1.z - h.t1.z / 3 }
	local b3 = h.p1
	local c0, c1, c2 = lerp3(b0, b1, s), lerp3(b1, b2, s), lerp3(b2, b3, s)
	local d0, d1 = lerp3(c0, c1, s), lerp3(c1, c2, s)
	local m = lerp3(d0, d1, s)
	local function tangent(a : Pt3, b : Pt3) : Pt3
		return { x = 3 * (b.x - a.x), y = 3 * (b.y - a.y), z = 3 * (b.z - a.z) }
	end
	return { p0 = b0, t0 = tangent(b0, c0), p1 = m, t1 = tangent(d0, m) },
		{ p0 = m, t0 = tangent(m, d1), p1 = b3, t1 = tangent(c2, b3) }
end

function network.nearestParam(h : Hermite, p : Pt) : number
	local function d2(s : number) : number
		local q = network.hermiteAt(h, s)
		return (q.x - p.x) ^ 2 + (q.y - p.y) ^ 2
	end
	local best, bestD = 0.0, d2(0)
	for k = 1, 100 do
		local d = d2(k / 100)
		if d < bestD then
			best, bestD = k / 100, d
		end
	end
	local step = 0.01
	while step > 1e-4 do
		step = step / 2
		for __, s in ipairs({ best - step, best + step }) do
			if s >= 0 and s <= 1 and d2(s) < bestD then
				best, bestD = s, d2(s)
			end
		end
	end
	return best
end

local CROSSING_CHORDS = 64

function network.crossings(track : Hermite, street : Hermite) : {PgraceRailRouterNetwork.Crossing}
	local a, b : {Pt3}, {Pt3} = {}, {}
	for k = 0, CROSSING_CHORDS do
		a[k + 1] = network.hermiteAt(track, k / CROSSING_CHORDS)
		b[k + 1] = network.hermiteAt(street, k / CROSSING_CHORDS)
	end
	local result : {PgraceRailRouterNetwork.Crossing} = {}
	for i = 1, CROSSING_CHORDS do
		local p, r = a[i], a[i + 1]
		local rx, ry = r.x - p.x, r.y - p.y
		for j = 1, CROSSING_CHORDS do
			local q, w = b[j], b[j + 1]
			local sx, sy = w.x - q.x, w.y - q.y
			local den = rx * sy - ry * sx
			if den ~= 0 then
				local qpx, qpy = q.x - p.x, q.y - p.y
				local t = (qpx * sy - qpy * sx) / den
				local v = (qpx * ry - qpy * rx) / den
				-- Half-open on each chord, so a crossing exactly at a shared chord end counts once; the curves' own
				-- ends don't count.
				local tOk = t >= 0 and t < 1 and not (i == 1 and t == 0)
				local vOk = v >= 0 and v < 1 and not (j == 1 and v == 0)
				if tOk and vOk then
					local u = (j - 1 + v) / CROSSING_CHORDS
					table.insert(result, { s = (i - 1 + t) / CROSSING_CHORDS, u = u, p = network.hermiteAt(street, u) })
				end
			end
		end
	end
	table.sort(result, function(x : PgraceRailRouterNetwork.Crossing, y : PgraceRailRouterNetwork.Crossing) : boolean
		return x.s < y.s
	end)
	return result
end

local MAX_CUT_OFFSET = 1.0

function network.cut(net : PgraceRailRouterNetwork.Network, first : integer, last : integer,
		cuts : {integer : {PgraceRailRouterNetwork.Cut}}) : PgraceRailRouterNetwork.Network
	local out : PgraceRailRouterNetwork.Network = { nodes = {}, edges = {}, chunks = {} }
	local index : {Pt3 : integer} = {}
	local function nodeIndex(p : Pt3) : integer
		if index[p] == nil then
			table.insert(out.nodes, p)
			index[p] = #out.nodes
		end
		return index[p]
	end
	-- A piece of e over its parameters s0..s1, with e's signals in that range (the last piece takes one at its end).
	local function piece(e : Edge, h : Hermite, n0 : Pt3, n1 : Pt3, s0 : number, s1 : number)
		local signals : {PgraceRailRouterNetwork.Signal} = nil
		for __, sg in ipairs(e.signals or {}) do
			if sg.param >= s0 and (sg.param < s1 or s1 >= 1) then
				signals = signals or {}
				table.insert(signals, { param = (sg.param - s0) / (s1 - s0), forward = sg.forward })
			end
		end
		table.insert(out.edges, { node0 = nodeIndex(n0), node1 = nodeIndex(n1), p0 = n0, p1 = n1, t0 = h.t0, t1 = h.t1,
			kind = e.kind, track = e.track, leg = e.leg, s0 = e.s0 + (e.s1 - e.s0) * s0,
			s1 = e.s0 + (e.s1 - e.s0) * s1, signals = signals, paired = e.paired, whole = e.whole })
	end
	for i = first, last do
		local e = net.edges[i]
		local n0, n1 = net.nodes[e.node0], net.nodes[e.node1]
		local list : {PgraceRailRouterNetwork.Cut} = {}
		for __, c in ipairs(cuts[i] or {}) do
			table.insert(list, c)
		end
		table.sort(list, function(x : PgraceRailRouterNetwork.Cut, y : PgraceRailRouterNetwork.Cut) : boolean
			return x.s < y.s
		end)
		local rest : Hermite = { p0 = e.p0, p1 = e.p1, t0 = e.t0, t1 = e.t1 }
		local from, fromS = n0, 0.0
		for __, c in ipairs(list) do
			local here, after = network.splitHermite(rest, (c.s - fromS) / (1 - fromS))
			local off = math.sqrt((here.p1.x - c.node.x) ^ 2 + (here.p1.y - c.node.y) ^ 2)
			assert(off <= MAX_CUT_OFFSET, ("a cut's node is %.2f m off the edge"):format(off))
			piece(e, here, from, c.node, fromS, c.s)
			rest = after
			from, fromS = c.node, c.s
		end
		piece(e, rest, from, n1, fromS, 1)
	end
	-- The chunk's splits and problem, where first..last is one of net's chunks.
	local splits : {PgraceRailRouterNetwork.Split} = nil
	local problem : string = nil
	for __, c in ipairs(net.chunks) do
		if c.first == first and c.last == last then
			splits, problem = c.splits, c.problem
		end
	end
	table.insert(out.chunks, { first = 1, last = #out.edges, leg = net.edges[first].leg, length = 0, splits = splits,
		problem = problem })
	return out
end

function network.defaults() : Options
	return { offset = 2.5, maxEdge = 250.0, chunkLength = 1000.0, tangent = "circle", crossovers = true }
end

-- The grade at a node where the profile's grade changes from a to b. Each edge's cubic leaves the node at this grade
-- and bends to its own chord's grade (a or b), overshooting that chord, on the far side from the node's grade, by a
-- third of their difference. The mean of a and b is the smoothest, but where the steepest grade starts after a
-- gentler one (common: the profile holds the grade limit for long stretches) the overshoot breaks the limit. So take
-- the grade nearest the mean whose overshoots on both sides stay within `limit`, or the one that goes over it least
-- where none does (a crest or hollow too sharp for any).
local function nodeGrade(a : number, b : number, limit : number) : number
	local mean = (a + b) / 2
	local best, bestOver, bestOff = mean, math.huge, math.huge
	for k = 0, 20 do
		local m = a + (b - a) * k / 20
		local over = math.max(0, math.abs(m) - limit, math.abs(a + (a - m) / 3) - limit,
			math.abs(b + (b - m) / 3) - limit)
		local off = math.abs(m - mean)
		if over < bestOver - 1e-12 or (over < bestOver + 1e-12 and off < bestOff) then
			best, bestOver, bestOff = m, over, off
		end
	end
	return best
end

-- The track's height at s metres along the leg (linear between samples), and its grade there: the slope of the
-- sample interval it falls in, or at a sample, nodeGrade of the two either side, so edges meeting there agree.
local function heightAt(leg : Leg, s : number, limit : number) : number, number
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
				return z[i + 1], nodeGrade(g, g2, limit)
			elseif math.abs(s - a) < 1e-6 and i > 1 then
				local g0 = (z[i] - z[i - 1]) / math.max(1e-9, a - samples[i - 1].s)
				return z[i], nodeGrade(g0, g, limit)
			end
			return h, g
		end
	end
	local g = (z[n] - z[n - 1]) / math.max(1e-9, samples[n].s - samples[n - 1].s)
	return z[n], g
end

-- The profile's steepest grade between samples (the leg's maxGrade, worked out here so a leg made by hand, as in the
-- tests, needs no summary).
local function steepestGrade(leg : Leg) : number
	local steepest = 0.0
	for i = 1, #leg.samples - 1 do
		local g = (leg.z[i + 1] - leg.z[i]) / math.max(1e-9, leg.samples[i + 1].s - leg.samples[i].s)
		steepest = math.max(steepest, math.abs(g))
	end
	return steepest
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
-- How far an edge's cubic may stray from the profile's height at a sample inside it (metres), and over the profile's
-- steepest grade.
local HEIGHT_TOLERANCE = 0.25
local GRADE_TOLERANCE = 0.001

-- The piece s metres along the leg lies on: with `atEnd`, the one that reaches it (the earlier where two meet), else
-- the one that begins at or before it (the later).
local function pieceAt(starts : {number}, s : number, atEnd : boolean) : integer
	local lo, hi = 1, #starts
	while lo < hi do
		local mid = math.floor((lo + hi + 1) / 2)
		if (atEnd and starts[mid] < s - 1e-6) or (not atEnd and starts[mid] <= s + 1e-6) then
			lo = mid
		else
			hi = mid - 1
		end
	end
	return lo
end

-- The index of the first sample more than 1e-6 m past s (#samples + 1 if none).
local function sampleAfter(samples : {PgraceRailRouterSmooth.Sample}, s : number) : integer
	local lo, hi = 1, #samples + 1
	while lo < hi do
		local mid = math.floor((lo + hi) / 2)
		if samples[mid].s > s + 1e-6 then
			hi = mid
		else
			lo = mid + 1
		end
	end
	return lo
end

-- One track's edge over s0..s1 of the centre line, at offset `off` (without its kind, track, leg or nodes).
local function edgeOver(leg : Leg, starts : {number}, s0 : number, s1 : number, off : number, options : Options,
		limit : number) : Edge
	local pieces = leg.pieces
	local i0, i1 = pieceAt(starts, s0, false), pieceAt(starts, s1, true)
	local q0, d0 = along(pieces[i0], s0 - starts[i0], off)
	local q1, d1 = along(pieces[i1], s1 - starts[i1], off)
	-- Each piece's share of the edge, at its own rule. Where an edge runs over a piece end, its part on one side is
	-- under MIN_EDGE; it may also cover several short pieces.
	local tl = 0.0
	for i = i0, i1 do
		local share = math.min(s1, starts[i] + pieces[i].length) - math.max(s0, starts[i])
		if share > 0 then
			tl = tl + tangentLength(pieces[i], share, off, options.tangent)
		end
	end
	local z0, g0 = heightAt(leg, s0, limit)
	local z1, g1 = heightAt(leg, s1, limit)
	return {
		p0 = { x = q0.x, y = q0.y, z = z0 }, p1 = { x = q1.x, y = q1.y, z = z1 },
		t0 = { x = d0.x * tl, y = d0.y * tl, z = g0 * tl }, t1 = { x = d1.x * tl, y = d1.y * tl, z = g1 * tl },
		s0 = s0, s1 = s1,
	}
end

-- Whether an edge's cubic follows the profile: its height within HEIGHT_TOLERANCE of every sample strictly inside it
-- (the curve's parameter taken as proportional to s, as it nearly is with these tangents), and its grade, at 11
-- points along it, no steeper than `limit` (plus GRADE_TOLERANCE).
local function follows(leg : Leg, e : Edge, limit : number) : boolean
	local samples = leg.samples
	local k = sampleAfter(samples, e.s0)
	while k <= #samples and samples[k].s < e.s1 - 1e-6 do
		local u = (samples[k].s - e.s0) / (e.s1 - e.s0)
		local u2, u3 = u * u, u * u * u
		local z = (2 * u3 - 3 * u2 + 1) * e.p0.z + (u3 - 2 * u2 + u) * e.t0.z + (-2 * u3 + 3 * u2) * e.p1.z
			+ (u3 - u2) * e.t1.z
		if math.abs(z - leg.z[k]) > HEIGHT_TOLERANCE then
			return false
		end
		k = k + 1
	end
	for m = 0, 10 do
		local u = m / 10
		local dh00, dh10, dh01, dh11 = 6 * u * u - 6 * u, 3 * u * u - 4 * u + 1, -6 * u * u + 6 * u, 3 * u * u - 2 * u
		local dx = dh00 * e.p0.x + dh10 * e.t0.x + dh01 * e.p1.x + dh11 * e.t1.x
		local dy = dh00 * e.p0.y + dh10 * e.t0.y + dh01 * e.p1.y + dh11 * e.t1.y
		local dz = dh00 * e.p0.z + dh10 * e.t0.z + dh01 * e.p1.z + dh11 * e.t1.z
		if math.abs(dz) > (limit + GRADE_TOLERANCE) * math.sqrt(dx * dx + dy * dy) then
			return false
		end
	end
	return true
end

-- Where the edges along a leg start and end (metres of centre line, as {s0, s1} pairs in order). They don't depend on
-- the track, so the two tracks' edges pair up index by index.
local function stretches(leg : Leg, starts : {number}, total : number, options : Options, limit : number,
		extra : {number}, keepWhole : {{number}}) : {{number}}
	-- No break strictly inside a keepWhole window (a switch's branch side).
	local function free(c : number) : boolean
		for __, w in ipairs(keepWhole or {}) do
			if c > w[1] + 1e-6 and c < w[2] - 1e-6 then
				return false
			end
		end
		return true
	end
	-- Where edges must break: where one piece meets the next, the spans' ends, and the extra cuts (the crossovers' ends,
	-- the fans' merges, an island end's ease), each with the samples either side of it, so no edge runs from it over a
	-- change of grade at a sample. The extra cuts are fixed: the crossovers and fans look for a node exactly there.
	local cuts : {number} = {}
	local fixed : {number : boolean} = {}
	for __, c in ipairs(extra or {}) do
		table.insert(cuts, c)
		fixed[c] = true
		local before, after : number, number = nil, nil
		for __, sample in ipairs(leg.samples) do
			if sample.s < c and (before == nil or sample.s > before) then
				before = sample.s
			elseif sample.s > c and (after == nil or sample.s < after) then
				after = sample.s
			end
		end
		if before ~= nil then
			table.insert(cuts, before)
		end
		if after ~= nil then
			table.insert(cuts, after)
		end
	end
	for i = 2, #starts do
		table.insert(cuts, starts[i])
	end
	for __, span in ipairs(leg.spans) do
		table.insert(cuts, span.s0)
		table.insert(cuts, span.s1)
	end
	table.sort(cuts)
	-- The cuts kept: one within MIN_EDGE of the last kept (or of the leg's end) is dropped. That also drops the second
	-- copy where one span ends and the next starts. A dropped span end moves the span's end to the kept break; a
	-- dropped piece end lets an edge run that far into the next piece, close enough to its own curve. A fixed cut
	-- takes the place of a kept one that isn't fixed instead: a sample 0.24 m before a fan's merge, kept first, left
	-- the merge with no node, so the fan was never made and the station's outer tracks dead-ended.
	local breaks : {number} = { 0.0 }
	local keptFixed = false
	for __, c in ipairs(cuts) do
		if c < total - MIN_EDGE and free(c) then
			if c > breaks[#breaks] + MIN_EDGE then
				table.insert(breaks, c)
				keptFixed = fixed[c] == true
			elseif fixed[c] and not keptFixed and #breaks > 1 and c > breaks[#breaks - 1] + MIN_EDGE then
				breaks[#breaks] = c
				keptFixed = true
			end
		end
	end
	table.insert(breaks, total)
	local list : {{number}} = {}
	local samples = leg.samples
	-- A stretch whose cubic strays from the profile (on either track: the tangents' lengths differ on curves) is split
	-- at the sample inside it nearest its middle, and each half checked again. One with no sample inside can't follow
	-- the profile better (the profile is straight there), and a cubic through a sharp change of grade at its end
	-- overshoots it however short it is, so it is kept as it is.
	local function refine(s0 : number, s1 : number)
		local fits = follows(leg, edgeOver(leg, starts, s0, s1, options.offset, options, limit), limit)
			and follows(leg, edgeOver(leg, starts, s0, s1, -options.offset, options, limit), limit)
		local split : number = nil
		if not fits then
			local mid = (s0 + s1) / 2
			local k = sampleAfter(samples, s0)
			while k <= #samples and samples[k].s < s1 - 1e-6 do
				local s = samples[k].s
				if s >= s0 + MIN_EDGE and s <= s1 - MIN_EDGE and free(s)
						and (split == nil or math.abs(s - mid) < math.abs(split - mid)) then
					split = s
				end
				k = k + 1
			end
		end
		if split == nil then
			table.insert(list, { s0, s1 })
		else
			refine(s0, split)
			refine(split, s1)
		end
	end
	for k = 1, #breaks - 1 do
		local a, b = breaks[k], breaks[k + 1]
		-- As many parts as keep edges within maxEdge.
		local parts = math.max(1, math.ceil((b - a) / options.maxEdge - 1e-9))
		if parts > 1 then
			for m = 1, parts - 1 do
				if not free(a + (b - a) * m / parts) then
					parts = 1
				end
			end
		end
		for m = 0, parts - 1 do
			refine(a + (b - a) * m / parts, a + (b - a) * (m + 1) / parts)
		end
	end
	return list
end

function network.trackEdges(leg : Leg, legIndex : integer, side : number, options : Options, cuts ?: {number},
		keepWhole ?: {{number}}) : {Edge}
	-- Where each piece starts along the leg, and where the leg ends.
	local starts : {number} = {}
	local total = 0.0
	for i, piece in ipairs(leg.pieces) do
		starts[i] = total
		total = total + piece.length
	end
	local limit = steepestGrade(leg)
	local function kindAt(s : number) : string
		for __, span in ipairs(leg.spans) do
			if s >= span.s0 - 1e-6 and s < span.s1 - 1e-6 then
				return span.kind
			end
		end
		return "ground"
	end
	local edges : {Edge} = {}
	for __, st in ipairs(stretches(leg, starts, total, options, limit, cuts, keepWhole)) do
		local e = edgeOver(leg, starts, st[1], st[2], side * options.offset, options, limit)
		e.kind, e.track, e.leg = kindAt((st[1] + st[2]) / 2), side > 0 and 1 or 2, legIndex
		table.insert(edges, e)
	end
	return edges
end

network.CROSSOVER_LENGTH = 45.0
-- The straight a leg's end needs for its crossovers (a station's approach, route.tl's APPROACH), and how far from
-- the platforms the first starts.
local CROSSOVER_STRAIGHT = 100.0
local CROSSOVER_START = 4.0
-- How far a crossover's end moves to sit on a sample (more than MIN_EDGE, under half the 3 m between the pair's
-- inner ends, so two ends never land on one sample), and the shortest a crossover may then be (its tightest radius
-- 42² / 30 = 59 m, over the game's 55 m).
local CROSSOVER_SNAP = 1.0
local CROSSOVER_MIN = 42.0
-- How much main track beside a switch's branch stays one edge (metres). The check's diagnosis: every switch with 16.6 m
-- or less there was refused ("Construction Not Possible"), 18 m or more passed; the other side's piece could be 3 m.
local SWITCH_CLEAR = 20.0

-- A leg's crossovers as {from track, s on it, to track, s on that}: a pair at each end whose first (last) piece is a
-- straight of CROSSOVER_STRAIGHT on the ground, beyond that end's base (its fan, or a bare island end's S-curves).
local function crossoverPlaces(leg : Leg, total : number, baseStart : number, baseEnd : number, atStart : boolean,
		atEnd : boolean) : {{number}}
	local places : {{number}} = {}
	if #leg.pieces == 0 or total < baseStart + baseEnd + 2 * CROSSOVER_STRAIGHT + 1 then
		return places
	end
	local function groundOver(s0 : number, s1 : number) : boolean
		for __, span in ipairs(leg.spans) do
			if span.kind ~= "ground" and span.s0 < s1 and span.s1 > s0 then
				return false
			end
		end
		return true
	end
	local L, a = network.CROSSOVER_LENGTH, CROSSOVER_START
	local first, last = leg.pieces[1], leg.pieces[#leg.pieces]
	-- A place within CROSSOVER_SNAP of a sample moves onto it: a cut that close to one would be merged away
	-- (MIN_EDGE), leaving an edge over the sample's change of grade.
	local function snap(s : number) : number
		for __, sample in ipairs(leg.samples) do
			if math.abs(sample.s - s) <= CROSSOVER_SNAP then
				return sample.s
			end
		end
		return s
	end
	local function add(fromTrack : number, s0 : number, toTrack : number, s1 : number)
		local a0, a1 = snap(s0), snap(s1)
		if a1 - a0 >= CROSSOVER_MIN then
			table.insert(places, { fromTrack, a0, toTrack, a1 })
		end
	end
	local straight = baseStart + CROSSOVER_STRAIGHT
	if atStart and first.kind == "straight" and first.length >= straight - 1e-6 and groundOver(0, straight) then
		add(1, baseStart + a, 2, baseStart + a + L)
		add(2, straight - a - L + 1, 1, straight - a + 1)
	end
	straight = baseEnd + CROSSOVER_STRAIGHT
	if atEnd and last.kind == "straight" and last.length >= straight - 1e-6 and groundOver(total - straight, total) then
		add(1, total - straight + a - 1, 2, total - straight + a + L - 1)
		add(2, total - baseEnd - a - L, 1, total - baseEnd - a)
	end
	return places
end

-- The node at s along a track's edges, or nil.
local function nodeAtS(list : {Edge}, s : number) : integer
	for __, e in ipairs(list) do
		if math.abs(e.s0 - s) < 1e-6 then
			return e.node0
		elseif math.abs(e.s1 - s) < 1e-6 then
			return e.node1
		end
	end
	return nil
end

-- The edge starting at node n in list, or nil.
local function edgeFrom(list : {Edge}, n : integer) : Edge
	for __, e in ipairs(list) do
		if e.node0 == n then
			return e
		end
	end
	return nil
end

-- Halt 2+2's fans (the Express & Local Rail Stations mod's geometry): the 4 station tracks run straight on for
-- FAN_APRON, then each local track, FAN_SPACING further out than the line's track on its side, merges into it over L
-- (network.fanLength), and the line runs on 30 m more before anything else. Edge.track of a fan piece.
local FAN_APRON = 20.0
local FAN_SPACING = 5.0
local FAN_TRACK = 3
-- Signals: a starter this far from the platforms on each leaving track, and a home signal this far past the fan
-- (or the terminus's crossovers) on each arriving one.
local STARTER = 26.0
local HOME_BEYOND = 15.0

function network.turnoutLength(radius : number) : number
	return math.max(40, 5 * math.floor(math.sqrt(4 * radius * FAN_SPACING) / 5 + 0.5))
end

function network.fanLength(l : number) : number
	return FAN_APRON + l + 30
end

local function addSignal(e : Edge, param : number, forward : boolean)
	e.signals = e.signals or {}
	table.insert(e.signals, { param = math.max(0.02, math.min(0.98, param)), forward = forward })
end

-- How far a signal stays from its edge's ends (metres): track joined later at a node beside a signal collided with it
-- (Bangor - Imperial Beach: a block signal 3 m before the end of a chunk; "Collision" with the next chunk's edge).
local SIGNAL_CLEAR = 15.0

-- A signal at s along a track's edges, moved at least SIGNAL_CLEAR from its edge's ends: within the edge if it's long
-- enough, else onto the nearest edge that is.
local function signalAt(list : {Edge}, s : number, forward : boolean)
	local best : Edge = nil
	local bestS = 0.0
	for __, e in ipairs(list) do
		if e.s1 - e.s0 >= 2 * SIGNAL_CLEAR then
			local at = math.max(e.s0 + SIGNAL_CLEAR, math.min(e.s1 - SIGNAL_CLEAR, s))
			if best == nil or math.abs(at - s) < math.abs(bestS - s) then
				best, bestS = e, at
			end
		end
	end
	if best ~= nil then
		addSignal(best, (bestS - best.s0) / (best.s1 - best.s0), forward)
	end
end

-- Junctions into an existing station's track (milestone 4b): the leg's first signals, one-way, this far out from the
-- junction's approach start on each of our tracks; and how close to an existing piece's end a cut uses the piece's
-- own node instead of splitting it (MIN_EDGE: a sliver of track is no use to the game).
local JUNCTION_SIGNAL = 15.0
local JUNCTION_TRACK = 4

-- A leg's junction at an existing station, on the station's leaving side (forward = true: the leg starts there) or
-- its arriving side: the end's stretch, its junction and our line's side; nil where the station is ours.
local function junctionOf(station : PgraceRailRouterRoute.Station, forward : boolean)
		: PgraceRailRouterExisting.End, PgraceRailRouterJunction.Layout, number
	if station == nil or station.existing == nil or station.endOf == nil then
		return nil, nil, nil
	end
	local k = station.endOf[forward]
	if k == nil or station.ends[k] == nil or station.junctions[k] == nil then
		return nil, nil, nil
	end
	return station.ends[k], station.junctions[k], station.sides[k] or 1
end

-- A junction's edges (track 4) at the leg's start (atStart) or end, into net.nodes: each junction piece taken from the
-- stretch's frame (e.frame) to the world, one edge never split (`whole`), then a straight on
-- our track from each piece's outer end to the leg's track end beside it (`ends`: the two tracks' end nodes). Where
-- our two tracks run side by side (from the outermost piece end on), the straights are a parallel pair (`paired`), so
-- the far track's straight is cut there. At the leg's start they run outward, at its end inward (pieces reversed:
-- ends swapped, tangents negated), along the leg; s is metres along the leg, before 0 or past `total`. The cuts become
-- nodes on the existing pieces (`existing` set; the crossing's shared by both crossing pieces), and the pieces to
-- split are returned, by piece, parameters ascending; and why the junction can't be built, if a cut lies on no piece.
local function junctionEdges(net : PgraceRailRouterNetwork.Network, e : PgraceRailRouterExisting.End,
		j : PgraceRailRouterJunction.Layout, side : number, ends : {integer}, atStart : boolean, total : number,
		li : integer)
		: {Edge}, {PgraceRailRouterNetwork.Split}, string
	local f = e.frame
	local function world(x : number, y : number) : Pt3
		return midline.world(f, x, y)
	end
	-- A frame vector (tx along, ty across) at frame x, in the world.
	local function vec(x : number, tx : number, ty : number) : Pt3
		return midline.vector(f, x, tx, ty)
	end
	local function frameY(p : Pt3) : number
		local __, y = midline.project(f, { x = p.x, y = p.y })
		return y
	end
	local function frameX(p : Pt3) : number
		local x = midline.project(f, { x = p.x, y = p.y })
		return x
	end
	-- The piece on `track` whose x range holds x, and its parameter where its curve is at x along the frame (bisected,
	-- so the node sits exactly there, whichever way the piece was laid).
	local function pieceAt(track : string, x : number) : PgraceRailRouterExisting.Piece, number
		for __, p in ipairs(e.pieces[track] or {}) do
			local xa, xb = frameX(p.p0), frameX(p.p1)
			if math.abs(xb - xa) > 1e-9 and x >= math.min(xa, xb) - 1e-6 and x <= math.max(xa, xb) + 1e-6 then
				local h : Hermite = { p0 = p.p0, p1 = p.p1, t0 = p.t0, t1 = p.t1 }
				local lo, hi = 0.0, 1.0
				local rising = xb > xa
				for __ = 1, 60 do
					local mid = (lo + hi) / 2
					if (frameX(network.hermiteAt(h, mid)) < x) == rising then
						lo = mid
					else
						hi = mid
					end
				end
				return p, (lo + hi) / 2
			end
		end
		return nil, 0
	end
	local splits : {PgraceRailRouterNetwork.Split} = {}
	local problem : string = nil
	local function addSplit(piece : integer, s : number)
		for __, sp in ipairs(splits) do
			if sp.piece == piece then
				table.insert(sp.s, s)
				table.sort(sp.s)
				return
			end
		end
		table.insert(splits, { piece = piece, s = { s } })
	end
	local function newNode(p : Pt3) : integer
		table.insert(net.nodes, p)
		return #net.nodes
	end
	-- Each cut's node (a piece's end at x on the existing track: near on our side, y × side > 0), made once: on the
	-- existing piece, or as a last resort (junction.fit puts cuts on nodes or keeps them 3 m away) the piece's own node
	-- where the cut is within MIN_EDGE of its end. Where no piece holds the cut, a plain node where the frame puts it,
	-- and the problem is reported.
	local cutNodes : {integer : integer} = {}
	local function cutNode(x : number, y : number) : integer
		for ci, c in ipairs(j.cuts) do
			if math.abs(c.x - x) < 1e-6 and math.abs(y) < 5 and (c.track == "near") == (y * side > 0) then
				if cutNodes[ci] == nil then
					local piece, s = pieceAt(c.track, x)
					if piece == nil then
						cutNodes[ci] = newNode(world(x, y))
						problem = problem or ("the junction's %s on the existing %s track, %.0f m along its stretch, is on no piece of it")
							:format(c.kind, c.track, x)
					else
						local h : Hermite = { p0 = piece.p0, p1 = piece.p1, t0 = piece.t0, t1 = piece.t1 }
						local at = network.hermiteAt(h, s)
						local len = math.sqrt((piece.p1.x - piece.p0.x) ^ 2 + (piece.p1.y - piece.p0.y) ^ 2)
						if s * len < MIN_EDGE then
							cutNodes[ci] = newNode({ x = piece.p0.x, y = piece.p0.y, z = piece.p0.z, entity = piece.node0 })
						elseif (1 - s) * len < MIN_EDGE then
							cutNodes[ci] = newNode({ x = piece.p1.x, y = piece.p1.y, z = piece.p1.z, entity = piece.node1 })
						else
							cutNodes[ci] = newNode({ x = at.x, y = at.y, z = at.z, existing = { piece = piece.entity, s = s } })
							addSplit(piece.entity, s)
						end
					end
				end
				return cutNodes[ci]
			end
		end
		return nil
	end
	local edges : {Edge} = {}
	-- An edge from node a (frame x0) to node b (x1), with frame tangents; reversed at the leg's end.
	local function add(a : integer, b : integer, x0 : number, x1 : number, t0 : Pt3, t1 : Pt3) : Edge
		local pa, pb = net.nodes[a], net.nodes[b]
		local e0 : Edge = { node0 = a, node1 = b, p0 = { x = pa.x, y = pa.y, z = pa.z }, p1 = { x = pb.x, y = pb.y, z = pb.z },
			t0 = t0, t1 = t1, s0 = x0 - j.approachX, s1 = x1 - j.approachX }
		if not atStart then
			local function neg(v : Pt3) : Pt3
				return { x = -v.x, y = -v.y, z = -v.z }
			end
			e0 = { node0 = b, node1 = a, p0 = e0.p1, p1 = e0.p0, t0 = neg(t1), t1 = neg(t0),
				s0 = total + j.approachX - x1, s1 = total + j.approachX - x0 }
		end
		e0.kind, e0.track, e0.leg = "ground", JUNCTION_TRACK, li
		table.insert(edges, e0)
		return e0
	end
	-- Our track's end node nearest the frame's y (the leg's two tracks: 7.5 and 12.5 off the axis on our side).
	local function legNode(y : number) : integer
		local best : integer = nil
		for __, n in ipairs(ends) do
			if best == nil or math.abs(frameY(net.nodes[n]) - y) < math.abs(frameY(net.nodes[best]) - y) then
				best = n
			end
		end
		return best
	end
	-- Where our two tracks start running side by side: the outermost piece end on our track.
	local pairX = -math.huge
	for __, pc in ipairs(j.pieces) do
		pairX = math.max(pairX, pc.x1)
	end
	-- The pieces from the station outward: each end on existing track is a cut's node (every piece starts on it), the
	-- outer end on our track a new node, from which a straight runs on to the leg's end (in two, the outer one paired,
	-- where it starts short of pairX).
	for __, pc in ipairs(j.pieces) do
		local a = cutNode(pc.x0, pc.y0) or newNode(world(pc.x0, pc.y0))
		local b = cutNode(pc.x1, pc.y1)
		if b == nil then
			b = newNode(world(pc.x1, pc.y1))
			local n = legNode(pc.y1)
			if n ~= nil then
				local from, x = b, pc.x1
				if pairX - x > MIN_EDGE then
					local mid = newNode(world(pairX, pc.y1))
					add(from, mid, x, pairX, vec(x, pairX - x, 0), vec(pairX, pairX - x, 0))
					from, x = mid, pairX
				end
				local d = j.approachX - x
				add(from, n, x, j.approachX, vec(x, d, 0), vec(j.approachX, d, 0)).paired = true
			end
		end
		add(a, b, pc.x0, pc.x1, vec(pc.x0, pc.tx0, pc.ty0), vec(pc.x1, pc.tx1, pc.ty1)).whole = true
	end
	return edges, splits, problem
end

-- Bare ends (an existing station's free track ends, milestone 4b): how far each of our tracks takes to ease from an
-- island platform's track (5 m off the midline) to its own place (2.5 m off), as one S-curve edge tangent to the axis
-- at both ends. A cubic like that, ISLAND_EASE long over a 2.5 m shift, bends tightest at its ends, at radius
-- ISLAND_EASE² / (6 × 2.5): 327 m at 70 m, over standard track's 300 m turnouts and far over the game's 55 m. One
-- edge, so no switch inside it: the crossovers start CROSSOVER_START beyond it.
local ISLAND_EASE = 70.0
-- A bare fan end's turnout length where the window's style has no fan (options.fan nil) and the options give none
-- (bareFan): simple track's. And the shortest turnout a bare fan may be shortened to (see fanAt).
local BARE_FAN_DEFAULT = 55.0
local MIN_TURNOUT = 40.0

function network.bareApproach(fan : number) : {string : number}
	return { direct = CROSSOVER_STRAIGHT, island = ISLAND_EASE + CROSSOVER_STRAIGHT,
		fan = network.fanLength(fan or BARE_FAN_DEFAULT) + CROSSOVER_STRAIGHT }
end

-- The bare end a leg leaving an existing station (forward = true), or arriving at it, uses; nil at a station of ours
-- or a junction end.
local function bareOf(station : PgraceRailRouterRoute.Station, forward : boolean) : PgraceRailRouterExisting.Bare
	if station == nil or station.existing == nil or station.endOf == nil or station.bare == nil then
		return nil
	end
	local k = station.endOf[forward]
	if k == nil then
		return nil
	end
	return station.bare[k]
end

-- A point's offset across a bare end's axis (to the left looking outward) from its nodes' midpoint.
local function across(b : PgraceRailRouterExisting.Bare, p : Pt3) : number
	return (p.y - b.mid.y) * b.out.x - (p.x - b.mid.x) * b.out.y
end

-- The bare end's node whose offset across the axis is nearest `v`, the offset of a place one of our tracks ends at:
-- the station track on that side, nearest it. A copy, with its entity; and the direction its own piece leaves it
-- outward (Bare.dirs, else the end's axis, b.out), which our track joining it must follow: track joined to existing
-- track 1.8° off its direction was refused.
local function bareNode(b : PgraceRailRouterExisting.Bare, v : number) : Pt3, Pt
	local best : Pt3 = nil
	local dir : Pt = nil
	for i, n in ipairs(b.nodes) do
		if best == nil or math.abs(across(b, n) - v) < math.abs(across(b, best) - v) then
			best, dir = n, b.dirs ~= nil and b.dirs[i] or nil
		end
	end
	return { x = best.x, y = best.y, z = best.z, entity = best.entity }, dir or b.out
end

-- A tangent turned to lie along `dir` (a unit vector in plan), keeping its length in plan and its rise.
local function alongDir(t : Pt3, dir : Pt) : Pt3
	local d = math.sqrt(t.x ^ 2 + t.y ^ 2)
	return { x = dir.x * d, y = dir.y * d, z = t.z }
end

-- The turnout length of the fan at a leg's end (nil: none). At a station of ours, Halt 2+2's (options.fan). At a bare
-- end with 4 tracks, whatever the style: options.fan, else options.bareFan, else BARE_FAN_DEFAULT, shortened in 5 m
-- steps to keep the merge on the leg's straight there (`piece`, its first or last: the planner gives a bare end
-- the straight network.bareApproach asks for, where the window passes it as Input.bareApproach), and none where not
-- even MIN_TURNOUT fits (the station's outer tracks are then left unjoined). None at any other bare end.
local function fanAt(b : PgraceRailRouterExisting.Bare, piece : Piece, options : Options) : number
	if b == nil then
		return options.fan
	elseif b.kind ~= "fan" then
		return nil
	end
	local l = options.fan or options.bareFan or BARE_FAN_DEFAULT
	local room = (piece ~= nil and piece.kind == "straight") and piece.length - FAN_APRON or 0.0
	if l > room + 1e-6 then
		l = 5 * math.floor(room / 5 + 1e-9)
	end
	if l < MIN_TURNOUT then
		return nil
	end
	return l
end

function network.build(plan : PgraceRailRouterRoute.Plan, options : Options) : PgraceRailRouterNetwork.Network
	local net : PgraceRailRouterNetwork.Network = { nodes = {}, edges = {}, chunks = {} }
	for li, leg in ipairs(plan.legs) do
		-- A linked leg (Leg.linked) runs on existing track: nothing to build, so no edges and no chunk.
		if not leg.linked then
			local total = 0.0
			for __, piece in ipairs(leg.pieces) do
				total = total + piece.length
			end
			-- An existing station at either end (milestone 4b): a junction there instead of a fan and crossovers.
			local stations = plan.stations or {}
			local eStart, jStart, sideStart = junctionOf(stations[li], true)
			local eEnd, jEnd, sideEnd = junctionOf(stations[li + 1], false)
			-- A station end (ours, or an existing station's bare end) rather than a junction.
			local ownStart, ownEnd = jStart == nil, jEnd == nil
			-- An existing station's bare end, met as a station of ours: our tracks end on its own nodes ("direct", a fan's
			-- inner two), or ease out to them ("island"), and a fan's outer two merge into ours.
			local bStart, bEnd = bareOf(stations[li], true), bareOf(stations[li + 1], false)
			-- Halt 2+2 (options.fan set): a fan at each end, then the crossovers, so a train can turn back at any station:
			-- reversing in the platform, it leaves on the track it came in on and crosses over before any signal faces it
			-- the wrong way (with crossovers at the line's ends only, a line turning back at Mercer Island had no path).
			local halt = options.fan ~= nil
			local fanZone = halt and network.fanLength(options.fan) or 0
			-- Each end's fan (its turnout length, nil for none), and where the crossovers start from: past the fan, past a
			-- bare island end's S-curves, at a bare end's nodes otherwise (as fanZone at a station of ours, or a junction).
			local fanStart : number = ownStart and fanAt(bStart, leg.pieces[1], options) or nil
			local fanEnd : number = ownEnd and fanAt(bEnd, leg.pieces[#leg.pieces], options) or nil
			local function baseOf(b : PgraceRailRouterExisting.Bare, fan : number) : number
				if b == nil then
					return fanZone
				elseif fan ~= nil then
					return network.fanLength(fan)
				elseif b.kind == "island" then
					return ISLAND_EASE
				end
				return 0
			end
			local baseStart, baseEnd = baseOf(bStart, fanStart), baseOf(bEnd, fanEnd)
			local places : {{number}} = {}
			if options.crossovers then
				places = crossoverPlaces(leg, total, baseStart, baseEnd, ownStart, ownEnd)
			end
			local cuts : {number} = {}
			-- Each track's switch windows: the main track beside a switch's branch, kept in one edge (SWITCH_CLEAR).
			local keep : {{{number}}} = { {}, {} }
			for __, p in ipairs(places) do
				table.insert(cuts, p[2])
				table.insert(cuts, p[4])
				table.insert(keep[p[1] as integer], { p[2], p[2] + SWITCH_CLEAR })
				table.insert(keep[p[3] as integer], { p[4] - SWITCH_CLEAR, p[4] })
			end
			-- A fan's merge: the local track joins the line's track on its side 20 + L from the platforms, the line's
			-- track kept in one edge from the platforms to there (the main edge beside the branch). 0: no fan at that end.
			local mergeStart, mergeEnd = 0.0, 0.0
			if fanStart ~= nil and total > 2 * (network.fanLength(fanStart) + 1) then
				mergeStart = FAN_APRON + fanStart
				table.insert(cuts, mergeStart)
			end
			if fanEnd ~= nil and total > 2 * (network.fanLength(fanEnd) + 1) then
				mergeEnd = FAN_APRON + fanEnd
				table.insert(cuts, total - mergeEnd)
			end
			for k = 1, 2 do
				if mergeStart > 0 then
					table.insert(keep[k], { 0, mergeStart })
				end
				if mergeEnd > 0 then
					table.insert(keep[k], { total - mergeEnd, total })
				end
			end
			-- A bare island end: our tracks start ISLAND_EASE out from its nodes, an S-curve before each (below).
			local islandStart = bStart ~= nil and bStart.kind == "island" and total > 2 * (ISLAND_EASE + 1)
			local islandEnd = bEnd ~= nil and bEnd.kind == "island" and total > 2 * (ISLAND_EASE + 1)
			if islandStart then
				table.insert(cuts, ISLAND_EASE)
			end
			if islandEnd then
				table.insert(cuts, total - ISLAND_EASE)
			end
			-- Each track's edges, then grouped by stretch: a chunk takes both tracks' edges between two cut points along
			-- the centre line, so the two tracks of a bridge are in one proposal (one parallel strip, probe P3).
			local tracks : {{Edge}} = { network.trackEdges(leg, li, 1, options, cuts, keep[1]),
				network.trackEdges(leg, li, -1, options, cuts, keep[2]) }
			-- At an island end, the edges before the cut are dropped (the S-curves take their place), their grade at the
			-- station kept for the S-curves.
			local gradeStart, gradeEnd : {number}, {number} = {}, {}
			for k, list in ipairs(tracks) do
				if #list > 0 then
					gradeStart[k] = list[1].t0.z / math.sqrt(list[1].t0.x ^ 2 + list[1].t0.y ^ 2)
					gradeEnd[k] = list[#list].t1.z / math.sqrt(list[#list].t1.x ^ 2 + list[#list].t1.y ^ 2)
				end
				while islandStart and #list > 1 and list[1].s1 < ISLAND_EASE + MIN_EDGE do
					table.remove(list, 1)
				end
				while islandEnd and #list > 1 and list[#list].s0 > total - ISLAND_EASE - MIN_EDGE do
					table.remove(list)
				end
			end
			for __, list in ipairs(tracks) do
				local previous : integer = nil
				for __, e in ipairs(list) do
					-- Nodes are copies, so a later change to an edge's end point (or to a node) doesn't move the other.
					if previous == nil then
						table.insert(net.nodes, { x = e.p0.x, y = e.p0.y, z = e.p0.z })
						previous = #net.nodes
					end
					table.insert(net.nodes, { x = e.p1.x, y = e.p1.y, z = e.p1.z })
					e.node0, e.node1 = previous, #net.nodes
					previous = e.node1
				end
			end
			-- A bare end with tracks 5 m apart ("direct", or a fan's inner two): our tracks' end nodes are the station's
			-- own, each the station track on its side (its entity, exactly where it is), and our first (last) edge leaves
			-- (reaches) it along the station's axis, as at a station of ours.
			local function snap(b : PgraceRailRouterExisting.Bare, atStart : boolean)
				for __, list in ipairs(tracks) do
					if #list > 0 then
						local e = atStart and list[1] or list[#list]
						local n = atStart and e.node0 or e.node1
						local node, dir = bareNode(b, across(b, net.nodes[n]))
						net.nodes[n] = node
						if atStart then
							e.p0, e.t0 = { x = node.x, y = node.y, z = node.z }, alongDir(e.t0, dir)
						else
							e.p1, e.t1 = { x = node.x, y = node.y, z = node.z }, alongDir(e.t1, { x = -dir.x, y = -dir.y })
						end
					end
				end
			end
			if bStart ~= nil and bStart.kind ~= "island" then
				snap(bStart, true)
			end
			if bEnd ~= nil and bEnd.kind ~= "island" then
				snap(bEnd, false)
			end
			-- A bare island end's S-curves (track 3, as a fan's pieces): one edge per track from the station's track on its
			-- side (its node, 5 m off the midline) to our track's first node (last, at the leg's end), ISLAND_EASE along the
			-- axis, tangent to it at both ends, at the profile's grade there. By end (true: the leg's start) and track.
			local eases : {boolean : {Edge}} = { [true] = {}, [false] = {} }
			local function ease(b : PgraceRailRouterExisting.Bare, atStart : boolean)
				for k, list in ipairs(tracks) do
					if #list > 0 then
						local e = atStart and list[1] or list[#list]
						local n = atStart and e.node0 or e.node1
						local inner = net.nodes[n]
						local node, dir = bareNode(b, across(b, inner))
						table.insert(net.nodes, node)
						local station = #net.nodes
						local l = atStart and e.s0 or total - e.s1
						local t = atStart and e.t0 or e.t1
						local d = math.sqrt(t.x ^ 2 + t.y ^ 2)
						local tTrack : Pt3 = { x = t.x / d * l, y = t.y / d * l, z = t.z / d * l }
						local way : Pt = atStart and dir or { x = -dir.x, y = -dir.y }
						local g = atStart and gradeStart[k] or gradeEnd[k]
						local tStation : Pt3 = { x = way.x * l, y = way.y * l, z = g * l }
						local x : Edge
						if atStart then
							x = { node0 = station, node1 = n, p0 = { x = node.x, y = node.y, z = node.z },
								p1 = { x = inner.x, y = inner.y, z = inner.z }, t0 = tStation, t1 = tTrack, s0 = 0, s1 = l }
						else
							x = { node0 = n, node1 = station, p0 = { x = inner.x, y = inner.y, z = inner.z },
								p1 = { x = node.x, y = node.y, z = node.z }, t0 = tTrack, t1 = tStation, s0 = total - l, s1 = total }
						end
						x.kind, x.track, x.leg = "ground", FAN_TRACK, li
						eases[atStart][k] = x
					end
				end
			end
			if islandStart then
				ease(bStart, true)
			end
			if islandEnd then
				ease(bEnd, false)
			end
			-- The crossovers: S-curves between the two tracks' nodes at their places, along the track's direction there, at
			-- the track's grade at each end. One edge each: a switch's branch must run some way before it ends (probe:
			-- every switch whose crossover piece was 16 m or shorter was refused, 18 m and longer passed), so a crossover
			-- isn't cut at the samples inside it, and follows the profile less closely than the tracks.
			local crossovers : {Edge} = {}
			-- The ends (true: the leg's start) where a crossover or fan found no node to join, reported as the chunk's
			-- problem below rather than left out of the network: a missing fan dead-ends the station's outer tracks.
			local lost : {boolean : string} = {}
			local function gradeAt(list : {Edge}, n : integer) : number
				local e = edgeFrom(list, n)
				if e == nil then
					return 0
				end
				return e.t0.z / math.sqrt(e.t0.x ^ 2 + e.t0.y ^ 2)
			end
			for __, p in ipairs(places) do
				local fromTrack, toTrack = tracks[p[1] as integer], tracks[p[3] as integer]
				local na = nodeAtS(fromTrack, p[2])
				local nb = nodeAtS(toTrack, p[4])
				local along = na ~= nil and edgeFrom(fromTrack, na) or nil
				if na ~= nil and nb ~= nil and along ~= nil then
					local a, b = net.nodes[na], net.nodes[nb]
					local d = math.sqrt(along.t0.x ^ 2 + along.t0.y ^ 2)
					local L = p[4] - p[2]
					local t0 : Pt3 = { x = along.t0.x / d * L, y = along.t0.y / d * L, z = gradeAt(fromTrack, na) * L }
					local t1 : Pt3 = { x = t0.x, y = t0.y, z = gradeAt(toTrack, nb) * L }
					table.insert(crossovers, { node0 = na, node1 = nb, p0 = { x = a.x, y = a.y, z = a.z },
						p1 = { x = b.x, y = b.y, z = b.z }, t0 = t0, t1 = t1, kind = "ground", track = 0, leg = li,
						s0 = p[2], s1 = p[4] })
				else
					local atStart = p[2] < total / 2
					lost[atStart] = lost[atStart] or ("a crossover %.0f m along the leg has no node at its ends"):format(p[2])
				end
			end
			-- The fans: at the leg's start (the station behind it) the left local runs into track 1 and the right into
			-- track 2 at its merge; at its end, from `total − merge` into the station. Each one edge from a new node at the
			-- local track's end, 5 m further out than the line's track on its side, along the track's direction; at a bare
			-- end, from the station's outer track's node on that side instead.
			local fans : {Edge} = {}
			-- The ends with a fan (true: the leg's start).
			local fanEnds : {boolean} = {}
			if mergeStart > 0 then
				table.insert(fanEnds, true)
			end
			if mergeEnd > 0 then
				table.insert(fanEnds, false)
			end
			for k = 1, 2 do
				local list = tracks[k]
				local out = k == 1 and 1 or -1
				for __, atStart in ipairs(fanEnds) do
					local merge = atStart and mergeStart or mergeEnd
					-- Not `atStart and bStart or bEnd`: with no bare end at the start (our own station) that gives bEnd.
					local b : PgraceRailRouterExisting.Bare = bEnd
					if atStart then
						b = bStart
					end
					local edge = atStart and list[1] or list[#list]
					local tip = atStart and edge.p0 or edge.p1
					local tan = atStart and edge.t0 or edge.t1
					local d = math.sqrt(tan.x ^ 2 + tan.y ^ 2)
					local nx, ny = -tan.y / d * out * FAN_SPACING, tan.x / d * out * FAN_SPACING
					-- The local track's end node, added to the network only with its fan edge (a node of no edge is a track
					-- end left unjoined).
					local lp : Pt3 = { x = tip.x + nx, y = tip.y + ny, z = tip.z }
					-- The local track's direction at its tip (at a bare end, the station's outer track's own, outward).
					local tipDir : Pt = { x = tan.x / d, y = tan.y / d }
					if b ~= nil then
						local node, dir = bareNode(b, across(b, lp))
						lp = node
						tipDir = atStart and dir or { x = -dir.x, y = -dir.y }
					end
					local mergeNode = nodeAtS(list, atStart and merge or total - merge)
					local along = mergeNode ~= nil and (atStart and edgeFrom(list, mergeNode) or edgeFrom(list, list[#list].node0)) or nil
					if mergeNode == nil or along == nil then
						lost[atStart] = lost[atStart] or ("a Halt 2+2 fan has no node at its merge, %.0f m from the platforms")
							:format(merge)
					else
						table.insert(net.nodes, lp)
						local localNode = #net.nodes
						local m = net.nodes[mergeNode]
						local gradeTip = tan.z / d
						local gradeMerge = gradeAt(list, mergeNode)
						local tx, ty = tan.x / d * merge, tan.y / d * merge
						local ux, uy = tipDir.x * merge, tipDir.y * merge
						local e : Edge
						if atStart then
							e = { node0 = localNode, node1 = mergeNode, p0 = { x = lp.x, y = lp.y, z = lp.z },
								p1 = { x = m.x, y = m.y, z = m.z }, t0 = { x = ux, y = uy, z = gradeTip * merge },
								t1 = { x = tx, y = ty, z = gradeMerge * merge }, s0 = 0, s1 = merge }
						else
							e = { node0 = mergeNode, node1 = localNode, p0 = { x = m.x, y = m.y, z = m.z },
								p1 = { x = lp.x, y = lp.y, z = lp.z }, t0 = { x = tx, y = ty, z = gradeMerge * merge },
								t1 = { x = ux, y = uy, z = gradeTip * merge }, s0 = total - merge, s1 = total }
						end
						e.kind, e.track, e.leg = "ground", FAN_TRACK, li
						-- Leaving the station: the tracks on the right of the way out (track 2 at the start, 1 at the end).
						if halt and ((atStart and k == 2) or (not atStart and k == 1)) then
							addSignal(e, atStart and STARTER / merge or 1 - STARTER / merge, atStart)
						end
						table.insert(fans, e)
					end
				end
			end
			-- The S-curves go into chunks as the fans do.
			for __, atStart in ipairs({ true, false }) do
				for k = 1, 2 do
					if eases[atStart][k] ~= nil then
						table.insert(fans, eases[atStart][k])
					end
				end
			end
			if halt and total > 2 * (fanZone + 1) then
				-- Starters on the line's leaving tracks (at an island end, on the leaving track's S-curve), home signals on
				-- its arriving ones past the end's fan (or S-curves) and crossovers, facing their trains (at a junction end,
				-- its signals below).
				local startHome = baseStart + CROSSOVER_STRAIGHT + HOME_BEYOND
				local endHome = baseEnd + CROSSOVER_STRAIGHT + HOME_BEYOND
				if ownStart then
					local x = eases[true][2]
					if x ~= nil then
						addSignal(x, STARTER / (x.s1 - x.s0), true)
					else
						signalAt(tracks[2], STARTER, true)
					end
					signalAt(tracks[1], startHome, false)
				else
					startHome = JUNCTION_SIGNAL
				end
				if ownEnd then
					local x = eases[false][1]
					if x ~= nil then
						addSignal(x, 1 - STARTER / (x.s1 - x.s0), false)
					else
						signalAt(tracks[1], total - STARTER, false)
					end
					signalAt(tracks[2], total - endHome, true)
				else
					endHome = JUNCTION_SIGNAL
				end
				-- Block signals between, each track's facing its trains.
				if options.blockSpacing ~= nil then
					local s = startHome + options.blockSpacing
					while s < total - endHome - options.blockSpacing / 2 do
						signalAt(tracks[1], s, false)
						signalAt(tracks[2], s, true)
						s = s + options.blockSpacing
					end
				end
			end
			-- A junction end's signals, with or without Halt 2+2: one-way, on our approach JUNCTION_SIGNAL out from its
			-- start, each facing its own track's trains (track 1 runs against the leg, 2 with it), so trains coming in wait
			-- clear of the junction, and the existing line's path signals take them through it.
			if not ownStart then
				signalAt(tracks[1], JUNCTION_SIGNAL, false)
				signalAt(tracks[2], JUNCTION_SIGNAL, true)
			end
			if not ownEnd then
				signalAt(tracks[1], total - JUNCTION_SIGNAL, false)
				signalAt(tracks[2], total - JUNCTION_SIGNAL, true)
			end
			-- The junctions' pieces, from the leg's track end nodes.
			local junctionStart, junctionEnd : {Edge}, {Edge} = {}, {}
			local splitsStart, splitsEnd : {PgraceRailRouterNetwork.Split}, {PgraceRailRouterNetwork.Split} = nil, nil
			local problemStart, problemEnd : string, string = nil, nil
			if jStart ~= nil and #tracks[1] > 0 and #tracks[2] > 0 then
				junctionStart, splitsStart, problemStart = junctionEdges(net, eStart, jStart, sideStart,
					{ tracks[1][1].node0, tracks[2][1].node0 }, true, total, li)
			end
			if jEnd ~= nil and #tracks[1] > 0 and #tracks[2] > 0 then
				junctionEnd, splitsEnd, problemEnd = junctionEdges(net, eEnd, jEnd, sideEnd,
					{ tracks[1][#tracks[1]].node1, tracks[2][#tracks[2]].node1 }, false, total, li)
			end
			-- A bare end left unjoined (the leg too short for an island end's S-curves, or a fan end's fan: the station's
			-- tracks there would be left unconnected, or its outer tracks) is reported as the chunk's problem, so the check
			-- shows it and nothing is built. The planner gives a bare end the straight its kind needs, so this is a backstop.
			local function bareProblem(b : PgraceRailRouterExisting.Bare, station : PgraceRailRouterRoute.Station,
					island : boolean, merge : number) : string
				if b == nil then
					return nil
				end
				local where = ("the existing station in %s"):format(station.town ~= nil and station.town.name or "?")
				if b.kind == "island" and not island then
					return ("the line at %s is too short (%.0f m) for the curves onto its island platform's tracks"):format(where,
						total)
				elseif b.kind == "fan" and merge <= 0 then
					return ("the line at %s has no room for the fan joining its outer tracks"):format(where)
				end
				return nil
			end
			problemStart = problemStart or bareProblem(bStart, stations[li], islandStart, mergeStart)
			problemEnd = problemEnd or bareProblem(bEnd, stations[li + 1], islandEnd, mergeEnd)
			local function lostProblem(atStart : boolean, station : PgraceRailRouterRoute.Station) : string
				if lost[atStart] == nil then
					return nil
				end
				return ("the line at %s: %s"):format(station ~= nil and station.town ~= nil and station.town.name or "?",
					lost[atStart])
			end
			problemStart = problemStart or lostProblem(true, stations[li])
			problemEnd = problemEnd or lostProblem(false, stations[li + 1])
			local added : {boolean} = {}
			-- Chunk cut points: after chunkLength of centre line, at the next edge end that isn't inside a bridge or tunnel.
			local left, right = tracks[1], tracks[2]
			local k, startS = 1, 0.0
			-- The right track's next edge for a chunk. Its edges are taken by distance along the centre line, not by index:
			-- a switch's window keeps a stretch of one track whole only, so the two tracks can have different numbers of
			-- edges (Halt 2+2 on high-speed track: pairing by index left the right track's last 130 m of a leg out).
			local r = 1
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
				-- The right track's edges ending by the same point (all that are left, with the leg's last chunk).
				while r <= #right and (right[r].s1 <= left[j].s1 + 1e-6 or j == #left) do
					table.insert(net.edges, right[r])
					length = length + (right[r].s1 - right[r].s0)
					r = r + 1
				end
				-- The crossovers and fans that end by this cut (their nodes are in this chunk or one before), and in the leg's
				-- last chunk the rest (an island end's S-curves reach past the tracks' last node).
				for m, x in ipairs(crossovers) do
					if not added[m] and math.max(x.s0, x.s1) <= left[j].s1 + 1e-6 then
						added[m] = true
						table.insert(net.edges, x)
						length = length + (x.s1 - x.s0)
					end
				end
				for m, x in ipairs(fans) do
					if not added[-m] and (x.s1 <= left[j].s1 + 1e-6 or j == #left) then
						added[-m] = true
						table.insert(net.edges, x)
						length = length + (x.s1 - x.s0)
					end
				end
				-- The junctions: at the leg's start in its first chunk, at its end in its last.
				local splits : {PgraceRailRouterNetwork.Split} = nil
				local problem : string = nil
				local function addJunction(list : {Edge}, cutPieces : {PgraceRailRouterNetwork.Split}, why : string)
					for __, x in ipairs(list) do
						table.insert(net.edges, x)
						length = length + (x.s1 - x.s0)
					end
					for __, sp in ipairs(cutPieces or {}) do
						splits = splits or {}
						table.insert(splits, sp)
					end
					problem = problem or why
				end
				if k == 1 then
					addJunction(junctionStart, splitsStart, problemStart)
				end
				if j == #left then
					addJunction(junctionEnd, splitsEnd, problemEnd)
				end
				table.insert(net.chunks, { first = first, last = #net.edges, leg = li, length = length, splits = splits,
					problem = problem })
				startS = left[j].s1
				k = j + 1
			end
		end
	end
	network.sharedSplits(net)
	return net
end

function network.sharedSplits(net : PgraceRailRouterNetwork.Network)
	local first : {integer : integer} = {}
	for ci, c in ipairs(net.chunks) do
		for __, sp in ipairs(c.splits or {}) do
			if first[sp.piece] == nil then
				first[sp.piece] = ci
			elseif first[sp.piece] ~= ci and c.problem == nil then
				c.problem = ("two junctions cut the same piece of existing track (%d), in chunks %d and %d: the first split would leave the second nothing to cut")
					:format(sp.piece, first[sp.piece], ci)
			end
		end
	end
end

return network
