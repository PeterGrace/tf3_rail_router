local t = ...
local builder = t.requireTl("gui/pgrace_rail_router/builder.tl")

local function hit(what, node0, node1, entity)
	return { entity = entity or 1, what = what, x = 0, y = 0, node0 = node0, node1 = node1 }
end

t.test("builder: streets collided with are level crossings", function()
	t.eq(builder.levelCrossings({ "Collision" }, { hit("street") }), 1, "one street")
	t.eq(builder.levelCrossings({ "Collision" }, { hit("street"), hit("street") }), 2, "two streets, nodes unknown")
	t.eq(builder.levelCrossings({ "Collision" }, { hit("street", 1, 2), hit("street", 3, 4) }), 2, "two roads")
	-- Bangor - Imperial Beach: the track crossed a road at the joint between two of its pieces.
	t.eq(builder.levelCrossings({ "Collision" }, { hit("street", 1, 2), hit("street", 2, 3) }), 1,
		"two pieces of one road, joined end to end")
	t.eq(builder.levelCrossings({ "Collision" }, { hit("street", 1, 2), hit("street", 3, 4), hit("street", 2, 3) }), 1,
		"three pieces, the joining one last")
	t.eq(builder.levelCrossings({ "Collision" }, { hit("street"), hit("track"), hit("street") }), 2,
		"with track hit too: the streets still count")
end)

t.test("builder: a road only run into, not crossed on the level, makes no level crossing", function()
	-- Aloha - Imperial Beach: an embankment's foot beside a bridge over a road hit the road.
	local level = function(street) return street ~= 7 end
	t.eq(builder.levelCrossings({ "Collision" }, { hit("street", 1, 2, 5) }, level), 1, "crossed")
	t.eq(builder.levelCrossings({ "Collision" }, { hit("street", 1, 2, 7) }, level), 0, "run into")
	t.eq(builder.levelCrossings({ "Collision" }, { hit("street", 1, 2, 7), hit("street", 2, 3, 5) }, level), 1,
		"one piece of the road crossed, the next hit at the joint")
	t.eq(builder.levelCrossings({ "Collision" }, { hit("street", 1, 2, 5), hit("street", 8, 9, 7) }, level), 0,
		"one road crossed, another run into")
end)

t.test("builder: no level crossings where nothing is a street, or another error came too", function()
	t.eq(builder.levelCrossings({ "Collision" }, { hit("track") }), 0, "track")
	t.eq(builder.levelCrossings({ "Collision", "Too Much Incline" }, { hit("street") }), 0, "another message")
	t.eq(builder.levelCrossings({ "Collision" }, {}), 0, "nothing known to have been hit")
end)

t.test("builder: a street node hit with the pieces it joins is the same crossing; a junction isn't one", function()
	-- Dover - Camarillo: two pieces of a road and the node between them.
	t.eq(builder.levelCrossings({ "Collision" }, { hit("street", 1, 2), hit("node", nil, nil, 2), hit("street", 2, 3) }), 1,
		"pieces and their node")
	t.eq(builder.levelCrossings({ "Collision" }, { hit("node", nil, nil, 7) }), 1, "a node alone")
	t.eq(builder.levelCrossings({ "Collision" }, { hit("junction", nil, nil, 2), hit("street", 1, 2) }), 1,
		"the junction isn't counted (it stays an error)")
end)

local function straight(x0, x1)
	return { p0 = { x = x0, y = 0, z = 0 }, p1 = { x = x1, y = 0, z = 0 }, t0 = { x = x1 - x0, y = 0, z = 0 },
		t1 = { x = x1 - x0, y = 0, z = 0 } }
end

t.test("builder: a split's parts, its length guard, and which part holds a signal", function()
	local h = straight(0, 100)
	local parts = builder.splitParts(h, { 0.3, 0.6 }, builder.MIN_SPLIT_PIECE)
	t.eq(#parts, 3, "three parts")
	t.near(parts[1].p1.x, 30, 1e-6, "the first ends at the first cut")
	t.near(parts[2].p1.x, 60, 1e-6, "the second at the second")
	t.near(parts[3].p1.x, 100, 1e-6, "the last at the piece's end")
	local none, why = builder.splitParts(h, { 0.3, 0.32 }, builder.MIN_SPLIT_PIECE)
	t.eq(none, nil, "a 2 m part is refused")
	t.ok(why:find("part 2"), "and says which")
	t.eq(builder.splitParts(h, { 0.6, 0.3 }, builder.MIN_SPLIT_PIECE), nil, "cuts out of order are refused")
	t.eq(builder.splitParts(h, { 1.0 }, builder.MIN_SPLIT_PIECE), nil, "a cut at the end is refused")
	t.eq(#builder.splitParts(h, { 0.3, 0.32 }), 3, "a street (no guard) is cut anyway")
	local j, u, d = builder.partOf(parts, { x = 45, y = 3, z = 0 })
	t.eq(j, 2, "a signal beside x = 45 is on the middle part")
	t.near(u, 0.5, 1e-2, "halfway along it")
	t.near(d, 3, 1e-2, "3 m off its curve")
	t.eq((builder.partOf(parts, { x = 80, y = -3, z = 0 })), 3, "one at x = 80 on the last")
end)

t.test("builder: a cut fits a piece only clear of its ends", function()
	local h = straight(0, 100)
	t.eq(builder.cutFits(h, { x = 40, y = 0.2, z = 0 }), true, "inside it")
	t.eq(builder.cutFits(h, { x = 40, y = 1, z = 0 }), false, "beside it")
	t.eq(builder.cutFits(h, { x = 40, y = 0, z = 3 }), false, "above it")
	t.eq(builder.cutFits(h, { x = 100, y = 0, z = 0 }), false, "at its end: a part that kept the id")
	t.eq(builder.cutFits(h, { x = 101, y = 0, z = 0 }), false, "past its end")
	t.eq(builder.cutFits(h, { x = 2, y = 0, z = 0 }), false, "within 2.5 m of its start")
end)

t.test("builder: junctions are counted per leg end", function()
	local function edge(s0, s1, whole)
		return { s0 = s0, s1 = s1, whole = whole }
	end
	local net = { nodes = {}, chunks = {}, edges = {
		edge(-120, -40, true), edge(-110, -30, true), edge(-30, 0, false), edge(0, 250, false), edge(250, 500, false),
		edge(510, 600, true) } }
	t.eq(builder.junctionCount(net, 1, 6), 2, "at both ends")
	t.eq(builder.junctionCount(net, 1, 3), 1, "at the start")
	t.eq(builder.junctionCount(net, 4, 6), 1, "at the end")
	t.eq(builder.junctionCount(net, 3, 5), 0, "none")
end)

t.test("builder: the check leaves out a junction's pieces and edges ending on their cuts", function()
	local nodes = { {}, {}, { existing = { piece = 10, s = 0.4 } }, {}, {} }
	local function edge(a, b, whole)
		return { node0 = a, node1 = b, whole = whole, leg = 1 }
	end
	local net = { nodes = nodes, chunks = {}, edges = { edge(1, 2), edge(2, 4), edge(3, 4, true), edge(3, 5), edge(5, 1) } }
	local sub, whole, touching = builder.checkedEdges(net, 1, 5)
	t.eq(whole, 1, "the junction piece")
	t.eq(touching, 1, "the edge on its cut")
	t.eq(#sub.edges, 3, "the rest")
	t.eq(sub.edges[3], net.edges[5], "in order")
	t.eq(sub.nodes, nodes, "net's own nodes")
	t.eq(sub.chunks[1].last, 3, "one chunk over them")
	local sub2, w2 = builder.checkedEdges(net, 1, 2)
	t.eq(#sub2.edges, 2, "a chunk with no junction keeps every edge")
	t.eq(w2, 0, "nothing left out")
end)
