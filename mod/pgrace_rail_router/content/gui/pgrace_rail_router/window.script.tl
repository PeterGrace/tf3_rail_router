local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local tool_react_util = ug_require "::/gui/main/tool_react_util.tl" as ToolReactUtil
local game_react_globals = ug_require "::/gui/main/game_react_globals.tl" as GameReactGlobals
local main_mod_button_area = ug_require "::/gui/main/main_mod_button_area.tl" as MainModButtonArea
local modes = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/modes.tl" as PgraceRailRouterModes
local corridor = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/corridor.tl" as PgraceRailRouterCorridor
local route = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/route.tl" as PgraceRailRouterRoute
local survey = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/survey.tl" as PgraceRailRouterSurvey
local area = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/area.tl" as PgraceRailRouterArea
local preview = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/preview.tl" as PgraceRailRouterPreview
local mapcapture = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/mapcapture.tl" as PgraceRailRouterMapCapture
local builder = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/builder.tl" as PgraceRailRouterBuilder
local build = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/build.tl" as PgraceRailRouterBuild
local network = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/network.tl" as PgraceRailRouterNetwork
local sl = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/stationlayout.tl" as PgraceRailRouterStationLayout
local probe = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/probe.tl" as PgraceRailRouterProbe -- PROBE (remove before release)

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
local EXPANSIONS_PER_CALL = 150
local CELL = 100.0
-- The surveyed area is the stops' bounding box grown by this share of its larger side, cut to the map; when a leg
-- finds no path, the work starts over with it doubled, up to MAX_RETRIES times (0.25, 0.5, 1.0), while that gives a
-- bigger area.
local SURVEY_MARGIN = 0.25
local MAX_RETRIES = 2
-- Towns adding at most this share of the direct distance on their own are offered as stops; those ticked by default
-- add at most this share together (corridor.select).
local DETOUR_BUDGET = 0.15
local PLATFORMS : {integer} = { 80, 120, 160, 240, 320 }
-- Check with the game: problems listed at most, then "and N more".
local MAX_PROBLEMS = 8

local record Settings
	-- Town entities; -1 for none.
	from : integer
	to : integer
	mode : Mode
	-- Track type name; nil for the mode's default in the current year.
	track : string
	-- Not used by the planner: milestone 2's builder lays catenary with it. nil: ticked if the chosen track has an
	-- electrified variant available in the current year.
	electrified : boolean
	platform : integer
	-- The player's ticks on candidate stops, by town id, over the default (corridor.select's towns ticked): true
	-- ticked, false unticked, nil the default. Cleared when From or To changes.
	ticked : {integer : boolean}
end

-- "Show all towns" in the stop list, kept until the game restarts.
local rememberedShowAll = false
-- Whether the station list and (PROBE) the dev tools are unfolded, kept between openings like the settings.
local rememberedStations = false
local rememberedProbes = false -- PROBE (remove before release)
-- Unticked candidates listed besides the ticked ones while the list is short.
local EXTRA_STOPS = 5

-- Kept between openings until the game restarts or a save is loaded (the window's state starts fresh each time).
local remembered : Settings = { from = -1, to = -1, mode = "cheapest", electrified = nil, platform = 160, ticked = {} }

local record GameData
	towns : {Town}
	tracks : {TrackType}
	year : integer
	error : boolean
end

local record Work
	stops : {Town}
	-- The track type planned for (the plan's estimate is priced with the game's price for it when the plan is done).
	track : TrackType
	weights : PgraceRailRouterModes.Weights
	platform : integer
	-- The survey margin in use, and how many times the work was started over with a wider one.
	margin : number
	retries : integer
	-- The map's extent, read on the first survey (the area is cut to it); nil if unknown.
	bounds : PgraceRailRouterArea.Bounds
	boundsRead : boolean
	surveyJob : PgraceRailRouterSurvey.Job
	routeJob : PgraceRailRouterRoute.Job
	-- Timing diagnostics for the planning part (after the survey) of the current attempt, logged when the plan is
	-- done: the slowest single route.step per kind (route.stepKind: "sites", "scout", "turn", and in the legs phase
	-- "search", "simplify", "fit", "heights", "resite") and in the legs phase as a whole ("legs"), and the total,
	-- microseconds, and the frames it took; the most a single step allocated (KB, from collectgarbage) and its kind.
	-- Reset on each retry.
	slowestStepUs : {string : integer}
	planUs : integer
	planFrames : integer
	maxStepKB : number
	maxStepKind : string
end

-- PROBE (remove before release): a whole-map capture in progress; job is nil until the first join starts it (its
-- engine reads belong on the main thread, not in the click handler).
local record CaptureWork
	job : PgraceRailRouterMapCapture.Job
end

-- Check with the game: the plan and the choices it was asked for; check is nil until the first join starts it (the
-- settings read the game's bridge and tunnel types, on the main thread).
local record CheckWork
	plan : Plan
	track : TrackType
	electrified : boolean
	-- The plan crosses roads on the level (its mode doesn't bridge them).
	levelCrossings : boolean
	check : PgraceRailRouterBuilder.Check
end

-- PROBE (remove before release): a probe in progress: its name ("P1" ... "P6"), the choices its settings are made
-- from, and its tasks (nil until the first join asks the probe for them), run one per join.
local record ProbeWork
	name : string
	track : TrackType
	electrified : boolean
	tasks : {function()}
	next : integer
end

local record Progress
	-- "survey" or "plan"
	stage : string
	percent : integer
	-- A retry with a wider survey after "no path".
	widening : boolean
	-- While planning, what is being done (see planDetail): the bar alone can stand still for seconds.
	detail : string
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

-- What the planner is doing, shown beside its progress: its share of the work can stand still for seconds where a
-- leg is much harder than the others (re-siting a station, a radius that finds no path).
local function planDetail(job : PgraceRailRouterRoute.Job) : string
	local kind = route.stepKind(job)
	if kind == "sites" then
		return _("finding station sites")
	elseif kind == "scout" or kind == "turn" then
		return _("lining up the stations")
	elseif kind == "done" then
		return nil
	end
	local legs = { leg = tostring(job.legIndex), legs = tostring(#job.input.stops - 1) }
	if kind == "resite" then
		return fill(_("leg {leg} of {legs}, trying other station sites"), legs)
	end
	return fill(_("leg {leg} of {legs}"), legs)
end

-- The track template built: the electrified variant when ticked and available in `year`, else the track type's own.
local function templateFor(track : TrackType, electrified : boolean, year : integer) : string
	if electrified and track.catenary ~= nil and (track.catenaryYearFrom == 0 or year >= track.catenaryYearFrom) then
		return track.catenary
	end
	return track.name
end

-- The builder's settings for the window's choices: the track template (its electrified variant when ticked and
-- available), its speed, the year, the bridge and tunnel types the game would pick (nil where none is available),
-- the station's modules for the year's era (the station script's getEra), and whether streets the track collides with
-- are level crossings. Main thread: reads the game's types.
local function settingsFor(track : TrackType, electrified : boolean, year : integer, levelCrossings : boolean)
		: PgraceRailRouterBuilder.Settings
	local name = templateFor(track, electrified, year)
	local function structure(which : string) : PgraceRailRouterModes.StructureType
		local ok, result = pcall(function() : PgraceRailRouterModes.StructureType
			return modes.structureFor(survey.structureTypes(which), track.speed, year)
		end)
		if not ok then
			debugPrint(LOG_PREFIX .. which .. " types: " .. tostring(result))
			return nil
		end
		return result as PgraceRailRouterModes.StructureType
	end
	local era = sl.eraLetter(year)
	local dir = "::/stations/rail/modular_station/"
	return {
		track = name, speed = track.speed, year = year,
		bridge = structure("bridge"), tunnel = structure("tunnel"),
		normalTypeIndex = -1,
		era = { platform = dir .. "platform_passenger_era_" .. era .. ".module", track = sl.trackModule(name) },
		addons = { building = dir .. "main_building_1_era_" .. era .. ".module",
			stairs = dir .. "addon_platform_passenger_stairs_era_" .. era .. ".module" },
		network = network.defaults(),
		levelCrossings = levelCrossings,
	}
end

-- The year for the builder's settings: read again (on the main thread), else the one read when the window opened.
local function currentYear(fallback : integer) : integer
	local year = survey.year()
	if year == nil or year <= 0 then
		return fallback
	end
	return year
end

-- Where a check's outcome is, for the window: the station's town, or how far along the line its chunk starts.
local function outcomePlace(check : PgraceRailRouterBuilder.Check, outcome : PgraceRailRouterBuilder.Outcome) : string
	if outcome.item.kind == "station" then
		local station = check.plan.stations[outcome.item.index]
		return fill(_("Station {town}"), { town = station ~= nil and station.town ~= nil and station.town.name or "?" })
	end
	local chunk = check.net.chunks[outcome.item.index]
	-- The legs run between platform ends: the platforms of the stations passed (one per leg before this one, and
	-- the leg's own first station) count too.
	local s = check.net.edges[chunk.first].s0 + chunk.leg * (check.plan.platformLength or 0)
	for i = 1, chunk.leg - 1 do
		s = s + (check.plan.legs[i].length or 0)
	end
	return fill(_("Track near km {km}"), { km = string.format("%.1f", s / 1000) })
end

local function textRow(text : string, class : string) : TreeNodeId
	return builtin.BoxLayout{
		children = {
			builtin.TextView{ meta = { class = class or "font-scale-body" }, text = text },
		},
	}
end

-- A row that shows or hides what follows it: the combobox arrow (down when shown) and a label.
local function expander(expanded : boolean, label : string, onClick : function()) : TreeNodeId
	return builtin.Button{
		content = builtin.BoxLayout{
			orientation = builtin.type.Orientation.Horizontal,
			children = {
				builtin.ImageView{ path = expanded and "::/gui/builtin/combobox/arrow_down.tga"
					or "::/gui/builtin/combobox/arrow_right.tga" },
				builtin.TextView{ text = label },
			},
		},
		onClick = onClick,
	}
end

-- What a collision was with, for the window.
local function collidedWith(what : string) : string
	if what == "street" then
		return _("a street")
	elseif what == "track" then
		return _("track")
	elseif what == "node" then
		return _("a street")
	elseif what == "junction" then
		return _("a road junction")
	elseif what == "building" then
		return _("a building")
	elseif what == "construction" then
		return _("a station or other construction")
	end
	return _("something")
end

-- One problem from the check: where, the game's messages and what the track or station ran into (streets left out
-- where others are there too), and a button that moves the camera to it (the first thing hit that isn't a street,
-- else the first thing hit, else the outcome's own place).
local function problemRow(check : PgraceRailRouterBuilder.Check, outcome : PgraceRailRouterBuilder.Outcome) : TreeNodeId
	local whats : {string} = {}
	local named : {string : boolean} = {}
	local target : PgraceRailRouterBuilder.Collision = nil
	for __, c in ipairs(outcome.collisions or {}) do
		-- Streets are level crossings there, counted on their own line.
		if outcome.crossings > 0 and (c.what == "street" or c.what == "node") then
			-- skip
		elseif not named[c.what] then
			named[c.what] = true
			table.insert(whats, collidedWith(c.what))
		end
		if c.x ~= nil and (target == nil or (target.what == "street" and c.what ~= "street")) then
			target = c
		end
	end
	local text = fill(_("{what}: {messages}"), { what = outcomePlace(check, outcome),
		messages = table.concat(outcome.messages, "; ") })
	if #whats > 0 then
		text = fill(_("{problem} with {things}"), { problem = text, things = table.concat(whats, ", ") })
	end
	local x, y = outcome.x, outcome.y
	if target ~= nil then
		x, y = target.x, target.y
	end
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			builtin.TextView{ meta = { class = "font-scale-annotation" }, text = text },
			builtin.Button{
				content = builtin.TextView{ meta = { class = "font-scale-annotation" }, text = _("Show") },
				onClick = function()
					local ok, err = pcall(function() : boolean
						local z = 0.0
						pcall(function() : boolean
							z = api.engine.terrain.getHeightAt(api.type.Vec2f.new(x, y))
							return true
						end)
						api.gui.camera.focusPosition(api.type.Vec3f.new(x, y, z), 300)
						return true
					end)
					if not ok then
						debugPrint(LOG_PREFIX .. "show problem: " .. tostring(err))
					end
				end,
			},
		},
	}
end

-- Candidate stops with a smaller detour than this are shown as "on the way" (metres).
local ON_THE_WAY = 50.0

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
	elseif plan.failure == "no_exit" then
		return fill(_("There's no way out of the station site in {town}: buildings surround it. Try another stop."),
			{ town = towns[1] or "?" })
	elseif plan.failure == "no_path" then
		return fill(_("No route found from {from} to {to}."), { from = towns[1] or "?", to = towns[2] or "?" })
	elseif plan.failure == "too_close" then
		return fill(_("The stations in {from} and {to} would be too close together or facing apart. Try other stops or shorter platforms."),
			{ from = towns[1] or "?", to = towns[2] or "?" })
	end
	return _("Choose two different towns.")
end

-- priceFactor scales the plan's estimate, made with the track type's listed price, to what the game charges for
-- the track to be built (pricesFor).
local function resultRows(plan : Plan, priceFactor : number) : {TreeNodeId}
	local rows : {TreeNodeId} = {}
	local sum = plan.summary
	table.insert(rows, textRow(fill(_("{length} of line · about {cost} for the track (our estimate)"),
		{ length = formatLength(sum.length), cost = formatMoney(sum.estimate * priceFactor) }), "font-scale-body"))
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
		table.insert(rows, textRow(_("Warning: the curves cut across buildings in places."), "font-scale-body"))
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
	-- The game's price for a metre of double track, by track template (plain and electrified), dry-run at the plan's
	-- first station when it's done; the estimate is scaled by it.
	local priceState : ReactStateT<{string : number}> = react.useState({})
	local generationState = react.useState(0) as ReactStateT<integer>
	local showAllState = react.useState(rememberedShowAll) as ReactStateT<boolean>
	local stationsState = react.useState(rememberedStations) as ReactStateT<boolean>
	local probesState = react.useState(rememberedProbes) as ReactStateT<boolean> -- PROBE (remove before release)
	local showState = react.useState(false) as ReactStateT<boolean>
	local progressState : ReactStateT<Progress> = react.useState(nil)
	local errorState = react.useState(false) as ReactStateT<boolean>
	local workRef : ReactRefT<Work> = react.useRef(nil)
	local captureRef : ReactRefT<CaptureWork> = react.useRef(nil) -- PROBE (remove before release)
	-- PROBE (remove before release): the capture's percentage while it runs, and its outcome once it's over.
	local capturePercentState : ReactStateT<integer> = react.useState(nil)
	local captureResultState : ReactStateT<string> = react.useState(nil)
	-- Check with the game: in progress (nil when none runs), how far it is (items done), and the finished check, or
	-- that it failed.
	local checkRef : ReactRefT<CheckWork> = react.useRef(nil)
	local checkDoneState : ReactStateT<integer> = react.useState(nil)
	local checkState : ReactStateT<PgraceRailRouterBuilder.Check> = react.useState(nil)
	local checkErrorState = react.useState(false) as ReactStateT<boolean>
	-- PROBE (remove before release): the probe running (nil when none), and the last one's outcome for the window.
	local probeRef : ReactRefT<ProbeWork> = react.useRef(nil)
	local probeStatusState : ReactStateT<string> = react.useState(nil)
	-- A join is queued and hasn't run yet; at most one at a time.
	local joinQueuedRef : ReactRefT<boolean> = react.useRef(false)
	-- Build (milestone 3): the build of the checked plan (nil before Build is clicked), and what the window last
	-- showed of it ("phase:done"), set each step so the window redraws as it goes.
	local buildRef : ReactRefT<PgraceRailRouterBuild.Build> = react.useRef(nil)
	local buildViewState : ReactStateT<string> = react.useState(nil)

	-- Copies from the latest state, not this render's `settings`, so two changes in one frame both stick: transform
	-- (as the base save-game page uses) hands us the newest value, even one set earlier in the same frame.
	local function setSettings(change : function(Settings))
		settingsState:transform(function(current : Settings) : Settings
			local copy : Settings = { from = current.from, to = current.to, mode = current.mode, track = current.track,
				electrified = current.electrified, platform = current.platform, ticked = current.ticked }
			change(copy)
			remembered = copy
			return copy
		end)
	end

	-- Drops a check with the game, running or done: it was for another plan or other settings.
	-- A build under way: commands are in flight, so the plan and settings stay as they are until it's over.
	local function building() : boolean
		local b = buildRef:get()
		return b ~= nil and b.phase ~= "done" and b.phase ~= "failed"
	end

	-- Build, once the check is clean: the button, then the build's progress, its result, or what failed with Show and
	-- Retry from here.
	local function buildRows(checked : PgraceRailRouterBuilder.Check) : {TreeNodeId}
		local rows : {TreeNodeId} = {}
		local b = buildRef:get()
		if b == nil then
			table.insert(rows, builtin.Button{
				meta = { class = "primary" },
				content = builtin.TextView{ text = _("Build") },
				onClick = function()
					if buildRef:get() == nil and workRef:get() == nil and probeRef:get() == nil
							and captureRef:get() == nil then
						buildRef:set(build.start(checked))
						buildViewState:set("start")
					end
				end,
			})
			return rows
		end
		local done, total = build.progress(b)
		if b.phase == "done" then
			table.insert(rows, textRow(fill(_("Built: {money}, {count} level crossings."), { money = formatMoney(b.charged),
				count = tostring(b.levelCrossings) }), "font-scale-body"))
		elseif b.phase == "failed" then
			local f = b.failure
			local what : string
			if f.item.kind == "station" then
				local station = checked.plan.stations[f.item.index]
				what = fill(_("Station {town}"), { town = station ~= nil and station.town ~= nil and station.town.name or "?" })
			else
				what = outcomePlace(checked, { item = f.item, ok = false, cost = 0, messages = f.messages, x = f.x, y = f.y,
					us = 0, collisions = {}, crossings = 0 })
			end
			table.insert(rows, textRow(fill(_("Building stopped at {what}: {messages}"), { what = what,
				messages = table.concat(f.messages, "; ") }), "font-scale-body"))
			table.insert(rows, builtin.BoxLayout{
				orientation = builtin.type.Orientation.Horizontal,
				children = {
					builtin.Button{
						content = builtin.TextView{ text = _("Show") },
						onClick = function()
							pcall(function() : boolean
								api.gui.camera.focusPosition(api.type.Vec3f.new(f.x, f.y, 0), 300)
								return true
							end)
						end,
					},
					builtin.Button{
						content = builtin.TextView{ text = _("Retry from here") },
						onClick = function()
							build.retry(b)
							buildViewState:set("retry")
						end,
					},
				},
			})
		else
			table.insert(rows, textRow(fill(_("Building… {done} of {total}"), { done = tostring(done),
				total = tostring(total) }), "font-scale-annotation"))
		end
		return rows
	end

	local function resetCheck()
		buildRef:set(nil)
		buildViewState:set(nil)
		checkRef:set(nil)
		checkDoneState:set(nil)
		checkState:set(nil)
		checkErrorState:set(false)
	end

	-- The game's price per metre of the plan's track, plain and electrified (main thread: two dry runs, about a
	-- millisecond each), at its first station along its direction; prices already known are kept.
	local function pricesFor(track : TrackType, plan : Plan)
		if track == nil or plan == nil or not plan.ok or #plan.stations == 0 then
			return
		end
		local station = plan.stations[1]
		local prices : {string : number} = {}
		for name, price in pairs(priceState:old()) do
			prices[name] = price
		end
		local year = currentYear(data.year)
		for __, electrified in ipairs({ false, true }) do
			local name = templateFor(track, electrified, year)
			if prices[name] == nil then
				local ok, price = pcall(function() : number
					return builder.pricePerMetre(settingsFor(track, electrified, year, false),
						{ x = station.site.centre.x, y = station.site.centre.y, z = station.z }, station.site.dir)
				end)
				if ok and price ~= nil then
					prices[name] = price as number
					debugPrint(LOG_PREFIX .. ("price of %s: %.1f a metre of double track (listed %.1f)"):format(name,
						price as number, 2 * track.cost))
				else
					debugPrint(LOG_PREFIX .. "price of " .. name .. ": " .. tostring(price))
				end
			end
		end
		priceState:set(prices)
	end

	-- Every settings change drops the shown plan and any work in progress: a plan for other settings would mislead.
	local function update(change : function(Settings))
		if building() then
			return
		end
		setSettings(change)
		resetCheck()
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
	-- Ticked by default: the towns that fit into the budget together.
	local byDefault : {integer : boolean} = {}
	if #candidates > 0 then
		for __, town in ipairs(corridor.select(fromTown, toTown, candidates, DETOUR_BUDGET)) do
			byDefault[town.id] = true
		end
	end
	local function isTicked(id : integer) : boolean
		local tick = settings.ticked[id]
		if tick == nil then
			return byDefault[id] == true
		end
		return tick
	end

	local function findRoute()
		-- Not while the map capture or a probe runs (PROBE), or a build: one piece of long work at a time.
		if captureRef:get() ~= nil or probeRef:get() ~= nil or building() then
			return
		end
		if fromTown == nil or toTown == nil or fromTown.id == toTown.id or track == nil then
			return
		end
		local picked : {Town} = {}
		for __, candidate in ipairs(candidates) do
			if isTicked(candidate.town.id) then
				table.insert(picked, candidate.town)
			end
		end
		workRef:set({ stops = corridor.order(fromTown, toTown, picked), track = track,
			weights = modes.weights(settings.mode, track),
			platform = settings.platform, margin = SURVEY_MARGIN, retries = 0, slowestStepUs = {},
			planUs = 0, planFrames = 0 })
		resetCheck()
		planState:set(nil)
		showState:set(false)
		errorState:set(false)
		progressState:set({ stage = "survey", percent = 0 })
	end

	local function setProgress(work : Work, stage : string, share : number)
		local percent = math.floor(100 * share)
		local widening = work.retries > 0
		local detail : string = nil
		if stage == "plan" and work.routeJob ~= nil then
			detail = planDetail(work.routeJob)
		end
		local old = progressState:old()
		if old == nil or old.stage ~= stage or old.percent ~= percent or old.widening ~= widening
				or old.detail ~= detail then
			progressState:set({ stage = stage, percent = percent, widening = widening, detail = detail })
		end
	end

	-- PROBE (remove before release): writes the planner's whole input to the log, so a route can be replayed and
	-- tuned offline on the player's own map. Heights in metres; flags per cell as a hex digit (1 blocked, 2 water,
	-- 4 road, 8 track).
	local function captureProbe(work : Work, g : PgraceRailRouterGrid.Grid)
		local tag = LOG_PREFIX .. "CAPTURE "
		debugPrint(tag .. "begin " .. string.format("%.3f %.3f %.3f %d %d", g.x0, g.y0, g.cell, g.nx, g.ny))
		local fields : {string} = {}
		for k, v in pairs(work.weights as {string : any}) do
			table.insert(fields, tostring(k) .. "=" .. tostring(v))
		end
		debugPrint(tag .. "weights " .. table.concat(fields, ";"))
		debugPrint(tag .. "platform " .. tostring(work.platform))
		for __, stop in ipairs(work.stops) do
			debugPrint(tag .. "stop " .. string.format("%d %.3f %.3f ", stop.id, stop.pos.x, stop.pos.y) .. stop.name)
		end
		for iy = 1, g.ny do
			local heights : {string} = {}
			local flags : {string} = {}
			for ix = 1, g.nx do
				local i = (iy - 1) * g.nx + ix
				table.insert(heights, string.format("%.1f", g.height[i] or 0))
				local f = (g.blocked[i] and 1 or 0) + (g.water[i] and 2 or 0) + (g.road[i] and 4 or 0)
					+ (g.track[i] and 8 or 0)
				table.insert(flags, string.format("%x", f))
			end
			debugPrint(tag .. "row " .. iy .. " " .. table.concat(heights, ",") .. " " .. table.concat(flags))
		end
		debugPrint(tag .. "end")
	end

	-- The Lua heap's size (KB), for the log's step allocation figure; nil where collectgarbage isn't there.
	local function heapKB() : number
		local ok, kb = pcall(function() : number
			return collectgarbage("count")
		end)
		if ok then
			return kb as number
		end
		return nil
	end

	-- Engine reads (terrain, octree) and the planner run in joins on the main thread, BUDGET_US per frame, as Jam
	-- Session's scan: the window stays responsive and the game doesn't freeze.
	local function advance(work : Work)
		local clock = api.type.Clock.new()
		if work.surveyJob == nil then
			if not work.boundsRead then
				work.bounds, work.boundsRead = survey.extent(), true
			end
			work.surveyJob = survey.start(work.stops, CELL, work.margin, work.bounds)
			if work.surveyJob == nil then
				error("survey: no area to survey")
			end
		end
		if work.routeJob == nil then
			if survey.step(work.surveyJob, BUDGET_US) then
				pcall(captureProbe, work, survey.grid(work.surveyJob)) -- PROBE (remove before release)
				work.routeJob = route.start({ grid = survey.grid(work.surveyJob), stops = work.stops,
					weights = work.weights, platformLength = work.platform })
				setProgress(work, "plan", 0)
			else
				setProgress(work, "survey", survey.progress(work.surveyJob))
			end
			return
		end
		local done = false
		local planStart = clock:getTime()
		work.planFrames = work.planFrames + 1
		repeat
			local phase = work.routeJob.phase
			local kind = route.stepKind(work.routeJob)
			local kbBefore = heapKB()
			local before = clock:getTime()
			done = route.step(work.routeJob, EXPANSIONS_PER_CALL)
			local took = clock:getTime() - before
			local kbAfter = heapKB()
			for __, key in ipairs({ kind, phase }) do
				if took > (work.slowestStepUs[key] or 0) then
					work.slowestStepUs[key] = took
				end
			end
			-- A collection during the step makes this less than it allocated (even negative): a lower bound.
			if kbBefore ~= nil and kbAfter ~= nil and kbAfter - kbBefore > (work.maxStepKB or 0) then
				work.maxStepKB, work.maxStepKind = kbAfter - kbBefore, kind
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
			-- Each leg's search radius (below the mode's where its turns didn't fit, or didn't pay), expansions, and the
			-- seconds its tight curves lose (planner/speed.tl).
			local searches : {string} = {}
			for __, leg in ipairs(plan.legs or {}) do
				table.insert(searches, tostring(math.floor(leg.searchRadius or 0)) .. " m/"
					.. tostring(leg.searchExpansions or 0) .. "/" .. string.format("%.1f", leg.timeLost or 0) .. " s")
			end
			debugPrint(LOG_PREFIX .. "plan done: " .. (plan.ok and "ok" or tostring(plan.failure)) .. ", "
				.. tostring(math.floor(work.planUs / 1000)) .. " ms over " .. tostring(work.planFrames)
				.. " frames; slowest step sites " .. tostring(work.slowestStepUs.sites or 0) .. " us, scout "
				.. tostring(work.slowestStepUs.scout or 0) .. " us, turn " .. tostring(work.slowestStepUs.turn or 0)
				.. " us, legs " .. tostring(work.slowestStepUs.legs or 0) .. " us (search "
				.. tostring(work.slowestStepUs.search or 0) .. ", simplify " .. tostring(work.slowestStepUs.simplify or 0)
				.. ", fit " .. tostring(work.slowestStepUs.fit or 0) .. ", heights " .. tostring(work.slowestStepUs.heights or 0)
				.. ", resite " .. tostring(work.slowestStepUs.resite or 0) .. "); most allocated in a step "
				.. tostring(math.floor(work.maxStepKB or 0)) .. " KB (" .. tostring(work.maxStepKind) .. "); length "
				.. tostring(math.floor(length))
				.. ", legs " .. tostring(plan.legs ~= nil and #plan.legs or 0) .. ", survey margin " .. tostring(work.margin)
				.. ", retries " .. tostring(work.retries) .. ", guarded "
				.. tostring(plan.summary ~= nil and plan.summary.guarded or 0) .. ", leg searches (radius/expansions/time lost) "
				.. table.concat(searches, " "))
			-- Perhaps the way round lies outside the surveyed area: start over on a wider one, unless that is the same
			-- area (already the whole map that way). no_exit (walled in) never gets better with a wider area.
			local wider = not plan.ok and plan.failure == "no_path" and work.retries < MAX_RETRIES
				and not area.same(area.box(work.stops, CELL, 2 * work.margin, work.bounds), work.surveyJob.box)
			if wider then
				work.retries = work.retries + 1
				work.margin = 2 * work.margin
				work.surveyJob = nil
				work.routeJob = nil
				work.slowestStepUs = {}
				work.maxStepKB, work.maxStepKind = nil, nil
				work.planUs = 0
				work.planFrames = 0
				setProgress(work, "survey", 0)
				return
			end
			nextGeneration = nextGeneration + 1
			generationState:set(nextGeneration)
			resetCheck()
			planState:set(plan)
			pricesFor(work.track, plan)
			workRef:set(nil)
			progressState:set(nil)
		else
			setProgress(work, "plan", route.progress(work.routeJob))
		end
	end

	-- PROBE (remove before release): writes the whole map to the log (mapcapture), BUDGET_US per frame.
	local function startCapture()
		if workRef:get() ~= nil or captureRef:get() ~= nil or checkRef:get() ~= nil or probeRef:get() ~= nil then
			return
		end
		captureRef:set({})
		capturePercentState:set(0)
		captureResultState:set(nil)
	end

	local function advanceCapture(capture : CaptureWork)
		if capture.job == nil then
			local tracks : {{string : any}} = {}
			for __, t in ipairs(data.tracks) do
				table.insert(tracks, t as any as {string : any})
			end
			capture.job = mapcapture.start({ tracks = tracks, meta = { mod = "pgrace_rail_router" } })
			if capture.job == nil then
				error("map capture: no extent")
			end
			return
		end
		if mapcapture.step(capture.job, BUDGET_US) then
			captureRef:set(nil)
			capturePercentState:set(nil)
			captureResultState:set("done")
		else
			local percent = math.floor(100 * mapcapture.progress(capture.job))
			if capturePercentState:old() ~= percent then
				capturePercentState:set(percent)
			end
		end
	end

	-- One dry run per join (each can take a few hundred milliseconds), never two in a frame. The first join makes
	-- the settings and the network.
	local function advanceCheck(work : CheckWork)
		if work.check == nil then
			local clock = api.type.Clock.new()
			local settings = settingsFor(work.track, work.electrified, currentYear(data.year), work.levelCrossings)
			work.check = builder.start(work.plan, settings, math.floor(clock:getTime()))
			checkDoneState:set(0)
		else
			builder.step(work.check)
			checkDoneState:set(work.check.next - 1)
		end
		if work.check.done then
			checkRef:set(nil)
			checkDoneState:set(nil)
			checkState:set(work.check)
		end
	end

	-- PROBE (remove before release): the first join asks the probe for its tasks (they read the camera), then one
	-- task per join.
	local function advanceProbe(work : ProbeWork)
		if work.tasks == nil then
			local settings = settingsFor(work.track, work.electrified, currentYear(data.year), false)
			if work.name == "P1" then
				work.tasks = probe.logTrack()
			elseif work.name == "P2" then
				work.tasks = probe.dryRunTrack(settings, data.tracks)
			elseif work.name == "P4" then
				work.tasks = probe.dryRunCrossing(settings)
			elseif work.name == "P8" then
				work.tasks = probe.bridgeClearance(settings)
			elseif work.name == "P12" then
				work.tasks = probe.catenaryPairs(settings)
			elseif work.name == "P9" then
				work.tasks = probe.levelCrossing(settings)
			elseif work.name == "P9b" then
				work.tasks = probe.levelCrossing(settings, 70)
			elseif work.name == "P9c" then
				work.tasks = probe.levelCrossing(settings, 90, 12)
			elseif work.name == "P9d" then
				work.tasks = probe.levelCrossing(settings, 90, 25)
			elseif work.name == "P10" then
				work.tasks = probe.buildStation(settings)
			elseif work.name == "P11" then
				work.tasks = probe.joinStation(settings)
			else
				work.tasks = probe.dryRunStation(settings, data.tracks)
			end
			work.next = 1
			return
		end
		local task = work.tasks[work.next]
		work.next = work.next + 1
		if task ~= nil then
			task()
		end
		if work.next > #work.tasks then
			probeRef:set(nil)
			probeStatusState:set("Probe " .. work.name .. " done (see log)")
		end
	end

	react.onStep(function()
		-- A build's callbacks change it between frames (a failure among them): show what it is now.
		local current = buildRef:get()
		if current ~= nil then
			local done = build.progress(current)
			local view = current.phase .. ":" .. tostring(done)
			if buildViewState:old() ~= view then
				buildViewState:set(view)
			end
		end
		if joinQueuedRef:get() then
			return
		end
		if building() then
			joinQueuedRef:set(true)
			safeJoin(function()
				joinQueuedRef:set(false)
				local b = buildRef:get()
				if b == nil then
					return
				end
				build.step(b)
				local done = build.progress(b)
				local view = b.phase .. ":" .. tostring(done)
				if buildViewState:old() ~= view then
					buildViewState:set(view)
				end
			end, "PgraceRailRouterBuild")
			return
		end
		if workRef:get() == nil and checkRef:get() ~= nil then
			joinQueuedRef:set(true)
			safeJoin(function()
				joinQueuedRef:set(false)
				local work = checkRef:get()
				if work == nil then
					return
				end
				local ok, err = pcall(function() : boolean
					advanceCheck(work)
					return true
				end)
				if not ok then
					debugPrint(LOG_PREFIX .. "check error: " .. tostring(err))
					checkRef:set(nil)
					checkDoneState:set(nil)
					checkErrorState:set(true)
				end
			end, "PgraceRailRouterCheck")
			return
		end
		-- PROBE (remove before release)
		if workRef:get() == nil and checkRef:get() == nil and probeRef:get() ~= nil then
			joinQueuedRef:set(true)
			safeJoin(function()
				joinQueuedRef:set(false)
				local work = probeRef:get()
				if work == nil then
					return
				end
				local ok, err = pcall(function() : boolean
					advanceProbe(work)
					return true
				end)
				if not ok then
					debugPrint(LOG_PREFIX .. "probe error: " .. tostring(err))
					probeRef:set(nil)
					probeStatusState:set("Probe " .. work.name .. " failed (see log)")
				end
			end, "PgraceRailRouterProbe")
			return
		end
		if workRef:get() == nil and captureRef:get() ~= nil then
			joinQueuedRef:set(true)
			safeJoin(function()
				joinQueuedRef:set(false)
				local capture = captureRef:get()
				if capture == nil then
					return
				end
				local ok, err = pcall(function() : boolean
					advanceCapture(capture)
					return true
				end)
				if not ok then
					debugPrint(LOG_PREFIX .. "map capture error: " .. tostring(err))
					captureRef:set(nil)
					capturePercentState:set(nil)
					captureResultState:set("failed")
				end
			end, "PgraceRailRouterCapture")
			return
		end
		if workRef:get() == nil then
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
		update(function(s : Settings) s.from = id s.ticked = {} end)
	end)))
	table.insert(body, labelled(_("To"), townCombo(data.towns, toTown ~= nil and toTown.id or -1, function(id : integer)
		update(function(s : Settings) s.to = id s.ticked = {} end)
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
	-- Default: ticked if the chosen track has an electrified variant that's available this year. A remembered tick
	-- shows unticked on a track without one.
	local electrifiable = track ~= nil and track.catenary ~= nil
	local electrified = settings.electrified
	if electrified == nil then
		local from = electrifiable and track.catenaryYearFrom or 0
		electrified = electrifiable and (from == 0 or data.year >= from)
	elseif not electrifiable then
		electrified = false
	end
	table.insert(body, builtin.CheckBox{
		label = _("Electrified"),
		value = electrified and 1 or 0,
		onValueChange = function(v : integer)
			setSettings(function(s : Settings) s.electrified = v == 1 end)
			-- A check with the game was for the other track.
			resetCheck()
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
		local on : {integer : boolean} = {}
		for __, candidate in ipairs(candidates) do
			on[candidate.town.id] = isTicked(candidate.town.id)
		end
		local showAll = showAllState:old()
		local listed = candidates
		if not showAll then
			listed = corridor.visible(candidates, on, settings.ticked, EXTRA_STOPS)
		end
		for __, candidate in ipairs(listed) do
			local id = candidate.town.id
			-- A town (almost) on the direct line costs no detour worth a number.
			local label = fill(_("{town} (on the way)"), { town = candidate.town.name })
			if candidate.detour >= ON_THE_WAY then
				label = fill(_("{town} (+{detour})"), { town = candidate.town.name, detour = formatLength(candidate.detour) })
			end
			table.insert(body, builtin.CheckBox{
				label = label,
				value = isTicked(id) and 1 or 0,
				onValueChange = function(v : integer)
					update(function(s : Settings)
						local ticked : {integer : boolean} = {}
						for k, tick in pairs(s.ticked) do
							ticked[k] = tick
						end
						-- Back to the default: no override, so it follows the default if that changes.
						if (v == 1) == (byDefault[id] == true) then
							ticked[id] = nil
						else
							ticked[id] = v == 1
						end
						s.ticked = ticked
					end)
				end,
			})
		end
	end
	if #candidates > 0 and (showAllState:old() or #candidates > EXTRA_STOPS) then
		local expanded = showAllState:old()
		local toggleLabel = expanded and _("Show fewer") or fill(_("Show all {count} towns"), { count = tostring(#candidates) })
		table.insert(body, expander(expanded, toggleLabel, function()
			rememberedShowAll = not expanded
			showAllState:set(not expanded)
		end))
	end
	table.insert(body, builtin.Button{
		meta = { class = "primary" },
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
		if progress.widening then
			-- The same words for a retry's survey and its planning: the player only needs to know it's trying wider.
			template = _("Widening the search… {percent}%")
		end
		local line = fill(template, { percent = tostring(progress.percent) })
		if progress.detail ~= nil then
			line = fill(_("{progress} · {detail}"), { progress = line, detail = progress.detail })
		end
		table.insert(body, textRow(line, "font-scale-annotation"))
	end
	if errorState:old() then
		table.insert(body, textRow(_("Planning failed (see log)"), "font-scale-body"))
	end
	local plan = planState:old()
	if plan ~= nil then
		if not plan.ok then
			table.insert(body, textRow(failureText(plan), "font-scale-body"))
		else
			local priceFactor = 1.0
			local perMetre = priceState:old()[templateFor(track, electrified, data.year)]
			if perMetre ~= nil and track.cost > 0 then
				priceFactor = perMetre / (2 * track.cost)
			end
			for __, row in ipairs(resultRows(plan, priceFactor)) do
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
			-- Check with the game: dry-run the stations and the track, the game's price and errors.
			local checked = checkState:old()
			local checking = checkRef:get()
			if checking ~= nil then
				local line = _("Checking with the game…")
				if checking.check ~= nil then
					line = fill(_("Checking with the game… {done} of {total}"),
						{ done = tostring(checkDoneState:old() or 0), total = tostring(#checking.check.items) })
				end
				table.insert(body, textRow(line, "font-scale-annotation"))
			elseif checked ~= nil then
				local stationsPrice = 0
				for __, outcome in ipairs(checked.outcomes) do
					if outcome.item.kind == "station" then
						stationsPrice = stationsPrice + outcome.cost
					end
				end
				table.insert(body, textRow(fill(_("The game's price: {price} (track {track}, stations {stations})"),
					{ price = formatMoney(checked.total), track = formatMoney(checked.total - stationsPrice),
					stations = formatMoney(stationsPrice) }), "font-scale-body"))
				if checked.built > 0 then
					table.insert(body, textRow(fill(_("{count} of {total} parts already built: Build carries on from there."),
						{ count = tostring(checked.built), total = tostring(#checked.items) }), "font-scale-annotation"))
				end
				if checked.crossings > 0 then
					table.insert(body, textRow(fill(_("Level crossings: {count}"),
						{ count = tostring(checked.crossings) }), "font-scale-annotation"))
				end
				if checked.failures > 0 then
					table.insert(body, textRow(fill(_("{count} of {total} parts can't be built as planned:"),
						{ count = tostring(checked.failures), total = tostring(#checked.items) }), "font-scale-body"))
				end
				local shown = 0
				for __, outcome in ipairs(checked.outcomes) do
					if not outcome.ok then
						shown = shown + 1
						if shown <= MAX_PROBLEMS then
							table.insert(body, problemRow(checked, outcome))
						end
					end
				end
				if shown > MAX_PROBLEMS then
					table.insert(body, textRow(fill(_("and {count} more"), { count = tostring(shown - MAX_PROBLEMS) }),
						"font-scale-annotation"))
				end
				if checked.failures == 0 then
					for __, row in ipairs(buildRows(checked)) do
						table.insert(body, row)
					end
				end
			else
				table.insert(body, builtin.Button{
					meta = { class = "primary" },
					content = builtin.TextView{ text = _("Check with the game") },
					onClick = function()
						if track == nil or workRef:get() ~= nil or captureRef:get() ~= nil or probeRef:get() ~= nil then
							return
						end
						checkRef:set({ plan = plan, track = track, electrified = electrified,
							levelCrossings = not modes.weights(settings.mode, track).bridgeRoads })
						checkDoneState:set(0)
						checkErrorState:set(false)
					end,
				})
				if checkErrorState:old() then
					table.insert(body, textRow(_("The check failed (see log)"), "font-scale-body"))
				end
			end
			-- Each station's distance from its town centre, folded away: a long line has many.
			table.insert(body, expander(stationsState:old(), fill(_("Stations ({count})"),
				{ count = tostring(#plan.stations) }), function()
				rememberedStations = not stationsState:old()
				stationsState:set(rememberedStations)
			end))
			if stationsState:old() then
				for __, station in ipairs(plan.stations) do
					table.insert(body, textRow(fill(_("{town}: station {distance} from the centre"),
						{ town = station.town.name, distance = formatLength(station.site.distance) }),
						"font-scale-annotation"))
				end
			end
		end
	end
	-- PROBE (remove before release): the milestone 2 probes, at the camera's look-at point; not translated.
	local function startProbe(name : string)
		if track == nil or workRef:get() ~= nil or captureRef:get() ~= nil or checkRef:get() ~= nil
				or probeRef:get() ~= nil then
			return
		end
		probeRef:set({ name = name, track = track, electrified = electrified })
		probeStatusState:set("Probe " .. name .. " running…")
	end
	-- PROBE (remove before release): the dev tools, folded away so the route and its check stay on screen.
	table.insert(body, expander(probesState:old(), "Probes", function()
		rememberedProbes = not probesState:old()
		probesState:set(rememberedProbes)
	end))
	if probesState:old() then
		table.insert(body, builtin.Button{
			content = builtin.TextView{ text = "Capture whole map (probe)" },
			onClick = startCapture,
		})
		for __, p in ipairs({
			{ "P1", "Probe P1: log track near camera" },
			{ "P2", "Probe P2: dry-run test track" },
			{ "P4", "Probe P4: dry-run across a street" },
			{ "P8", "Probe P8: bridge clearance over track and street" },
			{ "P6", "Probe P6: dry-run a station" },
			{ "P12", "Probe P12: overhead wire, two test pairs (builds; test map only)" },
			{ "P9", "Probe P9: level crossing (builds; test map only)" },
			{ "P9b", "Probe P9b: level crossing at 70 degrees (builds; test map only)" },
			{ "P9c", "Probe P9c: level crossing 12 m from a road joint (builds)" },
			{ "P9d", "Probe P9d: level crossing 25 m from a road joint (builds)" },
			{ "P10", "Probe P10: build a station (test map only)" },
			{ "P11", "Probe P11: join track to the station (test map only)" },
		}) do
			table.insert(body, builtin.Button{
				content = builtin.TextView{ text = p[2] },
				onClick = function()
					startProbe(p[1])
				end,
			})
		end
	end
	if probeStatusState:old() ~= nil then
		table.insert(body, textRow(probeStatusState:old(), "font-scale-annotation"))
	end
	local capturePercent = capturePercentState:old()
	if capturePercent ~= nil then
		table.insert(body, textRow("Capturing map… " .. tostring(capturePercent) .. "%", "font-scale-annotation"))
	elseif captureResultState:old() == "done" then
		table.insert(body, textRow("Map captured (see log)", "font-scale-annotation"))
	elseif captureResultState:old() == "failed" then
		table.insert(body, textRow("Map capture failed (see log)", "font-scale-annotation"))
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
	local gameCtx = params.payload ~= nil and params.payload.toolParam ~= nil and params.payload.toolParam.gameCtx
		or makeToolParam().gameCtx
	-- Without an action of its own, the tool leaves the map bare (no town names). Set the game's default, built
	-- once and passed on every render as the Music Player does.
	local mapActionRef : ReactRefT<function() : TreeNodeId> = react.useRef(nil)
	if mapActionRef:get() == nil then
		mapActionRef:set(preview.makeMapAction(gameCtx))
	end
	if params.payload ~= nil and params.payload.setActionFn ~= nil then
		params.payload.setActionFn(mapActionRef:get())
	end
	return builtin.Window{
		meta = { class = "pgrace-rail-router" },
		id = WINDOW_ID,
		title = MOD_NAME,
		closable = true,
		onClose = params.onClose,
		content = Content{ gameCtx = gameCtx },
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
