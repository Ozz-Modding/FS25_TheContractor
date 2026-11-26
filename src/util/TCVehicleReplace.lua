-- A vehicle swapped for a new object mid-session. We hold vehicles by
-- network object id (TCVehicleIds), but vanilla sometimes deletes a vehicle
-- and loads a copy of it: the copy keeps the uniqueId and gets a new object
-- id. Left alone, everything of ours still holding the old id loses the
-- machine: a harvest job's combine stops being emptied and locked (the
-- issue this was written for), and at the next save the dead id drops out
-- for good.
--
-- The two ways vanilla does it, both on the server:
--   Vehicle:reset        the map's Reset, or vanilla resetting a vehicle
--                        that fell out of the world. Publishes
--                        MessageType.VEHICLE_RESET(old, new); the old one's
--                        deleted after it, or (forceDelete) before the copy
--                        has even loaded.
--   ChangeVehicleConfigEvent  a configuration changed in the shop. Publishes
--                        nothing; the old one's deleted once the copy's in.
-- Both are caught from the removal (VehicleSystem:removeVehicle, while the
-- old one still has its object id): if another vehicle already has its
-- uniqueId, that's the copy. A forceDelete reset has no copy yet then, so
-- the old id waits for VEHICLE_RESET.
--
-- The server swaps the ids in its own state, then every client does the
-- same with TCVehicleReplacedEvent: clients hold the same ids (job
-- equipment, a driver's binding, ...). Anything new that holds a vehicle's
-- object id past the frame it got it adds a remapVehicle(oldId, newId) to
-- its subsystem and its key to SUBSYSTEMS (a module with no instance goes
-- in replace below).

TCVehicleReplace = {}

-- Keys of g_currentMission.TheContractor with a remapVehicle(oldId, newId).
TCVehicleReplace.SUBSYSTEMS = {
    "Jobs", "Cooldown", "Parking", "Logbook", "Drivers", "RepairContracts", "YardBales", "YardHaul",
    "EmergencyRefuel", "AuctionSite", "RandomEvents",
}

-- Server: uniqueId -> object id of a vehicle removed with no copy in its
-- place yet (a forceDelete reset), until its VEHICLE_RESET comes.
local removedIdByUniqueId = {}
-- Server: oldId -> newId already swapped, since a reset is seen twice (its
-- VEHICLE_RESET, then the old one's removal).
local replacedIds = {}

function TCVehicleReplace.install()
    removedIdByUniqueId = {}
    replacedIds = {}
    if MessageType ~= nil and MessageType.VEHICLE_RESET ~= nil then
        g_messageCenter:subscribe(MessageType.VEHICLE_RESET, TCVehicleReplace.onVehicleReset, TCVehicleReplace)
    end
end

function TCVehicleReplace.uninstall()
    g_messageCenter:unsubscribeAll(TCVehicleReplace)
    removedIdByUniqueId = {}
    replacedIds = {}
end

local function isServerRunning()
    return g_currentMission ~= nil and g_currentMission.TheContractor ~= nil and g_currentMission:getIsServer()
end

local function getUniqueId(vehicle)
    return vehicle ~= nil and vehicle.getUniqueId ~= nil and vehicle:getUniqueId() or nil
end

-- Server: vanilla's VEHICLE_RESET.
function TCVehicleReplace:onVehicleReset(oldVehicle, newVehicle)
    if not isServerRunning() or oldVehicle == nil or newVehicle == nil then
        return
    end
    local uniqueId = getUniqueId(oldVehicle)
    local oldId = NetworkUtil.getObjectId(oldVehicle)
    if uniqueId ~= nil then
        oldId = oldId or removedIdByUniqueId[uniqueId]
        removedIdByUniqueId[uniqueId] = nil
    end
    TCVehicleReplace.replaceEverywhere(oldId, NetworkUtil.getObjectId(newVehicle))
end

-- Server, from VehicleSystem:removeVehicle once the vehicle's out of the
-- uniqueId table. oldId: its object id, read before.
function TCVehicleReplace.onVehicleRemoved(vehicleSystem, vehicle, oldId)
    if not isServerRunning() or oldId == nil then
        return
    end
    local uniqueId = getUniqueId(vehicle)
    if uniqueId == nil then
        return
    end
    local copy = vehicleSystem:getVehicleByUniqueId(uniqueId)
    if copy ~= nil and copy ~= vehicle then
        TCVehicleReplace.replaceEverywhere(oldId, NetworkUtil.getObjectId(copy))
    elseif replacedIds[oldId] == nil then
        removedIdByUniqueId[uniqueId] = oldId
    end
end

-- Server: swaps here, then tells the clients.
function TCVehicleReplace.replaceEverywhere(oldId, newId)
    if oldId == nil or newId == nil or oldId == newId or replacedIds[oldId] == newId then
        return
    end
    replacedIds[oldId] = newId
    TCLog.info("TheContractor: vehicle %d was reloaded as %d, following it", oldId, newId)
    TCVehicleReplace.replace(oldId, newId)
    if g_server ~= nil then
        g_server:broadcastEvent(TCVehicleReplacedEvent.new(oldId, newId))
    end
end

-- Every machine: oldId becomes newId in everything of ours.
function TCVehicleReplace.replace(oldId, newId)
    local tc = g_currentMission.TheContractor
    if tc == nil then
        return
    end
    for _, key in ipairs(TCVehicleReplace.SUBSYSTEMS) do
        local subsystem = tc[key]
        if subsystem ~= nil and subsystem.remapVehicle ~= nil then
            subsystem:remapVehicle(oldId, newId)
        end
    end
    TCEquipmentVisibility.remapVehicle(oldId, newId)
    TCParking.remapVehicle(oldId, newId)
end

-- Class-level, as the scripts are sourced (VehicleSystem outlives any one
-- savegame), guarded so it can't stack.
if VehicleSystem ~= nil and VehicleSystem.removeVehicle ~= nil and not VehicleSystem.tcReplaceHookInstalled then
    VehicleSystem.removeVehicle = Utils.overwrittenFunction(VehicleSystem.removeVehicle,
        function(vehicleSystem, superFunc, vehicle, ...)
            local oldId = vehicle ~= nil and isServerRunning() and NetworkUtil.getObjectId(vehicle) or nil
            superFunc(vehicleSystem, vehicle, ...)
            if oldId ~= nil then
                TCVehicleReplace.onVehicleRemoved(vehicleSystem, vehicle, oldId)
            end
        end)
    VehicleSystem.tcReplaceHookInstalled = true
end
