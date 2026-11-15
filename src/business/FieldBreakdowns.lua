-- Field breakdowns (101), a random event (068): a customer's machine has
-- broken down out on an NPC's field, and they want it fixed on the spot,
-- today. FS25_AdvancedDamageSystem prepares it as its breakdown kind (one
-- fault at its critical stage, two at severity 3, the engine dead about a
-- third of the time) with a field service level: "player" (the player can
-- fix it with ADS's tool box) or "mobile" (it takes a mobile workshop van).
-- See tickets/101.
--
-- Everything after the roll is 100's (TheContractorRepairContracts): the
-- machine goes on its arrivals queue with a spot on the field instead of a
-- bay, is spawned, prepared, and
-- offered as an adsBreakdown job due today. 102: it's inspected on the spot,
-- then priced from the Inbox like a repair zone job, against the
-- adsFieldMargin benchmark. Without the kit for its level
-- (getBreakdownProblem: a tool box or the farm's own van for "player", the
-- van for "mobile") it can still be taken on, with a warning: a hired mobile
-- workshop can do it, at a price. It's done when ADS says so; a lapsed
-- offer or a missed job and the customer's own recovery takes the machine
-- away (100's collection, judged where the machine stands).
--
-- The odds: RATE_PER_PERIOD a month while the farm has a tool box or a van,
-- NO_KIT_RATE_FACTOR of that until it has either, so a new company isn't
-- shown offers it can't do itself, and OVERCHARGE_ARRIVAL_FACTOR of it while
-- the farm's known for overcharging (102). A farm with a tool box but no
-- van mostly gets jobs a tool box can do. One at a time per farm, in
-- working hours.
--
-- 121: the machine is the field's farmer's own (TheContractorFarmerFleet),
-- one ADS can take that isn't out already: their combine HARVESTER_SHARE of
-- the time (never in winter), else a tractor or their telehandler. It has
-- its own seed and age, brings its attachment (a combine's header), and the
-- farmer's the customer. A field no farmer holds, or a farmer with nothing
-- ADS can take, gets a random model with no customer, as before.
--
-- 123: a farmer with a yard (108) that no player owns has it break down
-- there instead YARD_SHARE of the time, on one of the yard's synced spots
-- where the machine (and its attachment) fits on open ground (pickYardSpot,
-- shared with 116's favours); with no room it's on the field after all. A
-- yard breakdown has the yard (workshop.yardFarmlandId) and no field. The
-- farmer waits by their machine either way (TCYardFarmers, as for a favour).
--
-- State: none of its own. The incident's data is { fieldId, fieldService,
-- severity }; the machine, the model and the spot are picked as it happens.

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

-- Where the machine stands: on the headland, its centre at most
-- MAX_EDGE_DEPTH metres in from the field's edge, and at least EDGE_GAP
-- beyond half its own size from every edge (so a big one goes as far in
-- as it must). It faces in, as it drove.
TheContractorFieldBreakdowns.EDGE_GAP = 1
TheContractorFieldBreakdowns.MAX_EDGE_DEPTH = 10

-- 123: the share of a farmer's breakdowns in their yard, when they have one.
TheContractorFieldBreakdowns.YARD_SHARE = 0.3
-- A yard spot faces the yard's middle; the machine's corners must be open
-- ground (108's test) as well as its middle. This many spots are tried.
TheContractorFieldBreakdowns.YARD_SPOT_TRIES = 12

function TheContractorFieldBreakdowns.new()
    local self = {}
    setmetatable(self, TheContractorFieldBreakdowns_mt)

    -- Server: tcEvent trigger fieldBreakdown <player|mobile>, for one trigger.
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
            details = "[player|mobile]",
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
    -- 102: fewer call-outs while the farm's known for overcharging.
    local repairContracts = g_currentMission.TheContractor.RepairContracts
    if repairContracts ~= nil then
        rate = rate * repairContracts:getArrivalFactor(farmId)
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
        if entry.farmId == farmId and entry.kind == TCADSRepairContracts.KIND.BREAKDOWN then
            return true
        end
    end
    return false
end

-- An NPC's field with no live job on it, and no crop a machine would be
-- lost in (156's TCSiteClearance.isUsableField).
function TheContractorFieldBreakdowns.isEligibleField(field)
    local fieldId = field ~= nil and field:getId() or nil
    return fieldId ~= nil and field:getOwner() == FarmlandManager.NO_OWNER_FARM_ID and
        not g_currentMission.TheContractor.Jobs:isFieldProtected(fieldId) and
        TCSiteClearance.isUsableField(field)
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
    return {
        fieldId = fields[math.random(1, #fields)]:getId(),
        fieldService = self.forcedFieldService or TheContractorFieldBreakdowns.pickFieldService(farmId, math.random),
        severity = TheContractorRepairContracts.pickSeverity(math.random),
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
    return "Usage: tcEvent trigger fieldBreakdown [player|mobile]"
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

-- 121: one of the farmer's machines ADS can take and isn't out ({ machine,
-- model }), or nil: their combine HARVESTER_SHARE of the time when there's
-- one (never in winter), else one of the rest.
function TheContractorFieldBreakdowns.pickFarmerMachine(farmer, repairContracts, random)
    if farmer == nil then
        return nil
    end
    local isCombine = function(machine)
        return machine.role == TheContractorFarmerFleet.ROLE.COMBINE
    end
    local combines = {}
    if not TheContractorFieldBreakdowns.isWinter() then
        combines = TheContractorFarmerFleet.getRepairableMachines(farmer, repairContracts, isCombine)
    end
    local others = TheContractorFarmerFleet.getRepairableMachines(farmer, repairContracts, function(machine)
        return not isCombine(machine)
    end)
    local list = others
    if #combines > 0 and (#others == 0 or random() < TheContractorFieldBreakdowns.HARVESTER_SHARE) then
        list = combines
    end
    if #list == 0 then
        return nil
    end
    return list[math.floor(random() * #list) + 1] or list[#list]
end

-- 121: the farmer holding a field, or nil.
function TheContractorFieldBreakdowns.getFieldFarmer(field)
    local farmers = g_currentMission.TheContractor.Farmers
    local farmland = field ~= nil and field.getFarmland ~= nil and field:getFarmland() or nil
    if farmers == nil or farmland == nil then
        return nil
    end
    return farmers:getHolder(farmland:getId())
end

-- How far in from the edge the model's centre can be: { min, max }.
function TheContractorFieldBreakdowns.getEdgeDepth(model)
    local minDepth = math.max(model.width, model.length) * 0.5 + TheContractorFieldBreakdowns.EDGE_GAP
    return { minDepth, math.max(minDepth, TheContractorFieldBreakdowns.MAX_EDGE_DEPTH) }
end

-- A spot on a random stretch of the field's headland (fly-tipping's site
-- plan, 075, at the model's depth), facing in: x, z, rotY, or nil.
function TheContractorFieldBreakdowns.pickSpot(fieldId, model, random)
    local field = g_fieldManager:getFieldById(fieldId)
    local boundary = field ~= nil and TCJoyriderRuts.getFieldBoundary(field) or {}
    local site = TCJoyriderRuts.planDumpSite(boundary, nil, nil, random,
        TheContractorFieldBreakdowns.getEdgeDepth(model))
    if site == nil then
        return nil
    end
    return site.x, site.z, site.heading
end

-- 116, 123: a spot in a farmer's yard for a machine this size: one of the
-- yard's synced standing spots (114's, the server's) facing the yard's
-- middle, with every corner of the machine on open ground too. x, z, rotY
-- or nil.
function TheContractorFieldBreakdowns.pickYardSpot(farmlandId, model, random)
    local entry = g_currentMission.TheContractor.Yards:getSpots(farmlandId)
    if entry == nil or #entry.spots == 0 then
        return nil
    end
    local halfWidth, halfLength = model.width * 0.5, model.length * 0.5
    for _ = 1, TheContractorFieldBreakdowns.YARD_SPOT_TRIES do
        local spot = entry.spots[math.floor(random() * #entry.spots) + 1] or entry.spots[1]
        local rotY = MathUtil.getYRotationFromDirection(entry.x - spot.x, entry.z - spot.z)
        local vX, vZ = math.sin(rotY), math.cos(rotY)
        local uX, uZ = vZ, -vX
        local open = true
        for _, corner in ipairs({ { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }) do
            local x = spot.x + uX * halfWidth * corner[1] + vX * halfLength * corner[2]
            local z = spot.z + uZ * halfWidth * corner[1] + vZ * halfLength * corner[2]
            if not TheContractorYards.isOpenGround(farmlandId, x, z) then
                open = false
                break
            end
        end
        if open then
            return spot.x, spot.z, rotY
        end
    end
    return nil
end

-- 123: the farmer's yard, if they have one no player owns and the yards are
-- known, else nil.
function TheContractorFieldBreakdowns.getUsableYard(farmer)
    local farmlandId = farmer ~= nil and farmer.yardFarmlandId or nil
    if farmlandId == nil or g_currentMission.TheContractor.Yards == nil then
        return nil
    end
    if g_farmlandManager ~= nil and
            g_farmlandManager:getFarmlandOwner(farmlandId) ~= FarmlandManager.NO_OWNER_FARM_ID then
        return nil
    end
    return farmlandId
end

-- 123: where a farmer's machine breaks down: { x, z, rotY, yardFarmlandId
-- or fieldId }. In their yard YARD_SHARE of the time (if there's room),
-- else on the field's headland; nil with neither.
function TheContractorFieldBreakdowns.pickFarmerSpot(farmer, fieldId, model, random)
    local yardFarmlandId = TheContractorFieldBreakdowns.getUsableYard(farmer)
    if yardFarmlandId ~= nil and random() < TheContractorFieldBreakdowns.YARD_SHARE then
        local x, z, rotY = TheContractorFieldBreakdowns.pickYardSpot(yardFarmlandId, model, random)
        if x ~= nil then
            return { x = x, z = z, rotY = rotY, yardFarmlandId = yardFarmlandId }
        end
    end
    local x, z, rotY = TheContractorFieldBreakdowns.pickSpot(fieldId, model, random)
    if x == nil then
        return nil
    end
    return { x = x, z = z, rotY = rotY, fieldId = fieldId }
end

-- Server, once the machine's there: its run in from the edge and the crop
-- round it flattened or cut (156's TCSiteClearance), so it can be seen.
function TheContractorFieldBreakdowns.clearSpot(entry, model)
    local field = g_fieldManager:getFieldById(entry.fieldId)
    if field == nil or model == nil or entry.x == nil then
        return
    end
    TCSiteClearance.paintMachineSite(field, entry.x, entry.z, entry.rotY or 0, model.width, model.length)
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

    -- 121: the farmer's own machine, with room for it and its attachment;
    -- 123: now and then in their yard.
    local farmer = TheContractorFieldBreakdowns.getFieldFarmer(field)
    local choice = TheContractorFieldBreakdowns.pickFarmerMachine(farmer, tc.RepairContracts, math.random)
    if choice ~= nil then
        local attachment = TheContractorFarmerFleet.getAttachmentArrival(farmer, choice.machine)
        local spot = TheContractorFieldBreakdowns.pickFarmerSpot(farmer, data.fieldId,
            TheContractorFarmerFleet.getFootprint(choice.model, attachment), math.random)
        if spot ~= nil then
            tc.RepairContracts:queueBreakdownArrival(incident.farmId, spot, choice.model, data.fieldService,
                data.severity, { farmer = farmer, machine = choice.machine, attachment = attachment })
            return TheContractorRandomEvents.DONE
        end
    end

    local model = TheContractorFieldBreakdowns.pickModel(tc.RepairContracts, math.random)
    local x, z, rotY = nil, nil, nil
    if model ~= nil then
        x, z, rotY = TheContractorFieldBreakdowns.pickSpot(data.fieldId, model, math.random)
    end
    if x == nil then
        TCLog.info("TheContractor: farm %d incident %d: no machine or no room for a breakdown on field %d",
            incident.farmId, incident.id, data.fieldId)
        return TheContractorRandomEvents.DONE
    end

    tc.RepairContracts:queueBreakdownArrival(incident.farmId, { x = x, z = z, rotY = rotY, fieldId = data.fieldId },
        model, data.fieldService, data.severity)
    return TheContractorRandomEvents.DONE
end
