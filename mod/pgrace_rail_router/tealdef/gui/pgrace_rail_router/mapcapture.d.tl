-- Writes the whole map to the game log as text records (docs/map-capture-format.md): the terrain on a 25 m grid,
-- every town, construction, town building, street and track edge, and the track types it's given. Spread over
-- frames: call start, then step from the main thread (react.enqueueJoin) until it returns true. Self-contained: it
-- uses only the format module, so other mods can copy the pair.
global record PgraceRailRouterMapCapture
	-- The default tag in front of every record line.
	DEFAULT_TAG : string
	-- Constructions, town buildings and edges are looked up in octree tiles this wide (metres).
	TILE : number

	record Options
		-- Put in front of every record line, followed by a space. Default DEFAULT_TAG.
		tag : string
		-- Put in front of the start and summary lines (not records). Default "[rail_router] ".
		logPrefix : string
		-- Track types as plain key=value tables, written as "track" records (nil: none).
		tracks : {{string : any}}
		-- Extra "meta" records (key, value).
		meta : {string : string}
	end

	-- A capture in progress. The fields are internal.
	record Job
		tag : string
		logPrefix : string
		-- Terrain grid: point (1, 1) at (x0, y0), spacing metres apart, nx × ny points.
		x0 : number
		y0 : number
		spacing : number
		nx : integer
		ny : integer
		-- The next terrain line to write: its row and first column.
		nextRow : integer
		nextCol : integer
		chunksTotal : integer
		chunksDone : integer
		-- Octree tile centres, the next one, and the next component kind (1..3) to look up in it.
		tiles : {{number}}
		nextTile : integer
		nextKind : integer
		lookupsDone : integer
		-- Entities found (written up to pendingHead - 1), with their kind (1 construction, 2 town building, 3 edge).
		pending : {integer}
		pendingKind : {integer}
		pendingHead : integer
		-- Entities already queued (they show up in several tiles).
		seen : {integer : boolean}
		-- Records written, by record name, plus diagnostics ("failures", "noBox", "straight", "off", "water").
		counts : {string : integer}
		-- Set once the end record has been written.
		finished : boolean
		-- Progress never falls (entities found later add work).
		lastProgress : number
		stepCalls : integer
		-- Time spent in step calls, and the slowest single task, microseconds.
		totalUs : integer
		slowestUs : integer
		-- Wall time since start.
		clock : Clock
	end

	-- Writes the header (format version, dates, extent, terrain settings, grid), the towns and the track types, and
	-- sets up the rest. nil if the map's extent can't be found (logged).
	start : function(opts : Options) : Job
	-- Works for about budgetUs microseconds (at least one task); true when done. Each task runs in a pcall: a failed
	-- one is counted, logged once per kind and skipped. The call that finishes writes the end record and a summary.
	step : function(job : Job, budgetUs : integer) : boolean
	-- Share of the work done, 0 to 1, never falling.
	progress : function(job : Job) : number
	done : function(job : Job) : boolean
end
