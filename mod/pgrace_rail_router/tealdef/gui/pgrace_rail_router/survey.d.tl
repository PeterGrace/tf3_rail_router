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
		-- Set once the finishing summary has been logged.
		reported : boolean
		-- Diagnostics, logged in that summary.
		-- Constructions and town buildings marked (each counted once).
		constructions : integer
		townBuildings : integer
		-- Constructions or town buildings with no box of their own or of their construction.
		noBox : integer
		-- Edges seen, and how many were streets or track; tunnels are counted and left out.
		edges : integer
		streetEdges : integer
		trackEdges : integer
		tunnelsSkipped : integer
		-- Edges drawn as a straight node-to-node line because their curve couldn't be read.
		curveFallbacks : integer
		-- Cells off the map (terrain.isValidCoordinate false).
		invalidCells : integer
		-- Reads or tasks that threw (each logged once per kind).
		failures : integer
		-- The slowest single row and tile tasks, microseconds.
		slowestRowUs : integer
		slowestTileUs : integer
		-- step calls so far, and the time spent in them, microseconds.
		stepCalls : integer
		totalUs : integer
	end

	-- Every town with its centre, sorted by name.
	towns : function() : {PgraceRailRouterCorridor.Town}
	-- The base track types (catenary variants left out), slowest first.
	trackTypes : function() : {PgraceRailRouterModes.TrackType}
	year : function() : integer
	-- Sets up a grid with `cell`-metre cells over the stops' bounding box, grown by `margin` × its larger side (at
	-- least 2 km). Cells get coarser if the grid would be too large. nil if there are no stops, or a stop's position
	-- isn't a finite number.
	start : function(stops : {PgraceRailRouterCorridor.Town}, cell : number, margin : number) : Job
	-- Works for about budgetUs microseconds (at least one task); true when done. Each task runs in a pcall: a failed
	-- one is logged once and skipped. The first call that finishes logs a summary of the survey.
	step : function(job : Job, budgetUs : integer) : boolean
	progress : function(job : Job) : number
	grid : function(job : Job) : PgraceRailRouterGrid.Grid
end
