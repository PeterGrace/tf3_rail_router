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

	-- A search in progress. The fields other than done, found and expansions are internal.
	-- Its states are (cell, arriving direction): node id (cell - 1) * 16 + k, k = 1..16 the move direction that
	-- entered the cell; node 0 is the virtual finish, past the goal cell.
	record Search
		g : Grid
		w : PgraceRailRouterModes.Weights
		startPt : PgraceRailRouterGeo.Pt
		goalPt : PgraceRailRouterGeo.Pt
		-- The goal cell's index, and its column and row.
		goal : integer
		gx : integer
		gy : integer
		-- The asked arrival direction (1..16), or 0 for any.
		goalDir : integer
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
		-- The reachability flood fill over cells that runs first: true while it runs; its queue of cell indices,
		-- the next one to take, and the cells queued so far (queue and seen are dropped once it ends).
		filling : boolean
		fillQueue : {integer}
		fillHead : integer
		fillSeen : {integer : boolean}
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

	-- Starts a search from `from` to `to`. startDir is the direction the track leaves `from` in (turns are counted
	-- from it; zero-length = any). goalDir is the direction it must arrive at `to` in: the last move may turn at most
	-- 90° from it, and that final turn is charged like any other (zero-length = any). A blocked goal cell finishes the
	-- search at once, not found. The first stepSearch calls flood-fill the cells from the start (about one cell per
	-- unit of budget, no expansions counted) and finish, not found, if the goal can't be reached at all.
	startSearch : function(g : Grid, from : PgraceRailRouterGeo.Pt, to : PgraceRailRouterGeo.Pt,
		startDir : PgraceRailRouterGeo.Pt, goalDir : PgraceRailRouterGeo.Pt, w : PgraceRailRouterModes.Weights) : Search
	-- Expands up to maxExpansions states (or fills that many cells first); true once the search is finished (found
	-- or not). Gives up, not found, after 12 expansions per cell (a goal cut off only by the turn limit).
	stepSearch : function(s : Search, maxExpansions : integer) : boolean
	-- Rough share of the work done, 0 to 1, never falling: how much nearer to the goal (in distance over empty
	-- ground) the search has reached than the start was; 1 once done.
	progress : function(s : Search) : number
	-- The path as points from `from` to `to` (cell centres in between); nil if there is none.
	path : function(s : Search) : {PgraceRailRouterGeo.Pt}
end
