-- Parking slot types: self-propelled harvesters only park in harvester
-- slots, other drivable machines only in vehicle slots and everything else
-- only in implement slots, whatever order the farm placed them in.

local function setup()
    stubs.install()

    -- Footprint nodes are plain tables holding their position.
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

    dofile("src/placeables/PlaceableTCParkingSlot.lua")
    dofile("src/util/TCEquipmentClass.lua")
    dofile("src/util/TCBallast.lua")
    dofile("src/util/TCParking.lua")
    g_currentMission.placeableSystem = { placeables = {} }
end

-- A slot with its start corner at x, 0: 4 m x 9 m unless given.
local function addSlot(farmId, x, slotType, width, length)
    local slot = { farmId = farmId }
    slot[PlaceableTCParkingSlot.KEY] = {
        startNode = { x = x, z = 0 },
        widthNode = { x = x + (width or 4), z = 0 },
        heightNode = { x = x, z = length or 9 },
        slotType = slotType,
    }
    function slot:getOwnerFarmId() return self.farmId end
    table.insert(g_currentMission.placeableSystem.placeables, slot)
    return slot
end

local function tractor()
    return { size = { width = 2.5, length = 5 }, spec_drivable = {} }
end

local function trailer()
    return { size = { width = 2.5, length = 7 } }
end

local function combine()
    return { size = { width = 3.5, length = 9.5 }, spec_drivable = {}, spec_combine = {} }
end

-- A trailed harvester: a Combine spec but nothing to drive.
local function trailedHarvester()
    return { size = { width = 3, length = 8 }, spec_combine = {} }
end

test("drivable machines are vehicles, everything else implements", function()
    setup()
    local SLOT_TYPE = PlaceableTCParkingSlot.SLOT_TYPE
    assertEquals(SLOT_TYPE.VEHICLE, PlaceableTCParkingSlot.getSlotTypeFor(tractor()))
    assertEquals(SLOT_TYPE.IMPLEMENT, PlaceableTCParkingSlot.getSlotTypeFor(trailer()))
    assertEquals(SLOT_TYPE.HARVESTER, PlaceableTCParkingSlot.getSlotTypeFor(combine()))
    assertEquals(SLOT_TYPE.IMPLEMENT, PlaceableTCParkingSlot.getSlotTypeFor(trailedHarvester()))
end)

test("a slot with no type is a vehicle slot", function()
    setup()
    local slot = addSlot(1, 0, nil)
    slot[PlaceableTCParkingSlot.KEY].slotType = nil
    assertEquals(PlaceableTCParkingSlot.SLOT_TYPE.VEHICLE, PlaceableTCParkingSlot.getSlotType(slot))
end)

test("getSlots filters by type, or gives every slot without one", function()
    setup()
    local SLOT_TYPE = PlaceableTCParkingSlot.SLOT_TYPE
    addSlot(1, 0, SLOT_TYPE.VEHICLE)
    addSlot(1, 10, SLOT_TYPE.IMPLEMENT)
    addSlot(1, 20, SLOT_TYPE.IMPLEMENT)
    addSlot(2, 30, SLOT_TYPE.IMPLEMENT)
    assertEquals(3, #TCParking.getSlots(1))
    assertEquals(1, #TCParking.getSlots(1, SLOT_TYPE.VEHICLE))
    assertEquals(2, #TCParking.getSlots(1, SLOT_TYPE.IMPLEMENT))
end)

test("each machine parks in a slot of its own type", function()
    setup()
    local SLOT_TYPE = PlaceableTCParkingSlot.SLOT_TYPE
    -- Implement slot placed first, so the old any-slot search would pick it.
    addSlot(1, 0, SLOT_TYPE.IMPLEMENT)
    addSlot(1, 10, SLOT_TYPE.VEHICLE)

    local x = TCParking.findSpot(tractor(), 1)
    assertNear(12, x, 0.001, "tractor centred in the vehicle slot")
    x = TCParking.findSpot(trailer(), 1)
    assertNear(2, x, 0.001, "trailer centred in the implement slot")
end)

test("no slot of the right type means no spot", function()
    setup()
    addSlot(1, 0, PlaceableTCParkingSlot.SLOT_TYPE.VEHICLE)
    assertTrue(TCParking.findSpot(trailer(), 1) == nil, "trailer has no implement slot")
    assertTrue(TCParking.findSpot(tractor(), 1) ~= nil, "tractor still parks")
end)

test("a harvester parks only in a harvester slot, and nothing else does", function()
    setup()
    local SLOT_TYPE = PlaceableTCParkingSlot.SLOT_TYPE
    addSlot(1, 0, SLOT_TYPE.VEHICLE, 24, 9)
    assertTrue(TCParking.findSpot(combine(), 1) == nil, "no harvester slot")

    addSlot(1, 30, SLOT_TYPE.HARVESTER, 8, 13.5)
    local x = TCParking.findSpot(combine(), 1)
    assertTrue(x ~= nil and x >= 30 and x <= 38, "combine in the harvester slot")

    -- The tractor goes in the vehicle slot, never the harvester slot.
    x = TCParking.findSpot(tractor(), 1)
    assertTrue(x < 24, "tractor in the vehicle slot")
end)

-- Obstacles for the overlap test: each a placeable's collision covering
-- every x, z, between bottom and top metres above the terrain (0).
local function installObstacles(obstacles)
    local shed = {}
    g_currentMission.nodeToObject = {}
    g_currentMission.players = {}
    function g_currentMission:getNodeObject(node) return shed end
    overlapBox = function(x, y, z, rx, ry, rz, ex, ey, ez, callback, target)
        for _, obstacle in ipairs(obstacles) do
            if obstacle.bottom < y + ey and obstacle.top > y - ey then
                if not target[callback](target, obstacle) then
                    return
                end
            end
        end
    end
end

test("the overlap box is the vehicle's height, standing just off the ground", function()
    setup()
    addSlot(1, 0, PlaceableTCParkingSlot.SLOT_TYPE.VEHICLE)
    local tall = tractor()
    tall.size.height = 3.5

    -- A shed's floor slab and a roof above the tractor don't block.
    installObstacles({ { bottom = -0.5, top = 0.1 }, { bottom = 4.5, top = 5 } })
    assertTrue(TCParking.findSpot(tall, 1) ~= nil, "parks under a high roof")

    -- A roof lower than the tractor does.
    installObstacles({ { bottom = 3, top = 3.5 } })
    assertTrue(TCParking.findSpot(tall, 1) == nil, "too tall for a low roof")

    -- So does a post standing in the slot.
    installObstacles({ { bottom = -1, top = 5 } })
    assertTrue(TCParking.findSpot(tall, 1) == nil, "blocked by a post")
end)

-- An implement whose hitches are at these z offsets from its origin (a
-- hitch node is a plain table holding its z), with its footprint's centre
-- lengthOffset ahead of its origin.
local function implementWithHitches(zs, lengthOffset)
    local joints = {}
    for _, z in ipairs(zs) do
        table.insert(joints, { node = { z = z } })
    end
    local vehicle = { size = { width = 2.5, length = 3, lengthOffset = lengthOffset or 0 }, rootNode = {} }
    function vehicle:getInputAttacherJoints() return joints end
    return vehicle
end

local function installLocalToLocal()
    localToLocal = function(node) return 0, 0, node.z end
end

test("only an implement hitched at its back counts as hitching at its back", function()
    setup()
    installLocalToLocal()
    assertTrue(TCParking.hitchesAtBack(implementWithHitches({ -1 })), "front mower")
    assertTrue(not TCParking.hitchesAtBack(implementWithHitches({ 1 })), "rear mower")
    assertTrue(not TCParking.hitchesAtBack(implementWithHitches({ -1, 1 })), "hitches either end")
    assertTrue(not TCParking.hitchesAtBack(implementWithHitches({})), "no hitch")
    assertTrue(not TCParking.hitchesAtBack(trailer()), "no attachable spec")
    local drivable = implementWithHitches({ -1 })
    drivable.spec_drivable = {}
    assertTrue(not TCParking.hitchesAtBack(drivable), "a drivable machine")
end)

test("an implement hitched at its back parks turned round, its footprint in the same place", function()
    setup()
    installLocalToLocal()
    addSlot(1, 0, PlaceableTCParkingSlot.SLOT_TYPE.IMPLEMENT)

    local x, _, rearZ, rearRotY = TCParking.findSpot(implementWithHitches({ 1 }, 0.5), 1)
    assertNear(2, x, 0.001, "rear implement centred")
    assertNear(0, rearRotY, 0.001, "rear implement faces the arrow")

    local frontX, _, frontZ, frontRotY = TCParking.findSpot(implementWithHitches({ -1 }, 0.5), 1)
    assertNear(2, frontX, 0.001, "front implement centred")
    assertNear(math.pi, frontRotY, 0.001, "front implement faces the start edge")
    -- Both footprints are centred on the same spot: origin + ahead * offset.
    assertNear(rearZ + 0.5, frontZ - 0.5, 0.001, "same footprint centre")
end)
