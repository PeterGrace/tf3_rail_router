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
	-- P9: a level crossing over the nearest street (within 200 m of the camera; test map only): the street split at
	-- the two points a double track square across it would cross (the engine's replaceSegment proposal, edited; it
	-- can't be dry-run), its lanes repaired, then 300 m of double track through the two new nodes, dry-run and built.
	levelCrossing : function(settings : PgraceRailRouterBuilder.Settings, angle ?: number, fromJoint ?: number) : {function()}
	-- P10: builds a 160 m station at the camera facing east (if its dry run is clean; test map only) and logs its
	-- frozen nodes: where the track ends are, and their pieces.
	buildStation : function(settings : PgraceRailRouterBuilder.Settings) : {function()}
	-- P11: joins 100 m of track to the free track ends on one side of the modular station nearest the camera (the
	-- ends' node entities in the proposal; new nodes at the same places with cleanupStreetGraph, dry run only), builds
	-- it, then a second 100 m from where the first ended (test map only).
	joinStation : function(settings : PgraceRailRouterBuilder.Settings) : {function()}
end
