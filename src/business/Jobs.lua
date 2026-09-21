-- Farm-scoped job list — the central per-job state (008). Generation (011),
-- inbox (013), negotiation (014), calendar (015), allocation (018),
-- progress (019), and completion/missed handling (022/024) all read/write
-- through this subsystem rather than touching TheContractorJob directly,
-- so creation and state transitions stay server-authoritative and
-- broadcast consistently (see src/events/README.md). No same-day cap
-- (Q24) — concurrency is whatever the caller decides to generate/allocate,
-- not an artificial limit enforced here.

TheContractorJobs = {}
TheContractorJobs_mt = Class(TheContractorJobs)

-- Placeholder flat penalty for a missed deadline, scaled down by whatever
-- progress the job had made (see missJob) — 026 owns the real balance pass,
-- same as every other placeholder number in this codebase.
TheContractorJobs.MISSED_JOB_REPUTATION_PENALTY = 10

local function isMissableState(state)
    return state == TheContractorJob.STATE.ACCEPTED or state == TheContractorJob.STATE.ALLOCATED or
        state == TheContractorJob.STATE.IN_PROGRESS
end

function TheContractorJobs.new()
    local self = {}
    setmetatable(self, TheContractorJobs_mt)

    -- jobsByFarm[farmId][jobId] = TheContractorJob
    self.jobsByFarm = {}
    self.nextJobId = 1

    return self
end

-- Query API -----------------------------------------------------------

function TheContractorJobs:getJob(farmId, jobId)
    local farmJobs = self.jobsByFarm[farmId]
    if farmJobs == nil then
        return nil
    end
    return farmJobs[jobId]
end

function TheContractorJobs:getAllJobs(farmId)
    local result = {}
    local farmJobs = self.jobsByFarm[farmId]
    if farmJobs ~= nil then
        for _, job in pairs(farmJobs) do
            table.insert(result, job)
        end
    end
    return result
end

function TheContractorJobs:getJobsByState(farmId, state)
    local result = {}
    for _, job in ipairs(self:getAllJobs(farmId)) do
        if job.state == state then
            table.insert(result, job)
        end
    end
    return result
end

function TheContractorJobs:getJobsByTargetDate(farmId, targetPeriod, targetDayInPeriod)
    local result = {}
    for _, job in ipairs(self:getAllJobs(farmId)) do
        if job.targetPeriod == targetPeriod and job.targetDayInPeriod == targetDayInPeriod then
            table.insert(result, job)
        end
    end
    return result
end

function TheContractorJobs:getJobsForField(farmId, fieldId)
    local result = {}
    for _, job in ipairs(self:getAllJobs(farmId)) do
        if job.fieldId == fieldId then
            table.insert(result, job)
        end
    end
    return result
end

-- Mutation API (server-authoritative) ----------------------------------

-- Assigns the next id, creates the job in the `offered` state, registers it
-- locally, then broadcasts the full snapshot so other clients can build
-- their own copy. Only the server may create jobs.
-- equipmentAvailable is optional (debug/test creation omits it and gets the
-- Job.new() default of true) — 011's generation engine is the one caller
-- that computes and passes the real answer.
function TheContractorJobs:createJob(farmId, jobType, fieldId, requiredSkillLevel, targetPeriod, targetDayInPeriod,
                                      price, equipmentAvailable)
    if not g_currentMission:getIsServer() then
        return nil
    end

    requiredSkillLevel = math.max(1, math.min(10, requiredSkillLevel))

    local id = self.nextJobId
    self.nextJobId = self.nextJobId + 1

    local job = TheContractorJob.new(id, farmId, jobType, fieldId, requiredSkillLevel, targetPeriod,
        targetDayInPeriod, price)
    if equipmentAvailable ~= nil then
        job.equipmentAvailable = equipmentAvailable
    end
    self:registerJob(job)

    if g_server ~= nil then
        g_server:broadcastEvent(TCJobCreatedEvent.new(job))
    end

    return job
end

-- Registers an already-constructed job — used for a freshly created job on
-- the server, or one rebuilt from TCJobCreatedEvent/initial-client-state on
-- a client. isNewArrival (default true) distinguishes a genuinely new offer
-- (createJob, or another client's TCJobCreatedEvent) from a historical job
-- replayed via readInitialClientState — only the former should trigger 013's
-- HUD notification sound.
function TheContractorJobs:registerJob(job, isNewArrival)
    self.jobsByFarm[job.farmId] = self.jobsByFarm[job.farmId] or {}
    self.jobsByFarm[job.farmId][job.id] = job

    if job.id >= self.nextJobId then
        self.nextJobId = job.id + 1
    end

    Logging.info("TheContractor: farm %d created job %d (%s)", job.farmId, job.id, job.jobType)

    if isNewArrival ~= false and job.state == TheContractorJob.STATE.OFFERED then
        local tc = g_currentMission.TheContractor
        if tc.InboxHUD ~= nil then
            tc.InboxHUD:onJobOffered(job)
        end
    end
end

-- Resolves one round of price negotiation (014) for an offered/negotiating
-- job: transitions offered -> negotiating on the first counter, resolves
-- the counter via TheContractorNegotiation, degrades eagerness, then either
-- accepts (price locked in, job -> accepted), rejects (job -> declined —
-- also forced here on hitting the hard round cap or eagerness bottoming
-- out, per the ticket's "not silently stuck in negotiating" criterion), or
-- counters back (price updated, stays negotiating). Only the server may
-- resolve negotiation; eagerness/round state must stay server-authoritative
-- so a client can't just retry a rejected counter until it sticks.
-- Returns outcome, resultingPrice (nil, nil if the job/state was invalid).
function TheContractorJobs:proposeCounterOffer(farmId, jobId, counterPrice)
    if not g_currentMission:getIsServer() then
        return nil
    end

    local job = self:getJob(farmId, jobId)
    if job == nil then
        return nil
    end

    if job.state ~= TheContractorJob.STATE.OFFERED and job.state ~= TheContractorJob.STATE.NEGOTIATING then
        return nil
    end

    if job.state == TheContractorJob.STATE.OFFERED then
        job:transitionTo(TheContractorJob.STATE.NEGOTIATING)
    end

    job.negotiationRounds = job.negotiationRounds + 1

    local outcome, resultPrice = TheContractorNegotiation.resolveCounterOffer(job, counterPrice)
    TheContractorNegotiation.degradeEagerness(job)

    local roundCapHit = job.negotiationRounds >= TheContractorNegotiation.MAX_ROUNDS
    local eagernessBottomedOut = job.eagerness <= 0

    if outcome == TheContractorNegotiation.OUTCOME.ACCEPTED then
        job.price = resultPrice
        job:transitionTo(TheContractorJob.STATE.ACCEPTED)
    elseif outcome == TheContractorNegotiation.OUTCOME.REJECTED or roundCapHit or eagernessBottomedOut then
        outcome = TheContractorNegotiation.OUTCOME.REJECTED
        job:transitionTo(TheContractorJob.STATE.DECLINED)
    else
        job.price = resultPrice
    end

    Logging.info("TheContractor: farm %d job %d negotiation round %d -> %s ($%.0f)", farmId, jobId,
        job.negotiationRounds, outcome, job.price)

    if g_server ~= nil then
        g_server:broadcastEvent(TCJobNegotiationUpdatedEvent.new(job))
    end

    return outcome, job.price
end

-- Validates the transition against the job's state machine, applies
-- locally, then broadcasts to other clients. Only the server may drive
-- transitions.
function TheContractorJobs:transitionJobState(farmId, jobId, newState)
    if not g_currentMission:getIsServer() then
        return false
    end

    local job = self:getJob(farmId, jobId)
    if job == nil or not job:canTransitionTo(newState) then
        return false
    end

    self:applyJobStateChanged(farmId, jobId, newState)

    if g_server ~= nil then
        g_server:broadcastEvent(TCJobStateChangedEvent.new(farmId, jobId, newState))
    end

    return true
end

-- The actual state flip, run on whichever machine (server, or a client
-- receiving TCJobStateChangedEvent) is applying the transition.
function TheContractorJobs:applyJobStateChanged(farmId, jobId, newState)
    local job = self:getJob(farmId, jobId)
    if job == nil then
        return
    end

    if job:transitionTo(newState) then
        Logging.info("TheContractor: farm %d job %d is now %s", farmId, jobId, newState)
    end
end

-- Missed-deadline handling (024, scoped down) --------------------------
--
-- Full ticket 024 still owns worker/equipment release on a miss — that's a
-- no-op here since this predates 018/019 landing. completionPercentage is
-- now kept live by TCJobProgress's background poll (019), so the penalty
-- scaling below reads real progress.

-- Server-only, same hook shape as 011's hourly generation tick and 012's
-- daily advertising-expiry check: once per in-game day, sweep every
-- farm's jobs for ones whose target date has passed without being
-- completed.
function TheContractorJobs:startDailyTick()
    if not g_currentMission:getIsServer() then
        return
    end

    g_messageCenter:subscribe(MessageType.DAY_CHANGED, self.onDayChanged, self)
end

function TheContractorJobs:stopDailyTick()
    g_messageCenter:unsubscribe(MessageType.DAY_CHANGED, self)
end

-- Compares each job's targetPeriod/targetDayInPeriod against "now" as a
-- same-year linear day index (period/dayInPeriod carry no year — 008's Q23
-- decision — so this can't disambiguate across a year boundary in the
-- abstract). That's safe here specifically because this runs every single
-- in-game day: a job's index can only be exceeded once, and it's caught the
-- very first day that happens, well before enough time could pass for the
-- cyclic period/day pair to wrap back around and look "not yet due" again.
function TheContractorJobs:onDayChanged()
    local environment = g_currentMission.environment
    local daysPerPeriod = environment.daysPerPeriod
    local nowIndex = (environment.currentPeriod - 1) * daysPerPeriod + environment.currentDayInPeriod

    for _, farmJobs in pairs(self.jobsByFarm) do
        for _, job in pairs(farmJobs) do
            if isMissableState(job.state) then
                local targetIndex = (job.targetPeriod - 1) * daysPerPeriod + job.targetDayInPeriod
                if nowIndex > targetIndex then
                    self:missJob(job)
                end
            end
        end
    end
end

-- Reputation loss scales down by whatever completion progress the job had
-- (per the ticket's design decision) — currently always a full penalty
-- since nothing populates completionPercentage yet (019). No payment, per
-- the ticket's explicit "harsh version first" call. Worker/equipment
-- release (018) is a no-op today since nothing assigns them yet.
function TheContractorJobs:missJob(job)
    -- Reputation.lua's score is otherwise always an integer (tier thresholds,
    -- %d display formatting) — floor this rather than let a partial-progress
    -- job leave a fractional score behind.
    local penalty = math.floor(TheContractorJobs.MISSED_JOB_REPUTATION_PENALTY * (1 - job.completionPercentage / 100))
    g_currentMission.TheContractor.Reputation:addReputation(job.farmId, -penalty)

    self:applyJobStateChanged(job.farmId, job.id, TheContractorJob.STATE.MISSED)
    TCJobMissedEvent.showNotification(job.farmId, job.jobType, job.fieldId)

    if g_server ~= nil then
        g_server:broadcastEvent(TCJobStateChangedEvent.new(job.farmId, job.id, TheContractorJob.STATE.MISSED))
        g_server:broadcastEvent(TCJobMissedEvent.new(job.farmId, job.jobType, job.fieldId))
    end

    Logging.info("TheContractor: farm %d job %d missed its deadline (%s, field %d, penalty -%.1f reputation)",
        job.farmId, job.id, job.jobType, job.fieldId, penalty)
end

-- Wire serialization, shared by TCJobCreatedEvent and initial client state.
-- Self-contained (carries its own farmId) so callers don't need to track it
-- separately.

function TheContractorJobs.writeJob(streamId, job)
    streamWriteInt32(streamId, job.farmId)
    streamWriteInt32(streamId, job.id)
    streamWriteString(streamId, job.jobType)
    streamWriteInt32(streamId, job.fieldId)
    streamWriteInt32(streamId, job.requiredSkillLevel)
    streamWriteInt32(streamId, job.targetPeriod)
    streamWriteInt32(streamId, job.targetDayInPeriod)
    streamWriteFloat32(streamId, job.price)
    streamWriteString(streamId, job.state)
    streamWriteFloat32(streamId, job.completionPercentage)
    streamWriteBool(streamId, job.equipmentAvailable)
    streamWriteInt32(streamId, job.eagerness)
    streamWriteInt32(streamId, job.negotiationRounds)

    streamWriteBool(streamId, job.assignedWorkerId ~= nil)
    if job.assignedWorkerId ~= nil then
        streamWriteInt32(streamId, job.assignedWorkerId)
    end

    streamWriteString(streamId, TheContractorJobs.encodeIdList(job.assignedEquipmentIds))

    streamWriteBool(streamId, job.paymentAmount ~= nil)
    if job.paymentAmount ~= nil then
        streamWriteFloat32(streamId, job.paymentAmount)
    end
end

function TheContractorJobs.readJob(streamId)
    local farmId = streamReadInt32(streamId)
    local id = streamReadInt32(streamId)
    local jobType = streamReadString(streamId)
    local fieldId = streamReadInt32(streamId)
    local requiredSkillLevel = streamReadInt32(streamId)
    local targetPeriod = streamReadInt32(streamId)
    local targetDayInPeriod = streamReadInt32(streamId)
    local price = streamReadFloat32(streamId)
    local state = streamReadString(streamId)
    local completionPercentage = streamReadFloat32(streamId)
    local equipmentAvailable = streamReadBool(streamId)
    local eagerness = streamReadInt32(streamId)
    local negotiationRounds = streamReadInt32(streamId)

    local job = TheContractorJob.new(id, farmId, jobType, fieldId, requiredSkillLevel, targetPeriod,
        targetDayInPeriod, price)
    job.state = state
    job.completionPercentage = completionPercentage
    job.equipmentAvailable = equipmentAvailable
    job.eagerness = eagerness
    job.negotiationRounds = negotiationRounds

    if streamReadBool(streamId) then
        job.assignedWorkerId = streamReadInt32(streamId)
    end

    job.assignedEquipmentIds = TheContractorJobs.decodeIdList(streamReadString(streamId))

    if streamReadBool(streamId) then
        job.paymentAmount = streamReadFloat32(streamId)
    end

    return job
end

function TheContractorJobs.encodeIdList(ids)
    if ids == nil or #ids == 0 then
        return ""
    end
    return table.concat(ids, ",")
end

function TheContractorJobs.decodeIdList(str)
    local ids = {}
    if str == nil or str == "" then
        return ids
    end
    for token in str:gmatch("[^,]+") do
        table.insert(ids, tonumber(token))
    end
    return ids
end

-- Persistence -----------------------------------------------------------

function TheContractorJobs:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    self.jobsByFarm = {}
    self.nextJobId = 1

    local rootKey = string.format("%s.jobs", TheContractor.SaveKey)
    self.nextJobId = Utils.getNoNil(getXMLInt(xmlFile, rootKey .. "#nextJobId"), 1)

    local farmIndex = 0
    while true do
        local farmKey = string.format("%s.farm(%d)", rootKey, farmIndex)
        if not hasXMLProperty(xmlFile, farmKey) then
            break
        end

        local farmId = getXMLInt(xmlFile, farmKey .. "#farmId")

        local jobIndex = 0
        while true do
            local jobKey = string.format("%s.job(%d)", farmKey, jobIndex)
            if not hasXMLProperty(xmlFile, jobKey) then
                break
            end

            local id = getXMLInt(xmlFile, jobKey .. "#id")
            local jobType = getXMLString(xmlFile, jobKey .. "#jobType")
            local fieldId = getXMLInt(xmlFile, jobKey .. "#fieldId")
            local requiredSkillLevel = getXMLInt(xmlFile, jobKey .. "#requiredSkillLevel")
            local targetPeriod = getXMLInt(xmlFile, jobKey .. "#targetPeriod")
            local targetDayInPeriod = getXMLInt(xmlFile, jobKey .. "#targetDayInPeriod")
            local price = getXMLFloat(xmlFile, jobKey .. "#price")

            local job = TheContractorJob.new(id, farmId, jobType, fieldId, requiredSkillLevel, targetPeriod,
                targetDayInPeriod, price)

            job.state = Utils.getNoNil(getXMLString(xmlFile, jobKey .. "#state"), job.state)
            job.completionPercentage = Utils.getNoNil(getXMLFloat(xmlFile, jobKey .. "#completionPercentage"), 0)
            job.equipmentAvailable = Utils.getNoNil(getXMLBool(xmlFile, jobKey .. "#equipmentAvailable"), true)
            job.eagerness = Utils.getNoNil(getXMLInt(xmlFile, jobKey .. "#eagerness"), job.eagerness)
            job.negotiationRounds = Utils.getNoNil(getXMLInt(xmlFile, jobKey .. "#negotiationRounds"), 0)
            job.assignedWorkerId = getXMLInt(xmlFile, jobKey .. "#assignedWorkerId")
            job.assignedEquipmentIds = TheContractorJobs.decodeIdList(getXMLString(xmlFile,
                jobKey .. "#assignedEquipmentIds"))
            job.paymentAmount = getXMLFloat(xmlFile, jobKey .. "#paymentAmount")

            self.jobsByFarm[farmId] = self.jobsByFarm[farmId] or {}
            self.jobsByFarm[farmId][id] = job

            if id >= self.nextJobId then
                self.nextJobId = id + 1
            end

            jobIndex = jobIndex + 1
        end

        farmIndex = farmIndex + 1
    end
end

function TheContractorJobs:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    local rootKey = string.format("%s.jobs", TheContractor.SaveKey)
    setXMLInt(xmlFile, rootKey .. "#nextJobId", self.nextJobId)

    local farmIndex = 0
    for farmId, farmJobs in pairs(self.jobsByFarm) do
        local farmKey = string.format("%s.farm(%d)", rootKey, farmIndex)
        setXMLInt(xmlFile, farmKey .. "#farmId", farmId)

        local jobIndex = 0
        for _, job in pairs(farmJobs) do
            local jobKey = string.format("%s.job(%d)", farmKey, jobIndex)
            setXMLInt(xmlFile, jobKey .. "#id", job.id)
            setXMLString(xmlFile, jobKey .. "#jobType", job.jobType)
            setXMLInt(xmlFile, jobKey .. "#fieldId", job.fieldId)
            setXMLInt(xmlFile, jobKey .. "#requiredSkillLevel", job.requiredSkillLevel)
            setXMLInt(xmlFile, jobKey .. "#targetPeriod", job.targetPeriod)
            setXMLInt(xmlFile, jobKey .. "#targetDayInPeriod", job.targetDayInPeriod)
            setXMLFloat(xmlFile, jobKey .. "#price", job.price)
            setXMLString(xmlFile, jobKey .. "#state", job.state)
            setXMLFloat(xmlFile, jobKey .. "#completionPercentage", job.completionPercentage)
            setXMLBool(xmlFile, jobKey .. "#equipmentAvailable", job.equipmentAvailable)
            setXMLInt(xmlFile, jobKey .. "#eagerness", job.eagerness)
            setXMLInt(xmlFile, jobKey .. "#negotiationRounds", job.negotiationRounds)

            if job.assignedWorkerId ~= nil then
                setXMLInt(xmlFile, jobKey .. "#assignedWorkerId", job.assignedWorkerId)
            end

            setXMLString(xmlFile, jobKey .. "#assignedEquipmentIds",
                TheContractorJobs.encodeIdList(job.assignedEquipmentIds))

            if job.paymentAmount ~= nil then
                setXMLFloat(xmlFile, jobKey .. "#paymentAmount", job.paymentAmount)
            end

            jobIndex = jobIndex + 1
        end

        farmIndex = farmIndex + 1
    end
end

function TheContractorJobs:writeInitialClientState(streamId, connection)
    local allJobs = {}
    for farmId, farmJobs in pairs(self.jobsByFarm) do
        for _, job in pairs(farmJobs) do
            table.insert(allJobs, job)
        end
    end

    streamWriteInt32(streamId, #allJobs)
    for _, job in ipairs(allJobs) do
        TheContractorJobs.writeJob(streamId, job)
    end
end

function TheContractorJobs:readInitialClientState(streamId, connection)
    local jobCount = streamReadInt32(streamId)
    for _ = 1, jobCount do
        self:registerJob(TheContractorJobs.readJob(streamId), false)
    end
end
