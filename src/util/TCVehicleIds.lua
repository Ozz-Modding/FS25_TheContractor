-- Vehicle references that outlive a session (same pattern as
-- FS25_UsedEquipmentYards). In memory and on the wire a vehicle is its
-- network object id (NetworkUtil.getObjectId), but those are handed out
-- afresh on every load, so the save stores vehicle:getUniqueId() instead.
--
-- Vehicles load after our loadMap, so a subsystem reads its saved
-- uniqueIds into a holding field and turns them back into object ids in
-- its resolveSavedVehicles, which TheContractor:resolveSavedVehicles calls
-- once vehicles exist. A vehicle that's gone (sold, or removed with its
-- mod) just drops out.

TCVehicleIds = {}

-- The uniqueId of the vehicle behind an object id, or nil if it's gone.
function TCVehicleIds.getUniqueId(vehicleId)
    local vehicle = vehicleId ~= nil and NetworkUtil.getObject(vehicleId) or nil
    if vehicle == nil or vehicle.isDeleted or vehicle.getUniqueId == nil then
        return nil
    end
    return vehicle:getUniqueId()
end

-- Server: the object id of the vehicle with this uniqueId, or nil if it's
-- gone.
function TCVehicleIds.getObjectId(uniqueId)
    if uniqueId == nil then
        return nil
    end
    local vehicle = g_currentMission.vehicleSystem:getVehicleByUniqueId(uniqueId)
    if vehicle == nil then
        return nil
    end
    return NetworkUtil.getObjectId(vehicle)
end

-- Writes a list of object ids as <key>.vehicle(i)#uniqueId, skipping any
-- vehicle that's gone.
function TCVehicleIds.saveList(xmlFile, key, vehicleIds)
    local index = 0
    for _, vehicleId in ipairs(vehicleIds or {}) do
        local uniqueId = TCVehicleIds.getUniqueId(vehicleId)
        if uniqueId ~= nil then
            setXMLString(xmlFile, string.format("%s.vehicle(%d)#uniqueId", key, index), uniqueId)
            index = index + 1
        end
    end
end

-- The uniqueIds saveList wrote, for resolveList once vehicles exist.
function TCVehicleIds.loadList(xmlFile, key)
    local uniqueIds = {}
    local index = 0
    while true do
        local uniqueId = getXMLString(xmlFile, string.format("%s.vehicle(%d)#uniqueId", key, index))
        if uniqueId == nil then
            break
        end
        table.insert(uniqueIds, uniqueId)
        index = index + 1
    end
    return uniqueIds
end

-- A vehicle swapped for a new object (TCVehicleReplace): oldId becomes
-- newId wherever it's in the list, in place. Whether it was there.
function TCVehicleIds.replaceInList(vehicleIds, oldId, newId)
    local found = false
    for i, vehicleId in ipairs(vehicleIds or {}) do
        if vehicleId == oldId then
            vehicleIds[i] = newId
            found = true
        end
    end
    return found
end

-- Likewise for a table keyed by vehicle id: the value moves to newId.
-- Whether there was one.
function TCVehicleIds.replaceKey(map, oldId, newId)
    if map == nil or map[oldId] == nil then
        return false
    end
    map[newId] = map[oldId]
    map[oldId] = nil
    return true
end

-- Likewise for one field of a table (t may be nil). Whether it held oldId.
function TCVehicleIds.replaceField(t, field, oldId, newId)
    if t == nil or t[field] ~= oldId then
        return false
    end
    t[field] = newId
    return true
end

-- Server: object ids for a list of uniqueIds, leaving out any vehicle
-- that's gone.
function TCVehicleIds.resolveList(uniqueIds)
    local vehicleIds = {}
    for _, uniqueId in ipairs(uniqueIds or {}) do
        local vehicleId = TCVehicleIds.getObjectId(uniqueId)
        if vehicleId ~= nil then
            table.insert(vehicleIds, vehicleId)
        end
    end
    return vehicleIds
end
