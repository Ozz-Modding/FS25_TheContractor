-- A combine with crop in its tank (TheContractorAllocation.getFilledHarvester)
-- can't be allocated: a different crop stops the AI Helper, and the job's
-- own crop is the farm's to sell. So a hired worker's harvest job empties
-- the last part-load on its way out (TCHaulage.emptyHarvestersAfterJob).

local function setup()
    local world = stubs.install()
    world:addFillType("WHEAT", "Wheat")
    world:addFillType("OAT", "Oat")

    TCJobProgress = { POLL_INTERVAL_MS = 3000 }
    TheContractorWorker = { MAX_SKILL = 10 }
    TheContractorJobGeneration = { JOB_TYPES = { harvest = { cropDependent = true }, plow = {} } }
    world:load("src/business/Allocation.lua")
    world:load("src/util/TCHaulage.lua")

    world.cartingLoads = 0
    TCJobFuel = {
        burnCartingFuel = function()
            world.cartingLoads = world.cartingLoads + 1
        end,
    }
    g_fruitTypeManager = {
        getFillTypeIndexByFruitTypeIndex = function(_, fruitTypeIndex)
            return fruitTypeIndex
        end,
    }
    g_fieldManager = {
        getFieldById = function()
            return {
                getFarmland = function()
                    return { id = 1 }
                end,
            }
        end,
    }
    return world
end

local function addCombine(world, level, fillType, capacity)
    local combine = world:addVehicle({
        name = "Combine",
        fillUnits = { { capacity = capacity or 10000, level = level, fillType = fillType } },
    })
    combine.spec_combine = { fillUnitIndex = 1 }
    return combine
end

local function harvestJob(combine, workerId)
    return {
        id = 1,
        jobType = "harvest",
        fieldId = 1,
        assignedWorkerId = workerId,
        assignedEquipmentIds = { combine.id },
        getFruitTypeIndex = function()
            return FillType.WHEAT
        end,
    }
end

test("an empty combine can be allocated", function()
    local world = setup()
    local combine = addCombine(world, 0, FillType.WHEAT)
    assertEquals(TheContractorAllocation.getFilledHarvester({ combine.id }), nil)
end)

test("a combine holding another crop can't", function()
    local world = setup()
    local combine = addCombine(world, 500, FillType.OAT)
    local vehicle, fillType = TheContractorAllocation.getFilledHarvester({ combine.id })
    assertEquals(vehicle, combine)
    assertEquals(fillType, FillType.OAT)
end)

test("nor can one holding the job's own crop: it's the farm's to sell", function()
    local world = setup()
    local combine = addCombine(world, 500, FillType.WHEAT)
    assertEquals(TheContractorAllocation.getFilledHarvester({ combine.id }), combine)
end)

test("a forage harvester has no tank to check", function()
    local world = setup()
    local chopper = addCombine(world, 500, FillType.WHEAT, math.huge)
    assertEquals(TheContractorAllocation.getFilledHarvester({ chopper.id }), nil)
end)

test("a hired worker's harvest job empties the combine at the end, however little is left", function()
    local world = setup()
    local combine = addCombine(world, 500, FillType.WHEAT)
    TCHaulage.emptyHarvestersAfterJob(harvestJob(combine, 7))
    assertEquals(combine:getFillUnitFillLevel(1), 0)
    assertEquals(TheContractorAllocation.getFilledHarvester({ combine.id }), nil, "free to go out again")
end)

test("a player-driven job's combine is left for the player", function()
    local world = setup()
    local combine = addCombine(world, 500, FillType.WHEAT)
    TCHaulage.emptyHarvestersAfterJob(harvestJob(combine, nil))
    assertEquals(combine:getFillUnitFillLevel(1), 500)
end)

test("crop that isn't the job's isn't touched", function()
    local world = setup()
    local combine = addCombine(world, 500, FillType.OAT)
    TCHaulage.emptyHarvestersAfterJob(harvestJob(combine, 7))
    assertEquals(combine:getFillUnitFillLevel(1), 500)
end)

test("the last load is carted by the hauler, burning its diesel", function()
    local world = setup()
    local combine = addCombine(world, 500, FillType.WHEAT)
    local job = harvestJob(combine, 7)
    job.haulerWorkerId = 8
    TCHaulage.emptyHarvestersAfterJob(job)
    assertEquals(world.cartingLoads, 1)
end)
