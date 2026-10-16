local modes : PgraceRailRouterModes = {}

local type TrackType = PgraceRailRouterModes.TrackType
local type Weights = PgraceRailRouterModes.Weights
local type Mode = PgraceRailRouterModes.Mode

-- Cheapest mode's default skips types faster than this (m/s): high-speed track costs 3× standard.
local CHEAPEST_MAX_SPEED = 60.0
-- Cheapest mode's curves: this many times the type's build minimum.
local CHEAPEST_RADIUS_FACTOR = 4.0
-- Fastest mode's curves: speed² / this (m/s² of sideways acceleration), at least the cheapest radius, at most
-- FASTEST_MAX_RADIUS. Starting values; tuned in milestone 4.
local FASTEST_LATERAL_ACCEL = 2.0
local FASTEST_MAX_RADIUS = 3000.0
local FASTEST_MAX_GRADE = 0.025

function modes.isAvailable(t : TrackType, year : integer) : boolean
	return (t.yearFrom == 0 or year >= t.yearFrom) and (t.yearTo == 0 or year < t.yearTo)
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

function modes.weights(mode : Mode, t : TrackType) : Weights
	local cheapestRadius = t.minCurveRadiusBuild * CHEAPEST_RADIUS_FACTOR
	if mode == "fastest" then
		local radius = math.max(cheapestRadius, t.speed * t.speed / FASTEST_LATERAL_ACCEL)
		return {
			maxGrade = math.min(FASTEST_MAX_GRADE, t.maxSlopeBuild),
			minRadius = math.min(FASTEST_MAX_RADIUS, radius),
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
		}
	end
	return {
		maxGrade = t.maxSlopeBuild,
		minRadius = cheapestRadius,
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
	}
end

return modes
