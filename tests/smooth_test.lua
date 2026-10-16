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

t.test("smooth: simplify measures to the segment, not the line through it", function()
	-- The middle point overshoots the end along the same line: a reversal, not a straight.
	local pts = smooth.simplify({ P(0, 0), P(2000, 0), P(1000, 0) }, 10)
	t.eq(#pts, 3, "overshoot kept")
end)

t.test("smooth: duplicate points don't make zero-radius arcs", function()
	local fixed = {}
	fixed[2], fixed[3] = true, true
	local r = smooth.fillet({ P(0, 0), P(1000, 0), P(1000, 0), P(1000, 1000) }, 200, fixed)
	t.near(r.minRadius, 200, 1e-6, "radius kept")
	local arcs = 0
	for __, piece in ipairs(r.pieces) do
		if piece.kind == "arc" then
			arcs = arcs + 1
		end
	end
	t.eq(arcs, 1, "one arc")
	local straightLine = smooth.fillet({ P(0, 0), P(1000, 0), P(1000, 0), P(2000, 0) }, 200, {})
	t.eq(#straightLine.pieces, 1, "duplicate on a straight")
	t.eq(straightLine.minRadius, math.huge, "no arcs")
	local lastDup = smooth.fillet({ P(0, 0), P(1000, 0), P(1000, 0) }, 200, {})
	t.eq(#lastDup.pieces, 1, "duplicate end")
	t.near(lastDup.pieces[1].length, 1000, 1e-9, "end kept")
end)

t.test("smooth: fillet of fewer than two points has no pieces", function()
	for __, pts in ipairs({ {}, { P(5, 5) } }) do
		local r = smooth.fillet(pts, 200, {})
		t.eq(#r.pieces, 0, "pieces")
		t.eq(r.minRadius, math.huge, "radius")
		t.eq(r.removed, 0, "removed")
	end
end)

t.test("smooth: simplify gives the kept points' indices", function()
	local pts, idx = smooth.simplify({ P(0, 0), P(500, 0), P(1000, 0), P(1000, 500), P(1000, 1000) }, 10)
	t.eq(#idx, #pts, "one index per point")
	t.eq(idx[1], 1, "first")
	t.eq(idx[2], 3, "corner")
	t.eq(idx[3], 5, "last")
end)

t.test("smooth: simplify splits a straight that isn't clear", function()
	local line = { P(0, 0), P(100, 0), P(200, 0), P(300, 1), P(400, 0) }
	-- Everything is within tolerance, but the whole range is refused: split at the middle index.
	local pts, idx = smooth.simplify(line, 10, function(i, j)
		return not (i == 1 and j == 5)
	end)
	t.eq(#pts, 3, "an interior point kept")
	t.eq(idx[2], 3, "the middle one")
	t.eq(pts[2].x, 200, "its x")
	-- Nothing is ever clear: every point stays, and ranges without an interior point aren't split.
	local all = smooth.simplify(line, 10, function()
		return false
	end)
	t.eq(#all, 5, "all kept")
	-- A clear() that always agrees changes nothing.
	t.eq(#smooth.simplify(line, 10, function()
		return true
	end), 2, "as without")
end)

-- A guard refusing every point within `r` of `c`.
local function disc(c, r, step)
	return { step = step, clear = function(p)
		local dx, dy = p.x - c.x, p.y - c.y
		return dx * dx + dy * dy > r * r
	end }
end

local function minDist(pieces, c, step)
	local best = math.huge
	for __, sample in ipairs(smooth.sample(pieces, step)) do
		local dx, dy = sample.p.x - c.x, sample.p.y - c.y
		best = math.min(best, math.sqrt(dx * dx + dy * dy))
	end
	return best
end

t.test("smooth: a guarded fillet keeps a point whose removal would cut through the disc", function()
	local jog = { P(0, 0), P(500, 0), P(550, 50), P(1000, 50) }
	local c = P(500, 40)
	local plain = smooth.fillet(jog, 200, {})
	t.eq(plain.removed, 1, "unguarded drops a point")
	t.ok(minDist(plain.pieces, c, 2) < 8, "and cuts through the disc")
	local r = smooth.fillet(jog, 200, {}, disc(c, 8, 5))
	-- The point at (550, 50) goes instead: the straight left without it is clear.
	t.eq(r.removed, 1, "the other point dropped")
	t.ok(r.guarded > 0, "guarded " .. r.guarded)
	t.ok(minDist(r.pieces, P(500, 0), 1) < 5, "the corner kept")
	t.ok(minDist(r.pieces, c, 2) > 8, "clear of the disc")
end)

t.test("smooth: a guarded fillet tightens an arc that crosses the disc", function()
	local corner = { P(0, 0), P(1000, 0), P(1000, 1000) }
	local c = P(960, 40)
	local plain = smooth.fillet(corner, 200, {})
	t.ok(minDist(plain.pieces, c, 2) < 30, "unguarded cuts through")
	local r = smooth.fillet(corner, 200, {}, disc(c, 30, 10))
	t.ok(r.guarded > 0, "guarded " .. r.guarded)
	t.ok(minDist(r.pieces, c, 2) > 30, "clear of the disc")
	t.near(r.minRadius, 50, 1e-6, "halved twice")
end)

t.test("smooth: the guard never tightens an arc below its minRadius", function()
	local corner = { P(0, 0), P(1000, 0), P(1000, 1000) }
	local guard = disc(P(960, 40), 30, 10)
	guard.minRadius = 120
	local r = smooth.fillet(corner, 200, {}, guard)
	t.near(r.minRadius, 120, 1e-6, "stops at the floor")
	t.ok(r.guarded > 0, "still counted")
end)

-- Distance from p to the polyline through pts.
local function polylineDist(p, pts)
	local best = math.huge
	for k = 2, #pts do
		local a, b = pts[k - 1], pts[k]
		local abx, aby = b.x - a.x, b.y - a.y
		local f = math.max(0, math.min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / (abx * abx + aby * aby)))
		local dx, dy = p.x - a.x - abx * f, p.y - a.y - aby * f
		best = math.min(best, math.sqrt(dx * dx + dy * dy))
	end
	return best
end

t.test("smooth: the guard lets a point go rather than keep it with curves below its minRadius", function()
	-- Keeping (500, 0) would squeeze both 45° turns onto the 71 m between it and (550, 50): 85 m curves. Cutting the
	-- corner is the lesser evil.
	local jog = { P(0, 0), P(500, 0), P(550, 50), P(1000, 50) }
	local r = smooth.fillet(jog, 200, {}, { step = 5, minRadius = 120, clear = function(p)
		return polylineDist(p, jog) <= 1
	end })
	t.ok(r.minRadius >= 120 - 1e-6, "radius " .. r.minRadius)
	t.eq(r.removed, 1, "dropped anyway")
end)

t.test("smooth: a guard that finds nothing changes nothing", function()
	local jog = { P(0, 0), P(500, 0), P(550, 50), P(1000, 50) }
	local plain = smooth.fillet(jog, 200, {})
	local r = smooth.fillet(jog, 200, {}, disc(P(5000, 5000), 10, 10))
	t.eq(r.guarded, 0, "guarded")
	t.eq(r.removed, plain.removed, "removed")
	t.eq(#r.pieces, #plain.pieces, "pieces")
	t.near(r.minRadius, plain.minRadius, 1e-9, "radius")
end)

t.test("smooth: the guard is asked about the input points each piece replaces", function()
	-- Point 2 is dropped: the straight from 1 to 3 replaces input points 1 to 3, and the arc at 3 (between 1 and 4)
	-- replaces 1 to 4.
	local seen = {}
	smooth.fillet({ P(0, 0), P(500, 0), P(550, 50), P(1000, 50) }, 200, {}, { step = 50, clear = function(p, from, to)
		seen[from .. "-" .. to] = true
		return true
	end })
	t.ok(seen["1-3"], "1-3")
	t.ok(seen["1-4"], "1-4")
end)
