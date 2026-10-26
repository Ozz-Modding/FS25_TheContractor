-- Joyriders (072), a random event (068): joyriders have driven over a grass
-- field and torn it up (TCJoyriderRuts paints the ruts). On an NPC's field
-- the farmer offers the contractor a plow job so it can be re-seeded, and
-- when that's done, FOLLOW_ON_SOW_CHANCE of a grass sow job on the same
-- field. On the farm's own field it's just bad luck: the damage and a
-- message, no job.
--
-- Which fields (getEligibleFields): grass by vanilla's own definition
-- (TheContractorJobGeneration.isGrass), meadows included, owned by nobody
-- (an NPC's) or by the event's own farm - never another player's farm in
-- multiplayer - and with no live job for any farm on it. Never in winter.
--
-- The plow job is due this month (createJobOnField's sameMonth): torn-up
-- grass is urgent. It keeps the field as it is when it's allocated
-- (job.keepFieldState, see TCFieldPreparation), or the ruts and the grass
-- would be wiped the moment it's allocated. It's flagged followOnSow, and
-- TheContractorJobs:completeJob hands it back here (onJobCompleted). Both
-- flags are server-only, saved with the job, never streamed.
--
-- State: none of its own. The incident's data is { fieldId, isOwnField }.

TheContractorJoyriders = {}
TheContractorJoyriders_mt = Class(TheContractorJoyriders)

TheContractorJoyriders.EVENT_TYPE = "joyriders"
TheContractorJoyriders.MESSAGE_KIND = "joyriders"

-- About one every 2-3 years, whatever the farm's size: it's the area's
-- grass fields that get hit, not the farm's fleet.
TheContractorJoyriders.RATE_PER_PERIOD = 0.03
TheContractorJoyriders.COOLDOWN_PERIODS = 6

TheContractorJoyriders.FOLLOW_ON_SOW_CHANCE = 0.5

function TheContractorJoyriders.new()
    local self = {}
    setmetatable(self, TheContractorJoyriders_mt)
    return self
end

-- Every machine, at load, before the save loads (068).
function TheContractorJoyriders:register(randomEvents, inbox)
    self.randomEvents = randomEvents

    randomEvents:registerEventType(TheContractorJoyriders.EVENT_TYPE, {
        l10nKey = "tc_joyriders_eventName",
        cooldownPeriods = TheContractorJoyriders.COOLDOWN_PERIODS,
        ratePerPeriod = function(farmId)
            return TheContractorJoyriders.RATE_PER_PERIOD
        end,
        canTrigger = function(farmId)
            return self:pickField(farmId)
        end,
        stages = {
            { key = "damage", run = function(incident)
                return self:onDamage(incident)
            end },
        },
    })

    inbox:registerMessageKind(TheContractorJoyriders.MESSAGE_KIND, {
        chipKey = "tc_inbox_chipJoyriders",
        endsWithJob = true,
        chipTone = "bad",
    })
end

-- Fields (server) -------------------------------------------------------------------

function TheContractorJoyriders.isWinter()
    local environment = g_currentMission.environment
    return environment:getSeasonAtDay(environment.currentMonotonicDay) == Season.WINTER
end

-- Grass growing on the field right now.
function TheContractorJoyriders.isGrassField(field)
    local fieldState = field:getFieldState()
    return fieldState ~= nil and fieldState.isValid and fieldState.fruitTypeIndex ~= nil and
        TheContractorJobGeneration.isGrass(fieldState.fruitTypeIndex)
end

-- The fields joyriders could tear up for this farm's event.
function TheContractorJoyriders:getEligibleFields(farmId)
    local result = {}
    local jobs = g_currentMission.TheContractor.Jobs
    for _, field in ipairs(g_fieldManager:getFields()) do
        local fieldId = field:getId()
        local owner = field:getOwner()
        if fieldId ~= nil and (owner == FarmlandManager.NO_OWNER_FARM_ID or owner == farmId) and
            TheContractorJoyriders.isGrassField(field) and not jobs:isFieldProtected(fieldId) then
            table.insert(result, field)
        end
    end
    return result
end

-- canTrigger (068): the incident's starting data, or nil.
function TheContractorJoyriders:pickField(farmId)
    if TheContractorJoyriders.isWinter() then
        return nil
    end
    local fields = self:getEligibleFields(farmId)
    if #fields == 0 then
        return nil
    end
    local field = fields[math.random(1, #fields)]
    return {
        fieldId = field:getId(),
        isOwnField = field:getOwner() == farmId,
    }
end

-- Stages (server) ---------------------------------------------------------------------

function TheContractorJoyriders:onDamage(incident)
    local data = incident.data
    local field = g_fieldManager:getFieldById(data.fieldId)
    -- Something may have happened to it since the roll (a load in between).
    if field == nil or not TheContractorJoyriders.isGrassField(field) then
        return TheContractorRandomEvents.DONE
    end
    if TCJoyriderRuts.paintField(field) == nil then
        return TheContractorRandomEvents.DONE
    end

    local tc = g_currentMission.TheContractor
    if data.isOwnField then
        tc.Inbox:postMessage(incident.farmId, TheContractorJoyriders.MESSAGE_KIND, "tc_joyriders_ownTitle",
            "tc_joyriders_ownBody", { data.fieldId }, nil, { incidentId = incident.id })
        TCLog.info("TheContractor: farm %d incident %d: joyriders tore up the farm's own field %d", incident.farmId,
            incident.id, data.fieldId)
        return TheContractorRandomEvents.DONE
    end

    local job = tc.JobGeneration:createJobOnField(incident.farmId, "plow", field, true)
    if job == nil then
        TCLog.info("TheContractor: farm %d incident %d: joyriders tore up field %d, but no plow job could be dated",
            incident.farmId, incident.id, data.fieldId)
        return TheContractorRandomEvents.DONE
    end
    job.keepFieldState = true
    job.followOnSow = true

    tc.Inbox:postMessage(incident.farmId, TheContractorJoyriders.MESSAGE_KIND, "tc_joyriders_offerTitle",
        "tc_joyriders_offerBody", { data.fieldId }, nil, { incidentId = incident.id, jobId = job.id })
    TCLog.info("TheContractor: farm %d incident %d: joyriders tore up field %d, plow job %d offered",
        incident.farmId, incident.id, data.fieldId, job.id)
    return TheContractorRandomEvents.DONE
end

-- Follow-on sow job (server) ---------------------------------------------------------

-- TheContractorJobs:completeJob, for a joyrider plow job: FOLLOW_ON_SOW_CHANCE
-- of a grass sow job on the same field. Sow jobs sow the field's planned
-- crop, so the plan becomes grass (as vanilla plans meadows) - put back if
-- grass can't be sown now and there's no job. random is for the tests.
function TheContractorJoyriders:onJobCompleted(job, random)
    if not job.followOnSow then
        return nil
    end
    random = random or math.random
    if random() >= TheContractorJoyriders.FOLLOW_ON_SOW_CHANCE then
        return nil
    end

    local field = g_fieldManager:getFieldById(job.fieldId)
    if field == nil or FruitType.GRASS == nil then
        return nil
    end

    local previousPlan = field.plannedFruitTypeIndex
    field.plannedFruitTypeIndex = FruitType.GRASS
    local tc = g_currentMission.TheContractor
    local sowJob = tc.JobGeneration:createJobOnField(job.farmId, "sow", field)
    if sowJob == nil then
        field.plannedFruitTypeIndex = previousPlan
        TCLog.info("TheContractor: farm %d job %d: no follow-on sow job, grass can't be sown on field %d now",
            job.farmId, job.id, job.fieldId)
        return nil
    end

    tc.Inbox:postMessage(job.farmId, TheContractorJoyriders.MESSAGE_KIND, "tc_joyriders_sowTitle",
        "tc_joyriders_sowBody", { job.fieldId }, nil, { jobId = sowJob.id })
    TCLog.info("TheContractor: farm %d job %d: follow-on grass sow job %d offered on field %d", job.farmId, job.id,
        sowJob.id, job.fieldId)
    return sowJob
end
