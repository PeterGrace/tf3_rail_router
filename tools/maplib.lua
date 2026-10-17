-- Reads a whole-map capture (docs/map-capture-format.md): terrain, towns, objects, streets and track, for offline
-- tools and tests. Plain Lua (5.1 to 5.4) with no mod dependencies: the same file is in the kit's template and in
-- Rail Router. The shared maps are in the kit's maps/ folder (maps/README.md).
--
--   local maplib = dofile("tools/maplib.lua")
--   local map = maplib.load("../maps/big-54-towns-16x16km.map")   -- errors on a truncated or inconsistent file
--   local h = maplib.heightAt(map, x, y)                          -- bilinear between the 25 m grid points
--   local cells = maplib.rasterise(map, x0, y0, cell, nx, ny)     -- optional: a grid by Rail Router's rules
--
-- map fields: version, meta {key = text}, extent {x0, y0, x1, y1, source}, terrain {key = text}, spacing, gx0, gy0
-- (point (1, 1)), nx, ny, height {metres} and flag {"L"|"W"|"X"} per point at (iy - 1) * nx + ix, towns {{id, name,
-- cx, cy, x0, y0, x1, y1}}, tracks {{key = value}}, objects {{id, kind, boxSource, min, max ({x, y, z} or nil),
-- construction, town, file}}, edges {{id, kind ("s"|"t"), edgeType ("n"|"b"|"u"|"?"), node0, node1, p0, p1, t0, t1
-- (nil: straight), template}}, counts (the end record), problems {text} (only with partial = true).
local maplib = {}

maplib.VERSION = 1
-- rasterise's default margin round object boxes (metres), as Rail Router's planner/area.tl.
maplib.BUILDING_BUFFER = 30.0
-- Rail Router's area.JUNCTION_BUFFER: how far round a road junction's node its cells are marked.
maplib.JUNCTION_BUFFER = 30.0

local function split(s)
	local out = {}
	for w in s:gmatch("%S+") do
		out[#out + 1] = w
	end
	return out
end

local function num(s)
	if s == nil or s == "-" then
		return nil
	end
	return tonumber(s)
end

local function int(s)
	local n = num(s)
	return n and math.floor(n) or nil
end

local function vec(t, i)
	local x, y, z = num(t[i]), num(t[i + 1]), num(t[i + 2])
	if x == nil or y == nil then
		return nil
	end
	return { x = x, y = y, z = z or 0 }
end

local function value(v)
	if v == "true" then
		return true
	elseif v == "false" then
		return false
	elseif v == "nil" then
		return nil
	end
	return tonumber(v) or v
end

local function field(s)
	if s == "-" then
		return nil
	end
	return s
end

-- The records after "MAP ": everything after the first word, and the rest after `skip` more words (for last fields
-- that may contain spaces).
local function after(rest, skip)
	local pos = 1
	for _ = 1, skip do
		local _, e = rest:find("^%s*%S+", pos)
		if not e then
			return ""
		end
		pos = e + 1
	end
	return (rest:sub(pos):gsub("^%s", ""))
end

-- Parses lines (an iterator of strings). Lines that don't start with "MAP " are ignored.
function maplib.parse(lines, opts)
	opts = opts or {}
	local map = { meta = {}, terrain = {}, towns = {}, tracks = {}, objects = {}, edges = {}, height = {}, flag = {},
		problems = {}, seen = { r = 0, town = 0, track = 0, obj = 0, edge = 0 } }
	local began, ended = false, false
	for line in lines do
		local kind, rest = line:match("^MAP (%S+) ?(.*)$")
		if kind == "begin" then
			if began then
				error("a second MAP begin: one map per file (tools/extract_captures.py splits logs)")
			end
			began = true
			map.version = tonumber(rest)
			if map.version == nil or map.version > maplib.VERSION then
				error("unsupported map format version " .. tostring(rest))
			end
		elseif kind == "meta" then
			local key = rest:match("^(%S+)")
			map.meta[key] = after(rest, 1)
		elseif kind == "extent" then
			local t = split(rest)
			map.extent = { x0 = num(t[1]), y0 = num(t[2]), x1 = num(t[3]), y1 = num(t[4]), source = t[5] }
		elseif kind == "terrain" then
			local key = rest:match("^(%S+)")
			map.terrain[key] = after(rest, 1)
		elseif kind == "grid" then
			local t = split(rest)
			map.spacing, map.gx0, map.gy0, map.nx, map.ny = num(t[1]), num(t[2]), num(t[3]), int(t[4]), int(t[5])
		elseif kind == "r" then
			assert(map.nx, "terrain row before the grid record")
			local iy, ix, hs, fs = rest:match("^(%d+) (%d+) (%S+) (%S+)$")
			iy, ix = tonumber(iy), tonumber(ix)
			local base = (iy - 1) * map.nx
			local k, d = 0, 0
			for h in hs:gmatch("[^,]+") do
				if k == 0 then
					d = tonumber(h)
				else
					d = d + tonumber(h)
				end
				map.height[base + ix + k] = d / 10
				k = k + 1
			end
			local j = 0
			for f, n in fs:gmatch("(%a)(%d+)") do
				for _ = 1, tonumber(n) do
					map.flag[base + ix + j] = f
					j = j + 1
				end
			end
			if j ~= k then
				table.insert(map.problems, ("row %d at %d: %d heights but %d flags"):format(iy, ix, k, j))
			end
			map.seen.r = map.seen.r + 1
		elseif kind == "town" then
			local t = split(rest)
			table.insert(map.towns, { id = int(t[1]), cx = num(t[2]), cy = num(t[3]), x0 = num(t[4]), y0 = num(t[5]),
				x1 = num(t[6]), y1 = num(t[7]), name = after(rest, 7) })
			map.seen.town = map.seen.town + 1
		elseif kind == "track" then
			local fields = {}
			for k, v in rest:gmatch("([^;=]+)=([^;]*)") do
				fields[k] = value(v)
			end
			table.insert(map.tracks, fields)
			map.seen.track = map.seen.track + 1
		elseif kind == "obj" then
			local t = split(rest)
			table.insert(map.objects, { id = int(t[1]), kind = t[2], boxSource = t[3], min = vec(t, 4), max = vec(t, 7),
				construction = int(t[10]), town = int(t[11]), file = field(t[12]) })
			map.seen.obj = map.seen.obj + 1
		elseif kind == "edge" then
			local t = split(rest)
			table.insert(map.edges, { id = int(t[1]), kind = t[2], edgeType = t[3], node0 = int(t[4]), node1 = int(t[5]),
				p0 = vec(t, 6), p1 = vec(t, 9), t0 = vec(t, 12), t1 = vec(t, 15), template = field(t[18]) })
			map.seen.edge = map.seen.edge + 1
		elseif kind == "end" then
			ended = true
			map.counts = {}
			for k, v in rest:gmatch("(%w+)=(%-?%d+)") do
				map.counts[k] = tonumber(v)
			end
		end
	end
	if not began then
		table.insert(map.problems, "no MAP begin record")
	end
	if not ended then
		table.insert(map.problems, "no MAP end record (truncated)")
	else
		for k, n in pairs(map.seen) do
			if map.counts[k] ~= nil and map.counts[k] ~= n then
				table.insert(map.problems, ("%d %s records, the end record says %d"):format(n, k, map.counts[k]))
			end
		end
	end
	if map.nx == nil then
		table.insert(map.problems, "no grid record")
	else
		local missing = 0
		for i = 1, map.nx * map.ny do
			if map.height[i] == nil or map.flag[i] == nil then
				missing = missing + 1
			end
		end
		if missing > 0 then
			table.insert(map.problems, missing .. " terrain points missing")
		end
	end
	map.seen = nil
	if #map.problems > 0 and not opts.partial then
		error("map: " .. table.concat(map.problems, "; "))
	end
	return map
end

function maplib.load(path, opts)
	local f = assert(io.open(path, "r"))
	local map = maplib.parse(f:lines(), opts)
	f:close()
	return map
end

-- The towns as {id, name, pos = {x, y}} (the centre of their box), sorted by name (as Rail Router's survey.towns).
function maplib.towns(map)
	local out = {}
	for _, t in ipairs(map.towns) do
		table.insert(out, { id = t.id, name = t.name, pos = { x = t.cx, y = t.cy } })
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out
end

-- The terrain height at (x, y): bilinear between the four grid points round it (clamped at the edges).
function maplib.heightAt(map, x, y)
	local nx, ny = map.nx, map.ny
	local fx = math.max(0, math.min(nx - 1, (x - map.gx0) / map.spacing))
	local fy = math.max(0, math.min(ny - 1, (y - map.gy0) / map.spacing))
	local cx, cy = math.floor(fx), math.floor(fy)
	local tx, ty = fx - cx, fy - cy
	local cx1, cy1 = math.min(cx + 1, nx - 1), math.min(cy + 1, ny - 1)
	local h = map.height
	local top = h[cy * nx + cx + 1] * (1 - tx) + h[cy * nx + cx1 + 1] * tx
	local bottom = h[cy1 * nx + cx + 1] * (1 - tx) + h[cy1 * nx + cx1 + 1] * tx
	return top * (1 - ty) + bottom * ty
end

-- The flag of the grid point nearest to (x, y); "X" (off the map) beyond the grid.
function maplib.flagAt(map, x, y)
	local ix = math.floor((x - map.gx0) / map.spacing + 0.5) + 1
	local iy = math.floor((y - map.gy0) / map.spacing + 0.5) + 1
	if ix < 1 or ix > map.nx or iy < 1 or iy > map.ny then
		return "X"
	end
	return map.flag[(iy - 1) * map.nx + ix]
end

-- Optional, from here on: rasterising boxes of the map into grids of cells, by the rules Rail Router's in-game survey
-- uses (survey.tl, planner/area.tl). Other mods can use it as it is, or write their own from the records above.

-- Grid helpers with Rail Router's grid conventions (planner/grid.tl): cell (1, 1)'s centre at (x0, y0).
local function cellOf(g, x, y)
	local ix = math.floor((x - g.x0) / g.cell + 1.5)
	local iy = math.floor((y - g.y0) / g.cell + 1.5)
	return math.max(1, math.min(g.nx, ix)), math.max(1, math.min(g.ny, iy))
end

local function inside(g, x, y)
	local fx = (x - g.x0) / g.cell + 1
	local fy = (y - g.y0) / g.cell + 1
	return fx >= 0.5 and fx <= g.nx + 0.5 and fy >= 0.5 and fy <= g.ny + 0.5
end

-- The marking rules of Rail Router's planner/area.tl (markBox, markPoint, markLine, markCurve), repeated here so
-- this file has no mod dependencies; Rail Router's tests/maplib_test.lua checks that both mark the same cells.
local function markBox(g, x0, y0, x1, y1, cells)
	local half = g.cell / 2
	if x1 < g.x0 - half or y1 < g.y0 - half or x0 > g.x0 + (g.nx - 1) * g.cell + half
			or y0 > g.y0 + (g.ny - 1) * g.cell + half then
		return
	end
	local ax, ay = cellOf(g, x0, y0)
	local bx, by = cellOf(g, x1, y1)
	for iy = ay, by do
		for ix = ax, bx do
			cells[(iy - 1) * g.nx + ix] = true
		end
	end
end

local function markPoint(g, x, y, cells)
	if inside(g, x, y) then
		local ix, iy = cellOf(g, x, y)
		cells[(iy - 1) * g.nx + ix] = true
	end
end

local function markLine(g, a, b, cells)
	local dx, dy = b.x - a.x, b.y - a.y
	local length = math.sqrt(dx * dx + dy * dy)
	local steps = math.max(1, math.ceil(length / (g.cell / 2)))
	for k = 0, steps do
		markPoint(g, a.x + dx * k / steps, a.y + dy * k / steps, cells)
	end
end

local function markCurve(g, p0, t0, p1, t1, cells)
	local chord = math.sqrt((p1.x - p0.x) ^ 2 + (p1.y - p0.y) ^ 2)
	local length = math.max(chord, math.sqrt(t0.x * t0.x + t0.y * t0.y), math.sqrt(t1.x * t1.x + t1.y * t1.y))
	local steps = math.max(1, math.ceil(length / (g.cell / 2)))
	for k = 0, steps do
		local t = k / steps
		local t2, t3 = t * t, t * t * t
		local h00 = 2 * t3 - 3 * t2 + 1
		local h10 = t3 - 2 * t2 + t
		local h01 = -2 * t3 + 3 * t2
		local h11 = t3 - t2
		markPoint(g, h00 * p0.x + h10 * t0.x + h01 * p1.x + h11 * t1.x, h00 * p0.y + h10 * t0.y + h01 * p1.y + h11 * t1.y,
			cells)
	end
end
maplib.markBox, maplib.markPoint, maplib.markLine, maplib.markCurve = markBox, markPoint, markLine, markCurve

-- A grid of nx × ny cells of `cell` metres, cell (1, 1)'s centre at (x0, y0), filled by Rail Router's survey rules
-- (opts.buffer: the margin round object boxes, default BUILDING_BUFFER):
--   * a cell centre off the map (the nearest grid point's flag is "X") is blocked, height 0, dry;
--   * otherwise its height is interpolated between the grid points, and it's water if the nearest point is;
--   * every object with a box blocks the cells nearest its box grown by BUILDING_BUFFER, and those between;
--   * every street (track) edge but tunnels marks road (track) along its curve, or its straight line without one.
-- Returns {x0, y0, cell, nx, ny, height, water, blocked, road, track} (lists at (iy - 1) * nx + ix) and stats.
function maplib.rasterise(map, x0, y0, cell, nx, ny, opts)
	opts = opts or {}
	local buffer = opts.buffer or maplib.BUILDING_BUFFER
	local g = { x0 = x0, y0 = y0, cell = cell, nx = nx, ny = ny, height = {}, water = {}, blocked = {}, road = {},
		track = {} }
	local stats = { invalid = 0, objects = 0, noBox = 0, edges = 0, tunnels = 0, straight = 0 }
	for iy = 1, ny do
		local y = y0 + (iy - 1) * cell
		for ix = 1, nx do
			local x = x0 + (ix - 1) * cell
			local i = (iy - 1) * nx + ix
			g.road[i], g.track[i] = false, false
			local flag = maplib.flagAt(map, x, y)
			if flag == "X" then
				g.height[i], g.water[i], g.blocked[i] = 0, false, true
				stats.invalid = stats.invalid + 1
			else
				g.height[i] = maplib.heightAt(map, x, y)
				g.water[i] = flag == "W"
				g.blocked[i] = false
			end
		end
	end
	for _, o in ipairs(map.objects) do
		if o.min ~= nil and o.max ~= nil then
			stats.objects = stats.objects + 1
			markBox(g, o.min.x - buffer, o.min.y - buffer, o.max.x + buffer, o.max.y + buffer, g.blocked)
		else
			stats.noBox = stats.noBox + 1
		end
	end
	-- Road junctions: street nodes that three or more pieces (of street or track, tunnels included) end at.
	g.junction = {}
	for i = 1, nx * ny do
		g.junction[i] = false
	end
	local ends, at, streetNode = {}, {}, {}
	for _, e in ipairs(map.edges) do
		for _, end_ in ipairs({ { e.node0, e.p0 }, { e.node1, e.p1 } }) do
			local node = end_[1]
			if node ~= nil then
				ends[node] = (ends[node] or 0) + 1
				at[node] = end_[2]
				if e.kind == "s" then
					streetNode[node] = true
				end
			end
		end
	end
	stats.junctions = 0
	local jb = maplib.JUNCTION_BUFFER
	for node, n in pairs(ends) do
		if n >= 3 and streetNode[node] then
			local p = at[node]
			markBox(g, p.x - jb, p.y - jb, p.x + jb, p.y + jb, g.junction)
			stats.junctions = stats.junctions + 1
		end
	end
	for _, e in ipairs(map.edges) do
		stats.edges = stats.edges + 1
		if e.edgeType == "u" then
			stats.tunnels = stats.tunnels + 1
		else
			local cells = e.kind == "s" and g.road or g.track
			if e.t0 ~= nil and e.t1 ~= nil then
				markCurve(g, e.p0, e.t0, e.p1, e.t1, cells)
			else
				stats.straight = stats.straight + 1
				markLine(g, e.p0, e.p1, cells)
			end
		end
	end
	return g, stats
end

return maplib
