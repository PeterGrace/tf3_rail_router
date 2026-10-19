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
		-- A node cut into an existing station's track (a junction's switch or crossing; milestone 4b): made by
		-- splitting that piece at that parameter before the chunk is built (Chunk.splits), which sets entity. nil
		-- for any other node.
		existing : ExistingCut
	end

	-- Where an existing track piece (its entity) is cut for a junction node: the parameter along it, from its node0.
	record ExistingCut
		piece : integer
		s : number
	end

	-- An existing piece a chunk splits before it is built: its entity, and the parameters to cut it at, ascending.
	record Split
		piece : integer
		s : {number}
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
		-- 1: the left track (in the leg's direction of travel), 2: the right; 0: a crossover between them; 3: a fan's
		-- piece, from a Halt 2+2 station's local track (or a bare 4-track end's outer track) into the line's track on
		-- its side, or a bare island end's S-curve from the station's track to ours; 4: a junction's piece into
		-- an existing station's track (one edge each, never split: `whole`), or a straight on from it to the leg's
		-- end (the outer ones, where our two tracks run side by side, `paired`).
		track : integer
		-- One-way signals on it (Halt 2+2), or nil.
		signals : {Signal}
		-- One of a parallel pair of tracks (the builder sets its distance as for tracks 1 and 2), though not track 1
		-- or 2: a junction's outer straights. And a piece never to be split (a junction's piece: the game refuses a new
		-- piece over existing track unless they share a node), not even at a level crossing.
		paired : boolean
		whole : boolean
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
		-- Centre-line metres × 2 (both tracks), and the junction pieces' lengths along the existing axis.
		length : number
		-- The existing pieces to split before the chunk (its junctions' cuts, by piece), or nil.
		splits : {Split}
		-- Why the chunk can't be built (a junction's cut on no existing piece: its node is then a plain new one), or
		-- nil.
		problem : string
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
		-- Halt 2+2 stations: the turnout length L of their fans (network.turnoutLength), nil for 2-track stations. With
		-- it, each leg gets a fan at both ends, crossovers after each fan (a train can turn back at any station), and one-way signals:
		-- starters, home signals, and (blockSpacing) block signals along the line, every so many metres.
		fan : number
		blockSpacing : number
		-- The turnout length for the fan at an existing station's bare end with 4 tracks where `fan` is nil (the
		-- window's simple style: the track's Halt 2+2 turnout, which the window always sets); nil: simple track's 55 m.
		-- With `fan` set, that is used.
		bareFan : number
	end

	-- A signal on an edge: where along it (0..1), and whether it faces trains running node0 → node1.
	record Signal
		param : number
		forward : boolean
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
	-- the pieces meeting at each cut's node (the piece ends moved onto it), each with its edge's signals that fall on
	-- it (and its paired and whole flags). Nodes that aren't cuts are net's own tables, so an entity set on one is seen
	-- by both. One chunk spans every edge, with the splits and problem of net's chunk first..last, if it is one.
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
	-- cuts: where edges must also break; keepWhole: windows {s0, s1} with no break inside (a switch's branch side).
	trackEdges : function(leg : PgraceRailRouterRoute.Leg, legIndex : integer, side : number, options : Options,
		cuts ?: {number}, keepWhole ?: {{number}}) : {Edge}
	-- A Halt 2+2 fan's turnout length for a radius: max(40, 5 × round(√(20 R) / 5)) (the Express & Local mod's: simple
	-- track 150 → 55 m, standard 300 → 75 m, high-speed 600 → 110 m).
	turnoutLength : function(radius : number) : number
	-- How far a fan reaches from the platforms for a turnout length: 20 + L + 30.
	fanLength : function(l : number) : number
	-- The whole plan's network. Where a leg starts or ends at an existing station (route.Station.existing), that end
	-- has no fan and no crossovers: its junction's pieces (track 4) run from the cuts in the existing track (nodes
	-- with `existing`; the crossing node shared by the two crossing pieces) to our two tracks, and a straight on each
	-- to the leg's track ends at the junction's approach start; they go into the leg's first (or last) chunk, which
	-- lists the cuts' pieces in `splits`. The leg's first signals there sit 15 m out from the approach start, one-way,
	-- each facing its own track's trains (with or without Halt 2+2; none on the junction pieces).
	-- Where a leg starts or ends at an existing station's bare end (route.Station.bare), that end is a station end of
	-- ours, measured from its nodes: our two tracks end on the station's own end nodes (their entities and exact
	-- positions; each node the station track on that track's side), the first (last) edge along the station's axis.
	-- "direct": no fan, whatever the style. "fan": the inner two nodes ours, the outer two merging into ours as Halt
	-- 2+2's fan does, whatever the style (turnout fan, else bareFan, shortened to fit the leg's straight there).
	-- "island": each track eases from the station's track (5 m off the midline) to its own (2.5 m) over a 70 m
	-- S-curve edge (track 3; tightest radius 327 m), tangent to the axis at both ends, before the crossovers.
	-- Crossovers follow the fan (or S-curves) where the straight has room, and with Halt 2+2 the starters and home
	-- signals as at a station of ours (a starter on an island end's leaving S-curve).
	build : function(plan : PgraceRailRouterRoute.Plan, options : Options) : Network
	-- Sets `problem` on every chunk that splits an existing piece an earlier chunk splits too (network.build calls it):
	-- the first split replaces the piece, and the later one would find it gone.
	sharedSplits : function(net : Network)
end
