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
        -- Allocated -> completed directly (022) covers a player-driven job:
        -- nothing ever flips it to in_progress (that transition is 020's
        -- Dispatch, hired-worker-only), so a player just drives it and 019's
        -- completion percentage crossing the finished threshold is the only
        -- signal that it's done.
        [TheContractorJob.STATE.COMPLETED] = true,
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
    -- The price as first offered, before any negotiation (026): the
    -- baseline TheContractorNegotiation measures counters against.
    self.offeredPrice = price

    self.state = TheContractorJob.STATE.OFFERED
    self.assignedWorkerId = nil
    self.assignedEquipmentIds = {}
    self.completionPercentage = 0
    self.paymentAmount = nil

    -- Hidden per-job negotiation mechanic (014) — never shown to the player.
    -- Degrades each negotiation round; hitting 0 means the NPC walks away
    -- regardless of the counter offered. See TheContractorNegotiation for
    -- the starting range and degradation curve.
    self.eagerness = TheContractorNegotiation.rollInitialEagerness()
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

    -- Crop-dependent jobs (harvest) only: the crop on the field when the
    -- job was generated, by fruit type name. nil for everything else, and
    -- for harvest jobs saved before this existed (see getFruitTypeIndex).
    self.fruitTypeName = nil

    -- Absolute (monotonic, never wraps) day the job is due by the end of —
    -- what 024's miss check actually compares against. targetPeriod/
    -- targetDayInPeriod above are the same day in calendar form, for
    -- display and calendar grouping.
    self.deadlineDay = nil

    -- Hired-worker jobs only (020): where each piece of allocated equipment
    -- stood before dispatch took it to the field, so it can go back there
    -- when the job's done - { { vehicleId, components = { {pos}, {rot} }... } }.
    -- Server-only, never sent to clients. See TCJobSiteSetup.recordHome/
    -- returnHome.
    self.equipmentHome = nil

    -- Hired-worker jobs only (020): true while the worker and equipment are
    -- on the road to the field (Dispatch's transport wait), still `allocated`
    -- until the AI starts and flips it to `in_progress`. Display-only, synced
    -- via TCJobTravellingEvent but never saved - Dispatch:resumeJobsAfterLoad
    -- sets it again when it picks the trip back up.
    self.isTravelling = false

    -- Hired-worker jobs only (020): game-time ms left on the trip to the
    -- field, set while Dispatch is staging the job (0 once arrived, nil
    -- otherwise). Server-only, never sent to clients; saved with the job so
    -- a save mid-trip resumes rather than restarting it.
    self.transportRemainingMs = nil

    -- Harvest jobs only (035): the client wants the crop carted away too,
    -- not just the field combined - a two-person job. Rolled at generation,
    -- priced/rewarded higher (TheContractorJobGeneration.HAULAGE_*).
    -- Allocated either to the player alone, who hauls the crop to
    -- deliveryStation themselves, or to two hired workers, where the
    -- carting is synthetic (TCHaulage).
    self.includesHaulage = false

    -- Two-worker haulage jobs only: the worker doing the carting, alongside
    -- assignedWorkerId on the combine, and the tractor + trailer they took.
    -- Never shown on the field - the haulage equipment stays hidden in the
    -- yard for the whole job and its cooldown, and is never rigged.
    self.haulerWorkerId = nil
    self.haulageEquipmentIds = {}

    -- Haulage jobs only: the selling point the crop has to go to, picked at
    -- generation like vanilla's HarvestMission (highest price). Stored the
    -- way vanilla saves it - owning placeable's uniqueId + unloading station
    -- index - and resolved lazily by TCHaulage, server-only. The name is
    -- display-only, and is what clients get.
    self.deliveryStationUniqueId = nil
    self.deliveryStationIndex = nil
    self.deliveryStationName = nil

    -- Player-driven haulage jobs only: litres that have to reach the
    -- delivery station (set at allocation) and litres delivered so far.
    -- Server-authoritative, synced via TCJobDeliveryEvent.
    self.requiredLiters = 0
    self.deliveredLiters = 0

    -- Completion summary (029), all server-authoritative and sent to
    -- clients in the job snapshot. workStartedAt/completedAt are absolute
    -- in-game minutes (TheContractorJobs.getGameMinutes): work starts when
    -- a hired worker sets off (Dispatch) or, for a player-driven job, at
    -- the first field progress seen. Fuel is what the job's own equipment
    -- actually burned once work had started (TCJobFuel), priced as it was
    -- burned. stuckInterventions counts 021's watchdog resets/escalations.
    -- qualityScore (0-100) is set on completion - see
    -- TheContractorJobs:calculateQualityScore.
    self.workStartedAt = nil
    self.completedAt = nil
    self.fuelUsedLiters = 0
    self.fuelCost = 0
    self.stuckInterventions = 0
    self.qualityScore = nil

    return self
end

-- In-game minutes from work starting to completion, or nil if either end
-- wasn't recorded (e.g. completed before 029 existed).
function TheContractorJob:getTimeTakenMinutes()
    if self.workStartedAt == nil or self.completedAt == nil then
        return nil
    end
    return math.max(0, self.completedAt - self.workStartedAt)
end

-- "2h 05m" style, or "-" when there's nothing to show.
function TheContractorJob.formatMinutes(minutes)
    if minutes == nil then
        return "-"
    end
    local rounded = math.floor(minutes + 0.5)
    return string.format(g_i18n:getText("tc_summary_duration"), math.floor(rounded / 60), rounded % 60)
end

-- One-line completion summary (029): "<title> on <field>: 2h 05m, fuel
-- €340 (120 l), quality 86%". Shared by the completion notification and
-- the Overview tab's last-job line.
function TheContractorJob:getSummaryText()
    local field = g_fieldManager:getFieldById(self.fieldId)
    return string.format(g_i18n:getText("tc_summary_line"), self:getDisplayTitle(),
        field ~= nil and field:getName() or tostring(self.fieldId),
        TheContractorJob.formatMinutes(self:getTimeTakenMinutes()),
        g_i18n:formatMoney(self.fuelCost, 0, true, true), self.fuelUsedLiters, self.qualityScore or 0)
end

-- The player's farm is doing the carting itself: a haulage job allocated
-- to the player (no worker) has to have its crop delivered before it can
-- complete (see TCHaulage / TheContractorJobs:completeJob).
function TheContractorJob:needsPlayerDelivery()
    return self.includesHaulage and self.assignedWorkerId == nil
end

-- Every hired worker on the job - the operator, plus the hauler on a
-- two-worker haulage job. Empty for a player-driven job.
function TheContractorJob:getWorkerIds()
    local ids = {}
    if self.assignedWorkerId ~= nil then
        table.insert(ids, self.assignedWorkerId)
    end
    if self.haulerWorkerId ~= nil then
        table.insert(ids, self.haulerWorkerId)
    end
    return ids
end

-- Every vehicle the job holds - the rigged field equipment plus any hidden
-- haulage equipment.
function TheContractorJob:getAllEquipmentIds()
    local ids = {}
    for _, id in ipairs(self.assignedEquipmentIds) do
        table.insert(ids, id)
    end
    for _, id in ipairs(self.haulageEquipmentIds) do
        table.insert(ids, id)
    end
    return ids
end

-- Falls back to the field's current crop for a harvest job that predates
-- fruitTypeName being recorded.
function TheContractorJob:getFruitTypeIndex()
    local fruitTypeName = self.fruitTypeName
    if fruitTypeName == nil and TheContractorJobGeneration.JOB_TYPES[self.jobType] ~= nil and
        TheContractorJobGeneration.JOB_TYPES[self.jobType].cropDependent then
        fruitTypeName = TheContractorJobGeneration.getFieldFruitTypeName(g_fieldManager:getFieldById(self.fieldId))
    end
    return TheContractorJobGeneration.getFruitTypeIndexByName(fruitTypeName)
end

-- Localized crop name ("Spinach"), or nil if the job has no crop.
function TheContractorJob:getCropTitle()
    local fruitTypeIndex = self:getFruitTypeIndex()
    if fruitTypeIndex == nil then
        return nil
    end
    local fillType = g_fruitTypeManager:getFillTypeByFruitTypeIndex(fruitTypeIndex)
    return fillType ~= nil and fillType.title or nil
end

-- "Harvest", "Cultivate", ... - or "Harvest & Haul" for a haulage job.
function TheContractorJob:getTypeText()
    return g_i18n:getText("tc_jobType_" .. self.jobType .. (self.includesHaulage and "Haul" or ""))
end

-- "Harvest (Spinach)" for crop jobs, plain "Cultivate" otherwise, and
-- "Harvest & Haul (Spinach)" for a haulage job.
function TheContractorJob:getDisplayTitle()
    local typeText = self:getTypeText()
    local cropTitle = self:getCropTitle()
    if cropTitle == nil then
        return typeText
    end
    return string.format("%s (%s)", typeText, cropTitle)
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
