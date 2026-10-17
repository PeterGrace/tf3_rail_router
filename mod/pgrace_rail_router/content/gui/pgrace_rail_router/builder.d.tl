-- Turns a plan into the game's proposals (one per station, one per network chunk) and dry-runs them, one per step
-- from a join (each can take a few hundred milliseconds), summing the game's price and collecting its errors.
-- Main thread only (react.enqueueJoin): every function here but progress calls the engine.
global record PgraceRailRouterBuilder
	-- What one proposal is: "station" (index into plan.stations) or "chunk" (index into net.chunks).
	record Item
		kind : string
		index : integer
	end

	record Outcome
		item : Item
		ok : boolean
		cost : integer
		-- The game's error messages (empty when clean), or why the proposal couldn't be made; and where (the item's
		-- first point), for the window.
		messages : {string}
		x : number
		y : number
		-- Wall time of the dry run (microseconds); 0 if there was none.
		us : integer
	end

	record Settings
		-- Track template resource name (the electrified variant if chosen).
		track : string
		-- The track's top speed (m/s), for picking bridge and tunnel types.
		speed : number
		year : integer
		-- The bridge and tunnel types for the line (modes.structureFor); nil where none is available: a chunk with a
		-- bridge (tunnel) then isn't dry-run but reported as "no bridge (tunnel) type available".
		bridge : PgraceRailRouterModes.StructureType
		tunnel : PgraceRailRouterModes.StructureType
		-- BaseEdge.typeIndex on plain (NORMAL) edges (probe P1 reads what the game's own carry).
		normalTypeIndex : integer
		era : PgraceRailRouterStationLayout.Era
		-- The main building, stairs and roofs besides the platforms and tracks; nil for none (probe P6 tries both).
		addons : PgraceRailRouterStationLayout.Addons
		network : PgraceRailRouterNetwork.Options
	end

	record Check
		plan : PgraceRailRouterRoute.Plan
		settings : Settings
		net : PgraceRailRouterNetwork.Network
		items : {Item}
		-- The next item to dry-run.
		next : integer
		outcomes : {Outcome}
		-- The sum of the game's prices, and the outcomes that weren't clean.
		total : integer
		failures : integer
		-- The slowest dry run so far and the time of all of them (microseconds).
		slowestUs : integer
		totalUs : integer
		done : boolean
	end

	-- The network (network.build) and the list of proposals to dry-run: the stations, then the chunks. Logs a summary
	-- with the time network.build took and settingsUs (the caller's time making the settings: structureTypes).
	start : function(plan : PgraceRailRouterRoute.Plan, settings : Settings, settingsUs ?: integer) : Check
	-- Dry-runs the next item (one dry run, never more). Returns true when all are done.
	step : function(check : Check) : boolean
	progress : function(check : Check) : number
	-- The SimpleProposal for edges first .. last of the network (new nodes for every end, so each chunk's dry run
	-- stands alone), or nil and why it can't be made (the track template not found, a bridge or tunnel with no type).
	chunkProposal : function(net : PgraceRailRouterNetwork.Network, first : integer, last : integer,
		settings : Settings) : SimpleProposal, string
	-- The SimpleProposal for one of the plan's stations, or nil and why it can't be made (the station or a module
	-- file not found).
	stationProposal : function(plan : PgraceRailRouterRoute.Plan, index : integer, settings : Settings) : SimpleProposal,
		string
	-- The station module's resource name as the module repository knows it: `name`, else the same with or without its
	-- leading "::"; nil if neither is found.
	resolveModule : function(name : string) : string
	-- A dry run: whether it's clean, the price, the error messages, its wall time in µs, and the raw ProposalData
	-- (nil if the dry run threw).
	dryRun : function(proposal : SimpleProposal) : boolean, integer, {string}, integer, ProposalData
end
