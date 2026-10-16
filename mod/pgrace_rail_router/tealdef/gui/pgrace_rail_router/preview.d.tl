-- Draws a plan on the map: one static arrow per ~100 m of track (green on the ground, blue on bridges, orange in
-- tunnels) and a white one along each platform, and frames the camera on it once.
global record PgraceRailRouterPreview
	record Params is IRecipeParamWithMeta
		plan : PgraceRailRouterRoute.Plan
		-- Different for each plan: part of the map action's key, so a new plan rebinds it.
		generation : integer
		-- The window's game context (window container and tool stack).
		baseCtx : GameContext
	end

	RouteAction : Recipe<Params>
	-- The map action for the window itself: the game's HUD (town names) and selector, no route.
	makeMapAction : function(baseCtx : GameContext) : function() : TreeNodeId
end
