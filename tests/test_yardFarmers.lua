-- 114: farmers standing in their yards - who's about (daylight, a yard no
-- player owns, with open spots), the spot every machine picks from the
-- server's synced list (through a client join and a refresh), a new spot
-- on a new day, and which way they face.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    world:load("src/business/Worker.lua")
    world:load("src/business/WorkingHours.lua")
    world:load("src/business/Yards.lua")
    world:load("src/util/TCIdleStaff.lua")
    world:load("src/util/TCYardFarmers.lua")
    world:load("src/events/TCYardSpotsEvent.lua")

    g_terrainNode = 1
    getTerrainHeightAtWorldPos = function(_, x, _, z) return 0.5 end
    MathUtil = { getYRotationFromDirection = function(dx, dz) return math.atan2(dx, dz) end }

    world.owners = {}
    g_farmlandManager = {
        getFarmlandOwner = function(_, farmlandId)
            return world.owners[farmlandId] or 0
        end,
    }

    g_currentMission.environment = { currentMonotonicDay = 10, dayTime = 12 * 3600000 }
    world.farmers = {}
    g_currentMission.TheContractor.Farmers = {
        getFarmers = function()
            return world.farmers
        end,
    }
    world.yards = TheContractorYards.new()
    g_currentMission.TheContractor.Yards = world.yards
    return world
end

local function addFarmer(world, id, yardFarmlandId)
    local person = { id = id, name = "Farmer " .. id, yardFarmlandId = yardFarmlandId, farmlandIds = {} }
    table.insert(world.farmers, person)
    return person
end

-- A yard's synced spots: count of them in a row east of the middle.
local function spotsEntry(count, x, z)
    local entry = { x = x or 0, z = z or 0, spots = {} }
    for i = 1, count do
        table.insert(entry.spots, { x = (x or 0) + i * 4, z = z or 0 })
    end
    return entry
end

local function setHour(hour)
    g_currentMission.environment.dayTime = hour * 3600000
end

test("a farmer is only about in daylight", function()
    local world = setup()
    world.yards:applySpots(5, spotsEntry(6))
    addFarmer(world, 2, 5)

    setHour(6.9)
    assertEquals(nil, TCYardFarmers.getWanted()[2])
    setHour(7)
    assertTrue(TCYardFarmers.getWanted()[2] ~= nil)
    setHour(18.9)
    assertTrue(TCYardFarmers.getWanted()[2] ~= nil)
    setHour(19)
    assertEquals(nil, TCYardFarmers.getWanted()[2])
end)

test("only a farmer with a yard on the map, no player owns it and it has spots", function()
    local world = setup()
    world.yards:applySpots(5, spotsEntry(6))
    world.yards:applySpots(6, spotsEntry(6, 500, 0))
    world.yards:applySpots(7, spotsEntry(0, 900, 0))
    addFarmer(world, 2, 5)
    addFarmer(world, 3, 6)
    addFarmer(world, 4, 7)
    addFarmer(world, 8, nil)
    world.owners[6] = 1

    local wanted = TCYardFarmers.getWanted()
    assertTrue(wanted[2] ~= nil)
    assertEquals(nil, wanted[3], "a player owns yard 6")
    assertEquals(nil, wanted[4], "yard 7 has no spots")
    assertEquals(nil, wanted[8], "no yard on the map")
    assertTrue(TCYardFarmers.getReason(world.farmers[2], world.yards):find("owned") ~= nil)
end)

test("a joined client puts the farmer on the same spot as the server", function()
    local world = setup()
    world.yards:applySpots(5, spotsEntry(12))
    world.yards:applySpots(9, spotsEntry(8, 300, 200))
    addFarmer(world, 2, 5)
    addFarmer(world, 3, 9)
    local serverWanted = TCYardFarmers.getWanted()

    local stream = world:newStream()
    world.yards:writeInitialClientState(stream)
    local client = TheContractorYards.new()
    client:readInitialClientState(stream)
    g_currentMission.TheContractor.Yards = client
    local clientWanted = TCYardFarmers.getWanted()

    for _, id in ipairs({ 2, 3 }) do
        assertEquals(serverWanted[id].spot.key, clientWanted[id].spot.key)
        assertNear(serverWanted[id].spot.x, clientWanted[id].spot.x, 0.001)
        assertNear(serverWanted[id].spot.z, clientWanted[id].spot.z, 0.001)
    end
end)

test("a refreshed yard's spots reach the clients, and a yard that's gone takes its farmer off", function()
    local world = setup()
    world.yards:applySpots(5, spotsEntry(3))
    addFarmer(world, 2, 5)
    local client = TheContractorYards.new()
    client:applySpots(5, spotsEntry(3))

    local stream = world:newStream()
    TCYardSpotsEvent.new(5, spotsEntry(9, 40, 40)):writeStream(stream)
    local event = TCYardSpotsEvent.emptyNew()
    g_currentMission.TheContractor.Yards = client
    event:readStream(stream, { getIsServer = function() return true end })
    assertEquals(9, #client:getSpots(5).spots)
    assertEquals(44, client:getSpots(5).spots[1].x)

    stream = world:newStream()
    TCYardSpotsEvent.new(5, nil):writeStream(stream)
    TCYardSpotsEvent.emptyNew():readStream(stream, { getIsServer = function() return true end })
    assertEquals(nil, client:getSpots(5))
    assertEquals(nil, TCYardFarmers.getWanted()[2])
end)

test("one spot all day, a new one some days, and every spot gets used", function()
    local world = setup()
    world.yards:applySpots(5, spotsEntry(5))
    addFarmer(world, 2, 5)

    setHour(8)
    local morning = TCYardFarmers.getWanted()[2].spot.key
    setHour(17)
    assertEquals(morning, TCYardFarmers.getWanted()[2].spot.key)

    local used, moves, last = {}, 0, nil
    for day = 1, 60 do
        g_currentMission.environment.currentMonotonicDay = day
        local key = TCYardFarmers.getWanted()[2].spot.key
        used[key] = true
        if last ~= nil and key ~= last then
            moves = moves + 1
        end
        last = key
    end
    local count = 0
    for _ in pairs(used) do
        count = count + 1
    end
    assertEquals(5, count)
    assertTrue(moves > 30, "moved on " .. moves .. " of 59 days")
end)

test("two farmers on the same day don't share a pattern", function()
    local world = setup()
    world.yards:applySpots(5, spotsEntry(10))
    world.yards:applySpots(6, spotsEntry(10))
    addFarmer(world, 2, 5)
    addFarmer(world, 3, 6)

    local same = 0
    for day = 1, 40 do
        g_currentMission.environment.currentMonotonicDay = day
        local wanted = TCYardFarmers.getWanted()
        if wanted[2].spot.x == wanted[3].spot.x then
            same = same + 1
        end
    end
    assertTrue(same < 15, "the same spot number on " .. same .. " of 40 days")
end)

test("a farmer faces the yard's middle, standing on the ground", function()
    local world = setup()
    -- One spot, 4 m east of a middle at (0, 0).
    world.yards:applySpots(5, spotsEntry(1))
    addFarmer(world, 2, 5)

    local spot = TCYardFarmers.getWanted()[2].spot
    assertNear(-math.pi / 2, spot.yaw, 0.0001)
    assertNear(0.5, spot.y, 0.0001)
end)
