-- Field breakdowns (101), a random event (068): a customer's machine has
-- broken down out on an NPC's field, and they want it fixed on the spot,
-- today. FS25_AdvancedDamageSystem prepares it as its breakdown kind (one
-- fault at its critical stage, two at severity 3, the engine dead about a
-- third of the time) with a field service level: "player" (the player can
-- fix it with ADS's tool box) or "mobile" (it takes a mobile workshop van).
-- See tickets/101 and docs/ads-repair-contracts.md.
--
-- Everything after the roll is 100's (TheContractorRepairContracts): the
-- machine goes on its arrivals queue with a spot on the field instead of a
-- bay, is spawned out of sight (or after the usual wait), prepared, and
-- offered as an adsBreakdown job due today, priced from ADS's quote (a hired
-- mobile workshop, call-out fee included) plus the margin. Accepting needs
-- the kit for its level (getBreakdownProblem): a tool box or the farm's own
-- van for "player", the van for "mobile". It's done when ADS says so; a
-- lapsed offer or a missed job and the customer's own recovery takes the
-- machine away (100's collection, judged where the machine stands).
--
-- The odds: RATE_PER_PERIOD a month while the farm has a tool box or a van,
-- NO_KIT_RATE_FACTOR of that until it has either, so a new company isn't
-- shown offers it can never take. A farm with a tool box but no van mostly
-- gets jobs a tool box can do. One at a time per farm, in working hours.
--
-- State: none of its own. The incident's data is { fieldId, fieldService,
-- severity }; the model and the spot are picked as it happens.

TheContractorFieldBreakdowns = {}
TheContractorFieldBreakdowns_mt = Class(TheContractorFieldBreakdowns)

TheContractorFieldBreakdowns.EVENT_TYPE = "fieldBreakdown"

-- About one a month with the kit, a quarter of that without.
TheContractorFieldBreakdowns.RATE_PER_PERIOD = 1.0
TheContractorFieldBreakdowns.NO_KIT_RATE_FACTOR = 0.25
TheContractorFieldBreakdowns.COOLDOWN_PERIODS = 0
-- Machines break down while they're working.
TheContractorFieldBreakdowns.TRIGGER_HOURS = { 8, 16 }

-- With a tool box and no van, the share that a tool box can fix.
TheContractorFieldBreakdowns.TOOL_BOX_PLAYER_SHARE = 0.75
-- The share that are harvesters (when there are any, and not in winter).
TheContractorFieldBreakdowns.HARVESTER_SHARE = 0.2

-- How far in from the field's edge the machine stands, beyond half its
-- own size (metres), and how many random points are tried for it.
TheContractorFieldBreakdowns.EDGE_MARGIN = 6
TheContractorFieldBreakdowns.SPOT_TRIES = 40

function TheContractorFieldBreakdowns.new()
    local self = {}
    setmetatable(self, TheContractorFieldBreakdowns_mt)

    -- Server: tcCompany event fieldBreakdown <player|mobile>, for one trigger.
    self.forcedFieldService = nil

    return self
end

-- Every machine, at load, before the save loads (068).
function TheContractorFieldBreakdowns:register(randomEvents)
    randomEvents:registerEventType(TheContractorFieldBreakdowns.EVENT_TYPE, {
        l10nKey = "tc_breakdown_eventName",
        cooldownPeriods = TheContractorFieldBreakdowns.COOLDOWN_PERIODS,
        triggerHours = TheContractorFieldBreakdowns.TRIGGER_HOURS,
        ratePerPeriod = function(farmId)
            return TheContractorFieldBreakdowns.getRate(farmId)
        end,
        canTrigger = function(farmId)
            return self:pickBreakdown(farmId)
        end,
        stages = {
            { key = "breakdown", run = function(incident)
                return self:onBreakdown(incident)
            end },
        },
        console = {
            prepareTrigger = function(farmId, details)
                return self:prepareTrigger(details)
            end,
            clearTrigger = function()
                self.forcedFieldService = nil
            end,
        },
    })
end

-- The roll (server) ------------------------------------------------------------------

-- Expected breakdowns a month (before the setting): none without ADS, fewer
-- until the farm can do any.
function TheContractorFieldBreakdowns.getRate(farmId)
    if not TCADSRepairContracts.isActive() then
        return 0
    end
    local rate = TheContractorFieldBreakdowns.RATE_PER_PERIOD
    if not TheContractorRepairContracts.hasBreakdownKit(farmId, TCADSRepairContracts.FIELD_SERVICE.PLAYER) then
        rate = rate * TheContractorFieldBreakdowns.NO_KIT_RATE_FACTOR
    end
    return rate
end

-- "player" or "mobile": even odds with a van (or with nothing), mostly what
-- a tool box can fix with only that.
function TheContractorFieldBreakdowns.pickFieldService(farmId, random)
    local fieldService = TCADSRepairContracts.FIELD_SERVICE
    local places = TCADSRepairContracts.getFarmPlaces(farmId)
    local playerShare = 0.5
    if not places[TCADSRepairContracts.PLACE.OWN_MOBILE] and places[TCADSRepairContracts.PLACE.PLAYER] then
        playerShare = TheContractorFieldBreakdowns.TOOL_BOX_PLAYER_SHARE
    end
    return random() < playerShare and fieldService.PLAYER or fieldService.MOBILE
end

-- Whether the farm already has a breakdown on its way or on offer or taken
-- on: one at a time.
function TheContractorFieldBreakdowns.hasOpenBreakdown(farmId)
    local tc = g_currentMission.TheContractor
    for _, job in ipairs(tc.Jobs:getAllJobs(farmId)) do
        if TheContractorRepairContracts.isBreakdownJob(job) and not job:isTerminal() then
            return true
        end
    end
    for _, entry in ipairs(tc.RepairContracts.arrivals) do
        if entry.farmId == farmId and entry.fieldId ~= nil then
            return true
        end
    end
    return false
end

-- An NPC's field with no live job on it and a boundary to stand in.
function TheContractorFieldBreakdowns.isEligibleField(field)
    local fieldId = field ~= nil and field:getId() or nil
    return fieldId ~= nil and field:getOwner() == FarmlandManager.NO_OWNER_FARM_ID and
        not g_currentMission.TheContractor.Jobs:isFieldProtected(fieldId)
end

function TheContractorFieldBreakdowns.getEligibleFields()
    local result = {}
    for _, field in ipairs(g_fieldManager:getFields()) do
        if TheContractorFieldBreakdowns.isEligibleField(field) then
            table.insert(result, field)
        end
    end
    return result
end

-- canTrigger (068): the incident's starting data, or nil.
function TheContractorFieldBreakdowns:pickBreakdown(farmId)
    if not TCADSRepairContracts.isActive() or TheContractorFieldBreakdowns.hasOpenBreakdown(farmId) then
        return nil
    end
    local fields = TheContractorFieldBreakdowns.getEligibleFields()
    if #fields == 0 then
        return nil
    end
    local standing = g_currentMission.TheContractor.Reputation:getStanding(farmId)
    return {
        fieldId = fields[math.random(1, #fields)]:getId(),
        fieldService = self.forcedFieldService or TheContractorFieldBreakdowns.pickFieldService(farmId, math.random),
        severity = TheContractorRepairContracts.pickSeverity(standing, math.random),
    }
end

-- The console's details: none, or the field service level to force.
function TheContractorFieldBreakdowns:prepareTrigger(details)
    local wanted = details[1] ~= nil and string.lower(details[1]) or nil
    if wanted == nil then
        return nil
    end
    for _, fieldService in pairs(TCADSRepairContracts.FIELD_SERVICE) do
        if fieldService == wanted then
            self.forcedFieldService = fieldService
            return nil
        end
    end
    return "Usage: tcCompany event fieldBreakdown [player|mobile]"
end

-- Model and spot (server) ------------------------------------------------------------

function TheContractorFieldBreakdowns.isWinter()
    local environment = g_currentMission.environment
    return Season ~= nil and environment.getSeasonAtDay ~= nil and
        environment:getSeasonAtDay(environment.currentMonotonicDay) == Season.WINTER
end

-- A model for a breakdown: a tractor, or now and then a harvester (never
-- in winter). Any ADS model 100's zones could get, whatever its size.
function TheContractorFieldBreakdowns.pickModel(repairContracts, random)
    local zoneType = PlaceableTCRepairZone.ZONE_TYPE
    local tractors = repairContracts:getEligibleModels(zoneType.VEHICLE)
    local harvesters = TheContractorFieldBreakdowns.isWinter() and {} or
        repairContracts:getEligibleModels(zoneType.HARVESTER)
    local list = tractors
    if #harvesters > 0 and (#tractors == 0 or random() < TheContractorFieldBreakdowns.HARVESTER_SHARE) then
        list = harvesters
    end
    if #list == 0 then
        return nil
    end
    return list[math.floor(random() * #list) + 1] or list[#list]
end

-- A spot inside the field, far enough in from its edge for the model, and
-- a random heading: x, z, rotY, or nil.
function TheContractorFieldBreakdowns.pickSpot(fieldId, model, random)
    local field = g_fieldManager:getFieldById(fieldId)
    local boundary = field ~= nil and TCJoyriderRuts.getFieldBoundary(field) or {}
    if #boundary < 3 then
        return nil
    end
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    for _, point in ipairs(boundary) do
        minX, maxX = math.min(minX, point[1]), math.max(maxX, point[1])
        minZ, maxZ = math.min(minZ, point[2]), math.max(maxZ, point[2])
    end
    local margin = TheContractorFieldBreakdowns.EDGE_MARGIN + math.max(model.width, model.length) * 0.5
    for _ = 1, TheContractorFieldBreakdowns.SPOT_TRIES do
        local x = minX + random() * (maxX - minX)
        local z = minZ + random() * (maxZ - minZ)
        if TCJoyriderRuts.isPointInside(x, z, boundary) and
                TCJoyriderRuts.getDistanceToBoundary(x, z, boundary) >= margin then
            return x, z, random() * 2 * math.pi
        end
    end
    return nil
end

-- Stages (server) ---------------------------------------------------------------------

function TheContractorFieldBreakdowns:onBreakdown(incident)
    local tc = g_currentMission.TheContractor
    local data = incident.data
    -- Someone may have taken a job on the field since the roll.
    local field = g_fieldManager:getFieldById(data.fieldId)
    if not TCADSRepairContracts.isActive() or not TheContractorFieldBreakdowns.isEligibleField(field) then
        return TheContractorRandomEvents.DONE
    end

    local model = TheContractorFieldBreakdowns.pickModel(tc.RepairContracts, math.random)
    local x, z, rotY = nil, nil, nil
    if model ~= nil then
        x, z, rotY = TheContractorFieldBreakdowns.pickSpot(data.fieldId, model, math.random)
    end
    if x == nil then
        Logging.info("TheContractor: farm %d incident %d: no machine or no room for a breakdown on field %d",
            incident.farmId, incident.id, data.fieldId)
        return TheContractorRandomEvents.DONE
    end

    tc.RepairContracts:queueFieldArrival(incident.farmId, data.fieldId, model, x, z, rotY, data.fieldService,
        data.severity)
    return TheContractorRandomEvents.DONE
end
