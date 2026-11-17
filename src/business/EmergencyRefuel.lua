-- Emergency refuel (127), a random event (068): one of a farmer's machines
-- (121) has run out of diesel on their field, and they ring the player to
-- bring some. The player takes diesel from the farm's own stock however they
-- like (a fuel trailer, a tank pallet, or tows it to a station) and fills it
-- up. Due today, like a breakdown. Diesel only.
--
-- When: RATE_PER_PERIOD a month, BUSY_FACTOR times that in the busy months
-- (BUSY_PERIODS: spring and harvest), in TRIGGER_HOURS, one at a time per
-- farm and per farmer. The farmer (never the official) isn't fallen out
-- with the farm (113), is picked by the relationship's offer weight, has a
-- field of their own no player owns with no live job on it, and a machine
-- free (not out, 121) that runs on diesel: one of their tractors, or their
-- combine COMBINE_SHARE of the time in HARVEST_PERIODS. The reason (REASONS)
-- is picked at the roll and kept with the job.
--
-- The job (JOB_TYPES' emergencyRefuel, made only by this event): the farmer
-- is its customer, on their field (offField: nothing's done to the field,
-- the marker's on the machine), due today, allocated to the farm's players
-- as it's accepted (allocateOnAccept). Its litres (TARGET_SHARE of the
-- tank, as it starts empty) are fixed at the offer.
--
-- The machine: accepting the job brings it out through 100's queue (a loan
-- arrival, no ADS) to its spot on the field's headland (101's spot rule),
-- with its attachment, and its diesel tank is emptied there (onLoanArrived),
-- so the engine won't run. The farmer waits by it (TCYardFarmers). It's a
-- contract vehicle (not sold, not on our lists), never locked for driving.
-- Done when the server sees its diesel at TARGET_SHARE of the tank or more,
-- however it got there. Once the job's over the farmer collects it (and its
-- attachment) when nobody's in it or towing it and nobody can see it
-- (queueLoanCollection's whenUnseen). A miss is an ordinary miss: the
-- diesel was always the player's.
--
-- Pay: the litres at the diesel price (vanilla's, EconomyScale's already,
-- so divided back out) times PRICE_FACTOR, plus CALL_OUT_FEE at the job pay
-- rate, as a base price (scaled live as job prices are). A little
-- reputation (JOB_TYPES' reputationReward) and RELATIONSHIP_BONUS on top of
-- a job's relationship gain, as a favour (116) does more for the farmer
-- than for the farm's name. The player drives it, so its quality is 100.
--
-- State: job.refuel, with the job (saved and sent).

TheContractorEmergencyRefuel = {}
TheContractorEmergencyRefuel_mt = Class(TheContractorEmergencyRefuel)

TheContractorEmergencyRefuel.EVENT_TYPE = "emergencyRefuel"
TheContractorEmergencyRefuel.JOB_TYPE = "emergencyRefuel"
TheContractorEmergencyRefuel.MESSAGE_KIND = "emergencyRefuel"
TheContractorEmergencyRefuel.LOAN_OWNER = "EmergencyRefuel"

-- Why it's empty: each has its own offer text
-- (tc_refuel_offerBody_<reason>).
TheContractorEmergencyRefuel.REASONS = { "headland", "gauge", "forgot" }
-- 112: every offer is signed by the farmer (getCustomerNamedArgs).
TheContractorEmergencyRefuel.NAMED_BODY_KEYS = {}
for _, reason in ipairs(TheContractorEmergencyRefuel.REASONS) do
    TheContractorEmergencyRefuel.NAMED_BODY_KEYS["tc_refuel_offerBody_" .. reason] = true
end

-- About one every two and a half months, twice that in the busy months:
-- spring (March to May) and harvest (July to October), by 068's periods.
TheContractorEmergencyRefuel.RATE_PER_PERIOD = 0.4
TheContractorEmergencyRefuel.BUSY_FACTOR = 2
TheContractorEmergencyRefuel.BUSY_PERIODS = { [1] = true, [2] = true, [3] = true, [5] = true, [6] = true, [7] = true,
    [8] = true }
TheContractorEmergencyRefuel.HARVEST_PERIODS = { [5] = true, [6] = true, [7] = true, [8] = true }
TheContractorEmergencyRefuel.COOLDOWN_PERIODS = 0
-- Due the day it's asked, so it's asked by 15:00, with the afternoon to do
-- it in.
TheContractorEmergencyRefuel.TRIGGER_HOURS = { 8, 15 }

-- At harvest, the share that are the farmer's combine (when it's free).
TheContractorEmergencyRefuel.COMBINE_SHARE = 0.3

-- Done at this share of the tank; the litres asked for are this share of
-- its capacity, rounded up.
TheContractorEmergencyRefuel.TARGET_SHARE = 0.25

-- Pay (base): the diesel at its price times this, plus the call-out.
TheContractorEmergencyRefuel.PRICE_FACTOR = 1.5
TheContractorEmergencyRefuel.CALL_OUT_FEE = 150

-- On top of a completed job's relationship gain (113).
TheContractorEmergencyRefuel.RELATIONSHIP_BONUS = 5

-- How often the server looks for finished jobs' machines to send home.
TheContractorEmergencyRefuel.COLLECT_CHECK_MS = 500

local function isTractor(role)
    local ROLE = TheContractorFarmerFleet.ROLE
    return role == ROLE.SMALL_TRACTOR or role == ROLE.MEDIUM_TRACTOR or role == ROLE.LARGE_TRACTOR
end

function TheContractorEmergencyRefuel.new()
    local self = {}
    setmetatable(self, TheContractorEmergencyRefuel_mt)

    -- Server: tcEvent trigger emergencyRefuel [reason] [combine] [farmer],
    -- for one trigger.
    self.forcedReason = nil
    self.forcedFarmerId = nil
    self.forcedCombine = false

    self.collectMs = 0

    return self
end

-- Every machine, at load, before the save loads (068).
function TheContractorEmergencyRefuel:register(randomEvents, inbox)
    randomEvents:registerEventType(TheContractorEmergencyRefuel.EVENT_TYPE, {
        l10nKey = "tc_refuel_eventName",
        cooldownPeriods = TheContractorEmergencyRefuel.COOLDOWN_PERIODS,
        triggerHours = TheContractorEmergencyRefuel.TRIGGER_HOURS,
        ratePerPeriod = function(farmId)
            return TheContractorEmergencyRefuel.getRate(farmId)
        end,
        canTrigger = function(farmId)
            return self:pickRequest(farmId)
        end,
        stages = {
            { key = "asked", run = function(incident)
                return self:onAsked(incident)
            end },
        },
        console = {
            details = "[headland|gauge|forgot] [combine] [farmer]",
            prepareTrigger = function(farmId, details)
                return self:prepareTrigger(details)
            end,
            clearTrigger = function()
                self.forcedReason = nil
                self.forcedFarmerId = nil
                self.forcedCombine = false
            end,
        },
    })

    inbox:registerMessageKind(TheContractorEmergencyRefuel.MESSAGE_KIND, {
        endsWithJob = true,
        category = "job",
        chipTone = "warn",
        getArgs = function(message)
            return TheContractorEmergencyRefuel.getOfferArgs(message)
        end,
    })
end

-- Reading (every machine) -------------------------------------------------------------

local function isTakenOn(job)
    return job.state == TheContractorJob.STATE.ACCEPTED or job.state == TheContractorJob.STATE.ALLOCATED or
        job.state == TheContractorJob.STATE.IN_PROGRESS
end

-- The farms and the farmers with an open (not finished) refuel.
function TheContractorEmergencyRefuel.getOpenJobs()
    local farms, farmers = {}, {}
    local jobs = g_currentMission.TheContractor.Jobs
    for farmId, farmJobs in pairs(jobs.jobsByFarm) do
        for _, job in pairs(farmJobs) do
            if job.refuel ~= nil and not job:isTerminal() then
                farms[farmId] = true
                farmers[job.refuel.farmerId or 0] = true
            end
        end
    end
    return farms, farmers
end

-- The machine's record in the farmer's fleet (every machine holds it), or
-- nil.
function TheContractorEmergencyRefuel.getFleetMachine(refuel)
    local farmers = g_currentMission.TheContractor.Farmers
    local farmer = farmers ~= nil and refuel ~= nil and farmers:getPerson(refuel.farmerId) or nil
    return TheContractorFarmerFleet.getMachine(farmer, refuel ~= nil and refuel.machineId or nil)
end

-- "Fendt 724 Vario", as the farmer's machine is now (122 can change its
-- model under the same id).
function TheContractorEmergencyRefuel.getMachineName(refuel)
    local machine = TheContractorEmergencyRefuel.getFleetMachine(refuel)
    if machine == nil then
        return g_i18n:getText("tc_refuel_machineUnknown")
    end
    return TheContractorFarmerFleet.getModelName(machine.xmlFilename)
end

-- The offer's args: the machine's name as it is now first, then what was
-- posted (the field, the litres), then the farmer's name (112).
function TheContractorEmergencyRefuel.getOfferArgs(message)
    local args = TheContractorInbox.getCustomerNamedArgs(message, TheContractorEmergencyRefuel.NAMED_BODY_KEYS)
    if not TheContractorEmergencyRefuel.NAMED_BODY_KEYS[message.bodyKey] then
        return args
    end
    local inbox = g_currentMission.TheContractor.Inbox
    local job = inbox ~= nil and inbox:getMessageJob(message) or nil
    local result = { job ~= nil and TheContractorEmergencyRefuel.getMachineName(job.refuel) or
        g_i18n:getText("tc_refuel_machineUnknown") }
    for _, arg in ipairs(args) do
        table.insert(result, arg)
    end
    return result
end

-- The machine, if it's out (every machine that has it).
function TheContractorEmergencyRefuel.getMachine(refuel)
    local vehicleId = refuel ~= nil and refuel.machineVehicleId or nil
    local vehicle = vehicleId ~= nil and vehicleId ~= 0 and NetworkUtil.getObject(vehicleId) or nil
    if vehicle == nil or vehicle.isDeleted then
        return nil
    end
    return vehicle
end

-- The machine's and its attachment's vehicle ids (for the contract
-- vehicles): { id, ... }.
function TheContractorEmergencyRefuel.getMachineIds(refuel)
    local ids = {}
    if refuel ~= nil and (refuel.machineVehicleId or 0) ~= 0 then
        table.insert(ids, refuel.machineVehicleId)
    end
    if refuel ~= nil and (refuel.attachmentVehicleId or 0) ~= 0 then
        table.insert(ids, refuel.attachmentVehicleId)
    end
    return ids
end

-- A machine's diesel now: level, capacity (litres), or nil without a diesel
-- tank.
function TheContractorEmergencyRefuel.getTank(vehicle)
    local consumer = vehicle ~= nil and TCJobSupplies.getDieselConsumer(vehicle) or nil
    if consumer == nil then
        return nil
    end
    return vehicle:getFillUnitFillLevel(consumer.fillUnitIndex) or 0,
        vehicle:getFillUnitCapacity(consumer.fillUnitIndex) or 0
end

-- TCJobProgress (server): the diesel in the tank against TARGET_SHARE of
-- it; 0 until the machine's out.
function TheContractorEmergencyRefuel.getCompletion(job)
    local level, capacity = TheContractorEmergencyRefuel.getTank(TheContractorEmergencyRefuel.getMachine(job.refuel))
    if level == nil or capacity <= 0 then
        return 0
    end
    return math.min(1, level / (capacity * TheContractorEmergencyRefuel.TARGET_SHARE))
end

-- The menu's machine row (every machine): "Fendt 724 Vario, 100 l of
-- diesel".
function TheContractorEmergencyRefuel.getDetailText(job)
    local refuel = job.refuel
    return string.format(g_i18n:getText("tc_refuel_detailValue"), TheContractorEmergencyRefuel.getMachineName(refuel),
        g_i18n:formatVolume(refuel.liters or 0, 0))
end

-- TCJobHotspots (every machine): on the machine while the job's taken on,
-- following it, or its spot on the field until it's out.
function TheContractorEmergencyRefuel.getSpot(job)
    local refuel = job.refuel
    if refuel == nil or not isTakenOn(job) then
        return nil
    end
    local vehicle = TheContractorEmergencyRefuel.getMachine(refuel)
    if vehicle ~= nil and vehicle.rootNode ~= nil then
        local x, _, z = getWorldTranslation(vehicle.rootNode)
        return { x = x, z = z }
    end
    return { x = refuel.x, z = refuel.z }
end

-- The logbook's record of it (060, in 124's shape, server): { fillTypeName,
-- requiredLiters (asked for), deliveredLiters (in the tank as it ended),
-- machineName }, or nil.
function TheContractorEmergencyRefuel.getLogbookDelivery(job)
    local refuel = job.refuel
    if refuel == nil then
        return nil
    end
    local level = TheContractorEmergencyRefuel.getTank(TheContractorEmergencyRefuel.getMachine(refuel))
    return {
        fillTypeName = "DIESEL",
        requiredLiters = refuel.liters or 0,
        deliveredLiters = level or 0,
        excessLiters = 0,
        excessPay = 0,
        machineName = TheContractorEmergencyRefuel.getMachineName(refuel),
    }
end

-- The machine (server) -----------------------------------------------------------------

-- A model's diesel tank in litres, from its vehicle XML as the shop reads
-- it (Motorized.loadSpecValueFuel, its first configurations), or 0 if it
-- has none or the store hasn't got it. Kept per model for the session
-- (tankCache). Engine side, replaced in the tests.
local tankCache = {}

function TheContractorEmergencyRefuel.getTankCapacity(xmlFilename)
    if xmlFilename == nil or g_storeManager:getItemByXMLFilename(xmlFilename) == nil then
        return 0
    end
    if tankCache[xmlFilename] ~= nil then
        return tankCache[xmlFilename]
    end
    local xmlFile = XMLFile ~= nil and Motorized ~= nil and Motorized.loadSpecValueFuel ~= nil and
        XMLFile.load("tcRefuelTank", xmlFilename, Vehicle.xmlSchema) or nil
    if xmlFile == nil then
        tankCache[xmlFilename] = 0
        return 0
    end
    local spec = Motorized.loadSpecValueFuel(xmlFile)
    xmlFile:delete()
    tankCache[xmlFilename] = TheContractorEmergencyRefuel.getDieselCapacityFromSpec(spec)
    return tankCache[xmlFilename]
end

-- From loadSpecValueFuel's { fillUnits, consumers }: the diesel consumer's
-- own capacity, else its fill unit's (first configurations), else 0.
function TheContractorEmergencyRefuel.getDieselCapacityFromSpec(spec)
    local consumers = spec ~= nil and spec.consumers ~= nil and spec.consumers[1] or {}
    for _, consumer in ipairs(consumers) do
        if consumer.fillType ~= nil and string.lower(consumer.fillType) == "diesel" then
            if (consumer.capacity or 0) > 0 then
                return consumer.capacity
            end
            local fillUnits = spec.fillUnits ~= nil and spec.fillUnits[1] or {}
            local fillUnit = fillUnits[consumer.fillUnitIndex or 1]
            return fillUnit ~= nil and fillUnit.capacity or 0
        end
    end
    return 0
end

-- At unload: models can change with the mods loaded.
function TheContractorEmergencyRefuel.clearTankCache()
    tankCache = {}
end

-- A farmer's machines that could have run dry: { { machine, model,
-- capacity, isCombine } } for each tractor (and their combine, if
-- withCombine) that's free, in the store and runs on diesel. With problems,
-- why each other one can't (for the log).
function TheContractorEmergencyRefuel.getFreeMachines(farmer, withCombine)
    local F = TheContractorFarmerFleet
    local result, problems = {}, {}
    for _, machine in ipairs(farmer.machines or {}) do
        local isCombine = machine.role == F.ROLE.COMBINE
        if isTractor(machine.role) or (isCombine and withCombine) then
            local model = F.getSizeModel(machine.xmlFilename)
            local capacity = model ~= nil and TheContractorEmergencyRefuel.getTankCapacity(machine.xmlFilename) or 0
            local problem = nil
            if model == nil then
                problem = "not in the store"
            elseif capacity <= 0 then
                problem = "no diesel tank"
            elseif F.isAnyOut(farmer, machine) then
                problem = "out already"
            else
                table.insert(result, { machine = machine, model = model, capacity = capacity, isCombine = isCombine })
            end
            if problem ~= nil then
                table.insert(problems, string.format("#%d %s: %s", machine.id, tostring(machine.xmlFilename), problem))
            end
        end
    end
    return result, problems
end

-- One of them: their combine COMBINE_SHARE of the time when it's there
-- (always, with preferCombine), else a tractor. Nil with none.
function TheContractorEmergencyRefuel.pickMachine(choices, preferCombine, random)
    local combines, tractors = {}, {}
    for _, choice in ipairs(choices) do
        table.insert(choice.isCombine and combines or tractors, choice)
    end
    local list = tractors
    if #combines > 0 and (preferCombine or #tractors == 0 or
            random() < TheContractorEmergencyRefuel.COMBINE_SHARE) then
        list = combines
    end
    if #list == 0 then
        return nil
    end
    return list[math.min(#list, math.floor(random() * #list) + 1)]
end

-- The farmer's fields it could happen on: their land, no player's, with no
-- live job on it and no crop a machine would be lost in (156), in id order.
function TheContractorEmergencyRefuel.getFields(farmer)
    local held = {}
    for _, farmlandId in ipairs(farmer.farmlandIds or {}) do
        held[farmlandId] = true
    end
    local jobs = g_currentMission.TheContractor.Jobs
    local result = {}
    for _, field in ipairs(g_fieldManager:getFields()) do
        local farmland = field.getFarmland ~= nil and field:getFarmland() or nil
        if farmland ~= nil and held[farmland:getId()] and field:getOwner() == FarmlandManager.NO_OWNER_FARM_ID and
                not jobs:isFieldProtected(field:getId()) and TCSiteClearance.isUsableField(field) then
            table.insert(result, field)
        end
    end
    table.sort(result, function(a, b)
        return a:getId() < b:getId()
    end)
    return result
end

-- The litres asked for: TARGET_SHARE of a tank this size, rounded up.
function TheContractorEmergencyRefuel.getLiters(capacity)
    return math.ceil((capacity or 0) * TheContractorEmergencyRefuel.TARGET_SHARE)
end

-- The roll (server) ----------------------------------------------------------------------

function TheContractorEmergencyRefuel.getPeriod()
    return g_currentMission.environment.currentPeriod
end

-- Expected calls a month (before the setting).
function TheContractorEmergencyRefuel.getRate(farmId)
    local rate = TheContractorEmergencyRefuel.RATE_PER_PERIOD
    if TheContractorEmergencyRefuel.BUSY_PERIODS[TheContractorEmergencyRefuel.getPeriod()] then
        rate = rate * TheContractorEmergencyRefuel.BUSY_FACTOR
    end
    return rate
end

function TheContractorEmergencyRefuel.isHarvest()
    return TheContractorEmergencyRefuel.HARVEST_PERIODS[TheContractorEmergencyRefuel.getPeriod()] == true
end

-- The farmers who could call: never the official, not fallen out with the
-- farm, no refuel open already, a field and a machine free. { { farmer,
-- weight } }.
function TheContractorEmergencyRefuel:getCandidateFarmers(farmId, withCombine)
    local tc = g_currentMission.TheContractor
    local _, openFarmers = TheContractorEmergencyRefuel.getOpenJobs()
    local candidates = {}
    for _, farmer in ipairs(tc.Farmers:getFarmers()) do
        local weight = tc.Relationships:getOfferWeight(farmId, farmer.id)
        local problem = nil
        -- Anyone else (the official, or not the console's farmer) isn't
        -- asked, so isn't logged.
        if farmer.isOfficial or (self.forcedFarmerId ~= nil and self.forcedFarmerId ~= farmer.id) then
            problem = nil
        elseif weight <= 0 then
            problem = "fallen out with the farm"
        elseif openFarmers[farmer.id] then
            problem = "a refuel on already"
        elseif #TheContractorEmergencyRefuel.getFields(farmer) == 0 then
            problem = "no field of theirs free"
        else
            local machines, problems = TheContractorEmergencyRefuel.getFreeMachines(farmer, withCombine)
            if #machines > 0 then
                table.insert(candidates, { farmer = farmer, weight = weight })
            else
                problem = #problems > 0 and table.concat(problems, "; ") or "no tractor in their fleet"
            end
        end
        if problem ~= nil then
            TCLog.info("TheContractor: emergencyRefuel: farmer #%d (%s) can't call: %s", farmer.id,
                tostring(farmer.name), problem)
        end
    end
    return candidates
end

-- canTrigger (068): { farmerId, machineId, fieldId, reason }, or nil.
function TheContractorEmergencyRefuel:pickRequest(farmId)
    local R = TheContractorEmergencyRefuel
    local openFarms = R.getOpenJobs()
    if openFarms[farmId] then
        TCLog.info("TheContractor: emergencyRefuel: farm %d has a refuel on already", farmId)
        return nil
    end
    local withCombine = self.forcedCombine or R.isHarvest()
    local farmer = TheContractorYardBales.pickWeighted(self:getCandidateFarmers(farmId, withCombine), math.random)
    if farmer == nil then
        TCLog.info("TheContractor: emergencyRefuel: none of the %d farmers can call",
            #g_currentMission.TheContractor.Farmers:getFarmers())
        return nil
    end
    local choice = R.pickMachine(R.getFreeMachines(farmer, withCombine), self.forcedCombine, math.random)
    local fields = R.getFields(farmer)
    if choice == nil or (self.forcedCombine and not choice.isCombine) then
        TCLog.info("TheContractor: emergencyRefuel: farmer #%d has no %s free", farmer.id,
            self.forcedCombine and "combine" or "machine")
        return nil
    end
    return {
        farmerId = farmer.id,
        machineId = choice.machine.id,
        fieldId = fields[math.random(1, #fields)]:getId(),
        reason = self.forcedReason or R.REASONS[math.random(1, #R.REASONS)],
    }
end

-- The console's details: [headland|gauge|forgot] [combine] [farmer id or
-- full name], in any order.
function TheContractorEmergencyRefuel:prepareTrigger(details)
    local rest = {}
    for _, detail in ipairs(details) do
        local lower = string.lower(detail)
        local isKnown = false
        for _, reason in ipairs(TheContractorEmergencyRefuel.REASONS) do
            if lower == reason then
                self.forcedReason = reason
                isKnown = true
            end
        end
        if lower == "combine" then
            self.forcedCombine = true
            isKnown = true
        end
        if not isKnown then
            table.insert(rest, detail)
        end
    end
    if #rest == 0 then
        return nil
    end
    local wanted = table.concat(rest, " ")
    for _, farmer in ipairs(g_currentMission.TheContractor.Farmers:getFarmers()) do
        if not farmer.isOfficial and (tostring(farmer.id) == wanted or string.lower(farmer.name) == string.lower(wanted)) then
            self.forcedFarmerId = farmer.id
            return nil
        end
    end
    self.forcedReason, self.forcedCombine = nil, false
    return "Usage: tcEvent trigger emergencyRefuel [headland|gauge|forgot] [combine] [farmer id or name] (tcFarmer list)"
end

-- Pricing (server) ----------------------------------------------------------------------

-- The diesel's rate per litre, as a base amount: vanilla's diesel price
-- (EconomyScale's already, so divided back out) times PRICE_FACTOR.
function TheContractorEmergencyRefuel.getBasePricePerLiter()
    local economyManager = g_currentMission.economyManager
    local price = economyManager ~= nil and economyManager:getCostPerLiter(FillType.DIESEL) or 0
    return price * TheContractorEmergencyRefuel.PRICE_FACTOR / TCEconomyScale.getFactor()
end

-- The job's base price: the litres at the rate, plus the call-out fee at
-- the job pay rate.
function TheContractorEmergencyRefuel.getBasePrice(liters, basePricePerLiter, payMultiplier)
    return math.floor(liters * basePricePerLiter + TheContractorEmergencyRefuel.CALL_OUT_FEE * (payMultiplier or 1) +
        0.5)
end

-- The offer (server) ---------------------------------------------------------------------

function TheContractorEmergencyRefuel:onAsked(incident)
    local tc = g_currentMission.TheContractor
    local R = TheContractorEmergencyRefuel
    local data = incident.data
    local farmer = tc.Farmers:getPerson(data.farmerId)
    local machine = farmer ~= nil and not farmer.isOfficial and TheContractorFarmerFleet.getMachine(farmer,
        data.machineId) or nil
    local model = machine ~= nil and TheContractorFarmerFleet.getSizeModel(machine.xmlFilename) or nil
    local capacity = model ~= nil and R.getTankCapacity(machine.xmlFilename) or 0
    local field = g_fieldManager:getFieldById(data.fieldId)
    if model == nil or capacity <= 0 or field == nil or TheContractorFarmerFleet.isAnyOut(farmer, machine) or
            tc.Jobs:isFieldProtected(data.fieldId) or not TCSiteClearance.isUsableField(field) then
        TCLog.info("TheContractor: farm %d incident %d: farmer #%s's machine #%s or field %s isn't free",
            incident.farmId, incident.id, tostring(data.farmerId), tostring(data.machineId), tostring(data.fieldId))
        return TheContractorRandomEvents.DONE
    end
    local attachment = TheContractorFarmerFleet.getAttachmentArrival(farmer, machine)
    local x, z, rotY = TheContractorFieldBreakdowns.pickSpot(data.fieldId,
        TheContractorFarmerFleet.getFootprint(model, attachment), math.random)
    if x == nil then
        TCLog.info("TheContractor: farm %d incident %d: no room for farmer #%d's %s on field %d", incident.farmId,
            incident.id, farmer.id, model.name, data.fieldId)
        return TheContractorRandomEvents.DONE
    end

    local liters = R.getLiters(capacity)
    local refuel = {
        farmerId = farmer.id,
        machineId = machine.id,
        attachmentMachineId = attachment ~= nil and attachment.machineId or nil,
        reason = data.reason,
        liters = liters,
        x = x,
        z = z,
        rotY = rotY,
    }

    local environment = g_currentMission.environment
    local today = environment.currentMonotonicDay
    local price = R.getBasePrice(liters, R.getBasePricePerLiter(), tc.Settings:getJobPayMultiplier())
    local job = tc.Jobs:createJob(incident.farmId, R.JOB_TYPE, data.fieldId, 1, environment:getPeriodFromDay(today),
        environment:getDayInPeriodFromDay(today), price, true, nil, today, false, nil, nil, nil, nil, nil, nil, refuel)
    if job == nil then
        return TheContractorRandomEvents.DONE
    end

    tc.Inbox:postMessage(incident.farmId, R.MESSAGE_KIND, "tc_refuel_offerTitle",
        "tc_refuel_offerBody_" .. tostring(data.reason), { field:getName(), "$volume_" .. liters }, nil,
        { incidentId = incident.id, jobId = job.id })
    TCLog.info("TheContractor: farm %d job %d: farmer #%d (%s) needs %.0f l in their %s (%.0f l tank) on field %d at %.0f, %.0f, for %.0f",
        incident.farmId, job.id, farmer.id, tostring(data.reason), liters, tostring(machine.xmlFilename), capacity,
        data.fieldId, x, z, job:getPrice())
    return TheContractorRandomEvents.DONE
end

-- The farmer's machine (server) -------------------------------------------------------------

-- Jobs:onJobAccepted: the machine comes out.
function TheContractorEmergencyRefuel:onJobAccepted(job)
    self:queueMachine(job)
end

function TheContractorEmergencyRefuel:queueMachine(job)
    local tc = g_currentMission.TheContractor
    local refuel = job.refuel
    local farmer = tc.Farmers:getPerson(refuel.farmerId)
    local machine = TheContractorFarmerFleet.getMachine(farmer, refuel.machineId)
    local model = machine ~= nil and TheContractorFarmerFleet.getSizeModel(machine.xmlFilename) or nil
    if model == nil then
        TCLog.info("TheContractor: farm %d job %d: farmer #%s's machine is gone", job.farmId, job.id,
            tostring(refuel.farmerId))
        return
    end
    local attachment = TheContractorFarmerFleet.getAttachmentArrival(farmer, machine)
    if attachment ~= nil and attachment.machineId ~= refuel.attachmentMachineId then
        attachment = nil
    end
    tc.RepairContracts:queueLoanArrival(job.farmId, job.id, farmer, machine, model,
        { x = refuel.x, z = refuel.z, rotY = refuel.rotY, fieldId = job.fieldId }, attachment,
        TheContractorEmergencyRefuel.LOAN_OWNER)
end

-- RepairContracts: whether a loan arrival is still wanted (its job taken on,
-- its machine not out yet).
function TheContractorEmergencyRefuel:isLoanWanted(entry)
    local job = g_currentMission.TheContractor.Jobs:getJob(entry.farmId, entry.jobId)
    return job ~= nil and job.refuel ~= nil and isTakenOn(job) and (job.refuel.machineVehicleId or 0) == 0
end

-- Server: the machine's tank emptied. Returns what was taken out.
function TheContractorEmergencyRefuel.emptyTank(vehicle, farmId)
    local consumer = TCJobSupplies.getDieselConsumer(vehicle)
    local level = consumer ~= nil and vehicle:getFillUnitFillLevel(consumer.fillUnitIndex) or 0
    if level <= 0 then
        return 0
    end
    return -(vehicle:addFillUnitFillLevel(farmId, consumer.fillUnitIndex, -level, consumer.fillType,
        ToolType.UNDEFINED, nil) or 0)
end

-- RepairContracts: the machine's on its spot (with its attachment, or nil),
-- and its tank's emptied.
function TheContractorEmergencyRefuel:onLoanArrived(entry, vehicle, attachment)
    if not self:isLoanWanted(entry) then
        TheContractorRepairContracts.deleteVehicle(vehicle)
        TheContractorRepairContracts.deleteVehicle(attachment)
        return
    end
    local job = g_currentMission.TheContractor.Jobs:getJob(entry.farmId, entry.jobId)
    local refuel = job.refuel
    if TCJobSupplies.getDieselConsumer(vehicle) == nil then
        TCLog.warning("TheContractor: farm %d job %d: the %s has no diesel tank", job.farmId, job.id,
            vehicle:getFullName())
    end
    TheContractorEmergencyRefuel.emptyTank(vehicle, job.farmId)
    refuel.machineUniqueId = vehicle.getUniqueId ~= nil and vehicle:getUniqueId() or nil
    refuel.attachmentUniqueId = attachment ~= nil and attachment.getUniqueId ~= nil and attachment:getUniqueId() or nil
    self:applyMachine(job.farmId, job.id, NetworkUtil.getObjectId(vehicle),
        attachment ~= nil and NetworkUtil.getObjectId(attachment) or 0)
    if g_server ~= nil then
        g_server:broadcastEvent(TCRefuelMachineEvent.new(job.farmId, job.id, refuel.machineVehicleId,
            refuel.attachmentVehicleId or 0))
    end
    TCLog.info("TheContractor: farm %d job %d: farmer #%d's %s is out of diesel on field %d%s", job.farmId, job.id,
        refuel.farmerId, vehicle:getFullName(), job.fieldId,
        attachment ~= nil and (" with the " .. attachment:getFullName()) or "")
end

-- Every machine (the server, and TCRefuelMachineEvent): the job's machine.
function TheContractorEmergencyRefuel:applyMachine(farmId, jobId, vehicleId, attachmentId)
    local job = g_currentMission.TheContractor.Jobs:getJob(farmId, jobId)
    if job == nil or job.refuel == nil then
        return
    end
    job.refuel.machineVehicleId = vehicleId ~= 0 and vehicleId or nil
    job.refuel.attachmentVehicleId = attachmentId ~= 0 and attachmentId or nil
    TheContractorRepairContracts.clearCache()
end

-- Server, from Jobs:completeJob after the relationship's moved: the
-- farmer's thanks on top.
function TheContractorEmergencyRefuel:onJobCompleted(job)
    g_currentMission.TheContractor.Relationships:adjust(job.farmId, job.customerId,
        TheContractorEmergencyRefuel.RELATIONSHIP_BONUS, "refuel")
end

-- Server: a finished job's machine (and attachment) goes home once nobody's
-- in it or towing it and nobody can see it.
function TheContractorEmergencyRefuel:collectMachine(job)
    local refuel = job.refuel
    local repairContracts = g_currentMission.TheContractor.RepairContracts
    if (refuel.machineVehicleId or 0) ~= 0 then
        repairContracts:queueLoanCollection(job.farmId, refuel.farmerId, refuel.machineVehicleId,
            refuel.machineUniqueId, refuel.machineId, true)
    end
    if (refuel.attachmentVehicleId or 0) ~= 0 then
        repairContracts:queueLoanCollection(job.farmId, refuel.farmerId, refuel.attachmentVehicleId,
            refuel.attachmentUniqueId, refuel.attachmentMachineId, true)
    end
    refuel.collected = true
end

function TheContractorEmergencyRefuel:collectFinishedMachines()
    local tc = g_currentMission.TheContractor
    for _, farm in ipairs(g_farmManager:getFarms()) do
        for _, job in ipairs(tc.Jobs:getAllJobs(farm.farmId)) do
            if job.refuel ~= nil and job:isTerminal() and not job.refuel.collected then
                self:collectMachine(job)
            end
        end
    end
end

function TheContractorEmergencyRefuel:update(dt)
    if not g_currentMission:getIsServer() then
        return
    end
    self.collectMs = self.collectMs + dt
    if self.collectMs >= TheContractorEmergencyRefuel.COLLECT_CHECK_MS then
        self.collectMs = 0
        self:collectFinishedMachines()
    end
end

-- After a load (server) ------------------------------------------------------------------

-- TheContractor:resolveSavedVehicles, after Jobs' and RepairContracts': the
-- machine gets its object ids back, and a job taken on without it (it never
-- came out, or it's gone) sends for it again.
function TheContractorEmergencyRefuel:resolveSavedVehicles()
    local tc = g_currentMission.TheContractor
    for _, farm in ipairs(g_farmManager:getFarms()) do
        for _, job in ipairs(tc.Jobs:getAllJobs(farm.farmId)) do
            local refuel = job.refuel
            if refuel ~= nil then
                refuel.machineVehicleId = refuel.machineUniqueId ~= nil and
                    TCVehicleIds.getObjectId(refuel.machineUniqueId) or nil
                refuel.attachmentVehicleId = refuel.attachmentUniqueId ~= nil and
                    TCVehicleIds.getObjectId(refuel.attachmentUniqueId) or nil
                if isTakenOn(job) and refuel.machineVehicleId == nil then
                    refuel.machineUniqueId, refuel.attachmentUniqueId = nil, nil
                    TheContractorRepairContracts.deleteVehicle(refuel.attachmentVehicleId ~= nil and
                        NetworkUtil.getObject(refuel.attachmentVehicleId) or nil)
                    refuel.attachmentVehicleId = nil
                    self:queueMachine(job)
                end
            end
        end
    end
    TheContractorRepairContracts.clearCache()
end

-- Sync and saves (with the job) -------------------------------------------------------------

local FLOAT_FIELDS = { "liters", "x", "z", "rotY" }
local INT_FIELDS = { "farmerId", "machineId", "attachmentMachineId" }

-- What clients hold: all but the vehicles' uniqueIds and whether it's been
-- sent home.
function TheContractorEmergencyRefuel.writeStream(streamId, refuel)
    if streamWriteBool(streamId, refuel ~= nil) then
        streamWriteString(streamId, refuel.reason or "")
        for _, name in ipairs(FLOAT_FIELDS) do
            streamWriteFloat32(streamId, refuel[name] or 0)
        end
        for _, name in ipairs(INT_FIELDS) do
            streamWriteInt32(streamId, refuel[name] or 0)
        end
        streamWriteInt32(streamId, refuel.machineVehicleId or 0)
        streamWriteInt32(streamId, refuel.attachmentVehicleId or 0)
    end
end

local function orNil(value)
    return value ~= 0 and value or nil
end

function TheContractorEmergencyRefuel.readStream(streamId)
    if not streamReadBool(streamId) then
        return nil
    end
    local refuel = { reason = streamReadString(streamId) }
    for _, name in ipairs(FLOAT_FIELDS) do
        refuel[name] = streamReadFloat32(streamId)
    end
    for _, name in ipairs(INT_FIELDS) do
        refuel[name] = streamReadInt32(streamId)
    end
    refuel.attachmentMachineId = orNil(refuel.attachmentMachineId)
    refuel.machineVehicleId = orNil(streamReadInt32(streamId))
    refuel.attachmentVehicleId = orNil(streamReadInt32(streamId))
    return refuel
end

-- The vehicles by uniqueId (TCVehicleIds), turned back into object ids by
-- resolveSavedVehicles.
function TheContractorEmergencyRefuel.saveToXML(xmlFile, key, refuel)
    setXMLString(xmlFile, key .. "#reason", refuel.reason or "")
    for _, name in ipairs(FLOAT_FIELDS) do
        setXMLFloat(xmlFile, key .. "#" .. name, refuel[name] or 0)
    end
    for _, name in ipairs(INT_FIELDS) do
        setXMLInt(xmlFile, key .. "#" .. name, refuel[name] or 0)
    end
    local machineUniqueId = refuel.machineUniqueId or TCVehicleIds.getUniqueId(refuel.machineVehicleId)
    if machineUniqueId ~= nil then
        setXMLString(xmlFile, key .. "#machineUniqueId", machineUniqueId)
    end
    local attachmentUniqueId = refuel.attachmentUniqueId or TCVehicleIds.getUniqueId(refuel.attachmentVehicleId)
    if attachmentUniqueId ~= nil then
        setXMLString(xmlFile, key .. "#attachmentUniqueId", attachmentUniqueId)
    end
    if refuel.collected then
        setXMLBool(xmlFile, key .. "#collected", true)
    end
end

function TheContractorEmergencyRefuel.loadFromXML(xmlFile, key)
    if not hasXMLProperty(xmlFile, key) then
        return nil
    end
    local refuel = { reason = getXMLString(xmlFile, key .. "#reason") or "" }
    for _, name in ipairs(FLOAT_FIELDS) do
        refuel[name] = getXMLFloat(xmlFile, key .. "#" .. name) or 0
    end
    for _, name in ipairs(INT_FIELDS) do
        refuel[name] = getXMLInt(xmlFile, key .. "#" .. name) or 0
    end
    refuel.attachmentMachineId = orNil(refuel.attachmentMachineId)
    refuel.machineUniqueId = getXMLString(xmlFile, key .. "#machineUniqueId")
    refuel.attachmentUniqueId = getXMLString(xmlFile, key .. "#attachmentUniqueId")
    refuel.collected = getXMLBool(xmlFile, key .. "#collected") == true
    return refuel
end

-- Nothing of its own to save or send: its state travels with the jobs.
function TheContractorEmergencyRefuel:writeInitialClientState(streamId, connection)
end

function TheContractorEmergencyRefuel:readInitialClientState(streamId, connection)
end
