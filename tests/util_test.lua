local t = ...
local util = t.requireTl("gui/pgrace_rail_router/util.tl")

t.test("greet: uses the name", function()
	t.eq(util.greet("Bronx Saw Mill"), "Hello, Bronx Saw Mill!")
end)

t.test("greet: handles an empty name", function()
	t.eq(util.greet(""), "Hello!")
	t.eq(util.greet(nil), "Hello!")
end)
