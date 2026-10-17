-- Plans a double-track line through the stops in order: a station site for each town (facing from the previous town
-- to the next), a scout of each leg (a free-turning search between the sites, any direction at either end), each
-- station found again facing along the scouted line, then one leg between each pair (grid search, curves, heights).
-- Pure (no api.*); spread over frames with start/step.
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
		-- Faces along the scouted line through it: from 600 m (or the full radius's minimum straight, if longer)
		-- before it to as far after it, along the scouts either side (one side at the line's ends). Where no site
		-- within one cell farther from the town than the first faces that way (or one leaves no room to the
		-- neighbouring stations, or less room to turn than the first site on a side a leg leaves from), the first
		-- site, facing from town to town, is kept.
		site : PgraceRailRouterStations.Site
		-- Ground height at the station's centre.
		z : number
	end

	-- From one station's platform end to the next one's: a straight approach of 100 m at each end, then room for the
	-- search's first turn at full radius before the searched path: 45° where the search turns freely, one 22.5° step
	-- where it spaces its turns (less where buildings or the grid edge are in the way, which may leave a curve tighter
	-- than the radius, and never more than a quarter of the way to the other station, past both approaches).
	record Leg
		pieces : {PgraceRailRouterSmooth.Piece}
		samples : {PgraceRailRouterSmooth.Sample}
		-- Track height at each sample; the first and last are the two stations' heights.
		z : {number}
		-- Ground, bridges and tunnels. Existing track (and roads, when weights.bridgeRoads) is crossed by a bridge
		-- with at least 7 m of clearance.
		spans : {PgraceRailRouterProfile.Span}
		length : number
		minRadius : number
		maxGrade : number
		-- Arcs tighter than weights.minRadius (where fixed points left no room for the full radius).
		tightCurves : integer
		-- true when the two stations are too far apart in height for the grade limit: the track still meets both,
		-- so a grade next to one of them is steeper than allowed.
		steepEnds : boolean
		-- Samples whose nearest cell is blocked by a building or obstacle (curves cutting corners, mostly). Existing
		-- track and roads are crossed by bridges instead (see the spans).
		blockedSamples : integer
		-- The curve radius the leg's search spaced its turns for (metres): weights.minRadius, or less where no path
		-- fitted it (halved per try, down to weights.minSearchRadius; see step). Smoothing still aims for
		-- weights.minRadius, so a smaller one leaves tight curves. And the states the search expanded, over all its
		-- tries. For the log.
		searchRadius : number
		searchExpansions : integer
		-- Path points kept, and arcs tightened, so that the smoothed track keeps to the ground the grid path chose:
		-- inside the grid, off blocked cells, over water only where the path is, and with ground within 4 m of a
		-- uniform slope across the path (no hills or hollows it went round). Never below weights.minBuildRadius
		-- (smooth.Result.guarded). For the log.
		guarded : integer
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
		-- Sums over the legs: arcs tighter than weights.minRadius, and samples over blocked cells.
		tightCurves : integer
		blockedSamples : integer
		-- Sum over the legs of Leg.guarded.
		guarded : integer
		-- Legs whose steepEnds is set.
		steepLegs : integer
	end

	record Plan
		ok : boolean
		-- Why the plan failed: "no_stops", "no_site", "no_exit" (the town has clear spots for a station, but buildings
		-- wall every one in, or a leg's search found its start closed off inside the area: a wider area can't help),
		-- "too_close" (two consecutive stations' platforms, with their approaches, don't fit between them, or the
		-- second isn't ahead of the first along both stations' directions) or "no_path"; nil when ok.
		failure : string
		-- The town for no_site and no_exit; the two towns for too_close and no_path.
		failureTowns : {string}
		platformLength : number
		stations : {Station}
		legs : {Leg}
		summary : Summary
	end

	-- A leg's path simplified, with the platform ends and approach points added, and the guard that holds the curves
	-- to the path's ground. Internal.
	record Simplified
		pts : {PgraceRailRouterGeo.Pt}
		guard : PgraceRailRouterSmooth.Guard
	end

	-- Work in progress. The fields are internal.
	record Job
		input : Input
		-- "sites", "scout", "turn", "legs" or "done"
		phase : string
		-- The station being sited, or turned; its site search, spread over steps (nil between stations); and, when
		-- turning, the other stations' platform cells, kept off.
		siteIndex : integer
		finder : PgraceRailRouterStations.Finder
		others : {integer : boolean}
		-- Each stop's exit check (by stop index), shared by its site searches.
		exits : {integer : PgraceRailRouterStations.Exit}
		-- Turning: the search has ended with this site (nil: none), to weigh in the next step.
		turnPending : boolean
		turnSite : PgraceRailRouterStations.Site
		-- Scouting: the round (1..), the leg being scouted, and the scouts' paths by leg (nil where none was found).
		round : integer
		scoutIndex : integer
		scouts : {integer : {PgraceRailRouterGeo.Pt}}
		legIndex : integer
		search : PgraceRailRouterGrid.Search
		-- The current leg's search tries: the radii to try (nil before its first), and which one is running; the
		-- fallback's path and cost once the first has finished; the radius of the path taken, and the states expanded
		-- over all its tries.
		radii : {number}
		tryIndex : integer
		fallback : {PgraceRailRouterGeo.Pt}
		fallbackCost : number
		searchRadius : number
		searchExpansions : integer
		-- A finished search's path, waiting for the next steps to build its leg: simplify it, fillet it, then sample
		-- its heights.
		path : {PgraceRailRouterGeo.Pt}
		simplified : Simplified
		fitted : PgraceRailRouterSmooth.Result
		-- Grid cells (by index) under the stations placed so far, kept off by later site searches. The grid itself
		-- is never changed.
		taken : {integer : boolean}
		result : Plan
	end

	start : function(input : Input) : Job
	-- One unit of work: part of a station's site search (see stations.stepFind), starting a search (a scout or a leg's), up to maxExpansions states of it,
	-- turning a station to face the scouted line, or building a leg from its path (curves, heights). true once the
	-- plan is finished (whether it succeeded or not).
	-- Where weights.minSearchRadius is below weights.minRadius, a leg is searched several times: first with turns
	-- spaced for minSearchRadius (the fallback; no path there fails the plan with "no_path"), then for minRadius,
	-- halving while above minSearchRadius, until a path costs at most 10% more than the fallback's; if none does,
	-- the fallback's path is taken.
	step : function(job : Job, maxExpansions : integer) : boolean
	-- Share of the work done, 0 to 1.
	progress : function(job : Job) : number
	-- The plan; complete once step has returned true.
	plan : function(job : Job) : Plan
end
