-- A flat junction into an existing double track (milestone 4b). Pure. Frame: x along the existing axis outward
-- from the station, y to the left of outward; the existing tracks at y = ±2.5, our line on side `side` (+1: +y).
global record PgraceRailRouterJunction
	-- Where the junction cuts an existing track: which ("near": the track on our side, "far"), how far along the
	-- stretch (metres from its start), and what goes there ("switch" or "crossing").
	record Cut
		track : string
		x : number
		kind : string
	end

	-- A junction piece in the frame, as a Hermite curve: from (x0, y0) to (x1, y1), tangents (tx0, ty0), (tx1, ty1).
	record Piece
		x0 : number
		y0 : number
		x1 : number
		y1 : number
		tx0 : number
		ty0 : number
		tx1 : number
		ty1 : number
		-- "merge" (our far track into the existing near one), "cross in" (the existing far track's switch to the
		-- crossing node), "cross out" (the crossing node to our near track).
		role : string
	end

	record Layout
		-- The start of our approach (the leg's fixed end), metres along the stretch; our tracks there at y = 7.5
		-- side and 12.5 side, running straight outward from it.
		approachX : number
		pieces : {Piece}
		cuts : {Cut}
	end

	-- The S-curve length for a lateral offset at turnout radius r: max(40, 5 × round(√(4 r × offset) / 5)).
	sCurve : function(offset : number, radius : number) : number
	-- The angle (radians) each crossing arc turns at radius r: acos(1 − 5 / r).
	crossAngle : function(radius : number) : number
	-- The x length of each crossing arc at radius r: r sin(crossAngle(r)).
	crossRun : function(radius : number) : number
	-- The junction nearest the stretch's start that fits, keeping every cut CLEAR (15 m) from the existing signals
	-- (x positions along the stretch, per track) and from the stretch's start: nil if none fits within `length`.
	-- `nodes` (nil: none): each track's existing nodes (its pieces' ends) as x along the stretch. A switch cut keeps
	-- every node 20 m outward of it and 3 m behind it away (the game refuses a switch whose main track on the branch's
	-- side is 16.6 m or shorter), but one within 0.5 m, which becomes the switch (the cut and its piece's end move
	-- onto it); the crossing cut keeps nodes 3 m away but one at its place (within 0.01 m). Placements every 5 m are
	-- tried, and those that put a cut on a node. `accept` (nil: any): a placement that fits is returned only if
	-- `accept` takes it; otherwise the search goes on outward (milestone 4c: the planner takes only placements on
	-- straight midline).
	fit : function(length : number, radius : number, side : number, signals : {string : {number}},
		nodes ?: {string : {number}}, accept ?: function(Layout) : boolean) : Layout
	-- Total length a junction needs at radius r (no signals in the way): sCurve(10, r) + 2 crossRun(r) + 80.
	needed : function(radius : number) : number
end
