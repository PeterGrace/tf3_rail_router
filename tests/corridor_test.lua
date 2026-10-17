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
