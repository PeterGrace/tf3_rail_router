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
-- A double track: two tracks 4.5–5.5 m apart, whose midline drifts no more than DRIFT from where it started.
local GAP_MIN = 4.5
local GAP_MAX = 5.5
local DRIFT = 0.5
-- The turnout radius a usable stretch must fit a junction at (standard track); the caller checks its own.
local RADIUS = 300.0

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

-- A stretch of double track found by the scan: its start (x), midline (y) and height there, its length, and the
-- spans it crossed, in the order the scan reached them (outward along each track).
local record Stretch
	start : number
	mid : number
	z : number
	length : number
	spans : {Span}
	seen : {Span : boolean}
end

-- The pieces near end k's axis (both ends 0 ≤ x ≤ REACH, |y| ≤ WIDE) that the station's end nodes reach over such
-- pieces, in the frame: x outward from the platform end, y to the left.
local function nearSpans(station : Station, snap : Snapshot, ox : number, oy : number, ex : number,
		ey : number) : {Span}
	local atNode : {integer : {Span}} = {}
	for __, p in ipairs(snap.pieces) do
		local x0 = (p.p0.x - ex) * ox + (p.p0.y - ey) * oy
		local y0 = (p.p0.y - ey) * ox - (p.p0.x - ex) * oy
		local x1 = (p.p1.x - ex) * ox + (p.p1.y - ey) * oy
		local y1 = (p.p1.y - ey) * ox - (p.p1.x - ex) * oy
		if math.min(x0, x1) >= -1 and math.max(x0, x1) <= REACH and math.abs(y0) <= WIDE and math.abs(y1) <= WIDE then
			local s : Span
			if x1 >= x0 then
				s = { piece = p, xa = x0, ya = y0, za = p.p0.z, xb = x1, yb = y1, zb = p.p1.z,
					nodeA = p.node0, nodeB = p.node1, dir = 1 }
			else
				s = { piece = p, xa = x1, ya = y1, za = p.p1.z, xb = x0, yb = y0, zb = p.p0.z,
					nodeA = p.node1, nodeB = p.node0, dir = -1 }
			end
			for __, n in ipairs({ p.node0, p.node1 }) do
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
	return out
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

-- At x, two ground pieces 4.5–5.5 m apart: their midline and height; nil otherwise.
local function double(cross : {Span}, x : number) : number, number
	if #cross ~= 2 or cross[1].piece.kind ~= "ground" or cross[2].piece.kind ~= "ground" then
		return nil, nil
	end
	local y1, z1 = at(cross[1], x)
	local y2, z2 = at(cross[2], x)
	local gap = math.abs(y1 - y2)
	if gap < GAP_MIN or gap > GAP_MAX then
		return nil, nil
	end
	return (y1 + y2) / 2, (z1 + z2) / 2
end

-- Every stretch of plain double track along the spans, scanning outward in STEP steps. A stretch starts where both
-- tracks' pieces lead on to plain nodes (degree 2: past the station's switches), and runs on while the two tracks
-- stay on the ground, 4.5–5.5 m apart, along the axis, through plain nodes. It ends at the node where that breaks,
-- or at the last step it held.
local function stretches(spans : {Span}, snap : Snapshot) : {Stretch}
	local out : {Stretch} = {}
	local cur : Stretch = nil
	local last : {Span} = {}
	local x = 0.0
	while true do
		local cross = crossing(spans, x)
		local mid, z = double(cross, x)
		if cur then
			local good = mid ~= nil and math.abs(mid - cur.mid) <= DRIFT
			if good then
				for __, s in ipairs(cross) do
					if s.xa > cur.start + EPS and snap.degree[s.nodeA] ~= 2 then
						good = false
					end
				end
			end
			if good then
				last = cross
				for __, s in ipairs(cross) do
					if not cur.seen[s] then
						cur.seen[s] = true
						table.insert(cur.spans, s)
					end
				end
			else
				local nodeX = math.huge
				for __, s in ipairs(last) do
					nodeX = math.min(nodeX, s.xb)
				end
				cur.length = (nodeX <= x + EPS and nodeX or x - STEP) - cur.start
				table.insert(out, cur)
				cur = nil
			end
		end
		if x > REACH then
			break
		end
		if not cur and mid ~= nil and snap.degree[cross[1].nodeB] == 2 and snap.degree[cross[2].nodeB] == 2 then
			cur = { start = x, mid = mid, z = z, length = 0, spans = { cross[1], cross[2] },
				seen = { [cross[1]] = true, [cross[2]] = true } }
			last = cross
		end
		x = x + STEP
	end
	return out
end

-- The usable end along a stretch, or nil and why: its signals must keep right-hand running (the track right of
-- outward governs outward trains, the left one inward trains).
local function readEnd(st : Stretch, side : number, ox : number, oy : number, ex : number, ey : number) : End, string
	local e : End = {
		origin = { x = ex + ox * st.start - oy * st.mid, y = ey + oy * st.start + ox * st.mid },
		z = st.z,
		dir = { x = ox, y = oy },
		length = st.length,
		pieces = { near = {}, far = {} },
		signals = { near = {}, far = {} },
	}
	for __, s in ipairs(st.spans) do
		local left = (s.ya + s.yb) / 2 > st.mid
		local track = (left == (side > 0)) and "near" or "far"
		table.insert(e.pieces[track], s.piece)
		for __, sig in ipairs(s.piece.signals or {}) do
			local outward = sig[2] * s.dir > 0
			if outward == left then
				return nil, "left-hand"
			end
			local f = s.dir > 0 and sig[1] or 1 - sig[1]
			table.insert(e.signals[track], s.xa + (s.xb - s.xa) * f - st.start)
		end
	end
	table.sort(e.signals.near)
	table.sort(e.signals.far)
	return e, nil
end

function existing.analyse(station : Station, snap : Snapshot, side : {integer : number}) : Result
	local result : Result = { ends = {}, why = {} }
	local needed = junction.needed(RADIUS)
	for __, k in ipairs({ 1, -1 }) do
		local ox, oy = k * station.dir.x, k * station.dir.y
		local ex, ey = station.centre.x + ox * station.half, station.centre.y + oy * station.half
		local found = stretches(nearSpans(station, snap, ox, oy, ex, ey), snap)
		local chosen : Stretch = nil
		for __, st in ipairs(found) do
			if not chosen and st.length >= needed then
				chosen = st
			end
		end
		if chosen then
			result.ends[k], result.why[k] = readEnd(chosen, side and side[k] or 1, ox, oy, ex, ey)
		else
			result.why[k] = #found > 0 and "short" or "no double track"
		end
	end
	return result
end

return existing
