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

-- Cheapest insertion: from a straight to b, repeatedly puts in the town (of `towns`, a and b left out) whose best
-- place in the line adds the least length, at that place, while the line stays at most maxLength long (nil: no
-- limit). Returns the line, a to b. Ties go to the lower id, then the earlier place, so the result is repeatable.
local function insertCheapest(a : Town, b : Town, towns : {Town}, maxLength : number) : {Town}
	local stops : {Town} = { a, b }
	local length = geo.dist(a.pos, b.pos)
	local left : {Town} = {}
	for __, town in ipairs(towns) do
		if town.id ~= a.id and town.id ~= b.id then
			table.insert(left, town)
		end
	end
	while #left > 0 do
		local best = math.huge
		local bestTown, bestPlace = 0, 0
		for k, town in ipairs(left) do
			for place = 2, #stops do
				local p, q = stops[place - 1].pos, stops[place].pos
				local added = geo.dist(p, town.pos) + geo.dist(town.pos, q) - geo.dist(p, q)
				if added < best - 1e-9
					or (added < best + 1e-9 and town.id < left[bestTown].id) then
					best, bestTown, bestPlace = added, k, place
				end
			end
		end
		if maxLength ~= nil and length + best > maxLength + 1e-9 then
			break
		end
		table.insert(stops, bestPlace, left[bestTown])
		table.remove(left, bestTown)
		length = length + best
	end
	return stops
end

function corridor.select(a : Town, b : Town, candidates : {Candidate}, budget : number) : {Town}
	local towns : {Town} = {}
	for __, candidate in ipairs(candidates) do
		table.insert(towns, candidate.town)
	end
	local stops = insertCheapest(a, b, towns, (1 + budget) * geo.dist(a.pos, b.pos))
	local chosen : {Town} = {}
	for k = 2, #stops - 1 do
		table.insert(chosen, stops[k])
	end
	return chosen
end

function corridor.visible(candidates : {Candidate}, on : {integer : boolean}, overridden : {integer : boolean},
		extra : integer) : {Candidate}
	local rest : {Candidate} = {}
	for __, candidate in ipairs(candidates) do
		local id = candidate.town.id
		if not on[id] and overridden[id] == nil then
			table.insert(rest, candidate)
		end
	end
	table.sort(rest, function(x : Candidate, y : Candidate) : boolean
		if x.detour ~= y.detour then
			return x.detour < y.detour
		end
		return x.town.id < y.town.id
	end)
	local shown : {integer : boolean} = {}
	for k = 1, math.min(extra, #rest) do
		shown[rest[k].town.id] = true
	end
	local result : {Candidate} = {}
	for __, candidate in ipairs(candidates) do
		local id = candidate.town.id
		if on[id] or overridden[id] ~= nil or shown[id] then
			table.insert(result, candidate)
		end
	end
	return result
end

function corridor.order(a : Town, b : Town, picked : {Town}) : {Town}
	return insertCheapest(a, b, picked, nil)
end

return corridor
