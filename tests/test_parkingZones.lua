-- The dev panel's Parking page: the farm's parking slots and repair zones,
-- where each is in the minimap's coordinates (0, 0 the map's corner), the
-- one nearest the player, and tcDebug removeZone selling one the
-- construction menu can't pick.

local function setup()
    local world = stubs.install()

    -- Footprint nodes are plain tables holding their position.
    getWorldTranslation = function(node) return node.x, 0, node.z end
    MathUtil = {
        vector2Length = function(x, z) return math.sqrt(x * x + z * z) end,
    }
    CollisionFlag = { VEHICLE = 1, PLAYER = 2, DYNAMIC_OBJECT = 4, TREE = 8, STATIC_OBJECT = 16, BUILDING = 32 }
    MoneyType = { SHOP_PROPERTY_SELL = "shopPropertySell" }
    GuiTopDownCursor = { getHitPlaceable = function() return nil end }
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end

    dofile("src/placeables/PlaceableTCParkingSlot.lua")
    dofile("src/placeables/PlaceableTCRepairZone.lua")
    dofile("src/util/TCEquipmentClass.lua")
    dofile("src/util/TCBallast.lua")
    dofile("src/util/TCParking.lua")
    world:load("src/util/TCConsole.lua")
    dofile("src/events/TCParkingNoticeEvent.lua")
    dofile("src/util/TCFolding.lua")
    dofile("src/business/Parking.lua")
    TCConsole.reset()
    TheContractorParking.registerConsoleCommands()

    g_currentMission.terrainSize = 2048
    g_currentMission.placeableSystem = { placeables = {} }
    world.money = {}
    g_currentMission.addMoney = function(_, amount, farmId, moneyType)
        table.insert(world.money, { amount = amount, farmId = farmId, moneyType = moneyType })
    end
    return world
end

-- A placeable with a start corner at x, z, 4 m wide and 9 m long: a
-- parking slot (slotType) or a repair zone (zoneType).
local function addZone(world, def)
    local placeable = { id = world.nextObjectId, farmId = def.farmId or 1, name = def.name or "Zone",
        sellPrice = def.sellPrice or 0 }
    world.nextObjectId = world.nextObjectId + 1
    world.objects[placeable.id] = placeable
    local data = {
        startNode = { x = def.x, z = def.z },
        widthNode = { x = def.x + 4, z = def.z },
        heightNode = { x = def.x, z = def.z + 9 },
    }
    if def.zoneType ~= nil then
        data.zoneType = def.zoneType
        data.bays = 1
        placeable[PlaceableTCRepairZone.KEY] = data
    else
        data.slotType = def.slotType or PlaceableTCParkingSlot.SLOT_TYPE.VEHICLE
        placeable[PlaceableTCParkingSlot.KEY] = data
    end
    function placeable:getOwnerFarmId() return self.farmId end
    function placeable:getName() return self.name end
    function placeable:getSellPrice() return self.sellPrice, false end
    function placeable:onSell() self.sold = true end
    function placeable:delete() self.isDeleted = true end
    table.insert(g_currentMission.placeableSystem.placeables, placeable)
    return placeable
end

local function removeZone(farmId, args)
    return TCConsole.groups.debug.subcommands.removezone.run(farmId, args)
end

test("a farm's slots and zones are listed by id, at the minimap's coordinates", function()
    local world = setup()
    local slot = addZone(world, { x = -100, z = 50 })
    addZone(world, { x = 0, z = 0, farmId = 2 })
    local zone = addZone(world, { x = 200, z = -300, zoneType = PlaceableTCRepairZone.ZONE_TYPE.VEHICLE })
    table.insert(g_currentMission.placeableSystem.placeables, { id = 99, getOwnerFarmId = function() return 1 end })

    local rows = TCParking.getZoneRows(1)
    assertEquals(#rows, 2, "the farm's own slot and zone, nothing else")
    assertEquals(rows[1].placeable, slot, "slot first, by id")
    assertEquals(rows[2].placeable, zone, "then the repair zone")
    -- The slot's middle is (-98, 54.5); half the 2048 m map is added.
    assertNear(rows[1].mapX, 926, 0.001, "slot x")
    assertNear(rows[1].mapZ, 1078.5, 0.001, "slot z")
    assertNear(rows[2].mapX, 1226, 0.001, "zone x")
    assertNear(rows[2].mapZ, 728.5, 0.001, "zone z")
    assertEquals(rows[1].distance, nil, "no distance without a position")
end)

test("the one nearest the player is picked, whatever the order", function()
    local world = setup()
    addZone(world, { x = 0, z = 0 })
    addZone(world, { x = 500, z = 500 })
    addZone(world, { x = 100, z = 0 })

    local rows, nearestIndex = TCParking.getZoneRows(1, 110, 10)
    assertEquals(nearestIndex, 3, "the third is beside the player")
    assertNear(rows[3].distance, math.sqrt(8 * 8 + 5.5 * 5.5), 0.001, "distance to its middle")

    local _, noPosition = TCParking.getZoneRows(1)
    assertEquals(noPosition, nil, "none nearest without a position")
end)

test("a deleted slot isn't listed", function()
    local world = setup()
    addZone(world, { x = 0, z = 0 }).isDeleted = true
    addZone(world, { x = 10, z = 0 }).markedForDeletion = true
    assertEquals(#TCParking.getZoneRows(1), 0, "neither")
end)

test("removeZone sells the zone to its owner at its sell price", function()
    local world = setup()
    local slot = addZone(world, { x = 0, z = 0, sellPrice = 250 })

    removeZone(1, { tostring(slot.id) })
    assertTrue(slot.sold, "sold as vanilla does")
    assertTrue(slot.isDeleted, "and gone")
    assertEquals(#world.money, 1, "paid once")
    assertEquals(world.money[1].amount, 250, "its sell price")
    assertEquals(world.money[1].farmId, 1, "to its farm")
    assertEquals(world.money[1].moneyType, MoneyType.SHOP_PROPERTY_SELL, "as a property sale")
    assertEquals(#TCParking.getZoneRows(1), 0, "no longer listed")
end)

test("removeZone refuses another farm's zone, an unknown id and anything that isn't a zone", function()
    local world = setup()
    local other = addZone(world, { x = 0, z = 0, farmId = 2, sellPrice = 100 })
    world.objects[50] = { id = 50, getOwnerFarmId = function() return 1 end, delete = function(self) self.isDeleted = true end }

    removeZone(1, { tostring(other.id) })
    assertEquals(other.isDeleted, nil, "another farm's stays")
    removeZone(1, { "50" })
    assertEquals(world.objects[50].isDeleted, nil, "not a zone, so left alone")
    removeZone(1, { "77" })
    assertEquals(#world.money, 0, "nothing paid")
    assertEquals(removeZone(1, {}), false, "no id is bad arguments")
end)
