-- 2D vector helpers on plain {x, y} tables, in metres. Pure (no api.*).
global record PgraceRailRouterGeo
	record Pt
		x : number
		y : number
	end

	pt : function(x : number, y : number) : Pt
	add : function(a : Pt, b : Pt) : Pt
	sub : function(a : Pt, b : Pt) : Pt
	scale : function(a : Pt, k : number) : Pt
	len : function(a : Pt) : number
	dist : function(a : Pt, b : Pt) : number
	-- The unit vector along a; (0, 0) stays (0, 0).
	norm : function(a : Pt) : Pt
	dot : function(a : Pt, b : Pt) : number
	-- z of the 3D cross product: positive when b points to the left of a.
	cross : function(a : Pt, b : Pt) : number
	-- a turned counter-clockwise by `radians`.
	rotate : function(a : Pt, radians : number) : Pt
	-- The unsigned angle between two directions, 0 to pi.
	turnAngle : function(a : Pt, b : Pt) : number
end
