-- Where a town's station goes: the nearest spot to its centre with room for a straight, flat run, never on a
-- building (the survey blocks buildings with a buffer). Pure (no api.*).
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
	-- `dir` (or up to 30° off it) is inside the grid, dry, unblocked and within `maxRelief` metres of height. nil if
	-- none lies within maxRadius.
	find : function(g : PgraceRailRouterGrid.Grid, town : PgraceRailRouterGeo.Pt, dir : PgraceRailRouterGeo.Pt,
		runLength : number, maxRelief : number, maxRadius : number) : Site
end
