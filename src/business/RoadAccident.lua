-- Road accidents (079): a job event (074). As a hired worker's job
-- completes, the crew can have an accident on the way back to the yard,
-- while its equipment is hidden in the cooldown (023). Either a car runs
-- into the back of the rig (rearEnded) or one clips it on a bend or while
-- overtaking (clipped). The machine it hit is damaged either way: vanilla
-- damage, or an ADS breakdown on a machine ADS manages (as 059's are).
--
-- Who's at fault is rolled from the driver's road skill (their tractor
-- rating, as an absolute 1-10, not against the job's level) and the worst
-- condition across their rig (getFaultChance):
--
--   FAULT_BASE[scenario] + SKILL_WEIGHT x (10 - rating) / 9 + CONDITION_WEIGHT x wear
--
-- clamped to FAULT_MIN-FAULT_MAX. A good driver in good kit is at fault about
-- one accident in five, a poor one in battered kit three in four.
--
-- Ours: the driver's morale drops (MORALE_AT_FAULT), the farm loses
-- reputation, and the other driver's claim arrives a little later through
-- public liability (052, Claims:chargeClaim), judged on the day of the
-- accident, and goes on the job's logbook entry. We pay for our own repair
-- at the workshop like any other damage.
-- Theirs: their insurer accepts it, then pays an estimated repair cost
-- (vanilla's repair price formula for the damage done, a game price, never
-- scaled) a month or two later, sooner with an office administrator (057).
-- Nothing goes on either insurance history.
--
-- Everything is rolled in canTrigger, so the incident's data (068, flat,
-- saved and synced) holds the whole story: jobId, fieldId, workerId,
-- workerName, vehicleId/vehicleUniqueId/vehicleName (the machine hit),
-- scenario, atFault, severity, repairEstimate, claimAmount, insured,
-- reputationPenalty, and later noticeId and claimPaid. No state of its own.

TheContractorRoadAccident = {}
TheContractorRoadAccident_mt = Class(TheContractorRoadAccident)

TheContractorRoadAccident.EVENT_TYPE = "roadAccident"
TheContractorRoadAccident.MESSAGE_KIND = "roadAccident"

-- On a busy firm (20 jobs a month) about one every 6 months, a small one
-- (5 a month) about one every 16, cooldown included.
TheContractorRoadAccident.CHANCE_PER_JOB = 0.015
TheContractorRoadAccident.COOLDOWN_PERIODS = 3

TheContractorRoadAccident.SCENARIO = {
    REAR_ENDED = "rearEnded",
    CLIPPED = "clipped",
}
TheContractorRoadAccident.FAULT_BASE = {
    rearEnded = 0.10,
    clipped = 0.30,
}
TheContractorRoadAccident.SKILL_WEIGHT = 0.40
TheContractorRoadAccident.CONDITION_WEIGHT = 0.30
TheContractorRoadAccident.FAULT_MIN = 0.05
TheContractorRoadAccident.FAULT_MAX = 0.90
-- A driver with no rating to judge (nothing they're rated on in the rig).
TheContractorRoadAccident.DEFAULT_RATING = 5

-- Damage done (0-1, vanilla), or how far along an ADS breakdown starts.
TheContractorRoadAccident.DAMAGE_MIN = 0.15
TheContractorRoadAccident.DAMAGE_MAX = 0.35

-- The other driver's claim, 1x UK, scaled (TheContractorSettings:scaleCost).
TheContractorRoadAccident.CLAIM_MIN = 1500
TheContractorRoadAccident.CLAIM_MAX = 6000

-- Reputation lost when it's ours: this share of what the job earns at 100%,
-- never less than the minimum.
TheContractorRoadAccident.REPUTATION_PENALTY_MULTIPLIER = 1.0
TheContractorRoadAccident.MIN_REPUTATION_PENALTY = 5
TheContractorRoadAccident.MORALE_AT_FAULT = -5

-- Months.
TheContractorRoadAccident.CLAIM_DELAY_PERIODS = { 0.25, 0.5 }
TheContractorRoadAccident.ASSESS_DELAY_PERIODS = { 0.25, 0.5 }
TheContractorRoadAccident.PAY_DELAY_PERIODS = { 1, 2 }
TheContractorRoadAccident.ADMIN_PAY_DELAY_PERIODS = { 0.5, 1 }

TheContractorRoadAccident.NOTICE_MONTHS = 1

TheContractorRoadAccident.STAGE = {
    REPORT = "report",
    CLAIM = "claim",
    ASSESSED = "assessed",
    PAID = "paid",
    PAID_FAST = "paidFast",
}

-- What the console can force on the next accident.
TheContractorRoadAccident.FAULT = {
    OURS = "ours",
    THEIRS = "theirs",
}

function TheContractorRoadAccident.new()
    local self = {}
    setmetatable(self, TheContractorRoadAccident_mt)

    -- tcDebug outcome roadAccident: who's to blame for the next accident.
    -- Server-only, not saved.
    self.forcedFault = nil

    return self
end

-- Every machine, at load, before the save loads (068).
function TheContractorRoadAccident:register(randomEvents, inbox)
    self.randomEvents = randomEvents
    local stage = TheContractorRoadAccident.STAGE

    randomEvents:registerEventType(TheContractorRoadAccident.EVENT_TYPE, {
        l10nKey = "tc_roadAccident_eventName",
        chancePerJob = TheContractorRoadAccident.CHANCE_PER_JOB,
        cooldownPeriods = TheContractorRoadAccident.COOLDOWN_PERIODS,
        canTrigger = function(farmId, job)
            return self:rollAccident(farmId, job, math.random)
        end,
        console = {
            outcomes = { TheContractorRoadAccident.FAULT.OURS, TheContractorRoadAccident.FAULT.THEIRS },
            setOutcome = function(fault)
                self.forcedFault = fault
                return string.format("The next road accident will be %s fault",
                    fault == TheContractorRoadAccident.FAULT.OURS and "your driver's" or "the other driver's")
            end,
        },
        stages = {
            { key = stage.REPORT, run = function(incident)
                return self:onReport(incident)
            end },
            { key = stage.CLAIM, delayPeriods = TheContractorRoadAccident.CLAIM_DELAY_PERIODS,
                run = function(incident)
                    return self:onClaim(incident)
                end },
            { key = stage.ASSESSED, delayPeriods = TheContractorRoadAccident.ASSESS_DELAY_PERIODS,
                run = function(incident)
                    return self:onAssessed(incident)
                end },
            { key = stage.PAID, delayPeriods = TheContractorRoadAccident.PAY_DELAY_PERIODS,
                run = function(incident)
                    return self:onPaid(incident)
                end },
            { key = stage.PAID_FAST, delayPeriods = TheContractorRoadAccident.ADMIN_PAY_DELAY_PERIODS,
                run = function(incident)
                    return self:onPaid(incident)
                end },
        },
    })

    inbox:registerMessageKind(TheContractorRoadAccident.MESSAGE_KIND, {
        category = "claim",
        chipTone = "bad",
    })
end

-- Fault ------------------------------------------------------------------------------

function TheContractorRoadAccident.getFaultChance(scenario, rating, wear)
    local chance = (TheContractorRoadAccident.FAULT_BASE[scenario] or 0) +
        TheContractorRoadAccident.SKILL_WEIGHT * (10 - math.max(1, math.min(10, rating))) / 9 +
        TheContractorRoadAccident.CONDITION_WEIGHT * math.max(0, math.min(1, wear))
    return math.max(TheContractorRoadAccident.FAULT_MIN, math.min(TheContractorRoadAccident.FAULT_MAX, chance))
end

-- How worn a machine is (0-1): vanilla damage, or 1 - ADS's condition on a
-- machine ADS manages (it zeroes vanilla damage there).
function TheContractorRoadAccident.getVehicleWear(vehicle)
    if TCVehicleCondition.isManagedByADS(vehicle) then
        return 1 - (vehicle:getConditionLevel() or 1)
    end
    if vehicle.getDamageAmount ~= nil then
        return vehicle:getDamageAmount() or 0
    end
    return 0
end

-- The rig (server) ---------------------------------------------------------------------

local function getLiveVehicle(vehicleId)
    local vehicle = vehicleId ~= nil and vehicleId ~= 0 and NetworkUtil.getObject(vehicleId) or nil
    if vehicle == nil or vehicle.isDeleted then
        return nil
    end
    return vehicle
end

-- Not ours to damage: 071's courtesy vehicle, or anything stolen (069).
function TheContractorRoadAccident.isExcluded(vehicleId)
    local tc = g_currentMission.TheContractor
    return (tc.CourtesyVehicle ~= nil and tc.CourtesyVehicle:isCourtesy(vehicleId)) or
        (tc.Theft ~= nil and tc.Theft:isStolen(vehicleId))
end

-- The worker's rig from their equipment ids: the machine they drove (the
-- first drivable) and everything else (towed or mounted), or nil with
-- nothing to drive.
function TheContractorRoadAccident.getRig(equipmentIds)
    local drivable, units = nil, {}
    for _, vehicleId in ipairs(equipmentIds or {}) do
        local vehicle = getLiveVehicle(vehicleId)
        if vehicle ~= nil then
            if drivable == nil and vehicle.spec_drivable ~= nil then
                drivable = vehicle
            else
                table.insert(units, vehicle)
            end
        end
    end
    return drivable, units
end

-- How far in front of the drivable (+) or behind it (-) a unit sits, along
-- the drivable's own length. Equipment in a cooldown is hidden but stays
-- where it was, hitched as it was.
function TheContractorRoadAccident.getLongitudinalOffset(drivable, vehicle)
    if drivable.rootNode == nil or vehicle.rootNode == nil then
        return -1
    end
    local x, y, z = getWorldTranslation(vehicle.rootNode)
    local _, _, localZ = worldToLocal(drivable.rootNode, x, y, z)
    return localZ
end

-- The machine the car hit. rearEnded: the unit furthest back, if anything
-- trails the drivable, else the drivable. clipped: any unit (a trailer, a
-- wide header), else the drivable. Courtesy and stolen units are skipped.
-- roll (0-1) picks among the units for clipped.
function TheContractorRoadAccident.pickTarget(scenario, drivable, units, roll)
    local candidates = {}
    for _, unit in ipairs(units) do
        if not TheContractorRoadAccident.isExcluded(NetworkUtil.getObjectId(unit)) then
            table.insert(candidates, unit)
        end
    end

    if scenario == TheContractorRoadAccident.SCENARIO.REAR_ENDED then
        local target, targetOffset = drivable, 0
        for _, unit in ipairs(candidates) do
            local offset = TheContractorRoadAccident.getLongitudinalOffset(drivable, unit)
            if offset < targetOffset then
                target, targetOffset = unit, offset
            end
        end
        return target
    end

    if #candidates == 0 then
        return drivable
    end
    return candidates[math.min(#candidates, math.floor(roll * #candidates) + 1)]
end

-- canTrigger (068, 074) -----------------------------------------------------------------

local function randomBetween(random, min, max)
    return min + random() * (max - min)
end

-- The incident's starting data, with everything rolled, or nil: no hired
-- worker on the job (the player drove it), nothing to drive, or the
-- machine they drove isn't ours to damage. random is for the tests.
function TheContractorRoadAccident:rollAccident(farmId, job, random)
    local tc = g_currentMission.TheContractor
    local crew = TCJobConsequences.getCrew(job)
    if #crew == 0 then
        return nil
    end
    -- On a haulage job (035) either of them could be on the road.
    local member = crew[math.min(#crew, math.floor(random() * #crew) + 1)]
    local worker = tc.Staff:getWorker(farmId, member.workerId)
    if worker == nil then
        return nil
    end
    local drivable, units = TheContractorRoadAccident.getRig(member.equipmentIds)
    if drivable == nil or TheContractorRoadAccident.isExcluded(NetworkUtil.getObjectId(drivable)) then
        return nil
    end

    local scenario = random() < 0.5 and TheContractorRoadAccident.SCENARIO.REAR_ENDED or
        TheContractorRoadAccident.SCENARIO.CLIPPED
    local target = TheContractorRoadAccident.pickTarget(scenario, drivable, units, random())

    local ratings = tc.Allocation:getWorkerJobRatings(worker, job, member.equipmentIds, member.isHauler)
    local rating = ratings.tractorRating or ratings.operationRating or TheContractorRoadAccident.DEFAULT_RATING
    local wear = TheContractorRoadAccident.getVehicleWear(drivable)
    for _, unit in ipairs(units) do
        wear = math.max(wear, TheContractorRoadAccident.getVehicleWear(unit))
    end
    local faultChance = TheContractorRoadAccident.getFaultChance(scenario, rating, wear)
    local faultRoll = random()
    local atFault = faultRoll < faultChance
    if self.forcedFault ~= nil then
        atFault = self.forcedFault == TheContractorRoadAccident.FAULT.OURS
        self.forcedFault = nil
    end

    local severity = randomBetween(random, TheContractorRoadAccident.DAMAGE_MIN, TheContractorRoadAccident.DAMAGE_MAX)
    local data = {
        jobId = job.id,
        fieldId = job.fieldId,
        workerId = worker.id,
        workerName = worker.name,
        vehicleId = NetworkUtil.getObjectId(target),
        vehicleUniqueId = target.getUniqueId ~= nil and target:getUniqueId() or "",
        vehicleName = target:getFullName(),
        scenario = scenario,
        atFault = atFault,
        severity = severity,
        repairEstimate = math.floor(Wearable.calculateRepairPrice(target:getPrice(), severity)),
        claimAmount = 0,
        insured = false,
        reputationPenalty = 0,
    }
    if atFault then
        data.claimAmount = tc.Settings:scaleCost(randomBetween(random, TheContractorRoadAccident.CLAIM_MIN,
            TheContractorRoadAccident.CLAIM_MAX))
        data.insured = tc.Claims:isInsured(farmId)
        data.reputationPenalty = math.floor(math.max(TheContractorRoadAccident.MIN_REPUTATION_PENALTY,
            TheContractorJobs.getBaseReputationReward(job) * TheContractorRoadAccident.REPUTATION_PENALTY_MULTIPLIER))
    end

    TCLog.info("TheContractor: farm %d job %d: road accident (%s), %s driving (rating %d, rig wear %.2f): fault chance %.2f, rolled %.2f - %s",
        farmId, job.id, scenario, worker.name, rating, wear, faultChance, faultRoll, atFault and "ours" or "theirs")
    return data
end

-- Stages (server) ------------------------------------------------------------------------

-- The damage, on whichever damage model the machine's under.
function TheContractorRoadAccident.damageVehicle(vehicle, severity)
    if TCJobConsequences.canBreakDown(vehicle) then
        vehicle:addBreakdown(nil, { breakdownProgress = severity })
    elseif vehicle.addDamageAmount ~= nil then
        vehicle:addDamageAmount(severity, true)
    end
end

function TheContractorRoadAccident:onReport(incident)
    local tc = g_currentMission.TheContractor
    local data = incident.data
    local farmId = incident.farmId

    local vehicle = getLiveVehicle(data.vehicleId)
    if vehicle ~= nil then
        TheContractorRoadAccident.damageVehicle(vehicle, data.severity)
    end

    tc.Inbox:postMessage(farmId, TheContractorRoadAccident.MESSAGE_KIND, "tc_roadAccident_title",
        string.format("tc_roadAccident_%s_%s", data.scenario, data.atFault and "atFaultBody" or "notAtFaultBody"),
        { data.fieldId, data.workerName, data.vehicleName }, nil, { incidentId = incident.id })
    tc.Notices:publish(farmId, string.format(g_i18n:getText("tc_roadAccident_notice"), data.fieldId,
        data.vehicleName), TheContractorRoadAccident.NOTICE_MONTHS)

    TCLog.info("TheContractor: farm %d incident %d: %s's %s damaged (%.2f) on the way back from field %d, %s fault",
        farmId, incident.id, data.workerName, data.vehicleName, data.severity, data.fieldId,
        data.atFault and "our" or "their")

    if not data.atFault then
        return TheContractorRoadAccident.STAGE.ASSESSED
    end

    local worker = tc.Staff:getWorker(farmId, data.workerId)
    if worker ~= nil then
        tc.Morale:adjust(farmId, { worker }, TheContractorRoadAccident.MORALE_AT_FAULT)
    end
    tc.Reputation:addReputation(farmId, -data.reputationPenalty)
    return TheContractorRoadAccident.STAGE.CLAIM
end

-- The other driver's claim. On the job's logbook entry, as a botch's is
-- (052); a job with a botch claim as well gets the two added together.
function TheContractorRoadAccident:onClaim(incident)
    local tc = g_currentMission.TheContractor
    local data = incident.data
    local farmId = incident.farmId

    local paid = tc.Claims:chargeClaim(farmId, data.claimAmount, data.insured)
    data.claimPaid = paid

    tc.Claims:addToJobLog(farmId, data.jobId, { cause = "roadAccident", amount = data.claimAmount, paid = paid,
        insured = data.insured, reputationPenalty = data.reputationPenalty })

    tc.Inbox:postMessage(farmId, TheContractorRoadAccident.MESSAGE_KIND, "tc_roadAccident_claimTitle",
        data.insured and "tc_roadAccident_claimBodyInsured" or "tc_roadAccident_claimBodyUninsured",
        { data.fieldId, data.workerName, "$money_" .. data.claimAmount, "$money_" .. paid }, nil,
        { incidentId = incident.id })
    tc.Notices:publish(farmId, string.format(g_i18n:getText("tc_roadAccident_claimNotice"),
        g_i18n:formatMoney(paid, 0, true, true)), TheContractorRoadAccident.NOTICE_MONTHS)

    TCLog.info("TheContractor: farm %d incident %d: accident claim of %.0f, %.0f paid (%s)", farmId, incident.id,
        data.claimAmount, paid, data.insured and "insured" or "uninsured")
    return TheContractorRandomEvents.DONE
end

-- Their insurer accepts it and says what it'll pay. An Overview notice
-- stays up until it does.
function TheContractorRoadAccident:onAssessed(incident)
    local tc = g_currentMission.TheContractor
    local data = incident.data
    local farmId = incident.farmId

    tc.Inbox:postMessage(farmId, TheContractorRoadAccident.MESSAGE_KIND, "tc_roadAccident_assessedTitle",
        "tc_roadAccident_assessedBody", { data.vehicleName, "$money_" .. data.repairEstimate }, nil,
        { incidentId = incident.id })
    data.noticeId = tc.Notices:publish(farmId, string.format(g_i18n:getText("tc_roadAccident_paymentNotice"),
        g_i18n:formatMoney(data.repairEstimate, 0, true, true), data.vehicleName))

    if tc.Office:hasAdministrator(farmId) then
        return TheContractorRoadAccident.STAGE.PAID_FAST
    end
    return TheContractorRoadAccident.STAGE.PAID
end

function TheContractorRoadAccident:onPaid(incident)
    local tc = g_currentMission.TheContractor
    local data = incident.data
    local farmId = incident.farmId

    if data.noticeId ~= nil then
        tc.Notices:remove(data.noticeId)
        data.noticeId = nil
    end
    if data.repairEstimate > 0 then
        g_currentMission:addMoney(data.repairEstimate, farmId, MoneyType.TC_INSURANCE_PAYOUT, true, true)
        tc.Finances:recordInsurancePayout(farmId, data.repairEstimate)
    end
    tc.Inbox:postMessage(farmId, TheContractorRoadAccident.MESSAGE_KIND, "tc_roadAccident_paidTitle",
        "tc_roadAccident_paidBody", { data.vehicleName, "$money_" .. data.repairEstimate }, nil,
        { incidentId = incident.id })

    TCLog.info("TheContractor: farm %d incident %d: the other driver's insurer paid %.0f for the %s",
        farmId, incident.id, data.repairEstimate, data.vehicleName)
    return TheContractorRandomEvents.DONE
end

-- Saved vehicles (server) ---------------------------------------------------------------

-- Once, after the save's vehicles exist: the damaged machine's object id
-- from its uniqueId. One that's gone is left at 0; the stages only name it.
function TheContractorRoadAccident:resolveSavedVehicles()
    if self.randomEvents == nil then
        return
    end
    for _, incident in pairs(self.randomEvents.incidents) do
        if incident.eventType == TheContractorRoadAccident.EVENT_TYPE then
            local uniqueId = incident.data.vehicleUniqueId
            incident.data.vehicleId = uniqueId ~= nil and uniqueId ~= "" and TCVehicleIds.getObjectId(uniqueId) or 0
        end
    end
end
