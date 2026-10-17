-- PROBE (remove before release): one-off engine probes for milestone 2, run from the window's probe buttons. Each
-- returns its work as a list of tasks, to be run in order, one per join (main thread, one dry run each at most), and
-- logs "[rail_router] PROBE <name> ..." lines. They're anchored at the camera's look-at point, read when called.
global record PgraceRailRouterProbe
	-- P1: every track edge within 300 m of the camera: type, typeIndex, distance, template, tangent lengths against
	-- the two curve rules, owner, parallel strips.
	logTrack : function() : {function()}
	-- P2 and P3: the bridge and tunnel types and the ones structureFor picks per track type; double-track straights of
	-- 100 to 2000 m as one edge each, grades, radii, a bridge and a tunnel, the two tangent rules.
	dryRunTrack : function(settings : PgraceRailRouterBuilder.Settings, tracks : {PgraceRailRouterModes.TrackType}) : {function()}
	-- P4: a 300 m double track across a street at the camera, on the ground and as a bridge.
	dryRunCrossing : function(settings : PgraceRailRouterBuilder.Settings) : {function()}
	-- P8: the nearest plain track and street edges within 200 m of the camera, each crossed square-on by a 300 m
	-- double-track bridge whose rails are 6 to 14 m above theirs: the clearance the game asks for.
	bridgeClearance : function(settings : PgraceRailRouterBuilder.Settings) : {function()}
	-- P6: a 160 m station at the camera facing east, without and with the main building and stairs (and roofs), with
	-- its bounding box's length along the axis; the module names.
	dryRunStation : function(settings : PgraceRailRouterBuilder.Settings, tracks : {PgraceRailRouterModes.TrackType}) : {function()}
	-- P5: builds a 200 m double-track straight at the camera (only if its dry run is clean and collides with nothing)
	-- and logs the price,
	-- the balance before and after, and the built edges.
	buildStraight : function(settings : PgraceRailRouterBuilder.Settings) : {function()}
end
