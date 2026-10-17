local t = ...
-- Regression routes on the kit's shared maps (../maps/, maps/README.md there), planned offline exactly as the window
-- plans them (tools/replaylib.lua). For every route:
--   * the plan is ok, or fails the way it is recorded to (expectFailure);
--   * the stops are the ones recorded (corridor selection);
--   * no arc is tighter than the track's build minimum (weights.minBuildRadius, 55 m);
--   * no sample lies on a blocked cell (unless a known number is recorded, with why);
--   * no single route.step takes longer than STEP_BUDGET_MS;
--   * length, estimate, tight curves, and bridges and tunnels are no worse than the baseline by more than TOLERANCE.
-- `just test` runs the routes marked quick (the test map, well under a second); `just regress` runs them all (the
-- 54-town map too, and checks the maps against the in-game route captures beside them).
--
-- Re-recording the baselines, after a change that makes plans better (or worse on purpose): run
--   RAIL_ROUTER_REGRESS=full RAIL_ROUTER_RECORD=1 lua tools/test.lua | grep "^RECORD"
-- and paste each printed `base = {...}` over the route's own below. Say in the commit why the figures moved.

local mapsDir = t.root .. "/../maps"
local full = os.getenv("RAIL_ROUTER_REGRESS") == "full"
local recording = os.getenv("RAIL_ROUTER_RECORD") == "1"

-- The longest single route.step allowed, desktop milliseconds at the window's 150 expansions a step. The slowest
-- seen on these routes is about 2.5 ms; in-game Lua runs about 4 times slower, so 10 ms here is about 40 ms in-game:
-- a step that would show as a hitch, well clear of timing noise on a busy desktop.
local STEP_BUDGET_MS = 10.0
-- How much worse than the baseline a figure may get: lengths and estimates as a share; tight curves, and bridges
-- plus tunnels, as a count; their length as a share, at least STRUCTURE_SLACK metres.
local TOLERANCE = { length = 0.02, estimate = 0.03, tight = 1, structures = 1, structureLength = 0.10 }
local STRUCTURE_SLACK = 100.0

local TEST_MAP = "rail-router-test-5x14km.map"
local BIG_MAP = "big-54-towns-16x16km.map"

-- base: length (m), estimate, tight (curves below the mode's radius), bridges, bridgeLength, tunnels, tunnelLength
-- (m). Recorded 2026-10-16 (mod commit after the floor-share and room-to-turn fixes).
local ROUTES = {
	{ map = TEST_MAP, from = "Bangor", to = "Imperial Beach", mode = "cheapest", track = "Standard Tracks", quick = true,
		stopsSeen = "Bangor, Mercer Island, Antelope, Aloha, Imperial Beach",
		base = { length = 14988, estimate = 5572157, tight = 2, bridges = 1, bridgeLength = 123, tunnels = 0, tunnelLength = 0 } },
	{ map = TEST_MAP, from = "Bangor", to = "Imperial Beach", mode = "cheapest", track = "Standard Tracks", quick = true,
		stops = { "Antelope", "Aloha" }, stopsSeen = "Bangor, Antelope, Aloha, Imperial Beach",
		base = { length = 12896, estimate = 4785760, tight = 0, bridges = 1, bridgeLength = 99, tunnels = 0, tunnelLength = 0 } },
	{ map = TEST_MAP, from = "Bangor", to = "Imperial Beach", mode = "fastest", track = "High-Speed Tracks", quick = true,
		stopsSeen = "Bangor, Mercer Island, Antelope, Aloha, Imperial Beach",
		base = { length = 14399, estimate = 19375877, tight = 5, bridges = 3, bridgeLength = 885, tunnels = 0, tunnelLength = 0 } },
	{ map = TEST_MAP, from = "Bangor", to = "Imperial Beach", mode = "fastest", track = "High-Speed Tracks", quick = true,
		stops = { "Antelope", "Aloha" }, stopsSeen = "Bangor, Antelope, Aloha, Imperial Beach",
		base = { length = 12957, estimate = 14844958, tight = 10, bridges = 2, bridgeLength = 197, tunnels = 0, tunnelLength = 0 } },

	{ map = BIG_MAP, from = "Ames", to = "Bridgeport", mode = "cheapest", track = "Standard Tracks",
		stopsSeen = "Ames, Foster City, Temple City, Miami, Bridgeport",
		base = { length = 11378, estimate = 4239492, tight = 9, bridges = 1, bridgeLength = 100, tunnels = 0, tunnelLength = 0 } },
	-- Before the fixes: an 8 m and a 48 m curve, and 2 samples on blocked cells (a loop between Temple City and Miami).
	{ map = BIG_MAP, from = "Ames", to = "Bridgeport", mode = "fastest", track = "High-Speed Tracks",
		stopsSeen = "Ames, Foster City, Temple City, Miami, Bridgeport",
		base = { length = 11798, estimate = 34105993, tight = 20, bridges = 9, bridgeLength = 2613, tunnels = 3, tunnelLength = 1333 } },
	{ map = BIG_MAP, from = "Pensacola", to = "Columbus", mode = "cheapest",
		stopsSeen = "Pensacola, Napa, Novato, Columbus",
		base = { length = 7155, estimate = 2713578, tight = 5, bridges = 1, bridgeLength = 96, tunnels = 0, tunnelLength = 0 } },
	-- Known: 4 samples on a blocked cell just past Napa. Buildings pull Napa's room to turn back to 3 m, and the grid
	-- path (searched at the 220 m fallback radius, which turns freely) jogs 78° right then 77° left 66 m apart. Those
	-- two corners don't fit even at 55 m, so smoothing drops them and cuts the corner over the cell (a cut corner rather
	-- than a curve the game can't build). Fixing it needs the search to space turns for the build minimum.
	{ map = BIG_MAP, from = "Pensacola", to = "Columbus", mode = "fastest", knownBlocked = 4,
		stopsSeen = "Pensacola, Napa, Novato, Columbus",
		base = { length = 7831, estimate = 16859649, tight = 12, bridges = 4, bridgeLength = 1945, tunnels = 0, tunnelLength = 0 } },
	{ map = BIG_MAP, from = "Englewood", to = "Weston", mode = "cheapest",
		stopsSeen = "Englewood, Sulphur, Weston",
		base = { length = 5776, estimate = 2244955, tight = 1, bridges = 1, bridgeLength = 115, tunnels = 0, tunnelLength = 0 } },
	{ map = BIG_MAP, from = "Englewood", to = "Weston", mode = "fastest",
		stopsSeen = "Englewood, Sulphur, Weston",
		base = { length = 4771, estimate = 12370321, tight = 10, bridges = 3, bridgeLength = 1671, tunnels = 0, tunnelLength = 0 } },
	{ map = BIG_MAP, from = "Gardner", to = "Herndon", mode = "cheapest",
		stopsSeen = "Gardner, Eldersburg, Pottstown, Herndon",
		base = { length = 7878, estimate = 2836021, tight = 1, bridges = 0, bridgeLength = 0, tunnels = 0, tunnelLength = 0 } },
	{ map = BIG_MAP, from = "Gardner", to = "Herndon", mode = "fastest",
		stopsSeen = "Gardner, Eldersburg, Pottstown, Herndon",
		base = { length = 8054, estimate = 16813858, tight = 9, bridges = 6, bridgeLength = 974, tunnels = 1, tunnelLength = 517 } },
	-- Expected failure: Bartlesville's station lands 170 m from the map's south edge facing south-east, with
	-- buildings across its whole arriving side, so no leg can reach it (Pasadena to Bartlesville alone plans fine,
	-- with the station facing another way). A station-siting limit; if it starts planning, record a baseline.
	{ map = BIG_MAP, from = "Durham", to = "Bartlesville", mode = "cheapest", expectFailure = "no_path",
		stopsSeen = "Durham, Pasadena, Bartlesville" },
}

-- The in-game route captures beside the maps, and how far the maps are from them (tools/compare_capture.lua's
-- figures): cells that differ, and the mean and max height difference (m).
local CAPTURES = {
	{ map = TEST_MAP, capture = "rail-router-test-5x14km.bangor-imperial-beach.capture", water = 3, meanHeight = 0.01,
		maxHeight = 2.61 },
	{ map = BIG_MAP, capture = "big-54-towns-16x16km.ames-bridgeport.capture", water = 13, meanHeight = 0.19,
		maxHeight = 6.07 },
}

local probe = io.open(mapsDir .. "/" .. TEST_MAP, "r")
if probe == nil then
	print("SKIP regression: no " .. mapsDir .. "/" .. TEST_MAP .. " (the kit's maps/ folder; clone the kit as tf3_mods "
		.. "with this repo inside it)")
	return
end
probe:close()

local lib = dofile(t.root .. "/tools/replaylib.lua")(t.root)
local maps = {}
local function loadMap(name)
	if maps[name] == nil then
		maps[name] = lib.maplib.load(mapsDir .. "/" .. name)
	end
	return maps[name]
end

local function routeName(rt)
	local name = rt.from .. " → " .. rt.to .. ", " .. rt.mode
	if rt.stops then
		name = name .. " via " .. table.concat(rt.stops, ", ")
	end
	return name .. " (" .. rt.map .. ")"
end

local function noWorse(label, now, base, share, slack)
	local limit = base * (1 + share) + (slack or 0)
	t.ok(now <= limit + 1e-6, ("%s %.0f, baseline %.0f (at most %.0f)"):format(label, now, base, limit))
end

local better = {}
local started = os.clock()
for _, rt in ipairs(ROUTES) do
	if rt.quick or full then
		t.test("regression: " .. routeName(rt), function()
			local r = lib.planOnMap(loadMap(rt.map), { from = rt.from, to = rt.to, mode = rt.mode, track = rt.track,
				stops = rt.stops })
			local names = {}
			for __, town in ipairs(r.stops) do
				table.insert(names, town.name)
			end
			t.eq(table.concat(names, ", "), rt.stopsSeen, "stops")
			t.ok(r.worstStep <= STEP_BUDGET_MS, ("slowest step %.2f ms, budget %.0f"):format(r.worstStep, STEP_BUDGET_MS))
			local plan = r.plan
			if rt.expectFailure then
				t.eq(plan.ok, false, "fails as recorded (now it plans: record a baseline)")
				t.eq(plan.failure, rt.expectFailure, "failure")
				return
			end
			t.ok(plan.ok, "plans: " .. tostring(plan.failure) .. " " .. table.concat(plan.failureTowns or {}, ", "))
			local s = plan.summary
			if recording then
				print(("RECORD %s\n\t\tbase = { length = %.0f, estimate = %.0f, tight = %d, bridges = %d, bridgeLength = %.0f, tunnels = %d, tunnelLength = %.0f } },"):format(
					routeName(rt), s.length, s.estimate, s.tightCurves, s.bridges, s.bridgeLength, s.tunnels, s.tunnelLength))
			end
			local below = lib.arcsBelow(plan, r.weights.minBuildRadius)
			local list = {}
			for __, arc in ipairs(below) do
				table.insert(list, ("leg %d: %.0f m at (%.0f, %.0f)"):format(arc.leg, arc.radius, arc.a.x, arc.a.y))
			end
			t.eq(#below, 0, "arcs below " .. r.weights.minBuildRadius .. " m: " .. table.concat(list, "; "))
			local blocked = lib.blockedSamples(r)
			t.eq(#blocked, rt.knownBlocked or 0, "samples on blocked cells")
			local b = rt.base
			noWorse("length", s.length, b.length, TOLERANCE.length)
			noWorse("estimate", s.estimate, b.estimate, TOLERANCE.estimate)
			noWorse("tight curves", s.tightCurves, b.tight, 0, TOLERANCE.tight)
			noWorse("bridges and tunnels", s.bridges + s.tunnels, b.bridges + b.tunnels, 0, TOLERANCE.structures)
			local structure = b.bridgeLength + b.tunnelLength
			noWorse("bridge and tunnel length", s.bridgeLength + s.tunnelLength, structure, TOLERANCE.structureLength,
				STRUCTURE_SLACK)
			if s.estimate < b.estimate * (1 - TOLERANCE.estimate) or s.length < b.length * (1 - TOLERANCE.length) then
				table.insert(better, routeName(rt))
			end
		end)
	end
end

if full then
	t.test("regression: the maps reproduce the in-game route captures beside them", function()
		for __, c in ipairs(CAPTURES) do
			local map = loadMap(c.map)
			local cap = lib.capture.load(mapsDir .. "/" .. c.capture)
			local g = lib.maplib.rasterise(map, cap.x0, cap.y0, cap.cell, cap.nx, cap.ny)
			local differ = { blocked = 0, water = 0, road = 0, track = 0 }
			local n, sum, max = 0, 0.0, 0.0
			for iy = 1, cap.ny do
				for ix = 1, cap.nx do
					local i = (iy - 1) * cap.nx + ix
					for k in pairs(differ) do
						if (g[k][i] or false) ~= (cap[k][i] or false) then
							differ[k] = differ[k] + 1
						end
					end
					local x, y = cap.x0 + (ix - 1) * cap.cell, cap.y0 + (iy - 1) * cap.cell
					if lib.maplib.flagAt(map, x, y) ~= "X" and not (cap.blocked[i] and cap.height[i] == 0) then
						local d = math.abs(g.height[i] - cap.height[i])
						n, sum, max = n + 1, sum + d, math.max(max, d)
					end
				end
			end
			t.eq(differ.blocked, 0, c.capture .. " blocked")
			t.eq(differ.road, 0, c.capture .. " road")
			t.eq(differ.track, 0, c.capture .. " track")
			t.ok(differ.water <= c.water, c.capture .. " water " .. differ.water)
			t.ok(sum / n <= c.meanHeight + 0.005, ("%s mean height difference %.3f"):format(c.capture, sum / n))
			t.ok(max <= c.maxHeight + 0.01, ("%s max height difference %.2f"):format(c.capture, max))
		end
	end)
end

print(("regression: %s set, %.1f s%s"):format(full and "full" or "quick", os.clock() - started,
	#better > 0 and ("; better than the baseline, re-record: " .. table.concat(better, "; ")) or ""))
