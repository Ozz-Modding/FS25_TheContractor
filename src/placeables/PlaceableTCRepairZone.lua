-- Repair zone (100): a placeable marking where customers' machines turn up
-- for repair or a service, built like a parking slot (062): a marker only,
-- owned by whichever farm placed it, with the same start/width/height
-- footprint nodes, terrain-decal visuals and thin pick collision.
-- TheContractorRepairContracts decides what arrives and when.
--
-- Bays: the rectangle is split into repairZone#bays equal bays along its
-- width, one customer machine in each. zoneType is "vehicle" (tractors) or
-- "harvester" (self-propelled harvesters), like a parking slot's slotType.
--
-- Filter: the player can keep a zone for some store categories ("small
-- tractors only"), from TCRepairZoneActivatable's prompt. It uses the
-- parking slot's filter shape (PlaceableTCParkingSlot.newFilter) with no
-- machines in it, since customers' machines aren't the farm's. It's the
-- zone's own state, saved in placeables.xml and streamed with the
-- placeable, like 086's.
--
-- Loaded by the base game's placeable specialization manager (modDesc), not
-- sourced by main.lua.

PlaceableTCRepairZone = {}

PlaceableTCRepairZone.KEY = "tcRepairZoneData"

PlaceableTCRepairZone.ZONE_TYPE = {
    VEHICLE = "vehicle",
    HARVESTER = "harvester",
}

function PlaceableTCRepairZone.prerequisitesPresent(specializations)
    return true
end

function PlaceableTCRepairZone.registerXMLPaths(schema, basePath)
    schema:setXMLSpecializationType("TCRepairZone")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".repairZone#startNode", "Footprint start node")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".repairZone#widthNode", "Footprint width node")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".repairZone#heightNode",
        "Footprint height node (machines face this way)")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".repairZone#visualsNode",
        "Visuals shown in the construction menu and with parking slots")
    schema:register(XMLValueType.STRING, basePath .. ".repairZone#zoneType",
        "What the zone takes: 'vehicle' (tractors) or 'harvester'", PlaceableTCRepairZone.ZONE_TYPE.VEHICLE)
    schema:register(XMLValueType.INT, basePath .. ".repairZone#bays", "Bays across its width, one machine each", 1)
    schema:setXMLSpecializationType()
end

function PlaceableTCRepairZone.registerSavegameXMLPaths(schema, basePath)
    schema:setXMLSpecializationType("TCRepairZone")
    schema:register(XMLValueType.STRING, basePath .. ".filter.category(?)#name", "Store category the zone takes")
    schema:setXMLSpecializationType()
end

function PlaceableTCRepairZone.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", PlaceableTCRepairZone)
    SpecializationUtil.registerEventListener(placeableType, "onReadStream", PlaceableTCRepairZone)
    SpecializationUtil.registerEventListener(placeableType, "onWriteStream", PlaceableTCRepairZone)
end

function PlaceableTCRepairZone:onLoad(savegame)
    local xmlFile = self.xmlFile
    local data = {
        startNode = xmlFile:getValue("placeable.repairZone#startNode", nil, self.components, self.i3dMappings),
        widthNode = xmlFile:getValue("placeable.repairZone#widthNode", nil, self.components, self.i3dMappings),
        heightNode = xmlFile:getValue("placeable.repairZone#heightNode", nil, self.components, self.i3dMappings),
        visualsNode = xmlFile:getValue("placeable.repairZone#visualsNode", nil, self.components, self.i3dMappings),
        zoneType = PlaceableTCRepairZone.ZONE_TYPE.VEHICLE,
        bays = math.max(1, xmlFile:getValue("placeable.repairZone#bays", 1) or 1),
        filter = PlaceableTCParkingSlot.newFilter(),
    }
    local zoneType = xmlFile:getValue("placeable.repairZone#zoneType")
    if zoneType == PlaceableTCRepairZone.ZONE_TYPE.HARVESTER then
        data.zoneType = zoneType
    elseif zoneType ~= nil and zoneType ~= PlaceableTCRepairZone.ZONE_TYPE.VEHICLE then
        TCLog.xmlWarning(xmlFile, "Unknown repairZone#zoneType '%s', using 'vehicle'", zoneType)
    end
    self[PlaceableTCRepairZone.KEY] = data

    PlaceableTCRepairZone.setVisualsVisible(self, g_currentMission.lastConstructionScreenOpenTime > -1 or
        TCParking.getShowSlotsSetting())
end

function PlaceableTCRepairZone.isZone(object)
    return type(object) == "table" and object[PlaceableTCRepairZone.KEY] ~= nil
end

function PlaceableTCRepairZone.getZoneType(placeable)
    local data = placeable[PlaceableTCRepairZone.KEY]
    return data ~= nil and data.zoneType or PlaceableTCRepairZone.ZONE_TYPE.VEHICLE
end

function PlaceableTCRepairZone.getBayCount(placeable)
    local data = placeable[PlaceableTCRepairZone.KEY]
    return data ~= nil and data.bays or 1
end

function PlaceableTCRepairZone.setVisualsVisible(placeable, isVisible)
    local data = placeable[PlaceableTCRepairZone.KEY]
    if data ~= nil and data.visualsNode ~= nil and entityExists(data.visualsNode) then
        setVisibility(data.visualsNode, isVisible)
    end
end

-- The whole zone's rectangle (PlaceableTCParkingSlot.getAreaFromNodes'
-- shape), or nil.
function PlaceableTCRepairZone.getArea(placeable)
    return PlaceableTCParkingSlot.getAreaFromNodes(placeable[PlaceableTCRepairZone.KEY])
end

-- Bay `index`'s rectangle, from the zone's: one equal share of its width,
-- the full length. nil for a bay it hasn't got.
function PlaceableTCRepairZone.getBayAreaFrom(area, bays, index)
    if area == nil or index < 1 or index > bays then
        return nil
    end
    local bayWidth = area.width / bays
    return {
        x = area.x + area.uX * bayWidth * (index - 1),
        z = area.z + area.uZ * bayWidth * (index - 1),
        uX = area.uX,
        uZ = area.uZ,
        vX = area.vX,
        vZ = area.vZ,
        width = bayWidth,
        length = area.length,
    }
end

function PlaceableTCRepairZone.getBayArea(placeable, index)
    return PlaceableTCRepairZone.getBayAreaFrom(PlaceableTCRepairZone.getArea(placeable),
        PlaceableTCRepairZone.getBayCount(placeable), index)
end

-- The middle of a rectangle: x, z.
function PlaceableTCRepairZone.getAreaCentre(area)
    return area.x + (area.uX * area.width + area.vX * area.length) * 0.5,
        area.z + (area.uZ * area.width + area.vZ * area.length) * 0.5
end

-- Filter ------------------------------------------------------------------------

function PlaceableTCRepairZone.getFilter(placeable)
    local data = placeable[PlaceableTCRepairZone.KEY]
    return data ~= nil and data.filter or PlaceableTCParkingSlot.newFilter()
end

-- Every machine, from TCRepairZoneFilterEvent (and a joining client's
-- stream). Categories only.
function PlaceableTCRepairZone.setFilter(placeable, filter)
    local data = placeable[PlaceableTCRepairZone.KEY]
    if data ~= nil then
        data.filter = PlaceableTCParkingSlot.newFilter(filter.categories)
    end
end

-- Whether the zone takes a store category (an unfiltered zone takes any).
function PlaceableTCRepairZone.takesCategory(placeable, categoryName)
    local filter = PlaceableTCRepairZone.getFilter(placeable)
    if #filter.categories == 0 then
        return true
    end
    return categoryName ~= nil and filter.categorySet[categoryName] == true
end

function PlaceableTCRepairZone:onWriteStream(streamId, connection)
    PlaceableTCParkingSlot.writeFilter(streamId, PlaceableTCRepairZone.getFilter(self))
end

function PlaceableTCRepairZone:onReadStream(streamId, connection)
    PlaceableTCRepairZone.setFilter(self, PlaceableTCParkingSlot.readFilter(streamId))
end

-- Vanilla's placeable save (placeables.xml, vanilla's XMLFile object).
function PlaceableTCRepairZone:saveToXMLFile(xmlFile, key, usedModNames)
    local data = self[PlaceableTCRepairZone.KEY]
    if data == nil then
        return
    end
    for i, name in ipairs(data.filter.categories) do
        xmlFile:setString(string.format("%s.filter.category(%d)#name", key, i - 1), name)
    end
end

function PlaceableTCRepairZone:loadFromXMLFile(xmlFile, key)
    local data = self[PlaceableTCRepairZone.KEY]
    if data == nil then
        return
    end
    local categories = {}
    local index = 0
    while true do
        local name = xmlFile:getString(string.format("%s.filter.category(%d)#name", key, index))
        if name == nil then
            break
        end
        table.insert(categories, name)
        index = index + 1
    end
    data.filter = PlaceableTCParkingSlot.newFilter(categories)
end
