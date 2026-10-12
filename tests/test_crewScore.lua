-- TheContractorJobs:getReputationQualificationRatio (022, 035): a job's
-- reputation and quality are scored on everyone who worked it - on a
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

test("one worker: their own ratio", function()
    local world, jobs = setup()
    local operator = addWorker(world, 1, { harvesting = 5 })
    assertNear(jobs:getReputationQualificationRatio(harvestJob(operator)), 0.5, 1e-9)
end)

test("two workers: both count, the combine driver more", function()
    local world, jobs = setup()
    local operator = addWorker(world, 1, { harvesting = 8 })
    local hauler = addWorker(world, 2, { haulage = 3 })
    local weight = TheContractorJobs.OPERATOR_SCORE_WEIGHT
    assertNear(jobs:getReputationQualificationRatio(harvestJob(operator, hauler)), weight * 0.8 + (1 - weight) * 0.3,
        1e-9)
end)

test("a weak hauler no longer sets the score on their own", function()
    local world, jobs = setup()
    local operator = addWorker(world, 1, { harvesting = 10 })
    local hauler = addWorker(world, 2, { haulage = 2 })
    assertTrue(jobs:getReputationQualificationRatio(harvestJob(operator, hauler)) > 0.2)
end)

test("the player alone always scores in full", function()
    local _, jobs = setup()
    assertNear(jobs:getReputationQualificationRatio(harvestJob(nil)), 1, 1e-9)
end)
