-- Selling a load for a farmer (126), a random event (068): a farmer with a
-- yard (108) has a load to sell and nobody to drive it, as their worker's
-- been hurt, is off sick or has just walked out (the reason, picked at the
-- roll and kept with the job, says which). Their own trailer (121) is
-- waiting full in the yard; the player brings a tractor, takes it to the
-- selling point the offer names and tips it. One load, no refills.
--
-- When: RATE_PER_PERIOD a month, AUTUMN_FACTOR times that in autumn (after
-- harvest), in TRIGGER_HOURS, one at a time per farm and per farmer (a yard
-- bale order, 124, counts too: one job in a yard at a time). The farmer has
-- a yard no player owns, isn't fallen out with the farm (113), is picked by
-- the relationship's offer weight, and has their trailer free (not out,
-- 121) and room for it on one of the yard's spots (123's test), or there's
-- no offer.
--
-- The load (pickLoad): a crop from the farmer's own fields (what's growing
-- there, or last harvested) that the trailer carries and a selling point
-- buys, else one of FALLBACK_FILL_TYPE_NAMES; LOAD_SHARE of the trailer's
-- capacity for it. The selling point is 035's pick for it
-- (TCHaulage.findDeliveryStation); none, no offer.
--
-- The job (JOB_TYPES' yardHaul): the farmer is its customer, its field only
-- the farmer's nearest one (offField), due in DUE_DAYS, allocated to the
-- farm's players as it's accepted (allocateOnAccept). It's 035's haulage
-- (includesHaulage, deliveryOnly): its tracker at the station takes the
-- load instead of selling it, and it's done at DELIVERY_SUCCESS_FACTOR of
-- the load. The farm's own grain of that type sold there counts too, as
-- with 035.
--
-- The trailer: accepting the job brings it out through 100's queue (a loan
-- arrival, no ADS) to its yard spot, in its grain configuration (one that
-- takes BENCHMARK_FILL_TYPE_NAME, getTrailerSpec: never a flatbed), where
-- the server fills it (fillTrailer). It's a contract vehicle (not sold, not on our lists),
-- never locked for driving, and the farmer collects it once the job's over
-- and nobody's towing it or can see it (queueLoanCollection's whenUnseen).
--
-- Grain that goes astray: only the station's deliveries are counted. At a
-- miss (judgeMiss, from Jobs:missJob) the load is set against what was
-- delivered and what's still in the trailer; more than THEFT_ALLOWANCE of
-- it gone means it was taken: a claim for it at the station's price
-- (uninsured: it was deliberate), and THEFT_REPUTATION and
-- THEFT_RELATIONSHIP lost on top of the ordinary miss. A miss with the
-- grain still in the trailer is an ordinary one.
--
-- Pay: a haulage fee only (the crop's value is the farmer's), 067's
-- transport shape: LOAD_FEE plus RATE_PER_METER from the yard to the
-- station, at the job pay rate setting (base, scaled live as job prices
-- are). A fixed reputation reward (JOB_TYPES' reputationReward), through
-- quality as any player-driven job.
--
-- State: job.yardHaul, with the job (saved and sent).

TheContractorYardHaul = {}
TheContractorYardHaul_mt = Class(TheContractorYardHaul)

-- 180: the trailer's map circle (metres across), tight enough to be on it.
TheContractorYardHaul.TRAILER_MARKER_RADIUS = 12
-- 180: how often (real ms) a trailer whose yard spot is taken looks for
-- another one.
TheContractorYardHaul.SPOT_RETRY_MS = 5000

TheContractorYardHaul.EVENT_TYPE = "yardHaul"
TheContractorYardHaul.JOB_TYPE = "yardHaul"
TheContractorYardHaul.MESSAGE_KIND = "yardHaul"
TheContractorYardHaul.CLAIM_KIND = "yardHaulClaim"

-- Why nobody's driving it: each has its own offer text
-- (tc_yardHaul_offerBody_<reason>).
TheContractorYardHaul.REASONS = { "injured", "sick", "left" }
-- 112: every offer is signed by the farmer (getCustomerNamedArgs).
TheContractorYardHaul.NAMED_BODY_KEYS = {}
for _, reason in ipairs(TheContractorYardHaul.REASONS) do
    TheContractorYardHaul.NAMED_BODY_KEYS["tc_yardHaul_offerBody_" .. reason] = true
end

-- Sold when nothing from the farmer's fields will do.
TheContractorYardHaul.FALLBACK_FILL_TYPE_NAMES = { "WHEAT", "BARLEY" }

-- About one every two and a half months, twice that in autumn.
TheContractorYardHaul.RATE_PER_PERIOD = 0.4
TheContractorYardHaul.AUTUMN_FACTOR = 2
TheContractorYardHaul.COOLDOWN_PERIODS = 0
TheContractorYardHaul.TRIGGER_HOURS = { 7, 14 }

-- The load: this share (a range) of the trailer's capacity for the crop,
-- in whole LITER_STEPs. A trailer holding less than MIN_LITERS of it won't
-- do.
TheContractorYardHaul.LOAD_SHARE = { 0.9, 1.0 }
TheContractorYardHaul.LITER_STEP = 100
TheContractorYardHaul.MIN_LITERS = 2000
-- A trailer will do only in a configuration that takes this (a grain
-- body, not a flatbed): getTrailerSpec.
TheContractorYardHaul.BENCHMARK_FILL_TYPE_NAME = "WHEAT"

-- Due this many days from today (a range).
TheContractorYardHaul.DUE_DAYS = { 2, 3 }

-- Pay (base): per load, plus per metre from the yard to the station.
TheContractorYardHaul.LOAD_FEE = 750
TheContractorYardHaul.RATE_PER_METER = 0.35

-- Taken: more than this share of the load neither delivered nor in the
-- trailer at the miss. Then this much more reputation and relationship
-- lost than an ordinary miss.
TheContractorYardHaul.THEFT_ALLOWANCE = 0.07
TheContractorYardHaul.THEFT_REPUTATION = 40
TheContractorYardHaul.THEFT_RELATIONSHIP = 60

-- How often the server looks for finished jobs' trailers to send home.
TheContractorYardHaul.COLLECT_CHECK_MS = 500

function TheContractorYardHaul.new()
    local self = {}
    setmetatable(self, TheContractorYardHaul_mt)

    -- Server: tcEvent trigger yardHaul [crop] [reason] [farmer], for one
    -- trigger.
    self.forcedFillTypeName = nil
    self.forcedReason = nil
    self.forcedFarmerId = nil

    self.collectMs = 0

    return self
end

-- Every machine, at load, before the save loads (068).
function TheContractorYardHaul:register(randomEvents, inbox)
    randomEvents:registerEventType(TheContractorYardHaul.EVENT_TYPE, {
        l10nKey = "tc_yardHaul_eventName",
        cooldownPeriods = TheContractorYardHaul.COOLDOWN_PERIODS,
        triggerHours = TheContractorYardHaul.TRIGGER_HOURS,
        ratePerPeriod = function(farmId)
            return TheContractorYardHaul.getRate(farmId)
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
            details = "[crop] [injured|sick|left] [farmer]",
            prepareTrigger = function(farmId, details)
                return self:prepareTrigger(details)
            end,
            clearTrigger = function()
                self.forcedFillTypeName = nil
                self.forcedReason = nil
                self.forcedFarmerId = nil
            end,
        },
    })

    inbox:registerMessageKind(TheContractorYardHaul.MESSAGE_KIND, {
        endsWithJob = true,
        category = "job",
        chipTone = "info",
        getArgs = function(message)
            return TheContractorInbox.getCustomerNamedArgs(message, TheContractorYardHaul.NAMED_BODY_KEYS)
        end,
    })
    -- The claim outlives the job, so the farmer's named from the payload.
    inbox:registerMessageKind(TheContractorYardHaul.CLAIM_KIND, {
        category = "claim",
        chipTone = "bad",
        getArgs = function(message)
            return TheContractorYardHaul.getClaimArgs(message)
        end,
    })
end

-- Reading (every machine) -------------------------------------------------------------

local function isTakenOn(job)
    return job.state == TheContractorJob.STATE.ACCEPTED or job.state == TheContractorJob.STATE.ALLOCATED or
        job.state == TheContractorJob.STATE.IN_PROGRESS
end

local function isActive(job)
    return job.state == TheContractorJob.STATE.ALLOCATED or job.state == TheContractorJob.STATE.IN_PROGRESS
end

function TheContractorYardHaul.getFillTypeIndex(haul)
    return g_fillTypeManager:getFillTypeIndexByName(haul.fillTypeName)
end

-- The farms with an open load to sell, and the farmers with any open job
-- in their yard (this, or 124's bales).
function TheContractorYardHaul.getOpenJobs()
    local farms, farmers = {}, {}
    local jobs = g_currentMission.TheContractor.Jobs
    for farmId, farmJobs in pairs(jobs.jobsByFarm) do
        for _, job in pairs(farmJobs) do
            if not job:isTerminal() then
                if job.yardHaul ~= nil then
                    farms[farmId] = true
                    farmers[job.yardHaul.farmerId or 0] = true
                elseif job.yardDelivery ~= nil then
                    farmers[job.yardDelivery.farmerId or 0] = true
                end
            end
        end
    end
    return farms, farmers
end

-- TCJobProgress (server): the share delivered of what has to be.
function TheContractorYardHaul.getCompletion(job)
    if job.yardHaul == nil or job.requiredLiters <= 0 then
        return 0
    end
    return math.min(1, job.deliveredLiters / job.requiredLiters)
end

-- The menu's delivery row (every machine): "24,000 l of Wheat to the Grain
-- Mill", and how much is in while it's under way.
function TheContractorYardHaul.getDeliveryText(job)
    local haul = job.yardHaul
    local fillTypeIndex = TheContractorYardHaul.getFillTypeIndex(haul)
    local text = string.format(g_i18n:getText("tc_yardHaul_deliveryValue"), g_i18n:formatVolume(haul.liters or 0, 0),
        fillTypeIndex ~= nil and g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex) or haul.fillTypeName,
        job.deliveryStationName or "?")
    if isActive(job) and job.requiredLiters > 0 then
        text = text .. string.format(g_i18n:getText("tc_yardBales_deliveredSuffix"),
            math.min(100, math.floor(100 * job.deliveredLiters / job.requiredLiters)))
    end
    return text
end

-- TCJobHotspots (every machine): on the trailer while it's taken on,
-- following it, or its spot in the yard until it's out.
function TheContractorYardHaul.getSpot(job)
    local haul = job.yardHaul
    if haul == nil or not isTakenOn(job) then
        return nil
    end
    local radius = TheContractorYardHaul.TRAILER_MARKER_RADIUS
    local trailer = TheContractorYardHaul.getTrailer(haul)
    if trailer ~= nil and trailer.rootNode ~= nil then
        local x, _, z = getWorldTranslation(trailer.rootNode)
        return { x = x, z = z, radius = radius }
    end
    return { x = haul.x, z = haul.z, radius = radius }
end

-- The trailer, if it's out (every machine that has it).
function TheContractorYardHaul.getTrailer(haul)
    local vehicleId = haul ~= nil and haul.trailerVehicleId or nil
    local vehicle = vehicleId ~= nil and vehicleId ~= 0 and NetworkUtil.getObject(vehicleId) or nil
    if vehicle == nil or vehicle.isDeleted then
        return nil
    end
    return vehicle
end

-- The trailer's vehicle id (for the contract vehicles): { id } or {}.
function TheContractorYardHaul.getTrailerIds(haul)
    if haul ~= nil and (haul.trailerVehicleId or 0) ~= 0 then
        return { haul.trailerVehicleId }
    end
    return {}
end

-- The logbook's record of it (060, in 124's shape): { fillTypeName,
-- requiredLiters (the load), deliveredLiters, stationName }, or nil.
function TheContractorYardHaul.getLogbookDelivery(job)
    local haul = job.yardHaul
    if haul == nil then
        return nil
    end
    return {
        fillTypeName = haul.fillTypeName,
        requiredLiters = haul.liters or 0,
        deliveredLiters = job.deliveredLiters,
        excessLiters = 0,
        excessPay = 0,
        stationName = job.deliveryStationName,
    }
end

-- The trailer (server) ----------------------------------------------------------------------

-- A trailer model's grain configuration and what it carries in it: {
-- capacity (litres, its biggest fill unit), fillTypes (fillTypeIndex ->
-- true), configurations (what it's spawned with: queueTrailer) }, or nil
-- and why not. The grain configuration is a fill unit configuration that
-- takes BENCHMARK_FILL_TYPE_NAME: the default one if it does, else the
-- first that does and that a configuration set allows. A trailer that's a
-- flatbed by default with a grain body to choose comes out with the grain
-- body; one with no grain body won't do. Read from its vehicle XML as
-- vanilla's FillUnit.getFillTypeNamesFromXML does, configuration by
-- configuration. Not the shop's specs: those are in the unit the shop
-- shows (a trailer's m3). Kept per model for the session (specCache).
local specCache = {}

function TheContractorYardHaul.getTrailerSpec(xmlFilename)
    local storeItem = xmlFilename ~= nil and g_storeManager:getItemByXMLFilename(xmlFilename) or nil
    if storeItem == nil then
        return nil, "not in the store"
    end
    if specCache[xmlFilename] == nil then
        local configs = TheContractorYardHaul.readFillUnitConfigurations(xmlFilename)
        local spec, problem = nil, "its XML won't load"
        if configs ~= nil then
            spec, problem = TheContractorYardHaul.chooseGrainConfiguration(configs, storeItem)
        end
        specCache[xmlFilename] = spec or { problem = problem }
    end
    local cached = specCache[xmlFilename]
    if cached.problem ~= nil then
        return nil, cached.problem
    end
    return cached
end

-- A vehicle XML's fill unit configurations, in order: a list of {
-- capacity, fillTypes (fillTypeIndex -> true) }, or nil if it won't load.
-- Engine side, replaced in the tests.
function TheContractorYardHaul.readFillUnitConfigurations(xmlFilename)
    local xmlFile = XMLFile ~= nil and Vehicle ~= nil and
        XMLFile.load("tcYardHaulTrailer", xmlFilename, Vehicle.xmlSchema) or nil
    if xmlFile == nil then
        return nil
    end
    local configs = {}
    local rootName = xmlFile:getRootName()
    xmlFile:iterate(rootName .. ".fillUnit.fillUnitConfigurations.fillUnitConfiguration", function(_, key)
        local capacity, names, categoryNames = 0, {}, {}
        xmlFile:iterate(key .. ".fillUnits.fillUnit", function(_, fillUnitKey)
            local unitCapacity = xmlFile:getValue(fillUnitKey .. "#capacity")
            if unitCapacity == nil or unitCapacity > 0 then
                capacity = math.max(capacity, unitCapacity or 0)
                local unitNames = xmlFile:getValue(fillUnitKey .. "#fillTypes")
                local unitCategoryNames = xmlFile:getValue(fillUnitKey .. "#fillTypeCategories")
                if unitNames ~= nil then
                    table.insert(names, unitNames)
                end
                if unitCategoryNames ~= nil then
                    table.insert(categoryNames, unitCategoryNames)
                end
            end
        end)
        local indices = g_fillTypeManager:getFillTypesByCategoryNames(
            #categoryNames > 0 and table.concat(categoryNames, " ") or nil, nil, {})
        indices = g_fillTypeManager:getFillTypesByNames(#names > 0 and table.concat(names, " ") or nil, nil, indices)
        local fillTypes = {}
        for _, fillTypeIndex in ipairs(indices or {}) do
            fillTypes[fillTypeIndex] = true
        end
        table.insert(configs, { capacity = capacity, fillTypes = fillTypes })
    end)
    xmlFile:delete()
    return configs
end

-- The grain configuration of configs (readFillUnitConfigurations) for
-- storeItem: the spec (getTrailerSpec), or nil and why not.
function TheContractorYardHaul.chooseGrainConfiguration(configs, storeItem)
    local benchmark = g_fillTypeManager:getFillTypeIndexByName(TheContractorYardHaul.BENCHMARK_FILL_TYPE_NAME)
    local items = storeItem.configurations ~= nil and storeItem.configurations.fillUnit or nil
    local default = 1
    if items ~= nil and ConfigurationUtil ~= nil and ConfigurationUtil.getDefaultConfigIdFromItems ~= nil then
        default = ConfigurationUtil.getDefaultConfigIdFromItems(items)
    end
    local order = { default }
    for index = 1, #configs do
        if index ~= default then
            table.insert(order, index)
        end
    end
    local anyGrain = false
    for _, index in ipairs(order) do
        local config = configs[index]
        local selectable = items == nil or items[index] == nil or items[index].isSelectable ~= false
        if config ~= nil and selectable and benchmark ~= nil and config.fillTypes[benchmark] then
            anyGrain = true
            local configurations = TCStoreConfigurations.getSetWith(storeItem, "fillUnit", index)
            if configurations ~= nil then
                return { capacity = config.capacity, fillTypes = config.fillTypes, configurations = configurations }
            end
        end
    end
    if anyGrain then
        return nil, "no configuration set allows its grain body"
    end
    return nil, string.format("no configuration takes %s", TheContractorYardHaul.BENCHMARK_FILL_TYPE_NAME)
end

-- At unload: models can change with the mods loaded.
function TheContractorYardHaul.clearSpecCache()
    specCache = {}
end

-- A farmer's trailer that's free: { machine, model (its size), spec }, or
-- nil, and why not (for the log).
function TheContractorYardHaul.getFreeTrailer(farmer)
    local F = TheContractorFarmerFleet
    local problems = {}
    for _, machine in ipairs(F.getMachinesByRole(farmer, F.ROLE.TRAILER)) do
        local model = F.getSizeModel(machine.xmlFilename)
        local spec, problem = nil, "not in the store"
        if model ~= nil then
            spec, problem = TheContractorYardHaul.getTrailerSpec(machine.xmlFilename)
        end
        if spec == nil then
            problem = problem or "not in the store"
        elseif spec.capacity < TheContractorYardHaul.MIN_LITERS then
            problem = string.format("capacity %.0f l", spec.capacity)
        elseif F.isAnyOut(farmer, machine) then
            problem = "out already"
        else
            return { machine = machine, model = model, spec = spec }
        end
        table.insert(problems, string.format("#%d %s: %s", machine.id, tostring(machine.xmlFilename), problem))
    end
    return nil, #problems > 0 and table.concat(problems, "; ") or "no trailer in their fleet"
end

-- For the log: a spec's fill types by name.
function TheContractorYardHaul.describeFillTypes(spec)
    local names = {}
    for fillTypeIndex in pairs(spec.fillTypes or {}) do
        table.insert(names, tostring(g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)))
    end
    table.sort(names)
    return #names > 0 and table.concat(names, " ") or "none"
end

-- Server, once it's out (onLoanArrived): liters of the fill type into the
-- trailer's biggest fill unit that takes it, as the job's farm's. Returns
-- what went in. Engine side.
function TheContractorYardHaul.fillTrailer(vehicle, fillTypeIndex, liters)
    local fillUnits = vehicle.spec_fillUnit ~= nil and vehicle.spec_fillUnit.fillUnits or {}
    local best, bestCapacity = nil, 0
    for index in ipairs(fillUnits) do
        if vehicle:getFillUnitSupportsFillType(index, fillTypeIndex) then
            local capacity = vehicle:getFillUnitCapacity(index) or 0
            if capacity > bestCapacity then
                best, bestCapacity = index, capacity
            end
        end
    end
    if best == nil or liters <= 0 then
        return 0
    end
    return vehicle:addFillUnitFillLevel(vehicle:getOwnerFarmId(), best, liters, fillTypeIndex, ToolType.UNDEFINED,
        nil) or 0
end

-- What's in the trailer of the job's fill type now (server), or nil if the
-- trailer's gone.
function TheContractorYardHaul.getTrailerLoad(haul)
    local vehicle = TheContractorYardHaul.getTrailer(haul)
    if vehicle == nil then
        return nil
    end
    local fillTypeIndex = TheContractorYardHaul.getFillTypeIndex(haul)
    local liters = 0
    local fillUnits = vehicle.spec_fillUnit ~= nil and vehicle.spec_fillUnit.fillUnits or {}
    for index in ipairs(fillUnits) do
        if vehicle:getFillUnitFillType(index) == fillTypeIndex then
            liters = liters + (vehicle:getFillUnitFillLevel(index) or 0)
        end
    end
    return liters
end

-- What the farmer has to sell (server) ---------------------------------------------------

-- The fill types of the crops on the farmer's fields (growing there, or
-- last harvested), grass left out, sorted.
function TheContractorYardHaul.getFieldFillTypes(farmer)
    local held = {}
    for _, farmlandId in ipairs(farmer.farmlandIds or {}) do
        held[farmlandId] = true
    end
    local found, result = {}, {}
    for _, field in ipairs(g_fieldManager:getFields()) do
        local farmland = field.getFarmland ~= nil and field:getFarmland() or nil
        local fieldState = farmland ~= nil and held[farmland:getId()] and field.getFieldState ~= nil and
            field:getFieldState() or nil
        local fruitTypeIndex = fieldState ~= nil and fieldState.fruitTypeIndex or nil
        if fruitTypeIndex ~= nil and fruitTypeIndex ~= FruitType.UNKNOWN and
                not TheContractorJobGeneration.isGrass(fruitTypeIndex) then
            local fillTypeIndex = g_fruitTypeManager:getFillTypeIndexByFruitTypeIndex(fruitTypeIndex)
            if fillTypeIndex ~= nil and not found[fillTypeIndex] then
                found[fillTypeIndex] = true
                table.insert(result, fillTypeIndex)
            end
        end
    end
    table.sort(result)
    return result
end

-- What's sold: { fillTypeIndex, station }, or nil. One of the fill types
-- the trailer carries and a selling point buys: the farmer's own crops
-- (fieldFillTypes) first, else the fallbacks. forcedFillTypeIndex (the
-- console) narrows it to that one. farmId: the farm that would deliver it
-- (162), nil for any.
function TheContractorYardHaul.pickLoad(fieldFillTypes, spec, forcedFillTypeIndex, random, farmId)
    local function candidatesFrom(fillTypeIndices)
        local candidates = {}
        for _, fillTypeIndex in ipairs(fillTypeIndices) do
            if spec.fillTypes[fillTypeIndex] and
                    (forcedFillTypeIndex == nil or forcedFillTypeIndex == fillTypeIndex) then
                local station = TCHaulage.findDeliveryStation(fillTypeIndex, farmId)
                if station ~= nil then
                    table.insert(candidates, { fillTypeIndex = fillTypeIndex, station = station })
                end
            end
        end
        return candidates
    end
    local candidates = candidatesFrom(fieldFillTypes)
    if #candidates == 0 then
        local fallbacks = {}
        for _, name in ipairs(TheContractorYardHaul.FALLBACK_FILL_TYPE_NAMES) do
            local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(name)
            if fillTypeIndex ~= nil then
                table.insert(fallbacks, fillTypeIndex)
            end
        end
        if forcedFillTypeIndex ~= nil then
            table.insert(fallbacks, forcedFillTypeIndex)
        end
        candidates = candidatesFrom(fallbacks)
    end
    if #candidates == 0 then
        return nil
    end
    return candidates[math.min(#candidates, math.floor(random() * #candidates) + 1)]
end

-- The load's litres: LOAD_SHARE of the capacity, in whole LITER_STEPs.
function TheContractorYardHaul.getLoadLiters(capacity, random)
    local Y = TheContractorYardHaul
    local share = Y.LOAD_SHARE[1] + random() * (Y.LOAD_SHARE[2] - Y.LOAD_SHARE[1])
    return math.floor(capacity * share / Y.LITER_STEP) * Y.LITER_STEP
end

-- The roll (server) ----------------------------------------------------------------------

function TheContractorYardHaul.isAutumn()
    local environment = g_currentMission.environment
    return Season ~= nil and Season.AUTUMN ~= nil and environment.getSeasonAtDay ~= nil and
        environment:getSeasonAtDay(environment.currentMonotonicDay) == Season.AUTUMN
end

-- Expected asks a month (before the setting).
function TheContractorYardHaul.getRate(farmId)
    local rate = TheContractorYardHaul.RATE_PER_PERIOD
    if TheContractorYardHaul.isAutumn() then
        rate = rate * TheContractorYardHaul.AUTUMN_FACTOR
    end
    return rate
end

-- The farmers who could ask: a yard no player owns, no open job in it, the
-- trailer free, not fallen out with the farm. { { farmer, weight } }.
function TheContractorYardHaul:getCandidateFarmers(farmId)
    local tc = g_currentMission.TheContractor
    local _, openFarmers = TheContractorYardHaul.getOpenJobs()
    local candidates = {}
    for _, farmer in ipairs(tc.Farmers:getFarmers()) do
        local weight = tc.Relationships:getOfferWeight(farmId, farmer.id)
        local problem = nil
        local isConsidered = (self.forcedFarmerId == nil or self.forcedFarmerId == farmer.id) and
            not farmer.isOfficial
        -- Anyone else (the official, or not the console's farmer) isn't
        -- asked, so isn't logged.
        if not isConsidered then
            problem = nil
        elseif weight <= 0 then
            problem = "fallen out with the farm"
        elseif openFarmers[farmer.id] then
            problem = "a job on in their yard already"
        elseif #(farmer.farmlandIds or {}) == 0 then
            problem = "no land"
        elseif farmer.yardFarmlandId == nil then
            problem = "no yard"
        elseif TheContractorFieldBreakdowns.getUsableYard(farmer) == nil then
            problem = string.format("yard %d is a player's", farmer.yardFarmlandId)
        else
            local trailer, trailerProblem = TheContractorYardHaul.getFreeTrailer(farmer)
            if trailer ~= nil then
                table.insert(candidates, { farmer = farmer, weight = weight })
            else
                problem = trailerProblem
            end
        end
        if problem ~= nil then
            TCLog.info("TheContractor: yardHaul: farmer #%d (%s) can't ask: %s", farmer.id, tostring(farmer.name),
                problem)
        end
    end
    return candidates
end

-- Where the trailer stands in the farmer's yard: x, z, rotY (facing the
-- yard's middle), or nil with no room.
function TheContractorYardHaul.pickSpot(farmer, model, random)
    local yardFarmlandId = TheContractorFieldBreakdowns.getUsableYard(farmer)
    if yardFarmlandId == nil then
        return nil
    end
    return TheContractorFieldBreakdowns.pickYardSpot(yardFarmlandId, model, random)
end

-- canTrigger (068): { farmerId, fillTypeName, liters, reason }, or nil.
function TheContractorYardHaul:pickRequest(farmId)
    local Y = TheContractorYardHaul
    local openFarms = Y.getOpenJobs()
    if openFarms[farmId] then
        TCLog.info("TheContractor: yardHaul: farm %d has a load to sell on already", farmId)
        return nil
    end
    local candidates = self:getCandidateFarmers(farmId)
    local farmer = TheContractorYardBales.pickWeighted(candidates, math.random)
    local trailer = farmer ~= nil and Y.getFreeTrailer(farmer) or nil
    if trailer == nil then
        TCLog.info("TheContractor: yardHaul: none of the %d farmers can ask",
            #g_currentMission.TheContractor.Farmers:getFarmers())
        return nil
    end
    if Y.pickSpot(farmer, trailer.model, math.random) == nil then
        TCLog.info("TheContractor: yardHaul: farmer #%d's yard %s has no room for the %s (%.1f x %.1f m)",
            farmer.id, tostring(farmer.yardFarmlandId), tostring(trailer.machine.xmlFilename), trailer.model.width,
            trailer.model.length)
        return nil
    end
    local forced = self.forcedFillTypeName ~= nil and g_fillTypeManager:getFillTypeIndexByName(self.forcedFillTypeName)
        or nil
    local fieldFillTypes = Y.getFieldFillTypes(farmer)
    local load = Y.pickLoad(fieldFillTypes, trailer.spec, forced, math.random, farmId)
    if load == nil then
        local fieldNames = {}
        for _, fillTypeIndex in ipairs(fieldFillTypes) do
            table.insert(fieldNames, tostring(g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)))
        end
        TCLog.info("TheContractor: yardHaul: farmer #%d's %s (%.0f l) carries %s; their fields have %s%s; nothing it carries of those or %s is bought anywhere",
            farmer.id, tostring(trailer.machine.xmlFilename), trailer.spec.capacity, Y.describeFillTypes(trailer.spec),
            #fieldNames > 0 and table.concat(fieldNames, " ") or "nothing",
            forced ~= nil and (" (asked for " .. tostring(self.forcedFillTypeName) .. ")") or "",
            table.concat(Y.FALLBACK_FILL_TYPE_NAMES, " or "))
        return nil
    end
    return {
        farmerId = farmer.id,
        fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(load.fillTypeIndex),
        liters = Y.getLoadLiters(trailer.spec.capacity, math.random),
        reason = self.forcedReason or Y.REASONS[math.random(1, #Y.REASONS)],
    }
end

-- The console's details: [crop] [injured|sick|left] [farmer id or full
-- name], in any order.
function TheContractorYardHaul:prepareTrigger(details)
    local rest = {}
    for _, detail in ipairs(details) do
        local lower = string.lower(detail)
        local isReason = false
        for _, reason in ipairs(TheContractorYardHaul.REASONS) do
            if lower == reason then
                self.forcedReason = reason
                isReason = true
            end
        end
        if not isReason then
            if self.forcedFillTypeName == nil and g_fillTypeManager:getFillTypeIndexByName(string.upper(detail)) ~= nil then
                self.forcedFillTypeName = string.upper(detail)
            else
                table.insert(rest, detail)
            end
        end
    end
    if #rest == 0 then
        return nil
    end
    local wanted = table.concat(rest, " ")
    for _, farmer in ipairs(g_currentMission.TheContractor.Farmers:getFarmers()) do
        if tostring(farmer.id) == wanted or string.lower(farmer.name) == string.lower(wanted) then
            self.forcedFarmerId = farmer.id
            return nil
        end
    end
    self.forcedFillTypeName, self.forcedReason = nil, nil
    return "Usage: tcEvent trigger yardHaul [crop] [injured|sick|left] [farmer id or name] (tcFarmer list)"
end

-- Pricing (server) ----------------------------------------------------------------------

-- The fee (base): LOAD_FEE plus RATE_PER_METER over distance, at the job
-- pay rate.
function TheContractorYardHaul.getBasePrice(distance, payMultiplier)
    local Y = TheContractorYardHaul
    return math.floor((Y.LOAD_FEE + (distance or 0) * Y.RATE_PER_METER) * (payMultiplier or 1) + 0.5)
end

-- From the yard spot to the station, as the crow flies (067's measure).
function TheContractorYardHaul.getDistance(x, z, station)
    if station == nil or station.rootNode == nil then
        return 0
    end
    local stationX, _, stationZ = getWorldTranslation(station.rootNode)
    return math.sqrt((stationX - x) ^ 2 + (stationZ - z) ^ 2)
end

-- The selling point's price per litre today (a vanilla price, already
-- EconomyScale's), or 0.
function TheContractorYardHaul.getStationPrice(station, fillTypeIndex)
    if station == nil or station.getEffectiveFillTypePrice == nil or fillTypeIndex == nil then
        return 0
    end
    return station:getEffectiveFillTypePrice(fillTypeIndex) or 0
end

-- The offer (server) ---------------------------------------------------------------------

function TheContractorYardHaul:onAsked(incident)
    local tc = g_currentMission.TheContractor
    local Y = TheContractorYardHaul
    local data = incident.data
    local farmer = tc.Farmers:getPerson(data.farmerId)
    local trailer = farmer ~= nil and not farmer.isOfficial and Y.getFreeTrailer(farmer) or nil
    local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(data.fillTypeName)
    local station = fillTypeIndex ~= nil and TCHaulage.findDeliveryStation(fillTypeIndex, incident.farmId) or nil
    if trailer == nil or station == nil or not trailer.spec.fillTypes[fillTypeIndex] then
        TCLog.info("TheContractor: farm %d incident %d: farmer #%s has no trailer free, or nowhere buys %s",
            incident.farmId, incident.id, tostring(data.farmerId), tostring(data.fillTypeName))
        return TheContractorRandomEvents.DONE
    end
    local x, z, rotY = Y.pickSpot(farmer, trailer.model, math.random)
    local field = x ~= nil and TheContractorYardBales.getNearestField(farmer, x, z) or nil
    if field == nil then
        TCLog.info("TheContractor: farm %d incident %d: no room for a trailer in farmer #%d's yard", incident.farmId,
            incident.id, farmer.id)
        return TheContractorRandomEvents.DONE
    end

    local haul = {
        farmerId = farmer.id,
        yardFarmlandId = TheContractorFieldBreakdowns.getUsableYard(farmer),
        fillTypeName = data.fillTypeName,
        liters = data.liters,
        reason = data.reason,
        machineId = trailer.machine.id,
        x = x,
        z = z,
        rotY = rotY,
        pricePerLiter = Y.getStationPrice(station, fillTypeIndex),
    }

    local environment = g_currentMission.environment
    local deadlineDay = environment.currentMonotonicDay + math.random(Y.DUE_DAYS[1], Y.DUE_DAYS[2])
    local price = Y.getBasePrice(Y.getDistance(x, z, station), tc.Settings:getJobPayMultiplier())
    local job = tc.Jobs:createJob(incident.farmId, Y.JOB_TYPE, field:getId(), 1,
        TCCalendar.getPeriodFromDay(deadlineDay), TCCalendar.getDayInPeriodFromDay(deadlineDay), price, true, nil,
        deadlineDay, true, station, nil, nil, nil, nil, haul)
    if job == nil then
        return TheContractorRandomEvents.DONE
    end

    tc.Inbox:postMessage(incident.farmId, Y.MESSAGE_KIND, "tc_yardHaul_offerTitle",
        "tc_yardHaul_offerBody_" .. tostring(data.reason),
        { "$volume_" .. data.liters, g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex) or data.fillTypeName,
            job.deliveryStationName or "?" }, nil,
        { incidentId = incident.id, jobId = job.id })
    TCLog.info("TheContractor: farm %d job %d: farmer #%d (%s) asks for %.0f l of %s sold at %s, trailer at %.0f, %.0f in yard %d, for %.0f",
        incident.farmId, job.id, farmer.id, tostring(data.reason), data.liters, data.fillTypeName,
        tostring(job.deliveryStationName), x, z, haul.yardFarmlandId or 0, job:getPrice())
    return TheContractorRandomEvents.DONE
end

-- The farmer's trailer (server) -------------------------------------------------------------

-- Jobs:onJobAccepted: the trailer comes out.
function TheContractorYardHaul:onJobAccepted(job)
    self:queueTrailer(job)
end

function TheContractorYardHaul:queueTrailer(job)
    local tc = g_currentMission.TheContractor
    local haul = job.yardHaul
    local farmer = tc.Farmers:getPerson(haul.farmerId)
    local machine = TheContractorFarmerFleet.getMachine(farmer, haul.machineId)
    local model = machine ~= nil and TheContractorFarmerFleet.getSizeModel(machine.xmlFilename) or nil
    if model == nil then
        TCLog.info("TheContractor: farm %d job %d: farmer #%s's trailer is gone", job.farmId, job.id,
            tostring(haul.farmerId))
        return
    end
    local entry = tc.RepairContracts:queueLoanArrival(job.farmId, job.id, farmer, machine, model,
        { x = haul.x, z = haul.z, rotY = haul.rotY, yardFarmlandId = haul.yardFarmlandId }, nil, "YardHaul")
    -- In its grain configuration, not its default (a flatbed, maybe).
    local spec = TheContractorYardHaul.getTrailerSpec(machine.xmlFilename)
    if entry ~= nil and spec ~= nil then
        entry.configurations = spec.configurations
    end
end

-- RepairContracts: whether a loan arrival is still wanted (its job taken on,
-- its trailer not out yet).
function TheContractorYardHaul:isLoanWanted(entry)
    local job = g_currentMission.TheContractor.Jobs:getJob(entry.farmId, entry.jobId)
    return job ~= nil and job.yardHaul ~= nil and isTakenOn(job) and (job.yardHaul.trailerVehicleId or 0) == 0
end

-- 180, RepairContracts: the trailer's yard spot isn't clear (a player's
-- tractor parked on it, waiting for the trailer, kept it from ever coming
-- out). Every SPOT_RETRY_MS, another spot in the yard. The job's spot moves
-- with it on the server (a load sends for it there); clients' markers
-- follow the trailer once it's out.
function TheContractorYardHaul:retryLoanSpot(entry, model)
    local now = g_time or 0
    if entry.spotRetryAt ~= nil and now < entry.spotRetryAt then
        return false
    end
    entry.spotRetryAt = now + TheContractorYardHaul.SPOT_RETRY_MS
    local tc = g_currentMission.TheContractor
    local job = tc.Jobs:getJob(entry.farmId, entry.jobId)
    local farmer = tc.Farmers:getPerson(entry.farmerId)
    if job == nil or job.yardHaul == nil or farmer == nil then
        return false
    end
    local x, z, rotY = TheContractorYardHaul.pickSpot(farmer, model, math.random)
    if x == nil then
        return false
    end
    entry.x, entry.z, entry.rotY = x, z, rotY
    job.yardHaul.x, job.yardHaul.z, job.yardHaul.rotY = x, z, rotY
    TCLog.info("TheContractor: farm %d job %d: the trailer's spot was taken, trying %.0f, %.0f", entry.farmId,
        entry.jobId, x, z)
    return true
end

-- RepairContracts: the trailer's in place. It's filled with what's still
-- to come (the whole load the first time), and if it holds less than that
-- the load is what it holds.
function TheContractorYardHaul:onLoanArrived(entry, vehicle, attachment)
    TheContractorRepairContracts.deleteVehicle(attachment)
    if not self:isLoanWanted(entry) then
        TheContractorRepairContracts.deleteVehicle(vehicle)
        return
    end
    local tc = g_currentMission.TheContractor
    local job = tc.Jobs:getJob(entry.farmId, entry.jobId)
    local haul = job.yardHaul
    local wanted = math.max(0, (haul.liters or 0) - (haul.filled and job.deliveredLiters or 0))
    local filled = TheContractorYardHaul.fillTrailer(vehicle, TheContractorYardHaul.getFillTypeIndex(haul), wanted)
    if filled <= 0 and wanted > 0 then
        TCLog.warning("TheContractor: farm %d job %d: the %s took none of its %s", job.farmId, job.id,
            vehicle:getFullName(), tostring(haul.fillTypeName))
    end
    if not haul.filled and filled < wanted then
        haul.liters = filled
        if job.requiredLiters > 0 then
            local required = TCHaulage.getRequiredLiters(job)
            tc.Jobs:applyJobDelivery(job.farmId, job.id, job.deliveredLiters, required)
            if g_server ~= nil then
                g_server:broadcastEvent(TCJobDeliveryEvent.new(job.farmId, job.id, job.deliveredLiters, required))
            end
        end
    end
    haul.filled = true
    haul.trailerUniqueId = vehicle.getUniqueId ~= nil and vehicle:getUniqueId() or nil
    self:applyTrailer(job.farmId, job.id, NetworkUtil.getObjectId(vehicle), haul.liters)
    if g_server ~= nil then
        g_server:broadcastEvent(TCYardHaulTrailerEvent.new(job.farmId, job.id, haul.trailerVehicleId, haul.liters))
    end
    TCLog.info("TheContractor: farm %d job %d: farmer #%d's %s is out in the yard with %.0f l of %s", job.farmId,
        job.id, haul.farmerId, vehicle:getFullName(), filled, tostring(haul.fillTypeName))
end

-- Every machine (the server, and TCYardHaulTrailerEvent): the job's
-- trailer, and the load it came with.
function TheContractorYardHaul:applyTrailer(farmId, jobId, vehicleId, liters)
    local job = g_currentMission.TheContractor.Jobs:getJob(farmId, jobId)
    if job == nil or job.yardHaul == nil then
        return
    end
    job.yardHaul.trailerVehicleId = vehicleId ~= 0 and vehicleId or nil
    if liters ~= nil then
        job.yardHaul.liters = liters
    end
    TheContractorRepairContracts.clearCache()
end

-- Server: a finished job's trailer goes home once nobody's towing it or can
-- see it.
function TheContractorYardHaul:collectTrailer(job)
    local haul = job.yardHaul
    if (haul.trailerVehicleId or 0) ~= 0 then
        g_currentMission.TheContractor.RepairContracts:queueLoanCollection(job.farmId, haul.farmerId,
            haul.trailerVehicleId, haul.trailerUniqueId, haul.machineId, true)
    end
    haul.trailerCollected = true
end

function TheContractorYardHaul:collectFinishedTrailers()
    local tc = g_currentMission.TheContractor
    for _, farm in ipairs(g_farmManager:getFarms()) do
        for _, job in ipairs(tc.Jobs:getAllJobs(farm.farmId)) do
            if job.yardHaul ~= nil and job:isTerminal() and not job.yardHaul.trailerCollected then
                self:collectTrailer(job)
            end
        end
    end
end

function TheContractorYardHaul:update(dt)
    if not g_currentMission:getIsServer() then
        return
    end
    self.collectMs = self.collectMs + dt
    if self.collectMs >= TheContractorYardHaul.COLLECT_CHECK_MS then
        self.collectMs = 0
        self:collectFinishedTrailers()
    end
end

-- A miss (server) -------------------------------------------------------------------------

-- From Jobs:missJob, before anything's released: how much of the load
-- neither reached the station nor is still in the trailer (haul.missingLiters,
-- 0 unless it's more than THEFT_ALLOWANCE of the load). Nothing's judged
-- for a trailer never filled, or gone.
function TheContractorYardHaul:judgeMiss(job)
    local haul = job.yardHaul
    haul.missingLiters = 0
    if not haul.filled then
        return 0
    end
    local inTrailer = TheContractorYardHaul.getTrailerLoad(haul)
    if inTrailer == nil then
        TCLog.info("TheContractor: farm %d job %d: the trailer's gone, so the load can't be checked", job.farmId,
            job.id)
        return 0
    end
    local missing = math.max(0, (haul.liters or 0) - job.deliveredLiters - inTrailer)
    if missing > (haul.liters or 0) * TheContractorYardHaul.THEFT_ALLOWANCE then
        haul.missingLiters = math.floor(missing)
    end
    TCLog.info("TheContractor: farm %d job %d missed: %.0f l load, %.0f delivered, %.0f in the trailer, %.0f l taken",
        job.farmId, job.id, haul.liters or 0, job.deliveredLiters, inTrailer, haul.missingLiters)
    return haul.missingLiters
end

-- Jobs:missJob's penalty: THEFT_REPUTATION more if the load was taken.
function TheContractorYardHaul.getTheftPenalty(job)
    if job.yardHaul == nil or (job.yardHaul.missingLiters or 0) <= 0 then
        return 0
    end
    return TheContractorYardHaul.THEFT_REPUTATION
end

-- What the claim comes to: the missing litres at the station's price today
-- (or the day of the offer, if it's gone). A vanilla price, so not scaled.
function TheContractorYardHaul.getClaimAmount(job)
    local haul = job.yardHaul
    local price = TheContractorYardHaul.getStationPrice(TCHaulage.resolveDeliveryStation(job),
        TheContractorYardHaul.getFillTypeIndex(haul))
    if price <= 0 then
        price = haul.pricePerLiter or 0
    end
    return math.floor((haul.missingLiters or 0) * price + 0.5)
end

-- From Jobs:missJob, after the logbook entry's written: a load that was
-- taken costs a claim (uninsured), on the entry, and the farmer's opinion
-- falls by THEFT_RELATIONSHIP more.
function TheContractorYardHaul:onJobMissed(job)
    local haul = job.yardHaul
    if (haul.missingLiters or 0) <= 0 then
        return
    end
    local tc = g_currentMission.TheContractor
    local farmId = job.farmId
    local amount = TheContractorYardHaul.getClaimAmount(job)
    local paid = tc.Claims:chargeClaim(farmId, amount, false)
    tc.Claims:addToJobLog(farmId, job.id, { cause = "grainTaken", amount = amount, paid = paid, insured = false,
        reputationPenalty = TheContractorYardHaul.THEFT_REPUTATION })
    tc.Relationships:adjust(farmId, job.customerId, -TheContractorYardHaul.THEFT_RELATIONSHIP, "grainTaken")

    local fillTypeIndex = TheContractorYardHaul.getFillTypeIndex(haul)
    tc.Inbox:postMessage(farmId, TheContractorYardHaul.CLAIM_KIND, "tc_yardHaul_claimTitle", "tc_yardHaul_claimBody",
        { "$volume_" .. haul.missingLiters, g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex) or
            haul.fillTypeName, "$money_" .. paid }, nil, { farmerId = haul.farmerId })
    TCLog.info("TheContractor: farm %d job %d: %.0f l of %s taken, claim of %.0f paid", farmId, job.id,
        haul.missingLiters, tostring(haul.fillTypeName), paid)
end

-- The claim's args with the farmer's name as it is now on the end (112).
function TheContractorYardHaul.getClaimArgs(message)
    local args = {}
    for i, arg in ipairs(message.args or {}) do
        args[i] = arg
    end
    local farmers = g_currentMission.TheContractor.Farmers
    local farmer = farmers ~= nil and message.payload ~= nil and farmers:getPerson(message.payload.farmerId) or nil
    table.insert(args, farmer ~= nil and farmer.name or g_i18n:getText("tc_inbox_customerUnknown"))
    return args
end

-- After a load (server) ------------------------------------------------------------------

-- TheContractor:resolveSavedVehicles, after Jobs' and RepairContracts': the
-- trailer gets its object id back, and a job taken on without it (it never
-- came out, or it's gone) sends for it again: filled with what's still to
-- come.
function TheContractorYardHaul:resolveSavedVehicles()
    local tc = g_currentMission.TheContractor
    for _, farm in ipairs(g_farmManager:getFarms()) do
        for _, job in ipairs(tc.Jobs:getAllJobs(farm.farmId)) do
            local haul = job.yardHaul
            if haul ~= nil then
                haul.trailerVehicleId = haul.trailerUniqueId ~= nil and TCVehicleIds.getObjectId(haul.trailerUniqueId)
                    or nil
                if isTakenOn(job) and haul.trailerVehicleId == nil then
                    haul.trailerUniqueId = nil
                    self:queueTrailer(job)
                end
            end
        end
    end
    TheContractorRepairContracts.clearCache()
end

-- Sync and saves (with the job) -------------------------------------------------------------

local FLOAT_FIELDS = { "liters", "x", "z", "rotY", "pricePerLiter" }
local INT_FIELDS = { "farmerId", "yardFarmlandId", "machineId" }

-- What clients hold: all but the trailer's uniqueId and the server's
-- bookkeeping (filled, missing, collected).
function TheContractorYardHaul.writeStream(streamId, haul)
    if streamWriteBool(streamId, haul ~= nil) then
        streamWriteString(streamId, haul.fillTypeName or "")
        streamWriteString(streamId, haul.reason or "")
        for _, name in ipairs(FLOAT_FIELDS) do
            streamWriteFloat32(streamId, haul[name] or 0)
        end
        for _, name in ipairs(INT_FIELDS) do
            streamWriteInt32(streamId, haul[name] or 0)
        end
        streamWriteInt32(streamId, haul.trailerVehicleId or 0)
    end
end

function TheContractorYardHaul.readStream(streamId)
    if not streamReadBool(streamId) then
        return nil
    end
    local haul = { fillTypeName = streamReadString(streamId), reason = streamReadString(streamId) }
    for _, name in ipairs(FLOAT_FIELDS) do
        haul[name] = streamReadFloat32(streamId)
    end
    for _, name in ipairs(INT_FIELDS) do
        haul[name] = streamReadInt32(streamId)
    end
    local trailerVehicleId = streamReadInt32(streamId)
    haul.trailerVehicleId = trailerVehicleId ~= 0 and trailerVehicleId or nil
    return haul
end

-- The trailer by uniqueId (TCVehicleIds), turned back into an object id by
-- resolveSavedVehicles. The job's litres are haulage's, saved by Jobs.
function TheContractorYardHaul.saveToXML(xmlFile, key, haul)
    setXMLString(xmlFile, key .. "#fillTypeName", haul.fillTypeName or "")
    setXMLString(xmlFile, key .. "#reason", haul.reason or "")
    for _, name in ipairs(FLOAT_FIELDS) do
        setXMLFloat(xmlFile, key .. "#" .. name, haul[name] or 0)
    end
    for _, name in ipairs(INT_FIELDS) do
        setXMLInt(xmlFile, key .. "#" .. name, haul[name] or 0)
    end
    local trailerUniqueId = haul.trailerUniqueId or TCVehicleIds.getUniqueId(haul.trailerVehicleId)
    if trailerUniqueId ~= nil then
        setXMLString(xmlFile, key .. "#trailerUniqueId", trailerUniqueId)
    end
    if haul.filled then
        setXMLBool(xmlFile, key .. "#filled", true)
    end
    if haul.trailerCollected then
        setXMLBool(xmlFile, key .. "#trailerCollected", true)
    end
    if (haul.missingLiters or 0) > 0 then
        setXMLFloat(xmlFile, key .. "#missingLiters", haul.missingLiters)
    end
end

function TheContractorYardHaul.loadFromXML(xmlFile, key)
    if not hasXMLProperty(xmlFile, key) then
        return nil
    end
    local haul = {
        fillTypeName = getXMLString(xmlFile, key .. "#fillTypeName") or "",
        reason = getXMLString(xmlFile, key .. "#reason") or "",
    }
    for _, name in ipairs(FLOAT_FIELDS) do
        haul[name] = getXMLFloat(xmlFile, key .. "#" .. name) or 0
    end
    for _, name in ipairs(INT_FIELDS) do
        haul[name] = getXMLInt(xmlFile, key .. "#" .. name) or 0
    end
    haul.trailerUniqueId = getXMLString(xmlFile, key .. "#trailerUniqueId")
    haul.filled = getXMLBool(xmlFile, key .. "#filled") == true
    haul.trailerCollected = getXMLBool(xmlFile, key .. "#trailerCollected") == true
    haul.missingLiters = getXMLFloat(xmlFile, key .. "#missingLiters") or 0
    return haul
end

-- Nothing of its own to save or send: its state travels with the jobs.
function TheContractorYardHaul:writeInitialClientState(streamId, connection)
end

function TheContractorYardHaul:readInitialClientState(streamId, connection)
end
