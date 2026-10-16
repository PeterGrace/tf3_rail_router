-- Replays a route plan offline from a capture (the "CAPTURE" lines the window's probe writes to the game log), and
-- draws it. usage: lua tools/replay.lua <capture file> [out.ppm] [key=value weight overrides...]
-- Prints the plan's summary and per-leg figures; with out.ppm, draws the map (20 m per pixel): terrain shaded by
-- height, water blue, blocked cells red, roads grey, track black, the grid path yellow, the planned track green
-- (ground), blue (bridge) or orange (tunnel), and samples over blocked cells magenta.
local root = arg[0]:match("^(.*)/tools/[^/]*$") or "."
package.path = root .. "/.tools/?.lua;" .. package.path
local tl = require("tl")

local idPipe = io.popen('"' .. root .. '/tools/mod_id.sh"')
local modId = idPipe:read("l")
idPipe:close()

local function requireTl(relPath)
	local path = root .. "/mod/" .. modId .. "/content/" .. relPath
	local f = assert(io.open(path, "r"))
	local src = f:read("a")
	f:close()
	local code = assert(tl.gen(src, tl.new_env({ defaults = { gen_target = "5.1" } })))
	return assert(load(code, "@" .. path))()
end
local loaded = {}
function ug_require(path)
	local rel = path:sub(#modId + 4)
	if loaded[rel] == nil then
		loaded[rel] = requireTl(rel)
	end
	return loaded[rel]
end

local grid = ug_require(modId .. "::/gui/pgrace_rail_router/planner/grid.tl")
local route = ug_require(modId .. "::/gui/pgrace_rail_router/planner/route.tl")

local capPath, outPath = arg[1], arg[2]
assert(capPath, "usage: lua tools/replay.lua <capture> [out.ppm] [key=value...]")
local overrides = {}
for i = 3, #arg do
	local k, v = arg[i]:match("^([%w_]+)=(.*)$")
	overrides[k] = v
end
if outPath and outPath:match("=") then
	local k, v = outPath:match("^([%w_]+)=(.*)$")
	overrides[k] = v
	outPath = nil
end

local g, weights, platform = nil, {}, 160
local stops = {}
for line in io.lines(capPath) do
	local kind, rest = line:match("^CAPTURE (%w+) ?(.*)$")
	if kind == "begin" then
		local x0, y0, cell, nx, ny = rest:match("(%S+) (%S+) (%S+) (%S+) (%S+)")
		g = grid.new(tonumber(x0), tonumber(y0), tonumber(cell), math.floor(tonumber(nx)), math.floor(tonumber(ny)))
	elseif kind == "weights" then
		for k, v in rest:gmatch("([%w_]+)=([^;]*)") do
			if v == "true" or v == "false" then
				weights[k] = v == "true"
			else
				weights[k] = tonumber(v)
			end
		end
	elseif kind == "platform" then
		platform = tonumber(rest)
	elseif kind == "stop" then
		local id, x, y, name = rest:match("^(%S+) (%S+) (%S+) (.*)$")
		table.insert(stops, { id = math.floor(tonumber(id)), name = name, pos = { x = tonumber(x), y = tonumber(y) } })
	elseif kind == "row" then
		local iy, hs, fs = rest:match("^(%d+) (%S+) (%S+)$")
		iy = tonumber(iy)
		local ix = 0
		for h in hs:gmatch("[^,]+") do
			ix = ix + 1
			g.height[(iy - 1) * g.nx + ix] = tonumber(h)
		end
		for ixf = 1, #fs do
			local f = tonumber(fs:sub(ixf, ixf), 16)
			local i = (iy - 1) * g.nx + ixf
			g.blocked[i] = f % 2 == 1
			g.water[i] = math.floor(f / 2) % 2 == 1
			g.road[i] = math.floor(f / 4) % 2 == 1
			g.track[i] = math.floor(f / 8) % 2 == 1
		end
	end
end
-- Captures from before weights.minSearchRadius: the Cheapest radius, as modes.weights sets it.
if weights.minSearchRadius == nil and weights.minBuildRadius ~= nil then
	weights.minSearchRadius = 4 * weights.minBuildRadius
end
for k, v in pairs(overrides) do
	if v == "true" or v == "false" then
		weights[k] = v == "true"
	else
		weights[k] = tonumber(v)
	end
end

local clock = os.clock()
local job = route.start({ grid = g, stops = stops, weights = weights, platformLength = platform })
local paths = {}
while not route.step(job, 1000000) do
	if job.path ~= nil and paths[job.legIndex] == nil then
		paths[job.legIndex] = job.path
	end
end
local plan = route.plan(job)
print(("replay %s: %.0f ms, %s"):format(capPath, (os.clock() - clock) * 1000, plan.ok and "ok" or plan.failure))
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
