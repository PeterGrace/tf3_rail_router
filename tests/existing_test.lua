local t = ...
local existing = t.requireTl("gui/pgrace_rail_router/planner/existing.tl")
local junction = t.requireTl("gui/pgrace_rail_router/planner/junction.tl")

local R = 300

local function straightPiece(id, n0, n1, x0, y0, x1, y1)
	return {
		entity = id, node0 = n0, node1 = n1,
		p0 = { x = x0, y = y0, z = 0 }, p1 = { x = x1, y = y1, z = 0 },
		t0 = { x = x1 - x0, y = y1 - y0, z = 0 }, t1 = { x = x1 - x0, y = y1 - y0, z = 0 },
		kind = "ground", signals = {},
	}
end

-- Builds a snapshot: nodes are shared by position, node degrees counted from the pieces.
local function builder()
	local b = { pieces = {}, ids = {}, nextNode = 1, nextPiece = 100 }
	function b.node(x, y)
		local k = x .. "," .. y
		if not b.ids[k] then
			b.ids[k] = b.nextNode
			b.nextNode = b.nextNode + 1
		end
		return b.ids[k]
	end
	function b.piece(x0, y0, x1, y1)
		local p = straightPiece(b.nextPiece, b.node(x0, y0), b.node(x1, y1), x0, y0, x1, y1)
		b.nextPiece = b.nextPiece + 1
		b.pieces[#b.pieces + 1] = p
		return p
	end
	-- A track at y through the x positions `xs`, one piece between each two.
	function b.track(y, xs)
		local out = {}
		for i = 1, #xs - 1 do
			out[i] = b.piece(xs[i], y, xs[i + 1], y)
		end
		return out
	end
	function b.snapshot()
		local degree = {}
		for __, p in ipairs(b.pieces) do
			degree[p.node0] = (degree[p.node0] or 0) + 1
			degree[p.node1] = (degree[p.node1] or 0) + 1
		end
		return { pieces = b.pieces, degree = degree }
	end
	return b
end

-- {a, a + step, ..., b}, with b last even if off the step.
local function steps(a, b, step)
	local out = {}
	local x = a
	while x < b - 1e-9 do
		out[#out + 1] = x
		x = x + step
	end
	out[#out + 1] = b
	return out
end

local function cat(a, b)
	local out = {}
	for __, v in ipairs(a) do
		out[#out + 1] = v
	end
	for __, v in ipairs(b) do
		out[#out + 1] = v
	end
	return out
end

-- A 4-track station at (0, 0) facing +x, half 80: end nodes at x = 80, y = 7.5, 2.5, −2.5, −7.5. The outer tracks
-- run straight to x = 130 and then merge into the inner ones at x = 180 (degree-3 nodes there).
local function fanStation(b)
	b.piece(80, 7.5, 130, 7.5)
	b.piece(130, 7.5, 180, 2.5)
	b.piece(80, 2.5, 180, 2.5)
	b.piece(80, -2.5, 180, -2.5)
	b.piece(80, -7.5, 130, -7.5)
	b.piece(130, -7.5, 180, -2.5)
	return { entity = 1, centre = { x = 0, y = 0 }, dir = { x = 1, y = 0 }, half = 80,
		ends = { b.node(80, 7.5), b.node(80, 2.5), b.node(80, -2.5), b.node(80, -7.5) } }
end

-- The fan, then a double track at y = ±2.5 from x = 180 to 1000 in 100 m pieces.
local function plain()
	local b = builder()
	local station = fanStation(b)
	local L = b.track(2.5, steps(180, 1000, 100))
	local Rt = b.track(-2.5, steps(180, 1000, 100))
	return b, station, L, Rt
end

t.test("existing: a straight double track past the fan is usable", function()
	local b, station, L, Rt = plain()
	local r = existing.analyse(station, b.snapshot(), { [1] = 1, [-1] = 1 }, R)
	local e = r.ends[1]
	t.ok(e ~= nil, "end +1 usable: " .. tostring(r.why[1]))
	t.near(e.origin.x, 180, 1e-9, "starts past the merge switches, at frame x = 100")
	t.near(e.length, 820, 1e-9, "to the track's end")
	t.near(e.origin.y, 0, 1e-9, "on the midline")
	t.near(e.z, 0, 1e-9, "height")
	t.near(e.dir.x, 1, 1e-9, "outward +x")
	t.near(e.dir.y, 0, 1e-9, "outward +x")
	t.eq(#e.pieces.near, 9, "nine near pieces from 180 to 1000")
	t.ok(e.pieces.near[1] == L[1] and e.pieces.near[9] == L[9], "near: the +2.5 track, ordered outward")
	t.ok(e.pieces.far[1] == Rt[1] and e.pieces.far[9] == Rt[9], "far: the −2.5 track, ordered outward")
	t.eq(r.ends[-1], nil, "nothing at the other end")
	t.eq(r.why[-1], "no double track", "no track at −x")
end)

t.test("existing: near and far follow the side", function()
	local b, station, L, Rt = plain()
	local r = existing.analyse(station, b.snapshot(), { [1] = -1 }, R)
	t.ok(r.ends[1].pieces.near[1] == Rt[1], "near is the −2.5 track (side −1)")
	t.ok(r.ends[1].pieces.far[1] == L[1], "far is the +2.5 track")
end)

t.test("existing: the station facing −x reads its +x end as end −1", function()
	local b, station, L = plain()
	station.dir = { x = -1, y = 0 }
	local r = existing.analyse(station, b.snapshot(), { [-1] = 1 }, R)
	t.ok(r.ends[-1] ~= nil, "end −1 usable")
	t.ok(r.ends[-1].pieces.near[1] == L[1], "left of +x outward is still +y")
	t.eq(r.why[1], "no double track", "nothing at −x")
end)

t.test("existing: the radius sets the length needed", function()
	local b, station = plain()
	t.ok(820 < junction.needed(5000), "820 m is short of a 5000 m radius junction")
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, 5000)
	t.eq(r.why[1], "short", "short at R = 5000")
end)

t.test("existing: a switch to a branch line short of the junction ends it", function()
	local b, station = plain()
	-- A branch leaves the +2.5 track at x = 380 (frame 300) and the corridor; the right track runs on.
	b.piece(380, 2.5, 480, 20)
	t.ok(200 < junction.needed(R), "the stretch (frame 100 to 300) is short of the junction")
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	t.eq(r.ends[1], nil, "not usable")
	t.eq(r.why[1], "short", "short, and not read on past the branch")
end)

t.test("existing: a branch inside the corridor isn't a crossover, and stops the reading", function()
	local b, station = plain()
	b.piece(280, 2.5, 380, 11)
	b.piece(380, 11, 480, 30)
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	t.eq(r.why[1], "short", "short (100 m), though long double track follows")
end)

t.test("existing: a switch just before a short piece ends the stretch at the switch", function()
	local b = builder()
	local station = fanStation(b)
	-- The left track has a 4.5 m piece before a switch at 502 and a 2.9 m one after it, both between 5 m samples.
	local L = b.track(2.5, { 180, 300, 497.5, 502, 504.9, 1000 })
	local Rt = b.track(-2.5, steps(180, 1000, 100))
	b.piece(502, 2.5, 600, 20)
	-- A wrong-way signal beyond the switch doesn't count; a far one past the end, on a listed piece, is kept.
	L[5].signals = { { 0.5, 1 } }
	Rt[4].signals = { { 0.9, 1 } }
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	local e = r.ends[1]
	t.ok(e ~= nil, "usable: " .. tostring(r.why[1]))
	t.near(e.length, 322, 1e-9, "frame 100 to the switch at 422")
	t.eq(#e.pieces.near, 3, "every left piece up to the switch")
	t.ok(e.pieces.near[3] == L[3], "the 4.5 m piece is listed")
	t.eq(#e.pieces.far, 4, "right pieces reaching the switch's x")
	t.eq(#e.signals.near, 0, "none near")
	t.eq(#e.signals.far, 1, "one far")
	t.near(e.signals.far[1], 570 - 180, 1e-9, "past the stretch's end")
end)

t.test("existing: staggered nodes end the stretch at the earlier track end", function()
	local b = builder()
	local station = fanStation(b)
	b.track(2.5, steps(180, 1000, 100))
	b.track(-2.5, cat({ 180 }, steps(230, 950, 100)))
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	t.near(r.ends[1].length, 770, 1e-9, "to the right track's end at 950")
end)

t.test("existing: a crossover pair right after the fan is skipped", function()
	local b = builder()
	local station = fanStation(b)
	b.track(2.5, cat({ 180, 220 }, steps(330, 1000, 100)))
	b.track(-2.5, cat({ 180, 265 }, steps(285, 1000, 100)))
	b.piece(220, 2.5, 265, -2.5)
	b.piece(285, -2.5, 330, 2.5)
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	local e = r.ends[1]
	t.ok(e ~= nil, "usable: " .. tostring(r.why[1]))
	t.near(e.origin.x, 330, 1e-9, "past the crossovers")
	t.near(e.length, 670, 1e-9, "to the track's end")
end)

t.test("existing: a short stretch ending at a crossover is read on past it", function()
	local b = builder()
	local station = fanStation(b)
	b.track(2.5, cat({ 180, 230 }, steps(330, 1000, 100)))
	b.track(-2.5, cat({ 180, 230 }, steps(375, 1000, 100)))
	b.piece(330, 2.5, 375, -2.5)
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	local e = r.ends[1]
	t.ok(e ~= nil, "usable: " .. tostring(r.why[1]))
	t.near(e.origin.x, 375, 1e-9, "past the crossover")
	t.near(e.length, 625, 1e-9, "to the track's end")
end)

t.test("existing: signals give positions along the stretch, per track", function()
	local b, station, L, Rt = plain()
	-- The +2.5 track from 380 to 480: facing inward (node1 → node0) at 430.
	L[3].signals = { { 0.5, -1 } }
	-- The −2.5 track from 480 to 580: facing outward at 500.
	Rt[4].signals = { { 0.2, 1 } }
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	local e = r.ends[1]
	t.ok(e ~= nil, "right-hand signals are fine: " .. tostring(r.why[1]))
	t.eq(#e.signals.near, 1, "one near signal")
	t.near(e.signals.near[1], 430 - 180, 1e-9, "near signal's place")
	t.eq(#e.signals.far, 1, "one far signal")
	t.near(e.signals.far[1], 500 - 180, 1e-9, "far signal's place")
end)

t.test("existing: a signal against right-hand running makes the end unusable", function()
	local b, station, __, Rt = plain()
	Rt[3].signals = { { 0.5, -1 } }
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	t.eq(r.ends[1], nil, "not usable")
	t.eq(r.why[1], "left-hand", "left-hand running")
end)

t.test("existing: a reversed piece's signal facing is read along its own direction", function()
	local b, station, __, Rt = plain()
	local p = Rt[3]
	-- Node0 → node1 now runs inward, so facing −1 governs outward trains.
	p.node0, p.node1, p.p0, p.p1 = p.node1, p.node0, p.p1, p.p0
	p.t0 = { x = -p.t0.x, y = 0, z = 0 }
	p.t1 = p.t0
	p.signals = { { 0.5, -1 } }
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	t.ok(r.ends[1] ~= nil, "outward on the right track: " .. tostring(r.why[1]))
	t.near(r.ends[1].length, 820, 1e-9, "the reversed piece continues the track")
end)

t.test("existing: a double track bending off the axis is not a straight stretch", function()
	local b = builder()
	local station = fanStation(b)
	-- From x = 180, both tracks bend 20 m to the left within 200 m, in 20 m chords.
	for i = 1, 10 do
		local x0, x1 = 180 + 20 * (i - 1), 180 + 20 * i
		local d0, d1 = 20 * ((i - 1) / 10) ^ 2, 20 * (i / 10) ^ 2
		b.piece(x0, 2.5 + d0, x1, 2.5 + d1)
		b.piece(x0, -2.5 + d0, x1, -2.5 + d1)
	end
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	t.eq(r.ends[1], nil, "not usable")
	t.ok(r.why[1] == "short" or r.why[1] == "no double track", "short or none: " .. tostring(r.why[1]))
end)

t.test("existing: a piece bulging sideways between straight chord ends breaks the stretch", function()
	local b = builder()
	local station = fanStation(b)
	b.track(2.5, { 180, 280 })
	b.track(-2.5, { 180, 280 })
	for __, y in ipairs({ 2.5, -2.5 }) do
		local p = b.piece(280, y, 1280, y)
		p.t0 = { x = 1000, y = 300, z = 0 }
		p.t1 = { x = 1000, y = 300, z = 0 }
	end
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	t.eq(r.ends[1], nil, "not usable")
	t.eq(r.why[1], "short", "100 m before the bulging piece")
end)

-- Puts the track from x = 180 on a grade (rising outward).
local function grade(b, g)
	for __, p in ipairs(b.pieces) do
		if p.p0.x >= 180 and p.p1.x >= 180 then
			p.p0.z = g * (p.p0.x - 180)
			p.p1.z = g * (p.p1.x - 180)
			p.t0.z = p.p1.z - p.p0.z
			p.t1.z = p.t0.z
		end
	end
end

t.test("existing: the stretch must be level", function()
	local b, station = plain()
	grade(b, 0.003)
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	t.eq(r.ends[1], nil, "a 0.3% grade climbs 0.5 m in 167 m")
	t.eq(r.why[1], "short", "short")
	local b2, station2 = plain()
	grade(b2, 0.02)
	local r2 = existing.analyse(station2, b2.snapshot(), { [1] = 1 }, R)
	t.eq(r2.ends[1], nil, "a 2% grade isn't level")
	local b3, station3 = plain()
	grade(b3, 0.0005)
	local r3 = existing.analyse(station3, b3.snapshot(), { [1] = 1 }, R)
	t.ok(r3.ends[1] ~= nil, "0.05% climbs 0.41 m over 820 m: " .. tostring(r3.why[1]))
end)

t.test("existing: a hump between level ends breaks the stretch", function()
	local b, station, L, Rt = plain()
	-- The 280–380 pieces rise and fall again: level ends, tangents 30% up and down.
	for __, p in ipairs({ L[2], Rt[2] }) do
		p.t0 = { x = 100, y = 0, z = 30 }
		p.t1 = { x = 100, y = 0, z = -30 }
	end
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	t.ok(r.ends[1] ~= nil, "usable beyond the hump: " .. tostring(r.why[1]))
	t.near(r.ends[1].origin.x, 380, 1e-9, "starts past the hump")
	t.near(r.ends[1].length, 620, 1e-9, "to the track's end")
end)

-- A 2-track station at (0, 0) facing +x, half 80, its end nodes at the platform end (frame x = 0).
local function twoTrack(b)
	return { entity = 1, centre = { x = 0, y = 0 }, dir = { x = 1, y = 0 }, half = 80,
		ends = { b.node(80, 2.5), b.node(80, -2.5) } }
end

t.test("existing: a branch switch just past a crossover stops the reading", function()
	local b = builder()
	local station = twoTrack(b)
	-- Frame x: a crossover from 52 on the right track to 103 on the left, a branch off the left at 106.
	b.track(2.5, cat({ 80, 183, 186 }, steps(286, 1000, 100)))
	b.track(-2.5, cat({ 80, 132 }, steps(232, 1000, 100)))
	b.piece(132, -2.5, 183, 2.5)
	b.piece(186, 2.5, 286, 20)
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	t.eq(r.ends[1], nil, "not usable")
	t.eq(r.why[1], "short", "short: the branch is another line's")
end)

t.test("existing: a siding coming into the corridor and joining a track stops the reading", function()
	local b = builder()
	local station = twoTrack(b)
	b.track(2.5, steps(80, 1000, 100))
	b.track(-2.5, steps(80, 1000, 100))
	-- Frame x: from outside the corridor to (100, 11), then down to the left track at 400 (world 480).
	b.piece(130, 30, 180, 11)
	b.piece(180, 11, 480, 2.5)
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	t.eq(r.ends[1], nil, "not usable")
	t.eq(r.why[1], "short", "short: the stretch past the siding's switch isn't the station's")
end)

t.test("existing: a branch line joining the right track stops the reading", function()
	local b = builder()
	local station = twoTrack(b)
	b.track(2.5, steps(80, 1000, 100))
	b.track(-2.5, steps(80, 1000, 100))
	-- Frame x: in from the right at 150, joining the right track at a switch at 300 (world 380).
	b.piece(180, -40, 230, -10)
	b.piece(230, -10, 380, -2.5)
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	t.eq(r.ends[1], nil, "not usable")
	t.eq(r.why[1], "short", "short")
end)

t.test("existing: a crossover's far switch must be towards the other track", function()
	local b = builder()
	local station = twoTrack(b)
	-- The left track's switch at 280 leads to a switch on a third line further left, not to the right track.
	b.track(2.5, cat({ 80, 180 }, steps(280, 1000, 100)))
	b.track(-2.5, steps(80, 1000, 100))
	b.track(7.5, { 300, 330, 400 })
	b.piece(280, 2.5, 330, 7.5)
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	t.eq(r.ends[1], nil, "not usable")
	t.eq(r.why[1], "short", "short (100 to 200), and not read on")
end)

t.test("existing: a bridge ends a stretch, and a long enough one beyond it is used", function()
	local b, station, L, Rt = plain()
	-- Ground from 180 to 380, too short; a bridge to 480; then ground to 1000, long enough.
	L[3].kind = "bridge"
	Rt[3].kind = "bridge"
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	t.ok(r.ends[1] ~= nil, "the ground beyond the bridge is long enough: " .. tostring(r.why[1]))
	t.near(r.ends[1].origin.x, 480, 1e-9, "starts past the bridge")
	t.near(r.ends[1].length, 520, 1e-9, "to the track's end")
end)

t.test("existing: station end nodes a little behind the platform end still lead out", function()
	local b = builder()
	b.track(2.5, steps(77, 1000, 100))
	b.track(-2.5, steps(77, 1000, 100))
	local station = { entity = 1, centre = { x = 0, y = 0 }, dir = { x = 1, y = 0 }, half = 80,
		ends = { b.node(77, 2.5), b.node(77, -2.5) } }
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	t.ok(r.ends[1] ~= nil, "usable: " .. tostring(r.why[1]))
	t.near(r.ends[1].origin.x, 77, 1e-9, "starts at the end nodes, frame x = −3")
	t.near(r.ends[1].length, 923, 1e-9, "to the track's end")
end)
