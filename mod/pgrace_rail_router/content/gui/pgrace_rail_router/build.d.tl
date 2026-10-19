-- Builds a checked plan (milestone 3): the stations, then the track chunk by chunk, each joined to the station ends
-- and chunks built before it, with level crossings where a chunk crosses a street and junctions into an existing
-- station's track (its pieces split first; milestone 4b), then a road from each station's
-- main building to the town's streets. One command in flight at a time,
-- each dry-run clean before it's sent (a street split, which can't be, aside); stepped from the window's join, and
-- advanced by the commands' callbacks. Main thread only.
global record PgraceRailRouterBuild
	record Failure
		-- What failed, for the window: "station" (index into plan.stations) or "chunk" (index into net.chunks).
		item : PgraceRailRouterBuilder.Item
		-- The game's messages, or why the step couldn't be made.
		messages : {string}
		-- Where (for the camera).
		x : number
		y : number
	end

	-- A chunk's level crossings in progress: the streets it collided with, the next to split, and the cuts so far
	-- (by network edge index: where the chunk's edges cross them, at the new or existing street nodes).
	record Crossings
		streets : {integer}
		next : integer
		cuts : {integer : {PgraceRailRouterNetwork.Cut}}
		-- The street pieces still to send again unedited (their lane connections), after a split.
		repair : {integer}
		count : integer
		-- Existing street nodes used as crossings, and the track (1, 2) each joins.
		nodeTrack : {integer : integer}
	end

	-- A way for a station's road to reach the streets: "dead end" (continued straight on), "node" (a T at a node
	-- along a street) or "split" (a T partway along a piece, at parameter u, split there first; node is set once it is).
	record RoadTarget
		kind : string
		p : PgraceRailRouterNetwork.Pt3
		-- The way the road runs as it arrives.
		arrive : PgraceRailRouterNetwork.Pt3
		node : PgraceRailRouterNetwork.Pt3
		piece : integer
		u : number
		-- The way the road leaves the entrance (turned `turn` degrees off straight out), and for a dead end, how far
		-- before it a middle point is (0: one curve straight to it).
		start : PgraceRailRouterNetwork.Pt3
		turn : number
		mid : number
		-- Its length plus a metre a degree it turns: shapes are tried cheapest first.
		cost : number
	end

	record Build
		check : PgraceRailRouterBuilder.Check
		-- "stations", "track", "roads", "done" or "failed"
		phase : string
		-- The next station, chunk, and station to build a road to.
		station : integer
		chunk : integer
		road : integer
		-- A command was sent and its callback hasn't come yet.
		waiting : boolean
		crossings : Crossings
		-- While a junction chunk's existing pieces are being split (milestone 4b): the next of its splits
		-- (Chunk.splits); nil otherwise.
		splitting : integer
		-- Track nodes whose pieces are to be sent again unedited for their lanes (a split's new nodes, the existing
		-- nodes a junction joined), queued from the next step; and those pieces still to send.
		repairNodes : {integer}
		trackRepair : {integer}
		failure : Failure
		-- Level crossings and junctions made, and the money the game charged.
		levelCrossings : integer
		junctions : integer
		charged : integer
		-- Stations given a road (or found with one), the towns of those left without, and street pieces still to send
		-- again for their lanes (at the junctions the roads made).
		roads : integer
		roadsMissing : {string}
		roadRepair : {integer}
		-- The street node a road was just joined to: its pieces are queued for repair on the next step.
		roadJunction : integer
		-- A street split for the current station's road: the road to its new node comes next.
		roadTarget : RoadTarget
		-- The current station's road shapes, and the next to dry-run.
		roadShapes : {RoadTarget}
		roadNext : integer
	end

	start : function(check : PgraceRailRouterBuilder.Check) : Build
	-- The next action, unless a command is in flight or the build is over. true once it's over (done or failed); a
	-- failed build still works off its pending repairs, one a step.
	step : function(b : Build) : boolean
	-- Whether the build still needs stepping: under way, or failed with a command in flight or track pieces still to
	-- repair (a split's or a junction's nodes, worked off after a failure too).
	busy : function(b : Build) : boolean
	-- Items built (stations, then chunks), and how many there are.
	progress : function(b : Build) : integer, integer
	-- After a failure: start the failed item again (a chunk from its dry run, so streets and existing track already
	-- split are used).
	retry : function(b : Build)
end
