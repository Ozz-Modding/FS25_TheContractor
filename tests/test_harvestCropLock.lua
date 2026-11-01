-- A harvest job's crop is the customer's unless the player is delivering it
-- themselves (a player-driven haulage job). A player-driven harvest without
-- haulage used to let the player overload the crop into their own trailer
-- and keep it, and kept whatever was left in the combine. Now the combine
-- can't unload the job's crop while the job's under way, and is emptied
-- when it ends.

local fakes = dofile("tests/fakes.lua")

local function setup()
    local world = stubs.install()
    fakes.installContractor(world)

    table.hasElement = table.hasElement or function(list, value)
        for _, element in ipairs(list) do
            if element == value then
                return true
            end
        end
        return false
    end

    TheContractorJobGeneration.getFruitTypeIndexByName = function(name)
        return name == "WHEAT" and 1 or nil
    end
    g_fieldManager = {
        getFieldById = function()
            return { getFarmland = function() return { id = 1 } end }
        end,
    }
    g_fruitTypeManager = {
        getFillTypeIndexByFruitTypeIndex = function(_, fruitTypeIndex)
            return fruitTypeIndex == 1 and FillType.WHEAT or nil
        end,
    }

    -- Vanilla's own check says yes, and records that it was asked.
    world.vanillaAsked = 0
    Dischargeable = {
        getCanDischargeToObject = function()
            world.vanillaAsked = world.vanillaAsked + 1
            return true
        end,
    }
    world:load("src/util/TCHaulage.lua")
    return world
end

local function addCombine(world, capacity, level)
    local combine = world:addVehicle({
        name = "Combine",
        fillUnits = { { capacity = capacity or 10000, level = level or 0, fillType = FillType.WHEAT } },
    })
    combine.spec_combine = { fillUnitIndex = 1 }
    combine.getDischargeFillType = function(self)
        return self:getFillUnitFillType(1)
    end
    return combine
end

local function addHarvestJob(world, combine, def)
    def = def or {}
    local job = world:addJob({ jobType = "harvest", workerId = def.workerId, state = def.state,
        vehicles = { combine } })
    job.fruitTypeName = "WHEAT"
    job.includesHaulage = def.includesHaulage == true
    return job
end

local function canUnload(combine)
    return Dischargeable.getCanDischargeToObject(combine, {})
end

-- The unloading lock ------------------------------------------------------------

test("a player-driven harvest without haulage can't unload the job's crop", function()
    local world = setup()
    local combine = addCombine(world, 10000, 4000)
    addHarvestJob(world, combine)

    assertEquals(canUnload(combine), false)
    assertEquals(world.vanillaAsked, 1)
end)

test("a player-driven haulage job's combine can unload: that crop is theirs to deliver", function()
    local world = setup()
    local combine = addCombine(world, 10000, 4000)
    addHarvestJob(world, combine, { includesHaulage = true })

    assertEquals(canUnload(combine), true)
end)

test("a hired crew's combine can't unload the job's crop either", function()
    local world = setup()
    local combine = addCombine(world, 10000, 4000)
    addHarvestJob(world, combine, { workerId = 3, includesHaulage = true })

    assertEquals(canUnload(combine), false)
end)

test("the lock lifts once the job's over", function()
    local world = setup()
    local combine = addCombine(world, 10000, 4000)
    addHarvestJob(world, combine, { state = TheContractorJob.STATE.COMPLETED })

    assertEquals(canUnload(combine), true)
end)

test("a combine carrying another crop isn't locked", function()
    local world = setup()
    local combine = addCombine(world, 10000, 4000)
    combine.fillUnits[1].fillType = FillType.POTATO
    addHarvestJob(world, combine)

    assertEquals(canUnload(combine), true)
end)

test("a combine on no job isn't locked", function()
    local world = setup()
    local combine = addCombine(world, 10000, 4000)
    local other = addCombine(world, 10000, 0)
    addHarvestJob(world, other)

    assertEquals(canUnload(combine), true)
end)

test("a buffer combine (forage harvester) isn't locked: it can't harvest without unloading", function()
    local world = setup()
    local combine = addCombine(world, math.huge, 0)
    combine.fillUnits[1].level = 100
    addHarvestJob(world, combine)

    assertEquals(canUnload(combine), true)
end)

test("vanilla's no stands", function()
    local world = setup()
    local combine = addCombine(world, 10000, 4000)
    Dischargeable.getCanDischargeToObject = Utils.overwrittenFunction(function() return false end,
        TCHaulage.getCanDischargeToObject)

    assertEquals(canUnload(combine), false)
end)

-- Emptied at the end ------------------------------------------------------------

test("a player-driven harvest without haulage has its combine emptied when it ends", function()
    local world = setup()
    local combine = addCombine(world, 10000, 6000)
    local job = addHarvestJob(world, combine)

    TCHaulage.emptyHarvestersAfterJob(job)

    assertEquals(combine:getFillUnitFillLevel(1), 0)
end)

test("a player-driven haulage job's combine is left for the player to deliver", function()
    local world = setup()
    local combine = addCombine(world, 10000, 6000)
    local job = addHarvestJob(world, combine, { includesHaulage = true })

    TCHaulage.emptyHarvestersAfterJob(job)

    assertEquals(combine:getFillUnitFillLevel(1), 6000)
end)

test("a hired crew's combine is still emptied when it ends", function()
    local world = setup()
    local combine = addCombine(world, 10000, 6000)
    local job = addHarvestJob(world, combine, { workerId = 3 })

    TCHaulage.emptyHarvestersAfterJob(job)

    assertEquals(combine:getFillUnitFillLevel(1), 0)
end)
