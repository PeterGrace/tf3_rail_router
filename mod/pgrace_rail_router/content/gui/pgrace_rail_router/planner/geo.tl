local geo : PgraceRailRouterGeo = {}

local type Pt = PgraceRailRouterGeo.Pt

function geo.pt(x : number, y : number) : Pt
	return { x = x, y = y }
end

function geo.add(a : Pt, b : Pt) : Pt
	return { x = a.x + b.x, y = a.y + b.y }
end

function geo.sub(a : Pt, b : Pt) : Pt
	return { x = a.x - b.x, y = a.y - b.y }
end

function geo.scale(a : Pt, k : number) : Pt
	return { x = a.x * k, y = a.y * k }
end

function geo.len(a : Pt) : number
	return math.sqrt(a.x * a.x + a.y * a.y)
end

function geo.dist(a : Pt, b : Pt) : number
	return geo.len(geo.sub(a, b))
end

function geo.norm(a : Pt) : Pt
	local l = geo.len(a)
	if l < 1e-9 then
		return { x = 0, y = 0 }
	end
	return { x = a.x / l, y = a.y / l }
end

function geo.dot(a : Pt, b : Pt) : number
	return a.x * b.x + a.y * b.y
end

function geo.cross(a : Pt, b : Pt) : number
	return a.x * b.y - a.y * b.x
end

function geo.rotate(a : Pt, radians : number) : Pt
	local c, s = math.cos(radians), math.sin(radians)
	return { x = a.x * c - a.y * s, y = a.x * s + a.y * c }
end

function geo.turnAngle(a : Pt, b : Pt) : number
	local c = geo.dot(geo.norm(a), geo.norm(b))
	if c > 1 then
		c = 1
	elseif c < -1 then
		c = -1
	end
	return math.acos(c)
end

return geo
