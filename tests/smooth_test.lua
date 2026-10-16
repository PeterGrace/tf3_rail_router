local t = ...
local smooth = t.requireTl("gui/pgrace_rail_router/planner/smooth.tl")

local function P(x, y)
	return { x = x, y = y }
end

t.test("smooth: simplify drops points on a straight line", function()
	local pts = smooth.simplify({ P(0, 0), P(100, 0), P(200, 0), P(300, 1), P(400, 0) }, 10)
	t.eq(#pts, 2, "two ends left")
	t.eq(pts[2].x, 400, "last kept")
end)

t.test("smooth: simplify keeps a real corner", function()
	local pts = smooth.simplify({ P(0, 0), P(500, 0), P(1000, 0), P(1000, 500), P(1000, 1000) }, 10)
	t.eq(#pts, 3, "corner kept")
	t.eq(pts[2].x, 1000, "corner x")
	t.eq(pts[2].y, 0, "corner y")
end)

t.test("smooth: a right-angle corner becomes straight, arc, straight", function()
	local r = smooth.fillet({ P(0, 0), P(1000, 0), P(1000, 1000) }, 200, {})
	t.eq(#r.pieces, 3, "pieces")
	t.eq(r.pieces[1].kind, "straight", "1")
	t.near(r.pieces[1].length, 800, 1e-6, "first straight")
	local arc = r.pieces[2]
	t.eq(arc.kind, "arc", "2")
	t.near(arc.radius, 200, 1e-6, "radius")
	t.near(arc.centre.x, 800, 1e-6, "centre x")
	t.near(arc.centre.y, 200, 1e-6, "centre y")
	t.near(arc.turn, math.pi / 2, 1e-9, "left turn")
	t.near(arc.length, 100 * math.pi, 1e-6, "arc length")
	local e = smooth.pointAt(arc, arc.length)
	t.near(e.x, 1000, 1e-6, "arc ends at x")
	t.near(e.y, 200, 1e-6, "arc ends at y")
	t.near(r.pieces[3].length, 800, 1e-6, "last straight")
	t.near(r.minRadius, 200, 1e-6, "min radius")
	t.eq(r.removed, 0, "nothing dropped")
end)

t.test("smooth: a right turn curves the other way", function()
	local r = smooth.fillet({ P(0, 0), P(1000, 0), P(1000, -1000) }, 200, {})
	t.ok(r.pieces[2].turn < 0, "negative turn")
	local e = smooth.pointAt(r.pieces[2], r.pieces[2].length)
	t.near(e.x, 1000, 1e-6, "x")
	t.near(e.y, -200, 1e-6, "y")
end)

t.test("smooth: a jog too short for two curves loses a point", function()
	local r = smooth.fillet({ P(0, 0), P(500, 0), P(550, 50), P(1000, 50) }, 200, {})
	t.eq(r.removed, 1, "one dropped")
	t.near(r.minRadius, 200, 1e-6, "radius kept")
end)

t.test("smooth: fixed points are kept and the arcs tighten", function()
	local fixed = {}
	fixed[2], fixed[3] = true, true
	local r = smooth.fillet({ P(0, 0), P(100, 0), P(100, 100), P(200, 100) }, 200, fixed)
	t.eq(r.removed, 0, "nothing dropped")
	t.near(r.minRadius, 50, 1e-6, "tightened")
end)

t.test("smooth: a straight line is one piece", function()
	local r = smooth.fillet({ P(0, 0), P(100, 0), P(200, 0) }, 200, {})
	t.eq(#r.pieces, 1, "one straight")
	t.near(r.pieces[1].length, 200, 1e-9, "length")
	t.eq(r.minRadius, math.huge, "no arcs")
end)

t.test("smooth: samples cover the pieces", function()
	local straight = smooth.sample(smooth.fillet({ P(0, 0), P(1000, 0) }, 200, {}).pieces, 100)
	t.eq(#straight, 11, "count")
	t.near(straight[11].s, 1000, 1e-9, "last s")
	t.near(straight[11].p.x, 1000, 1e-9, "last x")
	local r = smooth.fillet({ P(0, 0), P(1000, 0), P(1000, 1000) }, 200, {})
	for __, sample in ipairs(smooth.sample({ r.pieces[2] }, 10)) do
		local dx, dy = sample.p.x - 800, sample.p.y - 200
		t.near(math.sqrt(dx * dx + dy * dy), 200, 1e-6, "on the arc")
	end
end)
