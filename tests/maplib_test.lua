local t = ...
local root = (debug.getinfo(1, "S").source:match("^@(.*)/tests/[^/]*$")) or "."
local mapformat = t.requireTl("gui/pgrace_rail_router/mapformat.tl")
local area = t.requireTl("gui/pgrace_rail_router/planner/area.tl")
local grid = t.requireTl("gui/pgrace_rail_router/planner/grid.tl")
local maplib = dofile(root .. "/tools/maplib.lua")
local synth = dofile(root .. "/tests/synthmap.lua")(mapformat)

local function v(x, y, z)
	return { x = x, y = y, z = z or 0 }
end

local function small()
	return {
		x0 = -100, y0 = -100, x1 = 100, y1 = 100, chunk = 4,
		heightFn = function(x, y) return 50 + 0.01 * x - 0.02 * y end,
		flagFn = function(x, y)
			if x > 60 then return "X" elseif y > 60 then return "W" end
			return "L"
		end,
		towns = { { id = 11, name = "Ames Upon Sea", x = 0, y = 0, r = 50 } },
		tracks = synth.TRACKS,
		objects = {
			{ id = 21, kind = "townbuilding", boxSource = "con", min = v(-10, -10, 0), max = v(10, 10, 8),
				construction = 22, town = 11 },
			{ id = 23, kind = "station", boxSource = "own", min = v(20, 20), max = v(40, 30, 5), construction = -1,
				town = -1, file = "::/stations/rail/modular station.con" },
			{ id = 24, kind = "other", boxSource = "none", construction = -1, town = -1 },
		},
		edges = {
			{ id = 31, kind = "s", edgeType = "n", node0 = 1, node1 = 2, p0 = v(-90, -90, 1), p1 = v(90, -90, 2),
				t0 = v(180, 0, 0), t1 = v(180, 0, 0), template = "town large.lua" },
			{ id = 32, kind = "t", edgeType = "u", node0 = 3, node1 = 4, p0 = v(-90, 90), p1 = v(90, 90) },
		},
	}
end

t.test("mapformat → maplib: a synthetic map reads back the same", function()
	local lines = synth.lines(small())
	local map = maplib.parse(synth.iter(lines))
	t.eq(map.version, 1, "version")
	t.eq(map.meta.gameYear, "1950", "year")
	t.eq(map.extent.x0, -100, "extent")
	t.eq(map.extent.source, "bbox", "extent source")
	t.eq(map.nx, 9, "nx")
	t.eq(map.ny, 9, "ny")
	t.eq(map.spacing, 25, "spacing")
	for iy = 1, 9 do
		for ix = 1, 9 do
			local x, y = -100 + (ix - 1) * 25, -100 + (iy - 1) * 25
			local i = (iy - 1) * 9 + ix
			t.near(map.height[i], 50 + 0.01 * x - 0.02 * y, 0.051, "height " .. ix .. "," .. iy)
			local want = x > 60 and "X" or y > 60 and "W" or "L"
			t.eq(map.flag[i], want, "flag " .. ix .. "," .. iy)
		end
	end
	t.eq(#map.towns, 1, "towns")
	t.eq(map.towns[1].name, "Ames Upon Sea", "town name with spaces")
	t.eq(map.towns[1].cx, 0, "town centre")
	t.eq(map.towns[1].x1, 50, "town box")
	t.eq(#map.tracks, 2, "tracks")
	t.eq(map.tracks[2].label, "Standard Tracks", "track label")
	t.eq(map.tracks[2].yearFrom, 1930, "track number")
	t.eq(map.tracks[1].catenary, nil, "no catenary")
	t.eq(#map.objects, 3, "objects")
	t.eq(map.objects[1].construction, 22, "construction")
	t.eq(map.objects[1].max.z, 8, "box z")
	t.eq(map.objects[2].file, "::/stations/rail/modular_station.con", "file without spaces")
	t.eq(map.objects[3].min, nil, "no box")
	t.eq(#map.edges, 2, "edges")
	t.eq(map.edges[1].template, "town_large.lua", "template")
	t.eq(map.edges[1].t0.x, 180, "tangent")
	t.eq(map.edges[2].t0, nil, "straight edge")
	t.eq(map.edges[2].edgeType, "u", "tunnel")
	t.eq(map.counts.r, 27, "row lines (3 per row of 9 at 4 per line)")
end)

t.test("maplib: a truncated map is refused, or read with problems when partial", function()
	local lines = synth.lines(small())
	table.remove(lines)
	local ok, err = pcall(maplib.parse, synth.iter(lines))
	t.ok(not ok and tostring(err):find("truncated"), "truncated: " .. tostring(err))
	local map = maplib.parse(synth.iter(lines), { partial = true })
	t.ok(#map.problems > 0, "problems listed")
	-- A row line lost in the middle: the counts don't match the end record.
	lines = synth.lines(small())
	for i, line in ipairs(lines) do
		if line:match("^MAP r 5 ") then
			table.remove(lines, i)
			break
		end
	end
	ok, err = pcall(maplib.parse, synth.iter(lines))
	t.ok(not ok and tostring(err):find("missing"), "missing points: " .. tostring(err))
end)

t.test("mapformat: heights as decimetre differences, flags run-length encoded", function()
	t.eq(mapformat.row(3, 1, { 10.04, 10.26, 9.9 }, { "L", "L", "W" }), "r 3 1 100,3,-4 L2W1", "row")
	t.eq(mapformat.rle({}), "", "empty")
	t.eq(mapformat.decimetres(-0.04), 0, "rounding")
	t.eq(mapformat.decimetres(-0.06), -1, "negative")
end)

t.test("maplib.rasterise: heights interpolated, water and off-map from the nearest point", function()
	local spec = small()
	spec.objects, spec.edges = {}, {}
	local map = maplib.parse(synth.iter(synth.lines(spec)))
	local g = maplib.rasterise(map, -90, -90, 30, 7, 7)
	for iy = 1, 7 do
		for ix = 1, 7 do
			local x, y = -90 + (ix - 1) * 30, -90 + (iy - 1) * 30
			local i = (iy - 1) * 7 + ix
			-- The nearest point (25 m grid from -100) decides the flag.
			local px = -100 + 25 * math.floor((x + 100) / 25 + 0.5)
			local py = -100 + 25 * math.floor((y + 100) / 25 + 0.5)
			if px > 60 then
				t.eq(g.blocked[i], true, "off map blocked " .. ix .. "," .. iy)
				t.eq(g.height[i], 0, "off map height 0")
				t.eq(g.water[i], false, "off map dry")
			else
				t.eq(g.blocked[i], false, "on map " .. ix .. "," .. iy)
				t.eq(g.water[i], py > 60, "water " .. ix .. "," .. iy)
				-- A plane interpolates exactly (up to the decimetre rounding).
				t.near(g.height[i], 50 + 0.01 * x - 0.02 * y, 0.06, "height " .. ix .. "," .. iy)
			end
		end
	end
end)

t.test("maplib.rasterise: a building blocks the cells within 30 m of its box", function()
	local spec = { x0 = -1000, y0 = -1000, x1 = 1000, y1 = 1000,
		objects = { { id = 1, kind = "townbuilding", boxSource = "own", min = v(160, 0), max = v(180, 15),
			construction = -1, town = -1 } } }
	local map = maplib.parse(synth.iter(synth.lines(spec)))
	local g = maplib.rasterise(map, 0, 0, 100, 5, 3)
	-- Buffered box x 130..210, y -30..45: nearest cells x 2..3 (centres 100, 200), y 1 (centre 0).
	for iy = 1, 3 do
		for ix = 1, 5 do
			t.eq(g.blocked[(iy - 1) * 5 + ix], iy == 1 and (ix == 2 or ix == 3), "cell " .. ix .. "," .. iy)
		end
	end
end)

t.test("maplib.rasterise: edges mark the cells they cross (streets road, track track, tunnels skipped)", function()
	local spec = { x0 = -1000, y0 = -1000, x1 = 1000, y1 = 1000, edges = {
		{ id = 1, kind = "s", edgeType = "n", node0 = 1, node1 = 2, p0 = v(0, 0), p1 = v(400, 0), t0 = v(400, 0),
			t1 = v(400, 0) },
		{ id = 2, kind = "t", edgeType = "b", node0 = 3, node1 = 4, p0 = v(0, 200), p1 = v(400, 200) },
		{ id = 3, kind = "t", edgeType = "u", node0 = 5, node1 = 6, p0 = v(0, 400), p1 = v(400, 400) },
	} }
	local map = maplib.parse(synth.iter(synth.lines(spec)))
	local g, stats = maplib.rasterise(map, 0, 0, 100, 5, 5)
	for ix = 1, 5 do
		t.eq(g.road[ix], true, "road " .. ix)
		t.eq(g.track[2 * 5 + ix], true, "track " .. ix)
		t.eq(g.track[4 * 5 + ix], false, "tunnel " .. ix)
		t.eq(g.road[5 + ix], false, "nothing between " .. ix)
	end
	t.eq(stats.tunnels, 1, "tunnels counted")
	t.eq(stats.straight, 1, "straight edges counted (the tunnel is skipped first)")
end)

t.test("maplib's marking rules match planner/area.tl's", function()
	local seed = 99
	local function rnd()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
	local objects, edges = {}, {}
	for i = 1, 60 do
		local x, y = (rnd() - 0.5) * 3000, (rnd() - 0.5) * 3000
		local w, h = rnd() * 80, rnd() * 80
		table.insert(objects, { id = i, kind = "other", boxSource = "own", min = v(x, y), max = v(x + w, y + h),
			construction = -1, town = -1 })
	end
	for i = 1, 60 do
		local a = v((rnd() - 0.5) * 3000, (rnd() - 0.5) * 3000)
		local b = v(a.x + (rnd() - 0.5) * 800, a.y + (rnd() - 0.5) * 800)
		local e = { id = 100 + i, kind = rnd() < 0.5 and "s" or "t", edgeType = "n", node0 = 1, node1 = 2, p0 = a, p1 = b }
		if rnd() < 0.7 then
			e.t0 = v((b.x - a.x) + (rnd() - 0.5) * 300, (b.y - a.y) + (rnd() - 0.5) * 300)
			e.t1 = v((b.x - a.x) + (rnd() - 0.5) * 300, (b.y - a.y) + (rnd() - 0.5) * 300)
		end
		table.insert(edges, e)
	end
	local map = maplib.parse(synth.iter(synth.lines({ x0 = -2000, y0 = -2000, x1 = 2000, y1 = 2000,
		objects = objects, edges = edges })))
	local x0, y0, cell, nx, ny = -1234.5, -987.25, 100, 25, 21
	local m = maplib.rasterise(map, x0, y0, cell, nx, ny)
	local g = grid.new(x0, y0, cell, nx, ny)
	-- The same records as read back (rounded to the format's centimetres), marked by the planner's rules.
	for _, o in ipairs(map.objects) do
		area.markBox(g, o.min.x - area.BUILDING_BUFFER, o.min.y - area.BUILDING_BUFFER, o.max.x + area.BUILDING_BUFFER,
			o.max.y + area.BUILDING_BUFFER, g.blocked)
	end
	for _, e in ipairs(map.edges) do
		local cells = e.kind == "s" and g.road or g.track
		if e.t0 then
			area.markCurve(g, e.p0, e.t0, e.p1, e.t1, cells)
		else
			area.markLine(g, e.p0, e.p1, cells)
		end
	end
	local marked = 0
	for i = 1, nx * ny do
		t.eq(m.blocked[i], g.blocked[i], "blocked " .. i)
		t.eq(m.road[i], g.road[i], "road " .. i)
		t.eq(m.track[i], g.track[i], "track " .. i)
		if g.blocked[i] or g.road[i] or g.track[i] then
			marked = marked + 1
		end
	end
	t.ok(marked > 50, "a fair test: " .. marked .. " cells marked")
	t.eq(maplib.BUILDING_BUFFER, area.BUILDING_BUFFER, "same buffer")
end)

t.test("replay --map plans a route on a synthetic map", function()
	local path = os.tmpname()
	local spec = { x0 = -6000, y0 = -3000, x1 = 6000, y1 = 3000, year = 1950, tracks = synth.TRACKS,
		heightFn = function(x, y) return 100 + 20 * math.sin(x / 1500) end,
		towns = { { id = 1, name = "West Town", x = -4000, y = 0 }, { id = 2, name = "East Town", x = 4000, y = 300 } },
		objects = { { id = 5, kind = "townbuilding", boxSource = "own", min = v(-40, -40), max = v(40, 40),
			construction = -1, town = -1 } },
		edges = { { id = 6, kind = "s", edgeType = "n", node0 = 1, node1 = 2, p0 = v(0, -2500), p1 = v(0, 2500) } } }
	synth.write(path, synth.lines(spec))
	local p = io.popen(('lua "%s/tools/replay.lua" --map "%s" --from "west town" --to 2 2>&1'):format(root, path))
	local out = p:read("a")
	p:close()
	local list = io.popen(('lua "%s/tools/replay.lua" --map "%s" --list 2>&1'):format(root, path))
	local listed = list:read("a")
	list:close()
	os.remove(path)
	t.ok(out:find(": %d+ ms, ok"), "planned ok:\n" .. out)
	t.ok(out:find("cheapest on Standard Tracks"), "the default Cheapest track for 1950:\n" .. out)
	t.ok(listed:find("town 1 West Town") and listed:find("East Town"), "listed:\n" .. listed)
end)

t.test("compare_capture finds no differences against the map's own grid, and reports a changed cell", function()
	local mapPath, capPath = os.tmpname(), os.tmpname()
	local spec = { x0 = -2000, y0 = -2000, x1 = 2000, y1 = 2000,
		heightFn = function(x, y) return 30 + 0.005 * x end,
		flagFn = function(x, y) return x < -1500 and "W" or "L" end,
		objects = { { id = 1, kind = "station", boxSource = "own", min = v(100, 100), max = v(300, 140),
			construction = -1, town = -1 } },
		edges = { { id = 2, kind = "s", edgeType = "n", node0 = 1, node1 = 2, p0 = v(-1800, 0), p1 = v(1800, 50) } } }
	synth.write(mapPath, synth.lines(spec))
	local map = maplib.load(mapPath)
	local x0, y0, cell, nx, ny = -1900, -1900, 100, 30, 30
	local g = maplib.rasterise(map, x0, y0, cell, nx, ny)
	-- As the window's captureProbe writes it.
	local function writeCapture(changed)
		local lines = { ("CAPTURE begin %.3f %.3f %.3f %d %d"):format(x0, y0, cell, nx, ny) }
		for iy = 1, ny do
			local hs, fs = {}, {}
			for ix = 1, nx do
				local i = (iy - 1) * nx + ix
				hs[ix] = ("%.1f"):format(g.height[i])
				local f = (g.blocked[i] and 1 or 0) + (g.water[i] and 2 or 0) + (g.road[i] and 4 or 0) + (g.track[i] and 8 or 0)
				if changed == i then f = f ~ 1 end
				fs[ix] = ("%x"):format(f)
			end
			lines[#lines + 1] = ("CAPTURE row %d %s %s"):format(iy, table.concat(hs, ","), table.concat(fs))
		end
		lines[#lines + 1] = "CAPTURE end"
		synth.write(capPath, lines)
		local p = io.popen(('lua "%s/tools/compare_capture.lua" "%s" "%s" 2>&1'):format(root, mapPath, capPath))
		local out = p:read("a")
		p:close()
		return out
	end
	local same = writeCapture(nil)
	local differs = writeCapture(5)
	os.remove(mapPath)
	os.remove(capPath)
	t.ok(same:find("0 mismatching cells"), "same:\n" .. same)
	t.ok(differs:find("blocked%s+map only%s+0, capture only%s+1"), "differs:\n" .. differs)
end)
