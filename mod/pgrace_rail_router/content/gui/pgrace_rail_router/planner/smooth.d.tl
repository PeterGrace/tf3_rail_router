-- Turns a jagged grid path into straights and arcs no tighter than a radius, and samples points along them.
-- Pure (no api.*).
global record PgraceRailRouterSmooth
	record Piece
		-- "straight" or "arc"
		kind : string
		a : PgraceRailRouterGeo.Pt
		b : PgraceRailRouterGeo.Pt
		length : number
		-- Arcs only: radius, centre, and the signed turn in radians (positive turns left).
		radius : number
		centre : PgraceRailRouterGeo.Pt
		turn : number
	end

	record Sample
		p : PgraceRailRouterGeo.Pt
		-- Metres along the pieces from their start.
		s : number
	end

	record Result
		pieces : {Piece}
		-- The tightest arc's radius; math.huge without arcs. Below the asked radius only where fixed points left no
		-- room for it.
		minRadius : number
		-- Points dropped to make room for the curves.
		removed : integer
	end

	-- Douglas–Peucker: drops points within `tolerance` metres of the segment between their neighbours (so a point
	-- that overshoots the segment's end is kept). Keeps the ends.
	simplify : function(points : {PgraceRailRouterGeo.Pt}, tolerance : number) : {PgraceRailRouterGeo.Pt}
	-- Rounds each corner with an arc of `radius`. Where neighbouring arcs don't fit, a point is dropped (the one with
	-- the gentler turn); points marked in `fixed` (by index) and the two ends are never dropped, and arcs between
	-- them are tightened to fit instead. Consecutive points closer than 1e-6 m are merged first (fixed if either
	-- was; the ends stay). Fewer than two points give no pieces.
	fillet : function(points : {PgraceRailRouterGeo.Pt}, radius : number, fixed : {boolean}) : Result
	-- The point `d` metres along a piece.
	pointAt : function(piece : Piece, d : number) : PgraceRailRouterGeo.Pt
	-- Points every `step` metres or less along the pieces, both ends included.
	sample : function(pieces : {Piece}, step : number) : {Sample}
end
