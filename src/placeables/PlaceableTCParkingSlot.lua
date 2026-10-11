-- Parking slot (062): a placeable marking where equipment back from a job
-- is parked (see src/util/TCParking.lua and src/business/Parking.lua). It's
-- only a marker - no leveling, no foliage clearing - owned by whichever
-- farm placed it. Vanilla saves it, streams it to clients and syncs the
-- owner, so it has no state of its own here.
--
-- Footprint: three locator nodes, start/width/height, the idiom vanilla's
-- clearArea/levelArea use (and FS22 UsedEquipmentYards' yard extension).
-- Parked vehicles face from the start edge towards the height node.
--
-- Visuals: plain meshes (border strips and an arrow) under one pivot node,
-- tilted and raised to fit the terrain - the plane approach from FS22
-- UsedEquipmentYards' yard extension. They only show while the
-- construction menu is open, on each machine by itself and never
-- networked: here at load for a slot that appears while it's open (a
-- preview, a slot just placed), then by TCParking's screen-change hook for
-- every slot at once. Both read vanilla's lastConstructionScreenOpenTime
-- (g_time while the screen's open, -1 otherwise).
--
-- The slot's pick collision is a thin static box in the ROAD group (one of
-- the construction cursor's raycast groups, so it can be selected and
-- sold) with a collision mask of 0, so nothing physically collides with it.
--
-- Loaded by the base game's placeable specialization manager (modDesc), not
-- sourced by main.lua.

PlaceableTCParkingSlot = {}

PlaceableTCParkingSlot.KEY = "tcParkingSlotData"

function PlaceableTCParkingSlot.prerequisitesPresent(specializations)
    return true
end

function PlaceableTCParkingSlot.registerXMLPaths(schema, basePath)
    schema:setXMLSpecializationType("TCParkingSlot")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".parkingSlot#startNode", "Footprint start node")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".parkingSlot#widthNode", "Footprint width node")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".parkingSlot#heightNode",
        "Footprint height node (parked vehicles face this way)")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".parkingSlot#visualsNode",
        "Visuals shown only in the construction menu")
    schema:setXMLSpecializationType()
end

function PlaceableTCParkingSlot.registerOverwrittenFunctions(placeableType)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "setPreviewPosition",
        PlaceableTCParkingSlot.setPreviewPosition)
end

function PlaceableTCParkingSlot.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", PlaceableTCParkingSlot)
end

function PlaceableTCParkingSlot:onLoad(savegame)
    local xmlFile = self.xmlFile
    local data = {
        startNode = xmlFile:getValue("placeable.parkingSlot#startNode", nil, self.components, self.i3dMappings),
        widthNode = xmlFile:getValue("placeable.parkingSlot#widthNode", nil, self.components, self.i3dMappings),
        heightNode = xmlFile:getValue("placeable.parkingSlot#heightNode", nil, self.components, self.i3dMappings),
        visualsNode = xmlFile:getValue("placeable.parkingSlot#visualsNode", nil, self.components, self.i3dMappings),
    }
    self[PlaceableTCParkingSlot.KEY] = data

    -- A slot placed or loaded from a save is loaded fresh at its final
    -- transform, so it needs its own fit (the preview's doesn't carry over).
    PlaceableTCParkingSlot.setVisualsVisible(self, g_currentMission.lastConstructionScreenOpenTime > -1)
end

-- Every frame while the player drags the preview about. Vanilla only moves
-- and yaws the root node, which would leave the flat visuals poking through
-- a slope.
function PlaceableTCParkingSlot:setPreviewPosition(superFunc, x, y, z, rotX, rotY, rotZ)
    superFunc(self, x, y, z, rotX, rotY, rotZ)
    PlaceableTCParkingSlot.fitVisualsToTerrain(self)
end

function PlaceableTCParkingSlot.isSlot(object)
    return type(object) == "table" and object[PlaceableTCParkingSlot.KEY] ~= nil
end

-- Clearance (metres) kept between the visuals and the terrain.
PlaceableTCParkingSlot.VISUALS_CLEARANCE = 0.05

-- Shown slots are fitted again each time, so they follow any landscaping
-- done since.
function PlaceableTCParkingSlot.setVisualsVisible(placeable, isVisible)
    local data = placeable[PlaceableTCParkingSlot.KEY]
    if data == nil or data.visualsNode == nil or not entityExists(data.visualsNode) then
        return
    end
    if isVisible then
        PlaceableTCParkingSlot.fitVisualsToTerrain(placeable)
    end
    setVisibility(data.visualsNode, isVisible)
end

-- Tilts the visuals pivot (centred on the footprint, unscaled) to the plane
-- through the terrain under the start, width and height corners, then lifts
-- it so neither the fourth corner nor the centre is above it. Not the root
-- node: the footprint nodes have to stay flat for getArea.
--
-- FS22 UsedEquipmentYards passed world directions to setDirection, which
-- works in the parent's space - invisible on its square plane, but this
-- footprint isn't square, so they're converted first (as vanilla's
-- RollingGateAnimation does).
function PlaceableTCParkingSlot.fitVisualsToTerrain(placeable)
    local data = placeable[PlaceableTCParkingSlot.KEY]
    if data == nil or data.visualsNode == nil or data.startNode == nil or data.widthNode == nil or
        data.heightNode == nil or g_terrainNode == nil then
        return
    end

    local sx, _, sz = getWorldTranslation(data.startNode)
    local wx, _, wz = getWorldTranslation(data.widthNode)
    local hx, _, hz = getWorldTranslation(data.heightNode)
    local qx, qz = wx + hx - sx, wz + hz - sz
    local cx, cz = (wx + hx) * 0.5, (wz + hz) * 0.5
    local sy = getTerrainHeightAtWorldPos(g_terrainNode, sx, 0, sz)
    local wy = getTerrainHeightAtWorldPos(g_terrainNode, wx, 0, wz)
    local hy = getTerrainHeightAtWorldPos(g_terrainNode, hx, 0, hz)
    local qy = getTerrainHeightAtWorldPos(g_terrainNode, qx, 0, qz)
    local cy = getTerrainHeightAtWorldPos(g_terrainNode, cx, 0, cz)

    local dirX, dirY, dirZ = hx - sx, hy - sy, hz - sz
    local upX, upY, upZ = MathUtil.crossProduct(dirX, dirY, dirZ, wx - sx, wy - sy, wz - sz)
    local parent = getParent(data.visualsNode)
    local lDirX, lDirY, lDirZ = worldDirectionToLocal(parent, dirX, dirY, dirZ)
    local lUpX, lUpY, lUpZ = worldDirectionToLocal(parent, upX, upY, upZ)
    setDirection(data.visualsNode, lDirX, lDirY, lDirZ, lUpX, lUpY, lUpZ)

    -- The plane's height at the centre, and at the fourth corner.
    local planeY = (wy + hy) * 0.5
    local lift = math.max(0, qy - (wy + hy - sy), cy - planeY)
    setWorldTranslation(data.visualsNode, cx, planeY + lift + PlaceableTCParkingSlot.VISUALS_CLEARANCE, cz)
end

-- The slot's rectangle at its current transform: the start corner (x, z),
-- unit axes along its width (uX, uZ) and towards the height node (vX, vZ),
-- and the two lengths. nil if the xml's nodes are missing.
function PlaceableTCParkingSlot.getArea(placeable)
    local data = placeable[PlaceableTCParkingSlot.KEY]
    if data == nil or data.startNode == nil or data.widthNode == nil or data.heightNode == nil then
        return nil
    end

    local sx, _, sz = getWorldTranslation(data.startNode)
    local wx, _, wz = getWorldTranslation(data.widthNode)
    local hx, _, hz = getWorldTranslation(data.heightNode)
    local width = MathUtil.vector2Length(wx - sx, wz - sz)
    local length = MathUtil.vector2Length(hx - sx, hz - sz)
    if width <= 0 or length <= 0 then
        return nil
    end

    return {
        x = sx,
        z = sz,
        uX = (wx - sx) / width,
        uZ = (wz - sz) / width,
        vX = (hx - sx) / length,
        vZ = (hz - sz) / length,
        width = width,
        length = length,
    }
end
