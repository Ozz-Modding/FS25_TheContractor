-- Yard centre marker (146): where a farmer's yard (108) really is. On a map
-- whose farm buildings are part of the map's own scene, detection sees no
-- buildings, so a declared yard sits on the farmland's label, which can be
-- at its edge or in a building, and 114's standing spots (rings round the
-- middle) find nowhere open. A marker on the yard's farmland is its middle
-- instead (TheContractorYards.detect), ahead of its buildings' middle and
-- the label, and the spots are worked out again from there.
--
-- Placement: only on a farmland that's a yard (detected or declared), that
-- no player owns, with no marker already, and only by the host or an
-- admin, as with the map's Set as farmer yard (117): the yard is shared by
-- every farm. ConstructionBrushPlaceable:verifyPlacement asks the
-- placeable itself, so the rules are its own overrides: getIsOnOwnedFarmland
-- lets it go on land the player doesn't own, and getCanBePlacedAt applies
-- the rules (getPlacementError) with their own message. getIsOnFarmland is
-- false, as UsedEquipmentYards' yard does, so the farmland changing hands
-- doesn't treat it as a building on it.
--
-- A marker only, like the standing spot (065), whose i3d it shares: decals
-- shown with the parking slots (TCParking), nobody standing on it, so its
-- blocker stays out of physics. No state of its own: vanilla saves it,
-- streams it and syncs its owner, and every machine reads the middle from
-- it. The server works the yard's spots out again (Yards:refreshSpots,
-- which tells the clients) when one is placed or removed; after a load,
-- Yards:setUp does it once the placeables are in.
--
-- Loaded by the base game's placeable specialization manager (modDesc), not
-- sourced by main.lua.

PlaceableTCYardCentre = {}

PlaceableTCYardCentre.KEY = "tcYardCentreData"

-- Why a marker can't go somewhere: each its own tc_yardCentre_<value> text.
PlaceableTCYardCentre.PLACEMENT_ERROR = {
    NO_PERMISSION = "noPermission",
    OWNED = "owned",
    NOT_A_YARD = "notYard",
    TAKEN = "taken",
}

-- The placement verdict is asked every frame the cursor is out, and
-- detection walks every placeable, so a farmland's is kept this long (ms).
PlaceableTCYardCentre.CHECK_CACHE_MS = 500

function PlaceableTCYardCentre.prerequisitesPresent(specializations)
    return true
end

function PlaceableTCYardCentre.registerXMLPaths(schema, basePath)
    schema:setXMLSpecializationType("TCYardCentre")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".yardCentre#startNode", "Footprint start node")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".yardCentre#widthNode", "Footprint width node")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".yardCentre#heightNode", "Footprint height node")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".yardCentre#visualsNode",
        "Visuals shown only with the parking slots")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".yardCentre#blockerNode",
        "Collision the shared i3d has, kept out of physics")
    schema:setXMLSpecializationType()
end

function PlaceableTCYardCentre.registerOverwrittenFunctions(placeableType)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "getIsOnOwnedFarmland",
        PlaceableTCYardCentre.getIsOnOwnedFarmland)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "getIsOnFarmland",
        PlaceableTCYardCentre.getIsOnFarmland)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "getCanBePlacedAt",
        PlaceableTCYardCentre.getCanBePlacedAt)
end

function PlaceableTCYardCentre.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", PlaceableTCYardCentre)
    SpecializationUtil.registerEventListener(placeableType, "onFinalizePlacement", PlaceableTCYardCentre)
    SpecializationUtil.registerEventListener(placeableType, "onPreDelete", PlaceableTCYardCentre)
end

function PlaceableTCYardCentre:onLoad(savegame)
    local xmlFile = self.xmlFile
    local data = {
        startNode = xmlFile:getValue("placeable.yardCentre#startNode", nil, self.components, self.i3dMappings),
        widthNode = xmlFile:getValue("placeable.yardCentre#widthNode", nil, self.components, self.i3dMappings),
        heightNode = xmlFile:getValue("placeable.yardCentre#heightNode", nil, self.components, self.i3dMappings),
        visualsNode = xmlFile:getValue("placeable.yardCentre#visualsNode", nil, self.components, self.i3dMappings),
        blockerNode = xmlFile:getValue("placeable.yardCentre#blockerNode", nil, self.components, self.i3dMappings),
        -- The last placement check: { farmlandId, time, error }.
        check = nil,
    }
    self[PlaceableTCYardCentre.KEY] = data

    PlaceableTCYardCentre.setVisualsVisible(self, g_currentMission.lastConstructionScreenOpenTime > -1 or
        TCParking.getShowSlotsSetting())
end

function PlaceableTCYardCentre:onFinalizePlacement()
    local data = self[PlaceableTCYardCentre.KEY]
    if data ~= nil and data.blockerNode ~= nil and entityExists(data.blockerNode) then
        removeFromPhysics(data.blockerNode)
    end
    PlaceableTCYardCentre.refreshYard(self)
end

function PlaceableTCYardCentre:onPreDelete()
    -- isDeleting is set by now, so detection no longer counts this marker.
    if not g_currentMission.isExitingGame then
        PlaceableTCYardCentre.refreshYard(self)
    end
end

-- Server: the yard's spots from its new middle. Before Yards:setUp (a
-- savegame's placeables loading) there's nothing to redo yet.
function PlaceableTCYardCentre.refreshYard(placeable)
    local tc = g_currentMission.TheContractor
    if not placeable.isServer or tc == nil or tc.Yards == nil or not tc.Yards.isSetUp or
            placeable.getFarmlandId == nil then
        return
    end
    local farmlandId = placeable:getFarmlandId()
    if g_farmlandManager:getIsValidFarmlandId(farmlandId) then
        TCLog.info("TheContractor: yard centre marker changed on farmland %d", farmlandId)
        tc.Yards:refreshSpots(farmlandId)
    end
end

function PlaceableTCYardCentre.isMarker(object)
    return type(object) == "table" and object[PlaceableTCYardCentre.KEY] ~= nil
end

-- A marker that counts: placed, not the construction cursor's preview, and
-- not on its way out.
function PlaceableTCYardCentre.isActiveMarker(object)
    if not PlaceableTCYardCentre.isMarker(object) or object.isDeleted or object.isDeleting or
            object.markedForDeletion then
        return false
    end
    return PlaceablePropertyState == nil or object.propertyState ~= PlaceablePropertyState.CONSTRUCTION_PREVIEW
end

function PlaceableTCYardCentre.setVisualsVisible(placeable, isVisible)
    local data = placeable[PlaceableTCYardCentre.KEY]
    if data ~= nil and data.visualsNode ~= nil and entityExists(data.visualsNode) then
        setVisibility(data.visualsNode, isVisible)
    end
end

function PlaceableTCYardCentre.getArea(placeable)
    return PlaceableTCParkingSlot.getAreaFromNodes(placeable[PlaceableTCYardCentre.KEY])
end

-- Placement ---------------------------------------------------------------------

-- The PLACEMENT_ERROR stopping a marker going on a farmland, or nil: the
-- player's permission first, then the land.
function PlaceableTCYardCentre.getPlacementError(canChange, ownerFarmId, isYard, hasMarker)
    local E = PlaceableTCYardCentre.PLACEMENT_ERROR
    if not canChange then
        return E.NO_PERMISSION
    elseif ownerFarmId ~= FarmlandManager.NO_OWNER_FARM_ID then
        return E.OWNED
    elseif not isYard then
        return E.NOT_A_YARD
    elseif hasMarker then
        return E.TAKEN
    end
    return nil
end

-- The live map's verdict for the farmland at x, z (see getPlacementError).
function PlaceableTCYardCentre.getPlacementErrorAt(placeable, x, z)
    local tc = g_currentMission.TheContractor
    local farmlandId = g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)
    if tc == nil or tc.Yards == nil or not g_farmlandManager:getIsValidFarmlandId(farmlandId) then
        return PlaceableTCYardCentre.PLACEMENT_ERROR.NOT_A_YARD
    end
    local placeables = g_currentMission.placeableSystem ~= nil and g_currentMission.placeableSystem.placeables or {}
    return PlaceableTCYardCentre.getPlacementError(TheContractorSettings.getCanLocalPlayerChange(),
        g_farmlandManager:getFarmlandOwner(farmlandId), tc.Yards:getYard(farmlandId) ~= nil,
        TheContractorYards.findCentreMarker(placeables, farmlandId, placeable) ~= nil)
end

function PlaceableTCYardCentre:getCanBePlacedAt(superFunc, x, y, z, farmId)
    local canPlace, message = superFunc(self, x, y, z, farmId)
    if not canPlace then
        return canPlace, message
    end
    local data = self[PlaceableTCYardCentre.KEY]
    if data == nil then
        return canPlace, message
    end
    local farmlandId = g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)
    local now = g_time or 0
    local check = data.check
    if check == nil or check.farmlandId ~= farmlandId or now - check.time > PlaceableTCYardCentre.CHECK_CACHE_MS then
        check = { farmlandId = farmlandId, time = now, error = PlaceableTCYardCentre.getPlacementErrorAt(self, x, z) }
        data.check = check
    end
    if check.error ~= nil then
        return false, g_i18n:getText("tc_yardCentre_" .. check.error)
    end
    return true, nil
end

-- Its own rules (getCanBePlacedAt) decide where it goes, not whose land.
function PlaceableTCYardCentre:getIsOnOwnedFarmland(superFunc, x, y, z, rotY)
    return true
end

function PlaceableTCYardCentre:getIsOnFarmland(superFunc, farmlandId)
    return false
end
