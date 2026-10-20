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

t.test("junction: no existing signal anywhere along the junction, on either track", function()
	-- With nothing in the way the junction spans 15 (the merge's switch) to the cross-out piece's end.
	local free = junction.fit(600, R, 1, { near = {}, far = {} })
	local span1 = 0
	for __, p in ipairs(free.pieces) do
		span1 = math.max(span1, p.x0, p.x1)
	end
	-- A far-track signal between the far switch and the crossing (Aloha: 19 m before it), and a near-track one between
	-- the merge and the crossing: neither is near a cut, and both move the junction out past them.
	for __, case in ipairs({ { near = {}, far = { span1 - 40 } }, { near = { 60 }, far = {} } }) do
		local s = (case.near[1] or case.far[1])
		local j = junction.fit(600, R, 1, case)
		t.ok(j ~= nil, "fits further out")
		local lo, hi = math.huge, -math.huge
		for __, p in ipairs(j.pieces) do
			lo, hi = math.min(lo, p.x0, p.x1), math.max(hi, p.x0, p.x1)
		end
		t.ok(s <= lo - 15 or s >= hi + 15, ("signal at %.1f 15 m clear of the junction %.1f-%.1f"):format(s, lo, hi))
	end
end)

-- With no nodes in the way the merge's switch is at 15, the far switch at 145 and the crossing at 145 + C.
local function cutsOf(j)
	local by = {}
	for __, c in ipairs(j.cuts) do
		by[c.track .. " " .. c.kind] = c.x
	end
	return by
end

local NONE = { near = {}, far = {} }

t.test("junction: no existing node within 20 m outward of a switch or 3 m behind it", function()
	-- A far node 5 m past the far switch (145) would leave 5 m of main track beside the branch: the junction moves out
	-- 5 m, putting the switch on that node.
	local by = cutsOf(junction.fit(600, R, 1, NONE, { near = {}, far = { 150 } }))
	t.near(by["far switch"], 150, 1e-9, "the far switch on the node")
	t.near(by["near switch"], 20, 1e-9, "the merge 5 m further out")
	-- A far node 19 m past it: still too close; 21 m: clear of the switch rule, but the cross-in piece passes it 0.7 m
	-- beside (closer than 2 m), so the switch moves onto it too; 55 m (past the crossing's x): left where it was.
	by = cutsOf(junction.fit(600, R, 1, NONE, { near = {}, far = { 164 } }))
	t.near(by["far switch"], 164, 1e-9, "19 m: moved onto it")
	by = cutsOf(junction.fit(600, R, 1, NONE, { near = {}, far = { 166 } }))
	t.near(by["far switch"], 166, 1e-9, "21 m: moved onto it, the cross-in too close beside it")
	by = cutsOf(junction.fit(600, R, 1, NONE, { near = {}, far = { 200 } }))
	t.near(by["far switch"], 145, 1e-9, "55 m: left where it was")
	-- A near node 0.6 m behind the merge's switch (and before the stretch's 15 m clearance, so not a switch itself):
	-- the merge moves to the next place 3 m clear.
	by = cutsOf(junction.fit(600, R, 1, NONE, { near = { 14.4 }, far = {} }))
	t.near(by["near switch"], 20, 1e-9, "the merge at 20, 5.6 m past the node")
end)

t.test("junction: every piece passes existing nodes at least 2 m beside it (P17)", function()
	-- A near node 27.5 m past the merge's switch, where the merge is about 1.3 m off the near track (P17 refused it):
	-- the junction moves until the node is 2 m clear of every piece, or a cut is on it.
	local free = cutsOf(junction.fit(600, R, 1, NONE))
	local node = free["near switch"] + 27.5
	local j = junction.fit(600, R, 1, NONE, { near = { node }, far = {} })
	t.ok(j ~= nil, "fits")
	local by = cutsOf(j)
	t.ok(by["near switch"] ~= free["near switch"], "the merge moved")
	for __, p in ipairs(j.pieces) do
		for i = 0, 400 do
			local u = i / 400
			local u2, u3 = u * u, u * u * u
			local a, b, c, d = 2 * u3 - 3 * u2 + 1, u3 - 2 * u2 + u, -2 * u3 + 3 * u2, u3 - u2
			local x = a * p.x0 + b * p.tx0 + c * p.x1 + d * p.tx1
			local y = a * p.y0 + b * p.ty0 + c * p.y1 + d * p.ty1
			local dist = math.sqrt((x - node) ^ 2 + (y - 2.5) ^ 2)
			local own = math.abs(p.x0 - node) < 0.5 or math.abs(p.x1 - node) < 0.5
			t.ok(own or dist >= 2 - 0.05, ("%s passes the node %.2f m beside it"):format(p.role, dist))
		end
	end
end)

t.test("junction: a node within half a metre of a switch becomes the switch", function()
	local j = junction.fit(600, R, 1, NONE, { near = { 15.3 }, far = {} })
	local by = cutsOf(j)
	t.near(by["near switch"], 15.3, 1e-9, "the merge's switch on the node")
	for __, p in ipairs(j.pieces) do
		if p.role == "merge" then
			t.near(p.x0, 15.3, 1e-9, "the merge starts there")
			t.near(p.x1, 125, 1e-9, "and ends where it did")
		end
	end
	j = junction.fit(600, R, 1, NONE, { near = {}, far = { 144.6 } })
	by = cutsOf(j)
	t.near(by["far switch"], 144.6, 1e-9, "the far switch on its node")
	t.near(by["near crossing"], 145 + C, 1e-9, "the crossing where it was")
end)

t.test("junction: the crossing keeps 3 m from a node, or crosses at it", function()
	-- A near node 1 m past where the crossing would be: the junction moves so it crosses at the node.
	local j = junction.fit(600, R, 1, NONE, { near = { 145 + C + 1 }, far = {} })
	t.near(cutsOf(j)["near crossing"], 145 + C + 1, 1e-6, "crosses at the node")
	-- At the node exactly: kept as it is.
	j = junction.fit(600, R, 1, NONE, { near = { 145 + C }, far = {} })
	t.near(cutsOf(j)["near crossing"], 145 + C, 1e-9, "the node reused")
	t.near(cutsOf(j)["near switch"], 15, 1e-9, "nothing moved")
	-- Nodes every 2 m along the near track: nowhere to put either cut, so no junction.
	local many = {}
	for x = 0, 600, 2 do
		table.insert(many, x + 0.7)
	end
	t.ok(junction.fit(600, R, 1, NONE, { near = many, far = {} }) == nil, "no junction where nodes crowd the track")
end)

t.test("junction: a placement `accept` turns down is passed over for the next one out", function()
	-- Taken only from 100 m on: the first try at or past it (every 5 m from 15 m).
	local seen = 0
	local j = junction.fit(600, R, 1, NONE, nil, function(layout)
		seen = seen + 1
		return cutsOf(layout)["near switch"] >= 100
	end)
	t.near(cutsOf(j)["near switch"], 100, 1e-9, "the first placement taken")
	t.eq(seen, 18, "every placement from 15 m to 100 m asked")
	t.ok(junction.fit(600, R, 1, NONE, nil, function() return false end) == nil, "none taken: no junction")
end)
