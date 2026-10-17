-- The map capture format's records as text lines (docs/map-capture-format.md). Pure (no api.*): mapcapture.tl writes
-- through it, and the unit tests write synthetic maps through it for tools/maplib.lua to read back. Each function
-- returns one line without the log tag (mapcapture puts "<tag> " in front).
global record PgraceRailRouterMapFormat
	VERSION : integer
	-- Terrain grid spacing, metres.
	SPACING : number
	-- Grid points per terrain line (a row is split into lines of at most this many points).
	CHUNK : integer
	-- Per-point flags: on the map and dry, water, off the map (isValidCoordinate false).
	LAND : string
	WATER : string
	OFF : string

	record Vec3
		x : number
		y : number
		z : number
	end

	record Town
		id : integer
		name : string
		-- The town's bounding box (min and max corners); the centre is its middle.
		x0 : number
		y0 : number
		x1 : number
		y1 : number
	end

	record Obj
		id : integer
		-- "townbuilding", "station", "industry", "depot", "building" (a construction whose file is a building) or
		-- "other".
		kind : string
		-- Where the box came from: "own" (the entity's BOUNDING_VOLUME), "con" (its construction's) or "none" (no
		-- box; min and max are then nil).
		boxSource : string
		min : Vec3
		max : Vec3
		-- Town buildings: their construction and town entities; -1 for none.
		construction : integer
		town : integer
		-- The construction's fileName; nil for none.
		file : string
	end

	record Edge
		id : integer
		-- "s" street (has BASE_EDGE_STREET) or "t" track.
		kind : string
		-- "n" normal, "b" bridge, "u" tunnel, "?" unknown.
		edgeType : string
		node0 : integer
		node1 : integer
		p0 : Vec3
		p1 : Vec3
		-- nil: draw a straight line from p0 to p1 (the curve couldn't be read).
		t0 : Vec3
		t1 : Vec3
		-- The road template's resource name; nil if unreadable.
		template : string
	end

	begin : function() : string
	-- One line per key; the value may contain spaces.
	meta : function(key : string, value : string) : string
	extent : function(x0 : number, y0 : number, x1 : number, y1 : number, source : string) : string
	terrain : function(key : string, value : string) : string
	grid : function(spacing : number, x0 : number, y0 : number, nx : integer, ny : integer) : string
	-- Points ix, ix + 1, ... of row iy: heights in metres (written as whole decimetres, the first one absolute, the
	-- others as differences from the one before) and flags (LAND, WATER or OFF each, run-length encoded).
	row : function(iy : integer, ix : integer, heights : {number}, flags : {string}) : string
	town : function(t : Town) : string
	-- A track type as key=value pairs (keys sorted), as survey.trackTypes builds them.
	track : function(fields : {string : any}) : string
	obj : function(o : Obj) : string
	edge : function(e : Edge) : string
	-- The last line: the record counts by name (keys sorted).
	finish : function(counts : {string : integer}) : string

	-- Whole decimetres, rounded.
	decimetres : function(h : number) : integer
	-- "L128" or "L60W8L60": each run as its flag and its length.
	rle : function(flags : {string}) : string
end
