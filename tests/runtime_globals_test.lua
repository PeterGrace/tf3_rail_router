local t = ...

-- In-game, the mod's global records (PgraceRailRouter*) exist only as types: nothing assigns them at runtime. Teal
-- emits an unused `local type X = PgraceRailRouterY.Z` alias as runtime code, which indexes that missing global and
-- crashes the whole UI on load ("attempt to index global 'PgraceRailRouterGeo'"). The test runner can't see it, so
-- check the generated Lua of every content file for a runtime read of such a global.
t.test("no content file reads a PgraceRailRouter global at runtime", function()
	local p = io.popen('find "' .. t.root .. '/mod/' .. t.modId .. '/content" -name "*.tl" ! -name "*.d.tl"')
	local bad = {}
	for path in p:lines() do
		local rel = path:sub(#(t.root .. "/mod/" .. t.modId .. "/content/") + 1)
		local code = t.genTl(rel)
		for line in code:gmatch("[^\n]+") do
			if line:match("[^%w_\"]PgraceRailRouter%w*%s*[%.%[:]") or line:match("^PgraceRailRouter%w*%s*[%.%[:]") then
				table.insert(bad, rel .. ": " .. line)
			end
		end
	end
	p:close()
	t.eq(table.concat(bad, "\n"), "", "runtime reads")
end)
