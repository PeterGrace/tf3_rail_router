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
		-- Street nodes joining two pieces (Grid.joints).
		joints : integer
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

	-- Milestone 4b. Engine reads, each in a pcall: a station or piece that can't be read is left out and logged once.
	-- A station's track ends: the nodes of its frozen track edges that aren't among its frozen nodes (the builder joins
	-- these too). Positions are copied into plain numbers, with entity the node.
	trackEnds : function(station : integer) : {PgraceRailRouterNetwork.Pt3}
	-- The rail stations within reach (metres) of the town's centre: constructions with stations and frozen track. Each
	-- one's ends split into two groups along the line between the two furthest apart: centre is the midpoint of the
	-- groups' centroids, dir the unit vector between them, half half their distance. A terminus (ends all at one side)
	-- is left out, and so is a station nearer another town's centre.
	existingStations : function(town : PgraceRailRouterCorridor.Town, reach : number) : {PgraceRailRouterExisting.Station}
	-- Every track piece (BASE_EDGE without BASE_EDGE_STREET) within radius of centre, with its one-way signals and each
	-- of its nodes' track piece count. The analyser reads existing.REACH out from each platform end, so pass the
	-- station's centre and radius ≥ station.half + existing.REACH + 50. A piece whose signals can't all be read is
	-- "unknown" (the analyser stops there). Logs its size, the time it took and the failed reads.
	trackSnapshot : function(centre : PgraceRailRouterGeo.Pt, radius : number) : PgraceRailRouterExisting.Snapshot
	-- Linked legs (added after 4c stage 1's in-game test): the length (metres) of the train path the game's
	-- pathfinder finds from any terminal of one station construction to any of the other's (findPathNodeToNode,
	-- TransportMode.TRAIN: it follows the track's geometry, so a train never reverses on it, and ignores one-way
	-- signals), summing its track pieces' chords, each piece once. Entries that aren't readable track pieces are
	-- allowed only before the first piece and after the last (the stations' own network inside their constructions);
	-- nil where there's no path, no piece, an unread entry between pieces, or a read throws (logged once). Logs each query (the path's size and how its entries read).
	trackLink : function(stationA : integer, stationB : integer) : number
end
