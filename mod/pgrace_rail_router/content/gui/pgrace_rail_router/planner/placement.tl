local midline = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/midline.tl" as PgraceRailRouterMidline

local placement : PgraceRailRouterPlacement = {}

local type Hermite = PgraceRailRouterNetwork.Hermite
local type Frame = PgraceRailRouterMidline.Frame
local type Layout = PgraceRailRouterJunction.Layout

function placement.mapPiece(f : Frame, p : PgraceRailRouterJunction.Piece) : Hermite
	return { p0 = midline.world(f, p.x0, p.y0), p1 = midline.world(f, p.x1, p.y1),
		t0 = midline.vector(f, p.x0, p.tx0, p.ty0), t1 = midline.vector(f, p.x1, p.tx1, p.ty1) }
end

local SAMPLES = 64

function placement.tightest(h : Hermite) : number
	local best = math.huge
	for i = 0, SAMPLES do
		local t = i / SAMPLES
		-- First and second derivatives of the cubic Hermite in plan.
		local d1a, d1b, d1c, d1d = 6 * t * t - 6 * t, 3 * t * t - 4 * t + 1, -6 * t * t + 6 * t, 3 * t * t - 2 * t
		local d2a, d2b, d2c, d2d = 12 * t - 6, 6 * t - 4, -12 * t + 6, 6 * t - 2
		local dx = d1a * h.p0.x + d1b * h.t0.x + d1c * h.p1.x + d1d * h.t1.x
		local dy = d1a * h.p0.y + d1b * h.t0.y + d1c * h.p1.y + d1d * h.t1.y
		local ex = d2a * h.p0.x + d2b * h.t0.x + d2c * h.p1.x + d2d * h.t1.x
		local ey = d2a * h.p0.y + d2b * h.t0.y + d2c * h.p1.y + d2d * h.t1.y
		local cross = math.abs(dx * ey - dy * ex)
		if cross > 1e-9 then
			best = math.min(best, (dx * dx + dy * dy) ^ 1.5 / cross)
		end
	end
	return best
end

function placement.rayRoom(f : Frame, approachX : number, side : number, offset : number, slack : number,
		cell : number) : number
	local start = midline.world(f, approachX, offset * side)
	local __, out = midline.at(f, approachX)
	local d = 0.0
	for i = math.floor(approachX / f.step) + 2, #f.pts do
		local p = f.pts[i]
		local rx, ry = p.x - start.x, p.y - start.y
		local along = rx * out.x + ry * out.y
		-- The midline's offset from the ray towards our side: −offset where they run parallel.
		local across = (out.x * ry - out.y * rx) * side
		if across > -(offset - slack) or across < -cell or along <= d then
			break
		end
		d = along
	end
	return d
end

function placement.accept(f : Frame, side : number, o : PgraceRailRouterPlacement.Options) : function(Layout) : boolean
	return function(j : Layout) : boolean
		for __, p in ipairs(j.pieces) do
			if placement.tightest(placement.mapPiece(f, p)) < o.minRadius then
				return false
			end
		end
		return placement.rayRoom(f, j.approachX, side, o.offset, o.slack, o.cell) >= o.straight - 1e-6
	end
end

return placement
