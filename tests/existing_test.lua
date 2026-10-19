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
		local k = ("%.6f,%.6f"):format(x, y)
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

-- A piece along an arc: from angle a0 to a1 (radians, CCW positive) on a circle centre (cx, cy), radius r; tangents
-- by the 4R·tan(θ/4) rule the game's curves follow (a negative θ gives tangents pointing clockwise).
local function arcPiece(id, n0, n1, cx, cy, r, a0, a1)
	local th = a1 - a0
	local k = 4 * r * math.tan(th / 4) / r
	local function pt(a) return { x = cx + r * math.cos(a), y = cy + r * math.sin(a), z = 0 } end
	local function tg(a) return { x = -math.sin(a) * r * k, y = math.cos(a) * r * k, z = 0 } end
	return { entity = id, node0 = n0, node1 = n1, p0 = pt(a0), p1 = pt(a1), t0 = tg(a0), t1 = tg(a1),
		kind = "ground", signals = {} }
end

-- Adds an arc to the builder in `n` pieces (nodes shared by position, as b.piece does); returns its end point and the
-- unit direction of travel there.
local function addArc(b, cx, cy, r, a0, a1, n)
	local pieces = {}
	for i = 1, n do
		local s0, s1 = a0 + (a1 - a0) * (i - 1) / n, a0 + (a1 - a0) * i / n
		local p = arcPiece(b.nextPiece, 0, 0, cx, cy, r, s0, s1)
		p.node0, p.node1 = b.node(p.p0.x, p.p0.y), b.node(p.p1.x, p.p1.y)
		b.nextPiece = b.nextPiece + 1
		b.pieces[#b.pieces + 1] = p
		pieces[i] = p
	end
	local last = pieces[n]
	local d = math.sqrt(last.t1.x ^ 2 + last.t1.y ^ 2)
	return last.p1, { x = last.t1.x / d, y = last.t1.y / d }, pieces
end

-- A straight track from p along the unit d, `len` long, in pieces of `step`.
local function addStraight(b, p, d, len, step)
	local out = {}
	local n = math.ceil(len / step - 1e-9)
	for i = 1, n do
		local l0, l1 = len * (i - 1) / n, len * i / n
		out[i] = b.piece(p.x + d.x * l0, p.y + d.y * l0, p.x + d.x * l1, p.y + d.y * l1)
	end
	return out
end

-- The fan, 150 m of straight double track (x = 180 to 330), both tracks turning `deg` degrees left on concentric arcs
-- (midline radius `r`, in `n` pieces each), then `tail` metres straight on in 100 m pieces. Returns the builder, the
-- station, the arcs' centre and each track's tail pieces ([1] the left track's, [2] the right one's).
local function curved(r, deg, tail, n)
	local b = builder()
	local station = fanStation(b)
	b.track(2.5, { 180, 230, 330 })
	b.track(-2.5, { 180, 280, 330 })
	local th = math.rad(deg)
	local cx, cy = 330, r
	local tails = {}
	for i, y in ipairs({ 2.5, -2.5 }) do
		local p, d = addArc(b, cx, cy, r - y, -math.pi / 2, -math.pi / 2 + th, n or 2)
		tails[i] = tail > 0 and addStraight(b, p, d, tail, 100) or {}
	end
	return b, station, { x = cx, y = cy }, tails
end

t.test("existing: the arc helper stays on its circle", function()
	local network = t.requireTl("gui/pgrace_rail_router/planner/network.tl")
	for __, case in ipairs({ { 0, 0.7 }, { 1, -0.6 } }) do
		local p = arcPiece(1, 1, 2, 10, 20, 300, case[1], case[1] + case[2])
		for i = 0, 10 do
			local q = network.hermiteAt(p, i / 10)
			t.near(math.sqrt((q.x - 10) ^ 2 + (q.y - 20) ^ 2), 300, 0.02, "on the circle, θ = " .. case[2])
		end
	end
end)

t.test("existing: a stretch carries on through a curve", function()
	local midline = t.requireTl("gui/pgrace_rail_router/planner/midline.tl")
	local b, station, c = curved(300, 40, 400)
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	local e = r.ends[1]
	t.ok(e ~= nil, "usable: " .. tostring(r.why[1]))
	t.near(e.origin.x, 180, 1e-6, "starts past the fan")
	t.near(e.length, 150 + 300 * math.rad(40) + 400, 5, "through the curve to the track's end")
	t.eq(#r.stretches[1], 1, "one stretch")
	t.ok(r.stretches[1][1] == e, "ends[1] is the first stretch")
	local p = midline.at(e.frame, 150 + 300 * math.rad(20))
	t.near(math.sqrt((p.x - c.x) ^ 2 + (p.y - c.y) ^ 2), 300, 0.3, "the midline halfway round lies on the curve")
	local q, d = midline.at(e.frame, e.length - 1)
	t.near(d.x, math.cos(math.rad(40)), 0.01, "the direction past the curve: x")
	t.near(d.y, math.sin(math.rad(40)), 0.01, "the direction past the curve: y")
	t.near(midline.straightUntil(e.frame, 0, 0.005), 150, 3, "straight until the curve")
	t.eq(#e.pieces.near, 2 + 2 + 4, "near pieces: two straight, two on the arc, four after")
	t.eq(#e.pieces.far, 2 + 2 + 4, "far pieces")
	-- The nodes along the midline: the arc's middle node of the left (inner) track lies at 150 + 300·θ/2.
	local found = false
	for __, x in ipairs(e.nodes.near) do
		found = found or math.abs(x - (150 + 300 * math.rad(20))) < 0.5
	end
	t.ok(found, "the inner track's mid-arc node, projected onto the midline")
	t.ok(q ~= nil, "a point")
end)

t.test("existing: tracks drifting apart on a curve end the stretch where they pass 5.5 m", function()
	local b = builder()
	local station = fanStation(b)
	b.track(2.5, { 180, 230, 330 })
	b.track(-2.5, { 180, 280, 330 })
	-- The left track turns on radius 297.5 about (330, 300); the right one starts tangent beside it but on a circle
	-- 4 m wider (306.5 about (330, 304)), so the gap grows from 5 m as they turn.
	local th = math.rad(40)
	local p, d = addArc(b, 330, 300, 297.5, -math.pi / 2, -math.pi / 2 + th, 2)
	addStraight(b, p, d, 400, 100)
	p, d = addArc(b, 330, 304, 306.5, -math.pi / 2, -math.pi / 2 + th, 2)
	addStraight(b, p, d, 400, 100)
	-- The gap at angle φ round the left arc: 306.5 − |(297.5 sin φ, −297.5 cos φ − 4)|; 5.5 m at cos φ = 2078.75 / 2380.
	local phi = math.acos(2078.75 / 2380)
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	t.near(r.longest[1], 150 + 300 * phi, 3, "the stretch ends where the gap passes 5.5 m")
	t.eq(#r.stretches[1], 1, "and no other: they stay apart")
end)

t.test("existing: a third track beside the stretch ends it, and the next starts past it", function()
	local b = builder()
	local station = fanStation(b)
	b.track(2.5, steps(180, 1200, 100))
	b.track(-2.5, steps(180, 1200, 100))
	-- A lone track 9 m left of the midline from x = 600 to 700.
	b.piece(600, 9, 700, 9)
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	t.eq(#r.stretches[1], 2, "two stretches")
	local s1, s2 = r.stretches[1][1], r.stretches[1][2]
	t.near(s1.origin.x, 180, 1e-6, "the first from the fan")
	t.near(s1.length, 420, 3, "ends near x = 600")
	t.near(s2.origin.x, 700, 3, "the second starts near x = 700")
	t.near(s2.origin.x + s2.length, 1200, 1e-6, "to the track's end")
end)

t.test("existing: a bridge past a curve ends a stretch, and the next starts past it", function()
	local b, station, __, tails = curved(300, 40, 600)
	tails[1][2].kind, tails[2][2].kind = "bridge", "bridge"
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	t.eq(#r.stretches[1], 2, "two stretches")
	local s1, s2 = r.stretches[1][1], r.stretches[1][2]
	t.ok(r.ends[1] == s1, "ends[1] is the first")
	t.near(s1.length, 150 + 300 * math.rad(40) + 100, 1, "to the bridge")
	local far = { x = (tails[1][2].p1.x + tails[2][2].p1.x) / 2, y = (tails[1][2].p1.y + tails[2][2].p1.y) / 2 }
	t.near(s2.origin.x, far.x, 0.05, "the second starts at the bridge's far end: x")
	t.near(s2.origin.y, far.y, 0.05, "y")
	t.near(s2.length, 400, 0.05, "to the track's end")
	t.near(s2.dir.x, math.cos(math.rad(40)), 1e-3, "along the track past the curve")
end)

t.test("existing: stretches lists every long one, split by a crossover pair; ends[k] is the first", function()
	local b = builder()
	local station = fanStation(b)
	-- A crossover from the left track at 600 to the right one at 645, and back from 665 to 710.
	b.track(2.5, cat({ 180, 300, 400, 500, 600 }, steps(710, 1400, 100)))
	b.track(-2.5, cat({ 180, 300, 400, 500, 600, 645 }, steps(665, 1400, 100)))
	b.piece(600, 2.5, 645, -2.5)
	b.piece(665, -2.5, 710, 2.5)
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	t.eq(#r.stretches[1], 2, "two long stretches (the 20 m between the crossovers is short)")
	local s1, s2 = r.stretches[1][1], r.stretches[1][2]
	t.ok(r.ends[1] == s1, "ends[1] is the first")
	t.near(s1.origin.x, 180, 1e-6, "the first from the fan")
	t.near(s1.length, 420, 1e-6, "to the first crossover's switch")
	t.near(s2.origin.x, 710, 1e-6, "the second past the second crossover")
	t.near(s2.length, 690, 1e-6, "to the track's end")
	t.near(r.longest[1], 690, 1e-6, "the longest")
end)

t.test("existing: a stretch still on a curve at REACH ends there, its frame running on straight", function()
	local midline = t.requireTl("gui/pgrace_rail_router/planner/midline.tl")
	-- 150 m straight, then 150° on a 600 m radius: past REACH (1500 m from the platform end at x = 80).
	local b, station, c = curved(600, 150, 0, 6)
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	local e = r.ends[1]
	t.ok(e ~= nil, "usable: " .. tostring(r.why[1]))
	-- Each track is read 1400 m along itself from the start (100 m out); the outer (right) one gets there first,
	-- 1250 m round its 602.5 m arc.
	local phi = 1250 / 602.5
	t.near(e.length, 150 + 600 * phi, 2, "ends where the outer track reaches REACH")
	local p, d = midline.at(e.frame, e.length)
	t.near(math.sqrt((p.x - c.x) ^ 2 + (p.y - c.y) ^ 2), 600, 0.3, "on the curve at its end")
	t.near(d.x, math.cos(phi), 0.01, "the curve's direction there: x")
	t.near(d.y, math.sin(phi), 0.01, "y")
	-- Past its length the frame runs on straight along that direction, leaving the curve (accepted: a junction's
	-- footprint reaching past a stretch's end is bounded by REACH).
	local q = midline.at(e.frame, e.length + 50)
	t.near(q.x, p.x + d.x * 50, 1e-9, "straight on: x")
	t.near(q.y, p.y + d.y * 50, 1e-9, "straight on: y")
	t.ok(math.sqrt((q.x - c.x) ^ 2 + (q.y - c.y) ^ 2) > 601, "off the curve")
end)

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
	-- Each track's nodes along the stretch: 0, 100, ... 800 and its end at 820.
	for __, track in ipairs({ "near", "far" }) do
		t.eq(#e.nodes[track], 10, track .. ": ten nodes")
		t.near(e.nodes[track][2], 100, 1e-9, track .. ": 100 m out")
		t.near(e.nodes[track][10], 820, 1e-9, track .. ": the track's end")
	end
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

t.test("existing: a double track bending off the axis is read on, the frame following the bend", function()
	local midline = t.requireTl("gui/pgrace_rail_router/planner/midline.tl")
	local b = builder()
	local station = fanStation(b)
	-- Straight from x = 180 to 230, then both tracks bend 20 m to the left within 200 m in 20 m chords (kinks at the
	-- nodes), then run 400 m straight on along the last chord.
	b.track(2.5, { 180, 230 })
	b.track(-2.5, { 180, 230 })
	local last
	for i = 1, 10 do
		local x0, x1 = 230 + 20 * (i - 1), 230 + 20 * i
		local d0, d1 = 20 * ((i - 1) / 10) ^ 2, 20 * (i / 10) ^ 2
		b.piece(x0, 2.5 + d0, x1, 2.5 + d1)
		b.piece(x0, -2.5 + d0, x1, -2.5 + d1)
		last = { x = 20, y = d1 - d0 }
	end
	local l = math.sqrt(last.x ^ 2 + last.y ^ 2)
	local d = { x = last.x / l, y = last.y / l }
	addStraight(b, { x = 430, y = 22.5 }, d, 400, 100)
	addStraight(b, { x = 430, y = 17.5 }, d, 400, 100)
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	local e = r.ends[1]
	t.ok(e ~= nil, "usable: " .. tostring(r.why[1]))
	t.near(e.origin.x, 180, 1e-6, "from the fan")
	t.near(midline.straightUntil(e.frame, 0, 0.005), 50, 3, "straight until the bend")
	-- The midline through the bend: the centre of the tracks' chords (they're 5 m apart up and down, a little less
	-- square across, so the midline keeps to their middle).
	local x, y = midline.project(e.frame, { x = 330, y = 5 })
	t.near(y, 0, 0.2, "the bend's middle on the midline")
	x, y = midline.project(e.frame, { x = 430 + d.x * 200, y = 20 + d.y * 200 })
	t.near(y, 0, 0.2, "past the bend on the midline")
	local __, dir = midline.at(e.frame, e.length - 10)
	t.near(dir.y, d.y, 1e-3, "along the tracks past the bend")
	t.ok(x > 0, "x")
end)

t.test("existing: a piece bulging sideways between straight chord ends is read along its curve", function()
	local midline = t.requireTl("gui/pgrace_rail_router/planner/midline.tl")
	local network = t.requireTl("gui/pgrace_rail_router/planner/network.tl")
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
	local e = r.ends[1]
	t.ok(e ~= nil, "usable: " .. tostring(r.why[1]))
	-- The bulging pieces leave the straight ones at a 17° kink, where a point just past it on one track isn't square
	-- across from the other: the 100 m before it is a short stretch, and the long one starts a step or two past it.
	t.near(e.origin.x, 280, 3, "from just past the kink")
	-- The two curves are the same one 5 m apart up and down; the midline is their middle one (y = 0), whose length
	-- it takes.
	local centre = { p0 = { x = 280, y = 0, z = 0 }, p1 = { x = 1280, y = 0, z = 0 }, t0 = { x = 1000, y = 300, z = 0 },
		t1 = { x = 1000, y = 300, z = 0 } }
	local len, prev = 0, network.hermiteAt(centre, 0)
	for i = 1, 2000 do
		local q = network.hermiteAt(centre, i / 2000)
		len, prev = len + math.sqrt((q.x - prev.x) ^ 2 + (q.y - prev.y) ^ 2), q
	end
	-- (Within 1.5 m: the tracks' ends, level up and down, are 1.4 m apart along them where the curve ends at 17°.)
	t.near(e.length, len - (e.origin.x - 280), 1.5, "along the curve to the track's end")
	for __, s in ipairs({ 0.2, 0.5, 0.8 }) do
		local q = network.hermiteAt(centre, s)
		local __, y = midline.project(e.frame, q)
		t.near(y, 0, 0.05, "the middle curve is the midline at s = " .. s)
	end
end)

-- Puts the track from x = 180 on a grade (rising outward), level again from `kink` if given.
local function grade(b, g, kink)
	local function z(x)
		return g * (math.min(x, kink or math.huge) - 180)
	end
	for __, p in ipairs(b.pieces) do
		if p.p0.x >= 180 and p.p1.x >= 180 then
			p.p0.z = z(p.p0.x)
			p.p1.z = z(p.p1.x)
			p.t0.z = p.p1.z - p.p0.z
			p.t1.z = p.t0.z
		end
	end
end

t.test("existing: a steady grade is usable, and the end carries it", function()
	local b, station = plain()
	grade(b, 0.02)
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	local e = r.ends[1]
	t.ok(e ~= nil, "a 2% grade: " .. tostring(r.why[1]))
	t.near(e.grade, 0.02, 1e-9, "the grade")
	t.near(e.z, 0, 1e-9, "the start's height")
	t.near(e.length, 820, 1e-9, "to the track's end")
end)

t.test("existing: a change of grade is read on, the frame following it", function()
	local midline = t.requireTl("gui/pgrace_rail_router/planner/midline.tl")
	local b, station = plain()
	grade(b, 0.02, 580)
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	local e = r.ends[1]
	t.ok(e ~= nil, "usable: " .. tostring(r.why[1]))
	t.near(e.length, 820, 1e-6, "on past the kink at world x = 580 to the track's end")
	t.near(e.grade, 0.02, 1e-9, "the start's grade")
	t.near(midline.grade(e.frame, 200), 0.02, 1e-9, "2% before the kink")
	t.near(midline.grade(e.frame, 600), 0, 1e-9, "level past it")
	t.near(midline.at(e.frame, 700).z, 8, 1e-9, "at the kink's height")
	local b2, station2 = plain()
	grade(b2, 0.02, 380)
	local r2 = existing.analyse(station2, b2.snapshot(), { [1] = 1 }, R)
	t.ok(r2.ends[1] ~= nil, "a kink at 380: " .. tostring(r2.why[1]))
	t.near(r2.ends[1].origin.x, 180, 1e-6, "from the fan")
	t.near(midline.at(r2.ends[1].frame, 500).z, 4, 1e-9, "level at the kink's height past it")
end)

t.test("existing: tracks on different grades are not a double track", function()
	local b, station, L = plain()
	grade(b, 0.01)
	for __, p in ipairs(L) do
		p.p0.z, p.p1.z = 0, 0
		p.t0.z, p.t1.z = 0, 0
	end
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	t.eq(r.ends[1], nil, "1% apart")
end)

t.test("existing: a hump between level ends is read over, the frame rising and falling with it", function()
	local midline = t.requireTl("gui/pgrace_rail_router/planner/midline.tl")
	local b, station, L, Rt = plain()
	-- The 280–380 pieces rise and fall again: level ends, tangents 30% up and down.
	for __, p in ipairs({ L[2], Rt[2] }) do
		p.t0 = { x = 100, y = 0, z = 30 }
		p.t1 = { x = 100, y = 0, z = -30 }
	end
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	local e = r.ends[1]
	t.ok(e ~= nil, "usable: " .. tostring(r.why[1]))
	t.near(e.origin.x, 180, 1e-6, "from the fan")
	t.near(e.length, 820, 1e-6, "to the track's end")
	-- The hump's top, halfway along the piece: (h10(½) − h11(½)) × 30 = 7.5 m.
	t.near(midline.at(e.frame, 150).z, 7.5, 0.05, "over the hump")
	t.near(midline.at(e.frame, 300).z, 0, 1e-9, "level again")
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

t.test("existing: a station's outer tracks beyond 12 m widen the corridor", function()
	local b = builder()
	-- T P T T P T: tracks at ±2.5 and ±12.5, the outer ones merging into the inner ones at x = 200 (world 280).
	b.piece(80, 12.5, 180, 12.5)
	b.piece(180, 12.5, 280, 2.5)
	b.piece(80, -12.5, 180, -12.5)
	b.piece(180, -12.5, 280, -2.5)
	b.track(2.5, cat({ 80 }, steps(280, 1000, 100)))
	b.track(-2.5, cat({ 80 }, steps(280, 1000, 100)))
	local station = { entity = 1, centre = { x = 0, y = 0 }, dir = { x = 1, y = 0 }, half = 80,
		ends = { b.node(80, 12.5), b.node(80, 2.5), b.node(80, -2.5), b.node(80, -12.5) } }
	local r = existing.analyse(station, b.snapshot(), { [1] = 1 }, R)
	t.ok(r.ends[1] ~= nil, "usable: " .. tostring(r.why[1]))
	t.near(r.ends[1].origin.x, 280, 1e-9, "past the merge at frame x = 200")
	t.near(r.ends[1].length, 720, 1e-9, "to the track's end")
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

-- Bare ends (existing.bareEnd).

-- A 2-track station at (0, 0) facing +x, half 80, its own pieces between end nodes at y = ±2.5.
local function plainStation(b)
	b.piece(-80, 2.5, 80, 2.5)
	b.piece(-80, -2.5, 80, -2.5)
	return { entity = 1, centre = { x = 0, y = 0 }, dir = { x = 1, y = 0 }, half = 80,
		ends = { b.node(80, 2.5), b.node(80, -2.5), b.node(-80, 2.5), b.node(-80, -2.5) } }
end

t.test("existing: a station's free track ends are a bare end, its nodes left to right looking out", function()
	local b = builder()
	local station = plainStation(b)
	local snap = b.snapshot()
	for __, case in ipairs({ { 1, 2.5, 80 }, { -1, -2.5, -80 } }) do
		local k = case[1]
		local bare, why = existing.bareEnd(station, snap, k)
		t.eq(why, nil, "no why")
		t.eq(bare.kind, "direct", "kind")
		t.eq(#bare.nodes, 2, "two nodes")
		t.near(bare.nodes[1].y, case[2], 1e-9, "the left one first")
		t.eq(bare.nodes[1].entity, b.node(case[3], case[2]), "its entity")
		t.near(bare.mid.x, case[3], 1e-9, "mid x")
		t.near(bare.mid.y, 0, 1e-9, "mid y")
		t.near(bare.out.x, k, 1e-9, "outward")
	end
end)

t.test("existing: an end whose tracks lead on isn't bare; one with some leading on is mixed", function()
	local b = builder()
	local station = plainStation(b)
	b.piece(80, 2.5, 180, 2.5)
	b.piece(80, -2.5, 180, -2.5)
	b.piece(-80, 2.5, -180, 2.5)
	local snap = b.snapshot()
	local bare, why = existing.bareEnd(station, snap, 1)
	t.eq(bare, nil, "+x: not bare")
	t.eq(why, nil, "+x: no why")
	bare, why = existing.bareEnd(station, snap, -1)
	t.eq(bare, nil, "−x: not bare")
	t.eq(why, "mixed", "−x: mixed")
end)

t.test("existing: a bare end's kind follows its tracks' offsets, within 0.5 m", function()
	for __, case in ipairs({ { { 2.9, -2.4 }, "direct" }, { { 4.6, -5.3 }, "island" }, { { 2.5, -4 }, "other" },
			{ { 7.5, 2.5, -2.5, -7.5 }, "fan" }, { { 7.5, 2.5, -2.5 }, "other" }, { { 2.5 }, "other" } }) do
		local b = builder()
		local ends = {}
		for __, y in ipairs(case[1]) do
			b.piece(-80, y, 80, y)
			ends[#ends + 1] = b.node(80, y)
		end
		local station = { entity = 1, centre = { x = 0, y = 0 }, dir = { x = 1, y = 0 }, half = 80, ends = ends }
		local bare = existing.bareEnd(station, b.snapshot(), 1)
		t.eq(bare.kind, case[2], table.concat(case[1], ", "))
	end
end)

t.test("existing: a bare end whose tracks end 20 m apart along the axis is staggered (not joined)", function()
	local b = builder()
	b.piece(-80, 2.5, 80, 2.5)
	b.piece(-80, -2.5, 100, -2.5)
	local station = { entity = 1, centre = { x = 0, y = 0 }, dir = { x = 1, y = 0 }, half = 85,
		ends = { b.node(80, 2.5), b.node(100, -2.5), b.node(-80, 2.5), b.node(-80, -2.5) } }
	local snap = b.snapshot()
	t.eq(existing.bareEnd(station, snap, 1).kind, "staggered", "+x: staggered")
	t.eq(existing.bareEnd(station, snap, -1).kind, "direct", "−x: level, direct")
end)

t.test("existing: a bare end carries each node's own piece's direction there, outward", function()
	local b = builder()
	-- The tracks 0.5° off the axis.
	local rise = 160 * math.tan(math.rad(0.5))
	b.piece(-80, 2.5, 80, 2.5 + rise)
	b.piece(-80, -2.5, 80, -2.5 + rise)
	local station = { entity = 1, centre = { x = 0, y = rise / 2 }, dir = { x = 1, y = 0 }, half = 80,
		ends = { b.node(80, 2.5 + rise), b.node(80, -2.5 + rise), b.node(-80, 2.5), b.node(-80, -2.5) } }
	local snap = b.snapshot()
	local c, s = math.cos(math.rad(0.5)), math.sin(math.rad(0.5))
	for __, case in ipairs({ { 1, c, s }, { -1, -c, -s } }) do
		local bare = existing.bareEnd(station, snap, case[1])
		t.eq(bare.kind, "direct", "kind")
		for i = 1, 2 do
			t.near(bare.dirs[i].x, case[2], 1e-12, "end " .. case[1] .. " node " .. i .. " dir x")
			t.near(bare.dirs[i].y, case[3], 1e-12, "end " .. case[1] .. " node " .. i .. " dir y")
		end
	end
end)

t.test("existing: a usable end carries its frame, a line along the stretch", function()
	local midline = t.requireTl("gui/pgrace_rail_router/planner/midline.tl")
	local b, station = plain()
	local r = existing.analyse(station, b.snapshot(), { [1] = 1, [-1] = 1 }, R)
	local e = r.ends[1]
	t.ok(e ~= nil and e.frame ~= nil, "a frame")
	local p = midline.world(e.frame, 50, 0)
	t.near(p.x, e.origin.x + e.dir.x * 50, 1e-9, "x along the stretch") t.near(p.y, e.origin.y + e.dir.y * 50, 1e-9, "y")
	t.near(p.z, e.z + e.grade * 50, 1e-9, "z on its grade")
	t.near(e.frame.length, e.length, 1e-9, "as long as the stretch")
end)

-- The kit's maps folder, found as regression_test.lua does: RAIL_ROUTER_MAPS, ../maps beside the repo, or beside the
-- main checkout from a worktree (through git's common directory). nil when there is none.
local function findMapsDir()
	local env = os.getenv("RAIL_ROUTER_MAPS")
	if env ~= nil and env ~= "" then
		return env
	end
	local dir = t.root .. "/../maps"
	local f = io.open(dir .. "/README.md", "r")
	if f ~= nil then
		f:close()
		return dir
	end
	local p = io.popen('git -C "' .. t.root .. '" rev-parse --path-format=absolute --git-common-dir 2>/dev/null')
	local common = p and p:read("l")
	if p then
		p:close()
	end
	if common ~= nil and common:match("/%.git$") then
		dir = common:sub(1, -6) .. "/../maps"
		f = io.open(dir .. "/README.md", "r")
		if f ~= nil then
			f:close()
			return dir
		end
	end
	return nil
end

t.test("existing: line1 map: Aloha's ends read on past the crossovers and through the first curve", function()
	local midline = t.requireTl("gui/pgrace_rail_router/planner/midline.tl")
	local maps = findMapsDir()
	local mapFile = maps and (maps .. "/rail-router-test-5x14km-line1.map")
	local f = mapFile and io.open(mapFile, "r")
	if not f then
		print("SKIP existing line1: no rail-router-test-5x14km-line1.map (the kit's maps/ folder)")
		return
	end
	f:close()
	local lib = dofile(t.root .. "/tools/replaylib.lua")(t.root)
	local map = lib.maplib.load(mapFile)
	local st, snap = lib.existingFromMap(map, "Aloha")
	t.ok(st ~= nil, "a station")
	t.near(st.half, 160, 1, "320 m platforms")
	t.ok(#st.ends >= 4, "its track ends")
	t.ok(#snap.pieces > 50, "its track snapshot")
	local r = existing.analyse(st, snap, { [1] = 1, [-1] = 1 }, 150)
	-- Past the platforms' fans the tracks merge to two 255 m from the centre, then Halt 2+2's crossovers (switches at
	-- 289, 334, 337 and 382 m) cut them into stretches of 29 m and 3 m. Past the last switch the double track runs on
	-- through the line's first curve (about 390 m out) up to REACH.
	for __, k in ipairs({ 1, -1 }) do
		local e = r.ends[k]
		t.ok(e ~= nil, "end " .. k .. " usable: " .. tostring(r.why[k]))
		local along = (e.origin.x - st.centre.x) * st.dir.x * k + (e.origin.y - st.centre.y) * st.dir.y * k
		t.near(along, 382, 1, "end " .. k .. ": starts at the last crossover's switch")
		t.ok(e.length >= 600, "end " .. k .. ": at least 600 m")
		t.ok(midline.straightUntil(e.frame, 0, 0.005) < e.length, "end " .. k .. ": the frame turns (the curve)")
		t.ok(r.stretches[k][1] == e, "end " .. k .. ": the first stretch")
	end
end)

t.test("existing: stationFromEnds: two groups of ends give the centre, direction and half-length", function()
	local ends = {
		{ x = -100, y = -2.5, z = 0, entity = 1 }, { x = -100, y = 2.5, z = 0, entity = 2 },
		{ x = 100, y = -2.5, z = 0, entity = 3 }, { x = 100, y = 2.5, z = 0, entity = 4 },
	}
	local st = existing.stationFromEnds(7, ends)
	t.eq(st.entity, 7, "entity")
	t.near(st.half, 100, 1e-6, "half")
	t.near(math.abs(st.dir.x), 1, 1e-6, "dir along x")
	t.near(st.centre.x, 0, 1e-6, "centre x")
	t.eq(#st.ends, 4, "ends")
	local none, why = existing.stationFromEnds(7, { ends[1] })
	t.ok(none == nil and why ~= nil, "fewer than two ends")
end)

t.test("existing: planOnMap with Aloha's station: it joins the station", function()
	local maps = findMapsDir()
	local mapFile = maps and (maps .. "/rail-router-test-5x14km-line1.map")
	local f = mapFile and io.open(mapFile, "r")
	if not f then
		print("SKIP existing planOnMap: no rail-router-test-5x14km-line1.map (the kit's maps/ folder)")
		return
	end
	f:close()
	local lib = dofile(t.root .. "/tools/replaylib.lua")(t.root)
	local map = lib.maplib.load(mapFile)
	local r = lib.planOnMap(map, { from = "Aloha", to = "Mercer Island", stops = {}, existing = { "Aloha" } })
	t.ok(r.plan.ok, "the plan is made")
	-- Its ends now read through the first curve (milestone 4c), so the station is joined rather than replaced. (Where
	-- on the stretch the junction goes is the planner's: on its straight part, from 4c's Task 5.)
	for __, note in ipairs(r.plan.notes) do
		t.ok(not note:find("Aloha", 1, true), "no note about Aloha's station: " .. note)
	end
	t.ok(r.plan.stations[1].existing ~= nil, "Aloha's station is the existing one")
	t.ok(not pcall(lib.planOnMap, map, { from = "Aloha", to = "Mercer Island", stops = {}, existing = { "Antelope" } }),
		"an existing town that isn't a stop is an error")
end)
