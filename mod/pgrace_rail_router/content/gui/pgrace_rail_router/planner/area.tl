local grid = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/grid.tl" as PgraceRailRouterGrid

local area : PgraceRailRouterArea = {
	BUILDING_BUFFER = 30.0,
	MIN_MARGIN = 2000.0,
	MAX_CELLS = 250000,
	MAX_CELL = 5000.0,
}

local type Pt = PgraceRailRouterGeo.Pt
local type Town = PgraceRailRouterCorridor.Town
local type Grid = PgraceRailRouterGrid.Grid
local type Box = PgraceRailRouterArea.Box

local function isFinite(x : number) : boolean
	return x == x and x ~= math.huge and x ~= -math.huge
end

function area.box(stops : {Town}, cell : number, margin : number) : Box
	if #stops == 0 then
		return nil
	end
	local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
	for __, stop in ipairs(stops) do
		minX, maxX = math.min(minX, stop.pos.x), math.max(maxX, stop.pos.x)
		minY, maxY = math.min(minY, stop.pos.y), math.max(maxY, stop.pos.y)
	end
	if not (isFinite(minX) and isFinite(maxX) and isFinite(minY) and isFinite(maxY)) then
		return nil
	end
	local pad = math.max(area.MIN_MARGIN, margin * math.max(maxX - minX, maxY - minY))
	minX, maxX, minY, maxY = minX - pad, maxX + pad, minY - pad, maxY + pad
	local nx = math.floor((maxX - minX) / cell) + 1
	local ny = math.floor((maxY - minY) / cell) + 1
	while nx * ny > area.MAX_CELLS and cell < area.MAX_CELL do
		cell = cell * 1.25
		nx = math.floor((maxX - minX) / cell) + 1
		ny = math.floor((maxY - minY) / cell) + 1
	end
	return { minX = minX, minY = minY, maxX = maxX, maxY = maxY, cell = cell, nx = nx, ny = ny }
end

function area.markBox(g : Grid, x0 : number, y0 : number, x1 : number, y1 : number, cells : {boolean})
	local half = g.cell / 2
	if x1 < g.x0 - half or y1 < g.y0 - half or x0 > g.x0 + (g.nx - 1) * g.cell + half
			or y0 > g.y0 + (g.ny - 1) * g.cell + half then
		return
	end
	local ax, ay = grid.cellOf(g, { x = x0, y = y0 })
	local bx, by = grid.cellOf(g, { x = x1, y = y1 })
	for iy = ay, by do
		for ix = ax, bx do
			cells[grid.index(g, ix, iy)] = true
		end
	end
end

function area.markPoint(g : Grid, p : Pt, cells : {boolean})
	if grid.inside(g, p) then
		local ix, iy = grid.cellOf(g, p)
		cells[grid.index(g, ix, iy)] = true
	end
end

function area.markLine(g : Grid, a : Pt, b : Pt, cells : {boolean})
	local dx, dy = b.x - a.x, b.y - a.y
	local length = math.sqrt(dx * dx + dy * dy)
	local steps = math.max(1, math.ceil(length / (g.cell / 2)))
	for k = 0, steps do
		area.markPoint(g, { x = a.x + dx * k / steps, y = a.y + dy * k / steps }, cells)
	end
end

function area.markCurve(g : Grid, p0 : Pt, t0 : Pt, p1 : Pt, t1 : Pt, cells : {boolean})
	local chord = math.sqrt((p1.x - p0.x) ^ 2 + (p1.y - p0.y) ^ 2)
	-- The tangents' lengths are about the curve's length; take the longest so a bent edge is sampled finely enough.
	local length = math.max(chord, math.sqrt(t0.x * t0.x + t0.y * t0.y), math.sqrt(t1.x * t1.x + t1.y * t1.y))
	local steps = math.max(1, math.ceil(length / (g.cell / 2)))
	for k = 0, steps do
		local t = k / steps
		local t2, t3 = t * t, t * t * t
		local h00 = 2 * t3 - 3 * t2 + 1
		local h10 = t3 - 2 * t2 + t
		local h01 = -2 * t3 + 3 * t2
		local h11 = t3 - t2
		area.markPoint(g, { x = h00 * p0.x + h10 * t0.x + h01 * p1.x + h11 * t1.x,
			y = h00 * p0.y + h10 * t0.y + h01 * p1.y + h11 * t1.y }, cells)
	end
end

return area
