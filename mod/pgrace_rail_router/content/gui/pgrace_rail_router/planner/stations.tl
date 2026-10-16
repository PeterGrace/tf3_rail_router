local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo
local grid = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/grid.tl" as PgraceRailRouterGrid

local stations : PgraceRailRouterStations = {}

local type Pt = PgraceRailRouterGeo.Pt
local type Grid = PgraceRailRouterGrid.Grid
local type Site = PgraceRailRouterStations.Site

-- Directions tried at each spot: the wanted one first, then up to 30° either way.
local TURNS : {number} = { 0, math.rad(15), -math.rad(15), math.rad(30), -math.rad(30) }

local function clear(g : Grid, centre : Pt, dir : Pt, runLength : number, maxRelief : number) : boolean
	local step = g.cell / 2
	local lo, hi = math.huge, -math.huge
	local d = -runLength / 2
	while d <= runLength / 2 + 1e-6 do
		local p = geo.add(centre, geo.scale(dir, d))
		if not grid.inside(g, p) then
			return false
		end
		local ix, iy = grid.cellOf(g, p)
		local i = grid.index(g, ix, iy)
		if g.blocked[i] or g.water[i] then
			return false
		end
		local h = grid.heightAt(g, p)
		lo, hi = math.min(lo, h), math.max(hi, h)
		d = d + step
	end
	return hi - lo <= maxRelief
end

function stations.find(g : Grid, town : Pt, dir : Pt, runLength : number, maxRelief : number, maxRadius : number) : Site
	local unit = geo.norm(dir)
	local step = g.cell / 2
	local r = 0.0
	while r <= maxRadius do
		local n : integer = 1
		if r > 0 then
			n = math.floor(math.max(8, 2 * math.pi * r / step))
		end
		for i = 0, n - 1 do
			local angle = 2 * math.pi * i / n
			local centre : Pt = { x = town.x + r * math.cos(angle), y = town.y + r * math.sin(angle) }
			for __, turn in ipairs(TURNS) do
				local d = geo.rotate(unit, turn)
				if clear(g, centre, d, runLength, maxRelief) then
					return { centre = centre, dir = d, distance = r }
				end
			end
		end
		r = r + step
	end
	return nil
end

return stations
