-- Compares a route capture (the in-game survey's grid for one Find route, "CAPTURE" lines) with the same box
-- rasterised from a whole-map capture of the same save ("MAP" lines), cell by cell, to check that maplib.rasterise
-- reproduces what survey.tl sees.
-- usage: lua tools/compare_capture.lua <map file> <capture file> [--list N] [out.ppm]
-- Prints, per kind (blocked, water, road, track), the cells only the map or only the capture marks, with up to N
-- (default 10) examples each, and how far the heights differ. With out.ppm, draws the cells 4 px each: agreeing cells
-- grey (marked ones darker), and per kind map-only / capture-only: blocked red / magenta, water blue / cyan, road
-- orange / yellow, track green / lime.
local root = arg[0]:match("^(.*)/tools/[^/]*$") or "."
local maplib = dofile(root .. "/tools/maplib.lua")
local capture = dofile(root .. "/tools/capture_file.lua")

local mapPath, capPath, outPath
local listN = 10
do
	local plain = {}
	local i = 1
	while i <= #arg do
		if arg[i] == "--list" then
			listN = tonumber(arg[i + 1])
			i = i + 1
		else
			table.insert(plain, arg[i])
		end
		i = i + 1
	end
	mapPath, capPath, outPath = plain[1], plain[2], plain[3]
end
if not (mapPath and capPath) then
	io.stderr:write("usage: lua tools/compare_capture.lua <map file> <capture file> [--list N] [out.ppm]\n")
	os.exit(2)
end

local map = maplib.load(mapPath)
local c = capture.load(capPath)
if not c.complete or c.rows ~= c.ny then
	print(("warning: the capture has %d of %d rows%s"):format(c.rows, c.ny, c.complete and "" or ", no end line"))
end
local g, stats = maplib.rasterise(map, c.x0, c.y0, c.cell, c.nx, c.ny)
print(("box %.1f %.1f, %d × %d cells of %.1f m; map %s: %d off the map, %d objects, %d edges (%d tunnels, %d straight)"):format(
	c.x0, c.y0, c.nx, c.ny, c.cell, mapPath, stats.invalid, stats.objects, stats.edges, stats.tunnels, stats.straight))

-- Objects whose buffered box reaches the cell (for explaining blocked cells).
local function objectsAt(x, y)
	local half = c.cell / 2
	local b = maplib.BUILDING_BUFFER
	local found = {}
	for _, o in ipairs(map.objects) do
		if o.min and x + half >= o.min.x - b and x - half <= o.max.x + b and y + half >= o.min.y - b
				and y - half <= o.max.y + b then
			table.insert(found, o.kind .. " " .. o.id)
			if #found >= 3 then
				break
			end
		end
	end
	return #found > 0 and table.concat(found, ", ") or "no object"
end

local KINDS = { "blocked", "water", "road", "track" }
local mismatch = {}
for _, k in ipairs(KINDS) do
	mismatch[k] = { mapOnly = {}, captureOnly = {} }
end
local total = c.nx * c.ny
local heightCount, heightSum, heightMax, over1, over5 = 0, 0, 0, 0, 0
local worst
for iy = 1, c.ny do
	for ix = 1, c.nx do
		local i = (iy - 1) * c.nx + ix
		local x, y = c.x0 + (ix - 1) * c.cell, c.y0 + (iy - 1) * c.cell
		for _, k in ipairs(KINDS) do
			local m, cap = g[k][i] or false, c[k][i] or false
			if m and not cap then
				table.insert(mismatch[k].mapOnly, { ix = ix, iy = iy, x = x, y = y })
			elseif cap and not m then
				table.insert(mismatch[k].captureOnly, { ix = ix, iy = iy, x = x, y = y })
			end
		end
		-- Heights where both sides read the terrain (survey leaves off-map cells at 0).
		if maplib.flagAt(map, x, y) ~= "X" and c.height[i] ~= nil and not (c.blocked[i] and c.height[i] == 0) then
			local d = math.abs(g.height[i] - c.height[i])
			heightCount, heightSum = heightCount + 1, heightSum + d
			if d > heightMax then
				heightMax, worst = d, { x = x, y = y, map = g.height[i], cap = c.height[i] }
			end
			if d > 1 then over1 = over1 + 1 end
			if d > 5 then over5 = over5 + 1 end
		end
	end
end

local anyMismatch = false
for _, k in ipairs(KINDS) do
	local mm = mismatch[k]
	print(("%-8s map only %5d, capture only %5d (of %d cells)"):format(k, #mm.mapOnly, #mm.captureOnly, total))
	for _, side in ipairs({ "mapOnly", "captureOnly" }) do
		for n, cell in ipairs(mm[side]) do
			if n > listN then
				break
			end
			local why = ""
			if k == "blocked" then
				why = maplib.flagAt(map, cell.x, cell.y) == "X" and " (off the map)" or (" (" .. objectsAt(cell.x, cell.y) .. ")")
			end
			print(("    %s cell %d,%d at (%.0f, %.0f)%s"):format(side == "mapOnly" and "map only" or "capture only",
				cell.ix, cell.iy, cell.x, cell.y, why))
		end
		anyMismatch = anyMismatch or #mm[side] > 0
	end
end
if heightCount > 0 then
	print(("heights over %d cells: mean |difference| %.2f m, max %.2f m, over 1 m %d, over 5 m %d"):format(heightCount,
		heightSum / heightCount, heightMax, over1, over5))
	if worst then
		print(("    worst at (%.0f, %.0f): map %.1f, capture %.1f"):format(worst.x, worst.y, worst.map, worst.cap))
	end
end
print(anyMismatch and "cells differ" or "0 mismatching cells")

if outPath then
	local PX = 4
	local W, H = c.nx * PX, c.ny * PX
	local colours = {
		blocked = { { 220, 30, 30 }, { 230, 0, 230 } },
		water = { { 30, 60, 230 }, { 0, 220, 230 } },
		road = { { 255, 140, 0 }, { 255, 240, 0 } },
		track = { { 0, 160, 0 }, { 150, 255, 0 } },
	}
	local cellColour = {}
	for i = 1, total do
		local marked = c.blocked[i] or c.water[i] or c.road[i] or c.track[i]
		cellColour[i] = marked and { 90, 90, 90 } or { 170, 170, 170 }
	end
	for _, k in ipairs({ "water", "road", "track", "blocked" }) do
		for s, side in ipairs({ "mapOnly", "captureOnly" }) do
			for _, cell in ipairs(mismatch[k][side]) do
				cellColour[(cell.iy - 1) * c.nx + cell.ix] = colours[k][s]
			end
		end
	end
	local f = assert(io.open(outPath, "wb"))
	f:write(("P6\n%d %d\n255\n"):format(W, H))
	for py = 0, H - 1 do
		local iy = c.ny - math.floor(py / PX)
		local row = {}
		for px = 0, W - 1 do
			local col = cellColour[(iy - 1) * c.nx + math.floor(px / PX) + 1]
			row[#row + 1] = string.char(col[1], col[2], col[3])
		end
		f:write(table.concat(row))
	end
	f:close()
	print("wrote " .. outPath)
end
