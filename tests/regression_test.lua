local t = ...
-- Regression routes on the kit's shared maps (../maps/, maps/README.md there), planned offline exactly as the window
-- plans them (tools/replaylib.lua). For every route:
--   * the plan is ok, or fails the way it is recorded to (expectFailure);
--   * the stops are the ones recorded (corridor selection);
--   * no arc is tighter than the track's build minimum (weights.minBuildRadius, 55 m);
--   * no sample lies on a blocked cell (unless a known number is recorded, with why);
--   * no leg's heading swings (replaylib.sweep) more than SWEEP_SLACK past the baseline's widest: a leg that starts
--     to loop or hook round into a station shows here first;
--   * no single route.step takes longer than STEP_BUDGET_MS, nor allocates more than STEP_ALLOC_KB;
--   * length, estimate, tight curves, bridges and tunnels, and the seconds a train stopping at every station loses to
--     curves below the mode's radius (route.Summary.timeLost, planner/speed.tl) are no worse than the baseline by more
--     than TOLERANCE.
-- `just test` runs the routes marked quick (the test map, well under a second); `just regress` runs them all (the
-- 54-town map too, and checks the maps against the in-game route captures beside them).
--
-- Re-recording the baselines, after a change that makes plans better (or worse on purpose): run
--   RAIL_ROUTER_REGRESS=full RAIL_ROUTER_RECORD=1 lua tools/test.lua | grep "^RECORD"
-- and paste each printed `base = {...}` over the route's own below. Say in the commit why the figures moved.

-- The kit's maps: RAIL_ROUTER_MAPS if set, else ../maps beside the repo; from a worktree (.worktrees/<name>), beside
-- the main checkout, found through git's common directory.
local function findMapsDir()
	local env = os.getenv("RAIL_ROUTER_MAPS")
	if env ~= nil and env ~= "" then
		return env
	end
	local dir = t.root .. "/../maps"
	local f = io.open(dir .. "/README.md", "r")
	if f ~= nil then
		f:close()
		return dir
	end
	local p = io.popen('git -C "' .. t.root .. '" rev-parse --path-format=absolute --git-common-dir 2>/dev/null')
	local common = p and p:read("l")
	if p then
		p:close()
	end
	if common ~= nil and common:match("/%.git$") then
		return common:sub(1, -6) .. "/../maps"
	end
	return dir
end
local mapsDir = findMapsDir()
local full = os.getenv("RAIL_ROUTER_REGRESS") == "full"
local recording = os.getenv("RAIL_ROUTER_RECORD") == "1"

-- The longest single route.step allowed, desktop milliseconds at the window's 150 expansions a step, garbage
-- collection left out (replaylib.runPlan). The slowest seen on these routes is about 3 ms (fitting a Fastest leg's
-- curves up to 6 ms run alone); in-game Lua runs about 4 times slower, so 10 ms here is about 40 ms in-game: a step
-- that would show as a hitch, well clear of timing noise on a busy desktop.
local STEP_BUDGET_MS = 10.0
-- The most a single route.step may allocate (KB; replaylib's alloc.max). Unlike time, allocation is the same on every
-- run, and in-game it costs about as much again in garbage collection: the game's Lua 5.2 pays a step's collection
-- debt, work in proportion to what it allocated, at its next allocation, and over the game's whole heap. A search
-- once allocated up to 1.7 MB in one step (its tables doubling as it grew; now in the grid's store), and fitting a
-- leg's curves 856 KB (a point per guard check); the most now is about 600 KB (a re-siting step building a
-- candidate's leg).
local STEP_ALLOC_KB = 768
-- The most steps in a row the progress bar's whole percent may stand still (replaylib's alloc.longestStall). In-game
-- the window runs about 1,250 steps a second (New Game's Alliance → Aloha, Fastest: 6,781 steps in 5.4 s), so this is
-- about a second. Before the bar crept on through work of unknown length (re-siting, radius tries finding no path),
-- that route held at 61% for 2,900 steps and Dover → Camarillo (Fastest) at 75% for 4,000.
local MAX_STALL_STEPS = 1200
-- How much worse than the baseline a figure may get: lengths and estimates as a share; tight curves, and bridges
-- plus tunnels, as a count; their length as a share, at least STRUCTURE_SLACK metres.
local TOLERANCE = { length = 0.02, estimate = 0.03, tight = 1, structures = 1, structureLength = 0.10, timeLost = 0.10 }
local STRUCTURE_SLACK = 100.0
-- Seconds of time lost to curves the baseline may be exceeded by besides its share.
local TIME_SLACK = 3.0

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
-- (m), sweep (the widest any leg's heading swings, degrees), timeLost (seconds, Summary.timeLost). Recorded
-- 2026-10-17 (mod commit after the pocketed-site, area and re-siting fixes); re-recorded the same day for the
-- cost-optimal height profile (Fastest estimates down by up to 27%, 5% over the set; Cheapest unchanged but Pensacola →
-- Columbus, 5% down); and again for corners priced by their curves' room (feat/turn-pricing): no curve below the build
-- minimum and 1 sample on a blocked cell left (of 17), estimates 2.6% up over the set (paths that cut corners or curved
-- below the build minimum no longer count), Alliance → Aloha, Fastest 29% up (no hook left to re-site its stations),
-- Bossier City → Ashland, Cheapest 62% up (its leg no longer crosses its own station). And again for Fastest's search
-- radii (feat/fastest-speed: each try's rooms to turn sized for its own radius, tries weighed by cost and the time
-- their curves lose, slow legs' stations re-sited): Cheapest unchanged; Fastest 58% less time lost to tight curves
-- (1017 s to 423 s over its 15 routes), estimates 14% down, tight curves 253 to 230. And again for re-siting weighed
-- by cost and time (fix/fastest-ingame: in Fastest, each candidate's legs weighed as they would be built, every radius
-- tried, by cost plus the time they lose, the current site's built legs as built, and no candidate taken that loses
-- more time): Cheapest byte-identical; Fastest 6% less time lost (423 s to 398 s), estimates 1.3% up, tight curves
-- 230 to 235; Alliance → Aloha 41 s to 21 s, Elkhart → Fernley 55 s to 43 s, Englewood → Weston 7 s to 13 s.
local ROUTES = {
	{ map = TEST_MAP, from = "Bangor", to = "Imperial Beach", mode = "cheapest", track = "Standard Tracks", quick = true,
		stopsSeen = "Bangor, Mercer Island, Antelope, Aloha, Imperial Beach",
		base = { length = 14988, estimate = 5572157, tight = 2, bridges = 1, bridgeLength = 123, tunnels = 0, tunnelLength = 0, sweep = 96, timeLost = 0.0 } },
	{ map = TEST_MAP, from = "Bangor", to = "Imperial Beach", mode = "cheapest", track = "Standard Tracks", quick = true,
		stops = { "Antelope", "Aloha" }, stopsSeen = "Bangor, Antelope, Aloha, Imperial Beach",
		base = { length = 12906, estimate = 4780067, tight = 0, bridges = 1, bridgeLength = 93, tunnels = 0, tunnelLength = 0, sweep = 97, timeLost = 0.0 } },
	{ map = TEST_MAP, from = "Bangor", to = "Imperial Beach", mode = "fastest", track = "High-Speed Tracks", quick = true,
		stopsSeen = "Bangor, Mercer Island, Antelope, Aloha, Imperial Beach",
		base = { length = 14219, estimate = 19183814, tight = 6, bridges = 3, bridgeLength = 886, tunnels = 0, tunnelLength = 0, sweep = 96, timeLost = 16.3 } },
	{ map = TEST_MAP, from = "Bangor", to = "Imperial Beach", mode = "fastest", track = "High-Speed Tracks", quick = true,
		stops = { "Antelope", "Aloha" }, stopsSeen = "Bangor, Antelope, Aloha, Imperial Beach",
		base = { length = 12402, estimate = 16074028, tight = 8, bridges = 3, bridgeLength = 620, tunnels = 0, tunnelLength = 0, sweep = 72, timeLost = 3.8 } },

	{ map = BIG_MAP, from = "Ames", to = "Bridgeport", mode = "cheapest", track = "Standard Tracks",
		stopsSeen = "Ames, Foster City, Temple City, Miami, Bridgeport",
		base = { length = 11406, estimate = 4284095, tight = 5, bridges = 2, bridgeLength = 124, tunnels = 0, tunnelLength = 0, sweep = 135, timeLost = 9.5 } },
	-- Before the fixes: an 8 m and a 48 m curve, and 2 samples on blocked cells (a loop between Temple City and Miami).
	{ map = BIG_MAP, from = "Ames", to = "Bridgeport", mode = "fastest", track = "High-Speed Tracks",
		stopsSeen = "Ames, Foster City, Temple City, Miami, Bridgeport",
		base = { length = 11650, estimate = 26653872, tight = 23, bridges = 10, bridgeLength = 1778, tunnels = 1, tunnelLength = 845, sweep = 127, timeLost = 36.6 } },
	{ map = BIG_MAP, from = "Pensacola", to = "Columbus", mode = "cheapest",
		stopsSeen = "Pensacola, Napa, Novato, Columbus",
		base = { length = 7156, estimate = 2576328, tight = 4, bridges = 0, bridgeLength = 0, tunnels = 0, tunnelLength = 0, sweep = 107, timeLost = 10.8 } },
	-- Had 4 samples on a blocked cell just past Napa, until the search priced corners by their curves' room: buildings
	-- pull Napa's room to turn back to 3 m, and the grid path jogged 78° right then 77° left 66 m apart.
	{ map = BIG_MAP, from = "Pensacola", to = "Columbus", mode = "fastest",
		stopsSeen = "Pensacola, Napa, Novato, Columbus",
		base = { length = 7118, estimate = 13953801, tight = 11, bridges = 2, bridgeLength = 1451, tunnels = 0, tunnelLength = 0, sweep = 109, timeLost = 4.5 } },
	{ map = BIG_MAP, from = "Englewood", to = "Weston", mode = "cheapest",
		stopsSeen = "Englewood, Sulphur, Weston",
		base = { length = 4699, estimate = 1906869, tight = 1, bridges = 1, bridgeLength = 149, tunnels = 0, tunnelLength = 0, sweep = 128, timeLost = 3.0 } },
	-- Was 7.3 s lost and 7.6 M, with Sulphur re-sited by cost alone for a leg out that lost 28 s, until Weston's
	-- re-siting mended that leg. Re-siting by cost and time, with no more time lost, keeps Sulphur where it was.
	{ map = BIG_MAP, from = "Englewood", to = "Weston", mode = "fastest",
		stopsSeen = "Englewood, Sulphur, Weston",
		base = { length = 4324, estimate = 10312187, tight = 10, bridges = 4, bridgeLength = 1306, tunnels = 0, tunnelLength = 0, sweep = 142, timeLost = 12.8 } },
	{ map = BIG_MAP, from = "Gardner", to = "Herndon", mode = "cheapest",
		stopsSeen = "Gardner, Eldersburg, Pottstown, Herndon",
		base = { length = 7906, estimate = 2846207, tight = 1, bridges = 0, bridgeLength = 0, tunnels = 0, tunnelLength = 0, sweep = 87, timeLost = 2.0 } },
	-- Known: 1 sample on a blocked cell, where a straight between Gardner and Eldersburg grazes the corner of a
	-- building's buffer (the samples fall between the guard's checks).
	{ map = BIG_MAP, from = "Gardner", to = "Herndon", mode = "fastest", knownBlocked = 1,
		stopsSeen = "Gardner, Eldersburg, Pottstown, Herndon",
		base = { length = 7834, estimate = 16307456, tight = 12, bridges = 7, bridgeLength = 771, tunnels = 1, tunnelLength = 598, sweep = 72, timeLost = 28.1 } },
	-- Failed no_path until station sites had to connect to open country: Bartlesville's lay 170 m from the map's
	-- south edge with buildings across its whole arriving side.
	{ map = BIG_MAP, from = "Durham", to = "Bartlesville", mode = "cheapest",
		stopsSeen = "Durham, Pasadena, Bartlesville", base = { length = 6794, estimate = 2445734, tight = 2, bridges = 0, bridgeLength = 0, tunnels = 0, tunnelLength = 0, sweep = 132, timeLost = 2.2 } },
	{ map = BIG_MAP, from = "Durham", to = "Bartlesville", mode = "fastest",
		stopsSeen = "Durham, Pasadena, Bartlesville", base = { length = 6470, estimate = 8110025, tight = 15, bridges = 1, bridgeLength = 260, tunnels = 0, tunnelLength = 0, sweep = 155, timeLost = 48.5 } },

	-- PottstownTown. Dover to Camarillo failed no_path in-game (Gillette to Pottstown, after two wider areas):
	-- Pottstown's site was clear but walled in, 18 cells with no way out. Then South Valley's station faced so the
	-- line hooked round into it, until stations were re-sited by their legs' costs.
	{ map = POTTSTOWN_MAP, from = "Dover", to = "Camarillo", mode = "cheapest",
		stopsSeen = "Dover, Bronx, New Bedford, Gillette, Pottstown, South Valley, Pullman, Silverdale, Hartford, Camarillo",
		base = { length = 25046, estimate = 9800705, tight = 11, bridges = 4, bridgeLength = 544, tunnels = 0, tunnelLength = 0, sweep = 230, timeLost = 25.3 } },
	-- Fastest used to have 1 sample on a blocked cell 130 m before Silverdale's platforms (the curve onto them, held
	-- at the build minimum by the guard, clipped a building's buffer), until re-siting weighed time.
	{ map = POTTSTOWN_MAP, from = "Dover", to = "Camarillo", mode = "fastest",
		stopsSeen = "Dover, Bronx, New Bedford, Gillette, Pottstown, South Valley, Pullman, Silverdale, Hartford, Camarillo",
		base = { length = 25171, estimate = 46251313, tight = 51, bridges = 25, bridgeLength = 4241, tunnels = 1, tunnelLength = 98, sweep = 230, timeLost = 128.1 } },
	{ map = POTTSTOWN_MAP, from = "Gillette", to = "Pottstown", mode = "cheapest", stops = {},
		stopsSeen = "Gillette, Pottstown", base = { length = 1375, estimate = 667773, tight = 1, bridges = 1, bridgeLength = 120, tunnels = 0, tunnelLength = 0, sweep = 68, timeLost = 0.0 } },
	{ map = POTTSTOWN_MAP, from = "Elkhart", to = "Fernley", mode = "cheapest",
		stopsSeen = "Elkhart, West Haven, Brooklyn, Fernley", base = { length = 8815, estimate = 3173221, tight = 1, bridges = 0, bridgeLength = 0, tunnels = 0, tunnelLength = 0, sweep = 138, timeLost = 3.5 } },
	{ map = POTTSTOWN_MAP, from = "Elkhart", to = "Fernley", mode = "fastest",
		stopsSeen = "Elkhart, West Haven, Brooklyn, Fernley", base = { length = 8890, estimate = 13751426, tight = 17, bridges = 4, bridgeLength = 532, tunnels = 1, tunnelLength = 245, sweep = 155, timeLost = 42.5 } },
	{ map = POTTSTOWN_MAP, from = "Chicopee", to = "Colleyville", mode = "cheapest",
		stopsSeen = "Chicopee, Roswell, Des Moines, Colleyville", base = { length = 6494, estimate = 2337671, tight = 4, bridges = 0, bridgeLength = 0, tunnels = 0, tunnelLength = 0, sweep = 147, timeLost = 4.8 } },
	{ map = POTTSTOWN_MAP, from = "Chicopee", to = "Colleyville", mode = "fastest",
		stopsSeen = "Chicopee, Roswell, Des Moines, Colleyville", base = { length = 7566, estimate = 17754358, tight = 13, bridges = 4, bridgeLength = 1107, tunnels = 2, tunnelLength = 635, sweep = 103, timeLost = 13.3 } },

	-- New Game. Alliance to Aloha needed the wider area in-game (Turlock's first site was in a dead end); then the line
	-- hooked round into Owings Mills with an 8 m curve, until stations were re-sited by their legs' costs.
	-- Known, Cheapest: leg 3 loops round into Owings Mills (sweep 438°). Re-siting it weighed the west-facing site the
	-- free-turning search used to take, but the line can't leave that one towards Aloha without a curve below the build
	-- minimum (a 54 m one then): every site within reach of the town hooks round or leaves at such a corner, and the
	-- loop is the cheapest that can be built.
	{ map = NEWGAME_MAP, from = "Alliance", to = "Aloha", mode = "cheapest",
		stopsSeen = "Alliance, Hemet, Turlock, Owings Mills, Aloha", base = { length = 14306, estimate = 6467178, tight = 13, bridges = 3, bridgeLength = 915, tunnels = 0, tunnelLength = 0, sweep = 438, timeLost = 33.6 } },
	-- Fastest: every leg used to fall back to the Cheapest radius (the tries' rooms to turn were sized for 3 km), and
	-- leg 3 crossed the bay in sharp turns between bridges and hooked into Owings Mills, whose arriving end buildings
	-- wall in: the line lost 75 s to its curves (26 tight). Then its slow leg had Owings Mills re-sited on the bay's
	-- east shore, facing west: leg 3 runs north over land at a 375 m search radius (4 s lost), and the line lost 41 s.
	-- Now re-siting weighs time too, and Hemet faces west: leg 2 loses nothing (it lost 23 s), the line 21 s.
	{ map = NEWGAME_MAP, from = "Alliance", to = "Aloha", mode = "fastest", maxTimeLost = 25,
		stopsSeen = "Alliance, Hemet, Turlock, Owings Mills, Aloha", base = { length = 11366, estimate = 25629715, tight = 24, bridges = 7, bridgeLength = 3091, tunnels = 0, tunnelLength = 0, sweep = 106, timeLost = 21.2 } },
	-- Leg 1 used to hook round into Los Altos (sweep 267°) over Bossier City's own station and through a building's
	-- buffer (6 samples). Now it keeps off the stations and goes round the lake (62% dearer, the line's honest price).
	-- Known: 1 sample on a blocked cell at Ashland's arriving end, where the curve onto the platforms, held at the build
	-- minimum by the guard, clips the corner of a building's buffer.
	{ map = NEWGAME_MAP, from = "Bossier City", to = "Ashland", mode = "cheapest", knownBlocked = 1,
		stopsSeen = "Bossier City, Los Altos, Fairborn, Ashland", base = { length = 9990, estimate = 5251566, tight = 9, bridges = 2, bridgeLength = 1149, tunnels = 0, tunnelLength = 0, sweep = 198, timeLost = 28.1 } },
	{ map = NEWGAME_MAP, from = "Bossier City", to = "Ashland", mode = "fastest",
		stopsSeen = "Bossier City, Los Altos, Fairborn, Ashland", base = { length = 8141, estimate = 22814850, tight = 14, bridges = 4, bridgeLength = 3246, tunnels = 0, tunnelLength = 0, sweep = 141, timeLost = 6.5 } },
	{ map = NEWGAME_MAP, from = "Galt", to = "Bell Gardens", mode = "cheapest",
		stopsSeen = "Galt, Bel Air North, Des Moines, Bell Gardens", base = { length = 6374, estimate = 2294498, tight = 3, bridges = 0, bridgeLength = 0, tunnels = 0, tunnelLength = 0, sweep = 81, timeLost = 3.2 } },
	{ map = NEWGAME_MAP, from = "Galt", to = "Bell Gardens", mode = "fastest",
		stopsSeen = "Galt, Bel Air North, Des Moines, Bell Gardens", base = { length = 6335, estimate = 11930333, tight = 6, bridges = 6, bridgeLength = 1178, tunnels = 0, tunnelLength = 0, sweep = 76, timeLost = 10.8 } },

	-- NewGame2: early and lightly built, lots of water.
	{ map = NEWGAME2_MAP, from = "Adelanto", to = "Deltona", mode = "cheapest",
		stopsSeen = "Adelanto, Middle River, Great Falls, Deltona", base = { length = 12703, estimate = 4922322, tight = 9, bridges = 4, bridgeLength = 243, tunnels = 0, tunnelLength = 0, sweep = 165, timeLost = 27.4 } },
	{ map = NEWGAME2_MAP, from = "Adelanto", to = "Deltona", mode = "fastest",
		stopsSeen = "Adelanto, Middle River, Great Falls, Deltona", base = { length = 10518, estimate = 22396497, tight = 14, bridges = 6, bridgeLength = 2555, tunnels = 0, tunnelLength = 0, sweep = 120, timeLost = 12.9 } },
	{ map = NEWGAME2_MAP, from = "Cornelius", to = "Perth Amboy", mode = "cheapest",
		stopsSeen = "Cornelius, Salinas, Oshkosh, Bonney Lake, Perth Amboy", base = { length = 10444, estimate = 3759909, tight = 6, bridges = 0, bridgeLength = 0, tunnels = 0, tunnelLength = 0, sweep = 114, timeLost = 16.8 } },
	{ map = NEWGAME2_MAP, from = "Cornelius", to = "Perth Amboy", mode = "fastest",
		stopsSeen = "Cornelius, Salinas, Oshkosh, Bonney Lake, Perth Amboy", base = { length = 10505, estimate = 17604161, tight = 11, bridges = 6, bridgeLength = 783, tunnels = 1, tunnelLength = 380, sweep = 80, timeLost = 11.7 } },
}

-- In-game route captures planned as captured (not on the maps: their saves have changed since the maps were
-- captured, so they aren't in CAPTURES), with the same checks and a baseline of their own.
local CAPTURE_ROUTES = {
	-- New Game in 2154 (a year after the map), Fastest, High-Speed. In-game the slowest legs step took 48.7 ms here.
	-- Known slow: leg 3 (Turlock → Owings Mills) loses 56 s, threading a bay studded with buildings and hooking
	-- round into Owings Mills. Re-siting weighs every Owings Mills site within reach: the one west-facing site whose
	-- leg in is fast (6 s) can't be left towards Aloha (its leaving end is walled in), and the others lose more time;
	-- Turlock's sites all lose 48 s or more on that leg.
	{ capture = "newgame-16x16km.alliance-aloha-fastest-2154.capture", maxTimeLost = 95, maxTight = 28,
		stopsSeen = "Alliance, Hemet, Turlock, Owings Mills, Aloha",
		base = { length = 11459, estimate = 28948170, tight = 27, bridges = 11, bridgeLength = 3312, tunnels = 1, tunnelLength = 300, sweep = 180, timeLost = 90.7 } },
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
local arrows = t.requireTl("gui/pgrace_rail_router/planner/arrows.tl")
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

-- The checks every route gets (see the top), on its plan (replaylib's result from planFn()). A step over the time
-- budget is timed again on up to two more runs, and the fastest counts: on a busy desktop a step is sometimes
-- descheduled part-way (28 ms once for a step that takes 1.3 ms).
local function check(rt, planFn, name)
	local r = planFn()
	local worst = r.worstStep
	for __ = 1, 2 do
		if worst <= STEP_BUDGET_MS then
			break
		end
		worst = math.min(worst, planFn().worstStep)
	end
	local names = {}
	for __, town in ipairs(r.stops) do
		table.insert(names, town.name)
	end
	if recording then
		print(("RECORD %s stops %s"):format(name, table.concat(names, ", ")))
	end
	t.eq(table.concat(names, ", "), rt.stopsSeen, "stops")
	t.ok(worst <= STEP_BUDGET_MS, ("slowest step %.2f ms (%s), budget %.0f"):format(worst,
		tostring(r.alloc.worstKind), STEP_BUDGET_MS))
	t.ok(r.alloc.max <= STEP_ALLOC_KB, ("most allocated in a step %.0f KB (%s), at most %.0f"):format(r.alloc.max,
		tostring(r.alloc.maxKind), STEP_ALLOC_KB))
	t.ok(r.alloc.longestStall <= MAX_STALL_STEPS, ("progress bar stood still for %d steps, at most %d"):format(
		r.alloc.longestStall, MAX_STALL_STEPS))
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
		print(("RECORD %s\n\t\tbase = { length = %.0f, estimate = %.0f, tight = %d, bridges = %d, bridgeLength = %.0f, tunnels = %d, tunnelLength = %.0f, sweep = %.0f, timeLost = %.1f } },"):format(
			name, s.length, s.estimate, s.tightCurves, s.bridges, s.bridgeLength, s.tunnels, s.tunnelLength,
			sweep, s.timeLost))
	end
	local below = lib.arcsBelow(plan, r.weights.minBuildRadius)
	local list = {}
	for __, arc in ipairs(below) do
		table.insert(list, ("leg %d: %.0f m at (%.0f, %.0f)"):format(arc.leg, arc.radius, arc.a.x, arc.a.y))
	end
	t.eq(#below, rt.knownBelow or 0, "arcs below " .. r.weights.minBuildRadius .. " m: " .. table.concat(list, "; "))
	local blocked = lib.blockedSamples(r)
	t.eq(#blocked, rt.knownBlocked or 0, "samples on blocked cells")
	-- The preview's arrows (100 m chords, at least 25 m: shorter ones crash the game).
	for li, leg in ipairs(plan.legs) do
		for __, a in ipairs(arrows.split(leg, 100, 25)) do
			local d = math.sqrt((leg.samples[a.j].p.x - leg.samples[a.i].p.x) ^ 2
				+ (leg.samples[a.j].p.y - leg.samples[a.i].p.y) ^ 2)
			t.ok(d >= 25 - 1e-9, ("leg %d: a %.1f m preview arrow"):format(li, d))
		end
	end
	local b = rt.base
	noWorse("widest sweep of a leg (a loop or a hook?)", sweep, b.sweep, 0, SWEEP_SLACK)
	noWorse("length", s.length, b.length, TOLERANCE.length)
	noWorse("estimate", s.estimate, b.estimate, TOLERANCE.estimate)
	noWorse("tight curves", s.tightCurves, b.tight, 0, TOLERANCE.tight)
	noWorse("bridges and tunnels", s.bridges + s.tunnels, b.bridges + b.tunnels, 0, TOLERANCE.structures)
	local structure = b.bridgeLength + b.tunnelLength
	noWorse("bridge and tunnel length", s.bridgeLength + s.tunnelLength, structure, TOLERANCE.structureLength,
		STRUCTURE_SLACK)
	noWorse("seconds lost to tight curves", s.timeLost, b.timeLost, TOLERANCE.timeLost, TIME_SLACK)
	if rt.maxTimeLost ~= nil then
		t.ok(s.timeLost <= rt.maxTimeLost, ("seconds lost to tight curves %.1f, at most %.0f"):format(s.timeLost,
			rt.maxTimeLost))
	end
	if rt.maxTight ~= nil then
		t.ok(s.tightCurves <= rt.maxTight, ("tight curves %d, at most %d"):format(s.tightCurves, rt.maxTight))
	end
	if s.estimate < b.estimate * (1 - TOLERANCE.estimate) or s.length < b.length * (1 - TOLERANCE.length) then
		table.insert(better, name)
	end
end

for _, rt in ipairs(ROUTES) do
	if rt.quick or full then
		t.test("regression: " .. routeName(rt), function()
			check(rt, function()
				return lib.planOnMap(loadMap(rt.map), { from = rt.from, to = rt.to, mode = rt.mode, track = rt.track,
					stops = rt.stops })
			end, routeName(rt))
		end)
	end
end

-- The route captures planned as they are (lib.planCapture), on the save as it was then.
if full then
	for _, rt in ipairs(CAPTURE_ROUTES) do
		t.test("regression: " .. rt.capture, function()
			local c = lib.capture.load(mapsDir .. "/" .. rt.capture)
			check(rt, function()
				return lib.planCapture(c)
			end, rt.capture)
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
