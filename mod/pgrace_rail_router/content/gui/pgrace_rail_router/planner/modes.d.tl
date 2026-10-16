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
	end

	-- What the planner works with. Extra costs are in metres of plain track.
	record Weights
		maxGrade : number
		minRadius : number
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
		-- Cost estimate: a metre of bridge or tunnel costs this many times a metre on the ground.
		bridgeCostFactor : number
		tunnelCostFactor : number
		-- Track more than this far above the ground is a bridge, more than tunnelBelow below it a tunnel (metres).
		bridgeAbove : number
		tunnelBelow : number
		-- Whether roads are crossed by a bridge (fastest) or on the level (cheapest). Existing track is always bridged.
		bridgeRoads : boolean
	end

	isAvailable : function(t : TrackType, year : integer) : boolean
	-- Fastest: the fastest available type. Cheapest: the fastest available type up to 60 m/s (so not high-speed),
	-- else the cheapest available. nil if none is available.
	defaultTrack : function(types : {TrackType}, year : integer, mode : Mode) : TrackType
	weights : function(mode : Mode, t : TrackType) : Weights
end
