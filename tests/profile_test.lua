local t = ...
local profile = t.requireTl("gui/pgrace_rail_router/planner/profile.tl")

-- Samples every 25 m over 1 km; ground and water from functions of s.
local function line(groundOf, waterOf)
	local s, ground, water = {}, {}, {}
	for i = 0, 40 do
		s[#s + 1] = i * 25
		ground[#ground + 1] = groundOf(i * 25)
		water[#water + 1] = waterOf ~= nil and waterOf(i * 25) or false
	end
	return s, ground, water
end

-- fit's options: the given ones over the defaults (Fastest's thresholds and cost factors).
local function opts(o)
	local out = { bridgeAbove = 8, tunnelBelow = 12, bridgeCostFactor = 5, tunnelCostFactor = 8 }
	for k, v in pairs(o) do
		out[k] = v
	end
	return out
end

-- Neighbouring spans share their boundary; a point on it belongs to the later span.
local function spanAt(result, s)
	for i = #result.spans, 1, -1 do
		local span = result.spans[i]
		if s >= span.s0 and s <= span.s1 then
			return span.kind
		end
	end
end

local function gradesWithin(result, s, limit)
	for i = 2, #s do
		if math.abs(result.z[i] - result.z[i - 1]) / (s[i] - s[i - 1]) > limit + 1e-9 then
			return false
		end
	end
	return true
end

t.test("profile: flat ground is one ground span", function()
	local s, ground, water = line(function() return 0 end)
	local r = profile.fit(s, ground, water, opts({ maxGrade = 0.025 }))
	t.eq(#r.spans, 1, "spans")
	t.eq(r.spans[1].kind, "ground", "kind")
	t.near(r.spans[1].s1, 1000, 1e-9, "covers the route")
	t.near(r.maxGrade, 0, 1e-12, "grade")
end)

t.test("profile: a gentle slope is followed exactly", function()
	local s, ground, water = line(function(x) return 0.01 * x end)
	local r = profile.fit(s, ground, water, opts({ maxGrade = 0.025 }))
	for i = 1, #s do
		t.near(r.z[i], ground[i], 1e-9, "z " .. i)
	end
end)

t.test("profile: a deep valley becomes a bridge", function()
	local s, ground, water = line(function(x) return (x >= 400 and x <= 600) and -40 or 0 end)
	local r = profile.fit(s, ground, water, opts({ maxGrade = 0.02 }))
	t.eq(spanAt(r, 500), "bridge", "middle")
	t.ok(gradesWithin(r, s, 0.02), "grades")
end)

t.test("profile: a ridge becomes a tunnel", function()
	local s, ground, water = line(function(x) return (x >= 400 and x <= 600) and 40 or 0 end)
	local r = profile.fit(s, ground, water, opts({ maxGrade = 0.02 }))
	t.eq(spanAt(r, 500), "tunnel", "middle")
	t.ok(gradesWithin(r, s, 0.02), "grades")
end)

t.test("profile: water is bridged straight between the banks", function()
	local inLake = function(x) return x >= 400 and x <= 600 end
	local s, ground, water = line(function(x) return inLake(x) and -5 or 0 end, inLake)
	local r = profile.fit(s, ground, water, opts({ maxGrade = 0.02 }))
	t.eq(spanAt(r, 400), "bridge", "start of lake")
	t.eq(spanAt(r, 600), "bridge", "end of lake")
	t.near(r.z[21], 0, 1e-9, "deck at bank height mid-lake")
end)

t.test("profile: pinned ends meet the given heights", function()
	local s, ground, water = line(function(x) return 0.05 * x end)
	local r = profile.fit(s, ground, water, opts({ maxGrade = 0.025, zStart = 5, zEnd = 28 }))
	t.ok(r.feasible, "feasible")
	t.near(r.z[1], 5, 1e-9, "start")
	t.near(r.z[#s], 28, 1e-9, "end")
	t.ok(gradesWithin(r, s, 0.025), "grades")
end)

t.test("profile: free ends are feasible", function()
	-- Within the grade limit, so the track follows the ground to both ends. On ground steeper than the limit the
	-- free ends are balanced between the two clamp orders instead.
	local s, ground, water = line(function(x) return 0.02 * x end)
	local r = profile.fit(s, ground, water, opts({ maxGrade = 0.025 }))
	t.ok(r.feasible, "feasible")
	t.near(r.z[1], 0, 1e-9, "start follows the ground")
end)

t.test("profile: ends too far apart in height are infeasible", function()
	local s, ground, water = line(function() return 0 end)
	local r = profile.fit(s, ground, water, opts({ maxGrade = 0.025, zStart = 0, zEnd = 100 }))
	t.ok(not r.feasible, "infeasible")
	t.near(r.z[1], 0, 1e-9, "start pinned")
	t.near(r.z[#s], 100, 1e-9, "end pinned")
end)

t.test("profile: ground hovering at the bridge threshold isn't split into many spans", function()
	-- 1.5 km, with a 500 m valley whose floor alternates 7 and 9 m below the (almost flat) track.
	local s, ground, water = {}, {}, {}
	for i = 0, 60 do
		local x = i * 25
		s[#s + 1] = x
		local inValley = x >= 500 and x <= 1000
		ground[#ground + 1] = inValley and ((i % 2 == 0) and -7 or -9) or 0
		water[#water + 1] = false
	end
	local r = profile.fit(s, ground, water, opts({ maxGrade = 0.001 }))
	local bridges = 0
	for k, span in ipairs(r.spans) do
		if span.kind == "bridge" then
			bridges = bridges + 1
		end
		if k > 1 then
			t.near(span.s0, r.spans[k - 1].s1, 1e-9, "contiguous")
			t.ok(span.kind ~= r.spans[k - 1].kind, "neighbours differ")
		end
	end
	t.ok(bridges <= 1, "at most one bridge, got " .. bridges)
	t.near(r.spans[1].s0, 0, 1e-9, "starts at 0")
	t.near(r.spans[#r.spans].s1, 1500, 1e-9, "covers the route")
end)

t.test("profile: a 50 m river keeps its bridge", function()
	local inRiver = function(x) return x >= 475 and x <= 500 end
	local s, ground, water = line(function() return 0 end, inRiver)
	local r = profile.fit(s, ground, water, opts({ maxGrade = 0.025 }))
	t.eq(spanAt(r, 487.5), "bridge", "over the river")
	t.eq(#r.spans, 3, "ground, bridge, ground")
end)

t.test("profile: a crossing on flat ground is bridged with clearance", function()
	-- Existing line under samples 20..23 (500..575 m).
	local s, ground, water = line(function() return 0 end)
	local crossing = {}
	for i = 1, #s do
		crossing[i] = s[i] >= 500 and s[i] <= 575
	end
	local r = profile.fit(s, ground, water, opts({ maxGrade = 0.025, crossing = crossing }))
	for i = 1, #s do
		if crossing[i] then
			t.ok(r.z[i] - ground[i] >= 7 - 1e-9, "clearance at " .. s[i] .. ": " .. (r.z[i] - ground[i]))
			t.eq(spanAt(r, s[i]), "bridge", "bridge at " .. s[i])
		end
	end
	t.ok(gradesWithin(r, s, 0.025), "grades")
	t.near(r.z[1], 0, 1e-9, "back on the ground at the start")
	t.near(r.z[#s], 0, 1e-9, "back on the ground at the end")
end)

t.test("profile: a one-sample crossing keeps its bridge", function()
	local s, ground, water = line(function() return 0 end)
	local crossing = {}
	for i = 1, #s do
		crossing[i] = s[i] == 500
	end
	local r = profile.fit(s, ground, water, opts({ maxGrade = 0.025, zStart = 0, zEnd = 0, crossing = crossing }))
	t.eq(spanAt(r, 500), "bridge", "over the line")
	t.ok(r.z[21] >= 7 - 1e-9, "clearance " .. r.z[21])
	t.ok(gradesWithin(r, s, 0.025), "grades")
end)

t.test("profile: crossings on ground steeper than the limit keep their clearance", function()
	-- Ground climbing 20% over 450..600 m (crossing samples), flat either side.
	local s, ground, water = line(function(x) return 0.2 * math.max(450, math.min(600, x)) end)
	local crossing = {}
	for i = 1, #s do
		crossing[i] = s[i] >= 450 and s[i] <= 600
	end
	local r = profile.fit(s, ground, water, opts({ maxGrade = 0.025, crossing = crossing }))
	for i = 1, #s do
		if crossing[i] then
			t.ok(r.z[i] - ground[i] >= 7 - 1e-9, "clearance at " .. s[i] .. ": " .. (r.z[i] - ground[i]))
		end
	end
	t.ok(gradesWithin(r, s, 0.025), "grades")
end)

-- A 60 m cosine hill (or valley) in the middle of the 1 km line, level at both ends.
local function countKind(result, kind)
	local count, mid = 0, nil
	for __, span in ipairs(result.spans) do
		if span.kind == kind then
			count = count + 1
			mid = (span.s0 + span.s1) / 2
		end
	end
	return count, mid
end

local function checkBalanced(sign, kind)
	local s, ground, water = line(function(x) return sign * 30 * (1 - math.cos(2 * math.pi * x / 1000)) end)
	local r = profile.fit(s, ground, water, opts({ maxGrade = 0.025, zStart = 0, zEnd = 0 }))
	local n = #s
	-- Mirror images to within the height search's grid step (0.3125 m here): its ties and rounding fall one way.
	for k = 1, n do
		t.near(r.z[k], r.z[n + 1 - k], 0.32, "symmetric at " .. k)
	end
	t.ok(gradesWithin(r, s, 0.025), "grades")
	local count, mid = countKind(r, kind)
	t.eq(count, 1, "one " .. kind)
	t.near(mid, 500, 25, "centred")
end

t.test("profile: a ridge is tunnelled symmetrically", function()
	checkBalanced(1, "tunnel")
end)

t.test("profile: a valley is bridged symmetrically", function()
	checkBalanced(-1, "bridge")
end)

-- Samples every 25 m over `length` metres.
local function longLine(length, groundOf, waterOf)
	local s, ground, water = {}, {}, {}
	for i = 0, math.floor(length / 25) do
		s[#s + 1] = i * 25
		ground[#ground + 1] = groundOf(i * 25)
		water[#water + 1] = waterOf ~= nil and waterOf(i * 25) or false
	end
	return s, ground, water
end

-- What summarise charges for the spans (per metre of plain track: 1, bridges 5, tunnels 8).
local function costOf(result)
	local factor = { ground = 1, bridge = 5, tunnel = 8 }
	local sum = 0
	for __, span in ipairs(result.spans) do
		sum = sum + (span.s1 - span.s0) * factor[span.kind]
	end
	return sum
end

t.test("profile: flat ground before a ridge it tunnels through isn't bridged (Cornelius → Perth Amboy)", function()
	-- As leg 1 in-game: flat at 2 m with a road crossed at 650..675 m, then a 72 m ridge rising at 30% from 850 m
	-- and falling at 25% to flat ground; stations at ground level both ends. The balanced clamp kept the track ~10 m
	-- up from the crossing to the ridge: a 200 m bridge over flat ground, then the tunnel.
	local s, ground, water = longLine(2200, function(x)
		return 2 + math.max(0, math.min(70, 0.3 * (x - 850), 0.25 * (1700 - x)))
	end)
	local crossing = {}
	for i = 1, #s do
		crossing[i] = s[i] >= 650 and s[i] <= 675
	end
	local r = profile.fit(s, ground, water, opts({ maxGrade = 0.025, zStart = 2, zEnd = 2, crossing = crossing }))
	local bridges = countKind(r, "bridge")
	t.eq(bridges, 1, "one bridge, over the road")
	for __, span in ipairs(r.spans) do
		if span.kind == "bridge" then
			t.ok(span.s1 - span.s0 <= 100, ("bridge %.0f..%.0f only over the road"):format(span.s0, span.s1))
		end
	end
	local tunnels, mid = countKind(r, "tunnel")
	t.eq(tunnels, 1, "one tunnel")
	t.near(mid, 1250, 100, "through the ridge")
	t.ok(gradesWithin(r, s, 0.025), "grades")
	for i = 1, #s do
		if crossing[i] then
			t.ok(r.z[i] - ground[i] >= 7 - 1e-9, "clearance")
		end
	end
end)

t.test("profile: a gentle hill within the grade is followed, no bridge or tunnel", function()
	local s, ground, water = longLine(2000, function(x) return 7 * (1 - math.cos(2 * math.pi * x / 2000)) end)
	local r = profile.fit(s, ground, water, opts({ maxGrade = 0.025, zStart = 0, zEnd = 0 }))
	t.eq(#r.spans, 1, "spans")
	t.eq(r.spans[1].kind, "ground", "kind")
	for i = 1, #s do
		t.near(r.z[i], ground[i], 1e-9, "z " .. i)
	end
end)

t.test("profile: a valley is bridged once, where it's deep, and the rest is on the ground", function()
	-- 40 m deep, 300 m wide at the bottom, sides at 30%: the bridge should span little more than the valley.
	local s, ground, water = longLine(2000, function(x)
		return -math.max(0, math.min(40, 0.3 * (x - 700), 0.3 * (1300 - x)))
	end)
	local r = profile.fit(s, ground, water, opts({ maxGrade = 0.025, zStart = 0, zEnd = 0 }))
	local bridges, mid = countKind(r, "bridge")
	t.eq(bridges, 1, "one bridge")
	t.near(mid, 1000, 50, "centred")
	t.eq(countKind(r, "tunnel"), 0, "tunnels")
	t.ok(gradesWithin(r, s, 0.025), "grades")
	-- Level track at 0 bridges 700..1300 less the 8 m at each side: 547 m.
	for __, span in ipairs(r.spans) do
		if span.kind == "bridge" then
			t.ok(span.s1 - span.s0 <= 600, "bridge length " .. (span.s1 - span.s0))
		end
	end
end)

t.test("profile: water between hills is bridged, and the banks reached within the grade", function()
	-- A 200 m lake at -3 m between banks at 0, then a 20 m hill.
	local inLake = function(x) return x >= 700 and x <= 900 end
	local s, ground, water = longLine(2000, function(x)
		if inLake(x) then
			return -3
		end
		return 20 * math.max(0, 1 - math.abs(x - 1500) / 300)
	end, inLake)
	local r = profile.fit(s, ground, water, opts({ maxGrade = 0.025, zStart = 0, zEnd = 0 }))
	for i = 1, #s do
		if water[i] then
			t.eq(spanAt(r, s[i]), "bridge", "bridge over water at " .. s[i])
		end
	end
	t.ok(gradesWithin(r, s, 0.025), "grades")
end)

-- Rough ground (a fixed pseudo-random walk), pins, crossings and water: the guarantees hold whatever the ground.
local function roughCase(seed, length, maxGrade, pinned)
	local x = seed
	local function rand()
		x = (x * 1103515245 + 12345) % 2147483648
		return x / 2147483648
	end
	local h, heights = 0, {}
	local s, ground, water = longLine(length, function()
		h = h + (rand() - 0.5) * 12
		table.insert(heights, h)
		return h
	end, function() return rand() < 0.05 end)
	local crossing = {}
	for i = 1, #s do
		crossing[i] = rand() < 0.03
	end
	local o = { maxGrade = maxGrade, crossing = crossing }
	if pinned then
		o.zStart, o.zEnd = ground[1], ground[#s]
	end
	return s, ground, water, crossing, profile.fit(s, ground, water, opts(o))
end

t.test("profile: on rough ground the grade, the pins and the clearances hold", function()
	for seed = 1, 20 do
		local s, ground, water, crossing, r = roughCase(seed, 2500, seed % 2 == 0 and 0.025 or 0.085, seed % 3 ~= 0)
		local maxGrade = seed % 2 == 0 and 0.025 or 0.085
		if r.feasible then
			t.ok(gradesWithin(r, s, maxGrade), "grades, seed " .. seed)
		end
		if seed % 3 ~= 0 then
			t.near(r.z[1], ground[1], 1e-9, "start pin, seed " .. seed)
			t.near(r.z[#s], ground[#s], 1e-9, "end pin, seed " .. seed)
		end
		t.near(r.maxGrade, r.maxGrade, 0, "maxGrade")
		for i = 1, #s do
			-- Clearance holds unless a pin is too near to climb to it.
			local reach = math.huge
			if seed % 3 ~= 0 then
				reach = math.min(ground[1] + maxGrade * s[i], ground[#s] + maxGrade * (s[#s] - s[i]))
			end
			if crossing[i] and ground[i] + 7 <= reach then
				t.ok(r.z[i] - ground[i] >= 7 - 1e-9, ("clearance at %d, seed %d: %.2f"):format(s[i], seed, r.z[i] - ground[i]))
			end
			if crossing[i] or water[i] then
				t.eq(spanAt(r, s[i]), "bridge", "bridge at " .. s[i] .. ", seed " .. seed)
			end
		end
		for k, span in ipairs(r.spans) do
			if k > 1 then
				t.near(span.s0, r.spans[k - 1].s1, 1e-9, "contiguous")
			end
		end
	end
end)

t.test("profile: samples spaced unevenly (as smoothing samples them) keep the grade", function()
	local s, ground, water = {}, {}, {}
	local x = 0
	for i = 0, 80 do
		s[#s + 1] = x
		ground[#ground + 1] = 30 * math.sin(x / 150)
		water[#water + 1] = false
		x = x + 12.5 + (i * 7 % 13)
	end
	local r = profile.fit(s, ground, water, opts({ maxGrade = 0.025, zStart = 0, zEnd = ground[#s] }))
	t.ok(gradesWithin(r, s, 0.025), "grades")
	t.near(r.z[#s], ground[#s], 1e-9, "end pin")
end)

t.test("profile: the fit costs no more than the old balanced clamp on ridges and valleys", function()
	-- Each structure as the summary prices it; the old fit on these: ridge (tunnel 650 m), valley (bridge 650 m).
	for __, sign in ipairs({ 1, -1 }) do
		local s, ground, water = longLine(2000, function(x)
			return sign * math.max(0, math.min(50, 0.2 * (x - 600), 0.2 * (1400 - x)))
		end)
		local r = profile.fit(s, ground, water, opts({ maxGrade = 0.025, zStart = 0, zEnd = 0 }))
		t.ok(costOf(r) <= 2000 + 7 * 650, "cost " .. costOf(r))
	end
end)

t.test("profile: a long hilly leg fits quickly", function()
	-- 10 km of rolling 80 m hills at Fastest's grade: the DP's whole work, run once.
	local s, ground, water = longLine(10000, function(x) return 40 * (1 - math.cos(2 * math.pi * x / 1700)) end)
	local started = os.clock()
	local r = profile.fit(s, ground, water, opts({ maxGrade = 0.025, zStart = 0, zEnd = 0 }))
	local ms = (os.clock() - started) * 1000
	print(("  profile: 10 km hilly leg fitted in %.1f ms"):format(ms))
	t.ok(gradesWithin(r, s, 0.025), "grades")
end)
