-- The frame a junction is laid out in (milestone 4c): a sampled midline of an existing double track, x the distance
-- along it from its start, y the offset across it (to the left of the direction of increasing x). Pure.
global record PgraceRailRouterMidline
	-- The spacing a read stretch's midline is sampled at (metres).
	STEP : number

	record Frame
		-- Samples: pts[i] at x = (i − 1) × step, with its unit direction (in plan) and grade (dz per metre along).
		pts : {PgraceRailRouterNetwork.Pt3}
		dirs : {PgraceRailRouterGeo.Pt}
		grades : {number}
		step : number
		-- x of the last sample.
		length : number
	end

	-- A straight frame: from `origin` (height z) along the unit `dir`, on a steady grade, `length` long. Two samples,
	-- so it maps exactly as 4b's straight frame did.
	line : function(origin : PgraceRailRouterGeo.Pt, dir : PgraceRailRouterGeo.Pt, z : number, grade : number,
		length : number) : Frame
	-- A frame through `pts` (a polyline, in order, at least two points), resampled every `step` metres along it
	-- (the last sample at its end); each sample's direction and grade from its neighbours.
	fromPoints : function(pts : {PgraceRailRouterNetwork.Pt3}, step : number) : Frame
	-- The midline's point (height included) and unit direction at x. Between samples: interpolated (the direction
	-- renormalised). Before 0 or past `length`: extended straight along the end sample's direction and grade.
	at : function(f : Frame, x : number) : PgraceRailRouterNetwork.Pt3, PgraceRailRouterGeo.Pt
	-- The grade at x (the sample segment's; the end samples' outside).
	grade : function(f : Frame, x : number) : number
	-- The world point at frame (x, y): the midline's point at x, y along its left normal, at the midline's height.
	world : function(f : Frame, x : number, y : number) : PgraceRailRouterNetwork.Pt3
	-- A frame vector (tx along, ty across) at x in the world, its rise tx × grade(x).
	vector : function(f : Frame, x : number, tx : number, ty : number) : PgraceRailRouterNetwork.Pt3
	-- A world point's frame (x, y): its nearest point on the midline (extended straight past both ends).
	project : function(f : Frame, p : PgraceRailRouterGeo.Pt) : number, number
	-- How far the midline runs on from x0 while its direction stays within `tol` (the sine of the angle) of the
	-- direction at x0: the x where it first turns further (interpolated between samples), or `length`.
	straightUntil : function(f : Frame, x0 : number, tol : number) : number
end
