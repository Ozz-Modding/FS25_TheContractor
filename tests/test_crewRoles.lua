-- TheContractorAllocation:assignCrewRoles (035, 044): on a two-worker
-- harvest & haul job, who drives the combine and who hauls. Field work
-- decides, unless one of the pairings leaves someone on a tractor size
-- they aren't certified for.

local function setup()
    local world = stubs.install()
    Class = Class or function()
        return {}
    end
    TheContractorWorker = { MAX_SKILL = 10 }
    TheContractorJobGeneration = { JOB_TYPES = { harvest = {} } }
    TCEquipmentClass = {
        getSizeTier = function(vehicle)
            return vehicle.tier
        end,
    }
    dofile("src/business/Allocation.lua")

    world.workers = {}
    g_currentMission.TheContractor.Staff = {
        getWorker = function(_, farmId, workerId)
            return world.workers[workerId]
        end,
    }
    return world, TheContractorAllocation.new()
end

-- skills: { harvesting = n, haulage = n }; tiers: { medium = rating, ... }
-- (a size missing from tiers is one they aren't certified for).
local function addWorker(world, id, skills, tiers)
    world.workers[id] = {
        id = id,
        getSkill = function(_, skill)
            return skills[skill]
        end,
        getTierCapability = function(_, tier)
            return tiers[tier]
        end,
        hasCertification = function()
            return true
        end,
    }
    return id
end

local function addMachine(world, tier)
    return world:register({ tier = tier })
end

local function harvestJob()
    return {
        jobType = "harvest",
        requiredSkillLevel = 5,
        getOperationSkill = function()
            return "harvesting"
        end,
    }
end

test("the better harvester drives the combine, even if they'd haul better too", function()
    local world, allocation = setup()
    local weak = addWorker(world, 1, { harvesting = 4, haulage = 9 }, { medium = 9 })
    local strong = addWorker(world, 2, { harvesting = 7, haulage = 3 }, { medium = 9 })
    local combine = addMachine(world, nil)
    local haulTractor = addMachine(world, "medium")

    local operatorId, haulerId = allocation:assignCrewRoles(1, harvestJob(), { weak, strong }, { combine },
        { haulTractor })
    assertEquals(operatorId, strong, "on the combine")
    assertEquals(haulerId, weak, "hauling")
end)

test("the order they were picked in doesn't matter", function()
    local world, allocation = setup()
    local weak = addWorker(world, 1, { harvesting = 4, haulage = 5 }, { medium = 5 })
    local strong = addWorker(world, 2, { harvesting = 7, haulage = 5 }, { medium = 5 })
    local combine = addMachine(world, nil)
    local haulTractor = addMachine(world, "medium")

    local operatorId = allocation:assignCrewRoles(1, harvestJob(), { strong, weak }, { combine }, { haulTractor })
    assertEquals(operatorId, strong)
end)

test("someone who can't drive the haul tractor's size isn't put on it", function()
    local world, allocation = setup()
    -- Only the weaker harvester can drive the large haul tractor - which
    -- is also the way round harvesting skill picks.
    local bigTractorDriver = addWorker(world, 1, { harvesting = 4, haulage = 5 }, { large = 5 })
    local harvester = addWorker(world, 2, { harvesting = 8, haulage = 5 }, { medium = 5 })
    local combine = addMachine(world, nil)
    local haulTractor = addMachine(world, "large")

    local operatorId, haulerId, capability = allocation:assignCrewRoles(1, harvestJob(),
        { bigTractorDriver, harvester }, { combine }, { haulTractor })
    assertEquals(operatorId, harvester)
    assertEquals(haulerId, bigTractorDriver)
    assertTrue(capability ~= TheContractorAllocation.CAPABILITY.BLOCKED, "a workable crew")
end)

test("the haul tractor's size beats harvesting skill", function()
    local world, allocation = setup()
    -- Only the better harvester can drive the large haul tractor, so they
    -- haul and the weaker one combines.
    local weak = addWorker(world, 1, { harvesting = 4, haulage = 5 }, { medium = 5 })
    local strong = addWorker(world, 2, { harvesting = 7, haulage = 5 }, { medium = 5, large = 5 })
    local combine = addMachine(world, nil)
    local haulTractor = addMachine(world, "large")

    local operatorId, haulerId, capability = allocation:assignCrewRoles(1, harvestJob(), { strong, weak },
        { combine }, { haulTractor })
    assertEquals(operatorId, weak)
    assertEquals(haulerId, strong)
    assertTrue(capability ~= TheContractorAllocation.CAPABILITY.BLOCKED, "a workable crew")
end)

test("nobody can drive the haul tractor: blocked either way", function()
    local world, allocation = setup()
    local a = addWorker(world, 1, { harvesting = 4, haulage = 5 }, { medium = 5 })
    local b = addWorker(world, 2, { harvesting = 7, haulage = 5 }, { medium = 5 })
    local combine = addMachine(world, nil)
    local haulTractor = addMachine(world, "large")

    local _, _, capability = allocation:assignCrewRoles(1, harvestJob(), { a, b }, { combine }, { haulTractor })
    assertEquals(capability, TheContractorAllocation.CAPABILITY.BLOCKED)
end)

test("equal harvesters: the better hauler hauls", function()
    local world, allocation = setup()
    local a = addWorker(world, 1, { harvesting = 6, haulage = 2 }, { medium = 9 })
    local b = addWorker(world, 2, { harvesting = 6, haulage = 8 }, { medium = 9 })
    local combine = addMachine(world, nil)
    local haulTractor = addMachine(world, "medium")

    local operatorId, haulerId = allocation:assignCrewRoles(1, harvestJob(), { b, a }, { combine }, { haulTractor })
    assertEquals(operatorId, a)
    assertEquals(haulerId, b)
end)
