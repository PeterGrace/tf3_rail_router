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
	-- P13: the modular station nearest the camera: its transform, building modules, and every street piece within 200 m
	-- in its local frame (where the road the player builds to its main building goes).
	stationStreets : function() : {function()}
	-- P14: a Halt 2+2 station at the camera facing east (test map only), then 600 m of line off its east end with its
	-- fans, crossovers and one-way signals in one proposal; logs the signal resource the game knows and the signals as
	-- built, against the planned ones.
	halt : function(settings : PgraceRailRouterBuilder.Settings) : {function()}
	-- P15 (test map only), three stages, one click each (a stage counter wraps 1, 2, 3, 1): 1 builds a 400 m double
	-- track east of the camera with a one-way signal on each track at x = 300; 2 splits track 1 at x = 100, then splits
	-- the piece carrying the signal, logging where the signal ends up; 3 cuts track 1 at x = 60 and track 2 where the
	-- crossing track leaves it, and builds a flat junction from the north: one track switching into track 1, one
	-- switching into track 2 and crossing track 1 on the level at its node at x = 200, straight through it at 8° for
	-- 25 m each side (a diamond, as the game's own tool makes one). Logs every piece, node and signal.
	junction : function(settings : PgraceRailRouterBuilder.Settings) : {function()}
	-- P16 (test map only): a 360 m double track at the camera, both tracks split where a straight track at 6.5°
	-- crosses them, and that track built through the two nodes (a diamond at each, as the game's own tool makes one),
	-- dry-run with track spacing 0 and 5, built if clean.
	trackCrossing : function(settings : PgraceRailRouterBuilder.Settings) : {function()}
end
