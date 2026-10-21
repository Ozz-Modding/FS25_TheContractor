-- The "Set parking slot filter" prompt (086): one activatable for every
-- slot, registered at loadMap. It's offered while the local player is on
-- foot inside one of their farm's parking slots, and opens
-- TCParkingSlotDialog for it. (Slots are only visible in the construction
-- menu unless the player has them showing, TCParking.areSlotsShown.)
--
-- The activatable system picks the nearest offer, so getDistance is the
-- distance to the slot's middle: in a big slot something closer (a door, a
-- vehicle's own prompt) wins.

TCParkingSlotActivatable = {}
local TCParkingSlotActivatable_mt = Class(TCParkingSlotActivatable)

function TCParkingSlotActivatable.new()
    local self = setmetatable({}, TCParkingSlotActivatable_mt)
    self.activateText = g_i18n:getText("tc_parkingSlot_activate")
    -- The slot the player's standing in, from getIsActivatable.
    self.slot = nil
    return self
end

-- Registered once per load, taken away in deleteMap.
function TCParkingSlotActivatable.install()
    local system = g_currentMission.activatableObjectsSystem
    if system == nil then
        return
    end
    TCParkingSlotActivatable.INSTANCE = TCParkingSlotActivatable.new()
    system:addActivatable(TCParkingSlotActivatable.INSTANCE)
end

function TCParkingSlotActivatable.uninstall()
    local activatable = TCParkingSlotActivatable.INSTANCE
    if activatable == nil then
        return
    end
    local system = g_currentMission ~= nil and g_currentMission.activatableObjectsSystem or nil
    if system ~= nil then
        system:removeActivatable(activatable)
    end
    TCParkingSlotActivatable.INSTANCE = nil
end

-- The local farm's slot holding x, z, or nil.
function TCParkingSlotActivatable.getOwnSlotAt(x, z)
    local placeableSystem = g_currentMission.placeableSystem
    if placeableSystem == nil then
        return nil
    end
    local farmId = g_currentMission:getFarmId()
    for _, placeable in ipairs(placeableSystem.placeables) do
        if PlaceableTCParkingSlot.isSlot(placeable) and not placeable.isDeleted and
            not placeable.markedForDeletion and placeable:getOwnerFarmId() == farmId then
            local area = PlaceableTCParkingSlot.getArea(placeable)
            if area ~= nil and PlaceableTCParkingSlot.isInArea(area, x, z) then
                return placeable
            end
        end
    end
    return nil
end

function TCParkingSlotActivatable:getIsActivatable()
    self.slot = nil
    local player = g_localPlayer
    if player == nil or player.getCurrentVehicle == nil or player:getCurrentVehicle() ~= nil then
        return false
    end
    local x, _, z = player:getPosition()
    self.slot = TCParkingSlotActivatable.getOwnSlotAt(x, z)
    return self.slot ~= nil
end

function TCParkingSlotActivatable:getDistance(x, y, z)
    local area = self.slot ~= nil and PlaceableTCParkingSlot.getArea(self.slot) or nil
    if area == nil then
        return math.huge
    end
    local middleX = area.x + (area.uX * area.width + area.vX * area.length) * 0.5
    local middleZ = area.z + (area.uZ * area.width + area.vZ * area.length) * 0.5
    return MathUtil.vector2Length(x - middleX, z - middleZ)
end

function TCParkingSlotActivatable:run()
    if self.slot ~= nil then
        TCParkingSlotDialog.show(self.slot)
    end
end
