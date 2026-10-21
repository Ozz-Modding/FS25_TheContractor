-- Parking slot filters (086): a slot narrowed to some store categories or
-- machines. A vehicle tries the slots naming it first, then those taking
-- its category, then unfiltered ones, and never one whose filter shuts it
-- out. The filter saves by uniqueId, streams by object id, and the server
-- only takes the farm's own slot and drops anything that doesn't belong.

local CATEGORIES = {
    TRACTORSS = "Small Tractors",
    TRACTORSL = "Large Tractors",
    TRAILERS = "Trailers",
}

local world

local function setup()
    world = stubs.install()

    getWorldTranslation = function(node) return node.x, 0, node.z end
    getTerrainHeightAtWorldPos = function() return 0 end
    overlapBox = function() end
    g_terrainNode = {}
    MathUtil = {
        vector2Length = function(x, z) return math.sqrt(x * x + z * z) end,
        getYRotationFromDirection = function(dx, dz) return math.atan2(dx, dz) end,
    }
    CollisionFlag = { VEHICLE = 1, PLAYER = 2, DYNAMIC_OBJECT = 4, TREE = 8, STATIC_OBJECT = 16, BUILDING = 32 }
    GuiTopDownCursor = { getHitPlaceable = function() return nil end }
    VehiclePropertyState = { OWNED = 1, LEASED = 2, MISSION = 3 }
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end

    -- configFileName is the category itself, so getItemByXMLFilename can
    -- hand back a store item for it.
    g_storeManager = {
        getItemByXMLFilename = function(_, filename)
            return { categoryName = filename }
        end,
        getCategoryByName = function(_, name)
            local title = CATEGORIES[name]
            return title ~= nil and { name = name, title = title } or nil
        end,
    }

    dofile("src/placeables/PlaceableTCParkingSlot.lua")
    dofile("src/util/TCEquipmentClass.lua")
    dofile("src/util/TCVehicleIds.lua")
    dofile("src/util/TCParking.lua")
    dofile("src/util/TCParkingSlotFilter.lua")
    dofile("src/events/TCParkingSlotFilterEvent.lua")
    g_currentMission.placeableSystem = { placeables = {} }
end

-- A slot with its start corner at x, 0: 4 m x 9 m, room for one tractor.
local function addSlot(farmId, x, slotType)
    local slot = { farmId = farmId }
    slot[PlaceableTCParkingSlot.KEY] = {
        startNode = { x = x, z = 0 },
        widthNode = { x = x + 4, z = 0 },
        heightNode = { x = x, z = 9 },
        slotType = slotType or PlaceableTCParkingSlot.SLOT_TYPE.VEHICLE,
        filter = PlaceableTCParkingSlot.newFilter(),
    }
    function slot:getOwnerFarmId() return self.farmId end
    world:register(slot)
    table.insert(g_currentMission.placeableSystem.placeables, slot)
    return slot
end

-- A farm machine of a store category; drivable unless it's a trailer.
local function addMachine(category, farmId, uniqueId)
    local vehicle = {
        name = category,
        farmId = farmId or 1,
        configFileName = category,
        size = { width = 2.5, length = 5 },
        spec_wearable = {},
        propertyState = VehiclePropertyState.OWNED,
        uniqueId = uniqueId,
    }
    if category ~= "TRAILERS" then
        vehicle.spec_drivable = {}
    end
    function vehicle:getOwnerFarmId() return self.farmId end
    function vehicle:getFullName() return self.name end
    function vehicle:getUniqueId() return self.uniqueId end
    world:register(vehicle)
    table.insert(g_currentMission.vehicleSystem.vehicles, vehicle)
    return vehicle
end

local function setFilter(slot, categories, vehicles)
    local vehicleIds = {}
    for _, vehicle in ipairs(vehicles or {}) do
        table.insert(vehicleIds, vehicle.id)
    end
    PlaceableTCParkingSlot.setFilter(slot, PlaceableTCParkingSlot.newFilter(categories, vehicleIds))
end

-- The x of the slot findSpot parks the vehicle in (each slot is 4 m wide
-- from its start x), or nil.
local function parkedSlotX(vehicle)
    local x = TCParking.findSpot(vehicle, 1)
    return x ~= nil and x - 2 or nil
end

-- Fills a slot, so the overlap test turns everything in it down.
local function fill(slotX)
    local previous = overlapBox
    overlapBox = function(x, y, z, rx, ry, rz, ex, ey, ez, callback, target)
        if x >= slotX and x <= slotX + 4 then
            target[callback](target, {})
        elseif previous ~= nil then
            previous(x, y, z, rx, ry, rz, ex, ey, ez, callback, target)
        end
    end
    g_currentMission.nodeToObject = {}
    g_currentMission.players = {}
    function g_currentMission:getNodeObject() return {} end
end

test("a vehicle tries slots naming it, then its category, then unfiltered", function()
    setup()
    local tractor = addMachine("TRACTORSS")
    -- Placed in the opposite order to their rank.
    addSlot(1, 0)
    local categorySlot = addSlot(1, 10)
    local namedSlot = addSlot(1, 20)
    setFilter(categorySlot, { "TRACTORSS" })
    setFilter(namedSlot, {}, { tractor })

    assertEquals(20, parkedSlotX(tractor), "the slot naming it")
    fill(20)
    assertEquals(10, parkedSlotX(tractor), "then the slot for its category")
    fill(10)
    assertEquals(0, parkedSlotX(tractor), "then the unfiltered slot")
end)

test("a filter shuts out everything else, with no fallback into it", function()
    setup()
    local big = addMachine("TRACTORSL")
    local slot = addSlot(1, 0)
    setFilter(slot, { "TRACTORSS" })
    assertTrue(TCParking.findSpot(big, 1) == nil, "large tractor kept out of a small tractor slot")

    addSlot(1, 10)
    assertEquals(10, parkedSlotX(big), "it takes the unfiltered slot instead")
end)

test("a slot named for one machine turns away another of the same category", function()
    setup()
    local mine = addMachine("TRACTORSS")
    local other = addMachine("TRACTORSS")
    local slot = addSlot(1, 0)
    setFilter(slot, {}, { mine })
    assertEquals(0, parkedSlotX(mine))
    assertTrue(TCParking.findSpot(other, 1) == nil, "only the named machine")
end)

test("a filter of only sold machines takes anything again", function()
    setup()
    local sold = addMachine("TRACTORSL")
    local tractor = addMachine("TRACTORSS")
    local slot = addSlot(1, 0)
    setFilter(slot, {}, { sold })
    assertTrue(TCParking.findSpot(tractor, 1) == nil, "kept for the large tractor")

    world.objects[sold.id] = nil
    assertEquals(0, parkedSlotX(tractor), "free for anything once it's gone")
    assertEquals("Any vehicle", TCParkingSlotFilter.getSummary(slot, PlaceableTCParkingSlot.getFilter(slot)))
end)

test("the summary names a few choices and counts more", function()
    setup()
    local tractor = addMachine("TRACTORSS")
    tractor.name = "Fendt 211"
    local slot = addSlot(1, 0)
    local filter = PlaceableTCParkingSlot.newFilter({ "TRACTORSS" }, { tractor.id })
    assertEquals("Small Tractors, Fendt 211", TCParkingSlotFilter.getSummary(slot, filter))
    filter = PlaceableTCParkingSlot.newFilter({ "TRACTORSS", "TRACTORSL" }, { tractor.id })
    assertEquals("3 choices", TCParkingSlotFilter.getSummary(slot, filter))
    local implementSlot = addSlot(1, 10, PlaceableTCParkingSlot.SLOT_TYPE.IMPLEMENT)
    assertEquals("Any implement", TCParkingSlotFilter.getSummary(implementSlot, PlaceableTCParkingSlot.newFilter()))
end)

test("choices are the farm's machines and categories of the slot's type", function()
    setup()
    addMachine("TRACTORSS")
    addMachine("TRACTORSL")
    addMachine("TRACTORSL", 2)
    addMachine("TRAILERS")
    addMachine("TRACTORSS").isPallet = true
    addMachine("TRACTORSS").propertyState = VehiclePropertyState.MISSION
    local slot = addSlot(1, 0)

    assertEquals(2, #TCParkingSlotFilter.getEligibleVehicles(slot, 1))
    local names = TCParkingSlotFilter.getCategoryChoices(slot, 1, PlaceableTCParkingSlot.newFilter({ "TRAILERS" }))
    -- Sorted by title; a category already in the filter stays on offer.
    assertEquals("TRACTORSL,TRACTORSS,TRAILERS", table.concat(names, ","))
end)

test("the server drops what doesn't belong in a requested filter", function()
    setup()
    local tractor = addMachine("TRACTORSS")
    local otherFarms = addMachine("TRACTORSS", 2)
    local trailer = addMachine("TRAILERS")
    local slot = addSlot(1, 0)
    local filter = TCParkingSlotFilter.sanitise(slot, 1, PlaceableTCParkingSlot.newFilter(
        { "TRACTORSS", "NOSUCHCATEGORY" }, { tractor.id, otherFarms.id, trailer.id, 999 }))
    assertEquals("TRACTORSS", table.concat(filter.categories, ","))
    assertEquals(tostring(tractor.id), table.concat(filter.vehicleIds, ","))
end)

test("the event sets the farm's own slot and broadcasts it, and leaves others alone", function()
    setup()
    local broadcasts = {}
    g_server = { broadcastEvent = function(_, event) table.insert(broadcasts, event) end }
    local tractor = addMachine("TRACTORSS")
    local slot = addSlot(1, 0)
    local otherSlot = addSlot(2, 10)
    local request = PlaceableTCParkingSlot.newFilter({ "TRACTORSS" }, { tractor.id })

    TCParkingSlotFilterEvent.new(otherSlot.id, 1, request):run({})
    assertEquals(0, #broadcasts, "not farm 1's slot")
    assertTrue(not PlaceableTCParkingSlot.isFilterActive(PlaceableTCParkingSlot.getFilter(otherSlot)))

    TCParkingSlotFilterEvent.new(slot.id, 1, request):run({})
    assertEquals(1, #broadcasts)
    local filter = PlaceableTCParkingSlot.getFilter(slot)
    assertEquals("TRACTORSS", table.concat(filter.categories, ","))
    assertTrue(filter.vehicleSet[tractor.id], "machine kept")
end)

test("a filter streams by object id", function()
    setup()
    local stream = world:newStream()
    PlaceableTCParkingSlot.writeFilter(stream, PlaceableTCParkingSlot.newFilter({ "TRAILERS", "TRACTORSS" }, { 7, 3 }))
    local filter = PlaceableTCParkingSlot.readFilter(stream)
    assertEquals("TRACTORSS,TRAILERS", table.concat(filter.categories, ","))
    assertEquals("3,7", table.concat(filter.vehicleIds, ","))
end)

-- vanilla's XMLFile object, as far as the slot uses it.
local function newXMLFile()
    local values = {}
    return {
        values = values,
        setString = function(_, path, value) values[path] = value end,
        getString = function(_, path) return values[path] end,
    }
end

test("a filter saves machines by uniqueId and gets them back once vehicles exist", function()
    setup()
    local tractor = addMachine("TRACTORSS", 1, "vehicle_tractor")
    local sold = addMachine("TRACTORSL", 1, "vehicle_sold")
    g_currentMission.vehicleSystem.getVehicleByUniqueId = function(_, uniqueId)
        for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
            if vehicle.uniqueId == uniqueId and world.objects[vehicle.id] ~= nil then
                return vehicle
            end
        end
        return nil
    end
    local slot = addSlot(1, 0)
    setFilter(slot, { "TRACTORSS" }, { tractor, sold })

    local xmlFile = newXMLFile()
    PlaceableTCParkingSlot.saveToXMLFile(slot, xmlFile, "slot")
    assertEquals("TRACTORSS", xmlFile.values["slot.filter.category(0)#name"])

    -- Load into a fresh slot; the sold machine's gone by the time vehicles load.
    world.objects[sold.id] = nil
    local loaded = addSlot(1, 10)
    PlaceableTCParkingSlot.loadFromXMLFile(loaded, xmlFile, "slot")
    assertEquals(0, #PlaceableTCParkingSlot.getFilter(loaded).vehicleIds, "machines wait for vehicles to load")

    -- Saved again before they're resolved: the uniqueIds go back as they were.
    local again = newXMLFile()
    PlaceableTCParkingSlot.saveToXMLFile(loaded, again, "slot")
    assertEquals("vehicle_sold", again.values["slot.filter.vehicle(1)#uniqueId"])

    TCParking.resolveSavedVehicles()
    local filter = PlaceableTCParkingSlot.getFilter(loaded)
    assertEquals(tostring(tractor.id), table.concat(filter.vehicleIds, ","))
    assertEquals("TRACTORSS", table.concat(filter.categories, ","))
end)
