local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo

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
	local function piece(e : Edge, h : Hermite, n0 : Pt3, n1 : Pt3, s0 : number, s1 : number)
		table.insert(out.edges, { node0 = nodeIndex(n0), node1 = nodeIndex(n1), p0 = n0, p1 = n1, t0 = h.t0, t1 = h.t1,
			kind = e.kind, track = e.track, leg = e.leg, s0 = e.s0 + (e.s1 - e.s0) * s0,
			s1 = e.s0 + (e.s1 - e.s0) * s1 })
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
	table.insert(out.chunks, { first = 1, last = #out.edges, leg = net.edges[first].leg, length = 0 })
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
	-- Where edges must break: where one piece meets the next, the spans' ends, and the crossovers' ends (extra), each
	-- with the samples either side of it, so no edge runs from it over a change of grade at a sample.
	local cuts : {number} = {}
	for __, c in ipairs(extra or {}) do
		table.insert(cuts, c)
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
	-- dropped piece end lets an edge run that far into the next piece, close enough to its own curve.
	local breaks : {number} = { 0.0 }
	for __, c in ipairs(cuts) do
		if c > breaks[#breaks] + MIN_EDGE and c < total - MIN_EDGE and free(c) then
			table.insert(breaks, c)
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
-- straight of CROSSOVER_STRAIGHT on the ground.
local function crossoverPlaces(leg : Leg, total : number, base : number, atStart : boolean, atEnd : boolean)
		: {{number}}
	local places : {{number}} = {}
	if #leg.pieces == 0 or total < 2 * (base + CROSSOVER_STRAIGHT) + 1 then
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
	local straight = base + CROSSOVER_STRAIGHT
	if atStart and first.kind == "straight" and first.length >= straight - 1e-6 and groundOver(0, straight) then
		add(1, base + a, 2, base + a + L)
		add(2, straight - a - L + 1, 1, straight - a + 1)
	end
	if atEnd and last.kind == "straight" and last.length >= straight - 1e-6 and groundOver(total - straight, total) then
		add(1, total - straight + a - 1, 2, total - straight + a + L - 1)
		add(2, total - base - a - L, 1, total - base - a)
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

-- A signal at s along a track's edges.
local function signalAt(list : {Edge}, s : number, forward : boolean)
	for __, e in ipairs(list) do
		if s >= e.s0 and s < e.s1 then
			addSignal(e, (s - e.s0) / (e.s1 - e.s0), forward)
			return
		end
	end
end

function network.build(plan : PgraceRailRouterRoute.Plan, options : Options) : PgraceRailRouterNetwork.Network
	local net : PgraceRailRouterNetwork.Network = { nodes = {}, edges = {}, chunks = {} }
	for li, leg in ipairs(plan.legs) do
		local total = 0.0
		for __, piece in ipairs(leg.pieces) do
			total = total + piece.length
		end
		-- Halt 2+2 (options.fan set): a fan at each end, crossovers only at the line's ends, after the fan.
		local halt = options.fan ~= nil
		local fanZone = halt and network.fanLength(options.fan) or 0
		local places : {{number}} = {}
		if options.crossovers then
			places = crossoverPlaces(leg, total, fanZone, not halt or li == 1, not halt or li == #plan.legs)
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
		-- track kept in one edge from the platforms to there (the main edge beside the branch).
		local merge = 0.0
		if halt and total > 2 * (fanZone + 1) then
			merge = FAN_APRON + options.fan
			for k = 1, 2 do
				table.insert(keep[k], { 0, merge })
				table.insert(keep[k], { total - merge, total })
			end
			table.insert(cuts, merge)
			table.insert(cuts, total - merge)
		end
		-- Each track's edges, then grouped by stretch: a chunk takes both tracks' edges between two cut points along
		-- the centre line, so the two tracks of a bridge are in one proposal (one parallel strip, probe P3).
		local tracks : {{Edge}} = { network.trackEdges(leg, li, 1, options, cuts, keep[1]),
			network.trackEdges(leg, li, -1, options, cuts, keep[2]) }
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
		-- The crossovers: S-curves between the two tracks' nodes at their places, along the track's direction there, at
		-- the track's grade at each end. One edge each: a switch's branch must run some way before it ends (probe:
		-- every switch whose crossover piece was 16 m or shorter was refused, 18 m and longer passed), so a crossover
		-- isn't cut at the samples inside it, and follows the profile less closely than the tracks.
		local crossovers : {Edge} = {}
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
			end
		end
		-- The fans: at the leg's start (the station behind it) the left local runs into track 1 and the right into
		-- track 2 at `merge`; at its end, from `total − merge` into the station. Each one edge from a new node at the
		-- local track's end, 5 m further out than the line's track on its side, along the track's direction.
		local fans : {Edge} = {}
		if merge > 0 then
			for k = 1, 2 do
				local list = tracks[k]
				local out = k == 1 and 1 or -1
				for __, atStart in ipairs({ true, false }) do
					local edge = atStart and list[1] or list[#list]
					local tip = atStart and edge.p0 or edge.p1
					local tan = atStart and edge.t0 or edge.t1
					local d = math.sqrt(tan.x ^ 2 + tan.y ^ 2)
					local nx, ny = -tan.y / d * out * FAN_SPACING, tan.x / d * out * FAN_SPACING
					table.insert(net.nodes, { x = tip.x + nx, y = tip.y + ny, z = tip.z })
					local localNode = #net.nodes
					local mergeNode = nodeAtS(list, atStart and merge or total - merge)
					local along = mergeNode ~= nil and (atStart and edgeFrom(list, mergeNode) or edgeFrom(list, list[#list].node0)) or nil
					if mergeNode ~= nil and along ~= nil then
						local m = net.nodes[mergeNode]
						local gradeTip = tan.z / d
						local gradeMerge = gradeAt(list, mergeNode)
						local tx, ty = tan.x / d * merge, tan.y / d * merge
						local e : Edge
						if atStart then
							e = { node0 = localNode, node1 = mergeNode, p0 = { x = tip.x + nx, y = tip.y + ny, z = tip.z },
								p1 = { x = m.x, y = m.y, z = m.z }, t0 = { x = tx, y = ty, z = gradeTip * merge },
								t1 = { x = tx, y = ty, z = gradeMerge * merge }, s0 = 0, s1 = merge }
						else
							e = { node0 = mergeNode, node1 = localNode, p0 = { x = m.x, y = m.y, z = m.z },
								p1 = { x = tip.x + nx, y = tip.y + ny, z = tip.z }, t0 = { x = tx, y = ty, z = gradeMerge * merge },
								t1 = { x = tx, y = ty, z = gradeTip * merge }, s0 = total - merge, s1 = total }
						end
						e.kind, e.track, e.leg = "ground", FAN_TRACK, li
						-- Leaving the station: the tracks on the right of the way out (track 2 at the start, 1 at the end).
						if (atStart and k == 2) or (not atStart and k == 1) then
							addSignal(e, atStart and STARTER / merge or 1 - STARTER / merge, atStart)
						end
						table.insert(fans, e)
					end
				end
			end
			-- Starters on the line's leaving tracks, home signals on its arriving ones, facing their trains.
			local startZone = fanZone + (li == 1 and CROSSOVER_STRAIGHT or 0)
			local endZone = fanZone + (li == #plan.legs and CROSSOVER_STRAIGHT or 0)
			signalAt(tracks[2], STARTER, true)
			signalAt(tracks[1], startZone + HOME_BEYOND, false)
			signalAt(tracks[1], total - STARTER, false)
			signalAt(tracks[2], total - endZone - HOME_BEYOND, true)
			-- Block signals between, each track's facing its trains.
			if options.blockSpacing ~= nil then
				local s = startZone + HOME_BEYOND + options.blockSpacing
				while s < total - endZone - HOME_BEYOND - options.blockSpacing / 2 do
					signalAt(tracks[1], s, false)
					signalAt(tracks[2], s, true)
					s = s + options.blockSpacing
				end
			end
		end
		local added : {boolean} = {}
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
			-- The crossovers and fans that end by this cut (their nodes are in this chunk or one before).
			for m, x in ipairs(crossovers) do
				if not added[m] and math.max(x.s0, x.s1) <= left[j].s1 + 1e-6 then
					added[m] = true
					table.insert(net.edges, x)
					length = length + (x.s1 - x.s0)
				end
			end
			for m, x in ipairs(fans) do
				if not added[-m] and x.s1 <= left[j].s1 + 1e-6 then
					added[-m] = true
					table.insert(net.edges, x)
					length = length + (x.s1 - x.s0)
				end
			end
			table.insert(net.chunks, { first = first, last = #net.edges, leg = li, length = length })
			startS = left[j].s1
			k = j + 1
		end
	end
	return net
end

return network
