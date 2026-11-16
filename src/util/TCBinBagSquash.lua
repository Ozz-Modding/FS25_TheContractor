-- Bin bag squash (147): how a fly-tipped bin bag (a TCDebris prop) squashes,
-- stretches and swings, worked out from how it moves. Only the drawn bag
-- changes: its collision is the i3d's fixed shell. Each machine that draws
-- the bag works this out for itself from the bag's position frame by frame
-- (TCDebris.updateSquash), so nothing is synced or saved.
--
-- Two springs, both driven by the bag's change in velocity in its own frame:
--   - squash s (up is squashed: shorter and wider; down is stretched),
--     kicked by a change upwards (landing squashes it, falling stretches it
--     a little). Held in a player's hands it settles stretched
--     (HELD_STRETCH), hanging from its neck. Volume is kept: the sides go in
--     as it gets taller.
--   - a swing about the neck (tiltX, tiltZ), kicked by a change sideways so
--     the bag lags behind a move and swings back. Only while it's held: on
--     the ground the swing just settles.
-- The pose (getPose) is for the i3d's two nodes (dev/tools/genBinBagI3d.py):
-- `hang` at the neck takes the swing, `squash` below it the scale, moved so
-- the bottom stays put on the ground and the neck stays put in the hands.
--
-- Pure: no engine calls, so tests can step it.

TCBinBagSquash = {}

-- The squash spring, per second squared, and its damping, per second.
TCBinBagSquash.STIFFNESS = 140
TCBinBagSquash.DAMPING = 7
-- Squash speed (per second) for each m/s the bag's velocity changes along
-- its up axis. Landing at 3 m/s squashes it by about a quarter.
TCBinBagSquash.IMPULSE = 0.9
-- How far it can squash (shorter) and stretch (taller), as shares of its
-- height.
TCBinBagSquash.MAX_SQUASH = 0.35
TCBinBagSquash.MAX_STRETCH = 0.25
-- Held, it hangs this much taller.
TCBinBagSquash.HELD_STRETCH = 0.12
-- How fast it goes over to hanging, or back, per second.
TCBinBagSquash.HELD_RATE = 4

-- The swing: a short pendulum (about once a second), lightly damped.
TCBinBagSquash.TILT_STIFFNESS = 40
TCBinBagSquash.TILT_DAMPING = 3
-- Swing speed (radians per second) for each m/s of sideways change.
TCBinBagSquash.TILT_IMPULSE = 0.9
TCBinBagSquash.MAX_TILT = 0.5

-- Below these the bag counts as still (nothing to redraw).
TCBinBagSquash.SETTLED = 0.0005

-- Integration steps no longer than this (seconds), so the springs stay
-- stable at a low frame rate.
TCBinBagSquash.MAX_STEP = 1 / 120

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

function TCBinBagSquash.new()
    return { s = 0, sv = 0, tiltX = 0, tiltXv = 0, tiltZ = 0, tiltZv = 0, held = 0 }
end

-- Advances the bag by dt seconds. (dvx, dvy, dvz) is how much its velocity
-- changed over that time, in its own frame (y up the bag); isHeld whether a
-- player has it in their hands.
function TCBinBagSquash.step(state, dt, dvx, dvy, dvz, isHeld)
    if dt <= 0 then
        return
    end
    local B = TCBinBagSquash
    -- The kicks: a change in velocity is a change in the springs' speed,
    -- whatever the frame rate.
    state.sv = state.sv + B.IMPULSE * dvy
    if state.held > 0 then
        local share = state.held
        -- Lagging behind: a move to +x swings the bottom to -x (about z),
        -- a move to +z swings it to -z (about x).
        state.tiltZv = state.tiltZv - B.TILT_IMPULSE * dvx * share
        state.tiltXv = state.tiltXv + B.TILT_IMPULSE * dvz * share
    end

    local heldTarget = isHeld and 1 or 0
    local remaining = dt
    while remaining > 1e-9 do
        local h = math.min(remaining, B.MAX_STEP)
        remaining = remaining - h
        if state.held < heldTarget then
            state.held = math.min(heldTarget, state.held + B.HELD_RATE * h)
        elseif state.held > heldTarget then
            state.held = math.max(heldTarget, state.held - B.HELD_RATE * h)
        end
        local target = -B.HELD_STRETCH * state.held
        state.sv = state.sv + (-B.STIFFNESS * (state.s - target) - B.DAMPING * state.sv) * h
        state.s = clamp(state.s + state.sv * h, -B.MAX_STRETCH, B.MAX_SQUASH)
        state.tiltXv = state.tiltXv + (-B.TILT_STIFFNESS * state.tiltX - B.TILT_DAMPING * state.tiltXv) * h
        state.tiltZv = state.tiltZv + (-B.TILT_STIFFNESS * state.tiltZ - B.TILT_DAMPING * state.tiltZv) * h
        state.tiltX = clamp(state.tiltX + state.tiltXv * h, -B.MAX_TILT, B.MAX_TILT)
        state.tiltZ = clamp(state.tiltZ + state.tiltZv * h, -B.MAX_TILT, B.MAX_TILT)
    end
end

-- Whether it's at rest: nothing moving and nothing to draw but the plain bag.
function TCBinBagSquash.isSettled(state)
    local e = TCBinBagSquash.SETTLED
    return state.held == 0 and math.abs(state.s) < e and math.abs(state.sv) < e
        and math.abs(state.tiltX) < e and math.abs(state.tiltXv) < e
        and math.abs(state.tiltZ) < e and math.abs(state.tiltZv) < e
end

-- The pose for the i3d's nodes, the neck `neck` metres up: the squash
-- node's scale (sides, height) and its y (the bottom stays on the ground,
-- or the neck in the hands, as it changes height), and the hang node's
-- swing (x, z radians).
function TCBinBagSquash.getPose(state, neck)
    local height = 1 - state.s
    local sides = 1 / math.sqrt(height)
    local y = -neck * (1 + (height - 1) * state.held)
    return sides, height, y, state.tiltX, state.tiltZ
end
