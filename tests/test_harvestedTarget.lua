-- A player-driven harvest's delivery target comes from what was actually
-- threshed (TCHaulage, "Harvested litres"). Reported with Precision Farming
-- on: the whole field cut, a quarter of the canola still "missing", since
-- PF works out its own yield on any field that isn't a vanilla contract's
-- and the target was vanilla's formula.

local FARM = 1
local JOB_FARMLAND = 7

local function setup()
    local world = stubs.install()
    world:addFillType("WHEAT", "Wheat")
    world:addFillType("OAT", "Oat")

    -- The engine's combine, before TCHaulage is sourced (as in game): the
    -- litres it returns are what went into the tank.
    Combine = {
        addCutterArea = function(vehicle, area, liters, inputFruitType, outputFillType)
            return liters
        end,
    }

    TCJobProgress = { POLL_INTERVAL_MS = 3000 }
    TheContractorJob = { STATE = { ALLOCATED = 3, IN_PROGRESS = 4 } }
    TheContractorJobs = { COMPLETION_THRESHOLD_PERCENTAGE = 100 }
    TheContractorJobGeneration = {
        JOB_TYPES = { harvest = { cropDependent = true }, bale = { cropDependent = true, deliversBales = true } },
    }
    world:load("src/util/TCHaulage.lua")
    world.station = { missions = {} }
    TCHaulage.resolveDeliveryStation = function() return world.station end
    TCHaulage.canFarmDeliver = function() return true end

    g_fruitTypeManager = {
        getFillTypeIndexByFruitTypeIndex = function(_, fruitTypeIndex)
            return fruitTypeIndex
        end,
    }
    g_fieldManager = {
        getFieldById = function()
            return {
                getFarmland = function()
                    return { id = JOB_FARMLAND }
                end,
            }
        end,
    }
    getWorldTranslation = function(node)
        return node.x, 0, node.z
    end
    g_farmlandManager = {
        getFarmlandIdAtWorldPosition = function(_, x)
            return x
        end,
    }

    world.jobs = {}
    world.deliveries = {}
    g_currentMission.getIsServer = function() return true end
    g_currentMission.TheContractor.Jobs = {
        getJobById = function(_, jobId)
            return world.jobs[jobId]
        end,
        getAllJobs = function(_, farmId)
            local jobs = {}
            for _, job in pairs(world.jobs) do
                if job.farmId == farmId then
                    table.insert(jobs, job)
                end
            end
            return jobs
        end,
        applyJobDelivery = function(_, farmId, jobId, delivered, required)
            local job = world.jobs[jobId]
            job.deliveredLiters = delivered
            job.requiredLiters = required
        end,
    }
    g_server = { broadcastEvent = function() end }
    TCJobDeliveryEvent = { new = function() return {} end }
    return world
end

local function addJob(world, def)
    local job = {
        id = def.id or 1,
        farmId = FARM,
        jobType = def.jobType or "harvest",
        fieldId = 1,
        state = TheContractorJob.STATE.IN_PROGRESS,
        includesHaulage = true,
        completionPercentage = def.done or 0,
        requiredLiters = def.required or 10000,
        deliveredLiters = def.delivered or 0,
        harvestedLiters = def.harvested,
        needsPlayerDelivery = function(self)
            return self.includesHaulage and self.assignedWorkerId == nil
        end,
        getFruitTypeIndex = function()
            return FillType.WHEAT
        end,
    }
    world.jobs[job.id] = job
    return job
end

local function addCombine(world, farmlandId, farmId)
    local combine = world:addVehicle({ name = "Combine", farmId = farmId or FARM })
    combine.rootNode = { x = farmlandId or JOB_FARMLAND, z = 0 }
    return combine
end

local function thresh(combine, liters, fillType)
    return Combine.addCutterArea(combine, 1, liters, FillType.WHEAT, fillType or FillType.WHEAT, FARM, 1)
end

local function poll()
    TCHaulage.update(TCHaulage.POLL_INTERVAL_MS)
end

test("the combine's litres still go into its tank", function()
    local world = setup()
    addJob(world, { harvested = 0 })
    assertEquals(thresh(addCombine(world), 500), 500)
end)

test("what the farm's combine threshes on the job's land is counted", function()
    local world = setup()
    local job = addJob(world, { harvested = 0 })
    local combine = addCombine(world)

    thresh(combine, 500)
    thresh(combine, 250)

    assertEquals(job.harvestedLiters, 750)
end)

test("off the job's land, another crop or another farm's combine isn't", function()
    local world = setup()
    local job = addJob(world, { harvested = 0 })

    thresh(addCombine(world, 3), 500)
    thresh(addCombine(world), 500, FillType.OAT)
    thresh(addCombine(world, JOB_FARMLAND, 2), 500)

    assertEquals(job.harvestedLiters, 0)
end)

test("a hired crew's harvest or a bale job isn't counted", function()
    local world = setup()
    local hired = addJob(world, { id = 1, harvested = 0 })
    hired.assignedWorkerId = 4
    local bale = addJob(world, { id = 2, jobType = "bale", harvested = 0 })

    thresh(addCombine(world), 500)

    assertEquals(hired.harvestedLiters, 0)
    assertEquals(bale.harvestedLiters, 0)
end)

test("once the field's cut, the target is a share of what was threshed", function()
    local world = setup()
    local job = addJob(world, { done = 100, required = 10000, delivered = 6000, harvested = 7500 })

    poll()

    assertNear(job.requiredLiters, 7500 * TCHaulage.HARVEST_SUCCESS_FACTOR, 0.01)
    assertEquals(job.deliveredLiters, 6000)
end)

test("delivering what was threshed then meets the terms", function()
    local world = setup()
    local job = addJob(world, { done = 100, required = 10000, delivered = 7400, harvested = 7500 })

    poll()

    assertTrue(job.deliveredLiters >= job.requiredLiters)
    assertNear(job.deliveredLiters, 7500 * TCHaulage.HARVEST_SUCCESS_FACTOR, 0.01)
end)

test("the target stays the estimate while the field's still being cut", function()
    local world = setup()
    local job = addJob(world, { done = 60, required = 10000, delivered = 4000, harvested = 4000 })

    poll()

    assertEquals(job.requiredLiters, 10000)
end)

test("a better yield than expected never raises the target", function()
    local world = setup()
    local job = addJob(world, { done = 100, required = 10000, harvested = 14000 })

    poll()

    assertEquals(job.requiredLiters, 10000)
end)

test("a harvest not counted from the start keeps the estimate", function()
    local world = setup()
    local job = addJob(world, { done = 100, required = 10000 })
    thresh(addCombine(world), 500)

    poll()

    assertEquals(job.harvestedLiters, nil)
    assertEquals(job.requiredLiters, 10000)
end)
