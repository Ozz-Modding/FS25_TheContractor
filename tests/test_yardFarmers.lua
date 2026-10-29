-- 114: farmers standing in their yards - who's about (daylight, a yard no
-- player owns, with open spots), the spot every machine picks from the
-- server's synced list (through a client join and a refresh), a new spot
-- some slots of the day, favouring the farmhouse but not always, and which
-- way they face.

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
    local withHouse = spotsEntry(12)
    withHouse.spots[3].nearHouse = true
    world.yards:applySpots(5, withHouse)
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

    assertTrue(client:getSpots(5).spots[3].nearHouse)
    assertTrue(not client:getSpots(5).spots[4].nearHouse)
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

test("one spot through a slot, a new one in some slots, and every spot gets used", function()
    local world = setup()
    world.yards:applySpots(5, spotsEntry(5))
    addFarmer(world, 2, 5)

    setHour(7)
    local early = TCYardFarmers.getWanted()[2].spot.key
    setHour(9.9)
    assertEquals(early, TCYardFarmers.getWanted()[2].spot.key, "the same slot")

    local used, moves, last, slots = {}, 0, nil, 0
    for day = 1, 15 do
        g_currentMission.environment.currentMonotonicDay = day
        for _, hour in ipairs({ 8, 11, 14, 17 }) do
            setHour(hour)
            local key = TCYardFarmers.getWanted()[2].spot.key
            used[key] = true
            if last ~= nil and key ~= last then
                moves = moves + 1
            end
            last = key
            slots = slots + 1
        end
    end
    local count = 0
    for _ in pairs(used) do
        count = count + 1
    end
    assertEquals(5, count)
    assertTrue(moves > (slots - 1) / 2, "moved in " .. moves .. " of " .. (slots - 1) .. " slots")
end)

test("a yard with a farmhouse: near it about half the slots, and on other spots too", function()
    local world = setup()
    -- 10 spots, the first 2 near the house.
    local entry = spotsEntry(10)
    entry.spots[1].nearHouse = true
    entry.spots[2].nearHouse = true
    world.yards:applySpots(5, entry)
    addFarmer(world, 2, 5)

    local near, slots = 0, 0
    for day = 1, 100 do
        g_currentMission.environment.currentMonotonicDay = day
        for _, hour in ipairs({ 8, 11, 14, 17 }) do
            setHour(hour)
            if TCYardFarmers.getWanted()[2].spot.nearHouse then
                near = near + 1
            end
            slots = slots + 1
        end
    end
    -- Half by the roll, plus a fifth of the other half landing there anyway.
    assertTrue(near > slots * 0.45 and near < slots * 0.75, near .. " of " .. slots .. " slots near the house")
end)

test("a spot is near the house within the distance of its footprint, and only a farmhouse's", function()
    setup()
    local footprint = { { x = 0, z = 0 }, { x = 20, z = 0 }, { x = 20, z = 10 }, { x = 0, z = 10 } }
    local house = { category = "FARMHOUSES", x = 10, z = 5, footprints = { footprint } }
    local shed = { category = "SHEDS", x = 100, z = 5, footprints = {} }
    local buildings = { house, shed }
    local reach = TheContractorYards.NEAR_HOUSE_DISTANCE

    assertTrue(TheContractorYards.isNearHouse(buildings, 10, -reach + 1), "off the long side")
    assertTrue(not TheContractorYards.isNearHouse(buildings, 10, -reach - 1))
    assertTrue(TheContractorYards.isNearHouse(buildings, 20 + reach - 1, 5), "off the far end, by the edge")
    assertTrue(not TheContractorYards.isNearHouse(buildings, 100, 5 + 2), "beside the shed")

    -- A house without a footprint: from its position.
    house.footprints = {}
    assertTrue(not TheContractorYards.isNearHouse(buildings, 20 + reach - 1, 5))
    assertTrue(TheContractorYards.isNearHouse(buildings, 10 + reach - 1, 5))

    local yard = { farmlandId = 5, x = 50, z = 5, group = { buildings = buildings } }
    local made = TheContractorYards.makeSpotsEntry(yard, { { x = 10, z = 12 }, { x = 60, z = 40 } })
    assertTrue(made.spots[1].nearHouse)
    assertTrue(not made.spots[2].nearHouse)
end)

test("two farmers in the same slot don't share a pattern", function()
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

-- 116: farmer 2's favour (job 7, farm 1) with its machine at (100, 50),
-- facing +x, 3 m wide and 6 long; in yard 5 if yard is true.
local function addFavour(world, yard)
    TheContractorJob = { STATE = { OFFERED = 1, NEGOTIATING = 2, ACCEPTED = 3, COMPLETED = 4 } }
    local vehicle = { rootNode = { x = 100, z = 50, dirX = 1, dirZ = 0 }, size = { width = 3, length = 6 } }
    TheContractorRepairContracts = {
        isFavourJob = function(job) return job.favour == true end,
        getVehicle = function(job) return job.workshop.vehicleId == 9 and vehicle or nil end,
    }
    getWorldTranslation = function(node) return node.x, 0, node.z end
    localDirectionToWorld = function(node) return node.dirX, 0, node.dirZ end
    local job = { id = 7, favour = true, state = TheContractorJob.STATE.OFFERED, customerId = 2,
        workshop = { vehicleId = 9, yardFarmlandId = yard and 5 or nil } }
    g_currentMission.TheContractor.Jobs = { jobsByFarm = { [1] = { [7] = job } } }
    return job, vehicle
end

test("a farmer with a favour open waits beside its machine, facing it, day or night", function()
    local world = setup()
    world.yards:applySpots(5, spotsEntry(3))
    addFarmer(world, 2, nil)
    local job = addFavour(world, false)

    setHour(23)
    local spot = TCYardFarmers.getWanted()[2].spot
    -- Facing +x, its sides are 2.5 m north or south, 1.5 m ahead of its middle.
    assertNear(101.5, spot.x, 0.0001)
    assertNear(2.5, math.abs(spot.z - 50), 0.0001)
    local yaw = math.atan2(100 - spot.x, 50 - spot.z)
    assertNear(yaw, spot.yaw, 0.0001)

    -- Done, or the machine not on this map: back to the yard (or nowhere).
    job.state = TheContractorJob.STATE.COMPLETED
    assertEquals(nil, TCYardFarmers.getWanted()[2])
    job.state = TheContractorJob.STATE.ACCEPTED
    job.workshop.vehicleId = 0
    assertEquals(nil, TCYardFarmers.getWanted()[2])
end)

test("in a yard the farmer stands on the machine's side nearer the yard's middle, and moves with it", function()
    local world = setup()
    -- The yard's middle north of the machine.
    world.yards:applySpots(5, spotsEntry(3, 100, 80))
    addFarmer(world, 2, 5)
    local _, vehicle = addFavour(world, true)

    local spot = TCYardFarmers.getWanted()[2].spot
    assertNear(52.5, spot.z, 0.0001)
    vehicle.rootNode.z = 20
    local moved = TCYardFarmers.getWanted()[2].spot
    assertNear(22.5, moved.z, 0.0001)
    assertTrue(moved.key ~= spot.key, "a new spot once the machine's moved")
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
