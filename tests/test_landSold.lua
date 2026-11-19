-- A field bought by a player farm (a friend's in multiplayer, or the job's
-- own) is no farmer's any more, so the live jobs on it end with nothing
-- lost: an offer is withdrawn (declined, LAND_SOLD), a job taken on is
-- called off as a quiet miss without penalty, with a notice. Jobs whose
-- field only names where they are carry on.

local function setup()
    local world = stubs.install()
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }
    dofile("src/business/Job.lua")
    dofile("src/business/Jobs.lua")
    dofile("src/business/Relationships.lua")

    TheContractorJobGeneration = {
        JOB_TYPES = { harvest = {}, plow = {}, yardBales = { offField = true }, attendAuction = {} },
        getTypeLabel = function(jobType) return jobType end,
        getFruitTypeIndexByName = function() return nil end,
    }

    -- Fields 1 and 2 on farmland 10, field 3 on farmland 11.
    local function field(id, farmlandId)
        return {
            getId = function() return id end,
            getName = function() return tostring(id) end,
            getFarmland = function() return { getId = function() return farmlandId end } end,
        }
    end
    world.fields = { field(1, 10), field(2, 10), field(3, 11) }
    g_fieldManager = {
        getFields = function() return world.fields end,
        getFieldById = function(_, id) return world.fields[id] end,
    }
    g_farmManager.getFarmById = function(_, farmId) return { name = "Farm " .. farmId } end

    world.notices = {}
    g_currentMission.TheContractor.Notices = {
        publish = function(_, farmId, text, ttlMonths)
            table.insert(world.notices, { farmId = farmId, ttlMonths = ttlMonths })
        end,
    }

    local calls = {}
    local jobs = setmetatable({ jobsByFarm = {} }, { __index = TheContractorJobs })
    function jobs:transitionJobState(farmId, jobId, newState, playerName, declineReason)
        table.insert(calls, { "transition", jobId, newState, declineReason })
        self:getJob(farmId, jobId).state = newState
        return true
    end
    function jobs:missJob(job, noPenalty, quiet)
        table.insert(calls, { "miss", job.id, noPenalty, quiet })
        job.state = TheContractorJob.STATE.MISSED
    end

    local function addJob(id, farmId, jobType, fieldId, state)
        local job = TheContractorJob.new(id, farmId, jobType, fieldId, 1, 1, 1, 1000)
        job.state = state
        jobs.jobsByFarm[farmId] = jobs.jobsByFarm[farmId] or {}
        jobs.jobsByFarm[farmId][id] = job
        return job
    end
    return world, jobs, calls, addJob
end

test("a bought field's offers are withdrawn and its taken-on jobs called off, any farm's", function()
    local world, jobs, calls, addJob = setup()
    local STATE = TheContractorJob.STATE
    addJob(1, 2, "harvest", 1, STATE.OFFERED)
    addJob(2, 2, "plow", 2, STATE.NEGOTIATING)
    addJob(3, 2, "harvest", 1, STATE.IN_PROGRESS)
    addJob(4, 1, "plow", 2, STATE.ACCEPTED)

    jobs:onFarmlandOwnerChanged(10, 1, false)

    local reason = TheContractorRelationships.DECLINE_REASON.LAND_SOLD
    assertEquals(#calls, 4)
    local byJob = {}
    for _, call in ipairs(calls) do
        byJob[call[2]] = call
    end
    assertEquals(byJob[1][1], "transition")
    assertEquals(byJob[1][3], STATE.DECLINED)
    assertEquals(byJob[1][4], reason)
    assertEquals(byJob[2][1], "transition")
    assertEquals(byJob[2][4], reason)
    assertEquals(byJob[3][1], "miss")
    assertEquals(byJob[3][3], true, "no penalty")
    assertEquals(byJob[3][4], true, "quiet: the notice says why")
    assertEquals(byJob[4][1], "miss")
    assertEquals(#world.notices, 2)
    local noticeFarms = { world.notices[1].farmId, world.notices[2].farmId }
    table.sort(noticeFarms)
    assertEquals(table.concat(noticeFarms, ","), "1,2")
end)

test("jobs on other farmland, finished jobs, and jobs whose field only names where they are carry on", function()
    local _, jobs, calls, addJob = setup()
    local STATE = TheContractorJob.STATE
    addJob(1, 2, "harvest", 3, STATE.OFFERED)            -- farmland 11
    addJob(2, 2, "harvest", 1, STATE.COMPLETED)
    addJob(3, 2, "yardBales", 1, STATE.ACCEPTED)         -- offField
    local spill = addJob(4, 2, "harvest", 1, STATE.ACCEPTED)
    spill.spill = {}
    local attend = addJob(5, 2, "attendAuction", 1, STATE.ACCEPTED)
    attend.auctionId = 1

    jobs:onFarmlandOwnerChanged(10, 1, false)

    assertEquals(#calls, 0)
end)

test("land loaded from the save or sold back to nobody ends nothing", function()
    local _, jobs, calls, addJob = setup()
    local STATE = TheContractorJob.STATE
    addJob(1, 2, "harvest", 1, STATE.OFFERED)

    jobs:onFarmlandOwnerChanged(10, 1, true)
    jobs:onFarmlandOwnerChanged(10, FarmlandManager.NO_OWNER_FARM_ID, false)

    assertEquals(#calls, 0)
end)

test("an offer withdrawn because the land sold costs no relationship", function()
    setup()
    local relationships = TheContractorRelationships.new()
    local adjusted = false
    relationships.adjust = function() adjusted = true end
    relationships:onJobDeclined({ farmId = 1, customerId = 5 }, TheContractorRelationships.DECLINE_REASON.LAND_SOLD)
    assertTrue(not adjusted)
end)
