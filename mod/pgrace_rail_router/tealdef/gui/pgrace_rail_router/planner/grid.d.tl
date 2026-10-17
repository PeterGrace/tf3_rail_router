-- A square-cell grid over the area between the stops (terrain, water, obstacles), and a resumable cheapest-path
-- search over it with 16 move directions. Pure (no api.*).
global record PgraceRailRouterGrid
	record Grid
		-- World position of cell (1, 1)'s centre.
		x0 : number
		y0 : number
		-- Cell size in metres.
		cell : number
		nx : integer
		ny : integer
		-- Per cell, at index (iy - 1) * nx + ix.
		height : {number}
		water : {boolean}
		-- Buildings and other constructions (with a buffer), and points off the map: impassable.
		blocked : {boolean}
		road : {boolean}
		track : {boolean}
	end

	-- One of a search's possible ends: a point on a station's axis, its cell (index, column, row), and the cost of the
	-- straight between it and the asked end point.
	record End
		pt : PgraceRailRouterGeo.Pt
		cell : integer
		x : integer
		y : integer
		cost : number
	end

	-- A search in progress. The fields other than done, found, expansions and enclosed are internal.
	-- Its states are (cell, arriving direction): node id (cell - 1) * 16 + k, k = 1..16 the move direction that
	-- entered the cell; node 0 is the virtual finish, past the goal cell. Where corners are priced (free), the state a
	-- start state's first move reaches has its id negated: its next move prices the start point's corner.
	record Search
		g : Grid
		w : PgraceRailRouterModes.Weights
		startPt : PgraceRailRouterGeo.Pt
		goalPt : PgraceRailRouterGeo.Pt
		-- The start cell's index.
		start : integer
		-- Where the path may start and finish (the asked points first), and the goal cells, by cell index, to their
		-- index in goals.
		starts : {End}
		goals : {End}
		goalCells : {integer : integer}
		-- The goal cell's index, and its column and row.
		goal : integer
		gx : integer
		gy : integer
		-- The asked arrival direction (1..16), or 0 for any.
		goalDir : integer
		-- The curve radius the turns are spaced for (metres), and the turn model it gives: the most 22.5° steps one
		-- move may turn, and per direction (1..16) how many steps a move that turns onto it runs straight.
		radius : number
		maxTurn : integer
		straightSteps : {integer}
		-- Whether every move may turn, its corners priced by the room their curves have (see startSearch); then per
		-- pair of directions (index (k - 1) * 16 + j, from direction k onto j) what that corner costs between two cell
		-- moves, -1 where it doesn't fit.
		free : boolean
		cornerCost : {number}
		-- Half each direction's move length (metres), and the build minimum radius (w.minBuildRadius, 0 if not given).
		halfLength : {number}
		buildRadius : number
		-- startDir and goalDir as unit vectors (nil for any direction).
		startVec : PgraceRailRouterGeo.Pt
		goalVec : PgraceRailRouterGeo.Pt
		-- A station's room to turn behind the start point and beyond the goal point (metres: from its approach point
		-- to that point), and the straight of its approach (from the platform's end to the approach point).
		startRoom : number
		goalRoom : number
		approach : number
		-- Cells kept off as if blocked (the stations' platforms and approaches), less the start and goal cells.
		avoid : {integer : boolean}
		-- Paths costing more are not wanted (math.huge: no limit).
		maxCost : number
		done : boolean
		found : boolean
		-- States expanded so far.
		expansions : integer
		-- Distance to the goal cell over empty ground (metres): from the start cell, and the least of any expanded
		-- state (for progress).
		h0 : number
		bestH : number
		heap : {integer}
		heapF : {number}
		-- Keyed by node id. cost[0] is the finished path's cost.
		cost : {integer : number}
		parent : {integer : integer}
		-- The start states, by node id, to their index in starts.
		origin : {integer : integer}
		-- How the finish is reached from parent[0]: this many steps on in direction finishDir (0 steps when that
		-- state is at the goal cell).
		finishDir : integer
		finishSteps : integer
		-- The goal (index into goals) the finish reaches.
		finishGoal : integer
		-- The reachability flood fill over cells that runs first: true while it runs; its queue of cell indices,
		-- the next one to take, and the cells queued so far (queue and seen are dropped once it ends).
		filling : boolean
		fillQueue : {integer}
		fillHead : integer
		fillSeen : {integer : boolean}
		-- The fill reached a cell on the grid's edge.
		fillEdge : boolean
		-- Set by route.tl: the key a finished search is kept under (see route's searchFor); nil if it isn't kept.
		cacheKey : string
		-- Finished, not found, because the fill used up every cell it could reach from the start without meeting the
		-- goal or the grid's edge: the start is closed off inside the grid, and a wider grid wouldn't help.
		enclosed : boolean
	end

	-- A flat (height 0), dry, empty grid.
	new : function(x0 : number, y0 : number, cell : number, nx : integer, ny : integer) : Grid
	index : function(g : Grid, ix : integer, iy : integer) : integer
	-- Whether p lies within the grid's cells.
	inside : function(g : Grid, p : PgraceRailRouterGeo.Pt) : boolean
	-- The cell nearest to p, clamped to the grid.
	cellOf : function(g : Grid, p : PgraceRailRouterGeo.Pt) : integer, integer
	centre : function(g : Grid, ix : integer, iy : integer) : PgraceRailRouterGeo.Pt
	-- Ground height at p, interpolated between cell centres (clamped at the edges).
	heightAt : function(g : Grid, p : PgraceRailRouterGeo.Pt) : number
	-- Whether the cell nearest to p is water.
	waterAt : function(g : Grid, p : PgraceRailRouterGeo.Pt) : boolean

	-- Calls fn with the index of every cell the segment a–b passes through, in order from a to b, stopping (and
	-- returning false) as soon as fn returns false; true if it never did. Exact, and conservative: a cell the
	-- segment only touches (along an edge, or at a corner) counts too. Cells off the grid are skipped, so check
	-- that a and b are inside first.
	cellsAlong : function(g : Grid, a : PgraceRailRouterGeo.Pt, b : PgraceRailRouterGeo.Pt,
		fn : function(i : integer) : boolean) : boolean

	-- The 16 move directions as {dx, dy} in cells, counter-clockwise from +x.
	DIRS : {{integer}}

	-- Where a path may go first from the point p heading about `out` (or, the other way round, arrive at p heading
	-- against it), as a search's first or last segment: the neighbours of p's cell (by the search's 16 moves, the
	-- knight moves' rule included) within the 90° a free-turning search may turn from `out` (any way for a zero
	-- `out`), not blocked nor in `skip`, with the straight from p itself to the neighbour's centre clear of blocked
	-- cells. Their cell indices; empty if the path can't leave there.
	leaveCells : function(g : Grid, p : PgraceRailRouterGeo.Pt, out : PgraceRailRouterGeo.Pt,
		skip : {integer : boolean}) : {integer}

	-- Starts a search from `from` to `to`. startDir is the direction the track leaves `from` in (turns are counted
	-- from it; zero-length = any). goalDir is the direction it must arrive at `to` in: the last move may turn from it
	-- as far as any other move may, and that final turn is charged like any other (zero-length = any).
	-- Turns are spaced for curves of `radius` (default w.minRadius): a 22.5° turn needs a straight of
	-- L = 2 · radius · tan(11.25°) before the next one, so consecutive arcs fit. Where L is at most a cell, any move
	-- may turn by up to 90°, and each corner is priced by the room its curve has: a curve of radius R turning by θ
	-- takes R · tan(θ / 2) of straight on each side, and a corner between two cell moves has half of each to itself.
	-- A turn whose curve at the build minimum (w.minBuildRadius) doesn't fit is not made; the straight a curve of
	-- `radius` would lack costs a metre of plain track per metre (a 90° turn between two straight moves needs a
	-- diagonal or knight move on one side, or two 45° turns). Next to the start and goal points, off their cells'
	-- centres, corners are priced as the path really runs: the start point's corner with the next one, sharing the
	-- straight between them, with the station's room to turn behind it (startRoom, from its approach point), or where
	-- there is room, at the approach point instead with the approach behind it (`approach`, the approach's length;
	-- default unlimited); the goal's alike (goalRoom). Otherwise a move may turn by one 22.5° step only, and a move
	-- that turns carries on straight in its new direction for ceil(L / step length) steps in all, each checked and
	-- costed as a move of its own; passing through the goal cell part-way along, heading in goalDir, finishes there.
	-- The start state (startDir) may turn at once (the station's extension gives room behind it), as may every state
	-- the search reaches. Cells in `avoid` (the stations' platforms and approaches) are kept off as if blocked, but
	-- for the start's and goal's own cells. With startRun (metres), the path may instead start at any point up to
	-- that far out along startDir from
	-- `from`, one per cell, and with goalRun finish at any point up to that far back from `to` against goalDir: each
	-- ray stops at the first blocked, water, road or track cell, and costs its straight (length and slope, as moves).
	-- The path's first and last points are then those points. The first segment, from the start point to the next
	-- cell's centre, and the last, into the goal point, must be clear of blocked cells too (off-centre ends can cut a
	-- blocked cell's corner). With maxCost, the search finishes, not found, once every path left would cost more. A
	-- goal with every cell blocked finishes the search at once, not found. The first stepSearch calls flood-fill the cells from the start
	-- (about one cell per unit of budget, no expansions counted) and finish, not found, if the goal can't be reached
	-- at all. Entering a road or track cell costs w.roadCrossing or w.trackCrossing; a step from road to road costs
	-- 1.5 × its length, so the path doesn't run along roads.
	startSearch : function(g : Grid, from : PgraceRailRouterGeo.Pt, to : PgraceRailRouterGeo.Pt,
		startDir : PgraceRailRouterGeo.Pt, goalDir : PgraceRailRouterGeo.Pt, w : PgraceRailRouterModes.Weights,
		radius ?: number, maxCost ?: number, startRun ?: number, goalRun ?: number, startRoom ?: number,
		goalRoom ?: number, approach ?: number, avoid ?: {integer : boolean}) : Search
	-- Expands up to maxExpansions states (or fills that many cells first); true once the search is finished (found
	-- or not). Gives up, not found, after 12 expansions per cell (a goal cut off only by the turn limit).
	stepSearch : function(s : Search, maxExpansions : integer) : boolean
	-- Rough share of the work done, 0 to 1, never falling: how much nearer to the goal (in distance over empty
	-- ground) the search has reached than the start was; 1 once done.
	progress : function(s : Search) : number
	-- A finished search's result, without the work behind it (only its path's states): done, found, enclosed and
	-- cost[0] as s's, expansions 0, and path() gives the same path.
	finished : function(s : Search) : Search
	-- The path as points from `from` to `to` (cell centres in between); nil if there is none.
	path : function(s : Search) : {PgraceRailRouterGeo.Pt}
end
