local t = ...
local arrows = t.requireTl("gui/pgrace_rail_router/planner/arrows.tl")

-- A straight leg along x with samples at the given distances, and spans {kind, s0, s1}.
local function leg(ss, spans)
	local samples = {}
	for i, s in ipairs(ss) do
		samples[i] = { p = { x = s, y = 0 }, s = s }
	end
	local list = {}
	for i, sp in ipairs(spans or {}) do
		list[i] = { kind = sp[1], s0 = sp[2], s1 = sp[3] }
	end
	if #list == 0 then
		list[1] = { kind = "ground", s0 = 0, s1 = ss[#ss] }
	end
	return { samples = samples, spans = list }
end

local function range(from, to, step)
	local out = {}
	for s = from, to + 1e-9, step do
		table.insert(out, s)
	end
	return out
end

local function lengths(leg, list)
	local out = {}
	for i, a in ipairs(list) do
		out[i] = leg.samples[a.j].s - leg.samples[a.i].s
	end
	return out
end

-- Every arrow at least `min` long, and together they cover the leg once, in order.
local function covers(leg, list, min)
	t.ok(#list > 0, "some arrows")
	t.eq(list[1].i, 1, "first arrow starts the leg")
	t.eq(list[#list].j, #leg.samples, "last arrow ends it")
	for k, a in ipairs(list) do
		if k > 1 then
			t.eq(a.i, list[k - 1].j, "arrows join")
		end
		t.ok(a.j > a.i, "arrow runs forward")
		local p, q = leg.samples[a.i].p, leg.samples[a.j].p
		t.ok(math.sqrt((q.x - p.x) ^ 2 + (q.y - p.y) ^ 2) >= min - 1e-9, "arrow " .. k .. " at least " .. min .. " m")
	end
end

t.test("arrows: a plain leg is cut into chords of about 100 m, with a short tail taken into the last", function()
	local ss = range(0, 1000, 25)
	table.insert(ss, 1010)
	local l = leg(ss)
	local list = arrows.split(l, 100, 25)
	covers(l, list, 25)
	local len = lengths(l, list)
	for k = 1, #len - 1 do
		t.eq(len[k], 100, "chord " .. k)
	end
	t.eq(len[#len], 110, "the 10 m tail joins the last chord")
end)

t.test("arrows: a bridge gets arrows of its own colour, ending where it ends", function()
	local l = leg(range(0, 500, 25), { { "ground", 0, 200 }, { "bridge", 200, 300 }, { "ground", 300, 500 } })
	local list = arrows.split(l, 100, 25)
	covers(l, list, 25)
	local kinds = {}
	for __, a in ipairs(list) do
		table.insert(kinds, a.kind .. "@" .. l.samples[a.i].s)
	end
	t.eq(table.concat(kinds, " "), "ground@0 ground@100 bridge@200 ground@300 ground@400", "kinds")
end)

-- The crash on NewGame2 (Fastest, leg 3): a bridge 7 m long between two samples 7 m apart gave a 7 m arrow, and
-- the game's arrow drawing asserts on it ("AddEveryNthPoint: (num)>=(2)").
t.test("arrows: a stub shorter than the minimum runs on into the next samples, keeping its colour", function()
	local ss = { 0, 25, 50, 75, 100, 107, 132, 157, 182, 207 }
	local l = leg(ss, { { "ground", 0, 100 }, { "bridge", 100, 107 }, { "ground", 107, 207 } })
	local list = arrows.split(l, 100, 25)
	covers(l, list, 25)
	t.eq(list[2].kind, "bridge", "the bridge still shows")
	t.eq(l.samples[list[2].j].s, 132, "it runs on to the next sample")
end)

t.test("arrows: a short last arrow of another kind joins the one before it, the bridge colour winning", function()
	local l = leg({ 0, 25, 50, 75, 100, 110 }, { { "ground", 0, 100 }, { "bridge", 100, 110 } })
	local list = arrows.split(l, 100, 25)
	covers(l, list, 25)
	t.eq(#list, 1, "one arrow")
	t.eq(list[1].kind, "bridge", "kind")
end)

t.test("arrows: a leg shorter than the minimum draws nothing", function()
	local l = leg({ 0, 5, 10 })
	t.eq(#arrows.split(l, 100, 25), 0, "no arrows")
end)

t.test("arrows: duplicate samples never make a zero-length arrow", function()
	local l = leg({ 0, 25, 50, 50, 50, 75, 100, 125 }, { { "ground", 0, 50 }, { "tunnel", 50, 50.0001 },
		{ "ground", 50.0001, 125 } })
	covers(l, arrows.split(l, 100, 25), 25)
end)
