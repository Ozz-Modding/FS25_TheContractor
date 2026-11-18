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
-- type's reputationPerHa (JobGeneration's JOB_TYPES), scaled by the job's
-- quality score (080, see getQualityReputationFactor): the full reward only
-- at 100, none at REPUTATION_ZERO_QUALITY, and a loss below it. A reward
-- is never less than MIN_COMPLETION_REPUTATION_REWARD, so a tiny field
-- still counts.
TheContractorJobs.MIN_COMPLETION_REPUTATION_REWARD = 1
TheContractorJobs.REPUTATION_ZERO_QUALITY = 50

-- A job's field work counts as "finished" once 019's completionPercentage
-- (0-100 scale, already normalized against the fieldWorkDone setting by
-- TCJobProgress.getSuccessFactor) reaches this.
TheContractorJobs.COMPLETION_THRESHOLD_PERCENTAGE = 100

-- 076: that threshold leaves a strip unworked (vanilla's SUCCESS_FACTOR
-- leniency), and players like to finish the field off. A player-driven
-- job's field stays workable this long after it completes (TCFieldAccess),
-- in real time while the game runs (mod updates stop while it's paused),
-- and the bales the job leaves are only cleared up once it's over.
TheContractorJobs.GRACE_PERIOD_MS = 10 * 60 * 1000

-- Quality score (029, reworked by 080), 0-100, set on completion
-- (calculateQualityScore). A hired crew's score is the product of five
-- factors, each 0-1, so 100 needs every one of them at its best:
--   skill        headroom over the job's requiredSkillLevel on the crew's
--                weakest rating (getSkillFactorFor): QUALITY_SKILL_BY_MARGIN
--                for 0-3+ points over; under it, the at-level factor times
--                (0.5 + 0.5 x rating / required)
--   reliability  1 less QUALITY_PENALTY_PER_INTERVENTION for each time 021's
--                watchdog had to step in, floored at QUALITY_RELIABILITY_FLOOR
--   morale       TheContractorMorale.getJobQualityMultiplier (056)
--   condition    the worst damage on the job's equipment when it set off
--                (045's startCondition): 1 up to QUALITY_DAMAGE_ALLOWANCE,
--                falling to 1 - QUALITY_CONDITION_PENALTY at full damage
--   form         the crew's day, min(1, QUALITY_FORM_MIN + QUALITY_FORM_RANGE
--                x random): exactly 1 one time in six
-- An ordinary qualified crew scores in the low 80s, a perfect one 100 about
-- one job in five. The player driving personally always scores 100.
TheContractorJobs.QUALITY_SKILL_BY_MARGIN = { [0] = 0.90, [1] = 0.94, [2] = 0.97, [3] = 1.00 }
TheContractorJobs.QUALITY_MAX_MARGIN = 3
TheContractorJobs.QUALITY_PENALTY_PER_INTERVENTION = 0.15
TheContractorJobs.QUALITY_RELIABILITY_FLOOR = 0.55
TheContractorJobs.QUALITY_DAMAGE_ALLOWANCE = 0.1
TheContractorJobs.QUALITY_CONDITION_PENALTY = 0.1
TheContractorJobs.QUALITY_FORM_MIN = 0.90
TheContractorJobs.QUALITY_FORM_RANGE = 0.12

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

    -- 076: jobId -> job for completed jobs still in their grace period, so
    -- the countdown doesn't walk every job ever completed. Kept on every
    -- machine (registerJob, loadFromXMLFile, completeJob).
    self.graceJobs = {}

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
-- record one (032, JOB_TYPES' startState). workshop (100) is a workshop
-- job's customer machine and contract (TheContractorRepairContracts), whose
-- fieldId is 0. spill (106) is a spilt crop's job.spill (TheContractorCropSpill).
-- yardDelivery (124) is a yard bale job's job.yardDelivery
-- (TheContractorYardBales); its litres are the job's requiredLiters.
-- yardHaul (126) is a farmer's load to sell's job.yardHaul
-- (TheContractorYardHaul), a haulage job to deliveryStation. refuel (127)
-- is a farmer's machine run dry's job.refuel (TheContractorEmergencyRefuel).
-- readyDay (132) is the first day the job can be worked (Job.readyDay), nil
-- for ready now. auctionId (141) is an attend job's auction (Job.auctionId).
-- lotInspection (152) is an auction lot to inspect's (TCLotInspections).
-- offerSource is what brought an hourly-roll offer (Job.offerSource).
function TheContractorJobs:createJob(farmId, jobType, fieldId, requiredSkillLevel, targetPeriod, targetDayInPeriod,
                                      price, equipmentAvailable, fruitTypeName, deadlineDay, includesHaulage,
                                      deliveryStation, startState, workshop, spill, yardDelivery, yardHaul, refuel,
                                      readyDay, auctionId, lotInspection, offerSource)
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
    job.readyDay = readyDay
    if includesHaulage and deliveryStation ~= nil then
        job.includesHaulage = true
        TCHaulage.setDeliveryStation(job, deliveryStation)
    end
    job.workshop = workshop
    job.spill = spill
    job.yardDelivery = yardDelivery
    if yardDelivery ~= nil then
        job.requiredLiters = yardDelivery.liters or 0
    end
    job.yardHaul = yardHaul
    job.refuel = refuel
    job.auctionId = auctionId
    job.lotInspection = lotInspection
    job.offerSource = offerSource
    -- 110: after workshop, spill, the yard jobs, a refuel and a lot
    -- inspection, which decide it.
    local farmers = g_currentMission.TheContractor.Farmers
    if farmers ~= nil then
        job.customerId = farmers:getCustomerIdForJob(job)
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

    -- 076: a client's copy is replaced by each snapshot, so this keeps the
    -- countdown on the latest one.
    self.graceJobs[job.id] = job.graceRemainingMs ~= nil and job or nil

    -- 100: a customer's machine joins the ones kept out of our lists.
    if job.workshop ~= nil then
        TheContractorRepairContracts.clearCache()
    end

    TCLog.info("TheContractor: farm %d created job %d (%s)", job.farmId, job.id, job.jobType)

    if isNewArrival ~= false and job.state == TheContractorJob.STATE.OFFERED then
        local tc = g_currentMission.TheContractor
        if tc.InboxHUD ~= nil then
            tc.InboxHUD:onJobOffered(job)
        end
        -- 106: a spilt crop's urgent job says so as it arrives.
        if job.spill ~= nil then
            TheContractorCropSpill.showNotification(job)
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

    -- 102: a workshop job's price is agreed through its own quote
    -- (RepairContracts:proposeQuote), not 014's rounds.
    if TheContractorRepairContracts.isWorkshopJob(job) or TheContractorJobs.getAcceptProblem(job) ~= nil then
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
        self:onJobAccepted(job)
    elseif outcome == TheContractorNegotiation.OUTCOME.REJECTED or roundCapHit or eagernessBottomedOut then
        outcome = TheContractorNegotiation.OUTCOME.REJECTED
        job:transitionTo(TheContractorJob.STATE.DECLINED)
        self:onJobDeclined(job, TheContractorRelationships.DECLINE_REASON.WALKED_AWAY)
    else
        job:setPrice(resultPrice)
    end

    TCLog.info("TheContractor: farm %d job %d negotiation round %d -> %s ($%.0f)", farmId, jobId,
        job.negotiationRounds, outcome, job:getPrice())

    if g_server ~= nil then
        g_server:broadcastEvent(TCJobNegotiationUpdatedEvent.new(job))
    end

    return outcome, job:getPrice()
end

-- Validates the transition against the job's state machine, applies
-- locally, then broadcasts to other clients. Only the server may drive
-- transitions. playerName (107): who accepted it, for a job that's
-- allocated to its players as it's accepted (allocateOnAccept).
-- declineReason (113): how an offer going to declined ended, a
-- TheContractorRelationships.DECLINE_REASON (nil: the player declined it).
function TheContractorJobs:transitionJobState(farmId, jobId, newState, playerName, declineReason)
    if not g_currentMission:getIsServer() then
        return false
    end

    local job = self:getJob(farmId, jobId)
    if job == nil or not job:canTransitionTo(newState) then
        return false
    end
    if newState == TheContractorJob.STATE.ACCEPTED and TheContractorJobs.getAcceptProblem(job) ~= nil then
        return false
    end

    self:applyJobStateChanged(farmId, jobId, newState)

    if g_server ~= nil then
        g_server:broadcastEvent(TCJobStateChangedEvent.new(farmId, jobId, newState))
    end

    if newState == TheContractorJob.STATE.DECLINED then
        self:onJobDeclined(job, declineReason)
    elseif newState == TheContractorJob.STATE.ACCEPTED then
        self:onJobAccepted(job, playerName)
    end

    return true
end

-- Why an offer can't be accepted (or a price agreed) now, as text, or nil.
-- Only a workshop job (100) can be refused: its machine's gone, or ADS is
-- (102: missing tools only warn). The same on every machine: the Inbox
-- shows it, the server re-checks.
function TheContractorJobs.getAcceptProblem(job)
    if job == nil or job.workshop == nil then
        return nil
    end
    return TheContractorRepairContracts.getAcceptProblem(job)
end

-- Server: an offer's just been accepted. 100: a customer's machine that's
-- already been put right counts at once (ADS only says when it changes).
-- 102: ADS lets the work start (proposeQuote has already; this covers
-- tcJob state, and costs nothing twice). 107: a job that's allocated to
-- the farm's players as it's taken on (allocateOnAccept) is, under the
-- name of whoever accepted it (nil: "A player").
function TheContractorJobs:onJobAccepted(job, playerName)
    -- The offer's message (a fallen tree's, a farmer's call) has done its job.
    g_currentMission.TheContractor.Inbox:removeMessagesForJob(job.farmId, job.id)
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    if jobDef ~= nil and jobDef.allocateOnAccept and
            not g_currentMission.TheContractor.Allocation:allocateJob(job.farmId, job.id, {}, {}, {}, nil, playerName) then
        TCLog.warning("TheContractor: farm %d job %d (%s) couldn't be allocated to the farm's players as it was accepted",
            job.farmId, job.id, job.jobType)
    end
    if job.workshop ~= nil then
        local vehicle = TheContractorRepairContracts.getVehicle(job)
        if vehicle ~= nil then
            TCADSRepairContracts.authorize(vehicle)
        end
        g_currentMission.TheContractor.RepairContracts:checkJob(job)
    end
    -- 124: the farmer gets their telehandler out.
    if job.yardDelivery ~= nil then
        g_currentMission.TheContractor.YardBales:onJobAccepted(job)
    end
    -- 126: and their trailer, full.
    if job.yardHaul ~= nil then
        g_currentMission.TheContractor.YardHaul:onJobAccepted(job)
    end
    -- 127: and their machine, run dry on the field.
    if job.refuel ~= nil then
        g_currentMission.TheContractor.EmergencyRefuel:onJobAccepted(job)
    end
end

-- Server: an offer turned down, run out or walked away from in negotiation.
-- Anything laid out for it before it was even taken (075's fly-tipped pile)
-- goes - the farmer has found someone else. reason (113): a
-- TheContractorRelationships.DECLINE_REASON, nil for a plain decline; the
-- customer's relationship drops by it, and (148) the farm's reputation by
-- the job type's declineReputation.
function TheContractorJobs:onJobDeclined(job, reason)
    g_currentMission.TheContractor.Relationships:onJobDeclined(job, reason)
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    if jobDef ~= nil and jobDef.declineReputation ~= nil then
        g_currentMission.TheContractor.Reputation:addReputation(job.farmId, -jobDef.declineReputation)
    end
    TCFieldPreparation.clearUpAfterJob(job)
    g_currentMission.TheContractor.Inbox:removeMessagesForJob(job.farmId, job.id)
    -- 100: the customer takes their machine elsewhere.
    if job.workshop ~= nil then
        g_currentMission.TheContractor.RepairContracts:queueCollection(job)
    end
end

-- Server-only, for the tcJob state console command: like
-- transitionJobState, but the final states go the real way - completed
-- through completeJob (forced, so a job part-way through finishes now:
-- the AI stops, it's invoiced, the crew and machines come back) and missed
-- through missJob (the penalty, and everything released), and accepted
-- from allocated or in progress through unallocateJob (094). Returns
-- whether the job moved.
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
    elseif newState == TheContractorJob.STATE.ACCEPTED and job.state ~= TheContractorJob.STATE.OFFERED and
        job.state ~= TheContractorJob.STATE.NEGOTIATING then
        -- 094: back from allocated or in progress is an unallocate.
        return self:unallocateJob(farmId, jobId)
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
        TCLog.info("TheContractor: farm %d job %d is now %s", farmId, jobId, newState)
        -- 100: a workshop job's turnaround counts from here (its speed
        -- reputation). Stamped on every machine as the change arrives.
        if newState == TheContractorJob.STATE.ACCEPTED and job.workshop ~= nil then
            job.workshop.acceptedAt = TheContractorJobs.getGameMinutes()
        end
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
function TheContractorJobs:applyJobDelivery(farmId, jobId, deliveredLiters, requiredLiters, stationName)
    local job = self:getJob(farmId, jobId)
    if job == nil then
        return
    end

    -- 162: the station can change when delivery starts; nil leaves it.
    if stationName ~= nil then
        job.deliveryStationName = stationName
    end

    local wasDelivered = job.requiredLiters > 0 and job.deliveredLiters >= job.requiredLiters
    job.deliveredLiters = deliveredLiters
    job.requiredLiters = requiredLiters

    local isDelivered = requiredLiters > 0 and deliveredLiters >= requiredLiters
    -- 124, 126: a yard job completes as it's delivered, which says so.
    if isDelivered and not wasDelivered and not job:isYardJob() and g_client ~= nil and
            g_currentMission:getFarmId() == farmId then
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
-- reputation hit (only the customer's relationship, 113), and it stops a stale offer being accepted only to fail
-- at the very next day change.
function TheContractorJobs:onDayChanged()
    local today = g_currentMission.environment.currentMonotonicDay

    for farmId, farmJobs in pairs(self.jobsByFarm) do
        for _, job in pairs(farmJobs) do
            local isOffer = job.state == TheContractorJob.STATE.OFFERED or job.state == TheContractorJob.STATE.NEGOTIATING
            if isOffer and job.workshop ~= nil and job.workshop.offerExpiresDay ~= nil and
                    today > job.workshop.offerExpiresDay then
                -- 100: a workshop offer lapses before its job would be due.
                self:transitionJobState(farmId, job.id, TheContractorJob.STATE.DECLINED, nil,
                    TheContractorRelationships.DECLINE_REASON.LAPSED)
            elseif job.deadlineDay ~= nil and today > job.deadlineDay then
                if isMissableState(job.state) then
                    self:missJob(job)
                elseif job.state == TheContractorJob.STATE.OFFERED or job.state == TheContractorJob.STATE.NEGOTIATING then
                    self:transitionJobState(farmId, job.id, TheContractorJob.STATE.DECLINED, nil,
                        TheContractorRelationships.DECLINE_REASON.LAPSED)
                end
            end
        end
    end
end

-- The absolute (monotonic) day of the next time the calendar reads
-- period/dayInPeriod, today included. Assumes it's within the coming year,
-- which is all a yearless period/day can express.
function TheContractorJobs.getNextOccurrenceDay(period, dayInPeriod)
    return TCCalendar.getNextOccurrenceDay(period, dayInPeriod)
end

-- Calendar changes (160) ------------------------------------------------------
-- A job's deadline and ready day are monotonic days. When the days per month
-- changes, TCCalendarChange has every live job's days moved to the same date
-- (remapDates, on every machine), with its target date and a workshop
-- offer's expiry; its offer messages move through the Inbox's own
-- remapDates. An attend-the-auction job (141) follows its auction's day
-- instead (TheContractorAuctions:remapDates).

local function isDatedJob(job)
    return not job:isTerminal() and job.auctionId == nil
end

-- Every machine: each live job's days moved from one calendar to the other.
-- Its deadline keeps the end of its share of the month, its ready day the
-- start (TCCalendar.remapDay), never past the deadline. Its target date is
-- read off the new calendar as given, not this machine's, which may not
-- have taken the change up yet.
function TheContractorJobs:remapDates(fromModel, toModel)
    for _, farmJobs in pairs(self.jobsByFarm) do
        for _, job in pairs(farmJobs) do
            if isDatedJob(job) then
                local deadlineDay = TCCalendar.remapDay(job.deadlineDay, fromModel, toModel, true)
                local readyDay = TCCalendar.remapDay(job.readyDay, fromModel, toModel, false)
                if deadlineDay ~= nil and readyDay ~= nil and readyDay > deadlineDay then
                    readyDay = deadlineDay
                end
                if deadlineDay ~= job.deadlineDay or readyDay ~= job.readyDay then
                    TCLog.info("TheContractor: farm %d job %d dates moved: due day %s, ready day %s", job.farmId,
                        job.id, tostring(deadlineDay), tostring(readyDay))
                end
                job.deadlineDay = deadlineDay
                job.readyDay = readyDay
                if deadlineDay ~= nil then
                    local periodIndex, dayInPeriod = TCCalendar.getDayInfo(deadlineDay, toModel)
                    job.targetPeriod = (periodIndex - 1) % Environment.PERIODS_IN_YEAR + 1
                    job.targetDayInPeriod = dayInPeriod
                end
                -- 100: a workshop offer lapses the day before its job's due.
                if job.workshop ~= nil and job.workshop.offerExpiresDay ~= nil then
                    job.workshop.offerExpiresDay = TCCalendar.remapDay(job.workshop.offerExpiresDay, fromModel,
                        toModel, true)
                end
            end
        end
    end
end

local function makeDatesChange(job, deadlineDay, readyDay)
    if deadlineDay ~= nil and readyDay ~= nil and readyDay > deadlineDay then
        readyDay = deadlineDay
    end
    if deadlineDay == job.deadlineDay and readyDay == job.readyDay then
        return nil
    end
    return {
        farmId = job.farmId,
        jobId = job.id,
        deadlineDay = deadlineDay,
        readyDay = readyDay,
        targetPeriod = deadlineDay ~= nil and TCCalendar.getPeriodFromDay(deadlineDay) or job.targetPeriod,
        targetDayInPeriod = deadlineDay ~= nil and TCCalendar.getDayInPeriodFromDay(deadlineDay) or
            job.targetDayInPeriod,
    }
end

-- A save from before 160 has no calendar for its jobs, so a job dated before
-- a change still has its old day. Its target date (worked out with its
-- deadline, at the days per period of the time) says what was agreed: a job
-- whose deadline's no longer in its target month gets the end of that month
-- (its next one, if it's within half a year; one further off has gone by,
-- so it's left alone). The day within the month can't be told apart from a
-- change, so it's only the month that's put right.
function TheContractorJobs:getLegacyDateRepairs()
    local today = g_currentMission.environment.currentMonotonicDay
    local currentIndex = TCCalendar.getPeriodIndex()
    local changes = {}
    for _, farmJobs in pairs(self.jobsByFarm) do
        for _, job in pairs(farmJobs) do
            if isDatedJob(job) and job.deadlineDay ~= nil and job.deadlineDay >= today and job.targetPeriod ~= nil and
                    TCCalendar.getPeriodFromDay(job.deadlineDay) ~= job.targetPeriod then
                local monthsAhead = (job.targetPeriod - TCCalendar.getPeriodFromDay(today)) %
                    Environment.PERIODS_IN_YEAR
                if monthsAhead <= Environment.PERIODS_IN_YEAR / 2 then
                    local deadlineDay = TCCalendar.getMonotonicDay(currentIndex + monthsAhead, math.huge)
                    local change = makeDatesChange(job, deadlineDay, job.readyDay)
                    if change ~= nil then
                        table.insert(changes, change)
                    end
                end
            end
        end
    end
    table.sort(changes, function(a, b) return a.jobId < b.jobId end)
    return changes
end

-- Server, first update after loading a save from before 160
-- (TCCalendarChange.update): its jobs' months put right, and the clients
-- told.
function TheContractorJobs:repairLegacyDates()
    local changes = self:getLegacyDateRepairs()
    if #changes == 0 then
        return
    end
    for _, change in ipairs(changes) do
        TCLog.info("TheContractor: farm %d job %d put back in its month: due day %d", change.farmId, change.jobId,
            change.deadlineDay)
    end
    self:applyJobDates(changes)
    if g_server ~= nil then
        g_server:broadcastEvent(TCJobDatesChangedEvent.new(changes))
    end
end

-- Every machine: a job's new deadline, ready day and target date, and its
-- offer messages' expiry with them (the day after the deadline,
-- Inbox:getJobExpiryDay).
function TheContractorJobs:applyJobDates(changes)
    local inbox = g_currentMission.TheContractor.Inbox
    for _, change in ipairs(changes) do
        local job = self:getJob(change.farmId, change.jobId)
        if job ~= nil then
            local oldDeadlineDay = job.deadlineDay
            job.deadlineDay = change.deadlineDay
            job.readyDay = change.readyDay
            job.targetPeriod = change.targetPeriod
            job.targetDayInPeriod = change.targetDayInPeriod
            if inbox ~= nil then
                inbox:moveJobExpiry(change.farmId, change.jobId, oldDeadlineDay, change.deadlineDay)
            end
        end
    end
end

-- Reputation loss scales down by whatever completion progress the job had
-- (per the ticket's design decision). No payment, per the ticket's explicit
-- "harsh version first" call. The state flips to `missed` before anything
-- is released, so the AI_JOB_STOPPED that Dispatch:stopJob fires
-- synchronously (AISystem:stopJobInternal) hits an already-terminal job in
-- Dispatch:onAIJobStopped -> completeJob and no-ops there, rather than
-- racing a payout.
-- noPenalty (100): a workshop job whose machine ADS stopped managing ends
-- with nothing lost.
function TheContractorJobs:missJob(job, noPenalty)
    -- 141: a reminder (JOB_TYPES' noConsequences) just ends.
    if TheContractorJobs.hasNoConsequences(job) then
        self:endWithoutConsequences(job, TheContractorJob.STATE.MISSED)
        return
    end
    -- 126: whether a farmer's load went astray, while the trailer's still
    -- where it was left.
    if job.yardHaul ~= nil and not noPenalty then
        g_currentMission.TheContractor.YardHaul:judgeMiss(job)
    end
    -- Reputation.lua's score is otherwise always an integer (tier thresholds,
    -- %d display formatting) — floor this rather than let a partial-progress
    -- job leave a fractional score behind.
    local fullPenalty = math.max(TheContractorJobs.MIN_MISSED_JOB_REPUTATION_PENALTY,
        TheContractorJobs.getBaseReputationReward(job) * TheContractorJobs.MISSED_JOB_PENALTY_MULTIPLIER)
    local penalty = math.floor(fullPenalty * (1 - job.completionPercentage / 100))
    if noPenalty then
        penalty = 0
    elseif job.spill ~= nil then
        -- 106: the lot, whatever was delivered.
        penalty = TheContractorCropSpill.getMissPenalty(job)
    elseif job.workshop ~= nil then
        -- 100: judged as the customer comes for it - worse than it arrived
        -- costs more, and maybe a claim.
        penalty = g_currentMission.TheContractor.RepairContracts:judgeTampering(job, penalty)
    elseif job.yardHaul ~= nil then
        -- 126: and far more if the load was taken.
        penalty = penalty + TheContractorYardHaul.getTheftPenalty(job)
    end
    g_currentMission.TheContractor.Reputation:addReputation(job.farmId, -penalty)
    -- 113: the customer remembers (a workshop job has none).
    if not noPenalty then
        g_currentMission.TheContractor.Relationships:onJobMissed(job)
    end

    local wasAllocated = job.state ~= TheContractorJob.STATE.ACCEPTED
    self:applyJobStateChanged(job.farmId, job.id, TheContractorJob.STATE.MISSED)

    if g_server ~= nil then
        g_server:broadcastEvent(TCJobStateChangedEvent.new(job.farmId, job.id, TheContractorJob.STATE.MISSED))
    end

    -- 060: into the logbook, while its machines are still where the job
    -- left them.
    g_currentMission.TheContractor.Logbook:recordJobMissed(job, penalty)

    -- 106: the council clears the road, and a claim may follow (on the
    -- entry just written).
    if job.spill ~= nil then
        g_currentMission.TheContractor.CropSpill:onJobMissed(job)
    end
    -- 126: a taken load's claim (on the same entry), and the farmer's
    -- opinion of it.
    if job.yardHaul ~= nil and not noPenalty then
        g_currentMission.TheContractor.YardHaul:onJobMissed(job)
    end

    if wasAllocated then
        self:releaseMissedJobResources(job)
    else
        -- Nothing to release, but whatever was laid out for it (075's
        -- fly-tipped pile) still goes.
        TCFieldPreparation.clearUpAfterJob(job)
    end
    g_currentMission.TheContractor.Inbox:removeMessagesForJob(job.farmId, job.id)
    -- 100: the customer takes their machine back as it is.
    if job.workshop ~= nil then
        g_currentMission.TheContractor.RepairContracts:queueCollection(job)
    end

    TCJobMissedEvent.showNotification(job.farmId, job.jobType, job.fieldId, job:getTypeLabel())

    if g_server ~= nil then
        g_server:broadcastEvent(TCJobMissedEvent.new(job.farmId, job.jobType, job.fieldId, job:getTypeLabel()))
    end

    TCLog.info("TheContractor: farm %d job %d missed its deadline (%s, field %d, %.0f%% done, penalty -%d reputation)",
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
    self:releaseJobResources(job)
    TCFieldPreparation.clearUpAfterJob(job)
end

-- What a miss (above) and an unallocate (094) both do with a job's crew and
-- equipment. Leaves the field alone - an unallocated job still needs its
-- bales, windrow or pile for whoever's next.
function TheContractorJobs:releaseJobResources(job)
    local dispatch = g_currentMission.TheContractor.Dispatch
    local wasDispatched = job.assignedWorkerId ~= nil and dispatch:isJobActive(job)

    dispatch:stopJob(job.id, AIMessageSuccessStoppedByUser.new())
    dispatch:takeRanOutOfFill(job.id)
    TCJobProgress.clearJob(job.id)
    TCHaulage.stopDelivery(job)
    TCHaulage.emptyHarvestersAfterJob(job)
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

-- Unallocating (094) -----------------------------------------------------

-- Why a job can't be unallocated right now, as an l10n key, or nil if it
-- can. The same on every machine, from synced state: the menu hides the
-- button with it, the server re-checks with it.
function TheContractorJobs.getUnallocateProblem(job)
    if job == nil then
        return "tc_unallocate_problemGone"
    end
    -- 106: a spill is the farm's own to clear up.
    if job.spill ~= nil then
        return "tc_unallocate_problemSpill"
    end
    if job.state ~= TheContractorJob.STATE.ALLOCATED and job.state ~= TheContractorJob.STATE.IN_PROGRESS then
        return "tc_unallocate_problemState"
    end
    return nil
end

-- Server: takes the crew and equipment off an allocated or in-progress job
-- and puts it back to `accepted`, for someone else to be allocated. The
-- crew and kit go back the way a missed job's do (releaseJobResources):
-- into cooldown if any work got done, else straight back (the kit through
-- the parking queue if it had left the yard). The field and its progress
-- stay as they are, and wasUnallocated tells the next allocation to carry
-- on from them. No reputation lost: the deadline still stands. Returns
-- whether it went through.
function TheContractorJobs:unallocateJob(farmId, jobId)
    if not g_currentMission:getIsServer() then
        return false
    end

    local job = self:getJob(farmId, jobId)
    if TheContractorJobs.getUnallocateProblem(job) ~= nil then
        return false
    end

    -- 060: who had it, while the crew's still on the job.
    g_currentMission.TheContractor.Logbook:onCrewChanged(job)

    self:releaseJobResources(job)

    -- A hired crew carts its own crop, uncounted, so a player taking over
    -- delivers only what's left on the field (TCHaulage.resumeDelivery).
    -- A player's own deliveries so far still count.
    if not job:isPlayerDriven() then
        job.requiredLiters = 0
        job.deliveredLiters = 0
    end

    job.assignedWorkerId = nil
    job.haulerWorkerId = nil
    job.assignedEquipmentIds = {}
    job.haulageEquipmentIds = {}
    job.allocatedPlayerName = nil
    job.isTravelling = false
    job.transportRemainingMs = nil
    -- 045: the next crew's kit sets off in its own condition.
    job.startCondition = nil
    job.wasUnallocated = true
    job:transitionTo(TheContractorJob.STATE.ACCEPTED)
    TCFieldAccess.refresh()

    TCLog.info("TheContractor: farm %d job %d unallocated (%.0f%% done)", farmId, jobId, job.completionPercentage)

    -- The whole snapshot, as an allocation sends it: the crew and kit are
    -- cleared along with the state.
    if g_server ~= nil then
        g_server:broadcastEvent(TCJobAllocatedEvent.new(job))
    end
    return true
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

-- 132: a harvest taken on before jobs had a ready day, its crop not ready
-- yet, gets the day it's predicted to be (no later than its deadline), so
-- it can't be allocated - and its crop forced ripe - early. Every other job
-- is ready now. Same first-update timing as resolveLegacyDeadlines (after
-- it, so the deadline's there), with the fields loaded too.
function TheContractorJobs:resolveLegacyReadyDays()
    self.hasLegacyReadyDays = false
    for _, farmJobs in pairs(self.jobsByFarm) do
        for _, job in pairs(farmJobs) do
            if job.readyDay == nil and job.state == TheContractorJob.STATE.ACCEPTED then
                job.readyDay = TheContractorJobs.getLegacyReadyDay(job)
            end
        end
    end
end

-- The ready day an older save's job gets (resolveLegacyReadyDays), or nil
-- for ready now.
function TheContractorJobs.getLegacyReadyDay(job)
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    if jobDef == nil or not jobDef.cropDependent or g_fieldManager == nil then
        return nil
    end
    local field = g_fieldManager:getFieldById(job.fieldId)
    if field == nil then
        return nil
    end
    local fieldState = field:getFieldState()
    local fruitType = fieldState ~= nil and g_fruitTypeManager:getFruitTypeByIndex(fieldState.fruitTypeIndex) or nil
    if fruitType ~= nil and fruitType:getIsHarvestReady(fieldState.growthState) then
        return nil
    end
    local prediction = TCCropPrediction.getEstimatedHarvestReadyDate(field)
    if prediction == nil then
        return nil
    end
    local readyDay = prediction.absoluteDay
    if job.deadlineDay ~= nil then
        readyDay = math.min(readyDay, job.deadlineDay)
    end
    if readyDay <= g_currentMission.environment.currentMonotonicDay then
        return nil
    end
    return readyDay
end

function TheContractorJobs:update(dt)
    self:updateGracePeriods(dt)

    if not g_currentMission:getIsServer() then
        return
    end

    if self.hasLegacyDeadlines then
        self:resolveLegacyDeadlines()
    end
    if self.hasLegacyReadyDays then
        self:resolveLegacyReadyDays()
    end

    self.completionCheckAccumulatedMs = self.completionCheckAccumulatedMs + dt
    if self.completionCheckAccumulatedMs < TCJobProgress.POLL_INTERVAL_MS then
        return
    end
    self.completionCheckAccumulatedMs = 0

    self:checkForCompletions()
end

-- Grace period (076) ---------------------------------------------------------

-- A completed job the player drove themselves, with field work to finish
-- off. A hired worker's machines go into their cooldown and out of sight,
-- and a job with no equipment (a straw delivery, fly-tipping) has none.
function TheContractorJobs.getsGracePeriod(job)
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    return #job:getWorkerIds() == 0 and jobDef ~= nil and not jobDef.noEquipment
end

-- Every machine counts down its own copy, so field access ends at about
-- the same moment everywhere without an event. The server's count is the
-- one saved and sent to joining clients, and only the server clears up.
function TheContractorJobs:updateGracePeriods(dt)
    for _, job in pairs(self.graceJobs) do
        job.graceRemainingMs = job.graceRemainingMs - dt
        if job.graceRemainingMs <= 0 then
            self:endGracePeriod(job)
        end
    end
end

function TheContractorJobs:endGracePeriod(job)
    job.graceRemainingMs = nil
    self.graceJobs[job.id] = nil
    if g_currentMission:getIsServer() then
        TCFieldPreparation.clearUpAfterJob(job)
    end
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

-- Job history (029): a worker's history is the completed jobs they worked
-- on - as operator or as hauler. Only the farm's newest KEEP_FINISHED_JOBS
-- survive a save (getJobsToSave), so it's recent history, not a career
-- total: keep a running count on the worker if a staff-history view ever
-- needs one.
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
    local tc = g_currentMission.TheContractor
    -- 135: an auction site's field too, while it's up.
    local auctionSite = tc ~= nil and tc.AuctionSite or nil
    if auctionSite ~= nil and auctionSite:isFieldInUse(fieldId) then
        return true
    end
    -- 137: and an auction's, from its announcement until it's over.
    local auctions = tc ~= nil and tc.Auctions or nil
    if auctions ~= nil and auctions:isFieldInUse(fieldId) then
        return true
    end
    return self:hasLiveJob(fieldId)
end

-- Whether any farm has a job on the field that isn't over (on offer, taken
-- on or under way), whatever else protects it. 141: a job to attend an
-- auction isn't work on its field (it's the sale's own), so it never keeps
-- the field from being the site; nor (152) is inspecting one of its lots.
function TheContractorJobs:hasLiveJob(fieldId)
    for _, farmJobs in pairs(self.jobsByFarm) do
        for _, job in pairs(farmJobs) do
            if job.fieldId == fieldId and not job:isTerminal() and job.auctionId == nil and
                    job.lotInspection == nil then
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
    -- 100: a workshop job earns by how big a job it was.
    if job.workshop ~= nil then
        return TheContractorRepairContracts.getBaseReputation(job)
    end
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    -- 106: a spill's clear-up earns nothing (its miss costs what its spill
    -- says).
    if jobDef ~= nil and jobDef.noReward then
        return 0
    end
    -- 075: a job paid per piece earns per piece too.
    if jobDef ~= nil and jobDef.reputationPerItem ~= nil then
        return jobDef.reputationPerItem * (job.workTotal or 0)
    end
    -- 107: a job with no area of its own earns a fixed amount.
    if jobDef ~= nil and jobDef.reputationReward ~= nil then
        return jobDef.reputationReward
    end
    local field = g_fieldManager:getFieldById(job.fieldId)
    local areaHa = field ~= nil and field:getAreaHa() or 1
    local reputationPerHa = jobDef ~= nil and TheContractorJobGeneration.getReputationPerHa(jobDef) or 0
    local isExtraHaulage = job.includesHaulage and not (jobDef ~= nil and jobDef.deliveryOnly)
    local haulageMultiplier = isExtraHaulage and TheContractorJobGeneration.HAULAGE_REPUTATION_MULTIPLIER or 1
    return reputationPerHa * areaHa * haulageMultiplier
end

-- Reputation reward (022), scaled by the job's quality score (080, see
-- getQualityReputationFactor), so the score must be set first. A reward is
-- at least MIN_COMPLETION_REPUTATION_REWARD, and trade association members
-- (053) get a little extra on top. A poor job (below
-- REPUTATION_ZERO_QUALITY) loses reputation instead, with no minimum or
-- bonus. The player driving personally always scores 100, so earns in full.
-- A workshop job (100) also earns more for being done quickly
-- (TheContractorRepairContracts.getSpeedFactor), and by the margin it was
-- priced at (102, getMarginFactor): a factor at or below 0 makes it a loss
-- of that share of the base, whatever the quality and speed.
function TheContractorJobs:calculateReputationReward(job)
    -- 106: putting right your own spill earns nothing.
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    if jobDef ~= nil and jobDef.noReward then
        return 0
    end
    local factor = TheContractorJobs.getQualityReputationFactor(job.qualityScore or 100)
    local reward = TheContractorJobs.getBaseReputationReward(job) * factor
    if factor > 0 and job.workshop ~= nil then
        local marginFactor = TheContractorRepairContracts.getMarginFactor(job)
        if marginFactor <= 0 then
            factor = marginFactor
            reward = TheContractorJobs.getBaseReputationReward(job) * marginFactor
        else
            reward = reward * TheContractorRepairContracts.getSpeedFactor(job) * marginFactor
        end
    end
    if factor <= 0 then
        -- Rounded toward zero: a hair under the line costs nothing.
        return -math.floor(-reward)
    end
    reward = math.max(TheContractorJobs.MIN_COMPLETION_REPUTATION_REWARD, math.floor(reward))
    return reward + g_currentMission.TheContractor.Association:getReputationBonus(job.farmId, reward)
end

-- The share of the base reputation reward a job of this quality earns: 1 at
-- 100, 0 at REPUTATION_ZERO_QUALITY, and on the same line below it, so a
-- (theoretical) 0 loses one base reward - still less than a missed job's
-- MISSED_JOB_PENALTY_MULTIPLIER.
function TheContractorJobs.getQualityReputationFactor(qualityScore)
    local zero = TheContractorJobs.REPUTATION_ZERO_QUALITY
    return (qualityScore - zero) / (100 - zero)
end

-- The crew's skill factor (080): getWorkerSkillFactor for the operator, and
-- on a two-worker haulage job (035) the hauler too, each judged against
-- their own equipment's tier and their own operation skill (haulage for the
-- hauler), blended by OPERATOR_SCORE_WEIGHT.
function TheContractorJobs:getCrewSkillFactor(job)
    local factor = self:getWorkerSkillFactor(job, job.assignedWorkerId, job.assignedEquipmentIds, false)
    if job.haulerWorkerId ~= nil then
        local haulerFactor = self:getWorkerSkillFactor(job, job.haulerWorkerId, job.haulageEquipmentIds, true)
        local weight = TheContractorJobs.OPERATOR_SCORE_WEIGHT
        factor = weight * factor + (1 - weight) * haulerFactor
    end
    return factor
end

-- One worker's skill factor (getSkillFactorFor) from their weakest rating
-- for the job: the tractor tier they drove or the operation skill (044). No
-- worker, or nothing to judge, is 1. A job with no tractor (a
-- self-propelled combine) is judged on the operation skill alone.
function TheContractorJobs:getWorkerSkillFactor(job, workerId, equipmentIds, isHauler)
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

    local rating = TheContractorAllocation.getWeakestRating(ratings)
    if rating == nil then
        return 1
    end
    return TheContractorJobs.getSkillFactorFor(rating, job.requiredSkillLevel)
end

-- QUALITY_SKILL_BY_MARGIN for a rating at or over the requirement (capped
-- at QUALITY_MAX_MARGIN points over); under it, the at-level factor times
-- (0.5 + 0.5 x rating / required).
function TheContractorJobs.getSkillFactorFor(rating, requiredSkillLevel)
    local byMargin = TheContractorJobs.QUALITY_SKILL_BY_MARGIN
    local margin = math.floor(rating - requiredSkillLevel)
    if margin >= 0 then
        return byMargin[math.min(margin, TheContractorJobs.QUALITY_MAX_MARGIN)]
    end
    return byMargin[0] * (0.5 + 0.5 * math.max(0, rating) / requiredSkillLevel)
end

function TheContractorJobs.getReliabilityFactor(stuckInterventions)
    return math.max(TheContractorJobs.QUALITY_RELIABILITY_FLOOR,
        1 - (stuckInterventions or 0) * TheContractorJobs.QUALITY_PENALTY_PER_INTERVENTION)
end

-- The worst damage (0-1) on the job's equipment when it set off (045's
-- startCondition: vanilla damage, or 1 - ADS condition for a machine ADS
-- manages), as a factor: 1 up to QUALITY_DAMAGE_ALLOWANCE, falling to
-- 1 - QUALITY_CONDITION_PENALTY at full damage. No baseline is 1.
function TheContractorJobs.getConditionFactor(job)
    local worst = 0
    for _, condition in pairs(job.startCondition or {}) do
        local damage = condition.adsCondition ~= nil and (1 - condition.adsCondition) or condition.damage or 0
        worst = math.max(worst, damage)
    end
    local allowance = TheContractorJobs.QUALITY_DAMAGE_ALLOWANCE
    if worst <= allowance then
        return 1
    end
    return 1 - TheContractorJobs.QUALITY_CONDITION_PENALTY * (math.min(1, worst) - allowance) / (1 - allowance)
end

-- How the crew's day went, from a roll (0-1): exactly 1 one time in six,
-- else anywhere from QUALITY_FORM_MIN to 1.
function TheContractorJobs.getFormFactor(roll)
    return math.min(1, TheContractorJobs.QUALITY_FORM_MIN + TheContractorJobs.QUALITY_FORM_RANGE * roll)
end

-- 0-100 (029, 080): see the QUALITY_ constants. Rounded down, so 100 means
-- every factor was at its best, not nearly. A job with no hired worker on
-- it (the player driving personally) always scores 100. random is for the
-- tests.
function TheContractorJobs:calculateQualityScore(job, random)
    if job.assignedWorkerId == nil and job.haulerWorkerId == nil then
        return 100
    end
    random = random or math.random

    local score = self:getCrewSkillFactor(job) * TheContractorJobs.getReliabilityFactor(job.stuckInterventions) *
        TheContractorMorale.getJobQualityMultiplier(job) * TheContractorJobs.getConditionFactor(job) *
        TheContractorJobs.getFormFactor(random())
    return math.floor(math.max(0, math.min(1, score)) * 100 + 1e-6)
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

    -- 100: no field, crew or machines of ours.
    if job.workshop ~= nil then
        self:completeWorkshopJob(job)
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

    -- 141: a reminder (JOB_TYPES' noConsequences) is just done.
    if TheContractorJobs.hasNoConsequences(job) then
        self:endWithoutConsequences(job, TheContractorJob.STATE.COMPLETED)
        return
    end

    if not job:canTransitionTo(TheContractorJob.STATE.COMPLETED) then
        return
    end

    -- 049: invoiced rather than paid, unless late/unpaid invoices are
    -- switched off - see TheContractorFinances:invoiceJob. Sets
    -- job.invoiceDueDay before the completion broadcast below carries it.
    -- 124: a yard bale job's bales over the order are paid on top.
    job.paymentAmount = job:getPrice() + TheContractorYardBales.getExcessPay(job)
    g_currentMission.TheContractor.Finances:invoiceJob(job)

    -- Summary (029): computed here, alongside the payout, and sent to
    -- clients in the TCJobCompletedEvent snapshot below. Quality first: the
    -- reputation reward follows it (080).
    job.completedAt = TheContractorJobs.getGameMinutes()
    job.qualityScore = self:calculateQualityScore(job)

    local reputationReward = self:calculateReputationReward(job)
    g_currentMission.TheContractor.Reputation:addReputation(job.farmId, reputationReward)
    -- 113: and the customer's opinion, by the same quality.
    g_currentMission.TheContractor.Relationships:onJobCompleted(job)
    -- 127: a farmer helped out of a hole thinks more of the farm still.
    if job.refuel ~= nil then
        g_currentMission.TheContractor.EmergencyRefuel:onJobCompleted(job)
    end

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
    TCHaulage.emptyHarvestersAfterJob(job)
    -- 076: the field stays workable for a while (endGracePeriod clears
    -- up). A bale job's bales so far go now, any baled in the grace period
    -- at its end. Set before the completion broadcast, which carries it.
    if TheContractorJobs.getsGracePeriod(job) then
        job.graceRemainingMs = TheContractorJobs.GRACE_PERIOD_MS
        self.graceJobs[job.id] = job
        TCFieldPreparation.clearUpAtCompletion(job)
    else
        TCFieldPreparation.clearUpAfterJob(job)
    end
    self:setJobSupplyStatus(job, nil, nil)
    g_currentMission.TheContractor.Inbox:removeMessagesForJob(job.farmId, job.id)

    TCLog.info("TheContractor: farm %d job %d completed (%s, field %d) - billed %.0f, %+d reputation, %s taken, %.0f l fuel (%.0f), quality %d",
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

    -- 106: whatever's left of a spill is cleared away.
    if job.spill ~= nil then
        g_currentMission.TheContractor.CropSpill:onJobCompleted(job)
    end

    -- 072: a joyrider plow job may lead to a grass sow job.
    if job.followOnSow then
        g_currentMission.TheContractor.Joyriders:onJobCompleted(job)
    end

    -- 074: maybe a random event at the job's end (the kettle on, paid
    -- early, a worker stepping up). Last, so it follows everything above.
    g_currentMission.TheContractor.RandomEvents:onJobCompleted(job)
end

-- 141: a job with nothing riding on it (JOB_TYPES' noConsequences).
function TheContractorJobs.hasNoConsequences(job)
    local jobDef = job ~= nil and TheContractorJobGeneration.JOB_TYPES[job.jobType] or nil
    return jobDef ~= nil and jobDef.noConsequences == true
end

-- Server (141): a noConsequences job done (COMPLETED) or over (MISSED), and
-- nothing else: no invoice, quality score, reputation, relationship,
-- logbook entry, growth or job event, and nothing to release (it's never
-- allocated). Done says so as any job does (its summary is its own); a
-- miss is the quiet ending TCJobMissedEvent gives it, not a failure.
function TheContractorJobs:endWithoutConsequences(job, newState)
    if not job:canTransitionTo(newState) then
        return
    end
    if newState == TheContractorJob.STATE.COMPLETED then
        job.completedAt = TheContractorJobs.getGameMinutes()
        job.completionPercentage = 100
    end
    job:transitionTo(newState)
    g_currentMission.TheContractor.Inbox:removeMessagesForJob(job.farmId, job.id)
    TCLog.info("TheContractor: farm %d job %d (%s, field %d) %s, no consequences", job.farmId, job.id, job.jobType,
        job.fieldId, newState)

    if newState == TheContractorJob.STATE.COMPLETED then
        TCJobCompletedEvent.showNotification(job)
        if g_server ~= nil then
            g_server:broadcastEvent(TCJobCompletedEvent.new(job))
        end
        return
    end
    if g_server ~= nil then
        g_server:broadcastEvent(TCJobStateChangedEvent.new(job.farmId, job.id, newState))
    end
    TCJobMissedEvent.showNotification(job.farmId, job.jobType, job.fieldId, job:getTypeLabel())
    if g_server ~= nil then
        g_server:broadcastEvent(TCJobMissedEvent.new(job.farmId, job.jobType, job.fieldId, job:getTypeLabel()))
    end
end

-- Server (141): a job taken away as if it had never been (an attend job
-- whose auction's called off). Only for a job nothing else holds: never
-- allocated, no invoice, nothing in the logbook.
function TheContractorJobs:removeJob(job)
    if not g_currentMission:getIsServer() or job == nil then
        return
    end
    g_currentMission.TheContractor.Inbox:removeMessagesForJob(job.farmId, job.id)
    self:applyJobRemoved(job.farmId, job.id)
    if g_server ~= nil then
        g_server:broadcastEvent(TCJobRemovedEvent.new(job.farmId, job.id))
    end
end

-- Every machine (TCJobRemovedEvent on a client).
function TheContractorJobs:applyJobRemoved(farmId, jobId)
    local farmJobs = self.jobsByFarm[farmId]
    if farmJobs == nil or farmJobs[jobId] == nil then
        return
    end
    farmJobs[jobId] = nil
    self.graceJobs[jobId] = nil
    TCLog.info("TheContractor: farm %d job %d removed", farmId, jobId)
end

-- 100: a workshop job is done when ADS says the customer's machine is (or
-- tcJob state forces it): invoiced, reputation by kind, severity and speed
-- (quality 100, no crew), logged, and the customer comes for the machine.
function TheContractorJobs:completeWorkshopJob(job)
    if not job:canTransitionTo(TheContractorJob.STATE.COMPLETED) then
        return
    end

    job.paymentAmount = job:getPrice()
    g_currentMission.TheContractor.Finances:invoiceJob(job)
    job.completedAt = TheContractorJobs.getGameMinutes()
    job.qualityScore = 100
    job.completionPercentage = 100

    local reputationReward = self:calculateReputationReward(job)
    g_currentMission.TheContractor.Reputation:addReputation(job.farmId, reputationReward)
    -- 102: kept for the Workshop tab's completed view (streamed with the job).
    job.workshop.reputationReward = reputationReward

    job:transitionTo(TheContractorJob.STATE.COMPLETED)
    g_currentMission.TheContractor.Logbook:recordJobCompleted(job, reputationReward)
    -- 102: far over the benchmark, word gets round.
    g_currentMission.TheContractor.RepairContracts:onJobCompleted(job)
    g_currentMission.TheContractor.Inbox:removeMessagesForJob(job.farmId, job.id)

    TCLog.info("TheContractor: farm %d job %d completed (%s, %s) - billed %.0f, %+d reputation", job.farmId,
        job.id, job.jobType, job.workshop.vehicleName or "?", job.paymentAmount, reputationReward)

    TCJobCompletedEvent.showNotification(job)
    if g_server ~= nil then
        g_server:broadcastEvent(TCJobCompletedEvent.new(job))
    end

    g_currentMission.TheContractor.RepairContracts:queueCollection(job)
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
    -- eagerness (014) isn't sent: it's hidden and only the server
    -- negotiates with it.
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

    -- 076. -1 stands in for "no grace period".
    streamWriteFloat32(streamId, job.graceRemainingMs or -1)

    -- 093. "" stands in for "no player recorded".
    streamWriteString(streamId, job.allocatedPlayerName or "")

    -- 100.
    TheContractorJobs.writeWorkshop(streamId, job.workshop)
    -- 106.
    TheContractorCropSpill.writeStream(streamId, job.spill)
    -- 110. 0 stands in for "no customer".
    streamWriteInt32(streamId, job.customerId or 0)
    -- 124.
    TheContractorYardBales.writeStream(streamId, job.yardDelivery)
    -- 126.
    TheContractorYardHaul.writeStream(streamId, job.yardHaul)
    -- 127.
    TheContractorEmergencyRefuel.writeStream(streamId, job.refuel)
    -- 132. -1 stands in for "ready now".
    streamWriteInt32(streamId, job.readyDay or -1)
    -- 141. 0 stands in for "no auction".
    streamWriteInt32(streamId, job.auctionId or 0)
    -- 152.
    TCLotInspections.writeStream(streamId, job.lotInspection)
    -- "" stands in for no offer source.
    streamWriteString(streamId, job.offerSource or "")
end

-- 100: what a client needs of a workshop job (the uniqueIds stay on the
-- server).
function TheContractorJobs.writeWorkshop(streamId, workshop)
    streamWriteBool(streamId, workshop ~= nil)
    if workshop == nil then
        return
    end
    streamWriteInt32(streamId, workshop.vehicleId or 0)
    streamWriteString(streamId, workshop.vehicleName or "")
    streamWriteString(streamId, workshop.kind or "")
    streamWriteInt32(streamId, workshop.severity or 1)
    streamWriteInt32(streamId, workshop.offerExpiresDay or -1)
    streamWriteFloat32(streamId, workshop.quotePrice or 0)
    streamWriteString(streamId, table.concat(workshop.requiredTools or {}, ","))
    streamWriteString(streamId, workshop.serviceLevel or "")
    streamWriteFloat32(streamId, workshop.operatingHours or -1)
    streamWriteInt32(streamId, workshop.bayIndex or 0)
    -- 101: a breakdown's field.
    streamWriteInt32(streamId, workshop.fieldId or 0)
    streamWriteFloat32(streamId, workshop.partsCost or -1)
    streamWriteFloat32(streamId, workshop.acceptedAt or -1)
    -- 102: the cost and margins for the Negotiate dialog and the completed
    -- view. The customer's ceiling (refusalMargin) stays on the server.
    streamWriteFloat32(streamId, workshop.baseParts or -1)
    streamWriteFloat32(streamId, workshop.baseLabour or -1)
    streamWriteFloat32(streamId, workshop.laborHours or -1)
    streamWriteFloat32(streamId, workshop.benchmarkMargin or -1)
    streamWriteFloat32(streamId, workshop.margin or -1)
    streamWriteBool(streamId, workshop.reputationReward ~= nil)
    if workshop.reputationReward ~= nil then
        streamWriteInt32(streamId, workshop.reputationReward)
    end
    -- 116: a favour's part (ADS's l10n key), its size and the yard, for the
    -- menu. The farmer's the job's customer; the machine's record stays on
    -- the server.
    streamWriteString(streamId, workshop.targetNameKey or "")
    streamWriteString(streamId, workshop.partGrade or "")
    streamWriteInt32(streamId, workshop.yardFarmlandId or 0)
    -- 121: the machine's attachment, so it's the customer's on every machine.
    streamWriteInt32(streamId, workshop.attachmentId or 0)
end

-- A float that -1 stands in for nil.
local function readOptionalFloat(streamId)
    local value = streamReadFloat32(streamId)
    return value >= 0 and value or nil
end

local function splitList(text)
    local list = {}
    for item in string.gmatch(text or "", "[^,]+") do
        table.insert(list, item)
    end
    return list
end

function TheContractorJobs.readWorkshop(streamId)
    if not streamReadBool(streamId) then
        return nil
    end
    local workshop = {}
    workshop.vehicleId = streamReadInt32(streamId)
    workshop.vehicleName = streamReadString(streamId)
    workshop.kind = streamReadString(streamId)
    workshop.severity = streamReadInt32(streamId)
    local offerExpiresDay = streamReadInt32(streamId)
    workshop.offerExpiresDay = offerExpiresDay >= 0 and offerExpiresDay or nil
    workshop.quotePrice = streamReadFloat32(streamId)
    workshop.requiredTools = splitList(streamReadString(streamId))
    local serviceLevel = streamReadString(streamId)
    workshop.serviceLevel = serviceLevel ~= "" and serviceLevel or nil
    local operatingHours = streamReadFloat32(streamId)
    workshop.operatingHours = operatingHours >= 0 and operatingHours or nil
    workshop.bayIndex = streamReadInt32(streamId)
    local fieldId = streamReadInt32(streamId)
    workshop.fieldId = fieldId ~= 0 and fieldId or nil
    local partsCost = streamReadFloat32(streamId)
    workshop.partsCost = partsCost >= 0 and partsCost or nil
    local acceptedAt = streamReadFloat32(streamId)
    workshop.acceptedAt = acceptedAt >= 0 and acceptedAt or nil
    workshop.baseParts = readOptionalFloat(streamId)
    workshop.baseLabour = readOptionalFloat(streamId)
    workshop.laborHours = readOptionalFloat(streamId)
    workshop.benchmarkMargin = readOptionalFloat(streamId)
    workshop.margin = readOptionalFloat(streamId)
    if streamReadBool(streamId) then
        workshop.reputationReward = streamReadInt32(streamId)
    end
    local targetNameKey = streamReadString(streamId)
    workshop.targetNameKey = targetNameKey ~= "" and targetNameKey or nil
    local partGrade = streamReadString(streamId)
    workshop.partGrade = partGrade ~= "" and partGrade or nil
    local yardFarmlandId = streamReadInt32(streamId)
    workshop.yardFarmlandId = yardFarmlandId ~= 0 and yardFarmlandId or nil
    local attachmentId = streamReadInt32(streamId)
    workshop.attachmentId = attachmentId ~= 0 and attachmentId or nil
    return workshop
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
    local negotiationRounds = streamReadInt32(streamId)
    local fruitTypeName = streamReadString(streamId)
    local deadlineDay = streamReadInt32(streamId)

    local job = TheContractorJob.new(id, farmId, jobType, fieldId, requiredSkillLevel, targetPeriod,
        targetDayInPeriod, price)
    job.state = state
    job.completionPercentage = completionPercentage
    job.equipmentAvailable = equipmentAvailable
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

    local graceRemainingMs = streamReadFloat32(streamId)
    job.graceRemainingMs = graceRemainingMs >= 0 and graceRemainingMs or nil

    local allocatedPlayerName = streamReadString(streamId)
    job.allocatedPlayerName = allocatedPlayerName ~= "" and allocatedPlayerName or nil

    job.workshop = TheContractorJobs.readWorkshop(streamId)
    job.spill = TheContractorCropSpill.readStream(streamId)
    local customerId = streamReadInt32(streamId)
    job.customerId = customerId ~= 0 and customerId or nil
    job.yardDelivery = TheContractorYardBales.readStream(streamId)
    job.yardHaul = TheContractorYardHaul.readStream(streamId)
    job.refuel = TheContractorEmergencyRefuel.readStream(streamId)
    local readyDay = streamReadInt32(streamId)
    job.readyDay = readyDay >= 0 and readyDay or nil
    local auctionId = streamReadInt32(streamId)
    job.auctionId = auctionId ~= 0 and auctionId or nil
    job.lotInspection = TCLotInspections.readStream(streamId)
    local offerSource = streamReadString(streamId)
    job.offerSource = offerSource ~= "" and offerSource or nil

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

-- A farm deleted in multiplayer (TCFarmDeletion), on every machine.
function TheContractorJobs:forgetFarm(farmId, jobIds)
    for _, jobId in ipairs(jobIds) do
        self.graceJobs[jobId] = nil
    end
    self.jobsByFarm[farmId] = nil
    -- 100: its customers' machines leave the ones kept out of our lists.
    if TheContractorRepairContracts ~= nil then
        TheContractorRepairContracts.clearCache()
    end
end

function TheContractorJobs:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    self.jobsByFarm = {}
    self.graceJobs = {}
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
            -- 132: nil for saves from before it - resolveLegacyReadyDays
            -- gives an unready harvest one on the first update.
            job.readyDay = getXMLInt(xmlFile, jobKey .. "#readyDay")
            if job.readyDay == nil then
                self.hasLegacyReadyDays = true
            end
            job.assignedWorkerId = getXMLInt(xmlFile, jobKey .. "#assignedWorkerId")
            job.allocatedPlayerName = getXMLString(xmlFile, jobKey .. "#allocatedPlayerName")
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
            job.wasUnallocated = Utils.getNoNil(getXMLBool(xmlFile, jobKey .. "#wasUnallocated"), false)
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
            local debrisIndex = 0
            while true do
                local debrisKey = string.format("%s.debris(%d)", jobKey, debrisIndex)
                if not hasXMLProperty(xmlFile, debrisKey) then
                    break
                end
                table.insert(job.debrisIds, getXMLString(xmlFile, debrisKey .. "#uniqueId"))
                debrisIndex = debrisIndex + 1
            end
            job.debrisDisposed = Utils.getNoNil(getXMLInt(xmlFile, jobKey .. "#debrisDisposed"), 0)
            job.graceRemainingMs = getXMLFloat(xmlFile, jobKey .. "#graceRemainingMs")
            job.workshop = TheContractorJobs.loadWorkshop(xmlFile, jobKey .. ".workshop")
            job.spill = TheContractorCropSpill.loadFromXML(xmlFile, jobKey .. ".spill")
            job.yardDelivery = TheContractorYardBales.loadFromXML(xmlFile, jobKey .. ".yardDelivery")
            -- 126: its litres are haulage's, loaded above.
            job.yardHaul = TheContractorYardHaul.loadFromXML(xmlFile, jobKey .. ".yardHaul")
            -- 127.
            job.refuel = TheContractorEmergencyRefuel.loadFromXML(xmlFile, jobKey .. ".refuel")
            -- 124: its litres are kept with the order, not as haulage's.
            if job.yardDelivery ~= nil then
                job.requiredLiters = job.yardDelivery.liters or 0
                job.deliveredLiters = job.yardDelivery.deliveredLiters or 0
            end
            -- 110: nil for a job saved before it existed - TheContractorFarmers:
            -- setUp links it from its field.
            job.customerId = getXMLInt(xmlFile, jobKey .. "#customerId")
            -- 141.
            job.auctionId = getXMLInt(xmlFile, jobKey .. "#auctionId")
            -- 152.
            job.lotInspection = TCLotInspections.loadFromXML(xmlFile, jobKey .. ".lotInspection")
            job.offerSource = getXMLString(xmlFile, jobKey .. "#offerSource")

            self.jobsByFarm[farmId] = self.jobsByFarm[farmId] or {}
            self.jobsByFarm[farmId][id] = job
            if job.graceRemainingMs ~= nil then
                self.graceJobs[id] = job
            end

            if id >= self.nextJobId then
                self.nextJobId = id + 1
            end

            jobIndex = jobIndex + 1
        end

        farmIndex = farmIndex + 1
    end
end

-- 100: a workshop job's machine by uniqueId until resolveSavedVehicles.
function TheContractorJobs.loadWorkshop(xmlFile, key)
    if not hasXMLProperty(xmlFile, key) then
        return nil
    end
    return {
        vehicleId = nil,
        vehicleUniqueId = getXMLString(xmlFile, key .. "#vehicleUniqueId"),
        vehicleName = Utils.getNoNil(getXMLString(xmlFile, key .. "#vehicleName"), ""),
        zoneUniqueId = getXMLString(xmlFile, key .. "#zoneUniqueId"),
        bayIndex = Utils.getNoNil(getXMLInt(xmlFile, key .. "#bayIndex"), 0),
        kind = Utils.getNoNil(getXMLString(xmlFile, key .. "#kind"), "repair"),
        severity = Utils.getNoNil(getXMLInt(xmlFile, key .. "#severity"), 1),
        offerExpiresDay = getXMLInt(xmlFile, key .. "#offerExpiresDay"),
        quotePrice = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#quotePrice"), 0),
        partsCost = getXMLFloat(xmlFile, key .. "#partsCost"),
        acceptedAt = getXMLFloat(xmlFile, key .. "#acceptedAt"),
        requiredTools = splitList(getXMLString(xmlFile, key .. "#requiredTools")),
        serviceLevel = getXMLString(xmlFile, key .. "#serviceLevel"),
        operatingHours = getXMLFloat(xmlFile, key .. "#operatingHours"),
        fieldId = getXMLInt(xmlFile, key .. "#fieldId"),
        -- 102.
        baseParts = getXMLFloat(xmlFile, key .. "#baseParts"),
        baseLabour = getXMLFloat(xmlFile, key .. "#baseLabour"),
        laborHours = getXMLFloat(xmlFile, key .. "#laborHours"),
        benchmarkMargin = getXMLFloat(xmlFile, key .. "#benchmarkMargin"),
        refusalMargin = getXMLFloat(xmlFile, key .. "#refusalMargin"),
        margin = getXMLFloat(xmlFile, key .. "#margin"),
        reputationReward = getXMLInt(xmlFile, key .. "#reputationReward"),
        -- 116.
        farmerId = getXMLInt(xmlFile, key .. "#farmerId"),
        machineId = getXMLInt(xmlFile, key .. "#machineId"),
        yardFarmlandId = getXMLInt(xmlFile, key .. "#yardFarmlandId"),
        targetId = getXMLString(xmlFile, key .. "#targetId"),
        targetNameKey = getXMLString(xmlFile, key .. "#targetNameKey"),
        partGrade = getXMLString(xmlFile, key .. "#partGrade"),
        -- 121: the machine's attachment, by uniqueId until resolveSavedVehicles.
        attachmentUniqueId = getXMLString(xmlFile, key .. "#attachmentUniqueId"),
        attachmentMachineId = getXMLInt(xmlFile, key .. "#attachmentMachineId"),
    }
end

function TheContractorJobs.saveWorkshop(xmlFile, key, workshop)
    local uniqueId = workshop.vehicleUniqueId
    if workshop.vehicleId ~= nil and workshop.vehicleId ~= 0 then
        uniqueId = TCVehicleIds.getUniqueId(workshop.vehicleId) or uniqueId
    end
    if uniqueId ~= nil then
        setXMLString(xmlFile, key .. "#vehicleUniqueId", uniqueId)
    end
    setXMLString(xmlFile, key .. "#vehicleName", workshop.vehicleName or "")
    if workshop.zoneUniqueId ~= nil then
        setXMLString(xmlFile, key .. "#zoneUniqueId", workshop.zoneUniqueId)
    end
    setXMLInt(xmlFile, key .. "#bayIndex", workshop.bayIndex or 0)
    setXMLString(xmlFile, key .. "#kind", workshop.kind or "repair")
    setXMLInt(xmlFile, key .. "#severity", workshop.severity or 1)
    if workshop.offerExpiresDay ~= nil then
        setXMLInt(xmlFile, key .. "#offerExpiresDay", workshop.offerExpiresDay)
    end
    setXMLFloat(xmlFile, key .. "#quotePrice", workshop.quotePrice or 0)
    if workshop.partsCost ~= nil then
        setXMLFloat(xmlFile, key .. "#partsCost", workshop.partsCost)
    end
    if workshop.acceptedAt ~= nil then
        setXMLFloat(xmlFile, key .. "#acceptedAt", workshop.acceptedAt)
    end
    setXMLString(xmlFile, key .. "#requiredTools", table.concat(workshop.requiredTools or {}, ","))
    if workshop.serviceLevel ~= nil then
        setXMLString(xmlFile, key .. "#serviceLevel", workshop.serviceLevel)
    end
    if workshop.operatingHours ~= nil then
        setXMLFloat(xmlFile, key .. "#operatingHours", workshop.operatingHours)
    end
    if workshop.fieldId ~= nil then
        setXMLInt(xmlFile, key .. "#fieldId", workshop.fieldId)
    end
    -- 102.
    for _, name in ipairs({ "baseParts", "baseLabour", "laborHours", "benchmarkMargin", "refusalMargin", "margin" }) do
        if workshop[name] ~= nil then
            setXMLFloat(xmlFile, key .. "#" .. name, workshop[name])
        end
    end
    if workshop.reputationReward ~= nil then
        setXMLInt(xmlFile, key .. "#reputationReward", workshop.reputationReward)
    end
    -- 121: the machine's attachment.
    local attachmentUniqueId = workshop.attachmentUniqueId
    if workshop.attachmentId ~= nil and workshop.attachmentId ~= 0 then
        attachmentUniqueId = TCVehicleIds.getUniqueId(workshop.attachmentId) or attachmentUniqueId
    end
    if attachmentUniqueId ~= nil then
        setXMLString(xmlFile, key .. "#attachmentUniqueId", attachmentUniqueId)
    end
    -- 116: a favour's farmer, machine, part and yard (121: a breakdown's
    -- farmer and machine too, and the attachment's machine).
    for _, name in ipairs({ "farmerId", "machineId", "yardFarmlandId", "attachmentMachineId" }) do
        if workshop[name] ~= nil then
            setXMLInt(xmlFile, key .. "#" .. name, workshop[name])
        end
    end
    for _, name in ipairs({ "targetId", "targetNameKey", "partGrade" }) do
        if workshop[name] ~= nil then
            setXMLString(xmlFile, key .. "#" .. name, workshop[name])
        end
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
            -- 100: a workshop job's machine (gone once collected).
            if job.workshop ~= nil and job.workshop.vehicleId == nil then
                job.workshop.vehicleId = job.workshop.vehicleUniqueId ~= nil and
                    TCVehicleIds.getObjectId(job.workshop.vehicleUniqueId) or 0
            end
            -- 121: and its attachment.
            if job.workshop ~= nil and job.workshop.attachmentId == nil and job.workshop.attachmentUniqueId ~= nil then
                job.workshop.attachmentId = TCVehicleIds.getObjectId(job.workshop.attachmentUniqueId) or 0
            end
        end
    end
end

-- What the save keeps of finished jobs, so it doesn't grow for good. A
-- declined job (an offer turned down or left to lapse) is never saved:
-- nothing shows it, and the only things naming one, its offer's inbox
-- messages, already go once it's over or gone. Completed and missed jobs
-- are the farm's history (the Jobs tab's Completed list, the Workshop tab's
-- Completed view), so each farm keeps its newest KEEP_FINISHED_JOBS of each
-- kind, workshop jobs (100) and the rest, newest by when they finished
-- (getFinishedAt). An older one is kept anyway while something still names
-- it (getHeldJobIds). Dropped jobs only go at the next save, as Finances
-- drops settled invoices.
TheContractorJobs.KEEP_FINISHED_JOBS = 100

-- When a completed or missed job finished, in game minutes: its completion,
-- or for a missed job the end of its deadline day.
function TheContractorJobs.getFinishedAt(job)
    if job.completedAt ~= nil then
        return job.completedAt
    end
    return ((job.deadlineDay or 0) + 1) * 24 * 60
end

-- Newest finished first, as the menus list them.
function TheContractorJobs.sortNewestFinished(jobs)
    table.sort(jobs, function(a, b)
        local aAt, bAt = TheContractorJobs.getFinishedAt(a), TheContractorJobs.getFinishedAt(b)
        if aAt ~= bAt then
            return aAt > bAt
        end
        return a.id > b.id
    end)
end

-- Server: the ids of jobs something else still names, so they stay in the
-- save however old: an invoice not yet dropped from the save, a pending
-- claim (052's, or a workshop job's tampering claim), a cooldown (it washes
-- the job's kit when it ends), a random event's incident (074's job events)
-- or an inbox message.
function TheContractorJobs.getHeldJobIds()
    local tc = g_currentMission.TheContractor
    local held = {}
    local function hold(jobId)
        if jobId ~= nil then
            held[jobId] = true
        end
    end
    for _, invoice in pairs(tc.Finances.invoicesById or {}) do
        hold(invoice.jobId)
    end
    for _, claim in ipairs(tc.Claims.pendingClaims or {}) do
        hold(claim.jobId)
    end
    for _, claim in ipairs(tc.RepairContracts.pendingClaims or {}) do
        hold(claim.jobId)
    end
    for _, farmEntries in pairs(tc.Cooldown.entriesByFarm or {}) do
        for _, entry in pairs(farmEntries) do
            hold(entry.jobId)
        end
    end
    for _, incident in pairs(tc.RandomEvents.incidents or {}) do
        hold(incident.data ~= nil and incident.data.jobId or nil)
    end
    for _, message in pairs(tc.Inbox.messagesById or {}) do
        hold(message.payload ~= nil and message.payload.jobId or nil)
    end
    return held
end

-- Server: the farm's jobs that go in the save, in id order.
function TheContractorJobs:getJobsToSave(farmId, farmJobs)
    local jobs = {}
    local finishedByKind = { workshop = {}, field = {} }
    for _, job in pairs(farmJobs) do
        if job.state == TheContractorJob.STATE.COMPLETED or job.state == TheContractorJob.STATE.MISSED then
            table.insert(finishedByKind[job:isWorkshop() and "workshop" or "field"], job)
        elseif job.state ~= TheContractorJob.STATE.DECLINED then
            table.insert(jobs, job)
        end
    end

    local held = nil
    for _, finished in pairs(finishedByKind) do
        TheContractorJobs.sortNewestFinished(finished)
        for i, job in ipairs(finished) do
            local isKept = i <= TheContractorJobs.KEEP_FINISHED_JOBS or job.graceRemainingMs ~= nil
            if not isKept then
                held = held or TheContractorJobs.getHeldJobIds()
                isKept = held[job.id] == true
            end
            if isKept then
                table.insert(jobs, job)
            end
        end
    end

    table.sort(jobs, function(a, b) return a.id < b.id end)
    return jobs
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
        for _, job in ipairs(self:getJobsToSave(farmId, farmJobs)) do
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
            if job.readyDay ~= nil then
                setXMLInt(xmlFile, jobKey .. "#readyDay", job.readyDay)
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
            if job.wasUnallocated then
                setXMLBool(xmlFile, jobKey .. "#wasUnallocated", true)
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
            for i, uniqueId in ipairs(job.debrisIds) do
                setXMLString(xmlFile, string.format("%s.debris(%d)#uniqueId", jobKey, i - 1), uniqueId)
            end
            if job.debrisDisposed > 0 then
                setXMLInt(xmlFile, jobKey .. "#debrisDisposed", job.debrisDisposed)
            end
            if job.graceRemainingMs ~= nil then
                setXMLFloat(xmlFile, jobKey .. "#graceRemainingMs", job.graceRemainingMs)
            end
            if job.workshop ~= nil then
                TheContractorJobs.saveWorkshop(xmlFile, jobKey .. ".workshop", job.workshop)
            end
            if job.spill ~= nil then
                TheContractorCropSpill.saveToXML(xmlFile, jobKey .. ".spill", job.spill)
            end
            if job.yardDelivery ~= nil then
                TheContractorYardBales.saveToXML(xmlFile, jobKey .. ".yardDelivery", job.yardDelivery,
                    job.deliveredLiters)
            end
            if job.yardHaul ~= nil then
                TheContractorYardHaul.saveToXML(xmlFile, jobKey .. ".yardHaul", job.yardHaul)
            end
            if job.refuel ~= nil then
                TheContractorEmergencyRefuel.saveToXML(xmlFile, jobKey .. ".refuel", job.refuel)
            end
            if job.customerId ~= nil then
                setXMLInt(xmlFile, jobKey .. "#customerId", job.customerId)
            end
            if job.auctionId ~= nil then
                setXMLInt(xmlFile, jobKey .. "#auctionId", job.auctionId)
            end
            if job.lotInspection ~= nil then
                TCLotInspections.saveToXML(xmlFile, jobKey .. ".lotInspection", job.lotInspection)
            end
            if job.offerSource ~= nil then
                setXMLString(xmlFile, jobKey .. "#offerSource", job.offerSource)
            end

            if job.assignedWorkerId ~= nil then
                setXMLInt(xmlFile, jobKey .. "#assignedWorkerId", job.assignedWorkerId)
            end
            if job.allocatedPlayerName ~= nil then
                setXMLString(xmlFile, jobKey .. "#allocatedPlayerName", job.allocatedPlayerName)
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
    TCConsole.registerHint("jobId", "a job's id (tcJob list; tcJob list all for finished ones too)")
    TCConsole.registerHint("state", function()
        local states = {}
        for _, state in pairs(TheContractorJob.STATE) do
            table.insert(states, state)
        end
        table.sort(states)
        return TCConsole.listNames(states)
    end)

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
                local readyDay = job:getFutureReadyDay()
                if readyDay ~= nil then
                    table.insert(details, string.format("ready from %s (day %d)", TCCalendar.formatDay(readyDay),
                        readyDay))
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
                table.insert(lines, string.format("#%d %s, %s - %s, %s%s", job.id, job:getDisplayTitle(),
                    job:isWorkshop() and "workshop" or ("field " .. job:getLocationText()), job.state,
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
            local fieldId, skill, price = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
            local targetPeriod, targetDay = tonumber(args[5]), tonumber(args[6])
            if args[1] == nil or fieldId == nil or skill == nil or price == nil or targetPeriod == nil or
                targetDay == nil then
                return false
            end
            -- An event's own type (outside JOB_TYPE_KEYS) by its exact key.
            local jobType = TheContractorJobGeneration.findJobType(args[1])
            if jobType == nil and TheContractorJobGeneration.JOB_TYPES[args[1]] ~= nil then
                jobType = args[1]
            end
            if jobType == nil then
                return string.format("Unknown job type '%s'. Job types: %s", args[1],
                    table.concat(TheContractorJobGeneration.JOB_TYPE_KEYS, ", "))
            end

            -- Typed at the current price level; jobs store it without
            -- FS25_EconomyScale's factor (TheContractorJob:getPrice). The
            -- crop, start state and equipment check are read from the field
            -- as generation would.
            local jobDef = TheContractorJobGeneration.JOB_TYPES[jobType]
            local field = g_fieldManager:getFieldById(fieldId)
            local equipmentAvailable, fruitTypeName, startState = nil, nil, nil
            if jobDef ~= nil then
                fruitTypeName = TheContractorJobGeneration.getRecordedFruitTypeName(field, jobDef)
                startState = TheContractorJobGeneration.getFieldStartState(field, jobDef)
                equipmentAvailable = g_currentMission.TheContractor.JobGeneration:canFulfill(farmId, jobDef,
                    TheContractorJobGeneration.getFruitTypeIndexByName(fruitTypeName))
            end
            local job = g_currentMission.TheContractor.Jobs:createJob(farmId, jobType, fieldId, skill, targetPeriod,
                targetDay, price / TCEconomyScale.getFactor(), equipmentAvailable, fruitTypeName, nil, nil, nil,
                startState)
            return string.format("Created job %d for farm %d", job.id, farmId)
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

            if not g_currentMission.TheContractor.Jobs:forceJobState(farmId, jobId, state) then
                return string.format("Job %d couldn't go to %s.", jobId, state)
            end
            return string.format("Job %d is now %s.", jobId, job.state)
        end,
    })
end
