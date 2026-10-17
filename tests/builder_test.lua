local t = ...
local builder = t.requireTl("gui/pgrace_rail_router/builder.tl")

local function hit(what)
	return { entity = 1, what = what, x = 0, y = 0 }
end

t.test("builder: streets collided with are level crossings", function()
	t.eq(builder.levelCrossings({ "Collision" }, { hit("street") }), 1, "one street")
	t.eq(builder.levelCrossings({ "Collision" }, { hit("street"), hit("street") }), 2, "two streets")
	t.eq(builder.levelCrossings({ "Collision" }, { hit("street"), hit("track"), hit("street") }), 2,
		"with track hit too: the streets still count")
end)

t.test("builder: no level crossings where nothing is a street, or another error came too", function()
	t.eq(builder.levelCrossings({ "Collision" }, { hit("track") }), 0, "track")
	t.eq(builder.levelCrossings({ "Collision", "Too Much Incline" }, { hit("street") }), 0, "another message")
	t.eq(builder.levelCrossings({ "Collision" }, {}), 0, "nothing known to have been hit")
end)
