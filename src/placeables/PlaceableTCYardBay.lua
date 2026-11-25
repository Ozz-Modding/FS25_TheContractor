-- Yard machine bay (183): where a farmer's machine or trailer comes out in
-- their yard. A yard's standing spots (114) can pass every check and still
-- be somewhere the player can't get a tractor to (behind a fence, between
-- buildings), so the player marks the places that work. Two store items,
-- one spec: the harvester slot's size (8 m x 13.5 m) and a small one
-- (5 m x 11 m). The size is read from the nodes, so the code never knows
-- the two.
--
-- Picking (TCYardBays.pick, server): a machine that fits goes in a free
-- bay, the smallest first, before any standing spot, in the bay's middle
-- and facing from its start edge towards its height node (as a parking
-- slot, 062). Standing spots keep out of bays (TheContractorYards.pickSpots).
--
-- Placement: the yard centre marker's rules (146), but any number on a
-- yard: only on a farmland that's a yard (detected or declared), that no
-- player owns, by the host or an admin (the yard is shared by every farm),
-- and with the whole bay on that farmland (OFF_YARD), so a machine never
-- stands on someone else's land. The corners are read from the preview's
-- nodes: vanilla's brush moves the preview to the cursor
-- (setPreviewPosition) before it asks getCanBePlacedAt, which isn't given
-- the rotation.
--
-- A marker only, sharing a parking slot's i3d shape: decals shown with the
-- parking slots (TCParking). No state of its own: vanilla saves it,
-- streams it and syncs its owner, and only the server picks. The server
-- works the yard's spots out again (PlaceableTCYardCentre.refreshYard) when
-- one is placed or removed. If the yard is ruled out or a player buys the
-- land it stays but does nothing.
--
-- Loaded by the base game's placeable specialization manager (modDesc), not
-- sourced by main.lua.

PlaceableTCYardBay = {}

PlaceableTCYardBay.KEY = "tcYardBayData"

-- Why a bay can't go somewhere: the yard centre marker's PLACEMENT_ERRORs
-- (never TAKEN), plus its own; each a tc_yardBay_<value> text.
PlaceableTCYardBay.OFF_YARD = "offYard"

function PlaceableTCYardBay.prerequisitesPresent(specializations)
    return true
end

function PlaceableTCYardBay.registerXMLPaths(schema, basePath)
    schema:setXMLSpecializationType("TCYardBay")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".yardBay#startNode", "Footprint start node")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".yardBay#widthNode", "Footprint width node")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".yardBay#heightNode",
        "Footprint height node (machines face this way)")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".yardBay#visualsNode",
        "Visuals shown only with the parking slots")
    schema:setXMLSpecializationType()
end

function PlaceableTCYardBay.registerOverwrittenFunctions(placeableType)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "getIsOnOwnedFarmland",
        PlaceableTCYardBay.getIsOnOwnedFarmland)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "getIsOnFarmland",
        PlaceableTCYardBay.getIsOnFarmland)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "getCanBePlacedAt",
        PlaceableTCYardBay.getCanBePlacedAt)
end

function PlaceableTCYardBay.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", PlaceableTCYardBay)
    SpecializationUtil.registerEventListener(placeableType, "onFinalizePlacement", PlaceableTCYardBay)
    SpecializationUtil.registerEventListener(placeableType, "onPreDelete", PlaceableTCYardBay)
end

function PlaceableTCYardBay:onLoad(savegame)
    local xmlFile = self.xmlFile
    self[PlaceableTCYardBay.KEY] = {
        startNode = xmlFile:getValue("placeable.yardBay#startNode", nil, self.components, self.i3dMappings),
        widthNode = xmlFile:getValue("placeable.yardBay#widthNode", nil, self.components, self.i3dMappings),
        heightNode = xmlFile:getValue("placeable.yardBay#heightNode", nil, self.components, self.i3dMappings),
        visualsNode = xmlFile:getValue("placeable.yardBay#visualsNode", nil, self.components, self.i3dMappings),
        -- The last land check: { farmlandId, time, error } (the yard centre
        -- marker's, kept as briefly).
        check = nil,
    }

    PlaceableTCYardBay.setVisualsVisible(self, g_currentMission.lastConstructionScreenOpenTime > -1 or
        TCParking.getShowSlotsSetting())
end

function PlaceableTCYardBay:onFinalizePlacement()
    PlaceableTCYardCentre.refreshYard(self)
end

function PlaceableTCYardBay:onPreDelete()
    -- isDeleting is set by now, so the yard's spots no longer keep out of it.
    if not g_currentMission.isExitingGame then
        PlaceableTCYardCentre.refreshYard(self)
    end
end

function PlaceableTCYardBay.isBay(object)
    return type(object) == "table" and object[PlaceableTCYardBay.KEY] ~= nil
end

-- A bay that counts: placed, not the construction cursor's preview, and not
-- on its way out.
function PlaceableTCYardBay.isActiveBay(object)
    if not PlaceableTCYardBay.isBay(object) or object.isDeleted or object.isDeleting or
            object.markedForDeletion then
        return false
    end
    return PlaceablePropertyState == nil or object.propertyState ~= PlaceablePropertyState.CONSTRUCTION_PREVIEW
end

function PlaceableTCYardBay.setVisualsVisible(placeable, isVisible)
    local data = placeable[PlaceableTCYardBay.KEY]
    if data ~= nil and data.visualsNode ~= nil and entityExists(data.visualsNode) then
        setVisibility(data.visualsNode, isVisible)
    end
end

-- The bay's rectangle where it stands (PlaceableTCParkingSlot.getArea's
-- shape), or nil.
function PlaceableTCYardBay.getArea(placeable)
    return PlaceableTCParkingSlot.getAreaFromNodes(placeable[PlaceableTCYardBay.KEY])
end

-- The four corners of an area, as { x, z }.
function PlaceableTCYardBay.getCorners(area)
    local corners = {}
    for _, at in ipairs({ { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } }) do
        local u, v = area.width * at[1], area.length * at[2]
        table.insert(corners, { x = area.x + area.uX * u + area.vX * v, z = area.z + area.uZ * u + area.vZ * v })
    end
    return corners
end

-- Placement ---------------------------------------------------------------------

-- Whether every corner of the area is on farmlandId.
function PlaceableTCYardBay.isWhollyOn(area, farmlandId)
    for _, corner in ipairs(PlaceableTCYardBay.getCorners(area)) do
        if g_farmlandManager:getFarmlandIdAtWorldPosition(corner.x, corner.z) ~= farmlandId then
            return false
        end
    end
    return true
end

-- What stops the bay going down with its root at x, z (a PLACEMENT_ERROR
-- or OFF_YARD), or nil. The land's verdict is kept briefly per farmland, as
-- the yard centre marker's is; the corners are checked every time, since
-- they turn with the bay.
function PlaceableTCYardBay.getPlacementErrorFor(placeable, x, z)
    local data = placeable[PlaceableTCYardBay.KEY]
    local farmlandId = g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)
    local now = g_time or 0
    local check = data.check
    if check == nil or check.farmlandId ~= farmlandId or now - check.time > PlaceableTCYardCentre.CHECK_CACHE_MS then
        check = { farmlandId = farmlandId, time = now,
            error = PlaceableTCYardCentre.getPlacementErrorAt(placeable, x, z, true) }
        data.check = check
    end
    if check.error ~= nil then
        return check.error
    end
    local area = PlaceableTCYardBay.getArea(placeable)
    if area ~= nil and not PlaceableTCYardBay.isWhollyOn(area, farmlandId) then
        return PlaceableTCYardBay.OFF_YARD
    end
    return nil
end

function PlaceableTCYardBay:getCanBePlacedAt(superFunc, x, y, z, farmId)
    local canPlace, message = superFunc(self, x, y, z, farmId)
    if not canPlace or self[PlaceableTCYardBay.KEY] == nil then
        return canPlace, message
    end
    local placementError = PlaceableTCYardBay.getPlacementErrorFor(self, x, z)
    if placementError ~= nil then
        return false, g_i18n:getText("tc_yardBay_" .. placementError)
    end
    return true, nil
end

-- Its own rules (getCanBePlacedAt) decide where it goes, not whose land.
function PlaceableTCYardBay:getIsOnOwnedFarmland(superFunc, x, y, z, rotY)
    return true
end

function PlaceableTCYardBay:getIsOnFarmland(superFunc, farmlandId)
    return false
end
