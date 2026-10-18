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
		-- The straight before and after each platform (metres; nil: 100). Halt 2+2 stations need their fans' length
		-- and the crossovers' room after it (network.fanLength + 100).
		approach : number
		-- Existing stations to use (milestone 4b), by stop index (nil: none at that stop), and a snapshot of each
		-- one's track (existing.Snapshot, covering existing.REACH beyond its platform ends). The route reads each
		-- one's ends itself (existing.analyse), since which side of an end the line comes from depends on the
		-- neighbouring stops.
		existingStations : {integer : PgraceRailRouterExisting.Station}
		snapshots : {integer : PgraceRailRouterExisting.Snapshot}
		-- The turnout radius junctions are fitted for (metres); needed with existingStations.
		radius : number
	end

	record Station
		town : PgraceRailRouterCorridor.Town
		-- Faces along the scouted line through it: from 600 m (or the full radius's minimum straight, if longer)
		-- before it to as far after it, along the scouts either side (one side at the line's ends). Where no site
		-- within one cell farther from the town than the first faces that way (or one leaves no room to the
		-- neighbouring stations, or less room to turn than the first site on a side a leg leaves from), the first
		-- site, facing from town to town, is kept.
		site : PgraceRailRouterStations.Site
		-- Ground height at the station's centre (an existing station: its used ends' stretches' heights, averaged).
		z : number
		-- An existing station the line joins instead of a station of ours (nil: ours). Its site is its own centre
		-- (distance from the town's centre as for ours), facing the way the line runs through it. The line joins it
		-- at a junction on each end it uses (by end, ±1, as existing.Result's): the end's stretch (ends), the junction
		-- fitted to it (junctions) and the side of outward our line comes from (sides: +1 left, −1 right). endOf maps
		-- the leg leaving (true) and the leg arriving (false) to their ends. Such a station is never turned or
		-- re-sited, has no footprint, and its platforms aren't counted in the summary's length.
		existing : PgraceRailRouterExisting.Station
		ends : {integer : PgraceRailRouterExisting.End}
		junctions : {integer : PgraceRailRouterJunction.Layout}
		sides : {integer : number}
		endOf : {boolean : integer}
	end

	-- From one station's platform end to the next one's (at an existing station, its junction's approach start, 10 m
	-- off the existing axis, and the approach and room to turn run along that axis): a straight approach of 100 m at
	-- each end, then room for the
	-- search's first turn at full radius before the searched path: 45° where the search turns freely, one 22.5° step
	-- where it spaces its turns (less where buildings or the grid edge are in the way, which may leave a curve tighter
	-- than the radius, and never more than a quarter of the way to the other station, past both approaches).
	record Leg
		pieces : {PgraceRailRouterSmooth.Piece}
		samples : {PgraceRailRouterSmooth.Sample}
		-- Track height at each sample; the first and last are the two stations' heights (an existing station's: the
		-- existing track's at the junction's approach start).
		z : {number}
		-- Ground, bridges and tunnels. Existing track (and roads, when weights.bridgeRoads) is crossed by a bridge
		-- with at least 9 m of clearance.
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
		-- The search cost of the path taken (grid.Search cost[0]).
		searchCost : number
		-- Path points kept, and arcs tightened, so that the smoothed track keeps to the ground the grid path chose:
		-- inside the grid, off blocked cells, over water only where the path is, and with ground within 4 m of a
		-- uniform slope across the path (no hills or hollows it went round). Never below weights.minBuildRadius
		-- (smooth.Result.guarded). For the log.
		guarded : integer
		-- Seconds a train stopping at both stations loses to the leg's curves below weights.minRadius (speed.tl); 0
		-- where weights.topSpeed or lateralAccel is not given.
		timeLost : number
	end

	record Summary
		-- Metres of line, our own stations' platforms included.
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
		-- Sum over the legs of Leg.timeLost (seconds).
		timeLost : number
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
		-- Existing stations that couldn't be used, and why (a new station was planned instead), for the window.
		notes : {string}
	end

	-- A leg's path simplified, with the platform ends and approach points added, and the guard that holds the curves
	-- to the path's ground. Internal.
	record Simplified
		pts : {PgraceRailRouterGeo.Pt}
		guard : PgraceRailRouterSmooth.Guard
	end

	-- A leg's curves being fitted (spread over steps, a fillet each): the stage next, the leg as fitted so far, which
	-- ends had an arc below the build minimum (tight), which gave up their extension points (freed), and the samples
	-- on blocked cells in each half. Internal.
	record Fitting
		stage : integer
		fitted : PgraceRailRouterSmooth.Result
		tightA : boolean
		tightB : boolean
		freedA : boolean
		freedB : boolean
		blockedA : integer
		blockedB : integer
	end

	-- A leg's heights being fitted (spread over steps): its samples, and what finishing it needs. Internal.
	record LegHeights
		fitted : PgraceRailRouterSmooth.Result
		samples : {PgraceRailRouterSmooth.Sample}
		blockedSamples : integer
		fit : PgraceRailRouterProfile.FitJob
	end

	-- A leg as built so far: its path, simplified and fitted, the radius it was searched for, and its search cost.
	-- Internal.
	record LegTry
		path : {PgraceRailRouterGeo.Pt}
		simplified : Simplified
		fitted : PgraceRailRouterSmooth.Result
		radius : number
		cost : number
	end

	-- A re-siting candidate's leg being built to weigh the time it loses (with time priced): its path and search
	-- cost, the platforms it keeps off (the candidate's in place), and its curves as simplified and being fitted.
	-- Internal.
	record ResiteLeg
		path : {PgraceRailRouterGeo.Pt}
		cost : number
		taken : {integer : boolean}
		simplified : Simplified
		fitting : Fitting
	end

	-- Re-siting a station whose arriving leg loops, hooks round into it, or has a curve below the build minimum: the
	-- station (index), the directions to try, the candidate (0: the current site, then index into dirs), what is being
	-- done for it ("site": its site search; "in", "out": the searches for the legs arriving and leaving), the best so
	-- far and its cost, and the leg as built, to go back to. Internal.
	record Resite
		station : integer
		dirs : {PgraceRailRouterGeo.Pt}
		k : integer
		site : PgraceRailRouterStations.Site
		stage : string
		finder : PgraceRailRouterStations.Finder
		search : PgraceRailRouterGrid.Search
		-- The leg found for the candidate being built (nil: none), and the candidate's leg in as weighed: its search's
		-- cost, plus with time priced timeCost × the time it loses.
		leg : ResiteLeg
		-- With time priced, the radius try (index into route's searchRadii) of the leg being weighed, and its best
		-- try so far (cost plus timeCost × the time it loses; nil before one is found).
		try : integer
		legBest : number
		legBestTime : number
		inCost : number
		-- The seconds the candidate's leg in loses (with time priced), and the current site's two legs.
		inTime : number
		baseTime : number
		others : {integer : boolean}
		-- The stations' footprints with the candidate site in place (route.tl's footprints), for its legs' searches.
		avoid : {integer : boolean}
		-- The best candidate so far, and its legs' cost (weighed as inCost).
		best : PgraceRailRouterStations.Site
		bestCost : number
		keep : LegTry
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
		-- fallback's path and cost once the first has finished, and the best try so far (its path, radius, search cost
		-- and that plus the time it loses, priced: see step); the radius of the path taken, and the states expanded
		-- over all its tries.
		radii : {number}
		tryIndex : integer
		fallback : {PgraceRailRouterGeo.Pt}
		fallbackCost : number
		best : LegTry
		bestTotal : number
		searchRadius : number
		searchExpansions : integer
		-- A finished search's path, waiting for the next steps to build its leg: simplify it, fillet it, then sample
		-- its heights.
		path : {PgraceRailRouterGeo.Pt}
		-- The search cost of path.
		pathCost : number
		-- A station being re-sited (nil: none), and the stations that have been (each at most once).
		resite : Resite
		resited : {integer : boolean}
		simplified : Simplified
		fitting : Fitting
		fitted : PgraceRailRouterSmooth.Result
		heights : LegHeights
		-- Finished searches with no cost limit, by their inputs (see searchFor), so a search asked for again isn't
		-- run again (re-siting weighs the current site's legs first, the same searches the legs run); the keys in the
		-- order they came, oldest first, to keep only the last few.
		searchCache : {string : PgraceRailRouterGrid.Search}
		searchKeys : {string}
		-- Grid cells (by index) under the stations' platforms and approaches, which legs' searches keep off, and how
		-- many times they have been worked out (a key of searchCache's: a re-sited station changes them).
		footprint : {integer : boolean}
		footprintVersion : integer
		-- Grid cells (by index) under the stations placed so far, kept off by later site searches. The grid itself
		-- is never changed.
		taken : {integer : boolean}
		-- The most progress has shown so far (route.progress never goes back).
		shown : number
		-- Steps taken (route.step), and the last step route.progress crept on at (once a step).
		steps : integer
		creptAt : integer
		result : Plan
	end

	start : function(input : Input) : Job
	-- One unit of work: part of a station's site search (see stations.stepFind), starting a search (a scout or a leg's), up to maxExpansions states of it,
	-- turning a station to face the scouted line, or building a leg from its path (its curves; then its heights, over
	-- one step or more). true once the plan is finished (whether it succeeded or not).
	-- Where weights.minSearchRadius is below weights.minRadius, a leg is searched several times: first with turns
	-- spaced for minSearchRadius (the fallback; no path there fails the plan with "no_path"), then for minRadius,
	-- halving while above minSearchRadius, each with its stations' rooms to turn sized for its own radius. With
	-- weights.timeCost, every radius is tried and the path whose search cost plus timeCost × the seconds its curves
	-- lose (speed.tl, estimated from the path's corners) is least is taken; without, the first path that costs at most
	-- 10% more than the fallback's, else the fallback's.
	step : function(job : Job, maxExpansions : integer) : boolean
	-- What the next step does, for timing it: "sites", "scout", "turn" or "done" (the phase), or in the legs phase
	-- "search" (a leg's search), "simplify", "fit" (its curves), "heights" or "resite" (re-siting a station).
	stepKind : function(job : Job) : string
	-- Share of the work done, 0 to 1, never falling (where re-siting builds legs again, it holds until the work
	-- catches up).
	progress : function(job : Job) : number
	-- The plan; complete once step has returned true.
	plan : function(job : Job) : Plan
end
