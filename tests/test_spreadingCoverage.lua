-- 184: a spreader's cone leaves gaps the AI never fills, so a hired
-- worker's spreading job is done at 85% once its AI has driven the whole
-- course. Short of that the watchdog sends the worker round once more,
-- then holds the job. The real Jobs threshold, JOB_TYPES, Dispatch's
-- AI-stopped handling and the Watchdog; the rest faked.

local function loadJobs(world)
    TheContractor = { SaveKey = "TheContractor" }
    Environment = { PERIODS_IN_YEAR = 12 }
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    MessageType = { DAY_CHANGED = 1, HOUR_CHANGED = 2, FARMLAND_OWNER_CHANGED = 3 }
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }
    world:load("src/business/Job.lua")
    world:load("src/business/Jobs.lua")
    world:load("src/business/JobGeneration.lua")
end

local function newJob(jobType, percentage)
    local job = TheContractorJob.new(1, 1, jobType, 27, 1, 1, 1, 1000)
    job.state = TheContractorJob.STATE.IN_PROGRESS
    job.assignedWorkerId = 3
    job.completionPercentage = percentage
    return job
end

test("only a spreading job's finished course lowers the bar", function()
    local world = stubs.install()
    loadJobs(world)
    local full = TheContractorJobs.COMPLETION_THRESHOLD_PERCENTAGE
    local finished = TheContractorJobs.FINISHED_COURSE_THRESHOLD_PERCENTAGE

    assertTrue(finished < full, "lower than a full field")
    assertEquals(TheContractorJobs.getDoneThreshold(newJob("lime", 0), true), finished)
    assertEquals(TheContractorJobs.getDoneThreshold(newJob("fertilize", 0), true), finished)
    assertEquals(TheContractorJobs.getDoneThreshold(newJob("lime", 0), false), full, "stopped otherwise")
    assertEquals(TheContractorJobs.getDoneThreshold(newJob("herbicide", 0), true), full, "a boom sprayer")
    assertEquals(TheContractorJobs.getDoneThreshold(newJob("plow", 0), true), full)
end)

-- Dispatch's AI-stopped handling ----------------------------------------------

local function message(class, messageType)
    return {
        isa = function(_, other) return other == class end,
        getType = function() return messageType end,
        getMessage = function() return "stopped" end,
    }
end

local function setupDispatch()
    local world = stubs.install()
    loadJobs(world)
    TCAINotifications = { getVehicle = function() return nil end }
    TCADSWorkerRefusal = { isRefusalMessage = function() return false end }
    world:load("src/business/Dispatch.lua")
    AIMessageType = { ERROR = 3, OK = 1 }
    AIMessageErrorOutOfFill = {}
    AIMessageErrorOutOfFuel = {}
    AIMessageSuccessFinishedJob = {}
    AIMessageSuccessStoppedByUser = {}

    world.jobs = {}
    world.completed = {}
    world.courseShort = {}
    g_currentMission.TheContractor.Jobs = {
        getJobById = function(_, jobId) return world.jobs[jobId] end,
        completeJob = function(_, job, isForced, courseFinished)
            table.insert(world.completed, { jobId = job.id, isForced = isForced, courseFinished = courseFinished })
            if job.completionPercentage >= TheContractorJobs.getDoneThreshold(job, courseFinished) then
                job.state = TheContractorJob.STATE.COMPLETED
            end
        end,
    }
    g_currentMission.TheContractor.Watchdog = {
        onCourseFinishedShort = function(_, job) table.insert(world.courseShort, job.id) end,
    }
    return world, TheContractorDispatch.new()
end

local function stopAI(world, dispatch, job, aiMessage)
    world.jobs[job.id] = job
    local aiJob = {}
    dispatch.aiJobByOurJobId[job.id] = aiJob
    dispatch.ourJobIdByAIJob[aiJob] = job.id
    dispatch:onAIJobStopped(aiJob, aiMessage)
end

test("a spreading job whose worker drove the whole course completes short of a full field", function()
    local world, dispatch = setupDispatch()
    local job = newJob("lime", 90)

    stopAI(world, dispatch, job, message(AIMessageSuccessFinishedJob, AIMessageType.OK))

    assertEquals(world.completed[1].courseFinished, true)
    assertEquals(job.state, TheContractorJob.STATE.COMPLETED)
    assertEquals(#world.courseShort, 0)
end)

test("the player switching the AI off isn't a finished course", function()
    local world, dispatch = setupDispatch()
    local job = newJob("lime", 90)

    stopAI(world, dispatch, job, message(AIMessageSuccessStoppedByUser, AIMessageType.OK))

    assertEquals(world.completed[1].courseFinished, false)
    assertEquals(job.state, TheContractorJob.STATE.IN_PROGRESS)
    assertEquals(#world.courseShort, 0, "nothing for the watchdog")
end)

test("a spreading job's course finished well short goes to the watchdog", function()
    local world, dispatch = setupDispatch()
    local job = newJob("fertilize", 60)

    stopAI(world, dispatch, job, message(AIMessageSuccessFinishedJob, AIMessageType.OK))

    assertEquals(job.state, TheContractorJob.STATE.IN_PROGRESS)
    assertEquals(world.courseShort[1], job.id)
end)

test("another job type's course finished short is left to the stuck watchdog as before", function()
    local world, dispatch = setupDispatch()
    local job = newJob("plow", 97)

    stopAI(world, dispatch, job, message(AIMessageSuccessFinishedJob, AIMessageType.OK))

    assertEquals(job.state, TheContractorJob.STATE.IN_PROGRESS)
    assertEquals(#world.courseShort, 0)
end)

-- The watchdog: once more round, then held -----------------------------------

local function setupWatchdog()
    local world = stubs.install()
    loadJobs(world)
    TCJobProgress = { POLL_INTERVAL_MS = 3000 }
    world:load("src/business/Watchdog.lua")
    world:load("src/events/TCWatchdogInterventionEvent.lua")
    g_fieldManager = { getFieldById = function() return nil end }
    world.started = {}
    world.notices = {}
    world.jobs = {}
    g_server = { broadcastEvent = function(_, event) table.insert(world.notices, event.notice) end }
    g_currentMission.TheContractor.Jobs = {
        getJobsByState = function(_, farmId, state)
            local jobs = {}
            for _, job in ipairs(world.jobs) do
                if job.farmId == farmId and job.state == state then
                    table.insert(jobs, job)
                end
            end
            return jobs
        end,
    }
    g_currentMission.TheContractor.Staff = { getWorker = function() return {} end }
    g_currentMission.TheContractor.Dispatch = {
        startJobForWorker = function(_, job, skipTransport)
            table.insert(world.started, { jobId = job.id, skipTransport = skipTransport })
        end,
        holdForADS = function() return false end,
        stopJob = function() end,
    }
    return world, TheContractorWatchdog.new()
end

test("a course finished short is driven once more at the next check, not held against the worker", function()
    local world, watchdog = setupWatchdog()
    local job = newJob("lime", 70)
    table.insert(world.jobs, job)
    local stuckBefore = job.stuckInterventions

    watchdog:onCourseFinishedShort(job)
    assertEquals(#world.started, 0, "not from inside the AI-stopped callback")

    watchdog:checkActiveJobs()

    assertEquals(#world.started, 1)
    assertEquals(world.started[1].skipTransport, true, "already on the field")
    assertEquals(job.stuckInterventions, stuckBefore)
    assertEquals(#world.notices, 0, "a retry isn't announced")
end)

test("a second short course holds the job and says so, and the stuck timer leaves it alone", function()
    local world, watchdog = setupWatchdog()
    local job = newJob("lime", 70)
    table.insert(world.jobs, job)
    watchdog:onCourseFinishedShort(job)
    watchdog:checkActiveJobs()

    watchdog:onCourseFinishedShort(job)

    assertEquals(world.notices[1], TheContractorWatchdog.NOTICE.CANT_FINISH)
    assertTrue(watchdog.trackedByJobId[job.id].needsAttention, "held")

    -- Long past the stuck timeout: no reset.
    local checks = TheContractorWatchdog.STUCK_TIMEOUT_MINUTES * 60000 / TheContractorWatchdog.CHECK_INTERVAL_MS
    for _ = 1, checks * 2 do
        watchdog:checkActiveJobs()
    end
    assertEquals(#world.started, 1, "only the one retry")
    assertEquals(#world.notices, 1)
end)
