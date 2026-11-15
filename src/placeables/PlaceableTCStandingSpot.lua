-- Standing spot (065): a placeable marking where an idle worker is shown
-- standing in the yard (see src/util/TCIdleStaff.lua). Built like a parking
-- slot (062): a marker only, owned by whichever farm placed it, with no
-- state of its own - vanilla saves it, streams it and syncs the owner.
--
-- Footprint: start/width/height nodes, the same as a slot's, so the
-- construction cursor's terrain-hit selection (TCParking.getHitPlaceable)
-- works for it too. The worker stands on standNode, facing its +Z (the
-- arrow).
--
-- Visuals: terrain decals, shown with the parking slots (TCParking.
-- areSlotsShown: the construction menu, or the player's showParkingSlots
-- setting), here at load, then by TCParking.updateVisuals.
--
-- Blocker: a static box around the worker, in the PLAYER collision group
-- with a PLAYER-only mask, so it stops players but not vehicles. It's only
-- in physics while someone's standing on the spot. Every machine decides
-- that for itself (TCIdleStaff), so nothing here is networked. Vanilla adds
-- the whole placeable to physics when it's finalized, so it's taken out
-- again straight after.
--
-- Filter (120): the player can keep a placed spot for some of the farm's
-- staff (workers or office staff, by id), from TCStandingSpotActivatable's
-- prompt. Only they stand there, and they try it before any open spot
-- (TCIdleStaff.assign). It's the spot's own state, like 086's parking slot
-- filter: saved in the placeable's entry in placeables.xml, streamed with
-- the placeable to a joining client and changed through
-- TCStandingSpotFilterEvent. Staff ids never change, so unlike a slot's
-- machines nothing needs resolving after a load.
--
-- Seat spots (153) are standing spots too: their placeable type adds
-- PlaceableTCSeatSpot (the chair) to this specialization, and keeps the
-- blocker in physics (#keepBlocker).
--
-- Farmers' yards (154): a spot can also go on a yard no player owns, by
-- the host or an admin, for the yard's farmer (TCFarmerYardSpots). Placement
-- here: on land no player owns, TCFarmerYardSpots' rules; on owned land,
-- vanilla's.
--
-- Loaded by the base game's placeable specialization manager (modDesc), not
-- sourced by main.lua.

PlaceableTCStandingSpot = {}

PlaceableTCStandingSpot.KEY = "tcStandingSpotData"

function PlaceableTCStandingSpot.prerequisitesPresent(specializations)
    return true
end

function PlaceableTCStandingSpot.registerXMLPaths(schema, basePath)
    schema:setXMLSpecializationType("TCStandingSpot")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".standingSpot#startNode", "Footprint start node")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".standingSpot#widthNode", "Footprint width node")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".standingSpot#heightNode", "Footprint height node")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".standingSpot#visualsNode",
        "Visuals shown only in the construction menu")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".standingSpot#standNode",
        "Where the worker stands, facing +Z")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".standingSpot#blockerNode",
        "Player collision, in physics only while someone's standing there")
    schema:register(XMLValueType.BOOL, basePath .. ".standingSpot#keepBlocker",
        "Keep the blocker in physics even with nobody there (153's seat spots: the chair's always there)", false)
    schema:setXMLSpecializationType()
end

function PlaceableTCStandingSpot.registerSavegameXMLPaths(schema, basePath)
    schema:setXMLSpecializationType("TCStandingSpot")
    schema:register(XMLValueType.INT, basePath .. ".filter.staff(?)#id", "Worker or office member the spot is kept for (120)")
    schema:setXMLSpecializationType()
end

function PlaceableTCStandingSpot.registerOverwrittenFunctions(placeableType)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "getIsOnOwnedFarmland",
        PlaceableTCStandingSpot.getIsOnOwnedFarmland)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "getCanBePlacedAt",
        PlaceableTCStandingSpot.getCanBePlacedAt)
end

function PlaceableTCStandingSpot.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", PlaceableTCStandingSpot)
    SpecializationUtil.registerEventListener(placeableType, "onFinalizePlacement", PlaceableTCStandingSpot)
    SpecializationUtil.registerEventListener(placeableType, "onReadStream", PlaceableTCStandingSpot)
    SpecializationUtil.registerEventListener(placeableType, "onWriteStream", PlaceableTCStandingSpot)
end

function PlaceableTCStandingSpot:onLoad(savegame)
    local xmlFile = self.xmlFile
    local data = {
        startNode = xmlFile:getValue("placeable.standingSpot#startNode", nil, self.components, self.i3dMappings),
        widthNode = xmlFile:getValue("placeable.standingSpot#widthNode", nil, self.components, self.i3dMappings),
        heightNode = xmlFile:getValue("placeable.standingSpot#heightNode", nil, self.components, self.i3dMappings),
        visualsNode = xmlFile:getValue("placeable.standingSpot#visualsNode", nil, self.components, self.i3dMappings),
        standNode = xmlFile:getValue("placeable.standingSpot#standNode", nil, self.components, self.i3dMappings),
        blockerNode = xmlFile:getValue("placeable.standingSpot#blockerNode", nil, self.components, self.i3dMappings),
        isBlockerActive = true,
        keepBlocker = xmlFile:getValue("placeable.standingSpot#keepBlocker", false),
        filter = PlaceableTCStandingSpot.newFilter(),
    }
    self[PlaceableTCStandingSpot.KEY] = data

    PlaceableTCStandingSpot.setVisualsVisible(self, g_currentMission.lastConstructionScreenOpenTime > -1 or
        TCParking.getShowSlotsSetting())
end

function PlaceableTCStandingSpot:onFinalizePlacement()
    PlaceableTCStandingSpot.setBlockerActive(self, false)
end

-- 154: on land no player owns, the yard rules (TCFarmerYardSpots) decide.
function PlaceableTCStandingSpot:getCanBePlacedAt(superFunc, x, y, z, farmId)
    local canPlace, message = superFunc(self, x, y, z, farmId)
    local data = self[PlaceableTCStandingSpot.KEY]
    if not canPlace or data == nil then
        return canPlace, message
    end
    local check = TCFarmerYardSpots.getYardCheck(data, x, z)
    if check ~= nil and check.error ~= nil then
        return false, g_i18n:getText("tc_standingSpot_yard_" .. check.error)
    end
    return canPlace, message
end

-- 154: a yard placement getCanBePlacedAt allowed (it's asked first) needn't
-- be on the player's land.
function PlaceableTCStandingSpot:getIsOnOwnedFarmland(superFunc, x, y, z, rotY)
    local data = self[PlaceableTCStandingSpot.KEY]
    if data ~= nil then
        local check = TCFarmerYardSpots.getYardCheck(data, x, z)
        if check ~= nil then
            return check.error == nil
        end
    end
    return superFunc(self, x, y, z, rotY)
end

function PlaceableTCStandingSpot.isSpot(object)
    return type(object) == "table" and object[PlaceableTCStandingSpot.KEY] ~= nil
end

function PlaceableTCStandingSpot.setVisualsVisible(placeable, isVisible)
    local data = placeable[PlaceableTCStandingSpot.KEY]
    if data ~= nil and data.visualsNode ~= nil and entityExists(data.visualsNode) then
        setVisibility(data.visualsNode, isVisible)
    end
end

function PlaceableTCStandingSpot.setBlockerActive(placeable, isActive)
    local data = placeable[PlaceableTCStandingSpot.KEY]
    if data == nil or data.blockerNode == nil or data.isBlockerActive == isActive or
            not entityExists(data.blockerNode) then
        return
    end
    -- 153: a seat spot's chair is there whether anyone's sitting or not.
    if not isActive and data.keepBlocker then
        return
    end
    if isActive then
        addToPhysics(data.blockerNode)
    else
        removeFromPhysics(data.blockerNode)
    end
    data.isBlockerActive = isActive
end

function PlaceableTCStandingSpot.getArea(placeable)
    return PlaceableTCParkingSlot.getAreaFromNodes(placeable[PlaceableTCStandingSpot.KEY])
end

-- Where the worker stands: x, y, z and the yaw they face. nil if the xml's
-- stand node is missing.
function PlaceableTCStandingSpot.getStandPose(placeable)
    local data = placeable[PlaceableTCStandingSpot.KEY]
    if data == nil or data.standNode == nil or not entityExists(data.standNode) then
        return nil
    end
    local x, y, z = getWorldTranslation(data.standNode)
    local dx, _, dz = localDirectionToWorld(data.standNode, 0, 0, 1)
    return x, y, z, MathUtil.getYRotationFromDirection(dx, dz)
end

-- Filter (120) ----------------------------------------------------------------

-- { staffIds = sorted ids, staffSet = id -> true }. Only built here, so the
-- two always agree.
function PlaceableTCStandingSpot.newFilter(staffIds)
    local filter = { staffIds = {}, staffSet = {} }
    for _, id in ipairs(staffIds or {}) do
        if not filter.staffSet[id] then
            filter.staffSet[id] = true
            table.insert(filter.staffIds, id)
        end
    end
    table.sort(filter.staffIds)
    return filter
end

function PlaceableTCStandingSpot.getFilter(placeable)
    local data = placeable[PlaceableTCStandingSpot.KEY]
    return data ~= nil and data.filter or PlaceableTCStandingSpot.newFilter()
end

-- Every machine, from TCStandingSpotFilterEvent (and a joining client's
-- stream).
function PlaceableTCStandingSpot.setFilter(placeable, filter)
    local data = placeable[PlaceableTCStandingSpot.KEY]
    if data ~= nil then
        data.filter = filter
    end
end

function PlaceableTCStandingSpot.writeFilter(streamId, filter)
    streamWriteUInt16(streamId, #filter.staffIds)
    for _, id in ipairs(filter.staffIds) do
        streamWriteInt32(streamId, id)
    end
end

function PlaceableTCStandingSpot.readFilter(streamId)
    local staffIds = {}
    local count = streamReadUInt16(streamId)
    for _ = 1, count do
        table.insert(staffIds, streamReadInt32(streamId))
    end
    return PlaceableTCStandingSpot.newFilter(staffIds)
end

function PlaceableTCStandingSpot:onWriteStream(streamId, connection)
    PlaceableTCStandingSpot.writeFilter(streamId, PlaceableTCStandingSpot.getFilter(self))
end

function PlaceableTCStandingSpot:onReadStream(streamId, connection)
    PlaceableTCStandingSpot.setFilter(self, PlaceableTCStandingSpot.readFilter(streamId))
end

-- Vanilla's placeable save (placeables.xml, through its XMLFile object, as
-- 086's slots do). Staff who've left are kept: they're harmless (an id is
-- never reused) and TCIdleStaff ignores them.
function PlaceableTCStandingSpot:saveToXMLFile(xmlFile, key, usedModNames)
    local data = self[PlaceableTCStandingSpot.KEY]
    if data == nil then
        return
    end
    for i, id in ipairs(data.filter.staffIds) do
        xmlFile:setInt(string.format("%s.filter.staff(%d)#id", key, i - 1), id)
    end
end

-- Server, as the placeable finishes loading from the save.
function PlaceableTCStandingSpot:loadFromXMLFile(xmlFile, key)
    local data = self[PlaceableTCStandingSpot.KEY]
    if data == nil then
        return
    end
    local staffIds = {}
    local index = 0
    while true do
        local id = xmlFile:getInt(string.format("%s.filter.staff(%d)#id", key, index))
        if id == nil then
            break
        end
        table.insert(staffIds, id)
        index = index + 1
    end
    data.filter = PlaceableTCStandingSpot.newFilter(staffIds)
end
