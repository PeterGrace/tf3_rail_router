-- Minimal test runner: loads Teal modules as plain Lua and runs tests/*_test.lua.
-- usage: lua tools/test.lua
local root = arg[0]:match("^(.*)/tools/[^/]*$") or "."
package.path = root .. "/.tools/?.lua;" .. package.path
local tl = require("tl")

local t = { passed = 0, failed = 0 }

local idPipe = io.popen('"' .. root .. '/tools/mod_id.sh"')
local modId = idPipe:read("l")
idPipe:close()
assert(modId and modId ~= "", "tools/mod_id.sh found no mod")

function t.requireTl(relPath)
	local path = root .. "/mod/" .. modId .. "/content/" .. relPath
	local f = assert(io.open(path, "r"))
	local src = f:read("a")
	f:close()
	local code, result = tl.gen(src, tl.new_env({ defaults = { gen_target = "5.1" } }))
	if not code then
		error("failed to compile " .. path .. ": " .. tostring(result and result.syntax_errors and result.syntax_errors[1] and result.syntax_errors[1].msg))
	end
	return assert(load(code, "@" .. path))()
end

function t.eq(actual, expected, label)
	if actual ~= expected then
		error(("%s: expected %s, got %s"):format(label or "eq", tostring(expected), tostring(actual)), 2)
	end
end

function t.near(actual, expected, tolerance, label)
	if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
		error(("%s: expected %s ± %s, got %s"):format(label or "near", tostring(expected), tostring(tolerance),
			tostring(actual)), 2)
	end
end

function t.ok(value, label)
	if not value then
		error((label or "ok") .. ": expected a true value, got " .. tostring(value), 2)
	end
end

-- Pure modules load each other with ug_require "<modId>::/<path>", as in the game. Map that onto requireTl, once
-- per file, so tests can load modules that depend on others.
local loaded = {}
function ug_require(path)
	local prefix = modId .. "::/"
	assert(path:sub(1, #prefix) == prefix, "the test runner only loads this mod's files: " .. path)
	local rel = path:sub(#prefix + 1)
	if loaded[rel] == nil then
		loaded[rel] = t.requireTl(rel)
	end
	return loaded[rel]
end

function t.test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		t.passed = t.passed + 1
		print("PASS " .. name)
	else
		t.failed = t.failed + 1
		print("FAIL " .. name .. "\n     " .. tostring(err))
	end
end

local p = io.popen('ls "' .. root .. '/tests/"*_test.lua 2>/dev/null')
for file in p:lines() do
	assert(loadfile(file))(t)
end
p:close()
print(("%d passed, %d failed"):format(t.passed, t.failed))
os.exit(t.failed == 0 and t.passed > 0 and 0 or 1)
