-- Which towns lie on the way between two others, and in what order to visit them. Pure (no api.*).
global record PgraceRailRouterCorridor
	record Town
		-- The town entity.
		id : integer
		name : string
		-- Centre of the town's bounding box.
		pos : PgraceRailRouterGeo.Pt
	end

	record Candidate
		town : Town
		-- Extra straight-line metres to pass through the town's centre.
		detour : number
		-- Where the town projects onto the line from a to b: 0 at a, 1 at b.
		along : number
	end

	-- Towns other than a and b whose detour is at most budget × the direct distance and that lie between them,
	-- sorted from a to b.
	candidates : function(a : Town, b : Town, towns : {Town}, budget : number) : {Candidate}
	-- a, then the picked towns sorted from a to b, then b. a and b are skipped if picked.
	order : function(a : Town, b : Town, picked : {Town}) : {Town}
end
