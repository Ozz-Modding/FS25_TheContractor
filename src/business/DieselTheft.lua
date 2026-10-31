-- Diesel theft (078), a random event (068). Thieves come overnight and
-- either drain the yard's diesel tank or siphon a few parked machines. It's
-- found in the morning, between 07:00 and 09:00 (the framework's
-- triggerHours), as staff arrive. The litres are simply gone: no police
-- follow-up, no recovery, no insurance. The next hired-worker job that
-- needs diesel the farm no longer has goes on 063's noStock hold by itself.
--
--   tank     the farm's fullest diesel storage loses TANK_SHARE_MIN-MAX of
--            what's in it, at most TANK_MAX_LITERS
--   siphon   SIPHON_MIN_VEHICLES-MAX of the farm's parked drivables (069's
--            theft eligibility: owned, unhitched, nobody in it, not on a
--            job, in a cooldown, the parking queue, hidden, locked or
--            stolen) with diesel in the tank each lose SIPHON_SHARE_MIN-MAX
--            of it
--
-- canTrigger picks the version (TANK_CHANCE when both are possible) and
-- the stage does the taking, then records liters (and vehicleCount) on the
-- incident's data. No cooldown: it can strike twice in quick succession.
-- No state of its own (like Joyriders, nothing to save or stream): vanilla
-- syncs and saves the fill levels.

TheContractorDieselTheft = {}
TheContractorDieselTheft_mt = Class(TheContractorDieselTheft)

TheContractorDieselTheft.EVENT_TYPE = "dieselTheft"
TheContractorDieselTheft.MESSAGE_KIND = "dieselTheft"

TheContractorDieselTheft.VARIANT = {
    TANK = "tank",
    SIPHON = "siphon",
}

-- About once every 3 years.
TheContractorDieselTheft.RATE_PER_PERIOD = 0.03
TheContractorDieselTheft.TRIGGER_HOURS = { 7, 9 }

TheContractorDieselTheft.TANK_CHANCE = 0.6
TheContractorDieselTheft.TANK_SHARE_MIN = 0.4
TheContractorDieselTheft.TANK_SHARE_MAX = 0.9
TheContractorDieselTheft.TANK_MAX_LITERS = 3000
-- Less than this in the tank isn't worth the trip.
TheContractorDieselTheft.TANK_MIN_LITERS = 100

TheContractorDieselTheft.SIPHON_MIN_VEHICLES = 2
TheContractorDieselTheft.SIPHON_MAX_VEHICLES = 5
TheContractorDieselTheft.SIPHON_SHARE_MIN = 0.5
TheContractorDieselTheft.SIPHON_SHARE_MAX = 0.9
TheContractorDieselTheft.SIPHON_MIN_LITERS = 20

TheContractorDieselTheft.NOTICE_MONTHS = 1

function TheContractorDieselTheft.new()
    local self = {}
    setmetatable(self, TheContractorDieselTheft_mt)
    return self
end

-- Every machine, at load, before the save loads (068). theft (069) is whose
-- eligibility decides which machines can be siphoned.
function TheContractorDieselTheft:register(randomEvents, inbox, theft)
    self.theft = theft

    randomEvents:registerEventType(TheContractorDieselTheft.EVENT_TYPE, {
        l10nKey = "tc_dieselTheft_eventName",
        triggerHours = TheContractorDieselTheft.TRIGGER_HOURS,
        ratePerPeriod = function(farmId)
            return self:getRatePerPeriod(farmId)
        end,
        canTrigger = function(farmId)
            return self:pickVariant(farmId, math.random())
        end,
        stages = {
            { key = "discovered", run = function(incident)
                return self:onDiscovered(incident)
            end },
        },
    })

    inbox:registerMessageKind(TheContractorDieselTheft.MESSAGE_KIND, {
        category = "crime",
        chipTone = "bad",
    })
end

-- What there is to take (server) ----------------------------------------------------

local function randomBetween(min, max)
    return min + math.random() * (max - min)
end

-- The farm's fullest storage holding diesel, and how much is in it, or nil.
-- Storages only, not IBC pallets.
function TheContractorDieselTheft.getTank(farmId)
    local best, bestLevel = nil, 0
    for _, storage in pairs(g_currentMission.storageSystem:getStorages()) do
        if storage.getOwnerFarmId ~= nil and storage:getOwnerFarmId() == farmId and
                storage.getIsFillTypeSupported ~= nil and storage:getIsFillTypeSupported(FillType.DIESEL) then
            local level = storage:getFillLevel(FillType.DIESEL) or 0
            if level > bestLevel then
                best, bestLevel = storage, level
            end
        end
    end
    if best == nil or bestLevel < TheContractorDieselTheft.TANK_MIN_LITERS then
        return nil, 0
    end
    return best, bestLevel
end

-- The farm's parked machines that could be siphoned: { vehicle,
-- fillUnitIndex, level }...
function TheContractorDieselTheft:getSiphonable(farmId)
    local result = {}
    if self.theft == nil then
        return result
    end
    for _, candidate in ipairs(self.theft:getEligibleVehicles(farmId)) do
        local vehicle = candidate.vehicle
        local consumer = TCJobSupplies.getDieselConsumer(vehicle)
        if consumer ~= nil then
            local level = vehicle:getFillUnitFillLevel(consumer.fillUnitIndex) or 0
            if level >= TheContractorDieselTheft.SIPHON_MIN_LITERS then
                table.insert(result, { vehicle = vehicle, fillUnitIndex = consumer.fillUnitIndex, level = level })
            end
        end
    end
    return result
end

function TheContractorDieselTheft:getRatePerPeriod(farmId)
    if TheContractorDieselTheft.getTank(farmId) == nil and #self:getSiphonable(farmId) == 0 then
        return 0
    end
    return TheContractorDieselTheft.RATE_PER_PERIOD
end

-- canTrigger (068): { variant }, or nil with nothing to take. roll (0-1)
-- picks when both are possible.
function TheContractorDieselTheft:pickVariant(farmId, roll)
    local hasTank = TheContractorDieselTheft.getTank(farmId) ~= nil
    local canSiphon = #self:getSiphonable(farmId) > 0
    local variant = nil
    if hasTank and canSiphon then
        variant = roll < TheContractorDieselTheft.TANK_CHANCE and TheContractorDieselTheft.VARIANT.TANK or
            TheContractorDieselTheft.VARIANT.SIPHON
    elseif hasTank then
        variant = TheContractorDieselTheft.VARIANT.TANK
    elseif canSiphon then
        variant = TheContractorDieselTheft.VARIANT.SIPHON
    end
    return variant ~= nil and { variant = variant } or nil
end

-- Taking it (server) ----------------------------------------------------------------

-- Litres taken from the tank.
function TheContractorDieselTheft.drainTank(farmId)
    local storage, level = TheContractorDieselTheft.getTank(farmId)
    if storage == nil then
        return 0
    end
    local share = randomBetween(TheContractorDieselTheft.TANK_SHARE_MIN, TheContractorDieselTheft.TANK_SHARE_MAX)
    local taken = math.floor(math.min(level * share, TheContractorDieselTheft.TANK_MAX_LITERS))
    storage:setFillLevel(level - taken, FillType.DIESEL)
    return taken
end

-- Litres taken, and from how many machines.
function TheContractorDieselTheft:siphonVehicles(farmId)
    local candidates = self:getSiphonable(farmId)
    local wanted = math.random(TheContractorDieselTheft.SIPHON_MIN_VEHICLES,
        TheContractorDieselTheft.SIPHON_MAX_VEHICLES)

    local taken, count = 0, 0
    while #candidates > 0 and count < wanted do
        local candidate = table.remove(candidates, math.random(1, #candidates))
        local share = randomBetween(TheContractorDieselTheft.SIPHON_SHARE_MIN,
            TheContractorDieselTheft.SIPHON_SHARE_MAX)
        local applied = candidate.vehicle:addFillUnitFillLevel(farmId, candidate.fillUnitIndex,
            -math.floor(candidate.level * share), FillType.DIESEL, ToolType.UNDEFINED, nil)
        taken = taken + math.abs(applied or 0)
        count = count + 1
    end
    return math.floor(taken), count
end

-- Stage (server) ----------------------------------------------------------------------

function TheContractorDieselTheft:onDiscovered(incident)
    local farmId = incident.farmId
    local data = incident.data
    local tc = g_currentMission.TheContractor

    local isTank = data.variant == TheContractorDieselTheft.VARIANT.TANK
    if isTank then
        data.liters = TheContractorDieselTheft.drainTank(farmId)
        data.vehicleCount = 0
    else
        data.liters, data.vehicleCount = self:siphonVehicles(farmId)
    end
    TCLog.info("TheContractor: farm %d incident %d: diesel theft (%s), %d l taken%s", farmId, incident.id,
        tostring(data.variant), data.liters,
        isTank and "" or string.format(" from %d machine(s)", data.vehicleCount))

    -- Nothing left to take by the morning: nobody notices.
    if data.liters <= 0 then
        return TheContractorRandomEvents.DONE
    end

    local volume = "$volume_" .. data.liters
    if isTank then
        tc.Inbox:postMessage(farmId, TheContractorDieselTheft.MESSAGE_KIND, "tc_dieselTheft_tankTitle",
            "tc_dieselTheft_tankBody", { volume }, nil, { incidentId = incident.id })
    else
        tc.Inbox:postMessage(farmId, TheContractorDieselTheft.MESSAGE_KIND, "tc_dieselTheft_siphonTitle",
            "tc_dieselTheft_siphonBody", { data.vehicleCount, volume }, nil, { incidentId = incident.id })
    end
    tc.Notices:publish(farmId, string.format(g_i18n:getText("tc_dieselTheft_notice"),
        g_i18n:formatVolume(data.liters, 0)), TheContractorDieselTheft.NOTICE_MONTHS)

    return TheContractorRandomEvents.DONE
end

