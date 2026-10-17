-- Track heights along a route under a grade limit, and where that puts it on bridges or in tunnels. Pure (no api.*).
global record PgraceRailRouterProfile
	record Span
		-- "ground", "bridge" or "tunnel"
		kind : string
		-- Metres along the route.
		s0 : number
		s1 : number
	end

	record Options
		-- Steepest grade allowed (rise over run).
		maxGrade : number
		-- Track more than this far above the ground is a bridge, more than tunnelBelow under it a tunnel (metres).
		bridgeAbove : number
		tunnelBelow : number
		-- What a metre of bridge and of tunnel costs, in metres of track on the ground (Weights.bridgeCostFactor,
		-- tunnelCostFactor).
		bridgeCostFactor : number
		tunnelCostFactor : number
		-- The track's height at the first and last sample (nil: free).
		zStart : number
		zEnd : number
		-- Per sample, whether it's over a road or track to cross (nil: none).
		crossing : {boolean}
	end

	record Result
		-- Track height per sample.
		z : {number}
		-- Consecutive runs of one kind, covering the route; none shorter than 75 m unless the route is, or it's a
		-- bridge over water or a crossing.
		spans : {Span}
		-- Steepest grade between samples.
		maxGrade : number
		-- false when both ends are pinned and too far apart in height for the grade limit (the pins are kept anyway,
		-- so the grade into the last sample exceeds it).
		feasible : boolean
	end

	-- A fit spread over steps (start, step until it returns true, then result).
	record FitJob
		-- true once the fit is complete.
		done : boolean
		-- The fit, once done.
		result : Result
		-- profile.tl's own working state.
		state : any
	end

	-- `s` is metres along the route per sample (increasing), `ground` the ground height and `water` whether it's
	-- water. The track's heights are the cheapest within the grade limit: plain track costs 1 a metre (plus a little
	-- per metre of cut or fill, so it keeps to the ground where nothing is saved), bridges and tunnels their cost
	-- factors; over water it's a bridge whatever its height, and keeps near a straight line between the banks. Water,
	-- crossings, and track more than bridgeAbove over the ground, are bridges; track more than tunnelBelow under it is
	-- a tunnel. Runs shorter than 75 m are merged into their neighbours (between two of the same kind it takes theirs,
	-- else it joins the longer one), so noise doesn't split a bridge; a run over water or a crossing is always kept.
	-- Crossings are bridges with the track at least 9 m above the ground; the pinned ends win over that clearance when
	-- a crossing is too near them to climb to it.
	fit : function(s : {number}, ground : {number}, water : {boolean}, options : Options) : Result
	-- The same fit, spread over steps: start sets it up (linear in the samples), each step weighs heights until it has
	-- done `budget` units of work (a height times the predecessors it looks at; a 10 km leg over hills is a few
	-- hundred thousand) and returns true once the fit is complete, in job.result.
	start : function(s : {number}, ground : {number}, water : {boolean}, options : Options) : FitJob
	step : function(job : FitJob, budget : integer) : boolean
end
