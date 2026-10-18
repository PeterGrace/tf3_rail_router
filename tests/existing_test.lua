local t = ...
local existing = t.requireTl("gui/pgrace_rail_router/planner/existing.tl")
local junction = t.requireTl("gui/pgrace_rail_router/planner/junction.tl")

local function straightPiece(id, n0, n1, x0, y0, x1, y1)
	return {
		entity = id, node0 = n0, node1 = n1,
		p0 = { x = x0, y = y0, z = 0 }, p1 = { x = x1, y = y1, z = 0 },
		t0 = { x = x1 - x0, y = y1 - y0, z = 0 }, t1 = { x = x1 - x0, y = y1 - y0, z = 0 },
		kind = "ground", signals = {},
	}
end

-- A snapshot from a list of pieces: node degrees counted from the pieces themselves.
local function snapshot(pieces)
	local degree = {}
	for __, p in ipairs(pieces) do
		degree[p.node0] = (degree[p.node0] or 0) + 1
		degree[p.node1] = (degree[p.node1] or 0) + 1
	end
	return { pieces = pieces, degree = degree }
end

-- A 4-track station at (0, 0) facing +x, half 80: end nodes 1..4 at x = 80, y = 7.5, 2.5, −2.5, −7.5. The outer
-- tracks run straight to x = 130 and then merge into the inner ones at x = 180 (nodes 11, 12: degree 3). Then a
-- double track at y = ±2.5 out to `to` in 100 m pieces (the last one shorter).
local function fanStation(to)
	local pieces = {
		straightPiece(101, 1, 5, 80, 7.5, 130, 7.5),
		straightPiece(102, 5, 11, 130, 7.5, 180, 2.5),
		straightPiece(103, 2, 11, 80, 2.5, 180, 2.5),
		straightPiece(104, 3, 12, 80, -2.5, 180, -2.5),
		straightPiece(105, 4, 6, 80, -7.5, 130, -7.5),
		straightPiece(106, 6, 12, 130, -7.5, 180, -2.5),
	}
	local nodeL, nodeR, x, id, n = 11, 12, 180, 200, 1000
	while x < to - 1e-9 do
		local x1 = math.min(x + 100, to)
		pieces[#pieces + 1] = straightPiece(id, nodeL, n, x, 2.5, x1, 2.5)
		pieces[#pieces + 1] = straightPiece(id + 1, nodeR, n + 1, x, -2.5, x1, -2.5)
		nodeL, nodeR, x, id, n = n, n + 1, x1, id + 2, n + 2
	end
	local station = { entity = 1, centre = { x = 0, y = 0 }, dir = { x = 1, y = 0 }, half = 80, ends = { 1, 2, 3, 4 } }
	return station, pieces
end

local function nearY(e, track)
	local p = e.pieces[track][1]
	return p.p0.y
end

t.test("existing: a straight double track past the fan is usable", function()
	local station, pieces = fanStation(1000)
	local r = existing.analyse(station, snapshot(pieces), { [1] = 1, [-1] = 1 })
	local e = r.ends[1]
	t.ok(e ~= nil, "end +1 usable: " .. tostring(r.why[1]))
	t.near(e.length, 820, 10, "the double track's length")
	local start = e.origin.x - 80
	t.ok(start >= 100 - 1e-9 and start <= 105, "starts past the merge switches at x = 100: " .. start)
	t.near(e.origin.y, 0, 1e-9, "on the midline")
	t.near(e.z, 0, 1e-9, "height")
	t.near(e.dir.x, 1, 1e-9, "outward +x")
	t.near(e.dir.y, 0, 1e-9, "outward +x")
	t.near(nearY(e, "near"), 2.5, 1e-9, "near is the +2.5 track (side +1)")
	t.near(nearY(e, "far"), -2.5, 1e-9, "far is the −2.5 track")
	t.eq(#e.pieces.near, 9, "nine near pieces from 180 to 1000")
	t.eq(e.pieces.near[1].entity, 200, "ordered outward")
	t.eq(e.pieces.near[9].entity, 216, "ordered outward")
	t.eq(r.ends[-1], nil, "nothing at the other end")
	t.eq(r.why[-1], "no double track", "no track at −x")
end)

t.test("existing: near and far follow the side", function()
	local station, pieces = fanStation(1000)
	local r = existing.analyse(station, snapshot(pieces), { [1] = -1 })
	t.near(nearY(r.ends[1], "near"), -2.5, 1e-9, "near is the −2.5 track (side −1)")
	t.near(nearY(r.ends[1], "far"), 2.5, 1e-9, "far is the +2.5 track")
end)

t.test("existing: the station facing −x reads its +x end as end −1", function()
	local station, pieces = fanStation(1000)
	station.dir = { x = -1, y = 0 }
	local r = existing.analyse(station, snapshot(pieces), { [-1] = 1 })
	t.ok(r.ends[-1] ~= nil, "end −1 usable")
	t.near(nearY(r.ends[-1], "near"), 2.5, 1e-9, "left of +x outward is still +y")
	t.eq(r.why[1], "no double track", "nothing at −x")
end)

t.test("existing: a double track ending at a switch short of the junction is too short", function()
	local station, pieces = fanStation(300)
	-- A switch at x = 300 on the +2.5 track: a third piece leaves its end node.
	local last = pieces[#pieces - 1]
	pieces[#pieces + 1] = straightPiece(900, last.node1, 9000, 300, 2.5, 400, 8)
	pieces[#pieces + 1] = straightPiece(901, last.node1, 9001, 300, 2.5, 400, 2.5)
	t.ok(120 < junction.needed(300), "the stretch (180 to 300) is short of the junction")
	local r = existing.analyse(station, snapshot(pieces), { [1] = 1 })
	t.eq(r.ends[1], nil, "not usable")
	t.eq(r.why[1], "short", "short")
end)

t.test("existing: signals give positions along the stretch, per track", function()
	local station, pieces = fanStation(1000)
	for __, p in ipairs(pieces) do
		if p.entity == 204 then
			-- The +2.5 track from 380 to 480: a signal facing inward (node1 → node0) at 380 + 50.
			p.signals = { { 0.5, -1 } }
		elseif p.entity == 207 then
			-- The −2.5 track from 480 to 580: facing outward at 480 + 20.
			p.signals = { { 0.2, 1 } }
		end
	end
	local r = existing.analyse(station, snapshot(pieces), { [1] = 1 })
	local e = r.ends[1]
	t.ok(e ~= nil, "right-hand signals are fine: " .. tostring(r.why[1]))
	local start = e.origin.x - 80
	t.eq(#e.signals.near, 1, "one near signal")
	t.near(e.signals.near[1], 430 - 80 - start, 1e-9, "near signal's place")
	t.eq(#e.signals.far, 1, "one far signal")
	t.near(e.signals.far[1], 500 - 80 - start, 1e-9, "far signal's place")
end)

t.test("existing: a signal against right-hand running makes the end unusable", function()
	local station, pieces = fanStation(1000)
	for __, p in ipairs(pieces) do
		if p.entity == 205 then
			-- The −2.5 track (right of outward) facing inward.
			p.signals = { { 0.5, -1 } }
		end
	end
	local r = existing.analyse(station, snapshot(pieces), { [1] = 1 })
	t.eq(r.ends[1], nil, "not usable")
	t.eq(r.why[1], "left-hand", "left-hand running")
end)

t.test("existing: a reversed piece's signal facing is read along its own direction", function()
	local station, pieces = fanStation(1000)
	for __, p in ipairs(pieces) do
		if p.entity == 205 then
			-- Reverse the −2.5 piece: its node0 → node1 now runs inward, so facing −1 governs outward trains.
			p.node0, p.node1, p.p0, p.p1 = p.node1, p.node0, p.p1, p.p0
			p.t0 = { x = -p.t0.x, y = 0, z = 0 }
			p.t1 = p.t0
			p.signals = { { 0.5, -1 } }
		end
	end
	local r = existing.analyse(station, snapshot(pieces), { [1] = 1 })
	t.ok(r.ends[1] ~= nil, "outward on the right track: " .. tostring(r.why[1]))
end)

t.test("existing: a double track bending off the axis is not a straight stretch", function()
	local station, pieces = fanStation(180)
	-- From x = 180, both tracks bend 20 m to the left within 200 m, in 20 m chords.
	local nodeL, nodeR, id, n = 11, 12, 300, 2000
	for i = 1, 10 do
		local x0, x1 = 180 + 20 * (i - 1), 180 + 20 * i
		local d0, d1 = 20 * ((i - 1) / 10) ^ 2, 20 * (i / 10) ^ 2
		pieces[#pieces + 1] = straightPiece(id, nodeL, n, x0, 2.5 + d0, x1, 2.5 + d1)
		pieces[#pieces + 1] = straightPiece(id + 1, nodeR, n + 1, x0, -2.5 + d0, x1, -2.5 + d1)
		nodeL, nodeR, id, n = n, n + 1, id + 2, n + 2
	end
	local r = existing.analyse(station, snapshot(pieces), { [1] = 1 })
	t.eq(r.ends[1], nil, "not usable")
	t.ok(r.why[1] == "short" or r.why[1] == "no double track", "short or none: " .. tostring(r.why[1]))
end)

t.test("existing: a bridge ends a stretch, and a long enough one beyond it is used", function()
	local station, pieces = fanStation(1000)
	for __, p in ipairs(pieces) do
		if p.entity == 204 or p.entity == 205 then
			p.kind = "bridge"
		end
	end
	-- Ground from 180 to 380, too short; a bridge to 480; then ground to 1000, long enough.
	local r = existing.analyse(station, snapshot(pieces), { [1] = 1 })
	t.ok(r.ends[1] ~= nil, "the ground beyond the bridge, 480 to 1000, is long enough: " .. tostring(r.why[1]))
	t.near(r.ends[1].origin.x, 480, 5, "starts past the bridge")
	t.near(r.ends[1].length, 520, 10, "to the track's end")
end)
