local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local tool_react_util = ug_require "::/gui/main/tool_react_util.tl" as ToolReactUtil
local game_react_globals = ug_require "::/gui/main/game_react_globals.tl" as GameReactGlobals
local main_mod_button_area = ug_require "::/gui/main/main_mod_button_area.tl" as MainModButtonArea
local modes = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/modes.tl" as PgraceRailRouterModes
local corridor = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/corridor.tl" as PgraceRailRouterCorridor
local route = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/route.tl" as PgraceRailRouterRoute
local survey = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/survey.tl" as PgraceRailRouterSurvey
local preview = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/preview.tl" as PgraceRailRouterPreview

local type Town = PgraceRailRouterCorridor.Town
local type Candidate = PgraceRailRouterCorridor.Candidate
local type TrackType = PgraceRailRouterModes.TrackType
local type Mode = PgraceRailRouterModes.Mode
local type Plan = PgraceRailRouterRoute.Plan
local type ToolParam = ToolReactUtil.IToolParam

local LOG_PREFIX = "[rail_router] "
-- The mod's name, a brand: not translated.
local MOD_NAME = "Rail Router"
local WINDOW_ID = "pgrace_rail_router_window"
local BUTTON_ICON = "::/gui/game_bar/icons/vehicle_train_30.tga"
-- Microseconds of survey or planning work per frame.
local BUDGET_US = 6000
-- Cells a leg's search expands per call between clock checks.
local EXPANSIONS_PER_CALL = 400
local CELL = 100.0
local SURVEY_MARGIN = 0.25
-- Towns adding at most this share of the direct distance are offered as stops.
local DETOUR_BUDGET = 0.15
local PLATFORMS : {integer} = { 80, 120, 160, 240, 320 }

local record Settings
	-- Town entities; -1 for none.
	from : integer
	to : integer
	mode : Mode
	-- Track type name; nil for the mode's default in the current year.
	track : string
	-- Not used by the planner: milestone 2's builder lays catenary with it. nil: ticked if the chosen track has an
	-- electrified variant.
	electrified : boolean
	platform : integer
	-- Candidate stops the player unticked, by town id.
	skipped : {integer : boolean}
end

-- Kept between openings until the game restarts or a save is loaded (the window's state starts fresh each time).
local remembered : Settings = { from = -1, to = -1, mode = "cheapest", electrified = nil, platform = 160, skipped = {} }

local record GameData
	towns : {Town}
	tracks : {TrackType}
	year : integer
	error : boolean
end

local record Work
	stops : {Town}
	weights : PgraceRailRouterModes.Weights
	platform : integer
	surveyJob : PgraceRailRouterSurvey.Job
	routeJob : PgraceRailRouterRoute.Job
	-- Timing diagnostics for the planning part (after the survey), logged when the plan is done: the slowest single
	-- route.step per phase ("sites", "legs") and the total, microseconds, and the frames it took.
	slowestStepUs : {string : integer}
	planUs : integer
	planFrames : integer
end

local record Progress
	-- "survey" or "plan"
	stage : string
	percent : integer
end

local nextGeneration = 0

local loggedJoinError : {string : boolean} = {}
-- react.enqueueJoin runs without a pcall, and a join can run just after its recipe unmounted (window closed
-- mid-plan): an error there would take down the whole UI.
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

local function fill(template : string, values : {string : string}) : string
	return (template:gsub("{(%w+)}", function(key : string) : string
		return values[key] or ("{" .. key .. "}")
	end))
end

local function textRow(text : string, class : string) : TreeNodeId
	return builtin.BoxLayout{
		children = {
			builtin.TextView{ meta = { class = class or "font-scale-body" }, text = text },
		},
	}
end

local function formatLength(metres : number) : string
	local ok, text = pcall(api.util.formatLength, metres)
	if ok and text ~= nil then
		return text as string
	end
	return tostring(math.floor(metres + 0.5)) .. " m"
end

local function formatMoney(amount : number) : string
	local ok, text = pcall(api.util.formatMoney, math.floor(amount + 0.5))
	if ok and text ~= nil then
		return text as string
	end
	return tostring(math.floor(amount + 0.5))
end

local function formatPercent(share : number) : string
	return fill(_("{percent}%"), { percent = string.format("%.1f", 100 * share) })
end

local function townById(towns : {Town}, id : integer) : Town
	for __, town in ipairs(towns) do
		if town.id == id then
			return town
		end
	end
	return nil
end

local function trackByName(tracks : {TrackType}, name : string) : TrackType
	for __, track in ipairs(tracks) do
		if track.name == name then
			return track
		end
	end
	return nil
end

local function toInteger(value : integer | number | string) : integer
	local n = tonumber(tostring(value))
	if n == nil then
		return nil
	end
	return math.floor(n)
end

local function labelled(label : string, widget : TreeNodeId) : TreeNodeId
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			builtin.TextView{ meta = { class = "font-scale-body" }, text = label },
			widget,
		},
	}
end

local function townCombo(towns : {Town}, value : integer, onChange : function(integer)) : TreeNodeId
	local items : {TreeNodeId} = {
		builtin.ComboBoxItem{ value = -1, content = builtin.TextView{ text = _("Choose a town") } },
	}
	for __, town in ipairs(towns) do
		table.insert(items, builtin.ComboBoxItem{ value = town.id, content = builtin.TextView{ text = town.name } })
	end
	return builtin.ComboBox{
		value = value,
		items = items,
		onValueChange = function(v : integer | number | string)
			local id = toInteger(v)
			if id ~= nil then
				onChange(id)
			end
		end,
	}
end

local function failureText(plan : Plan) : string
	local towns = plan.failureTowns or {}
	if plan.failure == "no_site" then
		return fill(_("No room for a station near the centre of {town} without demolishing anything."),
			{ town = towns[1] or "?" })
	elseif plan.failure == "no_path" then
		return fill(_("No route found from {from} to {to}."), { from = towns[1] or "?", to = towns[2] or "?" })
	elseif plan.failure == "too_close" then
		return fill(_("The stations in {from} and {to} would be too close together. Untick one of them or use shorter platforms."),
			{ from = towns[1] or "?", to = towns[2] or "?" })
	end
	return _("Choose two different towns.")
end

local function resultRows(plan : Plan) : {TreeNodeId}
	local rows : {TreeNodeId} = {}
	local sum = plan.summary
	table.insert(rows, textRow(fill(_("{length} of line · about {cost} for the track (our estimate)"),
		{ length = formatLength(sum.length), cost = formatMoney(sum.estimate) }), "font-scale-body"))
	table.insert(rows, textRow(fill(_("Bridges: {bridges} ({bridgeLength}) · Tunnels: {tunnels} ({tunnelLength})"), {
		bridges = tostring(sum.bridges), bridgeLength = formatLength(sum.bridgeLength),
		tunnels = tostring(sum.tunnels), tunnelLength = formatLength(sum.tunnelLength),
	}), "font-scale-body"))
	local curve = _("no curves")
	if sum.minRadius < math.huge then
		curve = formatLength(sum.minRadius)
	end
	table.insert(rows, textRow(fill(_("Steepest grade {grade} · tightest curve {radius}"),
		{ grade = formatPercent(sum.maxGrade), radius = curve }), "font-scale-body"))
	-- Warnings: the plan is still shown, but these parts need the player's attention.
	if sum.tightCurves > 0 then
		table.insert(rows, textRow(fill(_("Warning: {count} curves are tighter than this mode allows."),
			{ count = tostring(sum.tightCurves) }), "font-scale-body"))
	end
	if sum.steepLegs > 0 then
		table.insert(rows, textRow(fill(_("Warning: {count} stretches between stations climb more steeply than this mode allows."),
			{ count = tostring(sum.steepLegs) }), "font-scale-body"))
	end
	if sum.blockedSamples > 0 then
		table.insert(rows, textRow(_("Warning: the curves cut across buildings or existing track in places."), "font-scale-body"))
	end
	for __, station in ipairs(plan.stations) do
		table.insert(rows, textRow(fill(_("{town}: station {distance} from the centre"),
			{ town = station.town.name, distance = formatLength(station.site.distance) }), "font-scale-annotation"))
	end
	return rows
end

local record ContentParams
	gameCtx : GameContext
end

local Content = react.RegisterRecipe("PgraceRailRouterContent", function(params : ContentParams) : TreeNodeId
	local dataState = react.useStateLazy(function() : GameData
		local ok, dataOrError = pcall(function() : GameData
			return { towns = survey.towns(), tracks = survey.trackTypes(), year = survey.year(), error = false }
		end)
		if ok then
			return dataOrError as GameData
		end
		debugPrint(LOG_PREFIX .. "read error: " .. tostring(dataOrError))
		return { towns = {}, tracks = {}, year = 0, error = true }
	end)
	local data = dataState:old()
	local settingsState = react.useState(remembered) as ReactStateT<Settings>
	local settings = settingsState:old()
	local planState : ReactStateT<Plan> = react.useState(nil)
	local generationState = react.useState(0) as ReactStateT<integer>
	local showState = react.useState(false) as ReactStateT<boolean>
	local progressState : ReactStateT<Progress> = react.useState(nil)
	local errorState = react.useState(false) as ReactStateT<boolean>
	local workRef : ReactRefT<Work> = react.useRef(nil)
	-- A join is queued and hasn't run yet; at most one at a time.
	local joinQueuedRef : ReactRefT<boolean> = react.useRef(false)

	-- Copies from the latest state, not this render's `settings`, so two changes in one frame both stick: transform
	-- (as the base save-game page uses) hands us the newest value, even one set earlier in the same frame.
	local function setSettings(change : function(Settings))
		settingsState:transform(function(current : Settings) : Settings
			local copy : Settings = { from = current.from, to = current.to, mode = current.mode, track = current.track,
				electrified = current.electrified, platform = current.platform, skipped = current.skipped }
			change(copy)
			remembered = copy
			return copy
		end)
	end

	-- Every settings change drops the shown plan and any work in progress: a plan for other settings would mislead.
	local function update(change : function(Settings))
		setSettings(change)
		planState:set(nil)
		showState:set(false)
		workRef:set(nil)
		progressState:set(nil)
		errorState:set(false)
	end

	local fromTown = townById(data.towns, settings.from)
	local toTown = townById(data.towns, settings.to)
	local track = trackByName(data.tracks, settings.track) or modes.defaultTrack(data.tracks, data.year, settings.mode)
	local candidates : {Candidate} = {}
	if fromTown ~= nil and toTown ~= nil and fromTown.id ~= toTown.id then
		candidates = corridor.candidates(fromTown, toTown, data.towns, DETOUR_BUDGET)
	end

	local function findRoute()
		if fromTown == nil or toTown == nil or fromTown.id == toTown.id or track == nil then
			return
		end
		local picked : {Town} = {}
		for __, candidate in ipairs(candidates) do
			if not settings.skipped[candidate.town.id] then
				table.insert(picked, candidate.town)
			end
		end
		workRef:set({ stops = corridor.order(fromTown, toTown, picked), weights = modes.weights(settings.mode, track),
			platform = settings.platform, slowestStepUs = { sites = 0, legs = 0 }, planUs = 0, planFrames = 0 })
		planState:set(nil)
		showState:set(false)
		errorState:set(false)
		progressState:set({ stage = "survey", percent = 0 })
	end

	local function setProgress(stage : string, share : number)
		local percent = math.floor(100 * share)
		local old = progressState:old()
		if old == nil or old.stage ~= stage or old.percent ~= percent then
			progressState:set({ stage = stage, percent = percent })
		end
	end

	-- Engine reads (terrain, octree) and the planner run in joins on the main thread, BUDGET_US per frame, as Jam
	-- Session's scan: the window stays responsive and the game doesn't freeze.
	local function advance(work : Work)
		local clock = api.type.Clock.new()
		if work.surveyJob == nil then
			work.surveyJob = survey.start(work.stops, CELL, SURVEY_MARGIN)
			if work.surveyJob == nil then
				error("survey: no area to survey")
			end
		end
		if work.routeJob == nil then
			if survey.step(work.surveyJob, BUDGET_US) then
				work.routeJob = route.start({ grid = survey.grid(work.surveyJob), stops = work.stops,
					weights = work.weights, platformLength = work.platform })
				setProgress("plan", 0)
			else
				setProgress("survey", survey.progress(work.surveyJob))
			end
			return
		end
		local done = false
		local planStart = clock:getTime()
		work.planFrames = work.planFrames + 1
		repeat
			local phase = work.routeJob.phase
			local before = clock:getTime()
			done = route.step(work.routeJob, EXPANSIONS_PER_CALL)
			local took = clock:getTime() - before
			if took > (work.slowestStepUs[phase] or 0) then
				work.slowestStepUs[phase] = took
			end
			local used = clock:getTime()
			-- A step inside a leg's search is bounded by EXPANSIONS_PER_CALL, but the others (a station site, starting a
			-- search, building a leg's curves and heights) can be long: past half the budget, leave those to the next
			-- frame rather than overrun this one.
			local stop = used >= BUDGET_US or (used > BUDGET_US / 2 and work.routeJob.search == nil)
		until done or stop
		work.planUs = work.planUs + (clock:getTime() - planStart)
		if done then
			local plan = route.plan(work.routeJob)
			local length = plan.summary ~= nil and plan.summary.length or 0
			debugPrint(LOG_PREFIX .. "plan done: " .. (plan.ok and "ok" or tostring(plan.failure)) .. ", "
				.. tostring(math.floor(work.planUs / 1000)) .. " ms over " .. tostring(work.planFrames)
				.. " frames; slowest step sites " .. tostring(work.slowestStepUs.sites or 0) .. " us, legs "
				.. tostring(work.slowestStepUs.legs or 0) .. " us; length " .. tostring(math.floor(length))
				.. ", legs " .. tostring(plan.legs ~= nil and #plan.legs or 0))
			nextGeneration = nextGeneration + 1
			generationState:set(nextGeneration)
			planState:set(plan)
			workRef:set(nil)
			progressState:set(nil)
		else
			setProgress("plan", route.progress(work.routeJob))
		end
	end

	react.onStep(function()
		if workRef:get() == nil or joinQueuedRef:get() then
			return
		end
		joinQueuedRef:set(true)
		safeJoin(function()
			joinQueuedRef:set(false)
			local work = workRef:get()
			if work == nil then
				return
			end
			local ok, err = pcall(function() : boolean
				advance(work)
				return true
			end)
			if not ok then
				debugPrint(LOG_PREFIX .. "planning error: " .. tostring(err))
				workRef:set(nil)
				progressState:set(nil)
				errorState:set(true)
			end
		end, "PgraceRailRouterWork")
	end)

	local body : {TreeNodeId} = {}
	if data.error then
		table.insert(body, textRow(_("Couldn't read the map (see log)"), "font-scale-body"))
	end
	-- Combo values must match an item: a remembered town that isn't on this map shows "Choose a town".
	table.insert(body, labelled(_("From"), townCombo(data.towns, fromTown ~= nil and fromTown.id or -1, function(id : integer)
		update(function(s : Settings) s.from = id s.skipped = {} end)
	end)))
	table.insert(body, labelled(_("To"), townCombo(data.towns, toTown ~= nil and toTown.id or -1, function(id : integer)
		update(function(s : Settings) s.to = id s.skipped = {} end)
	end)))
	table.insert(body, labelled(_("Mode"), builtin.ComboBox{
		value = settings.mode,
		items = {
			builtin.ComboBoxItem{ value = "cheapest", content = builtin.TextView{ text = _("Cheapest") } },
			builtin.ComboBoxItem{ value = "fastest", content = builtin.TextView{ text = _("Fastest") } },
		},
		onValueChange = function(v : integer | number | string)
			-- The default track depends on the mode: a type the player didn't pick follows it.
			local mode = tostring(v)
			if mode == "cheapest" or mode == "fastest" then
				update(function(s : Settings) s.mode = mode as Mode end)
			end
		end,
	}))
	local trackItems : {TreeNodeId} = {}
	for __, t in ipairs(data.tracks) do
		table.insert(trackItems, builtin.ComboBoxItem{ value = t.name, content = builtin.TextView{ text = t.label },
			available = modes.isAvailable(t, data.year) })
	end
	if #trackItems == 0 then
		-- One item, so the value "" matches it.
		table.insert(trackItems, builtin.ComboBoxItem{ value = "", content = builtin.TextView{ text = _("No track available") } })
	end
	table.insert(body, labelled(_("Track"), builtin.ComboBox{
		value = track ~= nil and track.name or "",
		items = trackItems,
		onValueChange = function(v : integer | number | string)
			local name = tostring(v)
			if name ~= "" then
				update(function(s : Settings) s.track = name end)
			end
		end,
	}))
	-- Not used for planning (milestone 2's builder uses it), so changing it keeps the plan and any work in progress.
	local electrified = settings.electrified
	if electrified == nil then
		electrified = track ~= nil and track.catenary ~= nil
	end
	table.insert(body, builtin.CheckBox{
		label = _("Electrified"),
		value = electrified and 1 or 0,
		onValueChange = function(v : integer)
			setSettings(function(s : Settings) s.electrified = v == 1 end)
		end,
	})
	local platformItems : {TreeNodeId} = {}
	for __, length in ipairs(PLATFORMS) do
		table.insert(platformItems, builtin.ComboBoxItem{ value = length,
			content = builtin.TextView{ text = formatLength(length) } })
	end
	table.insert(body, labelled(_("Platforms"), builtin.ComboBox{
		value = settings.platform,
		items = platformItems,
		onValueChange = function(v : integer | number | string)
			local length = toInteger(v)
			if length ~= nil then
				update(function(s : Settings) s.platform = length end)
			end
		end,
	}))
	if #candidates > 0 then
		table.insert(body, textRow(_("Stops on the way:"), "font-scale-body"))
		for __, candidate in ipairs(candidates) do
			local id = candidate.town.id
			table.insert(body, builtin.CheckBox{
				label = fill(_("{town} (+{detour})"), { town = candidate.town.name, detour = formatLength(candidate.detour) }),
				value = settings.skipped[id] and 0 or 1,
				onValueChange = function(v : integer)
					update(function(s : Settings)
						local skipped : {integer : boolean} = {}
						for k, skip in pairs(s.skipped) do
							skipped[k] = skip
						end
						skipped[id] = v == 0 or nil
						s.skipped = skipped
					end)
				end,
			})
		end
	end
	table.insert(body, builtin.Button{
		content = builtin.TextView{ text = _("Find route") },
		onClick = findRoute,
	})
	if fromTown == nil or toTown == nil or fromTown.id == toTown.id then
		table.insert(body, textRow(_("Choose two different towns."), "font-scale-annotation"))
	elseif track == nil then
		table.insert(body, textRow(_("No track type is available yet."), "font-scale-annotation"))
	end

	local progress = progressState:old()
	if progress ~= nil then
		local template = progress.stage == "survey" and _("Surveying… {percent}%") or _("Planning… {percent}%")
		table.insert(body, textRow(fill(template, { percent = tostring(progress.percent) }), "font-scale-annotation"))
	end
	if errorState:old() then
		table.insert(body, textRow(_("Planning failed (see log)"), "font-scale-body"))
	end
	local plan = planState:old()
	if plan ~= nil then
		if not plan.ok then
			table.insert(body, textRow(failureText(plan), "font-scale-body"))
		else
			for __, row in ipairs(resultRows(plan)) do
				table.insert(body, row)
			end
			table.insert(body, builtin.ToggleButton{
				content = builtin.TextView{ text = _("Show on map") },
				value = showState:old() and 1 or 0,
				onValueChange = function(v : integer)
					showState:set(v == 1)
				end,
			})
			if showState:old() then
				-- A fixed key, so the progress line coming and going above it doesn't remount it.
				table.insert(body, preview.RouteAction{ meta = { localKey = "route" }, plan = plan,
					generation = generationState:old(), baseCtx = params.gameCtx })
			end
		end
	end

	return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = body }
end)

-- The tool machinery only reads gameCtx.windowContainer (and the button its tool stack); the mod-area plugin gets
-- no gameCtx, so build one from the game's defaults.
local function makeToolParam() : ToolParam
	local gameCtx = {
		windowContainer = game_react_globals.getDefaultWindowContainer(),
		toolStack = game_react_globals.getDefaultToolStack(),
	} as GameContext
	return { gameCtx = gameCtx }
end

local RailRouterWindow = react.RegisterWrapperRecipe("PgraceRailRouterWindow", builtin.Window, function(params : ToolReactUtil.IToolWindowParam<ToolParam>) : TreeNodeId
	return builtin.Window{
		meta = { class = "pgrace-rail-router" },
		id = WINDOW_ID,
		title = MOD_NAME,
		closable = true,
		onClose = params.onClose,
		content = Content{
			gameCtx = params.payload ~= nil and params.payload.toolParam ~= nil and params.payload.toolParam.gameCtx
				or makeToolParam().gameCtx,
		},
	}
end)

local RailRouterTool = tool_react_util.registerToolWithWindow("PgraceRailRouter", WINDOW_ID, RailRouterWindow)

local RailRouterButton = react.RegisterPluginRecipe(main_mod_button_area.MainModButtonAreaExtension, "PgraceRailRouterButton", function() : TreeNodeId
	return builtin.BoxLayout{
		children = {
			builtin.ToolButton{
				meta = { tooltip = _("Rail Router: plan a rail line between two towns") },
				toolDefinition = RailRouterTool,
				toolStack = game_react_globals.getDefaultToolStack(),
				content = builtin.ImageView{
					path = BUTTON_ICON,
					scaling = builtin.type.ImageViewScaling.AutoFit,
				},
				showFn = function()
					local ok, err = pcall(function() : boolean
						game_react_globals.getDefaultToolStackApi().push(RailRouterTool, nil, makeToolParam())
						return true
					end)
					if not ok then
						debugPrint(LOG_PREFIX .. "open failed: " .. tostring(err))
					end
				end,
				hideFn = function()
					pcall(function() : boolean
						game_react_globals.getDefaultToolStackApi().pop(RailRouterTool, nil)
						return true
					end)
				end,
			},
		},
	}
end)

debugPrint(LOG_PREFIX .. "script loaded")

return {
	RailRouterButton = RailRouterButton,
}
