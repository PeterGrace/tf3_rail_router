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
		-- With a guard: points kept, and arcs tightened, because the guard refused the track without them.
		guarded : integer
		-- For each arc (by index into pieces), the index into fillet's `points` of the corner it rounds.
		corners : {integer : integer}
	end

	-- Keeps fillet's track on ground the caller accepts. `clear` is asked about points every `step` metres (or less)
	-- along a piece of track, both ends included; `from` and `to` are the indices into fillet's `points` of the
	-- stretch that piece replaces (for an arc, its corner's neighbours; for the straight left by dropping a point,
	-- that point's neighbours).
	record Guard
		step : number
		-- Arcs are never tightened below this for the guard (nil: the step); the track type's buildable minimum.
		minRadius : number
		clear : function(p : PgraceRailRouterGeo.Pt, from : integer, to : integer) : boolean
	end

	-- Douglas–Peucker: drops points within `tolerance` metres of the segment between their neighbours (so a point
	-- that overshoots the segment's end is kept). Keeps the ends. With `clear`, the points i..j (indices into
	-- `points`) only become one straight if clear(i, j) also agrees; otherwise the range is split at its middle index
	-- (a range with no point between its ends never is). Returns the kept points and their indices into `points`.
	simplify : function(points : {PgraceRailRouterGeo.Pt}, tolerance : number,
		clear ?: function(i : integer, j : integer) : boolean) : {PgraceRailRouterGeo.Pt}, {integer}
	-- Rounds each corner with an arc of `radius`. Where neighbouring arcs don't fit, a point is dropped (the one with
	-- the gentler turn); points marked in `fixed` (by index) and the two ends are never dropped, and arcs between
	-- them are tightened to fit instead. Consecutive points closer than 1e-6 m are merged first (fixed if either
	-- was; the ends stay). Fewer than two points give no pieces.
	-- With a guard (floor: the larger of guard.step and guard.minRadius), a point is only dropped if the straight
	-- between its neighbours is clear; otherwise it is kept as if fixed, unless the arcs on its two segments wouldn't
	-- fit even at the floor (then it is dropped anyway: a cut corner is better than a curve that can't be built). An
	-- arc that isn't clear has its radius halved until it is, stopping at the floor (then it stays as it is).
	fillet : function(points : {PgraceRailRouterGeo.Pt}, radius : number, fixed : {boolean}, guard ?: Guard) : Result
	-- The point `d` metres along a piece.
	pointAt : function(piece : Piece, d : number) : PgraceRailRouterGeo.Pt
	-- Points every `step` metres or less along the pieces, both ends included.
	sample : function(pieces : {Piece}, step : number) : {Sample}
end
