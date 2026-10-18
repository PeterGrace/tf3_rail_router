-- Builds a checked plan (milestone 3): the stations, then the track chunk by chunk, each joined to the station ends
-- and chunks built before it, with level crossings where a chunk crosses a street. One command in flight at a time,
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

	record Build
		check : PgraceRailRouterBuilder.Check
		-- "stations", "track", "done" or "failed"
		phase : string
		-- The next station and chunk to build.
		station : integer
		chunk : integer
		-- A command was sent and its callback hasn't come yet.
		waiting : boolean
		crossings : Crossings
		failure : Failure
		-- Level crossings made, and the money the game charged.
		levelCrossings : integer
		charged : integer
	end

	start : function(check : PgraceRailRouterBuilder.Check) : Build
	-- The next action, unless a command is in flight or the build is over. true once it's over (done or failed).
	step : function(b : Build) : boolean
	-- Items built (stations, then chunks), and how many there are.
	progress : function(b : Build) : integer, integer
	-- After a failure: start the failed item again (a chunk from its dry run, so streets already split are used).
	retry : function(b : Build)
end
