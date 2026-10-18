-- Engine reads: the towns, the track types, the year, and a grid of the area around the stops (terrain, water,
-- constructions, roads and track), spread over frames. Call start/step from the main thread (react.enqueueJoin).
global record PgraceRailRouterSurvey
	-- A survey in progress. The fields are internal.
	record Job
		-- The area surveyed.
		box : PgraceRailRouterArea.Box
		grid : PgraceRailRouterGrid.Grid
		-- Resumable tasks: each call works until the clock passes the budget (doing at least a little), and returns
		-- true once the task is done. A row's terrain, or a tile's octree lookups (one a call) and marking.
		tasks : {function(Clock, number) : boolean}
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
		-- Street nodes joining three or more pieces, marked as junctions.
		junctions : integer
		-- Shore cells sampled finer for water (Grid.shore).
		shoreCells : integer
		trackEdges : integer
		tunnelsSkipped : integer
		-- Edges drawn as a straight node-to-node line because their curve couldn't be read.
		curveFallbacks : integer
		-- Cells off the map (terrain.isValidCoordinate false).
		invalidCells : integer
		-- Reads or tasks that threw (each logged once per kind).
		failures : integer
		-- The slowest single call of a task (a slice) of any kind, of a row's terrain, of one octree lookup, and of
		-- marking what a lookup found, microseconds; the slices run, and the lookups.
		slowestTaskUs : integer
		slowestRowUs : integer
		slowestQueryUs : integer
		slowestMarkUs : integer
		slices : integer
		queries : integer
		-- The slowest whole step call (its budget plus the overrun of the slice it ended on), microseconds.
		slowestStepUs : integer
		-- step calls so far, and the time spent in them, microseconds.
		stepCalls : integer
		totalUs : integer
	end

	-- Every town with its centre, sorted by name.
	towns : function() : {PgraceRailRouterCorridor.Town}
	-- The base track types (catenary variants left out), slowest first.
	trackTypes : function() : {PgraceRailRouterModes.TrackType}
	-- The bridge ("bridge") or tunnel ("tunnel") types the construction menu lists, as plain data, whatever the year
	-- (modes.structureFor picks one).
	structureTypes : function(which : string) : {PgraceRailRouterModes.StructureType}
	year : function() : integer
	-- The map's extent: the terrain's bounding box, else TERRAIN.size × 256 m round the origin; nil if neither can be
	-- read (logged once).
	extent : function() : PgraceRailRouterArea.Bounds
	-- Sets up a grid with `cell`-metre cells over the stops' bounding box, grown by `margin` × its larger side (at
	-- least 2 km) and cut to `bounds` (the map's extent) if given: area.box. Cells get coarser if the grid would be too
	-- large. nil if there are no stops, or a stop's position isn't a finite number.
	start : function(stops : {PgraceRailRouterCorridor.Town}, cell : number, margin : number,
		bounds ?: PgraceRailRouterArea.Bounds) : Job
	-- Works for about budgetUs microseconds (at least one slice of a task; a slice stops at the budget, so a step
	-- overruns it by at most one terrain cell, one octree lookup or one entity's marking); true when done. Each task runs in a pcall: a failed
	-- one is logged once and skipped. The first call that finishes logs a summary of the survey.
	step : function(job : Job, budgetUs : integer) : boolean
	progress : function(job : Job) : number
	grid : function(job : Job) : PgraceRailRouterGrid.Grid
end
