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
-- Filter (086): the player can narrow a placed slot to some store
-- categories (the vehicle's primary one, TCEquipmentClass.getCategory)
-- and/or some of the farm's own machines, from TCParkingSlotActivatable's
-- prompt. An empty filter takes anything of the slot's type. The filter is
-- the slot's own state: saved in the placeable's entry in placeables.xml,
-- streamed with the placeable to a joining client and changed through
-- TCParkingSlotFilterEvent. Machines are object ids in memory and on the
-- wire and uniqueIds in the save; a loaded slot keeps the uniqueIds aside
-- (placeables load before vehicles) until resolveSavedVehicles. How a
-- filter ranks slots is TCParking.getSlotRank.
--
-- Visuals: terrain decals under one node, so they follow slopes. They show
-- while the construction menu is open, or everywhere while the player's
-- showParkingSlots setting is on (086), on each machine by itself and never
-- networked: here at load for a slot that appears while they should show (a
-- preview, a slot just placed, going by vanilla's
-- lastConstructionScreenOpenTime), then by TCParking.updateVisuals for
-- every slot at once.
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

function PlaceableTCParkingSlot.registerSavegameXMLPaths(schema, basePath)
    schema:setXMLSpecializationType("TCParkingSlot")
    schema:register(XMLValueType.STRING, basePath .. ".filter.category(?)#name", "Store category the slot takes (086)")
    schema:register(XMLValueType.STRING, basePath .. ".filter.vehicle(?)#uniqueId", "Machine the slot takes (086)")
    schema:setXMLSpecializationType()
end

function PlaceableTCParkingSlot.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", PlaceableTCParkingSlot)
    SpecializationUtil.registerEventListener(placeableType, "onReadStream", PlaceableTCParkingSlot)
    SpecializationUtil.registerEventListener(placeableType, "onWriteStream", PlaceableTCParkingSlot)
end

function PlaceableTCParkingSlot:onLoad(savegame)
    local xmlFile = self.xmlFile
    local data = {
        startNode = xmlFile:getValue("placeable.parkingSlot#startNode", nil, self.components, self.i3dMappings),
        widthNode = xmlFile:getValue("placeable.parkingSlot#widthNode", nil, self.components, self.i3dMappings),
        heightNode = xmlFile:getValue("placeable.parkingSlot#heightNode", nil, self.components, self.i3dMappings),
        visualsNode = xmlFile:getValue("placeable.parkingSlot#visualsNode", nil, self.components, self.i3dMappings),
        slotType = PlaceableTCParkingSlot.SLOT_TYPE.VEHICLE,
        filter = PlaceableTCParkingSlot.newFilter(),
        -- Server, from a save until resolveSavedVehicles.
        savedVehicleUniqueIds = nil,
    }
    local slotType = xmlFile:getValue("placeable.parkingSlot#slotType")
    if slotType == PlaceableTCParkingSlot.SLOT_TYPE.IMPLEMENT or slotType == PlaceableTCParkingSlot.SLOT_TYPE.HARVESTER then
        data.slotType = slotType
    elseif slotType ~= nil and slotType ~= PlaceableTCParkingSlot.SLOT_TYPE.VEHICLE then
        Logging.xmlWarning(xmlFile, "Unknown parkingSlot#slotType '%s', using 'vehicle'", slotType)
    end
    self[PlaceableTCParkingSlot.KEY] = data

    -- 086: or while the player's showing slots everywhere.
    PlaceableTCParkingSlot.setVisualsVisible(self, g_currentMission.lastConstructionScreenOpenTime > -1 or
        TCParking.getShowSlotsSetting())
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

-- Whether x, z is inside an area from getArea/getAreaFromNodes.
function PlaceableTCParkingSlot.isInArea(area, x, z)
    local dx, dz = x - area.x, z - area.z
    local u = dx * area.uX + dz * area.uZ
    local v = dx * area.vX + dz * area.vZ
    return u >= 0 and u <= area.width and v >= 0 and v <= area.length
end

-- Filter (086) ----------------------------------------------------------------

-- { categories = sorted store category names, vehicleIds = sorted object
-- ids }, plus a set of each for lookups. Only built here, so the lists and
-- the sets always agree.
function PlaceableTCParkingSlot.newFilter(categories, vehicleIds)
    local filter = { categories = {}, vehicleIds = {}, categorySet = {}, vehicleSet = {} }
    for _, name in ipairs(categories or {}) do
        if not filter.categorySet[name] then
            filter.categorySet[name] = true
            table.insert(filter.categories, name)
        end
    end
    for _, vehicleId in ipairs(vehicleIds or {}) do
        if not filter.vehicleSet[vehicleId] then
            filter.vehicleSet[vehicleId] = true
            table.insert(filter.vehicleIds, vehicleId)
        end
    end
    table.sort(filter.categories)
    table.sort(filter.vehicleIds)
    return filter
end

-- Whether the filter narrows anything: a category, or a machine that still
-- exists. A filter of only sold machines takes anything again, rather than
-- nothing until the next save drops them.
function PlaceableTCParkingSlot.isFilterActive(filter)
    if #filter.categories > 0 then
        return true
    end
    for _, vehicleId in ipairs(filter.vehicleIds) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        if vehicle ~= nil and not vehicle.isDeleted then
            return true
        end
    end
    return false
end

function PlaceableTCParkingSlot.getFilter(placeable)
    local data = placeable[PlaceableTCParkingSlot.KEY]
    return data ~= nil and data.filter or PlaceableTCParkingSlot.newFilter()
end

-- Every machine, from TCParkingSlotFilterEvent (and a joining client's
-- stream).
function PlaceableTCParkingSlot.setFilter(placeable, filter)
    local data = placeable[PlaceableTCParkingSlot.KEY]
    if data ~= nil then
        data.filter = filter
        data.savedVehicleUniqueIds = nil
    end
end

function PlaceableTCParkingSlot.writeFilter(streamId, filter)
    streamWriteUInt16(streamId, #filter.categories)
    for _, name in ipairs(filter.categories) do
        streamWriteString(streamId, name)
    end
    streamWriteUInt16(streamId, #filter.vehicleIds)
    for _, vehicleId in ipairs(filter.vehicleIds) do
        streamWriteInt32(streamId, vehicleId)
    end
end

function PlaceableTCParkingSlot.readFilter(streamId)
    local categories = {}
    local count = streamReadUInt16(streamId)
    for _ = 1, count do
        table.insert(categories, streamReadString(streamId))
    end
    local vehicleIds = {}
    count = streamReadUInt16(streamId)
    for _ = 1, count do
        table.insert(vehicleIds, streamReadInt32(streamId))
    end
    return PlaceableTCParkingSlot.newFilter(categories, vehicleIds)
end

-- A joining client gets the filter with the placeable. Its machines go as
-- object ids, so a slot from the save has its uniqueIds resolved first
-- (TheContractor:resolveSavedVehicles runs once; vehicles have all loaded
-- before anyone can join).
function PlaceableTCParkingSlot:onWriteStream(streamId, connection)
    local tc = g_currentMission.TheContractor
    if tc ~= nil and tc.resolveSavedVehicles ~= nil then
        tc:resolveSavedVehicles()
    end
    PlaceableTCParkingSlot.writeFilter(streamId, PlaceableTCParkingSlot.getFilter(self))
end

function PlaceableTCParkingSlot:onReadStream(streamId, connection)
    PlaceableTCParkingSlot.setFilter(self, PlaceableTCParkingSlot.readFilter(streamId))
end

-- Vanilla's placeable save (placeables.xml; key is this placeable's entry
-- plus the specialization's name, and xmlFile vanilla's XMLFile object).
-- Machines are saved by uniqueId; a slot whose saved ones haven't been
-- resolved yet writes them back as they were.
function PlaceableTCParkingSlot:saveToXMLFile(xmlFile, key, usedModNames)
    local data = self[PlaceableTCParkingSlot.KEY]
    if data == nil then
        return
    end
    for i, name in ipairs(data.filter.categories) do
        xmlFile:setString(string.format("%s.filter.category(%d)#name", key, i - 1), name)
    end
    local uniqueIds = data.savedVehicleUniqueIds
    if uniqueIds == nil then
        uniqueIds = {}
        for _, vehicleId in ipairs(data.filter.vehicleIds) do
            local uniqueId = TCVehicleIds.getUniqueId(vehicleId)
            if uniqueId ~= nil then
                table.insert(uniqueIds, uniqueId)
            end
        end
    end
    for i, uniqueId in ipairs(uniqueIds) do
        xmlFile:setString(string.format("%s.filter.vehicle(%d)#uniqueId", key, i - 1), uniqueId)
    end
end

-- Server, as the placeable finishes loading from the save.
function PlaceableTCParkingSlot:loadFromXMLFile(xmlFile, key)
    local data = self[PlaceableTCParkingSlot.KEY]
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
    local uniqueIds = {}
    index = 0
    while true do
        local uniqueId = xmlFile:getString(string.format("%s.filter.vehicle(%d)#uniqueId", key, index))
        if uniqueId == nil then
            break
        end
        table.insert(uniqueIds, uniqueId)
        index = index + 1
    end
    data.filter = PlaceableTCParkingSlot.newFilter(categories)
    data.savedVehicleUniqueIds = #uniqueIds > 0 and uniqueIds or nil
end

-- Server, once vehicles exist (TCParking.resolveSavedVehicles). A machine
-- that's gone drops out of the filter.
function PlaceableTCParkingSlot.resolveSavedVehicles(placeable)
    local data = placeable[PlaceableTCParkingSlot.KEY]
    if data == nil or data.savedVehicleUniqueIds == nil then
        return
    end
    local vehicleIds = TCVehicleIds.resolveList(data.savedVehicleUniqueIds)
    data.filter = PlaceableTCParkingSlot.newFilter(data.filter.categories, vehicleIds)
    data.savedVehicleUniqueIds = nil
end
