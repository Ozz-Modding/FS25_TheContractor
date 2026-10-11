-- Parking (062): where equipment back from a job is put down. The player
-- marks out the spots by placing Parking Slots (PlaceableTCParkingSlot)
-- from the construction menu; a farm's equipment only ever goes in that
-- farm's slots. The return queue that decides when to park what is
-- TheContractorParking (src/business/Parking.lua) - this is the geometry.
--
-- findSpot works on any rectangle, not just a one-vehicle slot, so a later
-- larger yard-area placeable is only a new i3d/xml. Each slot's rectangle
-- comes from its start/width/height nodes, and a parked vehicle faces from
-- the start edge towards the height node (the slot's arrow). The rectangle
-- is scanned in rows as deep as the vehicle, starting at the arrow end, and
-- each row is stepped along. A row or column with room for only one
-- vehicle uses the middle, so a single slot parks its vehicle centred.
-- Since parked vehicles always face the slot's way, a candidate's footprint
-- is inside the rectangle by construction - only the overlap test can turn
-- one down.
--
-- The overlap test filters like vanilla's PlacementUtil.collisionTestCallback:
-- only hits that resolve to an object (a vehicle, a player, a placeable...)
-- block. Terrain doesn't, and neither do the slots themselves - their pick
-- collision is in the ROAD group, which isn't in the mask, and they're
-- skipped by name too. Hidden equipment is out of physics, so it never
-- blocks either.
--
-- Server only, apart from the construction-menu visibility at the bottom.

TCParking = {}

-- Gap (metres) left around a vehicle's footprint.
TCParking.CLEARANCE = 0.5
-- Step along a row, in metres.
TCParking.ROW_STEP = 0.5
-- How far above the terrain a vehicle is put down (it drops the rest).
TCParking.PLACE_HEIGHT_OFFSET = 0.5
-- Overlap box height, centred like vanilla's getPlace test.
TCParking.TEST_HEIGHT = 10

-- FindPlaceTask.DEFAULT_COLLISION_MASK.
TCParking.COLLISION_MASK = CollisionFlag.VEHICLE + CollisionFlag.PLAYER + CollisionFlag.DYNAMIC_OBJECT +
    CollisionFlag.TREE + CollisionFlag.STATIC_OBJECT + CollisionFlag.BUILDING

-- Shop placement minimums, as vanilla's VehicleLoadingData uses for a reset.
TCParking.SHOP_MIN_WIDTH = 4
TCParking.SHOP_MIN_LENGTH = 4
TCParking.SHOP_MIN_HEIGHT = 3
TCParking.SHOP_WIDTH_OFFSET = 1

-- Slots -------------------------------------------------------------------

-- The farm's placed parking slots, in placement order.
function TCParking.getSlots(farmId)
    local slots = {}
    local placeableSystem = g_currentMission.placeableSystem
    if placeableSystem == nil then
        return slots
    end
    for _, placeable in ipairs(placeableSystem.placeables) do
        if PlaceableTCParkingSlot.isSlot(placeable) and not placeable.isDeleted and
            not placeable.markedForDeletion and placeable:getOwnerFarmId() == farmId then
            table.insert(slots, placeable)
        end
    end
    return slots
end

-- Finding a spot ------------------------------------------------------------

local overlapHit = false

function TCParking:onOverlap(nodeId)
    local mission = g_currentMission
    local object = mission.nodeToObject[nodeId] or mission.players[nodeId] or mission:getNodeObject(nodeId)
    if object == nil or PlaceableTCParkingSlot.isSlot(object) then
        return true
    end
    overlapHit = true
    return false
end

-- Whether a width x length footprint centred on x, z and facing rotY is
-- clear of vehicles, players and objects.
local function isClear(x, z, rotY, width, length)
    local terrainY = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
    overlapHit = false
    overlapBox(x, terrainY + 0.5, z, 0, rotY, 0, width * 0.5, TCParking.TEST_HEIGHT * 0.5, length * 0.5,
        "onOverlap", TCParking, TCParking.COLLISION_MASK, true, true, true, true)
    return not overlapHit
end

-- Positions along a span for something `size` long: the middle if there's
-- room for only one, else every ROW_STEP from one end (or every `step` if
-- given).
local function getPositions(span, size, step)
    if span < size then
        return {}
    end
    if span < size * 2 then
        return { span * 0.5 }
    end
    local positions = {}
    local position = size * 0.5
    while position <= span - size * 0.5 + 0.001 do
        table.insert(positions, position)
        position = position + (step or TCParking.ROW_STEP)
    end
    return positions
end

-- A vehicle's footprint size with clearance.
local function getFootprint(vehicle)
    local size = vehicle.size or {}
    return (size.width or 3) + TCParking.CLEARANCE, (size.length or 5) + TCParking.CLEARANCE,
        size.widthOffset or 0, size.lengthOffset or 0
end

local function shuffle(list)
    for i = #list, 2, -1 do
        local j = math.random(i)
        list[i], list[j] = list[j], list[i]
    end
end

-- The first free spot in one rectangle (PlaceableTCParkingSlot.getArea's
-- shape), as the footprint's centre and the facing. isRandom tries the
-- candidates in random order instead.
local function findSpotInArea(area, width, length, isRandom)
    local rotY = MathUtil.getYRotationFromDirection(area.vX, area.vZ)
    local rows = getPositions(area.length, length, length)
    local columns = getPositions(area.width, width)
    -- Front (arrow) row first.
    local candidates = {}
    for i = #rows, 1, -1 do
        for _, u in ipairs(columns) do
            table.insert(candidates, { u = u, v = rows[i] })
        end
    end
    if isRandom then
        shuffle(candidates)
    end

    for _, candidate in ipairs(candidates) do
        local x = area.x + area.uX * candidate.u + area.vX * candidate.v
        local z = area.z + area.uZ * candidate.u + area.vZ * candidate.v
        if isClear(x, z, rotY, width, length) then
            return x, z, rotY
        end
    end
    return nil
end

-- A free spot for the vehicle in one of farmId's slots: x, y, z, rotY for
-- setAbsolutePosition, or nil. isRandom (the tcJob park command) picks a
-- random free spot rather than the first.
function TCParking.findSpot(vehicle, farmId, isRandom)
    local width, length, widthOffset, lengthOffset = getFootprint(vehicle)
    local slots = TCParking.getSlots(farmId)
    if isRandom then
        shuffle(slots)
    end
    for _, slot in ipairs(slots) do
        local area = PlaceableTCParkingSlot.getArea(slot)
        if area ~= nil then
            local x, z, rotY = findSpotInArea(area, width, length, isRandom)
            if x ~= nil then
                -- The footprint's centre sits widthOffset to the vehicle's
                -- right and lengthOffset ahead of its origin (as in
                -- PlacementUtil.getPlace).
                local originX = x - area.uX * widthOffset - area.vX * lengthOffset
                local originZ = z - area.uZ * widthOffset - area.vZ * lengthOffset
                local y = getTerrainHeightAtWorldPos(g_terrainNode, originX, 0, originZ) + TCParking.PLACE_HEIGHT_OFFSET
                return originX, y, originZ, rotY
            end
        end
    end
    return nil
end

-- A spot at the shop, from the same reset places vanilla's vehicle reset
-- uses, marked used so the next one doesn't land on it. x, y, z, rotY, or
-- nil if the shop's full.
function TCParking.findShopSpot(vehicle)
    local size = vehicle.size or {}
    local placeSize = {
        width = math.max(size.width or 3, TCParking.SHOP_MIN_WIDTH) + TCParking.SHOP_WIDTH_OFFSET,
        length = math.max(size.length or 5, TCParking.SHOP_MIN_LENGTH),
        height = math.max(size.height or 3, TCParking.SHOP_MIN_HEIGHT),
        widthOffset = size.widthOffset or 0,
        lengthOffset = size.lengthOffset or 0,
    }
    local usage = g_currentMission.usedLoadPlaces
    local x, y, z, place, usedWidth = PlacementUtil.getPlace(g_currentMission:getResetPlaces(), placeSize, usage,
        true, true, false, true)
    if x == nil then
        return nil
    end
    PlacementUtil.markPlaceUsed(usage, place, usedWidth)
    return x, y, z, MathUtil.getYRotationFromDirection(place.dirPerpX, place.dirPerpZ)
end

-- Puts a hidden vehicle down and reveals it on every machine. Its position
-- replicates to clients by itself.
function TCParking.placeVehicle(vehicle, x, y, z, rotY)
    vehicle:removeFromPhysics()
    vehicle:setAbsolutePosition(x, y, z, 0, rotY, 0)
    TCEquipmentVisibility.setVisibleEverywhere({ NetworkUtil.getObjectId(vehicle) }, true)
end

-- Construction menu ---------------------------------------------------------
-- Slots only show while the construction menu is open, on each machine by
-- itself - never networked. A slot loaded while the menu's open (a preview,
-- or one just placed) sets itself from lastConstructionScreenOpenTime in
-- its own onLoad.

-- Whether the slots are currently shown, so the hook only acts when the
-- construction menu actually opens or closes.
local slotsShown = false

function TCParking.setSlotsVisible(isVisible)
    local placeableSystem = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if placeableSystem == nil then
        return
    end
    for _, placeable in ipairs(placeableSystem.placeables) do
        if PlaceableTCParkingSlot.isSlot(placeable) then
            PlaceableTCParkingSlot.setVisualsVisible(placeable, isVisible)
        end
    end
end

-- After every screen change. ConstructionScreen:onOpen/onClose set
-- lastConstructionScreenOpenTime inside Gui:changeScreen, so it's up to
-- date by the time this runs.
function TCParking.onScreenChanged()
    if g_currentMission == nil or g_currentMission.lastConstructionScreenOpenTime == nil then
        return
    end
    local isOpen = g_currentMission.lastConstructionScreenOpenTime > -1
    if isOpen == slotsShown then
        return
    end
    slotsShown = isOpen
    TCParking.setSlotsVisible(isOpen)
end

-- Called every loadMap. Every screen change goes through Gui:changeScreen
-- (hooking ConstructionScreen.onOpen/onClose on the class does nothing:
-- the screen element holds copies of them, made when its xml loaded at game
-- start). GUI_AFTER_OPEN/GUI_AFTER_CLOSE wouldn't do either, as they only
-- fire when the GUI as a whole opens or closes, not when one screen
-- replaces another. Flagged on Gui so it goes on once per game session;
-- changeScreen's return value is passed on, as some screens need it.
function TCParking.installConstructionMenuHook()
    slotsShown = false
    if not Gui.tcParkingHookInstalled then
        Gui.changeScreen = Utils.overwrittenFunction(Gui.changeScreen, function(self, superFunc, ...)
            local screenElement = superFunc(self, ...)
            TCParking.onScreenChanged()
            return screenElement
        end)
        Gui.tcParkingHookInstalled = true
    end
end
