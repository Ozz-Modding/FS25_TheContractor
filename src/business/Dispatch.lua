-- AI dispatch integration (020): when an `accepted` job is allocated (018)
-- to a hired worker (not the player), programmatically starts and tracks
-- the base game's real AI Helper job on the assigned vehicle — the exact
-- same server-side API the `gsAIStart` console command and the AI Helper
-- map UI both call
-- (g_currentMission.aiJobTypeManager:createJob(AIJobType.FIELDWORK) +
-- g_currentMission.aiSystem:startJob), not any faked UI interaction. Player
-- self-allocated jobs (assignedWorkerId == nil) never go through this
-- system at all — the player just drives normally, and 019's density-map
-- progress tracking picks up their work the same way it does a hired
-- worker's.
--
-- AISystem:startJob already asserts server-only (see AISystem:startJob in
-- Reference/FS25_Lua/ai/AISystem.lua), and this is always triggered from
-- TheContractorAllocation:allocateJob, itself already server-authoritative
-- (018) — no additional TCFooEvent wrapper needed, per the ticket's own
-- design note.
--
-- No state of its own to persist: the id<->AIJob lookup tables below only
-- ever hold currently-running AIJob object/id references (not serializable,
-- meaningless across a save/load boundary) — same "live cache, not
-- persisted state" reasoning TCJobProgress's scan-state cache uses. A job's
-- real, persisted state (allocated/in_progress/...) stays Job.lua's own
-- field, moved via TheContractorJobs:transitionJobState like everything
-- else does.

TheContractorDispatch = {}
TheContractorDispatch_mt = Class(TheContractorDispatch)

-- Dispatch staging (see startJobForWorker): how long equipment stays hidden
-- before it's rigged and moved, then how long after that before it's
-- revealed on the field and the AI started - lets hitch joints and physics
-- settle out of sight.
TheContractorDispatch.HIDDEN_MS = 500
TheContractorDispatch.SETTLE_MS = 1000

-- Transport wait: how long the worker and equipment are "on the road"
-- between leaving the yard and turning up on the field, in in-game minutes
-- (counted down against the effective time scale, so it speeds up with
-- it). Runs before HIDDEN_MS, so the equipment stays hidden for the whole
-- trip. Made up of
-- TRANSPORT_WAIT_FACTORS - each entry is a function(job, worker) returning
-- that factor's contribution in minutes, summed by getTransportWaitMs. Add
-- new factors (distance, equipment count, ...) by appending to the list.
-- `worker` is the job's slowest worker (TheContractorJobs.getSlowestWorker)
-- - a two-worker haulage job (035) travels at its slower half's pace.
-- 026: 30 in-game minutes for the slowest worker down to 10 for the
-- fastest, a bit under Cooldown's buffer since that also covers unloading
-- and cleaning down.
TheContractorDispatch.TRANSPORT_MAX_MINUTES = 30
TheContractorDispatch.TRANSPORT_MIN_MINUTES = 10

TheContractorDispatch.TRANSPORT_WAIT_FACTORS = {
    -- Worker speed (016): linear between a slowest worker's
    -- TRANSPORT_MAX_MINUTES and a fastest worker's TRANSPORT_MIN_MINUTES.
    {
        name = "workerSpeed",
        getMinutes = function(job, worker)
            return TheContractorWorker.scaleBySpeed(worker, TheContractorDispatch.TRANSPORT_MAX_MINUTES,
                TheContractorDispatch.TRANSPORT_MIN_MINUTES)
        end,
    },
    -- Supplies (032): loading the seed/fertilizer/... the job needs from the
    -- farm's stock before setting off, plus a flat few minutes if it
    -- refuelled (TCJobSupplies.getLoadingMinutes) - job.suppliesLoaded and
    -- job.fuelLoaded are what startJobForWorker just loaded.
    {
        name = "supplies",
        getMinutes = function(job, worker)
            return TCJobSupplies.getLoadingMinutes(job.suppliesLoaded, job.fuelLoaded)
        end,
    },
}

function TheContractorDispatch.getTransportWaitMs(job)
    local worker = TheContractorJobs.getSlowestWorker(job)
    local minutes = 0
    for _, factor in ipairs(TheContractorDispatch.TRANSPORT_WAIT_FACTORS) do
        minutes = minutes + factor.getMinutes(job, worker)
    end
    return math.max(0, minutes) * 60000
end

TheContractorDispatch.STAGE = {
    HIDDEN = "hidden",
    RIGGED = "rigged",
}

function TheContractorDispatch.new()
    local self = {}
    setmetatable(self, TheContractorDispatch_mt)

    -- ourJobId -> AIJob instance, populated the moment we hand a job to
    -- AISystem:startJob, cleared once AI_JOB_REMOVED confirms it's gone.
    self.aiJobByOurJobId = {}
    -- AIJob instance -> ourJobId, the reverse lookup AI_JOB_STARTED/
    -- AI_JOB_STOPPED hand back (they carry the AIJob object itself, not any
    -- id of ours) needs to work from.
    self.ourJobIdByAIJob = {}
    -- AISystem's own numeric jobId (assigned inside AISystem:startJob, only
    -- known once AI_JOB_STARTED fires) -> ourJobId, since AI_JOB_REMOVED
    -- only ever hands back that numeric id, not the AIJob object.
    self.ourJobIdByAISystemJobId = {}
    -- ourJobId -> { stage, elapsedMs }, for jobs part-way through
    -- startJobForWorker's hide -> rig/move -> reveal+start staging. Live
    -- only, like the tables above: a save mid-staging is picked back up by
    -- resumeJobsAfterLoad. The trip's own countdown lives on the job
    -- (job.transportRemainingMs) instead, so it's saved with it.
    self.pendingByJobId = {}
    self.hasResumedAfterLoad = false
    -- ourJobId -> true for jobs whose AI stopped itself on an empty tank
    -- (032) - TCJobSupplies' poll picks them up (takeRanOutOfFill) to refill
    -- and restart, or put them on hold. Live only, like the tables above.
    self.ranOutOfFillJobIds = {}

    return self
end

-- Server-only, same as every other subsystem's *Tick subscription — an AI
-- job can only ever be started/tracked server-side (AISystem's own
-- restriction), so there's nothing for a client to listen for here.
function TheContractorDispatch:startListening()
    if not g_currentMission:getIsServer() then
        return
    end

    g_messageCenter:subscribe(MessageType.AI_JOB_STARTED, self.onAIJobStarted, self)
    g_messageCenter:subscribe(MessageType.AI_JOB_STOPPED, self.onAIJobStopped, self)
    g_messageCenter:subscribe(MessageType.AI_JOB_REMOVED, self.onAIJobRemoved, self)
end

function TheContractorDispatch:stopListening()
    g_messageCenter:unsubscribe(MessageType.AI_JOB_STARTED, self)
    g_messageCenter:unsubscribe(MessageType.AI_JOB_STOPPED, self)
    g_messageCenter:unsubscribe(MessageType.AI_JOB_REMOVED, self)
end

-- Picks the one piece of allocated equipment (018) actually capable of
-- being handed to AIJobFieldWork as its driving vehicle — the tractor, or,
-- for a self-propelled job type like harvest, the combine itself.
-- getIsAvailableForVehicle folds in vehicle:getCanStartFieldWork() (false
-- for an implement with no engine of its own, or a tractor with nothing
-- attached) and vehicle:getIsAIJobSupported() - by the time this runs,
-- TCJobSiteSetup has already hitched the job's implements on. Returns nil if
-- nothing in the job's equipment currently qualifies.
function TheContractorDispatch:findOperatingVehicle(aiJob, equipmentIds)
    for _, vehicleId in ipairs(equipmentIds) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        if vehicle ~= nil and aiJob:getIsAvailableForVehicle(vehicle) then
            return vehicle
        end
    end
    return nil
end

-- Called from TheContractorAllocation:allocateJob right after a job is
-- successfully allocated to a hired worker (workerId ~= nil never reaches
-- here for a player self-allocation, see Allocation.lua), from 021's
-- watchdog retry, and from resumeJobsAfterLoad. Workers don't drive to the
-- field: the equipment is hidden straight away (it's "left the yard"), then
-- staged through update() -
--   HIDDEN  after the transport wait (game time) then HIDDEN_MS (real
--           time): TCJobSiteSetup hitches
--           the implements on and teleports the lot to the field's center,
--           still hidden
--   RIGGED  after SETTLE_MS: revealed on the field, AI job started
-- skipTransport: the worker is already out on the field (a watchdog retry,
-- or an in_progress job being resumed after load), so there's no trip to
-- make - only the physics staging runs. Otherwise a trip left over from
-- before a save/load (job.transportRemainingMs loaded with the job - 0 if
-- the save landed after arrival but before the AI started) carries on where
-- it left off rather than starting over.
--
-- A two-worker haulage job's tractor + trailer (035) are hidden here too,
-- but never staged: the hauler is synthetic, so they stay out of sight,
-- untouched, until the job's cooldown ends (or it's missed with no work
-- done - see TheContractorJobs:releaseMissedJobResources), when they go to
-- the parking return queue (062) like the rest.
function TheContractorDispatch:startJobForWorker(job, skipTransport)
    if not g_currentMission:getIsServer() then
        return
    end

    -- 032: the job's supplies go on first, out of the farm's stock. With a
    -- tank still empty (nothing in stock) or holding the wrong product, the
    -- worker doesn't go anywhere: the job's on hold until TCJobSupplies'
    -- poll finds the farm restocked and calls this again.
    -- 063: diesel is one of them, and a fresh trip out burns a little of
    -- it. Should that empty a tank (the farm's out of diesel), the second
    -- topUp is what puts the job on hold.
    local loaded, supplyStatus, supplyFillTypeName, fuelLoaded = TCJobSupplies.topUp(job)
    if supplyStatus == nil and not skipTransport and job.transportRemainingMs == nil and
        TCJobFuel.burnTravelFuel(job) then
        local reloaded, refuelled
        reloaded, supplyStatus, supplyFillTypeName, refuelled = TCJobSupplies.topUp(job)
        loaded = loaded + reloaded
        fuelLoaded = fuelLoaded + refuelled
    end
    local jobs = g_currentMission.TheContractor.Jobs
    jobs:setJobSupplyStatus(job, supplyStatus, supplyFillTypeName)
    if supplyStatus ~= nil then
        return
    end
    job.suppliesLoaded = loaded - fuelLoaded
    job.fuelLoaded = fuelLoaded

    -- The job's clock (029) starts as the worker sets off, so a slow
    -- worker's longer trip shows in their time taken. No-op when resuming
    -- after a load or retrying after a watchdog reset.
    g_currentMission.TheContractor.Jobs:markWorkStarted(job)
    -- 045: and the condition it set off in, for the skill-gap wear.
    TCJobConsequences.recordStartCondition(job)

    -- 062: a machine still waiting to be parked goes straight out from the
    -- queue - it's hidden already, and the dispatch moves it to the field.
    g_currentMission.TheContractor.Parking:removeVehicles(job:getAllEquipmentIds())

    -- Leave anything that isn't part of the job behind in the yard.
    TCJobSiteSetup.detachForeignImplements(job)

    if #job.haulageEquipmentIds > 0 then
        TCEquipmentVisibility.setVisibleEverywhere(job.haulageEquipmentIds, false)
    end

    if skipTransport then
        job.transportRemainingMs = 0
    elseif job.transportRemainingMs == nil then
        job.transportRemainingMs = TheContractorDispatch.getTransportWaitMs(job)
    end
    if job.transportRemainingMs > 0 then
        Logging.info("TheContractor: farm %d job %d on the road, arriving in %.1f min", job.farmId, job.id,
            job.transportRemainingMs / 60000)
    end

    self.pendingByJobId[job.id] = { stage = TheContractorDispatch.STAGE.HIDDEN, elapsedMs = 0 }
    TCEquipmentVisibility.setVisibleEverywhere(job.assignedEquipmentIds, false)
    TCVehicleLock.refresh()

    -- Shown as "Travelling" in the Calendar until the AI starts (or staging
    -- is called off) - cleared in cancelPending.
    if job.transportRemainingMs > 0 then
        g_currentMission.TheContractor.Jobs:setJobTravelling(job.farmId, job.id, true)
    end
end

-- Server-only, called every frame from TheContractor:update.
function TheContractorDispatch:update(dt)
    if not g_currentMission:getIsServer() then
        return
    end

    if not self.hasResumedAfterLoad then
        self.hasResumedAfterLoad = true
        self:resumeJobsAfterLoad()
    end

    local jobs = g_currentMission.TheContractor.Jobs
    for jobId, pending in pairs(self.pendingByJobId) do
        local job = jobs:getJobById(jobId)
        if job == nil or (job.state ~= TheContractorJob.STATE.ALLOCATED and
                job.state ~= TheContractorJob.STATE.IN_PROGRESS) then
            self:cancelPending(jobId, job)
            -- 062: whatever's still hidden goes to be parked.
            if job ~= nil then
                g_currentMission.TheContractor.Parking:returnHiddenVehicles(job.farmId, job:getAllEquipmentIds())
            end
        else
            -- The trip runs on game time (sped up by the time scale); the
            -- physics staging after it runs on real time.
            if job.transportRemainingMs > 0 then
                job.transportRemainingMs = math.max(0,
                    job.transportRemainingMs - dt * g_currentMission:getEffectiveTimeScale())
            else
                pending.elapsedMs = pending.elapsedMs + dt
            end

            if pending.stage == TheContractorDispatch.STAGE.HIDDEN and job.transportRemainingMs <= 0 and
                pending.elapsedMs >= TheContractorDispatch.HIDDEN_MS then
                local operatingVehicle, errorText = TCJobSiteSetup.rigAndPlace(job)
                if operatingVehicle == nil then
                    Logging.warning("TheContractor: farm %d job %d equipment couldn't be rigged: %s", job.farmId,
                        job.id, tostring(errorText))
                    self:cancelPending(jobId, job)
                    -- 062: it never got going, so it's parked. The haulage
                    -- rig stays hidden with the job, as it always has.
                    g_currentMission.TheContractor.Parking:returnVehicles(job.farmId, job.assignedEquipmentIds)
                    self:notifyDispatchFailed(job, errorText)
                else
                    pending.stage = TheContractorDispatch.STAGE.RIGGED
                    pending.elapsedMs = 0
                    -- 060: on the field - the end of the trip out.
                    g_currentMission.TheContractor.Logbook:onArrived(job)
                end
            elseif pending.stage == TheContractorDispatch.STAGE.RIGGED and
                pending.elapsedMs >= TheContractorDispatch.SETTLE_MS then
                self:cancelPending(jobId, job)
                TCEquipmentVisibility.setVisibleEverywhere(job.assignedEquipmentIds, true)
                self:startAIJob(job)
            end
        end
    end
end

-- Drops a job's staging. The equipment stays hidden: the caller reveals it
-- on the field, or sends it to the parking return queue (062), or hands it
-- to a cooldown or a fresh dispatch. Nothing goes back to where it stood.
function TheContractorDispatch:cancelPending(jobId, job)
    self.pendingByJobId[jobId] = nil
    if job ~= nil then
        job.transportRemainingMs = nil
        g_currentMission.TheContractor.Jobs:setJobTravelling(job.farmId, job.id, false)
    end
end

-- Base-game AI jobs don't survive a save/load, and a save can land
-- mid-staging - so on the first update after load, every hired-worker job
-- that should be out working gets dispatched again. An in_progress job was
-- already on its field, so it skips the trip; an allocated one either
-- carries on a saved trip (job.transportRemainingMs) or, with nothing
-- saved (e.g. its dispatch had failed), sets off again from the yard.
function TheContractorDispatch:resumeJobsAfterLoad()
    local tc = g_currentMission.TheContractor
    for _, farm in ipairs(g_farmManager:getFarms()) do
        for _, job in ipairs(tc.Jobs:getAllJobs(farm.farmId)) do
            if job.assignedWorkerId ~= nil and (job.state == TheContractorJob.STATE.ALLOCATED or
                    job.state == TheContractorJob.STATE.IN_PROGRESS) and self.aiJobByOurJobId[job.id] == nil then
                local worker = tc.Staff:getWorker(job.farmId, job.assignedWorkerId)
                if worker ~= nil then
                    Logging.info("TheContractor: farm %d job %d resuming AI dispatch after load", job.farmId, job.id)
                    self:startJobForWorker(job, job.state == TheContractorJob.STATE.IN_PROGRESS)
                end
            end
        end
    end
end

-- The AI half of dispatch, once the equipment is rigged and on the field.
-- Constructs an AIJobFieldWork against whichever assigned vehicle is
-- actually ready, validates and checks startability exactly the way the
-- base game's own AI Helper UI does, then starts it — surfacing a
-- notification instead on any failure rather than silently leaving the job
-- allocated-but-idle. Started as a direct start (isDirectStart = true), the
-- same as a player switching the AI on from the driver's seat: fieldwork
-- begins right where the vehicle stands, now inside the field
-- (AIJobFieldWork:getStartTaskIndex). A non-direct start would reuse the
-- vehicle's *previous* AI job's target position (AIJobFieldWork:
-- applyCurrentState) and drive off to whatever field that was.
function TheContractorDispatch:startAIJob(job)
    local worker = g_currentMission.TheContractor.Staff:getWorker(job.farmId, job.assignedWorkerId)

    local aiJob = g_currentMission.aiJobTypeManager:createJob(AIJobType.FIELDWORK)
    -- Our workers are paid staff wages, not the vanilla per-ms helper wage:
    -- AIJob:updateCost (server-only, per active job) only charges - and only
    -- runs its out-of-money stop - when getPricePerMs() > 0. Overridden on
    -- this instance alone, so the player's own vanilla AI helpers still pay.
    aiJob.getPricePerMs = TheContractorDispatch.getNoWagePricePerMs
    -- 046: and drive below the equipment's working speed by the operator's
    -- workSpeed (TCWorkerFieldSpeed). The operator's own, not the slowest
    -- worker's - a haulage job's hauler (035) never drives the field.
    aiJob.tcFieldSpeedFactor = TCWorkerFieldSpeed.getFactor(worker)
    local vehicle = self:findOperatingVehicle(aiJob, job.assignedEquipmentIds)
    if vehicle == nil then
        Logging.warning(
            "TheContractor: farm %d job %d has no allocated equipment ready for AI dispatch after rigging",
            job.farmId, job.id)
        self:notifyDispatchFailed(job, g_i18n:getText("tc_dispatch_noVehicleReady"))
        return
    end

    aiJob:applyCurrentState(vehicle, g_currentMission, job.farmId, true)
    aiJob:setValues()

    local isValid, validationError = aiJob:validate(job.farmId)
    if not isValid then
        Logging.warning("TheContractor: farm %d job %d AI job failed validation: %s", job.farmId, job.id,
            tostring(validationError))
        self:notifyDispatchFailed(job, tostring(validationError))
        return
    end

    -- nil connection: this call isn't on behalf of any one client's request,
    -- it's the server dispatching on its own initiative. FSBaseMission:
    -- getHasPlayerPermission already treats a nil connection as "the server
    -- itself" (an unconditional pass) when called on the server, so this
    -- still genuinely enforces the two checks that matter here —
    -- vehicle:getIsInUse() and AISystem:getAILimitedReached() — without us
    -- having to fake up a connection for a farm that may not even have a
    -- client attached to it (dedicated server, or the player simply not
    -- looking at this vehicle).
    local isStartable, startError = aiJob:getIsStartable(nil)
    if not isStartable then
        local errorText = AIJobFieldWork.getIsStartErrorText(startError)
        Logging.warning("TheContractor: farm %d job %d AI job not startable: %s", job.farmId, job.id, errorText)
        self:notifyDispatchFailed(job, errorText)
        return
    end

    self.aiJobByOurJobId[job.id] = aiJob
    self.ourJobIdByAIJob[aiJob] = job.id

    g_currentMission.aiSystem:startJob(aiJob, job.farmId)

    Logging.info("TheContractor: farm %d job %d dispatched to AI Helper on vehicle '%s' (worker %s, %d%% field speed)",
        job.farmId, job.id, vehicle:getName(), worker ~= nil and worker.name or "?", aiJob.tcFieldSpeedFactor * 100)
end

function TheContractorDispatch.getNoWagePricePerMs()
    return 0
end

-- Whether an AIJob is one of ours (a contract job's AI Helper). It's
-- registered before AISystem:startJob is called, so this already holds
-- inside a startJob hook (037's TheContractorDrivers leaves these alone).
function TheContractorDispatch:isOurAIJob(aiJob)
    return self.ourJobIdByAIJob[aiJob] ~= nil
end

-- AI_JOB_STARTED fires synchronously from inside AISystem:startJob (see
-- AISystem:startJobInternal), so this always runs within the same call
-- stack as startJobForWorker's own call above — safe to look the AIJob
-- straight back up in ourJobIdByAIJob. Ignores anything not ours (e.g. the
-- player using the vanilla AI Helper map UI directly on one of their own
-- vehicles, entirely outside our system) — that's the whole reason this
-- tracks AIJob object identity rather than assuming every AI_JOB_STARTED is
-- one of ours.
function TheContractorDispatch:onAIJobStarted(aiJob, startedFarmId)
    local ourJobId = self.ourJobIdByAIJob[aiJob]
    if ourJobId == nil then
        return
    end

    self.ourJobIdByAISystemJobId[aiJob.jobId] = ourJobId

    g_currentMission.TheContractor.Jobs:transitionJobState(startedFarmId, ourJobId, TheContractorJob.STATE.IN_PROGRESS)
end

-- Distinguishes a clean finish (AIMessageType.OK/INFO — e.g.
-- AIMessageSuccessFinishedJob) from a stuck/error condition
-- (AIMessageType.ERROR), per the ticket's own acceptance criterion. A clean
-- finish is 022's AI-worked completion trigger — handed to
-- TheContractorJobs:completeJob, which itself cross-checks against 019's
-- completion percentage (a clean stop that didn't actually finish the
-- field, e.g. the player manually stopping the AI Helper early, is a no-op
-- there rather than a payout). An error stop is 021's stuck-retry concern,
-- not this one's — left untouched here; the job's own state stays
-- `in_progress` until 021, this clean-finish path, or the existing
-- missed-deadline daily tick (Jobs.lua's onDayChanged) moves it on.
function TheContractorDispatch:onAIJobStopped(aiJob, aiMessage)
    local ourJobId = self.ourJobIdByAIJob[aiJob]
    if ourJobId == nil then
        return
    end

    local isClean = aiMessage == nil or aiMessage:getType() ~= AIMessageType.ERROR
    Logging.info("TheContractor: job %d AI job stopped (%s): %s", ourJobId, isClean and "clean" or "error",
        aiMessage ~= nil and aiMessage:getMessage(aiJob) or "no message")

    -- 032: an empty tank isn't the watchdog's business - it's a supplies
    -- problem. Forgotten here straight away (like stopJob does) so the job
    -- reads as not working, and left for TCJobSupplies' poll to refill and
    -- restart, or put on hold. An empty diesel tank (063) is the same.
    if not isClean and aiMessage.isa ~= nil and (aiMessage:isa(AIMessageErrorOutOfFill) or
            aiMessage:isa(AIMessageErrorOutOfFuel)) then
        self.ourJobIdByAIJob[aiJob] = nil
        if self.aiJobByOurJobId[ourJobId] == aiJob then
            self.aiJobByOurJobId[ourJobId] = nil
        end
        self.ranOutOfFillJobIds[ourJobId] = true
        return
    end

    if isClean then
        -- Forgotten first: it's already stopping, and completeJob stops
        -- whatever AI job is still tracked for the job (a second
        -- AISystem:stopJob on the same one would stop and broadcast twice).
        self.ourJobIdByAIJob[aiJob] = nil
        if self.aiJobByOurJobId[ourJobId] == aiJob then
            self.aiJobByOurJobId[ourJobId] = nil
        end
        local job = g_currentMission.TheContractor.Jobs:getJobById(ourJobId)
        if job ~= nil then
            g_currentMission.TheContractor.Jobs:completeJob(job)
        end
    end
end

-- AI_JOB_REMOVED only ever hands back AISystem's own numeric jobId (see
-- AISystem:delete/update), not the AIJob object the other two callbacks
-- get — ourJobIdByAISystemJobId (populated in onAIJobStarted, once that id
-- actually exists) is what bridges the two. This is where all three lookup
-- tables actually get cleaned up, since removal is the AI job's genuine
-- end-of-life (it can lag stop by a frame or more, per AISystem:update's own
-- jobsToRemove queue).
--
-- Guarded by aiJob.jobId == aiSystemJobId (021 addition): stopJob below
-- clears aiJobByOurJobId/ourJobIdByAIJob immediately rather than waiting for
-- this lagged removal event, specifically so a caller that stops and
-- immediately retriggers a fresh AI job for the same ourJobId (021's stuck
-- watchdog does exactly this) doesn't have its brand-new aiJob entry
-- clobbered when the old job's removal event finally arrives and looks
-- itself up by ourJobId. Without the guard, this would blindly nil out
-- whatever aiJob currently sits at that ourJobId — which could by then be
-- the new one, not the one actually being removed.
function TheContractorDispatch:onAIJobRemoved(aiSystemJobId)
    local ourJobId = self.ourJobIdByAISystemJobId[aiSystemJobId]
    if ourJobId == nil then
        return
    end

    local aiJob = self.aiJobByOurJobId[ourJobId]
    if aiJob ~= nil and aiJob.jobId == aiSystemJobId then
        self.ourJobIdByAIJob[aiJob] = nil
        self.aiJobByOurJobId[ourJobId] = nil
    end

    self.ourJobIdByAISystemJobId[aiSystemJobId] = nil
end

-- Stops the AI job currently tracked for ourJobId, if any (a no-op if the
-- job already finished/was removed, or was never dispatched at all — e.g. a
-- player self-allocated job, which never enters these lookup tables), or
-- abandons its dispatch staging if it hasn't got that far yet. Used by
-- 021's stuck watchdog ahead of retriggering a fresh dispatch for the same
-- job, and by 024's missed-job release. aiMessage defaults to a generic unknown-
-- error stop if the caller doesn't have anything more specific (AISystem:
-- stopJob requires a non-nil AIMessage — see AISystem:delete's own
-- AIMessageErrorUnknown.new() fallback for the same reason).
--
-- Clears this subsystem's own lookups for the stopped aiJob immediately,
-- rather than waiting for AI_JOB_REMOVED (which can lag a frame or more) —
-- see onAIJobRemoved's guard comment for why an immediate retrigger would
-- otherwise be unsafe.
function TheContractorDispatch:stopJob(jobId, aiMessage)
    if not g_currentMission:getIsServer() then
        return
    end

    -- Still mid-staging: nothing running yet, just drop the staging. The
    -- equipment stays hidden for the caller to deal with (cancelPending).
    if self.pendingByJobId[jobId] ~= nil then
        self:cancelPending(jobId, g_currentMission.TheContractor.Jobs:getJobById(jobId))
    end

    local aiJob = self.aiJobByOurJobId[jobId]
    if aiJob == nil then
        return
    end

    g_currentMission.aiSystem:stopJob(aiJob, aiMessage or AIMessageErrorUnknown.new())

    self.ourJobIdByAIJob[aiJob] = nil
    self.aiJobByOurJobId[jobId] = nil
end

-- Supplies (032) ------------------------------------------------------------

-- Whether a job has a worker out: its equipment on the road/being staged,
-- or its AI Helper running.
function TheContractorDispatch:isJobActive(job)
    return self.pendingByJobId[job.id] ~= nil or self.aiJobByOurJobId[job.id] ~= nil
end

-- Whether a job's AI Helper is running (past staging, actually working).
function TheContractorDispatch:isJobWorking(job)
    return self.pendingByJobId[job.id] == nil and self.aiJobByOurJobId[job.id] ~= nil
end

-- Server-only: stops a working job's AI Helper for want of supplies - the
-- worker stays on the field, the job in_progress, until TCJobSupplies'
-- poll restarts it (startJobForWorker, skipping the trip).
function TheContractorDispatch:pauseForSupplies(job)
    Logging.info("TheContractor: farm %d job %d on hold for supplies (%s %s)", job.farmId, job.id,
        tostring(job.supplyStatus), tostring(job.supplyFillTypeName))
    self:stopJob(job.id, AIMessageErrorOutOfFill.new())
    self.ranOutOfFillJobIds[job.id] = nil
end

-- Whether a job's AI stopped itself on an empty tank since last asked.
function TheContractorDispatch:takeRanOutOfFill(jobId)
    local ranOut = self.ranOutOfFillJobIds[jobId] == true
    self.ranOutOfFillJobIds[jobId] = nil
    return ranOut
end

-- Notification plumbing --------------------------------------------------

-- Surfaces a dispatch failure to the player (ticket AC: "surface a sensible
-- error ... don't attempt to bypass" the base game's own gating). Applied
-- directly here for the server/host's own local notification, then
-- broadcast via TCDispatchFailedEvent for any other client on the farm —
-- same "no SP loopback" shape TCJobMissedEvent already uses (see
-- src/events/README.md).
function TheContractorDispatch:notifyDispatchFailed(job, reasonText)
    TCDispatchFailedEvent.showNotification(job.farmId, job.jobType, job.fieldId, reasonText)

    if g_server ~= nil then
        g_server:broadcastEvent(TCDispatchFailedEvent.new(job.farmId, job.jobType, job.fieldId, reasonText))
    end
end
