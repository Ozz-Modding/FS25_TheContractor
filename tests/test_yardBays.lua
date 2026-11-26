-- 183: yard machine bays - a farmer's machine goes in a free bay it fits
-- (the smallest first), facing the bay's way, ahead of the yard's standing
-- spots; a bay with something in it or claimed by something on its way is
-- taken; with none free, a standing spot that keeps out of the bays; the
-- standing spots themselves keep out of bays; and where a bay may be
-- placed.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    MathUtil = {
        vector2Length = function(x, z) return math.sqrt(x * x + z * z) end,
        getYRotationFromDirection = function(x, z) return math.atan2(x, z) end,
    }
    getWorldTranslation = function(node) return node.x, 0, node.z end
    PlaceablePropertyState = { CONSTRUCTION_PREVIEW = 4, OWNED = 1 }
    FarmlandManager = { NO_OWNER_FARM_ID = 0 }
    world:load("src/business/Yards.lua")
    world:load("src/placeables/PlaceableTCParkingSlot.lua")
    world:load("src/placeables/PlaceableTCYardCentre.lua")
    world:load("src/placeables/PlaceableTCYardBay.lua")
    world:load("src/util/TCYardBays.lua")
    world:load("src/business/FieldBreakdowns.lua")
    TheContractorRepairContracts = { CLEARANCE = 0.5 }

    -- Farmland n covers x from n * 100 to n * 100 + 99; farmland 3 is farm 1's.
    world.owners = { [3] = 1 }
    g_farmlandManager = {
        getIsValidFarmlandId = function(_, farmlandId)
            return farmlandId ~= nil and farmlandId >= 1 and farmlandId <= 9
        end,
        getFarmlandOwner = function(_, farmlandId)
            return world.owners[farmlandId] or 0
        end,
        getFarmlandById = function(_, farmlandId)
            return { id = farmlandId, xWorldPos = farmlandId * 100 + 50, zWorldPos = 0 }
        end,
        getFarmlandIdAtWorldPosition = function(_, x)
            return math.floor(x / 100)
        end,
    }

    world.placeables = {}
    -- A bay: def { farmlandId (default from x), x, z (its middle), width,
    -- length, rotY (the way it faces, default north), propertyState }.
    function world:addBay(def)
        local rotY = def.rotY or 0
        local vX, vZ = math.sin(rotY), math.cos(rotY)
        local uX, uZ = vZ, -vX
        local w, l = def.width * 0.5, def.length * 0.5
        local sx, sz = def.x - uX * w - vX * l, (def.z or 0) - uZ * w - vZ * l
        local placeable = {
            boughtWithFarmland = false,
            propertyState = def.propertyState or PlaceablePropertyState.OWNED,
            [PlaceableTCYardBay.KEY] = {
                startNode = { x = sx, z = sz },
                widthNode = { x = sx + uX * def.width, z = sz + uZ * def.width },
                heightNode = { x = sx + vX * def.length, z = sz + vZ * def.length },
            },
        }
        local farmlandId = def.farmlandId or math.floor(def.x / 100)
        function placeable:getFarmlandId() return farmlandId end
        function placeable:getPosition() return def.x, 0, def.z or 0 end
        table.insert(self.placeables, placeable)
        return placeable
    end
    function world:addMarker(def)
        local placeable = { boughtWithFarmland = false, propertyState = PlaceablePropertyState.OWNED,
            [PlaceableTCYardCentre.KEY] = {} }
        function placeable:getFarmlandId() return def.farmlandId end
        function placeable:getPosition() return def.x, 0, def.z or 0 end
        table.insert(self.placeables, placeable)
        return placeable
    end

    world.yards = TheContractorYards.new()
    world.yards:applyOverride(8, TheContractorYards.MODE.ON)
    world.arrivals = {}
    world.jobsByFarm = { [1] = {} }
    g_currentMission.placeableSystem = { placeables = world.placeables }
    g_currentMission.TheContractor = { Yards = world.yards, RepairContracts = { arrivals = world.arrivals },
        Jobs = { jobsByFarm = world.jobsByFarm } }

    -- What's standing where: points nothing may be on.
    world.standing = {}
    TCParking = {
        isAreaClear = function(x, z, rotY, width, length)
            local area = TCYardBays.makeArea(x, z, rotY, width, length)
            for _, point in ipairs(world.standing) do
                if PlaceableTCParkingSlot.isInArea(area, point.x, point.z) then
                    return false
                end
            end
            return true
        end,
    }
    world.openGround = function() return true end
    TheContractorYards.isOpenGround = function(_, x, z) return world.openGround(x, z) end
    return world
end

local function setSpots(world, spots)
    world.yards:applySpots(8, { x = 850, z = 0, spots = spots })
end

local TRAILER = { width = 3, length = 9, height = 3.5 }
local TRACTOR_AND_IMPLEMENT = { width = 4, length = 12, height = 3.5 }
local COMBINE = { width = 9, length = 14, height = 4 }

local function addJob(world, def)
    local job = { id = #world.jobsByFarm[1] + 1, terminal = def.terminal, yardHaul = def.yardHaul,
        yardDelivery = def.yardDelivery }
    function job:isTerminal() return self.terminal == true end
    world.jobsByFarm[1][job.id] = job
    return job
end

test("a machine goes in a free bay it fits, in its middle and facing its way, ahead of the standing spots", function()
    local world = setup()
    setSpots(world, { { x = 870, z = 30 } })
    world:addBay({ x = 820, z = 10, width = 8, length = 13.5, rotY = math.pi / 2 })

    local x, z, rotY = TheContractorFieldBreakdowns.pickYardSpot(8, TRAILER, math.random)
    assertNear(x, 820, 0.001)
    assertNear(z, 10, 0.001)
    assertNear(rotY, math.pi / 2, 0.0001, "facing east, the bay's way")
end)

test("the smallest bay that fits first; a bay too small is passed over", function()
    local world = setup()
    setSpots(world, { { x = 870, z = 30 } })
    world:addBay({ x = 820, z = 0, width = 8, length = 13.5 })
    world:addBay({ x = 840, z = 0, width = 5, length = 11 })

    assertNear(TheContractorFieldBreakdowns.pickYardSpot(8, TRAILER, math.random), 840, 0.001)
    -- 12 m and its clearance is too long for the small bay.
    assertNear(TheContractorFieldBreakdowns.pickYardSpot(8, TRACTOR_AND_IMPLEMENT, math.random), 820, 0.001)
    -- Too wide for either: a standing spot.
    assertEquals(870, (TheContractorFieldBreakdowns.pickYardSpot(8, COMBINE, math.random)))
end)

test("a random one of the smallest free bays", function()
    local world = setup()
    world:addBay({ x = 820, z = 0, width = 5, length = 11 })
    world:addBay({ x = 830, z = 0, width = 5, length = 11 })
    world:addBay({ x = 850, z = 0, width = 8, length = 13.5 })
    assertNear(TheContractorFieldBreakdowns.pickYardSpot(8, TRAILER, function() return 0 end), 820, 0.001)
    assertNear(TheContractorFieldBreakdowns.pickYardSpot(8, TRAILER, function() return 0.99 end), 830, 0.001)
end)

test("a bay is taken by something in it, a machine on its way, a trailer not out yet, or a bale drop", function()
    local world = setup()
    world:addBay({ x = 820, z = 0, width = 5, length = 11 })
    world:addBay({ x = 850, z = 0, width = 8, length = 13.5 })
    local function pick()
        return (TheContractorFieldBreakdowns.pickYardSpot(8, TRAILER, math.random))
    end
    assertNear(pick(), 820, 0.001)

    world.standing = { { x = 821, z = 4 } }
    assertNear(pick(), 850, 0.001, "a tractor parked in it")
    world.standing = {}

    table.insert(world.arrivals, { x = 820, z = 0 })
    assertNear(pick(), 850, 0.001, "a machine on its way to it")
    table.remove(world.arrivals)

    local haulJob = addJob(world, { yardHaul = { x = 820, z = 0, trailerVehicleId = 0 } })
    assertNear(pick(), 850, 0.001, "a load to sell's trailer not out yet")
    haulJob.yardHaul.trailerVehicleId = 12
    assertNear(pick(), 820, 0.001, "the trailer's out: it's the vehicle that counts now")
    haulJob.yardHaul.trailerVehicleId = 0
    haulJob.terminal = true
    assertNear(pick(), 820, 0.001, "the job's over")

    -- A 12 m drop area whose middle is outside the bay but overlaps it.
    addJob(world, { yardDelivery = { x = 812, z = 0, rotY = 0, width = 12, length = 12 } })
    assertNear(pick(), 850, 0.001, "bales to be dropped in it")
end)

test("with every bay taken, a standing spot that doesn't reach into a bay", function()
    local world = setup()
    world:addBay({ x = 860, z = 0, width = 5, length = 11 })
    table.insert(world.arrivals, { x = 860, z = 0 })
    -- The first spot's 9 m trailer would reach into the bay, the second's wouldn't.
    setSpots(world, { { x = 860, z = -8 }, { x = 820, z = 0 } })
    local rolls = { 0, 0.99 }
    local index = 0
    local random = function()
        index = index + 1
        return rolls[math.min(index, #rolls)]
    end
    local x = TheContractorFieldBreakdowns.pickYardSpot(8, TRAILER, random)
    assertEquals(820, x)

    setSpots(world, { { x = 860, z = -8 } })
    assertEquals(nil, TheContractorFieldBreakdowns.pickYardSpot(8, TRAILER, math.random))
end)

test("only placed bays on the yard's own farmland count, and they're never its buildings", function()
    local world = setup()
    world:addBay({ x = 820, z = 0, width = 5, length = 11 })
    world:addBay({ x = 830, z = 0, width = 5, length = 11, propertyState = PlaceablePropertyState.CONSTRUCTION_PREVIEW })
    world:addBay({ x = 520, z = 0, width = 5, length = 11 })
    local going = world:addBay({ x = 840, z = 0, width = 5, length = 11 })
    going.isDeleting = true

    local bays = TheContractorYards.findBays(world.placeables, 8)
    assertEquals(1, #bays)
    local yards = TheContractorYards.detect(world.placeables, world.yards.overrides)
    assertEquals(1, #yards)
    assertEquals(1, #yards[1].bays)
    assertEquals(nil, yards[1].group)
    assertEquals(0, #TheContractorYards.getExcludedOn(world.placeables, 8))
end)

test("standing spots keep out of bays", function()
    local world = setup()
    local bay = TCYardBays.makeArea(820, 0, 0, 5, 11)
    local yard = { farmlandId = 8, x = 850, z = 0, bays = { bay } }
    local tally = {}
    local spots = TheContractorYards.pickSpots(yard, { { x = 820, z = 3 }, { x = 840, z = 0 } },
        function() return true end, tally)
    assertEquals(1, #spots)
    assertEquals(840, spots[1].x)
    assertEquals(1, tally.rejected[TheContractorYards.SPOT_REJECTION.BAY])
end)

test("bays placed flush don't overlap; a point inside or a turned rectangle across one does", function()
    setup()
    local a = TCYardBays.makeArea(0, 0, 0, 5, 11)
    assertEquals(false, TCYardBays.overlaps(a, TCYardBays.makeArea(5, 0, 0, 5, 11)))
    assertEquals(false, TCYardBays.overlaps(a, TCYardBays.makeArea(0, 11, 0, 5, 11)))
    assertTrue(TCYardBays.overlaps(a, TCYardBays.makeArea(1, 2, 0, 0, 0)))
    assertEquals(false, TCYardBays.overlaps(a, TCYardBays.makeArea(4, 2, 0, 0, 0)))
    assertTrue(TCYardBays.overlaps(a, TCYardBays.makeArea(4.5, 0, math.pi / 4, 2, 6)))
    assertEquals(false, TCYardBays.overlaps(a, TCYardBays.makeArea(9, 0, math.pi / 4, 2, 6)))
end)

test("a bay goes whole on a yard no player owns, any number of them, by the host or an admin", function()
    local world = setup()
    world.canChange = true
    TheContractorSettings = { getCanLocalPlayerChange = function() return world.canChange end }
    local E = PlaceableTCYardCentre.PLACEMENT_ERROR
    local get = PlaceableTCYardBay.getPlacementErrorFor
    local function preview(x, rotY)
        local bay = world:addBay({ x = x, z = 0, width = 8, length = 13.5, rotY = rotY,
            propertyState = PlaceablePropertyState.CONSTRUCTION_PREVIEW })
        return bay
    end

    g_time = 0
    world:addMarker({ farmlandId = 8, x = 850 })
    world:addBay({ x = 830, z = 0, width = 8, length = 13.5 })
    assertEquals(nil, get(preview(850), 850, 0), "a marker and another bay already there")
    assertEquals(E.NOT_A_YARD, get(preview(550), 550, 0))
    assertEquals(E.OWNED, get(preview(350), 350, 0))

    -- Its middle's on the yard, but facing east its far end isn't.
    assertEquals(nil, get(preview(895), 895, 0))
    assertEquals(PlaceableTCYardBay.OFF_YARD, get(preview(895, math.pi / 2), 895, 0))

    world.canChange = false
    assertEquals(E.NO_PERMISSION, get(preview(860), 860, 0))
end)
