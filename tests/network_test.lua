local t = ...
local network = t.requireTl("gui/pgrace_rail_router/planner/network.tl")

-- A leg along x from (0, 0): pieces as given, flat at height z unless heights are given as {s, z} pairs, spans as
-- {kind, s0, s1}. Samples every 25 m, as route.tl makes them.
local function leg(pieces, spans, heights)
	local total = 0
	for __, p in ipairs(pieces) do
		total = total + p.length
	end
	local samples, z = {}, {}
	local s = 0
	while true do
		table.insert(samples, { p = { x = s, y = 0 }, s = s })
		local h = 10
		if heights then
			for k = 1, #heights - 1 do
				local a, b = heights[k], heights[k + 1]
				if s >= a[1] and s <= b[1] then
					h = a[2] + (b[2] - a[2]) * (s - a[1]) / (b[1] - a[1])
				end
			end
		end
		table.insert(z, h)
		if s >= total then
			break
		end
		s = math.min(total, s + 25)
	end
	local list = {}
	for i, sp in ipairs(spans or { { "ground", 0, total } }) do
		list[i] = { kind = sp[1], s0 = sp[2], s1 = sp[3] }
	end
	return { pieces = pieces, samples = samples, z = z, spans = list, length = total }
end

local function straight(ax, ay, bx, by)
	local l = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
	return { kind = "straight", a = { x = ax, y = ay }, b = { x = bx, y = by }, length = l }
end

-- A left-turning arc of radius r from (ax, ay) heading +x, turning by `turn` radians.
local function arc(ax, ay, r, turn)
	local c = { x = ax, y = ay + r }
	local b = { x = c.x + r * math.sin(turn), y = c.y - r * math.cos(turn) }
	return { kind = "arc", a = { x = ax, y = ay }, b = b, length = r * turn, radius = r, centre = c, turn = turn }
end

local function hermite(e, u)
	local u2, u3 = u * u, u * u * u
	local h00, h10, h01, h11 = 2 * u3 - 3 * u2 + 1, u3 - 2 * u2 + u, -2 * u3 + 3 * u2, u3 - u2
	return {
		x = h00 * e.p0.x + h10 * e.t0.x + h01 * e.p1.x + h11 * e.t1.x,
		y = h00 * e.p0.y + h10 * e.t0.y + h01 * e.p1.y + h11 * e.t1.y,
		z = h00 * e.p0.z + h10 * e.t0.z + h01 * e.p1.z + h11 * e.t1.z,
	}
end

-- A right-turning arc of radius r from (ax, ay) heading +x, turning by `turn` radians.
local function rightArc(ax, ay, r, turn)
	local c = { x = ax, y = ay - r }
	local b = { x = c.x + r * math.sin(turn), y = c.y + r * math.cos(turn) }
	return { kind = "arc", a = { x = ax, y = ay }, b = b, length = r * turn, radius = r, centre = c, turn = -turn }
end

-- The edge's grade at parameter u: its height's rate of change over its rate in plan.
local function grade(e, u)
	local dh00, dh10, dh01, dh11 = 6 * u * u - 6 * u, 3 * u * u - 4 * u + 1, -6 * u * u + 6 * u, 3 * u * u - 2 * u
	local function d(c)
		return dh00 * e.p0[c] + dh10 * e.t0[c] + dh01 * e.p1[c] + dh11 * e.t1[c]
	end
	return d("z") / math.sqrt(d("x") ^ 2 + d("y") ^ 2)
end

-- Every edge's Hermite points (at u = 0, 0.05 .. 1) lie `radius` from `centre`, within `within` metres.
local function onCircle(edges, centre, radius, within)
	for __, e in ipairs(edges) do
		for k = 0, 20 do
			local p = hermite(e, k / 20)
			local r = math.sqrt((p.x - centre.x) ^ 2 + (p.y - centre.y) ^ 2)
			t.near(r, radius, within, ("on the circle at s %.1f-%.1f, u %.2f"):format(e.s0, e.s1, k / 20))
		end
	end
end

t.test("network: a straight is cut into edges no longer than maxEdge, offset to the left", function()
	local o = network.defaults()
	local edges = network.trackEdges(leg({ straight(0, 0, 600, 0) }), 1, 1, o)
	t.eq(#edges, 3, "600 m in edges of at most 250 m")
	for __, e in ipairs(edges) do
		t.near(e.p0.y, 2.5, 1e-9, "left track 2.5 m to the left")
		t.near(e.t0.x, e.p1.x - e.p0.x, 1e-9, "a straight's tangent is its chord")
		t.near(e.p0.z, 10, 1e-9, "flat")
	end
	t.near(edges[1].p0.x, 0, 1e-9, "starts at the leg's start")
	t.near(edges[3].p1.x, 600, 1e-9, "ends at its end")
	t.near(edges[1].p1.x, edges[2].p0.x, 1e-9, "edges join")
end)

t.test("network: an arc's edges stay on the offset circle", function()
	local o = network.defaults()
	local a = arc(0, 0, 500, math.pi / 2)
	local edges = network.trackEdges(leg({ a }), 1, -1, o)
	t.ok(#edges >= 4, "a 785 m arc in edges of at most 250 m")
	-- The right track (side -1) of a left turn runs on the outside: radius 502.5 about the same centre.
	for __, e in ipairs(edges) do
		for k = 0, 10 do
			local p = hermite(e, k / 10)
			local r = math.sqrt((p.x - a.centre.x) ^ 2 + (p.y - a.centre.y) ^ 2)
			t.near(r, 502.5, 0.05, "on the circle")
		end
	end
end)

t.test("network: edges split where a bridge starts and ends, and carry its kind", function()
	local o = network.defaults()
	local edges = network.trackEdges(leg({ straight(0, 0, 400, 0) },
		{ { "ground", 0, 120 }, { "bridge", 120, 230 }, { "ground", 230, 400 } }), 1, 1, o)
	local kinds = {}
	for __, e in ipairs(edges) do
		table.insert(kinds, ("%s %.0f-%.0f"):format(e.kind, e.s0, e.s1))
	end
	t.eq(table.concat(kinds, ", "), "ground 0-120, bridge 120-230, ground 230-400", "edges")
end)

t.test("network: heights and grades follow the profile, the same either side of a node", function()
	local o = network.defaults()
	local edges = network.trackEdges(leg({ straight(0, 0, 500, 0) }, nil, { { 0, 10 }, { 500, 30 } }), 1, 1, o)
	for __, e in ipairs(edges) do
		t.near(e.p1.z - e.p0.z, 20 * (e.s1 - e.s0) / 500, 1e-6, "height change")
		t.near(e.t0.z / math.sqrt(e.t0.x ^ 2 + e.t0.y ^ 2), 0.04, 1e-6, "4% grade at the start")
		t.near(e.t1.z / math.sqrt(e.t1.x ^ 2 + e.t1.y ^ 2), 0.04, 1e-6, "and at the end")
	end
end)

t.test("network: a piece under half a metre long is no edge of its own", function()
	local o = network.defaults()
	-- The smoother leaves pieces like these between longer ones: a 0.46 m straight, and a 0.46 m arc.
	local tiny = arc(300.46, 0, 500, 0.46 / 500)
	local heading = { x = math.cos(tiny.turn), y = math.sin(tiny.turn) }
	local pieces = { straight(0, 0, 300, 0), straight(300, 0, 300.46, 0), tiny,
		straight(tiny.b.x, tiny.b.y, tiny.b.x + 200 * heading.x, tiny.b.y + 200 * heading.y),
		straight(tiny.b.x + 200 * heading.x, tiny.b.y + 200 * heading.y,
			tiny.b.x + 200.3 * heading.x, tiny.b.y + 200.3 * heading.y) }
	local l = leg(pieces)
	local edges = network.trackEdges(l, 1, 1, o)
	for k, e in ipairs(edges) do
		t.ok(e.s1 - e.s0 >= 0.5, ("edge %d: %.2f m"):format(k, e.s1 - e.s0))
		if k > 1 then
			t.near(e.p0.x, edges[k - 1].p1.x, 1e-9, "edges join")
			t.near(e.p0.y, edges[k - 1].p1.y, 1e-9, "edges join")
		end
	end
	t.near(edges[1].s0, 0, 1e-9, "from the leg's start")
	t.near(edges[#edges].s1, l.length, 1e-9, "to its end")
	local last = edges[#edges]
	t.near(last.p1.x, tiny.b.x + 200.3 * heading.x - 2.5 * heading.y, 1e-6, "at the last piece's end, offset")
	t.near(last.p1.y, tiny.b.y + 200.3 * heading.y + 2.5 * heading.x, 1e-6, "at the last piece's end, offset")
end)

t.test("network: the left track of a right turn runs on the outside", function()
	local a = rightArc(0, 0, 400, math.pi / 3)
	local edges = network.trackEdges(leg({ a }), 1, 1, network.defaults())
	t.ok(#edges >= 2, "a 419 m arc in edges of at most 250 m")
	onCircle(edges, a.centre, 402.5, 0.05)
end)

t.test("network: an edge that runs 0.4 m of straight into an arc stays on the offset circle", function()
	local a = arc(300, 0, 200, math.pi / 2)
	-- The bridge starts 0.4 m before the arc: the arc's start is too close to be a node, so the first edge on the
	-- bridge covers the 0.4 m of straight and the arc's first part.
	local l = leg({ straight(0, 0, 300, 0), a },
		{ { "ground", 0, 299.6 }, { "bridge", 299.6, 300 + a.length } })
	local edges = network.trackEdges(l, 1, 1, network.defaults())
	local onArc = {}
	for __, e in ipairs(edges) do
		if e.s1 > 300 then
			table.insert(onArc, e)
		end
	end
	t.near(onArc[1].s0, 299.6, 1e-9, "the first edge on the bridge starts before the arc")
	-- The left track of a left turn: radius 197.5 (the straight's 0.4 m is within 0.001 m of that circle).
	onCircle(onArc, a.centre, 197.5, 0.1)
end)

t.test("network: an edge follows a grade change inside it, and keeps within the grade", function()
	local l = leg({ straight(0, 0, 250, 0) }, nil, { { 0, 10 }, { 100, 10 }, { 250, 16 } })
	local edges = network.trackEdges(l, 1, 1, network.defaults())
	t.ok(#edges > 1, "split where the grade changes")
	for k, sample in ipairs(l.samples) do
		for __, e in ipairs(edges) do
			if sample.s >= e.s0 - 1e-9 and sample.s <= e.s1 + 1e-9 then
				local z = hermite(e, (sample.s - e.s0) / (e.s1 - e.s0)).z
				t.near(z, l.z[k], 0.25, ("height at s %.0f"):format(sample.s))
			end
		end
	end
	for __, e in ipairs(edges) do
		for k = 0, 20 do
			local g = grade(e, k / 20)
			t.ok(math.abs(g) <= 0.04 + 1e-3, ("grade %.2f%% at s %.0f-%.0f, u %.2f, at most 4%%"):format(100 * g,
				e.s0, e.s1, k / 20))
		end
	end
end)

local function plan(legs)
	return { ok = true, legs = legs, stations = {}, platformLength = 160 }
end

t.test("network: both tracks, edges joined through shared nodes", function()
	local net = network.build(plan({ leg({ straight(0, 0, 600, 0) }) }), network.defaults())
	t.eq(#net.edges, 6, "three edges a track")
	t.eq(#net.nodes, 8, "four nodes a track")
	for k = 1, #net.edges - 1 do
		local a, b = net.edges[k], net.edges[k + 1]
		if a.track == b.track then
			t.eq(a.node1, b.node0, "consecutive edges share a node")
		end
	end
	for __, e in ipairs(net.edges) do
		local n0 = net.nodes[e.node0]
		t.near(n0.x, e.p0.x, 1e-9, "node at the edge's start")
		t.near(n0.y, e.p0.y, 1e-9, "node at the edge's start")
		t.ok(not rawequal(n0, e.p0), "a node is a copy, not the edge's own end point")
	end
end)

t.test("network: chunks of about chunkLength, never splitting a bridge", function()
	local o = network.defaults()
	o.chunkLength = 300
	-- A 600 m bridge in three edges: a chunk cut after 300 m would fall inside it.
	local l = leg({ straight(0, 0, 1000, 0) },
		{ { "ground", 0, 100 }, { "bridge", 100, 700 }, { "ground", 700, 1000 } })
	local net = network.build(plan({ l }), o)
	t.ok(#net.chunks >= 2, "split into chunks")
	local covered = 0
	for k, c in ipairs(net.chunks) do
		if k > 1 then
			t.eq(c.first, net.chunks[k - 1].last + 1, "chunks follow each other")
			-- The left track's last edge in the chunk before, and its first in this one (each chunk lists the left
			-- track's edges first).
			local before
			for i = net.chunks[k - 1].first, net.chunks[k - 1].last do
				if net.edges[i].track == 1 then
					before = net.edges[i]
				end
			end
			local after = net.edges[c.first]
			t.ok(before.kind == "ground" or after.kind == "ground",
				("a chunk cut at s %.0f, inside a %s"):format(after.s0, after.kind))
		end
		covered = covered + (c.last - c.first + 1)
	end
	t.eq(covered, #net.edges, "every edge in one chunk")
end)

t.test("network: every leg gets its own chunks", function()
	local net = network.build(plan({ leg({ straight(0, 0, 300, 0) }), leg({ straight(0, 0, 300, 0) }) }),
		network.defaults())
	t.eq(net.chunks[1].leg, 1, "leg 1")
	t.eq(net.chunks[#net.chunks].leg, 2, "leg 2")
end)
