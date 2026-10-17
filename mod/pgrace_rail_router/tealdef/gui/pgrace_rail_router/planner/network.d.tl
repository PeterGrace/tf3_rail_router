-- The track a plan builds, as the game's edges: two parallel tracks along each leg, as cubic Hermite curves between
-- nodes, split where a bridge or tunnel starts or ends and wherever a piece is longer than an edge may be, and grouped
-- into chunks for the dry runs (and in milestone 3, building). Pure (no api.*).
global record PgraceRailRouterNetwork
	record Pt3
		x : number
		y : number
		z : number
		-- A node: the game's node entity already there (a station's track end, a chunk built before), which a proposal
		-- joins instead of adding a node; nil for a new node.
		entity : integer
	end

	record Edge
		-- Indices into Network.nodes.
		node0 : integer
		node1 : integer
		p0 : Pt3
		p1 : Pt3
		-- Hermite tangents (their length is the curve's parameter scale; z is the grade times their length in plan).
		t0 : Pt3
		t1 : Pt3
		-- "ground", "bridge" or "tunnel".
		kind : string
		-- 1: the left track (in the leg's direction of travel), 2: the right.
		track : integer
		leg : integer
		-- Metres along the leg's centre line where the edge starts and ends.
		s0 : number
		s1 : number
	end

	-- A run of edges dry-run (and later built) as one proposal: Network.edges[first .. last].
	record Chunk
		first : integer
		last : integer
		leg : integer
		-- Centre-line metres × 2 (both tracks).
		length : number
	end

	record Network
		nodes : {Pt3}
		edges : {Edge}
		chunks : {Chunk}
	end

	record Options
		-- Half the distance between the two tracks' centre lines (metres; trackDistance / 2).
		offset : number
		-- The longest an edge may be (metres along the centre line).
		maxEdge : number
		-- About how much centre line goes into one chunk (metres); a bridge or tunnel is never split between two.
		chunkLength : number
		-- "circle" (tangent length 4 R tan(θ/4)) or "arc" (R θ): which the game's curves use (probe P1).
		tangent : string
	end

	-- The defaults: offset 2.5, maxEdge 250, chunkLength 1000, tangent "circle".
	defaults : function() : Options
	-- One track's edges along a leg, `side` +1 for the left track, -1 for the right, without node indices.
	trackEdges : function(leg : PgraceRailRouterRoute.Leg, legIndex : integer, side : number, options : Options) : {Edge}
	-- The whole plan's network.
	build : function(plan : PgraceRailRouterRoute.Plan, options : Options) : Network
end
