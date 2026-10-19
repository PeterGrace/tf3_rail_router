-- An existing station's ends, read from a snapshot of its track (milestone 4b). Pure: the survey fills in the
-- snapshot, and the planner uses each usable end's straight double-track stretch for a junction.
global record PgraceRailRouterExisting
	record Piece
		entity : integer
		node0 : integer
		node1 : integer
		p0 : PgraceRailRouterNetwork.Pt3
		p1 : PgraceRailRouterNetwork.Pt3
		t0 : PgraceRailRouterNetwork.Pt3
		t1 : PgraceRailRouterNetwork.Pt3
		-- "ground", "bridge" or "tunnel"; "unknown" when the survey couldn't read all its signals (the analyser stops
		-- there, as at any piece that isn't "ground")
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
	-- track end nodes.
	record Station
		entity : integer
		centre : PgraceRailRouterGeo.Pt
		dir : PgraceRailRouterGeo.Pt
		half : number
		ends : {integer}
	end

	-- A usable end: the straight double-track stretch's start on the two tracks' midline (and its height), its grade
	-- (dz per metre outward: the track at x along the stretch is at z + grade × x, and so is the junction), the unit
	-- outward direction, the stretch's length (metres), each track's pieces along it ("near": the track on our
	-- line's side, "far"), ordered outward, and each track's signals as positions along the stretch (metres from its
	-- start), and each track's nodes (its pieces' ends) the same way.
	record End
		origin : PgraceRailRouterGeo.Pt
		z : number
		grade : number
		dir : PgraceRailRouterGeo.Pt
		length : number
		pieces : {string : {Piece}}
		signals : {string : {number}}
		nodes : {string : {number}}
	end

	-- Both ends: [1] the end at +dir, [-1] the one at −dir; nil where not usable, and why in `why` ("no double
	-- track", "short": none long enough before something that stops the reading, or "left-hand").
	record Result
		ends : {integer : End}
		why : {integer : string}
		-- Per end, the longest stretch read (metres; nil where none was).
		longest : {integer : number}
	end

	-- Each end's first straight (on a steady grade), plain double-track stretch at least junction.needed(radius)
	-- long. Frame: x outward from the platform end, y to the left; the scan starts at the station's end nodes and
	-- reads up to 1.5 km out, 12 m either side. A stretch starts where exactly two straight ground pieces 4.5–5.5 m
	-- apart cross x, their grades within 0.2% of each other. Each track is then walked piece by piece through plain
	-- nodes (degree 2), and the stretch ends at the first node that isn't plain, a bridge or tunnel, a piece that
	-- isn't straight (tangents within 0.5% of the axis sideways and of the grade upward), or where the tracks stop
	-- being the only two, 4.5–5.5 m apart, with midline and height within 0.5 m of the straight line through the
	-- start (checked every 5 m and at each node). Past a short stretch the scan reads on only after a bridge or
	-- tunnel, such a drift, or a crossover; any other switch, the track's end or single track stops it. A stretch's
	-- tracks must also lead back only to the station's end nodes (through the fan's merges and crossovers), so a
	-- stretch past a siding, branch or another line's switch stops the scan too.
	-- `side[k]`: which side of end k our line comes from (+1 left of outward, −1 right; nil +1).
	analyse : function(station : Station, snap : Snapshot, side : {integer : number}, radius : number) : Result

	-- A bare end: one whose track end nodes are all free (only the station's own piece on each, degree 1), so the
	-- line joins them directly, as it joins a station of ours. kind, by the nodes' offsets across the axis from their
	-- midpoint (within 0.5 m): "direct" (2 tracks 5 m apart: our two tracks end on them), "island" (2 tracks 10 m
	-- apart: each of ours eases out 2.5 m to its own), "fan" (4 tracks at ±2.5 and ±7.5 m: our two end on the inner
	-- two, and the outer two merge into ours as Halt 2+2's fan does), or "other" (anything else: not joined). nodes:
	-- the end nodes (each with its entity, at its piece's end, height included), left to right looking outward
	-- (nodes[1] the leftmost); mid: their mean (height included); out: the unit outward direction (station.dir × k).
	record Bare
		kind : string
		nodes : {PgraceRailRouterNetwork.Pt3}
		mid : PgraceRailRouterNetwork.Pt3
		out : PgraceRailRouterGeo.Pt
	end

	-- End k (+1 at +dir, −1 at −dir) of the station, if bare: its end nodes on that side of the centre (positions from
	-- the snapshot's pieces; nodes it has no piece at are left out). nil and nil where none is free (track leads on:
	-- a junction end), nil and "mixed" where some are free and some not.
	bareEnd : function(station : Station, snap : Snapshot, k : integer) : Bare, string
end
