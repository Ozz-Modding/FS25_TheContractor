-- Keeps the player out of equipment that's away with a hired worker: every
-- vehicle on an allocated/in_progress hired-worker job (020), or sitting in
-- a post-job buffer (023), can't be tabbed to or driven. A player
-- self-allocated job is never locked - the player is the one driving it.
--
-- Technique from the user's FS25_UsedEquipmentYards mod
-- (UsedEquipmentYards.applyClientRestrictions): Enterable:setIsTabbable(false)
-- to drop it from the Tab cycle, and a Drivable player-control-allowed
-- function to refuse control. Unlike UEY's, our control function checks the
-- lock live, so it's registered once per vehicle and never needs removing
-- (UEY clears the whole playerControlAllowedFunctions table to undo it,
-- which would also drop anyone else's).
--
-- Both are local per-machine state, never networked, so every machine
-- derives the locked set itself from its own synced job/cooldown data every
-- REFRESH_INTERVAL_MS - same approach as TCFieldAccess.

TCVehicleLock = {}

TCVehicleLock.REFRESH_INTERVAL_MS = 1000

-- vehicleId -> true
local lockedVehicleIds = {}
-- vehicleId -> the vehicle's own isTabbable before we locked it
local originalTabbableById = {}
local controlFunctionRegistered = setmetatable({}, { __mode = "k" })
local accumulatedMs = 0

function TCVehicleLock.reset()
    lockedVehicleIds = {}
    originalTabbableById = {}
    accumulatedMs = 0
end

function TCVehicleLock.isLocked(vehicle)
    local vehicleId = NetworkUtil.getObjectId(vehicle)
    return vehicleId ~= nil and lockedVehicleIds[vehicleId] == true
end

local function isPlayerControlAllowed(vehicle)
    if TCVehicleLock.isLocked(vehicle) then
        return false, g_i18n:getText("tc_vehicleLock_busy")
    end
    return true
end

local function applyLock(vehicleId, isLocked)
    local vehicle = NetworkUtil.getObject(vehicleId)
    if vehicle == nil then
        return
    end

    if vehicle.spec_drivable ~= nil and not controlFunctionRegistered[vehicle] then
        vehicle:registerPlayerVehicleControlAllowedFunction(vehicle, isPlayerControlAllowed)
        controlFunctionRegistered[vehicle] = true
    end

    if vehicle.setIsTabbable ~= nil then
        if isLocked then
            originalTabbableById[vehicleId] = vehicle:getIsTabbable()
            vehicle:setIsTabbable(false)
        else
            vehicle:setIsTabbable(originalTabbableById[vehicleId] ~= false)
            originalTabbableById[vehicleId] = nil
        end
    end
end

function TCVehicleLock.refresh()
    local tc = g_currentMission.TheContractor
    if tc == nil or tc.Jobs == nil or tc.Cooldown == nil then
        return
    end

    local shouldLock = {}
    for _, farm in ipairs(g_farmManager:getFarms()) do
        for _, job in ipairs(tc.Jobs:getAllJobs(farm.farmId)) do
            if job.assignedWorkerId ~= nil and (job.state == TheContractorJob.STATE.ALLOCATED or
                    job.state == TheContractorJob.STATE.IN_PROGRESS) then
                for _, vehicleId in ipairs(job:getAllEquipmentIds()) do
                    shouldLock[vehicleId] = true
                end
            end
        end
    end
    for vehicleId in pairs(tc.Cooldown.vehicleIdsInCooldown) do
        shouldLock[vehicleId] = true
    end

    for vehicleId in pairs(shouldLock) do
        if not lockedVehicleIds[vehicleId] then
            applyLock(vehicleId, true)
        end
    end
    for vehicleId in pairs(lockedVehicleIds) do
        if not shouldLock[vehicleId] then
            applyLock(vehicleId, false)
        end
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
