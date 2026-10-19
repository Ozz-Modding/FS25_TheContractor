-- TheContractorDieselTheft (078) on the real random events framework (068):
-- what can be taken, the odds, both versions, the morning window and the
-- messages. 069's theft eligibility is faked: which machines count is its
-- own test's business.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    world.texts.ui_on = "On"
    world.texts.ui_off = "Off"
    for month = 1, 12 do
        world.texts["ui_month" .. month] = "Month " .. month
    end

    Environment = { PERIODS_IN_YEAR = 12 }
    g_currentMission.environment = {
        currentYear = 1,
        currentPeriod = 1,
        currentDayInPeriod = 1,
        daysPerPeriod = 1,
        plannedDaysPerPeriod = 1,
        currentMonotonicDay = 1,
        currentHour = 0,
    }
    g_farmManager.getFarmById = function(_, farmId)
        return { farmId = farmId }
    end

    TCJobSupplies = {
        getDieselConsumer = function(vehicle)
            local spec = vehicle.spec_motorized
            return spec ~= nil and spec.consumersByFillType[FillType.DIESEL] or nil
        end,
    }

    world:load("src/util/TCCalendar.lua")
    world:load("src/util/TCConsole.lua")
    world:load("src/business/Settings.lua")
    world:load("src/business/RandomEvents.lua")
    world:load("src/business/DieselTheft.lua")

    TCRandomEventIncidentEvent = {
        new = function(incident, isClosed)
            return { incident = incident, isClosed = isClosed }
        end,
    }

    world.messages, world.notices, world.parked = {}, {}, {}

    local tc = g_currentMission.TheContractor
    tc.Settings = TheContractorSettings.new()
    tc.Company = { companyNames = { [1] = "Test Contracting" } }
    tc.Inbox = {
        registerMessageKind = function() end,
        postMessage = function(_, farmId, kind, titleKey, bodyKey, args)
            -- Rendered as the client would ($volume_ included).
            local resolved = {}
            for i, arg in ipairs(args) do
                if type(arg) == "string" and string.sub(arg, 1, 8) == "$volume_" then
                    resolved[i] = g_i18n:formatVolume(tonumber(string.sub(arg, 9)), 0)
                else
                    resolved[i] = arg
                end
            end
            table.insert(world.messages, { farmId = farmId, kind = kind, titleKey = titleKey,
                body = string.format(g_i18n:getText(bodyKey), unpack(resolved)) })
            return #world.messages
        end,
    }
    tc.Notices = {
        publish = function(_, farmId, text)
            table.insert(world.notices, text)
        end,
    }
    -- 069's eligibility: whatever's in world.parked.
    tc.Theft = {
        getEligibleVehicles = function(_, farmId)
            local result = {}
            for _, vehicle in ipairs(world.parked) do
                if vehicle.farmId == farmId then
                    table.insert(result, { vehicle = vehicle, weight = 1 })
                end
            end
            return result
        end,
    }
    tc.RandomEvents = TheContractorRandomEvents.new()
    tc.DieselTheft = TheContractorDieselTheft.new()
    tc.DieselTheft:register(tc.RandomEvents, tc.Inbox, tc.Theft)

    function world:addParked(def)
        local vehicle = self:addVehicle({ name = def.name, farmId = def.farmId, dieselUsagePerHour = 10,
            dieselCapacity = def.capacity or 400, dieselLevel = def.level })
        table.insert(self.parked, vehicle)
        return vehicle
    end

    function world:addDieselTank(level, farmId)
        return self:addStorage({ farmId = farmId, levels = { [FillType.DIESEL] = level } })
    end

    return world, tc
end

local function getDiesel(vehicle)
    return vehicle:getFillUnitFillLevel(TCJobSupplies.getDieselConsumer(vehicle).fillUnitIndex)
end

test("nothing to take means no odds and no event", function()
    local world, tc = setup()
    world:addDieselTank(50)
    world:addParked({ name = "dry", level = 5 })
    world:addDieselTank(5000, 2)
    world:addParked({ name = "neighbours", farmId = 2 })

    assertEquals(tc.DieselTheft:getRatePerPeriod(1), 0, "rate")
    assertEquals(tc.DieselTheft:pickVariant(1, 0), nil, "nothing to act on")
end)

test("the version follows what there is to take", function()
    local world, tc = setup()
    world:addParked({ name = "tractor" })
    assertEquals(tc.DieselTheft:pickVariant(1, 0).variant, "siphon", "machines only")
    assertEquals(tc.DieselTheft:getRatePerPeriod(1), TheContractorDieselTheft.RATE_PER_PERIOD, "rate")

    world:addDieselTank(2000)
    assertEquals(tc.DieselTheft:pickVariant(1, 0).variant, "tank", "both, low roll")
    assertEquals(tc.DieselTheft:pickVariant(1, 0.99).variant, "siphon", "both, high roll")

    world.parked = {}
    assertEquals(tc.DieselTheft:pickVariant(1, 0.99).variant, "tank", "tank only")
end)

test("there's no cooldown", function()
    local _, tc = setup()
    assertEquals(tc.RandomEvents:getEventType("dieselTheft").cooldownPeriods, 0, "none")
end)

test("a drained tank loses a share of what's in it, capped", function()
    local world, tc = setup()
    local small = world:addDieselTank(1000)
    local incident = tc.RandomEvents:triggerEvent(1, "dieselTheft")
    assertEquals(incident.data.variant, "tank", "tank")
    local left = small:getFillLevel(FillType.DIESEL)
    assertEquals(incident.data.liters, 1000 - left, "recorded what went")
    assertTrue(incident.data.liters >= 400 and incident.data.liters <= 900, "40-90%: " .. incident.data.liters)

    local world2, tc2 = setup()
    local big = world2:addDieselTank(20000)
    local smaller = world2:addDieselTank(15000)
    local incident2 = tc2.RandomEvents:triggerEvent(1, "dieselTheft")
    assertEquals(incident2.data.liters, TheContractorDieselTheft.TANK_MAX_LITERS, "capped")
    assertEquals(big:getFillLevel(FillType.DIESEL), 20000 - TheContractorDieselTheft.TANK_MAX_LITERS,
        "from the fullest")
    assertEquals(smaller:getFillLevel(FillType.DIESEL), 15000, "the other's left alone")

    assertEquals(#world.messages, 1, "one message")
    assertEquals(world.messages[1].titleKey, "tc_dieselTheft_tankTitle", "tank message")
    assertTrue(string.find(world.messages[1].body, incident.data.liters .. " l", 1, true) ~= nil,
        "litres in the body: " .. world.messages[1].body)
    assertEquals(#world.notices, 1, "a notice")
    assertEquals(next(tc.RandomEvents.incidents), nil, "over at once")
end)

test("siphoning takes from a few eligible machines only", function()
    local world, tc = setup()
    local machines = {}
    for i = 1, 7 do
        table.insert(machines, world:addParked({ name = "tractor" .. i, level = 400 }))
    end
    local dry = world:addParked({ name = "dry", level = 10 })
    local busy = world:addVehicle({ name = "busy", dieselUsagePerHour = 10, dieselLevel = 400 })

    local incident = tc.RandomEvents:triggerEvent(1, "dieselTheft")
    assertEquals(incident.data.variant, "siphon", "siphon")

    local count, taken = 0, 0
    for _, vehicle in ipairs(machines) do
        local level = getDiesel(vehicle)
        if level < 400 then
            count = count + 1
            taken = taken + 400 - level
            assertTrue(level >= 40 and level <= 200, "50-90% of the tank: " .. level)
        end
    end
    assertTrue(count >= 2 and count <= 5, "2-5 machines: " .. count)
    assertEquals(incident.data.vehicleCount, count, "count recorded")
    assertEquals(incident.data.liters, taken, "litres recorded")
    assertEquals(getDiesel(dry), 10, "too little to bother with")
    assertEquals(getDiesel(busy), 400, "not one 069 would take")

    assertEquals(world.messages[1].titleKey, "tc_dieselTheft_siphonTitle", "siphon message")
    assertTrue(string.find(world.messages[1].body, count .. " of your parked machines", 1, true) ~= nil,
        "count in the body: " .. world.messages[1].body)
end)

test("one parked machine is all that's siphoned if it's all there is", function()
    local world, tc = setup()
    local only = world:addParked({ name = "tractor", level = 300 })
    local incident = tc.RandomEvents:triggerEvent(1, "dieselTheft")
    assertEquals(incident.data.vehicleCount, 1, "one")
    assertTrue(getDiesel(only) < 300, "taken")
end)

test("it's found between 07:00 and 09:00, and nothing's said if there's nothing left by then", function()
    local world, tc = setup()
    local tank = world:addDieselTank(1000)
    -- A certain hit: a high rate at 1 day a month.
    TheContractorDieselTheft.RATE_PER_PERIOD = 1

    tc.RandomEvents:rollNewEvents()
    assertEquals(tank:getFillLevel(FillType.DIESEL), 1000, "nothing taken at midnight")
    local hour = tc.RandomEvents.pendingTriggers[1].hour
    assertTrue(hour >= 7 and hour <= 8, "found 07:00-09:00")

    g_currentMission.environment.currentHour = hour
    tc.RandomEvents:firePendingTriggers()
    assertTrue(tank:getFillLevel(FillType.DIESEL) < 1000, "taken in the morning")
    assertEquals(#world.messages, 1, "message")

    -- Rolled at midnight, but the farm used it all before the morning.
    local environment = g_currentMission.environment
    environment.currentMonotonicDay = environment.currentMonotonicDay + 1
    environment.currentPeriod = environment.currentPeriod + 1
    environment.currentHour = 0
    tc.RandomEvents:rollNewEvents()
    tank:setFillLevel(0, FillType.DIESEL)
    g_currentMission.environment.currentHour = 9
    tc.RandomEvents:firePendingTriggers()
    assertEquals(#world.messages, 1, "no second message")
    assertEquals(next(tc.RandomEvents.incidents), nil, "no incident left open")
end)
