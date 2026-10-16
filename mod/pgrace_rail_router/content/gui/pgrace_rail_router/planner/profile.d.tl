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
		-- Consecutive runs of one kind, covering the route.
		spans : {Span}
		-- Steepest grade between samples.
		maxGrade : number
	end

	-- `s` is metres along the route per sample (increasing), `ground` the ground height and `water` whether it's
	-- water. The track follows the ground as closely as maxGrade allows, and runs straight between the banks over
	-- water. Water, and track more than bridgeAbove over the ground, are bridges; track more than tunnelBelow under
	-- it is a tunnel.
	fit : function(s : {number}, ground : {number}, water : {boolean}, maxGrade : number, bridgeAbove : number,
		tunnelBelow : number) : Result
end
