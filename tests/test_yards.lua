-- 108: farm yard detection - which placeables count, grouping them by
-- farmland, the yard rule, where a yard sits, how the player's overrides
-- combine with detection (and survive a save and a client join), and how
-- standing spots are picked round a building.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    world:load("src/business/Yards.lua")

    -- Farmlands 1-9, each with its indicator at (id * 100, 0); farmland 3
    -- owned by farm 1.
    world.owners = { [3] = 1 }
    g_farmlandManager = {
        getIsValidFarmlandId = function(_, farmlandId)
            return farmlandId ~= nil and farmlandId >= 1 and farmlandId <= 9
        end,
        getFarmlandOwner = function(_, farmlandId)
            return world.owners[farmlandId] or 0
        end,
        getFarmlandById = function(_, farmlandId)
            return { id = farmlandId, xWorldPos = farmlandId * 100, zWorldPos = 0 }
        end,
    }

    world.placeables = {}
    -- A map building: def { farmlandId, category, x, z, preplaced
    -- (default true), bought (default true), overwrite, sells, deleted }.
    function world:addBuilding(def)
        local placeable = {
            isPreplaced = def.preplaced ~= false,
            boughtWithFarmland = def.bought ~= false,
            boughtWithFarmlandSavegameOverwrite = def.overwrite,
            isDeleted = def.deleted,
            storeItem = { categoryName = def.category, name = def.category },
            spec_sellingStation = def.sells and {} or nil,
        }
        function placeable:getFarmlandId() return def.farmlandId end
        function placeable:getPosition() return def.x or 0, 0, def.z or 0 end
        table.insert(self.placeables, placeable)
        return placeable
    end

    world.yards = TheContractorYards.new()
    function world:detect()
        return TheContractorYards.detect(self.placeables, self.yards.overrides)
    end
    return world
end

local function findEntry(list, farmlandId)
    for _, entry in ipairs(list) do
        if entry.farmlandId == farmlandId then
            return entry
        end
    end
    return nil
end

test("two yard buildings on a farmland make a yard, in the middle of them", function()
    local world = setup()
    world:addBuilding({ farmlandId = 3, category = "SHEDS", x = 10, z = 20 })
    world:addBuilding({ farmlandId = 3, category = "SILOS", x = 30, z = 40 })
    -- Not a yard building, so it doesn't move the middle.
    world:addBuilding({ farmlandId = 3, category = "DECORATION", x = 500, z = 500 })

    local yards, nearMisses = world:detect()
    assertEquals(1, #yards)
    assertEquals(0, #nearMisses)
    local yard = yards[1]
    assertEquals(3, yard.farmlandId)
    assertEquals("detected", yard.how)
    assertEquals(1, yard.ownerFarmId)
    assertEquals(20, yard.x)
    assertEquals(30, yard.z)
    assertEquals(3, #yard.group.buildings)
    assertEquals(2, yard.group.yardBuildingCount)
end)

test("one yard building, or only other categories, is a near miss", function()
    local world = setup()
    world:addBuilding({ farmlandId = 1, category = "SHEDS" })
    world:addBuilding({ farmlandId = 2, category = "DECORATION" })
    world:addBuilding({ farmlandId = 2, category = "SELLINGPOINTS", sells = true })

    local yards, nearMisses, categories = world:detect()
    assertEquals(0, #yards)
    assertEquals(2, #nearMisses)
    assertEquals(1, nearMisses[1].farmlandId)
    assertEquals(2, nearMisses[2].farmlandId)
    assertTrue(nearMisses[2].group.buildings[2].hasSellingStation)
    assertEquals(1, categories.SELLINGPOINTS)
end)

test("yard buildings without a shed or farmhouse aren't a yard", function()
    local world = setup()
    world:addBuilding({ farmlandId = 2, category = "SILOS" })
    world:addBuilding({ farmlandId = 2, category = "SILOS" })
    world:addBuilding({ farmlandId = 2, category = "SILOS" })
    local yards, nearMisses = world:detect()
    assertEquals(0, #yards)
    assertEquals(2, nearMisses[1].farmlandId)

    world:addBuilding({ farmlandId = 2, category = "FARMHOUSES" })
    yards = world:detect()
    assertEquals(1, #yards)
end)

test("only preplaced buildings bought with their farmland count, the save's overwrite first", function()
    local world = setup()
    -- Placed by a player, not the map.
    world:addBuilding({ farmlandId = 4, category = "SHEDS", preplaced = false })
    -- Stays with the map whoever owns the land.
    world:addBuilding({ farmlandId = 4, category = "SHEDS", bought = false })
    -- The save says it isn't bought with the land after all.
    world:addBuilding({ farmlandId = 4, category = "SHEDS", overwrite = false })
    -- Gone.
    world:addBuilding({ farmlandId = 4, category = "SHEDS", deleted = true })
    -- Off any valid farmland.
    world:addBuilding({ farmlandId = 0, category = "SHEDS" })
    world:addBuilding({ farmlandId = 0, category = "SHEDS" })
    local yards, nearMisses = world:detect()
    assertEquals(0, #yards)
    assertEquals(0, #nearMisses)

    -- The save's overwrite can make one count, too.
    world:addBuilding({ farmlandId = 4, category = "SHEDS", bought = false, overwrite = true })
    world:addBuilding({ farmlandId = 4, category = "SILOS" })
    yards = world:detect()
    assertEquals(1, #yards)
    assertEquals(2, yards[1].group.yardBuildingCount)
end)

test("overrides: on makes a yard, off rules one out, auto goes back to detection", function()
    local world = setup()
    world:addBuilding({ farmlandId = 5, category = "SHEDS", x = 7, z = 9 })
    world:addBuilding({ farmlandId = 6, category = "SHEDS" })
    world:addBuilding({ farmlandId = 6, category = "SILOS" })
    local MODE = TheContractorYards.MODE

    world.yards:applyOverride(5, MODE.ON)
    world.yards:applyOverride(6, MODE.OFF)
    local yards, nearMisses = world:detect()
    assertEquals(1, #yards)
    assertEquals(5, yards[1].farmlandId)
    assertEquals("declared", yards[1].how)
    -- Its only building, though not enough for the rule.
    assertEquals(7, yards[1].x)
    assertEquals(9, yards[1].z)
    local ruledOut = findEntry(nearMisses, 6)
    assertEquals("ruledOut", ruledOut.how)

    world.yards:applyOverride(5, MODE.AUTO)
    world.yards:applyOverride(6, MODE.AUTO)
    assertEquals(MODE.AUTO, world.yards:getOverride(5))
    yards, nearMisses = world:detect()
    assertEquals(1, #yards)
    assertEquals(6, yards[1].farmlandId)
    assertEquals("detected", yards[1].how)
    assertEquals(5, nearMisses[1].farmlandId)
end)

test("a declared yard with no buildings sits in the middle of its farmland", function()
    local world = setup()
    world.yards:applyOverride(8, TheContractorYards.MODE.ON)
    local yards, nearMisses = world:detect()
    assertEquals(1, #yards)
    assertEquals(nil, yards[1].group)
    assertEquals(800, yards[1].x)
    assertEquals(0, yards[1].z)
    assertEquals(0, #nearMisses)

    -- Ruling out a farmland with nothing on it lists nothing.
    world.yards:applyOverride(8, TheContractorYards.MODE.OFF)
    yards, nearMisses = world:detect()
    assertEquals(0, #yards)
    assertEquals(0, #nearMisses)
end)

test("overrides survive a save and a client join", function()
    local world = setup()
    local MODE = TheContractorYards.MODE
    world.yards:applyOverride(2, MODE.ON)
    world.yards:applyOverride(7, MODE.OFF)

    local xmlFile = {}
    world.yards:saveToXmlFile(xmlFile)
    local loaded = TheContractorYards.new()
    loaded:loadFromXMLFile(xmlFile)
    assertEquals(MODE.ON, loaded:getOverride(2))
    assertEquals(MODE.OFF, loaded:getOverride(7))
    assertEquals(MODE.AUTO, loaded:getOverride(3))

    local stream = world:newStream()
    loaded:writeInitialClientState(stream)
    local client = TheContractorYards.new()
    client:readInitialClientState(stream)
    assertEquals(MODE.ON, client:getOverride(2))
    assertEquals(MODE.OFF, client:getOverride(7))
end)

test("spots go round a building's footprint, outside it, apart, and only where open", function()
    setup()
    -- A 10 x 10 shed with its corner at the origin.
    local footprint = { { x = 0, z = 0 }, { x = 10, z = 0 }, { x = 10, z = 10 }, { x = 0, z = 10 } }
    local yard = { farmlandId = 1, x = 5, z = 5, group = { buildings = { { x = 5, z = 5, footprints = { footprint } } } } }

    local candidates = TheContractorYards.getCandidates(yard)
    local spots = TheContractorYards.pickSpots(yard, candidates, function(x, z)
        -- Something's in the way west of the shed.
        return x > -1
    end)

    assertTrue(#spots > 0)
    assertTrue(#spots <= TheContractorYards.MAX_SPOTS)
    local sides = {}
    for i, spot in ipairs(spots) do
        assertTrue(not TheContractorYards.isInside(footprint, spot.x, spot.z))
        assertTrue(spot.x > -1)
        for j = i + 1, #spots do
            local other = spots[j]
            assertTrue((spot.x - other.x) ^ 2 + (spot.z - other.z) ^ 2 >= TheContractorYards.SPOT_SEPARATION ^ 2)
        end
        if spot.z < 0 then sides.south = true end
        if spot.z > 10 then sides.north = true end
        if spot.x > 10 then sides.east = true end
    end
    assertTrue(sides.south and sides.north and sides.east)
end)

test("a building without a footprint gets a ring of its own", function()
    setup()
    local yard = { farmlandId = 1, group = { buildings = { { x = 50, z = 50, footprints = {} } } } }
    local candidates = TheContractorYards.getCandidates(yard)
    assertEquals(TheContractorYards.RING_POINTS, #candidates)
    for _, point in ipairs(candidates) do
        assertNear(TheContractorYards.BUILDING_RING_RADIUS, math.sqrt((point.x - 50) ^ 2 + (point.z - 50) ^ 2), 0.001)
    end
end)

test("with more open spots than it keeps, a yard spreads them out from its middle", function()
    setup()
    -- 100 open points every 4 m along a line, the yard's middle at its start.
    local candidates = {}
    for i = 0, 99 do
        table.insert(candidates, { x = i * 4, z = 0 })
    end
    local yard = { farmlandId = 1, x = 0, z = 0 }
    local spots, openCount = TheContractorYards.pickSpots(yard, candidates, function() return true end)

    assertEquals(100, openCount)
    assertEquals(TheContractorYards.MAX_SPOTS, #spots)
    assertEquals(0, spots[1].x)
    -- Both ends kept, and no stretch of the line left without one: 40
    -- evenly over 396 m would be ~10 m apart.
    local xs = {}
    for _, spot in ipairs(spots) do
        table.insert(xs, spot.x)
    end
    table.sort(xs)
    assertEquals(0, xs[1])
    assertEquals(396, xs[#xs])
    for i = 2, #xs do
        assertTrue(xs[i] - xs[i - 1] <= 16)
    end
end)

test("a farmhouse's spawn node is measured clockwise from its +Z, seen from above", function()
    setup()
    local turn = TheContractorYards.getTurnFromForward
    -- A house facing +Z (south on the map): the node out in front, to its
    -- west (clockwise from south), to its east and behind it.
    assertNear(0, turn(0, 1, 0, 6), 0.001)
    assertNear(90, turn(0, 1, -6, 0), 0.001)
    assertNear(-90, turn(0, 1, 6, 0), 0.001)
    assertNear(180, math.abs(turn(0, 1, 0, -6)), 0.001)
    -- Turned to face east, the node out in front of it.
    assertNear(0, turn(1, 0, 6, 0), 0.001)
    assertEquals(nil, turn(0, 1, 0, 0), "a node on the root")
end)
