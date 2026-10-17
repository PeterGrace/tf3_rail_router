-- Writes synthetic map captures through the mod's own format functions (mapformat.tl), for the maplib and replay
-- tests. usage: local synth = dofile(root .. "/tests/synthmap.lua")(mapformat)
return function(mapformat)
	local synth = {}

	-- spec: x0, y0, x1, y1 (extent), heightFn(x, y), flagFn(x, y) ("L", "W" or "X"; default "L"), towns
	-- {{id, name, x, y, r}}, objects {mapformat.Obj}, edges {mapformat.Edge}, tracks {{key = value}}, year, chunk
	-- (points per line; default mapformat.CHUNK), meta {key = value}. Returns the lines, each starting "MAP ".
	function synth.lines(spec)
		local out = {}
		local function emit(line)
			out[#out + 1] = "MAP " .. line
		end
		local S = mapformat.SPACING
		local nx = math.floor((spec.x1 - spec.x0) / S + 1e-6) + 1
		local ny = math.floor((spec.y1 - spec.y0) / S + 1e-6) + 1
		local chunk = spec.chunk or mapformat.CHUNK
		local counts = { r = 0, town = 0, track = 0, obj = 0, edge = 0, failures = 0 }
		emit(mapformat.begin())
		emit(mapformat.meta("captured", "2026-10-16T12:00:00Z"))
		emit(mapformat.meta("gameYear", tostring(spec.year or 1950)))
		for k, v in pairs(spec.meta or {}) do
			emit(mapformat.meta(k, v))
		end
		emit(mapformat.extent(spec.x0, spec.y0, spec.x1, spec.y1, "bbox"))
		emit(mapformat.terrain("size", "4 4"))
		emit(mapformat.terrain("waterLevel", "0"))
		emit(mapformat.grid(S, spec.x0, spec.y0, nx, ny))
		for _, t in ipairs(spec.towns or {}) do
			local r = t.r or 300
			emit(mapformat.town({ id = t.id, name = t.name, x0 = t.x - r, y0 = t.y - r, x1 = t.x + r, y1 = t.y + r }))
			counts.town = counts.town + 1
		end
		for _, tr in ipairs(spec.tracks or {}) do
			emit(mapformat.track(tr))
			counts.track = counts.track + 1
		end
		for iy = 1, ny do
			local y = spec.y0 + (iy - 1) * S
			local ix = 1
			while ix <= nx do
				local heights, flags = {}, {}
				for k = ix, math.min(nx, ix + chunk - 1) do
					local x = spec.x0 + (k - 1) * S
					heights[#heights + 1] = spec.heightFn and spec.heightFn(x, y) or 0
					flags[#flags + 1] = spec.flagFn and spec.flagFn(x, y) or "L"
				end
				emit(mapformat.row(iy, ix, heights, flags))
				counts.r = counts.r + 1
				ix = ix + chunk
			end
		end
		for _, o in ipairs(spec.objects or {}) do
			emit(mapformat.obj(o))
			counts.obj = counts.obj + 1
		end
		for _, e in ipairs(spec.edges or {}) do
			emit(mapformat.edge(e))
			counts.edge = counts.edge + 1
		end
		emit(mapformat.finish(counts))
		return out
	end

	function synth.iter(lines)
		local i = 0
		return function()
			i = i + 1
			return lines[i]
		end
	end

	function synth.write(path, lines)
		local f = assert(io.open(path, "w"))
		f:write(table.concat(lines, "\n"), "\n")
		f:close()
	end

	-- The track types survey.trackTypes gives on a stock map (as the log shows them).
	synth.TRACKS = {
		{ name = "::/infrastructure/track/simple/simple.street_template", label = "Simple Tracks", cost = 60,
			speed = 27.777, maxSlopeBuild = 0.085, minCurveRadiusBuild = 55, trackDistance = 5, yearFrom = 0, yearTo = 0,
			catenaryYearFrom = 0 },
		{ name = "::/infrastructure/track/standard/standard.street_template", label = "Standard Tracks", cost = 180,
			speed = 44.44, maxSlopeBuild = 0.085, minCurveRadiusBuild = 55, trackDistance = 5, yearFrom = 1930,
			yearTo = 0, catenary = "::/infrastructure/track/standard/standard_catenary.street_template",
			catenaryYearFrom = 1930 },
	}

	return synth
end
