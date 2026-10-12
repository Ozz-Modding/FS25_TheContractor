-- TheContractorJobs:forceJobState (tcJob state): completed and missed go
-- through the real completeJob (forced) and missJob; other states are a
-- plain transition; an illegal one does nothing.

local function setup()
    local world = stubs.install()
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    dofile("src/business/Job.lua")
    dofile("src/business/Jobs.lua")

    local calls = {}
    local jobs = setmetatable({ jobsByFarm = { [1] = {} } }, { __index = TheContractorJobs })
    function jobs:completeJob(job, isForced)
        table.insert(calls, { "complete", isForced })
        job.state = TheContractorJob.STATE.COMPLETED
    end
    function jobs:missJob(job)
        table.insert(calls, { "miss" })
        job.state = TheContractorJob.STATE.MISSED
    end
    function jobs:transitionJobState(farmId, jobId, newState)
        table.insert(calls, { "transition", newState })
        return true
    end

    local function addJob(id, state)
        local job = setmetatable({ id = id, farmId = 1, state = state }, { __index = TheContractorJob })
        jobs.jobsByFarm[1][id] = job
        return job
    end
    return jobs, calls, addJob
end

test("completed is a forced real completion", function()
    local jobs, calls, addJob = setup()
    addJob(1, TheContractorJob.STATE.IN_PROGRESS)
    assertEquals(jobs:forceJobState(1, 1, TheContractorJob.STATE.COMPLETED), true)
    assertEquals(calls[1][1], "complete")
    assertEquals(calls[1][2], true, "isForced")
end)

test("missed is a real miss", function()
    local jobs, calls, addJob = setup()
    addJob(1, TheContractorJob.STATE.ALLOCATED)
    assertEquals(jobs:forceJobState(1, 1, TheContractorJob.STATE.MISSED), true)
    assertEquals(calls[1][1], "miss")
end)

test("other states are a plain transition", function()
    local jobs, calls, addJob = setup()
    addJob(1, TheContractorJob.STATE.OFFERED)
    jobs:forceJobState(1, 1, TheContractorJob.STATE.ACCEPTED)
    assertEquals(calls[1][1], "transition")
    assertEquals(calls[1][2], TheContractorJob.STATE.ACCEPTED)
end)

test("an illegal state or a missing job does nothing", function()
    local jobs, calls, addJob = setup()
    addJob(1, TheContractorJob.STATE.OFFERED)
    assertEquals(jobs:forceJobState(1, 1, TheContractorJob.STATE.COMPLETED), false)
    assertEquals(jobs:forceJobState(1, 99, TheContractorJob.STATE.ACCEPTED), false)
    assertEquals(#calls, 0)
end)
