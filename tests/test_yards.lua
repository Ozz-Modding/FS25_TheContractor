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

test("only buildings bought with their farmland count, the save's overwrite first", function()
    local world = setup()
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

test("a map's default placeables count as well as its preplaced ones", function()
    local world = setup()
    -- From the map's placeables XML: not preplaced, bought with the land
    -- by the map's overwrite.
    world:addBuilding({ farmlandId = 6, category = "SHEDS", preplaced = false, bought = false, overwrite = true })
    world:addBuilding({ farmlandId = 6, category = "FARMHOUSES", preplaced = false, bought = false, overwrite = true })
    -- Scenery the map doesn't sell with the land.
    world:addBuilding({ farmlandId = 7, category = "SHEDS", preplaced = false, bought = false })
    world:addBuilding({ farmlandId = 7, category = "FARMHOUSES", preplaced = false, bought = false })

    local yards = world:detect()
    assertEquals(1, #yards)
    assertEquals(6, yards[1].farmlandId)
    assertEquals(2, yards[1].group.yardBuildingCount)
end)

test("each placeable left out on a farmland says every reason, and only that farmland's", function()
    local world = setup()
    local exclusion = TheContractorYards.EXCLUSION
    world:addBuilding({ farmlandId = 4, category = "sheds", bought = false, preplaced = false })
    world:addBuilding({ farmlandId = 4, category = "SHEDS", overwrite = false })
    world:addBuilding({ farmlandId = 4, category = "SHEDS", deleted = true, bought = false })
    -- Counted, so not listed.
    world:addBuilding({ farmlandId = 4, category = "SILOS", x = 7, z = 8 })
    -- Another farmland's.
    world:addBuilding({ farmlandId = 5, category = "SHEDS", bought = false })

    local excluded = TheContractorYards.getExcludedOn(world.placeables, 4)
    assertEquals(3, #excluded)
    assertEquals(1, #excluded[1].exclusions)
    assertEquals(exclusion.NOT_BOUGHT, excluded[1].exclusions[1])
    assertEquals("SHEDS", excluded[1].category)
    assertEquals(false, excluded[1].isPreplaced)
    assertEquals(exclusion.SAVE_NOT_BOUGHT, excluded[2].exclusions[1])
    assertTrue(excluded[2].isPreplaced)
    assertEquals(2, #excluded[3].exclusions)
    assertEquals(exclusion.DELETED, excluded[3].exclusions[1])
    assertEquals(exclusion.NOT_BOUGHT, excluded[3].exclusions[2])

    local offFarmland = TheContractorYards.getExclusions(world:addBuilding({ farmlandId = 0, category = "SHEDS" }))
    assertEquals(1, #offFarmland)
    assertEquals(exclusion.NO_FARMLAND, offFarmland[1])
    assertEquals(0, #TheContractorYards.getExclusions(world.placeables[4]))
end)

test("a farmland that fails the rule says every way it fails", function()
    local world = setup()
    local failure = TheContractorYards.RULE_FAILURE
    local function failuresOn(farmlandId)
        local groups = TheContractorYards.groupByFarmland((function()
            local buildings = {}
            for _, placeable in ipairs(world.placeables) do
                table.insert(buildings, TheContractorYards.describePlaceable(placeable))
            end
            return buildings
        end)())
        return TheContractorYards.getRuleFailures(groups[farmlandId])
    end

    local none = failuresOn(1)
    assertEquals(1, #none)
    assertEquals(failure.NO_BUILDINGS, none[1])

    world:addBuilding({ farmlandId = 1, category = "SILOS" })
    local both = failuresOn(1)
    assertEquals(2, #both)
    assertEquals(failure.TOO_FEW_YARD_BUILDINGS, both[1])
    assertEquals(failure.NO_ANCHOR, both[2])

    world:addBuilding({ farmlandId = 1, category = "SILOS" })
    local anchor = failuresOn(1)
    assertEquals(1, #anchor)
    assertEquals(failure.NO_ANCHOR, anchor[1])

    world:addBuilding({ farmlandId = 1, category = "FARMHOUSES" })
    assertEquals(0, #failuresOn(1))
end)

test("a yard needs a working building, and a village of farmhouses isn't one", function()
    local world = setup()
    local failure = TheContractorYards.RULE_FAILURE
    -- Two cottages: no working building.
    world:addBuilding({ farmlandId = 1, category = "FARMHOUSES" })
    world:addBuilding({ farmlandId = 1, category = "FARMHOUSES" })
    -- A village: more farmhouses than MAX_FARMHOUSES, with a shed.
    for _ = 1, TheContractorYards.MAX_FARMHOUSES + 1 do
        world:addBuilding({ farmlandId = 2, category = "FARMHOUSES" })
    end
    world:addBuilding({ farmlandId = 2, category = "SHEDS" })
    -- A farm at the limit: MAX_FARMHOUSES houses and a shed.
    for _ = 1, TheContractorYards.MAX_FARMHOUSES do
        world:addBuilding({ farmlandId = 3, category = "FARMHOUSES" })
    end
    world:addBuilding({ farmlandId = 3, category = "SHEDS" })
    -- A house and a silo: the silo's the working building.
    world:addBuilding({ farmlandId = 4, category = "FARMHOUSES" })
    world:addBuilding({ farmlandId = 4, category = "SILOS" })

    local yards, nearMisses = world:detect()
    assertEquals(2, #yards)
    assertEquals(3, yards[1].farmlandId)
    assertEquals(4, yards[2].farmlandId)
    assertEquals(2, #nearMisses)

    local cottages = TheContractorYards.getRuleFailures(findEntry(nearMisses, 1).group)
    assertEquals(1, #cottages)
    assertEquals(failure.NO_WORKING_BUILDING, cottages[1])
    local village = TheContractorYards.getRuleFailures(findEntry(nearMisses, 2).group)
    assertEquals(1, #village)
    assertEquals(failure.TOO_MANY_HOUSES, village[1])
    assertEquals(TheContractorYards.MAX_FARMHOUSES + 1, findEntry(nearMisses, 2).group.houseCount)
    assertEquals(1, findEntry(nearMisses, 2).group.workingCount)
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

test("a spot tally counts each candidate once, by the check that ruled it out, and names what's in the way", function()
    setup()
    local rejection = TheContractorYards.SPOT_REJECTION
    local footprint = { { x = 0, z = 0 }, { x = 10, z = 0 }, { x = 10, z = 10 }, { x = 0, z = 10 } }
    local yard = { farmlandId = 1, x = 5, z = 5,
        group = { buildings = { { name = "Shed", x = 5, z = 5, footprints = { footprint } } } } }
    local candidates = {
        { x = 5, z = 5 },      -- inside the shed
        { x = 20, z = 0 },     -- open
        { x = 21, z = 0 },     -- too close to the one before
        { x = -20, z = 0 },    -- a pad in the way
        { x = -30, z = 0 },    -- the same pad
        { x = 0, z = -20 },    -- a fence
        { x = 0, z = 30 },     -- indoors
    }
    local tally = {}
    local spots, openCount = TheContractorYards.pickSpots(yard, candidates, function(x, z)
        if x < 0 then
            return false, rejection.BLOCKED, "Concrete Pad"
        elseif z < 0 then
            return false, rejection.BLOCKED, "Fence"
        elseif z > 20 then
            return false, rejection.INDOOR
        end
        return true
    end, tally)

    assertEquals(1, #spots)
    assertEquals(1, openCount)
    assertEquals(7, tally.candidates)
    assertEquals(1, tally.rejected[rejection.FOOTPRINT])
    assertEquals(1, tally.rejected[rejection.SEPARATION])
    assertEquals(3, tally.rejected[rejection.BLOCKED])
    assertEquals(1, tally.rejected[rejection.INDOOR])
    assertEquals(2, tally.blockers["Concrete Pad"])
    assertEquals(1, tally.blockers["Fence"])
    assertEquals(1, tally.blockers["Shed"])
end)

test("a footprint with no area has nothing inside it", function()
    setup()
    local point = { { x = 3, z = 4 }, { x = 3, z = 4 }, { x = 3, z = 4 }, { x = 3, z = 4 } }
    local line = { { x = 0, z = 0 }, { x = 10, z = 0 }, { x = 10, z = 0 }, { x = 0, z = 0 } }
    assertEquals(false, TheContractorYards.isInside(point, 3, 4))
    assertEquals(false, TheContractorYards.isInside(point, 100, -50))
    assertEquals(false, TheContractorYards.isInside(line, 5, 0))
    assertEquals(false, TheContractorYards.isInside(line, 5, 20))

    -- A yard with one such building still finds its spots round the rest.
    local square = { { x = 0, z = 0 }, { x = 10, z = 0 }, { x = 10, z = 10 }, { x = 0, z = 10 } }
    assertTrue(TheContractorYards.isInside(square, 5, 5))
    local yard = { farmlandId = 1, x = 5, z = 5, group = { buildings = {
        { name = "Ground Texture", x = 3, z = 4, footprints = { point } },
        { name = "Shed", x = 5, z = 5, footprints = { square } },
    } } }
    local spots = TheContractorYards.pickSpots(yard, TheContractorYards.getCandidates(yard), function()
        return true
    end)
    assertTrue(#spots > 0)
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

-- 117: the map's Set/Unset as farmer yard.

test("the map's button turns a farmland the other way, keeping an override only where it differs from detection", function()
    local world = setup()
    g_currentMission.placeableSystem = { placeables = world.placeables }
    world:addBuilding({ farmlandId = 5, category = "SHEDS" })
    world:addBuilding({ farmlandId = 6, category = "SHEDS" })
    world:addBuilding({ farmlandId = 6, category = "SILOS" })
    local MODE = TheContractorYards.MODE

    -- Detected: unsetting rules it out, and setting it again goes back to
    -- detection.
    local isYard, mode = world.yards:getToggle(6)
    assertTrue(isYard)
    assertEquals(MODE.OFF, mode)
    world.yards:applyOverride(6, mode)
    isYard, mode = world.yards:getToggle(6)
    assertTrue(not isYard)
    assertEquals(MODE.AUTO, mode)

    -- Not a yard by the rule (one building, or nothing at all): setting
    -- declares it, and unsetting goes back to detection.
    for _, farmlandId in ipairs({ 5, 8 }) do
        isYard, mode = world.yards:getToggle(farmlandId)
        assertTrue(not isYard)
        assertEquals(MODE.ON, mode)
        world.yards:applyOverride(farmlandId, mode)
        isYard, mode = world.yards:getToggle(farmlandId)
        assertTrue(isYard)
        assertEquals(MODE.AUTO, mode)
        world.yards:applyOverride(farmlandId, mode)
        assertTrue(not (world.yards:getToggle(farmlandId)))
    end
end)

test("a yard request is set only for the host or an admin, on a real farmland and mode", function()
    local world = setup()
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    world.texts.ui_on = "On"
    world.texts.ui_off = "Off"
    world:load("src/business/Settings.lua")
    world:load("src/events/TCYardOverrideEvent.lua")
    g_currentMission.TheContractor.Yards = world.yards
    -- Standing spots need the engine's ground checks.
    world.yards.refreshSpots = function() end
    world.broadcasts = {}
    g_server = { broadcastEvent = function(_, event) table.insert(world.broadcasts, event) end }
    world.admins = {}
    g_currentMission.userManager = {
        getIsConnectionMasterUser = function(_, connection)
            return world.admins[connection] == true
        end,
    }
    local function newConnection()
        return { getIsServer = function() return false end, getIsLocal = function() return false end }
    end
    local MODE = TheContractorYards.MODE

    local player = newConnection()
    TCYardOverrideEvent.new(4, MODE.ON):run(player)
    assertEquals(MODE.AUTO, world.yards:getOverride(4))
    assertEquals(0, #world.broadcasts)

    local admin = newConnection()
    world.admins[admin] = true
    TCYardOverrideEvent.new(42, MODE.ON):run(admin)
    TCYardOverrideEvent.new(4, 7):run(admin)
    assertEquals(0, #world.broadcasts)

    TCYardOverrideEvent.new(4, MODE.ON):run(admin)
    assertEquals(MODE.ON, world.yards:getOverride(4))
    assertEquals(1, #world.broadcasts)
    assertEquals(4, world.broadcasts[1].farmlandId)

    -- And a client applies what the server sends.
    local client = TheContractorYards.new()
    g_currentMission.TheContractor.Yards = client
    TCYardOverrideEvent.new(4, MODE.ON):run({ getIsServer = function() return true end })
    assertEquals(MODE.ON, client:getOverride(4))
end)
