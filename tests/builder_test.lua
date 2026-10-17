local t = ...
local builder = t.requireTl("gui/pgrace_rail_router/builder.tl")

local function hit(what)
	return { entity = 1, what = what, x = 0, y = 0 }
end

t.test("builder: collisions with streets alone are level crossings", function()
	t.ok(builder.crossingsOnly({ "Collision" }, { hit("street") }), "one street")
	t.ok(builder.crossingsOnly({ "Collision" }, { hit("street"), hit("street") }), "two streets")
end)

t.test("builder: anything else in the way is an error", function()
	t.ok(not builder.crossingsOnly({ "Collision" }, { hit("street"), hit("building") }), "a building too")
	t.ok(not builder.crossingsOnly({ "Collision" }, { hit("track") }), "track")
	t.ok(not builder.crossingsOnly({ "Collision", "Too Much Incline" }, { hit("street") }), "another message")
	t.ok(not builder.crossingsOnly({ "Collision" }, {}), "nothing known to have been hit")
end)
