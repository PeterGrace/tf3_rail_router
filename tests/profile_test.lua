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
	local r = profile.fit(s, ground, water, 0.025, 8, 12)
	t.eq(#r.spans, 1, "spans")
	t.eq(r.spans[1].kind, "ground", "kind")
	t.near(r.spans[1].s1, 1000, 1e-9, "covers the route")
	t.near(r.maxGrade, 0, 1e-12, "grade")
end)

t.test("profile: a gentle slope is followed exactly", function()
	local s, ground, water = line(function(x) return 0.01 * x end)
	local r = profile.fit(s, ground, water, 0.025, 8, 12)
	for i = 1, #s do
		t.near(r.z[i], ground[i], 1e-9, "z " .. i)
	end
end)

t.test("profile: a deep valley becomes a bridge", function()
	local s, ground, water = line(function(x) return (x >= 400 and x <= 600) and -40 or 0 end)
	local r = profile.fit(s, ground, water, 0.02, 8, 12)
	t.eq(spanAt(r, 500), "bridge", "middle")
	t.ok(gradesWithin(r, s, 0.02), "grades")
end)

t.test("profile: a ridge becomes a tunnel", function()
	local s, ground, water = line(function(x) return (x >= 400 and x <= 600) and 40 or 0 end)
	local r = profile.fit(s, ground, water, 0.02, 8, 12)
	t.eq(spanAt(r, 500), "tunnel", "middle")
	t.ok(gradesWithin(r, s, 0.02), "grades")
end)

t.test("profile: water is bridged straight between the banks", function()
	local inLake = function(x) return x >= 400 and x <= 600 end
	local s, ground, water = line(function(x) return inLake(x) and -5 or 0 end, inLake)
	local r = profile.fit(s, ground, water, 0.02, 8, 12)
	t.eq(spanAt(r, 400), "bridge", "start of lake")
	t.eq(spanAt(r, 600), "bridge", "end of lake")
	t.near(r.z[21], 0, 1e-9, "deck at bank height mid-lake")
end)

t.test("profile: pinned ends meet the given heights", function()
	local s, ground, water = line(function(x) return 0.05 * x end)
	local r = profile.fit(s, ground, water, 0.025, 8, 12, 5, 28)
	t.ok(r.feasible, "feasible")
	t.near(r.z[1], 5, 1e-9, "start")
	t.near(r.z[#s], 28, 1e-9, "end")
	t.ok(gradesWithin(r, s, 0.025), "grades")
end)

t.test("profile: free ends are feasible", function()
	local s, ground, water = line(function(x) return 0.05 * x end)
	local r = profile.fit(s, ground, water, 0.025, 8, 12)
	t.ok(r.feasible, "feasible")
	t.near(r.z[1], 0, 1e-9, "start follows the ground")
end)

t.test("profile: ends too far apart in height are infeasible", function()
	local s, ground, water = line(function() return 0 end)
	local r = profile.fit(s, ground, water, 0.025, 8, 12, 0, 100)
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
	local r = profile.fit(s, ground, water, 0.001, 8, 12)
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
	local r = profile.fit(s, ground, water, 0.025, 8, 12)
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
	local r = profile.fit(s, ground, water, 0.025, 8, 12, nil, nil, crossing)
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
	local r = profile.fit(s, ground, water, 0.025, 8, 12, 0, 0, crossing)
	t.eq(spanAt(r, 500), "bridge", "over the line")
	t.ok(r.z[21] >= 7 - 1e-9, "clearance " .. r.z[21])
	t.ok(gradesWithin(r, s, 0.025), "grades")
end)
