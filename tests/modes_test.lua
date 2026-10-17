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

t.test("modes: templates the player can never build are left out", function()
	local function tpl(yearFrom, yearTo) return { name = "x", cost = 1, speed = 1, yearFrom = yearFrom, yearTo = yearTo } end
	t.ok(modes.isEverBuildable(tpl(0, 0)), "always")
	t.ok(modes.isEverBuildable(tpl(1930, 0)), "from 1930")
	t.ok(modes.isEverBuildable(tpl(0, 1950)), "until 1950")
	t.ok(not modes.isEverBuildable(tpl(100000, 0)), "depot track")
	t.ok(not modes.isEverBuildable(tpl(100000, 1)), "industry track")
	t.ok(not modes.isEverBuildable(tpl(1800, 1800)), "station mod track")
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
	t.near(w.minSearchRadius, 220, 1e-9, "search fallback: its own radius")
	t.near(w.costPerMetre, 360, 1e-9, "two tracks")
end)

t.test("modes: fastest is flatter and wider", function()
	local w = modes.weights("fastest", TYPES[2])
	t.near(w.maxGrade, 0.025, 1e-9, "grade")
	t.near(w.minRadius, 44.4 * 44.4 / 2, 1e-6, "radius from speed")
	t.near(modes.weights("fastest", TYPES[3]).minRadius, 3000, 1e-9, "capped")
	t.near(w.minSearchRadius, 220, 1e-9, "search fallback: the Cheapest radius")
	local c = modes.weights("cheapest", TYPES[2])
	t.ok(w.turnPenalty > c.turnPenalty, "turns cost more")
	t.ok(w.bridgeFactor < c.bridgeFactor, "bridges cost less, relatively")
	t.eq(w.bridgeRoads, true, "fastest bridges roads")
	t.eq(c.bridgeRoads, false, "cheapest crosses roads level")
	-- The speed model: planned for the speed the radius allows, at most the track's; time priced in Fastest only.
	t.near(w.topSpeed, 44.4, 1e-6, "top speed: the track's")
	t.near(modes.weights("fastest", TYPES[3]).topSpeed, math.sqrt(2 * 3000), 1e-6, "top speed: what 3 km allows")
	t.ok(w.timeCost > 0, "fastest prices time")
	t.eq(c.timeCost, 0, "cheapest doesn't")
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

-- Bridge and tunnel types as in base/content (bridge/*.bridge.lua, tunnel/*.tunnel.lua): menu order, cost, km/h, years.
local function structure(name, order, cost, kmh, yearFrom, yearTo, opts)
	opts = opts or {}
	return { name = name, index = order, order = order, cost = cost, speedLimit = kmh / 3.6, yearFrom = yearFrom,
		yearTo = yearTo, rail = opts.rail ~= false, autoSelectable = opts.auto ~= false }
end
local BRIDGES = {
	structure("trestle", 10, 100, 60, 0, 1970),
	structure("trestle_s", 20, 100, 60, 0, 1970, { rail = false }),
	structure("stone", 30, 200, 90, 0, 0),
	structure("steel", 40, 200, 140, 1940, 0),
	structure("concrete", 50, 200, 280, 1970, 0),
	structure("suspension", 60, 600, 180, 1940, 0, { auto = false }),
	structure("cable", 70, 750, 220, 2000, 0, { auto = false }),
	structure("tarch", 80, 650, 350, 2010, 0, { auto = false }),
	structure("placeholder", 1000, 200, 90, -1, -1),
}

t.test("modes: the bridge picked is the slowest fast enough, else the fastest", function()
	t.eq(modes.structureFor(BRIDGES, 80 / 3.6, 2000).name, "stone", "80 km/h")
	t.eq(modes.structureFor(BRIDGES, 120 / 3.6, 2000).name, "steel", "120 km/h")
	t.eq(modes.structureFor(BRIDGES, 350 / 3.6, 2050).name, "concrete", "350 km/h: none fast enough, the fastest")
	t.eq(modes.structureFor(BRIDGES, 120 / 3.6, 1900).name, "stone", "steel not yet available")
	t.eq(modes.structureFor(BRIDGES, 50 / 3.6, 1900).name, "trestle", "50 km/h before 1970: trestle")
	t.eq(modes.structureFor(BRIDGES, 50 / 3.6, 1970).name, "stone", "trestle gone from 1970")
	t.eq(modes.structureFor(BRIDGES, 90 / 3.6, 2000).name, "stone", "exactly the limit is fast enough")
end)

t.test("modes: the closest speed above wins, not the cheapest", function()
	local types = { structure("fast_cheap", 10, 50, 200, 0, 0), structure("slow_dear", 20, 500, 100, 0, 0) }
	t.eq(modes.structureFor(types, 80 / 3.6, 2000).name, "slow_dear", "the game's rule")
end)

t.test("modes: equal speeds go to the first in the menu's order", function()
	-- The base tunnels have no speedLimit (0): every track is faster, and tunnel_a comes first in the menu.
	local tunnels = { structure("tunnel_b", 30, 600, 0, 1970, 0), structure("tunnel_a", 20, 600, 0, 0, 0) }
	t.eq(modes.structureFor(tunnels, 120 / 3.6, 2000).name, "tunnel_a", "after 1970")
	t.eq(modes.structureFor(tunnels, 120 / 3.6, 1950).name, "tunnel_a", "before 1970")
	t.eq(modes.structureFor({ tunnels[1] }, 120 / 3.6, 1950), nil, "none available")
end)
