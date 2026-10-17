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
	end

	-- Searches rings around `town`, nearest first, for a centre where a straight run of `runLength` metres along
	-- `dir` (or up to 30° off it) is inside the grid, dry, clear of blocked, road and track cells, and within
	-- `maxRelief` metres of height (checked every quarter cell and at both ends). nil if none lies within maxRadius.
	-- `taken` (optional) marks more cells, by grid index, to treat as blocked (other stations' platforms); the grid
	-- itself is never changed.
	find : function(g : PgraceRailRouterGrid.Grid, town : PgraceRailRouterGeo.Pt, dir : PgraceRailRouterGeo.Pt,
		runLength : number, maxRelief : number, maxRadius : number, taken ?: {integer : boolean}) : Site
	-- The same search, spread over calls: start it, then stepFind until it returns true; the result is in .site.
	-- Each stepFind stops once it has done maxWork units of work (finishing the spot it is on): a spot counts 1,
	-- each run tried at it 1 more, and 4 more each for walking its cells and sampling its heights (about 1 µs a unit
	-- on desktop Lua). Out to 1.5 km a search passes some 3,000 spots; on a big town's site that took 41 ms in one
	-- go in-game.
	startFind : function(g : PgraceRailRouterGrid.Grid, town : PgraceRailRouterGeo.Pt, dir : PgraceRailRouterGeo.Pt,
		runLength : number, maxRelief : number, maxRadius : number, taken ?: {integer : boolean}) : Finder
	stepFind : function(f : Finder, maxWork : integer) : boolean
end
