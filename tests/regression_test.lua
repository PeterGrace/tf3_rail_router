local t = ...
-- Regression routes on the kit's shared maps (../maps/, maps/README.md there), planned offline exactly as the window
-- plans them (tools/replaylib.lua). For every route:
--   * the plan is ok, or fails the way it is recorded to (expectFailure);
--   * the stops are the ones recorded (corridor selection);
--   * no arc is tighter than the track's build minimum (weights.minBuildRadius, 55 m);
--   * no sample lies on a blocked cell (unless a known number is recorded, with why);
--   * no leg's heading swings (replaylib.sweep) more than SWEEP_SLACK past the baseline's widest: a leg that starts
--     to loop or hook round into a station shows here first;
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

-- The longest single route.step allowed, desktop milliseconds at the window's 150 expansions a step, garbage
-- collection left out (replaylib.runPlan). The slowest seen on these routes is about 3 ms (fitting a Fastest leg's
-- curves up to 6 ms run alone); in-game Lua runs about 4 times slower, so 10 ms here is about 40 ms in-game: a step
-- that would show as a hitch, well clear of timing noise on a busy desktop.
local STEP_BUDGET_MS = 10.0
-- How much worse than the baseline a figure may get: lengths and estimates as a share; tight curves, and bridges
-- plus tunnels, as a count; their length as a share, at least STRUCTURE_SLACK metres.
local TOLERANCE = { length = 0.02, estimate = 0.03, tight = 1, structures = 1, structureLength = 0.10 }
local STRUCTURE_SLACK = 100.0

-- The kit's maps (maps/README.md there). A map renamed in the kit is renamed here, and nowhere else.
local TEST_MAP = "rail-router-test-5x14km.map"
local BIG_MAP = "big-54-towns-16x16km.map"
-- The player's third save, "PottstownTown" (2254).
local POTTSTOWN_MAP = "pottstowntown-16x16km.map"
-- The player's first save, "New Game" (2153).
local NEWGAME_MAP = "newgame-16x16km.map"
-- "NewGame2", an early, lightly built save (2001), with lots of water.
local NEWGAME2_MAP = "newgame2-16x16km.map"
-- How much more than the baseline's widest a leg's heading may swing (degrees).
local SWEEP_SLACK = 30

-- base: length (m), estimate, tight (curves below the mode's radius), bridges, bridgeLength, tunnels, tunnelLength
-- (m), sweep (the widest any leg's heading swings, degrees). Recorded 2026-10-17 (mod commit after the pocketed-site,
-- area and re-siting fixes); re-recorded the same day for the cost-optimal height profile (Fastest estimates down by
-- up to 27%, 5% over the set; Cheapest unchanged but Pensacola → Columbus, 5% down).
local ROUTES = {
	{ map = TEST_MAP, from = "Bangor", to = "Imperial Beach", mode = "cheapest", track = "Standard Tracks", quick = true,
		stopsSeen = "Bangor, Mercer Island, Antelope, Aloha, Imperial Beach",
		base = { length = 14988, estimate = 5572157, tight = 2, bridges = 1, bridgeLength = 123, tunnels = 0, tunnelLength = 0, sweep = 96 } },
	{ map = TEST_MAP, from = "Bangor", to = "Imperial Beach", mode = "cheapest", track = "Standard Tracks", quick = true,
		stops = { "Antelope", "Aloha" }, stopsSeen = "Bangor, Antelope, Aloha, Imperial Beach",
		base = { length = 12896, estimate = 4785760, tight = 0, bridges = 1, bridgeLength = 99, tunnels = 0, tunnelLength = 0, sweep = 99 } },
	{ map = TEST_MAP, from = "Bangor", to = "Imperial Beach", mode = "fastest", track = "High-Speed Tracks", quick = true,
		stopsSeen = "Bangor, Mercer Island, Antelope, Aloha, Imperial Beach",
		base = { length = 14399, estimate = 19375877, tight = 5, bridges = 3, bridgeLength = 885, tunnels = 0, tunnelLength = 0, sweep = 91 } },
	{ map = TEST_MAP, from = "Bangor", to = "Imperial Beach", mode = "fastest", track = "High-Speed Tracks", quick = true,
		stops = { "Antelope", "Aloha" }, stopsSeen = "Bangor, Antelope, Aloha, Imperial Beach",
		base = { length = 12957, estimate = 14844958, tight = 10, bridges = 2, bridgeLength = 197, tunnels = 0, tunnelLength = 0, sweep = 148 } },

	{ map = BIG_MAP, from = "Ames", to = "Bridgeport", mode = "cheapest", track = "Standard Tracks",
		stopsSeen = "Ames, Foster City, Temple City, Miami, Bridgeport",
		base = { length = 11369, estimate = 4270931, tight = 8, bridges = 2, bridgeLength = 124, tunnels = 0, tunnelLength = 0, sweep = 117 } },
	-- Before the fixes: an 8 m and a 48 m curve, and 2 samples on blocked cells (a loop between Temple City and Miami).
	{ map = BIG_MAP, from = "Ames", to = "Bridgeport", mode = "fastest", track = "High-Speed Tracks",
		stopsSeen = "Ames, Foster City, Temple City, Miami, Bridgeport",
		base = { length = 11813, estimate = 27135207, tight = 21, bridges = 9, bridgeLength = 1861, tunnels = 1, tunnelLength = 839, sweep = 154 } },
	{ map = BIG_MAP, from = "Pensacola", to = "Columbus", mode = "cheapest",
		stopsSeen = "Pensacola, Napa, Novato, Columbus",
		base = { length = 7155, estimate = 2575686, tight = 5, bridges = 0, bridgeLength = 0, tunnels = 0, tunnelLength = 0, sweep = 121 } },
	-- Known: 4 samples on a blocked cell just past Napa. Buildings pull Napa's room to turn back to 3 m, and the grid
	-- path (searched at the 220 m fallback radius, which turns freely) jogs 78° right then 77° left 66 m apart. Those
	-- two corners don't fit even at 55 m, so smoothing drops them and cuts the corner over the cell (a cut corner rather
	-- than a curve the game can't build). Fixing it needs the search to space turns for the build minimum.
	{ map = BIG_MAP, from = "Pensacola", to = "Columbus", mode = "fastest", knownBlocked = 4,
		stopsSeen = "Pensacola, Napa, Novato, Columbus",
		base = { length = 7831, estimate = 16122673, tight = 12, bridges = 4, bridgeLength = 1774, tunnels = 0, tunnelLength = 0, sweep = 155 } },
	{ map = BIG_MAP, from = "Englewood", to = "Weston", mode = "cheapest",
		stopsSeen = "Englewood, Sulphur, Weston",
		base = { length = 5776, estimate = 2244955, tight = 1, bridges = 1, bridgeLength = 115, tunnels = 0, tunnelLength = 0, sweep = 129 } },
	{ map = BIG_MAP, from = "Englewood", to = "Weston", mode = "fastest",
		stopsSeen = "Englewood, Sulphur, Weston",
		base = { length = 4771, estimate = 11759586, tight = 10, bridges = 3, bridgeLength = 1529, tunnels = 0, tunnelLength = 0, sweep = 177 } },
	{ map = BIG_MAP, from = "Gardner", to = "Herndon", mode = "cheapest",
		stopsSeen = "Gardner, Eldersburg, Pottstown, Herndon",
		base = { length = 7878, estimate = 2836021, tight = 1, bridges = 0, bridgeLength = 0, tunnels = 0, tunnelLength = 0, sweep = 87 } },
	{ map = BIG_MAP, from = "Gardner", to = "Herndon", mode = "fastest",
		stopsSeen = "Gardner, Eldersburg, Pottstown, Herndon",
		base = { length = 8054, estimate = 16637729, tight = 9, bridges = 6, bridgeLength = 974, tunnels = 1, tunnelLength = 493, sweep = 71 } },
	-- Failed no_path until station sites had to connect to open country: Bartlesville's lay 170 m from the map's
	-- south edge with buildings across its whole arriving side.
	{ map = BIG_MAP, from = "Durham", to = "Bartlesville", mode = "cheapest",
		stopsSeen = "Durham, Pasadena, Bartlesville", base = { length = 6711, estimate = 2415864, tight = 2, bridges = 0, bridgeLength = 0, tunnels = 0, tunnelLength = 0, sweep = 132 } },
	{ map = BIG_MAP, from = "Durham", to = "Bartlesville", mode = "fastest",
		stopsSeen = "Durham, Pasadena, Bartlesville", base = { length = 6789, estimate = 8564554, tight = 15, bridges = 3, bridgeLength = 285, tunnels = 0, tunnelLength = 0, sweep = 187 } },

	-- PottstownTown. Dover to Camarillo failed no_path in-game (Gillette to Pottstown, after two wider areas):
	-- Pottstown's site was clear but walled in, 18 cells with no way out. Then South Valley's station faced so the
	-- line hooked round into it, until stations were re-sited by their legs' costs.
	{ map = POTTSTOWN_MAP, from = "Dover", to = "Camarillo", mode = "cheapest", knownBlocked = 1,
		stopsSeen = "Dover, Bronx, New Bedford, Gillette, Pottstown, South Valley, Pullman, Silverdale, Hartford, Camarillo",
		base = { length = 24986, estimate = 9655580, tight = 11, bridges = 4, bridgeLength = 459, tunnels = 0, tunnelLength = 0, sweep = 208 } },
	{ map = POTTSTOWN_MAP, from = "Dover", to = "Camarillo", mode = "fastest", knownBlocked = 4,
		stopsSeen = "Dover, Bronx, New Bedford, Gillette, Pottstown, South Valley, Pullman, Silverdale, Hartford, Camarillo",
		base = { length = 25372, estimate = 49280954, tight = 56, bridges = 23, bridgeLength = 5065, tunnels = 0, tunnelLength = 0, sweep = 230 } },
	{ map = POTTSTOWN_MAP, from = "Gillette", to = "Pottstown", mode = "cheapest", stops = {},
		stopsSeen = "Gillette, Pottstown", base = { length = 1375, estimate = 667773, tight = 1, bridges = 1, bridgeLength = 120, tunnels = 0, tunnelLength = 0, sweep = 68 } },
	{ map = POTTSTOWN_MAP, from = "Elkhart", to = "Fernley", mode = "cheapest",
		stopsSeen = "Elkhart, West Haven, Brooklyn, Fernley", base = { length = 8815, estimate = 3173221, tight = 1, bridges = 0, bridgeLength = 0, tunnels = 0, tunnelLength = 0, sweep = 138 } },
	{ map = POTTSTOWN_MAP, from = "Elkhart", to = "Fernley", mode = "fastest",
		stopsSeen = "Elkhart, West Haven, Brooklyn, Fernley", base = { length = 8781, estimate = 15610309, tight = 15, bridges = 3, bridgeLength = 418, tunnels = 1, tunnelLength = 571, sweep = 143 } },
	{ map = POTTSTOWN_MAP, from = "Chicopee", to = "Colleyville", mode = "cheapest",
		stopsSeen = "Chicopee, Roswell, Des Moines, Colleyville", base = { length = 6506, estimate = 2342212, tight = 4, bridges = 0, bridgeLength = 0, tunnels = 0, tunnelLength = 0, sweep = 144 } },
	{ map = POTTSTOWN_MAP, from = "Chicopee", to = "Colleyville", mode = "fastest",
		stopsSeen = "Chicopee, Roswell, Des Moines, Colleyville", base = { length = 8627, estimate = 19699274, tight = 20, bridges = 3, bridgeLength = 1272, tunnels = 1, tunnelLength = 646, sweep = 192 } },

	-- New Game. Alliance to Aloha needed the wider area in-game (Turlock's first site was in a dead end); then the line
	-- hooked round into Owings Mills with an 8 m curve, until stations were re-sited by their legs' costs.
	-- Known, Cheapest: a 54 m curve (1 m under the build minimum) leaving Owings Mills, whose re-sited station faces
	-- west into buildings: the line leaves its end turning 112° (the move turns 90°, from the end point off its cell's
	-- centre more), and smoothing can round that corner at 54 m at most. Every site within reach of the town hooks
	-- round or leaves at such a corner; the free-turning search prices neither.
	{ map = NEWGAME_MAP, from = "Alliance", to = "Aloha", mode = "cheapest", knownBelow = 1, knownBlocked = 1,
		stopsSeen = "Alliance, Hemet, Turlock, Owings Mills, Aloha", base = { length = 13885, estimate = 6122831, tight = 10, bridges = 2, bridgeLength = 781, tunnels = 0, tunnelLength = 0, sweep = 219 } },
	{ map = NEWGAME_MAP, from = "Alliance", to = "Aloha", mode = "fastest",
		stopsSeen = "Alliance, Hemet, Turlock, Owings Mills, Aloha", base = { length = 11327, estimate = 24550290, tight = 21, bridges = 9, bridgeLength = 2851, tunnels = 0, tunnelLength = 0, sweep = 137 } },
	-- Known: leg 1 still hooks round into Los Altos (sweep 267°): re-siting both its stations found nothing cheaper, and
	-- the 55 m curves at Los Altos' arriving end cut a building's buffer (6 samples, guarded at the build minimum).
	{ map = NEWGAME_MAP, from = "Bossier City", to = "Ashland", mode = "cheapest", knownBlocked = 6,
		stopsSeen = "Bossier City, Los Altos, Fairborn, Ashland", base = { length = 8985, estimate = 3234525, tight = 5, bridges = 0, bridgeLength = 0, tunnels = 0, tunnelLength = 0, sweep = 267 } },
	{ map = NEWGAME_MAP, from = "Bossier City", to = "Ashland", mode = "fastest",
		stopsSeen = "Bossier City, Los Altos, Fairborn, Ashland", base = { length = 8956, estimate = 31091805, tight = 18, bridges = 4, bridgeLength = 2889, tunnels = 2, tunnelLength = 1183, sweep = 194 } },
	{ map = NEWGAME_MAP, from = "Galt", to = "Bell Gardens", mode = "cheapest",
		stopsSeen = "Galt, Bel Air North, Des Moines, Bell Gardens", base = { length = 6374, estimate = 2294498, tight = 3, bridges = 0, bridgeLength = 0, tunnels = 0, tunnelLength = 0, sweep = 81 } },
	{ map = NEWGAME_MAP, from = "Galt", to = "Bell Gardens", mode = "fastest",
		stopsSeen = "Galt, Bel Air North, Des Moines, Bell Gardens", base = { length = 6463, estimate = 14051924, tight = 9, bridges = 5, bridgeLength = 1637, tunnels = 0, tunnelLength = 0, sweep = 86 } },

	-- NewGame2: early and lightly built, lots of water.
	{ map = NEWGAME2_MAP, from = "Adelanto", to = "Deltona", mode = "cheapest",
		stopsSeen = "Adelanto, Middle River, Great Falls, Deltona", base = { length = 11953, estimate = 4539411, tight = 10, bridges = 2, bridgeLength = 164, tunnels = 0, tunnelLength = 0, sweep = 165 } },
	{ map = NEWGAME2_MAP, from = "Adelanto", to = "Deltona", mode = "fastest",
		stopsSeen = "Adelanto, Middle River, Great Falls, Deltona", base = { length = 9595, estimate = 30450128, tight = 15, bridges = 6, bridgeLength = 4650, tunnels = 0, tunnelLength = 0, sweep = 90 } },
	{ map = NEWGAME2_MAP, from = "Cornelius", to = "Perth Amboy", mode = "cheapest",
		stopsSeen = "Cornelius, Salinas, Oshkosh, Bonney Lake, Perth Amboy", base = { length = 11072, estimate = 3986080, tight = 3, bridges = 0, bridgeLength = 0, tunnels = 0, tunnelLength = 0, sweep = 100 } },
	{ map = NEWGAME2_MAP, from = "Cornelius", to = "Perth Amboy", mode = "fastest",
		stopsSeen = "Cornelius, Salinas, Oshkosh, Bonney Lake, Perth Amboy", base = { length = 10615, estimate = 26202146, tight = 11, bridges = 5, bridgeLength = 1265, tunnels = 2, tunnelLength = 1227, sweep = 82 } },
}

-- The in-game route captures beside the maps, and how far the maps are from them (tools/compare_capture.lua's
-- figures): cells that differ, and the mean and max height difference (m).
local CAPTURES = {
	{ map = TEST_MAP, capture = "rail-router-test-5x14km.bangor-imperial-beach.capture", water = 3, meanHeight = 0.01,
		maxHeight = 2.61 },
	{ map = BIG_MAP, capture = "big-54-towns-16x16km.ames-bridgeport.capture", water = 13, meanHeight = 0.19,
		maxHeight = 6.07 },
	-- One road cell differs: a street the map has and the in-game grid hadn't (at (-7166, 6042), the box's edge).
	{ map = POTTSTOWN_MAP, capture = "pottstowntown-16x16km.dover-camarillo.capture", water = 102, road = 1,
		meanHeight = 0.20, maxHeight = 12.20 },
	{ map = NEWGAME_MAP, capture = "newgame-16x16km.alliance-aloha.capture", water = 37, meanHeight = 0.15,
		maxHeight = 5.73 },
	{ map = NEWGAME2_MAP, capture = "newgame2-16x16km.adelanto-deltona.capture", water = 70, meanHeight = 0.28,
		maxHeight = 5.58 },
	{ map = NEWGAME2_MAP, capture = "newgame2-16x16km.cornelius-perth-amboy.capture", water = 10, meanHeight = 0.14,
		maxHeight = 3.55 },
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
	if rt.stops and #rt.stops > 0 then
		name = name .. " via " .. table.concat(rt.stops, ", ")
	elseif rt.stops then
		name = name .. " with no stops between"
	end
	return name .. " (" .. rt.map .. ")"
end

local function noWorse(label, now, base, share, slack)
	t.ok(base ~= nil, label .. ": no baseline recorded")
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
			if recording then
				print(("RECORD %s stops %s"):format(routeName(rt), table.concat(names, ", ")))
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
			local sweep = 0
			for __, v in ipairs(lib.sweep(plan)) do
				sweep = math.max(sweep, v)
			end
			if recording then
				print(("RECORD %s\n\t\tbase = { length = %.0f, estimate = %.0f, tight = %d, bridges = %d, bridgeLength = %.0f, tunnels = %d, tunnelLength = %.0f, sweep = %.0f } },"):format(
					routeName(rt), s.length, s.estimate, s.tightCurves, s.bridges, s.bridgeLength, s.tunnels, s.tunnelLength,
					sweep))
			end
			local below = lib.arcsBelow(plan, r.weights.minBuildRadius)
			local list = {}
			for __, arc in ipairs(below) do
				table.insert(list, ("leg %d: %.0f m at (%.0f, %.0f)"):format(arc.leg, arc.radius, arc.a.x, arc.a.y))
			end
			t.eq(#below, rt.knownBelow or 0, "arcs below " .. r.weights.minBuildRadius .. " m: " .. table.concat(list, "; "))
			local blocked = lib.blockedSamples(r)
			t.eq(#blocked, rt.knownBlocked or 0, "samples on blocked cells")
			local b = rt.base
			noWorse("widest sweep of a leg (a loop or a hook?)", sweep, b.sweep, 0, SWEEP_SLACK)
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
			t.eq(differ.road, c.road or 0, c.capture .. " road")
			t.eq(differ.track, 0, c.capture .. " track")
			t.ok(differ.water <= c.water, c.capture .. " water " .. differ.water)
			t.ok(sum / n <= c.meanHeight + 0.005, ("%s mean height difference %.3f"):format(c.capture, sum / n))
			t.ok(max <= c.maxHeight + 0.01, ("%s max height difference %.2f"):format(c.capture, max))
		end
	end)
end

print(("regression: %s set, %.1f s%s"):format(full and "full" or "quick", os.clock() - started,
	#better > 0 and ("; better than the baseline, re-record: " .. table.concat(better, "; ")) or ""))
