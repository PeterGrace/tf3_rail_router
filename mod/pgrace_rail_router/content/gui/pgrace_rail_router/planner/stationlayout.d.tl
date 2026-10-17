-- A 2-track passenger through station on the base game's modular station: its modules (slot id → module file) and
-- where it goes (rotation and origin for Mat4f.rotZTransl), and its four track ends in world coordinates. Pure.
global record PgraceRailRouterStationLayout
	record Module
		name : string
		variant : integer
	end

	-- One era's module files.
	record Era
		-- e.g. "::/stations/rail/modular_station/platform_passenger_era_c.module"
		platform : string
		-- The station track module for the line's track type (see trackModule).
		track : string
	end

	record Layout
		modules : {integer : Module}
		-- Rotation about z (radians) and the origin of the station's local frame (world, metres).
		angle : number
		origin : PgraceRailRouterGeo.Pt
		-- Track ends: {left track's start, right track's start, left's end, right's end} in the direction of travel
		-- (left/right as network.tl's tracks 1 and 2).
		ends : {PgraceRailRouterGeo.Pt}
	end

	-- What the base station menu adds to a 2-track through station besides its platforms and tracks (module files).
	record Addons
		-- e.g. "::/stations/rail/modular_station/main_building_1_era_c.module"
		building : string
		-- e.g. "::/stations/rail/modular_station/addon_platform_passenger_stairs_era_c.module"
		stairs : string
		-- e.g. "::/stations/rail/modular_station/platform_passenger_roof_era_c.module"; nil for no roofs.
		roof : string
	end

	-- Slot ids, as the station script mangles them.
	trackSlot : function(i : integer, j : integer) : integer
	platformSlot : function(i : integer, j : integer) : integer
	-- The station track module the base game generates for a track template resource name: "::/trainstation_" and
	-- the name with "::" replaced by "__", e.g. "::/infrastructure/track/standard/standard.street_template" →
	-- "::/trainstation___/infrastructure/track/standard/standard.street_template", and a mod's
	-- "foo::/a/b.street_template" → "::/trainstation_foo__/a/b.street_template".
	trackModule : function(template : string) : string
	-- The station era for a year, as the station script picks it (getEra): "a" before 1950, "b" before 1990, "c".
	eraLetter : function(year : integer) : string
	-- The main building, underpass stairs and (if addons.roof is set) roofs the station script's template puts on a
	-- 2-track through station of this platform length (createTemplateFn for 2 tracks: main building 1 at slot
	-- 3400000 + 10 k, stairs and roofs on platform rows 0 and 3).
	addons : function(platformLength : number, addons : Addons) : {integer : Module}
	-- The layout for a site (centre, unit direction of travel) and platform length (a multiple of 40 m; at most 840 m,
	-- 21 modules, the most the station script has slots for).
	layout : function(centre : PgraceRailRouterGeo.Pt, dir : PgraceRailRouterGeo.Pt, platformLength : number,
		era : Era) : Layout
end
