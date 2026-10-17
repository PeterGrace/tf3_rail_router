local t = ...
local sl = t.requireTl("gui/pgrace_rail_router/planner/stationlayout.tl")

local ERA = { platform = "P", track = "T" }

t.test("stationlayout: slot ids as the station script mangles them", function()
	t.eq(sl.trackSlot(1, 0), 8401000, "track i=1 j=0")
	t.eq(sl.trackSlot(2, -1), 8401990, "track i=2 j=-1")
	t.eq(sl.platformSlot(3, 2), 7403020, "platform i=3 j=2")
end)

t.test("stationlayout: a 160 m station has 4 modules along on each of its 4 rows", function()
	local l = sl.layout({ x = 0, y = 0 }, { x = 0, y = 1 }, 160, ERA)
	local tracks, platforms = 0, 0
	for __, m in pairs(l.modules) do
		if m.name == "T" then tracks = tracks + 1 elseif m.name == "P" then platforms = platforms + 1 end
	end
	t.eq(tracks, 8, "2 tracks × 4")
	t.eq(platforms, 8, "2 platforms × 4")
	t.ok(l.modules[sl.trackSlot(1, -1)] ~= nil and l.modules[sl.trackSlot(1, 2)] ~= nil, "j from -1 to 2")
	t.ok(l.modules[sl.trackSlot(1, -2)] == nil and l.modules[sl.trackSlot(1, 3)] == nil, "and no further")
	t.eq(l.modules[sl.platformSlot(0, 0)].name, "P", "platform on row 0")
	t.eq(l.modules[sl.trackSlot(2, 0)].name, "T", "track on row 2")
	t.eq(l.modules[sl.platformSlot(3, 0)].name, "P", "platform on row 3")
end)

t.test("stationlayout: the track ends straddle the site's axis, at the platforms' ends", function()
	-- Facing north (+y): local x is east, so the left track (west) is 2.5 m west of the axis.
	local l = sl.layout({ x = 100, y = 200 }, { x = 0, y = 1 }, 160, ERA)
	t.near(l.angle, 0, 1e-9, "no rotation facing +y")
	t.near(l.ends[1].x, 97.5, 1e-9, "left track start x")
	t.near(l.ends[2].x, 102.5, 1e-9, "right track start x")
	t.near(l.ends[1].y, 200 - 80, 1e-9, "start 80 m behind the centre (half the platforms)")
	t.near(l.ends[3].y, 200 + 80, 1e-9, "end 80 m ahead")
	t.near(l.ends[4].x, 102.5, 1e-9, "right track end x")
	-- 4 modules (j = -1..2): the origin is module 0's centre, 20 m behind the platforms' middle.
	t.near(l.origin.x, 92.5, 1e-9, "origin 7.5 m left of the axis")
	t.near(l.origin.y, 180, 1e-9, "origin 20 m behind the centre")
end)

t.test("stationlayout: an odd number of modules is centred too, and turning the site turns the ends", function()
	local l = sl.layout({ x = 0, y = 0 }, { x = 1, y = 0 }, 120, ERA)
	-- Facing east: left is north (+y).
	t.near(l.ends[1].y, 2.5, 1e-9, "left track north of the axis")
	t.near(l.ends[1].x, -60, 1e-9, "half of 120 m behind")
	t.near(l.ends[3].x, 60, 1e-9, "and ahead")
	t.near(l.ends[2].y, -2.5, 1e-9, "right track south of the axis")
end)

t.test("stationlayout: the angle turns local +y onto the direction of travel in every quadrant", function()
	local s = math.sqrt(0.5)
	for __, d in ipairs({ { 0, 1 }, { 1, 0 }, { 0, -1 }, { -1, 0 }, { s, s }, { -s, s }, { s, -s }, { -s, -s } }) do
		local dir = { x = d[1], y = d[2] }
		local a = sl.layout({ x = 0, y = 0 }, dir, 80, ERA).angle
		-- rotZ(a) takes (0, 1) to (-sin a, cos a).
		local label = ("dir (%.2f, %.2f)"):format(dir.x, dir.y)
		t.near(-math.sin(a), dir.x, 1e-9, label .. " x")
		t.near(math.cos(a), dir.y, 1e-9, label .. " y")
	end
end)

t.test("stationlayout: the station track module for a track template", function()
	t.eq(sl.trackModule("::/infrastructure/track/standard/standard.street_template"),
		"::/trainstation___/infrastructure/track/standard/standard.street_template", "with ::")
	t.eq(sl.trackModule("foo::/a/b.street_template"), "::/trainstation_foo__/a/b.street_template", "a mod's template")
end)

t.test("stationlayout: platforms longer than the station script's 21 slots along are cut to 840 m", function()
	local l = sl.layout({ x = 0, y = 0 }, { x = 0, y = 1 }, 2000, ERA)
	local tracks = 0
	for __, m in pairs(l.modules) do
		if m.name == "T" then tracks = tracks + 1 end
	end
	t.eq(tracks, 42, "2 tracks × 21")
	t.ok(l.modules[sl.trackSlot(1, -10)] ~= nil and l.modules[sl.trackSlot(1, 10)] ~= nil, "j from -10 to 10")
	t.near(l.ends[1].y, -420, 1e-9, "start 420 m behind")
	t.near(l.ends[3].y, 420, 1e-9, "end 420 m ahead")
end)

t.test("stationlayout: the era by year, as the station script's getEra", function()
	t.eq(sl.eraLetter(1850), "a", "1850")
	t.eq(sl.eraLetter(1949), "a", "1949")
	t.eq(sl.eraLetter(1950), "b", "1950")
	t.eq(sl.eraLetter(1989), "b", "1989")
	t.eq(sl.eraLetter(1990), "c", "1990")
	t.eq(sl.eraLetter(0), "a", "an unknown year")
end)

local ADDONS = { building = "B", stairs = "S", roof = "R" }

local function slots(modules, name)
	local list = {}
	for slot, m in pairs(modules) do
		if m.name == name then table.insert(list, slot) end
	end
	table.sort(list)
	return table.concat(list, " ")
end

t.test("stationlayout: a 160 m station's main building, stairs and roofs, as the research's base template", function()
	local m = sl.addons(160, ADDONS)
	t.eq(slots(m, "B"), "3400020", "main building 1 at 3400020")
	t.eq(slots(m, "S"), "10800000 10803000", "stairs at the middle module of each platform")
	t.eq(slots(m, "R"), "10399990 10400000 10400010 10400020 10402990 10403000 10403010 10403020",
		"roofs over every module (j = -1..2)")
end)

t.test("stationlayout: addons for 120 m and 320 m stations, and none without roofs", function()
	local m = sl.addons(120, { building = "B", stairs = "S" })
	t.eq(slots(m, "B"), "3400000", "an odd count along: main building at k = 0")
	t.eq(slots(m, "S"), "10800000 10803000", "stairs at the middle (j = 0)")
	t.eq(slots(m, "R"), "", "no roofs")
	-- 8 modules: j = -3..4, centre 0, dist 7: stairs also at s + 1 = -2 and e - 1 = 3; roofs off the two end modules.
	m = sl.addons(320, ADDONS)
	t.eq(slots(m, "B"), "3400020", "an even count along: k = 2")
	t.eq(slots(m, "S"), "10799980 10800000 10800030 10802980 10803000 10803030", "stairs at -2, 0, 3")
	t.eq(slots(m, "R"), "10399980 10399990 10400000 10400010 10400020 10400030 10402980 10402990 10403000 10403010 10403020 10403030",
		"roofs from j = -2 to 3")
end)
