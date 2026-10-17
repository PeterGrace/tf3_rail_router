local profile : PgraceRailRouterProfile = {}

local type Span = PgraceRailRouterProfile.Span
local type Result = PgraceRailRouterProfile.Result

-- Bridges, tunnels and stretches of ground shorter than this are merged into their neighbours (metres).
local MIN_SPAN = 75.0
-- Over a crossed road or track, the track runs at least this far above the ground (metres).
local CLEARANCE = 7.0

-- Merges spans shorter than MIN_SPAN, shortest first: one between two of the same kind takes that kind, any other
-- joins its longer neighbour. Spans over water or a crossing (keep[k]) are never merged away, though they may absorb
-- others.
local function mergeShort(spans : {Span}, keep : {boolean}) : {Span}
	while #spans > 1 do
		local shortest : integer = nil
		local shortestLen = MIN_SPAN
		for k, span in ipairs(spans) do
			local l = span.s1 - span.s0
			if l < shortestLen and not keep[k] then
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
			keep[k - 1] = keep[k - 1] or keep[k + 1]
			table.remove(spans, k + 1)
			table.remove(keep, k + 1)
		elseif next == nil or (prev ~= nil and prev.s1 - prev.s0 >= next.s1 - next.s0) then
			prev.s1 = spans[k].s1
		else
			next.s0 = spans[k].s0
		end
		table.remove(spans, k)
		table.remove(keep, k)
	end
	return spans
end

function profile.fit(s : {number}, ground : {number}, water : {boolean}, maxGrade : number, bridgeAbove : number,
		tunnelBelow : number, zStart ?: number, zEnd ?: number, crossing ?: {boolean}) : Result
	local n = #s
	crossing = crossing or {}
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
	-- Over a crossing the track must clear the crossed line: a floor of CLEARANCE over the ground there, spread to the
	-- neighbours at the grade limit (forward, then backward), so the track can climb to it in time. The grade passes
	-- below never take the track under a floor that is itself within the grade limit. The spread floor is: it's the
	-- highest of the raw ground + CLEARANCE values less maxGrade × distance, so even a run of crossing samples on
	-- ground steeper than the limit keeps its clearance (the track is lifted higher there instead, more than
	-- CLEARANCE above the lower samples). Only the pinned ends can break it, when a crossing is too near them.
	local floor : {number} = {}
	local anyCrossing = false
	for k = 1, n do
		if crossing[k] then
			floor[k] = ground[k] + CLEARANCE
			anyCrossing = true
		else
			floor[k] = -math.huge
		end
	end
	if anyCrossing then
		for k = 2, n do
			floor[k] = math.max(floor[k], floor[k - 1] - maxGrade * (s[k] - s[k - 1]))
		end
		for k = n - 1, 1, -1 do
			floor[k] = math.max(floor[k], floor[k + 1] - maxGrade * (s[k + 1] - s[k]))
		end
		for k = 1, n do
			target[k] = math.max(target[k], floor[k])
		end
	end
	-- Pinned ends are where the track must be, whatever the ground (and whatever a crossing next to them needs).
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
	-- Clamp each sample to its neighbour ± the grade limit, one direction after the other, so afterwards every pair is
	-- within it. A single order is lopsided: over a ridge the first pass lags below the ground on the way up (a tunnel
	-- near that end) and stays above it on the way down (a long viaduct), and a valley is the reverse. So run both
	-- orders and average them. Each result keeps the grade limit and the pins, and neither goes under a crossing floor
	-- (the floor is itself within the grade limit, and the targets are at or above it), so the average keeps all
	-- three. When the pins are infeasible they still win over the grade, in both.
	local function clamp(forwardFirst : boolean) : {number}
		local out : {number} = {}
		for k = 1, n do
			out[k] = target[k]
		end
		for pass = 1, 2 do
			if (pass == 1) == forwardFirst then
				for k = 2, n do
					local limit = maxGrade * (s[k] - s[k - 1])
					out[k] = math.max(out[k - 1] - limit, math.min(out[k - 1] + limit, out[k]))
				end
				-- The end just reached goes back to its pin before the other pass starts from it.
				if n > 0 and zEnd ~= nil then
					out[n] = zEnd
				end
			else
				for k = n - 1, 1, -1 do
					local limit = maxGrade * (s[k + 1] - s[k])
					out[k] = math.max(out[k + 1] - limit, math.min(out[k + 1] + limit, out[k]))
				end
				if n > 0 and zStart ~= nil then
					out[1] = zStart
				end
			end
		end
		return out
	end
	local za = clamp(true)
	local zb = clamp(false)
	local z : {number} = {}
	for k = 1, n do
		z[k] = (za[k] + zb[k]) / 2
	end
	local kinds : {string} = {}
	local maxG = 0.0
	for k = 1, n do
		if water[k] or crossing[k] or z[k] - ground[k] > bridgeAbove then
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
	local keep : {boolean} = {}
	local start = 1
	for k = 2, n + 1 do
		if k > n or kinds[k] ~= kinds[start] then
			local stop = s[n]
			if k <= n then
				stop = s[k]
			end
			table.insert(spans, { kind = kinds[start], s0 = s[start], s1 = stop })
			local kept = false
			for m = start, k - 1 do
				kept = kept or water[m] or crossing[m] == true
			end
			table.insert(keep, kept)
			start = k
		end
	end
	return { z = z, spans = mergeShort(spans, keep), maxGrade = maxG, feasible = feasible }
end

return profile
