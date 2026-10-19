-- An existing station's ends, read from a snapshot of its track (milestone 4b; through curves, 4c). Pure: the survey
-- fills in the snapshot, and the planner uses a usable end's double-track stretches for a junction.
global record PgraceRailRouterExisting
	record Piece
		entity : integer
		node0 : integer
		node1 : integer
		p0 : PgraceRailRouterNetwork.Pt3
		p1 : PgraceRailRouterNetwork.Pt3
		t0 : PgraceRailRouterNetwork.Pt3
		t1 : PgraceRailRouterNetwork.Pt3
		-- "ground", "bridge" or "tunnel"; "unknown" when the survey couldn't read all its signals (a stretch ends
		-- there, as at any piece that isn't "ground", and the reading goes on past it as past a bridge)
		kind : string
		-- One-way signals only (the survey leaves out two-way path signals, type 0): param along the piece, and +1
		-- facing node0 → node1 trains, −1 the other way.
		signals : {{number}}
	end

	-- How far out from each platform end the analyser reads (metres).
	REACH : number

	record Snapshot
		pieces : {Piece}
		-- Track pieces per node (entity → count), as streetSystem.getNodeTrackSegments gives.
		degree : {integer : integer}
	end

	-- A station: its platforms' centre and direction (a unit vector; normalised anyway), half their length, and its
	-- track end nodes. box: its construction's bounding box (world, axis-aligned; nil where the survey couldn't read
	-- it), which the survey blocks on the grid (with area.BUILDING_BUFFER round it) like any construction's: a modular
	-- station's runs about 10 m past its platform ends, so the planner treats those cells along the axis out of a bare
	-- end as the station's own there (route.tl's ownCells).
	record Station
		entity : integer
		centre : PgraceRailRouterGeo.Pt
		dir : PgraceRailRouterGeo.Pt
		half : number
		ends : {integer}
		box : PgraceRailRouterArea.Bounds
	end

	-- A usable end: a plain double-track stretch (milestone 4c: through curves). Its start on the two tracks' midline
	-- (and its height), its grade there (dz per metre outward over the first metres), the unit outward direction
	-- there, the stretch's length along its midline (metres), each track's pieces along it ("near": the track on our
	-- line's side, "far"), ordered outward, each track's one-way signals as positions along the stretch (metres from
	-- its start, projected onto the frame), and each track's nodes (its pieces' ends) the same way.
	record End
		origin : PgraceRailRouterGeo.Pt
		z : number
		grade : number
		dir : PgraceRailRouterGeo.Pt
		length : number
		pieces : {string : {Piece}}
		signals : {string : {number}}
		nodes : {string : {number}}
		-- The stretch's frame (milestone 4c): x along its midline from its start, y to the left; the midline through
		-- the two tracks' midpoints, every midline.STEP. Every use of the stretch's geometry goes through it. Past
		-- `length` it runs on straight along the end's direction (where a stretch ends mid-curve it parts from the
		-- track there).
		frame : PgraceRailRouterMidline.Frame
	end

	-- Both ends: [1] the end at +dir, [-1] the one at −dir; nil where not usable, and why in `why` ("no double
	-- track", "short": none long enough before something that stops the reading, or "left-hand").
	record Result
		ends : {integer : End}
		why : {integer : string}
		-- Per end, the longest stretch read (metres; nil where none was).
		longest : {integer : number}
		-- Per end, every stretch long enough (junction.needed), nearest first, through curves (milestone 4c); ends[k]
		-- is the first.
		stretches : {integer : {End}}
	end

	-- Each end's plain double-track stretches at least junction.needed(radius) long, read through curves (milestone
	-- 4c). The reading starts where, scanning out along the station's axis from its end nodes, exactly two straight
	-- ground pieces 4.5–5.5 m apart first cross it, their grades within 0.2% of each other (past the station's fan),
	-- and goes on up to 1.5 km out along the track. The tracks behind that start must lead back only to the station's
	-- end nodes (through the fan's merges and crossovers), or nothing is read. Each track is then walked piece by
	-- piece, whatever their shape, through plain nodes (degree 2) and through crossovers to the other track (keeping
	-- to its own track); any other switch (a node with four pieces too: a scissors crossover or a diamond), a dead
	-- end or a piece turning back ends the reading. Sampled every 2 m, the two tracks make a stretch while they are
	-- 4.5–5.5 m apart square across, level within 0.3 m, both on the ground, and no other track comes within 12 m of
	-- their midline (a bridge or tunnel more than 6 m above or below it crosses over or under, and doesn't count). A
	-- bridge or tunnel, a crossover (between and at its switches) or such a drift ends a stretch, and the next starts
	-- where the pair holds again. Each stretch's frame is the midline through the pairs' midpoints.
	-- `side[k]`: which side of end k our line comes from (+1 left of outward, −1 right; nil +1).
	analyse : function(station : Station, snap : Snapshot, side : {integer : number}, radius : number) : Result

	-- A bare end: one whose track end nodes are all free (only the station's own piece on each, degree 1), so the
	-- line joins them directly, as it joins a station of ours. kind, by the nodes' offsets across the axis from their
	-- midpoint (within 0.5 m): "direct" (2 tracks 5 m apart: our two tracks end on them), "island" (2 tracks 10 m
	-- apart: each of ours eases out 2.5 m to its own), "fan" (4 tracks at ±2.5 and ±7.5 m: our two end on the inner
	-- two, and the outer two merge into ours as Halt 2+2's fan does), "staggered" (one of those, but the nodes more
	-- than 1 m apart along the axis: not joined), or "other" (anything else: not joined). nodes: the end nodes (each
	-- with its entity, at its piece's end, height included), left to right looking outward (nodes[1] the leftmost);
	-- dirs: each node's own piece's direction there, pointing outward (unit, in plan; nil where its tangent is zero),
	-- which our track joining it follows; mid: their mean (height included); out: the unit outward direction
	-- (station.dir × k).
	record Bare
		kind : string
		nodes : {PgraceRailRouterNetwork.Pt3}
		dirs : {PgraceRailRouterGeo.Pt}
		mid : PgraceRailRouterNetwork.Pt3
		out : PgraceRailRouterGeo.Pt
	end

	-- End k (+1 at +dir, −1 at −dir) of the station, if bare: its end nodes on that side of the centre (positions from
	-- the snapshot's pieces; nodes it has no piece at are left out). nil and nil where none is free (track leads on:
	-- a junction end), nil and "mixed" where some are free and some not.
	bareEnd : function(station : Station, snap : Snapshot, k : integer) : Bare, string
	-- A station from its track end nodes (survey.trackEnds in-game, a map capture offline): the two groups of ends
	-- either side of the middle of the farthest pair, their centres giving the platforms' centre, direction (first
	-- group to second) and half-length. nil and why where the ends are fewer than two or closer than 20 m.
	stationFromEnds : function(entity : integer, ends : {PgraceRailRouterNetwork.Pt3}) : Station, string
end
