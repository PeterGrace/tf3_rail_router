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
-- A step from one road cell to another costs this many times its length: entering a road is paid once
-- (roadCrossing), so without it a path could run along a road for free, laid on it in Cheapest and on a long bridge
-- in Fastest. At least 1, so the heuristic stays admissible.
local ROAD_FOLLOW_FACTOR = 1.5

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
	local nx = g.nx
	local fx = math.max(0, math.min(nx - 1, (p.x - g.x0) / g.cell))
	local fy = math.max(0, math.min(g.ny - 1, (p.y - g.y0) / g.cell))
	local cx, cy = math.floor(fx), math.floor(fy)
	local tx, ty = fx - cx, fy - cy
	local cx1, cy1 = math.min(cx + 1, nx - 1), math.min(cy + 1, g.ny - 1)
	-- Zero-based cell coordinates; the height list is one-based.
	local height = g.height
	local top = height[cy * nx + cx + 1] * (1 - tx) + height[cy * nx + cx1 + 1] * tx
	local bottom = height[cy1 * nx + cx + 1] * (1 - tx) + height[cy1 * nx + cx1 + 1] * tx
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

local function pop(s : Search) : integer, number
	local heap, keys = s.heap, s.heapF
	local n = #heap
	local top, topKey = heap[1], keys[1]
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
	return top, topKey
end

-- Search states are (cell, arriving direction): node = (cell - 1) * 16 + k, with k the index into DIRS of the move
-- that entered the cell. Tracking the direction lets a cell be entered several ways, so a costly turn now can be
-- traded for a cheaper path later. FINISH is a virtual node past the goal, reached from a state at the goal cell
-- through the final turn onto the asked arrival direction.
local NDIRS = 16
-- Metres: smaller cost differences are rounding noise.
local EPSILON = 1e-6
-- Give up after this many expansions per cell (there are 16 states per cell). Random small grids with many
-- obstacles needed up to 9.7 before finding their path; 8 cut off 0.3% of them.
local MAX_EXPANSIONS_PER_CELL = 12
local FINISH = 0

local function cellOfNode(node : integer) : integer
	return math.floor((node - 1) / NDIRS) + 1
end

local function cellXY(g : Grid, cell : integer) : integer, integer
	return (cell - 1) % g.nx + 1, math.floor((cell - 1) / g.nx) + 1
end

local SQRT2, SQRT5 = math.sqrt(2), math.sqrt(5)

-- The length of the shortest path from a cell to the goal cell over empty, flat ground, in metres: the offset split
-- between the two move directions either side of it. No step costs less than its length and turns only add, so
-- this never overestimates; it is a distance, so it never drops by more than a step's cost either.
local function heuristic(s : Search, ax : integer, ay : integer) : number
	local dx, dy = math.abs(s.gx - ax), math.abs(s.gy - ay)
	local long, short = math.max(dx, dy), math.min(dx, dy)
	if 2 * short <= long then
		-- Straight moves and knight moves.
		return s.g.cell * ((long - 2 * short) + short * SQRT5)
	end
	-- Knight moves and diagonals.
	return s.g.cell * ((long - short) * SQRT5 + (2 * short - long) * SQRT2)
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

-- 22.5° steps between directions a and b (0 to 8).
local function turnSteps(a : integer, b : integer) : integer
	local t = math.abs(a - b)
	if t > 8 then
		t = 16 - t
	end
	return t
end

-- The least turn penalty still to pay from a state arriving in direction k: the turns from k round to the goal
-- direction add up to at least turnSteps(k, goalDir) steps, and a turn of n steps costs n² ≥ n. Each move's own turn
-- pays for any drop in this, so with the distance it stays a consistent heuristic.
local function turnBound(s : Search, k : integer) : number
	if s.goalDir == 0 then
		return 0
	end
	return s.w.turnPenalty * turnSteps(k, s.goalDir)
end

-- The cost of moving from cell a (at ax, ay) in direction k, turns not included, or nil if the move isn't allowed.
local function moveCost(s : Search, a : integer, ax : integer, ay : integer, k : integer) : number
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
	if g.road[a] and g.road[b] then
		factor = factor * ROAD_FOLLOW_FACTOR
	end
	local cost = length * factor
	if g.road[b] and not g.road[a] then
		cost = cost + w.roadCrossing
	end
	if g.track[b] and not g.track[a] then
		cost = cost + w.trackCrossing
	end
	return cost
end

-- Before the search proper, a flood fill over cells from the start (the same moves, turns, water and costs aside)
-- checks that the goal can be reached at all: otherwise the search would try every (cell, direction) state before
-- giving up. Fills up to `budget` cells; returns the budget left.
local function fillStep(s : Search, budget : integer) : integer
	local g = s.g
	local nx, ny, blocked = g.nx, g.ny, g.blocked
	local seen, queue = s.fillSeen, s.fillQueue
	local head, tail = s.fillHead, #queue
	while budget > 0 and head <= tail do
		local a = queue[head]
		head = head + 1
		budget = budget - 1
		local ax = (a - 1) % nx + 1
		local ay = math.floor((a - 1) / nx) + 1
		for k = 1, NDIRS do
			local d = DIRS[k]
			local dx, dy = d[1], d[2]
			local bx, by = ax + dx, ay + dy
			if bx >= 1 and bx <= nx and by >= 1 and by <= ny then
				local b = (by - 1) * nx + bx
				if not seen[b] and not blocked[b] then
					local open = true
					-- A knight move passes between two cells: both must be passable.
					if dx * dx + dy * dy == 5 then
						open = not blocked[(ay + math.floor(dy / 2) - 1) * nx + ax + math.floor(dx / 2)]
							and not blocked[(ay + math.ceil(dy / 2) - 1) * nx + ax + math.ceil(dx / 2)]
					end
					if open then
						if b == s.goal then
							s.filling, s.fillSeen, s.fillQueue = false, nil, nil
							return budget
						end
						seen[b] = true
						tail = tail + 1
						queue[tail] = b
					end
				end
			end
		end
	end
	s.fillHead = head
	if head > tail then
		-- Nothing left to fill and the goal not met: unreachable.
		s.filling, s.fillSeen, s.fillQueue = false, nil, nil
		s.done = true
	end
	return budget
end

function grid.startSearch(g : Grid, from : Pt, to : Pt, startDir : Pt, goalDir : Pt, w : Weights) : Search
	local sx, sy = grid.cellOf(g, from)
	local gx, gy = grid.cellOf(g, to)
	local s : Search = { g = g, w = w, startPt = from, goalPt = to, goal = grid.index(g, gx, gy), gx = gx, gy = gy,
		goalDir = nearestDir(goalDir), done = false, found = false, expansions = 0, h0 = 0, bestH = 0, heap = {},
		heapF = {}, cost = {}, parent = {}, filling = true, fillQueue = {}, fillHead = 1, fillSeen = {} }
	local start = grid.index(g, sx, sy)
	s.fillQueue[1], s.fillSeen[start] = start, true
	if start == s.goal then
		s.filling, s.fillSeen, s.fillQueue = false, nil, nil
	end
	s.h0 = heuristic(s, sx, sy)
	s.bestH = s.h0
	if g.blocked[s.goal] then
		s.done = true
		return s
	end
	-- Without a start direction, every direction is a start state, so the first move may go any way, unpenalised.
	local k0 = nearestDir(startDir)
	for k = 1, NDIRS do
		if k0 == 0 or k == k0 then
			local node = (start - 1) * NDIRS + k
			s.cost[node] = 0
			push(s, node, s.h0 + turnBound(s, k))
		end
	end
	return s
end

function grid.stepSearch(s : Search, maxExpansions : integer) : boolean
	if s.done then
		return true
	end
	local budget = maxExpansions
	if s.filling then
		budget = fillStep(s, budget)
		if s.done or s.filling then
			return s.done
		end
	end
	local g, w = s.g, s.w
	local cost = s.cost
	-- A backstop for goals that only the turn limit cuts off: by then the search has gone far past any sensible path.
	local maxTotal = math.max(20000, MAX_EXPANSIONS_PER_CELL * g.nx * g.ny)
	while budget > 0 do
		if #s.heap == 0 then
			s.done = true
			return true
		end
		local node, f = pop(s)
		if node == FINISH then
			if f <= cost[FINISH] then
				s.done, s.found = true, true
				return true
			end
		else
			local a = cellOfNode(node)
			local prev = node - (a - 1) * NDIRS
			local base = cost[node]
			local ax, ay = cellXY(g, a)
			local h = heuristic(s, ax, ay)
			-- An entry pushed before the state's cost last fell carries a higher f: skip it. With a consistent
			-- heuristic, a state's first pop is final, so no other check for closed states is needed.
			if f <= base + h + turnBound(s, prev) then
				if s.expansions >= maxTotal then
					s.done = true
					return true
				end
				s.expansions = s.expansions + 1
				budget = budget - 1
				if h < s.bestH then
					s.bestH = h
				end
				if a == s.goal then
					local turn = 0
					if s.goalDir ~= 0 then
						turn = turnSteps(prev, s.goalDir)
					end
					if turn <= MAX_TURN_STEPS then
						local fc = base + w.turnPenalty * turn * turn
						if cost[FINISH] == nil or fc < cost[FINISH] then
							cost[FINISH], s.parent[FINISH] = fc, node
							push(s, FINISH, fc)
						end
					end
				end
				for turn = -MAX_TURN_STEPS, MAX_TURN_STEPS do
					local k = (prev - 1 + turn) % NDIRS + 1
					local c = moveCost(s, a, ax, ay, k)
					if c ~= nil then
						local d = DIRS[k]
						local bx, by = ax + d[1], ay + d[2]
						local nb = (grid.index(g, bx, by) - 1) * NDIRS + k
						local nc = base + c + w.turnPenalty * turn * turn
						-- Gains below EPSILON are rounding (the same cost summed in another order): taking them would
						-- expand a finished state again.
						if cost[nb] == nil or nc < cost[nb] - EPSILON then
							cost[nb], s.parent[nb] = nc, node
							push(s, nb, nc + heuristic(s, bx, by) + turnBound(s, k))
						end
					end
				end
			end
		end
	end
	return false
end

function grid.progress(s : Search) : number
	if s.done or s.h0 <= 0 then
		return 1
	end
	return math.max(0, math.min(1, 1 - s.bestH / s.h0))
end

function grid.path(s : Search) : {Pt}
	if not s.found then
		return nil
	end
	local g = s.g
	local cells : {integer} = {}
	local node = s.parent[FINISH]
	while node ~= nil do
		table.insert(cells, 1, cellOfNode(node))
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
