local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo

local grid : PgraceRailRouterGrid = {}

local type Pt = PgraceRailRouterGeo.Pt
local type Grid = PgraceRailRouterGrid.Grid
local type Search = PgraceRailRouterGrid.Search
local type End = PgraceRailRouterGrid.End
local type Weights = PgraceRailRouterModes.Weights

-- The 16 move directions, counter-clockwise from +x, about 22.5° apart (the knight moves are 26.6° off the axes,
-- close enough for counting turns).
local DIRS : {{integer}} = {
	{ 1, 0 }, { 2, 1 }, { 1, 1 }, { 1, 2 }, { 0, 1 }, { -1, 2 }, { -1, 1 }, { -2, 1 },
	{ -1, 0 }, { -2, -1 }, { -1, -1 }, { -1, -2 }, { 0, -1 }, { 1, -2 }, { 1, -1 }, { 2, -1 },
}
-- A single move may turn at most this many 22.5° steps (90°), where the radius leaves room to turn on every move.
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

-- Cell coordinates within this much of a cell edge count as on it, so rounding never skips a cell the segment
-- touches.
local EDGE_SLACK = 1e-9

-- Every cell is the closed square of side `cell` round its centre, so a segment along an edge or through a corner
-- visits the cells on both sides: never fewer than it really crosses. Goes line by line of cells across the
-- segment's main direction (columns if it runs more along x, rows if more along y), and along each line through the
-- cells the segment spans there, both from a's end to b's, so the cells come in order along it.
function grid.cellsAlong(g : Grid, a : Pt, b : Pt, fn : function(i : integer) : boolean) : boolean
	-- Cell coordinates: cell ix spans u = ix − ½ .. ix + ½. u runs along the main direction, v across it.
	local ax, ay = (a.x - g.x0) / g.cell + 1, (a.y - g.y0) / g.cell + 1
	local bx, by = (b.x - g.x0) / g.cell + 1, (b.y - g.y0) / g.cell + 1
	local alongX = math.abs(bx - ax) >= math.abs(by - ay)
	local ua, va, ub, vb, nu, nv = ax, ay, bx, by, g.nx, g.ny
	if not alongX then
		ua, va, ub, vb, nu, nv = ay, ax, by, bx, g.ny, g.nx
	end
	local function first(lo : number) : integer
		return math.max(1, math.ceil(lo - 0.5 - EDGE_SLACK))
	end
	local function last(hi : number, n : integer) : integer
		return math.min(n, math.floor(hi + 0.5 + EDGE_SLACK))
	end
	local iu0, iu1 = first(math.min(ua, ub)), last(math.max(ua, ub), nu)
	local ustep = 1
	if ub < ua then
		iu0, iu1, ustep = iu1, iu0, -1
	end
	local du = ub - ua
	for iu = iu0, iu1, ustep do
		-- The stretch of the segment within this line of cells (all of it for a single point).
		local vlo, vhi = math.min(va, vb), math.max(va, vb)
		if math.abs(du) > 1e-12 then
			local f0 = math.max(0, math.min(1, (iu - 0.5 - ua) / du))
			local f1 = math.max(0, math.min(1, (iu + 0.5 - ua) / du))
			local v0, v1 = va + (vb - va) * f0, va + (vb - va) * f1
			vlo, vhi = math.min(v0, v1), math.max(v0, v1)
		end
		local iv0, iv1 = first(vlo), last(vhi, nv)
		local vstep = 1
		if vb < va then
			iv0, iv1, vstep = iv1, iv0, -1
		end
		for iv = iv0, iv1, vstep do
			local i : integer
			if alongX then
				i = grid.index(g, iu, iv)
			else
				i = grid.index(g, iv, iu)
			end
			if not fn(i) then
				return false
			end
		end
	end
	return true
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
local function octile(cell : number, dx : integer, dy : integer) : number
	dx, dy = math.abs(dx), math.abs(dy)
	local long, short = math.max(dx, dy), math.min(dx, dy)
	if 2 * short <= long then
		-- Straight moves and knight moves.
		return cell * ((long - 2 * short) + short * SQRT5)
	end
	-- Knight moves and diagonals.
	return cell * ((long - short) * SQRT5 + (2 * short - long) * SQRT2)
end

-- With several goal cells (a run along the arrival ray), the least of those distances: each is a lower bound for
-- reaching its goal cell (and its run to the goal point only adds), and the least of consistent heuristics is
-- consistent.
local function heuristic(s : Search, ax : integer, ay : integer) : number
	local goals = s.goals
	local h = octile(s.g.cell, s.gx - ax, s.gy - ay)
	for i = 2, #goals do
		local e = goals[i]
		local hi = octile(s.g.cell, e.x - ax, e.y - ay)
		if hi < h then
			h = hi
		end
	end
	return h
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
	local length = g.cell * math.sqrt(d[1] * d[1] + d[2] * d[2])
	local grade = math.abs(g.height[b] - g.height[a]) / length
	-- A knight move passes between two cells: both must be passable, and the ground there (their mean height, at the
	-- move's midpoint) counts towards its grade, or the move hops over a ridge one cell wide.
	if math.abs(d[1]) + math.abs(d[2]) == 3 then
		local m1 = grid.index(g, ax + math.floor(d[1] / 2), ay + math.floor(d[2] / 2))
		local m2 = grid.index(g, ax + math.ceil(d[1] / 2), ay + math.ceil(d[2] / 2))
		if g.blocked[m1] or g.blocked[m2] then
			return nil
		end
		overWater = overWater or g.water[m1] or g.water[m2]
		local hm = (g.height[m1] + g.height[m2]) / 2
		grade = math.max(grade, math.abs(hm - g.height[a]) / (length / 2), math.abs(g.height[b] - hm) / (length / 2))
	end
	local factor = 1.0
	if overWater then
		factor = w.bridgeFactor
	else
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
						if s.goalCells[b] ~= nil then
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

-- The turn model for a curve radius: a 22.5° arc of radius R takes R·tan(11.25°) of straight on each side of its
-- corner, so two turns need 2·R·tan(11.25°) between them. Where every move is at least that long (no more than a cell),
-- any move may turn, by up to 90° (the old model, kept exactly). Otherwise a move may turn by one step only, and a
-- turning move runs on straight in its new direction for as many steps as that length takes: the search's states stay
-- (cell, direction), each one free to turn again.
local function turnModel(s : Search, cell : number, radius : number)
	local straight = 2 * radius * math.tan(math.pi / 16)
	s.straightSteps = {}
	if straight <= cell + EPSILON then
		s.maxTurn = MAX_TURN_STEPS
		for k = 1, NDIRS do
			s.straightSteps[k] = 1
		end
		return
	end
	s.maxTurn = 1
	for k, d in ipairs(DIRS) do
		local length = cell * math.sqrt(d[1] * d[1] + d[2] * d[2])
		s.straightSteps[k] = math.max(1, math.ceil(straight / length - EPSILON))
	end
end

-- The points along a ray from p in direction dir (a unit vector), one cell apart, out to `run` metres: p itself, then
-- each one whose straight from p stays inside the grid and off blocked, water, road and track cells (the first that
-- doesn't ends the ray). Each costs the straight from p to it, as moves do (length, and the slope penalty over the
-- grade between neighbouring points). One per cell, the nearest to p.
local function ray(g : Grid, w : Weights, p : Pt, dir : Pt, run : number) : {End}
	local ix, iy = grid.cellOf(g, p)
	local ends : {End} = { { pt = p, cell = grid.index(g, ix, iy), x = ix, y = iy, cost = 0 } }
	local seen : {integer : boolean} = { [ends[1].cell] = true }
	local prev, cost, d = p, 0.0, g.cell
	while d <= run + EPSILON do
		local q = geo.add(p, geo.scale(dir, d))
		if not grid.inside(g, q) or not grid.cellsAlong(g, prev, q, function(i : integer) : boolean
				return not (g.blocked[i] or g.water[i] or g.road[i] or g.track[i])
			end) then
			break
		end
		local grade = math.abs(grid.heightAt(g, q) - grid.heightAt(g, prev)) / g.cell
		local factor = 1.0
		if grade > w.maxGrade then
			factor = 1 + w.slopePenalty * (grade - w.maxGrade) / w.maxGrade
		end
		cost = cost + g.cell * factor
		local qx, qy = grid.cellOf(g, q)
		local cell = grid.index(g, qx, qy)
		if not seen[cell] then
			seen[cell] = true
			table.insert(ends, { pt = q, cell = cell, x = qx, y = qy, cost = cost })
		end
		prev, d = q, d + g.cell
	end
	return ends
end

function grid.startSearch(g : Grid, from : Pt, to : Pt, startDir : Pt, goalDir : Pt, w : Weights,
		radius ?: number, maxCost ?: number, startRun ?: number, goalRun ?: number) : Search
	local sx, sy = grid.cellOf(g, from)
	local gx, gy = grid.cellOf(g, to)
	local s : Search = { g = g, w = w, startPt = from, goalPt = to, goal = grid.index(g, gx, gy), gx = gx, gy = gy,
		goalDir = nearestDir(goalDir), radius = radius or w.minRadius, maxCost = maxCost or math.huge, done = false,
		found = false, expansions = 0, h0 = 0, bestH = 0, heap = {}, heapF = {}, cost = {}, parent = {},
		origin = {}, finishDir = 0, finishSteps = 0, finishGoal = 1, filling = true, fillQueue = {}, fillHead = 1,
		fillSeen = {} }
	turnModel(s, g.cell, s.radius)
	local start = grid.index(g, sx, sy)
	s.start = start
	-- The ends may move out along the stations' axes: the start forward along startDir, the goal back against
	-- goalDir (only with a direction to move along).
	local k0 = nearestDir(startDir)
	if k0 ~= 0 and startRun ~= nil and startRun > 0 then
		s.starts = ray(g, w, from, geo.norm(startDir), startRun)
	else
		s.starts = { { pt = from, cell = start, x = sx, y = sy, cost = 0 } }
	end
	if s.goalDir ~= 0 and goalRun ~= nil and goalRun > 0 then
		s.goals = ray(g, w, to, geo.scale(geo.norm(goalDir), -1), goalRun)
	else
		s.goals = { { pt = to, cell = s.goal, x = gx, y = gy, cost = 0 } }
	end
	s.goalCells = {}
	for i, e in ipairs(s.goals) do
		if not g.blocked[e.cell] then
			s.goalCells[e.cell] = i
		end
	end
	s.h0 = heuristic(s, sx, sy)
	s.bestH = s.h0
	if next(s.goalCells) == nil then
		s.done = true
		return s
	end
	for __, e in ipairs(s.starts) do
		if s.goalCells[e.cell] ~= nil then
			s.filling = false
		end
		if not s.fillSeen[e.cell] then
			s.fillSeen[e.cell] = true
			table.insert(s.fillQueue, e.cell)
		end
	end
	if not s.filling then
		s.fillSeen, s.fillQueue = nil, nil
	end
	-- Without a start direction, every direction is a start state, so the first move may go any way, unpenalised.
	for i, e in ipairs(s.starts) do
		for k = 1, NDIRS do
			if k0 == 0 or k == k0 then
				local node = (e.cell - 1) * NDIRS + k
				if s.cost[node] == nil then
					s.cost[node], s.origin[node] = e.cost, i
					push(s, node, e.cost + heuristic(s, e.x, e.y) + turnBound(s, k))
				end
			end
		end
	end
	return s
end

-- The path's ends are the asked points, not their cells' centres, so its first and last segments run off the lines
-- between centres that moves are checked along: a diagonal past a blocked cell's corner then cuts into it. Whether
-- the segment from p to q is clear of blocked cells.
local function segmentClear(g : Grid, p : Pt, q : Pt) : boolean
	return grid.cellsAlong(g, p, q, function(i : integer) : boolean
		return not g.blocked[i]
	end)
end

-- Offers the finish at cost fc, reached from state `from` by `steps` more steps in direction k (0 steps: from a state
-- at the goal cell itself).
local function finish(s : Search, fc : number, from : integer, k : integer, steps : integer, goal : integer)
	fc = fc + s.goals[goal].cost
	if s.cost[FINISH] == nil or fc < s.cost[FINISH] then
		s.cost[FINISH], s.parent[FINISH], s.finishDir, s.finishSteps, s.finishGoal = fc, from, k, steps, goal
		push(s, FINISH, fc)
	end
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
		if f > s.maxCost then
			-- Everything left costs more than the caller will take.
			s.done = true
			return true
		end
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
				local maxTurn = s.maxTurn
				-- A start state not reached any cheaper way: its first move runs from its start point.
				local origin : Pt = nil
				if s.parent[node] == nil and s.origin[node] ~= nil then
					origin = s.starts[s.origin[node]].pt
				end
				local goalHere = s.goalCells[a]
				if goalHere ~= nil then
					-- The final turn onto the asked direction obeys the same limit as any other: this state is free to
					-- turn, and the room beyond the goal (a station's extension) takes the far side of the curve.
					local turn = 0
					if s.goalDir ~= 0 then
						turn = turnSteps(prev, s.goalDir)
					end
					-- The last segment runs from the cell before (or the start point) to the goal point.
					local before = origin
					if before == nil then
						before = grid.centre(g, ax - DIRS[prev][1], ay - DIRS[prev][2])
					end
					if turn <= maxTurn and segmentClear(g, before, s.goals[goalHere].pt) then
						finish(s, base + w.turnPenalty * turn * turn, node, prev, 0, goalHere)
					end
				end
				for turn = -maxTurn, maxTurn do
					local k = (prev - 1 + turn) % NDIRS + 1
					-- A turning move runs on straight for its whole minimum length; every step of it is checked and
					-- costed as a move of its own.
					local steps = 1
					if turn ~= 0 then
						steps = s.straightSteps[k]
					end
					local d = DIRS[k]
					local bx, by, b = ax, ay, a
					local nc = base + w.turnPenalty * turn * turn
					for j = 1, steps do
						local c = moveCost(s, b, bx, by, k)
						if c == nil then
							nc = nil
							break
						end
						if j == 1 and origin ~= nil
							and not segmentClear(g, origin, grid.centre(g, bx + d[1], by + d[2])) then
							nc = nil
							break
						end
						bx, by = bx + d[1], by + d[2]
						b = (by - 1) * g.nx + bx
						nc = nc + c
						-- Passing through the goal part-way along the straight finishes there, but only heading the
						-- asked way: a turn here would come too soon after the last.
						local goalThere = s.goalCells[b]
						if j < steps and goalThere ~= nil and (s.goalDir == 0 or k == s.goalDir)
							and segmentClear(g, grid.centre(g, bx - d[1], by - d[2]), s.goals[goalThere].pt) then
							finish(s, nc, node, k, j, goalThere)
						end
					end
					if nc ~= nil then
						local nb = (b - 1) * NDIRS + k
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
	local nodes : {integer} = {}
	local node = s.parent[FINISH]
	while node ~= nil do
		table.insert(nodes, 1, node)
		node = s.parent[node]
	end
	-- A move may be a turn and its straight, several cells long: fill in the cells along it, stepping in the
	-- direction it arrived in.
	local cells : {integer} = { cellOfNode(nodes[1]) }
	local function walk(k : integer, steps : integer, target : integer)
		local d = DIRS[k]
		local x, y = cellXY(g, cells[#cells])
		for __ = 1, steps do
			x, y = x + d[1], y + d[2]
			local c = grid.index(g, x, y)
			table.insert(cells, c)
			if c == target then
				return
			end
		end
	end
	for i = 2, #nodes do
		local c = cellOfNode(nodes[i])
		local k = nodes[i] - (c - 1) * NDIRS
		walk(k, s.straightSteps[k], c)
	end
	local goal = s.goals[s.finishGoal]
	walk(s.finishDir, s.finishSteps, goal.cell)
	-- The ends are the points along the stations' axes the path left and reached them at.
	local first, last = s.starts[s.origin[nodes[1]]].pt, goal.pt
	if #cells < 2 then
		return { first, last }
	end
	local pts : {Pt} = {}
	for i, c in ipairs(cells) do
		local ix, iy = cellXY(g, c)
		pts[i] = grid.centre(g, ix, iy)
	end
	pts[1] = first
	pts[#pts] = last
	return pts
end

return grid
