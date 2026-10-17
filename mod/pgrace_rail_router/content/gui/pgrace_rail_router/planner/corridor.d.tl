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
	-- sorted from a to b. Each is judged on its own: together they may well take the line far over the budget.
	candidates : function(a : Town, b : Town, towns : {Town}, budget : number) : {Candidate}
	-- The default stops among the candidates, in route order (a and b not included): cheapest insertion from the
	-- straight line a to b, each time taking the town whose best place in the line adds the least length, for as
	-- long as the whole line stays within (1 + budget) × the direct distance. The budget is for the line, not each
	-- town, so towns either side of the line don't all get in and make it zigzag.
	select : function(a : Town, b : Town, candidates : {Candidate}, budget : number) : {Town}
	-- a, the picked towns, then b, the picked towns ordered by cheapest insertion with no limit (each put in where it
	-- adds least, the cheapest first), not by where they project onto the line: towns the player ticks on both sides
	-- still make a sensible tour. For select's towns it gives select's order. a and b are skipped if picked.
	order : function(a : Town, b : Town, picked : {Town}) : {Town}
end
