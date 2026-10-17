local profile : PgraceRailRouterProfile = {}

local type Span = PgraceRailRouterProfile.Span
local type Result = PgraceRailRouterProfile.Result
local type Options = PgraceRailRouterProfile.Options
local type FitJob = PgraceRailRouterProfile.FitJob

-- Bridges, tunnels and stretches of ground shorter than this are merged into their neighbours (metres).
local MIN_SPAN = 75.0
-- Over a crossed road or track, the track runs at least this far above the ground (metres). Probe P8: a double-track
-- bridge square across existing track collided with it at 7 m (rail to rail) and was clean from 8 m; over a street,
-- 6 m was clean. 9 leaves a metre for crossings at an angle and uneven ground.
local CLEARANCE = 9.0
-- The height search runs on evenly spaced nodes at most this far apart (metres; route.tl samples every 25 m at most).
local NODE_STEP = 25.0
-- The coarsest height step it tries (metres). The step is the grade limit's rise between nodes split evenly, so the
-- steepest allowed climb is a whole number of steps: 0.3125 m at 2.5% (Fastest), 0.425 m at 8.5%.
local MAX_RESOLUTION = 0.5
-- What a metre of plain track costs per metre of cut or fill under it, on top of its 1 (in metres of plain track).
-- The game doesn't charge for earthworks, so this only keeps the track at the ground where leaving it saves
-- nothing (else it would ride anywhere up to 8 m above it, or 12 m below, at no cost), and makes a big embankment or
-- cutting pay its way: 8 m of fill is 1.4 times plain track, still far below a bridge's 5.
local EARTHWORKS = 0.05
-- The same for bridges and tunnels, smaller: a bridge's deck keeps low, a tunnel shallow, over water near the
-- banks' line, without that moving where they start and end.
local STRUCTURE_LEAN = 0.002

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

-- Clamps each sample to its neighbour ± the grade limit, forward from the start's pin then backward from the end's, so
-- afterwards every pair is within it and both pins hold (when they're within reach of each other). In place.
local function clampToGrade(s : {number}, z : {number}, maxGrade : number, zStart : number, zEnd : number)
	local n = #z
	if n == 0 then
		return
	end
	if zStart ~= nil then
		z[1] = zStart
	end
	for k = 2, n do
		local limit = maxGrade * (s[k] - s[k - 1])
		z[k] = math.max(z[k - 1] - limit, math.min(z[k - 1] + limit, z[k]))
	end
	if zEnd ~= nil then
		z[n] = zEnd
	end
	for k = n - 1, 1, -1 do
		local limit = maxGrade * (s[k + 1] - s[k])
		z[k] = math.max(z[k + 1] - limit, math.min(z[k + 1] + limit, z[k]))
	end
	if zStart ~= nil then
		z[1] = zStart
	end
end

-- A fit's working state, between steps.
local record State
	s : {number}
	ground : {number}
	water : {boolean}
	crossing : {boolean}
	options : Options
	-- Per sample: the height the track would like (the ground; over water the banks' line), and the lowest it may be
	-- (crossings' clearance spread at the grade, capped at what the pins can reach).
	ref : {number}
	floor : {number}
	-- The end's pin, or when out of the start's reach the nearest height within it; and whether it was within.
	zEndFit : number
	feasible : boolean
	-- The search, when there is one (three samples or more): nodes 0..nodes, du metres apart; heights base + i h,
	-- `steps` of them the most between nodes; per node its reference height, water and crossing, and the band of
	-- grid heights it tries (first..last). The last node it weighs (the one before a pinned end), the next one to,
	-- the cheapest cost to each height of the node before it, and per node each height's cheapest predecessor.
	searching : boolean
	nodes : integer
	du : number
	rise : number
	steps : integer
	h : number
	base : number
	refN : {number}
	waterN : {boolean}
	crossN : {boolean}
	first : {integer}
	last : {integer}
	lastNode : integer
	node : integer
	cost : {number}
	back : {{integer}}
end

-- The cost of a metre of track at height z over a node whose reference height is r, in metres of plain track.
local function costAt(z : number, r : number, overWater : boolean, crossing : boolean, o : Options) : number
	local dz = z - r
	if overWater or crossing then
		return o.bridgeCostFactor + STRUCTURE_LEAN * math.abs(dz)
	elseif dz > o.bridgeAbove then
		return o.bridgeCostFactor + STRUCTURE_LEAN * dz
	elseif -dz > o.tunnelBelow then
		return o.tunnelCostFactor - STRUCTURE_LEAN * dz
	end
	return 1 + EARTHWORKS * math.abs(dz)
end

-- Sets up the search for the cheapest heights within the grade limit: dynamic programming (Viterbi) over evenly
-- spaced nodes and heights on a grid of h metres, per node and height the cheapest way there from the start. The
-- heights at the samples are then linear between nodes, which keeps the nodes' grades.
local function setUp(st : State)
	local s, ref, o = st.s, st.ref, st.options
	local n = #s
	local zStart, zEnd = o.zStart, st.zEndFit
	local length = s[n] - s[1]
	local nodes = math.max(1, math.ceil(length / NODE_STEP - 1e-9))
	local du = length / nodes
	local rise = o.maxGrade * du
	-- The steepest climb or descent between nodes is `steps` grid steps exactly.
	local steps = math.max(1, math.ceil(rise / MAX_RESOLUTION - 1e-9))
	local h = rise / steps
	if rise <= 0 then
		steps, h = 0, MAX_RESOLUTION
	end
	-- Node m (0-based) is at s[1] + m du: its reference height interpolated, water and crossing from the nearest
	-- sample, and the floor of every sample in the intervals either side (so the line between nodes clears them).
	local refN : {number} = {}
	local waterN : {boolean} = {}
	local crossN : {boolean} = {}
	local floorN : {number} = {}
	local j = 1
	for m = 0, nodes do
		local u = s[1] + m * du
		while j < n - 1 and s[j + 1] < u do
			j = j + 1
		end
		local span = s[j + 1] - s[j]
		local t = 0.0
		if span > 0 then
			t = math.max(0, math.min(1, (u - s[j]) / span))
		end
		refN[m] = ref[j] + (ref[j + 1] - ref[j]) * t
		local near = j
		if t >= 0.5 then
			near = j + 1
		end
		waterN[m] = st.water[near] or false
		crossN[m] = st.crossing[near] or false
		floorN[m] = -math.huge
	end
	for k = 1, n do
		if st.floor[k] > -math.huge then
			local m = math.max(0, math.min(nodes, math.floor((s[k] - s[1]) / du)))
			floorN[m] = math.max(floorN[m], st.floor[k])
			if m < nodes then
				floorN[m + 1] = math.max(floorN[m + 1], st.floor[k])
			end
		end
	end
	for m = 1, nodes do
		floorN[m] = math.max(floorN[m], floorN[m - 1] - rise)
	end
	for m = nodes - 1, 0, -1 do
		floorN[m] = math.max(floorN[m], floorN[m + 1] - rise)
	end
	-- What the pins allow at each node.
	local reachLo : {number} = {}
	local reachHi : {number} = {}
	for m = 0, nodes do
		local lo, hi = -math.huge, math.huge
		if zStart ~= nil then
			lo, hi = math.max(lo, zStart - m * rise), math.min(hi, zStart + m * rise)
		end
		if zEnd ~= nil then
			lo, hi = math.max(lo, zEnd - (nodes - m) * rise), math.min(hi, zEnd + (nodes - m) * rise)
		end
		reachLo[m], reachHi[m] = lo, hi
		floorN[m] = math.min(floorN[m], hi)
	end
	-- Each node's band of heights worth trying. A cheapest track never goes under the lowest the reference heights
	-- allow at the grade limit (lifting it up to that only brings it nearer the reference: no dearer), nor over the
	-- highest that they and the floors need: so clip to those envelopes, and to the pins' reach.
	local lower : {number} = {}
	local upper : {number} = {}
	for m = 0, nodes do
		lower[m] = refN[m]
		upper[m] = math.max(refN[m], floorN[m])
	end
	if zStart ~= nil then
		lower[0], upper[0] = zStart, zStart
	end
	if zEnd ~= nil then
		lower[nodes], upper[nodes] = zEnd, zEnd
	end
	for m = 1, nodes do
		lower[m] = math.min(lower[m], lower[m - 1] + rise)
		upper[m] = math.max(upper[m], upper[m - 1] - rise)
	end
	for m = nodes - 1, 0, -1 do
		lower[m] = math.min(lower[m], lower[m + 1] + rise)
		upper[m] = math.max(upper[m], upper[m + 1] - rise)
	end
	local base = zStart or 0.0
	local first : {integer} = {}
	local last : {integer} = {}
	for m = 0, nodes do
		local lo = math.max(lower[m], floorN[m], reachLo[m])
		local hi = math.max(lo, math.min(upper[m], reachHi[m]))
		-- A feasible track rounded up to the grid stays feasible (rounding keeps a rise of whole steps), so the band
		-- runs from lo, and up to hi, rounded up.
		first[m] = math.ceil((lo - base) / h - 1e-9)
		last[m] = math.ceil((hi - base) / h - 1e-9)
	end
	st.searching, st.nodes, st.du, st.rise, st.steps, st.h, st.base = true, nodes, du, rise, steps, h, base
	st.refN, st.waterN, st.crossN, st.first, st.last = refN, waterN, crossN, first, last
	-- The last node, when pinned, is that exact height, reached from the node before it (finish).
	st.lastNode = nodes
	if zEnd ~= nil then
		st.lastNode = nodes - 1
	end
	st.cost, st.back, st.node = {}, {}, 1
	for i = first[0], last[0] do
		st.cost[i - first[0] + 1] = costAt(base + i * h, refN[0], waterN[0], crossN[0], o) * du
	end
end

-- Weighs node m: for each of its heights, the cheapest predecessor within the grade and the cost so far. Returns
-- the work done (heights times predecessors looked at).
local function weigh(st : State, m : integer) : integer
	local o = st.options
	local bridgeFactor, tunnelFactor = o.bridgeCostFactor, o.tunnelCostFactor
	local bridgeAbove, tunnelBelow = o.bridgeAbove, o.tunnelBelow
	local abs, huge = math.abs, math.huge
	local a0, b0, a1, b1 = st.first[m - 1], st.last[m - 1], st.first[m], st.last[m]
	local steps, base, h = st.steps, st.base, st.h
	local weight = st.du
	if m == st.nodes then
		weight = 0
	end
	local r = st.refN[m]
	local structure = st.waterN[m] or st.crossN[m]
	local cost = st.cost
	local nextCost : {number} = {}
	local from : {integer} = {}
	local offset = a0 - 1
	for i = a1, b1 do
		local lo, hi = i - steps, i + steps
		if lo < a0 then
			lo = a0
		end
		if hi > b0 then
			hi = b0
		end
		local best, arg = huge, -1
		for p = lo - offset, hi - offset do
			local v = cost[p]
			if v < best then
				best, arg = v, p
			end
		end
		local k = i - a1 + 1
		if best < huge then
			local dz = base + i * h - r
			local c : number
			if structure then
				c = bridgeFactor + STRUCTURE_LEAN * abs(dz)
			elseif dz > bridgeAbove then
				c = bridgeFactor + STRUCTURE_LEAN * dz
			elseif -dz > tunnelBelow then
				c = tunnelFactor - STRUCTURE_LEAN * dz
			else
				c = 1 + EARTHWORKS * abs(dz)
			end
			nextCost[k] = best + c * weight
			from[k] = arg + offset
		else
			nextCost[k] = huge
			from[k] = -1
		end
	end
	st.cost = nextCost
	st.back[m] = from
	return (b1 - a1 + 1) * (2 * steps + 1)
end

-- The searched heights at the samples, or nil when no path fits (it always should).
local function searched(st : State) : {number}
	local zEnd = st.zEndFit
	local nodes, base, h = st.nodes, st.base, st.h
	local best, arg = math.huge, -1
	local a = st.first[st.lastNode]
	for i = a, st.last[st.lastNode] do
		local v = st.cost[i - a + 1]
		if v < best and (zEnd == nil or math.abs(zEnd - (base + i * h)) <= st.rise + h + 1e-9) then
			best, arg = v, i
		end
	end
	if best == math.huge then
		return nil
	end
	local zN : {number} = {}
	if zEnd ~= nil then
		zN[nodes] = zEnd
	end
	local level = arg
	for m = st.lastNode, 0, -1 do
		zN[m] = base + level * h
		if m > 0 then
			level = st.back[m][level - st.first[m] + 1]
		end
	end
	local s = st.s
	local z : {number} = {}
	for k = 1, #s do
		local x = (s[k] - s[1]) / st.du
		local m = math.max(0, math.min(nodes - 1, math.floor(x)))
		z[k] = zN[m] + (zN[m + 1] - zN[m]) * (x - m)
	end
	return z
end

-- The fit's result from the searched heights.
local function finish(st : State) : Result
	local s, ground, water, crossing, ref, floor, o = st.s, st.ground, st.water, st.crossing, st.ref, st.floor,
		st.options
	local n = #s
	local z : {number} = nil
	local h = 0.0
	if st.searching then
		z, h = searched(st), st.h
	end
	-- Each sample moves up to a grid step towards its reference height (so a track that can follow the ground does so
	-- exactly, and the grid doesn't decide where a bridge ends), then the grade limit and pins are put right: by less
	-- than a step, as the clamp keeps each sample within h of the grid track.
	local target : {number} = {}
	for k = 1, n do
		if z ~= nil then
			target[k] = math.max(z[k] - h, math.min(z[k] + h, ref[k]))
		else
			target[k] = math.max(ref[k], floor[k])
		end
	end
	clampToGrade(s, target, o.maxGrade, o.zStart, st.zEndFit)
	z = target
	-- The clamp never takes the track under a floor it started above (the floor is within the grade limit), but the
	-- step towards the reference might: lift those back (still within the grade, and within the pins' reach).
	for k = 1, n do
		z[k] = math.max(z[k], floor[k])
	end
	if not st.feasible then
		z[n] = o.zEnd
	end
	local kinds : {string} = {}
	local maxG = 0.0
	for k = 1, n do
		if water[k] or crossing[k] or z[k] - ground[k] > o.bridgeAbove then
			kinds[k] = "bridge"
		elseif ground[k] - z[k] > o.tunnelBelow then
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
	return { z = z, spans = mergeShort(spans, keep), maxGrade = maxG, feasible = st.feasible }
end

function profile.start(s : {number}, ground : {number}, water : {boolean}, o : Options) : FitJob
	local n = #s
	local maxGrade = o.maxGrade
	local crossing = o.crossing or {}
	local zStart, zEnd = o.zStart, o.zEnd
	-- What the track would like to follow: the ground, and over water a straight line between the banks.
	local ref : {number} = {}
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
					ref[k] = left + (right - left) * (s[k] - s[i - 1]) / (s[j + 1] - s[i - 1])
				else
					ref[k] = left or right or ground[k]
				end
			end
			i = j + 1
		else
			ref[i] = ground[i]
			i = i + 1
		end
	end
	-- Pins too far apart for the grade: aim for the nearest height the start's pin can reach, and put the end's pin
	-- back at the very end (the last grade breaks the limit).
	local feasible = true
	local zEndFit = zEnd
	if n > 1 and zStart ~= nil and zEnd ~= nil then
		local reach = maxGrade * (s[n] - s[1])
		if math.abs(zEnd - zStart) > reach + 1e-9 then
			feasible = false
			zEndFit = math.max(zStart - reach, math.min(zStart + reach, zEnd))
		end
	end
	-- Over a crossing the track must clear the crossed line: a floor of CLEARANCE over the ground there, spread to the
	-- neighbours at the grade limit (forward, then backward), so the track can climb to it in time. It's the highest
	-- of the raw ground + CLEARANCE values less maxGrade × distance, so even a run of crossing samples on ground
	-- steeper than the limit keeps its clearance (the track is lifted higher there instead). Where the pins can't
	-- reach that high, they win: the floor is capped at their reach.
	local floor : {number} = {}
	for k = 1, n do
		if crossing[k] then
			floor[k] = ground[k] + CLEARANCE
		else
			floor[k] = -math.huge
		end
	end
	for k = 2, n do
		floor[k] = math.max(floor[k], floor[k - 1] - maxGrade * (s[k] - s[k - 1]))
	end
	for k = n - 1, 1, -1 do
		floor[k] = math.max(floor[k], floor[k + 1] - maxGrade * (s[k + 1] - s[k]))
	end
	for k = 1, n do
		if zStart ~= nil then
			floor[k] = math.min(floor[k], zStart + maxGrade * (s[k] - s[1]))
		end
		if zEndFit ~= nil then
			floor[k] = math.min(floor[k], zEndFit + maxGrade * (s[n] - s[k]))
		end
	end
	local st : State = { s = s, ground = ground, water = water, crossing = crossing, options = o, ref = ref,
		floor = floor, zEndFit = zEndFit, feasible = feasible, searching = false }
	if n >= 3 and s[n] > s[1] then
		setUp(st)
	end
	return { done = false, state = st }
end

function profile.step(job : FitJob, budget : integer) : boolean
	if job.done then
		return true
	end
	local st = job.state as State
	if st.searching then
		local work = 0
		while st.node <= st.lastNode and work < budget do
			work = work + weigh(st, st.node)
			st.node = st.node + 1
		end
		if st.node <= st.lastNode then
			return false
		end
	end
	job.result = finish(st)
	job.done, job.state = true, nil
	return true
end

function profile.fit(s : {number}, ground : {number}, water : {boolean}, o : Options) : Result
	local job = profile.start(s, ground, water, o)
	while not profile.step(job, 1000000000) do
	end
	return job.result
end

return profile
