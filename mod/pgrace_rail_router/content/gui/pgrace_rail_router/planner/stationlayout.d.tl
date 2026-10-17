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

	-- Slot ids, as the station script mangles them.
	trackSlot : function(i : integer, j : integer) : integer
	platformSlot : function(i : integer, j : integer) : integer
	-- The station track module for a track template resource name, e.g.
	-- "::/infrastructure/track/standard/standard.street_template" →
	-- "::/trainstation___/infrastructure/track/standard/standard.street_template".
	trackModule : function(template : string) : string
	-- The layout for a site (centre, unit direction of travel) and platform length (a multiple of 40 m).
	layout : function(centre : PgraceRailRouterGeo.Pt, dir : PgraceRailRouterGeo.Pt, platformLength : number,
		era : Era) : Layout
end
