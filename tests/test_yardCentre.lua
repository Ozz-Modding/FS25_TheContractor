-- 146: yard centre markers - a marker on a yard's farmland is its middle,
-- ahead of its buildings and its farmland's label; it's never one of the
-- yard's buildings; only a marker that's placed counts; and where one may
-- be placed.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    world:load("src/business/Yards.lua")
    world:load("src/placeables/PlaceableTCYardCentre.lua")
    PlaceablePropertyState = { CONSTRUCTION_PREVIEW = 4, OWNED = 1 }

    -- Farmlands 1-9, each with its label at (id * 100, 0); farmland 3 owned
    -- by farm 1.
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
    function world:addBuilding(def)
        local placeable = {
            isPreplaced = true,
            boughtWithFarmland = true,
            storeItem = { categoryName = def.category, name = def.category },
        }
        function placeable:getFarmlandId() return def.farmlandId end
        function placeable:getPosition() return def.x or 0, 0, def.z or 0 end
        table.insert(self.placeables, placeable)
        return placeable
    end
    -- A yard centre marker: def { farmlandId, x, z, propertyState }.
    function world:addMarker(def)
        local placeable = {
            boughtWithFarmland = false,
            propertyState = def.propertyState or PlaceablePropertyState.OWNED,
            storeItem = { categoryName = "MISC", name = "Yard Centre Marker" },
            [PlaceableTCYardCentre.KEY] = {},
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

test("a declared yard's middle is its marker, not its farmland's label", function()
    local world = setup()
    local FROM = TheContractorYards.MIDDLE_FROM
    world.yards:applyOverride(8, TheContractorYards.MODE.ON)

    local yard = findEntry((world:detect()), 8)
    assertEquals(800, yard.x)
    assertEquals(FROM.LABEL, yard.middleFrom)

    world:addMarker({ farmlandId = 8, x = 870, z = -40 })
    yard = findEntry((world:detect()), 8)
    assertEquals(870, yard.x)
    assertEquals(-40, yard.z)
    assertEquals(FROM.MARKER, yard.middleFrom)
    -- The marker isn't a building of the yard, or one left out.
    assertEquals(nil, yard.group)
    assertEquals(0, #TheContractorYards.getExcludedOn(world.placeables, 8))
end)

test("a detected yard's marker moves its middle off its buildings", function()
    local world = setup()
    local FROM = TheContractorYards.MIDDLE_FROM
    world:addBuilding({ farmlandId = 6, category = "SHEDS", x = 10, z = 20 })
    world:addBuilding({ farmlandId = 6, category = "SILOS", x = 30, z = 40 })

    local yard = findEntry((world:detect()), 6)
    assertEquals(20, yard.x)
    assertEquals(FROM.BUILDINGS, yard.middleFrom)

    world:addMarker({ farmlandId = 6, x = 300, z = 400 })
    yard = findEntry((world:detect()), 6)
    assertEquals(300, yard.x)
    assertEquals(400, yard.z)
    assertEquals(FROM.MARKER, yard.middleFrom)
    assertEquals(2, #yard.group.buildings)
end)

test("a marker makes no yard on its own, and a ruled-out yard ignores it", function()
    local world = setup()
    world:addMarker({ farmlandId = 5, x = 500, z = 0 })
    local yards, nearMisses = world:detect()
    assertEquals(0, #yards)
    assertEquals(0, #nearMisses)

    world:addBuilding({ farmlandId = 6, category = "SHEDS", x = 10, z = 20 })
    world:addBuilding({ farmlandId = 6, category = "SILOS", x = 30, z = 40 })
    world:addMarker({ farmlandId = 6, x = 300, z = 400 })
    world.yards:applyOverride(6, TheContractorYards.MODE.OFF)
    yards = world:detect()
    assertEquals(nil, findEntry(yards, 6))
end)

test("only a placed marker counts: not the cursor's preview, or one being removed", function()
    local world = setup()
    local FROM = TheContractorYards.MIDDLE_FROM
    world.yards:applyOverride(8, TheContractorYards.MODE.ON)

    local preview = world:addMarker({ farmlandId = 8, x = 870, z = 0,
        propertyState = PlaceablePropertyState.CONSTRUCTION_PREVIEW })
    assertEquals(FROM.LABEL, findEntry((world:detect()), 8).middleFrom)

    local placed = world:addMarker({ farmlandId = 8, x = 860, z = 0 })
    assertEquals(860, findEntry((world:detect()), 8).x)
    assertEquals(placed, TheContractorYards.findCentreMarker(world.placeables, 8))
    -- Placing a second: the one being placed doesn't count against itself.
    assertEquals(placed, TheContractorYards.findCentreMarker(world.placeables, 8, preview))
    assertEquals(nil, TheContractorYards.findCentreMarker(world.placeables, 8, placed))

    placed.isDeleting = true
    assertEquals(FROM.LABEL, findEntry((world:detect()), 8).middleFrom)
    assertEquals(nil, TheContractorYards.findCentreMarker(world.placeables, 8))
end)

test("a marker goes only on a yard no player owns, with none there yet, by the host or an admin", function()
    setup()
    local E = PlaceableTCYardCentre.PLACEMENT_ERROR
    local get = PlaceableTCYardCentre.getPlacementError
    assertEquals(nil, get(true, 0, true, false))
    assertEquals(E.NO_PERMISSION, get(false, 0, true, false))
    assertEquals(E.OWNED, get(true, 1, true, false))
    assertEquals(E.NOT_A_YARD, get(true, 0, false, false))
    assertEquals(E.TAKEN, get(true, 0, true, true))
    -- Permission first, then the land.
    assertEquals(E.NO_PERMISSION, get(false, 1, false, true))
    assertEquals(E.OWNED, get(true, 1, false, true))
end)

test("the cursor check reads the live map, and keeps a farmland's verdict briefly", function()
    local world = setup()
    g_currentMission.TheContractor = { Yards = world.yards }
    g_currentMission.placeableSystem = { placeables = world.placeables }
    g_farmlandManager.getFarmlandIdAtWorldPosition = function(_, x, z)
        return math.floor(x / 100)
    end
    world.canChange = true
    TheContractorSettings = { getCanLocalPlayerChange = function() return world.canChange end }
    world.yards:applyOverride(8, TheContractorYards.MODE.ON)

    local marker = world:addMarker({ farmlandId = 8, propertyState = PlaceablePropertyState.CONSTRUCTION_PREVIEW })
    local function superFunc() return true, nil end
    local function check(x)
        local canPlace = PlaceableTCYardCentre.getCanBePlacedAt(marker, superFunc, x, 0, 0, 1)
        return canPlace
    end

    g_time = 0
    assertTrue(check(850))
    -- Farmland 5 isn't a yard, and 3 is a player's.
    assertEquals(false, check(550))
    assertEquals(PlaceableTCYardCentre.PLACEMENT_ERROR.NOT_A_YARD, marker[PlaceableTCYardCentre.KEY].check.error)
    assertEquals(false, check(350))
    assertEquals(PlaceableTCYardCentre.PLACEMENT_ERROR.OWNED, marker[PlaceableTCYardCentre.KEY].check.error)

    -- Back on 8 an admin's lost their rights: a new farmland is checked at once...
    world.canChange = false
    assertEquals(false, check(850))
    -- ...and the same farmland keeps its verdict until it's stale.
    world.canChange = true
    g_time = 100
    assertEquals(false, check(860))
    g_time = 100 + PlaceableTCYardCentre.CHECK_CACHE_MS + 1
    assertTrue(check(860))

    -- Another marker already on the yard.
    world:addMarker({ farmlandId = 8, x = 820 })
    g_time = g_time + PlaceableTCYardCentre.CHECK_CACHE_MS + 1
    assertEquals(false, check(860))
    assertEquals(PlaceableTCYardCentre.PLACEMENT_ERROR.TAKEN, marker[PlaceableTCYardCentre.KEY].check.error)
end)

test("placing or removing a marker redoes its yard's spots on the server, once the yards are set up", function()
    local world = setup()
    g_currentMission.TheContractor = { Yards = world.yards }
    world.refreshed = {}
    world.yards.refreshSpots = function(_, farmlandId) table.insert(world.refreshed, farmlandId) end
    local marker = world:addMarker({ farmlandId = 8, x = 820 })
    marker.isServer = true

    -- A savegame's placeables load before setUp, which does every yard.
    PlaceableTCYardCentre.onFinalizePlacement(marker)
    assertEquals(0, #world.refreshed)

    world.yards.isSetUp = true
    PlaceableTCYardCentre.onFinalizePlacement(marker)
    PlaceableTCYardCentre.onPreDelete(marker)
    assertEquals(2, #world.refreshed)
    assertEquals(8, world.refreshed[1])

    -- A client leaves it to the server.
    marker.isServer = false
    PlaceableTCYardCentre.onFinalizePlacement(marker)
    assertEquals(2, #world.refreshed)
end)
