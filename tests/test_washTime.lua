-- Return and wash time (023, 045): the dirtiest vehicle washes at the full
-- rate, the rest add a little each, and the wash is capped, so a big rig
-- doesn't keep the crew out for an hour and a half.

local function setup()
    local world = stubs.install()
    world:load("src/util/TCJobConsequences.lua")
    return world
end

test("one fully dirty vehicle takes 40 minutes for the untidiest, 15 for the tidiest", function()
    setup()
    assertNear(TCJobConsequences.getWashMinutes(1, 1, 0), 30, 0.001, "capped")
    assertNear(TCJobConsequences.getWashMinutes(1, 1, 1), 15, 0.001)
    assertNear(TCJobConsequences.getWashMinutes(0.5, 0.5, 1), 7.5, 0.001)
end)

test("other vehicles add a few minutes each, not a full wash", function()
    setup()
    -- Tidiest worker, tractor and two implements all fully dirty.
    assertNear(TCJobConsequences.getWashMinutes(1, 3, 1), 25, 0.001)
end)

test("a big dirty rig is capped", function()
    setup()
    assertNear(TCJobConsequences.getWashMinutes(1, 4, 0.5), TCJobConsequences.WASH_CAP_MINUTES, 0.001)
end)
