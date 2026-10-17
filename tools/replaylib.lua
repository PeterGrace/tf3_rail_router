-- Plans routes offline with the mod's own planner, as the window does in-game: on a whole-map capture (any two towns)
-- or from a route capture (the planner's exact input for one Find route). Used by tools/replay.lua and the regression
-- tests (tests/regression_test.lua).
--
--   local replaylib = dofile(root .. "/tools/replaylib.lua")(root)
--   local r = replaylib.planOnMap(map, { from = "Ames", to = "Bridgeport", mode = "fastest", track = "High-Speed Tracks" })
--   -- r.plan, r.paths, r.slowest, r.ms, r.grid, r.stops, r.track, r.weights, r.year, r.candidates, r.areas
--
-- root is the mod repo's folder (tools/ and .tools/tl.lua under it).
return function(root)
	package.path = root .. "/.tools/?.lua;" .. package.path
	local tl = require("tl")

	local idPipe = io.popen('"' .. root .. '/tools/mod_id.sh"')
	local modId = idPipe:read("l")
	idPipe:close()

	-- Shares ug_require with tools/test.lua when both are loaded (same files, same loader).
	if ug_require == nil then
		local loaded = {}
		function ug_require(path)
			local rel = path:sub(#modId + 4)
			if loaded[rel] == nil then
				local file = root .. "/mod/" .. modId .. "/content/" .. rel
				local f = assert(io.open(file, "r"))
				local src = f:read("a")
				f:close()
				local code = assert(tl.gen(src, tl.new_env({ defaults = { gen_target = "5.1" } })))
				loaded[rel] = assert(load(code, "@" .. file))()
			end
			return loaded[rel]
		end
	end

	local lib = {}
	local base = modId .. "::/gui/pgrace_rail_router/planner/"
	lib.grid = ug_require(base .. "grid.tl")
	lib.route = ug_require(base .. "route.tl")
	lib.corridor = ug_require(base .. "corridor.tl")
	lib.modes = ug_require(base .. "modes.tl")
	lib.area = ug_require(base .. "area.tl")
	lib.maplib = dofile(root .. "/tools/maplib.lua")
	lib.capture = dofile(root .. "/tools/capture_file.lua")
	local grid, route, corridor, modes, area, maplib = lib.grid, lib.route, lib.corridor, lib.modes, lib.area, lib.maplib

	-- As the window's DETOUR_BUDGET, CELL, SURVEY_MARGIN, MAX_RETRIES and its per-step expansions.
	lib.DETOUR_BUDGET = 0.15
	lib.CELL = 100.0
	lib.SURVEY_MARGIN = 0.25
	lib.MAX_RETRIES = 2
	lib.STEP_EXPANSIONS = 150

	local function applyOverrides(weights, overrides)
		for k, v in pairs(overrides or {}) do
			if v == "true" or v == "false" then
				weights[k] = v == "true"
			else
				weights[k] = tonumber(v) or v
			end
		end
	end
	lib.applyOverrides = applyOverrides

	local function clock()
		return os.clock()
	end

	-- Runs the planner to the end with `expansions` per step (default: as the window). Returns the plan, the grid paths
	-- per leg, the slowest single route.step per phase (ms, garbage collection left out; in-game Lua runs about 4 times
	-- slower), the slowest step overall (ms) and the total time (ms).
	function lib.runPlan(g, stops, weights, platform, expansions)
		expansions = expansions or lib.STEP_EXPANSIONS
		local start = clock()
		local job = route.start({ grid = g, stops = stops, weights = weights, platformLength = platform })
		local paths = {}
		local slowest, worst = {}, 0
		while true do
			local phase = job.phase
			-- The collector is held off while a step is timed, and catches up between steps: a collection costs in
			-- proportion to the whole heap, here the maps loaded (five in the regression test, hundreds of MB) and in
			-- the game everything else, and lands on whichever step allocates past its threshold (one step "took"
			-- 21 ms and 46 ms that way, 2 ms without).
			collectgarbage("stop")
			local before = clock()
			local done = route.step(job, expansions)
			local ms = (clock() - before) * 1000
			collectgarbage("restart")
			collectgarbage("step")
			slowest[phase] = math.max(slowest[phase] or 0, ms)
			worst = math.max(worst, ms)
			if done then
				break
			end
			if job.path ~= nil and paths[job.legIndex] == nil then
				paths[job.legIndex] = job.path
			end
		end
		return route.plan(job), paths, slowest, worst, (clock() - start) * 1000
	end

	local function baseName(name)
		local last = name:match("([^/\\:]+)$") or name
		return last:match("^([^%.]+)") or last
	end

	-- The map's track types as survey.trackTypes gives them, slowest first.
	function lib.tracks(map)
		local tracks = {}
		for _, t in ipairs(map.tracks) do
			table.insert(tracks, { name = t.name, label = t.label or t.name, cost = t.cost or 0, speed = t.speed or 0,
				maxSlopeBuild = t.maxSlopeBuild or 0, minCurveRadiusBuild = t.minCurveRadiusBuild or 0,
				trackDistance = t.trackDistance or 5, yearFrom = t.yearFrom or 0, yearTo = t.yearTo or 0,
				catenary = t.catenary, catenaryYearFrom = t.catenaryYearFrom or 0 })
		end
		table.sort(tracks, function(a, b) return a.speed < b.speed end)
		return tracks
	end

	function lib.findTrack(tracks, key)
		for _, t in ipairs(tracks) do
			if t.label:lower() == key:lower() or t.name == key or baseName(t.name) == key then
				return t
			end
		end
		return nil
	end

	function lib.findTown(towns, key)
		local id = tonumber(key)
		for _, town in ipairs(towns) do
			if town.id == id or town.name:lower() == tostring(key):lower() then
				return town
			end
		end
		return nil
	end

	-- A grid for the box rasterised from the map.
	function lib.gridFor(map, box)
		local cells, stats = maplib.rasterise(map, box.minX, box.minY, box.cell, box.nx, box.ny)
		local g = grid.new(box.minX, box.minY, box.cell, box.nx, box.ny)
		for i = 1, box.nx * box.ny do
			g.height[i], g.water[i], g.blocked[i] = cells.height[i], cells.water[i], cells.blocked[i]
			g.road[i], g.track[i] = cells.road[i], cells.track[i]
		end
		return g, stats
	end

	-- Plans from one town to another on a map, as the window does. opts: from, to (names, case-insensitive, or ids),
	-- mode ("cheapest" default, or "fastest"), track (label or name; default the mode's for the map's year), stops
	-- (a list of town names or ids between from and to: replaces corridor.select's choice; {} for none), platform
	-- (default 160), overrides ({key = value} weights), expansions (per step). Errors on unknown towns or tracks.
	function lib.planOnMap(map, opts)
		local towns = maplib.towns(map)
		local year = tonumber(map.meta.gameYear) or 0
		local tracks = lib.tracks(map)
		local from = assert(lib.findTown(towns, opts.from), "no town " .. tostring(opts.from))
		local to = assert(lib.findTown(towns, opts.to), "no town " .. tostring(opts.to))
		local mode = opts.mode or "cheapest"
		assert(mode == "cheapest" or mode == "fastest", "mode is cheapest or fastest")
		local track
		if opts.track then
			track = assert(lib.findTrack(tracks, opts.track), "no track type " .. opts.track)
		else
			track = assert(modes.defaultTrack(tracks, year, mode), "no track type available in " .. year)
		end
		local weights = modes.weights(mode, track)
		applyOverrides(weights, opts.overrides)
		local platform = opts.platform or 160
		local candidates = corridor.candidates(from, to, towns, lib.DETOUR_BUDGET)
		local stops
		if opts.stops then
			stops = { from }
			for _, key in ipairs(opts.stops) do
				table.insert(stops, (assert(lib.findTown(towns, key), "no town " .. tostring(key))))
			end
			table.insert(stops, to)
		else
			stops = corridor.order(from, to, corridor.select(from, to, candidates, lib.DETOUR_BUDGET))
		end
		local r = { year = year, track = track, mode = mode, weights = weights, stops = stops, candidates = candidates,
			platform = platform, areas = {} }
		-- As the window: the area cut to the map's extent, and on "no path" a wider one, unless widening gives the same
		-- box (already the whole map that way).
		local bounds = { minX = map.extent.x0, minY = map.extent.y0, maxX = map.extent.x1, maxY = map.extent.y1 }
		local margin = lib.SURVEY_MARGIN
		local box = assert(area.box(stops, lib.CELL, margin, bounds), "no area")
		for retry = 0, lib.MAX_RETRIES do
			local g, stats = lib.gridFor(map, box)
			table.insert(r.areas, { box = box, margin = margin, stats = stats })
			r.grid = g
			r.plan, r.paths, r.slowest, r.worstStep, r.ms = lib.runPlan(g, stops, weights, platform, opts.expansions)
			if r.plan.ok or r.plan.failure ~= "no_path" or retry == lib.MAX_RETRIES then
				break
			end
			local wider = area.box(stops, lib.CELL, 2 * margin, bounds)
			if area.same(wider, box) then
				r.sameArea = true
				break
			end
			margin, box = 2 * margin, wider
		end
		return r
	end

	-- Plans from a route capture (tools/capture_file.lua's table). opts: reselect (pick the stops between the
	-- capture's ends again, as the window would by default), overrides, expansions.
	function lib.planCapture(c, opts)
		opts = opts or {}
		local g = grid.new(c.x0, c.y0, c.cell, c.nx, c.ny)
		for i = 1, c.nx * c.ny do
			g.height[i] = c.height[i] or 0
			g.blocked[i], g.water[i], g.road[i], g.track[i] = c.blocked[i] or false, c.water[i] or false,
				c.road[i] or false, c.track[i] or false
		end
		local weights, stops = {}, c.stops
		for k, v in pairs(c.weights) do
			weights[k] = v
		end
		local r = { grid = g, platform = c.platform }
		if opts.reselect and #stops > 2 then
			local a, b = stops[1], stops[#stops]
			r.candidates = corridor.candidates(a, b, stops, lib.DETOUR_BUDGET)
			stops = corridor.order(a, b, corridor.select(a, b, r.candidates, lib.DETOUR_BUDGET))
		end
		applyOverrides(weights, opts.overrides)
		r.weights, r.stops = weights, stops
		r.plan, r.paths, r.slowest, r.worstStep, r.ms = lib.runPlan(g, stops, weights, c.platform, opts.expansions)
		return r
	end

	-- Arcs below a radius, per leg: {{leg, radius, a}}.
	function lib.arcsBelow(plan, radius)
		local out = {}
		for i, leg in ipairs(plan.legs or {}) do
			for _, piece in ipairs(leg.pieces) do
				if piece.kind == "arc" and piece.radius < radius - 1e-6 then
					table.insert(out, { leg = i, radius = piece.radius, a = piece.a })
				end
			end
		end
		return out
	end

	-- Each leg's sweep (degrees): how far its heading swings, the widest spread of the arcs' turns added up with their
	-- signs (left positive) from the leg's start. A line that bends one way and back stays low; one that loops or
	-- hooks round to enter a station the other way sweeps 270° or more.
	function lib.sweep(plan)
		local out = {}
		for i, leg in ipairs(plan.legs or {}) do
			local heading, lo, hi = 0, 0, 0
			for _, piece in ipairs(leg.pieces) do
				if piece.kind == "arc" then
					heading = heading + piece.turn
					lo, hi = math.min(lo, heading), math.max(hi, heading)
				end
			end
			out[i] = math.deg(hi - lo)
		end
		return out
	end

	-- Samples over blocked cells, per leg: {{leg, p, s}}.
	function lib.blockedSamples(r)
		local out = {}
		for i, leg in ipairs(r.plan.legs or {}) do
			for _, sample in ipairs(leg.samples) do
				local ix, iy = grid.cellOf(r.grid, sample.p)
				if r.grid.blocked[grid.index(r.grid, ix, iy)] then
					table.insert(out, { leg = i, p = sample.p, s = sample.s })
				end
			end
		end
		return out
	end

	return lib
end
