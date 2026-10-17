local mapformat : PgraceRailRouterMapFormat = {
	VERSION = 1,
	SPACING = 25.0,
	CHUNK = 128,
	LAND = "L",
	WATER = "W",
	OFF = "X",
}

local type Vec3 = PgraceRailRouterMapFormat.Vec3
local type Town = PgraceRailRouterMapFormat.Town
local type Obj = PgraceRailRouterMapFormat.Obj
local type Edge = PgraceRailRouterMapFormat.Edge

-- A field that must not contain spaces: whitespace becomes "_", and nil or "" becomes "-".
local function token(s : string) : string
	if s == nil or s == "" then
		return "-"
	end
	return (s:gsub("%s", "_"))
end

-- A last field, which may contain spaces but not line breaks.
local function tail(s : string) : string
	if s == nil then
		return ""
	end
	return (s:gsub("[\r\n]", " "))
end

local function num(x : number) : string
	if x == nil or x ~= x then
		return "nan"
	end
	return string.format("%.2f", x)
end

local function vec(v : Vec3) : string
	if v == nil then
		return "- - -"
	end
	return num(v.x) .. " " .. num(v.y) .. " " .. num(v.z)
end

local function int(n : integer) : string
	if n == nil then
		return "-1"
	end
	return string.format("%d", n)
end

function mapformat.decimetres(h : number) : integer
	if h == nil or h ~= h then
		return 0
	end
	return math.floor(h * 10 + 0.5)
end

function mapformat.rle(flags : {string}) : string
	local parts : {string} = {}
	local current : string = nil as string
	local run = 0
	for __, f in ipairs(flags) do
		if f == current then
			run = run + 1
		else
			if current ~= nil then
				table.insert(parts, current .. string.format("%d", run))
			end
			current, run = f, 1
		end
	end
	if current ~= nil then
		table.insert(parts, current .. string.format("%d", run))
	end
	return table.concat(parts)
end

function mapformat.begin() : string
	return "begin " .. string.format("%d", mapformat.VERSION)
end

function mapformat.meta(key : string, value : string) : string
	return "meta " .. token(key) .. " " .. tail(value)
end

function mapformat.extent(x0 : number, y0 : number, x1 : number, y1 : number, source : string) : string
	return "extent " .. num(x0) .. " " .. num(y0) .. " " .. num(x1) .. " " .. num(y1) .. " " .. token(source)
end

function mapformat.terrain(key : string, value : string) : string
	return "terrain " .. token(key) .. " " .. tail(value)
end

function mapformat.grid(spacing : number, x0 : number, y0 : number, nx : integer, ny : integer) : string
	return "grid " .. num(spacing) .. " " .. num(x0) .. " " .. num(y0) .. " " .. int(nx) .. " " .. int(ny)
end

function mapformat.row(iy : integer, ix : integer, heights : {number}, flags : {string}) : string
	local parts : {string} = {}
	local previous = 0
	for k, h in ipairs(heights) do
		local d = mapformat.decimetres(h)
		if k == 1 then
			table.insert(parts, string.format("%d", d))
		else
			table.insert(parts, string.format("%d", d - previous))
		end
		previous = d
	end
	return "r " .. int(iy) .. " " .. int(ix) .. " " .. table.concat(parts, ",") .. " " .. mapformat.rle(flags)
end

function mapformat.town(t : Town) : string
	return "town " .. int(t.id) .. " " .. num(0.5 * (t.x0 + t.x1)) .. " " .. num(0.5 * (t.y0 + t.y1)) .. " "
		.. num(t.x0) .. " " .. num(t.y0) .. " " .. num(t.x1) .. " " .. num(t.y1) .. " " .. tail(t.name)
end

function mapformat.track(fields : {string : any}) : string
	local keys : {string} = {}
	for k, v in pairs(fields) do
		if v ~= nil then
			table.insert(keys, k)
		end
	end
	table.sort(keys)
	local parts : {string} = {}
	for __, k in ipairs(keys) do
		local v = tostring(fields[k]):gsub("[;\r\n]", " ")
		table.insert(parts, k .. "=" .. v)
	end
	return "track " .. table.concat(parts, ";")
end

function mapformat.obj(o : Obj) : string
	local box = "- - - - - -"
	if o.min ~= nil and o.max ~= nil then
		box = vec(o.min) .. " " .. vec(o.max)
	end
	return "obj " .. int(o.id) .. " " .. token(o.kind) .. " " .. token(o.boxSource) .. " " .. box .. " "
		.. int(o.construction) .. " " .. int(o.town) .. " " .. token(o.file)
end

function mapformat.edge(e : Edge) : string
	return "edge " .. int(e.id) .. " " .. token(e.kind) .. " " .. token(e.edgeType) .. " " .. int(e.node0) .. " "
		.. int(e.node1) .. " " .. vec(e.p0) .. " " .. vec(e.p1) .. " " .. vec(e.t0) .. " " .. vec(e.t1) .. " "
		.. token(e.template)
end

function mapformat.finish(counts : {string : integer}) : string
	local keys : {string} = {}
	for k in pairs(counts) do
		table.insert(keys, k)
	end
	table.sort(keys)
	local parts : {string} = {}
	for __, k in ipairs(keys) do
		table.insert(parts, k .. "=" .. int(counts[k]))
	end
	return "end " .. table.concat(parts, " ")
end

return mapformat
