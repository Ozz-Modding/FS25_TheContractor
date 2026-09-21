-- Single job entity and its state machine. Central data structure that
-- generation (011), inbox (013), negotiation (014), calendar (015),
-- allocation (018), progress tracking (019), and completion/missed
-- handling (022/024) all attach to — this file only owns the shape and the
-- legal state transitions, not anything that creates or drives jobs (see
-- TheContractorJobs in Jobs.lua for that).
--
-- targetDate (targetPeriod + targetDayInPeriod) is fixed once the job is
-- created (Q23) — only price is renegotiable (014), and that's not enforced
-- here either, just a plain field later tickets read/write through
-- TheContractorJobs. Acceptance and allocation are decoupled (Q25): an
-- `accepted` job has a committed targetDate but assignedWorkerId/
-- assignedEquipmentIds stay nil/empty until allocation (018) happens,
-- separately and possibly same-day.

TheContractorJob = {}
TheContractorJob_mt = Class(TheContractorJob)

TheContractorJob.STATE = {
    OFFERED = "offered",
    NEGOTIATING = "negotiating",
    ACCEPTED = "accepted",
    ALLOCATED = "allocated",
    IN_PROGRESS = "in_progress",
    COMPLETED = "completed",
    DECLINED = "declined",
    MISSED = "missed",
}

-- Legal transitions, keyed by current state -> set of allowed next states.
-- offered can go straight to accepted (accepting an offer with no
-- negotiation) or via negotiating first; accepted/allocated/in_progress can
-- all be knocked into missed (hard deadline at end of target day, Q26).
-- completed/declined/missed are terminal — no way out.
TheContractorJob.VALID_TRANSITIONS = {
    [TheContractorJob.STATE.OFFERED] = {
        [TheContractorJob.STATE.NEGOTIATING] = true,
        [TheContractorJob.STATE.ACCEPTED] = true,
        [TheContractorJob.STATE.DECLINED] = true,
    },
    [TheContractorJob.STATE.NEGOTIATING] = {
        [TheContractorJob.STATE.ACCEPTED] = true,
        [TheContractorJob.STATE.DECLINED] = true,
    },
    [TheContractorJob.STATE.ACCEPTED] = {
        [TheContractorJob.STATE.ALLOCATED] = true,
        [TheContractorJob.STATE.MISSED] = true,
    },
    [TheContractorJob.STATE.ALLOCATED] = {
        [TheContractorJob.STATE.IN_PROGRESS] = true,
        [TheContractorJob.STATE.MISSED] = true,
    },
    [TheContractorJob.STATE.IN_PROGRESS] = {
        [TheContractorJob.STATE.COMPLETED] = true,
        [TheContractorJob.STATE.MISSED] = true,
    },
    [TheContractorJob.STATE.COMPLETED] = {},
    [TheContractorJob.STATE.DECLINED] = {},
    [TheContractorJob.STATE.MISSED] = {},
}

function TheContractorJob.new(id, farmId, jobType, fieldId, requiredSkillLevel, targetPeriod, targetDayInPeriod, price)
    local self = {}
    setmetatable(self, TheContractorJob_mt)

    self.id = id
    self.farmId = farmId
    self.jobType = jobType
    self.fieldId = fieldId
    self.requiredSkillLevel = requiredSkillLevel
    self.targetPeriod = targetPeriod
    self.targetDayInPeriod = targetDayInPeriod
    self.price = price

    self.state = TheContractorJob.STATE.OFFERED
    self.assignedWorkerId = nil
    self.assignedEquipmentIds = {}
    self.completionPercentage = 0
    self.paymentAmount = nil

    -- Hidden per-job negotiation mechanic (014) — never shown to the player.
    -- Degrades each negotiation round; hitting 0 means the NPC walks away
    -- regardless of the counter offered. Initial value/degradation amount
    -- are placeholders (see TheContractorNegotiation), exact formula
    -- deferred to 026 — only the field and its lifecycle need to exist now.
    self.eagerness = TheContractorNegotiation.INITIAL_EAGERNESS
    -- Rounds of counter-offers made so far, enforced against
    -- TheContractorNegotiation.MAX_ROUNDS regardless of eagerness (Q12's
    -- hard safety cap, keeping the negotiation finite even if the
    -- eagerness math never bottoms out).
    self.negotiationRounds = 0

    -- Whether the farm's currently-owned equipment can fulfill this job,
    -- per 009's classification. Set by whoever creates the job (011's
    -- generation engine computes the real answer; debug/test creation just
    -- leaves the default). Flagged, not filtered (011 Q15) — the job is
    -- still generated and shown either way, this is display-only pressure
    -- toward buying better equipment, not a gate on offer creation.
    self.equipmentAvailable = true

    return self
end

function TheContractorJob:canTransitionTo(newState)
    local allowed = TheContractorJob.VALID_TRANSITIONS[self.state]
    return allowed ~= nil and allowed[newState] == true
end

-- Flips state if legal, returns true/false. Callers (TheContractorJobs) own
-- persistence/broadcast — this is just the state-machine guard.
function TheContractorJob:transitionTo(newState)
    if not self:canTransitionTo(newState) then
        Logging.warning("TheContractor: job %s illegal transition %s -> %s", tostring(self.id), self.state,
            tostring(newState))
        return false
    end

    self.state = newState
    return true
end
