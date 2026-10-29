-- Farmer favours (116), a random event (068): one of the map's farmers (110)
-- asks the farm to fit a new part to one of their own machines. The machine
-- turns up in their yard (108), or on the headland of one of their fields
-- without one, and the job is to bring the part and fit it. The parts are
-- the ones a farm can keep in stock: ADS's fixed-size parts, the battery and
-- the air filter (TCADSRepairContracts.getStockParts), sold in S/M/L rather
-- than for one model and fitted by hand, so no tool box is needed. It pays
-- the part back and earns goodwill (113) more than reputation. See
-- docs/ads-farmer-favours.md.
--
-- The machines: each farmer owns one or two, kept on their record by
-- TheContractorFarmers and made here the first time a favour needs one
-- (ensureMachines): a tractor sized to their holding, with a seed of its own.
-- ADS ages it the first time it comes out (its quote's operating hours), and
-- from then on it's that age plus HOURS_PER_MONTH for every month since, so
-- it's the same machine every time, only older. What's been fitted to it and
-- when is kept too, so it isn't asked for again within REFIT_MONTHS.
--
-- Once the machine's loaded, ADS prepares it as a service of just one of
-- those parts (prepareVehicle's targets), worn as a service wears it, which
-- only a new one puts right (ADS counts it serviced above 95% condition).
-- One the machine hasn't got (targetNotApplicable) gives way to the other.
--
-- Everything else is 100's (TheContractorRepairContracts): the arrivals
-- queue, the job (adsFavour, a workshop job with the farmer as its customer
-- and no negotiation: accept or decline), completion when ADS says done,
-- tampering, collection.
--
-- The odds: RATE_PER_PERIOD a month for a farm with a company, one at a time
-- per farm, at most one per farmer whichever farm has it. A farmer the farm
-- has fallen out with asks nothing; the better the relationship, the likelier
-- they are to be the one asking. In working hours.
--
-- State: none of its own (the machines are the farmers'). The incident's
-- data is { farmerId }; the machine, the spot and the part are picked as it
-- happens.

TheContractorFarmerFavours = {}
TheContractorFarmerFavours_mt = Class(TheContractorFarmerFavours)

TheContractorFarmerFavours.EVENT_TYPE = "farmerFavour"
TheContractorFarmerFavours.JOB_TYPE = "adsFavour"

-- About one every two months.
TheContractorFarmerFavours.RATE_PER_PERIOD = 0.5
TheContractorFarmerFavours.COOLDOWN_PERIODS = 0
-- Due the day it's asked, so it's asked by 15:00 (068 holds a hit for an
-- hour from 08:00 to 14:00), with the afternoon to do it in.
TheContractorFarmerFavours.TRIGGER_HOURS = { 8, 15 }
-- ADS's severity for the part (how far gone it is).
TheContractorFarmerFavours.SEVERITY = 2

-- The rewards: relationship in place of a job's COMPLETED_GAIN, a little
-- reputation (word gets round), and the part paid back at ADS's list price.
TheContractorFarmerFavours.RELATIONSHIP_GAIN = 15
TheContractorFarmerFavours.REPUTATION = 2

-- A part fitted to a machine isn't asked for again on it for this long.
TheContractorFarmerFavours.REFIT_MONTHS = 12

-- A farmer's machines: a second one from SECOND_MACHINE_ACRES, tractors by
-- holding (under SMALL_ACRES small, under LARGE_ACRES medium, else large),
-- and HOURS_PER_MONTH { base, per acre, most } of work a month.
TheContractorFarmerFavours.SECOND_MACHINE_ACRES = 80
TheContractorFarmerFavours.SMALL_ACRES = 40
TheContractorFarmerFavours.LARGE_ACRES = 150
TheContractorFarmerFavours.HOURS_PER_MONTH = { 20, 0.3, 70 }

-- A farmer with a yard is this many times likelier to be the one asking,
-- so the machine's in a yard rather than on a headland when it can be.
TheContractorFarmerFavours.YARD_WEIGHT = 4

-- A yard spot faces the yard's middle; the machine's corners must be open
-- ground (108's test) as well as its middle.
TheContractorFarmerFavours.YARD_SPOT_TRIES = 12

function TheContractorFarmerFavours.new()
    local self = {}
    setmetatable(self, TheContractorFarmerFavours_mt)

    -- Server: tcCompany event farmerFavour <farmer>, for one trigger.
    self.forcedFarmerId = nil

    return self
end

-- Every machine, at load, before the save loads (068).
function TheContractorFarmerFavours:register(randomEvents)
    randomEvents:registerEventType(TheContractorFarmerFavours.EVENT_TYPE, {
        l10nKey = "tc_favour_eventName",
        cooldownPeriods = TheContractorFarmerFavours.COOLDOWN_PERIODS,
        triggerHours = TheContractorFarmerFavours.TRIGGER_HOURS,
        ratePerPeriod = function(farmId)
            return TheContractorFarmerFavours.getRate(farmId)
        end,
        canTrigger = function(farmId)
            return self:pickFarmer(farmId)
        end,
        stages = {
            { key = "asked", run = function(incident)
                return self:onAsked(incident)
            end },
        },
        console = {
            prepareTrigger = function(farmId, details)
                return self:prepareTrigger(details)
            end,
            clearTrigger = function()
                self.forcedFarmerId = nil
            end,
        },
    })
end

-- Reading (every machine) ---------------------------------------------------------

function TheContractorFarmerFavours.isFavourJob(job)
    return TheContractorRepairContracts.isFavourJob(job)
end

-- The part's name in ADS's words, as ADS writes it ("Battery"), for a chip
-- or a label.
function TheContractorFarmerFavours.getPartTitle(job)
    return TCADSRepairContracts.getText(job.workshop.targetNameKey)
end

-- The same for the middle of a sentence: "a new battery", but "a new ECU".
function TheContractorFarmerFavours.getPartName(job)
    local name = TheContractorFarmerFavours.getPartTitle(job)
    if string.find(name, "^%u%l") then
        name = string.lower(string.sub(name, 1, 1)) .. string.sub(name, 2)
    end
    return name
end

-- "Size L", the size the machine takes, or nil if ADS didn't say.
function TheContractorFarmerFavours.getPartSizeText(job)
    local grade = job.workshop.partGrade
    return grade ~= nil and string.format(g_i18n:getText("tc_favour_partSize"), grade) or nil
end

-- The part in a sentence with its size: "battery (size L)", or just
-- "battery".
function TheContractorFarmerFavours.getPartText(job)
    local grade = job.workshop.partGrade
    if grade == nil then
        return TheContractorFarmerFavours.getPartName(job)
    end
    return string.format(g_i18n:getText("tc_favour_partWithSize"), TheContractorFarmerFavours.getPartName(job), grade)
end

-- The roll (server) -------------------------------------------------------------------

-- Expected favours a month (before the setting): none without ADS's
-- targets or a part to ask for.
function TheContractorFarmerFavours.getRate(farmId)
    if not TCADSRepairContracts.hasTargets() or #TCADSRepairContracts.getStockParts() == 0 then
        return 0
    end
    return TheContractorFarmerFavours.RATE_PER_PERIOD
end

-- Whether a farmer has a favour on its way, on offer or taken on, with any
-- farm; and whether the farm has one with anybody.
function TheContractorFarmerFavours.getOpenFavours()
    local tc = g_currentMission.TheContractor
    local farmers, farms = {}, {}
    for farmId, farmJobs in pairs(tc.Jobs.jobsByFarm) do
        for _, job in pairs(farmJobs) do
            if TheContractorFarmerFavours.isFavourJob(job) and not job:isTerminal() then
                farmers[job.workshop.farmerId or 0] = true
                farms[farmId] = true
            end
        end
    end
    for _, entry in ipairs(tc.RepairContracts.arrivals) do
        if entry.favour then
            farmers[entry.farmerId or 0] = true
            farms[entry.farmId] = true
        end
    end
    return farmers, farms
end

-- canTrigger (068): { farmerId } or nil. A farmer with land and a yard or
-- a field to stand a machine on, asking nothing already, and not fallen out
-- with the farm; picked by the relationship's offer weight (113), times
-- YARD_WEIGHT for a farmer with a yard.
function TheContractorFarmerFavours:pickFarmer(farmId)
    if TheContractorFarmerFavours.getRate(farmId) <= 0 then
        return nil
    end
    local tc = g_currentMission.TheContractor
    local openFarmers, openFarms = TheContractorFarmerFavours.getOpenFavours()
    if openFarms[farmId] then
        return nil
    end
    local candidates, total = {}, 0
    for _, farmer in ipairs(tc.Farmers:getFarmers()) do
        local weight = tc.Relationships:getOfferWeight(farmId, farmer.id)
        if farmer.yardFarmlandId ~= nil then
            weight = weight * TheContractorFarmerFavours.YARD_WEIGHT
        end
        if (self.forcedFarmerId == nil or self.forcedFarmerId == farmer.id) and not openFarmers[farmer.id] and
                #farmer.farmlandIds > 0 and weight > 0 then
            table.insert(candidates, { farmer = farmer, weight = weight })
            total = total + weight
        end
    end
    local roll = math.random() * total
    for _, candidate in ipairs(candidates) do
        roll = roll - candidate.weight
        if roll < 0 then
            return { farmerId = candidate.farmer.id }
        end
    end
    return candidates[#candidates] ~= nil and { farmerId = candidates[#candidates].farmer.id } or nil
end

-- The console's details: none, or a farmer (id or full name) to ask.
function TheContractorFarmerFavours:prepareTrigger(details)
    if details[1] == nil then
        return nil
    end
    local wanted = table.concat(details, " ")
    for _, farmer in ipairs(g_currentMission.TheContractor.Farmers:getFarmers()) do
        if tostring(farmer.id) == wanted or string.lower(farmer.name) == string.lower(wanted) then
            self.forcedFarmerId = farmer.id
            return nil
        end
    end
    return "Usage: tcCompany event farmerFavour [farmer id or name] (tcCompany farmers lists them)"
end

-- The machines (server) -----------------------------------------------------------------

-- The tractor category for a holding's acres.
function TheContractorFarmerFavours.getCategoryForAcres(acres)
    local F = TheContractorFarmerFavours
    if acres < F.SMALL_ACRES then
        return "TRACTORSS"
    elseif acres < F.LARGE_ACRES then
        return "TRACTORSM"
    end
    return "TRACTORSL"
end

function TheContractorFarmerFavours.getHoursPerMonth(acres)
    local hours = TheContractorFarmerFavours.HOURS_PER_MONTH
    return math.min(hours[1] + acres * hours[2], hours[3])
end

-- Gives a farmer with none their machines, from models (100's tractor
-- models) of their holding's size, or any if there are none of it. Returns
-- the machines (empty without models).
function TheContractorFarmerFavours.ensureMachines(farmer, models, acres, random)
    if farmer.machines ~= nil and #farmer.machines > 0 then
        return farmer.machines
    end
    farmer.machines = {}
    local category = TheContractorFarmerFavours.getCategoryForAcres(acres)
    local sized = {}
    for _, model in ipairs(models) do
        if model.categoryName == category then
            table.insert(sized, model)
        end
    end
    if #sized == 0 then
        sized = models
    end
    if #sized == 0 then
        return farmer.machines
    end
    local count = acres >= TheContractorFarmerFavours.SECOND_MACHINE_ACRES and 2 or 1
    for i = 1, count do
        local model = sized[math.floor(random() * #sized) + 1] or sized[#sized]
        table.insert(farmer.machines, {
            id = i,
            xmlFilename = model.xmlFilename,
            seed = TheContractorRepairContracts.rollSeed(random),
            hoursPerMonth = TheContractorFarmerFavours.getHoursPerMonth(acres),
            fitted = {},
        })
    end
    TCLog.info("TheContractor: farmer #%d (%s, %.0f acres) owns %d machine(s)", farmer.id, farmer.name, acres, count)
    return farmer.machines
end

function TheContractorFarmerFavours.getMachine(farmer, machineId)
    for _, machine in ipairs(farmer ~= nil and farmer.machines or {}) do
        if machine.id == machineId then
            return machine
        end
    end
    return nil
end

-- A machine's operating hours on a day: its first age, plus its months of
-- work since. nil before ADS has aged it.
function TheContractorFarmerFavours.getHours(machine, today, daysPerPeriod)
    if machine.hours == nil then
        return nil
    end
    local months = math.max(0, today - (machine.hoursDay or today)) / math.max(daysPerPeriod or 1, 1)
    return machine.hours + months * (machine.hoursPerMonth or 0)
end

-- The parts a favour can be about: the stock parts (getStockParts' { id,
-- nameKey }) not fitted to the machine within REFIT_MONTHS, each with its
-- prepareVehicle target.
function TheContractorFarmerFavours.getTargets(parts, fitted, today, daysPerPeriod)
    local refitDays = TheContractorFarmerFavours.REFIT_MONTHS * math.max(daysPerPeriod or 1, 1)
    local targets = {}
    for _, part in ipairs(parts or {}) do
        local day = fitted ~= nil and fitted[part.id] or nil
        if day == nil or today - day >= refitDays then
            table.insert(targets, { id = part.id, nameKey = part.nameKey, request = { consumable = part.id } })
        end
    end
    return targets
end

-- Where (server) --------------------------------------------------------------------------

-- A spot in the farmer's yard for a machine this size: one of the yard's
-- synced standing spots (114's, the server's) facing the yard's middle,
-- with every corner of the machine on open ground too. x, z, rotY or nil.
function TheContractorFarmerFavours.pickYardSpot(farmlandId, model, random)
    local entry = g_currentMission.TheContractor.Yards:getSpots(farmlandId)
    if entry == nil or #entry.spots == 0 then
        return nil
    end
    local halfWidth, halfLength = model.width * 0.5, model.length * 0.5
    for _ = 1, TheContractorFarmerFavours.YARD_SPOT_TRIES do
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

-- The farmer's fields with no live job on them.
function TheContractorFarmerFavours.getFreeFields(farmer)
    local held = {}
    for _, farmlandId in ipairs(farmer.farmlandIds) do
        held[farmlandId] = true
    end
    local jobs = g_currentMission.TheContractor.Jobs
    local fields = {}
    for _, field in ipairs(g_fieldManager:getFields()) do
        local farmland = field.getFarmland ~= nil and field:getFarmland() or nil
        if farmland ~= nil and held[farmland:getId()] and not jobs:isFieldProtected(field:getId()) then
            table.insert(fields, field)
        end
    end
    return fields
end

-- Where the machine stands: { x, z, rotY, yardFarmlandId or fieldId }, in
-- the yard if there's room, else on the headland of one of their fields
-- (101's spot). nil with neither.
function TheContractorFarmerFavours.pickSpot(farmer, model, random)
    if farmer.yardFarmlandId ~= nil then
        local x, z, rotY = TheContractorFarmerFavours.pickYardSpot(farmer.yardFarmlandId, model, random)
        if x ~= nil then
            return { x = x, z = z, rotY = rotY, yardFarmlandId = farmer.yardFarmlandId }
        end
    end
    local fields = TheContractorFarmerFavours.getFreeFields(farmer)
    while #fields > 0 do
        local index = math.floor(random() * #fields) + 1
        local field = table.remove(fields, math.min(index, #fields))
        local x, z, rotY = TheContractorFieldBreakdowns.pickSpot(field:getId(), model, random)
        if x ~= nil then
            return { x = x, z = z, rotY = rotY, fieldId = field:getId() }
        end
    end
    return nil
end

-- Stages and outcomes (server) -------------------------------------------------------

function TheContractorFarmerFavours:onAsked(incident)
    local tc = g_currentMission.TheContractor
    local farmer = tc.Farmers:getPerson(incident.data.farmerId)
    if farmer == nil or farmer.isOfficial or TheContractorFarmerFavours.getRate(incident.farmId) <= 0 then
        return TheContractorRandomEvents.DONE
    end
    local land = TheContractorFarmers.getLand()
    local models = tc.RepairContracts:getEligibleModels(PlaceableTCRepairZone.ZONE_TYPE.VEHICLE)
    local machines = TheContractorFarmerFavours.ensureMachines(farmer, models,
        TheContractorFarmers.getAcres(farmer, land), math.random)
    local machine = machines[math.random(1, math.max(#machines, 1))]
    local model = machine ~= nil and tc.RepairContracts:findModelByXml(machine.xmlFilename) or nil
    local spot = model ~= nil and TheContractorFarmerFavours.pickSpot(farmer, model, math.random) or nil
    if spot == nil then
        TCLog.info("TheContractor: farm %d incident %d: no machine or nowhere to stand it for farmer #%d",
            incident.farmId, incident.id, farmer.id)
        return TheContractorRandomEvents.DONE
    end
    tc.RepairContracts:queueFavourArrival(incident.farmId, farmer, machine, model, spot)
    return TheContractorRandomEvents.DONE
end

-- RepairContracts:createFavourOffer: the machine's first time out sets its
-- age (ADS's), counted on from today.
function TheContractorFarmerFavours.onOffered(job, quote)
    local farmer = g_currentMission.TheContractor.Farmers:getPerson(job.workshop.farmerId)
    local machine = TheContractorFarmerFavours.getMachine(farmer, job.workshop.machineId)
    if machine ~= nil and machine.hours == nil and quote.operatingHours ~= nil then
        machine.hours = quote.operatingHours
        machine.hoursDay = g_currentMission.environment.currentMonotonicDay
    end
end

-- RepairContracts:onJobCompleted: the farmer's thanks (in place of a job's
-- relationship gain), and the part's on the machine's record.
function TheContractorFarmerFavours.onCompleted(job)
    local tc = g_currentMission.TheContractor
    tc.Relationships:adjust(job.farmId, job.customerId, TheContractorFarmerFavours.RELATIONSHIP_GAIN, "favour")
    local machine = TheContractorFarmerFavours.getMachine(tc.Farmers:getPerson(job.workshop.farmerId),
        job.workshop.machineId)
    if machine ~= nil and job.workshop.targetId ~= nil then
        machine.fitted = machine.fitted or {}
        machine.fitted[job.workshop.targetId] = g_currentMission.environment.currentMonotonicDay
    end
end
