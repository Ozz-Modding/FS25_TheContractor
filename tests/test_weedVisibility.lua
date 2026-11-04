-- A weed/hoe job's field is laid out with weeds the player can see: an
-- invisible (just-germinated) start state is raised to the first visible
-- one the job's tool still clears to nothing.

-- The base game's maps_weed.xml: map colours (the visible states) from 3,
-- the tine weeder clears 1-3, the hoe 1-4 and 6.
local function baseGameWeedSystem()
    local mapColor = {
        { states = { 3 } }, { states = { 4 } }, { states = { 5 } }, { states = { 6 } }, { states = { 7, 8, 9 } },
    }
    local weeder = { weed = { replacements = { [1] = 0, [2] = 0, [3] = 0, [4] = 6 } } }
    local hoe = { weed = { replacements = { [1] = 0, [2] = 0, [3] = 0, [4] = 0, [6] = 0 } } }
    return {
        getColors = function()
            return mapColor, mapColor
        end,
        getWeederReplacements = function(_, isHoe)
            return isHoe and hoe or weeder
        end,
    }
end

local function setup()
    local world = stubs.install()
    FieldGroundType = {}
    world:load("src/util/TCFieldPreparation.lua")
end

test("an invisible weed state becomes the first visible one a tine weeder clears", function()
    setup()
    local weedSystem = baseGameWeedSystem()
    assertEquals(3, TCFieldPreparation.getVisibleWeedState(weedSystem, 1, false))
    assertEquals(3, TCFieldPreparation.getVisibleWeedState(weedSystem, 2, false))
end)

test("an invisible weed state becomes the first visible one at or above it a hoe clears", function()
    setup()
    local weedSystem = baseGameWeedSystem()
    assertEquals(3, TCFieldPreparation.getVisibleWeedState(weedSystem, 1, true))
    assertEquals(3, TCFieldPreparation.getVisibleWeedState(weedSystem, 2, true))
end)

test("a visible weed state is kept", function()
    setup()
    local weedSystem = baseGameWeedSystem()
    assertEquals(3, TCFieldPreparation.getVisibleWeedState(weedSystem, 3, false))
    assertEquals(4, TCFieldPreparation.getVisibleWeedState(weedSystem, 4, true))
end)

test("no visible state the tool clears leaves the field's own", function()
    setup()
    local weedSystem = baseGameWeedSystem()
    weedSystem.getWeederReplacements = function()
        return { weed = { replacements = { [1] = 0, [2] = 0 } } }
    end
    assertEquals(nil, TCFieldPreparation.getVisibleWeedState(weedSystem, 1, false))
end)
