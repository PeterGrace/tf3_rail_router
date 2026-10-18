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
		-- 1: the left track (in the leg's direction of travel), 2: the right; 0: a crossover between them.
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
		-- A pair of crossovers in the straight at each end of a leg (a station's approach): track 1 to 2, then 2 to 1,
		-- each an S-curve CROSSOVER_LENGTH long, so a train on either track can reach either platform (Rail Doctor:
		-- with none, the game's choice of platform could be on the other track, and the train had no path). An end
		-- that isn't straight ground for 100 m gets none.
		crossovers : boolean
	end

	-- A cubic Hermite curve (an edge's shape).
	record Hermite
		p0 : Pt3
		p1 : Pt3
		t0 : Pt3
		t1 : Pt3
	end

	-- Where a track edge crosses a street: the parameters along each, and the point on the street.
	record Crossing
		s : number
		u : number
		p : Pt3
	end

	-- A point where a chunk's edge is cut (network.cut): the parameter along the edge, and the node there.
	record Cut
		s : number
		node : Pt3
	end

	-- Where the track curve crosses the street curve in plan, in order along the track (both sampled into 64 chords;
	-- touching ends don't count).
	crossings : function(track : Hermite, street : Hermite) : {Crossing}
	-- Edges first..last of net as a network of their own, with each edge that has cuts split at them (sorted by s),
	-- the pieces meeting at each cut's node (the piece ends moved onto it). Nodes that aren't cuts are net's own
	-- tables, so an entity set on one is seen by both. One chunk spans every edge.
	cut : function(net : Network, first : integer, last : integer, cuts : {integer : {Cut}}) : Network

	-- The point at parameter s (0..1) along h.
	hermiteAt : function(h : Hermite, s : number) : Pt3
	-- h split at parameter s into the two curves either side (de Casteljau on its Bézier form), which together
	-- trace exactly h.
	splitHermite : function(h : Hermite, s : number) : Hermite, Hermite
	-- The parameter of h's point nearest p in plan (to about a thousandth: sampled, then refined).
	nearestParam : function(h : Hermite, p : PgraceRailRouterGeo.Pt) : number

	-- A crossover's length along the track (metres): its S-curve's tightest radius is length² / (6 × 5 m), 67 m,
	-- over the game's 55 m minimum; two fit in a station's 100 m approach.
	CROSSOVER_LENGTH : number
	-- The defaults: offset 2.5, maxEdge 250, chunkLength 1000, tangent "circle", crossovers on.
	defaults : function() : Options
	-- One track's edges along a leg, `side` +1 for the left track, -1 for the right, without node indices.
	trackEdges : function(leg : PgraceRailRouterRoute.Leg, legIndex : integer, side : number, options : Options,
		cuts ?: {number}) : {Edge}
	-- The whole plan's network.
	build : function(plan : PgraceRailRouterRoute.Plan, options : Options) : Network
end
