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
