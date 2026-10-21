local t = ...
local placement = t.requireTl("gui/pgrace_rail_router/planner/placement.tl")
local midline = t.requireTl("gui/pgrace_rail_router/planner/midline.tl")
local junction = t.requireTl("gui/pgrace_rail_router/planner/junction.tl")

-- A midline: `straight` m along +x, then a left arc of radius r through `deg` degrees, then `tail` m straight.
local function track(straight, r, deg, tail)
	local pts = {}
	for x = 0, straight, 1 do
		pts[#pts + 1] = { x = x, y = 0, z = 0 }
	end
	local th = math.rad(deg)
	local n = math.ceil(r * th)
	for i = 1, n do
		local a = th * i / n
		pts[#pts + 1] = { x = straight + r * math.sin(a), y = r * (1 - math.cos(a)), z = 0 }
	end
	local ex, ey = straight + r * math.sin(th), r * (1 - math.cos(th))
	for s = 1, tail do
		pts[#pts + 1] = { x = ex + s * math.cos(th), y = ey + s * math.sin(th), z = 0 }
	end
	return midline.fromPoints(pts, midline.STEP)
end

local O = { minRadius = 100, straight = 50, offset = 10, slack = 0.5, cell = 100 }

t.test("placement: a frame piece maps onto a straight frame unchanged", function()
	local f = midline.line({ x = 0, y = 0 }, { x = 1, y = 0 }, 0, 0, 500)
	local h = placement.mapPiece(f, { x0 = 10, y0 = 2.5, x1 = 120, y1 = 12.5, tx0 = 110, ty0 = 0, tx1 = 110, ty1 = 0,
		role = "merge" })
	t.near(h.p0.x, 10, 1e-9, "p0 x")
	t.near(h.p0.y, 2.5, 1e-9, "p0 y")
	t.near(h.p1.y, 12.5, 1e-9, "p1 y")
	t.near(h.t0.x, 110, 1e-9, "t0 along")
	t.near(h.t1.y, 0, 1e-9, "t1 across")
end)

t.test("placement: tightest radius of an arc and a straight", function()
	-- A quarter circle of radius 200 as a Hermite (tangent length 4 r tan(θ/4)).
	local r, l = 200, 4 * 200 * math.tan(math.pi / 8)
	local h = { p0 = { x = 0, y = 0, z = 0 }, p1 = { x = r, y = r, z = 0 }, t0 = { x = l, y = 0, z = 0 },
		t1 = { x = 0, y = l, z = 0 } }
	t.near(placement.tightest(h), r, r * 0.02, "about 200 m")
	local s = { p0 = { x = 0, y = 0, z = 0 }, p1 = { x = 100, y = 0, z = 0 }, t0 = { x = 100, y = 0, z = 0 },
		t1 = { x = 100, y = 0, z = 0 } }
	t.eq(placement.tightest(s), math.huge, "straight")
end)

t.test("placement: our straight runs on beside a curve away from us, and stops where it curves towards us", function()
	local f = track(100, 220, 70, 300)
	-- Approach start at x = 150, on the arc. Our side −1 (right, the curve's outside): the track turns away, so the
	-- straight runs far; side +1 (inside): the track comes back across our straight within about 46 m.
	t.ok(placement.rayRoom(f, 150, -1, 10, 0.5, 100) >= 50, "outside: room for 50 m")
	t.ok(placement.rayRoom(f, 150, 1, 10, 0.5, 100) < 50, "inside: under 50 m")
	-- Past the arc (it ends at 100 + 268.8), the inside has room again.
	t.ok(placement.rayRoom(f, 400, 1, 10, 0.5, 100) >= 50, "inside, on the straight beyond: room")
end)

t.test("placement: accept takes a junction on a 220 m curve from the outside, its pieces 100 m or wider", function()
	local f = track(100, 220, 70, 300)
	local ok = placement.accept(f, -1, O)
	local j = junction.fit(f.length - 50, 300, -1, { near = {}, far = {} }, nil, ok)
	t.ok(j ~= nil, "fits")
	local first = math.huge
	for __, c in ipairs(j.cuts) do
		first = math.min(first, c.x)
	end
	t.ok(first < 100 + 268.8, ("the first cut (%.1f) is on the curve"):format(first))
	for __, p in ipairs(j.pieces) do
		t.ok(placement.tightest(placement.mapPiece(f, p)) >= 100, p.role .. " no tighter than 100 m")
	end
end)

t.test("placement: a branch the curve bends tighter than the floor is refused", function()
	local f = track(100, 220, 70, 600)
	local strict = { minRadius = 1000, straight = 50, offset = 10, slack = 0.5, cell = 100 }
	-- The fit's 300 m turnouts are under 1000 m wherever they go, but on straight track that's their own radius, not
	-- the curve's doing. On the outside the curve widens them: a placement on it. On the inside it bends them
	-- tighter: only one wholly on the straight tail (the arc ends at 100 + 268.8).
	for __, case in ipairs({ { side = -1, onCurve = true }, { side = 1, onCurve = false } }) do
		local j = junction.fit(f.length - 50, 300, case.side, { near = {}, far = {} }, nil,
			placement.accept(f, case.side, strict))
		t.ok(j ~= nil, "side " .. case.side .. ": fits")
		local first = math.huge
		for __, c in ipairs(j.cuts) do
			first = math.min(first, c.x)
		end
		t.eq(first < 100 + 268.8, case.onCurve, ("side %d: the first cut (%.1f) on the curve"):format(case.side, first))
	end
end)

t.test("placement: 150 m turnouts' merge (94 m as one Hermite) passes on straight track, and isn't bent tighter",
		function()
	-- Standard track's 150 m turnouts: the merge S-curve, 10 m across over 75 m, is 94 m at its ends as one cubic.
	local straight = midline.line({ x = 0, y = 0 }, { x = 1, y = 0 }, 0, 0, 1000)
	local j = junction.fit(straight.length - 50, 150, 1, { near = {}, far = {} }, nil, placement.accept(straight, 1, O))
	t.ok(j ~= nil, "fits on straight track")
	t.near(j.cuts[1].x, 15, 1e-6, "at the first place tried")
	local own = math.huge
	for __, p in ipairs(j.pieces) do
		own = math.min(own, placement.tightest(placement.mapPiece(straight, p)))
	end
	t.ok(own < 100, ("its tightest piece (%.0f m) is under the floor"):format(own))
	-- On the inside of a 220 m curve the curve bends the pieces tighter still: whatever fits keeps them no tighter.
	local f = track(100, 220, 70, 300)
	local inside = junction.fit(f.length - 50, 150, 1, { near = {}, far = {} }, nil, placement.accept(f, 1, O))
	t.ok(inside ~= nil, "fits")
	for __, p in ipairs(inside.pieces) do
		local r = placement.tightest(placement.mapPiece(f, p))
		t.ok(r >= own * 0.99, ("%s: %.0f m, no tighter than on straight track"):format(p.role, r))
	end
end)

t.test("placement: rayRoom with a limit stops once that far, and agrees below it", function()
	local f = track(100, 220, 70, 300)
	local full = placement.rayRoom(f, 150, -1, 10, 0.5, 100)
	local capped = placement.rayRoom(f, 150, -1, 10, 0.5, 100, 50)
	t.ok(capped >= 50 and capped <= full and capped < 60, ("capped at %.1f of %.1f"):format(capped, full))
	-- Inside, where the room is under the limit, the same answer either way.
	t.eq(placement.rayRoom(f, 150, 1, 10, 0.5, 100, 50), placement.rayRoom(f, 150, 1, 10, 0.5, 100), "inside")
end)
