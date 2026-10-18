local junction = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/junction.tl" as PgraceRailRouterJunction

local existing : PgraceRailRouterExisting = {}

local type Piece = PgraceRailRouterExisting.Piece
local type Snapshot = PgraceRailRouterExisting.Snapshot
local type Station = PgraceRailRouterExisting.Station
local type End = PgraceRailRouterExisting.End
local type Result = PgraceRailRouterExisting.Result

-- How far out from the platform end, and how far across the axis, the approach is looked for (metres).
local REACH = 1500.0
local WIDE = 12.0
local STEP = 5.0
local EPS = 1e-6
-- A double track: two tracks 4.5–5.5 m apart, whose midline and height drift no more than DRIFT from the start.
local GAP_MIN = 4.5
local GAP_MAX = 5.5
local DRIFT = 0.5
-- A straight, level piece: each tangent's sideways share (|t × outward| / |t|) and upward share at most this.
local SIDEWAYS = 0.005
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

-- A stretch of double track: its start (x), midline (y) and height there, its length, each track's spans in order
-- outward (left: left of outward) and the two pieces it starts on, and why it ended ("stop", or "structure",
-- "drift" or "crossover", past which the scan reads on).
local record Stretch
	start : number
	mid : number
	z : number
	length : number
	left : {Span}
	right : {Span}
	firsts : {Span}
	why : string
end

-- The pieces near end k's axis that the station's end nodes reach over such pieces, in the frame: x outward from
-- the platform end, y to the left. Near means |y| ≤ WIDE, x up to REACH and no further back than the end nodes
-- (less 1 m); returns the corridor and the end nodes' smallest x, where the scan starts.
local function corridor(station : Station, snap : Snapshot, ox : number, oy : number, ex : number,
		ey : number) : Corridor, number
	local all : {Span} = {}
	local isEnd : {integer : boolean} = {}
	for __, n in ipairs(station.ends) do
		isEnd[n] = true
	end
	local lo = math.huge
	for __, p in ipairs(snap.pieces) do
		local x0 = (p.p0.x - ex) * ox + (p.p0.y - ey) * oy
		local y0 = (p.p0.y - ey) * ox - (p.p0.x - ex) * oy
		local x1 = (p.p1.x - ex) * ox + (p.p1.y - ey) * oy
		local y1 = (p.p1.y - ey) * ox - (p.p1.x - ex) * oy
		if math.min(x0, x1) >= -station.half and math.max(x0, x1) <= REACH and math.abs(y0) <= WIDE
				and math.abs(y1) <= WIDE then
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

-- Both tangents along the axis and level: a piece that bulges or kinks, sideways or up, isn't straight, whatever its
-- chord.
local function straight(p : Piece, ox : number, oy : number) : boolean
	for __, tg in ipairs({ p.t0, p.t1 }) do
		local len = math.sqrt(tg.x * tg.x + tg.y * tg.y + tg.z * tg.z)
		if len < EPS or math.abs(tg.x * oy - tg.y * ox) / len > SIDEWAYS or math.abs(tg.z) / len > SIDEWAYS then
			return false
		end
	end
	return true
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

-- One track outward from `first`, piece by piece through plain nodes (degree 2). Ends at the first node that isn't
-- plain ("switch" for degree 3, else "stop"), or where the next piece leaves the corridor or turns back ("stop"),
-- isn't on the ground ("structure") or isn't straight ("drift"). Returns the track's spans and where it ends.
local function walk(c : Corridor, snap : Snapshot, first : Span) : {Span}, number, string
	local list : {Span} = { first }
	local s = first
	while true do
		local n = s.nodeB
		local degree = snap.degree[n]
		if degree ~= 2 then
			return list, s.xb, degree == 3 and "switch" or "stop"
		end
		local nxt = onward(c, n, s)
		if not nxt or nxt.nodeA ~= n then
			return list, s.xb, "stop"
		end
		if nxt.piece.kind ~= "ground" then
			return list, s.xb, "structure"
		end
		if not straight(nxt.piece, c.ox, c.oy) then
			return list, s.xb, "drift"
		end
		table.insert(list, nxt)
		s = nxt
	end
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

-- Whether the switch where `came` ends is one side of a crossover: of its other two pieces, one carries on along
-- the track's line, and the other leads across (see `across`) to the other track.
local function crossover(c : Corridor, snap : Snapshot, came : Span, mid : number) : boolean
	local n, y = came.nodeB, came.yb
	local on, off = 0, {}
	for __, o in ipairs(c.atNode[n] or {}) do
		if o ~= came then
			local yo = o.nodeA == n and o.yb or o.ya
			if math.abs(yo - y) <= ON_LINE then
				on = on + 1
			else
				table.insert(off, o)
			end
		end
	end
	return on == 1 and #off == 1 and across(c, snap, n, off[1], y, mid)
end

-- Whether the track behind the pieces `firsts` comes only from the station: walking inward from them through the
-- corridor, every way back ends at a station end node. On the way, a node may join two inward pieces (a fan's
-- merge), or split towards the station only where one of its outward pieces leads across to the other track (a
-- crossover). A piece leaving the corridor (a branch, a siding or another line coming in), a dead end or any other
-- switch means the stretch belongs to more than the station's own tracks.
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
			if #outward == 2 and not across(c, snap, n, outward[1], s.ya, mid)
					and not across(c, snap, n, outward[2], s.ya, mid) then
				return false
			end
			for __, o in ipairs(inward) do
				table.insert(stack, o)
			end
		end
	end
	return true
end

-- The span of a track's list at x (the inner one at a node).
local function onTrack(list : {Span}, x : number) : Span
	for __, s in ipairs(list) do
		if s.xa - EPS <= x and x <= s.xb + EPS then
			return s
		end
	end
	return nil
end

-- A stretch starting at x, if one does: exactly two pieces cross x, on the ground, straight and 4.5–5.5 m apart.
-- Each track is walked outward through plain nodes (see `walk`); the stretch ends where the first track does. Then
-- every STEP and at every node on the way, the two tracks must stay the only ones crossing, 4.5–5.5 m apart, with
-- midline and height within DRIFT of the start's; where that fails, the stretch ends at the point checked before
-- ("drift").
local function stretchAt(c : Corridor, snap : Snapshot, x : number) : Stretch
	local cross = crossing(c.spans, x)
	if #cross ~= 2 then
		return nil
	end
	for __, s in ipairs(cross) do
		if s.piece.kind ~= "ground" or not straight(s.piece, c.ox, c.oy) then
			return nil
		end
	end
	local y1, z1 = at(cross[1], x)
	local y2, z2 = at(cross[2], x)
	if math.abs(y1 - y2) < GAP_MIN or math.abs(y1 - y2) > GAP_MAX then
		return nil
	end
	local leftFirst, rightFirst = cross[1], cross[2]
	if y2 > y1 then
		leftFirst, rightFirst = cross[2], cross[1]
	end
	local mid, z0 = (y1 + y2) / 2, (z1 + z2) / 2
	local left, leftEnd, leftWhy = walk(c, snap, leftFirst)
	local right, rightEnd, rightWhy = walk(c, snap, rightFirst)
	local stop = math.min(leftEnd, rightEnd)
	local why : string = nil
	for __, track in ipairs({ { left, leftEnd, leftWhy }, { right, rightEnd, rightWhy } }) do
		local list, e, w = track[1] as {Span}, track[2] as number, track[3] as string
		if e <= stop + EPS then
			if w == "switch" then
				w = crossover(c, snap, list[#list], mid) and "crossover" or "stop"
			end
			if not why or w == "stop" then
				why = w
			end
		end
	end
	local points : {number} = {}
	local p = x
	while p < stop - EPS do
		table.insert(points, p)
		p = p + STEP
	end
	for __, list in ipairs({ left, right }) do
		for __, s in ipairs(list) do
			if s.xb > x + EPS and s.xb < stop - EPS then
				table.insert(points, s.xb)
			end
		end
	end
	table.insert(points, stop)
	table.sort(points)
	local prev = x
	for __, q in ipairs(points) do
		local l, r = onTrack(left, q), onTrack(right, q)
		local good = l ~= nil and r ~= nil and (q >= stop - EPS or #crossing(c.spans, q) == 2)
		if good then
			local yl, zl = at(l, q)
			local yr, zr = at(r, q)
			good = yl - yr >= GAP_MIN and yl - yr <= GAP_MAX and math.abs((yl + yr) / 2 - mid) <= DRIFT
				and math.abs(zl - z0) <= DRIFT and math.abs(zr - z0) <= DRIFT
		end
		if not good then
			stop, why = prev, "drift"
			break
		end
		prev = q
	end
	local function upTo(list : {Span}) : {Span}
		local out : {Span} = {}
		for __, s in ipairs(list) do
			if s.xa < stop - EPS then
				table.insert(out, s)
			end
		end
		return out
	end
	return { start = x, mid = mid, z = z0, length = stop - x, left = upTo(left), right = upTo(right),
		firsts = { leftFirst, rightFirst }, why = why }
end

-- The usable end along a stretch, or nil and why: its one-way signals must keep right-hand running (the track
-- right of outward governs outward trains, the left one inward trains).
local function readEnd(st : Stretch, side : number, ox : number, oy : number, ex : number, ey : number) : End, string
	local e : End = {
		origin = { x = ex + ox * st.start - oy * st.mid, y = ey + oy * st.start + ox * st.mid },
		z = st.z,
		dir = { x = ox, y = oy },
		length = st.length,
		pieces = { near = {}, far = {} },
		signals = { near = {}, far = {} },
	}
	for __, track in ipairs({ { st.left, true }, { st.right, false } }) do
		local list, left = track[1] as {Span}, track[2] as boolean
		local name = (left == (side > 0)) and "near" or "far"
		for __, s in ipairs(list) do
			table.insert(e.pieces[name], s.piece)
			for __, sig in ipairs(s.piece.signals or {}) do
				if (sig[2] * s.dir > 0) == left then
					return nil, "left-hand"
				end
				local f = s.dir > 0 and sig[1] or 1 - sig[1]
				table.insert(e.signals[name], s.xa + (s.xb - s.xa) * f - st.start)
			end
		end
	end
	table.sort(e.signals.near)
	table.sort(e.signals.far)
	return e, nil
end

-- Per end, scans outward from the end nodes for the first stretch at least junction.needed(radius) long. Until two
-- tracks are the only ones (the station's fan) nothing starts. Past a stretch that's too short the scan reads on
-- only if it ended at a bridge or tunnel, a drift (a bend, a grade, a third track) or a crossover; any other
-- switch, the track's end or single track stop it ("short"). Every stretch's tracks must come only from the station
-- (see `fromStation`), so one past a switch the scan stepped over (between stretches, or a track joining before
-- the first) stops it too ("short").
function existing.analyse(station : Station, snap : Snapshot, side : {integer : number}, radius : number) : Result
	local result : Result = { ends = {}, why = {} }
	local needed = junction.needed(radius)
	local len = math.sqrt(station.dir.x * station.dir.x + station.dir.y * station.dir.y)
	for __, k in ipairs({ 1, -1 }) do
		local ox, oy = k * station.dir.x / len, k * station.dir.y / len
		local ex, ey = station.centre.x + ox * station.half, station.centre.y + oy * station.half
		local c, x = corridor(station, snap, ox, oy, ex, ey)
		local found = 0
		local chosen : Stretch = nil
		while x <= REACH do
			local st = stretchAt(c, snap, x)
			if st then
				found = found + 1
				if not fromStation(c, snap, st.firsts, st.mid) then
					break
				end
				if st.length >= needed then
					chosen = st
					break
				end
				if st.why == "stop" then
					break
				end
				x = math.max(st.start + st.length, x + STEP)
			else
				x = x + STEP
			end
		end
		if chosen then
			result.ends[k], result.why[k] = readEnd(chosen, side and side[k] or 1, ox, oy, ex, ey)
		else
			result.why[k] = found > 0 and "short" or "no double track"
		end
	end
	return result
end

return existing
