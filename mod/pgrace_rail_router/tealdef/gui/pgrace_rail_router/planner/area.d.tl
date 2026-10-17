-- The area a route is planned over (the stops' box with a margin, and its cell size), and the rules that mark
-- buildings, roads and track on a grid. Pure (no api.*): survey.tl uses it in-game, tools/replay.lua offline, so the
-- two can't drift apart.
global record PgraceRailRouterArea
	-- Cells within this distance of a building or other construction are blocked (metres).
	BUILDING_BUFFER : number
	-- At least this much room around the stops (metres).
	MIN_MARGIN : number
	-- Larger grids get coarser cells instead (memory and search time).
	MAX_CELLS : integer
	-- Cells never get coarser than this while shrinking the grid (metres).
	MAX_CELL : number

	record Box
		-- The stops' bounding box grown by the margin (world metres). Cell (1, 1)'s centre is (minX, minY).
		minX : number
		minY : number
		maxX : number
		maxY : number
		-- Cell size (metres) and the number of cells.
		cell : number
		nx : integer
		ny : integer
	end

	-- The map's extent (world metres), the most a box may cover.
	record Bounds
		minX : number
		minY : number
		maxX : number
		maxY : number
	end

	-- The stops' bounding box grown by `margin` × its larger side (at least MIN_MARGIN) on every side, cut to
	-- `bounds` if given (and finite), with `cell`-metre cells, made 1.25 times coarser at a time (up to MAX_CELL)
	-- while there would be more than MAX_CELLS. nil if there are no stops, or a stop's position isn't a finite
	-- number.
	box : function(stops : {PgraceRailRouterCorridor.Town}, cell : number, margin : number, bounds ?: Bounds) : Box
	-- Whether two boxes are the same (both nil counts): a wider margin that gives the same box can't help.
	same : function(a : Box, b : Box) : boolean

	-- Marks the cells whose centres are nearest to the box's corners and everything between (world coordinates).
	-- Boxes wholly outside the grid are skipped.
	markBox : function(g : PgraceRailRouterGrid.Grid, x0 : number, y0 : number, x1 : number, y1 : number,
		cells : {boolean})
	-- Marks the cell nearest to p, if p lies within the grid.
	markPoint : function(g : PgraceRailRouterGrid.Grid, p : PgraceRailRouterGeo.Pt, cells : {boolean})
	-- Marks the cells along the straight line from a to b, sampled at most half a cell apart.
	markLine : function(g : PgraceRailRouterGrid.Grid, a : PgraceRailRouterGeo.Pt, b : PgraceRailRouterGeo.Pt,
		cells : {boolean})
	-- Marks the cells along the cubic Hermite curve from p0 (tangent t0) to p1 (tangent t1), sampled at most half a
	-- cell apart (by the longest of the chord and the two tangents).
	markCurve : function(g : PgraceRailRouterGrid.Grid, p0 : PgraceRailRouterGeo.Pt, t0 : PgraceRailRouterGeo.Pt,
		p1 : PgraceRailRouterGeo.Pt, t1 : PgraceRailRouterGeo.Pt, cells : {boolean})
end
