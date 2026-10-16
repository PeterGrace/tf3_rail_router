-- Track heights along a route under a grade limit, and where that puts it on bridges or in tunnels. Pure (no api.*).
global record PgraceRailRouterProfile
	record Span
		-- "ground", "bridge" or "tunnel"
		kind : string
		-- Metres along the route.
		s0 : number
		s1 : number
	end

	record Result
		-- Track height per sample.
		z : {number}
		-- Consecutive runs of one kind, covering the route; none shorter than 75 m unless the route is, or it's a
		-- bridge over water.
		spans : {Span}
		-- Steepest grade between samples.
		maxGrade : number
		-- false when both ends are pinned and too far apart in height for the grade limit (the pins are kept anyway,
		-- so a grade next to one end exceeds it).
		feasible : boolean
	end

	-- `s` is metres along the route per sample (increasing), `ground` the ground height and `water` whether it's
	-- water. The track follows the ground as closely as maxGrade allows, and runs straight between the banks over
	-- water. Water, and track more than bridgeAbove over the ground, are bridges; track more than tunnelBelow under
	-- it is a tunnel. Runs shorter than 75 m are merged into their neighbours (between two of the same kind it takes
	-- theirs, else it joins the longer one), so noise doesn't split a bridge; a run over water is always kept. zStart and zEnd pin the track's height
	-- at the first and last sample (nil: free, following the ground).
	fit : function(s : {number}, ground : {number}, water : {boolean}, maxGrade : number, bridgeAbove : number,
		tunnelBelow : number, zStart ?: number, zEnd ?: number) : Result
end
