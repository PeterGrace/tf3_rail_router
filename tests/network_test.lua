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
