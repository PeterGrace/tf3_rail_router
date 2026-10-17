-- How the preview cuts a leg into map arrows. Pure (no api.*), so it is unit-tested: the game asserts on an arrow too
-- short to draw ("AddEveryNthPoint: (num)>=(2)", a crash to desktop; a 7 m bridge on NewGame2 gave one).
global record PgraceRailRouterArrows
	-- One arrow, from sample i to sample j of the leg, coloured for its kind ("ground", "bridge" or "tunnel").
	record Arrow
		i : integer
		j : integer
		kind : string
	end

	-- The arrows along a leg: chords up to `chord` metres along it, ending early where the kind changes, so every
	-- bridge and tunnel shows, a short tail of the same kind taken into the last chord. None is shorter than
	-- `minLength` (straight from end to end): a shorter one runs on into the next samples, keeping its kind, and a
	-- short last one joins the one before it (a bridge or tunnel's kind wins over ground). A leg shorter than
	-- `minLength` gets none. Together they run from the first sample to the last, each starting where the one before
	-- ends.
	split : function(leg : PgraceRailRouterRoute.Leg, chord : number, minLength : number) : {Arrow}
end
