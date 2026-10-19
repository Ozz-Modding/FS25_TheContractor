-- TheContractorJobs:getCrewSkillFactor (022, 035, 080): a job's quality
-- (and so its reputation) is scored on everyone who worked it - on a
-- harvest & haul job both workers count, the combine driver for
-- OPERATOR_SCORE_WEIGHT of it.

local function setup()
    local world = stubs.install()
    Class = Class or function()
        return {}
    end
    TheContractorWorker = { MAX_SKILL = 10 }
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    TheContractorJobGeneration = { JOB_TYPES = { harvest = {} } }
    TCEquipmentClass = {
        getSizeTier = function()
            return nil
        end,
    }
    dofile("src/business/Allocation.lua")
    dofile("src/business/Jobs.lua")

    world.workers = {}
    local tc = g_currentMission.TheContractor
    tc.Allocation = TheContractorAllocation.new()
    tc.Staff = {
        getWorker = function(_, farmId, workerId)
            return world.workers[workerId]
        end,
    }
    return world, setmetatable({}, { __index = TheContractorJobs })
end

local function addWorker(world, id, skills)
    world.workers[id] = {
        id = id,
        getSkill = function(_, skill)
            return skills[skill]
        end,
        getTierCapability = function()
            return nil
        end,
    }
    return id
end

local function harvestJob(operatorId, haulerId)
    return {
        farmId = 1,
        jobType = "harvest",
        requiredSkillLevel = 10,
        assignedWorkerId = operatorId,
        haulerWorkerId = haulerId,
        assignedEquipmentIds = {},
        haulageEquipmentIds = {},
        getOperationSkill = function()
            return "harvesting"
        end,
    }
end

-- Under the requirement: the at-level factor times (0.5 + 0.5 x ratio).
local function under(rating, required)
    return TheContractorJobs.QUALITY_SKILL_BY_MARGIN[0] * (0.5 + 0.5 * rating / required)
end

test("one worker: their own factor", function()
    local world, jobs = setup()
    local operator = addWorker(world, 1, { harvesting = 5 })
    assertNear(jobs:getCrewSkillFactor(harvestJob(operator)), under(5, 10), 1e-9)
end)

test("two workers: both count, the combine driver more", function()
    local world, jobs = setup()
    local operator = addWorker(world, 1, { harvesting = 8 })
    local hauler = addWorker(world, 2, { haulage = 10 })
    local weight = TheContractorJobs.OPERATOR_SCORE_WEIGHT
    assertNear(jobs:getCrewSkillFactor(harvestJob(operator, hauler)),
        weight * under(8, 10) + (1 - weight) * TheContractorJobs.QUALITY_SKILL_BY_MARGIN[0], 1e-9)
end)

test("a weak hauler doesn't set the score on their own", function()
    local world, jobs = setup()
    local operator = addWorker(world, 1, { harvesting = 10 })
    local hauler = addWorker(world, 2, { haulage = 2 })
    assertTrue(jobs:getCrewSkillFactor(harvestJob(operator, hauler)) > under(2, 10))
end)

test("the player alone always scores in full", function()
    local _, jobs = setup()
    assertNear(jobs:getCrewSkillFactor(harvestJob(nil)), 1, 1e-9)
end)
