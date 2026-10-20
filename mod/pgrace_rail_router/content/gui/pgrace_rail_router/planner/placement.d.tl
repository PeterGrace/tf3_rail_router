-- A junction layout (PgraceRailRouterJunction.Layout) laid along an existing double track's midline frame, and
-- judged there (milestone 4c stage 3). Pure.
global record PgraceRailRouterPlacement
	record Options
		-- The tightest radius a mapped junction piece may have (metres), unless it's tighter on straight track.
		minRadius : number
		-- How far our straight past the approach start must run beside the track (route.tl's JUNCTION_STRAIGHT).
		straight : number
		-- Our tracks' midline's offset from the existing midline at the approach start (route.tl's JUNCTION_OFFSET).
		offset : number
		-- How much closer than `offset` the existing midline may come to our straight's ray (route.tl's RAY_SLACK).
		slack : number
		-- How far away it may get (a grid cell).
		cell : number
	end

	-- A frame piece as a world Hermite: its ends through midline.world, its tangents through midline.vector, as
	-- network.junctionEdges maps them.
	mapPiece : function(f : PgraceRailRouterMidline.Frame, p : PgraceRailRouterJunction.Piece)
		: PgraceRailRouterNetwork.Hermite
	-- The tightest radius along a Hermite's plan curve (64 samples, curvature of the cubic); math.huge if straight.
	tightest : function(h : PgraceRailRouterNetwork.Hermite) : number
	-- How far our straight, starting at frame (approachX, offset × side) along the frame's direction there, may run
	-- (metres along it): it ends at the first sample past the approach start whose midline comes within offset − slack
	-- of the ray, or lies more than `cell` from it on the far side, or lies no further along than the one before; else
	-- at the last sample. With `limit`, it may stop at the first sample at least that far along (accept needs no more).
	rayRoom : function(f : PgraceRailRouterMidline.Frame, approachX : number, side : number, offset : number,
		slack : number, cell : number, limit ?: number) : number
	-- junction.fit's accept for placements anywhere on the stretch, curves included: every mapped piece no tighter
	-- than minRadius, or where the piece itself is (unmapped, in the straight frame), no tighter than that (less 1%),
	-- and our straight past the approach start with rayRoom ≥ straight.
	accept : function(f : PgraceRailRouterMidline.Frame, side : number, o : Options)
		: function(PgraceRailRouterJunction.Layout) : boolean
end
