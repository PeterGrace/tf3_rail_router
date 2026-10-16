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
	record Search
		g : Grid
		w : PgraceRailRouterModes.Weights
		startPt : PgraceRailRouterGeo.Pt
		goalPt : PgraceRailRouterGeo.Pt
		goal : integer
		done : boolean
		found : boolean
		expansions : integer
		heap : {integer}
		heapF : {number}
		cost : {integer : number}
		parent : {integer : integer}
		dir : {integer : integer}
		closed : {integer : boolean}
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

	-- Starts a search from `from` to `to`; startDir is the direction the track leaves `from` in (turns are counted
	-- from it).
	startSearch : function(g : Grid, from : PgraceRailRouterGeo.Pt, to : PgraceRailRouterGeo.Pt,
		startDir : PgraceRailRouterGeo.Pt, w : PgraceRailRouterModes.Weights) : Search
	-- Expands up to maxExpansions cells; true once the search is finished (found or not).
	stepSearch : function(s : Search, maxExpansions : integer) : boolean
	-- Rough share of the work done, 0 to 1 (cells expanded / all cells).
	progress : function(s : Search) : number
	-- The path as points from `from` to `to` (cell centres in between); nil if there is none.
	path : function(s : Search) : {PgraceRailRouterGeo.Pt}
end
