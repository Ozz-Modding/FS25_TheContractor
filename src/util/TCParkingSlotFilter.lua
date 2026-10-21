-- Parking slot filters (086): what a slot's filter can be set to, checking
-- a requested one on the server, and its summary text. The filter itself
-- lives on the slot (PlaceableTCParkingSlot.getFilter/setFilter) and how it
-- ranks slots is TCParking.getSlotRank. The prompt is
-- TCParkingSlotActivatable and the editor TCParkingSlotDialog.
--
-- A filter picks from two things: store categories (a vehicle's primary
-- one, TCEquipmentClass.getCategory, so a slot can be kept for small
-- tractors) and the farm's own machines of the slot's type. Categories on
-- offer are those of the farm's machines of that type, plus any already in
-- the filter: we can't tell a category's type (vehicle or implement) from
-- the store alone, and the farm's fleet is what's worth sorting anyway.

TCParkingSlotFilter = {}

-- Whether a machine can be named in this slot's filter: one of the farm's
-- own (not a pallet, a courtesy vehicle or anything else on a mission) and
-- the slot's type.
function TCParkingSlotFilter.isEligibleVehicle(vehicle, slot, farmId)
    if vehicle == nil or vehicle.isDeleted or vehicle.isPallet or vehicle.spec_wearable == nil or
        vehicle.getOwnerFarmId == nil or vehicle:getOwnerFarmId() ~= farmId or
        vehicle.propertyState == VehiclePropertyState.MISSION then
        return false
    end
    return PlaceableTCParkingSlot.getSlotTypeFor(vehicle) == PlaceableTCParkingSlot.getSlotType(slot)
end

-- The farm's machines that can be named in this slot's filter.
function TCParkingSlotFilter.getEligibleVehicles(slot, farmId)
    local vehicles = {}
    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if TCParkingSlotFilter.isEligibleVehicle(vehicle, slot, farmId) then
            table.insert(vehicles, vehicle)
        end
    end
    return vehicles
end

-- A store category's shop title, or its name if the store doesn't know it.
function TCParkingSlotFilter.getCategoryTitle(name)
    local category = g_storeManager:getCategoryByName(name)
    return category ~= nil and category.title or name
end

-- Category names on offer for this slot: its type's categories among the
-- farm's machines, plus whatever the filter already has. Sorted by title.
function TCParkingSlotFilter.getCategoryChoices(slot, farmId, filter)
    local seen = {}
    local names = {}
    local function add(name)
        if name ~= nil and not seen[name] then
            seen[name] = true
            table.insert(names, name)
        end
    end
    for _, vehicle in ipairs(TCParkingSlotFilter.getEligibleVehicles(slot, farmId)) do
        add(TCEquipmentClass.getCategory(vehicle))
    end
    for _, name in ipairs(filter ~= nil and filter.categories or {}) do
        add(name)
    end
    table.sort(names, function(a, b)
        return TCParkingSlotFilter.getCategoryTitle(a) < TCParkingSlotFilter.getCategoryTitle(b)
    end)
    return names
end

-- Server: the requested filter with anything that doesn't belong dropped:
-- categories the store doesn't know, and machines that are gone, not the
-- farm's or not the slot's type.
function TCParkingSlotFilter.sanitise(slot, farmId, filter)
    local categories = {}
    for _, name in ipairs(filter.categories) do
        if g_storeManager:getCategoryByName(name) ~= nil then
            table.insert(categories, name)
        end
    end
    local vehicleIds = {}
    for _, vehicleId in ipairs(filter.vehicleIds) do
        if TCParkingSlotFilter.isEligibleVehicle(NetworkUtil.getObject(vehicleId), slot, farmId) then
            table.insert(vehicleIds, vehicleId)
        end
    end
    return PlaceableTCParkingSlot.newFilter(categories, vehicleIds)
end

-- How many names a summary lists before it just counts them.
TCParkingSlotFilter.SUMMARY_MAX_NAMES = 2

-- One line saying what the slot takes: "Any vehicle", or its categories'
-- titles and machines' names ("Small Tractors, Fendt 942 Vario"), or a
-- count once there are more than SUMMARY_MAX_NAMES.
function TCParkingSlotFilter.getSummary(slot, filter)
    if not PlaceableTCParkingSlot.isFilterActive(filter) then
        return g_i18n:getText("tc_parkingSlot_takesAny_" .. PlaceableTCParkingSlot.getSlotType(slot))
    end
    local names = {}
    for _, name in ipairs(filter.categories) do
        table.insert(names, TCParkingSlotFilter.getCategoryTitle(name))
    end
    for _, vehicleId in ipairs(filter.vehicleIds) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        if vehicle ~= nil and not vehicle.isDeleted then
            table.insert(names, vehicle:getFullName())
        end
    end
    if #names > TCParkingSlotFilter.SUMMARY_MAX_NAMES then
        return string.format(g_i18n:getText("tc_parkingSlot_takesCount"), #names)
    end
    return table.concat(names, ", ")
end
