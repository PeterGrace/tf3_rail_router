-- How long a train takes over a leg, and how much of that its tight curves cost. Pure (no api.*).
-- The train starts and stops at the stations at the leg's ends (every station is a stop), accelerates as a
-- high-speed train does (about 0.5 m/s² from a standstill, then limited by its power), and brakes at a steady rate.
-- A curve of radius R limits it to sqrt(lateralAccel · R); curves of the mode's radius or wider, and straights,
-- to the speed at that radius (weights.topSpeed). Fastest prices the time tight curves lose (weights.timeCost).
global record PgraceRailRouterSpeed
	-- A stretch of the leg (metres from its start) where the train may go at most v (m/s).
	record Limit
		s0 : number
		s1 : number
		v : number
	end

	-- The speed a curve of `radius` allows: sqrt(w.lateralAccel · radius), at most w.topSpeed.
	curveSpeed : function(radius : number, w : PgraceRailRouterModes.Weights) : number
	-- Seconds from a standstill at 0 to a standstill at `length`, at most `top` (m/s) and within the limits.
	runTime : function(length : number, limits : {Limit}, top : number) : number
	-- Seconds the limits add to the run (runTime with them, less without them); 0 for none.
	timeLost : function(length : number, limits : {Limit}, top : number) : number
	-- The limits along fitted pieces (their arcs below w.minRadius), measured from `lead` metres before the first
	-- piece. Also returns the pieces' length.
	pieceLimits : function(pieces : {PgraceRailRouterSmooth.Piece}, lead : number, w : PgraceRailRouterModes.Weights)
		: {Limit}, number
end
