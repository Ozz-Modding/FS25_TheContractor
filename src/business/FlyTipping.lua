-- Fly-tipping (075), a random event (068): someone has dumped a pile of
-- junk just inside an NPC's field, by the gate. The farmer offers the
-- contractor a job to clear it: the player carries the pieces (TCDebris) to
-- a skip the farm has placed (PlaceableTCDisposalSkip), where they
-- disappear. Each piece from a job costs a small tipping fee.
--
-- Which fields (getEligibleFields): owned by nobody (an NPC's) and with no
-- live job for any farm on it. Never the farm's own, never another
-- player's. Any season.
--
-- The job (JobGeneration's flyTipping type) is due this month, like 072's
-- plow job, priced per piece. Its pieces are tracked by item uniqueId in
-- job.debrisIds, server-only and saved; taking one to a skip counts it
-- (job.debrisDisposed) and TCJobProgress measures the rest. Whatever's left
-- of the pile goes when the job's over (TCFieldPreparation.clearUpAfterJob),
-- or when the offer is declined or runs out.
--
-- State: none of its own. The incident's data is { fieldId }.

TheContractorFlyTipping = {}
TheContractorFlyTipping_mt = Class(TheContractorFlyTipping)

TheContractorFlyTipping.EVENT_TYPE = "flyTipping"
TheContractorFlyTipping.MESSAGE_KIND = "flyTipping"
TheContractorFlyTipping.JOB_TYPE = "flyTipping"

-- About one every couple of years, like joyriders: it's the area's fields
-- that get hit, not the farm's.
TheContractorFlyTipping.RATE_PER_PERIOD = 0.04
TheContractorFlyTipping.COOLDOWN_PERIODS = 4

TheContractorFlyTipping.MIN_PIECES = 10
TheContractorFlyTipping.MAX_PIECES = 30

-- Where the pile lands: TCJoyriderRuts.planDumpSite's spot 4-7 m in from
-- the field's edge, by its gate where it can, with the van's ruts painted in
-- to it and the ground churned up under it, so it can be found from the
-- edge. A field without a boundary falls back to GATE_INSET in from its
-- gate (its teleport point) towards its middle. Metres.
TheContractorFlyTipping.GATE_INSET = 6

-- Per job piece taken to a skip, 1x UK (a landfill gate fee's share for a
-- bulky item), charged through scaleCost. An old ADS part (103) costs the
-- same.
TheContractorFlyTipping.TIPPING_FEE = 5

table.insert(FinanceStats.statNames, "tcWasteDisposal")
FinanceStats.statNameToIndex["tcWasteDisposal"] = #FinanceStats.statNames

function TheContractorFlyTipping.new()
    local self = {}
    setmetatable(self, TheContractorFlyTipping_mt)

    MoneyType.TC_WASTE_DISPOSAL = MoneyType.register("tcWasteDisposal", "tc_moneyType_wasteDisposal")
    MoneyType.LAST_ID = MoneyType.LAST_ID + 1

    return self
end

-- Every machine, at load, before the save loads (068).
function TheContractorFlyTipping:register(randomEvents, inbox)
    randomEvents:registerEventType(TheContractorFlyTipping.EVENT_TYPE, {
        l10nKey = "tc_flyTipping_eventName",
        cooldownPeriods = TheContractorFlyTipping.COOLDOWN_PERIODS,
        ratePerPeriod = function(farmId)
            return TheContractorFlyTipping.RATE_PER_PERIOD
        end,
        canTrigger = function(farmId)
            return self:pickField(farmId)
        end,
        stages = {
            { key = "dump", run = function(incident)
                return self:onDump(incident)
            end },
        },
    })

    inbox:registerMessageKind(TheContractorFlyTipping.MESSAGE_KIND, {
        chipKey = "tc_inbox_chipFlyTipping",
        endsWithJob = true,
        chipTone = "bad",
    })
end

-- Fields (server) -------------------------------------------------------------------

function TheContractorFlyTipping:getEligibleFields(farmId)
    local result = {}
    local jobs = g_currentMission.TheContractor.Jobs
    for _, field in ipairs(g_fieldManager:getFields()) do
        local fieldId = field:getId()
        if fieldId ~= nil and field:getOwner() == FarmlandManager.NO_OWNER_FARM_ID and
            not jobs:isFieldProtected(fieldId) then
            table.insert(result, field)
        end
    end
    return result
end

-- canTrigger (068): the incident's starting data, or nil.
function TheContractorFlyTipping:pickField(farmId)
    if #TCDebris.RANDOM_PROPS == 0 then
        return nil
    end
    local fields = self:getEligibleFields(farmId)
    if #fields == 0 then
        return nil
    end
    return { fieldId = fields[math.random(1, #fields)]:getId() }
end

-- The fallback spot (see GATE_INSET): in from the field's gate towards its
-- middle (or halfway there, on a field that small).
function TheContractorFlyTipping.getDumpSpot(field)
    local gateX, gateZ = field:getTeleportPosition()
    local centreX, centreZ = field:getCenterOfFieldWorldPosition()
    local dx, dz = centreX - gateX, centreZ - gateZ
    local distance = math.sqrt(dx * dx + dz * dz)
    if distance < 0.01 then
        return gateX, gateZ
    end
    local inset = math.min(TheContractorFlyTipping.GATE_INSET, distance * 0.5)
    return gateX + dx / distance * inset, gateZ + dz / distance * inset
end

-- Stages (server) ---------------------------------------------------------------------

function TheContractorFlyTipping:onDump(incident)
    local tc = g_currentMission.TheContractor
    local field = g_fieldManager:getFieldById(incident.data.fieldId)
    -- Someone may have taken a job on it since the roll (a load in between).
    if field == nil or tc.Jobs:isFieldProtected(incident.data.fieldId) then
        return TheContractorRandomEvents.DONE
    end

    local count = math.random(TheContractorFlyTipping.MIN_PIECES, TheContractorFlyTipping.MAX_PIECES)
    local x, z
    local site = TCJoyriderRuts.paintDumpSite(field)
    if site ~= nil then
        x, z = site.x, site.z
    else
        x, z = TheContractorFlyTipping.getDumpSpot(field)
    end
    local pieces = TCDebris.spawnPileAt(x, z, count, incident.farmId)
    if #pieces == 0 then
        return TheContractorRandomEvents.DONE
    end

    local job = tc.JobGeneration:createJobOnField(incident.farmId, TheContractorFlyTipping.JOB_TYPE, field, true,
        #pieces)
    if job == nil then
        for _, debris in ipairs(pieces) do
            debris:delete()
        end
        Logging.info("TheContractor: farm %d incident %d: fly-tipping on field %d, but no job could be dated",
            incident.farmId, incident.id, incident.data.fieldId)
        return TheContractorRandomEvents.DONE
    end
    for _, debris in ipairs(pieces) do
        table.insert(job.debrisIds, debris:getUniqueId())
    end
    job.workTotal = #pieces

    tc.Inbox:postMessage(incident.farmId, TheContractorFlyTipping.MESSAGE_KIND, "tc_flyTipping_offerTitle",
        "tc_flyTipping_offerBody", { incident.data.fieldId, #pieces }, nil,
        { incidentId = incident.id, jobId = job.id })
    Logging.info("TheContractor: farm %d incident %d: %d pieces fly-tipped on field %d, job %d offered",
        incident.farmId, incident.id, #pieces, incident.data.fieldId, job.id)
    return TheContractorRandomEvents.DONE
end

-- Disposal (server) -------------------------------------------------------------------

-- The live (not finished) job a piece of debris belongs to, or nil.
function TheContractorFlyTipping:getJobForDebris(debris)
    local uniqueId = debris:getUniqueId()
    if uniqueId == nil then
        return nil, nil
    end
    for _, farm in ipairs(g_farmManager:getFarms()) do
        for _, job in ipairs(g_currentMission.TheContractor.Jobs:getAllJobs(farm.farmId)) do
            if job.debrisIds ~= nil and not job:isTerminal() then
                for i, id in ipairs(job.debrisIds) do
                    if id == uniqueId then
                        return job, i
                    end
                end
            end
        end
    end
    return nil, nil
end

-- The tipping fee for one piece, at today's prices.
function TheContractorFlyTipping.getTippingFee()
    return g_currentMission.TheContractor.Settings:scaleCost(TheContractorFlyTipping.TIPPING_FEE)
end

-- A skip took a piece: it counts towards its job (and costs the job's farm
-- the tipping fee), then it's gone. Debris from no job goes for nothing.
function TheContractorFlyTipping:disposeDebris(debris)
    local job, index = self:getJobForDebris(debris)
    if job ~= nil then
        table.remove(job.debrisIds, index)
        job.debrisDisposed = job.debrisDisposed + 1
        local fee = TheContractorFlyTipping.getTippingFee()
        if fee > 0 then
            g_currentMission:addMoney(-fee, job.farmId, MoneyType.TC_WASTE_DISPOSAL, true, true)
            g_currentMission.TheContractor.Finances:recordDisposal(job.farmId, fee)
        end
        Logging.info("TheContractor: farm %d job %d: debris taken to a skip (%d taken, %d left), fee %.0f",
            job.farmId, job.id, job.debrisDisposed, #job.debrisIds, fee)
    end
    debris:delete()
    return job
end

-- A skip took an old part a replacement left (103, TCADSStock.isUsedPart):
-- its owner pays the tipping fee, then it's gone. Selling it to a dealer
-- through ADS stays the other way out. Returns the fee charged.
function TheContractorFlyTipping:disposeUsedPart(part)
    local farmId = part.getOwnerFarmId ~= nil and part:getOwnerFarmId() or nil
    local fee = 0
    if farmId ~= nil and farmId ~= FarmManager.SPECTATOR_FARM_ID then
        fee = TheContractorFlyTipping.getTippingFee()
        if fee > 0 then
            g_currentMission:addMoney(-fee, farmId, MoneyType.TC_WASTE_DISPOSAL, true, true)
            g_currentMission.TheContractor.Finances:recordDisposal(farmId, fee)
        end
    end
    Logging.info("TheContractor: farm %s: old part %s taken to a skip, fee %.0f", tostring(farmId),
        part.getName ~= nil and part:getName() or "?", fee)
    part:delete()
    return fee
end
