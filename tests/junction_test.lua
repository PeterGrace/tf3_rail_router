local t = ...
local junction = t.requireTl("gui/pgrace_rail_router/planner/junction.tl")

-- Standard track: R = 300.
local R = 300
local THETA = math.acos(1 - 5 / R)
local C = R * math.sin(THETA)

t.test("junction: S-curve and crossing arcs follow the radius", function()
	t.eq(junction.sCurve(10, 300), 110, "standard, 10 m")
	t.eq(junction.sCurve(10, 600), 155, "high-speed, 10 m")
	t.eq(junction.sCurve(5, 300), 75, "standard, 5 m (as the fans)")
	t.near(math.deg(junction.crossAngle(300)), 10.48, 0.01, "standard: about 10.5 degrees")
	t.near(junction.crossRun(300), 54.54, 0.01, "standard: about 54.5 m")
	t.near(math.deg(junction.crossAngle(600)), 7.40, 0.01, "high-speed: about 7.4 degrees")
	t.near(junction.needed(300), 110 + 2 * C + 80, 1e-9, "S-curve + two arcs + 80")
end)

t.test("junction: from the station out, merge, gap, crossing arcs, approach; cuts where they touch", function()
	local j = junction.fit(400, R, 1, { near = {}, far = {} })
	t.ok(j ~= nil, "fits in 400 m")
	local by = {}
	for __, p in ipairs(j.pieces) do
		by[p.role] = p
	end
	local merge, cin, cout = by["merge"], by["cross in"], by["cross out"]
	t.near(merge.x0, 15, 1e-9, "the merge's switch 15 m out")
	t.near(merge.y0, 2.5, 1e-9, "on the existing near track")
	t.near(merge.x1, 125, 1e-9, "110 m S-curve")
	t.near(merge.y1, 12.5, 1e-9, "to our far track")
	t.near(merge.tx0, 110, 1e-9, "S-curve tangent along x")
	t.near(merge.ty0, 0, 1e-9, "flat at the switch")
	t.near(merge.ty1, 0, 1e-9, "flat at our track")
	t.near(cin.x0, 145, 1e-9, "20 m further out")
	t.near(cin.y0, -2.5, 1e-9, "from the existing far track")
	t.near(cin.x1, 145 + C, 1e-9, "one arc's run")
	t.near(cin.y1, 2.5, 1e-9, "to the crossing node on the near track")
	t.near(cin.ty0, 0, 1e-9, "leaves the far track along it")
	t.near(math.atan(cin.ty1 / cin.tx1), THETA, 1e-9, "crosses at the arc's angle")
	t.near(math.sqrt(cin.tx1 ^ 2 + cin.ty1 ^ 2), R * THETA, 1e-9, "tangent as long as the arc")
	t.near(cout.x0, cin.x1, 1e-9, "the outer arc starts at the crossing node")
	t.near(cout.tx0, cin.tx1, 1e-9, "tangent to the inner arc there (x)")
	t.near(cout.ty0, cin.ty1, 1e-9, "tangent to the inner arc there (y)")
	t.near(cout.x1, 145 + 2 * C, 1e-9, "a second run")
	t.near(cout.y1, 7.5, 1e-9, "to our near track")
	t.near(cout.ty1, 0, 1e-9, "flat at our track")
	t.near(j.approachX, 145 + 2 * C + 30, 1e-9, "30 m of approach")
	local byKind = {}
	for __, c in ipairs(j.cuts) do
		byKind[c.track .. " " .. c.kind] = c.x
	end
	t.near(byKind["near switch"], 15, 1e-9, "merge switch")
	t.near(byKind["far switch"], 145, 1e-9, "crossing track's switch")
	t.near(byKind["near crossing"], 145 + C, 1e-9, "the crossing node where the arcs meet")
end)

t.test("junction: mirrored for a line from the other side", function()
	local j = junction.fit(400, R, -1, { near = {}, far = {} })
	for __, p in ipairs(j.pieces) do
		if p.role == "merge" then
			t.near(p.y0, -2.5, 1e-9, "the near track is at −2.5")
			t.near(p.y1, -12.5, 1e-9, "our far track at −12.5")
		elseif p.role == "cross in" then
			t.near(p.y0, 2.5, 1e-9, "from the far track at +2.5")
			t.ok(p.ty1 < 0, "turning towards −y")
		end
	end
end)

t.test("junction: moves out past existing signals, and fails when it can't fit", function()
	local j = junction.fit(500, R, 1, { near = { 20 }, far = {} })
	t.ok(j ~= nil, "fits further out")
	for __, c in ipairs(j.cuts) do
		if c.track == "near" then
			t.ok(math.abs(c.x - 20) >= 15, "cut " .. c.kind .. " 15 m clear of the signal at 20")
		end
	end
	t.ok(junction.fit(junction.needed(R), R, 1, { near = {}, far = {} }) ~= nil, "exactly the length needed fits")
	t.ok(junction.fit(junction.needed(R) - 1, R, 1, { near = {}, far = {} }) == nil, "1 m less is too short")
end)
