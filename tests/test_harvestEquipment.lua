-- TCEquipmentClass.canHarvestFruit: a combine with no cutter of its own
-- harvests what its tank takes (the header's output, the crop's fill type
-- or a converter's), so a grain combine counts for wheat and maize but not
-- cotton; one with its own cutter harvests what that cutter cuts.

local WHEAT, MAIZE, COTTON, POTATO = 1, 2, 3, 4
local FILL_WHEAT, FILL_MAIZE, FILL_COTTON, FILL_POTATO, FILL_CHAFF = 11, 12, 13, 14, 15

local function setup()
    local world = stubs.install()
    TheContractorNegotiation = {
        rollInitialEagerness = function()
            return 1
        end,
    }
    world:load("src/business/Job.lua")
    world:load("src/business/JobGeneration.lua")
    world:load("src/util/TCEquipmentClass.lua")
    local fillTypes = { [WHEAT] = FILL_WHEAT, [MAIZE] = FILL_MAIZE, [COTTON] = FILL_COTTON, [POTATO] = FILL_POTATO }
    g_fruitTypeManager = {
        fruitTypeConverters = { { [MAIZE] = { fillTypeIndex = FILL_CHAFF, conversionFactor = 1 } } },
        getFillTypeIndexByFruitTypeIndex = function(_, fruitTypeIndex)
            return fillTypes[fruitTypeIndex]
        end,
    }
    return world
end

local function harvestDef()
    return TheContractorJobGeneration.JOB_TYPES.harvest
end

local function combine(tankFillTypes, cutterFruits)
    local supported = {}
    for _, fillType in ipairs(tankFillTypes) do
        supported[fillType] = true
    end
    local vehicle = {
        spec_combine = { fillUnitIndex = 1 },
        spec_motorized = {},
        getFillUnitSupportsFillType = function(_, index, fillType)
            return index == 1 and supported[fillType] == true
        end,
    }
    if cutterFruits ~= nil then
        vehicle.spec_cutter = { fruitTypeIndices = cutterFruits }
    end
    return vehicle
end

local function header(fruits)
    return { spec_cutter = { fruitTypeIndices = fruits } }
end

local function contains(list, key)
    for _, value in ipairs(list) do
        if value == key then
            return true
        end
    end
    return false
end

test("a grain combine harvests grain and maize but not cotton", function()
    setup()
    local grainCombine = combine({ FILL_WHEAT, FILL_MAIZE })
    assertTrue(TCEquipmentClass.canHarvestFruit(grainCombine, WHEAT), "wheat")
    assertTrue(TCEquipmentClass.canHarvestFruit(grainCombine, MAIZE), "maize")
    assertTrue(not TCEquipmentClass.canHarvestFruit(grainCombine, COTTON), "cotton")
    assertEquals(TCEquipmentClass.getJobRole(grainCombine, harvestDef(), WHEAT), "harvester")
    assertEquals(TCEquipmentClass.getJobRole(grainCombine, harvestDef(), COTTON), nil)
end)

test("a cotton job with only a grain combine is missing its harvester", function()
    setup()
    local missing = TCEquipmentClass.getMissingEquipment({ combine({ FILL_WHEAT }) }, harvestDef(), COTTON)
    assertTrue(contains(missing, "harvester"), "harvester missing")
    assertTrue(contains(missing, "cutter"), "cutter missing")
end)

test("a forage harvester takes maize through a converter's chaff", function()
    setup()
    local forageHarvester = combine({ FILL_CHAFF })
    assertTrue(TCEquipmentClass.canHarvestFruit(forageHarvester, MAIZE), "maize as chaff")
    assertTrue(not TCEquipmentClass.canHarvestFruit(forageHarvester, POTATO), "potato")
end)

test("a harvester with its own cutter harvests what the cutter cuts", function()
    setup()
    local cottonHarvester = combine({ FILL_COTTON }, { COTTON })
    assertTrue(TCEquipmentClass.canHarvestFruit(cottonHarvester, COTTON), "cotton")
    assertTrue(not TCEquipmentClass.canHarvestFruit(cottonHarvester, WHEAT), "wheat")
    assertEquals(#TCEquipmentClass.getMissingEquipment({ cottonHarvester }, harvestDef(), COTTON), 0)
end)

test("a grain combine and grain header cover a wheat job", function()
    setup()
    local missing = TCEquipmentClass.getMissingEquipment({ combine({ FILL_WHEAT }), header({ WHEAT }) }, harvestDef(),
        WHEAT)
    assertTrue(not contains(missing, "harvester"), "harvester there")
    assertTrue(not contains(missing, "cutter"), "cutter there")
end)

test("a combine whose tank can't be read still counts", function()
    setup()
    local unknown = { spec_combine = {} }
    assertTrue(TCEquipmentClass.canHarvestFruit(unknown, COTTON), "unknown tank")
    assertTrue(TCEquipmentClass.canHarvestFruit(combine({ FILL_WHEAT }), nil), "any crop")
end)
