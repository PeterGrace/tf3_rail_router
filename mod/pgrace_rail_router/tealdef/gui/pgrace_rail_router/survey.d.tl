-- Engine reads: the towns, the track types, the year, and a grid of the area around the stops (terrain, water,
-- constructions, roads and track), spread over frames. Call start/step from the main thread (react.enqueueJoin).
global record PgraceRailRouterSurvey
	-- A survey in progress. The fields are internal.
	record Job
		grid : PgraceRailRouterGrid.Grid
		tasks : {function()}
		next : integer
		-- Entities already marked (buildings and edges show up in several tiles).
		seen : {integer : boolean}
	end

	-- Every town with its centre, sorted by name.
	towns : function() : {PgraceRailRouterCorridor.Town}
	-- The base track types (catenary variants left out), slowest first.
	trackTypes : function() : {PgraceRailRouterModes.TrackType}
	year : function() : integer
	-- Sets up a grid with `cell`-metre cells over the stops' bounding box, grown by `margin` × its larger side (at
	-- least 2 km). Cells get coarser if the grid would be too large.
	start : function(stops : {PgraceRailRouterCorridor.Town}, cell : number, margin : number) : Job
	-- Works for about budgetUs microseconds (at least one task); true when done. Each task runs in a pcall: a failed
	-- one is logged once and skipped.
	step : function(job : Job, budgetUs : integer) : boolean
	progress : function(job : Job) : number
	grid : function(job : Job) : PgraceRailRouterGrid.Grid
end
