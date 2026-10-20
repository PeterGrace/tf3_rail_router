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
				if accept == nil or accept(layout) then
					return layout
				end
			end
		end
	end
	return nil
end

return junction
