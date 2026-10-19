local midline : PgraceRailRouterMidline = {}

local type Frame = PgraceRailRouterMidline.Frame
local type Pt = PgraceRailRouterGeo.Pt
local type Pt3 = PgraceRailRouterNetwork.Pt3

midline.STEP = 5.0

function midline.line(origin : Pt, dir : Pt, z : number, grade : number, length : number) : Frame
	return {
		pts = { { x = origin.x, y = origin.y, z = z },
			{ x = origin.x + dir.x * length, y = origin.y + dir.y * length, z = z + grade * length } },
		dirs = { { x = dir.x, y = dir.y }, { x = dir.x, y = dir.y } },
		grades = { grade, grade },
		step = length, length = length,
	}
end

local function unit(x : number, y : number) : Pt
	local d = math.sqrt(x * x + y * y)
	if d < 1e-12 then
		return { x = 1, y = 0 }
	end
	return { x = x / d, y = y / d }
end

function midline.fromPoints(pts : {Pt3}, step : number) : Frame
	-- Resample by arc length (in plan).
	local out : {Pt3} = { { x = pts[1].x, y = pts[1].y, z = pts[1].z } }
	local want, run = step, 0.0
	for i = 2, #pts do
		local a, b = pts[i - 1], pts[i]
		local l = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
		while l > 1e-12 and run + l >= want - 1e-9 do
			local u = (want - run) / l
			table.insert(out, { x = a.x + (b.x - a.x) * u, y = a.y + (b.y - a.y) * u, z = a.z + (b.z - a.z) * u })
			want = want + step
		end
		run = run + l
	end
	local last = pts[#pts]
	local length = (#out - 1) * step
	if run - length > 1e-6 then
		-- The end, short of a whole step: kept at x = length + its own distance by stretching the last step.
		table.insert(out, { x = last.x, y = last.y, z = last.z })
		length = run
	end
	local n = #out
	local dirs : {Pt} = {}
	local grades : {number} = {}
	for i = 1, n do
		local a, b = out[math.max(1, i - 1)], out[math.min(n, i + 1)]
		-- An end sample's chord to its one neighbour is half a step off the true tangent on a curve, so the ends
		-- take the input polyline's first and last segment instead.
		if i == 1 then
			a, b = pts[1], pts[2]
		elseif i == n then
			a, b = pts[#pts - 1], pts[#pts]
		end
		dirs[i] = unit(b.x - a.x, b.y - a.y)
		local l = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
		grades[i] = l > 1e-12 and (b.z - a.z) / l or 0
	end
	-- Samples are `step` apart but the last, which may be nearer (at x = length; see `segment`).
	local f : Frame = { pts = out, dirs = dirs, grades = grades, step = step, length = length }
	return f
end

-- The segment holding x (1 .. #pts − 1) and the fraction along it (outside [0, 1] beyond the ends).
local function segment(f : Frame, x : number) : integer, number
	local n = #f.pts
	local i = math.floor(x / f.step) + 1
	if i < 1 then
		i = 1
	elseif i > n - 1 then
		i = n - 1
	end
	local x0 = (i - 1) * f.step
	local x1 = i == n - 1 and f.length or i * f.step
	return i, (x - x0) / (x1 - x0)
end

function midline.at(f : Frame, x : number) : Pt3, Pt
	local n = #f.pts
	if x <= 0 or x >= f.length then
		local k = x <= 0 and 1 or n
		local d = x <= 0 and x or x - f.length
		local p, dir = f.pts[k], f.dirs[k]
		return { x = p.x + dir.x * d, y = p.y + dir.y * d, z = p.z + f.grades[k] * d }, { x = dir.x, y = dir.y }
	end
	local i, u = segment(f, x)
	local a, b = f.pts[i], f.pts[i + 1]
	local da, db = f.dirs[i], f.dirs[i + 1]
	return { x = a.x + (b.x - a.x) * u, y = a.y + (b.y - a.y) * u, z = a.z + (b.z - a.z) * u },
		unit(da.x + (db.x - da.x) * u, da.y + (db.y - da.y) * u)
end

function midline.grade(f : Frame, x : number) : number
	if x <= 0 then
		return f.grades[1]
	elseif x >= f.length then
		return f.grades[#f.grades]
	end
	local i = segment(f, x)
	local a, b = f.pts[i], f.pts[i + 1]
	local l = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
	return l > 1e-12 and (b.z - a.z) / l or f.grades[i]
end

function midline.world(f : Frame, x : number, y : number) : Pt3
	local p, d = midline.at(f, x)
	return { x = p.x - d.y * y, y = p.y + d.x * y, z = p.z }
end

function midline.vector(f : Frame, x : number, tx : number, ty : number) : Pt3
	local __, d = midline.at(f, x)
	return { x = d.x * tx - d.y * ty, y = d.y * tx + d.x * ty, z = midline.grade(f, x) * tx }
end

function midline.project(f : Frame, p : Pt) : number, number
	local n = #f.pts
	local bestX, bestY, bestD = 0.0, 0.0, math.huge
	for i = 1, n - 1 do
		local a, b = f.pts[i], f.pts[i + 1]
		local x0 = (i - 1) * f.step
		local x1 = i == n - 1 and f.length or i * f.step
		local ex, ey = b.x - a.x, b.y - a.y
		local l2 = ex * ex + ey * ey
		local u = l2 > 1e-12 and ((p.x - a.x) * ex + (p.y - a.y) * ey) / l2 or 0
		-- Clamped between samples, except past the midline's two ends, where it runs on straight.
		if (u < 0 and i > 1) then
			u = 0
		elseif u > 1 and i < n - 1 then
			u = 1
		end
		local qx, qy = a.x + ex * u, a.y + ey * u
		local d = (p.x - qx) ^ 2 + (p.y - qy) ^ 2
		if d < bestD then
			local l = math.sqrt(l2)
			bestD = d
			bestX = x0 + (x1 - x0) * u
			bestY = l > 1e-12 and ((p.y - qy) * ex - (p.x - qx) * ey) / l or 0
		end
	end
	return bestX, bestY
end

function midline.straightUntil(f : Frame, x0 : number, tol : number) : number
	local __, d0 = midline.at(f, x0)
	local i = segment(f, math.max(0, x0))
	local prevX, prevS = x0, 0.0
	for k = i + 1, #f.pts do
		local x = k == #f.pts and f.length or (k - 1) * f.step
		local d = f.dirs[k]
		local s = math.abs(d0.x * d.y - d0.y * d.x)
		if s > tol then
			-- Between the last sample within it and this one.
			return prevX + (x - prevX) * (tol - prevS) / (s - prevS)
		end
		prevX, prevS = x, s
	end
	return f.length
end

return midline
