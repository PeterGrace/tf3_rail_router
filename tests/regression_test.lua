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
-- The test map with Rail Router's first line (Bangor → Imperial Beach via Aloha, Halt 2+2, 320 m) built on it.
local TEST_LINE1_MAP = "rail-router-test-5x14km-line1.map"
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
-- And again for stations kept clear of the streets themselves (2026-10-19, an in-game "Collision" at Bangor): only
-- Ames → Bridgeport moved (Bridgeport's first site had a street under it, and re-siting from the new one ends
-- elsewhere): Cheapest 5.7% longer, 4 more tight curves; Fastest 6% longer, 8 s less lost to tight curves.
local ROUTES = {
	{ map = TEST_MAP, from = "Bangor", to = "Imperial Beach", mode = "cheapest", track = "Standard Tracks", quick = true,
		stopsSeen = "Bangor, Mercer Island, Antelope, Aloha, Imperial Beach",
		base = { length = 14988, estimate = 5185032, tight = 2, bridges = 2, bridgeLength = 269, tunnels = 0, tunnelLength = 0, sweep = 96, timeLost = 0.0 } },
	{ map = TEST_MAP, from = "Bangor", to = "Imperial Beach", mode = "cheapest", track = "Standard Tracks", quick = true,
		stops = { "Antelope", "Aloha" }, stopsSeen = "Bangor, Antelope, Aloha, Imperial Beach",
		base = { length = 12906, estimate = 4477023, tight = 0, bridges = 2, bridgeLength = 213, tunnels = 0, tunnelLength = 0, sweep = 97, timeLost = 0.0 } },
	{ map = TEST_MAP, from = "Bangor", to = "Imperial Beach", mode = "fastest", track = "High-Speed Tracks", quick = true,
		stopsSeen = "Bangor, Mercer Island, Antelope, Aloha, Imperial Beach",
		base = { length = 14219, estimate = 15386214, tight = 6, bridges = 3, bridgeLength = 1034, tunnels = 0, tunnelLength = 0, sweep = 96, timeLost = 16.3 } },
	{ map = TEST_MAP, from = "Bangor", to = "Imperial Beach", mode = "fastest", track = "High-Speed Tracks", quick = true,
		stops = { "Antelope", "Aloha" }, stopsSeen = "Bangor, Antelope, Aloha, Imperial Beach",
		base = { length = 12402, estimate = 13346385, tight = 8, bridges = 3, bridgeLength = 745, tunnels = 0, tunnelLength = 0, sweep = 72, timeLost = 3.8 } },

	-- In-game (2026-10-19, on the test map as it had grown), Bangor's station had its centre line in clear cells and
	-- its main building over two streets in the next cell ("Collision"); planned again on this map, main put it on
	-- the same spot. Stations now keep their width clear of the streets themselves.
	{ map = TEST_MAP, from = "Bangor", to = "Imperial Beach", mode = "cheapest", track = "Standard Tracks", quick = true,
		stops = { "Aloha" }, platform = 320, stopsSeen = "Bangor, Aloha, Imperial Beach",
		base = { length = 12596, estimate = 4423111, tight = 0, bridges = 2, bridgeLength = 213, tunnels = 0, tunnelLength = 0, sweep = 118, timeLost = 0.0 } },

	-- 4b's first in-game test, a second line beside the first: its 447 m bridge over the first line at a shallow
	-- angle dipped to 6.9 m above it in a cell not marked track ("Collision"); every route now checks its bridges'
	-- clearance over the maps' track.
	{ map = TEST_LINE1_MAP, from = "Aloha", to = "Mercer Island", mode = "cheapest", track = "Standard Tracks",
		quick = true, stops = { "Antelope" }, platform = 320, approach = 225, stopsSeen = "Aloha, Antelope, Mercer Island",
		base = { length = 8813, estimate = 3175951, tight = 2, bridges = 3, bridgeLength = 611, tunnels = 0, tunnelLength = 0, sweep = 127, timeLost = 1.2 } },
	-- 4c stage 1's in-game test, offline: a second line through Aloha joining its existing station (the first line's
	-- Halt 2+2) at both ends. Each end's stretch runs from the last crossover through the line's first curve; the
	-- junctions go on the straight past it (first cuts 397 and 347 m out from the platform ends). Recorded for 4c
	-- stage 1 (2026-10-19). Known heavy: the sites step reading Aloha's ends (existing.analyse walks and pairs both
	-- tracks out to 1.5 km at each end) allocates about 1.1 MB of the step's 1.45 MB, over STEP_ALLOC_KB; once per
	-- plan, 7 ms on the desktop. Its 3 tight curves aren't the junctions': an S-jog 205–356 m before Aloha's −1
	-- approach and a 130 m curve at Antelope's end (grid and search effects).
	{ map = TEST_LINE1_MAP, from = "Antelope", to = "Imperial Beach", mode = "cheapest", track = "Standard Tracks",
		quick = true, stops = { "Aloha" }, existing = { "Aloha" }, stopsSeen = "Antelope, Aloha, Imperial Beach",
		maxAllocKB = 1600,
		base = { length = 8473, estimate = 3131523, tight = 3, bridges = 5, bridgeLength = 683, tunnels = 0, tunnelLength = 0, sweep = 95, timeLost = 2.5 } },

	{ map = BIG_MAP, from = "Ames", to = "Bridgeport", mode = "cheapest", track = "Standard Tracks",
		stopsSeen = "Ames, Foster City, Temple City, Miami, Bridgeport",
		base = { length = 12051, estimate = 4171585, tight = 9, bridges = 5, bridgeLength = 421, tunnels = 0, tunnelLength = 0, sweep = 135, timeLost = 10.4 } },
	-- Before the fixes: an 8 m and a 48 m curve, and 2 samples on blocked cells (a loop between Temple City and Miami).
	{ map = BIG_MAP, from = "Ames", to = "Bridgeport", mode = "fastest", track = "High-Speed Tracks",
		stopsSeen = "Ames, Foster City, Temple City, Miami, Bridgeport",
		base = { length = 12375, estimate = 16003521, tight = 19, bridges = 8, bridgeLength = 1940, tunnels = 1, tunnelLength = 845, sweep = 127, timeLost = 28.7 } },
	{ map = BIG_MAP, from = "Pensacola", to = "Columbus", mode = "cheapest",
		stopsSeen = "Pensacola, Napa, Novato, Columbus",
		base = { length = 7223, estimate = 2439302, tight = 5, bridges = 2, bridgeLength = 241, tunnels = 0, tunnelLength = 0, sweep = 124, timeLost = 19.1 } },
	-- Had 4 samples on a blocked cell just past Napa, until the search priced corners by their curves' room: buildings
	-- pull Napa's room to turn back to 3 m, and the grid path jogged 78° right then 77° left 66 m apart.
	{ map = BIG_MAP, from = "Pensacola", to = "Columbus", mode = "fastest",
		stopsSeen = "Pensacola, Napa, Novato, Columbus",
		base = { length = 7118, estimate = 8269702, tight = 11, bridges = 2, bridgeLength = 1474, tunnels = 0, tunnelLength = 0, sweep = 109, timeLost = 4.5 } },
	{ map = BIG_MAP, from = "Englewood", to = "Weston", mode = "cheapest",
		stopsSeen = "Englewood, Sulphur, Weston",
		base = { length = 4699, estimate = 1648026, tight = 1, bridges = 2, bridgeLength = 448, tunnels = 0, tunnelLength = 0, sweep = 128, timeLost = 3.0 } },
	-- Was 7.3 s lost and 7.6 M, with Sulphur re-sited by cost alone for a leg out that lost 28 s, until Weston's
	-- re-siting mended that leg. Re-siting by cost and time, with no more time lost, keeps Sulphur where it was.
	{ map = BIG_MAP, from = "Englewood", to = "Weston", mode = "fastest",
		stopsSeen = "Englewood, Sulphur, Weston",
		base = { length = 4364, estimate = 5204258, tight = 8, bridges = 3, bridgeLength = 1169, tunnels = 0, tunnelLength = 0, sweep = 142, timeLost = 12.8 } },
	{ map = BIG_MAP, from = "Gardner", to = "Herndon", mode = "cheapest",
		stopsSeen = "Gardner, Eldersburg, Pottstown, Herndon",
		base = { length = 7906, estimate = 2745602, tight = 1, bridges = 5, bridgeLength = 451, tunnels = 0, tunnelLength = 0, sweep = 87, timeLost = 2.0 } },
	-- Known: 1 sample on a blocked cell, where a straight between Gardner and Eldersburg grazes the corner of a
	-- building's buffer (the samples fall between the guard's checks).
	{ map = BIG_MAP, from = "Gardner", to = "Herndon", mode = "fastest", knownBlocked = 1,
		stopsSeen = "Gardner, Eldersburg, Pottstown, Herndon",
		base = { length = 7834, estimate = 10018065, tight = 12, bridges = 7, bridgeLength = 1109, tunnels = 1, tunnelLength = 598, sweep = 72, timeLost = 28.1 } },
	-- Failed no_path until station sites had to connect to open country: Bartlesville's lay 170 m from the map's
	-- south edge with buildings across its whole arriving side.
	{ map = BIG_MAP, from = "Durham", to = "Bartlesville", mode = "cheapest",
		stopsSeen = "Durham, Pasadena, Bartlesville", base = { length = 6794, estimate = 2293984, tight = 2, bridges = 1, bridgeLength = 73, tunnels = 0, tunnelLength = 0, sweep = 132, timeLost = 2.2 } },
	{ map = BIG_MAP, from = "Durham", to = "Bartlesville", mode = "fastest",
		stopsSeen = "Durham, Pasadena, Bartlesville", base = { length = 6470, estimate = 6776747, tight = 15, bridges = 1, bridgeLength = 356, tunnels = 0, tunnelLength = 0, sweep = 155, timeLost = 48.5 } },

	-- PottstownTown. Dover to Camarillo failed no_path in-game (Gillette to Pottstown, after two wider areas):
	-- Pottstown's site was clear but walled in, 18 cells with no way out. Then South Valley's station faced so the
	-- line hooked round into it, until stations were re-sited by their legs' costs.
	{ map = POTTSTOWN_MAP, from = "Dover", to = "Camarillo", mode = "cheapest",
		stopsSeen = "Dover, Bronx, New Bedford, Gillette, Pottstown, South Valley, Pullman, Silverdale, Hartford, Camarillo",
		base = { length = 25058, estimate = 9247004, tight = 11, bridges = 14, bridgeLength = 2785, tunnels = 0, tunnelLength = 0, sweep = 230, timeLost = 25.3 } },
	-- Fastest used to have 1 sample on a blocked cell 130 m before Silverdale's platforms (the curve onto them, held
	-- at the build minimum by the guard, clipped a building's buffer), until re-siting weighed time.
	{ map = POTTSTOWN_MAP, from = "Dover", to = "Camarillo", mode = "fastest",
		stopsSeen = "Dover, Bronx, New Bedford, Gillette, Pottstown, South Valley, Pullman, Silverdale, Hartford, Camarillo",
		base = { length = 25161, estimate = 30719389, tight = 52, bridges = 23, bridgeLength = 6104, tunnels = 0, tunnelLength = 0, sweep = 230, timeLost = 118.8 } },
	{ map = POTTSTOWN_MAP, from = "Gillette", to = "Pottstown", mode = "cheapest", stops = {},
		stopsSeen = "Gillette, Pottstown", base = { length = 1375, estimate = 428182, tight = 1, bridges = 1, bridgeLength = 168, tunnels = 0, tunnelLength = 0, sweep = 68, timeLost = 0.0 } },
	{ map = POTTSTOWN_MAP, from = "Elkhart", to = "Fernley", mode = "cheapest",
		stopsSeen = "Elkhart, West Haven, Brooklyn, Fernley", base = { length = 8815, estimate = 3050154, tight = 1, bridges = 2, bridgeLength = 373, tunnels = 0, tunnelLength = 0, sweep = 138, timeLost = 3.5 } },
	{ map = POTTSTOWN_MAP, from = "Elkhart", to = "Fernley", mode = "fastest",
		stopsSeen = "Elkhart, West Haven, Brooklyn, Fernley", base = { length = 8890, estimate = 10378633, tight = 17, bridges = 4, bridgeLength = 1088, tunnels = 1, tunnelLength = 245, sweep = 155, timeLost = 42.5 } },
	{ map = POTTSTOWN_MAP, from = "Chicopee", to = "Colleyville", mode = "cheapest",
		stopsSeen = "Chicopee, Roswell, Des Moines, Colleyville", base = { length = 6494, estimate = 2169878, tight = 4, bridges = 2, bridgeLength = 217, tunnels = 0, tunnelLength = 0, sweep = 147, timeLost = 4.8 } },
	{ map = POTTSTOWN_MAP, from = "Chicopee", to = "Colleyville", mode = "fastest",
		stopsSeen = "Chicopee, Roswell, Des Moines, Colleyville", base = { length = 7566, estimate = 10013575, tight = 13, bridges = 4, bridgeLength = 1345, tunnels = 2, tunnelLength = 635, sweep = 103, timeLost = 13.3 } },

	-- New Game. Alliance to Aloha needed the wider area in-game (Turlock's first site was in a dead end); then the line
	-- hooked round into Owings Mills with an 8 m curve, until stations were re-sited by their legs' costs.
	-- Known, Cheapest: leg 3 loops round into Owings Mills (sweep 438°). Re-siting it weighed the west-facing site the
	-- free-turning search used to take, but the line can't leave that one towards Aloha without a curve below the build
	-- minimum (a 54 m one then): every site within reach of the town hooks round or leaves at such a corner, and the
	-- loop is the cheapest that can be built.
	{ map = NEWGAME_MAP, from = "Alliance", to = "Aloha", mode = "cheapest",
		stopsSeen = "Alliance, Hemet, Turlock, Owings Mills, Aloha", base = { length = 14306, estimate = 5326815, tight = 13, bridges = 10, bridgeLength = 1614, tunnels = 0, tunnelLength = 0, sweep = 438, timeLost = 33.6 } },
	-- Fastest: every leg used to fall back to the Cheapest radius (the tries' rooms to turn were sized for 3 km), and
	-- leg 3 crossed the bay in sharp turns between bridges and hooked into Owings Mills, whose arriving end buildings
	-- wall in: the line lost 75 s to its curves (26 tight). Then its slow leg had Owings Mills re-sited on the bay's
	-- east shore, facing west: leg 3 runs north over land at a 375 m search radius (4 s lost), and the line lost 41 s.
	-- Now re-siting weighs time too, and Hemet faces west: leg 2 loses nothing (it lost 23 s), the line 21 s.
	{ map = NEWGAME_MAP, from = "Alliance", to = "Aloha", mode = "fastest", maxTimeLost = 25,
		stopsSeen = "Alliance, Hemet, Turlock, Owings Mills, Aloha", base = { length = 11366, estimate = 14275783, tight = 24, bridges = 7, bridgeLength = 3316, tunnels = 0, tunnelLength = 0, sweep = 106, timeLost = 21.2 } },
	-- Leg 1 used to hook round into Los Altos (sweep 267°) over Bossier City's own station and through a building's
	-- buffer (6 samples). Now it keeps off the stations and goes round the lake (62% dearer, the line's honest price).
	-- Known: 1 sample on a blocked cell at Ashland's arriving end, where the curve onto the platforms, held at the build
	-- minimum by the guard, clips the corner of a building's buffer.
	{ map = NEWGAME_MAP, from = "Bossier City", to = "Ashland", mode = "cheapest", knownBlocked = 1,
		stopsSeen = "Bossier City, Los Altos, Fairborn, Ashland", base = { length = 9990, estimate = 3942632, tight = 9, bridges = 8, bridgeLength = 2002, tunnels = 0, tunnelLength = 0, sweep = 198, timeLost = 28.1 } },
	{ map = NEWGAME_MAP, from = "Bossier City", to = "Ashland", mode = "fastest",
		stopsSeen = "Bossier City, Los Altos, Fairborn, Ashland", base = { length = 8141, estimate = 11045970, tight = 14, bridges = 3, bridgeLength = 3409, tunnels = 0, tunnelLength = 0, sweep = 141, timeLost = 6.5 } },
	{ map = NEWGAME_MAP, from = "Galt", to = "Bell Gardens", mode = "cheapest",
		stopsSeen = "Galt, Bel Air North, Des Moines, Bell Gardens", base = { length = 6374, estimate = 2177789, tight = 3, bridges = 4, bridgeLength = 395, tunnels = 0, tunnelLength = 0, sweep = 81, timeLost = 3.2 } },
	{ map = NEWGAME_MAP, from = "Galt", to = "Bell Gardens", mode = "fastest",
		stopsSeen = "Galt, Bel Air North, Des Moines, Bell Gardens", base = { length = 6335, estimate = 7546663, tight = 6, bridges = 6, bridgeLength = 1616, tunnels = 0, tunnelLength = 0, sweep = 76, timeLost = 10.8 } },

	-- NewGame2: early and lightly built, lots of water.
	{ map = NEWGAME2_MAP, from = "Adelanto", to = "Deltona", mode = "cheapest",
		stopsSeen = "Adelanto, Middle River, Great Falls, Deltona", base = { length = 12703, estimate = 4723441, tight = 9, bridges = 10, bridgeLength = 1322, tunnels = 0, tunnelLength = 0, sweep = 165, timeLost = 27.4 } },
	{ map = NEWGAME2_MAP, from = "Adelanto", to = "Deltona", mode = "fastest",
		stopsSeen = "Adelanto, Middle River, Great Falls, Deltona", base = { length = 10518, estimate = 13613185, tight = 14, bridges = 7, bridgeLength = 3408, tunnels = 0, tunnelLength = 0, sweep = 120, timeLost = 12.9 } },
	{ map = NEWGAME2_MAP, from = "Cornelius", to = "Perth Amboy", mode = "cheapest",
		stopsSeen = "Cornelius, Salinas, Oshkosh, Bonney Lake, Perth Amboy", base = { length = 10444, estimate = 3548186, tight = 6, bridges = 3, bridgeLength = 265, tunnels = 0, tunnelLength = 0, sweep = 114, timeLost = 16.8 } },
	{ map = NEWGAME2_MAP, from = "Cornelius", to = "Perth Amboy", mode = "fastest",
		stopsSeen = "Cornelius, Salinas, Oshkosh, Bonney Lake, Perth Amboy", base = { length = 10505, estimate = 12335599, tight = 11, bridges = 7, bridgeLength = 1196, tunnels = 1, tunnelLength = 380, sweep = 80, timeLost = 11.7 } },
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
		base = { length = 11459, estimate = 15405686, tight = 27, bridges = 10, bridgeLength = 3758, tunnels = 1, tunnelLength = 300, sweep = 180, timeLost = 90.7 } },
	-- 4b's first in-game test (2026-10-19), as planned in-game, with the map's streets and track (captured 7 minutes
	-- later): its 447 m bridge over the first line at a shallow angle dipped to 6.9 m above it ("Collision").
	{ capture = "rail-router-test-5x14km-line1.aloha-mercer-island.capture", map = TEST_LINE1_MAP,
		stopsSeen = "Aloha, Antelope, Mercer Island",
		base = { length = 9329, estimate = 3246139, tight = 2, bridges = 4, bridgeLength = 810, tunnels = 0, tunnelLength = 0, sweep = 119, timeLost = 2.4 } },
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
	-- The 46 blocked cells are the bottom row, on the map's edge: off the map in-game, valid points in the map.
	{ map = TEST_LINE1_MAP, capture = "rail-router-test-5x14km-line1.aloha-mercer-island.capture", water = 5,
		blocked = 46, meanHeight = 0.02, maxHeight = 2.81 },
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
local network = t.requireTl("gui/pgrace_rail_router/planner/network.tl")
local maps = {}
local function loadMap(name)
	if maps[name] == nil then
		maps[name] = lib.maplib.load(mapsDir .. "/" .. name)
	end
	return maps[name]
end

-- The network as the window builds it with Halt 2+2 (window.script.tl settingsFor): a fan's two edges at each end of
-- every station of ours that a leg leaves or reaches, and no chunk problems. A curve's sample just before a fan's
-- merge once took the merge's place as a cut, and the fan was silently left out (Antelope's south end in-game).
-- `speed`: the track's top speed (m/s), which picks the turnout as the window's turnoutRadius does.
local function haltFans(plan, speed)
	local radius = speed < 30 and 150 or (speed < 60 and 300 or 600)
	local halt = network.defaults()
	halt.fan = network.turnoutLength(radius)
	halt.bareFan = halt.fan
	halt.blockSpacing = 500
	local net = network.build(plan, halt)
	local fans = {}
	for __, e in ipairs(net.edges) do
		if e.track == 3 then
			local key = e.leg .. (e.s0 == 0 and "s" or "e")
			fans[key] = (fans[key] or 0) + 1
		end
	end
	local stations = plan.stations or {}
	for li, leg in ipairs(plan.legs) do
		if not leg.linked and leg.length > 2 * (network.fanLength(halt.fan) + 1) then
			for __, k in ipairs({ "s", "e" }) do
				local st = stations[k == "s" and li or li + 1]
				if st == nil or st.existing == nil then
					t.eq(fans[li .. k] or 0, 2, ("Halt 2+2: leg %d's %s: fan edges"):format(li, k == "s" and "start" or "end"))
				end
			end
		end
	end
	for k, c in ipairs(net.chunks) do
		t.ok(c.problem == nil, ("Halt 2+2: chunk %d: %s"):format(k, tostring(c.problem)))
	end
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

-- Per map, its track's points (every 2 m, with heights) bucketed by 50 m square.
local trackPoints = {}
local function trackClearance(map, plan)
	local index = trackPoints[map]
	if index == nil then
		index = {}
		for __, e in ipairs(map.edges) do
			if e.kind == "t" and e.edgeType ~= "u" and e.t0 ~= nil and e.t1 ~= nil then
				local len = math.sqrt((e.p1.x - e.p0.x) ^ 2 + (e.p1.y - e.p0.y) ^ 2)
				local n = math.max(2, math.ceil(len / 2))
				for k = 0, n do
					local u = k / n
					local u2, u3 = u * u, u * u * u
					local a, b, c, d = 2 * u3 - 3 * u2 + 1, u3 - 2 * u2 + u, -2 * u3 + 3 * u2, u3 - u2
					local x = a * e.p0.x + b * e.t0.x + c * e.p1.x + d * e.t1.x
					local y = a * e.p0.y + b * e.t0.y + c * e.p1.y + d * e.t1.y
					local key = math.floor(x / 50) .. "," .. math.floor(y / 50)
					index[key] = index[key] or {}
					table.insert(index[key], { x, y, e.p0.z + (e.p1.z - e.p0.z) * u })
				end
			end
		end
		trackPoints[map] = index
	end
	local near = 15.0
	-- The least height over the track points within `near` of sample i of a leg (nil: none near), and how far the
	-- nearest track point is (in plan).
	local function over(leg, i)
		local smp, low, closest = leg.samples[i], nil, math.huge
		local bx, by = math.floor(smp.p.x / 50), math.floor(smp.p.y / 50)
		for kx = bx - 1, bx + 1 do
			for ky = by - 1, by + 1 do
				for __, q in ipairs(index[kx .. "," .. ky] or {}) do
					local d2 = (q[1] - smp.p.x) ^ 2 + (q[2] - smp.p.y) ^ 2
					if d2 <= near * near then
						low = math.min(low or math.huge, leg.z[i] - q[3])
						closest = math.min(closest, math.sqrt(d2))
					end
				end
			end
		end
		return low, closest
	end
	-- A leg at an existing station's junction starts (or ends) beside its track on purpose, on the ground 10 m off its
	-- midline (7.5 m from the near track): from that end, samples are left out until the first one clear of the track,
	-- but only beside it, not over it: one within CROSS_NEAR of a track point still counts.
	local CROSS_NEAR = 6.0
	local function atJunction(st, forward)
		return st ~= nil and st.existing ~= nil and st.junctions ~= nil and st.endOf ~= nil
			and st.junctions[st.endOf[forward]] ~= nil
	end
	local least, at = math.huge, nil
	for li, leg in ipairs(plan.legs) do
		local function count(i, skipping)
			local low, closest = over(leg, i)
			if low ~= nil and (not skipping or closest < CROSS_NEAR) and low < least then
				least, at = low, leg.samples[i].p
			end
			return low ~= nil
		end
		local n = #leg.samples
		local first, last = 1, n
		if atJunction(plan.stations[li], true) then
			while first <= n and count(first, true) do
				first = first + 1
			end
		end
		if atJunction(plan.stations[li + 1], false) then
			while last >= first and count(last, true) do
				last = last - 1
			end
		end
		for i = first, last do
			count(i, false)
		end
	end
	return least, at
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
	local allocKB = rt.maxAllocKB or STEP_ALLOC_KB
	t.ok(r.alloc.max <= allocKB, ("most allocated in a step %.0f KB (%s), at most %.0f"):format(r.alloc.max,
		tostring(r.alloc.maxKind), allocKB))
	t.ok(r.alloc.longestStall <= MAX_STALL_STEPS, ("progress bar stood still for %d steps, at most %d"):format(
		r.alloc.longestStall, MAX_STALL_STEPS))
	local plan = r.plan
	if rt.expectFailure then
		t.eq(plan.ok, false, "fails as recorded (now it plans: record a baseline)")
		t.eq(plan.failure, rt.expectFailure, "failure")
		return
	end
	t.ok(plan.ok, "plans: " .. tostring(plan.failure) .. " " .. table.concat(plan.failureTowns or {}, ", "))
	-- The existing stations the route joins (rt.existing, by name) are joined, not replaced by a station of ours.
	for __, name in ipairs(rt.existing or {}) do
		for __, st in ipairs(plan.stations) do
			if st.town.name == name then
				t.ok(st.existing ~= nil, name .. "'s existing station joined")
			end
		end
		for __, note in ipairs(plan.notes) do
			-- (Where a leg joins its line is told, milestone 4c stage 3: not a station that couldn't be used.)
			t.ok(not note:find(name, 1, true) or note:find("Joins the existing line", 1, true) ~= nil,
				"no note about " .. name .. "'s station: " .. note)
		end
	end
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
	-- Bridges clear the maps' track: every sample within TRACK_NEAR of a track point is BRIDGE_ABOVE over it, less a
	-- little for the track's own height between its ends (taken as a straight line).
	if rt.map ~= nil then
		local least, at = trackClearance(loadMap(rt.map), plan)
		t.ok(least >= r.weights.bridgeAbove - 0.5, ("least clearance over track %.1f m at (%.0f, %.0f)"):format(least,
			at and at.x or 0, at and at.y or 0))
	end
	-- No station over a street (stations.tl's footprint: the building's side faces the town). A route capture has no
	-- streets' points, so this checks only routes planned on a map.
	for __, st in ipairs(plan.stations) do
		local c, d, town = st.site.centre, st.site.dir, st.town.pos
		local townLeft = -d.y * (town.x - c.x) + d.x * (town.y - c.y) >= 0
		local left, right = lib.stations.BUILDING_SIDE, lib.stations.TRACK_SIDE
		if not townLeft then
			left, right = right, left
		end
		t.ok(not lib.grid.streetIn(r.grid, c, d, r.platform / 2 + lib.stations.STATION_END, left, right),
			("station %s at (%.0f, %.0f) over a street"):format(tostring(st.town.name), c.x, c.y))
	end
	-- The preview's arrows (100 m chords, at least 25 m: shorter ones crash the game).
	for li, leg in ipairs(plan.legs) do
		for __, a in ipairs(arrows.split(leg, 100, 25)) do
			local d = math.sqrt((leg.samples[a.j].p.x - leg.samples[a.i].p.x) ^ 2
				+ (leg.samples[a.j].p.y - leg.samples[a.i].p.y) ^ 2)
			t.ok(d >= 25 - 1e-9, ("leg %d: a %.1f m preview arrow"):format(li, d))
		end
	end
	-- The network the dry runs would send: no edge longer than allowed, none of (next to) no length; each edge's cubic
	-- within 0.25 m of the profile at the samples inside it, and no steeper than the leg's steepest grade. Where the
	-- profile's grade changes sharply at a sample, a smooth curve through it has to overshoot one side's grade, so an
	-- edge with no sample inside (one the network can't split further) may go over by up to GRADE_OVERSHOOT (2.4
	-- points at worst on these maps).
	local GRADE_OVERSHOOT = 0.03
	-- How far a crossover (one 45 m edge between the tracks, over one or two samples), or the main track beside a
	-- switch (one edge of 20 m or more), may stray from the profile.
	local CROSSOVER_STRAY = 1.0
	local net = network.build(plan, network.defaults())
	local maxEdge = network.defaults().maxEdge
	local tooHigh, tooSteep, worstOver, worstAt = 0, 0, 0, ""
	for __, e in ipairs(net.edges) do
		local len = math.sqrt((e.p1.x - e.p0.x) ^ 2 + (e.p1.y - e.p0.y) ^ 2)
		t.ok(len > 0.5, ("leg %d: a %.2f m edge at s %.0f"):format(e.leg, len, e.s0))
		t.ok(e.s1 - e.s0 <= maxEdge + 1e-6, "edge within maxEdge")
		local leg = plan.legs[e.leg]
		local inside = false
		-- Crossovers, and the main track in a station's approach (kept whole beside the switches), may stray more.
		local loose = e.track == 0 or e.s1 <= 100 + 1e-6 or e.s0 >= leg.length - 100 - 1e-6
		for k, sample in ipairs(leg.samples) do
			if sample.s > e.s0 + 1e-6 and sample.s < e.s1 - 1e-6 then
				inside = true
				local u = (sample.s - e.s0) / (e.s1 - e.s0)
				local u2, u3 = u * u, u * u * u
				local z = (2 * u3 - 3 * u2 + 1) * e.p0.z + (u3 - 2 * u2 + u) * e.t0.z + (-2 * u3 + 3 * u2) * e.p1.z
					+ (u3 - u2) * e.t1.z
				-- A crossover is one edge (a switch's branch must be long): it may stray more.
				if math.abs(z - leg.z[k]) > (loose and CROSSOVER_STRAY or 0.25) + 1e-6 then
					tooHigh = tooHigh + 1
				end
			end
		end
		for m = 0, 20 do
			local u = m / 20
			local dh00, dh10 = 6 * u * u - 6 * u, 3 * u * u - 4 * u + 1
			local dh01, dh11 = -6 * u * u + 6 * u, 3 * u * u - 2 * u
			local dx = dh00 * e.p0.x + dh10 * e.t0.x + dh01 * e.p1.x + dh11 * e.t1.x
			local dy = dh00 * e.p0.y + dh10 * e.t0.y + dh01 * e.p1.y + dh11 * e.t1.y
			local dz = dh00 * e.p0.z + dh10 * e.t0.z + dh01 * e.p1.z + dh11 * e.t1.z
			local over = math.abs(dz) / math.sqrt(dx * dx + dy * dy) - leg.maxGrade
			if over > ((inside and not loose) and 0.002 or GRADE_OVERSHOOT) then
				tooSteep = tooSteep + 1
				if over > worstOver then
					worstOver, worstAt = over, ("leg %d, s %.0f-%.0f"):format(e.leg, e.s0, e.s1)
				end
			end
		end
	end
	t.eq(tooHigh, 0, "samples where an edge strays over 0.25 m from the profile")
	t.eq(tooSteep, 0, ("points where an edge is too steep (worst %.1f points over, %s)"):format(100 * worstOver,
		worstAt))
	-- A chunk never ends inside a bridge or tunnel: between two edges (of the left track) that aren't ground.
	for k = 2, #net.chunks do
		local c, previous = net.chunks[k], net.chunks[k - 1]
		if c.leg == previous.leg then
			local before
			for i = previous.first, previous.last do
				if net.edges[i].track == 1 then
					before = net.edges[i]
				end
			end
			local after = net.edges[c.first]
			t.ok(before.kind == "ground" or after.kind == "ground",
				("leg %d: a chunk cut at s %.0f, inside a %s"):format(c.leg, after.s0, after.kind))
		end
	end
	t.ok(#net.chunks > 0, "some chunks")
	-- Every chunk builds as it is: no junction cut on no existing piece, no existing piece split by two chunks.
	for k, c in ipairs(net.chunks) do
		t.ok(c.problem == nil, ("chunk %d: %s"):format(k, tostring(c.problem)))
	end
	-- A capture records no track type; its weights' top speed (at most the track's) stands in for it.
	haltFans(plan, r.track ~= nil and r.track.speed or r.weights.topSpeed)
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
					stops = rt.stops, existing = rt.existing })
			end, routeName(rt))
		end)
	end
end

-- Planned as the window plans for Halt 2+2 (its platform, and the straight its fan and crossovers need at each end,
-- approachFor): the in-game route whose fan at Antelope's south end was left out, and the one other route where a
-- sample beside a merge did the same (leg 4's end). The routes above are planned without an approach.
t.test("regression: Halt 2+2 fans on routes planned with the window's approach", function()
	local track = "Standard Tracks"
	local approach = network.fanLength(network.turnoutLength(300)) + 100
	for __, rt in ipairs({ { from = "Bangor", to = "Aloha", stops = { "Antelope" }, platform = 320 },
			{ from = "Bangor", to = "Imperial Beach" } }) do
		local r = lib.planOnMap(loadMap(TEST_MAP), { from = rt.from, to = rt.to, mode = "cheapest", track = track,
			stops = rt.stops, platform = rt.platform, approach = approach })
		t.ok(r.plan.ok, rt.from .. " to " .. rt.to .. ": plans")
		haltFans(r.plan, r.track.speed)
	end
end)

-- The route captures planned as they are (lib.planCapture), on the save as it was then.
if full then
	for _, rt in ipairs(CAPTURE_ROUTES) do
		t.test("regression: " .. rt.capture, function()
			local c = lib.capture.load(mapsDir .. "/" .. rt.capture)
			local map = rt.map and loadMap(rt.map) or nil
			check(rt, function()
				return lib.planCapture(c, { map = map })
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
			t.eq(differ.blocked, c.blocked or 0, c.capture .. " blocked")
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
