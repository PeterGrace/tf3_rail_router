-- Where a town's station goes: the nearest spot to its centre with room for a straight, flat run, never on a
-- building, road or existing track (the survey blocks buildings with a buffer). Pure (no api.*).
global record PgraceRailRouterStations
	record Site
		-- Centre of the platforms.
		centre : PgraceRailRouterGeo.Pt
		-- Unit direction of the platforms, in the direction of travel.
		dir : PgraceRailRouterGeo.Pt
		-- Metres from the town's centre.
		distance : number
	end

	-- The check that a site connects to open country, where a leg can leave and reach it: its centre cell, and each
	-- end of its run a leg uses, without going back through the run's other cells, must connect over unblocked cells
	-- (by the grid search's moves, the knight moves' rule included) to a cell farther than `radius` from the town's
	-- centre, or on the grid's edge (beyond it is unknown). A clear run in a pocket of buildings, or with one end in a
	-- dead end, can't be reached by any leg.
	record Exit
		radius : number
		-- Which ends a leg uses: forward (the end the run's direction points to; a leg leaves there) and backward (a
		-- leg arrives there). nil counts as true.
		forward : boolean
		backward : boolean
		-- What the centre floods found, by cell index: true connects, false is boxed in. Filled in by the search; pass
		-- the same Exit to later searches for the same town (and grid) to reuse it. nil: a new one.
		known : {integer : boolean}
	end

	-- One way-out check: a flood from `cell`, never entering `excluded` (the run's other cells; nil for the centre
	-- check). For an end, `pt` is the end point and `out` the way out of the station there: the flood starts with
	-- the moves a leg's search could make from it (grid.leaveCells). Internal.
	record Check
		cell : integer
		excluded : {integer : boolean}
		pt : PgraceRailRouterGeo.Pt
		out : PgraceRailRouterGeo.Pt
	end

	-- A flood in progress. Internal.
	record Flood
		-- Cells to look at, by distance from the town's centre (a max-heap: farthest first).
		heap : {integer}
		keys : {number}
		seen : {integer : boolean}
		-- Every cell reached, to record in Exit.known when a centre flood ends.
		cells : {integer}
		-- As the check's.
		excluded : {integer : boolean}
	end

	-- A search for a site in progress (startFind, stepFind). The fields other than site are internal.
	record Finder
		-- The site found; nil until then, and when the search ends with none.
		site : Site
		-- The search has ended (found a site or passed maxRadius).
		done : boolean
		g : PgraceRailRouterGrid.Grid
		town : PgraceRailRouterGeo.Pt
		-- The wanted direction, and the directions tried at each spot.
		unit : PgraceRailRouterGeo.Pt
		dirs : {PgraceRailRouterGeo.Pt}
		runLength : number
		maxRelief : number
		maxRadius : number
		-- The ring being searched, its number of spots, and the next spot on it (0-based).
		r : number
		n : integer
		i : integer
		-- Whether a cell (by grid index) is dry and clear of blocked, road, track and taken cells.
		free : function(i : integer) : boolean
		-- Work done in the current stepFind.
		work : integer
		-- The exit check (nil: none). The spot whose runs are being tried, and the next run (index into dirs). The site
		-- being weighed (its runs clear), its checks and the one running, and its flood.
		exit : Exit
		spot : PgraceRailRouterGeo.Pt
		di : integer
		candidate : Site
		checks : {Check}
		checkIndex : integer
		flood : Flood
		-- Sites refused because their clear run is boxed in (no way out to open country at the centre or an end a
		-- leg uses).
		pocketed : integer
	end

	-- Searches rings around `town`, nearest first, for a centre where a straight run of `runLength` metres along
	-- `dir` (or up to 30° off it) is inside the grid, dry, clear of blocked, road and track cells, and within
	-- `maxRelief` metres of height (checked every quarter cell and at both ends). nil if none lies within maxRadius.
	-- `taken` (optional) marks more cells, by grid index, to treat as blocked (other stations' platforms); the grid
	-- itself is never changed. With `exit`, a spot whose run is clear but boxed in (see Exit) is passed over too.
	find : function(g : PgraceRailRouterGrid.Grid, town : PgraceRailRouterGeo.Pt, dir : PgraceRailRouterGeo.Pt,
		runLength : number, maxRelief : number, maxRadius : number, taken ?: {integer : boolean}, exit ?: Exit) : Site
	-- The same search, spread over calls: start it, then stepFind until it returns true; the result is in .site.
	-- Each stepFind stops once it has done maxWork units of work (finishing the spot it is on): a spot counts 1,
	-- each run tried at it 1 more, and 4 more each for walking its cells and sampling its heights (about 1 µs a unit
	-- on desktop Lua), and each cell of an exit check's flood 2 (a flood stops mid-way at the budget and carries on
	-- in the next call). Out to 1.5 km a search passes some 3,000 spots; on a big town's site that took 41 ms in one
	-- go in-game.
	startFind : function(g : PgraceRailRouterGrid.Grid, town : PgraceRailRouterGeo.Pt, dir : PgraceRailRouterGeo.Pt,
		runLength : number, maxRelief : number, maxRadius : number, taken ?: {integer : boolean}, exit ?: Exit) : Finder
	stepFind : function(f : Finder, maxWork : integer) : boolean
end
