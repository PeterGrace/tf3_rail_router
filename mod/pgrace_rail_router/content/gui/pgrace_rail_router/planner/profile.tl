local profile : PgraceRailRouterProfile = {}

local type Span = PgraceRailRouterProfile.Span
local type Result = PgraceRailRouterProfile.Result

-- Bridges, tunnels and stretches of ground shorter than this are merged into their neighbours (metres).
local MIN_SPAN = 75.0

-- Merges spans shorter than MIN_SPAN, shortest first: one between two of the same kind takes that kind, any other
-- joins its longer neighbour. Spans over water (wet[k]) are never merged away, though they may absorb others.
local function mergeShort(spans : {Span}, wet : {boolean}) : {Span}
	while #spans > 1 do
		local shortest : integer = nil
		local shortestLen = MIN_SPAN
		for k, span in ipairs(spans) do
			local l = span.s1 - span.s0
			if l < shortestLen and not wet[k] then
				shortest, shortestLen = k, l
			end
		end
		if shortest == nil then
			break
		end
		local k = shortest
		local prev, next = spans[k - 1], spans[k + 1]
		if prev ~= nil and next ~= nil and prev.kind == next.kind then
			prev.s1 = next.s1
			wet[k - 1] = wet[k - 1] or wet[k + 1]
			table.remove(spans, k + 1)
			table.remove(wet, k + 1)
		elseif next == nil or (prev ~= nil and prev.s1 - prev.s0 >= next.s1 - next.s0) then
			prev.s1 = spans[k].s1
		else
			next.s0 = spans[k].s0
		end
		table.remove(spans, k)
		table.remove(wet, k)
	end
	return spans
end

function profile.fit(s : {number}, ground : {number}, water : {boolean}, maxGrade : number, bridgeAbove : number,
		tunnelBelow : number, zStart ?: number, zEnd ?: number) : Result
	local n = #s
	-- What the track would like to follow: the ground, and over water a straight line between the banks.
	local target : {number} = {}
	local i = 1
	while i <= n do
		if water[i] then
			local j = i
			while j < n and water[j + 1] do
				j = j + 1
			end
			local left : number = nil
			local right : number = nil
			if i > 1 then
				left = ground[i - 1]
			end
			if j < n then
				right = ground[j + 1]
			end
			for k = i, j do
				if left ~= nil and right ~= nil then
					target[k] = left + (right - left) * (s[k] - s[i - 1]) / (s[j + 1] - s[i - 1])
				else
					target[k] = left or right or ground[k]
				end
			end
			i = j + 1
		else
			target[i] = ground[i]
			i = i + 1
		end
	end
	-- Pinned ends are where the track must be, whatever the ground.
	if n > 0 and zStart ~= nil then
		target[1] = zStart
	end
	if n > 0 and zEnd ~= nil then
		target[n] = zEnd
	end
	local feasible = true
	if n > 1 and zStart ~= nil and zEnd ~= nil and math.abs(zEnd - zStart) > maxGrade * (s[n] - s[1]) + 1e-9 then
		feasible = false
	end
	-- Forward from the start, then backward from the end, each sample clamped to its neighbour ± the grade limit:
	-- afterwards every pair is within it.
	local z : {number} = {}
	for k = 1, n do
		z[k] = target[k]
	end
	for k = 2, n do
		local limit = maxGrade * (s[k] - s[k - 1])
		z[k] = math.max(z[k - 1] - limit, math.min(z[k - 1] + limit, z[k]))
	end
	if n > 0 and zEnd ~= nil then
		z[n] = zEnd
	end
	for k = n - 1, 1, -1 do
		local limit = maxGrade * (s[k + 1] - s[k])
		z[k] = math.max(z[k + 1] - limit, math.min(z[k + 1] + limit, z[k]))
	end
	-- When feasible the backward pass leaves the start alone; when not, the pins win over the grade.
	if n > 0 and zStart ~= nil then
		z[1] = zStart
	end
	local kinds : {string} = {}
	local maxG = 0.0
	for k = 1, n do
		if water[k] or z[k] - ground[k] > bridgeAbove then
			kinds[k] = "bridge"
		elseif ground[k] - z[k] > tunnelBelow then
			kinds[k] = "tunnel"
		else
			kinds[k] = "ground"
		end
		if k > 1 and s[k] > s[k - 1] then
			maxG = math.max(maxG, math.abs(z[k] - z[k - 1]) / (s[k] - s[k - 1]))
		end
	end
	local spans : {Span} = {}
	local wet : {boolean} = {}
	local start = 1
	for k = 2, n + 1 do
		if k > n or kinds[k] ~= kinds[start] then
			local stop = s[n]
			if k <= n then
				stop = s[k]
			end
			table.insert(spans, { kind = kinds[start], s0 = s[start], s1 = stop })
			local anyWater = false
			for m = start, k - 1 do
				anyWater = anyWater or water[m]
			end
			table.insert(wet, anyWater)
			start = k
		end
	end
	return { z = z, spans = mergeShort(spans, wet), maxGrade = maxG, feasible = feasible }
end

return profile
