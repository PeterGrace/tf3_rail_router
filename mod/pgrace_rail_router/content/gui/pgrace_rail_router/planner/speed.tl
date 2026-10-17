local speed : PgraceRailRouterSpeed = {}

local type Limit = PgraceRailRouterSpeed.Limit
local type Weights = PgraceRailRouterModes.Weights
local type Piece = PgraceRailRouterSmooth.Piece

-- The train: accelerates at TRAIN_ACCEL (m/s²) from a standstill, and once its power runs short at
-- TRAIN_POWER / v (W/kg ÷ m/s): an ICE 1 (two 4,790 kW power cars, 200 kN of tractive effort each, about 800 t)
-- has 0.5 m/s² and 12 W/kg. It brakes at TRAIN_BRAKE (m/s²; the ICE 1's data says 2.5, but a starting value to
-- tune in-game). Such a train takes about 13 km to reach 77 m/s, so on legs of a few kilometres it never does, and
-- a curve near a station costs little: it is slow there anyway.
local TRAIN_ACCEL = 0.5
local TRAIN_POWER = 12.0
local TRAIN_BRAKE = 1.0
-- The run is worked out every STEP metres (or a little less, to fit the length).
local STEP = 10.0

function speed.curveSpeed(radius : number, w : Weights) : number
	return math.min(w.topSpeed, math.sqrt(w.lateralAccel * radius))
end

function speed.runTime(length : number, limits : {Limit}, top : number) : number
	if length <= 0 then
		return 0
	end
	local n = math.max(1, math.ceil(length / STEP))
	local ds = length / n
	local cap : {number} = {}
	for k = 0, n do
		cap[k] = top
	end
	for __, l in ipairs(limits) do
		local k0 = math.max(0, math.floor(l.s0 / ds))
		local k1 = math.min(n, math.ceil(l.s1 / ds))
		for k = k0, k1 do
			if l.v < cap[k] then
				cap[k] = l.v
			end
		end
	end
	local v : {number} = { [0] = 0 }
	for k = 1, n do
		local prev = v[k - 1]
		local a = math.min(TRAIN_ACCEL, TRAIN_POWER / math.max(prev, 1))
		v[k] = math.min(cap[k], math.sqrt(prev * prev + 2 * a * ds))
	end
	v[n] = 0
	for k = n - 1, 0, -1 do
		local next = v[k + 1]
		v[k] = math.min(v[k], math.sqrt(next * next + 2 * TRAIN_BRAKE * ds))
	end
	local time = 0.0
	for k = 1, n do
		-- Both ends of a step are never at a standstill together (the step is at most `STEP` long).
		time = time + 2 * ds / math.max(v[k - 1] + v[k], 1e-6)
	end
	return time
end

function speed.timeLost(length : number, limits : {Limit}, top : number) : number
	if #limits == 0 then
		return 0
	end
	return math.max(0, speed.runTime(length, limits, top) - speed.runTime(length, {}, top))
end

function speed.pieceLimits(pieces : {Piece}, lead : number, w : Weights) : {Limit}, number
	local limits : {Limit} = {}
	local s = lead
	for __, piece in ipairs(pieces) do
		if piece.kind == "arc" and piece.radius < w.minRadius - 1e-6 then
			table.insert(limits, { s0 = s, s1 = s + piece.length, v = speed.curveSpeed(piece.radius, w) })
		end
		s = s + piece.length
	end
	return limits, s - lead
end

return speed
