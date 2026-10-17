local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo

local sl : PgraceRailRouterStationLayout = {}

local type Pt = PgraceRailRouterGeo.Pt
local type Layout = PgraceRailRouterStationLayout.Layout
local type Era = PgraceRailRouterStationLayout.Era
local type Module = PgraceRailRouterStationLayout.Module
local type Addons = PgraceRailRouterStationLayout.Addons

-- The station script's slots (modular_station.script.lua GetId, addSlot): row i across at local x = 5 i, module j
-- along at y = 40 j, each module 40 × 5 m. A track module's edges run from y − 20 to y + 20 (trainstationutil.lua
-- makeTrack). The two tracks (rows 1 and 2) are at x = 5 and 10, so the station's axis is at 7.5.
local AXIS_X = 7.5
local LEFT_X = 5.0
local RIGHT_X = 10.0
local MODULE_LENGTH = 40.0
-- The station script only makes slots for j from -10 to 10 (trainstationutil.lua stationYMin, stationYMax): at most
-- 21 modules, 840 m.
local MAX_MODULES = 21
local TRACK_SLOT = 8400000
local PASSENGER_PLATFORM_SLOT = 7400000
local MAIN_BUILDING_SLOT = 3400000
local ROOF_SLOT = 10400000
local STAIRS_SLOT = 10800000

function sl.trackSlot(i : integer, j : integer) : integer
	return TRACK_SLOT + 1000 * i + 10 * j
end

function sl.platformSlot(i : integer, j : integer) : integer
	return PASSENGER_PLATFORM_SLOT + 1000 * i + 10 * j
end

-- The station track module the base game generates for a track template (mod.script.tl TrackNameToModuleName,
-- modular_station.script.lua ResNameToModuleName): "::" becomes "__", after "::/trainstation_". Exactly so: a wrong
-- resource name in a proposal can crash the game.
function sl.trackModule(template : string) : string
	local name = template:gsub("::", "__")
	return "::/trainstation_" .. name
end

function sl.eraLetter(year : integer) : string
	if year >= 1990 then
		return "c"
	elseif year >= 1950 then
		return "b"
	end
	return "a"
end

-- The modules along (j from s to e) for a platform length: platformLength / 40 of them (at most MAX_MODULES),
-- k = count − 1, s = −floor(k / 2), e = ceil(k / 2). This is NOT what the base menu does: its createTemplateFn maps
-- the Length choice's index (80, 120, 160, 240, 320 m) through lmap = { 0, 1, 2, 3, 5, 7, 9 } to k, so its "160 m"
-- has k = 2, 3 modules (120 m of modules). Which count gives the platform length on the ground is for probe P6's
-- bounding box to settle.
local function range(platformLength : number) : integer, integer
	local count = math.min(MAX_MODULES, math.max(1, math.floor(platformLength / MODULE_LENGTH + 0.5)))
	local k = count - 1
	return -math.floor(k / 2), math.ceil(k / 2)
end

function sl.addons(platformLength : number, addons : Addons) : {integer : Module}
	local s, e = range(platformLength)
	local dist = e - s
	local modules : {integer : Module} = {}
	-- Main building 1 (fewer than 3 tracks), offset 0; k = 2 where the count along is even (e − s odd).
	local k = dist % 2 == 1 and 2 or 0
	modules[MAIN_BUILDING_SLOT + 10 * k] = { name = addons.building, variant = 0 }
	local centre = math.floor(dist / 2) + s
	for __, i in ipairs({ 0, 3 }) do
		for j = s, e do
			if j == centre or (dist > 3 and (j == s + 1 or j == e - 1)) then
				modules[STAIRS_SLOT + 1000 * i + 10 * j] = { name = addons.stairs, variant = 0 }
			end
			if addons.roof ~= nil and ((j ~= s and j ~= e) or dist <= 3) then
				modules[ROOF_SLOT + 1000 * i + 10 * j] = { name = addons.roof, variant = 0 }
			end
		end
	end
	return modules
end

-- atan2 from the one-argument math.atan: the game's Lua (5.2) ignores atan's second argument, and Lua 5.4 (the test
-- runner) has no math.atan2.
local function atan2(y : number, x : number) : number
	if x > 0 then
		return math.atan(y / x)
	elseif x < 0 then
		return math.atan(y / x) + (y >= 0 and math.pi or -math.pi)
	elseif y > 0 then
		return math.pi / 2
	elseif y < 0 then
		return -math.pi / 2
	end
	return 0
end

function sl.layout(centre : Pt, dir : Pt, platformLength : number, era : Era) : Layout
	-- platformLength / 40 modules along (see range), k = count − 1, j from s to e.
	local s, e = range(platformLength)
	local k = e - s
	local modules : {integer : Module} = {}
	for j = s, e do
		modules[sl.platformSlot(0, j)] = { name = era.platform, variant = 0 }
		modules[sl.trackSlot(1, j)] = { name = era.track, variant = 0 }
		modules[sl.trackSlot(2, j)] = { name = era.track, variant = 0 }
		modules[sl.platformSlot(3, j)] = { name = era.platform, variant = 0 }
	end
	-- Local +y is along dir, local +x to its right. With an odd count the platforms run from 40 s − 20 to 40 e + 20,
	-- centred on the origin; with an even count they're centred 20 m ahead of it, so the origin moves back 20 m.
	local localX : Pt = { x = dir.y, y = -dir.x }
	local origin = geo.sub(geo.sub(centre, geo.scale(localX, AXIS_X)), geo.scale(dir, MODULE_LENGTH / 2 * (k % 2)))
	local function world(x : number, y : number) : Pt
		return geo.add(geo.add(origin, geo.scale(localX, x)), geo.scale(dir, y))
	end
	local y0, y1 = MODULE_LENGTH * s - MODULE_LENGTH / 2, MODULE_LENGTH * e + MODULE_LENGTH / 2
	-- The track at x = 5 is the left of the two (network.tl's track 1).
	return {
		modules = modules,
		-- rotZ(angle) takes local +y, (0, 1), to (−sin angle, cos angle) = dir.
		angle = atan2(-dir.x, dir.y),
		origin = origin,
		ends = { world(LEFT_X, y0), world(RIGHT_X, y0), world(LEFT_X, y1), world(RIGHT_X, y1) },
	}
end

return sl
