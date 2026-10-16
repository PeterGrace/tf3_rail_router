local util : PgraceRailRouterUtil = {}

function util.greet(name : string) : string
	if name == nil or name == "" then
		return "Hello!"
	end
	return "Hello, " .. name .. "!"
end

return util
