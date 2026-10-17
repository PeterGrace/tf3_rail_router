local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo

local smooth : PgraceRailRouterSmooth = {}

local type Pt = PgraceRailRouterGeo.Pt
local type Piece = PgraceRailRouterSmooth.Piece
local type Sample = PgraceRailRouterSmooth.Sample
local type Result = PgraceRailRouterSmooth.Result
local type Guard = PgraceRailRouterSmooth.Guard

-- Distance from p to the segment a–b (not the infinite line through it, so overshoots count). Plain arithmetic, as
-- in the other inner loops here: geo allocates a table per call.
local function perpDist(p : Pt, a : Pt, b : Pt) : number
	local abx, aby = b.x - a.x, b.y - a.y
	local apx, apy = p.x - a.x, p.y - a.y
	local l2 = abx * abx + aby * aby
	if l2 < 1e-18 then
		return math.sqrt(apx * apx + apy * apy)
	end
	local f = math.max(0, math.min(1, (apx * abx + apy * aby) / l2))
	local dx, dy = p.x - (a.x + abx * f), p.y - (a.y + aby * f)
	return math.sqrt(dx * dx + dy * dy)
end

function smooth.simplify(points : {Pt}, tolerance : number, clear ?: function(i : integer, j : integer) : boolean)
		: {Pt}, {integer}
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
		local split = 0
		if worst > 0 and worstD > tolerance then
			split = worst
		elseif j - i > 1 and clear ~= nil and not clear(i, j) then
			-- Within tolerance but not clear: every point is near the straight, so halve the range instead.
			split = math.floor((i + j) / 2)
		end
		if split > 0 then
			keep[split] = true
			table.insert(stack, { i, split })
			table.insert(stack, { split, j })
		end
	end
	local result : {Pt} = {}
	local indices : {integer} = {}
	for k = 1, n do
		if keep[k] then
			table.insert(result, points[k])
			table.insert(indices, k)
		end
	end
	return result, indices
end

local function straight(pieces : {Piece}, a : Pt, b : Pt)
	local length = geo.dist(a, b)
	if length > 1e-6 then
		table.insert(pieces, { kind = "straight", a = a, b = b, length = length })
	end
end

-- Pieces for points whose corner tangents (t) fit, tightening any that overlap between fixed points. Also returns,
-- for each arc (by piece index), the point whose corner it rounds; the result has it as the input point's index
-- (src).
-- Where two arcs' tangents overlap on a segment, each first gets its share up to the floor radius (`floor`, 0 for
-- none), and only the rest of the segment is shared in proportion to what each asks beyond that. Shared in proportion
-- to the whole tangents, an arc already tightened to the floor next to a wide one on a short segment was squeezed far
-- below it (an 8 m curve beside a 3 km one on the 54-town map). Only where the floor shares alone don't fit are both
-- below it.
local function build(pts : {Pt}, src : {integer}, theta : {number}, t : {number}, removed : integer,
		guarded : integer, floor : number) : Result, {integer : integer}
	local n = #pts
	local fit : {number} = {}
	local base : {number} = {}
	for i = 1, n do
		fit[i] = t[i]
		base[i] = math.min(t[i], floor * math.tan(theta[i] / 2))
	end
	for i = 1, n - 1 do
		local len = geo.dist(pts[i], pts[i + 1])
		local sum = t[i] + t[i + 1]
		if sum > len and sum > 0 then
			local bi, bj = base[i], base[i + 1]
			local ai, aj : number, number
			if bi + bj >= len then
				local k = len / math.max(bi + bj, 1e-12)
				ai, aj = bi * k, bj * k
			else
				local k = (len - bi - bj) / (sum - bi - bj)
				ai, aj = bi + (t[i] - bi) * k, bj + (t[i + 1] - bj) * k
			end
			fit[i] = math.min(fit[i], ai)
			fit[i + 1] = math.min(fit[i + 1], aj)
		end
	end
	local pieces : {Piece} = {}
	local corners : {integer : integer} = {}
	local inputCorners : {integer : integer} = {}
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
			corners[#pieces] = i
			inputCorners[#pieces] = src[i]
			minRadius = math.min(minRadius, r)
			cur = b
		end
	end
	straight(pieces, cur, pts[n])
	return { pieces = pieces, minRadius = minRadius, removed = removed, guarded = guarded, corners = inputCorners },
		corners
end

-- Points closer than this to the one before are merged into it.
local SAME = 1e-6

-- The point pieceClear asks the guard about, reused (the guard doesn't keep it).
local probe : Pt = { x = 0, y = 0 }

-- Whether the points every `step` (or less) along a piece, both ends included, pass the guard.
local function pieceClear(piece : Piece, guard : Guard, from : integer, to : integer) : boolean
	local m = math.max(1, math.ceil(piece.length / guard.step))
	for k = 0, m do
		probe.x, probe.y = smooth.pointAtXY(piece, piece.length * k / m)
		if not guard.clear(probe, from, to) then
			return false
		end
	end
	return true
end

-- Whether the corners either side of point v, without it, still fit their curves at the floor radius on their
-- segments: dropping a point on a tight loop over open ground would otherwise fold the loop into one sharp corner
-- (a 145° turn with a 13 m curve, where the grid path had room for every curve at the build minimum).
local function fitsWithout(pts : {Pt}, theta : {number}, v : integer, floor : number) : boolean
	local n = #pts
	local function angle(i : integer, prev : integer, next : integer) : number
		if i <= 1 or i >= n then
			return 0
		end
		return geo.turnAngle(geo.sub(pts[i], pts[prev]), geo.sub(pts[next], pts[i]))
	end
	local function tf(th : number) : number
		return floor * math.tan(th / 2)
	end
	local before, after = v - 1, v + 1
	local tb = tf(angle(before, before - 1, after))
	local ta = tf(angle(after, before, after + 1))
	if tb + ta > geo.dist(pts[before], pts[after]) + 1e-6 then
		return false
	end
	if before > 1 and tf(theta[before - 1]) + tb > geo.dist(pts[before - 1], pts[before]) + 1e-6 then
		return false
	end
	if after < n and tf(theta[after + 1]) + ta > geo.dist(pts[after], pts[after + 1]) + 1e-6 then
		return false
	end
	return true
end

function smooth.fillet(points : {Pt}, radius : number, fixed : {boolean}, guard ?: Guard) : Result
	if #points < 2 then
		return { pieces = {}, minRadius = math.huge, removed = 0, guarded = 0, corners = {} }
	end
	-- Merge repeated points (a merged point is fixed if either was); the ends always stay. src is the input index
	-- each point came from, for the guard.
	local pts : {Pt} = {}
	local fix : {boolean} = {}
	local src : {integer} = {}
	local count = #points
	for i, p in ipairs(points) do
		local m = #pts
		if m > 1 and geo.dist(pts[m], p) < SAME then
			-- The last point replaces the one it repeats, so the end stays where it was.
			if i == count then
				pts[m] = p
				src[m] = i
			end
			fix[m] = fix[m] or fixed[i] == true
		elseif m == 1 and i < count and geo.dist(pts[1], p) < SAME then
			fix[1] = true
		else
			table.insert(pts, p)
			table.insert(fix, fixed[i] == true)
			table.insert(src, i)
		end
	end
	fix[1], fix[#pts] = true, true
	-- The guard never makes a curve tighter than this: its minRadius (the track's buildable minimum), at least a step.
	local floor = 0.0
	if guard ~= nil then
		floor = math.max(guard.step, guard.minRadius or 0)
	end
	local removed, guarded = 0, 0
	local theta : {number} = {}
	local t : {number} = {}
	while true do
		local n = #pts
		theta, t = {}, {}
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
			break
		end
		local dropOk = true
		if guard ~= nil then
			local a, b = pts[victim - 1], pts[victim + 1]
			dropOk = pieceClear({ kind = "straight", a = a, b = b, length = geo.dist(a, b) }, guard, src[victim - 1],
				src[victim + 1]) and fitsWithout(pts, theta, victim, floor)
			if not dropOk then
				-- Kept, it may only squeeze the curves on its two segments down to the floor: a curve the game can't
				-- build is worse than one that cuts a corner, so if they don't fit even at the floor it goes anyway.
				local tf = function(i : integer) : number
					return floor * math.tan(theta[i] / 2)
				end
				dropOk = tf(victim - 1) + tf(victim) > geo.dist(a, pts[victim]) + 1e-6
					or tf(victim) + tf(victim + 1) > geo.dist(pts[victim], b) + 1e-6
			end
		end
		if dropOk then
			table.remove(pts, victim)
			table.remove(fix, victim)
			table.remove(src, victim)
			removed = removed + 1
		else
			-- The straight without it would leave the ground the path chose: keep it, and let the arcs either side
			-- tighten to fit instead.
			fix[victim] = true
			guarded = guarded + 1
		end
	end
	local result, corners = build(pts, src, theta, t, removed, guarded, floor)
	if guard == nil then
		return result
	end
	-- Halve the radius of each arc that leaves the guard's ground until every arc is clear, or one reaches the floor
	-- (the guard's minRadius, at least a guard step; that one then stays as it is: a curve the game can't build is
	-- worse than one that cuts a corner). Tightening one arc can give its neighbours room to widen again, so every
	-- arc is checked each round.
	local tightened : {boolean} = {}
	-- Each corner's arc last found clear: an arc the same as then (its neighbours tightened, not it) is clear still,
	-- and isn't checked again (the checks are most of fillet's work).
	local clearArc : {integer : Piece} = {}
	local function sameArc(p : Piece, q : Piece) : boolean
		return q ~= nil and p.radius == q.radius and p.a.x == q.a.x and p.a.y == q.a.y and p.b.x == q.b.x
			and p.b.y == q.b.y
	end
	while true do
		local changed = false
		for k, piece in ipairs(result.pieces) do
			local i = corners[k]
			local clear = true
			if i ~= nil and piece.radius > floor + 1e-6 and not sameArc(piece, clearArc[i]) then
				clear = pieceClear(piece, guard, src[i - 1], src[i + 1])
				if clear then
					clearArc[i] = piece
				end
			end
			if not clear then
				t[i] = math.max(piece.radius / 2, floor) * math.tan(theta[i] / 2)
				if not tightened[i] then
					tightened[i] = true
					guarded = guarded + 1
				end
				changed = true
			end
		end
		if not changed then
			return result
		end
		result, corners = build(pts, src, theta, t, removed, guarded, floor)
	end
end

function smooth.pointAtXY(piece : Piece, d : number) : number, number
	local f = piece.length > 0 and d / piece.length or 0
	local a = piece.a
	if piece.kind == "arc" then
		local c = piece.centre
		local angle = piece.turn * f
		local cs, sn = math.cos(angle), math.sin(angle)
		local rx, ry = a.x - c.x, a.y - c.y
		return c.x + (rx * cs - ry * sn), c.y + (rx * sn + ry * cs)
	end
	local b = piece.b
	return a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f
end

function smooth.pointAt(piece : Piece, d : number) : Pt
	local x, y = smooth.pointAtXY(piece, d)
	return { x = x, y = y }
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
