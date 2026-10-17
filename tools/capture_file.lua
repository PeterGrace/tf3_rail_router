-- Reads a route capture: the "CAPTURE" lines the window's probe writes to the game log (the planner's input for one
-- Find route). Plain Lua. Returns {x0, y0, cell, nx, ny, weights {key = value}, platform, stops {{id, name, pos}},
-- height, blocked, water, road, track (lists at (iy - 1) * nx + ix), rows (how many were read), complete}.
local capture = {}

function capture.load(path)
	local c = { weights = {}, platform = 160, stops = {}, height = {}, blocked = {}, water = {}, road = {}, track = {},
		rows = 0, complete = false }
	for line in io.lines(path) do
		local kind, rest = line:match("^CAPTURE (%w+) ?(.*)$")
		if kind == "begin" then
			local x0, y0, cell, nx, ny = rest:match("(%S+) (%S+) (%S+) (%S+) (%S+)")
			c.x0, c.y0, c.cell = tonumber(x0), tonumber(y0), tonumber(cell)
			c.nx, c.ny = math.floor(tonumber(nx)), math.floor(tonumber(ny))
		elseif kind == "weights" then
			for k, v in rest:gmatch("([%w_]+)=([^;]*)") do
				if v == "true" or v == "false" then
					c.weights[k] = v == "true"
				else
					c.weights[k] = tonumber(v)
				end
			end
		elseif kind == "platform" then
			c.platform = tonumber(rest)
		elseif kind == "stop" then
			local id, x, y, name = rest:match("^(%S+) (%S+) (%S+) (.*)$")
			table.insert(c.stops, { id = math.floor(tonumber(id)), name = name, pos = { x = tonumber(x), y = tonumber(y) } })
		elseif kind == "row" then
			local iy, hs, fs = rest:match("^(%d+) (%S+) (%S+)$")
			iy = tonumber(iy)
			local ix = 0
			for h in hs:gmatch("[^,]+") do
				ix = ix + 1
				c.height[(iy - 1) * c.nx + ix] = tonumber(h)
			end
			for ixf = 1, #fs do
				local f = tonumber(fs:sub(ixf, ixf), 16)
				local i = (iy - 1) * c.nx + ixf
				c.blocked[i] = f % 2 == 1
				c.water[i] = math.floor(f / 2) % 2 == 1
				c.road[i] = math.floor(f / 4) % 2 == 1
				c.track[i] = math.floor(f / 8) % 2 == 1
			end
			c.rows = c.rows + 1
		elseif kind == "end" then
			c.complete = true
		end
	end
	assert(c.nx, "no CAPTURE begin line in " .. path)
	-- Captures from before weights.minSearchRadius: the Cheapest radius, as modes.weights sets it.
	if c.weights.minSearchRadius == nil and c.weights.minBuildRadius ~= nil then
		c.weights.minSearchRadius = 4 * c.weights.minBuildRadius
	end
	-- Captures from before the speed model (planner/speed.tl): as modes.weights sets it, with the top speed the
	-- radius allows (the capture has no track speed; modes.weights derives the Fastest radius from it, so they agree
	-- unless the radius was capped or floored), and Fastest (the mode that bridges roads) pricing time at its
	-- FASTEST_TIME_COST.
	if c.weights.lateralAccel == nil and c.weights.minRadius ~= nil then
		c.weights.lateralAccel = 2.0
		c.weights.topSpeed = math.sqrt(2.0 * c.weights.minRadius)
		c.weights.timeCost = c.weights.bridgeRoads and 50.0 or 0
	end
	return c
end

return capture
