local t = ...
-- build.tl drives the game's commands; only its bookkeeping is tested here, with the engine missing (every engine
-- call throws, as an error in any step would).
debugPrint = debugPrint or function() end
local build = t.requireTl("gui/pgrace_rail_router/build.tl")

local function check()
	return { plan = { stations = { { town = { name = "A" }, z = 0 }, { town = { name = "B" }, existing = { half = 100 } } },
		legs = {}, platformLength = 160 }, net = { chunks = {}, edges = {}, nodes = {} }, settings = {} }
end

t.test("build: an error in the roads phase fails a road, not a chunk past the last", function()
	local b = build.start(check())
	b.phase, b.station = "roads", 3
	t.eq(build.step(b), true, "stopped")
	t.eq(b.phase, "failed", "failed")
	t.eq(b.failure.item.kind, "road", "a road")
	t.eq(b.failure.item.index, 1, "station 1's")
	build.retry(b)
	t.eq(b.phase, "roads", "retry carries on with the roads")
end)
