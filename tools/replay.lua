-- Replays a route plan offline, and draws it. Two sources:
--
-- From a route capture (the "CAPTURE" lines the window's probe writes to the game log):
--   lua tools/replay.lua <capture file> [out.ppm] [key=value weight overrides...] [reselect=true]
-- reselect=true picks the stops again as the window would by default: the capture's first and last stops are the ends,
-- the ones between are the towns (corridor.candidates, select, order with the window's 15% budget).
--
-- From a whole-map capture (the "MAP" lines, docs/map-capture-format.md), any route on that map:
--   lua tools/replay.lua --map <file> --from <town> --to <town> [--mode cheapest|fastest] [--track <label or name>]
--       [--stops <town,town,...|none>] [--platform 160] [out.ppm] [key=value weight overrides...]
--   lua tools/replay.lua --map <file> --list
-- Towns by name (case-insensitive) or entity id. As the window does: the default track for the mode and the map's
-- year, modes.weights, the stops corridor.select picks (or --stops: the ones between, in order), the area round them
-- (planner/area.tl, cut to the map's extent) rasterised from the map (tools/maplib.lua), and on "no path" up to two
-- retries with the margin doubled, while that gives a bigger area. The planning itself is tools/replaylib.lua (the regression tests use it too), stepped as the window steps
-- it (150 expansions a step), so "slowest step" is the longest single route.step, about 4 times longer in-game.
--
-- Prints the plan's summary and per-leg figures; with out.ppm, draws the map (20 m per pixel): terrain shaded by
-- height, water blue, blocked cells red, roads grey, track black, the grid path yellow, the planned track green
-- (ground), blue (bridge) or orange (tunnel), and samples over blocked cells magenta.
local root = arg[0]:match("^(.*)/tools/[^/]*$") or "."
local lib = dofile(root .. "/tools/replaylib.lua")(root)
local grid, modes, maplib, capture = lib.grid, lib.modes, lib.maplib, lib.capture

local function usage()
	io.stderr:write("usage: lua tools/replay.lua <capture> [out.ppm] [key=value...]\n"
		.. "       lua tools/replay.lua --map <file> --from <town> --to <town> [--mode cheapest|fastest] "
		.. "[--track <label or name>] [--stops <town,town|none>] [--platform 160] [out.ppm] [key=value...]\n"
		.. "       lua tools/replay.lua --map <file> --list\n")
	os.exit(2)
end

-- Options: --name value pairs (--list alone), key=value overrides, and up to two plain arguments.
local opts, overrides, plain = {}, {}, {}
do
	local i = 1
	while i <= #arg do
		local a = arg[i]
		local name = a:match("^%-%-(%w+)$")
		if name == "list" then
			opts.list = true
		elseif name then
			opts[name] = arg[i + 1] or usage()
			i = i + 1
		elseif a:match("^[%w_]+=") then
			local k, v = a:match("^([%w_]+)=(.*)$")
			overrides[k] = v
		else
			table.insert(plain, a)
		end
		i = i + 1
	end
end

local r, label
local outPath
if opts.map then
	outPath = plain[1]
	local map = maplib.load(opts.map)
	local towns = maplib.towns(map)
	local year = tonumber(map.meta.gameYear) or 0
	if opts.list then
		print(("%s: extent %.0f %.0f %.0f %.0f, year %d, %d towns, %d objects, %d edges"):format(opts.map,
			map.extent.x0, map.extent.y0, map.extent.x1, map.extent.y1, year, #towns, #map.objects, #map.edges))
		for _, town in ipairs(towns) do
			print(("  town %d %s (%.0f, %.0f)"):format(town.id, town.name, town.pos.x, town.pos.y))
		end
		for _, t in ipairs(lib.tracks(map)) do
			print(("  track %s (%s), %.1f m/s, cost %s, years %d-%d%s"):format(t.label, t.name, t.speed,
				tostring(t.cost), t.yearFrom, t.yearTo, modes.isAvailable(t, year) and "" or ", not available"))
		end
		return
	end
	if not (opts.from and opts.to) then
		usage()
	end
	for _, key in ipairs({ opts.from, opts.to }) do
		if not lib.findTown(towns, key) then
			io.stderr:write("no town " .. key .. " on this map (--list shows them)\n")
			os.exit(2)
		end
	end
	if opts.track and not lib.findTrack(lib.tracks(map), opts.track) then
		io.stderr:write("no track type " .. opts.track .. " on this map (--list shows them)\n")
		os.exit(2)
	end
	local stops
	if opts.stops == "none" then
		stops = {}
	elseif opts.stops then
		stops = {}
		for name in opts.stops:gmatch("[^,]+") do
			table.insert(stops, name)
		end
	end
	r = lib.planOnMap(map, { from = opts.from, to = opts.to, mode = opts.mode, track = opts.track, stops = stops,
		platform = tonumber(opts.platform), overrides = overrides })
	local names = {}
	for _, town in ipairs(r.stops) do
		table.insert(names, town.name)
	end
	print(("%s %s → %s, %s on %s (year %d): stops %s (%d candidates)"):format(opts.map, r.stops[1].name,
		r.stops[#r.stops].name, r.mode, r.track.label, r.year, table.concat(names, ", "), #r.candidates))
	for k, a in ipairs(r.areas) do
		if k > 1 then
			print("  no path: widening the area")
		end
		local box, stats = a.box, a.stats
		print(("  area %.0f %.0f, %d × %d cells of %.0f m (margin %.2f): %d off the map, %d objects, %d edges (%d tunnels skipped)"):format(
			box.minX, box.minY, box.nx, box.ny, box.cell, a.margin, stats.invalid, stats.objects, stats.edges, stats.tunnels))
	end
	if r.sameArea then
		print("  no path: a wider margin gives the same area (the whole map that way), so no retry")
	end
	label = opts.map
else
	local capPath = plain[1] or usage()
	outPath = plain[2]
	local reselect = overrides.reselect == "true"
	overrides.reselect = nil
	r = lib.planCapture(capture.load(capPath), { reselect = reselect, overrides = overrides })
	if reselect and r.candidates then
		local list = {}
		for __, town in ipairs(r.stops) do
			table.insert(list, town.name)
		end
		print(("reselected %d of %d candidates: %s"):format(#r.stops - 2, #r.candidates, table.concat(list, ", ")))
	end
	label = capPath
end
local g, plan, paths, slowest, ms, weights = r.grid, r.plan, r.paths, r.slowest, r.ms, r.weights

print(("replay %s: %.0f ms, %s"):format(label, ms, plan.ok and "ok" or plan.failure))
print(("  slowest step (%d expansions a step): %.2f ms; sites %.2f, scout %.2f, turn %.2f, legs %.2f"):format(
	lib.STEP_EXPANSIONS, r.worstStep, slowest.sites or 0, slowest.scout or 0, slowest.turn or 0, slowest.legs or 0))
if not plan.ok then
	print("  towns: " .. table.concat(plan.failureTowns, ", "))
	os.exit(1)
end
local sum = plan.summary
print(("  length %.0f m, estimate %.0f, bridges %d (%.0f m), tunnels %d (%.0f m), max grade %.3f, min radius %.0f, tight %d, blocked samples %d, guarded %d"):format(
	sum.length, sum.estimate, sum.bridges, sum.bridgeLength, sum.tunnels, sum.tunnelLength, sum.maxGrade,
	sum.minRadius, sum.tightCurves, sum.blockedSamples, sum.guarded))
for i, st in ipairs(plan.stations) do
	print(("  station %s: (%.0f, %.0f) dir (%.2f, %.2f), %.0f m from centre"):format(st.town.name, st.site.centre.x,
		st.site.centre.y, st.site.dir.x, st.site.dir.y, st.site.distance))
end
for i, leg in ipairs(plan.legs) do
	local arcs = {}
	for __, piece in ipairs(leg.pieces) do
		if piece.kind == "arc" and piece.radius < weights.minRadius - 1e-6 then
			table.insert(arcs, ("%.0f@(%.0f,%.0f)"):format(piece.radius, piece.a.x, piece.a.y))
		end
	end
	print(("  leg %d: %.0f m, search radius %.0f (%d expansions), grid path %d points, pieces %d, tight %d, blocked %d, guarded %d%s"):format(i,
		leg.length, leg.searchRadius, leg.searchExpansions, paths[i] and #paths[i] or 0, #leg.pieces, leg.tightCurves,
		leg.blockedSamples, leg.guarded,
		#arcs > 0 and (", tight arcs " .. table.concat(arcs, " ")) or ""))
	for __, span in ipairs(leg.spans) do
		if span.kind ~= "ground" then
			local a, b
			for __, sample in ipairs(leg.samples) do
				if a == nil and sample.s >= span.s0 then a = sample end
				if sample.s <= span.s1 then b = sample end
			end
			print(("    %s %.0f m from (%.0f, %.0f) to (%.0f, %.0f)"):format(span.kind, span.s1 - span.s0, a.p.x, a.p.y,
				b.p.x, b.p.y))
		end
	end
	for __, sample in ipairs(leg.samples) do
		local ix, iy = grid.cellOf(g, sample.p)
		if g.blocked[grid.index(g, ix, iy)] then
			print(("    blocked sample at (%.0f, %.0f) s=%.0f"):format(sample.p.x, sample.p.y, sample.s))
		end
	end
end

if outPath == nil then
	return
end
local PX = 20
local W, H = math.floor(g.nx * g.cell / PX), math.floor(g.ny * g.cell / PX)
local img = {}
local hmin, hmax = math.huge, -math.huge
for i = 1, g.nx * g.ny do
	if not g.blocked[i] or g.height[i] ~= 0 then
		hmin, hmax = math.min(hmin, g.height[i]), math.max(hmax, g.height[i])
	end
end
local x0, y0 = g.x0 - g.cell / 2, g.y0 - g.cell / 2
local function toPx(p)
	return math.floor((p.x - x0) / PX), H - 1 - math.floor((p.y - y0) / PX)
end
for py = 0, H - 1 do
	for px = 0, W - 1 do
		local wx, wy = x0 + (px + 0.5) * PX, y0 + (H - 1 - py + 0.5) * PX
		local ix, iy = grid.cellOf(g, { x = wx, y = wy })
		local i = grid.index(g, ix, iy)
		local v = math.floor(60 + 150 * (g.height[i] - hmin) / math.max(1, hmax - hmin))
		local c = { v // 2, v, v // 2 }
		if g.water[i] then
			c = { 40, 80, 200 }
		elseif g.track[i] then
			c = { 0, 0, 0 }
		elseif g.road[i] then
			c = { 130, 130, 130 }
		elseif g.blocked[i] then
			c = { 150, 30, 30 }
		end
		img[py * W + px] = c
	end
end
local function plot(p, c, r)
	local cx, cy = toPx(p)
	for dy = -r, r do
		for dx = -r, r do
			local x, y = cx + dx, cy + dy
			if x >= 0 and x < W and y >= 0 and y < H then
				img[y * W + x] = c
			end
		end
	end
end
for __, path in pairs(paths) do
	for k = 2, #path do
		local a, b = path[k - 1], path[k]
		local n = math.max(1, math.ceil(math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2) / (PX / 2)))
		for j = 0, n do
			plot({ x = a.x + (b.x - a.x) * j / n, y = a.y + (b.y - a.y) * j / n }, { 255, 230, 0 }, 0)
		end
	end
end
for __, leg in ipairs(plan.legs) do
	for k, sample in ipairs(leg.samples) do
		local kind = "ground"
		for __, span in ipairs(leg.spans) do
			if sample.s >= span.s0 and sample.s <= span.s1 then
				kind = span.kind
			end
		end
		local c = kind == "bridge" and { 60, 160, 255 } or kind == "tunnel" and { 255, 140, 0 } or { 0, 255, 80 }
		local ix, iy = grid.cellOf(g, sample.p)
		if g.blocked[grid.index(g, ix, iy)] then
			c = { 255, 0, 255 }
		end
		plot(sample.p, c, 1)
	end
end
for __, st in ipairs(plan.stations) do
	plot(st.site.centre, { 255, 255, 255 }, 3)
end
local f = assert(io.open(outPath, "wb"))
f:write(("P6\n%d %d\n255\n"):format(W, H))
local bytes = {}
for i = 0, W * H - 1 do
	local c = img[i]
	bytes[#bytes + 1] = string.char(c[1], c[2], c[3])
	if #bytes >= 4096 then
		f:write(table.concat(bytes))
		bytes = {}
	end
end
f:write(table.concat(bytes))
f:close()
print("  wrote " .. outPath)
