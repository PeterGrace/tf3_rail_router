local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo

local arrows : PgraceRailRouterArrows = {}

local type Arrow = PgraceRailRouterArrows.Arrow
local type Leg = PgraceRailRouterRoute.Leg

-- The kind of each stretch between samples i and i + 1: a bridge or tunnel span overlapping it wins over ground, so
-- one shorter than the sample spacing still shows. Spans are in order along the leg; one pass over both lists.
local function segmentKinds(leg : Leg) : {string}
	local kinds : {string} = {}
	local spans = leg.spans
	local first = 1
	for i = 1, #leg.samples - 1 do
		local a, b = leg.samples[i].s, leg.samples[i + 1].s
		while first <= #spans and spans[first].s1 <= a do
			first = first + 1
		end
		local kind = "ground"
		local k = first
		while k <= #spans and spans[k].s0 < b do
			if spans[k].kind ~= "ground" then
				kind = spans[k].kind
				break
			end
			k = k + 1
		end
		kinds[i] = kind
	end
	return kinds
end

function arrows.split(leg : Leg, chord : number, minLength : number) : {Arrow}
	local samples = leg.samples
	local n = #samples
	local kinds = segmentKinds(leg)
	local function long(i : integer, j : integer) : boolean
		return geo.dist(samples[i].p, samples[j].p) >= minLength
	end
	local list : {Arrow} = {}
	local i = 1
	while i < n do
		local kind = kinds[i]
		local j = i + 1
		while j < n and samples[j].s - samples[i].s < chord and kinds[j] == kind do
			j = j + 1
		end
		-- Take a short tail of the same kind into this chord rather than leaving a stub arrow.
		if j < n and samples[n].s - samples[j].s < chord / 2 then
			local same = true
			for k = j, n - 1 do
				if kinds[k] ~= kind then
					same = false
					break
				end
			end
			if same then
				j = n
			end
		end
		while j < n and not long(i, j) do
			j = j + 1
		end
		table.insert(list, { i = i, j = j, kind = kind })
		i = j
	end
	local last = list[#list]
	if last ~= nil and not long(last.i, last.j) then
		table.remove(list)
		local before = list[#list]
		if before ~= nil then
			before.j = n
			if before.kind == "ground" then
				before.kind = last.kind
			end
		end
	end
	return list
end

return arrows
