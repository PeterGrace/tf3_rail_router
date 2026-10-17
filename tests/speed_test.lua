local t = ...
local speed = t.requireTl("gui/pgrace_rail_router/planner/speed.tl")

-- Fastest on high-speed track: curves of 3000 m or wider are free, 2 m/s² sideways.
local W = { minRadius = 3000, lateralAccel = 2, topSpeed = math.sqrt(2 * 3000) }

t.test("speed: a curve's speed is sqrt(lateral acceleration × radius), at most the top speed", function()
	t.near(speed.curveSpeed(200, W), 20, 1e-9, "200 m")
	t.near(speed.curveSpeed(3000, W), W.topSpeed, 1e-9, "the mode's radius")
	t.near(speed.curveSpeed(10000, W), W.topSpeed, 1e-9, "wider")
end)

t.test("speed: a short run is accelerating then braking", function()
	-- 0.5 m/s² up, 1 m/s² down, never power-limited below 24 m/s: v² (1/1 + 1/2) = 200 m, so v = 11.55 m/s, and
	-- v / 0.5 + v / 1 seconds.
	local v = math.sqrt(200 / 1.5)
	t.near(speed.runTime(200, {}, 100), v / 0.5 + v / 1, 0.5, "200 m")
	t.eq(speed.runTime(0, {}, 100), 0, "nothing to run")
end)

t.test("speed: a long run tops out at the top speed", function()
	-- 30 km at 50 m/s at most: the cruise takes most of it.
	local time = speed.runTime(30000, {}, 50)
	t.ok(time > 30000 / 50, "slower than cruising all the way: " .. time)
	t.ok(time < 30000 / 50 + 200, "but not by much: " .. time)
	t.ok(speed.runTime(30000, {}, 30) > time, "a lower top speed takes longer")
end)

t.test("speed: time lost to a limit", function()
	t.eq(speed.timeLost(5000, {}, W.topSpeed), 0, "none without limits")
	local mid = speed.timeLost(5000, { { s0 = 2400, s1 = 2600, v = 15 } }, W.topSpeed)
	t.ok(mid > 5, "a 15 m/s stretch mid-leg costs time: " .. mid)
	-- Near a stop the train is slow anyway.
	local near = speed.timeLost(5000, { { s0 = 50, s1 = 250, v = 15 } }, W.topSpeed)
	t.ok(near < mid / 3, ("near the start it costs less: %.1f s against %.1f s"):format(near, mid))
	-- A limit above the speed the train reaches there costs nothing: on 1 km it peaks below 20 m/s.
	t.near(speed.timeLost(1000, { { s0 = 400, s1 = 600, v = 25 } }, W.topSpeed), 0, 1e-9, "above the speed reached")
	-- Two limits close together slow the train once, not twice over.
	local one = speed.timeLost(5000, { { s0 = 2400, s1 = 2500, v = 15 } }, W.topSpeed)
	local two = speed.timeLost(5000, { { s0 = 2400, s1 = 2500, v = 15 }, { s0 = 2550, s1 = 2650, v = 15 } }, W.topSpeed)
	t.ok(two < 2 * one, ("two close limits %.1f s, one %.1f s"):format(two, one))
end)

t.test("speed: the limits along fitted pieces are their arcs below the mode's radius", function()
	local pieces = {
		{ kind = "straight", length = 500 },
		{ kind = "arc", length = 200, radius = 450 },
		{ kind = "straight", length = 300 },
		{ kind = "arc", length = 400, radius = 3000 },
		{ kind = "arc", length = 100, radius = 800 },
	}
	local limits, length = speed.pieceLimits(pieces, 80, W)
	t.eq(length, 1500, "length")
	t.eq(#limits, 2, "two arcs below 3000 m")
	t.near(limits[1].s0, 580, 1e-9, "first from")
	t.near(limits[1].s1, 780, 1e-9, "first to")
	t.near(limits[1].v, 30, 1e-9, "first speed")
	t.near(limits[2].s0, 1480, 1e-9, "second from")
	t.near(limits[2].v, 40, 1e-9, "second speed")
end)
