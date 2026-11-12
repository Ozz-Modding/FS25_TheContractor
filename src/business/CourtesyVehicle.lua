-- Courtesy vehicle (071). A farm on comprehensive machinery cover (070)
-- that loses a vehicle to theft (069) is lent a similar one by the insurer
-- from the day the police close the case until the claim settles.
--
-- Picking (pickStoreItem, pure): a store item from the stolen vehicle's
-- store category with a power spec, falling back to the tractor categories.
-- A different model if there's one: the lowest power at or above the
-- stolen vehicle's, otherwise the highest below it, ties broken by price
-- then name, so every machine would pick the same. The stolen vehicle's
-- power comes from its configured motor (getConfiguredPower); a candidate's
-- from its default configuration, which is what's spawned.
--
-- Spawning (server): at the shop, then moved to a free Parking Slot if the
-- farm has one (TCParking.findSpot). Its property state is MISSION: vanilla
-- charges no leasing and no daily upkeep for it, use doesn't wear it, and
-- neither the map nor the workshop offer to sell it (getCanBeSold is
-- hooked too). It isn't OWNED, so it's never stolen (069) and isn't part of
-- the insured fleet (070). Jobs can use it like any other vehicle.
--
-- Returning: Theft puts getReturnStages after its writtenOff stage. Free (no
-- one in it, not on a job, not in a cooldown) and it's deleted at once.
-- Otherwise the farm's told, and it's tried again every day until it is.
-- Out on a job, it's flagged on the job's Overview line and collected as
-- the job's equipment comes home (collectDueVehicles, from the parking
-- queue), not a day later.
--
-- State: none of its own. The incident's data (068, saved and synced) has
-- courtesyVehicleId, courtesyUniqueId (for the save) and courtesyName.
-- resolveSavedVehicles finds it again after a load; one that's gone is
-- dropped and nothing else happens.

TheContractorCourtesyVehicle = {}
TheContractorCourtesyVehicle_mt = Class(TheContractorCourtesyVehicle)

TheContractorCourtesyVehicle.MESSAGE_KIND = "courtesyVehicle"
TheContractorCourtesyVehicle.NOTICE_MONTHS = 1

TheContractorCourtesyVehicle.STAGE = {
    RETURN = "courtesyReturn",
    -- Waits a day (the shortest a stage can wait) and tries again.
    RETRY = "courtesyRetry",
}
TheContractorCourtesyVehicle.RETRY_DELAY_PERIODS = { 0, 0 }

-- Where to look when the stolen vehicle's own category has nothing.
TheContractorCourtesyVehicle.FALLBACK_CATEGORIES = { "TRACTORSS", "TRACTORSM", "TRACTORSL" }

function TheContractorCourtesyVehicle.new()
    local self = {}
    setmetatable(self, TheContractorCourtesyVehicle_mt)
    return self
end

-- Every machine, at load, before Theft registers (it asks for the stages).
function TheContractorCourtesyVehicle:register(randomEvents, inbox)
    self.randomEvents = randomEvents
    inbox:registerMessageKind(TheContractorCourtesyVehicle.MESSAGE_KIND, {
        category = "insurance",
        chipTone = "info",
    })
end

-- Reading (every machine) ---------------------------------------------------------

-- The open incident a courtesy vehicle belongs to, or nil.
function TheContractorCourtesyVehicle:getIncidentForVehicle(vehicleId)
    if vehicleId == nil or vehicleId == 0 or self.randomEvents == nil then
        return nil
    end
    for _, incident in pairs(self.randomEvents.incidents) do
        if incident.data.courtesyVehicleId == vehicleId then
            return incident
        end
    end
    return nil
end

function TheContractorCourtesyVehicle:isCourtesy(vehicleId)
    return self:getIncidentForVehicle(vehicleId) ~= nil
end

-- The sell buttons already skip a MISSION vehicle; this covers anything
-- else that asks. Hooked on Vehicle at module scope, guarded, like Theft's.
-- getIsInUse is left alone: AI jobs and resets refuse a vehicle in use.
function TheContractorCourtesyVehicle.getCanBeSold(vehicle, superFunc)
    local tc = g_currentMission ~= nil and g_currentMission.TheContractor or nil
    if tc ~= nil and tc.CourtesyVehicle ~= nil and tc.CourtesyVehicle:isCourtesy(NetworkUtil.getObjectId(vehicle)) then
        return false
    end
    return superFunc(vehicle)
end

if not Vehicle.tcCourtesyHookInstalled and Vehicle.getCanBeSold ~= nil then
    Vehicle.getCanBeSold = Utils.overwrittenFunction(Vehicle.getCanBeSold, TheContractorCourtesyVehicle.getCanBeSold)
    Vehicle.tcCourtesyHookInstalled = true
end

-- Vanilla only lets a MISSION vehicle's own work areas work a mission's
-- field. A lent self-propelled machine (a sprayer for a stolen sprayer)
-- has to work the farm's fields like the one it replaces, so it's judged
-- as if it were owned. Patched on the specialization before vehicle types
-- are finalized, like the Vehicle hooks.
function TheContractorCourtesyVehicle.getIsAccessibleAtWorldPosition(vehicle, superFunc, ...)
    local tc = g_currentMission ~= nil and g_currentMission.TheContractor or nil
    if vehicle.propertyState == VehiclePropertyState.MISSION and tc ~= nil and tc.CourtesyVehicle ~= nil and
            tc.CourtesyVehicle:isCourtesy(NetworkUtil.getObjectId(vehicle)) then
        vehicle.propertyState = VehiclePropertyState.OWNED
        local isAccessible, farmId, isBuyable = superFunc(vehicle, ...)
        vehicle.propertyState = VehiclePropertyState.MISSION
        return isAccessible, farmId, isBuyable
    end
    return superFunc(vehicle, ...)
end

if WorkArea ~= nil and not WorkArea.tcCourtesyHookInstalled and WorkArea.getIsAccessibleAtWorldPosition ~= nil then
    WorkArea.getIsAccessibleAtWorldPosition = Utils.overwrittenFunction(WorkArea.getIsAccessibleAtWorldPosition,
        TheContractorCourtesyVehicle.getIsAccessibleAtWorldPosition)
    WorkArea.tcCourtesyHookInstalled = true
end

-- Picking ---------------------------------------------------------------------------

local function getSortedKeys(map)
    local keys = {}
    for key in pairs(map) do
        table.insert(keys, key)
    end
    table.sort(keys)
    return keys
end

-- A store item's horsepower with these configurations (configName ->
-- index), or nil if it has no power spec. A config with its own hp
-- (specs.powerConfig) wins, then the motor config's power, then the base
-- spec.
function TheContractorCourtesyVehicle.getConfiguredPower(storeItem, configurations)
    if StoreItemUtil ~= nil and StoreItemUtil.loadSpecsFromXML ~= nil then
        StoreItemUtil.loadSpecsFromXML(storeItem)
    end
    local specs = storeItem.specs or {}
    configurations = configurations or {}

    if specs.powerConfig ~= nil then
        for _, name in ipairs(getSortedKeys(configurations)) do
            local byIndex = specs.powerConfig[name]
            if byIndex ~= nil and byIndex[configurations[name]] ~= nil then
                return byIndex[configurations[name]]
            end
        end
    end

    local motors = storeItem.configurations ~= nil and storeItem.configurations.motor or nil
    local motor = motors ~= nil and configurations.motor ~= nil and motors[configurations.motor] or nil
    if motor ~= nil and motor.power ~= nil then
        return motor.power
    end
    return specs.power
end

-- configName -> the default index, for every configuration the item has.
function TheContractorCourtesyVehicle.getDefaultConfigurations(storeItem)
    local result = {}
    if storeItem.configurations == nil or ConfigurationUtil == nil then
        return result
    end
    for name, items in pairs(storeItem.configurations) do
        result[name] = ConfigurationUtil.getDefaultConfigIdFromItems(items)
    end
    return result
end

local function isCandidate(storeItem)
    if storeItem.bundleInfo ~= nil or storeItem.showInStore == false then
        return false
    end
    if StoreSpecies ~= nil and storeItem.species ~= nil and storeItem.species ~= StoreSpecies.VEHICLE then
        return false
    end
    if g_storeManager.getIsItemUnlocked ~= nil and not g_storeManager:getIsItemUnlocked(storeItem) then
        return false
    end
    return true
end

-- { storeItem, power, price, name } for every store item in these
-- categories that has a power spec.
function TheContractorCourtesyVehicle.getCandidates(categoryNames)
    local wanted = {}
    for _, name in ipairs(categoryNames) do
        wanted[name] = true
    end

    local result = {}
    for _, storeItem in ipairs(g_storeManager:getItems()) do
        if storeItem.categoryName ~= nil and wanted[storeItem.categoryName] and isCandidate(storeItem) then
            local power = TheContractorCourtesyVehicle.getConfiguredPower(storeItem,
                TheContractorCourtesyVehicle.getDefaultConfigurations(storeItem))
            if power ~= nil and power > 0 then
                table.insert(result, {
                    storeItem = storeItem,
                    power = power,
                    price = storeItem.price or 0,
                    name = storeItem.name or storeItem.xmlFilename or "",
                })
            end
        end
    end
    return result
end

local function isSameItem(storeItem, xmlFilename)
    return xmlFilename ~= nil and storeItem.xmlFilename ~= nil and
        string.lower(storeItem.xmlFilename) == string.lower(xmlFilename)
end

-- Pure: the candidate closest in power at or above `power`, otherwise the
-- closest below, never the stolen model (stolenXmlFilename). Ties by
-- price, then name. nil if there's nothing.
function TheContractorCourtesyVehicle.pickStoreItem(candidates, power, stolenXmlFilename)
    local best = nil
    local function isBetter(candidate)
        if best == nil then
            return true
        end
        local candidateAbove, bestAbove = candidate.power >= power, best.power >= power
        if candidateAbove ~= bestAbove then
            return candidateAbove
        end
        if candidate.power ~= best.power then
            if candidateAbove then
                return candidate.power < best.power
            end
            return candidate.power > best.power
        end
        if candidate.price ~= best.price then
            return candidate.price < best.price
        end
        return candidate.name < best.name
    end

    for _, candidate in ipairs(candidates) do
        if not isSameItem(candidate.storeItem, stolenXmlFilename) and isBetter(candidate) then
            best = candidate
        end
    end
    return best
end

-- The store item to lend for a stolen vehicle: its own category first,
-- then the tractor categories, then (if nothing else has power at all) the
-- same model. Returns the candidate, or nil.
function TheContractorCourtesyVehicle.pickForStolen(stolenStoreItem, power)
    local stolenXml = stolenStoreItem.xmlFilename
    local categoryLists = {}
    if stolenStoreItem.categoryName ~= nil then
        table.insert(categoryLists, { stolenStoreItem.categoryName })
    end
    table.insert(categoryLists, TheContractorCourtesyVehicle.FALLBACK_CATEGORIES)

    for _, categoryNames in ipairs(categoryLists) do
        local picked = TheContractorCourtesyVehicle.pickStoreItem(
            TheContractorCourtesyVehicle.getCandidates(categoryNames), power, stolenXml)
        if picked ~= nil then
            return picked
        end
    end

    -- Nothing different anywhere: the same model's better than nothing.
    local samePower = TheContractorCourtesyVehicle.getConfiguredPower(stolenStoreItem,
        TheContractorCourtesyVehicle.getDefaultConfigurations(stolenStoreItem))
    if samePower ~= nil and isCandidate(stolenStoreItem) then
        return { storeItem = stolenStoreItem, power = samePower, price = stolenStoreItem.price or 0,
            name = stolenStoreItem.name or "" }
    end
    return nil
end

-- Lending (server) ------------------------------------------------------------------

local function getLiveVehicle(vehicleId)
    local vehicle = vehicleId ~= nil and vehicleId ~= 0 and NetworkUtil.getObject(vehicleId) or nil
    if vehicle == nil or vehicle.isDeleted then
        return nil
    end
    return vehicle
end

-- Whether this level of cover comes with a courtesy vehicle.
function TheContractorCourtesyVehicle.isIncluded(levelKey)
    local level = levelKey ~= nil and TheContractorMachineryInsurance.getLevel(levelKey) or nil
    return level ~= nil and level.courtesyVehicle == true
end

-- From Theft's police report, when the case is closed and the farm was
-- insured on the day. Picks and spawns one if the cover includes it and
-- the stolen vehicle had a power spec. stolenVehicle is nil if it's gone.
-- Returns whether one is on its way.
function TheContractorCourtesyVehicle:lend(incident, stolenVehicle)
    local data = incident.data
    if not TheContractorCourtesyVehicle.isIncluded(data.coverLevel) then
        return false
    end
    local stolenStoreItem = data.storeItem ~= nil and data.storeItem ~= "" and
        g_storeManager:getItemByXMLFilename(data.storeItem) or nil
    if stolenStoreItem == nil then
        return false
    end

    local configurations = stolenVehicle ~= nil and stolenVehicle.configurations or
        TheContractorCourtesyVehicle.getDefaultConfigurations(stolenStoreItem)
    local power = TheContractorCourtesyVehicle.getConfiguredPower(stolenStoreItem, configurations)
    if power == nil or power <= 0 then
        TCLog.info("TheContractor: farm %d incident %d: %s has no power spec, no courtesy vehicle",
            incident.farmId, incident.id, data.name)
        return false
    end

    local picked = TheContractorCourtesyVehicle.pickForStolen(stolenStoreItem, power)
    if picked == nil then
        TCLog.warning("TheContractor: farm %d incident %d: no courtesy vehicle to be had for %s (%d hp)",
            incident.farmId, incident.id, data.name, power)
        return false
    end

    TCLog.info("TheContractor: farm %d incident %d: courtesy %s (%d hp) for %s (%d hp)", incident.farmId,
        incident.id, picked.name, picked.power, data.name, power)
    return self:spawn(incident, picked.storeItem)
end

function TheContractorCourtesyVehicle:spawn(incident, storeItem)
    if VehicleLoadingData == nil then
        return false
    end
    local loadingData = VehicleLoadingData.new()
    loadingData:setStoreItem(storeItem)
    TCStoreConfigurations.apply(loadingData, storeItem)
    loadingData:setLoadingPlace(g_currentMission.storeSpawnPlaces, g_currentMission.usedStorePlaces)
    loadingData:setPropertyState(VehiclePropertyState.MISSION)
    loadingData:setOwnerFarmId(incident.farmId)
    loadingData:load(self.onSpawned, self, { incidentId = incident.id, farmId = incident.farmId })
    return true
end

-- VehicleLoadingData's callback: into a free Parking Slot if there is one,
-- else it stays at the shop where it loaded.
function TheContractorCourtesyVehicle:onSpawned(vehicles, loadingState, args)
    local vehicle = vehicles ~= nil and vehicles[1] or nil
    if vehicle == nil or loadingState ~= VehicleLoadingState.OK then
        TCLog.warning("TheContractor: incident %d: the courtesy vehicle failed to load", args.incidentId)
        return
    end

    local incident = self.randomEvents:getIncident(args.incidentId)
    if incident == nil then
        -- The incident ended while it loaded: nothing to lend it for.
        vehicle:delete()
        return
    end

    local placeKey = "tc_courtesy_placeShop"
    local x, y, z, rotY = TCParking.findSpot(vehicle, args.farmId)
    if x ~= nil then
        TCParking.placeVehicle(vehicle, x, y, z, rotY)
        placeKey = "tc_courtesy_placeSlot"
    end

    local data = incident.data
    data.courtesyVehicleId = NetworkUtil.getObjectId(vehicle)
    data.courtesyUniqueId = vehicle.getUniqueId ~= nil and vehicle:getUniqueId() or ""
    data.courtesyName = vehicle:getFullName()
    self.randomEvents:commitIncident(incident)

    local tc = g_currentMission.TheContractor
    tc.Inbox:postMessage(incident.farmId, TheContractorCourtesyVehicle.MESSAGE_KIND, "tc_courtesy_lentTitle",
        "tc_courtesy_lentBody", { data.courtesyName, data.name, "$l10n_" .. placeKey }, nil,
        { incidentId = incident.id })
    tc.Notices:publish(incident.farmId, string.format(g_i18n:getText("tc_courtesy_lentNotice"), data.courtesyName,
        g_i18n:getText(placeKey)), TheContractorCourtesyVehicle.NOTICE_MONTHS)
    TCLog.info("TheContractor: farm %d incident %d: courtesy %s (%d) at %s", incident.farmId, incident.id,
        data.courtesyName, data.courtesyVehicleId, placeKey)
end

-- Returning (server) ----------------------------------------------------------------

-- Theft puts these after its write-off. RETURN runs straight away; RETRY
-- runs it again a day later, for as long as the vehicle's busy.
function TheContractorCourtesyVehicle:getReturnStages()
    local stage = TheContractorCourtesyVehicle.STAGE
    return {
        { key = stage.RETURN, run = function(incident)
            return self:onReturn(incident, true)
        end },
        { key = stage.RETRY, delayPeriods = TheContractorCourtesyVehicle.RETRY_DELAY_PERIODS, run = function(incident)
            return self:onReturn(incident, false)
        end },
    }
end

-- Someone's in it or driving it, or it's out on a job or cooling down
-- after one. Waiting to be parked doesn't count: it's taken from the queue.
function TheContractorCourtesyVehicle.isBusy(vehicle)
    local tc = g_currentMission.TheContractor
    local vehicleId = NetworkUtil.getObjectId(vehicle)
    return TheContractorTheft.isInUse(vehicle) or TheContractorTheft.getJobVehicleIds()[vehicleId] == true or
        tc.Cooldown:isVehicleInCooldown(vehicleId)
end

function TheContractorCourtesyVehicle:onReturn(incident, isFirstTry)
    local data = incident.data
    local vehicle = getLiveVehicle(data.courtesyVehicleId)
    if vehicle == nil then
        -- None lent, or it's gone already.
        return TheContractorRandomEvents.DONE
    end

    local tc = g_currentMission.TheContractor
    if TheContractorCourtesyVehicle.isBusy(vehicle) then
        if isFirstTry then
            tc.Inbox:postMessage(incident.farmId, TheContractorCourtesyVehicle.MESSAGE_KIND,
                "tc_courtesy_dueTitle", "tc_courtesy_dueBody", { data.courtesyName }, nil, { incidentId = incident.id })
            TCLog.info("TheContractor: farm %d incident %d: courtesy %s is busy, collecting it when it's free",
                incident.farmId, incident.id, data.courtesyName)
        end
        return TheContractorCourtesyVehicle.STAGE.RETRY
    end

    self:collect(incident, vehicle)
    return TheContractorRandomEvents.DONE
end

-- Whether the insurer is waiting to collect this courtesy vehicle (the
-- claim's settled, but it was busy). Every machine: the Overview's job lines
-- flag it on the job it's out on.
function TheContractorCourtesyVehicle:isDue(vehicleId)
    local incident = self:getIncidentForVehicle(vehicleId)
    return incident ~= nil and incident.stage == TheContractorCourtesyVehicle.STAGE.RETRY
end

-- The name of a due courtesy vehicle out on this job, or nil.
function TheContractorCourtesyVehicle:getDueOnJob(job)
    for _, vehicleId in ipairs(job:getAllEquipmentIds()) do
        if self:isDue(vehicleId) then
            return self:getIncidentForVehicle(vehicleId).data.courtesyName
        end
    end
    return nil
end

-- Server, from the parking queue (every job's equipment comes home through
-- it): a due courtesy vehicle back from a job is collected there and then,
-- rather than parked and collected the next day. Returns the vehicle ids
-- left to park.
function TheContractorCourtesyVehicle:collectDueVehicles(vehicleIds)
    local remaining = {}
    for _, vehicleId in ipairs(vehicleIds) do
        local incident = self:isDue(vehicleId) and self:getIncidentForVehicle(vehicleId) or nil
        local vehicle = incident ~= nil and getLiveVehicle(vehicleId) or nil
        if vehicle ~= nil and not TheContractorCourtesyVehicle.isBusy(vehicle) then
            self:collect(incident, vehicle)
            self.randomEvents:closeIncident(incident)
        else
            table.insert(remaining, vehicleId)
        end
    end
    return remaining
end

-- The insurer takes it away: anything hitched is left behind.
function TheContractorCourtesyVehicle:collect(incident, vehicle)
    local tc = g_currentMission.TheContractor
    local data = incident.data
    local vehicleId = data.courtesyVehicleId
    tc.Parking:removeVehicles({ vehicleId })
    TCJobSiteSetup.unhitchVehicles({ vehicleId })
    vehicle:delete()
    data.courtesyVehicleId = 0

    tc.Inbox:postMessage(incident.farmId, TheContractorCourtesyVehicle.MESSAGE_KIND, "tc_courtesy_returnedTitle",
        "tc_courtesy_returnedBody", { data.courtesyName }, nil, { incidentId = incident.id })
    tc.Notices:publish(incident.farmId, string.format(g_i18n:getText("tc_courtesy_returnedNotice"),
        data.courtesyName), TheContractorCourtesyVehicle.NOTICE_MONTHS)
    TCLog.info("TheContractor: farm %d incident %d: courtesy %s collected", incident.farmId, incident.id,
        data.courtesyName)
end

-- Saved vehicles (server) ------------------------------------------------------------

-- Once, after the save's vehicles exist: each courtesy vehicle's object id
-- from its uniqueId. One that's gone is dropped.
function TheContractorCourtesyVehicle:resolveSavedVehicles()
    if self.randomEvents == nil then
        return
    end
    for _, incident in pairs(self.randomEvents.incidents) do
        local uniqueId = incident.data.courtesyUniqueId
        if uniqueId ~= nil and uniqueId ~= "" then
            local vehicleId = TCVehicleIds.getObjectId(uniqueId)
            incident.data.courtesyVehicleId = vehicleId or 0
            if vehicleId == nil then
                incident.data.courtesyUniqueId = ""
            end
        end
    end
end
