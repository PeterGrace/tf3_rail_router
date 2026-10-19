local midline = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/midline.tl" as PgraceRailRouterMidline
local junction = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/junction.tl" as PgraceRailRouterJunction

local existing : PgraceRailRouterExisting = {}

local type Piece = PgraceRailRouterExisting.Piece
local type Snapshot = PgraceRailRouterExisting.Snapshot
local type Station = PgraceRailRouterExisting.Station
local type End = PgraceRailRouterExisting.End
local type Result = PgraceRailRouterExisting.Result

-- How far out from the platform end, and how far across the axis (at least; a station's outer tracks widen it),
-- the approach is looked for (metres).
local REACH = 1500.0
existing.REACH = REACH
local WIDE = 12.0
local STEP = 5.0
local EPS = 1e-6
-- A double track: two tracks 4.5–5.5 m apart (square across), level with each other within LEVEL, with no other
-- track within WIDE of their midline.
local GAP_MIN = 4.5
local GAP_MAX = 5.5
local LEVEL = 0.3
-- The point paired with one on the other track lies square across: the cosine of the angle between the track and
-- the line to it at most this.
local ACROSS = 0.2
-- Tracks are sampled, and paired, about this far apart along them (metres).
local SAMPLE = 2.0
-- Another track counts beside a pair when within this along the midline of its midpoint (half the pairs' spacing,
-- and a little over, so that the checks leave no gap even on the outside of a curve).
local WINDOW = SAMPLE / 2 + 0.1
-- A piece touching a node of our two tracks meets one of them where it lies within this across of it (at a switch).
local MEETS = 1.5
-- A bridge or tunnel piece more than this above or below the midline crosses over or under it: not beside it.
local CLEARANCE = 6.0
-- The grid cell other tracks' samples are bucketed by (metres): over twice WIDE + WINDOW, so the 2 × 2 cells nearest a
-- point hold every sample that could lie beside it.
local CELL = 25.0
-- A crossover's leg has at most this many pieces; a walk at most this many (a loop of track would go on forever).
local LEG_PIECES = 10
local MAX_LINKS = 5000
-- The start's pieces are straight along the axis at the pair's grade: each tangent's sideways share
-- (|t × outward| / |t_xy|) and its grade's difference from the pair's at most this.
local SIDEWAYS = 0.005
-- The two tracks' grades at the start may differ by this.
local GRADES = 0.002
-- A node on the track's line: within this of it across the axis.
local ON_LINE = 1.0

-- A piece in one end's frame, its ends ordered outward (a inner, b outer); dir +1 if node0 → node1 runs outward.
local record Span
	piece : Piece
	xa : number
	ya : number
	za : number
	xb : number
	yb : number
	zb : number
	nodeA : integer
	nodeB : integer
	dir : number
end

-- The pieces near one end's axis, the pieces at each node, and the station's end nodes.
local record Corridor
	spans : {Span}
	atNode : {integer : {Span}}
	ends : {integer : boolean}
	ox : number
	oy : number
end

-- The pieces near end k's axis that the station's end nodes reach over such pieces, in the frame: x outward from
-- the platform end, y to the left. Near means |y| ≤ WIDE, or 1 m past the station's outermost end node if that's
-- wider, x up to REACH and no further back than the end nodes (less 1 m); returns the corridor and the end nodes'
-- smallest x, where the scan starts.
local function corridor(station : Station, snap : Snapshot, ox : number, oy : number, ex : number,
		ey : number) : Corridor, number
	local all : {Span} = {}
	local isEnd : {integer : boolean} = {}
	for __, n in ipairs(station.ends) do
		isEnd[n] = true
	end
	local wide = WIDE
	for __, p in ipairs(snap.pieces) do
		if isEnd[p.node0] then
			wide = math.max(wide, math.abs((p.p0.y - ey) * ox - (p.p0.x - ex) * oy) + 1)
		end
		if isEnd[p.node1] then
			wide = math.max(wide, math.abs((p.p1.y - ey) * ox - (p.p1.x - ex) * oy) + 1)
		end
	end
	local lo = math.huge
	for __, p in ipairs(snap.pieces) do
		local x0 = (p.p0.x - ex) * ox + (p.p0.y - ey) * oy
		local y0 = (p.p0.y - ey) * ox - (p.p0.x - ex) * oy
		local x1 = (p.p1.x - ex) * ox + (p.p1.y - ey) * oy
		local y1 = (p.p1.y - ey) * ox - (p.p1.x - ex) * oy
		if math.min(x0, x1) >= -station.half and math.max(x0, x1) <= REACH and math.abs(y0) <= wide
				and math.abs(y1) <= wide then
			local s : Span
			if x1 >= x0 then
				s = { piece = p, xa = x0, ya = y0, za = p.p0.z, xb = x1, yb = y1, zb = p.p1.z,
					nodeA = p.node0, nodeB = p.node1, dir = 1 }
			else
				s = { piece = p, xa = x1, ya = y1, za = p.p1.z, xb = x0, yb = y0, zb = p.p0.z,
					nodeA = p.node1, nodeB = p.node0, dir = -1 }
			end
			table.insert(all, s)
			if isEnd[s.nodeA] then
				lo = math.min(lo, s.xa)
			end
			if isEnd[s.nodeB] then
				lo = math.min(lo, s.xb)
			end
		end
	end
	if lo == math.huge then
		lo = 0
	end
	local atNode : {integer : {Span}} = {}
	for __, s in ipairs(all) do
		if s.xa >= lo - 1 then
			for __, n in ipairs({ s.nodeA, s.nodeB }) do
				atNode[n] = atNode[n] or {}
				table.insert(atNode[n], s)
			end
		end
	end
	local out : {Span} = {}
	local taken : {Span : boolean} = {}
	local queue : {integer} = {}
	local visited : {integer : boolean} = {}
	for __, n in ipairs(station.ends) do
		if not visited[n] then
			visited[n] = true
			table.insert(queue, n)
		end
	end
	local head = 1
	while head <= #queue do
		local n = queue[head]
		head = head + 1
		for __, s in ipairs(atNode[n] or {}) do
			if not taken[s] then
				taken[s] = true
				table.insert(out, s)
				for __, m in ipairs({ s.nodeA, s.nodeB }) do
					if not visited[m] then
						visited[m] = true
						table.insert(queue, m)
					end
				end
			end
		end
	end
	local reached : {integer : {Span}} = {}
	for __, s in ipairs(out) do
		for __, n in ipairs({ s.nodeA, s.nodeB }) do
			reached[n] = reached[n] or {}
			table.insert(reached[n], s)
		end
	end
	return { spans = out, atNode = reached, ends = isEnd, ox = ox, oy = oy }, lo
end

-- The span's y and z at x, along its chord (the stretch's pieces are straight).
local function at(s : Span, x : number) : number, number
	local f = (x - s.xa) / (s.xb - s.xa)
	return s.ya + (s.yb - s.ya) * f, s.za + (s.zb - s.za) * f
end

-- The spans that cross the line x (a piece starting at x counts, one ending there doesn't).
local function crossing(spans : {Span}, x : number) : {Span}
	local out : {Span} = {}
	for __, s in ipairs(spans) do
		if s.xa <= x and x < s.xb then
			table.insert(out, s)
		end
	end
	return out
end

-- Both tangents along the axis at grade g (dz per metre outward): a piece that bulges or kinks, sideways or up,
-- isn't straight, whatever its chord.
local function straight(p : Piece, ox : number, oy : number, g : number) : boolean
	for __, tg in ipairs({ p.t0, p.t1 }) do
		local len = math.sqrt(tg.x * tg.x + tg.y * tg.y)
		if len < EPS or math.abs(tg.x * oy - tg.y * ox) / len > SIDEWAYS then
			return false
		end
		local along = tg.x * ox + tg.y * oy > 0 and 1 or -1
		if math.abs(along * tg.z / len - g) > SIDEWAYS then
			return false
		end
	end
	return true
end

-- The span's grade along its chord (dz per metre outward).
local function gradeOf(s : Span) : number
	return (s.zb - s.za) / (s.xb - s.xa)
end

-- The other piece at a plain node.
local function onward(c : Corridor, n : integer, s : Span) : Span
	for __, o in ipairs(c.atNode[n] or {}) do
		if o ~= s then
			return o
		end
	end
	return nil
end

-- Whether piece `o`, leaving node n (at y across the axis), leads through plain nodes within the corridor to a
-- switch 4.5–5.5 m across, towards the midline `mid`: the other side of a crossover.
local function across(c : Corridor, snap : Snapshot, n : integer, o : Span, y : number, mid : number) : boolean
	local s, from = o, n
	for __ = 1, 10 do
		local m = s.nodeA == from and s.nodeB or s.nodeA
		if snap.degree[m] == 3 then
			local d = (s.nodeA == from and s.yb or s.ya) - y
			return math.abs(d) >= GAP_MIN and math.abs(d) <= GAP_MAX and d * (mid - y) > 0
		end
		if snap.degree[m] ~= 2 then
			return false
		end
		local nxt = onward(c, m, s)
		if not nxt then
			return false
		end
		s, from = nxt, m
	end
	return false
end

-- Whether the track behind the pieces `firsts` comes only from the station: walking inward from them through the
-- corridor, every way back ends at a station end node. On the way, a node may join two inward pieces (a fan's
-- merge), or split towards the station only where one of its outward pieces leads across to the other track (a
-- crossover). A piece leaving the corridor (a branch, a siding or another line coming in), a dead end or any other
-- switch means the stretch belongs to more than the station's own tracks. A node with four pieces (a level crossing
-- or a scissors crossover in the throat) fails it too, which may be overcautious.
local function fromStation(c : Corridor, snap : Snapshot, firsts : {Span}, mid : number) : boolean
	local seen : {integer : boolean} = {}
	local stack : {Span} = {}
	for __, s in ipairs(firsts) do
		table.insert(stack, s)
	end
	while #stack > 0 do
		local s = table.remove(stack)
		local n = s.nodeA
		if not seen[n] and not c.ends[n] then
			seen[n] = true
			local here = c.atNode[n] or {}
			if #here ~= snap.degree[n] or #here > 3 then
				return false
			end
			local inward, outward : {Span}, {Span} = {}, {}
			for __, o in ipairs(here) do
				table.insert(o.nodeB == n and inward or outward, o)
			end
			if #inward == 0 or #outward > 2 then
				return false
			end
			if #outward == 2 then
				-- The other outward piece leads across; or the trace came in along the crossover's leg itself
				-- (which led across from the other track), and the other piece carries on along this track.
				local other = outward[1] == s and outward[2] or outward[1]
				local otherY = other.nodeA == n and other.yb or other.ya
				if not across(c, snap, n, other, s.ya, mid)
						and not (math.abs(otherY - s.ya) <= ON_LINE and across(c, snap, n, s, s.ya, mid)) then
					return false
				end
			end
			for __, o in ipairs(inward) do
				table.insert(stack, o)
			end
		end
	end
	return true
end

-- Where the reading starts at x, if it does there: exactly two pieces cross x, on the ground, 4.5–5.5 m apart, on
-- grades within GRADES of each other and straight along the axis at their mean grade (the station's fan runs straight
-- out of it). Returns the left span (left of outward), the right one and the midline's y there.
local function startAt(c : Corridor, x : number) : Span, Span, number
	local cross = crossing(c.spans, x)
	if #cross ~= 2 then
		return nil, nil, nil
	end
	local g = (gradeOf(cross[1]) + gradeOf(cross[2])) / 2
	if math.abs(gradeOf(cross[1]) - gradeOf(cross[2])) > GRADES then
		return nil, nil, nil
	end
	for __, s in ipairs(cross) do
		if s.piece.kind ~= "ground" or not straight(s.piece, c.ox, c.oy, g) then
			return nil, nil, nil
		end
	end
	local y1 = at(cross[1], x)
	local y2 = at(cross[2], x)
	if math.abs(y1 - y2) < GAP_MIN or math.abs(y1 - y2) > GAP_MAX then
		return nil, nil, nil
	end
	if y2 > y1 then
		return cross[2], cross[1], (y1 + y2) / 2
	end
	return cross[1], cross[2], (y1 + y2) / 2
end

-- (x, y) as a unit vector ((0, 0) for a zero one).
local function unit(x : number, y : number) : number, number
	local d = math.sqrt(x * x + y * y)
	if d < EPS then
		return 0, 0
	end
	return x / d, y / d
end

local function chord(p : Piece) : number
	return math.sqrt((p.p1.x - p.p0.x) ^ 2 + (p.p1.y - p.p0.y) ^ 2)
end

-- How many samples a piece takes to be sampled at most SAMPLE apart along it: its curve is no longer than its control
-- polygon (p0, p0 + t0/3, p1 − t1/3, p1; in plan), however it bulges.
local function samples(p : Piece) : integer
	local ax, ay = p.p0.x + p.t0.x / 3, p.p0.y + p.t0.y / 3
	local bx, by = p.p1.x - p.t1.x / 3, p.p1.y - p.t1.y / 3
	local l = math.sqrt(p.t0.x ^ 2 + p.t0.y ^ 2) / 3 + math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
		+ math.sqrt(p.t1.x ^ 2 + p.t1.y ^ 2) / 3
	return math.max(1, math.ceil(l / SAMPLE))
end

-- The point at parameter s along a piece's curve (as network.hermiteAt, without building a table).
local function hermite(p : Piece, s : number) : number, number, number
	local s2, s3 = s * s, s * s * s
	local h00, h10, h01, h11 = 2 * s3 - 3 * s2 + 1, s3 - 2 * s2 + s, -2 * s3 + 3 * s2, s3 - s2
	return h00 * p.p0.x + h10 * p.t0.x + h01 * p.p1.x + h11 * p.t1.x,
		h00 * p.p0.y + h10 * p.t0.y + h01 * p.p1.y + h11 * p.t1.y,
		h00 * p.p0.z + h10 * p.t0.z + h01 * p.p1.z + h11 * p.t1.z
end

-- A piece's end at a node: which is 0 at its node0, 1 at its node1.
local record Ref
	piece : Piece
	which : integer
end

-- The node at the piece's other end, and its position.
local function refFar(r : Ref) : integer
	return r.which == 0 and r.piece.node1 or r.piece.node0
end

local function refFarPos(r : Ref) : PgraceRailRouterNetwork.Pt3
	return r.which == 0 and r.piece.p1 or r.piece.p0
end

-- The piece's direction (unit, in plan) leaving the node into it, and arriving at its far end, travelling that way.
local function refAway(r : Ref) : number, number
	if r.which == 0 then
		return unit(r.piece.t0.x, r.piece.t0.y)
	end
	return unit(-r.piece.t1.x, -r.piece.t1.y)
end

local function refArrive(r : Ref) : number, number
	if r.which == 0 then
		return unit(r.piece.t1.x, r.piece.t1.y)
	end
	return unit(-r.piece.t0.x, -r.piece.t0.y)
end

-- The whole snapshot, read once per analysis: each node's piece ends; and for the third-track check, each piece's
-- points about every SAMPLE metres along it (x, y, z flat, aligned with `pieces`), sampled when first needed.
local record Index
	at : {integer : {Ref}}
	pieces : {Piece}
	samples : {{number}}
end

local function cellKey(cx : integer, cy : integer) : integer
	return cx * 65536 + cy
end

local function index(snap : Snapshot) : Index
	local ix : Index = { at = {}, pieces = snap.pieces, samples = {} }
	for __, p in ipairs(snap.pieces) do
		for which = 0, 1 do
			local n = which == 0 and p.node0 or p.node1
			ix.at[n] = ix.at[n] or {}
			table.insert(ix.at[n], { piece = p, which = which })
		end
	end
	return ix
end

local function samplesOf(ix : Index, i : integer) : {number}
	local pts = ix.samples[i]
	if pts == nil then
		local p = ix.pieces[i]
		pts = {}
		local n = samples(p)
		for j = 0, n do
			local x, y, z = hermite(p, j / n)
			pts[3 * j + 1], pts[3 * j + 2], pts[3 * j + 3] = x, y, z
		end
		ix.samples[i] = pts
	end
	return pts
end

-- A piece of a track walked outward: dir +1 where its node0 → node1 runs outward; nodeA its inner node, nodeB its
-- outer one.
local record Link
	piece : Piece
	dir : number
	nodeA : integer
	nodeB : integer
end

local function linkFrom(r : Ref) : Link
	return { piece = r.piece, dir = r.which == 0 and 1 or -1, nodeA = r.which == 0 and r.piece.node0 or r.piece.node1,
		nodeB = refFar(r) }
end

-- The link's outward direction at its outer node (unit, in plan).
local function outAt(l : Link) : number, number
	if l.dir > 0 then
		return unit(l.piece.t1.x, l.piece.t1.y)
	end
	return unit(-l.piece.t0.x, -l.piece.t0.y)
end

-- Whether the piece end r, leaving the switch at node n on a track running outward along (ox, oy) there, is one leg
-- of a crossover to the other track: it leads through plain nodes (at most LEG_PIECES pieces) to another switch, 4.5–5.5
-- m across to the `side` of n (−1 right, +1 left). Across is measured square to the mean of the two tracks' outward
-- directions at the two switches, so it reads nearly true on a curve too: two points on concentric circles lie
-- (r2 − r1)·cos(Δ/2) apart square to that mean, Δ the angle between them (4.99 m for 5 m with a 45 m leg on a 300 m
-- curve). The other track's direction is its own piece's
-- leaving the far switch outward (the game's switches are tangent, but a leg may meet the track at an angle).
-- Returns the far switch's node, or nil.
local function legFrom(ix : Index, snap : Snapshot, n : integer, ox : number, oy : number, r : Ref,
		side : number) : integer
	local ax, ay = refAway(r)
	local facing = ax * ox + ay * oy > 0
	local from = r.which == 0 and r.piece.p0 or r.piece.p1
	local cur = r
	for __ = 1, LEG_PIECES do
		local m = refFar(cur)
		local degree = snap.degree[m]
		if degree == 3 then
			-- The other track's outward direction there: roughly the leg's own, or against it for a leg coming from
			-- behind; exactly, that of the track's piece leaving the switch that way.
			local tx, ty = refArrive(cur)
			if not facing then
				tx, ty = -tx, -ty
			end
			for __, o in ipairs(ix.at[m] or {}) do
				if o.piece ~= cur.piece then
					local wx, wy = refAway(o)
					if wx * tx + wy * ty > 0 then
						tx, ty = wx, wy
						break
					end
				end
			end
			local bx, by = unit(ox + tx, oy + ty)
			local q = refFarPos(cur)
			local off = side * (bx * (q.y - from.y) - by * (q.x - from.x))
			if off >= GAP_MIN and off <= GAP_MAX then
				return m
			end
			return nil
		end
		local here = ix.at[m]
		if degree ~= 2 or here == nil or #here ~= 2 then
			return nil
		end
		local nxt = here[1].piece == cur.piece and here[2] or here[1]
		local px, py = refArrive(cur)
		local nx, ny = refAway(nxt)
		if px * nx + py * ny <= 0 then
			return nil
		end
		cur = nxt
	end
	return nil
end

-- One track walked outward from `first`, piece by piece, whatever the pieces' shape, until `budget` metres (of chord)
-- past it. At a plain node (degree 2) it carries on, unless the next piece turns back. At a switch it carries on along
-- its own track only where the switch is one side of a crossover to the other track (at `side`, see legFrom): at a
-- facing switch on the piece that isn't the leg, at a trailing one (the leg coming in from behind) on the one ahead.
-- Any other switch (a node with four pieces too, such as a scissors crossover or a diamond, which may be
-- overcautious), a dead end, a node with pieces the snapshot lacks or a piece turning back ends the walk ("stop");
-- so does the budget ("reach"). Bridges and tunnels are walked like any piece. far[k]: where a crossover leaves the
-- outer node of links[k], its far switch's node.
local record Walk
	links : {Link}
	why : string
	far : {integer : integer}
end

local function walk(ix : Index, snap : Snapshot, first : Link, side : number, budget : number) : Walk
	local w : Walk = { links = { first }, why = "stop", far = {} }
	local run = 0.0
	while true do
		local cur = w.links[#w.links]
		if run >= budget then
			w.why = "reach"
			return w
		end
		local n = cur.nodeB
		local here = ix.at[n] or {}
		if snap.degree[n] ~= #here then
			return w
		end
		local ox, oy = outAt(cur)
		local ahead, behind : {Ref}, {Ref} = {}, {}
		for __, r in ipairs(here) do
			if r.piece ~= cur.piece then
				local ax, ay = refAway(r)
				table.insert(ax * ox + ay * oy > 0 and ahead or behind, r)
			end
		end
		local nxt : Ref = nil
		if #ahead == 1 and #behind == 0 then
			nxt = ahead[1]
		elseif #ahead == 1 and #behind == 1 then
			local m = legFrom(ix, snap, n, ox, oy, behind[1], side)
			if m ~= nil then
				nxt, w.far[#w.links] = ahead[1], m
			end
		elseif #ahead == 2 and #behind == 0 then
			-- Both pieces leave tangent to the track, so only where they lead tells the leg from the track.
			local m1 = legFrom(ix, snap, n, ox, oy, ahead[1], side)
			local m2 = legFrom(ix, snap, n, ox, oy, ahead[2], side)
			if m1 ~= nil and m2 == nil then
				nxt, w.far[#w.links] = ahead[2], m1
			elseif m2 ~= nil and m1 == nil then
				nxt, w.far[#w.links] = ahead[1], m2
			end
		end
		if nxt == nil or #w.links >= MAX_LINKS then
			return w
		end
		table.insert(w.links, linkFrom(nxt))
		run = run + chord(nxt.piece)
	end
end

-- Cuts each walk at its first crossover whose far switch isn't on the other walk (a crossover to some third track):
-- the walk stops at that switch. Repeated, since cutting one walk can strand the other's crossovers.
local function pairWalks(l : Walk, r : Walk)
	local changed = true
	while changed do
		changed = false
		for __, pair in ipairs({ { l, r }, { r, l } }) do
			local w, o = pair[1], pair[2]
			local on : {integer : boolean} = {}
			for __, link in ipairs(o.links) do
				on[link.nodeB] = true
			end
			for k = 1, #w.links do
				local m = w.far[k]
				if m ~= nil and not on[m] then
					for i = #w.links, k + 1, -1 do
						w.links[i] = nil
					end
					local far : {integer : integer} = {}
					for i, f in pairs(w.far) do
						if i < k then
							far[i] = f
						end
					end
					w.far, w.why, changed = far, "stop", true
					break
				end
			end
		end
	end
end

-- A walk's polyline: its pieces sampled about every SAMPLE metres, in order outward from the start point (parameter
-- s0 along the first piece, outward), up to `budget` metres along it. arc[i]: point i's distance along the line;
-- seg[i]: the link segment i (point i to i + 1) lies on; nodeArc[k]: the distance of links[k]'s outer node, for the
-- nodes the line reaches. why: the walk's, or "reach" where the budget cut the line.
local record Line
	xs : {number}
	ys : {number}
	zs : {number}
	arc : {number}
	seg : {integer}
	nodeArc : {number}
	walk : Walk
	why : string
end

local function line(w : Walk, s0 : number, budget : number) : Line
	local ln : Line = { xs = {}, ys = {}, zs = {}, arc = {}, seg = {}, nodeArc = {}, walk = w, why = w.why }
	local function param(l : Link, s : number) : number
		return l.dir > 0 and s or 1 - s
	end
	local x, y, z = hermite(w.links[1].piece, param(w.links[1], s0))
	ln.xs[1], ln.ys[1], ln.zs[1], ln.arc[1] = x, y, z, 0
	for k, l in ipairs(w.links) do
		local from = k == 1 and s0 or 0
		local n = math.max(1, math.ceil(samples(l.piece) * (1 - from)))
		for j = 1, n do
			local i = #ln.xs
			local px, py, pz = hermite(l.piece, param(l, from + (1 - from) * j / n))
			local d = math.sqrt((px - ln.xs[i]) ^ 2 + (py - ln.ys[i]) ^ 2)
			if ln.arc[i] + d >= budget then
				local u = d > EPS and (budget - ln.arc[i]) / d or 0
				ln.xs[i + 1], ln.ys[i + 1] = ln.xs[i] + (px - ln.xs[i]) * u, ln.ys[i] + (py - ln.ys[i]) * u
				ln.zs[i + 1], ln.arc[i + 1], ln.seg[i] = ln.zs[i] + (pz - ln.zs[i]) * u, budget, k
				ln.why = "reach"
				return ln
			end
			ln.xs[i + 1], ln.ys[i + 1], ln.zs[i + 1], ln.arc[i + 1], ln.seg[i] = px, py, pz, ln.arc[i] + d, k
		end
		ln.nodeArc[k] = ln.arc[#ln.arc]
	end
	return ln
end

-- The segment of ln holding distance a along it, moving from segment i either way. At a node, side −1 takes the
-- segment before it, +1 the one after, 0 either.
local function seek(ln : Line, i : integer, a : number, side : integer) : integer
	local last = #ln.xs - 1
	while i < last and (ln.arc[i + 1] < a or (side > 0 and ln.arc[i + 1] <= a)) do
		i = i + 1
	end
	while i > 1 and (ln.arc[i] > a or (side < 0 and ln.arc[i] >= a)) do
		i = i - 1
	end
	return i
end

-- The point at distance a along segment i of ln, and the segment's direction (unit, in plan).
local function pointOn(ln : Line, i : integer, a : number) : number, number, number, number, number
	local l = ln.arc[i + 1] - ln.arc[i]
	local u = l > EPS and (a - ln.arc[i]) / l or 0
	local ex, ey = ln.xs[i + 1] - ln.xs[i], ln.ys[i + 1] - ln.ys[i]
	local dx, dy = unit(ex, ey)
	return ln.xs[i] + ex * u, ln.ys[i] + ey * u, ln.zs[i] + (ln.zs[i + 1] - ln.zs[i]) * u, dx, dy
end

-- The squared distance from (px, py) to segment i of ln, and the fraction along it of the nearest point.
local function toSegment(ln : Line, i : integer, px : number, py : number) : number, number
	local ax, ay = ln.xs[i], ln.ys[i]
	local ex, ey = ln.xs[i + 1] - ax, ln.ys[i + 1] - ay
	local l2 = ex * ex + ey * ey
	local u = 0.0
	if l2 > EPS * EPS then
		u = math.max(0, math.min(1, ((px - ax) * ex + (py - ay) * ey) / l2))
	end
	local dx, dy = ax + ex * u - px, ay + ey * u - py
	return dx * dx + dy * dy, u
end

-- The nearest point of ln to (px, py), searching from segment j on to neighbouring segments while the nearest point
-- lies at the segment's end and they come nearer (the two tracks run side by side, so the match moves on steadily, and
-- a segment the point lies square across from is the nearest within the line's sag, a few millimetres): its segment
-- and its distance along ln.
local function nearest(ln : Line, j : integer, px : number, py : number) : integer, number
	local last = #ln.xs - 1
	local d, u = toSegment(ln, j, px, py)
	while u >= 1 and j < last do
		local d2, u2 = toSegment(ln, j + 1, px, py)
		if d2 > d then
			break
		end
		j, d, u = j + 1, d2, u2
	end
	while u <= 0 and j > 1 do
		local d2, u2 = toSegment(ln, j - 1, px, py)
		if d2 >= d then
			break
		end
		j, d, u = j - 1, d2, u2
	end
	return j, ln.arc[j] + (ln.arc[j + 1] - ln.arc[j]) * u
end

-- A stretch read off the two lines: its midline's points, each pair's distances along the left and right lines (as,
-- bs), where it starts and ends along the left line (a0, a1) and the right one (b0, b1), why it ended, and (while it's
-- read) the number of switches each line has passed.
local record Run
	mids : {PgraceRailRouterNetwork.Pt3}
	as : {number}
	bs : {number}
	a0 : number
	a1 : number
	b0 : number
	b1 : number
	why : string
	sl : integer
	sr : integer
end

-- A point the pairing looks at: a along the left line, at a node on the side `side` (see `seek`); and for a node of
-- the right line, b along the right line (and its side there), else nil.
local record Item
	a : number
	side : integer
	b : number
	rside : integer
end

-- The stretches along two walked tracks. The left line is followed in steps of SAMPLE, each point paired with the
-- nearest point of the right line (searched onward from the last match), and at each node where something changes
-- (a crossover's switch, the ground ending or starting) on either side of it. A pair holds while the two points are
-- 4.5–5.5 m apart, level within LEVEL, the right one square across (|cos| ≤ ACROSS) to the right, both on the ground,
-- and no other track lies beside their midpoint (see `crowded`). A stretch is a run of pairs that hold with no switch
-- between them; it ends at the last pair that held before one that doesn't ("drift", "structure", or "crossover"
-- between a crossover's two switches), at a switch ("crossover"), or where either line ends (its why).
local function pair(left : Line, right : Line, ix : Index) : {Run}
	-- Every other piece's samples, by grid cell (our own two tracks aren't a third).
	local own : {integer : boolean} = {}
	for __, ln in ipairs({ left, right }) do
		for __, l in ipairs(ln.walk.links) do
			own[l.piece.entity] = true
		end
	end
	-- Only the cells round the left line matter (a midpoint is 2.5 m from it, and what lies beside one within WIDE of
	-- it): a piece is sampled only if its curve's bounding box (its control points') meets them.
	local near : {integer : boolean} = {}
	local lastKey : integer = nil
	for i = 1, #left.xs do
		local cx, cy = math.floor(left.xs[i] / CELL), math.floor(left.ys[i] / CELL)
		local key = cellKey(cx, cy)
		if key ~= lastKey then
			lastKey = key
			for gx = cx - 1, cx + 1 do
				for gy = cy - 1, cy + 1 do
					near[cellKey(gx, gy)] = true
				end
			end
		end
	end
	-- The nodes of our two tracks (the crossovers' far switches among them): only a piece touching one can be where
	-- another track meets ours at a switch.
	local ours : {integer : boolean} = {}
	for __, ln in ipairs({ left, right }) do
		for __, l in ipairs(ln.walk.links) do
			ours[l.nodeA], ours[l.nodeB] = true, true
		end
		for __, m in pairs(ln.walk.far) do
			ours[m] = true
		end
	end
	-- Each sample in its cell as x, y, z, whether its piece touches our tracks (1 or 0) and whether it's a bridge or
	-- tunnel (1 or 0).
	local cells : {integer : {number}} = {}
	for i, p in ipairs(ix.pieces) do
		if not own[p.entity] then
			local ax, bx = p.p0.x + p.t0.x / 3, p.p1.x - p.t1.x / 3
			local ay, by = p.p0.y + p.t0.y / 3, p.p1.y - p.t1.y / 3
			local x0 = math.floor(math.min(p.p0.x, ax, bx, p.p1.x) / CELL)
			local x1 = math.floor(math.max(p.p0.x, ax, bx, p.p1.x) / CELL)
			local y0 = math.floor(math.min(p.p0.y, ay, by, p.p1.y) / CELL)
			local y1 = math.floor(math.max(p.p0.y, ay, by, p.p1.y) / CELL)
			local meets = false
			for gx = x0, x1 do
				for gy = y0, y1 do
					meets = meets or near[cellKey(gx, gy)] == true
				end
			end
			if meets then
				local touches = (ours[p.node0] or ours[p.node1]) and 1 or 0
				local structure = (p.kind == "bridge" or p.kind == "tunnel") and 1 or 0
				local pts = samplesOf(ix, i)
				for j = 1, #pts, 3 do
					local key = cellKey(math.floor(pts[j] / CELL), math.floor(pts[j + 1] / CELL))
					if near[key] then
						local cell = cells[key]
						if cell == nil then
							cell = {}
							cells[key] = cell
						end
						local m = #cell
						cell[m + 1], cell[m + 2], cell[m + 3], cell[m + 4], cell[m + 5] = pts[j], pts[j + 1], pts[j + 2],
							touches, structure
					end
				end
			end
		end
	end
	-- Each crossover as the two links whose outer nodes its switches are at: between them (one line past its switch,
	-- the other not) the leg runs between the tracks.
	local leftAt, rightAt : {integer : integer}, {integer : integer} = {}, {}
	for k, l in ipairs(left.walk.links) do
		leftAt[l.nodeB] = k
	end
	for k, l in ipairs(right.walk.links) do
		rightAt[l.nodeB] = k
	end
	local xl, xr : {integer}, {integer} = {}, {}
	for k, m in pairs(left.walk.far) do
		if rightAt[m] ~= nil then
			table.insert(xl, k)
			table.insert(xr, rightAt[m])
		end
	end
	for k, m in pairs(right.walk.far) do
		if leftAt[m] ~= nil then
			table.insert(xl, leftAt[m])
			table.insert(xr, k)
		end
	end
	-- The switches each line has passed on each link.
	local function passed(w : Walk) : {integer}
		local out : {integer} = {}
		local count = 0
		for k = 1, #w.links do
			out[k] = count
			if w.far[k] ~= nil then
				count = count + 1
			end
		end
		return out
	end
	local sl, sr = passed(left.walk), passed(right.walk)

	-- Where the reading ends: at the end of the line that ends first (along the left), why as that line's.
	local leftTotal, rightTotal = left.arc[#left.arc], right.arc[#right.arc]
	local __, aOfRightEnd = nearest(left, #left.xs - 1, right.xs[#right.xs], right.ys[#right.ys])
	local ___, bOfLeftEnd = nearest(right, #right.xs - 1, left.xs[#left.xs], left.ys[#left.ys])
	local events : {Item} = {}
	local aEnd, endWhy : number, string
	if aOfRightEnd < leftTotal - EPS then
		aEnd, endWhy = aOfRightEnd, right.why
		table.insert(events, { a = aEnd, side = 0, b = rightTotal, rside = -1 })
	elseif bOfLeftEnd < rightTotal - EPS then
		aEnd, endWhy = leftTotal, left.why
		table.insert(events, { a = aEnd, side = -1 })
	else
		aEnd = leftTotal
		endWhy = (left.why == "stop" or right.why == "stop") and "stop" or "reach"
		table.insert(events, { a = aEnd, side = -1, b = rightTotal, rside = -1 })
	end
	-- The nodes where something changes, on each side of them.
	local function changes(ln : Line, k : integer) : boolean
		local w = ln.walk
		return w.far[k] ~= nil or (w.links[k].piece.kind == "ground") ~= (w.links[k + 1].piece.kind == "ground")
	end
	for k = 1, #left.walk.links - 1 do
		local at = left.nodeArc[k]
		if at ~= nil and at < aEnd - EPS and changes(left, k) then
			table.insert(events, { a = at, side = -1 })
			table.insert(events, { a = at, side = 1 })
		end
	end
	local jl = 1
	for k = 1, #right.walk.links - 1 do
		local bt = right.nodeArc[k]
		if bt ~= nil and bt < rightTotal - EPS and changes(right, k) then
			local i = seek(right, 1, bt, 0)
			local px, py = pointOn(right, i, bt)
			local at : number
			jl, at = nearest(left, jl, px, py)
			if at < aEnd - EPS then
				table.insert(events, { a = at, side = 0, b = bt, rside = -1 })
				table.insert(events, { a = at, side = 0, b = bt, rside = 1 })
			end
		end
	end
	local function before(p : Item, q : Item) : boolean
		if p.a ~= q.a then
			return p.a < q.a
		elseif p.side ~= q.side then
			return p.side < q.side
		end
		return (p.rside or 0) < (q.rside or 0)
	end
	table.sort(events, before)
	-- The steps along the left line, with the (few) events merged in, in order.
	local items : {Item} = {}
	local ev, a = 1, 0.0
	while a < aEnd - EPS or ev <= #events do
		local step : Item = nil
		if a < aEnd - EPS then
			step = { a = a, side = 0 }
		end
		if step == nil or (ev <= #events and before(events[ev], step)) then
			table.insert(items, events[ev])
			ev = ev + 1
		else
			table.insert(items, step)
			a = a + SAMPLE
		end
	end

	-- Whether another track's sample lies beside the midpoint (mx, my, height mz), the tracks running along (dx, dy)
	-- there: within WINDOW along and WIDE across. Not where a piece touching our tracks' nodes meets one of them (within
	-- MEETS of the left or right track's offset yl, yr): there it's joining ours at a switch (a crossover's leg, a fan's
	-- merge), which the crossovers and the walk's switches account for. Nor a bridge or tunnel more than CLEARANCE
	-- above or below: a line crossing over or under. A track coming in beside, or crossing on the level, ends the
	-- stretch where it comes within WIDE of the midline. Checked at every pair, as the pairs are SAMPLE apart.
	local function crowded(mx : number, my : number, mz : number, dx : number, dy : number, yl : number,
			yr : number) : boolean
		local fx, fy = mx / CELL, my / CELL
		local cx, cy = math.floor(fx), math.floor(fy)
		local x0 = fx - cx < 0.5 and cx - 1 or cx
		local y0 = fy - cy < 0.5 and cy - 1 or cy
		for gx = x0, x0 + 1 do
			for gy = y0, y0 + 1 do
				local cell = cells[cellKey(gx, gy)]
				if cell ~= nil then
					for i = 1, #cell, 5 do
						local rx, ry = cell[i] - mx, cell[i + 1] - my
						if math.abs(rx * dx + ry * dy) <= WINDOW then
							local off = dx * ry - dy * rx
							local meets = cell[i + 3] == 1 and (math.abs(off - yl) <= MEETS or math.abs(off - yr) <= MEETS)
							local apart = cell[i + 4] == 1 and math.abs(cell[i + 2] - mz) > CLEARANCE
							if math.abs(off) <= WIDE and not meets and not apart then
								return true
							end
						end
					end
				end
			end
		end
		return false
	end

	local runs : {Run} = {}
	local cur : Run = nil
	local function close(why : string)
		if cur ~= nil then
			cur.why = why
			if #cur.mids >= 2 and cur.a1 - cur.a0 > EPS then
				table.insert(runs, cur)
			end
			cur = nil
		end
	end
	local il, ir = 1, 1
	for __, it in ipairs(items) do
		il = seek(left, il, it.a, it.side)
		local px, py, pz, dx, dy = pointOn(left, il, it.a)
		local qx, qy, qz, b : number, number, number, number
		if it.b ~= nil then
			ir = seek(right, ir, it.b, it.rside)
			b = it.b
		else
			ir, b = nearest(right, ir, px, py)
		end
		qx, qy, qz = pointOn(right, ir, b)
		local kl, kr = left.seg[il], right.seg[ir]
		local why : string = nil
		if left.walk.links[kl].piece.kind ~= "ground" or right.walk.links[kr].piece.kind ~= "ground" then
			why = "structure"
		else
			for x = 1, #xl do
				if (kl > xl[x]) ~= (kr > xr[x]) then
					why = "crossover"
					break
				end
			end
		end
		local mx, my = (px + qx) / 2, (py + qy) / 2
		if why == nil then
			local ex, ey = qx - px, qy - py
			local gap = math.sqrt(ex * ex + ey * ey)
			if gap < GAP_MIN or gap > GAP_MAX or math.abs(pz - qz) > LEVEL or math.abs(dx * ex + dy * ey) > ACROSS * gap
					or dx * ey - dy * ex >= 0
					or crowded(mx, my, (pz + qz) / 2, dx, dy, dx * (py - my) - dy * (px - mx),
						dx * (qy - my) - dy * (qx - mx)) then
				why = "drift"
			end
		end
		if why ~= nil then
			close(why)
		else
			if cur ~= nil and (cur.sl ~= sl[kl] or cur.sr ~= sr[kr]) then
				close("crossover")
			end
			if cur == nil then
				cur = { mids = {}, as = {}, bs = {}, a0 = it.a, b0 = b, sl = sl[kl], sr = sr[kr] }
			end
			table.insert(cur.mids, { x = mx, y = my, z = (pz + qz) / 2 })
			table.insert(cur.as, it.a)
			table.insert(cur.bs, b)
			cur.a1, cur.b1 = it.a, b
		end
	end
	close(endWhy)
	return runs
end

-- The End for a stretch: its frame, the midline through its points (fromPoints, every midline.STEP); origin, dir, z
-- and grade at its start; each track's pieces along it (those reaching into it, in order outward), their nodes and
-- one-way signals projected onto the frame (x from the start). why "left-hand" (with the End all the same) where a
-- signal is against right-hand running: the track right of outward governs outward trains, the left one inward.
local function readEnd(run : Run, frame : PgraceRailRouterMidline.Frame, left : Line, right : Line,
		side : number) : End, string
	local d = frame.dirs[1]
	local e : End = {
		origin = { x = frame.pts[1].x, y = frame.pts[1].y },
		z = frame.pts[1].z,
		grade = midline.grade(frame, 0),
		dir = { x = d.x, y = d.y },
		length = frame.length,
		pieces = { near = {}, far = {} },
		signals = { near = {}, far = {} },
		nodes = { near = {}, far = {} },
		frame = frame,
	}
	-- Each pair's x along the midline (as fromPoints measures it), so that a node whose distance along its line the
	-- pairs straddle takes its x from them: projecting each onto the frame would cost a search of the whole midline.
	local xs : {number} = { 0 }
	for i = 2, #run.mids do
		local p, q = run.mids[i - 1], run.mids[i]
		xs[i] = xs[i - 1] + math.sqrt((q.x - p.x) ^ 2 + (q.y - p.y) ^ 2)
	end
	local function xOf(arcs : {number}, a : number) : number
		if a == nil or a < arcs[1] - EPS or a > arcs[#arcs] + EPS then
			return nil
		end
		local lo, hi = 1, #arcs
		while hi - lo > 1 do
			local m = math.floor((lo + hi) / 2)
			if arcs[m] <= a then
				lo = m
			else
				hi = m
			end
		end
		local span = arcs[hi] - arcs[lo]
		local u = span > EPS and math.max(0, math.min(1, (a - arcs[lo]) / span)) or 0
		return xs[lo] + (xs[hi] - xs[lo]) * u
	end
	local why : string = nil
	local function add(ln : Line, arcs : {number}, a0 : number, a1 : number, isLeft : boolean)
		local name = (isLeft == (side > 0)) and "near" or "far"
		for k, l in ipairs(ln.walk.links) do
			local s = k == 1 and 0 or ln.nodeArc[k - 1]
			local f = ln.nodeArc[k] or math.huge
			if s ~= nil and s < a1 - EPS and f > a0 + EPS then
				table.insert(e.pieces[name], l.piece)
				-- The inner node (behind the start on the first link) and the outer one, by their distances along the line.
				local ends : {number} = { k > 1 and s or nil, ln.nodeArc[k] }
				local inner = l.dir > 0 and l.piece.p0 or l.piece.p1
				local outer = l.dir > 0 and l.piece.p1 or l.piece.p0
				for j, p in ipairs({ inner, outer }) do
					local x = xOf(arcs, ends[j]) or midline.project(frame, { x = p.x, y = p.y })
					local seen = false
					for __, n in ipairs(e.nodes[name]) do
						seen = seen or math.abs(n - x) < 1e-6
					end
					if not seen then
						table.insert(e.nodes[name], x)
					end
				end
				for __, sig in ipairs(l.piece.signals or {}) do
					if (sig[2] * l.dir > 0) == isLeft then
						why = "left-hand"
					end
					local x, y = hermite(l.piece, sig[1])
					table.insert(e.signals[name], (midline.project(frame, { x = x, y = y })))
				end
			end
		end
	end
	add(left, run.as, run.a0, run.a1, true)
	add(right, run.bs, run.b0, run.b1, false)
	table.sort(e.signals.near)
	table.sort(e.signals.far)
	table.sort(e.nodes.near)
	table.sort(e.nodes.far)
	return e, why
end

-- Per end, the stretches of plain double track out to REACH. The reading starts at the first x along the axis (in
-- STEP steps from the end nodes) where two straight tracks begin (see startAt): until then it's the station's fan. If
-- the tracks behind that start lead anywhere but the station (see `fromStation`), nothing is read ("short"). From
-- there each track is walked outward through curves (see `walk`), and the stretches are read off the pair (see `pair`):
-- past a bridge or tunnel, a crossover or a drift (a third track, the tracks parting or one rising over the other)
-- the reading carries on along the tracks, and a stretch starts again where the pair holds again; any other switch
-- (a scissors crossover's four-piece node among them), the track's end or REACH ends it.
function existing.analyse(station : Station, snap : Snapshot, side : {integer : number}, radius : number) : Result
	local result : Result = { ends = {}, why = {}, longest = {}, stretches = {} }
	local needed = junction.needed(radius)
	local len = math.sqrt(station.dir.x * station.dir.x + station.dir.y * station.dir.y)
	local ix : Index = nil
	for __, k in ipairs({ 1, -1 }) do
		local ox, oy = k * station.dir.x / len, k * station.dir.y / len
		local ex, ey = station.centre.x + ox * station.half, station.centre.y + oy * station.half
		local c, x = corridor(station, snap, ox, oy, ex, ey)
		local leftFirst, rightFirst, mid : Span, Span, number = nil, nil, nil
		while x <= REACH do
			leftFirst, rightFirst, mid = startAt(c, x)
			if leftFirst ~= nil then
				break
			end
			x = x + STEP
		end
		result.stretches[k] = {}
		if leftFirst == nil then
			result.why[k] = "no double track"
		elseif not fromStation(c, snap, { leftFirst, rightFirst }, mid) then
			result.why[k] = "short"
		else
			ix = ix or index(snap)
			local budget = REACH - x
			local function first(s : Span) : Link
				return { piece = s.piece, dir = s.dir, nodeA = s.nodeA, nodeB = s.nodeB }
			end
			local lw = walk(ix, snap, first(leftFirst), -1, budget)
			local rw = walk(ix, snap, first(rightFirst), 1, budget)
			pairWalks(lw, rw)
			local left = line(lw, (x - leftFirst.xa) / (leftFirst.xb - leftFirst.xa), budget)
			local right = line(rw, (x - rightFirst.xa) / (rightFirst.xb - rightFirst.xa), budget)
			local leftHand = false
			for __, run in ipairs(pair(left, right, ix)) do
				local frame = midline.fromPoints(run.mids, midline.STEP)
				result.longest[k] = math.max(result.longest[k] or 0, frame.length)
				if frame.length >= needed then
					local e, why = readEnd(run, frame, left, right, side and side[k] or 1)
					if why == "left-hand" then
						leftHand = true
					else
						table.insert(result.stretches[k], e)
					end
				end
			end
			result.ends[k] = result.stretches[k][1]
			if result.ends[k] == nil then
				result.why[k] = leftHand and "left-hand" or "short"
			end
		end
	end
	return result
end


-- How far a bare end's nodes may be off the offsets of a layout the line joins (metres).
local BARE_TOLERANCE = 0.5
-- How far apart along the axis a bare end's nodes may be (metres): our tracks' ends are snapped onto them, so a track a
-- module longer than its neighbour (20 m) would make our first edge on it run backwards.
local BARE_STAGGER = 1.0

-- Which layout a bare end's offsets across its axis (descending: left to right) fit, else "other".
local function bareKind(v : {number}) : string
	local function fits(want : {number}) : boolean
		if #v ~= #want then
			return false
		end
		for i, w in ipairs(want) do
			if math.abs(v[i] - w) > BARE_TOLERANCE then
				return false
			end
		end
		return true
	end
	if fits({ 2.5, -2.5 }) then
		return "direct"
	elseif fits({ 5, -5 }) then
		return "island"
	elseif fits({ 7.5, 2.5, -2.5, -7.5 }) then
		return "fan"
	end
	return "other"
end

function existing.bareEnd(station : Station, snap : Snapshot, k : integer) : PgraceRailRouterExisting.Bare, string
	local len = math.sqrt(station.dir.x * station.dir.x + station.dir.y * station.dir.y)
	local ox, oy = k * station.dir.x / len, k * station.dir.y / len
	local at : {integer : PgraceRailRouterNetwork.Pt3} = {}
	-- Each node's piece's direction there, pointing away from the piece (outward, at a free end node), in plan.
	local away : {integer : PgraceRailRouterGeo.Pt} = {}
	local function dirOf(t : PgraceRailRouterNetwork.Pt3, sign : number) : PgraceRailRouterGeo.Pt
		local d = math.sqrt(t.x * t.x + t.y * t.y)
		if d < 1e-9 then
			return nil
		end
		return { x = sign * t.x / d, y = sign * t.y / d }
	end
	for __, p in ipairs(snap.pieces) do
		at[p.node0] = at[p.node0] or p.p0
		at[p.node1] = at[p.node1] or p.p1
		away[p.node0] = away[p.node0] or dirOf(p.t0, -1)
		away[p.node1] = away[p.node1] or dirOf(p.t1, 1)
	end
	local nodes : {PgraceRailRouterNetwork.Pt3} = {}
	local held = 0
	for __, n in ipairs(station.ends) do
		local p = at[n]
		if p ~= nil and (p.x - station.centre.x) * ox + (p.y - station.centre.y) * oy > 0 then
			if snap.degree[n] == 1 then
				table.insert(nodes, { x = p.x, y = p.y, z = p.z, entity = n })
			else
				held = held + 1
			end
		end
	end
	if #nodes == 0 then
		return nil, nil
	elseif held > 0 then
		return nil, "mixed"
	end
	local mid : PgraceRailRouterNetwork.Pt3 = { x = 0, y = 0, z = 0 }
	for __, p in ipairs(nodes) do
		mid.x, mid.y, mid.z = mid.x + p.x / #nodes, mid.y + p.y / #nodes, mid.z + p.z / #nodes
	end
	-- Across: positive to the left of outward.
	local function across(p : PgraceRailRouterNetwork.Pt3) : number
		return (p.y - mid.y) * ox - (p.x - mid.x) * oy
	end
	table.sort(nodes, function(a : PgraceRailRouterNetwork.Pt3, b : PgraceRailRouterNetwork.Pt3) : boolean
		return across(a) > across(b)
	end)
	local v : {number} = {}
	local dirs : {PgraceRailRouterGeo.Pt} = {}
	local lo, hi = math.huge, -math.huge
	for i, p in ipairs(nodes) do
		v[i] = across(p)
		dirs[i] = away[p.entity]
		local along = (p.x - mid.x) * ox + (p.y - mid.y) * oy
		lo, hi = math.min(lo, along), math.max(hi, along)
	end
	local kind = bareKind(v)
	if kind ~= "other" and hi - lo > BARE_STAGGER then
		kind = "staggered"
	end
	return { kind = kind, nodes = nodes, dirs = dirs, mid = mid, out = { x = ox, y = oy } }, nil
end

-- Track ends closer together than this along the station's axis are one end of it (metres): a station with all its
-- ends at one side (a terminus) has no platforms' centre to read.
local MIN_STATION_SPAN = 20.0

-- A station from its track ends: they split into two groups along the line between the two furthest apart; the
-- centre is the midpoint of the groups' centroids, dir the unit vector from one to the other, half half the distance
-- between them. nil (with why) if they don't make two groups.
function existing.stationFromEnds(entity : integer, ends : {PgraceRailRouterNetwork.Pt3}) : Station, string
	if #ends < 2 then
		return nil, "fewer than two track ends"
	end
	local a, b : PgraceRailRouterNetwork.Pt3, PgraceRailRouterNetwork.Pt3 = ends[1], ends[2]
	local far = -1.0
	for i = 1, #ends do
		for j = i + 1, #ends do
			local d = (ends[i].x - ends[j].x) ^ 2 + (ends[i].y - ends[j].y) ^ 2
			if d > far then
				a, b, far = ends[i], ends[j], d
			end
		end
	end
	local len = math.sqrt(far)
	if len < MIN_STATION_SPAN then
		return nil, ("track ends only %.1f m apart"):format(len)
	end
	local ux, uy = (b.x - a.x) / len, (b.y - a.y) / len
	local sums : {{number}} = { { 0, 0, 0 }, { 0, 0, 0 } }
	local ids : {integer} = {}
	for __, e in ipairs(ends) do
		local s = (e.x - a.x) * ux + (e.y - a.y) * uy
		local g = s < len / 2 and 1 or 2
		sums[g][1] = sums[g][1] + e.x
		sums[g][2] = sums[g][2] + e.y
		sums[g][3] = sums[g][3] + 1
		table.insert(ids, e.entity)
	end
	local c1 : PgraceRailRouterGeo.Pt = { x = sums[1][1] / sums[1][3], y = sums[1][2] / sums[1][3] }
	local c2 : PgraceRailRouterGeo.Pt = { x = sums[2][1] / sums[2][3], y = sums[2][2] / sums[2][3] }
	local dx, dy = c2.x - c1.x, c2.y - c1.y
	local d = math.sqrt(dx * dx + dy * dy)
	if d < MIN_STATION_SPAN then
		return nil, ("its ends' groups only %.1f m apart"):format(d)
	end
	return { entity = entity, centre = { x = (c1.x + c2.x) / 2, y = (c1.y + c2.y) / 2 }, dir = { x = dx / d, y = dy / d },
		half = d / 2, ends = ids }, nil
end

return existing
