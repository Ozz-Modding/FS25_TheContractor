-- Parking (062): where equipment back from a job is put down. The player
-- marks out the spots by placing Parking Slots (PlaceableTCParkingSlot)
-- from the construction menu; a farm's equipment only ever goes in that
-- farm's slots. The return queue that decides when to park what is
-- TheContractorParking (src/business/Parking.lua) - this is the geometry.
--
-- findSpot works on any rectangle, not just a one-vehicle slot, so a later
-- larger yard-area placeable is only a new i3d/xml. Each slot's rectangle
-- comes from its start/width/height nodes, and a parked vehicle faces from
-- the start edge towards the height node (the slot's arrow). Self-propelled
-- harvesters only go in harvester slots, other drivable machines only in
-- vehicle slots and everything else only in implement slots
-- (PlaceableTCParkingSlot.SLOT_TYPE). The rectangle
-- is scanned in rows as deep as the vehicle, starting at the arrow end, and
-- each row is stepped along. A row or column with room for only one
-- vehicle uses the middle, so a single slot parks its vehicle centred.
-- Since parked vehicles always face the slot's way, a candidate's footprint
-- is inside the rectangle by construction - only the overlap test can turn
-- one down.
--
-- The overlap test is a box the vehicle's own size standing just off the
-- ground, so a slot inside a shed works: the floor is below it and a roof
-- the vehicle fits under is above it, while posts and walls in the way
-- still block. It filters like vanilla's PlacementUtil.collisionTestCallback:
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
TCParking.PLACE_HEIGHT_OFFSET = 0.3
-- The overlap box is the vehicle's own size: its footprint, from
-- GROUND_GAP above the terrain (so a shed's floor slab doesn't count) up to
-- its height plus HEIGHT_CLEARANCE (so a roof it fits under doesn't
-- either). DEFAULT_HEIGHT is for a vehicle with no size.height.
TCParking.GROUND_GAP = 0.2
TCParking.HEIGHT_CLEARANCE = 0.2
TCParking.DEFAULT_HEIGHT = 4

-- FindPlaceTask.DEFAULT_COLLISION_MASK.
TCParking.COLLISION_MASK = CollisionFlag.VEHICLE + CollisionFlag.PLAYER + CollisionFlag.DYNAMIC_OBJECT +
    CollisionFlag.TREE + CollisionFlag.STATIC_OBJECT + CollisionFlag.BUILDING

-- Shop placement minimums, as vanilla's VehicleLoadingData uses for a reset.
TCParking.SHOP_MIN_WIDTH = 4
TCParking.SHOP_MIN_LENGTH = 4
TCParking.SHOP_MIN_HEIGHT = 3
TCParking.SHOP_WIDTH_OFFSET = 1

-- Slots -------------------------------------------------------------------

-- The farm's placed parking slots, in placement order. slotType (a
-- PlaceableTCParkingSlot.SLOT_TYPE) keeps only that kind; nil gives all.
function TCParking.getSlots(farmId, slotType)
    local slots = {}
    local placeableSystem = g_currentMission.placeableSystem
    if placeableSystem == nil then
        return slots
    end
    for _, placeable in ipairs(placeableSystem.placeables) do
        if PlaceableTCParkingSlot.isSlot(placeable) and not placeable.isDeleted and
            not placeable.markedForDeletion and placeable:getOwnerFarmId() == farmId and
            (slotType == nil or PlaceableTCParkingSlot.getSlotType(placeable) == slotType) then
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

-- Whether a width x length x height box standing on the ground, centred on
-- x, z and facing rotY, is clear of vehicles, players and objects.
local function isClear(x, z, rotY, width, length, height)
    local terrainY = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
    local halfHeight = (height + TCParking.HEIGHT_CLEARANCE - TCParking.GROUND_GAP) * 0.5
    overlapHit = false
    overlapBox(x, terrainY + TCParking.GROUND_GAP + halfHeight, z, 0, rotY, 0, width * 0.5, halfHeight, length * 0.5,
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

-- A vehicle's footprint size with clearance, and its height.
local function getFootprint(vehicle)
    local size = vehicle.size or {}
    return (size.width or 3) + TCParking.CLEARANCE, (size.length or 5) + TCParking.CLEARANCE,
        size.widthOffset or 0, size.lengthOffset or 0, size.height or TCParking.DEFAULT_HEIGHT
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
local function findSpotInArea(area, width, length, height, isRandom)
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
        if isClear(x, z, rotY, width, length, height) then
            return x, z, rotY
        end
    end
    return nil
end

-- A free spot for the vehicle in one of farmId's slots of its kind (vehicle,
-- implement or harvester): x, y, z, rotY for setAbsolutePosition, or nil. isRandom
-- (the tcJob park command) picks a random free spot rather than the first.
function TCParking.findSpot(vehicle, farmId, isRandom)
    local width, length, widthOffset, lengthOffset, height = getFootprint(vehicle)
    local slots = TCParking.getSlots(farmId, PlaceableTCParkingSlot.getSlotTypeFor(vehicle))
    if isRandom then
        shuffle(slots)
    end
    for _, slot in ipairs(slots) do
        local area = PlaceableTCParkingSlot.getArea(slot)
        if area ~= nil then
            local x, z, rotY = findSpotInArea(area, width, length, height, isRandom)
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

function TCParking.setSlotsVisible(isVisible)
    local placeableSystem = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if placeableSystem == nil then
        return
    end
    for _, placeable in ipairs(placeableSystem.placeables) do
        if PlaceableTCParkingSlot.isSlot(placeable) then
            PlaceableTCParkingSlot.setVisualsVisible(placeable, isVisible)
        elseif PlaceableTCStandingSpot.isSpot(placeable) then
            -- 065: standing spots share the hook.
            PlaceableTCStandingSpot.setVisualsVisible(placeable, isVisible)
        end
    end
end

local function onConstructionScreenOpen()
    TCParking.setSlotsVisible(true)
end

local function onConstructionScreenClose()
    TCParking.setSlotsVisible(false)
end

-- Hooking ConstructionScreen.onOpen/onClose on the class does nothing: when
-- the screen's xml loads (at game start, before any mod), GuiElement:
-- addCallback copies the target's functions into the screen element's
-- onOpenCallback/onCloseCallback. Opening always goes through the element
-- (Gui:changeScreen calls screenElement:onOpen), so its copy is wrapped.
-- Closing usually doesn't: the screen closes itself with
-- self:changeScreen(nil), and Gui:changeScreen then calls onClose on the
-- controller (sourceScreen) directly, never raising the element's
-- onCloseCallback. So the controller instance, g_constructionScreen, gets
-- its own onClose wrapper too; the element's onCloseCallback is still
-- wrapped for a close with no source screen. The GUI outlives a savegame,
-- so the originals are kept and each load wraps them afresh rather than
-- stacking on the last load's wrapper.
function TCParking.installConstructionScreenHook()
    local element = g_gui ~= nil and g_gui.screens[ConstructionScreen] or nil
    if element == nil then
        Logging.warning("[TheContractor] Construction screen not found; parking slots won't show in it.")
        return
    end
    if element.tcOriginalOnOpenCallback == nil then
        element.tcOriginalOnOpenCallback = element.onOpenCallback or false
        element.tcOriginalOnCloseCallback = element.onCloseCallback or false
    end
    element.onOpenCallback = Utils.appendedFunction(element.tcOriginalOnOpenCallback or nil, onConstructionScreenOpen)
    element.onCloseCallback = Utils.appendedFunction(element.tcOriginalOnCloseCallback or nil, onConstructionScreenClose)

    local screen = g_constructionScreen
    if screen ~= nil then
        if screen.tcOriginalOnClose == nil then
            screen.tcOriginalOnClose = rawget(screen, "onClose") or false
        end
        screen.onClose = Utils.appendedFunction(screen.tcOriginalOnClose or ConstructionScreen.onClose,
            onConstructionScreenClose)
    end
end

-- The slot or standing spot (065) (any farm's) whose rectangle holds x, z,
-- or nil.
function TCParking.getSlotAt(x, z)
    local placeableSystem = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if placeableSystem == nil then
        return nil
    end
    for _, placeable in ipairs(placeableSystem.placeables) do
        if not placeable.isDeleted and not placeable.markedForDeletion then
            local area = nil
            if PlaceableTCParkingSlot.isSlot(placeable) then
                area = PlaceableTCParkingSlot.getArea(placeable)
            elseif PlaceableTCStandingSpot.isSpot(placeable) then
                area = PlaceableTCStandingSpot.getArea(placeable)
            end
            if area ~= nil then
                local dx, dz = x - area.x, z - area.z
                local u = dx * area.uX + dz * area.uZ
                local v = dx * area.vX + dz * area.vZ
                if u >= 0 and u <= area.width and v >= 0 and v <= area.length then
                    return placeable
                end
            end
        end
    end
    return nil
end

-- Selecting a slot or standing spot (to sell it) with the construction
-- cursor. The cursor picks placeables by raycasting for their collision,
-- and a slot's pick box is only a thin slab: slots don't level the ground, so on a slope the
-- terrain covers part or all of it and the ray hits the terrain instead. In
-- selection mode, a terrain hit inside a slot's rectangle counts as that
-- slot.
function TCParking.getHitPlaceable(cursor, superFunc)
    local placeable = superFunc(cursor)
    if placeable == nil and cursor.selectionMode and cursor.currentHitId ~= nil and
        cursor.currentHitId == g_terrainNode and cursor.currentHitX ~= nil then
        placeable = TCParking.getSlotAt(cursor.currentHitX, cursor.currentHitZ)
    end
    return placeable
end

GuiTopDownCursor.getHitPlaceable = Utils.overwrittenFunction(GuiTopDownCursor.getHitPlaceable,
    TCParking.getHitPlaceable)
