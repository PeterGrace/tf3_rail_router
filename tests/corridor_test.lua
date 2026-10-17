local t = ...
local corridor = t.requireTl("gui/pgrace_rail_router/planner/corridor.tl")

local function town(id, name, x, y)
	return { id = id, name = name, pos = { x = x, y = y } }
end

local A = town(1, "A", 0, 0)
local B = town(2, "B", 10000, 0)
local NEAR = town(3, "Near", 5000, 1000)    -- detour about 198 m
local FAR = town(4, "Far", 5000, 4000)      -- detour about 2,806 m
local EARLY = town(5, "Early", 2000, -500)  -- detour about 77 m
local BEHIND = town(6, "Behind", -1000, 0)  -- before A

t.test("corridor: keeps towns within the budget, in order from a to b", function()
	local list = corridor.candidates(A, B, { A, B, NEAR, FAR, EARLY, BEHIND }, 0.15)
	t.eq(#list, 2, "count")
	t.eq(list[1].town.name, "Early", "first")
	t.eq(list[2].town.name, "Near", "second")
	t.near(list[2].detour, 2 * math.sqrt(5000 * 5000 + 1000 * 1000) - 10000, 1e-6, "detour")
	t.near(list[2].along, 0.5, 1e-9, "along")
end)

t.test("corridor: a bigger budget takes more towns", function()
	t.eq(#corridor.candidates(A, B, { NEAR, FAR, EARLY }, 0.3), 3, "count")
end)

t.test("corridor: order puts the picked towns between the ends", function()
	local stops = corridor.order(A, B, { NEAR, EARLY, A })
	t.eq(#stops, 4, "count")
	t.eq(stops[1].name, "A", "1")
	t.eq(stops[2].name, "Early", "2")
	t.eq(stops[3].name, "Near", "3")
	t.eq(stops[4].name, "B", "4")
end)

local function tourLength(stops)
	local l = 0
	for k = 2, #stops do
		local p, q = stops[k - 1].pos, stops[k].pos
		l = l + math.sqrt((q.x - p.x) ^ 2 + (q.y - p.y) ^ 2)
	end
	return l
end

local function names(stops)
	local list = {}
	for __, town in ipairs(stops) do
		table.insert(list, town.name)
	end
	return table.concat(list, " ")
end

-- Towns either side of the line, each within 15% on its own (about 6% each), but not all together.
local ZIGZAG = {
	town(11, "Up1", 2000, 1500),
	town(12, "Down1", 4000, -1500),
	town(13, "Up2", 6000, 1500),
	town(14, "Down2", 8000, -1500),
	town(15, "OnLine", 5000, 50),
}

t.test("corridor: select keeps the whole line within the budget, not each town", function()
	local candidates = corridor.candidates(A, B, ZIGZAG, 0.15)
	t.eq(#candidates, 5, "each town fits on its own")
	local chosen = corridor.select(A, B, candidates, 0.15)
	t.ok(#chosen < 5, "not all: " .. names(chosen))
	local stops = { A }
	for __, town in ipairs(chosen) do
		table.insert(stops, town)
	end
	table.insert(stops, B)
	t.ok(tourLength(stops) <= 1.15 * 10000 + 1e-6, "within the budget: " .. tourLength(stops))
	-- The town on the line costs next to nothing, so it's always taken.
	local onLine = false
	for __, town in ipairs(chosen) do
		onLine = onLine or town.name == "OnLine"
	end
	t.ok(onLine, "on the line taken: " .. names(chosen))
	-- No town left out would still fit anywhere.
	for __, candidate in ipairs(candidates) do
		local taken = false
		for __, town in ipairs(chosen) do
			taken = taken or town.id == candidate.town.id
		end
		if not taken then
			for k = 2, #stops do
				local with = {}
				for j = 1, #stops do
					if j == k then
						table.insert(with, candidate.town)
					end
					table.insert(with, stops[j])
				end
				t.ok(tourLength(with) > 1.15 * 10000, candidate.town.name .. " would have fitted")
			end
		end
	end
end)

t.test("corridor: select returns the towns in route order", function()
	local chosen = corridor.select(A, B, corridor.candidates(A, B, { NEAR, EARLY, FAR }, 0.5), 0.5)
	t.eq(names(chosen), "Early Near Far", "order")
end)

t.test("corridor: select takes nothing when no town fits", function()
	t.eq(#corridor.select(A, B, corridor.candidates(A, B, { FAR }, 0.3), 0.1), 0, "none")
end)

t.test("corridor: order inserts each town where it adds least, not by projection", function()
	-- By projection: Up1 (0.4), Dip (0.45), Up2 (0.5), a zigzag down and back up. Up1 and Up2 belong together.
	local up1, dip, up2 = town(21, "Up1", 4000, 3000), town(22, "Dip", 4500, -100), town(23, "Up2", 5000, 3000)
	local stops = corridor.order(A, B, { up1, dip, up2 })
	t.eq(#stops, 5, "count")
	t.eq(stops[1].name, "A", "first")
	t.eq(stops[5].name, "B", "last")
	local at = {}
	for k, s in ipairs(stops) do
		at[s.name] = k
	end
	t.eq(math.abs(at.Up1 - at.Up2), 1, "Up1 and Up2 together: " .. names(stops))
	local projected = { A, up1, dip, up2, B }
	t.ok(tourLength(stops) < tourLength(projected), "shorter than by projection")
end)

t.test("corridor: order of select's towns is select's order", function()
	local candidates = corridor.candidates(A, B, ZIGZAG, 0.15)
	local chosen = corridor.select(A, B, candidates, 0.15)
	local stops = corridor.order(A, B, chosen)
	t.eq(names(stops), "A " .. names(chosen) .. " B", "same order")
end)
