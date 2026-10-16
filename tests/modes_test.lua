local t = ...
local modes = t.requireTl("gui/pgrace_rail_router/planner/modes.tl")

-- The base game's three track types (base/content/infrastructure/track.zip).
local function track(name, cost, speed, yearFrom)
	return { name = name, label = name, cost = cost, speed = speed, maxSlopeBuild = 0.085, minCurveRadiusBuild = 55,
		trackDistance = 5, yearFrom = yearFrom, yearTo = 0 }
end
local TYPES = {
	track("simple.lua", 60, 27.8, 0),
	track("standard.lua", 180, 44.4, 1930),
	track("high_speed.lua", 540, 97.2, 1980),
}

t.test("modes: availability respects yearFrom and yearTo", function()
	local old = { name = "old", cost = 1, speed = 1, yearFrom = 0, yearTo = 1950 }
	t.ok(modes.isAvailable(old, 1949), "before yearTo")
	t.ok(not modes.isAvailable(old, 1950), "from yearTo on")
	t.ok(not modes.isAvailable(TYPES[2], 1929), "before yearFrom")
	t.ok(modes.isAvailable(TYPES[2], 1930), "from yearFrom on")
end)

t.test("modes: default track by year and mode", function()
	t.eq(modes.defaultTrack(TYPES, 1900, "cheapest").name, "simple.lua", "1900 cheapest")
	t.eq(modes.defaultTrack(TYPES, 1900, "fastest").name, "simple.lua", "1900 fastest")
	t.eq(modes.defaultTrack(TYPES, 1950, "cheapest").name, "standard.lua", "1950 cheapest")
	t.eq(modes.defaultTrack(TYPES, 1990, "cheapest").name, "standard.lua", "1990 cheapest skips high-speed")
	t.eq(modes.defaultTrack(TYPES, 1990, "fastest").name, "high_speed.lua", "1990 fastest")
	t.eq(modes.defaultTrack({}, 1990, "fastest"), nil, "no types")
end)

t.test("modes: cheapest uses the type's limits", function()
	local w = modes.weights("cheapest", TYPES[2])
	t.near(w.maxGrade, 0.085, 1e-9, "grade")
	t.near(w.minRadius, 220, 1e-9, "radius: 4 × 55")
	t.near(w.costPerMetre, 360, 1e-9, "two tracks")
end)

t.test("modes: fastest is flatter and wider", function()
	local w = modes.weights("fastest", TYPES[2])
	t.near(w.maxGrade, 0.025, 1e-9, "grade")
	t.near(w.minRadius, 44.4 * 44.4 / 2, 1e-6, "radius from speed")
	t.near(modes.weights("fastest", TYPES[3]).minRadius, 3000, 1e-9, "capped")
	local c = modes.weights("cheapest", TYPES[2])
	t.ok(w.turnPenalty > c.turnPenalty, "turns cost more")
	t.ok(w.bridgeFactor < c.bridgeFactor, "bridges cost less, relatively")
end)

t.test("modes: cheapest falls back to the cheapest type when only fast ones are available", function()
	local function fast(name, cost, speed, yearFrom)
		return { name = name, label = name, cost = cost, speed = speed, maxSlopeBuild = 0.085, minCurveRadiusBuild = 55,
			trackDistance = 5, yearFrom = yearFrom, yearTo = 0 }
	end
	local types = { fast("high_speed.lua", 540, 97.2, 0), fast("mid_fast.lua", 400, 80, 0) }
	t.eq(modes.defaultTrack(types, 1990, "cheapest").name, "mid_fast.lua", "cheapest of the fast ones")
	local future = { fast("a.lua", 540, 97.2, 2100), fast("b.lua", 400, 80, 2100) }
	t.eq(modes.defaultTrack(future, 1990, "cheapest"), nil, "none available")
end)
