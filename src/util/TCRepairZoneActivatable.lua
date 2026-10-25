-- The "Set repair zone filter" prompt (100): one activatable for every
-- repair zone, registered at loadMap, offered while the local player is on
-- foot inside one of their farm's zones. It opens 086's
-- TCParkingSlotDialog with ZONE_ADAPTER: store categories only, from the
-- models the zone can get (TheContractorRepairContracts:getCategoryChoices).
-- Built like TCParkingSlotActivatable; the nearer prompt wins.

TCRepairZoneActivatable = {}
local TCRepairZoneActivatable_mt = Class(TCRepairZoneActivatable)

TCRepairZoneActivatable.ZONE_ADAPTER = {
    getTitle = function()
        return g_i18n:getText("tc_repairZone_dialogTitle")
    end,
    getHint = function(zone)
        return g_i18n:getText("tc_repairZone_dialogHint_" .. PlaceableTCRepairZone.getZoneType(zone))
    end,
    getFilter = function(zone)
        return PlaceableTCRepairZone.getFilter(zone)
    end,
    getCategoryChoices = function(zone, farmId, filter)
        return g_currentMission.TheContractor.RepairContracts:getCategoryChoices(zone, filter)
    end,
    getEligibleVehicles = function(zone, farmId)
        return {}
    end,
    getArea = function(zone)
        return PlaceableTCRepairZone.getArea(zone)
    end,
    getSummary = function(zone, filter)
        return TCRepairZoneActivatable.getSummary(zone, filter)
    end,
    send = function(zone, farmId, filter)
        g_client:getServerConnection():sendEvent(TCRepairZoneFilterEvent.new(NetworkUtil.getObjectId(zone), farmId,
            filter))
    end,
}

-- "Any tractor", or the categories' titles, or a count.
function TCRepairZoneActivatable.getSummary(zone, filter)
    if #filter.categories == 0 then
        return g_i18n:getText("tc_repairZone_takesAny_" .. PlaceableTCRepairZone.getZoneType(zone))
    end
    if #filter.categories > TCParkingSlotFilter.SUMMARY_MAX_NAMES then
        return string.format(g_i18n:getText("tc_parkingSlot_takesCount"), #filter.categories)
    end
    local names = {}
    for _, name in ipairs(filter.categories) do
        table.insert(names, TCParkingSlotFilter.getCategoryTitle(name))
    end
    return table.concat(names, ", ")
end

-- Server: the requested filter with categories the store doesn't know
-- dropped.
function TCRepairZoneActivatable.sanitise(filter)
    local categories = {}
    for _, name in ipairs(filter.categories) do
        if g_storeManager:getCategoryByName(name) ~= nil then
            table.insert(categories, name)
        end
    end
    return PlaceableTCParkingSlot.newFilter(categories)
end

function TCRepairZoneActivatable.new()
    local self = setmetatable({}, TCRepairZoneActivatable_mt)
    self.activateText = g_i18n:getText("tc_repairZone_activate")
    self.zone = nil
    return self
end

function TCRepairZoneActivatable.install()
    local system = g_currentMission.activatableObjectsSystem
    if system == nil then
        return
    end
    TCRepairZoneActivatable.INSTANCE = TCRepairZoneActivatable.new()
    system:addActivatable(TCRepairZoneActivatable.INSTANCE)
end

function TCRepairZoneActivatable.uninstall()
    local activatable = TCRepairZoneActivatable.INSTANCE
    if activatable == nil then
        return
    end
    local system = g_currentMission ~= nil and g_currentMission.activatableObjectsSystem or nil
    if system ~= nil then
        system:removeActivatable(activatable)
    end
    TCRepairZoneActivatable.INSTANCE = nil
end

-- The local farm's zone holding x, z, or nil.
function TCRepairZoneActivatable.getOwnZoneAt(x, z)
    for _, zone in ipairs(TheContractorRepairContracts.getZones(g_currentMission:getFarmId())) do
        local area = PlaceableTCRepairZone.getArea(zone)
        if area ~= nil and PlaceableTCParkingSlot.isInArea(area, x, z) then
            return zone
        end
    end
    return nil
end

function TCRepairZoneActivatable:getIsActivatable()
    self.zone = nil
    local player = g_localPlayer
    if player == nil or player.getCurrentVehicle == nil or player:getCurrentVehicle() ~= nil then
        return false
    end
    local x, _, z = player:getPosition()
    self.zone = TCRepairZoneActivatable.getOwnZoneAt(x, z)
    return self.zone ~= nil
end

function TCRepairZoneActivatable:getDistance(x, y, z)
    local area = self.zone ~= nil and PlaceableTCRepairZone.getArea(self.zone) or nil
    if area == nil then
        return math.huge
    end
    local middleX, middleZ = PlaceableTCRepairZone.getAreaCentre(area)
    return MathUtil.vector2Length(x - middleX, z - middleZ)
end

function TCRepairZoneActivatable:run()
    if self.zone ~= nil then
        TCParkingSlotDialog.show(self.zone, TCRepairZoneActivatable.ZONE_ADAPTER)
    end
end
