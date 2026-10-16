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

	-- From one station's platform end to the next one's: a straight approach of 100 m at each end, then room for a
	-- 45° turn at full radius before the searched path.
	record Leg
		pieces : {PgraceRailRouterSmooth.Piece}
		samples : {PgraceRailRouterSmooth.Sample}
		-- Track height at each sample; the first and last are the two stations' heights.
		z : {number}
		spans : {PgraceRailRouterProfile.Span}
		length : number
		minRadius : number
		maxGrade : number
		-- Arcs tighter than weights.minRadius (where fixed points left no room for the full radius).
		tightCurves : integer
		-- true when the two stations are too far apart in height for the grade limit: the track still meets both,
		-- so a grade next to one of them is steeper than allowed.
		steepEnds : boolean
		-- Samples whose nearest cell is blocked or has track on it (curves cutting corners, mostly).
		blockedSamples : integer
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
		-- Sums over the legs: arcs tighter than weights.minRadius, and samples over blocked cells or track.
		tightCurves : integer
		blockedSamples : integer
		-- Legs whose steepEnds is set.
		steepLegs : integer
	end

	record Plan
		ok : boolean
		-- Why the plan failed: "no_stops", "no_site", "too_close" (two consecutive stations' platforms, with their
		-- approaches, don't fit between them, or the second is behind the first) or "no_path"; nil when ok.
		failure : string
		-- The town for no_site; the two towns for too_close and no_path.
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
		-- Cells blocked for the earlier platforms during the site search, with their old values.
		saved : {integer : boolean}
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
