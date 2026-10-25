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
        -- 100: a workshop job (job.workshop) has no crew to allocate; it's
        -- done when ADS says the customer's machine is.
        [TheContractorJob.STATE.COMPLETED] = true,
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
        -- 094: unallocated (TheContractorJobs:unallocateJob), to be given
        -- to someone else.
        [TheContractorJob.STATE.ACCEPTED] = true,
    },
    [TheContractorJob.STATE.IN_PROGRESS] = {
        [TheContractorJob.STATE.ACCEPTED] = true,
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
    -- Both prices are stored without FS25_EconomyScale's factor and read
    -- through getPrice/getOfferedPrice, which apply it, so a job that
    -- hasn't been paid yet follows that mod's setting the way a vanilla
    -- contract's reward does. paymentAmount fixes it at completion.
    self.basePrice = price
    -- The price as first offered, before any negotiation (026): the
    -- baseline TheContractorNegotiation measures counters against.
    self.baseOfferedPrice = price

    self.state = TheContractorJob.STATE.OFFERED
    self.assignedWorkerId = nil
    -- Vehicle network object ids, like every vehicle list here; saved by
    -- uniqueId (TCVehicleIds).
    self.assignedEquipmentIds = {}
    self.completionPercentage = 0
    self.paymentAmount = nil
    -- 049: the day the job's invoice is expected to be paid (monotonic),
    -- shown in its summary. nil when it was paid on completion (late/unpaid
    -- invoices switched off, or a job from before invoices existed).
    self.invoiceDueDay = nil

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

    -- Job types that record their crop (JOB_TYPES' recordsCrop - harvest,
    -- mow, bale) only: the crop on the field when the job was generated, by
    -- fruit type name. nil for everything else, and for harvest jobs saved
    -- before this existed (see getFruitTypeIndex).
    self.fruitTypeName = nil

    -- Absolute (monotonic, never wraps) day the job is due by the end of —
    -- what 024's miss check actually compares against. targetPeriod/
    -- targetDayInPeriod above are the same day in calendar form, for
    -- display and calendar grouping.
    self.deadlineDay = nil

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

    -- Hired-worker jobs only (032): how much supply the worker just loaded
    -- setting off (TCJobSupplies.topUp), which the trip's loading time is
    -- worked out from. Server-only, transient. fuelLoaded is the diesel,
    -- kept apart since refuelling takes a flat time.
    self.suppliesLoaded = nil
    self.fuelLoaded = nil

    -- Harvest jobs (035): the client wants the crop carted away too, not
    -- just the field combined - a two-person job. Rolled at generation,
    -- priced/rewarded higher (TheContractorJobGeneration.HAULAGE_*).
    -- Allocated either to the player alone, who hauls the crop to
    -- deliveryStation themselves, or to two hired workers, where the
    -- carting is synthetic (TCHaulage). 067: a straw bale job can roll it
    -- too (bale & deliver), and a straw delivery always has it - both the
    -- player's alone (TheContractorJobGeneration.isPlayerOnly).
    self.includesHaulage = false

    -- Two-worker haulage jobs only: the worker doing the carting, alongside
    -- assignedWorkerId on the combine, and the tractor + trailer they took.
    -- Never shown on the field - the haulage equipment stays hidden in the
    -- yard for the whole job and its cooldown, and is never rigged.
    self.haulerWorkerId = nil
    self.haulageEquipmentIds = {}

    -- 093: a player-driven job's player, by nickname: whoever allocated it
    -- (TCAllocateJobEvent's connection). In multiplayer any of the farm's
    -- players can drive it; the logbook records who did. Saved and
    -- streamed, nil for a hired crew and for jobs allocated before 093.
    self.allocatedPlayerName = nil

    -- 094, server-only, saved: the job's been unallocated since its field
    -- was prepared, so the next allocation carries on from the work done
    -- (no fresh field, no progress reset). Cleared by that allocation.
    self.wasUnallocated = false

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

    -- 032: the field state the job starts from, for job types that record
    -- one (JOB_TYPES' startState - fertilize's spray level, the weed state
    -- for herbicide/weed/hoe). Recorded at generation, put back at
    -- allocation (TCFieldPreparation), and what fertilize/herbicide
    -- progress is measured against, so it's sent to clients too.
    self.startState = nil

    -- 072, server-only, saved: a joyrider plow job leaves its field as it is
    -- at allocation (TCFieldPreparation), ruts and grass and all, and may
    -- lead to a grass sow job when it's done (TheContractorJoyriders:
    -- onJobCompleted).
    self.keepFieldState = false
    self.followOnSow = false

    -- 032, server-only, saved: the baseline a serverMeasured job's progress
    -- is measured against, set once its field has been prepared at
    -- allocation - litres of windrow spawned (tedder/bale), weed area at the
    -- start (weed/hoe), bales spawned (bale wrap, straw delivery). nil
    -- until then. 075: a fly-tipping job's pile size, set at creation.
    self.workTotal = nil
    -- Bale wrap and straw delivery only (server-only, saved): uniqueIds of
    -- the bales spawned for the job, removed again once it's over.
    self.spawnedBaleIds = {}
    -- 075, fly-tipping only (server-only, saved): item uniqueIds of the
    -- pile's pieces still out there (a piece taken to a skip comes off),
    -- and how many have been taken. workTotal is the pile's size.
    self.debrisIds = {}
    self.debrisDisposed = 0

    -- 076: real-time ms left in a completed player-driven job's grace
    -- period (TheContractorJobs.GRACE_PERIOD_MS), while its field can still
    -- be worked to finish it off. nil otherwise. Counted down on every
    -- machine, sent to clients and saved.
    self.graceRemainingMs = nil

    -- 032: why work is on hold for supplies, or nil - "noStock" (the farm
    -- is out of what the job's equipment needs) or "wrongFill" (a tank
    -- holds something else). supplyFillTypeName is the product concerned.
    -- Server-authoritative, re-derived every TCJobSupplies poll (so not
    -- saved), synced via TCJobSupplyStatusEvent.
    self.supplyStatus = nil
    self.supplyFillTypeName = nil

    -- 044: the worker operation skill the work uses (a
    -- TheContractorWorker.SKILLS key), decided once at creation by
    -- TheContractorJobGeneration.getOperationSkill - a sow job's seeding or
    -- planting depends on the field's planned crop, which could change
    -- later. Sent to clients; see getOperationSkill for older saves.
    self.operationSkill = nil

    -- 045 (see TCJobConsequences): hired-worker jobs only. startCondition
    -- is each piece of equipment's damage/wear when the worker set off -
    -- { [vehicleId] = { damage, wear, adsCondition } }, adsCondition only
    -- for a machine ADS manages (080 reads it for job quality) -
    -- server-only, saved while the job runs. workerReports is what each worker did to the machines (extra
    -- wear, washed or not), set on completion, sent to clients and saved.
    -- washVehicleIds (server-only, saved) is what gets washed when the
    -- cooldown ends; washMinutes (server-only, transient) the washing time
    -- the cooldown adds.
    self.startCondition = nil
    self.workerReports = {}
    self.washVehicleIds = nil
    self.washMinutes = nil

    -- 100: a workshop job's customer machine and contract, nil for every
    -- other job (TheContractorRepairContracts; fieldId is 0). Sent to
    -- clients: vehicleId, vehicleName, kind, severity, offerExpiresDay,
    -- quotePrice (ADS's quote at the price level of the day it was made),
    -- partsCost (the parts and materials in it, which the price is worked
    -- out from; nil on a job from before it was kept), acceptedAt (game
    -- minutes, for the speed reputation; nil until accepted), requiredTools, serviceLevel, operatingHours, bayIndex, and
    -- 101's fieldId (a breakdown's field, nil otherwise; its serviceLevel is
    -- ADS's field service, "player" or "mobile"). Saved too, and
    -- server-only: vehicleUniqueId, zoneUniqueId.
    self.workshop = nil

    return self
end

-- 100: a workshop job (a customer's machine in a repair zone), not field
-- work.
function TheContractorJob:isWorkshop()
    return self.workshop ~= nil
end

-- Where the job is, for lines that would name its field: the field's name,
-- or a workshop job's machine (and a breakdown's field, 101).
function TheContractorJob:getLocationText()
    if self.workshop ~= nil then
        if self.workshop.fieldId ~= nil then
            local field = g_fieldManager:getFieldById(self.workshop.fieldId)
            return string.format(g_i18n:getText("tc_breakdown_location"), self.workshop.vehicleName or "?",
                field ~= nil and field:getName() or tostring(self.workshop.fieldId))
        end
        return self.workshop.vehicleName or "?"
    end
    local field = g_fieldManager:getFieldById(self.fieldId)
    return field ~= nil and field:getName() or tostring(self.fieldId)
end

-- 044: operationSkill, worked out on first use for a job from before it
-- was recorded.
function TheContractorJob:getOperationSkill()
    if self.operationSkill == nil then
        self.operationSkill = TheContractorJobGeneration.getOperationSkill(self.jobType, self.fieldId)
    end
    return self.operationSkill
end

-- 044: "Planting", "Harvesting", ... or nil if the job type has no skill.
function TheContractorJob:getOperationSkillText()
    local skill = self:getOperationSkill()
    return skill ~= nil and g_i18n:getText("tc_skill_" .. skill) or nil
end

-- Whether work on the job is on hold waiting for supplies (032).
function TheContractorJob:isWaitingForSupplies()
    return self.supplyStatus ~= nil
end

-- "Seeds", "Liquid fertilizer" - the product a supply status is about.
function TheContractorJob:getSupplyFillTypeTitle()
    local fillTypeIndex = self.supplyFillTypeName ~= nil and
        g_fillTypeManager:getFillTypeIndexByName(self.supplyFillTypeName) or nil
    return fillTypeIndex ~= nil and g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex) or
        tostring(self.supplyFillTypeName)
end

-- Player-facing "Waiting for Seeds" / "Tank holds Herbicide" line.
function TheContractorJob:getSupplyStatusText()
    if self.supplyStatus == nil then
        return nil
    end
    return string.format(g_i18n:getText("tc_supplies_status_" .. self.supplyStatus), self:getSupplyFillTypeTitle())
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
    -- 100: no field, fuel or crew time to speak of.
    if self.workshop ~= nil then
        return string.format(g_i18n:getText("tc_repair_summaryLine"), self:getTypeText(),
            self.workshop.vehicleName or "?")
    end
    local field = g_fieldManager:getFieldById(self.fieldId)
    return string.format(g_i18n:getText("tc_summary_line"), self:getDisplayTitle(),
        field ~= nil and field:getName() or tostring(self.fieldId),
        TheContractorJob.formatMinutes(self:getTimeTakenMinutes()),
        g_i18n:formatMoney(self.fuelCost, 0, true, true), self.fuelUsedLiters, self.qualityScore or 0)
end

-- The price at FS25_EconomyScale's price level (TCEconomyScale).
function TheContractorJob:getPrice()
    return TCEconomyScale.scale(self.basePrice)
end

function TheContractorJob:getOfferedPrice()
    return TCEconomyScale.scale(self.baseOfferedPrice)
end

-- Sets the price from an amount at the current price level (a counter
-- offer the player typed, say).
function TheContractorJob:setPrice(price)
    self.basePrice = price / TCEconomyScale.getFactor()
end

-- 049: "Invoiced £X, expected around June 10, Year 2", or "Paid £X" for a
-- job paid on completion.
function TheContractorJob:getPaymentText()
    local amount = g_i18n:formatMoney(self.paymentAmount or self:getPrice(), 0, true, true)
    if self.invoiceDueDay ~= nil then
        return string.format(g_i18n:getText("tc_summary_invoiced"), amount, TCCalendar.formatDay(self.invoiceDueDay))
    end
    return string.format(g_i18n:getText("tc_summary_paid"), amount)
end

-- The player's farm is doing the carting itself: a haulage job allocated
-- to the player (no worker) has to have its crop delivered before it can
-- complete (see TCHaulage / TheContractorJobs:completeJob).
function TheContractorJob:needsPlayerDelivery()
    return self.includesHaulage and self.assignedWorkerId == nil
end

-- 093: no hired crew - the farm's player(s) do it themselves.
function TheContractorJob:isPlayerDriven()
    return self.assignedWorkerId == nil and self.haulerWorkerId == nil
end

-- 093: the player who took a player-driven job on, or "A player" for a job
-- allocated before that was recorded.
function TheContractorJob:getPlayerName()
    if self.allocatedPlayerName ~= nil and self.allocatedPlayerName ~= "" then
        return self.allocatedPlayerName
    end
    return g_i18n:getText("tc_logbook_aPlayer")
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

-- "Harvest", "Cultivate", "Mow", ... - or "Harvest & Haul"/"Bale &
-- Deliver" for a haulage job. A straw delivery is all haulage, so it's
-- just "Deliver Straw".
function TheContractorJob:getTypeText()
    local jobDef = TheContractorJobGeneration.JOB_TYPES[self.jobType]
    local isExtraHaulage = self.includesHaulage and not (jobDef ~= nil and jobDef.deliveryOnly)
    return g_i18n:getText("tc_jobType_" .. self.jobType .. (isExtraHaulage and "Haul" or ""))
end

-- "Harvest (Spinach)" for crop jobs, plain "Cultivate" otherwise, and
-- "Harvest & Haul (Spinach)" for a haulage job.
function TheContractorJob:getDisplayTitle()
    local typeText = self:getTypeText()
    -- 100: "Workshop repair (Fendt 942 Vario)".
    if self.workshop ~= nil then
        return string.format("%s (%s)", typeText, self.workshop.vehicleName or "?")
    end
    local cropTitle = self:getCropTitle()
    if cropTitle == nil then
        return typeText
    end
    return string.format("%s (%s)", typeText, cropTitle)
end

-- A table row's Type cell: the display title, but a workshop job's is just
-- its type, since a machine name doesn't fit the column (the details
-- panel names the machine).
function TheContractorJob:getListTitle()
    if self.workshop ~= nil then
        return self:getTypeText()
    end
    return self:getDisplayTitle()
end

-- A table row's Field cell: the field's name, a breakdown's field, or "-"
-- for a machine in one of our repair zones.
function TheContractorJob:getListFieldText()
    if self.workshop ~= nil then
        if self.workshop.fieldId ~= nil then
            local field = g_fieldManager:getFieldById(self.workshop.fieldId)
            return field ~= nil and field:getName() or tostring(self.workshop.fieldId)
        end
        return "-"
    end
    return self:getLocationText()
end

function TheContractorJob:canTransitionTo(newState)
    local allowed = TheContractorJob.VALID_TRANSITIONS[self.state]
    return allowed ~= nil and allowed[newState] == true
end

-- completed/declined/missed - the states with no way out.
function TheContractorJob:isTerminal()
    local allowed = TheContractorJob.VALID_TRANSITIONS[self.state]
    return allowed == nil or next(allowed) == nil
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
