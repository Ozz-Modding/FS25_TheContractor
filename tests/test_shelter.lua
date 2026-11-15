-- 155: shelter from the weather. Rain, snow, hail or a twister make it wet,
-- read from the weather's synced type when the weather changes (not
-- polled); while it's wet only spots indoors (vanilla's indoor mask) are in
-- use, for our staff and for farmers in their yards, placed spots or
-- generated; with none indoors they go out of sight. Dry again, everything
-- is back.

local world

local function setup()
    world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    dofile("src/business/Worker.lua")
    dofile("src/business/WorkingHours.lua")
    dofile("src/business/Office.lua")
    dofile("src/business/Yards.lua")
    dofile("src/placeables/PlaceableTCParkingSlot.lua")
    dofile("src/placeables/PlaceableTCStandingSpot.lua")
    dofile("src/placeables/PlaceableTCSeatSpot.lua")
    dofile("src/util/TCIdleStaff.lua")
    dofile("src/util/TCShelter.lua")
    dofile("src/util/TCFarmerYardSpots.lua")
    dofile("src/util/TCYardFarmers.lua")
    PlaceablePropertyState = { CONSTRUCTION_PREVIEW = 4, OWNED = 1 }
    WeatherType = { SUN = 1, CLOUDY = 3, RAIN = 4, SNOW = 5, HAIL = 6, TWISTER = 7 }
    MessageType = { WEATHER_CHANGED = "weatherChanged", HOUR_CHANGED = "hourChanged" }

    entityExists = function() return true end
    getWorldTranslation = function(node) return node.x, 0, node.z end
    localDirectionToWorld = function() return 0, 0, 1 end
    g_terrainNode = 1
    getTerrainHeightAtWorldPos = function() return 0 end
    MathUtil = {
        getYRotationFromDirection = function(dx, dz) return math.atan2(dx, dz) end,
        vector2Length = function(x, z) return math.sqrt(x * x + z * z) end,
        vector3Length = function(x, y, z) return math.sqrt(x * x + y * y + z * z) end,
    }

    -- Farmlands 1-9, 100 m wide along x; farmland 3 is farm 1's.
    world.owners = { [3] = 1 }
    g_farmlandManager = {
        getIsValidFarmlandId = function(_, farmlandId)
            return farmlandId ~= nil and farmlandId >= 1 and farmlandId <= 9
        end,
        getFarmlandOwner = function(_, farmlandId)
            return world.owners[farmlandId] or 0
        end,
    }

    -- Indoors: x positions listed in world.indoor.
    world.indoor = {}
    g_currentMission.indoorMask = {
        getIsIndoorAtWorldPosition = function(_, x, z)
            return world.indoor[x] == true
        end,
    }
    world.weatherType = WeatherType.SUN
    world.weatherReady = true
    g_currentMission.environment = {
        currentMonotonicDay = 10,
        dayTime = 12 * 3600000,
        weather = {
            getIsReady = function() return world.weatherReady end,
            getCurrentWeatherType = function() return world.weatherType end,
        },
    }
    world.subscriptions = {}
    g_messageCenter = {
        subscribe = function(_, messageType, callback, target)
            world.subscriptions[messageType] = { callback = callback, target = target }
        end,
        unsubscribeAll = function(_, target)
            for messageType, entry in pairs(world.subscriptions) do
                if entry.target == target then
                    world.subscriptions[messageType] = nil
                end
            end
        end,
    }
    function world:publish(messageType, ...)
        local entry = self.subscriptions[messageType]
        if entry ~= nil then
            entry.callback(entry.target, ...)
        end
    end

    g_currentMission.placeableSystem = { placeables = {} }
    g_currentMission.TheContractor.Staff = { workersByFarm = {} }
    g_currentMission.TheContractor.Office = TheContractorOffice.new()
    world.farmers = {}
    g_currentMission.TheContractor.Farmers = {
        getFarmers = function()
            return world.farmers
        end,
    }
    world.yards = TheContractorYards.new()
    g_currentMission.TheContractor.Yards = world.yards
    TCShelter.install()
end

local function addSpot(farmId, x, staffIds)
    local spot = { farmId = farmId, propertyState = PlaceablePropertyState.OWNED }
    spot[PlaceableTCStandingSpot.KEY] = {
        standNode = { x = x, z = 0 },
        filter = PlaceableTCStandingSpot.newFilter(staffIds),
    }
    function spot:getOwnerFarmId() return self.farmId end
    function spot:getFarmlandId() return math.floor(x / 100) end
    table.insert(g_currentMission.placeableSystem.placeables, spot)
    return spot
end

local function addWorker(farmId, id)
    local workersByFarm = g_currentMission.TheContractor.Staff.workersByFarm
    workersByFarm[farmId] = workersByFarm[farmId] or {}
    local worker = { id = id, farmId = farmId, name = "Worker " .. id, status = TheContractorWorker.STATUS.IDLE }
    workersByFarm[farmId][id] = worker
    return worker
end

local function addFarmer(id, yardFarmlandId)
    local person = { id = id, name = "Farmer " .. id, yardFarmlandId = yardFarmlandId, farmlandIds = {} }
    table.insert(world.farmers, person)
    return person
end

local function setWeather(weatherType)
    world.weatherType = weatherType
    world:publish(MessageType.WEATHER_CHANGED, { weatherType = weatherType })
end

test("rain, snow, hail and a twister are wet; sun and cloud aren't", function()
    setup()
    for _, name in ipairs({ "RAIN", "SNOW", "HAIL", "TWISTER" }) do
        assertTrue(TCShelter.isWetType(WeatherType[name]), name)
    end
    for _, name in ipairs({ "SUN", "CLOUDY" }) do
        assertTrue(not TCShelter.isWetType(WeatherType[name]), name)
    end
    assertTrue(not TCShelter.isWetType(nil))
end)

test("wet or dry follows the weather changing, the hour as a backstop, never read while it's not ready", function()
    setup()
    assertEquals(false, TCShelter.isWet)
    setWeather(WeatherType.RAIN)
    assertEquals(true, TCShelter.isWet)
    setWeather(WeatherType.CLOUDY)
    assertEquals(false, TCShelter.isWet)

    -- A change missed: the next hour picks it up.
    world.weatherType = WeatherType.SNOW
    world:publish(MessageType.HOUR_CHANGED)
    assertEquals(true, TCShelter.isWet)

    -- Not ready yet (a client before the forecast's in): left as it was.
    world.weatherReady = false
    world.weatherType = WeatherType.SUN
    TCShelter.refresh()
    assertEquals(true, TCShelter.isWet)

    -- Set at install from the weather as it is.
    world.weatherReady = true
    world.weatherType = WeatherType.HAIL
    TCShelter.uninstall()
    assertEquals(nil, world.subscriptions[MessageType.WEATHER_CHANGED])
    TCShelter.install()
    assertEquals(true, TCShelter.isWet)
end)

test("in wet weather staff only use indoor spots, kept spots outdoors included; dry, all of them", function()
    setup()
    local outdoor = addSpot(1, 310)
    local kept = addSpot(1, 320, { 8 })
    local indoor = addSpot(1, 330)
    world.indoor[330] = true
    addWorker(1, 7)
    addWorker(1, 8)

    setWeather(WeatherType.RAIN)
    local wanted = TCIdleStaff.getWanted()
    local count = 0
    for _, entry in pairs(wanted) do
        assertTrue(entry.spot.placeable == indoor, "only the indoor spot")
        count = count + 1
    end
    assertEquals(1, count, "one indoor spot, one person on it; the other's inside out of sight")

    setWeather(WeatherType.SUN)
    wanted = TCIdleStaff.getWanted()
    assertTrue(wanted[8].spot.placeable == kept, "back on their kept spot")
    assertTrue(wanted[7] ~= nil)
    assertTrue(wanted[7].spot.placeable == outdoor or wanted[7].spot.placeable == indoor)
end)

test("in wet weather a farmer uses their yard's indoor placed spots, or goes in; never the generated ones", function()
    setup()
    world.yards:applySpots(5, { x = 500, z = 0, spots = { { x = 504, z = 0 }, { x = 508, z = 0 } } })
    addFarmer(2, 5)
    local outdoor = addSpot(1, 520)
    local indoor = addSpot(1, 540)
    world.indoor[540] = true

    setWeather(WeatherType.SNOW)
    for hour = 7, 18, 3 do
        g_currentMission.environment.dayTime = hour * 3600000
        assertTrue(TCYardFarmers.getWanted()[2].spot.placeable == indoor)
    end

    world.indoor[540] = nil
    assertEquals(nil, TCYardFarmers.getWanted()[2], "nowhere under cover: indoors")
    world.indoor[504] = true
    assertEquals(nil, TCYardFarmers.getWanted()[2], "a yard with placed spots never falls back on generated ones")

    setWeather(WeatherType.SUN)
    local spot = TCYardFarmers.getWanted()[2].spot
    assertTrue(spot.placeable == outdoor or spot.placeable == indoor)
end)

test("a yard with only generated spots: in wet weather only those under cover, else the farmer's in", function()
    setup()
    world.yards:applySpots(5, { x = 500, z = 0, spots = {
        { x = 504, z = 0, nearHouse = true }, { x = 508, z = 0 }, { x = 512, z = 0 } } })
    addFarmer(2, 5)

    setWeather(WeatherType.HAIL)
    assertEquals(nil, TCYardFarmers.getWanted()[2])
    world.indoor[512] = true
    for hour = 7, 18, 3 do
        g_currentMission.environment.dayTime = hour * 3600000
        local spot = TCYardFarmers.getWanted()[2].spot
        assertEquals(512, spot.x, "the one under cover, never the farmhouse's outdoor one")
        assertEquals("5:3", spot.key, "keyed by its place in the yard's list")
    end
end)
