local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo

local corridor : PgraceRailRouterCorridor = {}

local type Pt = PgraceRailRouterGeo.Pt
local type Town = PgraceRailRouterCorridor.Town
local type Candidate = PgraceRailRouterCorridor.Candidate

-- Where p projects onto the line from a to b: 0 at a, 1 at b (can fall outside 0..1).
local function along(a : Pt, b : Pt, p : Pt) : number
	local ab = geo.sub(b, a)
	local l2 = geo.dot(ab, ab)
	if l2 < 1e-9 then
		return 0
	end
	return geo.dot(geo.sub(p, a), ab) / l2
end

function corridor.candidates(a : Town, b : Town, towns : {Town}, budget : number) : {Candidate}
	local direct = geo.dist(a.pos, b.pos)
	local result : {Candidate} = {}
	for __, town in ipairs(towns) do
		if town.id ~= a.id and town.id ~= b.id then
			local detour = geo.dist(a.pos, town.pos) + geo.dist(town.pos, b.pos) - direct
			local t = along(a.pos, b.pos, town.pos)
			if detour <= budget * direct and t > 0 and t < 1 then
				table.insert(result, { town = town, detour = detour, along = t })
			end
		end
	end
	table.sort(result, function(x : Candidate, y : Candidate) : boolean
		if x.along ~= y.along then
			return x.along < y.along
		end
		return x.town.id < y.town.id
	end)
	return result
end

function corridor.order(a : Town, b : Town, picked : {Town}) : {Town}
	local middle : {Town} = {}
	for __, town in ipairs(picked) do
		if town.id ~= a.id and town.id ~= b.id then
			table.insert(middle, town)
		end
	end
	local alongById : {integer:number} = {}
	for __, town in ipairs(middle) do
		alongById[town.id] = along(a.pos, b.pos, town.pos)
	end
	table.sort(middle, function(x : Town, y : Town) : boolean
		if alongById[x.id] ~= alongById[y.id] then
			return alongById[x.id] < alongById[y.id]
		end
		return x.id < y.id
	end)
	local stops : {Town} = { a }
	for __, town in ipairs(middle) do
		table.insert(stops, town)
	end
	table.insert(stops, b)
	return stops
end

return corridor
