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

table.insert(FinanceStats.statNames, "tcJobPayout")
FinanceStats.statNameToIndex["tcJobPayout"] = #FinanceStats.statNames

-- Placeholder flat penalty for a missed deadline, scaled down by whatever
-- progress the job had made (see missJob) — 026 owns the real balance pass,
-- same as every other placeholder number in this codebase.
TheContractorJobs.MISSED_JOB_REPUTATION_PENALTY = 10

-- Completion reputation reward (022) is the field's area times the job
-- type's reputationPerHa (JobGeneration's JOB_TYPES), scaled down by
-- operator under-qualification (see calculateReputationReward). Never less
-- than MIN_COMPLETION_REPUTATION_REWARD, so a tiny field still counts. 026
-- owns the real balance pass, same as every other placeholder number in
-- this codebase.
TheContractorJobs.MIN_COMPLETION_REPUTATION_REWARD = 1

-- A job's field work counts as "finished" once 019's completionPercentage
-- (0-100 scale, already normalized against AbstractMission.SUCCESS_FACTOR by
-- TCJobProgress) reaches this.
TheContractorJobs.COMPLETION_THRESHOLD_PERCENTAGE = 100

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

    -- 022: reuses TCJobProgress's own poll cadence for the completion sweep
    -- below - no benefit checking more often than completionPercentage
    -- itself actually refreshes, same reasoning 021's Watchdog already uses
    -- for its own check interval.
    self.completionCheckAccumulatedMs = 0

    MoneyType.TC_JOB_PAYOUT = MoneyType.register("tcJobPayout", "tc_moneyType_jobPayout")
    MoneyType.LAST_ID = MoneyType.LAST_ID + 1

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
-- that computes and passes the real answer. fruitTypeName is optional too —
-- only crop-dependent (harvest) jobs carry one. deadlineDay (absolute
-- monotonic day) is optional: 011 passes the one it worked out, callers
-- that only have a period/day (debug creation) get the next occurrence of
-- that date (getNextOccurrenceDay). includesHaulage/deliveryStation
-- (an unloading station object) are harvest-only and optional (035).
function TheContractorJobs:createJob(farmId, jobType, fieldId, requiredSkillLevel, targetPeriod, targetDayInPeriod,
                                      price, equipmentAvailable, fruitTypeName, deadlineDay, includesHaulage,
                                      deliveryStation)
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
    job.fruitTypeName = fruitTypeName
    job.deadlineDay = deadlineDay or TheContractorJobs.getNextOccurrenceDay(targetPeriod, targetDayInPeriod)
    if includesHaulage and deliveryStation ~= nil then
        job.includesHaulage = true
        TCHaulage.setDeliveryStation(job, deliveryStation)
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

-- Server-only: flags a hired-worker job as on the road to its field (or
-- not), applies locally, then broadcasts to other clients. Driven by
-- Dispatch's transport wait - see TheContractorJob.isTravelling.
function TheContractorJobs:setJobTravelling(farmId, jobId, isTravelling)
    if not g_currentMission:getIsServer() then
        return
    end

    local job = self:getJob(farmId, jobId)
    if job == nil or job.isTravelling == isTravelling then
        return
    end

    self:applyJobTravelling(farmId, jobId, isTravelling)

    if g_server ~= nil then
        g_server:broadcastEvent(TCJobTravellingEvent.new(farmId, jobId, isTravelling))
    end
end

-- The actual flag flip, run on whichever machine (server, or a client
-- receiving TCJobTravellingEvent) is applying it.
function TheContractorJobs:applyJobTravelling(farmId, jobId, isTravelling)
    local job = self:getJob(farmId, jobId)
    if job ~= nil then
        job.isTravelling = isTravelling
    end
end

-- Delivery progress on a player-driven haulage job (035), run on whichever
-- machine (server via TCHaulage, or a client receiving TCJobDeliveryEvent)
-- is applying it. Tells the farm's player once the delivery terms are met,
-- since from then on their loads sell as normal.
function TheContractorJobs:applyJobDelivery(farmId, jobId, deliveredLiters, requiredLiters)
    local job = self:getJob(farmId, jobId)
    if job == nil then
        return
    end

    local wasDelivered = job.requiredLiters > 0 and job.deliveredLiters >= job.requiredLiters
    job.deliveredLiters = deliveredLiters
    job.requiredLiters = requiredLiters

    local isDelivered = requiredLiters > 0 and deliveredLiters >= requiredLiters
    if isDelivered and not wasDelivered and g_client ~= nil and g_currentMission:getFarmId() == farmId then
        local field = g_fieldManager:getFieldById(job.fieldId)
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
            string.format(g_i18n:getText("tc_haulage_deliveryComplete"),
                field ~= nil and field:getName() or tostring(job.fieldId)))
    end
end

-- The slowest of a job's hired workers (by workSpeed), or nil for a
-- player-driven job - what the speed-scaled waits (Dispatch's transport,
-- Cooldown's buffer) go by, since a two-worker job can only move as fast
-- as its slower half.
function TheContractorJobs.getSlowestWorker(job)
    local staff = g_currentMission.TheContractor.Staff
    local slowest = nil
    for _, workerId in ipairs(job:getWorkerIds()) do
        local worker = staff:getWorker(job.farmId, workerId)
        if worker ~= nil and (slowest == nil or worker.workSpeed < slowest.workSpeed) then
            slowest = worker
        end
    end
    return slowest
end

-- Missed-deadline handling (024) ---------------------------------------
--
-- completionPercentage is kept live by TCJobProgress's background poll
-- (019), so the penalty scaling below reads real progress; allocated
-- resources (018) are released via releaseMissedJobResources.

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

-- A job is due by the end of its deadlineDay (absolute monotonic day), so
-- it's missed once the day counter moves past it. This used to compare
-- targetPeriod/targetDayInPeriod as a same-year day index, which (having no
-- year, per 008's Q23) read any job due next calendar year — e.g. a harvest
-- predicted for spring, generated in autumn — as already overdue.
--
-- Offers nobody answered (offered/negotiating) lapse at the same point,
-- quietly flipping to declined: the player never committed, so there's no
-- reputation hit, and it stops a stale offer being accepted only to fail
-- at the very next day change.
function TheContractorJobs:onDayChanged()
    local today = g_currentMission.environment.currentMonotonicDay

    for farmId, farmJobs in pairs(self.jobsByFarm) do
        for _, job in pairs(farmJobs) do
            if job.deadlineDay ~= nil and today > job.deadlineDay then
                if isMissableState(job.state) then
                    self:missJob(job)
                elseif job.state == TheContractorJob.STATE.OFFERED or job.state == TheContractorJob.STATE.NEGOTIATING then
                    self:transitionJobState(farmId, job.id, TheContractorJob.STATE.DECLINED)
                end
            end
        end
    end
end

-- The absolute (monotonic) day of the next time the calendar reads
-- period/dayInPeriod, today included. Assumes it's within the coming year,
-- which is all a yearless period/day can express.
function TheContractorJobs.getNextOccurrenceDay(period, dayInPeriod)
    local environment = g_currentMission.environment
    local daysPerPeriod = environment.daysPerPeriod
    local yearLength = daysPerPeriod * Environment.PERIODS_IN_YEAR
    local nowIndex = (environment.currentPeriod - 1) * daysPerPeriod + environment.currentDayInPeriod
    local targetIndex = (period - 1) * daysPerPeriod + math.min(dayInPeriod, daysPerPeriod)
    return environment.currentMonotonicDay + (targetIndex - nowIndex) % yearLength
end

-- Reputation loss scales down by whatever completion progress the job had
-- (per the ticket's design decision). No payment, per the ticket's explicit
-- "harsh version first" call. The state flips to `missed` before anything
-- is released, so the AI_JOB_STOPPED that Dispatch:stopJob fires
-- synchronously (AISystem:stopJobInternal) hits an already-terminal job in
-- Dispatch:onAIJobStopped -> completeJob and no-ops there, rather than
-- racing a payout.
function TheContractorJobs:missJob(job)
    -- Reputation.lua's score is otherwise always an integer (tier thresholds,
    -- %d display formatting) — floor this rather than let a partial-progress
    -- job leave a fractional score behind.
    local penalty = math.floor(TheContractorJobs.MISSED_JOB_REPUTATION_PENALTY * (1 - job.completionPercentage / 100))
    g_currentMission.TheContractor.Reputation:addReputation(job.farmId, -penalty)

    local wasAllocated = job.state ~= TheContractorJob.STATE.ACCEPTED
    self:applyJobStateChanged(job.farmId, job.id, TheContractorJob.STATE.MISSED)

    if g_server ~= nil then
        g_server:broadcastEvent(TCJobStateChangedEvent.new(job.farmId, job.id, TheContractorJob.STATE.MISSED))
    end

    if wasAllocated then
        self:releaseMissedJobResources(job)
    end

    TCJobMissedEvent.showNotification(job.farmId, job.jobType, job.fieldId)

    if g_server ~= nil then
        g_server:broadcastEvent(TCJobMissedEvent.new(job.farmId, job.jobType, job.fieldId))
    end

    Logging.info("TheContractor: farm %d job %d missed its deadline (%s, field %d, %.0f%% done, penalty -%d reputation)",
        job.farmId, job.id, job.jobType, job.fieldId, job.completionPercentage, penalty)
end

-- Releases an allocated/in_progress job's worker and equipment on a miss.
-- Equipment needs no explicit release of its own - Allocation:isVehicleFree
-- only treats allocated/in_progress jobs as holding a vehicle, so the
-- `missed` flip already frees it. What does need undoing: a still-running
-- AI Helper (020) would otherwise keep working a field we no longer get
-- paid for, and a hired worker would sit `assigned` forever.
--
-- Cooldown follows the ticket's "same rules as 023, based on whatever
-- partial work occurred" default: if any work happened, the worker and
-- equipment go through the normal skill-scaled buffer (they were genuinely
-- out on the job); if none did, there's nothing to come back from, so the
-- worker goes straight back to idle and the equipment stays visible.
function TheContractorJobs:releaseMissedJobResources(job)
    g_currentMission.TheContractor.Dispatch:stopJob(job.id, AIMessageSuccessStoppedByUser.new())
    TCJobProgress.clearJob(job.id)
    TCHaulage.stopDelivery(job)

    if job.completionPercentage > 0 then
        g_currentMission.TheContractor.Cooldown:startCooldown(job)
    else
        -- No buffer to come back from - dispatched equipment (020) goes
        -- straight back to where it was taken from, and haulage equipment
        -- (035), which never left the yard, just reappears.
        TCJobSiteSetup.returnHome(job)
        if #job.haulageEquipmentIds > 0 then
            TCEquipmentVisibility.setVisibleEverywhere(job.haulageEquipmentIds, true)
        end
        for _, workerId in ipairs(job:getWorkerIds()) do
            g_currentMission.TheContractor.Staff:setWorkerStatus(job.farmId, workerId, TheContractorWorker.STATUS.IDLE)
        end
    end
end

-- Completion and payout (022) --------------------------------------------
--
-- Two trigger paths converge on completeJob below: this sweep (server-only,
-- reuses TCJobProgress's poll cadence) catches a player-driven job — one
-- that never transitions to in_progress at all, since that transition is
-- 020's Dispatch, hired-worker-only, so a player just drives normally and
-- 019's completion percentage crossing the finished threshold is the only
-- signal it's done — by scanning allocated jobs too, not just in_progress
-- ones (008's Q25 decoupling means "allocated" already implies resources
-- are assigned and work could be underway). Dispatch.lua's onAIJobStopped
-- is the other path, for an AI-worked job's clean finish.
-- Jobs saved before deadlineDay existed: the next occurrence of their
-- stored period/day. Safe for anything still missable, since the daily
-- check would already have missed it had its day passed. Runs on the first
-- update rather than at load, once the environment's savegame day is
-- certainly in place, and before any client can have joined. Clients get
-- the result through the normal job snapshot (initial client state).
function TheContractorJobs:resolveLegacyDeadlines()
    self.hasLegacyDeadlines = false
    for _, farmJobs in pairs(self.jobsByFarm) do
        for _, job in pairs(farmJobs) do
            if job.deadlineDay == nil then
                job.deadlineDay = TheContractorJobs.getNextOccurrenceDay(job.targetPeriod, job.targetDayInPeriod)
            end
        end
    end
end

function TheContractorJobs:update(dt)
    if not g_currentMission:getIsServer() then
        return
    end

    if self.hasLegacyDeadlines then
        self:resolveLegacyDeadlines()
    end

    self.completionCheckAccumulatedMs = self.completionCheckAccumulatedMs + dt
    if self.completionCheckAccumulatedMs < TCJobProgress.POLL_INTERVAL_MS then
        return
    end
    self.completionCheckAccumulatedMs = 0

    self:checkForCompletions()
end

function TheContractorJobs:checkForCompletions()
    for _, farm in ipairs(g_farmManager:getFarms()) do
        local farmId = farm.farmId
        for _, job in ipairs(self:getJobsByState(farmId, TheContractorJob.STATE.ALLOCATED)) do
            self:completeJob(job)
        end
        for _, job in ipairs(self:getJobsByState(farmId, TheContractorJob.STATE.IN_PROGRESS)) do
            self:completeJob(job)
        end
    end
end

-- Cross-farm lookup by job id alone. Safe because ids are globally unique
-- (008's nextJobId is a single mod-wide counter, not per-farm) - used where
-- a farmId isn't readily at hand, e.g. Dispatch's AI_JOB_STOPPED callback,
-- which only carries the AIJob object/our job id, never which farm it
-- belongs to.
function TheContractorJobs:getJobById(jobId)
    for _, farmJobs in pairs(self.jobsByFarm) do
        local job = farmJobs[jobId]
        if job ~= nil then
            return job
        end
    end
    return nil
end

-- Full (fully-qualified operator) reputation reward before rounding: field
-- area times the job type's reputationPerHa, scaled up for a haulage job
-- (035).
function TheContractorJobs.getBaseReputationReward(job)
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    local field = g_fieldManager:getFieldById(job.fieldId)
    local areaHa = field ~= nil and field:getAreaHa() or 1
    local reputationPerHa = jobDef ~= nil and jobDef.reputationPerHa or 0
    local haulageMultiplier = job.includesHaulage and TheContractorJobGeneration.HAULAGE_REPUTATION_MULTIPLIER or 1
    return reputationPerHa * areaHa * haulageMultiplier
end

-- Reputation reward, scaled by the operator's skill relative to the job's
-- requiredSkillLevel (022's design decision): the player operating
-- personally, or a hired worker who meets/exceeds the requirement, gets the
-- full base reward; an under-qualified-but-still-assignable worker (018
-- already allows this, just warns - see TheContractorAllocation.CAPABILITY.
-- WARN) gets it scaled down linearly by workerSkill/requiredSkillLevel. A
-- job whose equipment carries no size tier at all (e.g. a self-propelled
-- combine with no tractor) has no tier to compare against, so it's treated
-- as always fully qualified, same as TheContractorAllocation:
-- previewWorkerCapability already does for that case.
function TheContractorJobs:calculateReputationReward(job)
    local reward = TheContractorJobs.getBaseReputationReward(job) * self:getReputationQualificationRatio(job)
    return math.max(TheContractorJobs.MIN_COMPLETION_REPUTATION_REWARD, math.floor(reward))
end

-- 1 for a fully-qualified operator (see calculateReputationReward), else
-- workerSkill/requiredSkillLevel. On a two-worker haulage job (035) each
-- worker is judged against their own equipment's tier and the weaker ratio
-- counts.
function TheContractorJobs:getReputationQualificationRatio(job)
    local ratio = self:getWorkerQualificationRatio(job, job.assignedWorkerId, job.assignedEquipmentIds)
    if job.haulerWorkerId ~= nil then
        ratio = math.min(ratio, self:getWorkerQualificationRatio(job, job.haulerWorkerId, job.haulageEquipmentIds))
    end
    return ratio
end

function TheContractorJobs:getWorkerQualificationRatio(job, workerId, equipmentIds)
    if workerId == nil then
        return 1
    end

    local worker = g_currentMission.TheContractor.Staff:getWorker(job.farmId, workerId)
    if worker == nil then
        return 1
    end

    local requiredTier = g_currentMission.TheContractor.Allocation:getRequiredTier(equipmentIds)
    if requiredTier == nil then
        return 1
    end

    local workerSkill = worker:getTierCapability(requiredTier)
    if workerSkill == nil or workerSkill >= job.requiredSkillLevel then
        return 1
    end

    return workerSkill / job.requiredSkillLevel
end

-- Pays the full negotiated price and awards scaled reputation once a job's
-- field work has actually finished (019's completionPercentage crossing
-- COMPLETION_THRESHOLD_PERCENTAGE) - that check doubles as the "cross-
-- checked against 019's completion percentage" guard the ticket calls for
-- on the AI-dispatch trigger path, and as the ordinary idempotency guard
-- against calling this twice for the same job (a second call finds the job
-- already `completed`, which canTransitionTo rejects). No payment reduction
-- for an under-qualified operator (022's design decision) - that's the
-- reputation reward's job, not the price's; only the missed-job case (024)
-- ever pays less than the full negotiated price.
function TheContractorJobs:completeJob(job)
    if not g_currentMission:getIsServer() then
        return
    end

    if job.completionPercentage < TheContractorJobs.COMPLETION_THRESHOLD_PERCENTAGE then
        return
    end

    -- A player-driven haulage job (035) isn't done until the crop has been
    -- delivered, as well as cut.
    if job:needsPlayerDelivery() and job.deliveredLiters < job.requiredLiters then
        return
    end

    if not job:canTransitionTo(TheContractorJob.STATE.COMPLETED) then
        return
    end

    job.paymentAmount = job.price
    g_currentMission:addMoney(job.paymentAmount, job.farmId, MoneyType.TC_JOB_PAYOUT, true, true)

    local reputationReward = self:calculateReputationReward(job)
    g_currentMission.TheContractor.Reputation:addReputation(job.farmId, reputationReward)

    job:transitionTo(TheContractorJob.STATE.COMPLETED)

    -- 023: worker + equipment don't go straight back to idle/available -
    -- they sit in a skill-scaled buffer first (simulating driving back,
    -- unloading, etc.), during which equipment is physically hidden. See
    -- TheContractorCooldown:startCooldown.
    g_currentMission.TheContractor.Cooldown:startCooldown(job)

    TCJobProgress.clearJob(job.id)
    TCHaulage.stopDelivery(job)

    Logging.info("TheContractor: farm %d job %d completed (%s, field %d) - paid %.0f, +%d reputation", job.farmId,
        job.id, job.jobType, job.fieldId, job.paymentAmount, reputationReward)

    if g_server ~= nil then
        g_server:broadcastEvent(TCJobCompletedEvent.new(job))
    end
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
    streamWriteString(streamId, job.fruitTypeName or "")
    streamWriteInt32(streamId, job.deadlineDay or -1)

    streamWriteBool(streamId, job.assignedWorkerId ~= nil)
    if job.assignedWorkerId ~= nil then
        streamWriteInt32(streamId, job.assignedWorkerId)
    end

    streamWriteString(streamId, TheContractorJobs.encodeIdList(job.assignedEquipmentIds))

    streamWriteBool(streamId, job.paymentAmount ~= nil)
    if job.paymentAmount ~= nil then
        streamWriteFloat32(streamId, job.paymentAmount)
    end

    streamWriteBool(streamId, job.isTravelling)

    streamWriteBool(streamId, job.includesHaulage)
    streamWriteBool(streamId, job.haulerWorkerId ~= nil)
    if job.haulerWorkerId ~= nil then
        streamWriteInt32(streamId, job.haulerWorkerId)
    end
    streamWriteString(streamId, TheContractorJobs.encodeIdList(job.haulageEquipmentIds))
    streamWriteString(streamId, job.deliveryStationName or "")
    streamWriteFloat32(streamId, job.requiredLiters)
    streamWriteFloat32(streamId, job.deliveredLiters)
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
    local fruitTypeName = streamReadString(streamId)
    local deadlineDay = streamReadInt32(streamId)

    local job = TheContractorJob.new(id, farmId, jobType, fieldId, requiredSkillLevel, targetPeriod,
        targetDayInPeriod, price)
    job.state = state
    job.completionPercentage = completionPercentage
    job.equipmentAvailable = equipmentAvailable
    job.eagerness = eagerness
    job.negotiationRounds = negotiationRounds
    if fruitTypeName ~= "" then
        job.fruitTypeName = fruitTypeName
    end
    if deadlineDay >= 0 then
        job.deadlineDay = deadlineDay
    end

    if streamReadBool(streamId) then
        job.assignedWorkerId = streamReadInt32(streamId)
    end

    job.assignedEquipmentIds = TheContractorJobs.decodeIdList(streamReadString(streamId))

    if streamReadBool(streamId) then
        job.paymentAmount = streamReadFloat32(streamId)
    end

    job.isTravelling = streamReadBool(streamId)

    job.includesHaulage = streamReadBool(streamId)
    if streamReadBool(streamId) then
        job.haulerWorkerId = streamReadInt32(streamId)
    end
    job.haulageEquipmentIds = TheContractorJobs.decodeIdList(streamReadString(streamId))
    local deliveryStationName = streamReadString(streamId)
    if deliveryStationName ~= "" then
        job.deliveryStationName = deliveryStationName
    end
    job.requiredLiters = streamReadFloat32(streamId)
    job.deliveredLiters = streamReadFloat32(streamId)

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
            job.fruitTypeName = getXMLString(xmlFile, jobKey .. "#fruitType")
            -- nil for saves from before deadlineDay existed — filled in by
            -- resolveLegacyDeadlines on the first update, once the
            -- environment's own savegame day is certainly loaded.
            job.deadlineDay = getXMLInt(xmlFile, jobKey .. "#deadlineDay")
            if job.deadlineDay == nil then
                self.hasLegacyDeadlines = true
            end
            job.assignedWorkerId = getXMLInt(xmlFile, jobKey .. "#assignedWorkerId")
            job.assignedEquipmentIds = TheContractorJobs.decodeIdList(getXMLString(xmlFile,
                jobKey .. "#assignedEquipmentIds"))
            job.paymentAmount = getXMLFloat(xmlFile, jobKey .. "#paymentAmount")
            job.equipmentHome = TCJobSiteSetup.loadHomeFromXML(xmlFile, jobKey .. ".equipmentHome")
            job.transportRemainingMs = getXMLFloat(xmlFile, jobKey .. "#transportRemainingMs")
            job.includesHaulage = Utils.getNoNil(getXMLBool(xmlFile, jobKey .. "#includesHaulage"), false)
            job.haulerWorkerId = getXMLInt(xmlFile, jobKey .. "#haulerWorkerId")
            job.haulageEquipmentIds = TheContractorJobs.decodeIdList(getXMLString(xmlFile,
                jobKey .. "#haulageEquipmentIds"))
            job.deliveryStationUniqueId = getXMLString(xmlFile, jobKey .. ".delivery#stationUniqueId")
            job.deliveryStationIndex = getXMLInt(xmlFile, jobKey .. ".delivery#stationIndex")
            job.deliveryStationName = getXMLString(xmlFile, jobKey .. ".delivery#stationName")
            job.requiredLiters = Utils.getNoNil(getXMLFloat(xmlFile, jobKey .. ".delivery#requiredLiters"), 0)
            job.deliveredLiters = Utils.getNoNil(getXMLFloat(xmlFile, jobKey .. ".delivery#deliveredLiters"), 0)

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
            if job.fruitTypeName ~= nil then
                setXMLString(xmlFile, jobKey .. "#fruitType", job.fruitTypeName)
            end
            if job.deadlineDay ~= nil then
                setXMLInt(xmlFile, jobKey .. "#deadlineDay", job.deadlineDay)
            end

            if job.assignedWorkerId ~= nil then
                setXMLInt(xmlFile, jobKey .. "#assignedWorkerId", job.assignedWorkerId)
            end

            setXMLString(xmlFile, jobKey .. "#assignedEquipmentIds",
                TheContractorJobs.encodeIdList(job.assignedEquipmentIds))

            if job.paymentAmount ~= nil then
                setXMLFloat(xmlFile, jobKey .. "#paymentAmount", job.paymentAmount)
            end

            if job.equipmentHome ~= nil then
                TCJobSiteSetup.saveHomeToXML(xmlFile, jobKey .. ".equipmentHome", job.equipmentHome)
            end

            if job.transportRemainingMs ~= nil then
                setXMLFloat(xmlFile, jobKey .. "#transportRemainingMs", job.transportRemainingMs)
            end

            if job.includesHaulage then
                setXMLBool(xmlFile, jobKey .. "#includesHaulage", true)
                if job.haulerWorkerId ~= nil then
                    setXMLInt(xmlFile, jobKey .. "#haulerWorkerId", job.haulerWorkerId)
                end
                if #job.haulageEquipmentIds > 0 then
                    setXMLString(xmlFile, jobKey .. "#haulageEquipmentIds",
                        TheContractorJobs.encodeIdList(job.haulageEquipmentIds))
                end
                if job.deliveryStationUniqueId ~= nil then
                    setXMLString(xmlFile, jobKey .. ".delivery#stationUniqueId", job.deliveryStationUniqueId)
                    setXMLInt(xmlFile, jobKey .. ".delivery#stationIndex", job.deliveryStationIndex)
                end
                if job.deliveryStationName ~= nil then
                    setXMLString(xmlFile, jobKey .. ".delivery#stationName", job.deliveryStationName)
                end
                setXMLFloat(xmlFile, jobKey .. ".delivery#requiredLiters", job.requiredLiters)
                setXMLFloat(xmlFile, jobKey .. ".delivery#deliveredLiters", job.deliveredLiters)
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
