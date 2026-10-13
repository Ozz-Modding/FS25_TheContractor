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
-- Visuals: terrain decals, shown only while the construction menu is open
-- (here at load, then by TCParking's construction-screen hook).
--
-- Blocker: a static box around the worker, in the PLAYER collision group
-- with a PLAYER-only mask, so it stops players but not vehicles. It's only
-- in physics while someone's standing on the spot. Every machine decides
-- that for itself (TCIdleStaff), so nothing here is networked. Vanilla adds
-- the whole placeable to physics when it's finalized, so it's taken out
-- again straight after.
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
    schema:setXMLSpecializationType()
end

function PlaceableTCStandingSpot.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", PlaceableTCStandingSpot)
    SpecializationUtil.registerEventListener(placeableType, "onFinalizePlacement", PlaceableTCStandingSpot)
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
    }
    self[PlaceableTCStandingSpot.KEY] = data

    PlaceableTCStandingSpot.setVisualsVisible(self, g_currentMission.lastConstructionScreenOpenTime > -1)
end

function PlaceableTCStandingSpot:onFinalizePlacement()
    PlaceableTCStandingSpot.setBlockerActive(self, false)
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
