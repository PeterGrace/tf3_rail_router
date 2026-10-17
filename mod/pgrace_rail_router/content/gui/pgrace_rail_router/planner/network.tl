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

function network.trackEdges(leg : Leg, legIndex : integer, side : number, options : Options) : {Edge}
	local off = side * options.offset
	-- Where edges must break besides the pieces' ends: the spans' ends.
	local cuts : {number} = {}
	for __, span in ipairs(leg.spans) do
		table.insert(cuts, span.s0)
		table.insert(cuts, span.s1)
	end
	table.sort(cuts)
	local function kindAt(s : number) : string
		for __, span in ipairs(leg.spans) do
			if s >= span.s0 - 1e-6 and s < span.s1 - 1e-6 then
				return span.kind
			end
		end
		return "ground"
	end
	local edges : {Edge} = {}
	local s = 0.0
	for __, piece in ipairs(leg.pieces) do
		local pieceStart, pieceEnd = s, s + piece.length
		-- This piece's breaks: its ends, the span ends inside it, and as many more as keep edges within maxEdge. One
		-- span ends where the next starts, so each cut is in the list twice: compare with the last break, not the
		-- piece's start, or the second copy makes an edge of no length.
		local breaks : {number} = { pieceStart }
		for __, c in ipairs(cuts) do
			if c > breaks[#breaks] + 1e-6 and c < pieceEnd - 1e-6 then
				table.insert(breaks, c)
			end
		end
		table.insert(breaks, pieceEnd)
		for k = 1, #breaks - 1 do
			local a, b = breaks[k], breaks[k + 1]
			local parts = math.max(1, math.ceil((b - a) / options.maxEdge - 1e-9))
			for m = 0, parts - 1 do
				local s0, s1 = a + (b - a) * m / parts, a + (b - a) * (m + 1) / parts
				local q0, d0 = along(piece, s0 - pieceStart, off)
				local q1, d1 = along(piece, s1 - pieceStart, off)
				local tl = tangentLength(piece, s1 - s0, off, options.tangent)
				local z0, g0 = heightAt(leg, s0)
				local z1, g1 = heightAt(leg, s1)
				table.insert(edges, {
					p0 = { x = q0.x, y = q0.y, z = z0 }, p1 = { x = q1.x, y = q1.y, z = z1 },
					t0 = { x = d0.x * tl, y = d0.y * tl, z = g0 * tl }, t1 = { x = d1.x * tl, y = d1.y * tl, z = g1 * tl },
					kind = kindAt((s0 + s1) / 2), track = side > 0 and 1 or 2, leg = legIndex, s0 = s0, s1 = s1,
				})
			end
		end
		s = pieceEnd
	end
	return edges
end

function network.build(plan : PgraceRailRouterRoute.Plan, options : Options) : PgraceRailRouterNetwork.Network
	return { nodes = {}, edges = {}, chunks = {} }
end

return network
