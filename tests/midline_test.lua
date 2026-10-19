local t = ...
local midline = t.requireTl("gui/pgrace_rail_router/planner/midline.tl")

-- An arc of radius r turning left from (0, 0) heading +x, sampled every metre, at height z0 + g × s.
local function arc(r, len, z0, g)
	local pts = {}
	for s = 0, len do
		local a = s / r
		pts[#pts + 1] = { x = r * math.sin(a), y = r * (1 - math.cos(a)), z = z0 + g * s }
	end
	return pts
end

t.test("midline: a line maps as 4b's straight frame", function()
	local f = midline.line({ x = 10, y = 20 }, { x = 0.6, y = 0.8 }, 5, 0.01, 300)
	local p = midline.world(f, 100, 7.5)
	t.near(p.x, 10 + 0.6 * 100 - 0.8 * 7.5, 1e-9, "x") t.near(p.y, 20 + 0.8 * 100 + 0.6 * 7.5, 1e-9, "y")
	t.near(p.z, 5 + 0.01 * 100, 1e-9, "z")
	local v = midline.vector(f, 40, 50, 5)
	t.near(v.x, 0.6 * 50 - 0.8 * 5, 1e-9, "vx") t.near(v.y, 0.8 * 50 + 0.6 * 5, 1e-9, "vy") t.near(v.z, 0.5, 1e-9, "vz")
	local x, y = midline.project(f, p)
	t.near(x, 100, 1e-9, "project x") t.near(y, 7.5, 1e-9, "project y")
	t.near(midline.straightUntil(f, 0, 0.005), 300, 1e-9, "straight all the way")
end)

t.test("midline: a line extends straight past both ends", function()
	local f = midline.line({ x = 0, y = 0 }, { x = 1, y = 0 }, 0, 0.02, 100)
	local p = midline.world(f, -50, 2)
	t.near(p.x, -50, 1e-9, "back x") t.near(p.y, 2, 1e-9, "y") t.near(p.z, -1, 1e-9, "z on the grade")
	local x = midline.project(f, { x = 160, y = 0 })
	t.near(x, 160, 1e-9, "projected past the end")
end)

t.test("midline: from points along an arc follows the arc", function()
	local r = 220
	local f = midline.fromPoints(arc(r, 200, 3, 0.01), midline.STEP)
	t.near(f.step, 5, 1e-9, "step") t.ok(math.abs(f.length - 200) < 0.1, "length along the polyline")
	for __, s in ipairs({ 0, 37, 100, 163, 200 }) do
		local p, d = midline.at(f, s)
		local a = s / r
		t.near(p.x, r * math.sin(a), 0.05, "x at " .. s) t.near(p.y, r * (1 - math.cos(a)), 0.05, "y at " .. s)
		t.near(p.z, 3 + 0.01 * s, 1e-3, "z at " .. s)
		t.near(d.x, math.cos(a), 0.01, "dir x at " .. s) t.near(d.y, math.sin(a), 0.01, "dir y at " .. s)
	end
	-- 7.5 m to the left of the midline is the inner circle, radius r − 7.5.
	local q = midline.world(f, 100, 7.5)
	t.near(math.sqrt(q.x ^ 2 + (q.y - r) ^ 2), r - 7.5, 0.05, "offset to the inside")
	local x, y = midline.project(f, q)
	t.near(x, 100, 0.1, "project back x") t.near(y, 7.5, 0.05, "project back y")
end)

t.test("midline: straightUntil stops where the midline turns", function()
	local pts = {}
	for s = 0, 150 do
		pts[#pts + 1] = { x = s, y = 0, z = 0 }
	end
	for __, p in ipairs(arc(220, 150, 0, 0)) do
		if p.x > 0 then
			pts[#pts + 1] = { x = 150 + p.x, y = p.y, z = 0 }
		end
	end
	local f = midline.fromPoints(pts, midline.STEP)
	local until_ = midline.straightUntil(f, 0, 0.005)
	-- sin(θ) = 0.005 after s = 220 × 0.005 = 1.1 m of arc; the samples smooth the corner by a step or so.
	t.ok(until_ > 145 and until_ < 160, "the straight ends at the curve: " .. until_)
	t.ok(midline.straightUntil(f, 200, 0.005) < 210, "on the curve it turns at once")
end)
