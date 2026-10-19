-- Plans routes offline with the mod's own planner, as the window does in-game: on a whole-map capture (any two towns)
-- or from a route capture (the planner's exact input for one Find route). Used by tools/replay.lua and the regression
-- tests (tests/regression_test.lua).
--
--   local replaylib = dofile(root .. "/tools/replaylib.lua")(root)
--   local r = replaylib.planOnMap(map, { from = "Ames", to = "Bridgeport", mode = "fastest", track = "High-Speed Tracks" })
--   -- r.plan, r.paths, r.slowest, r.worstStep, r.alloc, r.ms, r.grid, r.stops, r.track, r.weights, r.year, r.candidates, r.areas
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
	lib.network = ug_require(base .. "network.tl")
	lib.stations = ug_require(base .. "stations.tl")
	lib.existing = ug_require(base .. "existing.tl")
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
	-- per leg, the slowest single route.step per kind (route.stepKind: "sites", "scout", "turn", and in the legs phase
	-- "search", "simplify", "fit", "heights", "resite"; ms, garbage collection left out; in-game Lua runs about 4 times
	-- slower), the slowest step overall (ms), the total time (ms), and `alloc`: what the steps allocated (KB), in all
	-- (total), the most in one step (max, maxKind) and the slowest step's (worst, worstKind). Allocation is what in-game
	-- costs most beyond the work itself: the game's Lua (5.2) collects incrementally, and pays a step's garbage
	-- collection debt (as much work as bytes allocated) at its next allocation, so a step that allocates megabytes (a
	-- search's tables doubling) makes a hitch there that the desktop, with the collector held off, never shows.
	function lib.runPlan(g, stops, weights, platform, expansions, approach, joins)
		expansions = expansions or lib.STEP_EXPANSIONS
		local start = clock()
		-- joins (optional): existing stations to join, as the window passes them: bareApproach, existingStations,
		-- snapshots (by stop index) and radius.
		joins = joins or {}
		local job = route.start({ grid = g, stops = stops, weights = weights, platformLength = platform, approach = approach,
			bareApproach = joins.bareApproach, existingStations = joins.existingStations, snapshots = joins.snapshots,
			radius = joins.radius })
		local paths = {}
		local slowest, worst = {}, 0
		local alloc = { total = 0, max = 0, maxKind = nil, worst = 0, worstKind = nil }
		-- The most steps in a row the progress bar stood still: its whole percent (route.progress, as the window shows it
		-- after each step) unchanged.
		local shown, stall = -1, 0
		alloc.longestStall = 0
		while true do
			local kind = route.stepKind(job)
			-- The collector is held off while a step is timed, and catches up between steps: a collection costs in
			-- proportion to the whole heap, here the maps loaded (five in the regression test, hundreds of MB) and in
			-- the game everything else, and lands on whichever step allocates past its threshold (one step "took"
			-- 21 ms and 46 ms that way, 2 ms without).
			collectgarbage("stop")
			local kb = collectgarbage("count")
			local before = clock()
			local done = route.step(job, expansions)
			local ms = (clock() - before) * 1000
			kb = collectgarbage("count") - kb
			collectgarbage("restart")
			collectgarbage("step")
			slowest[kind] = math.max(slowest[kind] or 0, ms)
			alloc.total = alloc.total + kb
			if kb > alloc.max then
				alloc.max, alloc.maxKind = kb, kind
			end
			if ms > worst then
				worst, alloc.worst, alloc.worstKind = ms, kb, kind
			end
			local p = math.floor(100 * route.progress(job))
			if p > shown then
				shown, stall = p, 0
			else
				stall = stall + 1
				alloc.longestStall = math.max(alloc.longestStall, stall)
			end
			if done then
				break
			end
			-- The leg's path once taken (not while its search radii are weighed), the last one where re-siting builds a
			-- leg again.
			if job.path ~= nil and job.radii == nil then
				paths[job.legIndex] = job.path
			end
		end
		return route.plan(job), paths, slowest, worst, (clock() - start) * 1000, alloc
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

	-- The streets' and track's points (Grid.streets, Grid.tracks), as the survey keeps them: every edge but tunnels.
	function lib.addPoints(g, map)
		for _, e in ipairs(map.edges) do
			if e.edgeType ~= "u" then
				local chord = { x = e.p1.x - e.p0.x, y = e.p1.y - e.p0.y }
				local add = e.kind == "s" and grid.addStreet or grid.addTrack
				add(g, e.p0, e.t0 or chord, e.p1, e.t1 or chord)
			end
		end
	end

	-- A grid for the box rasterised from the map.
	function lib.gridFor(map, box)
		local cells, stats = maplib.rasterise(map, box.minX, box.minY, box.cell, box.nx, box.ny)
		local g = grid.new(box.minX, box.minY, box.cell, box.nx, box.ny)
		for i = 1, box.nx * box.ny do
			g.height[i], g.water[i], g.blocked[i] = cells.height[i], cells.water[i], cells.blocked[i]
			g.road[i], g.track[i], g.junction[i] = cells.road[i], cells.track[i], cells.junction[i]
		end
		for _, p in ipairs(cells.joints or {}) do
			grid.addJoint(g, p)
		end
		lib.addPoints(g, map)
		-- Shore cells sampled finer, as the survey does (from the map's 25 m flags).
		local n = grid.SHORE_SUB * grid.SHORE_SUB
		for _, i in ipairs(grid.shoreCells(g)) do
			local fine = {}
			for k = 1, n do
				local p = grid.shorePoint(g, i, k)
				fine[k] = maplib.flagAt(map, p.x, p.y) == "W"
			end
			g.shore[i] = fine
		end
		return g, stats
	end

	-- An existing rail station from a whole-map capture, as the window reads it in-game (survey.existingStations,
	-- nearestStation, trackSnapshot). Every station construction within `reach` (default 1500 m) of the town is
	-- read: its end nodes are its track pieces' nodes that only one piece inside its box reaches (each station
	-- track's two extremes), and stationFromEnds gives its centre, direction and half-length. Candidates that don't
	-- read (fewer than two ends, ends not at +-half along the axis) or whose centre is nearer another town are
	-- dropped, and the one whose centre is nearest the town is taken. Offline only constructions whose file matches
	-- "rail" count (in-game: any construction with stations and frozen track). The snapshot is every track piece
	-- whose end points' box meets the circle of half + existing.REACH + 50 m (the window's SNAPSHOT_MARGIN) round
	-- the centre, ground unless the capture marks a bridge or tunnel, with no signals (captures don't record them;
	-- right-hand running is assumed). Returns station, snapshot; or nil and why.
	function lib.existingFromMap(map, townKey, reach)
		reach = reach or 1500
		local towns = maplib.towns(map)
		local town = assert(lib.findTown(towns, townKey), "no town " .. tostring(townKey))
		local function nearerTown(p)
			local d = (p.x - town.pos.x) ^ 2 + (p.y - town.pos.y) ^ 2
			for _, other in ipairs(towns) do
				if other.id ~= town.id and (p.x - other.pos.x) ^ 2 + (p.y - other.pos.y) ^ 2 < d then
					return other
				end
			end
			return nil
		end
		local best, bestD, whyNot = nil, nil, "no rail station within reach"
		for _, o in ipairs(map.objects) do
			if o.kind == "station" and o.min and o.max and o.file and o.file:match("rail") then
				local cx, cy = (o.min.x + o.max.x) / 2, (o.min.y + o.max.y) / 2
				if math.sqrt((cx - town.pos.x) ^ 2 + (cy - town.pos.y) ^ 2) <= reach then
					local function inBox(p)
						return p.x >= o.min.x - 1 and p.x <= o.max.x + 1 and p.y >= o.min.y - 1 and p.y <= o.max.y + 1
					end
					local count, at = {}, {}
					for _, e in ipairs(map.edges) do
						if e.kind == "t" and inBox(e.p0) and inBox(e.p1) then
							for _, nd in ipairs({ { e.node0, e.p0 }, { e.node1, e.p1 } }) do
								count[nd[1]] = (count[nd[1]] or 0) + 1
								at[nd[1]] = nd[2]
							end
						end
					end
					local ends = {}
					for n, c in pairs(count) do
						if c == 1 then
							ends[#ends + 1] = { x = at[n].x, y = at[n].y, z = at[n].z, entity = n }
						end
					end
					table.sort(ends, function(a, b) return a.entity < b.entity end)
					local st, why = lib.existing.stationFromEnds(o.id, ends)
					if st then
						-- A misread from track that merely lies inside the box: every end sits at +-half along the axis.
						for _, e in ipairs(ends) do
							local along = (e.x - st.centre.x) * st.dir.x + (e.y - st.centre.y) * st.dir.y
							if math.abs(math.abs(along) - st.half) > 3 then
								st, why = nil, "ends don't line up"
								break
							end
						end
					end
					if st and nearerTown(st.centre) then
						st, why = nil, "nearer " .. nearerTown(st.centre).name
					end
					if st then
						local d = math.sqrt((st.centre.x - town.pos.x) ^ 2 + (st.centre.y - town.pos.y) ^ 2)
						if not bestD or d < bestD then
							st.box = { minX = o.min.x, minY = o.min.y, maxX = o.max.x, maxY = o.max.y }
							best, bestD = st, d
						end
					else
						whyNot = why
					end
				end
			end
		end
		if not best then
			return nil, whyNot
		end
		local st = best
		local r = st.half + lib.existing.REACH + 50
		local kinds = { n = "ground", b = "bridge", u = "tunnel" }
		local pieces, degree = {}, {}
		for _, e in ipairs(map.edges) do
			if e.kind == "t" then
				degree[e.node0] = (degree[e.node0] or 0) + 1
				degree[e.node1] = (degree[e.node1] or 0) + 1
				-- The end points' box meets the circle, as the octree query finds them.
				local nx = math.max(math.min(e.p0.x, e.p1.x), math.min(st.centre.x, math.max(e.p0.x, e.p1.x)))
				local ny = math.max(math.min(e.p0.y, e.p1.y), math.min(st.centre.y, math.max(e.p0.y, e.p1.y)))
				if math.sqrt((nx - st.centre.x) ^ 2 + (ny - st.centre.y) ^ 2) <= r then
					pieces[#pieces + 1] = { entity = e.id, node0 = e.node0, node1 = e.node1, p0 = e.p0, p1 = e.p1,
						t0 = e.t0, t1 = e.t1, kind = kinds[e.edgeType] or "unknown", signals = {} }
				end
			end
		end
		return st, { pieces = pieces, degree = degree }
	end

	-- Plans from one town to another on a map, as the window does. opts: from, to (names, case-insensitive, or ids),
	-- mode ("cheapest" default, or "fastest"), track (label or name; default the mode's for the map's year), stops
	-- (a list of town names or ids between from and to: replaces corridor.select's choice; {} for none), platform
	-- (default 160), overrides ({key = value} weights), expansions (per step), existing (a list of town names or ids
	-- whose existing rail station the line joins, as ticked in the window; they must be among the planned stops).
	-- Errors on unknown towns or tracks, or an existing town that isn't a stop. A stop whose station can't be read
	-- is planned without it, as in the window, and r.existing[stop index] says why.
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
		-- As the window: each ticked stop's existing station and its track snapshot, by stop index, the junctions'
		-- radius and the bare ends' approach for the track's turnouts.
		local joins
		r.existing = {}
		for _, key in ipairs(opts.existing or {}) do
			local town = assert(lib.findTown(towns, key), "no town " .. tostring(key))
			local found = false
			for i, stop in ipairs(stops) do
				if stop.id == town.id then
					found = true
					local st, snap = lib.existingFromMap(map, key)
					if st then
						joins = joins or { existingStations = {}, snapshots = {}, radius = 150.0 }
						joins.existingStations[i], joins.snapshots[i] = st, snap
					else
						r.existing[i] = snap
					end
				end
			end
			assert(found, "existing: " .. tostring(key) .. " is not among the planned stops")
		end
		if joins then
			local radius = track.speed < 30 and 150 or (track.speed < 60 and 300 or 600)
			joins.bareApproach = lib.network.bareApproach(lib.network.turnoutLength(radius))
		end
		-- As the window: the area cut to the map's extent, and on "no path" a wider one, unless widening gives the same
		-- box (already the whole map that way).
		local bounds = { minX = map.extent.x0, minY = map.extent.y0, maxX = map.extent.x1, maxY = map.extent.y1 }
		local margin = lib.SURVEY_MARGIN
		local box = assert(area.box(stops, lib.CELL, margin, bounds), "no area")
		for retry = 0, lib.MAX_RETRIES do
			local g, stats = lib.gridFor(map, box)
			table.insert(r.areas, { box = box, margin = margin, stats = stats })
			r.grid = g
			r.plan, r.paths, r.slowest, r.worstStep, r.ms, r.alloc = lib.runPlan(g, stops, weights, platform,
				opts.expansions, opts.approach, joins)
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
	-- capture's ends again, as the window would by default), overrides, expansions, map (the streets' and track's
	-- points from a map of the same save, which captures haven't got).
	function lib.planCapture(c, opts)
		opts = opts or {}
		local g = grid.new(c.x0, c.y0, c.cell, c.nx, c.ny)
		for i = 1, c.nx * c.ny do
			g.height[i] = c.height[i] or 0
			g.blocked[i], g.water[i], g.road[i], g.track[i] = c.blocked[i] or false, c.water[i] or false,
				c.road[i] or false, c.track[i] or false
		end
		if opts.map then
			lib.addPoints(g, opts.map)
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
		r.plan, r.paths, r.slowest, r.worstStep, r.ms, r.alloc = lib.runPlan(g, stops, weights, c.platform, opts.expansions,
			c.approach)
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
