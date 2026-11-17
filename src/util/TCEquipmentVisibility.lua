-- Physically hiding/revealing farm equipment that's "away" on contractor
-- work - shared by 023's post-completion buffer (Cooldown.lua) and 020's
-- dispatch staging (Dispatch.lua: hidden while it's rigged up and moved to
-- the job field).
--
-- Technique from the user's FS25_UsedEquipmentYards mod
-- (YardInventory:hideVehicle/placeVehicleInYard): vehicle:removeFromPhysics()
-- + vehicle:setVisibility(false) to hide, the reverse to bring it back.
-- Deliberately skips UEY's detachVehicle step - our equipment stays
-- farm-owned and attached as-is. A ballast weight hitched to a vehicle
-- (TCBallast) is hidden and revealed with it, the vehicle going back into
-- physics first so the weight's joint is rebuilt; the engine wouldn't take
-- it along by itself.
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
--
-- 061: the server also keeps the set of vehicle ids it currently has hidden,
-- whichever path hid them (dispatch, haulage, cooldown, a re-hide after a
-- load), so a client that joins later gets them in initial state. It isn't
-- saved - the resume and re-hide paths rebuild it after a load.

TCEquipmentVisibility = {}

-- Client only: vehicleId -> true (reveal) / false (hide).
local pendingByVehicleId = {}

-- Server only: vehicleId -> true while hidden.
local hiddenVehicleIds = {}

function TCEquipmentVisibility.reset()
    pendingByVehicleId = {}
    hiddenVehicleIds = {}
end

-- Server only (062: what the parking queue takes back).
function TCEquipmentVisibility.isHidden(vehicleId)
    return hiddenVehicleIds[vehicleId] == true
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

-- Anyone sitting in it gets out first, where it stood: each machine puts
-- its own player out (leaveVehicle sends vanilla's VehicleLeaveEvent), the
-- same way vanilla's menus do before a teleport.
function TCEquipmentVisibility.hideVehicle(vehicle)
    local player = g_localPlayer
    if player ~= nil and player.getCurrentVehicle ~= nil and player:getCurrentVehicle() == vehicle then
        player:leaveVehicle()
    end
    if vehicle.stopMotor ~= nil then
        vehicle:stopMotor()
    end
    vehicle:removeFromPhysics()
    vehicle:setVisibility(false)
    TCEquipmentVisibility.setHotspotHidden(vehicle, true)
    for _, weight in ipairs(TCBallast.getWeights(vehicle)) do
        weight:removeFromPhysics()
        weight:setVisibility(false)
        TCEquipmentVisibility.setHotspotHidden(weight, true)
    end
end

function TCEquipmentVisibility.revealVehicle(vehicle)
    -- 105: a tipped trailer is frozen on the server, its body in physics
    -- without its wheels (TheContractorTippedTrailer.setLying). Re-adding
    -- it here would build wheel shapes on a kinematic body.
    if vehicle.tcFrozen then
        vehicle:setVisibility(true)
        TCEquipmentVisibility.setHotspotHidden(vehicle, false)
        return
    end
    vehicle:removeFromPhysics()
    vehicle:setVisibility(true)
    vehicle:addToPhysics()
    TCEquipmentVisibility.setHotspotHidden(vehicle, false)
    -- After the vehicle, so each weight's joint is rebuilt as it goes in.
    for _, weight in ipairs(TCBallast.getWeights(vehicle)) do
        -- A joining client may still have the weight waiting to be hidden.
        local weightId = NetworkUtil.getObjectId(weight)
        if weightId ~= nil then
            pendingByVehicleId[weightId] = nil
        end
        weight:removeFromPhysics()
        weight:setVisibility(true)
        weight:addToPhysics()
        TCEquipmentVisibility.setHotspotHidden(weight, false)
    end
end

-- Map hotspots: a hidden vehicle's would stay on the map where it stood.
-- Vanilla re-reads getIsMapHotspotVisible every update (Vehicle:update ->
-- updateMapHotspot), so the flag is checked there; the hotspot is updated
-- at once too, since a hidden vehicle may not be updating. Local, like the
-- hiding itself: every machine sets it for its own map.
function TCEquipmentVisibility.setHotspotHidden(vehicle, isHidden)
    vehicle.tcIsHotspotHidden = isHidden or nil
    if vehicle.updateMapHotspot ~= nil then
        vehicle:updateMapHotspot()
    end
end

function TCEquipmentVisibility.getIsMapHotspotVisible(vehicle, superFunc)
    if vehicle.tcIsHotspotHidden then
        return false
    end
    return superFunc(vehicle)
end

-- At module scope, guarded so it can't stack: vehicle types pick up
-- Vehicle's functions when they're finalized, after mods' sources run.
if not Vehicle.tcHotspotHookInstalled then
    Vehicle.getIsMapHotspotVisible = Utils.overwrittenFunction(Vehicle.getIsMapHotspotVisible,
        TCEquipmentVisibility.getIsMapHotspotVisible)
    Vehicle.tcHotspotHookInstalled = true
end

-- Hides/reveals every vehicle id. On the server a vehicle that's gone
-- (sold/deleted in the meantime) is skipped - nothing to hide or reveal
-- for it either way. On a client one that isn't ready yet waits (see top).
local function setVisible(vehicleIds, isVisible)
    local isServer = g_currentMission:getIsServer()
    for _, vehicleId in ipairs(vehicleIds) do
        local vehicle = getReadyVehicle(vehicleId)
        if isServer then
            hiddenVehicleIds[vehicleId] = not isVisible or nil
            -- Its weights too, so a client joining mid-job hides them even
            -- before it has the attachment.
            for _, weight in ipairs(vehicle ~= nil and TCBallast.getWeights(vehicle) or {}) do
                local weightId = NetworkUtil.getObjectId(weight)
                if weightId ~= nil then
                    hiddenVehicleIds[weightId] = not isVisible or nil
                end
            end
        end
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

-- 061: a joining client gets every vehicle the server has hidden, as object
-- ids. Anything that's been sold or deleted since drops out here.
function TCEquipmentVisibility.writeInitialClientState(streamId, connection)
    local vehicleIds = {}
    for vehicleId in pairs(hiddenVehicleIds) do
        if getReadyVehicle(vehicleId) ~= nil then
            table.insert(vehicleIds, vehicleId)
        else
            hiddenVehicleIds[vehicleId] = nil
        end
    end

    streamWriteInt32(streamId, #vehicleIds)
    for _, vehicleId in ipairs(vehicleIds) do
        streamWriteInt32(streamId, vehicleId)
    end
end

-- Vehicles still streaming in wait in the pending queue (see top).
function TCEquipmentVisibility.readInitialClientState(streamId, connection)
    local vehicleIds = {}
    local count = streamReadInt32(streamId)
    for i = 1, count do
        vehicleIds[i] = streamReadInt32(streamId)
    end
    TCEquipmentVisibility.hideVehicles(vehicleIds)
end
