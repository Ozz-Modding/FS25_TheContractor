-- Keeps the player out of equipment that's away with a hired worker: every
-- vehicle on an allocated/in_progress hired-worker job (020), sitting in a
-- post-job buffer (023), still hidden waiting for a parking space (062),
-- stolen (069), or a lot at an auction (135), can't be tabbed to or driven. A player
-- self-allocated job is never locked - the player is the one driving it.
--
-- Adapted from the user's FS25_UsedEquipmentYards mod
-- (UsedEquipmentYards.applyClientRestrictions): the vehicle's own
-- getIsTabbable is wrapped to drop it from the Tab cycle, and a Drivable
-- player-control-allowed function refuses control. Both check the lock live,
-- so they're installed once per vehicle and never need removing (UEY clears
-- the whole playerControlAllowedFunctions table to undo it, which would also
-- drop anyone else's). Never Enterable:setIsTabbable: vanilla saves that flag
-- with the vehicle, so a machine saved while locked came back un-tabbable for
-- good (repairSavedTabbable heals saves from before this).
--
-- Both are local per-machine state, never networked, so every machine
-- derives the locked set itself from its own synced job/cooldown data every
-- REFRESH_INTERVAL_MS - same approach as TCFieldAccess.
--
-- Selling one is refused too (SellVehicleEvent hook below): the shop's
-- garage list still offers equipment that's hidden away on a job.

TCVehicleLock = {}

TCVehicleLock.REFRESH_INTERVAL_MS = 1000

-- vehicleId -> the l10n key of why it's locked
local lockedVehicleIds = {}

TCVehicleLock.REASON_BUSY = "tc_vehicleLock_busy"
TCVehicleLock.REASON_AUCTION_LOT = "tc_vehicleLock_auctionLot"
local controlFunctionRegistered = setmetatable({}, { __mode = "k" })
local tabbableWrapped = setmetatable({}, { __mode = "k" })
local accumulatedMs = 0

function TCVehicleLock.reset()
    lockedVehicleIds = {}
    accumulatedMs = 0
end

function TCVehicleLock.isLocked(vehicle)
    local vehicleId = NetworkUtil.getObjectId(vehicle)
    return vehicleId ~= nil and lockedVehicleIds[vehicleId] ~= nil
end

local function isPlayerControlAllowed(vehicle)
    local vehicleId = NetworkUtil.getObjectId(vehicle)
    local reason = vehicleId ~= nil and lockedVehicleIds[vehicleId] or nil
    if reason ~= nil then
        return false, g_i18n:getText(reason)
    end
    return true
end

local function applyLock(vehicleId)
    local vehicle = NetworkUtil.getObject(vehicleId)
    if vehicle == nil then
        return
    end

    if vehicle.spec_drivable ~= nil and not controlFunctionRegistered[vehicle] then
        vehicle:registerPlayerVehicleControlAllowedFunction(vehicle, isPlayerControlAllowed)
        controlFunctionRegistered[vehicle] = true
    end

    if vehicle.getIsTabbable ~= nil and not tabbableWrapped[vehicle] then
        local getIsTabbable = vehicle.getIsTabbable
        vehicle.getIsTabbable = function(self, ...)
            if TCVehicleLock.isLocked(self) then
                return false
            end
            return getIsTabbable(self, ...)
        end
        tabbableWrapped[vehicle] = true
    end
end

-- Older versions locked through setIsTabbable(false), which vanilla saved
-- with the vehicle, so a farm's machine saved mid-job loads un-tabbable for
-- good. Puts back the vehicle xml's own isTabbable on farm-owned vehicles
-- (not spectator/NPC ones, which other mods may hide on purpose). Server,
-- once, before any client streams the flag in (resolveSavedVehicles).
function TCVehicleLock.repairSavedTabbable()
    if g_currentMission.vehicleSystem == nil then
        return
    end
    local spectatorFarmId = FarmManager ~= nil and FarmManager.SPECTATOR_FARM_ID or nil
    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        local spec = vehicle.spec_enterable
        local farmId = vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() or 0
        if spec ~= nil and spec.isTabbable == false and vehicle.xmlFile ~= nil and
                farmId ~= 0 and farmId ~= spectatorFarmId and
                vehicle.xmlFile:getValue("vehicle.enterable#isTabbable", true) then
            spec.isTabbable = true
        end
    end
end

-- vehicleId -> the reason's l10n key for everything that should be locked
-- right now, or nil before the subsystems exist.
local function collectLockedVehicleIds()
    local tc = g_currentMission.TheContractor
    if tc == nil or tc.Jobs == nil or tc.Cooldown == nil then
        return nil
    end

    local shouldLock = {}
    for _, farm in ipairs(g_farmManager:getFarms()) do
        for _, job in ipairs(tc.Jobs:getAllJobs(farm.farmId)) do
            if job.assignedWorkerId ~= nil and (job.state == TheContractorJob.STATE.ALLOCATED or
                    job.state == TheContractorJob.STATE.IN_PROGRESS) then
                for _, vehicleId in ipairs(job:getAllEquipmentIds()) do
                    shouldLock[vehicleId] = TCVehicleLock.REASON_BUSY
                end
            end
        end
    end
    for vehicleId in pairs(tc.Cooldown.vehicleIdsInCooldown) do
        shouldLock[vehicleId] = TCVehicleLock.REASON_BUSY
    end
    if tc.Parking ~= nil then
        for vehicleId in pairs(tc.Parking.entryByVehicleId) do
            shouldLock[vehicleId] = TCVehicleLock.REASON_BUSY
        end
    end
    -- 069: stolen, hidden until the police report.
    if tc.Theft ~= nil then
        for vehicleId in pairs(tc.Theft:getStolenVehicleIds()) do
            shouldLock[vehicleId] = TCVehicleLock.REASON_BUSY
        end
    end
    -- 135: an auction's lots, until they're sold (139).
    if tc.AuctionSite ~= nil then
        for vehicleId in pairs(tc.AuctionSite:getLotVehicleIds()) do
            shouldLock[vehicleId] = TCVehicleLock.REASON_AUCTION_LOT
        end
    end
    return shouldLock
end

function TCVehicleLock.refresh()
    local shouldLock = collectLockedVehicleIds()
    if shouldLock == nil then
        return
    end

    -- Every time, not just newly locked ones: a client may not have the
    -- vehicle streamed in yet. Installing is once per vehicle anyway.
    for vehicleId in pairs(shouldLock) do
        applyLock(vehicleId)
    end

    lockedVehicleIds = shouldLock
end

function TCVehicleLock.update(dt)
    accumulatedMs = accumulatedMs + dt
    if accumulatedMs < TCVehicleLock.REFRESH_INTERVAL_MS then
        return
    end
    accumulatedMs = 0

    TCVehicleLock.refresh()
end

-- Selling: the server refuses a locked vehicle, or anything hitched to one,
-- with vanilla's own "in use" reply. Worked out live rather than from the
-- last refresh, so a job allocated a moment ago already counts.
-- getIsInUse isn't hooked for this: our own dispatch's AI start checks it
-- (AIJob:getIsStartable) and would refuse the job's equipment.
function TCVehicleLock.isBusyForSale(vehicle)
    local lockedIds = collectLockedVehicleIds()
    if lockedIds == nil then
        return false
    end
    while vehicle ~= nil do
        local vehicleId = NetworkUtil.getObjectId(vehicle)
        if vehicleId ~= nil and lockedIds[vehicleId] then
            return true
        end
        -- 100: a customer's machine isn't ours to sell.
        if TheContractorRepairContracts ~= nil and TheContractorRepairContracts.isContractVehicle(vehicle) then
            return true
        end
        vehicle = vehicle.getAttacherVehicle ~= nil and vehicle:getAttacherVehicle() or nil
    end
    return false
end

-- The server's half of SellVehicleEvent (a client's request arrives with a
-- client connection, single-player included).
function TCVehicleLock.sellVehicleEventRun(event, superFunc, connection)
    local vehicle = event.vehicle
    if not connection:getIsServer() and vehicle ~= nil and TCVehicleLock.isBusyForSale(vehicle) then
        connection:sendEvent(SellVehicleEvent.newServerToClient(SellVehicleEvent.SELL_VEHICLE_IN_USE, 0,
            event.isDirectSell, vehicle.propertyState == VehiclePropertyState.OWNED, vehicle:getOwnerFarmId()))
        return
    end
    return superFunc(event, connection)
end

if SellVehicleEvent ~= nil and not SellVehicleEvent.tcVehicleLockHookInstalled then
    SellVehicleEvent.run = Utils.overwrittenFunction(SellVehicleEvent.run, TCVehicleLock.sellVehicleEventRun)
    SellVehicleEvent.tcVehicleLockHookInstalled = true
end
