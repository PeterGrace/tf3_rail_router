local junction : PgraceRailRouterJunction = {}

local type Layout = PgraceRailRouterJunction.Layout
local type Piece = PgraceRailRouterJunction.Piece

-- Every cut stays this far from the stretch's start, and the junction's whole span this far from existing signals
-- (metres): the clearance our own signals keep from edge ends (a signal 3 m from a node collided with track joined
-- there). A signal stands beside its track, so one between the cuts lies under a junction piece leaving or meeting
-- that track: Aloha's cross-in piece, with a block signal 19 m before its crossing, was refused at build time.
local CLEAR = 15.0
local GAP = 20.0
local APPROACH = 30.0
local STEP = 5.0
-- What each crossing arc climbs: the far track (−2.5) to the crossing node (+2.5), and on to our near track (+7.5).
local CLIMB = 5.0

function junction.sCurve(offset : number, radius : number) : number
	return math.max(40, 5 * math.floor(math.sqrt(4 * radius * offset) / 5 + 0.5))
end

function junction.crossAngle(radius : number) : number
	return math.acos(1 - CLIMB / radius)
end

function junction.crossRun(radius : number) : number
	return radius * math.sin(junction.crossAngle(radius))
end

function junction.needed(radius : number) : number
	return junction.sCurve(10, radius) + 2 * junction.crossRun(radius) + GAP + APPROACH + 2 * CLEAR
end

-- No signal within CLEAR of the span x0..x1.
local function clear(x0 : number, x1 : number, signals : {number}) : boolean
	for __, s in ipairs(signals or {}) do
		if s > x0 - CLEAR and s < x1 + CLEAR then
			return false
		end
	end
	return true
end

-- A piece from (x0, y0) to (x1, y1) on side +1, its tangents at angles a0, a1 to x and `len` long; mirrored by side.
local function piece(x0 : number, y0 : number, x1 : number, y1 : number, a0 : number, a1 : number, len : number,
		side : number, role : string) : Piece
	return {
		x0 = x0, y0 = y0 * side, x1 = x1, y1 = y1 * side,
		tx0 = math.cos(a0) * len, ty0 = math.sin(a0) * len * side,
		tx1 = math.cos(a1) * len, ty1 = math.sin(a1) * len * side,
		role = role,
	}
end

-- The game refuses a switch whose main track on the branch's side is 16.6 m or shorter (18 m passed): a switch cut
-- keeps every existing node within SWITCH_CLEAR outward of it, and SLIVER behind it, away; one within SNAP of it is
-- used as the switch (the cut moves onto it). A crossing cut keeps nodes SLIVER away, but one at its very place
-- (within EXACT), which then is the crossing node.
local SWITCH_CLEAR = 20.0
local SLIVER = 3.0
local SNAP = 0.5
local EXACT = 0.01

-- Where a switch cut at x goes on a track with nodes at `nodes`: x, or the node within SNAP of it; nil if another
-- node lies in (x − SLIVER, x + SWITCH_CLEAR].
local function switchAt(x : number, nodes : {number}) : number
	local at = x
	for __, n in ipairs(nodes) do
		if n > x - SLIVER and n <= x + SWITCH_CLEAR then
			if math.abs(n - x) <= SNAP then
				at = n
			else
				return nil
			end
		end
	end
	return at
end

local function crossingClear(x : number, nodes : {number}) : boolean
	for __, n in ipairs(nodes) do
		if math.abs(n - x) <= SLIVER and math.abs(n - x) > EXACT then
			return false
		end
	end
	return true
end

-- Every junction piece passes each existing node (and each other cut) at least this far away, but the nodes it starts
-- or ends on (within END of them): P17 had a merge refused ("Construction Not Possible") passing a joint of its own
-- track 1.32 m beside it, and clean at 1.97 m; a crossing piece passed one 1.60 m beside it.
local BESIDE = 2.0
local END = 0.5

local function hermite(p : Piece, t : number) : number, number
	local t2, t3 = t * t, t * t * t
	local a, b, c, d = 2 * t3 - 3 * t2 + 1, t3 - 2 * t2 + t, -2 * t3 + 3 * t2, t3 - t2
	return a * p.x0 + b * p.tx0 + c * p.x1 + d * p.tx1, a * p.y0 + b * p.ty0 + c * p.y1 + d * p.ty1
end

-- No piece passes a point (pxs[k], pys[k], k ≤ count) within BESIDE, but at its own ends. Samples and points go in
-- tables kept between calls (the fit runs in the planner's steps, which keep allocation down).
local N = 64
local xs, ys, pxs, pys : {number}, {number}, {number}, {number} = {}, {}, {}, {}
local function besideClear(pieces : {Piece}, count : integer) : boolean
	for __, p in ipairs(pieces) do
		for i = 0, N do
			xs[i], ys[i] = hermite(p, i / N)
		end
		local lo, hi = math.min(p.x0, p.x1) - BESIDE, math.max(p.x0, p.x1) + BESIDE
		for k = 1, count do
			local qx, qy = pxs[k], pys[k]
			if qx > lo and qx < hi and (qx - p.x0) ^ 2 + (qy - p.y0) ^ 2 > END * END
					and (qx - p.x1) ^ 2 + (qy - p.y1) ^ 2 > END * END then
				for i = 1, N do
					local ax, ay = xs[i - 1], ys[i - 1]
					local dx, dy = xs[i] - ax, ys[i] - ay
					local len2 = dx * dx + dy * dy
					local u = len2 > 0 and math.max(0, math.min(1, ((qx - ax) * dx + (qy - ay) * dy) / len2)) or 0
					if (ax + u * dx - qx) ^ 2 + (ay + u * dy - qy) ^ 2 < BESIDE * BESIDE then
						return false
					end
				end
			end
		end
	end
	return true
end

function junction.fit(length : number, radius : number, side : number, signals : {string : {number}},
		nodes ?: {string : {number}}, accept ?: function(Layout) : boolean) : Layout
	local l = junction.sCurve(10, radius)
	local theta = junction.crossAngle(radius)
	local c = junction.crossRun(radius)
	local arc = radius * theta
	local near : {number} = nodes and nodes.near or {}
	local far : {number} = nodes and nodes.far or {}
	-- The merge's switch positions to try, nearest the stretch's start first: every STEP from CLEAR, and those that
	-- put a cut on an existing node (the merge's switch, the crossing on the near track, the far switch).
	local tries : {number} = {}
	local m = CLEAR
	while m + l + GAP + 2 * c + APPROACH + CLEAR <= length + 1e-9 do
		table.insert(tries, m)
		m = m + STEP
	end
	for __, n in ipairs(near) do
		table.insert(tries, n)
		table.insert(tries, n - c - GAP - l)
	end
	for __, n in ipairs(far) do
		table.insert(tries, n - GAP - l)
	end
	table.sort(tries)
	for __, try in ipairs(tries) do
		if try >= CLEAR - 1e-9 and try + l + GAP + 2 * c + APPROACH + CLEAR <= length + 1e-9 then
			local c0 = try + l + GAP
			local crossing = c0 + c
			local ms, cs = switchAt(try, near), switchAt(c0, far)
			-- Signals on either track clear of everything from the merge's switch to the cross-out piece's end.
			if ms ~= nil and cs ~= nil and crossingClear(crossing, near) and clear(ms, c0 + 2 * c, signals.near)
					and clear(ms, c0 + 2 * c, signals.far) then
				local layout : Layout = {
					approachX = c0 + 2 * c + APPROACH,
					pieces = {
						piece(ms, 2.5, try + l, 12.5, 0, 0, try + l - ms, side, "merge"),
						piece(cs, -2.5, crossing, 2.5, 0, theta, arc, side, "cross in"),
						piece(crossing, 2.5, c0 + 2 * c, 7.5, theta, 0, arc, side, "cross out"),
					},
					cuts = {
						{ track = "near", x = ms, kind = "switch" },
						{ track = "near", x = crossing, kind = "crossing" },
						{ track = "far", x = cs, kind = "switch" },
					},
				}
				-- Each track's nodes and the cuts, as points in the frame (the near track at y = 2.5 side).
				local count = 0
				for __, n in ipairs(near) do
					count = count + 1
					pxs[count], pys[count] = n, 2.5 * side
				end
				for __, n in ipairs(far) do
					count = count + 1
					pxs[count], pys[count] = n, -2.5 * side
				end
				for __, c in ipairs(layout.cuts) do
					count = count + 1
					pxs[count], pys[count] = c.x, (c.track == "near" and 2.5 or -2.5) * side
				end
				if besideClear(layout.pieces, count) and (accept == nil or accept(layout)) then
					return layout
				end
			end
		end
	end
	return nil
end

return junction
