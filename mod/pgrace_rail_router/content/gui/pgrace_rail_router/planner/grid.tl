local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo

local grid : PgraceRailRouterGrid = {}

local type Pt = PgraceRailRouterGeo.Pt
local type Grid = PgraceRailRouterGrid.Grid
local type Search = PgraceRailRouterGrid.Search
local type Weights = PgraceRailRouterModes.Weights

-- The 16 move directions, counter-clockwise from +x, about 22.5° apart (the knight moves are 26.6° off the axes,
-- close enough for counting turns).
local DIRS : {{integer}} = {
	{ 1, 0 }, { 2, 1 }, { 1, 1 }, { 1, 2 }, { 0, 1 }, { -1, 2 }, { -1, 1 }, { -2, 1 },
	{ -1, 0 }, { -2, -1 }, { -1, -1 }, { -1, -2 }, { 0, -1 }, { 1, -2 }, { 1, -1 }, { 2, -1 },
}
-- A single move may turn at most this many 22.5° steps (90°).
local MAX_TURN_STEPS = 4

function grid.new(x0 : number, y0 : number, cell : number, nx : integer, ny : integer) : Grid
	local g : Grid = { x0 = x0, y0 = y0, cell = cell, nx = nx, ny = ny, height = {}, water = {}, blocked = {},
		road = {}, track = {} }
	for i = 1, nx * ny do
		g.height[i] = 0
		g.water[i] = false
		g.blocked[i] = false
		g.road[i] = false
		g.track[i] = false
	end
	return g
end

function grid.index(g : Grid, ix : integer, iy : integer) : integer
	return (iy - 1) * g.nx + ix
end

function grid.inside(g : Grid, p : Pt) : boolean
	local fx = (p.x - g.x0) / g.cell + 1
	local fy = (p.y - g.y0) / g.cell + 1
	return fx >= 0.5 and fx <= g.nx + 0.5 and fy >= 0.5 and fy <= g.ny + 0.5
end

function grid.cellOf(g : Grid, p : Pt) : integer, integer
	local ix = math.floor((p.x - g.x0) / g.cell + 1.5)
	local iy = math.floor((p.y - g.y0) / g.cell + 1.5)
	return math.max(1, math.min(g.nx, ix)), math.max(1, math.min(g.ny, iy))
end

function grid.centre(g : Grid, ix : integer, iy : integer) : Pt
	return { x = g.x0 + (ix - 1) * g.cell, y = g.y0 + (iy - 1) * g.cell }
end

function grid.heightAt(g : Grid, p : Pt) : number
	local fx = math.max(0, math.min(g.nx - 1, (p.x - g.x0) / g.cell))
	local fy = math.max(0, math.min(g.ny - 1, (p.y - g.y0) / g.cell))
	local cx, cy = math.floor(fx), math.floor(fy)
	local tx, ty = fx - cx, fy - cy
	local cx1, cy1 = math.min(cx + 1, g.nx - 1), math.min(cy + 1, g.ny - 1)
	-- Zero-based cell coordinates.
	local function h(x : integer, y : integer) : number
		return g.height[y * g.nx + x + 1]
	end
	local top = h(cx, cy) * (1 - tx) + h(cx1, cy) * tx
	local bottom = h(cx, cy1) * (1 - tx) + h(cx1, cy1) * tx
	return top * (1 - ty) + bottom * ty
end

function grid.waterAt(g : Grid, p : Pt) : boolean
	local ix, iy = grid.cellOf(g, p)
	return g.water[grid.index(g, ix, iy)]
end

-- A binary min-heap on f, with duplicates allowed (stale entries are skipped when popped).
local function push(s : Search, node : integer, f : number)
	local heap, keys = s.heap, s.heapF
	local i = #heap + 1
	heap[i], keys[i] = node, f
	while i > 1 do
		local parent = math.floor(i / 2)
		if keys[parent] <= keys[i] then
			break
		end
		heap[parent], heap[i] = heap[i], heap[parent]
		keys[parent], keys[i] = keys[i], keys[parent]
		i = parent
	end
end

local function pop(s : Search) : integer
	local heap, keys = s.heap, s.heapF
	local n = #heap
	local top = heap[1]
	heap[1], keys[1] = heap[n], keys[n]
	heap[n], keys[n] = nil, nil
	n = n - 1
	local i = 1
	while true do
		local l, r = 2 * i, 2 * i + 1
		local smallest = i
		if l <= n and keys[l] < keys[smallest] then
			smallest = l
		end
		if r <= n and keys[r] < keys[smallest] then
			smallest = r
		end
		if smallest == i then
			break
		end
		heap[smallest], heap[i] = heap[i], heap[smallest]
		keys[smallest], keys[i] = keys[i], keys[smallest]
		i = smallest
	end
	return top
end

local function cellXY(g : Grid, node : integer) : integer, integer
	return (node - 1) % g.nx + 1, math.floor((node - 1) / g.nx) + 1
end

-- Straight-line metres to the goal: no step costs less than its length, so this never overestimates.
local function heuristic(s : Search, node : integer) : number
	local ax, ay = cellXY(s.g, node)
	local gx, gy = cellXY(s.g, s.goal)
	return s.g.cell * math.sqrt((gx - ax) * (gx - ax) + (gy - ay) * (gy - ay))
end

local function nearestDir(d : Pt) : integer
	if geo.len(d) < 1e-9 then
		return 0
	end
	local unit = geo.norm(d)
	local best, bestDot = 0, -math.huge
	for k, v in ipairs(DIRS) do
		local dot = geo.dot(unit, geo.norm({ x = v[1], y = v[2] }))
		if dot > bestDot then
			best, bestDot = k, dot
		end
	end
	return best
end

-- The cost of moving from cell a (at ax, ay) in direction k, or nil if the move isn't allowed.
local function stepCost(s : Search, a : integer, ax : integer, ay : integer, k : integer) : number
	local g, w = s.g, s.w
	local d = DIRS[k]
	local bx, by = ax + d[1], ay + d[2]
	if bx < 1 or bx > g.nx or by < 1 or by > g.ny then
		return nil
	end
	local b = grid.index(g, bx, by)
	if g.blocked[b] then
		return nil
	end
	local overWater = g.water[a] or g.water[b]
	-- A knight move passes between two cells: both must be passable.
	if math.abs(d[1]) + math.abs(d[2]) == 3 then
		local m1 = grid.index(g, ax + math.floor(d[1] / 2), ay + math.floor(d[2] / 2))
		local m2 = grid.index(g, ax + math.ceil(d[1] / 2), ay + math.ceil(d[2] / 2))
		if g.blocked[m1] or g.blocked[m2] then
			return nil
		end
		overWater = overWater or g.water[m1] or g.water[m2]
	end
	local turnSteps = 0
	local prev = s.dir[a] or 0
	if prev ~= 0 then
		turnSteps = math.abs(k - prev)
		if turnSteps > 8 then
			turnSteps = 16 - turnSteps
		end
		if turnSteps > MAX_TURN_STEPS then
			return nil
		end
	end
	local length = g.cell * math.sqrt(d[1] * d[1] + d[2] * d[2])
	local factor = 1.0
	if overWater then
		factor = w.bridgeFactor
	else
		local grade = math.abs(g.height[b] - g.height[a]) / length
		if grade > w.maxGrade then
			factor = 1 + w.slopePenalty * (grade - w.maxGrade) / w.maxGrade
		end
	end
	local cost = length * factor + w.turnPenalty * turnSteps * turnSteps
	if g.road[b] and not g.road[a] then
		cost = cost + w.roadCrossing
	end
	if g.track[b] and not g.track[a] then
		cost = cost + w.trackCrossing
	end
	return cost
end

function grid.startSearch(g : Grid, from : Pt, to : Pt, startDir : Pt, w : Weights) : Search
	local sx, sy = grid.cellOf(g, from)
	local gx, gy = grid.cellOf(g, to)
	local s : Search = { g = g, w = w, startPt = from, goalPt = to, goal = grid.index(g, gx, gy), done = false,
		found = false, expansions = 0, heap = {}, heapF = {}, cost = {}, parent = {}, dir = {}, closed = {} }
	local start = grid.index(g, sx, sy)
	s.cost[start] = 0
	s.dir[start] = nearestDir(startDir)
	push(s, start, heuristic(s, start))
	return s
end

function grid.stepSearch(s : Search, maxExpansions : integer) : boolean
	if s.done then
		return true
	end
	local g = s.g
	local budget = maxExpansions
	while budget > 0 do
		if #s.heap == 0 then
			s.done = true
			return true
		end
		local a = pop(s)
		if not s.closed[a] then
			s.closed[a] = true
			s.expansions = s.expansions + 1
			budget = budget - 1
			if a == s.goal then
				s.done, s.found = true, true
				return true
			end
			local ax, ay = cellXY(g, a)
			for k = 1, #DIRS do
				local c = stepCost(s, a, ax, ay, k)
				if c ~= nil then
					local d = DIRS[k]
					local b = grid.index(g, ax + d[1], ay + d[2])
					local nc = s.cost[a] + c
					if not s.closed[b] and (s.cost[b] == nil or nc < s.cost[b]) then
						s.cost[b], s.parent[b], s.dir[b] = nc, a, k
						push(s, b, nc + heuristic(s, b))
					end
				end
			end
		end
	end
	return false
end

function grid.progress(s : Search) : number
	if s.done then
		return 1
	end
	return math.min(1, s.expansions / (s.g.nx * s.g.ny))
end

function grid.path(s : Search) : {Pt}
	if not s.found then
		return nil
	end
	local g = s.g
	local cells : {integer} = {}
	local node = s.goal
	while node ~= nil do
		table.insert(cells, 1, node)
		node = s.parent[node]
	end
	if #cells < 2 then
		return { s.startPt, s.goalPt }
	end
	local pts : {Pt} = {}
	for i, c in ipairs(cells) do
		local ix, iy = cellXY(g, c)
		pts[i] = grid.centre(g, ix, iy)
	end
	pts[1] = s.startPt
	pts[#pts] = s.goalPt
	return pts
end

return grid
