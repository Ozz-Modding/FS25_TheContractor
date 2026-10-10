-- Physically hiding/revealing farm equipment that's "away" on contractor
-- work - shared by 023's post-completion buffer (Cooldown.lua) and 020's
-- dispatch staging (Dispatch.lua: hidden while it's rigged up and moved to
-- the job field).
--
-- Technique from the user's FS25_UsedEquipmentYards mod
-- (YardInventory:hideVehicle/placeVehicleInYard): vehicle:removeFromPhysics()
-- + vehicle:setVisibility(false) to hide, the reverse to bring it back.
-- Deliberately skips UEY's detachVehicle step - our equipment stays
-- farm-owned and attached as-is.
--
-- Hiding/revealing is local rendering/physics state the base game never
-- networks on its own (unlike a vehicle's position), so every machine has
-- to apply it itself - see setVisibleEverywhere and
-- TCEquipmentVisibilityEvent.
--
-- On a client a vehicle id may not resolve yet (a joining client still
-- streaming vehicles in), or resolve to a vehicle that's still loading,
-- whose postReadStream would put it back in physics anyway. Those wait in
-- pendingByVehicleId (newest request wins) and update retries them - the
-- pendingClientItems pattern from FS25_UsedEquipmentYards.

TCEquipmentVisibility = {}

-- Client only: vehicleId -> true (reveal) / false (hide).
local pendingByVehicleId = {}

function TCEquipmentVisibility.reset()
    pendingByVehicleId = {}
end

-- The vehicle behind an id once it's ready to hide or reveal, else nil.
local function getReadyVehicle(vehicleId)
    local vehicle = NetworkUtil.getObject(vehicleId)
    if vehicle == nil or vehicle.isDeleted then
        return nil
    end
    if not g_currentMission:getIsServer() and vehicle.getIsSynchronized ~= nil and not vehicle:getIsSynchronized() then
        return nil
    end
    return vehicle
end

function TCEquipmentVisibility.hideVehicle(vehicle)
    if vehicle.stopMotor ~= nil then
        vehicle:stopMotor()
    end
    vehicle:removeFromPhysics()
    vehicle:setVisibility(false)
end

function TCEquipmentVisibility.revealVehicle(vehicle)
    vehicle:removeFromPhysics()
    vehicle:setVisibility(true)
    vehicle:addToPhysics()
end

-- Hides/reveals every vehicle id. On the server a vehicle that's gone
-- (sold/deleted in the meantime) is skipped - nothing to hide or reveal
-- for it either way. On a client one that isn't ready yet waits (see top).
local function setVisible(vehicleIds, isVisible)
    local isServer = g_currentMission:getIsServer()
    for _, vehicleId in ipairs(vehicleIds) do
        local vehicle = getReadyVehicle(vehicleId)
        if vehicle ~= nil then
            pendingByVehicleId[vehicleId] = nil
            if isVisible then
                TCEquipmentVisibility.revealVehicle(vehicle)
            else
                TCEquipmentVisibility.hideVehicle(vehicle)
            end
        elseif not isServer then
            pendingByVehicleId[vehicleId] = isVisible
        end
    end
end

function TCEquipmentVisibility.hideVehicles(vehicleIds)
    setVisible(vehicleIds, false)
end

function TCEquipmentVisibility.revealVehicles(vehicleIds)
    setVisible(vehicleIds, true)
end

-- Every frame from TheContractor:update: retries what was waiting.
function TCEquipmentVisibility.update(dt)
    if next(pendingByVehicleId) == nil then
        return
    end
    for vehicleId, isVisible in pairs(pendingByVehicleId) do
        local vehicle = getReadyVehicle(vehicleId)
        if vehicle ~= nil then
            pendingByVehicleId[vehicleId] = nil
            if isVisible then
                TCEquipmentVisibility.revealVehicle(vehicle)
            else
                TCEquipmentVisibility.hideVehicle(vehicle)
            end
        end
    end
end

-- Server-side: applies locally, then broadcasts to every client (no SP
-- loopback - see src/events/README.md).
function TCEquipmentVisibility.setVisibleEverywhere(vehicleIds, isVisible)
    if isVisible then
        TCEquipmentVisibility.revealVehicles(vehicleIds)
    else
        TCEquipmentVisibility.hideVehicles(vehicleIds)
    end

    if g_server ~= nil then
        g_server:broadcastEvent(TCEquipmentVisibilityEvent.new(vehicleIds, isVisible))
    end
end
