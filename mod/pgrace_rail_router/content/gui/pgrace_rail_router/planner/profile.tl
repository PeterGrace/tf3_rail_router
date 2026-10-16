local profile : PgraceRailRouterProfile = {}

local type Span = PgraceRailRouterProfile.Span
local type Result = PgraceRailRouterProfile.Result

function profile.fit(s : {number}, ground : {number}, water : {boolean}, maxGrade : number, bridgeAbove : number,
		tunnelBelow : number) : Result
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
	-- Forward then backward, each sample clamped to its neighbour ± the grade limit: afterwards every pair is within
	-- it.
	local z : {number} = {}
	for k = 1, n do
		z[k] = target[k]
	end
	for k = 2, n do
		local limit = maxGrade * (s[k] - s[k - 1])
		z[k] = math.max(z[k - 1] - limit, math.min(z[k - 1] + limit, z[k]))
	end
	for k = n - 1, 1, -1 do
		local limit = maxGrade * (s[k + 1] - s[k])
		z[k] = math.max(z[k + 1] - limit, math.min(z[k + 1] + limit, z[k]))
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
	local start = 1
	for k = 2, n + 1 do
		if k > n or kinds[k] ~= kinds[start] then
			local stop = s[n]
			if k <= n then
				stop = s[k]
			end
			table.insert(spans, { kind = kinds[start], s0 = s[start], s1 = stop })
			start = k
		end
	end
	return { z = z, spans = spans, maxGrade = maxG }
end

return profile
