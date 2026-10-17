local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local game_react_globals = ug_require "::/gui/main/game_react_globals.tl" as GameReactGlobals
local selector_react_util = ug_require "::/gui/main/selector_react_util.tl" as SelectorReactUtil
local color_util = ug_require "::/gui/main/color_util.tl" as ColorUtil
local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo
local arrows = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/arrows.tl" as PgraceRailRouterArrows

local preview : PgraceRailRouterPreview = {}

local type Plan = PgraceRailRouterRoute.Plan
local type Params = PgraceRailRouterPreview.Params
local type FlowData = LayerConfig.CargoFlowRenderableConfig.FlowData

local LOG_PREFIX = "[rail_router] "
local ACTION_KEY = "pgrace_rail_router_route"
-- Arrows are drawn as arcs rising about 6% of their length, so long stretches are split into chords this long:
-- at 200 m the arches read as a bouncing route from a low camera.
local CHORD = 100.0
-- No arrow is shorter than this (metres; one sample step): the game's arrow drawing asserts on a very short one and
-- crashes to desktop (a 7 m bridge on NewGame2: "AddEveryNthPoint: (num)>=(2)", 1 < 2).
local MIN_ARROW = 25.0
-- Arrows sit this far above the track height, so the ground doesn't hide them (metres).
local LIFT = 3.0
-- Camera framing: distance as a multiple of the route's extent, clamped (focusPosition caps it near 4,055 m).
local CAMERA_FACTOR = 1.2
local CAMERA_MIN = 500.0
local CAMERA_MAX = 4000.0

-- The base cargo-flow colours are a gradient with this many stops; ours repeat one colour as often.
local layerColors = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/layers/layer_colors.gres")).data as LayerColors
-- (Counted through color_util.toArray4, as Jam Session reads them: the gres array itself may not support #.)
local GRADIENT_STOPS = math.max(1, #color_util.toArray4(layerColors.CargoFlow.Consumers3D.Actual))

local loggedJoinError : {string : boolean} = {}
-- react.enqueueJoin runs without a pcall, and a join can run just after its recipe unmounted.
local function safeJoin(fn : function(), scope : string)
	react.enqueueJoin(function()
		local ok, err = pcall(function() : boolean
			fn()
			return true
		end)
		if not ok and not loggedJoinError[scope] then
			loggedJoinError[scope] = true
			debugPrint(LOG_PREFIX .. scope .. " error: " .. tostring(err))
		end
	end, scope)
end

local function colours(r : number, g : number, b : number) : {Vec4f}
	local list : {Vec4f} = {}
	for i = 1, GRADIENT_STOPS do
		list[i] = api.type.Vec4f.new(r, g, b, 1.0)
	end
	return list
end

-- Built once: green on the ground, blue on bridges, orange in tunnels, white along platforms.
local GROUND = colours(0.35, 0.8, 0.35)
local STATION = colours(1.0, 1.0, 1.0)
local KIND_COLOURS : {string : {Vec4f}} = {
	ground = GROUND,
	bridge = colours(0.3, 0.6, 1.0),
	tunnel = colours(1.0, 0.6, 0.2),
}

local function makeLayerConfig(plan : Plan) : LayerConfig
	local passenger = api.res.cargoTypeRep.getPassengerCargoTypeId()
	local flows : {FlowData} = {}
	local function add(ax : number, ay : number, az : number, bx : number, by : number, bz : number, arrowColors : {Vec4f})
		local flow = api.type.LayerConfig.CargoFlowRenderableConfig.FlowData.new()
		flow.from = api.type.Vec3f.new(ax, ay, az + LIFT)
		flow.to = api.type.Vec3f.new(bx, by, bz + LIFT)
		flow.speed = 0
		flow.arrowColors = arrowColors
		flow.cargoIconAlpha = 0
		flow.cargoTypes = { passenger }
		table.insert(flows, flow)
	end
	for __, leg in ipairs(plan.legs) do
		for __, arrow in ipairs(arrows.split(leg, CHORD, MIN_ARROW)) do
			local p, q = leg.samples[arrow.i].p, leg.samples[arrow.j].p
			add(p.x, p.y, leg.z[arrow.i], q.x, q.y, leg.z[arrow.j], KIND_COLOURS[arrow.kind] or GROUND)
		end
	end
	for __, station in ipairs(plan.stations) do
		local half = geo.scale(station.site.dir, plan.platformLength / 2)
		local a, b = geo.sub(station.site.centre, half), geo.add(station.site.centre, half)
		add(a.x, a.y, station.z, b.x, b.y, station.z, STATION)
	end
	local cargoFlow = api.type.LayerConfig.CargoFlowRenderableConfig.new()
	cargoFlow.flowData = flows
	local layerConfig = api.type.LayerConfig.new()
	layerConfig.cargoFlowRenderableConfig = cargoFlow
	return layerConfig
end

-- Main thread only.
local function frameCamera(plan : Plan)
	local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
	local function include(c : PgraceRailRouterGeo.Pt)
		minX, maxX = math.min(minX, c.x), math.max(maxX, c.x)
		minY, maxY = math.min(minY, c.y), math.max(maxY, c.y)
	end
	local z = 0.0
	for __, station in ipairs(plan.stations) do
		include(station.site.centre)
		z = z + station.z / #plan.stations
	end
	if #plan.stations == 0 then
		return
	end
	-- The whole track, not just the stations: a detour can swing well outside them.
	for __, leg in ipairs(plan.legs) do
		for __, sample in ipairs(leg.samples) do
			include(sample.p)
		end
	end
	local extent = math.max(maxX - minX, maxY - minY)
	local distance = math.min(CAMERA_MAX, math.max(CAMERA_MIN, extent * CAMERA_FACTOR))
	api.gui.camera.focusPosition(api.type.Vec3f.new(0.5 * (minX + maxX), 0.5 * (minY + maxY), z), distance)
end

-- The renderer API has this, but the type definitions don't. Clearing it with `false` hands the map back.
local record ActiveOwnerApi
	setActiveOwnerOverride : function(ReactRefWrap | boolean)
end

-- The selector reads filters from the game context; the window gets none. Module-level, not hooks: the renderer
-- calls into the action for a moment after our recipe unmounts (AGENTS.md, Jam Session).
local mapFilters : GameContext.Filters = {
	menuFilter = { enabledItems = {}, disabledItems = {}, disabledParams = {} },
	vehicleFilter = { enabledVehicles = {}, disabledVehicles = {} },
	protectedEntities = {},
	selectorEntityFilter = {},
}
local record FiltersRef
	get : function(FiltersRef) : GameContext.Filters
	set : function(FiltersRef, GameContext.Filters)
end
local mapFiltersRef : FiltersRef = {
	get = function(__ : FiltersRef) : GameContext.Filters return mapFilters end,
	set = function(__ : FiltersRef, filters : GameContext.Filters) mapFilters = filters end,
}

-- No accessNotificationCacheFn: a lookup there runs on worker threads and crashed Jam Session twice.
local function mapGameContext(base : GameContext) : GameContext
	return {
		rendererComponent = game_react_globals.getDefaultRendererComponent(),
		windowContainer = base.windowContainer,
		toolStack = base.toolStack,
		filters = mapFiltersRef as any as ReactRefT<GameContext.Filters>,
	} as GameContext
end

-- The map while the window is open and no route is shown: the game's own HUD (town names, station and vehicle icons)
-- and click-to-select. A tool window that sets no action gets an empty map, without town names.
function preview.makeMapAction(baseCtx : GameContext) : function() : TreeNodeId
	return selector_react_util.makeDefaultSelectorAction(mapGameContext(baseCtx))
end

local record Cache
	key : string
	action : function() : TreeNodeId
end

preview.RouteAction = react.RegisterRecipe("PgraceRailRouterRouteAction", function(params : Params) : TreeNodeId
	local gameCtx = mapGameContext(params.baseCtx)
	local key = ACTION_KEY .. ":" .. tostring(params.generation)
	local cacheRef : ReactRefT<Cache> = react.useRef(nil)
	local frameRef : ReactRefT<boolean> = react.useRef(false)
	local changed = cacheRef:get() == nil or cacheRef:get().key ~= key
	if changed then
		local ok, layerOrError = pcall(makeLayerConfig, params.plan)
		local action : function() : TreeNodeId = nil
		if ok then
			action = selector_react_util.makeDefaultSelectorAction(gameCtx, layerOrError as LayerConfig)
			frameRef:set(true)
		else
			debugPrint(LOG_PREFIX .. "preview error: " .. tostring(layerOrError))
		end
		cacheRef:set({ key = key, action = action })
	end
	react.onStep(function()
		if frameRef:get() then
			frameRef:set(false)
			safeJoin(function()
				frameCamera(params.plan)
			end, "PgraceRailRouterFrameCamera")
		end
	end)

	local selfRef = react.useAction(gameCtx.rendererComponent, cacheRef:get().action, key)

	local function setOverride(owner : ReactRefWrap | boolean) : boolean
		local rendererComponent = gameCtx.rendererComponent
		if rendererComponent == nil or rendererComponent:hasExpired() then
			return false
		end
		local rc = rendererComponent:get()
		if rc == nil or not rc:getIdentity() then
			return false
		end
		local rcApi = rc:getApi() as any as ActiveOwnerApi
		if rcApi.setActiveOwnerOverride == nil then
			return false
		end
		rcApi.setActiveOwnerOverride(owner)
		return true
	end

	-- Only with an action bound: taking over the map without one would leave it ownerless.
	local function activate()
		if cacheRef:get().action ~= nil then
			setOverride(selfRef)
		end
	end

	react.onMount(activate)
	if changed and selfRef:get() ~= nil then
		if cacheRef:get().action ~= nil then
			activate()
		else
			-- The rebuild failed: hand the map back rather than leave the previous plan's override in place.
			setOverride(false)
		end
	end
	react.onUnmount(function()
		setOverride(false)
	end)

	return builtin.BoxLayout{ children = {} }
end)

return preview
