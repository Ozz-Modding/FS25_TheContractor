-- Bin bag squash (147): how the drawn bag squashes as it lands, settles
-- back, hangs stretched in the hands with its neck held, swings behind a
-- move while carried, and keeps its volume. TCBinBagSquash is pure, so
-- it's stepped directly.

local NECK = 0.6

local function load()
    stubs.install()
    dofile("src/util/TCBinBagSquash.lua")
end

-- Steps a state for seconds at a frame rate, with a velocity change of
-- (dvx, dvy, dvz) in the first frame only. Returns the largest squash seen.
local function run(state, seconds, fps, dvx, dvy, dvz, isHeld)
    local dt = 1 / fps
    local peak = state.s
    for i = 1, math.floor(seconds * fps + 0.5) do
        if i == 1 then
            TCBinBagSquash.step(state, dt, dvx or 0, dvy or 0, dvz or 0, isHeld)
        else
            TCBinBagSquash.step(state, dt, 0, 0, 0, isHeld)
        end
        peak = math.max(peak, state.s)
    end
    return peak
end

test("a bag at rest stays the plain bag", function()
    load()
    local state = TCBinBagSquash.new()
    run(state, 2, 60)
    assertTrue(TCBinBagSquash.isSettled(state))
    local sides, height, y, tiltX, tiltZ = TCBinBagSquash.getPose(state, NECK)
    assertNear(sides, 1, 1e-9)
    assertNear(height, 1, 1e-9)
    assertNear(y, -NECK, 1e-9, "its bottom where the model's is")
    assertEquals(tiltX, 0)
    assertEquals(tiltZ, 0)
end)

test("landing squashes it, keeping its volume, and it settles back", function()
    load()
    local state = TCBinBagSquash.new()
    -- Stopped by the ground from 3 m/s down.
    local peak = run(state, 0.15, 60, 0, 3, 0, false)
    assertTrue(peak > 0.1, "squashed")
    local sides, height, y = TCBinBagSquash.getPose(state, NECK)
    assertTrue(height < 1 and sides > 1, "shorter and wider")
    assertNear(sides * sides * height, 1, 1e-9, "same volume")
    assertNear(y, -NECK, 1e-9, "still on its bottom")

    run(state, 3, 60)
    assertTrue(TCBinBagSquash.isSettled(state), "settled")
end)

test("a harder landing squashes it more, up to a limit", function()
    load()
    local soft, hard, huge = TCBinBagSquash.new(), TCBinBagSquash.new(), TCBinBagSquash.new()
    local softPeak = run(soft, 0.3, 60, 0, 1, 0, false)
    local hardPeak = run(hard, 0.3, 60, 0, 3, 0, false)
    local hugePeak = run(huge, 0.3, 60, 0, 50, 0, false)
    assertTrue(hardPeak > softPeak)
    assertTrue(hugePeak >= hardPeak)
    local _, height = TCBinBagSquash.getPose(huge, NECK)
    assertTrue(height > 0.5, "never flattened")
end)

test("much the same at any frame rate", function()
    load()
    local slow, fast = TCBinBagSquash.new(), TCBinBagSquash.new()
    local slowPeak = run(slow, 0.3, 30, 0, 3, 0, false)
    local fastPeak = run(fast, 0.3, 144, 0, 3, 0, false)
    assertNear(slowPeak, fastPeak, fastPeak * 0.15)
end)

test("in the hands it hangs stretched from its neck, and goes back when let go", function()
    load()
    local state = TCBinBagSquash.new()
    run(state, 2, 60, 0, 0, 0, true)
    local sides, height, y = TCBinBagSquash.getPose(state, NECK)
    assertTrue(height > 1 and sides < 1, "taller and thinner")
    -- The neck's height above the squash node, scaled, lands back on the
    -- hang node (the neck): the hands hold it there.
    assertNear(y + NECK * height, 0, 1e-9, "the neck stays in the hands")
    assertTrue(not TCBinBagSquash.isSettled(state))

    run(state, 3, 60, 0, 0, 0, false)
    assertTrue(TCBinBagSquash.isSettled(state), "back to the plain bag")
    local _, _, restY = TCBinBagSquash.getPose(state, NECK)
    assertNear(restY, -NECK, 1e-9)
end)

test("carried, it swings behind a move; on the ground it doesn't swing", function()
    load()
    local held = TCBinBagSquash.new()
    run(held, 1, 60, 0, 0, 0, true)
    -- Moved off to +x and +z.
    run(held, 0.1, 60, 2, 0, 2, true)
    assertTrue(held.tiltZ < 0, "the bottom lags towards -x")
    assertTrue(held.tiltX > 0, "and towards -z")
    run(held, 5, 60, 0, 0, 0, true)
    assertNear(held.tiltX, 0, 0.01, "swung back")
    assertNear(held.tiltZ, 0, 0.01)

    local ground = TCBinBagSquash.new()
    run(ground, 0.1, 60, 2, 0, 2, false)
    assertEquals(ground.tiltX, 0)
    assertEquals(ground.tiltZ, 0)
end)
