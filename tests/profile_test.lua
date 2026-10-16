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
