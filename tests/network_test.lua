local t = ...
local network = t.requireTl("gui/pgrace_rail_router/planner/network.tl")
local midline = t.requireTl("gui/pgrace_rail_router/planner/midline.tl")

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

local function noCrossovers()
	local o = network.defaults()
	o.crossovers = false
	return o
end

t.test("network: both tracks, edges joined through shared nodes", function()
	local net = network.build(plan({ leg({ straight(0, 0, 600, 0) }) }), noCrossovers())
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

t.test("network: a Hermite split traces the curve, and halves as Bus Loops' midpoint split does", function()
	local h = { p0 = { x = 0, y = 0, z = 0 }, p1 = { x = 100, y = 40, z = 6 }, t0 = { x = 120, y = -30, z = 2 },
		t1 = { x = 60, y = 90, z = 4 } }
	for __, s in ipairs({ 0.25, 0.5, 0.8 }) do
		local a, b = network.splitHermite(h, s)
		for __, u in ipairs({ 0, 0.3, 0.7, 1 }) do
			local pa, pb = network.hermiteAt(a, u), network.hermiteAt(b, u)
			local qa, qb = network.hermiteAt(h, s * u), network.hermiteAt(h, s + (1 - s) * u)
			t.near(pa.x, qa.x, 1e-9, "a.x") t.near(pa.y, qa.y, 1e-9, "a.y") t.near(pa.z, qa.z, 1e-9, "a.z")
			t.near(pb.x, qb.x, 1e-9, "b.x") t.near(pb.y, qb.y, 1e-9, "b.y")
		end
	end
	local a = network.splitHermite(h, 0.5)
	-- Bus Loops: m = 0.5 p0 + 0.125 t0 + 0.5 p1 - 0.125 t1; the halves' tangents t0/2 and tm/2.
	t.near(a.p1.x, 0.5 * 0 + 0.125 * 120 + 0.5 * 100 - 0.125 * 60, 1e-9, "midpoint")
	t.near(a.t0.x, 60, 1e-9, "first half's start tangent is t0/2")
end)

t.test("network: the nearest parameter on a curve", function()
	local h = { p0 = { x = 0, y = 0, z = 0 }, p1 = { x = 100, y = 0, z = 0 }, t0 = { x = 100, y = 0, z = 0 },
		t1 = { x = 100, y = 0, z = 0 } }
	t.near(network.nearestParam(h, { x = 37, y = 20 }), 0.37, 1e-3, "a straight line")
	t.near(network.nearestParam(h, { x = -5, y = 0 }), 0, 1e-9, "before the start")
end)

local function line(x0, y0, x1, y1)
	return { p0 = { x = x0, y = y0, z = 0 }, p1 = { x = x1, y = y1, z = 0 },
		t0 = { x = x1 - x0, y = y1 - y0, z = 0 }, t1 = { x = x1 - x0, y = y1 - y0, z = 0 } }
end

t.test("network: a straight track square across a straight street crosses once", function()
	local c = network.crossings(line(0, 0, 100, 0), line(30, -50, 30, 50))
	t.eq(#c, 1, "one crossing")
	t.near(c[1].s, 0.3, 1e-6, "30% along the track")
	t.near(c[1].u, 0.5, 1e-6, "halfway along the street")
	t.near(c[1].p.x, 30, 1e-6, "x") t.near(c[1].p.y, 0, 1e-6, "y")
end)

t.test("network: no crossing where the track runs parallel or stops short", function()
	t.eq(#network.crossings(line(0, 0, 100, 0), line(0, 10, 100, 10)), 0, "parallel")
	t.eq(#network.crossings(line(0, 0, 20, 0), line(30, -50, 30, 50)), 0, "short of it")
end)

t.test("network: a street crossed twice gives both crossings in order along the track", function()
	-- A street bowing across the track and back: from (20, 50) down to y -50 and back up at x 80.
	local street = { p0 = { x = 20, y = 50, z = 0 }, p1 = { x = 80, y = 50, z = 0 },
		t0 = { x = 0, y = -300, z = 0 }, t1 = { x = 0, y = 300, z = 0 } }
	local c = network.crossings(line(0, 0, 100, 0), street)
	t.eq(#c, 2, "two crossings")
	t.ok(c[1].s < c[2].s, "in order along the track")
	t.ok(math.abs(c[1].p.y) < 0.5 and math.abs(c[2].p.y) < 0.5, "both on the track's line")
end)

local function oneEdgeNet()
	local n0, n1 = { x = 0, y = 0, z = 5 }, { x = 100, y = 0, z = 5 }
	return { nodes = { n0, n1 }, edges = { { node0 = 1, node1 = 2, p0 = n0, p1 = n1, t0 = { x = 100, y = 0, z = 0 },
		t1 = { x = 100, y = 0, z = 0 }, kind = "ground", track = 1, leg = 1, s0 = 0, s1 = 100 } }, chunks = {} }
end

t.test("network: a cut edge becomes pieces through the cut nodes, in order", function()
	local net = oneEdgeNet()
	local a, b = { x = 30, y = 0, z = 5, entity = 77 }, { x = 70, y = 0.5, z = 5, entity = 78 }
	local out = network.cut(net, 1, 1, { [1] = { { s = 0.7, node = b }, { s = 0.3, node = a } } })
	t.eq(#out.edges, 3, "three pieces")
	t.ok(out.nodes[out.edges[1].node0] == net.nodes[1], "starts at the original node (same table)")
	t.ok(out.nodes[out.edges[1].node1] == a and out.nodes[out.edges[2].node0] == a, "first cut joins pieces 1 and 2")
	t.ok(out.nodes[out.edges[2].node1] == b and out.nodes[out.edges[3].node0] == b, "second cut joins pieces 2 and 3")
	t.ok(out.nodes[out.edges[3].node1] == net.nodes[2], "ends at the original node")
	t.near(out.edges[1].t0.x, 30, 1e-9, "tangents scaled to the piece")
	t.near(out.edges[2].s0, 30, 1e-9, "s0") t.near(out.edges[2].s1, 70, 1e-9, "s1")
	t.eq(#out.chunks, 1, "one chunk") t.eq(out.chunks[1].last, 3, "spanning all")
end)

t.test("network: edges without cuts pass through untouched", function()
	local net = oneEdgeNet()
	local out = network.cut(net, 1, 1, {})
	t.eq(#out.edges, 1, "one edge")
	t.ok(out.nodes[1] == net.nodes[1] and out.nodes[2] == net.nodes[2], "same node tables")
end)

t.test("network: a pair of crossovers at each end of a leg, joined to both tracks' nodes", function()
	local net = network.build(plan({ leg({ straight(0, 0, 1000, 0) }) }), network.defaults())
	local uses = {}
	local pieces = {}
	for __, e in ipairs(net.edges) do
		uses[e.node0] = (uses[e.node0] or 0) + 1
		uses[e.node1] = (uses[e.node1] or 0) + 1
		if e.track == 0 then
			table.insert(pieces, e)
		end
	end
	-- The switches: crossover ends on a track (three edges there); between them, joints of two crossover pieces.
	local switches, starts = 0, {}
	for __, e in ipairs(pieces) do
		for __, n in ipairs({ e.node0, e.node1 }) do
			if uses[n] == 3 then
				switches = switches + 1
			else
				t.eq(uses[n], 2, "a joint inside a crossover")
			end
		end
		if uses[e.node0] == 3 then
			table.insert(starts, e)
		end
		t.ok(math.abs(e.t0.y) < 1e-9 or uses[e.node0] == 2, "leaves a track along it")
	end
	t.eq(switches, 8, "two switches a crossover, four crossovers")
	-- Each crossover from one track to the other, CROSSOVER_LENGTH along.
	local crossovers = {}
	for __, e in ipairs(starts) do
		local s0, y0 = e.s0, net.nodes[e.node0].y
		local cur = e
		while uses[cur.node1] ~= 3 do
			for __, f in ipairs(pieces) do
				if f.node0 == cur.node1 then
					cur = f
					break
				end
			end
		end
		table.insert(crossovers, s0)
		t.near(math.abs(net.nodes[cur.node1].y - y0), 5, 1e-9, "from one track to the other")
		t.near(cur.s1 - s0, network.CROSSOVER_LENGTH, 1, "its length along the track (its ends moved onto samples within 1 m)")
	end
	t.ok(network.CROSSOVER_LENGTH ^ 2 / 30 >= 55, "its tightest radius over the game's 55 m minimum")
	table.sort(crossovers)
	t.eq(#crossovers, 4, "two at each end")
	t.near(crossovers[1], 4, 1e-9, "the first 4 m from the platforms") t.near(crossovers[4], 1000 - 49, 1, "the last mirrored")
	-- Every edge, crossovers included, in exactly one chunk.
	local inChunks = 0
	for __, c in ipairs(net.chunks) do
		inChunks = inChunks + (c.last - c.first + 1)
	end
	t.eq(inChunks, #net.edges, "every edge in a chunk")
end)

t.test("network: no crossovers where a leg's end isn't 100 m of straight ground", function()
	local l = leg({ straight(0, 0, 1000, 0) }, { { "bridge", 0, 150 }, { "ground", 150, 1000 } })
	local net = network.build(plan({ l }), network.defaults())
	local starts = 0
	for __, e in ipairs(net.edges) do
		if e.track == 0 then
			t.ok(e.s0 > 900, "none at the bridge end")
			starts = starts + 1
			t.near(math.abs(net.nodes[e.node0].y - net.nodes[e.node1].y), 5, 1e-9, "one edge from track to track")
		end
	end
	t.eq(starts, 2, "a pair at the end on the ground")
end)

t.test("network: beside a switch's branch, the main track runs on in one edge of 18 m or more", function()
	-- Samples every 25 m would otherwise cut the track a few metres from the switches.
	for __, length in ipairs({ 1000, 1013.7 }) do
		local net = network.build(plan({ leg({ straight(0, 0, length, 0) }) }), network.defaults())
		for __, x in ipairs(net.edges) do
			if x.track == 0 then
				for __, end_ in ipairs({ { x.node0, 1 }, { x.node1, -1 } }) do
					-- The branch leaves node0 forward (along s) and reaches node1 from behind.
					local n, dir = end_[1], end_[2]
					local found = false
					for __, e in ipairs(net.edges) do
						if e.track ~= 0 and ((dir > 0 and e.node0 == n) or (dir < 0 and e.node1 == n)) then
							found = true
							t.ok(e.s1 - e.s0 >= 18, ("leg %.0f m: %.1f m of main track beside the switch at s %.1f"):format(length,
								e.s1 - e.s0, dir > 0 and e.s0 or e.s1))
						end
					end
					t.ok(found, "a main track edge on the branch side")
				end
			end
		end
	end
end)

local function halt()
	local o = network.defaults()
	o.fan = network.turnoutLength(300)
	o.blockSpacing = 2000
	return o
end

-- A linked leg (route.tl: existing track already runs between its stations), as the planner makes it.
local function linkedLeg(length)
	return { pieces = {}, samples = {}, z = {}, spans = {}, length = length, minRadius = math.huge, maxGrade = 0,
		tightCurves = 0, linked = true }
end

t.test("network: a linked leg has no edges or chunks; the legs either side keep their own", function()
	for __, o in ipairs({ network.defaults(), halt() }) do
		local only = network.build(plan({ linkedLeg(3000) }), o)
		t.eq(#only.edges, 0, "no edges")
		t.eq(#only.chunks, 0, "no chunks")
		local net = network.build(plan({ leg({ straight(0, 0, 300, 0) }), linkedLeg(3000), leg({ straight(0, 0, 300, 0) }) }), o)
		t.ok(#net.chunks >= 2, "chunks")
		for __, c in ipairs(net.chunks) do
			t.ok(c.leg ~= 2, "no chunk on the linked leg")
		end
		t.eq(net.chunks[#net.chunks].leg, 3, "the last leg's chunks")
	end
end)

t.test("network: a Halt 2+2 fan's turnout length follows the radius, as the Express & Local mod's", function()
	t.eq(network.turnoutLength(150), 55, "simple")
	t.eq(network.turnoutLength(300), 75, "standard")
	t.eq(network.turnoutLength(600), 110, "high-speed")
	t.eq(network.fanLength(75), 125, "20 m apron, the turnout, 30 m on")
end)

t.test("network: Halt 2+2 fans run each local track into the line's track on its side", function()
	local net = network.build(plan({ leg({ straight(0, 0, 3000, 0) }) }), halt())
	local uses = {}
	for __, e in ipairs(net.edges) do
		uses[e.node0] = (uses[e.node0] or 0) + 1
		uses[e.node1] = (uses[e.node1] or 0) + 1
	end
	local fans = {}
	for __, e in ipairs(net.edges) do
		if e.track == 3 then
			table.insert(fans, e)
		end
	end
	t.eq(#fans, 4, "two at each end")
	for __, e in ipairs(fans) do
		local atStart = e.s0 == 0
		local tip = atStart and net.nodes[e.node0] or net.nodes[e.node1]
		local merge = atStart and net.nodes[e.node1] or net.nodes[e.node0]
		t.near(math.abs(tip.y), 7.5, 1e-9, "the local track's end 7.5 m off the axis")
		t.near(math.abs(merge.y), 2.5, 1e-9, "merging into the line's track")
		t.ok(tip.y * merge.y > 0, "on its own side")
		t.near(math.abs(tip.x - merge.x), 95, 1e-9, "20 m apron and 75 m turnout")
		t.near(atStart and tip.x or 3000 - tip.x, 0, 1e-9, "at the platforms")
		t.eq(uses[atStart and e.node1 or e.node0], 3, "a switch at the merge")
		t.eq(uses[atStart and e.node0 or e.node1], 1, "the station's track end, joined when built")
	end
	-- The line's track from the platforms to the merge is one edge (the main edge beside the branch).
	for __, e in ipairs(net.edges) do
		if e.track == 1 or e.track == 2 then
			t.ok(not (e.s0 < 95 - 1e-6 and e.s1 > 1e-6 and (e.s0 > 1e-6 or e.s1 < 95 - 1e-6)) or e.s0 >= 95 - 1e-6,
				"no node between the platforms and the merge")
		end
	end
	local crossovers = 0
	for __, e in ipairs(net.edges) do
		crossovers = crossovers + (e.track == 0 and 1 or 0)
	end
	t.eq(crossovers, 4, "a pair at each end")
end)

-- A leg with an extra sample at each s in `extra` (route.tl samples curves more finely than every 25 m).
local function withSamples(l, extra)
	for __, s in ipairs(extra) do
		local k = 1
		while k <= #l.samples and l.samples[k].s < s do
			k = k + 1
		end
		table.insert(l.samples, k, { p = { x = s, y = 0 }, s = s })
		table.insert(l.z, k, l.z[k] or l.z[#l.z])
	end
	return l
end

-- In-game (Bangor to Aloha via Antelope): a sample 0.24 m before the end's merge was kept as a cut and the merge
-- dropped, so the fan found no node there and was left out, and the station's outer tracks dead-ended.
t.test("network: a Halt 2+2 fan's merge stays a node with a sample just beside it, at either end", function()
	local merge = 20 + 75
	for __, at in ipairs({ 3000 - merge - 0.24, 3000 - merge + 0.24, merge - 0.24, merge + 0.24 }) do
		local label = ("a sample at %.2f"):format(at)
		local net = network.build(plan({ withSamples(leg({ straight(0, 0, 3000, 0) }), { at }) }), halt())
		local uses = {}
		for __, e in ipairs(net.edges) do
			uses[e.node0] = (uses[e.node0] or 0) + 1
			uses[e.node1] = (uses[e.node1] or 0) + 1
		end
		local fans = {}
		for __, e in ipairs(net.edges) do
			if e.track == 3 then
				table.insert(fans, e)
			end
		end
		t.eq(#fans, 4, label .. ": two fans at each end")
		for __, e in ipairs(fans) do
			t.eq(uses[e.s0 == 0 and e.node1 or e.node0], 3, label .. ": a switch at the merge")
		end
		for n = 1, #net.nodes do
			t.ok(uses[n] ~= nil, label .. ": every node on an edge")
		end
		for k, c in ipairs(net.chunks) do
			t.ok(c.problem == nil, ("%s: chunk %d: %s"):format(label, k, tostring(c.problem)))
		end
	end
end)

t.test("network: Halt 2+2 crossovers at every station end, after the fans, so a train can turn back anywhere", function()
	local net = network.build(plan({ leg({ straight(0, 0, 3000, 0) }), leg({ straight(0, 0, 3000, 0) }) }), halt())
	local byLeg = { {}, {} }
	for __, e in ipairs(net.edges) do
		if e.track == 0 then
			table.insert(byLeg[e.leg], e.s0)
		end
	end
	for li = 1, 2 do
		t.eq(#byLeg[li], 4, "leg " .. li .. ": a pair at each end")
		for __, s in ipairs(byLeg[li]) do
			t.ok(s >= 125 and s <= 3000 - 125 - 45, "after the fans")
		end
	end
end)

t.test("network: Halt 2+2 signals face their tracks' trains: right-hand running", function()
	local net = network.build(plan({ leg({ straight(0, 0, 6000, 0) }) }), halt())
	local forward, backward = 0, 0
	for __, e in ipairs(net.edges) do
		for __, sg in ipairs(e.signals or {}) do
			t.ok(sg.param > 0 and sg.param < 1, "on the edge")
			if e.track == 1 then
				t.ok(not sg.forward, "track 1 (the left) runs against the leg")
			elseif e.track == 2 then
				t.ok(sg.forward, "track 2 runs with it")
			end
			if sg.forward then forward = forward + 1 else backward = backward + 1 end
		end
	end
	-- Each way: 2 starters (local and express) leaving one end, a home signal arriving at the other, and blocks.
	t.ok(forward == backward, "as many each way")
	t.ok(forward >= 3 + 2, "starters, home and block signals (6 km, 2 km apart)")
end)

t.test("network: every track edge is in exactly one chunk, each track's in order, also when the tracks are cut differently", function()
	for __, o in ipairs({ network.defaults(), halt() }) do
		o.fan = o.fan and network.turnoutLength(600) or nil
		local net = network.build(plan({ leg({ straight(0, 0, 2060, 0) }), leg({ straight(0, 0, 2756, 0) }) }), o)
		local seen = {}
		for __, c in ipairs(net.chunks) do
			for i = c.first, c.last do
				t.ok(not seen[i], "edge " .. i .. " in one chunk")
				seen[i] = true
			end
		end
		-- Each leg's tracks reach from 0 to its end with no gap, in the order they're built.
		for li, total in ipairs({ 2060, 2756 }) do
			for k = 1, 2 do
				local at = 0
				for __, e in ipairs(net.edges) do
					if e.leg == li and e.track == k then
						t.near(e.s0, at, 1e-6, ("leg %d track %d continues at %.0f"):format(li, k, at))
						at = e.s1
					end
				end
				t.near(at, total, 1e-6, ("leg %d track %d reaches the end"):format(li, k))
			end
		end
	end
end)

t.test("network: Halt 2+2 signals stay 15 m from their edges' ends", function()
	local o = halt()
	o.fan = network.turnoutLength(600)
	o.blockSpacing = 500
	local net = network.build(plan({ leg({ straight(0, 0, 2060, 0) }), leg({ straight(0, 0, 2756, 0) }) }), o)
	local count = 0
	for __, e in ipairs(net.edges) do
		local length = e.s1 - e.s0
		for __, sg in ipairs(e.signals or {}) do
			count = count + 1
			t.ok(sg.param * length >= 15 - 1e-6 and (1 - sg.param) * length >= 15 - 1e-6,
				("signal on track %d at %.1f of %.1f m"):format(e.track, sg.param * length, length))
		end
	end
	t.ok(count > 10, "block signals too")
end)

-- Junctions into an existing station's track (milestone 4b).
local junction = t.requireTl("gui/pgrace_rail_router/planner/junction.tl")

-- An existing straight piece from frame x0 to x1 on frame y, as the survey reads it (its node0 at x0).
local function exPiece(e, entity, x0, x1, y)
	local function at(x)
		return { x = e.origin.x + e.dir.x * x - e.dir.y * y, y = e.origin.y + e.dir.y * x + e.dir.x * y,
			z = e.z + e.grade * x }
	end
	local d = x1 - x0
	local tg = { x = e.dir.x * d, y = e.dir.y * d, z = e.grade * d }
	return { entity = entity, node0 = entity * 10, node1 = entity * 10 + 1, p0 = at(x0), p1 = at(x1), t0 = tg, t1 = tg,
		kind = "ground", signals = {} }
end

-- An existing end at `origin` facing `dir`, 700 m of stretch, its z and grade; one piece per track (101 near, 102
-- far) unless `near` gives the near track's pieces as {entity, x0, x1}.
local function exEnd(origin, dir, side, z, grade, near)
	local e = { origin = origin, dir = dir, z = z, grade = grade, length = 700, pieces = { near = {}, far = {} },
		signals = { near = {}, far = {} } }
	e.frame = midline.line(origin, dir, z, grade, 700)
	for __, p in ipairs(near or { { 101, 0, 700 } }) do
		table.insert(e.pieces.near, exPiece(e, p[1], p[2], p[3], 2.5 * side))
	end
	table.insert(e.pieces.far, exPiece(e, 102, 0, 700, -2.5 * side))
	return e
end

-- An existing station using end `k` (+1) for the leg leaving it (forward true) or arriving (false).
local function exStation(e, side, forward)
	local j = junction.fit(e.length - 100, 300, side, e.signals)
	return { existing = { entity = 1 }, ends = { [1] = e }, junctions = { [1] = j }, sides = { [1] = side },
		endOf = { [forward] = 1 } }, j
end

-- The frame point (x, y) of an end, in the world, and its height.
local function frame(e, x, y)
	return e.origin.x + e.dir.x * x - e.dir.y * y, e.origin.y + e.dir.y * x + e.dir.x * y, e.z + e.grade * x
end

-- The leg from (or to) the junction's approach start, 10 m off the axis on our side, straight along the axis for
-- `length` metres (outward from the start, or inward to the end), heights on the stretch's grade at the junction.
local function junctionLeg(e, j, side, length, atStart)
	local ax, ay, az = frame(e, j.approachX, 10 * side)
	local bx, by = ax + e.dir.x * length, ay + e.dir.y * length
	if atStart then
		return leg({ straight(ax, ay, bx, by) }, nil, { { 0, az }, { length, az } })
	end
	return leg({ straight(bx, by, ax, ay) }, nil, { { 0, az }, { length, az } })
end

local function byTrack(net, track)
	local list = {}
	for __, e in ipairs(net.edges) do
		if e.track == track then
			table.insert(list, e)
		end
	end
	return list
end

-- The junction edges' shared checks: 3 whole pieces and 3 straights (two of them a parallel pair, 5 m apart, from the
-- cross-out's outer end), 3 existing nodes, the crossing node shared and tangent, each edge's ends on its nodes (x, y,
-- z), the straights ending at the leg's track ends, the merge's straights on the leg track that runs the way the
-- existing near track does (inward on side +1, outward on side −1), and all in one chunk with the splits.
local function checkJunction(net, e, j, side, chunk, atStart)
	local edges = byTrack(net, 4)
	t.eq(#edges, 6, "3 junction pieces and 3 straights to the approach start")
	local function fx(p)
		return (p.x - e.origin.x) * e.dir.x + (p.y - e.origin.y) * e.dir.y
	end
	local function fy(p)
		return -(p.x - e.origin.x) * e.dir.y + (p.y - e.origin.y) * e.dir.x
	end
	local uses, existing, whole, paired = {}, {}, {}, {}
	for __, x in ipairs(edges) do
		for __, n in ipairs({ x.node0, x.node1 }) do
			uses[n] = (uses[n] or 0) + 1
		end
		for __, pair in ipairs({ { x.p0, net.nodes[x.node0] }, { x.p1, net.nodes[x.node1] } }) do
			for __, c in ipairs({ "x", "y", "z" }) do
				t.near(pair[1][c], pair[2][c], 1e-9, "the edge's end on its node (" .. c .. ")")
			end
		end
		t.ok(not (x.whole and x.paired), "a piece or a straight")
		table.insert(x.whole and whole or (x.paired and paired or {}), x)
	end
	t.eq(#whole, 3, "the three junction pieces kept whole")
	t.eq(#paired, 2, "two straights paired")
	local c1 = j.approachX - 30
	for __, x in ipairs(paired) do
		local a, b = fx(x.p0), fx(x.p1)
		t.near(math.min(a, b), c1, 1e-6, "paired from the cross-out's outer end")
		t.near(math.max(a, b), j.approachX, 1e-6, "to the approach start")
	end
	t.near(math.abs(fy(paired[1].p0) - fy(paired[2].p0)), 5, 1e-6, "5 m apart")
	for n in pairs(uses) do
		if net.nodes[n].existing then
			table.insert(existing, n)
		end
	end
	t.eq(#existing, 3, "3 cuts in existing track")
	local crossing
	for __, n in ipairs(existing) do
		if uses[n] == 2 then
			crossing = n
		end
	end
	t.ok(crossing ~= nil, "the crossing node is shared by two junction pieces")
	local at = {}
	for __, x in ipairs(edges) do
		if x.node0 == crossing then
			at.out = x.t0
		elseif x.node1 == crossing then
			at.into = x.t1
		end
	end
	t.ok(at.out and at.into, "one piece into the crossing node, one out")
	local cross = at.out.x * at.into.y - at.out.y * at.into.x
	t.near(cross / math.sqrt((at.out.x ^ 2 + at.out.y ^ 2) * (at.into.x ^ 2 + at.into.y ^ 2)), 0, 1e-9,
		"tangent at the crossing")
	t.ok(at.out.x * at.into.x + at.out.y * at.into.y > 0, "running on through it")
	-- Every junction node not on existing track (and not a leg's end) joins two edges.
	local trackOf = {}
	for __, x in ipairs(net.edges) do
		if x.track == 1 or x.track == 2 then
			trackOf[x.node0], trackOf[x.node1] = x.track, x.track
		end
	end
	local legEnds = 0
	for n, count in pairs(uses) do
		if trackOf[n] then
			legEnds = legEnds + 1
			t.near(fx(net.nodes[n]), j.approachX, 1e-6, "a straight ends at the approach start")
		elseif not net.nodes[n].existing then
			t.eq(count, 2, "an outer piece end or the pair's start, joined on by a straight")
		end
	end
	t.eq(legEnds, 2, "both of the leg's tracks joined")
	-- The merge: the whole piece from a switch (an existing node it alone uses). Its straights lead to a leg track
	-- running as the existing near track does: track 2 runs with the leg (outward from a start), track 1 against it.
	local merge
	for __, x in ipairs(whole) do
		local a, b = net.nodes[x.node0].existing, net.nodes[x.node1].existing
		local switch = a and x.node0 or (b and x.node1)
		if (a == nil) ~= (b == nil) and uses[switch] == 1 then
			merge = x
		end
	end
	t.ok(merge ~= nil, "the merge found")
	local n = net.nodes[merge.node0].existing and merge.node1 or merge.node0
	local seen = { [merge] = true }
	while not trackOf[n] do
		local nextN
		for __, x in ipairs(edges) do
			if not seen[x] and (x.node0 == n or x.node1 == n) then
				seen[x], nextN = true, x.node0 == n and x.node1 or x.node0
			end
		end
		n = nextN
	end
	t.near(math.abs(fy(net.nodes[n])), 12.5, 1e-6, "the merge leads to our far track")
	local outward = (trackOf[n] == 2) == atStart
	t.eq(outward, side < 0, "our far track runs as the existing near track: outward on side −1, inward on +1")
	-- All in one chunk, which lists the splits.
	local c = net.chunks[chunk]
	for i, x in ipairs(net.edges) do
		if x.track == 4 then
			t.ok(i >= c.first and i <= c.last, "junction edge in the leg's chunk at that end")
		end
	end
	return edges, existing, c
end

-- A one-leg network with a junction at its start (atStart) or end, the end at `origin` facing `dir`, our line on
-- `side`; `near` as exEnd's.
local function junctionNet(origin, dir, side, atStart, near, options)
	local e = exEnd(origin, dir, side, 10, 0, near)
	local st, j = exStation(e, side, atStart)
	local l = junctionLeg(e, j, side, 2500, atStart)
	local stations = atStart and { st, {} } or { {}, st }
	local net = network.build({ ok = true, legs = { l }, stations = stations, platformLength = 160 },
		options or network.defaults())
	return net, e, j
end

t.test("network: junctions at either end, either side, either way round: the merge on the track running as the existing near one", function()
	for __, atStart in ipairs({ true, false }) do
		for __, side in ipairs({ 1, -1 }) do
			for __, dir in ipairs({ { x = 1, y = 0 }, { x = 0, y = -1 } }) do
				local net, e, j = junctionNet({ x = 3000, y = 3000 }, dir, side, atStart)
				checkJunction(net, e, j, side, atStart and 1 or #net.chunks, atStart)
			end
		end
	end
end)

t.test("network: a junction's edges and cuts follow the end's frame, not its origin and direction", function()
	-- The frame starts 100 m further out than the end's origin says (its pieces run from frame x −100 to 600): every
	-- edge and cut must be where the frame puts them, so nothing reads origin/dir for geometry (milestone 4c).
	for __, atStart in ipairs({ true, false }) do
		local origin, dir = { x = 2000, y = 1000 }, { x = 0.6, y = 0.8 }
		local e = exEnd(origin, dir, 1, 10, 0)
		local shifted = { x = origin.x + dir.x * 100, y = origin.y + dir.y * 100 }
		e.frame = midline.line(shifted, dir, 10, 0, 700)
		local st, j = exStation(e, 1, atStart)
		-- The checks' frame (exEnd's helpers read origin and dir): the shifted one.
		local seen = { origin = shifted, dir = dir, z = 10, grade = 0 }
		local l = junctionLeg(seen, j, 1, 2500, atStart)
		local net = network.build({ ok = true, legs = { l }, stations = atStart and { st, {} } or { {}, st },
			platformLength = 160 }, network.defaults())
		local __, existingNodes, c = checkJunction(net, seen, j, 1, atStart and 1 or #net.chunks, atStart)
		t.ok(c.problem == nil, "no problem: " .. tostring(c.problem))
		local byPiece = {}
		for __, sp in ipairs(c.splits) do
			byPiece[sp.piece] = sp.s
		end
		-- Frame x 15 (the merge's switch) is 115 m along the near piece, 700 m long.
		t.near(byPiece[101][1], 115 / 700, 1e-9, "the merge's switch at frame x 15")
		t.near(byPiece[102][1], 245 / 700, 1e-9, "the far switch at frame x 145")
		for __, n in ipairs(existingNodes) do
			local p, y = net.nodes[n], net.nodes[n].existing.piece == 101 and 2.5 or -2.5
			t.near(p.x, origin.x + dir.x * 700 * p.existing.s - dir.y * y, 1e-9, "on its piece (x)")
			t.near(p.y, origin.y + dir.y * 700 * p.existing.s + dir.x * y, 1e-9, "on its piece (y)")
		end
	end
end)

t.test("network: a cut within half a metre of an existing piece's end uses its node; one on no piece is reported", function()
	-- The near track's first piece ends 0.3 m past the merge's switch (x 15).
	local net = junctionNet({ x = 0, y = 0 }, { x = 1, y = 0 }, 1, true, { { 201, 0, 15.3 }, { 202, 15.3, 700 } })
	local reused = 0
	for __, n in ipairs(net.nodes) do
		if n.entity == 2011 then
			reused = reused + 1
			t.near(n.x, 15.3, 1e-9, "at the piece's end")
			t.ok(n.existing == nil, "not split")
		end
	end
	t.eq(reused, 1, "the piece's own node")
	local byPiece = {}
	for __, sp in ipairs(net.chunks[1].splits) do
		byPiece[sp.piece] = #sp.s
	end
	t.ok(byPiece[201] == nil, "the first near piece not split")
	t.eq(byPiece[202], 1, "the second only at the crossing")
	t.eq(byPiece[102], 1, "the far piece at its switch")
	t.ok(net.chunks[1].problem == nil, "no problem")
	-- No near piece before x 100: the merge's switch (x 15) lies on none.
	local bad = junctionNet({ x = 0, y = 0 }, { x = 1, y = 0 }, 1, true, { { 201, 100, 700 } })
	t.ok(bad.chunks[1].problem ~= nil and bad.chunks[1].problem:find("switch") ~= nil,
		"reported: " .. tostring(bad.chunks[1].problem))
end)

t.test("network: cutting a chunk keeps its edges' signals on the pieces that hold them, and the chunk's splits", function()
	local net = junctionNet({ x = 0, y = 0 }, { x = 1, y = 0 }, 1, true, nil, halt())
	local c = net.chunks[1]
	-- Cut the track-2 edge with the first signal (15 m out) at its middle.
	local index, edge
	for i = c.first, c.last do
		local x = net.edges[i]
		if x.track == 2 and x.signals then
			index, edge = index or i, edge or x
		end
	end
	local sg = edge.signals[1]
	local hm = { p0 = edge.p0, p1 = edge.p1, t0 = edge.t0, t1 = edge.t1 }
	local cutAt = 0.5
	local out = network.cut(net, c.first, c.last, { [index] = { { s = cutAt, node = network.hermiteAt(hm, cutAt) } } })
	t.eq(out.chunks[1].splits, c.splits, "the chunk's splits carried over")
	local found = 0
	for __, x in ipairs(out.edges) do
		for __, g in ipairs(x.signals or {}) do
			if x.track == 2 and math.abs(x.s0 + g.param * (x.s1 - x.s0) - (edge.s0 + sg.param * (edge.s1 - edge.s0))) < 1e-6 then
				found = found + 1
				t.eq(g.forward, sg.forward, "facing as before")
			end
		end
	end
	t.eq(found, 1, "the signal kept, at the same place")
	local whole, paired = 0, 0
	for __, x in ipairs(out.edges) do
		whole = whole + (x.whole and 1 or 0)
		paired = paired + (x.paired and 1 or 0)
	end
	t.eq(whole, 3, "the junction pieces still whole")
	t.eq(paired, 2, "the pair still paired")
end)

t.test("network: a junction at the leg's start: pieces into the existing track, its cuts, no fan or crossovers", function()
	local e = exEnd({ x = 1000, y = 500 }, { x = 1, y = 0 }, 1, 10, 0)
	local st, j = exStation(e, 1, true)
	local l = junctionLeg(e, j, 1, 3000, true)
	local o = halt()
	o.blockSpacing = 500
	local net = network.build({ ok = true, legs = { l }, stations = { st, {} }, platformLength = 160 }, o)
	local edges, existing, c = checkJunction(net, e, j, 1, 1, true)
	-- The splits: the near piece at the merge's switch and the crossing, ascending; the far at its switch.
	t.eq(#c.splits, 2, "two pieces split")
	local byPiece = {}
	for __, sp in ipairs(c.splits) do
		byPiece[sp.piece] = sp.s
	end
	t.eq(#byPiece[101], 2, "the near piece: switch and crossing")
	t.near(byPiece[101][1], 15 / 700, 1e-9, "the merge's switch at x 15")
	t.near(byPiece[101][2], (145 + 54.543560573) / 700, 1e-9, "the crossing")
	t.eq(#byPiece[102], 1, "the far piece: the crossing track's switch")
	t.near(byPiece[102][1], 145 / 700, 1e-9, "at x 145")
	for i = 2, #net.chunks do
		t.ok(net.chunks[i].splits == nil, "only the first chunk splits")
	end
	-- Literal pieces: the merge, x 15 → 125 from the near track (y 2.5) to our far track (12.5).
	local merge, crossIn
	for __, x in ipairs(edges) do
		if math.abs(x.p0.x - 1015) < 1e-6 then
			merge = x
		elseif math.abs(x.p0.x - 1145) < 1e-6 then
			crossIn = x
		end
	end
	t.near(merge.p0.y, 502.5, 1e-9, "the merge leaves the near track")
	t.near(merge.p1.x, 1125, 1e-9, "110 m on")
	t.near(merge.p1.y, 512.5, 1e-9, "on our far track")
	t.near(merge.t0.x, 110, 1e-9, "along the axis")
	t.near(merge.t0.y, 0, 1e-9, "along the axis")
	t.near(merge.p0.z, 10, 1e-9, "flat")
	t.near(crossIn.p0.y, 497.5, 1e-9, "the crossing track leaves the far track")
	t.near(crossIn.p1.x, 1199.543560573, 1e-6, "to the crossing node")
	t.near(crossIn.p1.y, 502.5, 1e-9, "on the near track")
	t.near(crossIn.t0.x, 54.848615023, 1e-6, "an arc of radius 300 at 10.5°")
	t.near(crossIn.t1.x, 54.848615023 * math.cos(0.182828717), 1e-6, "turned 10.5°")
	t.near(crossIn.t1.y, 54.848615023 * math.sin(0.182828717), 1e-6, "turned 10.5°")
	t.near(j.approachX, 145 + 2 * 54.543560573 + 30, 1e-6, "approach start")
	-- The existing nodes sit on the existing pieces, marked with their cut.
	for __, n in ipairs(existing) do
		local p = net.nodes[n]
		t.ok(p.existing.piece == 101 or p.existing.piece == 102, "a cut in a stretch piece")
		t.near(p.x, 1000 + 700 * p.existing.s, 1e-9, "at its parameter")
	end
	-- No fan and no crossovers at the junction end; the other end (ours) has both.
	for __, x in ipairs(net.edges) do
		if x.track == 0 or x.track == 3 then
			t.ok(x.s0 > 1500, ("track %d at s %.0f: only at our own station's end"):format(x.track, x.s0))
		end
	end
	t.eq(#byTrack(net, 3), 2, "our station's fan")
	t.eq(#byTrack(net, 0), 2, "our station's crossovers")
	-- Signals: none on the junction; the leg's first 15 m out from the approach start, facing each track's trains:
	-- track 1 (our far track, left of outward on side +1) inward, track 2 (near) outward.
	local first = {}
	for __, x in ipairs(net.edges) do
		for __, sg in ipairs(x.signals or {}) do
			t.ok(x.track ~= 4, "no signal on a junction piece")
			local s = x.s0 + sg.param * (x.s1 - x.s0)
			t.ok(sg.param * (x.s1 - x.s0) >= 15 - 1e-6 and (1 - sg.param) * (x.s1 - x.s0) >= 15 - 1e-6,
				"15 m from its edge's ends")
			if x.track == 1 or x.track == 2 then
				first[x.track] = math.min(first[x.track] or math.huge, s)
				t.eq(sg.forward, x.track == 2, "facing its track's trains")
			end
		end
	end
	t.near(first[1], 15, 1e-6, "track 1's first signal 15 m out")
	t.near(first[2], 15, 1e-6, "track 2's first signal 15 m out")
	local far = net.nodes[byTrack(net, 1)[1].node0]
	t.near(far.y, 512.5, 1e-6, "track 1 is our far track here")
	-- Block signals continue from there.
	local blocks = 0
	for __, x in ipairs(byTrack(net, 2)) do
		for __, sg in ipairs(x.signals or {}) do
			local s = x.s0 + sg.param * (x.s1 - x.s0)
			if math.abs(s - 515) < 1e-6 then
				blocks = blocks + 1
			end
		end
	end
	t.eq(blocks, 1, "a block signal 500 m on")
end)

t.test("network: a junction at the leg's end, the station facing the other way, our line on its right", function()
	-- The station's end faces −x; our line on side −1 (right of outward: +y in the world). The near track's pieces:
	-- one laid outward, then one laid inward (node0 at its outer end).
	local e = exEnd({ x = 5000, y = 0 }, { x = -1, y = 0 }, -1, 10, 0, { { 201, 0, 150 }, { 202, 400, 150 }, { 203, 400, 700 } })
	local st, j = exStation(e, -1, false)
	local l = junctionLeg(e, j, -1, 2500, false)
	local net = network.build({ ok = true, legs = { l }, stations = { {}, st }, platformLength = 160 },
		network.defaults())
	local __, __, c = checkJunction(net, e, j, -1, #net.chunks, false)
	local byPiece = {}
	for __, sp in ipairs(c.splits) do
		byPiece[sp.piece] = sp.s
	end
	t.near(byPiece[201][1], 15 / 150, 1e-9, "the merge's switch on the first piece")
	t.near(byPiece[202][1], (199.543560573 - 400) / (150 - 400), 1e-9, "the crossing on the inward-laid piece")
	t.near(byPiece[102][1], 145 / 700, 1e-9, "the far piece")
	t.ok(byPiece[203] == nil, "the piece past the junction untouched")
	-- In the world: the near track at y = +2.5 (right of −x), the merge from x 5000 − 15 to our far track at y 12.5.
	local merge
	for __, x in ipairs(byTrack(net, 4)) do
		if math.abs(x.p1.x - 4985) < 1e-6 then
			merge = x
		end
	end
	t.ok(merge ~= nil, "the merge ends at the switch (the edge runs inward, as the leg)")
	t.near(merge.p1.y, 2.5, 1e-9, "on the near track")
	t.near(merge.p0.x, 4875, 1e-9, "from 110 m further out")
	t.near(merge.p0.y, 12.5, 1e-9, "on our far track")
	t.near(merge.t1.x, 110, 1e-9, "running inward (+x), as the leg")
	-- The leg's track 1 (left of +x travel: +y) is our far track; it runs against the leg (outward), track 2 with it.
	for __, x in ipairs(net.edges) do
		for __, sg in ipairs(x.signals or {}) do
			t.ok(x.track ~= 4, "no signal on a junction piece")
		end
	end
	local function lastSignal(track)
		local list = byTrack(net, track)
		local best
		for __, x in ipairs(list) do
			for __, sg in ipairs(x.signals or {}) do
				best = { s = x.s0 + sg.param * (x.s1 - x.s0), forward = sg.forward }
			end
		end
		return best
	end
	t.near(lastSignal(1).s, 2500 - 15, 1e-6, "track 1's signal 15 m out from the approach start")
	t.eq(lastSignal(1).forward, false, "facing its outward trains")
	t.near(lastSignal(2).s, 2500 - 15, 1e-6, "track 2's too")
	t.eq(lastSignal(2).forward, true, "facing its inward trains")
	for __, x in ipairs(byTrack(net, 0)) do
		t.ok(x.s1 < 1000, "crossovers only at our own station's end")
	end
	t.eq(#byTrack(net, 0), 2, "a pair there")
end)

t.test("network: junctions at both ends of a leg; heights on the stretch's grade", function()
	local e1 = exEnd({ x = 0, y = 0 }, { x = 1, y = 0 }, 1, 20, 0.01)
	local st1, j1 = exStation(e1, 1, true)
	local l = junctionLeg(e1, j1, 1, 2000, true)
	-- The far station's end faces back along the leg (−x), its approach start where the leg ends. The leg runs along
	-- y = 10, on the right of that end's outward (its left is −y): side −1.
	local ax = j1.approachX + 2000
	local e2 = exEnd({ x = 0, y = 0 }, { x = -1, y = 0 }, -1, 0, 0)
	local st2, j2 = exStation(e2, -1, false)
	e2.origin = { x = ax + j2.approachX, y = 0 }
	e2.z = 20 + 0.01 * j1.approachX
	e2.frame = midline.line(e2.origin, e2.dir, e2.z, 0, e2.length)
	e2.pieces = exEnd(e2.origin, e2.dir, -1, e2.z, 0).pieces
	local net = network.build({ ok = true, legs = { l }, stations = { st1, st2 }, platformLength = 160 },
		network.defaults())
	local edges = byTrack(net, 4)
	t.eq(#edges, 12, "6 at each end")
	local splitCount = 0
	for __, c in ipairs(net.chunks) do
		splitCount = splitCount + #(c.splits or {})
	end
	t.eq(splitCount, 4, "two pieces split at each end")
	-- On the graded stretch (1%), every junction node at the start is at z 20 + 0.01 x, and tangents climb at 1%.
	for __, x in ipairs(edges) do
		if x.p0.x < 1000 then
			for __, p in ipairs({ x.p0, x.p1 }) do
				t.near(p.z, 20 + 0.01 * p.x, 1e-9, "on the stretch's grade")
			end
			t.near(x.t0.z, 0.01 * x.t0.x, 1e-9, "climbing at its grade")
			t.near(x.t1.z, 0.01 * x.t1.x, 1e-9, "climbing at its grade")
		end
	end
end)

t.test("network: two chunks splitting one existing piece is refused on the later one", function()
	local net = { nodes = {}, edges = {}, chunks = {
		{ first = 1, last = 1, leg = 1, length = 0, splits = { { piece = 7, s = { 0.4 } }, { piece = 8, s = { 0.5 } } } },
		{ first = 2, last = 2, leg = 1, length = 0 },
		{ first = 3, last = 3, leg = 2, length = 0, splits = { { piece = 9, s = { 0.2 } } } },
		{ first = 4, last = 4, leg = 2, length = 0, splits = { { piece = 8, s = { 0.7 } } } } } }
	network.sharedSplits(net)
	t.eq(net.chunks[1].problem, nil, "the first keeps its split")
	t.eq(net.chunks[3].problem, nil, "another piece is fine")
	t.ok(net.chunks[4].problem ~= nil and net.chunks[4].problem:find("(8)", 1, true) ~= nil, "the later one is refused, naming the piece")
end)

-- Bare ends: an existing station's free track ends, joined as a station of ours (milestone 4b).

-- A bare end at mid (x, y, z) facing `out`, with end nodes at offsets `vs` across it (to the left looking outward,
-- largest first, as existing.bareEnd sorts them), entities base + i; each node nudged by `nudge` (a few cm) outward,
-- so snapping to exact positions shows.
local function bareEnd(kind, mx, my, mz, out, vs, nudge, base)
	local left = { x = -out.y, y = out.x }
	local nodes = {}
	for i, v in ipairs(vs) do
		nodes[i] = { x = mx + left.x * v + out.x * (nudge or 0), y = my + left.y * v + out.y * (nudge or 0), z = mz,
			entity = (base or 900) + i }
	end
	return { kind = kind, nodes = nodes, mid = { x = mx, y = my, z = mz }, out = out }
end

-- An existing station met at a bare end by the leg leaving it (forward true) or arriving (false).
local function bareSt(b, forward)
	local k = forward and 1 or -1
	return { existing = { entity = 1, half = 120 }, ends = {}, junctions = {}, sides = {}, bare = { [k] = b },
		endOf = { [forward] = k } }
end

local KINDS = { direct = { 2.5, -2.5 }, island = { 5, -5 }, fan = { 7.5, 2.5, -2.5, -7.5 } }

-- A 3000 m leg along +x at height 10 from a bare end of `kind` (out +x) to another (out −x); `pieces` replaces the
-- straight.
local function bareNet(kindStart, kindEnd, options, pieces)
	local l = leg(pieces or { straight(0, 0, 3000, 0) })
	local stations = { {}, {} }
	if kindStart then
		stations[1] = bareSt(bareEnd(kindStart, 0, 0, 10, { x = 1, y = 0 }, KINDS[kindStart], 0.03), true)
	end
	if kindEnd then
		stations[2] = bareSt(bareEnd(kindEnd, l.length, 0, 10, { x = -1, y = 0 }, KINDS[kindEnd], 0.03, 800), false)
	end
	local net = network.build({ ok = true, legs = { l }, stations = stations, platformLength = 160 },
		options or network.defaults())
	return net, stations, l.length
end

-- How many edges use each node.
local function uses(net)
	local n = {}
	for __, e in ipairs(net.edges) do
		n[e.node0] = (n[e.node0] or 0) + 1
		n[e.node1] = (n[e.node1] or 0) + 1
	end
	return n
end

-- The node of entity `entity`, and its index; nil if none (or more than one) has it.
local function nodeOf(net, entity)
	local found, index
	for i, n in ipairs(net.nodes) do
		if n.entity == entity then
			if found then
				return nil
			end
			found, index = n, i
		end
	end
	return found, index
end

-- Each end node of a bare end is the station's (entity, exact x, y, z), on one edge only, which leaves along the axis.
local function checkJoined(net, b, label)
	local count = uses(net)
	for __, sn in ipairs(b.nodes) do
		local n, i = nodeOf(net, sn.entity)
		t.ok(n ~= nil, label .. ": node " .. sn.entity .. " in the network once")
		t.near(n.x, sn.x, 1e-12, label .. ": exact x") t.near(n.y, sn.y, 1e-12, label .. ": exact y")
		t.near(n.z, sn.z, 1e-12, label .. ": exact z")
		t.eq(count[i], 1, label .. ": one edge at the station's node")
		for __, e in ipairs(net.edges) do
			if e.node0 == i or e.node1 == i then
				local p, tg = e.node0 == i and e.p0 or e.p1, e.node0 == i and e.t0 or e.t1
				t.near(p.x, sn.x, 1e-12, label .. ": the edge's end on it") t.near(p.y, sn.y, 1e-12, label .. ": y")
				local d = math.sqrt(tg.x ^ 2 + tg.y ^ 2)
				t.near(math.abs(tg.x * b.out.x + tg.y * b.out.y) / d, 1, 1e-12, label .. ": tangent along the axis")
			end
		end
	end
end

-- Our track k's edge at the leg's start (or end), and the node there.
local function trackEnd(net, k, atStart)
	local list = byTrack(net, k)
	local e = atStart and list[1] or list[#list]
	return e, net.nodes[atStart and e.node0 or e.node1]
end

t.test("network: a bare end with 2 tracks 5 m apart: our tracks end on its nodes, each on its side; no fan, crossovers", function()
	for __, o in ipairs({ network.defaults(), halt() }) do
		local label = o.fan and "halt" or "simple"
		local net, stations = bareNet("direct", "direct", o)
		checkJoined(net, stations[1].bare[1], label .. " start")
		checkJoined(net, stations[2].bare[-1], label .. " end")
		-- Track 1 is the left in the leg's direction (+x): +y at both ends. At the start that's the left looking out
		-- (nodes[1]), at the end the right looking out (−x): nodes[2].
		t.eq(select(2, trackEnd(net, 1, true)).entity, 901, label .. ": track 1 starts on the +y node")
		t.eq(select(2, trackEnd(net, 2, true)).entity, 902, label .. ": track 2 on the −y node")
		t.eq(select(2, trackEnd(net, 1, false)).entity, 802, label .. ": track 1 ends on the +y node")
		t.eq(select(2, trackEnd(net, 2, false)).entity, 801, label .. ": track 2 on the −y node")
		t.eq(#byTrack(net, 3), 0, label .. ": no fan")
		local crossovers = byTrack(net, 0)
		t.eq(#crossovers, 4, label .. ": a pair at each end")
		for __, x in ipairs(crossovers) do
			t.ok(math.min(x.s0, 3000 - x.s1) < 110, label .. ": from the station's nodes, not past a fan")
		end
		if o.fan then
			-- No edge before the crossovers is long enough for a signal 15 m from its ends, so the starter on the leaving
			-- track and the home signal on the arriving one both sit just past them (100 + 15 m out), facing their trains;
			-- none nearer the station.
			local near = {}
			for __, e in ipairs(net.edges) do
				for __, sg in ipairs(e.signals or {}) do
					local s = e.s0 + sg.param * (e.s1 - e.s0)
					t.ok(s >= 100 and s <= 3000 - 100, "no signal among the crossovers")
					if s < 130 then
						near[#near + 1] = e.track .. (sg.forward and "+" or "-")
					end
				end
			end
			table.sort(near)
			t.eq(table.concat(near, " "), "1- 2+", "a home signal on track 1 and a starter on track 2 at the start")
		end
	end
end)

-- A Halt 2+2 station of ours at one end and a bare end at the other: our station's fan stays ours. The fans' bare end
-- was picked as `atStart and bStart or bEnd`, which gives bEnd at the start when bStart is nil, so our start fan's
-- local node was the far station's: a 2 km edge to it, refused in-game as Too Much Curvature (Mercer Island →
-- Antelope).
t.test("network: our Halt 2+2 station at one end, a bare end at the other: each end's pieces stay at that end", function()
	for kind in pairs(KINDS) do
		for __, ourStart in ipairs({ true, false }) do
			local label = kind .. (ourStart and ", ours at the start" or ", ours at the end")
			local net, stations, total
			if ourStart then
				net, stations, total = bareNet(nil, kind, halt())
			else
				net, stations, total = bareNet(kind, nil, halt())
			end
			for i, e in ipairs(net.edges) do
				local chord = math.sqrt((e.p1.x - e.p0.x) ^ 2 + (e.p1.y - e.p0.y) ^ 2)
				t.ok(chord <= e.s1 - e.s0 + 15, label .. ": edge " .. i .. " (track " .. e.track .. ") spans "
					.. string.format("%.0f m for %.0f m of line", chord, e.s1 - e.s0))
				for __, n in ipairs({ net.nodes[e.node0], net.nodes[e.node1] }) do
					if n.entity ~= nil then
						t.ok((n.x < total / 2) == not ourStart, label .. ": the station's node " .. n.entity .. " at its end")
					end
				end
			end
			local b = ourStart and stations[2].bare[-1] or stations[1].bare[1]
			if kind ~= "island" then
				checkJoined(net, b, label)
			end
		end
	end
end)

t.test("network: a bare end with 4 tracks: its outer two merge into ours as Halt 2+2's fan, whatever the style", function()
	for __, o in ipairs({ network.defaults(), halt() }) do
		local label = o.fan and "halt" or "simple"
		local merge = o.fan and 20 + 75 or 20 + 55
		local net, stations = bareNet("fan", "fan", o)
		local count = uses(net)
		local fans = byTrack(net, 3)
		t.eq(#fans, 4, label .. ": two at each end")
		for __, end_ in ipairs({ { stations[1].bare[1], true }, { stations[2].bare[-1], false } }) do
			local b, atStart = end_[1], end_[2]
			checkJoined(net, b, label)
			-- The inner two are our tracks' ends; the outer two the fans' tips, each merging into our track on its side.
			for __, i in ipairs({ 1, 4 }) do
				local __, ni = nodeOf(net, b.nodes[i].entity)
				for __, e in ipairs(fans) do
					if e.node0 == ni or e.node1 == ni then
						local m = net.nodes[e.node0 == ni and e.node1 or e.node0]
						t.near(math.abs(m.x - b.nodes[i].x), merge - 0.03, 1e-6, label .. ": merging the turnout's way out")
						t.near(m.y, b.nodes[i].y > 0 and 2.5 or -2.5, 1e-9, label .. ": into our track on its side")
						t.eq(count[e.node0 == ni and e.node1 or e.node0], 3, label .. ": a switch there")
					end
				end
			end
			for __, i in ipairs({ 2, 3 }) do
				local __, ni = nodeOf(net, b.nodes[i].entity)
				local onTrack = false
				for __, e in ipairs(net.edges) do
					if (e.node0 == ni or e.node1 == ni) and (e.track == 1 or e.track == 2) then
						onTrack = true
					end
				end
				t.ok(onTrack, label .. ": an inner node is our track's end")
			end
		end
		for __, x in ipairs(byTrack(net, 0)) do
			t.ok(math.min(x.s0, 3000 - x.s1) >= merge + 30 - 1, label .. ": crossovers after the fan")
		end
	end
end)

t.test("network: a bare fan's turnout is shortened to fit the leg's straight there", function()
	local o = network.defaults()
	o.bareFan = 110
	-- 100 m of straight (the simple style's approach), then a curve.
	local net = bareNet("fan", nil, o, { straight(0, 0, 100, 0), arc(100, 0, 1000, 0.5), straight(0, 0, 1000, 0) })
	local fans = byTrack(net, 3)
	t.eq(#fans, 2, "the start's fan")
	for __, e in ipairs(fans) do
		t.near(e.s1, 20 + 80, 1e-9, "a 80 m turnout, its merge on the straight")
	end
end)

-- The tightest radius in plan along an edge (sampled).
local function tightest(e)
	local r = math.huge
	for k = 0, 50 do
		local u = k / 50
		local d1 = { x = 0, y = 0 }
		local d2 = { x = 0, y = 0 }
		for __, c in ipairs({ "x", "y" }) do
			d1[c] = (6 * u * u - 6 * u) * e.p0[c] + (3 * u * u - 4 * u + 1) * e.t0[c] + (-6 * u * u + 6 * u) * e.p1[c]
				+ (3 * u * u - 2 * u) * e.t1[c]
			d2[c] = (12 * u - 6) * e.p0[c] + (6 * u - 4) * e.t0[c] + (-12 * u + 6) * e.p1[c] + (6 * u - 2) * e.t1[c]
		end
		local cross = math.abs(d1.x * d2.y - d1.y * d2.x)
		if cross > 1e-12 then
			r = math.min(r, (d1.x ^ 2 + d1.y ^ 2) ^ 1.5 / cross)
		end
	end
	return r
end

t.test("network: a bare end with 2 tracks 10 m apart: each of ours eases out to its own over an S-curve", function()
	for __, o in ipairs({ network.defaults(), halt() }) do
		local label = o.fan and "halt" or "simple"
		local net, stations = bareNet("island", "island", o)
		local eases = byTrack(net, 3)
		t.eq(#eases, 4, label .. ": one a track at each end")
		for __, b in ipairs({ stations[1].bare[1], stations[2].bare[-1] }) do
			checkJoined(net, b, label)
		end
		for __, e in ipairs(eases) do
			local atStart = e.s0 == 0
			local station = net.nodes[atStart and e.node0 or e.node1]
			local ours = net.nodes[atStart and e.node1 or e.node0]
			t.ok(station.entity ~= nil, label .. ": from the station's node")
			t.near(math.abs(station.y), 5, 0.01, label .. ": 5 m off the midline")
			t.near(ours.y, station.y / 2, 1e-9, label .. ": to our track on its side, 2.5 m off")
			t.near(e.s1 - e.s0, 70, 1e-9, label .. ": 70 m along the axis")
			for __, tg in ipairs({ e.t0, e.t1 }) do
				t.near(tg.y, 0, 1e-12, label .. ": tangent along the axis")
			end
			t.ok(tightest(e) >= 300, label .. (": radius %.0f m, at least 300"):format(tightest(e)))
			t.ok(e.signals == nil or o.fan ~= nil, label .. ": signals only with Halt 2+2")
		end
		-- Our tracks start (end) where the S-curves end, 70 m out.
		for k = 1, 2 do
			local list = byTrack(net, k)
			t.near(list[1].s0, 70, 1e-9, label .. ": track " .. k .. " starts after the S-curve")
			t.near(list[#list].s1, 2930, 1e-9, label .. ": and ends before it")
		end
		local crossovers = byTrack(net, 0)
		t.eq(#crossovers, 4, label .. ": a pair at each end")
		for __, x in ipairs(crossovers) do
			t.ok(math.min(x.s0, 3000 - x.s1) >= 70 + 3, label .. ": past the S-curves")
		end
		if o.fan then
			local starters = 0
			for __, e in ipairs(eases) do
				starters = starters + #(e.signals or {})
			end
			t.eq(starters, 2, "a starter on each leaving S-curve")
		end
	end
end)

t.test("network: every bare kind's edges are in exactly one chunk", function()
	for kind in pairs(KINDS) do
		for __, o in ipairs({ network.defaults(), halt() }) do
			local net = bareNet(kind, kind, o)
			local seen = {}
			for __, c in ipairs(net.chunks) do
				for i = c.first, c.last do
					t.ok(not seen[i], kind .. ": edge " .. i .. " in one chunk")
					seen[i] = true
				end
			end
			t.eq(#seen, #net.edges, kind .. ": all edges chunked")
		end
	end
end)

t.test("network: a station with a junction at one end and a bare end at the other", function()
	local e = exEnd({ x = 3000, y = 3000 }, { x = 1, y = 0 }, 1, 10, 0)
	local st, j = exStation(e, 1, true)
	local l = junctionLeg(e, j, 1, 2500, true)
	local last = l.pieces[1].b
	local b = bareEnd("direct", last.x, last.y, 10, { x = -1, y = 0 }, KINDS.direct, 0.03)
	local net = network.build({ ok = true, legs = { l }, stations = { st, bareSt(b, false) }, platformLength = 160 },
		network.defaults())
	checkJunction(net, e, j, 1, 1, true)
	checkJoined(net, b, "bare end")
	local crossovers = byTrack(net, 0)
	t.eq(#crossovers, 2, "crossovers at the bare end only")
	for __, x in ipairs(crossovers) do
		t.ok(x.s0 > 2000, "at the bare end")
	end
end)

t.test("network: our tracks join a bare end's nodes along their own pieces' directions, not the end's axis", function()
	local a = math.rad(0.8)
	for __, kind in ipairs({ "direct", "island", "fan" }) do
		for __, o in ipairs({ network.defaults(), halt() }) do
			local l = leg({ straight(0, 0, 3000, 0) })
			local bs = bareEnd(kind, 0, 0, 10, { x = 1, y = 0 }, KINDS[kind], 0.03)
			local be = bareEnd(kind, l.length, 0, 10, { x = -1, y = 0 }, KINDS[kind], 0.03, 800)
			-- Each node's piece turned by ±0.8° (alternating), outward.
			for __, b in ipairs({ bs, be }) do
				b.dirs = {}
				for i = 1, #b.nodes do
					local r = (i % 2 == 0 and 1 or -1) * a
					b.dirs[i] = { x = b.out.x * math.cos(r) - b.out.y * math.sin(r), y = b.out.x * math.sin(r) + b.out.y * math.cos(r) }
				end
			end
			local stations = { bareSt(bs, true), bareSt(be, false) }
			local net = network.build({ ok = true, legs = { l }, stations = stations, platformLength = 160 }, o)
			for __, b in ipairs({ bs, be }) do
				for i, sn in ipairs(b.nodes) do
					local __, ni = nodeOf(net, sn.entity)
					t.ok(ni ~= nil, kind .. ": node " .. sn.entity .. " joined")
					for __, e in ipairs(net.edges) do
						if e.node0 == ni or e.node1 == ni then
							-- Leaving the station (node0) along its direction out; arriving (node1) along it inward.
							local tg = e.node0 == ni and e.t0 or { x = -e.t1.x, y = -e.t1.y }
							local d = math.sqrt(tg.x ^ 2 + tg.y ^ 2)
							t.near((tg.x * b.dirs[i].x + tg.y * b.dirs[i].y) / d, 1, 1e-12, kind .. ": node " .. sn.entity
								.. "'s edge along its piece")
						end
					end
				end
			end
		end
	end
end)

t.test("network: a bare island or fan end the leg is too short for is a chunk problem", function()
	for __, case in ipairs({ { "island", 120 }, { "fan", 60 } }) do
		local net = bareNet(case[1], nil, nil, { straight(0, 0, case[2], 0) })
		local problem
		for __, c in ipairs(net.chunks) do
			problem = problem or c.problem
		end
		t.ok(problem ~= nil, case[1] .. ": a problem")
		t.ok(problem:find("existing station", 1, true) ~= nil, case[1] .. ": " .. tostring(problem))
	end
	for __, kind in ipairs({ "direct", "island", "fan" }) do
		local net = bareNet(kind, kind)
		for __, c in ipairs(net.chunks) do
			t.eq(c.problem, nil, kind .. ": no problem on a 3 km leg")
		end
	end
end)
