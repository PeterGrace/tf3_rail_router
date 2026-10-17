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

	-- Searches rings around `town`, nearest first, for a centre where a straight run of `runLength` metres along
	-- `dir` (or up to 30° off it) is inside the grid, dry, clear of blocked, road and track cells, and within
	-- `maxRelief` metres of height (checked every quarter cell and at both ends). nil if none lies within maxRadius.
	-- `taken` (optional) marks more cells, by grid index, to treat as blocked (other stations' platforms); the grid
	-- itself is never changed.
	find : function(g : PgraceRailRouterGrid.Grid, town : PgraceRailRouterGeo.Pt, dir : PgraceRailRouterGeo.Pt,
		runLength : number, maxRelief : number, maxRadius : number, taken ?: {integer : boolean}) : Site
end
