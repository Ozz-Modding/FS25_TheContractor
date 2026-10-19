-- Spray drift complaints (081): a job event (074). As a hired worker's
-- herbicide job completes, a neighbour, a beekeeper or an organic grower
-- next to the field can complain that our spray drifted onto their land.
-- It's looked into, and the findings come back a week or two later.
--
-- Whether it really drifted comes from the operator's crop care skill (their
-- operation rating for the job, an absolute 1-10) and the wind as they
-- finish (getDriftChance):
--
--   DRIFT_BASE + UNSKILLED_WEIGHT x unskill
--              + windiness x (WIND_SKILLED + (WIND_UNSKILLED - WIND_SKILLED) x unskill)
--
-- capped at DRIFT_MAX, where unskill runs from 0 at a crop care of 10 to 1
-- at the spraying certificate's readySkill (054, the least a certified
-- operator can have; every hired herbicide operator is certified), and
-- windiness from 0 at WIND_CALM to 1 at WIND_STRONG. A poor operator is hit
-- far harder by the wind than a good one, who'd stop or change nozzles.
-- Drift always brings a complaint; a clean job still gets an unfounded one
-- now and then (UNFOUNDED_CHANCE). So the chance of a complaint on a job is
-- drift + (1 - drift) x UNFOUNDED_CHANCE (chancePerJob, a function of the
-- job), and once one's in, it's upheld with drift's share of that.
--
-- Cleared: an inbox message, nothing else. Upheld: the complainant's claim
-- through public liability (052, Claims:chargeClaim, cover judged on the
-- day), a reputation hit, a morale knock for the operator, and the claim on
-- the job's logbook entry.
--
-- Never for a player-driven job, nor one that's already rolled a 052 botch
-- claim (whose "drift" cause is the customer's own crop; this is next door).
--
-- Everything is rolled in canTrigger, so the incident's data (068, flat,
-- saved and synced) holds the whole story: jobId, fieldId, neighbourFieldId
-- (the nearest NPC field, 0 if none), workerId, workerName, complainant,
-- windiness, upheld, claimAmount, insured, reputationPenalty, and later
-- noticeId and claimPaid. No state of its own.

TheContractorSprayDrift = {}
TheContractorSprayDrift_mt = Class(TheContractorSprayDrift)

TheContractorSprayDrift.EVENT_TYPE = "sprayDrift"
TheContractorSprayDrift.MESSAGE_KIND = "sprayDrift"
TheContractorSprayDrift.JOB_TYPE = "herbicide"

TheContractorSprayDrift.COOLDOWN_PERIODS = 1

TheContractorSprayDrift.DRIFT_BASE = 0.01
TheContractorSprayDrift.UNSKILLED_WEIGHT = 0.10
TheContractorSprayDrift.WIND_SKILLED = 0.10
TheContractorSprayDrift.WIND_UNSKILLED = 0.60
TheContractorSprayDrift.DRIFT_MAX = 0.90
TheContractorSprayDrift.UNFOUNDED_CHANCE = 0.02

-- Wind speed (m/s, vanilla's units) counted as calm, and as too strong to
-- spray in. Spraying guidance stops at about 4.5 m/s (10 mph).
TheContractorSprayDrift.WIND_CALM = 2
TheContractorSprayDrift.WIND_STRONG = 7
-- Below this windiness the cleared message calls the day calm.
TheContractorSprayDrift.CALM_WINDINESS = 0.25

-- Who complains, and what they claim: 1x UK, scaled (TheContractorSettings:scaleCost).
TheContractorSprayDrift.COMPLAINANTS = {
    neighbour = { claimMin = 500, claimMax = 2500 },
    beekeeper = { claimMin = 1500, claimMax = 4000 },
    organicGrower = { claimMin = 3000, claimMax = 8000 },
}
TheContractorSprayDrift.COMPLAINANT_KEYS = { "neighbour", "beekeeper", "organicGrower" }

-- Reputation lost when it's upheld: this share of what the job earns at
-- 100%, never less than the minimum (as 079's).
TheContractorSprayDrift.REPUTATION_PENALTY_MULTIPLIER = 1.0
TheContractorSprayDrift.MIN_REPUTATION_PENALTY = 5
TheContractorSprayDrift.MORALE_UPHELD = -3

-- Months.
TheContractorSprayDrift.FINDINGS_DELAY_PERIODS = { 0.25, 0.5 }

TheContractorSprayDrift.NOTICE_MONTHS = 1

TheContractorSprayDrift.STAGE = {
    COMPLAINT = "complaint",
    FINDINGS = "findings",
}

function TheContractorSprayDrift.new()
    local self = {}
    setmetatable(self, TheContractorSprayDrift_mt)

    -- tcCompany outcome sprayDrift: true/false for the next complaint's findings.
    -- Server-only, not saved.
    self.forcedUpheld = nil

    return self
end

-- Every machine, at load, before the save loads (068).
function TheContractorSprayDrift:register(randomEvents, inbox)
    local stage = TheContractorSprayDrift.STAGE

    randomEvents:registerEventType(TheContractorSprayDrift.EVENT_TYPE, {
        l10nKey = "tc_sprayDrift_eventName",
        chancePerJob = function(farmId, job)
            return self:getComplaintChanceForJob(farmId, job)
        end,
        cooldownPeriods = TheContractorSprayDrift.COOLDOWN_PERIODS,
        canTrigger = function(farmId, job)
            return self:rollComplaint(farmId, job, math.random)
        end,
        console = {
            outcomes = { "upheld", "cleared" },
            setOutcome = function(outcome)
                self.forcedUpheld = outcome == "upheld"
                return string.format("The next spray drift complaint will be %s", outcome)
            end,
        },
        stages = {
            { key = stage.COMPLAINT, run = function(incident)
                return self:onComplaint(incident)
            end },
            { key = stage.FINDINGS, delayPeriods = TheContractorSprayDrift.FINDINGS_DELAY_PERIODS,
                run = function(incident)
                    return self:onFindings(incident)
                end },
        },
    })

    inbox:registerMessageKind(TheContractorSprayDrift.MESSAGE_KIND, {
        chipKey = "tc_inbox_chipSprayDrift",
        chipTone = "bad",
    })
end

-- The odds ---------------------------------------------------------------------------

-- 0 at WIND_CALM or less, 1 at WIND_STRONG or more.
function TheContractorSprayDrift.getWindiness(velocity)
    local span = TheContractorSprayDrift.WIND_STRONG - TheContractorSprayDrift.WIND_CALM
    return math.max(0, math.min(1, ((velocity or 0) - TheContractorSprayDrift.WIND_CALM) / span))
end

-- The wind right now (m/s), 0 if the weather can't say.
function TheContractorSprayDrift.getWindVelocity()
    local environment = g_currentMission.environment
    local weather = environment ~= nil and environment.weather or nil
    local windUpdater = weather ~= nil and weather.windUpdater or nil
    if windUpdater == nil or windUpdater.getCurrentValues == nil then
        return 0
    end
    local _, _, velocity = windUpdater:getCurrentValues()
    return velocity or 0
end

-- 0 for the best operator, 1 for one only just good enough to be certified.
function TheContractorSprayDrift.getUnskill(cropCare)
    local readySkill = TheContractorTraining.CERTIFICATIONS.spraying.readySkill
    local maxSkill = TheContractorWorker.MAX_SKILL
    return math.max(0, math.min(1, (maxSkill - cropCare) / (maxSkill - readySkill)))
end

-- The chance the spray really did drift.
function TheContractorSprayDrift.getDriftChance(cropCare, windiness)
    local unskill = TheContractorSprayDrift.getUnskill(cropCare)
    local windWeight = TheContractorSprayDrift.WIND_SKILLED +
        (TheContractorSprayDrift.WIND_UNSKILLED - TheContractorSprayDrift.WIND_SKILLED) * unskill
    local chance = TheContractorSprayDrift.DRIFT_BASE + TheContractorSprayDrift.UNSKILLED_WEIGHT * unskill +
        windWeight * math.max(0, math.min(1, windiness))
    return math.min(TheContractorSprayDrift.DRIFT_MAX, chance)
end

-- The chance of a complaint at all: every drift, plus the odd unfounded one.
function TheContractorSprayDrift.getComplaintChance(driftChance)
    return driftChance + (1 - driftChance) * TheContractorSprayDrift.UNFOUNDED_CHANCE
end

-- The job's operator and their crop care, or nil: not a herbicide job, the
-- player sprayed it, or it's already had a botch claim.
function TheContractorSprayDrift:getOperator(farmId, job)
    local tc = g_currentMission.TheContractor
    if job.jobType ~= TheContractorSprayDrift.JOB_TYPE or job.assignedWorkerId == nil or
            tc.Claims:hasPendingClaimForJob(job.id) then
        return nil
    end
    local worker = tc.Staff:getWorker(farmId, job.assignedWorkerId)
    if worker == nil then
        return nil
    end
    local ratings = tc.Allocation:getWorkerJobRatings(worker, job, job.assignedEquipmentIds, false)
    local cropCare = ratings.operationRating or TheContractorTraining.CERTIFICATIONS.spraying.readySkill
    return worker, cropCare
end

-- chancePerJob (074): this job's chance of a complaint, 0 if it can't have one.
function TheContractorSprayDrift:getComplaintChanceForJob(farmId, job)
    local worker, cropCare = self:getOperator(farmId, job)
    if worker == nil then
        return 0
    end
    local windiness = TheContractorSprayDrift.getWindiness(TheContractorSprayDrift.getWindVelocity())
    return TheContractorSprayDrift.getComplaintChance(TheContractorSprayDrift.getDriftChance(cropCare, windiness))
end

-- canTrigger (068, 074) -----------------------------------------------------------------

-- The nearest field to fieldId's that's nobody's (an NPC's), for the
-- message, or 0.
function TheContractorSprayDrift.findNeighbourField(fieldId)
    local field = g_fieldManager:getFieldById(fieldId)
    if field == nil then
        return 0
    end
    local x, z = field:getCenterOfFieldWorldPosition()
    local bestId, bestDistance = 0, math.huge
    for _, other in ipairs(g_fieldManager:getFields()) do
        local otherId = other:getId()
        if otherId ~= nil and otherId ~= fieldId and other:getOwner() == FarmlandManager.NO_OWNER_FARM_ID then
            local ox, oz = other:getCenterOfFieldWorldPosition()
            local distance = (ox - x) ^ 2 + (oz - z) ^ 2
            if distance < bestDistance then
                bestId, bestDistance = otherId, distance
            end
        end
    end
    return bestId
end

local function randomBetween(random, min, max)
    return min + random() * (max - min)
end

-- The incident's starting data, with everything rolled, or nil (see
-- getOperator). The wind is read now: as the crew finishes on a real roll,
-- whatever it's doing on a forced one. random is for the tests.
function TheContractorSprayDrift:rollComplaint(farmId, job, random)
    local tc = g_currentMission.TheContractor
    local worker, cropCare = self:getOperator(farmId, job)
    if worker == nil then
        return nil
    end

    local windiness = TheContractorSprayDrift.getWindiness(TheContractorSprayDrift.getWindVelocity())
    local driftChance = TheContractorSprayDrift.getDriftChance(cropCare, windiness)
    local upheldChance = driftChance / TheContractorSprayDrift.getComplaintChance(driftChance)
    local roll = random()
    local upheld = roll < upheldChance
    if self.forcedUpheld ~= nil then
        upheld = self.forcedUpheld
        self.forcedUpheld = nil
    end

    local keys = TheContractorSprayDrift.COMPLAINANT_KEYS
    local complainant = keys[math.min(#keys, math.floor(random() * #keys) + 1)]

    local data = {
        jobId = job.id,
        fieldId = job.fieldId,
        neighbourFieldId = TheContractorSprayDrift.findNeighbourField(job.fieldId),
        workerId = worker.id,
        workerName = worker.name,
        complainant = complainant,
        windiness = windiness,
        upheld = upheld,
        claimAmount = 0,
        insured = false,
        reputationPenalty = 0,
    }
    if upheld then
        local definition = TheContractorSprayDrift.COMPLAINANTS[complainant]
        data.claimAmount = tc.Settings:scaleCost(randomBetween(random, definition.claimMin, definition.claimMax))
        data.insured = tc.Claims:isInsured(farmId)
        data.reputationPenalty = math.floor(math.max(TheContractorSprayDrift.MIN_REPUTATION_PENALTY,
            TheContractorJobs.getBaseReputationReward(job) * TheContractorSprayDrift.REPUTATION_PENALTY_MULTIPLIER))
    end

    Logging.info("TheContractor: farm %d job %d: spray drift complaint (%s), %s spraying (crop care %d, windiness %.2f): drift chance %.2f, upheld chance %.2f, rolled %.2f - %s",
        farmId, job.id, complainant, worker.name, cropCare, windiness, driftChance, upheldChance, roll,
        upheld and "upheld" or "cleared")
    return data
end

-- Stages (server) ------------------------------------------------------------------------

function TheContractorSprayDrift:onComplaint(incident)
    local tc = g_currentMission.TheContractor
    local data = incident.data
    local farmId = incident.farmId

    local bodyKey = string.format("tc_sprayDrift_%s_complaintBody", data.complainant)
    local args = { data.fieldId, data.workerName }
    if data.neighbourFieldId ~= 0 then
        bodyKey = bodyKey .. "Field"
        table.insert(args, data.neighbourFieldId)
    end
    tc.Inbox:postMessage(farmId, TheContractorSprayDrift.MESSAGE_KIND, "tc_sprayDrift_complaintTitle", bodyKey,
        args, nil, { incidentId = incident.id })
    data.noticeId = tc.Notices:publish(farmId, string.format(g_i18n:getText("tc_sprayDrift_notice"), data.fieldId))

    Logging.info("TheContractor: farm %d incident %d: %s complains of spray drift from field %d (%s)", farmId,
        incident.id, data.complainant, data.fieldId, data.upheld and "will be upheld" or "will be cleared")
    return TheContractorSprayDrift.STAGE.FINDINGS
end

function TheContractorSprayDrift:onFindings(incident)
    local tc = g_currentMission.TheContractor
    local data = incident.data
    local farmId = incident.farmId

    if data.noticeId ~= nil then
        tc.Notices:remove(data.noticeId)
        data.noticeId = nil
    end

    if not data.upheld then
        tc.Inbox:postMessage(farmId, TheContractorSprayDrift.MESSAGE_KIND, "tc_sprayDrift_clearedTitle",
            data.windiness < TheContractorSprayDrift.CALM_WINDINESS and "tc_sprayDrift_clearedBodyCalm" or
            "tc_sprayDrift_clearedBodyBreezy",
            { data.fieldId, data.workerName }, nil, { incidentId = incident.id })
        Logging.info("TheContractor: farm %d incident %d: spray drift complaint cleared", farmId, incident.id)
        return TheContractorRandomEvents.DONE
    end

    local paid = tc.Claims:chargeClaim(farmId, data.claimAmount, data.insured)
    data.claimPaid = paid
    tc.Reputation:addReputation(farmId, -data.reputationPenalty)
    local worker = tc.Staff:getWorker(farmId, data.workerId)
    if worker ~= nil then
        tc.Morale:adjust(farmId, { worker }, TheContractorSprayDrift.MORALE_UPHELD)
    end
    tc.Claims:addToJobLog(farmId, data.jobId, { cause = "sprayDrift", amount = data.claimAmount, paid = paid,
        insured = data.insured, reputationPenalty = data.reputationPenalty })

    tc.Inbox:postMessage(farmId, TheContractorSprayDrift.MESSAGE_KIND, "tc_sprayDrift_upheldTitle",
        data.insured and "tc_sprayDrift_upheldBodyInsured" or "tc_sprayDrift_upheldBodyUninsured",
        { data.fieldId, data.workerName, "$money_" .. data.claimAmount,
            "$l10n_tc_sprayDrift_damage_" .. data.complainant, "$money_" .. paid }, nil, { incidentId = incident.id })
    tc.Notices:publish(farmId, string.format(g_i18n:getText("tc_sprayDrift_upheldNotice"), data.fieldId,
        g_i18n:formatMoney(paid, 0, true, true)), TheContractorSprayDrift.NOTICE_MONTHS)

    Logging.info("TheContractor: farm %d incident %d: spray drift complaint upheld: %.0f claimed, %.0f paid (%s), -%d reputation",
        farmId, incident.id, data.claimAmount, paid, data.insured and "insured" or "uninsured",
        data.reputationPenalty)
    return TheContractorRandomEvents.DONE
end
