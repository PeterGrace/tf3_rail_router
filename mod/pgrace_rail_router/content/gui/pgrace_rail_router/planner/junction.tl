local junction : PgraceRailRouterJunction = {}

local type Layout = PgraceRailRouterJunction.Layout
local type Piece = PgraceRailRouterJunction.Piece

-- Every cut stays this far from existing signals and from the stretch's start (metres): the clearance our own
-- signals keep from edge ends (a signal 3 m from a node collided with track joined there).
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

local function clear(x : number, signals : {number}) : boolean
	for __, s in ipairs(signals) do
		if math.abs(x - s) < CLEAR then
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

function junction.fit(length : number, radius : number, side : number, signals : {string : {number}}) : Layout
	local l = junction.sCurve(10, radius)
	local theta = junction.crossAngle(radius)
	local c = junction.crossRun(radius)
	local arc = radius * theta
	local m = CLEAR
	while m + l + GAP + 2 * c + APPROACH + CLEAR <= length + 1e-9 do
		local c0 = m + l + GAP
		local crossing = c0 + c
		if clear(m, signals.near) and clear(crossing, signals.near) and clear(c0, signals.far) then
			return {
				approachX = c0 + 2 * c + APPROACH,
				pieces = {
					piece(m, 2.5, m + l, 12.5, 0, 0, l, side, "merge"),
					piece(c0, -2.5, crossing, 2.5, 0, theta, arc, side, "cross in"),
					piece(crossing, 2.5, c0 + 2 * c, 7.5, theta, 0, arc, side, "cross out"),
				},
				cuts = {
					{ track = "near", x = m, kind = "switch" },
					{ track = "near", x = crossing, kind = "crossing" },
					{ track = "far", x = c0, kind = "switch" },
				},
			}
		end
		m = m + STEP
	end
	return nil
end

return junction
