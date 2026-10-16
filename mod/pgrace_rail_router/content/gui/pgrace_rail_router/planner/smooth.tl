local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo

local smooth : PgraceRailRouterSmooth = {}

local type Pt = PgraceRailRouterGeo.Pt
local type Piece = PgraceRailRouterSmooth.Piece
local type Sample = PgraceRailRouterSmooth.Sample
local type Result = PgraceRailRouterSmooth.Result

-- Distance from p to the segment a–b (not the infinite line through it, so overshoots count).
local function perpDist(p : Pt, a : Pt, b : Pt) : number
	local ab = geo.sub(b, a)
	local l2 = geo.dot(ab, ab)
	if l2 < 1e-18 then
		return geo.dist(p, a)
	end
	local f = math.max(0, math.min(1, geo.dot(geo.sub(p, a), ab) / l2))
	return geo.dist(p, geo.add(a, geo.scale(ab, f)))
end

function smooth.simplify(points : {Pt}, tolerance : number) : {Pt}
	local n = #points
	local keep : {boolean} = {}
	keep[1], keep[n] = true, true
	local stack : {{integer}} = { { 1, n } }
	while #stack > 0 do
		local range = table.remove(stack)
		local i, j = range[1], range[2]
		local worst, worstD = 0, 0.0
		for k = i + 1, j - 1 do
			local d = perpDist(points[k], points[i], points[j])
			if d > worstD then
				worst, worstD = k, d
			end
		end
		if worst > 0 and worstD > tolerance then
			keep[worst] = true
			table.insert(stack, { i, worst })
			table.insert(stack, { worst, j })
		end
	end
	local result : {Pt} = {}
	for k = 1, n do
		if keep[k] then
			table.insert(result, points[k])
		end
	end
	return result
end

local function straight(pieces : {Piece}, a : Pt, b : Pt)
	local length = geo.dist(a, b)
	if length > 1e-6 then
		table.insert(pieces, { kind = "straight", a = a, b = b, length = length })
	end
end

-- Pieces for points whose corner tangents (t) fit, tightening any that overlap between fixed points.
local function build(pts : {Pt}, theta : {number}, t : {number}, removed : integer) : Result
	local n = #pts
	local fit : {number} = {}
	for i = 1, n do
		fit[i] = t[i]
	end
	for i = 1, n - 1 do
		local len = geo.dist(pts[i], pts[i + 1])
		local sum = t[i] + t[i + 1]
		if sum > len and sum > 0 then
			local k = len / sum
			fit[i] = math.min(fit[i], t[i] * k)
			fit[i + 1] = math.min(fit[i + 1], t[i + 1] * k)
		end
	end
	local pieces : {Piece} = {}
	local minRadius = math.huge
	local cur = pts[1]
	for i = 2, n - 1 do
		if theta[i] > 1e-6 then
			local din = geo.norm(geo.sub(pts[i], pts[i - 1]))
			local dout = geo.norm(geo.sub(pts[i + 1], pts[i]))
			local a = geo.sub(pts[i], geo.scale(din, fit[i]))
			local b = geo.add(pts[i], geo.scale(dout, fit[i]))
			local r = fit[i] / math.tan(theta[i] / 2)
			local side = geo.cross(din, dout) > 0 and 1 or -1
			local centre = geo.add(a, geo.scale({ x = -din.y, y = din.x }, side * r))
			straight(pieces, cur, a)
			table.insert(pieces, { kind = "arc", a = a, b = b, length = r * theta[i], radius = r, centre = centre,
				turn = side * theta[i] })
			minRadius = math.min(minRadius, r)
			cur = b
		end
	end
	straight(pieces, cur, pts[n])
	return { pieces = pieces, minRadius = minRadius, removed = removed }
end

-- Points closer than this to the one before are merged into it.
local SAME = 1e-6

function smooth.fillet(points : {Pt}, radius : number, fixed : {boolean}) : Result
	if #points < 2 then
		return { pieces = {}, minRadius = math.huge, removed = 0 }
	end
	-- Merge repeated points (a merged point is fixed if either was); the ends always stay.
	local pts : {Pt} = {}
	local fix : {boolean} = {}
	local count = #points
	for i, p in ipairs(points) do
		local m = #pts
		if m > 1 and geo.dist(pts[m], p) < SAME then
			-- The last point replaces the one it repeats, so the end stays where it was.
			if i == count then
				pts[m] = p
			end
			fix[m] = fix[m] or fixed[i] == true
		elseif m == 1 and i < count and geo.dist(pts[1], p) < SAME then
			fix[1] = true
		else
			table.insert(pts, p)
			table.insert(fix, fixed[i] == true)
		end
	end
	fix[1], fix[#pts] = true, true
	local removed = 0
	while true do
		local n = #pts
		local theta : {number} = {}
		local t : {number} = {}
		for i = 1, n do
			theta[i], t[i] = 0, 0
		end
		for i = 2, n - 1 do
			theta[i] = geo.turnAngle(geo.sub(pts[i], pts[i - 1]), geo.sub(pts[i + 1], pts[i]))
			t[i] = radius * math.tan(theta[i] / 2)
		end
		local victim : integer = nil
		for i = 1, n - 1 do
			if t[i] + t[i + 1] > geo.dist(pts[i], pts[i + 1]) + 1e-6 then
				if not fix[i] and not fix[i + 1] then
					victim = theta[i] <= theta[i + 1] and i or i + 1
				elseif not fix[i] then
					victim = i
				elseif not fix[i + 1] then
					victim = i + 1
				end
				if victim ~= nil then
					break
				end
			end
		end
		if victim == nil then
			return build(pts, theta, t, removed)
		end
		table.remove(pts, victim)
		table.remove(fix, victim)
		removed = removed + 1
	end
end

function smooth.pointAt(piece : Piece, d : number) : Pt
	if piece.kind == "arc" then
		local f = piece.length > 0 and d / piece.length or 0
		return geo.add(piece.centre, geo.rotate(geo.sub(piece.a, piece.centre), piece.turn * f))
	end
	local f = piece.length > 0 and d / piece.length or 0
	return geo.add(piece.a, geo.scale(geo.sub(piece.b, piece.a), f))
end

function smooth.sample(pieces : {Piece}, step : number) : {Sample}
	local samples : {Sample} = {}
	local s0 = 0.0
	for __, piece in ipairs(pieces) do
		local m = math.max(1, math.ceil(piece.length / step))
		for j = 0, m - 1 do
			local d = piece.length * j / m
			table.insert(samples, { p = smooth.pointAt(piece, d), s = s0 + d })
		end
		s0 = s0 + piece.length
	end
	if #pieces > 0 then
		local last = pieces[#pieces]
		table.insert(samples, { p = smooth.pointAt(last, last.length), s = s0 })
	end
	return samples
end

return smooth
