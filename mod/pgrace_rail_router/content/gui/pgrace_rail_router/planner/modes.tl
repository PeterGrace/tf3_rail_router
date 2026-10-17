local modes : PgraceRailRouterModes = {}

local type TrackType = PgraceRailRouterModes.TrackType
local type Weights = PgraceRailRouterModes.Weights
local type Mode = PgraceRailRouterModes.Mode
local type StructureType = PgraceRailRouterModes.StructureType

-- Cheapest mode's default skips types faster than this (m/s): high-speed track costs 3× standard.
local CHEAPEST_MAX_SPEED = 60.0
-- Cheapest mode's curves: this many times the type's build minimum.
local CHEAPEST_RADIUS_FACTOR = 4.0
-- Fastest mode's curves: speed² / this (m/s² of sideways acceleration), at least the cheapest radius, at most
-- FASTEST_MAX_RADIUS. Starting values; tuned in milestone 4.
local FASTEST_LATERAL_ACCEL = 2.0
local FASTEST_MAX_RADIUS = 3000.0
local FASTEST_MAX_GRADE = 0.025
-- Fastest: what a second of travel time lost to curves below its radius is worth, in metres of plain track (see
-- Weights.timeCost and route.tl's choice of search radius). A starting value, tuned on the regression maps.
local FASTEST_TIME_COST = 50.0

function modes.isAvailable(t : TrackType, year : integer) : boolean
	return (t.yearFrom == 0 or year >= t.yearFrom) and (t.yearTo == 0 or year < t.yearTo)
end

-- Templates that are never offered to the player: depot and industry tracks (yearFrom 100000) and tracks that
-- belong to station mods (yearTo at or before yearFrom, e.g. 1800–1800).
local NEVER_YEAR = 100000

function modes.isEverBuildable(t : TrackType) : boolean
	return t.yearFrom < NEVER_YEAR and (t.yearTo == 0 or t.yearTo > t.yearFrom)
end

function modes.defaultTrack(types : {TrackType}, year : integer, mode : Mode) : TrackType
	local best : TrackType = nil
	for __, t in ipairs(types) do
		if modes.isAvailable(t, year) and (mode == "fastest" or t.speed <= CHEAPEST_MAX_SPEED) then
			if best == nil or t.speed > best.speed then
				best = t
			end
		end
	end
	if best == nil then
		for __, t in ipairs(types) do
			if modes.isAvailable(t, year) and (best == nil or t.cost < best.cost) then
				best = t
			end
		end
	end
	return best
end

-- The construction menu's order (menu_category_util.tl filterObjectLess): menu order, then yearFrom, then yearTo
-- (0, no end, last), then index.
local function menuBefore(a : StructureType, b : StructureType) : boolean
	if a.order ~= b.order then
		return a.order < b.order
	end
	if a.yearFrom ~= b.yearFrom then
		return a.yearFrom < b.yearFrom
	end
	if a.yearTo ~= b.yearTo then
		if a.yearTo == 0 then
			return false
		end
		if b.yearTo == 0 then
			return true
		end
		return a.yearTo < b.yearTo
	end
	return a.index < b.index
end

-- As the track tool's default bridge and tunnel (construction_react_util.tl makeFilterObjectsFn): over the menu's
-- available types that carry rail and may be picked automatically, the one whose speed limit is closest above the
-- track's speed, else closest below it. Not the cheapest: the base types' costs don't follow their speeds.
function modes.structureFor(types : {StructureType}, speed : number, year : integer) : StructureType
	local available : {StructureType} = {}
	for __, ty in ipairs(types) do
		-- The menu's availability test (menu_category_util.tl getAvailableObjectsSorted).
		if ty.rail and ty.autoSelectable and (ty.yearFrom == 0 or ty.yearFrom <= year)
			and (ty.yearTo == 0 or year < ty.yearTo) then
			table.insert(available, ty)
		end
	end
	table.sort(available, menuBefore)
	local above, below : StructureType, StructureType = nil, nil
	for __, ty in ipairs(available) do
		if ty.speedLimit >= speed then
			if above == nil or ty.speedLimit < above.speedLimit then
				above = ty
			end
		elseif below == nil or ty.speedLimit > below.speedLimit then
			below = ty
		end
	end
	return above or below
end

function modes.weights(mode : Mode, t : TrackType) : Weights
	local cheapestRadius = t.minCurveRadiusBuild * CHEAPEST_RADIUS_FACTOR
	if mode == "fastest" then
		local radius = math.min(FASTEST_MAX_RADIUS, math.max(cheapestRadius, t.speed * t.speed / FASTEST_LATERAL_ACCEL))
		return {
			maxGrade = math.min(FASTEST_MAX_GRADE, t.maxSlopeBuild),
			minRadius = radius,
			minBuildRadius = t.minCurveRadiusBuild,
			minSearchRadius = cheapestRadius,
			slopePenalty = 1.5,
			bridgeFactor = 3.0,
			turnPenalty = 150.0,
			roadCrossing = 300.0,
			trackCrossing = 400.0,
			costPerMetre = 2 * t.cost,
			bridgeCostFactor = 5.0,
			tunnelCostFactor = 8.0,
			bridgeAbove = 8.0,
			tunnelBelow = 12.0,
			bridgeRoads = true,
			lateralAccel = FASTEST_LATERAL_ACCEL,
			topSpeed = math.min(t.speed, math.sqrt(FASTEST_LATERAL_ACCEL * radius)),
			timeCost = FASTEST_TIME_COST,
		}
	end
	return {
		maxGrade = t.maxSlopeBuild,
		minRadius = cheapestRadius,
		minBuildRadius = t.minCurveRadiusBuild,
		minSearchRadius = cheapestRadius,
		slopePenalty = 3.0,
		bridgeFactor = 6.0,
		turnPenalty = 20.0,
		roadCrossing = 50.0,
		trackCrossing = 400.0,
		costPerMetre = 2 * t.cost,
		bridgeCostFactor = 5.0,
		tunnelCostFactor = 8.0,
		bridgeAbove = 8.0,
		tunnelBelow = 12.0,
		bridgeRoads = false,
		lateralAccel = FASTEST_LATERAL_ACCEL,
		topSpeed = math.min(t.speed, math.sqrt(FASTEST_LATERAL_ACCEL * cheapestRadius)),
		timeCost = 0,
	}
end

return modes
