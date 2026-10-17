local ssu = require "::/gui/main/stylesheetutil.lua"

-- Keyed on the window's class: an id selector with a dot didn't apply (Trim the Fat). Docked at the left edge,
-- vertically centred, so the route on the map stays mostly in view.
function data()
	local result = {}
	local a = ssu.makeAdder(result)
	a("Window!pgrace-rail-router", {
		gravity = { 0.0, 0.5 },
		anchorPoint = { 0.0, 0.5 },
		padding = { 0, 0, 0, 16 },
	})
	a("Window!pgrace-rail-router Window::Content", {
		padding = { 8, 12, 12, 12 },
	})
	return result
end
