-- Vehicle theft (069), the first random event (068). Now and then one of a
-- farm's drivable vehicles is stolen: never an implement or trailer, and
-- only ever one vehicle. Anything hitched to it is unhitched and left where
-- it stood. It's hidden and locked (the same as equipment away on a job)
-- and reported to the police. When their report comes back, the vehicle has
-- been recovered (RECOVERY_CHANCE: damaged and dirty, and back through the
-- parking queue, 062) or the case is closed and it's written off: deleted
-- there and then. Either way the "stolen" inbox message is taken down, as
-- the report's message replaces it. A farm with machinery insurance (070)
-- on the day of the theft then claims: the insurer's claim stages run on the
-- value copied at the theft. Comprehensive cover also lends a courtesy
-- vehicle (071) from the police report until settlement; its return stages
-- come after the write-off.
--
-- What can be stolen (getEligibleVehicles): an owned drivable that isn't
-- attached to anything, nobody's in or driving (player, AI helper,
-- AutoDrive, a 037 staff driver), and that isn't on an allocated or
-- in-progress job, in a cooldown, waiting for parking, hidden or locked -
-- nor is anything hitched to it. Weighted by store category toward what
-- really gets stolen (CATEGORY_WEIGHTS).
--
-- 096: a vehicle with FS25_AdvancedDamageSystem's anti-theft system fitted
-- (hasAntiTheft) counts ANTI_THEFT_WEIGHT of its weight and is recovered at
-- ANTI_THEFT_RECOVERY_CHANCE. It still counts as a whole vehicle in the
-- fleet factor: thieves don't know it's fitted until they've taken it, and
-- it keeps enough risk that insuring a fitted fleet still makes sense.
-- Whether it had one is judged on the day of the theft (data.antiTheft).
--
-- The rate is per month (068): BASE_RATE_PER_PERIOD times a fleet factor
-- from how many vehicles could be stolen, with a year's cooldown per farm.
--
-- State: none of its own. The incident's data (068, saved and synced) has
-- the vehicle's object id, uniqueId (for the save), name, value and store
-- item, copied at the theft so later messages (and 070's claim) don't need
-- the vehicle, plus coverLevel (070, "" when uninsured) and antiTheft (096). Every machine reads the stolen vehicles off the open
-- incidents (isStolen): TCVehicleLock locks them, allocation skips them and
-- they can't be sold.

TheContractorTheft = {}
TheContractorTheft_mt = Class(TheContractorTheft)

TheContractorTheft.EVENT_TYPE = "theft"
TheContractorTheft.MESSAGE_KIND = "theft"
-- What machinery insurance (070) has to cover for a theft to be claimed.
TheContractorTheft.PERIL = "theft"

-- About one theft every 4-5 years for a typical fleet.
TheContractorTheft.BASE_RATE_PER_PERIOD = 0.02
-- Fleet factor: FLEET_FACTOR_BASE + eligible vehicles / FLEET_FACTOR_DIVISOR,
-- at most FLEET_FACTOR_MAX.
TheContractorTheft.FLEET_FACTOR_BASE = 0.5
TheContractorTheft.FLEET_FACTOR_DIVISOR = 20
TheContractorTheft.FLEET_FACTOR_MAX = 2
TheContractorTheft.COOLDOWN_PERIODS = 12

-- The police report comes back this many months after the theft.
TheContractorTheft.POLICE_DELAY_PERIODS = { 0.1, 0.35 }
TheContractorTheft.RECOVERY_CHANCE = 0.35

-- 096: ADS's anti-theft system (an ADS workshop upgrade, only offered while
-- this mod is loaded). ADS saves and syncs it as a vehicle state and gives
-- it no effect of its own.
TheContractorTheft.ANTI_THEFT_MOD = "FS25_AdvancedDamageSystem"
TheContractorTheft.ANTI_THEFT_STATE = "ANTI_THEFT_SYSTEM"
TheContractorTheft.ANTI_THEFT_WEIGHT = 0.1
TheContractorTheft.ANTI_THEFT_RECOVERY_CHANCE = 0.7

-- A recovered vehicle comes back with this much more damage (0-1, on top of
-- what it had), and filthy.
TheContractorTheft.RECOVERY_DAMAGE_MIN = 0.1
TheContractorTheft.RECOVERY_DAMAGE_MAX = 0.3
TheContractorTheft.RECOVERY_DIRT = 1

TheContractorTheft.NOTICE_MONTHS = 1

-- Store categories thieves go for, and ones they hardly ever take. Anything
-- else counts DEFAULT_WEIGHT. The ids are vanilla's as far as the mod's
-- code and references show them; one that doesn't exist just never
-- matches.
TheContractorTheft.DEFAULT_WEIGHT = 1
TheContractorTheft.CATEGORY_WEIGHTS = {
    TRACTORSS = 3,
    TRACTORSM = 3,
    TRACTORSL = 2,
    FRONTLOADERVEHICLES = 3,
    TELELOADERVEHICLES = 3,
    WHEELLOADERVEHICLES = 2,
    SKIDSTEERVEHICLES = 3,
    CARS = 3,
    ANIMALSVEHICLES = 3,
    HARVESTERS = 0.25,
    COMBINES = 0.25,
    FORAGEHARVESTERS = 0.25,
    BEETVEHICLES = 0.25,
    BEETHARVESTING = 0.25,
    POTATOVEHICLES = 0.25,
    POTATOHARVESTING = 0.25,
    VEGETABLEVEHICLES = 0.25,
    SPINACHHARVESTERS = 0.25,
    COTTONVEHICLES = 0.25,
    SUGARCANEVEHICLES = 0.25,
    SUGARCANEHARVESTING = 0.25,
    GRAPEVEHICLES = 0.25,
    OLIVEVEHICLES = 0.25,
    RICEVEHICLES = 0.25,
}

-- Outcomes the console can force on the next police report.
TheContractorTheft.OUTCOME = {
    RECOVERED = "recovered",
    LOST = "lost",
}

function TheContractorTheft.new()
    local self = {}
    setmetatable(self, TheContractorTheft_mt)

    -- tcCompany outcome theft: the next police report's outcome. Server-only,
    -- not saved.
    self.forcedOutcome = nil

    return self
end

-- Every machine, at load, before the save loads (068). insurance (070,
-- optional) adds its claim stages between the police report and the write
-- off, and courtesy (071, optional) its return stages after it.
function TheContractorTheft:register(randomEvents, inbox, insurance, courtesy)
    self.randomEvents = randomEvents
    self.insurance = insurance
    self.courtesy = courtesy

    local stages = {
        { key = "stolen", run = function(incident)
            return self:onStolen(incident)
        end },
        { key = "policeReport", delayPeriods = TheContractorTheft.POLICE_DELAY_PERIODS, run = function(incident)
            return self:onPoliceReport(incident)
        end },
    }
    if insurance ~= nil then
        for _, stage in ipairs(insurance:getClaimStages("writtenOff")) do
            table.insert(stages, stage)
        end
    end
    table.insert(stages, { key = "writtenOff", run = function(incident)
        return self:onWrittenOff(incident)
    end })
    if courtesy ~= nil then
        for _, stage in ipairs(courtesy:getReturnStages()) do
            table.insert(stages, stage)
        end
    end

    randomEvents:registerEventType(TheContractorTheft.EVENT_TYPE, {
        l10nKey = "tc_theft_eventName",
        peril = TheContractorTheft.PERIL,
        cooldownPeriods = TheContractorTheft.COOLDOWN_PERIODS,
        ratePerPeriod = function(farmId)
            return self:getRatePerPeriod(farmId)
        end,
        canTrigger = function(farmId)
            return self:pickVehicle(farmId)
        end,
        stages = stages,
        console = {
            outcomes = { TheContractorTheft.OUTCOME.RECOVERED, TheContractorTheft.OUTCOME.LOST },
            setOutcome = function(outcome)
                self.forcedOutcome = outcome
                return string.format("The next police report on a stolen vehicle will say it's %s",
                    outcome == TheContractorTheft.OUTCOME.RECOVERED and "been recovered" or "not been found")
            end,
        },
    })

    inbox:registerMessageKind(TheContractorTheft.MESSAGE_KIND, {
        category = "crime",
        chipTone = "bad",
    })
end

-- Reading (every machine) ---------------------------------------------------------

-- The open theft incident for a vehicle, or nil.
function TheContractorTheft:getIncidentForVehicle(vehicleId)
    if vehicleId == nil or vehicleId == 0 or self.randomEvents == nil then
        return nil
    end
    for _, incident in pairs(self.randomEvents.incidents) do
        if incident.eventType == TheContractorTheft.EVENT_TYPE and incident.data.vehicleId == vehicleId then
            return incident
        end
    end
    return nil
end

function TheContractorTheft:isStolen(vehicleId)
    return self:getIncidentForVehicle(vehicleId) ~= nil
end

-- vehicleId -> true for every vehicle that's stolen right now.
function TheContractorTheft:getStolenVehicleIds()
    local result = {}
    if self.randomEvents == nil then
        return result
    end
    for _, incident in pairs(self.randomEvents.incidents) do
        local vehicleId = incident.data.vehicleId
        if incident.eventType == TheContractorTheft.EVENT_TYPE and vehicleId ~= nil and vehicleId ~= 0 then
            result[vehicleId] = true
        end
    end
    return result
end

-- Selling a stolen vehicle (the shop's garage list still has it): the
-- shop's sell button reads getCanBeSold, and the server's SellVehicleEvent
-- refuses a vehicle that getIsInUse. Hooked on Vehicle at module scope,
-- guarded, before vehicle types are finalized (as TCEquipmentVisibility's
-- hotspot hook is).
local function isVehicleStolen(vehicle)
    local tc = g_currentMission ~= nil and g_currentMission.TheContractor or nil
    if tc == nil or tc.Theft == nil then
        return false
    end
    return tc.Theft:isStolen(NetworkUtil.getObjectId(vehicle))
end

function TheContractorTheft.getCanBeSold(vehicle, superFunc)
    if isVehicleStolen(vehicle) then
        return false
    end
    return superFunc(vehicle)
end

function TheContractorTheft.getIsInUse(vehicle, superFunc, connection)
    if isVehicleStolen(vehicle) then
        return true
    end
    return superFunc(vehicle, connection)
end

if not Vehicle.tcTheftHooksInstalled and Vehicle.getCanBeSold ~= nil and Vehicle.getIsInUse ~= nil then
    Vehicle.getCanBeSold = Utils.overwrittenFunction(Vehicle.getCanBeSold, TheContractorTheft.getCanBeSold)
    Vehicle.getIsInUse = Utils.overwrittenFunction(Vehicle.getIsInUse, TheContractorTheft.getIsInUse)
    Vehicle.tcTheftHooksInstalled = true
end

-- 096: the vehicle has ADS's anti-theft system fitted. Every machine gets
-- the same answer (ADS syncs it); without ADS, never.
function TheContractorTheft.hasAntiTheft(vehicle)
    return vehicle ~= nil and vehicle.hasBreakdown ~= nil and
        vehicle:hasBreakdown(TheContractorTheft.ANTI_THEFT_STATE) == true
end

-- 096: ADS is loaded, so the anti-theft system can be fitted.
function TheContractorTheft.isAntiTheftOffered()
    return g_modIsLoaded ~= nil and g_modIsLoaded[TheContractorTheft.ANTI_THEFT_MOD] == true
end

-- Eligibility (server) ------------------------------------------------------------

local function getLiveVehicle(vehicleId)
    local vehicle = vehicleId ~= nil and vehicleId ~= 0 and NetworkUtil.getObject(vehicleId) or nil
    if vehicle == nil or vehicle.isDeleted then
        return nil
    end
    return vehicle
end

-- The vehicle and everything hitched to it, all the way down.
local function getChain(vehicle, result)
    result = result or {}
    table.insert(result, vehicle)
    if vehicle.getAttachedImplements ~= nil then
        for _, implement in ipairs(vehicle:getAttachedImplements()) do
            if implement.object ~= nil then
                getChain(implement.object, result)
            end
        end
    end
    return result
end

-- Vehicle ids out on any farm's allocated or in-progress job.
function TheContractorTheft.getJobVehicleIds()
    local result = {}
    local jobs = g_currentMission.TheContractor.Jobs
    for _, farm in ipairs(g_farmManager:getFarms()) do
        for _, job in ipairs(jobs:getAllJobs(farm.farmId)) do
            if job.state == TheContractorJob.STATE.ALLOCATED or job.state == TheContractorJob.STATE.IN_PROGRESS then
                for _, vehicleId in ipairs(job:getAllEquipmentIds()) do
                    result[vehicleId] = true
                end
            end
        end
    end
    return result
end

-- Something in the chain is busy with the business: on a job, in a
-- cooldown, waiting for parking, hidden, locked or already stolen.
function TheContractorTheft:isChainBusy(chain, jobVehicleIds)
    local tc = g_currentMission.TheContractor
    for _, vehicle in ipairs(chain) do
        local vehicleId = NetworkUtil.getObjectId(vehicle)
        if vehicleId == nil or jobVehicleIds[vehicleId] or tc.Cooldown:isVehicleInCooldown(vehicleId) or
                tc.Parking:isPending(vehicleId) or TCEquipmentVisibility.isHidden(vehicleId) or
                TCVehicleLock.isLocked(vehicle) or self:isStolen(vehicleId) then
            return true
        end
    end
    return false
end

-- Someone's in it or driving it.
function TheContractorTheft.isInUse(vehicle)
    if vehicle.getIsControlled ~= nil and vehicle:getIsControlled() then
        return true
    end
    if TheContractorDrivers.isVehicleDriven(vehicle) then
        return true
    end
    return g_currentMission.TheContractor.Drivers:hasDriver(vehicle)
end

-- The farm's vehicles that could be stolen right now, each with its weight
-- (096: less with an anti-theft system).
function TheContractorTheft:getEligibleVehicles(farmId)
    local result = {}
    local jobVehicleIds = TheContractorTheft.getJobVehicleIds()

    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if not vehicle.isDeleted and vehicle.spec_drivable ~= nil and vehicle.getOwnerFarmId ~= nil and
                vehicle:getOwnerFarmId() == farmId and vehicle.propertyState == VehiclePropertyState.OWNED and
                (vehicle.getAttacherVehicle == nil or vehicle:getAttacherVehicle() == nil) and
                not TheContractorTheft.isInUse(vehicle) and not self:isChainBusy(getChain(vehicle), jobVehicleIds) then
            local categoryName = TCEquipmentClass.getCategory(vehicle)
            local weight = categoryName ~= nil and TheContractorTheft.CATEGORY_WEIGHTS[categoryName] or nil
            local share = TheContractorTheft.hasAntiTheft(vehicle) and TheContractorTheft.ANTI_THEFT_WEIGHT or 1
            table.insert(result, { vehicle = vehicle, weight = (weight or TheContractorTheft.DEFAULT_WEIGHT) * share })
        end
    end
    return result
end

-- eligibleCount: vehicles that could be stolen.
function TheContractorTheft.getFleetFactor(eligibleCount)
    return math.min(TheContractorTheft.FLEET_FACTOR_MAX,
        TheContractorTheft.FLEET_FACTOR_BASE + eligibleCount / TheContractorTheft.FLEET_FACTOR_DIVISOR)
end

-- Expected thefts a month (068), nothing if there's nothing to steal.
function TheContractorTheft:getRatePerPeriod(farmId)
    local eligible = self:getEligibleVehicles(farmId)
    if #eligible == 0 then
        return 0
    end
    return TheContractorTheft.BASE_RATE_PER_PERIOD * TheContractorTheft.getFleetFactor(#eligible)
end

-- roll (0-1) picks by weight.
function TheContractorTheft.pickWeighted(candidates, roll)
    local total = 0
    for _, candidate in ipairs(candidates) do
        total = total + candidate.weight
    end
    if total <= 0 then
        return nil
    end
    local target = roll * total
    for _, candidate in ipairs(candidates) do
        target = target - candidate.weight
        if target < 0 then
            return candidate
        end
    end
    return candidates[#candidates]
end

-- canTrigger (068): the incident's starting data, or nil.
function TheContractorTheft:pickVehicle(farmId)
    local picked = TheContractorTheft.pickWeighted(self:getEligibleVehicles(farmId), math.random())
    if picked == nil then
        return nil
    end
    local vehicle = picked.vehicle
    return {
        vehicleId = NetworkUtil.getObjectId(vehicle),
        vehicleUniqueId = vehicle.getUniqueId ~= nil and vehicle:getUniqueId() or "",
        name = vehicle:getFullName(),
        value = math.floor(vehicle:getSellPrice()),
        storeItem = vehicle.configFileName or "",
        stolenDay = g_currentMission.environment.currentMonotonicDay,
        crimeReference = string.format("%02d/%05d", math.random(10, 99), math.random(0, 99999)),
        antiTheft = TheContractorTheft.hasAntiTheft(vehicle),
    }
end

-- Stages (server) ------------------------------------------------------------------

-- A message body, its "Tracker" variant if the vehicle had an anti-theft
-- system (096).
function TheContractorTheft.getBodyKey(bodyKey, data)
    return data.antiTheft == true and bodyKey .. "Tracker" or bodyKey
end

function TheContractorTheft:onStolen(incident)
    local data = incident.data
    local vehicle = getLiveVehicle(data.vehicleId)
    if vehicle == nil then
        return TheContractorRandomEvents.DONE
    end

    local tc = g_currentMission.TheContractor
    -- 070: cover is judged on the day of the theft.
    data.coverLevel = self.insurance ~= nil and
        self.insurance:getCoverLevel(incident.farmId, TheContractorTheft.PERIL) or ""

    TCJobSiteSetup.unhitchVehicles({ data.vehicleId })
    TCEquipmentVisibility.setVisibleEverywhere({ data.vehicleId }, false)
    -- The incident's already open on this machine, so the lock sees it.
    TCVehicleLock.refresh()

    data.stolenMessageId = tc.Inbox:postMessage(incident.farmId, TheContractorTheft.MESSAGE_KIND,
        "tc_theft_stolenTitle", TheContractorTheft.getBodyKey("tc_theft_stolenBody", data),
        { data.name, data.crimeReference }, nil,
        { incidentId = incident.id })
    tc.Notices:publish(incident.farmId, string.format(g_i18n:getText("tc_theft_stolenNotice"), data.name),
        TheContractorTheft.NOTICE_MONTHS)

    TCLog.info("TheContractor: farm %d incident %d: %s (%d) stolen, worth %d", incident.farmId, incident.id,
        data.name, data.vehicleId, data.value)
    return nil
end

-- antiTheft: it had ADS's anti-theft system on the day it was taken (096).
function TheContractorTheft:rollRecovered(antiTheft)
    local forced = self.forcedOutcome
    self.forcedOutcome = nil
    if forced ~= nil then
        return forced == TheContractorTheft.OUTCOME.RECOVERED
    end
    return math.random() < (antiTheft and TheContractorTheft.ANTI_THEFT_RECOVERY_CHANCE or
        TheContractorTheft.RECOVERY_CHANCE)
end

function TheContractorTheft:onPoliceReport(incident)
    local data = incident.data
    local recovered = self:rollRecovered(data.antiTheft == true)
    local vehicle = getLiveVehicle(data.vehicleId)
    TCLog.info("TheContractor: farm %d incident %d: police report on %s - %s%s", incident.farmId, incident.id,
        data.name, recovered and "recovered" or "not found", vehicle == nil and " (vehicle gone)" or "")

    local tc = g_currentMission.TheContractor
    if data.stolenMessageId ~= nil then
        tc.Inbox:removeMessage(data.stolenMessageId)
        data.stolenMessageId = nil
    end

    if recovered and vehicle ~= nil then
        self:returnRecovered(incident, vehicle)
        return TheContractorRandomEvents.DONE
    end

    -- The case is closed and the vehicle goes now. Insured on the day of the
    -- theft: the claim (070) comes next, on the value copied at the theft.
    local isInsured = self.insurance ~= nil and data.coverLevel ~= nil and data.coverLevel ~= ""
    tc.Inbox:postMessage(incident.farmId, TheContractorTheft.MESSAGE_KIND, "tc_theft_lostTitle",
        TheContractorTheft.getBodyKey(isInsured and "tc_theft_lostBodyInsured" or "tc_theft_lostBody", data),
        { data.name, data.crimeReference }, nil,
        { incidentId = incident.id })
    tc.Notices:publish(incident.farmId, string.format(g_i18n:getText("tc_theft_lostNotice"), data.name),
        TheContractorTheft.NOTICE_MONTHS)

    -- 071: comprehensive cover lends one until the claim settles. Before
    -- the delete: it reads the stolen vehicle's configuration.
    if isInsured and self.courtesy ~= nil then
        self.courtesy:lend(incident, vehicle)
    end
    self:deleteStolenVehicle(incident)

    if isInsured then
        return TheContractorMachineryInsurance.STAGE.CLAIM
    end
    return "writtenOff"
end

-- Off the farm's fleet for good. A no-op once it's gone.
function TheContractorTheft:deleteStolenVehicle(incident)
    local data = incident.data
    local vehicle = getLiveVehicle(data.vehicleId)
    if vehicle ~= nil then
        vehicle:delete()
    end
    data.vehicleId = 0
    data.vehicleUniqueId = ""
end

function TheContractorTheft:returnRecovered(incident, vehicle)
    local data = incident.data
    local tc = g_currentMission.TheContractor
    local startSnapshot = TCVehicleCondition.capture(vehicle)

    if vehicle.addDamageAmount ~= nil then
        local damage = TheContractorTheft.RECOVERY_DAMAGE_MIN +
            math.random() * (TheContractorTheft.RECOVERY_DAMAGE_MAX - TheContractorTheft.RECOVERY_DAMAGE_MIN)
        vehicle:addDamageAmount(damage, true)
    end
    if vehicle.addDirtAmount ~= nil then
        vehicle:addDirtAmount(TheContractorTheft.RECOVERY_DIRT, true)
    end

    tc.Logbook:recordTheftRecovered(incident.farmId, vehicle, startSnapshot,
        (g_currentMission.environment.currentMonotonicDay - data.stolenDay) * 24 * 60)

    -- Still hidden, so it joins the parking queue like equipment back from a
    -- job; it stays locked until it's parked.
    tc.Parking:returnHiddenVehicles(incident.farmId, { data.vehicleId })

    tc.Inbox:postMessage(incident.farmId, TheContractorTheft.MESSAGE_KIND, "tc_theft_recoveredTitle",
        TheContractorTheft.getBodyKey("tc_theft_recoveredBody", data), { data.name, data.crimeReference }, nil,
        { incidentId = incident.id })
    tc.Notices:publish(incident.farmId, string.format(g_i18n:getText("tc_theft_recoveredNotice"), data.name),
        TheContractorTheft.NOTICE_MONTHS)
end

-- Lost for good: straight after the police report, or once an insurance
-- claim (070) has settled. The vehicle went at the police report (this only
-- deletes one still kept by a save from before that). Then any courtesy
-- vehicle goes back (071's stages, next in the list), or the incident ends.
function TheContractorTheft:onWrittenOff(incident)
    self:deleteStolenVehicle(incident)
    return nil
end

-- Saved vehicles (server) ------------------------------------------------------------

-- Once, after the save's vehicles exist: each stolen vehicle's object id
-- from its uniqueId, and hidden again (vehicles load where they stood, in
-- view). A vehicle that's gone is left at 0; the police report then
-- writes it off.
function TheContractorTheft:resolveSavedVehicles()
    if self.randomEvents == nil then
        return
    end
    local hidden = {}
    for _, incident in pairs(self.randomEvents.incidents) do
        if incident.eventType == TheContractorTheft.EVENT_TYPE then
            local uniqueId = incident.data.vehicleUniqueId
            local vehicleId = uniqueId ~= nil and uniqueId ~= "" and TCVehicleIds.getObjectId(uniqueId) or nil
            incident.data.vehicleId = vehicleId or 0
            if vehicleId ~= nil then
                table.insert(hidden, vehicleId)
            end
        end
    end
    if #hidden > 0 then
        TCEquipmentVisibility.setVisibleEverywhere(hidden, false)
        TCVehicleLock.refresh()
    end
end
