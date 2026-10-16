-- Plans a double-track line through the stops in order: a station site for each town, then one leg between each
-- pair (grid search, curves, heights). Pure (no api.*); spread over frames with start/step.
global record PgraceRailRouterRoute
	record Input
		grid : PgraceRailRouterGrid.Grid
		-- The towns to stop at, in order along the line.
		stops : {PgraceRailRouterCorridor.Town}
		weights : PgraceRailRouterModes.Weights
		-- Platform length in metres.
		platformLength : number
	end

	record Station
		town : PgraceRailRouterCorridor.Town
		site : PgraceRailRouterStations.Site
		-- Ground height at the station's centre.
		z : number
	end

	record Leg
		pieces : {PgraceRailRouterSmooth.Piece}
		samples : {PgraceRailRouterSmooth.Sample}
		-- Track height at each sample.
		z : {number}
		spans : {PgraceRailRouterProfile.Span}
		length : number
		minRadius : number
		maxGrade : number
	end

	record Summary
		-- Metres of line, platforms included.
		length : number
		bridges : integer
		bridgeLength : number
		tunnels : integer
		tunnelLength : number
		maxGrade : number
		-- The tightest curve's radius in metres; math.huge if the line is straight.
		minRadius : number
		-- Our own price estimate for both tracks (bridges and tunnels included, stations not).
		estimate : number
	end

	record Plan
		ok : boolean
		-- Why the plan failed: "no_stops", "no_site" or "no_path"; nil when ok.
		failure : string
		-- The town for no_site; the two ends of the leg for no_path.
		failureTowns : {string}
		platformLength : number
		stations : {Station}
		legs : {Leg}
		summary : Summary
	end

	-- Work in progress. The fields are internal.
	record Job
		input : Input
		-- "sites", "legs" or "done"
		phase : string
		siteIndex : integer
		legIndex : integer
		search : PgraceRailRouterGrid.Search
		result : Plan
	end

	start : function(input : Input) : Job
	-- One unit of work: a station site, or up to maxExpansions cells of a leg's search. true once the plan is
	-- finished (whether it succeeded or not).
	step : function(job : Job, maxExpansions : integer) : boolean
	-- Share of the work done, 0 to 1.
	progress : function(job : Job) : number
	-- The plan; complete once step has returned true.
	plan : function(job : Job) : Plan
end
