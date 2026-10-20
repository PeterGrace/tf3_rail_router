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

t.test("placement: a branch tighter than the floor is refused", function()
	local f = track(100, 220, 70, 300)
	local strict = { minRadius = 1000, straight = 50, offset = 10, slack = 0.5, cell = 100 }
	local j = junction.fit(f.length - 50, 300, -1, { near = {}, far = {} }, nil, placement.accept(f, -1, strict))
	-- Only a placement wholly on the straight tail (its S-curves 300 m-ish there, but the fit's turnouts at 300 m
	-- are still under 1000 m): none.
	t.ok(j == nil, "no placement with every piece 1000 m or wider")
end)
