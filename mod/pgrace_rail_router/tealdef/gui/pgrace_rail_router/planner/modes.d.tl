-- The two planning modes, and the track types' limits. Pure (no api.*).
global record PgraceRailRouterModes
	enum Mode
		"cheapest"
		"fastest"
	end

	-- A base track type (not its catenary variant), read from the game by survey.trackTypes.
	record TrackType
		-- Resource name, e.g. "standard.lua".
		name : string
		-- Display name.
		label : string
		-- Cost per metre of one track.
		cost : number
		-- Top speed, metres per second.
		speed : number
		maxSlopeBuild : number
		minCurveRadiusBuild : number
		-- Distance between parallel tracks, metres.
		trackDistance : number
		-- 0 means no limit.
		yearFrom : integer
		yearTo : integer
		-- The electrified variant's resource name; nil if none.
		catenary : string
		-- The year the electrified variant becomes available; 0 if always (or there is none).
		catenaryYearFrom : integer
	end

	-- What the planner works with. Extra costs are in metres of plain track.
	record Weights
		maxGrade : number
		minRadius : number
		-- The tightest curve the game builds for the track type (the guard on smoothing never goes below it).
		minBuildRadius : number
		-- The radius a leg's search falls back to where its turns spaced for minRadius don't fit (route.step): the
		-- Cheapest radius, the build minimum × 4, whose spacing is under a cell, so any move may turn. nil: minRadius
		-- (no fallback).
		minSearchRadius : number
		-- Over the grade limit, each step costs 1 + slopePenalty × (grade − maxGrade) / maxGrade times as much.
		slopePenalty : number
		-- Steps over water cost this many times as much (they need a bridge).
		bridgeFactor : number
		-- Extra cost per turn: turnPenalty × (22.5° steps)².
		turnPenalty : number
		roadCrossing : number
		trackCrossing : number
		-- Money per metre of double track.
		costPerMetre : number
		-- The height fit's cost: a metre of bridge or tunnel costs this many times a metre on the ground (more than the
		-- game charges, which the estimate uses: route.tl's BRIDGE_PRICE, TUNNEL_PRICE).
		bridgeCostFactor : number
		tunnelCostFactor : number
		-- Track more than this far above the ground is a bridge, more than tunnelBelow below it a tunnel (metres).
		bridgeAbove : number
		tunnelBelow : number
		-- Whether roads are crossed by a bridge (fastest) or on the level (cheapest). Existing track is always bridged.
		bridgeRoads : boolean
		-- The speed model (speed.tl): the most sideways acceleration a curve may ask of a train (m/s²: a curve of radius
		-- R allows sqrt(lateralAccel · R)), and the speed the line is planned for: the track's top speed, or what
		-- minRadius allows if less (m/s).
		lateralAccel : number
		topSpeed : number
		-- What a second of travel time lost to curves below minRadius is worth, in metres of plain track: Fastest
		-- weighs a leg's search radii by their paths' cost plus this times the time they lose (route.tl). 0: time is
		-- not priced (Cheapest).
		timeCost : number
	end

	-- A bridge or tunnel type, as plain data (survey.structureTypes).
	record StructureType
		-- The resource name (bridgeTypeRep / tunnelTypeRep), and its index there (BaseEdge.typeIndex).
		name : string
		index : integer
		-- Its place in the construction menu (menuCategory.categories[1].order), the first tie-break.
		order : integer
		cost : number
		-- Metres per second; 0 if the type sets none (the base tunnels).
		speedLimit : number
		-- 0 means no limit.
		yearFrom : integer
		yearTo : integer
		rail : boolean
		autoSelectable : boolean
	end

	-- The type the game's track tool would pick for track of `speed` in `year`, among the available, rail-carrying,
	-- auto-selectable types: the slowest at least that fast, else the fastest; equal speeds go to the first in the
	-- menu's order. nil if none.
	structureFor : function(types : {StructureType}, speed : number, year : integer) : StructureType

	isAvailable : function(t : TrackType, year : integer) : boolean
	isEverBuildable : function(t : TrackType) : boolean
	-- Fastest: the fastest available type. Cheapest: the fastest available type up to 60 m/s (so not high-speed),
	-- else the cheapest available. nil if none is available.
	defaultTrack : function(types : {TrackType}, year : integer, mode : Mode) : TrackType
	weights : function(mode : Mode, t : TrackType) : Weights
end
