-- Parking (062): once a return's machines are all parked, the farm is told
-- which ones are back - not before, and not for any that went to the shop.

local function setup()
    local world = stubs.install()

    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    TheContractorInbox = { DISMISS_ACTION = { key = "dismiss" } }

    -- The spot finder hands out world.freeSpots places, then nothing.
    world.freeSpots = 0
    TCParking = {
        findSpot = function()
            if world.freeSpots > 0 then
                world.freeSpots = world.freeSpots - 1
                return 0, 0, 0, 0
            end
            return nil
        end,
        findShopSpot = function()
            return 0, 0, 0, 0
        end,
        placeVehicle = function() end,
    }
    TCJobSiteSetup = { unhitchVehicles = function() end }
    TCEquipmentVisibility = { setVisibleEverywhere = function() end, isHidden = function() return true end }
    TCVehicleLock = { refresh = function() end }

    local tc = g_currentMission.TheContractor
    tc.Cooldown = { isVehicleInCooldown = function() return false end }
    tc.Notices = { publish = function() return 1 end, remove = function() end }

    dofile("src/events/TCParkingNoticeEvent.lua")
    dofile("src/business/Parking.lua")

    local parking = TheContractorParking.new()
    -- What the farm was told: { key, names (the arg), isGood }.
    world.told = {}
    local notify = parking.notify
    parking.notify = function(self, farmId, textKey, arg, isGood)
        table.insert(world.told, { key = textKey, names = arg, isGood = isGood })
        return notify(self, farmId, textKey, arg, isGood)
    end
    parking:register({
        registerMessageKind = function() end,
        postMessage = function() return 1 end,
        removeMessage = function() end,
    })
    tc.Parking = parking
    return world, parking
end

local function addMachine(world, name)
    local vehicle = world:addVehicle({ name = name })
    function vehicle:getFullName() return self.name end
    return vehicle.id
end

local function pass(parking)
    parking.accumulatedMs = parking.intervalMs
    parking:update(0)
end

local function returnedNotifications(world)
    local found = {}
    for _, told in ipairs(world.told) do
        if told.key == "tc_parking_returnedNotification" then
            table.insert(found, told)
        end
    end
    return found
end

test("the farm hears once, when the last machine of a return is parked", function()
    local world, parking = setup()
    world.freeSpots = 2
    parking:returnVehicles(1, { addMachine(world, "Combine"), addMachine(world, "Header") })

    pass(parking)
    assertEquals(#returnedNotifications(world), 0, "one of two parked")

    pass(parking)
    local found = returnedNotifications(world)
    assertEquals(#found, 1)
    assertEquals(found[1].names, "Combine, Header")
    assertTrue(found[1].isGood, "good news")
end)

test("nothing is said while a machine is still waiting for a space", function()
    local world, parking = setup()
    world.freeSpots = 1
    parking:returnVehicles(1, { addMachine(world, "Combine"), addMachine(world, "Header") })

    pass(parking)
    pass(parking)
    assertEquals(#returnedNotifications(world), 0)

    world.freeSpots = 1
    pass(parking)
    assertEquals(returnedNotifications(world)[1].names, "Combine, Header")
end)

test("machines sent to the shop aren't listed as parked", function()
    local world, parking = setup()
    world.freeSpots = 1
    local combine = addMachine(world, "Combine")
    local header = addMachine(world, "Header")
    parking:returnVehicles(1, { combine, header })

    pass(parking)
    parking:sendToShop({ header })

    assertEquals(returnedNotifications(world)[1].names, "Combine")
end)

test("a return sent wholly to the shop says nothing", function()
    local world, parking = setup()
    local combine = addMachine(world, "Combine")
    parking:returnVehicles(1, { combine })

    parking:sendToShop({ combine })

    assertEquals(#returnedNotifications(world), 0)
end)
