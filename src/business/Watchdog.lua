-- Stuck-detection watchdog (021): detects a hired AI worker wedged on
-- geometry using 019's job *completion percentage*, not vehicle stillness —
-- a vehicle can jitter in place just enough to fool a stillness check, but
-- a genuinely stuck vehicle's field-completion percentage won't move
-- (Q18, agreed). Only ever watches jobs allocated to a hired worker
-- (assignedWorkerId ~= nil) that are actually in_progress via 020's AI
-- dispatch — a player driving personally isn't watched at all, same
-- operator-gating 020 itself uses.
--
-- This supplements, not replaces, the base game's own short-term recovery
-- (AIFieldWorker's 5-second static-collision timer, which already
-- self-recovers the common transient blockage well before this watchdog's
-- much longer window would ever trigger) — see the brief's own "sometimes
-- bomb out... reset them to the middle of the field and trigger the AI
-- again" framing.
--
-- No state of its own to persist: trackedByJobId only ever holds live
-- "how long has this job's progress been flat" counters, meaningless across
-- a save/load boundary (a fresh load also means a fresh AI job with a fresh
-- 5-minute grace period) — same "live cache, not persisted state" reasoning
-- TCJobProgress's scan-state cache and Dispatch's AIJob lookup tables use.

TheContractorWatchdog = {}
TheContractorWatchdog_mt = Class(TheContractorWatchdog)

-- Configurable tunable per the ticket's own AC ("expose as a tunable, not
-- hardcoded deep in logic") — how long a job's completion percentage can go
-- unchanged before it's treated as stuck. Reviewed in 026 and kept.
TheContractorWatchdog.STUCK_TIMEOUT_MINUTES = 5

-- Retries attempted (reset + retrigger) before giving up and escalating to
-- a "needs your attention" notification instead of retrying forever (the
-- ticket's own infinite-loop guard).
TheContractorWatchdog.MAX_RETRIES_PER_JOB = 2

-- No benefit checking more often than 019's own background tracker actually
-- refreshes completionPercentage — reuses TCJobProgress's cadence rather
-- than inventing a second, unrelated poll interval.
TheContractorWatchdog.CHECK_INTERVAL_MS = TCJobProgress.POLL_INTERVAL_MS

-- Completion percentage (0-100 scale, matching Job.lua) has to move by more
-- than this to count as "real" progress, not float noise from the
-- partitioned density-map scan settling.
TheContractorWatchdog.PROGRESS_EPSILON = 0.01

function TheContractorWatchdog.new()
    local self = {}
    setmetatable(self, TheContractorWatchdog_mt)

    -- jobId -> { lastPercentage, elapsedStuckMs, retryCount, needsAttention }
    self.trackedByJobId = {}
    self.accumulatedMs = 0

    return self
end

-- Called from TheContractor:update(dt) every frame; only actually checks
-- once accumulatedMs crosses CHECK_INTERVAL_MS. Server-only: intervening
-- (stopping/repositioning/retriggering an AI job) is only ever legal
-- server-side, same restriction 020's Dispatch itself has.
-- A farm deleted in multiplayer (TCFarmDeletion), on every machine.
function TheContractorWatchdog:forgetFarm(farmId, jobIds)
    for _, jobId in ipairs(jobIds) do
        self.trackedByJobId[jobId] = nil
    end
end

function TheContractorWatchdog:update(dt)
    if not g_currentMission:getIsServer() then
        return
    end

    self.accumulatedMs = self.accumulatedMs + dt
    if self.accumulatedMs < TheContractorWatchdog.CHECK_INTERVAL_MS then
        return
    end
    self.accumulatedMs = 0

    self:checkActiveJobs()
end

-- Sweeps every farm's in_progress, hired-worker jobs, updating/checking each
-- one's stuck timer, then purges tracking for anything no longer in that
-- state (job completed/missed, or reassigned) so this doesn't accumulate
-- entries for jobs that have long since moved on.
function TheContractorWatchdog:checkActiveJobs()
    local tc = g_currentMission.TheContractor
    if tc == nil or tc.Jobs == nil then
        return
    end

    local activeJobIds = {}

    -- A job on hold for supplies (032) isn't stuck, it's waiting on the
    -- farm - left out, so it gets a fresh grace period once it's back at
    -- work.
    for _, farm in ipairs(g_farmManager:getFarms()) do
        for _, job in ipairs(tc.Jobs:getJobsByState(farm.farmId, TheContractorJob.STATE.IN_PROGRESS)) do
            if job.assignedWorkerId ~= nil and not job:isWaitingForSupplies() then
                activeJobIds[job.id] = true
                self:checkJob(job)
            end
        end
    end

    for jobId in pairs(self.trackedByJobId) do
        if not activeJobIds[jobId] then
            self.trackedByJobId[jobId] = nil
        end
    end
end

-- Advances (or initializes) one job's stuck timer against its current
-- completionPercentage (kept live by 019's TCJobProgress, already refreshed
-- on the same machine before this runs — see TheContractor:update's call
-- order). Fires handleStuckJob once the timeout is crossed with no real
-- progress since the timer last reset.
function TheContractorWatchdog:checkJob(job)
    local entry = self.trackedByJobId[job.id]
    if entry == nil then
        entry = { lastPercentage = job.completionPercentage, elapsedStuckMs = 0, retryCount = 0, needsAttention = false }
        self.trackedByJobId[job.id] = entry
    end

    if job.completionPercentage > entry.lastPercentage + TheContractorWatchdog.PROGRESS_EPSILON then
        entry.lastPercentage = job.completionPercentage
        entry.elapsedStuckMs = 0
        return
    end

    -- Already escalated and waiting on the player - keep tracking progress
    -- above (a player manually freeing the vehicle should still clear the
    -- stuck state), but don't re-fire the escalation notification every
    -- check pass.
    if entry.needsAttention then
        return
    end

    entry.elapsedStuckMs = entry.elapsedStuckMs + TheContractorWatchdog.CHECK_INTERVAL_MS
    if entry.elapsedStuckMs >= TheContractorWatchdog.STUCK_TIMEOUT_MINUTES * 60000 then
        self:handleStuckJob(job, entry)
    end
end

-- Reset-and-retrigger intervention (per the brief: "reset them to the
-- middle of the field and then trigger the AI again"), capped at
-- MAX_RETRIES_PER_JOB before giving up and leaving the job for the player to
-- sort out by hand rather than retrying forever (the ticket's own guard).
-- Deliberately doesn't touch Job.lua's state machine (008) for the
-- escalated case - there's no "needs attention" job state, and adding one
-- would be 022/024's call to make, not this ticket's; a stuck-and-abandoned
-- job just stays `in_progress` with no further AI job running until either
-- the player intervenes (re-allocates/reposition manually) or it eventually
-- hits Jobs.lua's own missed-deadline sweep.
function TheContractorWatchdog:handleStuckJob(job, entry)
    entry.retryCount = entry.retryCount + 1
    -- Persisted on the job itself (unlike retryCount, which is live-only):
    -- feeds its quality score at completion (029).
    job.stuckInterventions = job.stuckInterventions + 1

    if entry.retryCount > TheContractorWatchdog.MAX_RETRIES_PER_JOB then
        entry.needsAttention = true
        TCLog.warning(
            "TheContractor: farm %d job %d stuck watchdog exhausted %d retries - needs player attention",
            job.farmId, job.id, TheContractorWatchdog.MAX_RETRIES_PER_JOB)
        self:notify(job, true)
        return
    end

    TCLog.info(
        "TheContractor: farm %d job %d appears stuck (no field progress for %d min) - resetting and retrying (%d/%d)",
        job.farmId, job.id, TheContractorWatchdog.STUCK_TIMEOUT_MINUTES, entry.retryCount,
        TheContractorWatchdog.MAX_RETRIES_PER_JOB)

    -- A fresh dispatch re-rigs the equipment and teleports it back to the
    -- field's center (TCJobSiteSetup) before restarting the AI.
    g_currentMission.TheContractor.Dispatch:stopJob(job.id, AIMessageErrorBlockedByObject.new())

    local worker = g_currentMission.TheContractor.Staff:getWorker(job.farmId, job.assignedWorkerId)
    if worker ~= nil then
        g_currentMission.TheContractor.Dispatch:startJobForWorker(job, true)
    end

    entry.elapsedStuckMs = 0

    self:notify(job, false)
end

-- Applies directly here for the server/host's own local notification, then
-- broadcasts via TCWatchdogInterventionEvent for any other client on the
-- farm - same "no SP loopback" shape TCJobMissedEvent/TCDispatchFailedEvent
-- already use (see src/events/README.md).
function TheContractorWatchdog:notify(job, isEscalation)
    TCWatchdogInterventionEvent.showNotification(job.farmId, job:getTypeLabel(), job.fieldId, isEscalation)

    if g_server ~= nil then
        g_server:broadcastEvent(TCWatchdogInterventionEvent.new(job.farmId, job:getTypeLabel(), job.fieldId, isEscalation))
    end
end
