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

t.test("builder: a junction's dry run hitting only the pieces it splits and their nodes is clean", function()
	local splits = { { piece = 10, s = { 0.3, 0.6 } }, { piece = 20, s = { 0.5 } } }
	local all, rest = builder.junctionHits({ hit("track", 11, 12, 10) }, splits)
	t.eq(all, true, "the piece")
	t.eq(#rest, 0, "nothing left")
	all = builder.junctionHits({ hit("track", 11, 12, 10), hit("node", nil, nil, 12), hit("track", 21, 22, 20) }, splits)
	t.eq(all, true, "both pieces and a node the collisions list for one")
	all = builder.junctionHits({ hit("node", nil, nil, 31) }, splits, { 31, 32 })
	t.eq(all, true, "a node given")
	all, rest = builder.junctionHits({ hit("track", 11, 12, 10), hit("track", 12, 13, 15) }, splits)
	t.eq(all, false, "the next piece along isn't split")
	t.eq(#rest, 1, "it is left")
	t.eq(rest[1].entity, 15, "it is the one left")
	all = builder.junctionHits({ hit("node", nil, nil, 12) }, splits)
	t.eq(all, false, "a node no split piece is known to have")
	all, rest = builder.junctionHits({ hit("track", 11, 12, 10), hit("street", 1, 2, 40) }, splits)
	t.eq(all, false, "a street too")
	t.eq(rest[1].what, "street", "the street is left for the level-crossing count")
	t.eq(builder.junctionHits({}, splits), false, "nothing hit isn't a junction's joint")
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
