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
-- Slot types: each store item is for one kind of machine, set by its xml's
-- parkingSlot#slotType - "harvester" (a drivable machine with a Combine
-- spec: combines, forage and beet harvesters), "vehicle" (anything else
-- drivable: tractors, loaders, other self-propelled machines) or
-- "implement" (everything else: trailers, tools, headers). Each of the three
-- sizes comes as a vehicle and an implement slot, and there's one harvester
-- slot. A slot only ever takes its own kind (TCParking.findSpot); an xml
-- without the attribute is a vehicle slot.
--
-- Visuals: terrain decals under one node, so they follow slopes. They only
-- show while the construction menu is open, on each machine by itself and
-- never networked: here at load for a slot that appears while it's open (a
-- preview, a slot just placed, going by vanilla's
-- lastConstructionScreenOpenTime), then by TCParking's construction-screen
-- hook for every slot at once.
--
-- The slot's pick collision is a thin static box in the ROAD group (one of
-- the construction cursor's raycast groups, so it can be selected and
-- sold) with a collision mask of 0, so nothing physically collides with it.
--
-- Loaded by the base game's placeable specialization manager (modDesc), not
-- sourced by main.lua.

PlaceableTCParkingSlot = {}

PlaceableTCParkingSlot.KEY = "tcParkingSlotData"

PlaceableTCParkingSlot.SLOT_TYPE = {
    VEHICLE = "vehicle",
    IMPLEMENT = "implement",
    HARVESTER = "harvester",
}

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
    schema:register(XMLValueType.STRING, basePath .. ".parkingSlot#slotType",
        "What the slot takes: 'vehicle' (drivable), 'implement' or 'harvester'", PlaceableTCParkingSlot.SLOT_TYPE.VEHICLE)
    schema:setXMLSpecializationType()
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
        slotType = PlaceableTCParkingSlot.SLOT_TYPE.VEHICLE,
    }
    local slotType = xmlFile:getValue("placeable.parkingSlot#slotType")
    if slotType == PlaceableTCParkingSlot.SLOT_TYPE.IMPLEMENT or slotType == PlaceableTCParkingSlot.SLOT_TYPE.HARVESTER then
        data.slotType = slotType
    elseif slotType ~= nil and slotType ~= PlaceableTCParkingSlot.SLOT_TYPE.VEHICLE then
        Logging.xmlWarning(xmlFile, "Unknown parkingSlot#slotType '%s', using 'vehicle'", slotType)
    end
    self[PlaceableTCParkingSlot.KEY] = data

    PlaceableTCParkingSlot.setVisualsVisible(self, g_currentMission.lastConstructionScreenOpenTime > -1)
end

function PlaceableTCParkingSlot.isSlot(object)
    return type(object) == "table" and object[PlaceableTCParkingSlot.KEY] ~= nil
end

-- The slot's SLOT_TYPE.
function PlaceableTCParkingSlot.getSlotType(placeable)
    local data = placeable[PlaceableTCParkingSlot.KEY]
    return data ~= nil and data.slotType or PlaceableTCParkingSlot.SLOT_TYPE.VEHICLE
end

-- The SLOT_TYPE a vehicle parks in: self-propelled harvesters in harvester
-- slots, other drivable machines in vehicle slots, everything else
-- (trailed harvesters too) in implement slots.
function PlaceableTCParkingSlot.getSlotTypeFor(vehicle)
    if vehicle.spec_drivable ~= nil then
        if vehicle.spec_combine ~= nil then
            return PlaceableTCParkingSlot.SLOT_TYPE.HARVESTER
        end
        return PlaceableTCParkingSlot.SLOT_TYPE.VEHICLE
    end
    return PlaceableTCParkingSlot.SLOT_TYPE.IMPLEMENT
end

function PlaceableTCParkingSlot.setVisualsVisible(placeable, isVisible)
    local data = placeable[PlaceableTCParkingSlot.KEY]
    if data ~= nil and data.visualsNode ~= nil and entityExists(data.visualsNode) then
        setVisibility(data.visualsNode, isVisible)
    end
end

-- The slot's rectangle at its current transform: the start corner (x, z),
-- unit axes along its width (uX, uZ) and towards the height node (vX, vZ),
-- and the two lengths. nil if the xml's nodes are missing.
function PlaceableTCParkingSlot.getArea(placeable)
    return PlaceableTCParkingSlot.getAreaFromNodes(placeable[PlaceableTCParkingSlot.KEY])
end

-- The same rectangle from any spec data with start/width/height nodes (065's
-- standing spots use it too).
function PlaceableTCParkingSlot.getAreaFromNodes(data)
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
