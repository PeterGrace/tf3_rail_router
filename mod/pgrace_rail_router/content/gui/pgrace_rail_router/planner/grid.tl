local geo = ug_require "pgrace_rail_router::/gui/pgrace_rail_router/planner/geo.tl" as PgraceRailRouterGeo

local grid : PgraceRailRouterGrid = {}

local type Pt = PgraceRailRouterGeo.Pt
local type Grid = PgraceRailRouterGrid.Grid
local type Search = PgraceRailRouterGrid.Search
local type End = PgraceRailRouterGrid.End
local type Store = PgraceRailRouterGrid.Store
local type Weights = PgraceRailRouterModes.Weights

-- The 16 move directions, counter-clockwise from +x, about 22.5° apart (the knight moves are 26.6° off the axes,
-- close enough for counting turns).
local DIRS : {{integer}} = {
	{ 1, 0 }, { 2, 1 }, { 1, 1 }, { 1, 2 }, { 0, 1 }, { -1, 2 }, { -1, 1 }, { -2, 1 },
	{ -1, 0 }, { -2, -1 }, { -1, -1 }, { -1, -2 }, { 0, -1 }, { 1, -2 }, { 1, -1 }, { 2, -1 },
}
grid.DIRS = DIRS
-- A single move may turn at most this many 22.5° steps (90°), where the radius leaves room to turn on every move.
local MAX_TURN_STEPS = 4
-- Where every move may turn, each metre by which the straight between two corners falls short of what curves of the
-- search's radius need costs this many metres of plain track: about the track a path with room for those curves
-- would take (see turnModel).
local SHORTFALL_FACTOR = 1.0
-- A step from one road cell to another costs this many times its length: entering a road is paid once
-- (roadCrossing), so without it a path could run along a road for free, laid on it in Cheapest and on a long bridge
-- in Fastest. At least 1, so the heuristic stays admissible.
local ROAD_FOLLOW_FACTOR = 1.5

function grid.new(x0 : number, y0 : number, cell : number, nx : integer, ny : integer) : Grid
	local g : Grid = { x0 = x0, y0 = y0, cell = cell, nx = nx, ny = ny, height = {}, water = {}, blocked = {},
		road = {}, track = {}, junction = {}, shore = {} }
	for i = 1, nx * ny do
		g.height[i] = 0
		g.water[i] = false
		g.blocked[i] = false
		g.road[i] = false
		g.track[i] = false
		g.junction[i] = false
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

grid.SHORE_SUB = 4

function grid.shoreCells(g : Grid) : {integer}
	local result : {integer} = {}
	for iy = 1, g.ny do
		for ix = 1, g.nx do
			local i = grid.index(g, ix, iy)
			local w = g.water[i]
			local shore = false
			for dy = -1, 1 do
				for dx = -1, 1 do
					local jx, jy = ix + dx, iy + dy
					if not shore and jx >= 1 and jx <= g.nx and jy >= 1 and jy <= g.ny
							and g.water[grid.index(g, jx, jy)] ~= w then
						shore = true
					end
				end
			end
			if shore then
				table.insert(result, i)
			end
		end
	end
	return result
end

function grid.shorePoint(g : Grid, i : integer, k : integer) : Pt
	local n = grid.SHORE_SUB
	local ix, iy = (i - 1) % g.nx + 1, (i - 1) // g.nx + 1
	local kx, ky = (k - 1) % n + 1, (k - 1) // n + 1
	local d = g.cell / n
	return { x = g.x0 + (ix - 1) * g.cell + (kx - 0.5 - n / 2) * d, y = g.y0 + (iy - 1) * g.cell + (ky - 0.5 - n / 2) * d }
end

-- Fine point (jx, jy) (1-based over the whole grid, SHORE_SUB per cell side): water?
local function fineWater(g : Grid, jx : integer, jy : integer) : boolean
	local n = grid.SHORE_SUB
	jx = math.max(1, math.min(g.nx * n, jx))
	jy = math.max(1, math.min(g.ny * n, jy))
	local ix, iy = (jx - 1) // n + 1, (jy - 1) // n + 1
	local i = grid.index(g, ix, iy)
	local fine = g.shore ~= nil and g.shore[i]
	if fine ~= nil then
		return fine[((jy - 1) % n) * n + (jx - 1) % n + 1]
	end
	return g.water[i]
end

function grid.waterAt(g : Grid, p : Pt) : boolean
	local ix, iy = grid.cellOf(g, p)
	return g.water[grid.index(g, ix, iy)]
end

function grid.wetAt(g : Grid, p : Pt) : boolean
	local n = grid.SHORE_SUB
	local d = g.cell / n
	-- Fine point j sits at x0 - cell/2 + (j - 0.5) d.
	local fx = (p.x - (g.x0 - g.cell / 2)) / d + 0.5
	local fy = (p.y - (g.y0 - g.cell / 2)) / d + 0.5
	local jx, jy = math.floor(fx), math.floor(fy)
	return fineWater(g, jx, jy) or fineWater(g, jx + 1, jy) or fineWater(g, jx, jy + 1) or fineWater(g, jx + 1, jy + 1)
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

-- A binary min-heap on f, with duplicates allowed (stale entries are skipped when popped). Its tables are the
-- store's, reused by every search on the grid, so entries past heapN are left over, not cleared.
local function push(s : Search, node : integer, f : number)
	local heap, keys = s.heap, s.heapF
	local i = s.heapN + 1
	s.heapN = i
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
	local n = s.heapN
	local top, topKey = heap[1], keys[1]
	heap[1], keys[1] = heap[n], keys[n]
	n = n - 1
	s.heapN = n
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
	if node < 0 then
		node = -node
	end
	return math.floor((node - 1) / NDIRS) + 1
end

-- A state's arriving direction (1..16).
local function dirOfNode(node : integer) : integer
	if node < 0 then
		node = -node
	end
	return (node - 1) % NDIRS + 1
end

local function cellXY(g : Grid, cell : integer) : integer, integer
	return (cell - 1) % g.nx + 1, math.floor((cell - 1) / g.nx) + 1
end

-- Cells along a row per page of the store: a page holds BLOCK × 16 states (a 16-cell stretch of a row, every
-- arriving direction), so a search makes pages only where it goes, a few KB each.
local BLOCK = 16

-- The grid's store (see Store), made on its first search.
local function storeOf(g : Grid) : Store
	if g.store == nil then
		g.store = { current = 0, nextId = 1, pageSize = BLOCK * NDIRS, blocksPerRow = math.ceil(g.nx / BLOCK),
			stamp = {}, cost = {}, parent = {}, heap = {}, heapF = {}, fillStamp = {}, fillQueue = {} }
	end
	return g.store
end

-- The fill's stamps for grid row iy, made (none queued) if they aren't yet.
local function fillRow(st : Store, nx : integer, iy : integer) : {integer}
	local row = st.fillStamp[iy]
	if row == nil then
		row = {}
		for i = 1, nx do
			row[i] = 0
		end
		st.fillStamp[iy] = row
	end
	return row
end

-- The store's page p, made (every state unreached) if it isn't yet; its stamps.
local function page(st : Store, p : integer) : {integer}
	local stamp = st.stamp[p]
	if stamp == nil then
		local cost : {number} = {}
		local parent : {integer} = {}
		stamp = {}
		for i = 1, st.pageSize do
			stamp[i], cost[i], parent[i] = 0, 0, 0
		end
		st.stamp[p], st.cost[p], st.parent[p] = stamp, cost, parent
	end
	return stamp
end

-- Where the store keeps the state of cell (ix, iy) arriving in direction k: its page and the offset in it.
local function slotXY(st : Store, ix : integer, iy : integer, k : integer) : integer, integer
	local x0 = ix - 1
	local b = math.floor(x0 / BLOCK)
	return (iy - 1) * st.blocksPerRow + b + 1, (x0 - b * BLOCK) * NDIRS + k
end

local function slot(s : Search, node : integer) : integer, integer
	local ix, iy = cellXY(s.g, cellOfNode(node))
	return slotXY(s.store, ix, iy, dirOfNode(node))
end

-- A state's cost so far, or nil if the search hasn't reached it. States in the store (see slot); the finish,
-- negative ids and a finished search's copy, in s.cost.
local function costOf(s : Search, node : integer) : number
	local st = s.store
	if node <= 0 or st == nil then
		return s.cost[node]
	end
	local p, o = slot(s, node)
	local stamp = st.stamp[p]
	if stamp == nil or stamp[o] ~= s.id then
		return nil
	end
	return st.cost[p][o]
end

-- The state a state was reached from, or nil (a start state, or not reached).
local function parentOf(s : Search, node : integer) : integer
	local st = s.store
	if node <= 0 or st == nil then
		return s.parent[node]
	end
	local p, o = slot(s, node)
	local stamp = st.stamp[p]
	if stamp == nil or stamp[o] ~= s.id then
		return nil
	end
	local par = st.parent[p][o]
	if par == 0 then
		return nil
	end
	return par
end

-- Records a state's cost and the state it was reached from (nil for a start state).
local function setState(s : Search, node : integer, c : number, par : integer)
	local st = s.store
	if node <= 0 then
		s.cost[node], s.parent[node] = c, par
		return
	end
	local p, o = slot(s, node)
	page(st, p)[o] = s.id
	st.cost[p][o], st.parent[p][o] = c, par or 0
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

function grid.leaveCells(g : Grid, p : Pt, out : Pt, skip : {integer : boolean}) : {integer}
	local nx, ny, blocked = g.nx, g.ny, g.blocked
	local ax, ay = grid.cellOf(g, p)
	local k0 = nearestDir(out)
	local cells : {integer} = {}
	for k, d in ipairs(DIRS) do
		local dx, dy = d[1], d[2]
		local bx, by = ax + dx, ay + dy
		if (k0 == 0 or turnSteps(k0, k) <= MAX_TURN_STEPS) and bx >= 1 and bx <= nx and by >= 1 and by <= ny then
			local b = grid.index(g, bx, by)
			local open = not blocked[b] and not skip[b]
			if open and dx * dx + dy * dy == 5 then
				open = not blocked[grid.index(g, ax + math.floor(dx / 2), ay + math.floor(dy / 2))]
					and not blocked[grid.index(g, ax + math.ceil(dx / 2), ay + math.ceil(dy / 2))]
			end
			if open and grid.cellsAlong(g, p, grid.centre(g, bx, by), function(i : integer) : boolean
					return not blocked[i]
				end) then
				table.insert(cells, b)
			end
		end
	end
	return cells
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
	local avoid = s.avoid
	if g.blocked[b] or avoid[b] then
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
		if g.blocked[m1] or g.blocked[m2] or avoid[m1] or avoid[m2] then
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
	-- A road junction is bridged as track is (route.tl), so it costs as much to cross.
	if (g.track[b] and not g.track[a]) or (g.junction[b] and not g.junction[a]) then
		cost = cost + w.trackCrossing
	end
	return cost
end

-- Before the search proper, a flood fill over cells from the start (the same moves, turns, water and costs aside)
-- checks that the goal can be reached at all: otherwise the search would try every (cell, direction) state before
-- giving up. Fills up to `budget` cells; returns the budget left.
local function fillStep(s : Search, budget : integer) : integer
	local g = s.g
	local nx, ny, blocked, avoid = g.nx, g.ny, g.blocked, s.avoid
	local st, queue, id = s.store, s.fillQueue, s.id
	local seen = st.fillStamp
	local head, tail = s.fillHead, s.fillTail
	while budget > 0 and head <= tail do
		local a = queue[head]
		head = head + 1
		budget = budget - 1
		local ax = (a - 1) % nx + 1
		local ay = math.floor((a - 1) / nx) + 1
		if ax == 1 or ax == nx or ay == 1 or ay == ny then
			s.fillEdge = true
		end
		for k = 1, NDIRS do
			local d = DIRS[k]
			local dx, dy = d[1], d[2]
			local bx, by = ax + dx, ay + dy
			if bx >= 1 and bx <= nx and by >= 1 and by <= ny then
				local b = (by - 1) * nx + bx
				local row = seen[by] or fillRow(st, nx, by)
				if row[bx] ~= id and not blocked[b] and not avoid[b] then
					local open = true
					-- A knight move passes between two cells: both must be passable.
					if dx * dx + dy * dy == 5 then
						local m1 = (ay + math.floor(dy / 2) - 1) * nx + ax + math.floor(dx / 2)
						local m2 = (ay + math.ceil(dy / 2) - 1) * nx + ax + math.ceil(dx / 2)
						open = not blocked[m1] and not blocked[m2] and not avoid[m1] and not avoid[m2]
					end
					if open then
						if s.goalCells[b] ~= nil then
							s.filling = false
							return budget
						end
						row[bx] = id
						tail = tail + 1
						queue[tail] = b
					end
				end
			end
		end
	end
	s.fillHead, s.fillTail = head, tail
	if head > tail then
		-- Nothing left to fill and the goal not met: unreachable. Closed off inside the grid unless the fill reached its
		-- edge (then a wider grid might have a way round).
		s.filling = false
		s.done = true
		s.enclosed = not s.fillEdge
	end
	return budget
end

-- What one side of a corner costs, beyond the turn penalty: the corner turns by θ, with tan(θ / 2) = t, and has
-- `room` metres of straight to itself on that side. Its curve at radius R takes R·t of that straight. Nil if a curve
-- of the build minimum doesn't fit; otherwise SHORTFALL_FACTOR per metre that one of the search's radius would lack.
local function side(s : Search, t : number, room : number) : number
	if s.buildRadius * t > room + EPSILON then
		return nil
	end
	local short = s.radius * t - room
	if short > 0 then
		return SHORTFALL_FACTOR * short
	end
	return 0
end

-- Two corners (tan of half their turns a and b) with `length` of straight between them, where both are known: they
-- share it as they need, so their curves at radius R fit where R · (a + b) ≤ length. Priced as side prices one.
local function shared(s : Search, a : number, b : number, length : number) : number
	return side(s, a + b, length)
end

-- Both sides of a corner (nil if either doesn't fit).
local function both(a : number, b : number) : number
	if a == nil or b == nil then
		return nil
	end
	return a + b
end

-- tan(θ / 2) for the angle θ between directions u and v (0 if either is nil or zero, and huge for opposite ones).
local function tanHalf(u : Pt, v : Pt) : number
	if u == nil or v == nil then
		return 0
	end
	local lu, lv = geo.len(u), geo.len(v)
	if lu < 1e-9 or lv < 1e-9 then
		return 0
	end
	local denom = lu * lv + u.x * v.x + u.y * v.y
	if denom < 1e-9 then
		return math.huge
	end
	return math.abs(u.x * v.y - u.y * v.x) / denom
end

local function dirVec(k : integer) : Pt
	return { x = DIRS[k][1], y = DIRS[k][2] }
end

-- The turn model for a curve radius: a 22.5° arc of radius R takes R·tan(11.25°) of straight on each side of its
-- corner, so two turns need 2·R·tan(11.25°) between them. Where every move is at least that long (no more than a cell),
-- any move may turn, by up to 90°, and each corner is priced by the room its curve has: it gets half of each move
-- either side of it (the other half is the next corner's), and a turn whose curve at the build minimum wouldn't fit in
-- that is not allowed (a 90° turn needs a diagonal or knight move on one side, or two 45° turns), while the straight
-- a curve at the search's radius would lack is charged (see side). Otherwise a move may turn by one step only, and a
-- turning move runs on straight in its new direction for as many steps as that length takes. Either way the search's
-- states stay (cell, direction), each one free to turn again.
local function turnModel(s : Search, cell : number, radius : number)
	local straight = 2 * radius * math.tan(math.pi / 16)
	s.straightSteps = {}
	s.halfLength = {}
	for k, d in ipairs(DIRS) do
		s.halfLength[k] = cell * math.sqrt(d[1] * d[1] + d[2] * d[2]) / 2
	end
	if straight <= cell + EPSILON then
		s.maxTurn = MAX_TURN_STEPS
		s.free = true
		s.cornerCost = {}
		for k = 1, NDIRS do
			s.straightSteps[k] = 1
			for j = 1, NDIRS do
				local t = math.tan(turnSteps(k, j) * math.pi / 16)
				s.cornerCost[(k - 1) * NDIRS + j] = both(side(s, t, s.halfLength[k]), side(s, t, s.halfLength[j])) or -1
			end
		end
		return
	end
	s.maxTurn = 1
	s.free = false
	for k = 1, NDIRS do
		s.straightSteps[k] = math.max(1, math.ceil(straight / (2 * s.halfLength[k]) - EPSILON))
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
		radius ?: number, maxCost ?: number, startRun ?: number, goalRun ?: number, startRoom ?: number,
		goalRoom ?: number, approach ?: number, avoid ?: {integer : boolean}) : Search
	local sx, sy = grid.cellOf(g, from)
	local gx, gy = grid.cellOf(g, to)
	local s : Search = { g = g, w = w, startPt = from, goalPt = to, goal = grid.index(g, gx, gy), gx = gx, gy = gy,
		goalDir = nearestDir(goalDir), radius = radius or w.minRadius, maxCost = maxCost or math.huge, done = false,
		found = false, expansions = 0, h0 = 0, bestH = 0, heapN = 0, cost = {}, parent = {},
		origin = {}, finishDir = 0, finishSteps = 0, finishGoal = 1, filling = true, fillHead = 1, fillTail = 0,
		fillEdge = false, enclosed = false, buildRadius = w.minBuildRadius or 0,
		startRoom = startRoom or 0, goalRoom = goalRoom or 0, approach = approach or math.huge, avoid = {} }
	-- The grid's store is this search's from now on.
	local st = storeOf(g)
	s.store, s.id = st, st.nextId
	st.current, st.nextId = st.nextId, st.nextId + 1
	s.heap, s.heapF, s.fillQueue = st.heap, st.heapF, st.fillQueue
	if geo.len(startDir) > 1e-9 then
		s.startVec = geo.norm(startDir)
	end
	if geo.len(goalDir) > 1e-9 then
		s.goalVec = geo.norm(goalDir)
	end
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
	-- Cells to keep off besides blocked ones, less the ends' own cells.
	if avoid ~= nil then
		for i in pairs(avoid) do
			s.avoid[i] = true
		end
		for __, e in ipairs(s.starts) do
			s.avoid[e.cell] = nil
		end
		for __, e in ipairs(s.goals) do
			s.avoid[e.cell] = nil
		end
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
		local row = fillRow(st, g.nx, e.y)
		if row[e.x] ~= s.id then
			row[e.x] = s.id
			s.fillTail = s.fillTail + 1
			s.fillQueue[s.fillTail] = e.cell
		end
	end
	-- Without a start direction, every direction is a start state, so the first move may go any way, unpenalised.
	for i, e in ipairs(s.starts) do
		for k = 1, NDIRS do
			if k0 == 0 or k == k0 then
				local node = (e.cell - 1) * NDIRS + k
				if costOf(s, node) == nil then
					setState(s, node, e.cost, nil)
					s.origin[node] = i
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

-- Whether a state is a start state whose moves leave from its start point (not reached any cheaper way).
local function fromStartPoint(s : Search, node : integer) : boolean
	return node ~= nil and node > 0 and parentOf(s, node) == nil and s.origin[node] ~= nil
end

-- Where corners are priced, the state a start state's first move reaches is a state of its own (its node id
-- negated): its next move prices the start's corner (startPair), unlike a state reached any other way. The start
-- point it came from.
local function freshFrom(s : Search, node : integer) : Pt
	if node == nil or node >= 0 then
		return nil
	end
	return s.starts[s.origin[s.parent[node]]].pt
end

-- Where the curve at a station end may be (where corners are priced): at the end point itself (the search's start or
-- goal point, its extension), with the station's room to turn on its far side, or the approach where there is no
-- such room; or, where there is, at the approach point, the approach on its far side (fitLeg gives the extension up
-- there). For the start (sign -1, axis startVec) or the goal (sign 1, axis goalVec): the points and their far rooms.
local function endOptions(s : Search, p : Pt, axis : Pt, room : number, sign : number) : {Pt}, {number}
	if axis == nil then
		return { p }, { math.huge }
	end
	if room <= EPSILON then
		return { p }, { s.approach }
	end
	return { p, geo.add(p, geo.scale(axis, sign * room)) }, { room, s.approach }
end

-- The corner at a station end point `e` (its far side `far`, the station's axis `axis`) and the next corner, at `c`,
-- which turns onto `out`: both their sides, the straight between them shared as they need it. Beyond c, the next
-- corner's own straight is `outRoom` (nextT nil), or is shared with a known corner nextT over nextLen. Nil if they don't
-- fit, or where `check` asks and the straight from e to c crosses a blocked cell.
local function pairAtEnd(s : Search, e : Pt, far : number, axis : Pt, c : Pt, out : Pt, outRoom : number,
		nextT : number, nextLen : number, check : boolean) : number
	local v = geo.sub(c, e)
	local te, tc = tanHalf(axis, v), tanHalf(v, out)
	local beyond : number
	if nextT == nil then
		beyond = side(s, tc, outRoom)
	else
		beyond = shared(s, tc, nextT, nextLen)
	end
	local charge = both(both(side(s, te, far), shared(s, te, tc, geo.len(v))), beyond)
	if charge ~= nil and check and not segmentClear(s.g, e, c) then
		return nil
	end
	return charge
end

-- The least of the start's options (endOptions) for its corner and the next, at c (see pairAtEnd); nil if none fits.
local function startPair(s : Search, sp : Pt, c : Pt, out : Pt, outRoom : number, nextT : number,
		nextLen : number) : number
	local pts, rooms = endOptions(s, sp, s.startVec, s.startRoom, -1)
	local best : number = nil
	for i, e in ipairs(pts) do
		local charge = pairAtEnd(s, e, rooms[i], s.startVec, c, out, outRoom, nextT, nextLen, i > 1)
		if charge ~= nil and (best == nil or charge < best) then
			best = charge
		end
	end
	return best
end

-- Where corners are priced: what finishing from state `node` (at a goal cell, arriving in direction prev) adds for
-- its last corners, or nil if they don't fit. The goal point takes the place of the cell's centre, so the last
-- straight runs from the corner before it (the cell before, or the start point) to the goal's corner (at the goal
-- point or its approach, endOptions), and the two share it. The corner before was priced when this state's move was
-- made, as the path ran on then: it is priced again as it really turns, for any more it costs.
local function finishCharge(s : Search, node : integer, par : integer, prev : integer, gp : Pt) : number
	local g = s.g
	local goals, fronts = endOptions(s, gp, s.goalVec, s.goalRoom, 1)
	local sp = freshFrom(s, node)
	if fromStartPoint(s, node) then
		sp = s.starts[s.origin[node]].pt
	end
	local best : number = nil
	local function offer(charge : number)
		if charge ~= nil and (best == nil or charge < best) then
			best = charge
		end
	end
	if sp ~= nil then
		-- From the start's corner straight to the goal's: neither was priced on the way here.
		local starts, backs = endOptions(s, sp, s.startVec, s.startRoom, -1)
		for i, e in ipairs(starts) do
			for j, q in ipairs(goals) do
				local axis : Pt = s.goalVec
				if axis == nil then
					axis = geo.sub(q, e)
				end
				offer(pairAtEnd(s, e, backs[i], s.startVec, q, axis, fronts[j], nil, nil, i > 1 or j > 1))
			end
		end
		return best
	end
	-- The corner at the cell before, c, turned onto prev when this state's move was priced: `was`.
	local ax, ay = cellXY(g, cellOfNode(node))
	local c = grid.centre(g, ax - DIRS[prev][1], ay - DIRS[prev][2])
	local grandStart = freshFrom(s, par)
	local into = dirVec(dirOfNode(par))
	local was : number
	if grandStart ~= nil then
		was = startPair(s, grandStart, c, dirVec(prev), s.halfLength[prev], nil, nil) or 0
	else
		was = s.cornerCost[(dirOfNode(par) - 1) * NDIRS + prev]
	end
	for j, q in ipairs(goals) do
		local v = geo.sub(q, c)
		local length = geo.len(v)
		local tq = tanHalf(v, s.goalVec)
		local now : number
		if grandStart ~= nil then
			now = startPair(s, grandStart, c, v, 0, tq, length)
		else
			local tc = tanHalf(into, v)
			now = both(side(s, tc, s.halfLength[dirOfNode(par)]), shared(s, tc, tq, length))
		end
		local goalFar = side(s, tq, fronts[j])
		if goalFar ~= nil and now ~= nil and (j == 1 or segmentClear(g, c, q)) then
			offer(goalFar + math.max(0, now - was))
		end
	end
	return best
end

-- A search whose store a newer search has taken over can't go on (its states are the newer one's now).
local function checkCurrent(s : Search)
	if s.store ~= nil and s.store.current ~= s.id then
		error("grid: a newer search on this grid has taken over this one's store")
	end
end

function grid.stepSearch(s : Search, maxExpansions : integer) : boolean
	if s.done then
		return true
	end
	checkCurrent(s)
	local budget = maxExpansions
	if s.filling then
		budget = fillStep(s, budget)
		if s.done or s.filling then
			return s.done
		end
	end
	local g, w = s.g, s.w
	local cost = s.cost
	local st, id = s.store, s.id
	local stampPages, costPages, parentPages, blocksPerRow = st.stamp, st.cost, st.parent, st.blocksPerRow
	-- A backstop for goals that only the turn limit cuts off: by then the search has gone far past any sensible path.
	local maxTotal = math.max(20000, MAX_EXPANSIONS_PER_CELL * g.nx * g.ny)
	while budget > 0 do
		if s.heapN == 0 then
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
			local prev = dirOfNode(node)
			local base = costOf(s, node)
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
				if fromStartPoint(s, node) then
					origin = s.starts[s.origin[node]].pt
				end
				-- Where corners are priced (s.free), those next to a start or goal point, off its cell's centre, are
				-- priced as the path really runs there: a start's corner with the next one (startPair), once the state
				-- after its first move (here: startAt) moves on, and the last ones when the path finishes.
				local par = parentOf(s, node)
				local startAt = freshFrom(s, node)
				local goalHere = s.goalCells[a]
				if goalHere ~= nil then
					-- The final turn onto the asked direction obeys the same limit as any other: this state is free to
					-- turn, and the room beyond the goal (a station's extension) takes the far side of the curve.
					local turn = 0
					if s.goalDir ~= 0 then
						turn = turnSteps(prev, s.goalDir)
					end
					-- The last segment runs from the cell before (or the start point) to the goal point.
					local before = origin or startAt
					if before == nil then
						before = grid.centre(g, ax - DIRS[prev][1], ay - DIRS[prev][2])
					end
					local goalPt = s.goals[goalHere].pt
					local charge : number = 0
					if s.free then
						charge = finishCharge(s, node, par, prev, goalPt)
					end
					if turn <= maxTurn and charge ~= nil and segmentClear(g, before, goalPt) then
						finish(s, base + w.turnPenalty * turn * turn + charge, node, prev, 0, goalHere)
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
					local charge : number = 0
					if s.free then
						if origin ~= nil then
							-- The start's corner is priced with the next one, after this move (startPair).
							charge = 0
						elseif startAt ~= nil then
							charge = startPair(s, startAt, grid.centre(g, ax, ay), dirVec(k), s.halfLength[k], nil, nil)
						else
							charge = s.cornerCost[(prev - 1) * NDIRS + k]
							if charge < 0 then
								charge = nil
							end
						end
					end
					local nc : number = nil
					if charge ~= nil then
						nc = base + w.turnPenalty * turn * turn + charge
					else
						steps = 0
					end
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
						if origin ~= nil and s.free then
							nb = -nb
						end
						-- Gains below EPSILON are rounding (the same cost summed in another order): taking them would
						-- expand a finished state again.
						if nb < 0 then
							if cost[nb] == nil or nc < cost[nb] - EPSILON then
								cost[nb], s.parent[nb] = nc, node
								push(s, nb, nc + heuristic(s, bx, by) + turnBound(s, k))
							end
						else
							-- In the store (slotXY).
							local x0 = bx - 1
							local blk = math.floor(x0 / BLOCK)
							local p = (by - 1) * blocksPerRow + blk + 1
							local o = (x0 - blk * BLOCK) * NDIRS + k
							local stamp = stampPages[p] or page(st, p)
							local costs = costPages[p]
							if stamp[o] ~= id or nc < costs[o] - EPSILON then
								stamp[o], costs[o], parentPages[p][o] = id, nc, node
								push(s, nb, nc + heuristic(s, bx, by) + turnBound(s, k))
							end
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

function grid.finished(s : Search) : Search
	checkCurrent(s)
	local parent : {integer : integer} = {}
	local origin : {integer : integer} = {}
	local node = s.parent[FINISH]
	parent[FINISH] = node
	while node ~= nil do
		local par = parentOf(s, node)
		parent[node] = par
		if par == nil then
			origin[node] = s.origin[node]
		end
		node = par
	end
	return { g = s.g, w = s.w, startPt = s.startPt, goalPt = s.goalPt, start = s.start, starts = s.starts,
		goals = s.goals, goalCells = s.goalCells, goal = s.goal, gx = s.gx, gy = s.gy, goalDir = s.goalDir,
		radius = s.radius, maxTurn = s.maxTurn, straightSteps = s.straightSteps, maxCost = s.maxCost, done = true,
		found = s.found, expansions = 0, h0 = s.h0, bestH = s.bestH, heap = {}, heapF = {}, heapN = 0,
		cost = { [FINISH] = s.cost[FINISH] }, parent = parent, origin = origin, finishDir = s.finishDir,
		finishSteps = s.finishSteps, finishGoal = s.finishGoal, filling = false, fillEdge = s.fillEdge,
		enclosed = s.enclosed }
end

function grid.path(s : Search) : {Pt}
	if not s.found then
		return nil
	end
	checkCurrent(s)
	local g = s.g
	local nodes : {integer} = {}
	local node = s.parent[FINISH]
	while node ~= nil do
		table.insert(nodes, 1, node)
		node = parentOf(s, node)
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
		local k = dirOfNode(nodes[i])
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
