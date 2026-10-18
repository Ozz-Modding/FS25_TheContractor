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

-- Missed-deadline penalty (026): MISSED_JOB_PENALTY_MULTIPLIER times what
-- the job would have earned on completion (getBaseReputationReward), never
-- less than MIN_MISSED_JOB_REPUTATION_PENALTY, then scaled down by whatever
-- progress the job had made (see missJob). Tied to the job rather than a
-- flat amount so a miss stings the same at every tier - a flat 10 is
-- nothing to a company on thousands of points. Over 1x so taking on work
-- you can't finish is a net loss, not a free roll.
TheContractorJobs.MISSED_JOB_PENALTY_MULTIPLIER = 1.5
TheContractorJobs.MIN_MISSED_JOB_REPUTATION_PENALTY = 10

-- Completion reputation reward (022) is the field's area times the job
-- type's reputationPerHa (JobGeneration's JOB_TYPES), scaled down by
-- operator under-qualification (see calculateReputationReward). Never less
-- than MIN_COMPLETION_REPUTATION_REWARD, so a tiny field still counts.
TheContractorJobs.MIN_COMPLETION_REPUTATION_REWARD = 1

-- A job's field work counts as "finished" once 019's completionPercentage
-- (0-100 scale, already normalized against AbstractMission.SUCCESS_FACTOR by
-- TCJobProgress) reaches this.
TheContractorJobs.COMPLETION_THRESHOLD_PERCENTAGE = 100

-- Quality score (029), 0-100, set on completion (calculateQualityScore): a
-- weighted blend of skill (the crew's qualification ratio, the same one
-- that scales the reputation reward) and reliability (1 minus
-- QUALITY_PENALTY_PER_INTERVENTION for each time 021's watchdog had to step
-- in, floored at 0). The player driving personally always scores 100.
TheContractorJobs.QUALITY_SKILL_WEIGHT = 0.7
TheContractorJobs.QUALITY_RELIABILITY_WEIGHT = 0.3
TheContractorJobs.QUALITY_PENALTY_PER_INTERVENTION = 0.5

-- A two-worker harvest & haul crew (035) is scored on both workers, each
-- for their own part: the combine driver counts for OPERATOR_SCORE_WEIGHT
-- of it, the hauler the rest. The field work matters more.
TheContractorJobs.OPERATOR_SCORE_WEIGHT = 0.6

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
-- (an unloading station object) are optional: harvest & haul (035), bale
-- & deliver and straw delivery (067).
-- startState is the field state the job starts from, for job types that
-- record one (032, JOB_TYPES' startState).
function TheContractorJobs:createJob(farmId, jobType, fieldId, requiredSkillLevel, targetPeriod, targetDayInPeriod,
                                      price, equipmentAvailable, fruitTypeName, deadlineDay, includesHaulage,
                                      deliveryStation, startState)
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
    job.startState = startState
    job.operationSkill = TheContractorJobGeneration.getOperationSkill(jobType, fieldId)
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
        job:setPrice(resultPrice)
        job:transitionTo(TheContractorJob.STATE.ACCEPTED)
    elseif outcome == TheContractorNegotiation.OUTCOME.REJECTED or roundCapHit or eagernessBottomedOut then
        outcome = TheContractorNegotiation.OUTCOME.REJECTED
        job:transitionTo(TheContractorJob.STATE.DECLINED)
    else
        job:setPrice(resultPrice)
    end

    Logging.info("TheContractor: farm %d job %d negotiation round %d -> %s ($%.0f)", farmId, jobId,
        job.negotiationRounds, outcome, job:getPrice())

    if g_server ~= nil then
        g_server:broadcastEvent(TCJobNegotiationUpdatedEvent.new(job))
    end

    return outcome, job:getPrice()
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

-- Server-only, for the tcJob state console command: like
-- transitionJobState, but the final states go the real way - completed
-- through completeJob (forced, so a job part-way through finishes now:
-- the AI stops, it's invoiced, the crew and machines come back) and missed
-- through missJob (the penalty, and everything released). Returns whether
-- the job moved.
function TheContractorJobs:forceJobState(farmId, jobId, newState)
    local job = self:getJob(farmId, jobId)
    if job == nil or not job:canTransitionTo(newState) then
        return false
    end

    if newState == TheContractorJob.STATE.COMPLETED then
        self:completeJob(job, true)
        return job.state == TheContractorJob.STATE.COMPLETED
    elseif newState == TheContractorJob.STATE.MISSED then
        self:missJob(job)
        return true
    end
    return self:transitionJobState(farmId, jobId, newState)
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

-- Server-only (032): puts a job on hold for supplies (status "noStock" or
-- "wrongFill", fillTypeName the product concerned) or takes it off hold
-- (nil), applies locally, then broadcasts - see TCJobSupplies.
function TheContractorJobs:setJobSupplyStatus(job, status, fillTypeName)
    if not g_currentMission:getIsServer() then
        return
    end
    if job.supplyStatus == status and job.supplyFillTypeName == fillTypeName then
        return
    end

    self:applyJobSupplyStatus(job.farmId, job.id, status, fillTypeName)

    if g_server ~= nil then
        g_server:broadcastEvent(TCJobSupplyStatusEvent.new(job.farmId, job.id, status, fillTypeName))
    end
end

-- The actual status change, run on whichever machine (server, or a client
-- receiving TCJobSupplyStatusEvent) is applying it. Going on hold tells the
-- farm's player what's missing, since nothing else moves until they sort
-- it.
function TheContractorJobs:applyJobSupplyStatus(farmId, jobId, status, fillTypeName)
    local job = self:getJob(farmId, jobId)
    if job == nil then
        return
    end

    local wasWaiting = job:isWaitingForSupplies()
    job.supplyStatus = status
    job.supplyFillTypeName = fillTypeName

    if status ~= nil and not wasWaiting and g_client ~= nil and g_currentMission:getFarmId() == farmId and
        isMissableState(job.state) then
        local field = g_fieldManager:getFieldById(job.fieldId)
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            string.format(g_i18n:getText("tc_supplies_onHold"), job:getTypeText(),
                field ~= nil and field:getName() or tostring(job.fieldId), job:getSupplyStatusText()))
    end
end

-- Progress on a serverMeasured job (032), run on a client receiving
-- TCJobProgressEvent - the server keeps its own copy live itself
-- (TCJobProgress).
function TheContractorJobs:applyJobProgress(farmId, jobId, completionPercentage)
    local job = self:getJob(farmId, jobId)
    if job ~= nil then
        job.completionPercentage = completionPercentage
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
    local fullPenalty = math.max(TheContractorJobs.MIN_MISSED_JOB_REPUTATION_PENALTY,
        TheContractorJobs.getBaseReputationReward(job) * TheContractorJobs.MISSED_JOB_PENALTY_MULTIPLIER)
    local penalty = math.floor(fullPenalty * (1 - job.completionPercentage / 100))
    g_currentMission.TheContractor.Reputation:addReputation(job.farmId, -penalty)

    local wasAllocated = job.state ~= TheContractorJob.STATE.ACCEPTED
    self:applyJobStateChanged(job.farmId, job.id, TheContractorJob.STATE.MISSED)

    if g_server ~= nil then
        g_server:broadcastEvent(TCJobStateChangedEvent.new(job.farmId, job.id, TheContractorJob.STATE.MISSED))
    end

    -- 060: into the logbook, while its machines are still where the job
    -- left them.
    g_currentMission.TheContractor.Logbook:recordJobMissed(job, penalty)

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
-- worker goes straight back to idle. Equipment that had left the yard (a
-- dispatch under way, or anything hidden, haulage rig included) goes to
-- the parking return queue (062); a player's own equipment, never hidden,
-- stays where they left it (startCooldown skips a player-driven job too).
function TheContractorJobs:releaseMissedJobResources(job)
    local dispatch = g_currentMission.TheContractor.Dispatch
    local wasDispatched = job.assignedWorkerId ~= nil and dispatch:isJobActive(job)

    dispatch:stopJob(job.id, AIMessageSuccessStoppedByUser.new())
    TCJobProgress.clearJob(job.id)
    TCHaulage.stopDelivery(job)
    TCFieldPreparation.clearUpAfterJob(job)
    self:setJobSupplyStatus(job, nil, nil)

    if job.completionPercentage > 0 then
        g_currentMission.TheContractor.Cooldown:startCooldown(job)
    else
        local parking = g_currentMission.TheContractor.Parking
        if wasDispatched then
            parking:returnVehicles(job.farmId, job:getAllEquipmentIds())
        else
            parking:returnHiddenVehicles(job.farmId, job:getAllEquipmentIds())
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

-- Also where a player-driven job's work start gets recorded (029): nothing
-- dispatches it, so the first field progress seen is the best signal
-- there is. A hired worker's job has normally been marked already, when
-- Dispatch sent them off.
function TheContractorJobs:checkForCompletions()
    for _, farm in ipairs(g_farmManager:getFarms()) do
        local farmId = farm.farmId
        for _, job in ipairs(self:getJobsByState(farmId, TheContractorJob.STATE.ALLOCATED)) do
            if job.completionPercentage > 0 then
                self:markWorkStarted(job)
            end
            self:completeJob(job)
        end
        for _, job in ipairs(self:getJobsByState(farmId, TheContractorJob.STATE.IN_PROGRESS)) do
            self:markWorkStarted(job)
            self:completeJob(job)
        end
    end
end

-- Absolute in-game minutes (monotonic across days/years) - what a job's
-- workStartedAt/completedAt are measured in (029).
function TheContractorJobs.getGameMinutes()
    local environment = g_currentMission.environment
    return environment.currentMonotonicDay * 24 * 60 + environment.dayTime / 60000
end

-- Server-only. First call wins, so it's safe from every path that might
-- see work begin (Dispatch setting off, a resumed/retried dispatch, the
-- completion sweep).
function TheContractorJobs:markWorkStarted(job)
    if not g_currentMission:getIsServer() or job.workStartedAt ~= nil then
        return
    end
    job.workStartedAt = TheContractorJobs.getGameMinutes()
    -- 060: and the condition its machines set off in.
    g_currentMission.TheContractor.Logbook:onWorkStarted(job)
end

-- Job history (029): completed jobs stay in jobsByFarm (and the save) for
-- good, so a worker's history is just the completed jobs they worked on -
-- as operator or as hauler. Per-worker aggregation for a staff-history
-- view builds on these two.
function TheContractorJobs:getCompletedJobsForWorker(farmId, workerId)
    local result = {}
    for _, job in ipairs(self:getJobsByState(farmId, TheContractorJob.STATE.COMPLETED)) do
        for _, id in ipairs(job:getWorkerIds()) do
            if id == workerId then
                table.insert(result, job)
                break
            end
        end
    end
    table.sort(result, function(a, b)
        return (a.completedAt or 0) < (b.completedAt or 0)
    end)
    return result
end

-- Average qualityScore over the worker's completed jobs that have one, and
-- how many that was. nil, 0 for a worker with no scored jobs yet.
function TheContractorJobs:getAverageQualityForWorker(farmId, workerId)
    local total, count = 0, 0
    for _, job in ipairs(self:getCompletedJobsForWorker(farmId, workerId)) do
        if job.qualityScore ~= nil then
            total = total + job.qualityScore
            count = count + 1
        end
    end
    if count == 0 then
        return nil, 0
    end
    return total / count, count
end

-- The farm's most recently completed job with a recorded completion time
-- (029), or nil.
function TheContractorJobs:getLastCompletedJob(farmId)
    local last = nil
    for _, job in ipairs(self:getJobsByState(farmId, TheContractorJob.STATE.COMPLETED)) do
        if job.completedAt ~= nil and (last == nil or job.completedAt > last.completedAt) then
            last = job
        end
    end
    return last
end

-- The allocated/in_progress job holding this vehicle (by network object
-- id) whose work has started, or nil - what TCJobFuel charges fuel to.
function TheContractorJobs:getWorkingJobForVehicle(vehicleId)
    for _, farmJobs in pairs(self.jobsByFarm) do
        for _, job in pairs(farmJobs) do
            if job.workStartedAt ~= nil and (job.state == TheContractorJob.STATE.ALLOCATED or
                    job.state == TheContractorJob.STATE.IN_PROGRESS) then
                for _, id in ipairs(job:getAllEquipmentIds()) do
                    if id == vehicleId then
                        return job
                    end
                end
            end
        end
    end
    return nil
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

-- True while any farm has a non-terminal job (offers included) on the
-- field - what keeps vanilla's NPC fieldwork off it (034, TCFreezeNPCFieldwork).
-- A plain scan rather than a cached set: it only runs once per field per
-- period, plus once per queued NPC task.
function TheContractorJobs:isFieldProtected(fieldId)
    for _, farmJobs in pairs(self.jobsByFarm) do
        for _, job in pairs(farmJobs) do
            if job.fieldId == fieldId and not job:isTerminal() then
                return true
            end
        end
    end
    return false
end

-- Full (fully-qualified operator) reputation reward before rounding: field
-- area times the job type's reputationPerHa, scaled up for a haulage job
-- (035) - not a straw delivery (067), where hauling is the whole job and
-- its reputationPerHa already says so.
function TheContractorJobs.getBaseReputationReward(job)
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    local field = g_fieldManager:getFieldById(job.fieldId)
    local areaHa = field ~= nil and field:getAreaHa() or 1
    local reputationPerHa = jobDef ~= nil and TheContractorJobGeneration.getReputationPerHa(jobDef) or 0
    local isExtraHaulage = job.includesHaulage and not (jobDef ~= nil and jobDef.deliveryOnly)
    local haulageMultiplier = isExtraHaulage and TheContractorJobGeneration.HAULAGE_REPUTATION_MULTIPLIER or 1
    return reputationPerHa * areaHa * haulageMultiplier
end

-- Reputation reward, scaled by the operator's skill relative to the job's
-- requiredSkillLevel (022's design decision): the player operating
-- personally, or a hired worker who meets/exceeds the requirement, gets the
-- full base reward; an under-qualified-but-still-assignable worker (018
-- already allows this, just warns - see TheContractorAllocation.CAPABILITY.
-- WARN) gets it scaled down linearly by workerSkill/requiredSkillLevel,
-- workerSkill being the weaker of their tractor rating and operation skill
-- for the job (044). A job with no tractor (e.g. a self-propelled combine)
-- is judged on the operation skill alone.
-- Trade association members (053) get a little extra on top.
function TheContractorJobs:calculateReputationReward(job)
    local reward = TheContractorJobs.getBaseReputationReward(job) * self:getReputationQualificationRatio(job)
    reward = math.max(TheContractorJobs.MIN_COMPLETION_REPUTATION_REWARD, math.floor(reward))
    return reward + g_currentMission.TheContractor.Association:getReputationBonus(job.farmId, reward)
end

-- 1 for a fully-qualified operator (see calculateReputationReward), else
-- workerSkill/requiredSkillLevel. On a two-worker haulage job (035) each
-- worker is judged against their own equipment's tier and their own
-- operation skill (haulage for the hauler), and the two are blended by
-- OPERATOR_SCORE_WEIGHT.
function TheContractorJobs:getReputationQualificationRatio(job)
    local ratio = self:getWorkerQualificationRatio(job, job.assignedWorkerId, job.assignedEquipmentIds, false)
    if job.haulerWorkerId ~= nil then
        local haulerRatio = self:getWorkerQualificationRatio(job, job.haulerWorkerId, job.haulageEquipmentIds, true)
        local weight = TheContractorJobs.OPERATOR_SCORE_WEIGHT
        ratio = weight * ratio + (1 - weight) * haulerRatio
    end
    return ratio
end

function TheContractorJobs:getWorkerQualificationRatio(job, workerId, equipmentIds, isHauler)
    if workerId == nil then
        return 1
    end

    local worker = g_currentMission.TheContractor.Staff:getWorker(job.farmId, workerId)
    if worker == nil then
        return 1
    end

    local ratings = g_currentMission.TheContractor.Allocation:getWorkerJobRatings(worker, job, equipmentIds,
        isHauler)
    -- Allocation never lets an uncertified worker take the tractor, so a
    -- missing tractor rating here means nothing to judge, not a zero.
    if ratings.tractorRating == nil then
        ratings.tractorTier = nil
    end

    local workerSkill = TheContractorAllocation.getWeakestRating(ratings)
    if workerSkill == nil or workerSkill >= job.requiredSkillLevel then
        return 1
    end

    return workerSkill / job.requiredSkillLevel
end

-- 0-100 (029), see QUALITY_SKILL_WEIGHT. Reuses 022's qualification ratio
-- rather than a second skill formula. 056: an unhappy crew does worse work.
function TheContractorJobs:calculateQualityScore(job)
    local skill = self:getReputationQualificationRatio(job)
    local reliability = math.max(0,
        1 - job.stuckInterventions * TheContractorJobs.QUALITY_PENALTY_PER_INTERVENTION)
    local score = (TheContractorJobs.QUALITY_SKILL_WEIGHT * skill +
        TheContractorJobs.QUALITY_RELIABILITY_WEIGHT * reliability) * TheContractorMorale.getJobQualityMultiplier(job)
    return math.floor(math.max(0, math.min(1, score)) * 100 + 0.5)
end

-- Bills the full negotiated price (an invoice since 049) and awards scaled
-- reputation once a job's
-- field work has actually finished (019's completionPercentage crossing
-- COMPLETION_THRESHOLD_PERCENTAGE) - that check doubles as the "cross-
-- checked against 019's completion percentage" guard the ticket calls for
-- on the AI-dispatch trigger path, and as the ordinary idempotency guard
-- against calling this twice for the same job (a second call finds the job
-- already `completed`, which canTransitionTo rejects). No payment reduction
-- for an under-qualified operator (022's design decision) - that's the
-- reputation reward's job, not the price's; only the missed-job case (024)
-- ever pays less than the full negotiated price.
-- isForced (the tcJob state console command) skips the field-done and
-- delivered checks: everything else happens as on a real finish.
function TheContractorJobs:completeJob(job, isForced)
    if not g_currentMission:getIsServer() then
        return
    end

    if not isForced and job.completionPercentage < TheContractorJobs.COMPLETION_THRESHOLD_PERCENTAGE then
        return
    end

    -- A player-driven haulage job (035) isn't done until the crop has been
    -- delivered, as well as cut - or (067) the straw, as well as baled.
    if not isForced and job:needsPlayerDelivery() and job.deliveredLiters < job.requiredLiters then
        return
    end

    if not job:canTransitionTo(TheContractorJob.STATE.COMPLETED) then
        return
    end

    -- 049: invoiced rather than paid, unless late/unpaid invoices are
    -- switched off - see TheContractorFinances:invoiceJob. Sets
    -- job.invoiceDueDay before the completion broadcast below carries it.
    job.paymentAmount = job:getPrice()
    g_currentMission.TheContractor.Finances:invoiceJob(job)

    local reputationReward = self:calculateReputationReward(job)
    g_currentMission.TheContractor.Reputation:addReputation(job.farmId, reputationReward)

    -- Summary (029): computed here, alongside the payout, and sent to
    -- clients in the TCJobCompletedEvent snapshot below.
    job.completedAt = TheContractorJobs.getGameMinutes()
    job.qualityScore = self:calculateQualityScore(job)

    -- 045: extra wear from skill gaps, dirt, and whether the workers wash
    -- the equipment - before the cooldown (it adds the washing time) and
    -- the broadcast (it carries the reports).
    TCJobConsequences.applyOnCompletion(job)

    -- 052: whether a worker botched it, for a claim a few days later.
    g_currentMission.TheContractor.Claims:rollForJob(job)

    job:transitionTo(TheContractorJob.STATE.COMPLETED)

    -- The progress sweep can complete a job while its AI Helper is still
    -- out: vanilla's field percentage reaches the finished threshold with a
    -- strip still uncut, so the helper carries on. Stopped here, after the
    -- state flip, so the AI_JOB_STOPPED this fires finds the job already
    -- completed (as missJob does). A no-op if the helper stopped itself.
    g_currentMission.TheContractor.Dispatch:stopJob(job.id, AIMessageSuccessFinishedJob.new())

    -- 023: worker + equipment don't go straight back to idle/available -
    -- they sit in a skill-scaled buffer first (simulating driving back,
    -- unloading, etc.), during which equipment is physically hidden. See
    -- TheContractorCooldown:startCooldown.
    g_currentMission.TheContractor.Cooldown:startCooldown(job)

    -- 060: into the logbook - after the cooldown's set up, since its length
    -- is the trip back.
    g_currentMission.TheContractor.Logbook:recordJobCompleted(job, reputationReward)

    TCJobProgress.clearJob(job.id)
    TCHaulage.stopDelivery(job)
    TCFieldPreparation.clearUpAfterJob(job)
    self:setJobSupplyStatus(job, nil, nil)

    Logging.info("TheContractor: farm %d job %d completed (%s, field %d) - billed %.0f, +%d reputation, %s taken, %.0f l fuel (%.0f), quality %d",
        job.farmId, job.id, job.jobType, job.fieldId, job.paymentAmount, reputationReward,
        TheContractorJob.formatMinutes(job:getTimeTakenMinutes()), job.fuelUsedLiters, job.fuelCost,
        job.qualityScore)

    -- The host's own notification - the broadcast below doesn't loop back
    -- to it (see src/events/README.md).
    TCJobCompletedEvent.showNotification(job)

    if g_server ~= nil then
        g_server:broadcastEvent(TCJobCompletedEvent.new(job))
    end

    -- 030: the job's workers may grow from it. After the completion
    -- broadcast so the "job complete" notification comes first.
    g_currentMission.TheContractor.Staff:applyGrowthFromJob(job)

    -- 072: a joyrider plow job may lead to a grass sow job.
    if job.followOnSow then
        g_currentMission.TheContractor.Joyriders:onJobCompleted(job)
    end

    -- 074: maybe a random event at the job's end (the kettle on, paid
    -- early, a worker stepping up). Last, so it follows everything above.
    g_currentMission.TheContractor.RandomEvents:onJobCompleted(job)
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
    streamWriteFloat32(streamId, job.basePrice)
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
    streamWriteFloat32(streamId, job.baseOfferedPrice)

    -- Completion summary (029). -1 stands in for "not recorded".
    streamWriteFloat32(streamId, job.workStartedAt or -1)
    streamWriteFloat32(streamId, job.completedAt or -1)
    streamWriteFloat32(streamId, job.fuelUsedLiters)
    streamWriteFloat32(streamId, job.fuelCost)
    streamWriteInt32(streamId, job.stuckInterventions)
    streamWriteInt32(streamId, job.qualityScore or -1)

    -- 032. -1 stands in for "no start state".
    streamWriteInt32(streamId, job.startState or -1)
    streamWriteString(streamId, job.supplyStatus or "")
    streamWriteString(streamId, job.supplyFillTypeName or "")

    -- 044. getOperationSkill fills it in for a job from an older save.
    streamWriteString(streamId, job:getOperationSkill() or "")

    -- 045.
    TCJobConsequences.writeReports(streamId, job)

    -- 049. -1 stands in for "paid on completion".
    streamWriteInt32(streamId, job.invoiceDueDay or -1)
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
    job.baseOfferedPrice = streamReadFloat32(streamId)

    local workStartedAt = streamReadFloat32(streamId)
    local completedAt = streamReadFloat32(streamId)
    job.workStartedAt = workStartedAt >= 0 and workStartedAt or nil
    job.completedAt = completedAt >= 0 and completedAt or nil
    job.fuelUsedLiters = streamReadFloat32(streamId)
    job.fuelCost = streamReadFloat32(streamId)
    job.stuckInterventions = streamReadInt32(streamId)
    local qualityScore = streamReadInt32(streamId)
    job.qualityScore = qualityScore >= 0 and qualityScore or nil

    local startState = streamReadInt32(streamId)
    job.startState = startState >= 0 and startState or nil
    local supplyStatus = streamReadString(streamId)
    local supplyFillTypeName = streamReadString(streamId)
    job.supplyStatus = supplyStatus ~= "" and supplyStatus or nil
    job.supplyFillTypeName = supplyFillTypeName ~= "" and supplyFillTypeName or nil

    local operationSkill = streamReadString(streamId)
    job.operationSkill = operationSkill ~= "" and operationSkill or nil

    job.workerReports = TCJobConsequences.readReports(streamId)

    local invoiceDueDay = streamReadInt32(streamId)
    job.invoiceDueDay = invoiceDueDay >= 0 and invoiceDueDay or nil

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

            -- Saves from before 026 have no offeredPrice - the current price
            -- (Job.new's default) is the best baseline left.
            job.baseOfferedPrice = Utils.getNoNil(getXMLFloat(xmlFile, jobKey .. "#offeredPrice"),
                job.baseOfferedPrice)
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
            -- Vehicles by uniqueId until resolveSavedVehicles.
            job.savedEquipmentUniqueIds = TCVehicleIds.loadList(xmlFile, jobKey .. ".equipment")
            job.paymentAmount = getXMLFloat(xmlFile, jobKey .. "#paymentAmount")
            job.invoiceDueDay = getXMLInt(xmlFile, jobKey .. "#invoiceDueDay")
            job.transportRemainingMs = getXMLFloat(xmlFile, jobKey .. "#transportRemainingMs")
            job.includesHaulage = Utils.getNoNil(getXMLBool(xmlFile, jobKey .. "#includesHaulage"), false)
            job.haulerWorkerId = getXMLInt(xmlFile, jobKey .. "#haulerWorkerId")
            job.savedHaulageUniqueIds = TCVehicleIds.loadList(xmlFile, jobKey .. ".haulageEquipment")
            job.deliveryStationUniqueId = getXMLString(xmlFile, jobKey .. ".delivery#stationUniqueId")
            job.deliveryStationIndex = getXMLInt(xmlFile, jobKey .. ".delivery#stationIndex")
            job.deliveryStationName = getXMLString(xmlFile, jobKey .. ".delivery#stationName")
            job.requiredLiters = Utils.getNoNil(getXMLFloat(xmlFile, jobKey .. ".delivery#requiredLiters"), 0)
            job.deliveredLiters = Utils.getNoNil(getXMLFloat(xmlFile, jobKey .. ".delivery#deliveredLiters"), 0)
            job.workStartedAt = getXMLFloat(xmlFile, jobKey .. ".summary#workStartedAt")
            job.completedAt = getXMLFloat(xmlFile, jobKey .. ".summary#completedAt")
            job.fuelUsedLiters = Utils.getNoNil(getXMLFloat(xmlFile, jobKey .. ".summary#fuelUsedLiters"), 0)
            job.fuelCost = Utils.getNoNil(getXMLFloat(xmlFile, jobKey .. ".summary#fuelCost"), 0)
            job.stuckInterventions = Utils.getNoNil(getXMLInt(xmlFile, jobKey .. ".summary#stuckInterventions"), 0)
            job.qualityScore = getXMLInt(xmlFile, jobKey .. ".summary#qualityScore")
            job.startState = getXMLInt(xmlFile, jobKey .. "#startState")
            job.keepFieldState = Utils.getNoNil(getXMLBool(xmlFile, jobKey .. "#keepFieldState"), false)
            job.followOnSow = Utils.getNoNil(getXMLBool(xmlFile, jobKey .. "#followOnSow"), false)
            -- 044: nil for a job saved before it existed - getOperationSkill
            -- works it out on first use.
            job.operationSkill = getXMLString(xmlFile, jobKey .. "#operationSkill")
            TCJobConsequences.loadFromXML(xmlFile, jobKey, job)
            job.workTotal = getXMLFloat(xmlFile, jobKey .. "#workTotal")
            local baleIndex = 0
            while true do
                local baleKey = string.format("%s.spawnedBale(%d)", jobKey, baleIndex)
                if not hasXMLProperty(xmlFile, baleKey) then
                    break
                end
                table.insert(job.spawnedBaleIds, getXMLString(xmlFile, baleKey .. "#uniqueId"))
                baleIndex = baleIndex + 1
            end

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

-- Server, once vehicles exist (TheContractor:resolveSavedVehicles): the
-- saved uniqueIds back to object ids, for every job and the equipment
-- data hanging off it.
function TheContractorJobs:resolveSavedVehicles()
    for _, farmJobs in pairs(self.jobsByFarm) do
        for _, job in pairs(farmJobs) do
            if job.savedEquipmentUniqueIds ~= nil then
                job.assignedEquipmentIds = TCVehicleIds.resolveList(job.savedEquipmentUniqueIds)
                job.savedEquipmentUniqueIds = nil
            end
            if job.savedHaulageUniqueIds ~= nil then
                job.haulageEquipmentIds = TCVehicleIds.resolveList(job.savedHaulageUniqueIds)
                job.savedHaulageUniqueIds = nil
            end
            TCJobConsequences.resolveSavedVehicles(job)
        end
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
            setXMLFloat(xmlFile, jobKey .. "#price", job.basePrice)
            setXMLFloat(xmlFile, jobKey .. "#offeredPrice", job.baseOfferedPrice)
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
            if job.startState ~= nil then
                setXMLInt(xmlFile, jobKey .. "#startState", job.startState)
            end
            if job.keepFieldState then
                setXMLBool(xmlFile, jobKey .. "#keepFieldState", true)
            end
            if job.followOnSow then
                setXMLBool(xmlFile, jobKey .. "#followOnSow", true)
            end
            if job.operationSkill ~= nil then
                setXMLString(xmlFile, jobKey .. "#operationSkill", job.operationSkill)
            end
            TCJobConsequences.saveToXML(xmlFile, jobKey, job)
            if job.workTotal ~= nil then
                setXMLFloat(xmlFile, jobKey .. "#workTotal", job.workTotal)
            end
            for i, uniqueId in ipairs(job.spawnedBaleIds) do
                setXMLString(xmlFile, string.format("%s.spawnedBale(%d)#uniqueId", jobKey, i - 1), uniqueId)
            end

            if job.assignedWorkerId ~= nil then
                setXMLInt(xmlFile, jobKey .. "#assignedWorkerId", job.assignedWorkerId)
            end

            TCVehicleIds.saveList(xmlFile, jobKey .. ".equipment", job.assignedEquipmentIds)

            if job.paymentAmount ~= nil then
                setXMLFloat(xmlFile, jobKey .. "#paymentAmount", job.paymentAmount)
            end
            if job.invoiceDueDay ~= nil then
                setXMLInt(xmlFile, jobKey .. "#invoiceDueDay", job.invoiceDueDay)
            end

            if job.transportRemainingMs ~= nil then
                setXMLFloat(xmlFile, jobKey .. "#transportRemainingMs", job.transportRemainingMs)
            end

            if job.includesHaulage then
                setXMLBool(xmlFile, jobKey .. "#includesHaulage", true)
                if job.haulerWorkerId ~= nil then
                    setXMLInt(xmlFile, jobKey .. "#haulerWorkerId", job.haulerWorkerId)
                end
                TCVehicleIds.saveList(xmlFile, jobKey .. ".haulageEquipment", job.haulageEquipmentIds)
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

            -- Completion summary (029) - written once work has started, so
            -- offers and untouched jobs stay compact.
            if job.workStartedAt ~= nil or job.completedAt ~= nil then
                if job.workStartedAt ~= nil then
                    setXMLFloat(xmlFile, jobKey .. ".summary#workStartedAt", job.workStartedAt)
                end
                if job.completedAt ~= nil then
                    setXMLFloat(xmlFile, jobKey .. ".summary#completedAt", job.completedAt)
                end
                setXMLFloat(xmlFile, jobKey .. ".summary#fuelUsedLiters", job.fuelUsedLiters)
                setXMLFloat(xmlFile, jobKey .. ".summary#fuelCost", job.fuelCost)
                setXMLInt(xmlFile, jobKey .. ".summary#stuckInterventions", job.stuckInterventions)
                if job.qualityScore ~= nil then
                    setXMLInt(xmlFile, jobKey .. ".summary#qualityScore", job.qualityScore)
                end
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

-- Console commands (tcJob - see TCConsole) ---------------------------------------------

function TheContractorJobs.registerConsoleCommands()
    -- The ids the other job commands take. Open jobs by default (not yet
    -- completed, declined or missed), or one state, or all. Read-only, so it
    -- works on any machine.
    TCConsole.register("job", "list", {
        args = "[state|all]",
        description = "Your jobs with their ids: open ones, one state, or all",
        serverOnly = false,
        run = function(farmId, args)
            local filter = args[1] ~= nil and string.lower(args[1]) or nil
            local isState = false
            for _, state in pairs(TheContractorJob.STATE) do
                isState = isState or state == filter
            end
            if filter ~= nil and filter ~= "all" and not isState then
                return false
            end

            local staff = g_currentMission.TheContractor.Staff
            local jobs = {}
            for _, job in ipairs(g_currentMission.TheContractor.Jobs:getAllJobs(farmId)) do
                if (filter == nil and not job:isTerminal()) or filter == "all" or job.state == filter then
                    table.insert(jobs, job)
                end
            end
            if #jobs == 0 then
                return string.format("Farm %d has no %s jobs.", farmId, filter or "open")
            end
            table.sort(jobs, function(a, b)
                return a.id < b.id
            end)

            local lines = { string.format("Farm %d jobs (%s, today is day %d):", farmId, filter or "open",
                g_currentMission.environment.currentMonotonicDay) }
            for _, job in ipairs(jobs) do
                local details = {}
                if job.state == TheContractorJob.STATE.IN_PROGRESS or job.completionPercentage > 0 then
                    table.insert(details, string.format("%.0f%% done", job.completionPercentage))
                end
                if job.deadlineDay ~= nil then
                    table.insert(details, string.format("due %s (day %d)", TCCalendar.formatDay(job.deadlineDay),
                        job.deadlineDay))
                end
                if job.state == TheContractorJob.STATE.ALLOCATED or job.state == TheContractorJob.STATE.IN_PROGRESS then
                    local crew = {}
                    for _, workerId in ipairs(job:getWorkerIds()) do
                        local worker = staff:getWorker(farmId, workerId)
                        table.insert(crew, worker ~= nil and worker.name or ("#" .. workerId))
                    end
                    table.insert(details, #crew > 0 and ("crew " .. table.concat(crew, ", ")) or "you")
                end
                local field = g_fieldManager:getFieldById(job.fieldId)
                table.insert(lines, string.format("#%d %s, field %s - %s, %s%s", job.id, job:getDisplayTitle(),
                    field ~= nil and field:getName() or tostring(job.fieldId), job.state,
                    g_i18n:formatMoney(job:getPrice(), 0, true, true),
                    #details > 0 and (", " .. table.concat(details, ", ")) or ""))
            end
            return table.concat(lines, "\n")
        end,
    })

    -- Nothing checked: the field needn't suit the type, nor the date be workable.
    TCConsole.register("job", "create", {
        args = "<jobType> <fieldId> <skill 1-10> <price> <period 1-12> <day>",
        description = "Create a job with every detail set by hand, unchecked",
        run = function(farmId, args)
            local jobType = args[1]
            local fieldId, skill, price = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
            local targetPeriod, targetDay = tonumber(args[5]), tonumber(args[6])
            if jobType == nil or fieldId == nil or skill == nil or price == nil or targetPeriod == nil or
                targetDay == nil then
                return false
            end

            -- Typed at the current price level; jobs store it without
            -- FS25_EconomyScale's factor (TheContractorJob:getPrice).
            g_client:getServerConnection():sendEvent(TCDebugCreateJobEvent.new(farmId, jobType, fieldId, skill,
                targetPeriod, targetDay, price / TCEconomyScale.getFactor()))
            return string.format("Requested job creation for farm %d", farmId)
        end,
    })

    TCConsole.register("job", "state", {
        args = "<jobId> <state>",
        description = "Force a job into another state (legal transitions only)",
        run = function(farmId, args)
            local jobId, state = tonumber(args[1]), args[2] ~= nil and string.lower(args[2]) or nil
            if jobId == nil then
                return false
            end

            local job = g_currentMission.TheContractor.Jobs:getJob(farmId, jobId)
            if job == nil then
                return string.format("Farm %d has no job %d. tcJob list shows their ids.", farmId, jobId)
            end
            -- No state, or one it can't go to from here: say where it can go.
            if state == nil or not job:canTransitionTo(state) then
                local nextStates = {}
                for nextState in pairs(TheContractorJob.VALID_TRANSITIONS[job.state] or {}) do
                    table.insert(nextStates, nextState)
                end
                table.sort(nextStates)
                local prefix = state ~= nil and string.format("Job %d can't go from %s to %s. ", jobId, job.state,
                    state) or ""
                if #nextStates == 0 then
                    return string.format("%sJob %d is %s, which is final.", prefix, jobId, job.state)
                end
                return string.format("%sJob %d is %s. It can go to: %s", prefix, jobId, job.state,
                    table.concat(nextStates, ", "))
            end

            g_client:getServerConnection():sendEvent(TCDebugSetJobStateEvent.new(farmId, jobId, state))
            return string.format("Requested job %d -> %s for farm %d", jobId, state, farmId)
        end,
    })
end
