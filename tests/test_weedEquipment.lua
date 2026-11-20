-- Which weeders do a weed or hoe job (TCEquipmentClass.canWeed). The job's
-- own kind always does; a hoe also does a weed job, since it kills every
-- weed a tine weeder does, but only while the crop is at a stage a hoe may
-- work. A tine weeder never does a hoe job: it leaves the bigger weeds.

local WHEAT, SUGARBEET = 1, 2

-- The base game's maps_weed.xml: the tine weeder clears 1-3 (4 to 6), the
-- hoe 1-4 and 6.
local function baseGameWeedSystem()
    local weeder = { weed = { replacements = { [1] = 0, [2] = 0, [3] = 0, [4] = 6 } } }
    local hoe = { weed = { replacements = { [1] = 0, [2] = 0, [3] = 0, [4] = 0, [6] = 0 } } }
    return {
        getWeederReplacements = function(_, isHoe)
            return isHoe and hoe or weeder
        end,
    }
end

local function setup()
    local world = stubs.install()
    TheContractorNegotiation = {
        rollInitialEagerness = function()
            return 1
        end,
    }
    FruitType = FruitType or {}
    FruitType.UNKNOWN = 0
    -- Base game stages: wheat weeds to 5, hoes to 3; sugar beet weeds to 3,
    -- hoes to 5.
    local fruitTypes = {
        [WHEAT] = { maxWeederState = 5, maxWeederHoeState = 3, cutState = 10 },
        [SUGARBEET] = { maxWeederState = 3, maxWeederHoeState = 5, cutState = 9 },
    }
    g_fruitTypeManager = {
        getFruitTypeByIndex = function(_, index)
            return fruitTypes[index]
        end,
    }
    g_currentMission.weedSystem = baseGameWeedSystem()
    world:load("src/business/Job.lua")
    world:load("src/business/JobGeneration.lua")
    world:load("src/util/TCEquipmentClass.lua")
    return world
end

local function jobDef(jobType)
    return TheContractorJobGeneration.JOB_TYPES[jobType]
end

local tineWeeder = { spec_weeder = { isHoeWeeder = false } }
local hoe = { spec_weeder = { isHoeWeeder = true } }

test("each kind does its own job", function()
    setup()
    assertTrue(TCEquipmentClass.isJobImplement(tineWeeder, jobDef("weed")), "tine weeder, weed job")
    assertTrue(TCEquipmentClass.isJobImplement(hoe, jobDef("hoe")), "hoe, hoe job")
end)

test("a hoe does a weed job", function()
    setup()
    assertTrue(TCEquipmentClass.isJobImplement(hoe, jobDef("weed")), "crop not known")
    assertTrue(TCEquipmentClass.isJobImplement(hoe, jobDef("weed"), nil,
        { fruitTypeIndex = WHEAT, growthState = 3 }), "wheat at a hoeable stage")
    -- Only the tractor to pull it is missing.
    assertTrue(TCEquipmentClass.getMissingEquipment({ hoe }, jobDef("weed"))[1] ~= "implement", "hoe counted")
end)

test("a hoe doesn't do a weed job once the crop is past hoeing", function()
    setup()
    local crop = { fruitTypeIndex = WHEAT, growthState = 4 }
    assertTrue(not TCEquipmentClass.isJobImplement(hoe, jobDef("weed"), nil, crop), "wheat past hoeing")
    assertTrue(TCEquipmentClass.isJobImplement(tineWeeder, jobDef("weed"), nil, crop), "tine weeder still does")
    assertEquals(TCEquipmentClass.getMissingEquipment({ hoe }, jobDef("weed"), nil, crop)[1], "implement")
end)

test("a hoe does a weed job on a cut crop", function()
    setup()
    assertTrue(TCEquipmentClass.isJobImplement(hoe, jobDef("weed"), nil,
        { fruitTypeIndex = WHEAT, growthState = 10 }), "cut wheat")
end)

test("a tine weeder never does a hoe job", function()
    setup()
    assertTrue(not TCEquipmentClass.isJobImplement(tineWeeder, jobDef("hoe")), "crop not known")
    assertTrue(not TCEquipmentClass.isJobImplement(tineWeeder, jobDef("hoe"), nil,
        { fruitTypeIndex = SUGARBEET, growthState = 1 }), "young sugar beet")
end)

test("a hoe isn't taken for a weed job when the hoe kills fewer weeds", function()
    setup()
    g_currentMission.weedSystem.getWeederReplacements = function(_, isHoe)
        if isHoe then
            return { weed = { replacements = { [1] = 0, [2] = 0 } } }
        end
        return { weed = { replacements = { [1] = 0, [2] = 0, [3] = 0 } } }
    end
    assertTrue(not TCEquipmentClass.isJobImplement(hoe, jobDef("weed")), "hoe leaves state 3")
end)
