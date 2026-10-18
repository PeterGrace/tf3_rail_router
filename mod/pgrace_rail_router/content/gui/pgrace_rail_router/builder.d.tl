-- Turns a plan into the game's proposals (one per station, one per network chunk) and dry-runs them, one per step
-- from a join (each can take a few hundred milliseconds), summing the game's price and collecting its errors.
-- Main thread only (react.enqueueJoin): every function here but progress calls the engine.
global record PgraceRailRouterBuilder
	-- What one proposal is: "station" (index into plan.stations) or "chunk" (index into net.chunks).
	record Item
		kind : string
		index : integer
	end

	-- Something a dry run's track or station ran into, as the game lists it.
	record Collision
		entity : integer
		-- "street", "track", "node" (where pieces of street or track join), "junction" (a node joining three or more),
		-- "building" (a town building), "construction" or "other".
		what : string
		-- Where it is (its bounding box's centre, or an edge's middle); nil where it can't be read.
		x : number
		y : number
		-- For "other": the names of the component types it has (to find out what it is).
		components : string
		-- An edge's end nodes (streets and track); nil for anything else.
		node0 : integer
		node1 : integer
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
		-- Already built (a build stopped earlier): not dry-run, no price.
		built : boolean
		-- What it ran into, each entity once (the game lists some several times).
		collisions : {Collision}
		-- Streets crossed on the level (Settings.levelCrossings): in a dry run the track collides with them, since a
		-- level crossing splits the street (milestone 3). An outcome whose only errors are these is ok; one with other
		-- collisions too still counts them.
		crossings : integer
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
		-- The plan crosses roads on the level (Weights.bridgeRoads false): a collision with streets alone is a level
		-- crossing, not an error.
		levelCrossings : boolean
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
		-- Level crossings over all the outcomes, and the items already built.
		crossings : integer
		built : integer
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
	-- stands alone, except nodes with an entity, which it joins), or nil and why it can't be made (the track template not found, a bridge or tunnel with no type).
	chunkProposal : function(net : PgraceRailRouterNetwork.Network, first : integer, last : integer,
		settings : Settings) : SimpleProposal, string
	-- The SimpleProposal for one of the plan's stations, or nil and why it can't be made (the station or a module
	-- file not found).
	stationProposal : function(plan : PgraceRailRouterRoute.Plan, index : integer, settings : Settings) : SimpleProposal,
		string
	-- The station module's resource name as the module repository knows it: `name`, else the same with or without its
	-- leading "::"; nil if neither is found.
	resolveModule : function(name : string) : string
	-- How many level crossings a dry run's collisions make: the streets, pieces joined end to end counting once (a
	-- crossing at a joint hits both, and may hit the node joining them too), where every message is a collision; 0
	-- otherwise. A junction is never part of one. With `onLevel`, every road hit must have a piece it says is crossed
	-- on the level, else 0. Pure (but for what onLevel does).
	levelCrossings : function(messages : {string}, collisions : {Collision},
		onLevel ?: function(street : integer) : boolean) : integer
	-- Whether a ground edge of the chunk (edges first..last) crosses the street piece within 1.5 m of its height: a
	-- level crossing, not a street the track only runs into (an embankment's foot beside a bridge over it).
	crossesOnLevel : function(net : PgraceRailRouterNetwork.Network, first : integer, last : integer,
		street : integer) : boolean
	-- The entities a dry run collided with, each once, with what each is and where. Empty when there are none or
	-- they can't be read.
	collisions : function(data : ProposalData) : {Collision}
	-- The game's price for a metre of double track (settings.track, on the ground) at `at`: a 100 m straight along
	-- `dir` dry-run there (its price whatever it collides with). nil if the dry run fails or prices it at nothing.
	pricePerMetre : function(settings : Settings, at : PgraceRailRouterNetwork.Pt3, dir : PgraceRailRouterGeo.Pt) : number
	-- A proposal context for the player; cleanup sets cleanupStreetGraph (the game simplifies the edge and node
	-- graph: probe P9 tries it for level crossings).
	newContext : function(cleanup ?: boolean) : Context
	-- PROBE (remove before release): after a chunk's dry run failed, each of its edges dry-run alone (and with the
	-- edges sharing its nodes), logged: which the game refuses. Never throws.
	diagnose : function(net : PgraceRailRouterNetwork.Network, first : integer, last : integer, settings : Settings)
	-- Whether station i is already built (a build stopped earlier): a modular station at its site whose track ends
	-- (the nodes of its frozen edges that aren't frozen nodes) are the network's nodes there, within 1 m; those nodes
	-- get their entities. Main thread.
	builtStation : function(plan : PgraceRailRouterRoute.Plan, i : integer, net : PgraceRailRouterNetwork.Network) : boolean
	-- Whether chunk c is already built: every node of its edges is a track node in the game within 0.5 m (then they
	-- get their entities; otherwise none does). Main thread.
	builtChunk : function(net : PgraceRailRouterNetwork.Network, c : integer) : boolean
	-- A dry run: whether it's clean, the price, the error messages, its wall time in µs, and the raw ProposalData
	-- (nil if the dry run threw).
	dryRun : function(proposal : SimpleProposal, context ?: Context) : boolean, integer, {string}, integer, ProposalData
end
