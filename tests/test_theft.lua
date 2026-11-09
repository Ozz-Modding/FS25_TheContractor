-- TheContractorTheft (069) on the real random events framework (068):
-- what can be stolen, the odds, the theft itself, both police outcomes,
-- selling a stolen vehicle, and save/load.

local function setup(daysPerPeriod)
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
        daysPerPeriod = daysPerPeriod or 3,
        plannedDaysPerPeriod = daysPerPeriod or 3,
        currentMonotonicDay = 1,
    }
    g_farmManager.getFarmById = function(_, farmId)
        return { farmId = farmId }
    end
    g_farmManager.getFarmByUserId = function()
        return { farmId = 1 }
    end

    VehiclePropertyState = { OWNED = 2, LEASED = 3 }
    Vehicle.getCanBeSold = function()
        return true
    end
    Vehicle.getIsInUse = function()
        return false
    end
    TheContractorJob = { STATE = { ALLOCATED = "allocated", IN_PROGRESS = "in_progress" } }

    -- The mod's other modules, faked: world records what they were asked.
    world.unhitched, world.hidden, world.returned, world.messages, world.notices, world.recoveries = {}, {}, {}, {}, {},
        {}
    world.cooldown, world.pending, world.locked, world.jobs, world.categories = {}, {}, {}, {}, {}
    world.lockRefreshes = 0

    TCEquipmentVisibility = {
        isHidden = function(vehicleId)
            return world.hidden[vehicleId] == true
        end,
        setVisibleEverywhere = function(vehicleIds, isVisible)
            for _, vehicleId in ipairs(vehicleIds) do
                world.hidden[vehicleId] = not isVisible or nil
            end
        end,
    }
    TCVehicleLock = {
        isLocked = function(vehicle)
            return world.locked[vehicle.id] == true
        end,
        refresh = function()
            world.lockRefreshes = world.lockRefreshes + 1
        end,
    }
    TCJobSiteSetup = {
        unhitchVehicles = function(vehicleIds)
            for _, vehicleId in ipairs(vehicleIds) do
                local vehicle = NetworkUtil.getObject(vehicleId)
                for _, implement in ipairs(vehicle.implements) do
                    implement.object.attacher = nil
                end
                vehicle.implements = {}
                table.insert(world.unhitched, vehicleId)
            end
        end,
    }
    TCEquipmentClass = {
        getCategory = function(vehicle)
            return world.categories[vehicle.id]
        end,
    }
    TCVehicleCondition = {
        capture = function(vehicle)
            return { damage = vehicle.damage }
        end,
    }
    TCVehicleIds = {
        getObjectId = function(uniqueId)
            for id, object in pairs(world.objects) do
                if object.uniqueId == uniqueId and not object.isDeleted then
                    return id
                end
            end
            return nil
        end,
    }
    TheContractorDrivers = {
        isVehicleDriven = function(vehicle)
            return vehicle:getIsAIActive()
        end,
    }

    world:load("src/util/TCCalendar.lua")
    world:load("src/util/TCConsole.lua")
    world:load("src/business/Settings.lua")
    world:load("src/business/RandomEvents.lua")
    world:load("src/business/Theft.lua")

    TCRandomEventIncidentEvent = {
        new = function(incident, isClosed)
            return { incident = incident, isClosed = isClosed }
        end,
    }

    local tc = g_currentMission.TheContractor
    tc.Settings = TheContractorSettings.new()
    tc.Company = { companyNames = { [1] = "Test Contracting" } }
    tc.Jobs = {
        getAllJobs = function(_, farmId)
            return world.jobs
        end,
    }
    tc.Cooldown = {
        isVehicleInCooldown = function(_, vehicleId)
            return world.cooldown[vehicleId] == true
        end,
    }
    tc.Parking = {
        isPending = function(_, vehicleId)
            return world.pending[vehicleId] == true
        end,
        returnHiddenVehicles = function(_, farmId, vehicleIds)
            for _, vehicleId in ipairs(vehicleIds) do
                assertTrue(world.hidden[vehicleId], "only a hidden vehicle goes to the parking queue")
                table.insert(world.returned, vehicleId)
            end
        end,
    }
    tc.Drivers = {
        hasDriver = function(_, vehicle)
            return vehicle.hasStaffDriver == true
        end,
    }
    tc.Inbox = {
        registerMessageKind = function() end,
        postMessage = function(_, farmId, kind, titleKey, bodyKey, args)
            -- Rendered as the client would, so a broken text fails here.
            local body = string.format(g_i18n:getText(bodyKey), unpack(args))
            table.insert(world.messages, { farmId = farmId, kind = kind, titleKey = titleKey, bodyKey = bodyKey,
                args = args, body = body })
            return #world.messages
        end,
        removeMessage = function(_, messageId)
            world.messages[messageId].removed = true
        end,
    }
    tc.Notices = {
        publish = function(_, farmId, text)
            table.insert(world.notices, text)
        end,
    }
    tc.Logbook = {
        recordTheftRecovered = function(_, farmId, vehicle, startSnapshot, minutes)
            table.insert(world.recoveries, { vehicle = vehicle, startSnapshot = startSnapshot, minutes = minutes })
        end,
    }
    tc.RandomEvents = TheContractorRandomEvents.new()
    tc.Theft = TheContractorTheft.new()
    tc.Theft:register(tc.RandomEvents, tc.Inbox)

    -- def: { name, farmId, drivable (default true), propertyState, category,
    --        value, controlled, aiActive, hasStaffDriver, antiTheft (096: ADS's state) }
    function world:addMachine(def)
        local vehicle = self:addVehicle({ name = def.name, farmId = def.farmId, isAIActive = def.aiActive })
        vehicle.spec_drivable = def.drivable ~= false and {} or nil
        vehicle.propertyState = def.propertyState or VehiclePropertyState.OWNED
        vehicle.uniqueId = "unique" .. vehicle.id
        vehicle.configFileName = "data/" .. vehicle.name .. ".xml"
        vehicle.hasStaffDriver = def.hasStaffDriver
        vehicle.controlled = def.controlled
        vehicle.value = def.value or 50000
        vehicle.damage = 0
        vehicle.dirt = 0
        vehicle.implements = {}
        world.categories[vehicle.id] = def.category

        function vehicle:getFullName() return self.name end
        function vehicle:getUniqueId() return self.uniqueId end
        function vehicle:getSellPrice() return self.value end
        function vehicle:getIsControlled() return self.controlled == true end
        function vehicle:getAttachedImplements() return self.implements end
        function vehicle:getAttacherVehicle() return self.attacher end
        function vehicle:addDamageAmount(amount) self.damage = self.damage + amount end
        function vehicle:addDirtAmount(amount) self.dirt = math.min(1, self.dirt + amount) end
        function vehicle:delete() self.isDeleted = true end
        vehicle.getCanBeSold = Vehicle.getCanBeSold
        vehicle.getIsInUse = Vehicle.getIsInUse
        if def.antiTheft ~= nil then
            vehicle.states = { ANTI_THEFT_SYSTEM = def.antiTheft or nil }
            function vehicle:hasBreakdown(id) return self.states[id] == true end
        end
        return vehicle
    end

    function world:hitch(vehicle, implement)
        table.insert(vehicle.implements, { object = implement })
        implement.attacher = vehicle
    end

    function world:nextDay()
        local environment = g_currentMission.environment
        environment.currentMonotonicDay = environment.currentMonotonicDay + 1
        environment.currentDayInPeriod = environment.currentDayInPeriod + 1
        if environment.currentDayInPeriod > environment.daysPerPeriod then
            environment.currentDayInPeriod = 1
            environment.currentPeriod = environment.currentPeriod + 1
        end
        tc.RandomEvents:advanceDueIncidents()
    end

    -- Days until every open incident has moved on.
    function world:runUntilClosed()
        for _ = 1, 60 do
            if next(tc.RandomEvents.incidents) == nil then
                return
            end
            self:nextDay()
        end
        error("incident never closed")
    end

    return world, tc
end

local function eligibleNames(tc)
    local names = {}
    for _, candidate in ipairs(tc.Theft:getEligibleVehicles(1)) do
        table.insert(names, candidate.vehicle.name)
    end
    table.sort(names)
    return table.concat(names, ",")
end

test("only free, owned drivables nobody's using can be stolen", function()
    local world, tc = setup()
    world:addMachine({ name = "free" })
    world:addMachine({ name = "plough", drivable = false })
    world:addMachine({ name = "leased", propertyState = VehiclePropertyState.LEASED })
    world:addMachine({ name = "neighbours", farmId = 2 })
    world:addMachine({ name = "driven", controlled = true })
    world:addMachine({ name = "ai", aiActive = true })
    world:addMachine({ name = "staffDriver", hasStaffDriver = true })
    world.cooldown[world:addMachine({ name = "cooldown" }).id] = true
    world.pending[world:addMachine({ name = "parking" }).id] = true
    world.hidden[world:addMachine({ name = "hidden" }).id] = true
    world.locked[world:addMachine({ name = "locked" }).id] = true

    local onJob = world:addMachine({ name = "onJob" })
    local allocated = world:addMachine({ name = "allocated" })
    local job = { state = "in_progress", getAllEquipmentIds = function() return { onJob.id } end }
    local playerJob = { state = "allocated", getAllEquipmentIds = function() return { allocated.id } end }
    local done = world:addMachine({ name = "doneJob" })
    local finished = { state = "completed", getAllEquipmentIds = function() return { done.id } end }
    world.jobs = { job, playerJob, finished }

    assertEquals(eligibleNames(tc), "doneJob,free", "eligible")
end)

test("a tractor hitched to something busy, or hitched to something itself, is left alone", function()
    local world, tc = setup()
    local tractor = world:addMachine({ name = "tractor" })
    local trailer = world:addMachine({ name = "trailer", drivable = false })
    world:hitch(tractor, trailer)
    local loader = world:addMachine({ name = "loader" })
    local frontLoader = world:addMachine({ name = "towedDrivable" })
    world:hitch(loader, frontLoader)
    local busy = world:addMachine({ name = "busyTractor" })
    local busyImplement = world:addMachine({ name = "busyImplement", drivable = false })
    world:hitch(busy, busyImplement)
    world.cooldown[busyImplement.id] = true

    assertEquals(eligibleNames(tc), "loader,tractor", "eligible")
end)

test("the monthly rate follows the fleet and is nothing with nothing to steal", function()
    local world, tc = setup()
    assertEquals(tc.Theft:getRatePerPeriod(1), 0, "no vehicles")
    for i = 1, 10 do
        world:addMachine({ name = "tractor" .. i })
    end
    assertNear(tc.Theft:getRatePerPeriod(1), 0.02 * 1.0, 1e-9, "10 vehicles: factor 1")
    for i = 11, 60 do
        world:addMachine({ name = "tractor" .. i })
    end
    assertNear(tc.Theft:getRatePerPeriod(1), 0.02 * 2, 1e-9, "capped at twice")
end)

test("thieves favour tractors and loaders over harvesters", function()
    local world, tc = setup()
    local tractor = world:addMachine({ name = "tractor", category = "TRACTORSM" })
    local combine = world:addMachine({ name = "combine", category = "HARVESTERS" })
    local other = world:addMachine({ name = "mower", category = "MOWERVEHICLES" })
    local candidates = tc.Theft:getEligibleVehicles(1)
    local weights = {}
    for _, candidate in ipairs(candidates) do
        weights[candidate.vehicle.name] = candidate.weight
    end
    assertEquals(weights.tractor, 3, "tractor")
    assertEquals(weights.combine, 0.25, "combine")
    assertEquals(weights.mower, 1, "unlisted")

    -- Total 4.25: the tractor takes rolls up to 3/4.25.
    assertEquals(TheContractorTheft.pickWeighted(candidates, 0).vehicle, tractor, "low roll")
    assertEquals(TheContractorTheft.pickWeighted(candidates, 0.75).vehicle, combine, "between")
    assertEquals(TheContractorTheft.pickWeighted(candidates, 0.99).vehicle, other, "high roll")
end)

test("a theft takes the one vehicle, leaves what was hitched, and reports it", function()
    local world, tc = setup()
    local tractor = world:addMachine({ name = "Fendt 724", value = 120000 })
    local plough = world:addMachine({ name = "Plough", drivable = false })
    world:hitch(tractor, plough)

    local incident = tc.RandomEvents:triggerEvent(1, "theft")
    assertEquals(incident.stage, "policeReport", "waiting on the police")
    assertEquals(incident.data.vehicleId, tractor.id, "the tractor")
    assertEquals(incident.data.value, 120000, "its value copied")
    assertEquals(incident.data.name, "Fendt 724", "its name copied")
    assertEquals(#tractor.implements, 0, "plough unhitched")
    assertEquals(plough.attacher, nil, "plough left behind")
    assertTrue(world.hidden[tractor.id], "tractor hidden")
    assertTrue(not world.hidden[plough.id], "plough not hidden")
    assertTrue(tc.Theft:isStolen(tractor.id), "stolen")
    assertTrue(not tc.Theft:isStolen(plough.id), "plough not stolen")
    assertTrue(world.lockRefreshes > 0, "locks refreshed")

    assertEquals(#world.messages, 1, "one message")
    assertEquals(world.messages[1].titleKey, "tc_theft_stolenTitle", "stolen message")
    assertEquals(world.messages[1].args[2], incident.data.crimeReference, "crime reference in it")
    assertEquals(#world.notices, 1, "notice")
    assertEquals(tc.RandomEvents:getCooldownLeft(1, "theft"), 12, "a year's cooldown")
    assertEquals(eligibleNames(tc), "", "a stolen vehicle can't be stolen again")

    assertEquals(tractor:getCanBeSold(), false, "can't be sold")
    assertEquals(tractor:getIsInUse(), true, "the server refuses to sell it")
    assertEquals(plough:getCanBeSold(), true, "the plough still can")
end)

test("recovered: damaged, dirty, logged and back through the parking queue", function()
    local world, tc = setup(28)
    local tractor = world:addMachine({ name = "Fendt 724" })
    tc.Theft.forcedOutcome = TheContractorTheft.OUTCOME.RECOVERED

    local incident = tc.RandomEvents:triggerEvent(1, "theft")
    local wait = incident.nextStageDay - g_currentMission.environment.currentMonotonicDay
    assertTrue(wait >= 3 and wait <= 10, "3-10 days at 28 a month: " .. wait)

    world:runUntilClosed()
    assertTrue(tractor.damage >= 0.1 and tractor.damage <= 0.3, "damage added: " .. tractor.damage)
    assertEquals(tractor.dirt, 1, "filthy")
    assertTrue(not tractor.isDeleted, "kept")
    assertEquals(world.returned[1], tractor.id, "into the parking queue")
    assertEquals(#world.recoveries, 1, "logged")
    assertEquals(world.recoveries[1].startSnapshot.damage, 0, "logged with its condition before the damage")
    assertEquals(world.recoveries[1].minutes, wait * 24 * 60, "missing for the wait")
    assertTrue(not tc.Theft:isStolen(tractor.id), "no longer stolen")
    assertEquals(world.messages[2].titleKey, "tc_theft_recoveredTitle", "recovered message")
    assertTrue(world.messages[1].removed, "the stolen message is taken down")
    assertTrue(not world.messages[2].removed, "the recovered one stays")
    assertEquals(tc.Theft.forcedOutcome, nil, "the forced outcome is used up")
end)

test("not found: written off and gone", function()
    local world, tc = setup()
    local tractor = world:addMachine({ name = "Fendt 724" })
    tc.Theft.forcedOutcome = TheContractorTheft.OUTCOME.LOST

    tc.RandomEvents:triggerEvent(1, "theft")
    world:runUntilClosed()
    assertTrue(tractor.isDeleted, "deleted")
    assertEquals(#world.returned, 0, "nothing parked")
    assertEquals(world.messages[2].titleKey, "tc_theft_lostTitle", "written-off message")
    assertTrue(world.messages[1].removed, "the stolen message is taken down")
    assertEquals(#world.notices, 2, "notice")
end)

test("after a reload the stolen vehicle is found by its uniqueId and hidden again", function()
    local world, tc = setup()
    world:addMachine({ name = "decoy" })
    local tractor = world:addMachine({ name = "Fendt 724" })
    tc.Theft.forcedOutcome = TheContractorTheft.OUTCOME.RECOVERED
    local incident = tc.RandomEvents:triggerEvent(1, "theft")

    local xmlFile = {}
    tc.RandomEvents:saveToXmlFile(xmlFile)

    -- A new session: the tractor loads in view, under a new object id.
    world.hidden = {}
    world.objects[tractor.id] = nil
    world:register(tractor)
    local randomEvents = TheContractorRandomEvents.new()
    local theft = TheContractorTheft.new()
    theft:register(randomEvents, tc.Inbox)
    theft.forcedOutcome = TheContractorTheft.OUTCOME.RECOVERED
    randomEvents:loadFromXMLFile(xmlFile)
    tc.RandomEvents, tc.Theft = randomEvents, theft

    theft:resolveSavedVehicles()
    assertEquals(randomEvents:getIncident(incident.id).data.vehicleId, tractor.id, "new object id")
    assertTrue(world.hidden[tractor.id], "hidden again")
    assertTrue(theft:isStolen(tractor.id), "still stolen")

    world:runUntilClosed()
    assertEquals(world.returned[1], tractor.id, "recovered as normal")
end)

test("a stolen vehicle that's gone after a reload is simply written off", function()
    local world, tc = setup()
    local tractor = world:addMachine({ name = "Fendt 724" })
    tc.Theft.forcedOutcome = TheContractorTheft.OUTCOME.RECOVERED
    local incident = tc.RandomEvents:triggerEvent(1, "theft")
    tractor.isDeleted = true

    tc.Theft:resolveSavedVehicles()
    assertEquals(tc.RandomEvents:getIncident(incident.id).data.vehicleId, 0, "not found")
    world:runUntilClosed()
    assertEquals(#world.returned, 0, "nothing to return")
    assertEquals(world.messages[2].titleKey, "tc_theft_lostTitle", "written off")
end)

test("tcDebug outcome theft sets the next outcome", function()
    local _, tc = setup()
    TCConsole.reset()
    TheContractorRandomEvents.registerConsoleCommands()
    local group = TCConsole.groups.debug

    TCConsole.dispatch(group, { "outcome", "THEFT", "Lost" })
    assertEquals(tc.Theft.forcedOutcome, "lost", "set, whatever the case")
    TCConsole.dispatch(group, { "outcome", "theft", "maybe" })
    assertEquals(tc.Theft.forcedOutcome, "lost", "not an outcome: unchanged")
end)

-- 096: FS25_AdvancedDamageSystem's anti-theft system.

local function withRoll(roll, fn)
    local realRandom = math.random
    math.random = function(...)
        if select("#", ...) == 0 then
            return roll
        end
        return realRandom(...)
    end
    local result = fn()
    math.random = realRandom
    return result
end

test("a vehicle without ADS, or without the system, has no anti-theft", function()
    local world = setup()
    assertEquals(TheContractorTheft.hasAntiTheft(world:addMachine({ name = "noADS" })), false, "no hasBreakdown")
    assertEquals(TheContractorTheft.hasAntiTheft(world:addMachine({ name = "unfitted", antiTheft = false })), false,
        "ADS, not fitted")
    assertEquals(TheContractorTheft.hasAntiTheft(world:addMachine({ name = "fitted", antiTheft = true })), true, "fitted")
    assertEquals(TheContractorTheft.isAntiTheftOffered(), false, "ADS not loaded")
    g_modIsLoaded = { FS25_AdvancedDamageSystem = true }
    assertEquals(TheContractorTheft.isAntiTheftOffered(), true, "ADS loaded")
    g_modIsLoaded = nil
end)

test("a fitted vehicle is a tenth as likely to be picked but counts in full in the rate", function()
    local world, tc = setup()
    world:addMachine({ name = "tractor", category = "TRACTORSM" })
    world:addMachine({ name = "fitted", category = "TRACTORSM", antiTheft = true })
    local weights = {}
    for _, candidate in ipairs(tc.Theft:getEligibleVehicles(1)) do
        weights[candidate.vehicle.name] = candidate.weight
    end
    assertEquals(weights.tractor, 3, "unfitted")
    assertNear(weights.fitted, 0.3, 1e-9, "fitted")

    -- 2 vehicles: factor 0.5 + 2 / 20.
    assertNear(tc.Theft:getRatePerPeriod(1), 0.02 * (0.5 + 2 / 20), 1e-9, "rate")
end)

test("a fully fitted fleet is stolen from as often as an unfitted one", function()
    local world, tc = setup()
    for i = 1, 4 do
        world:addMachine({ name = "tractor" .. i, antiTheft = true })
    end
    -- Factor 0.5 + 4 / 20.
    assertNear(tc.Theft:getRatePerPeriod(1), 0.02 * 0.7, 1e-9, "rate")
end)

test("anti-theft is judged on the day of the theft and recovers 70% of the time", function()
    local world, tc = setup()
    local tractor = world:addMachine({ name = "Fendt 724", antiTheft = true })
    local incident = tc.RandomEvents:triggerEvent(1, "theft")
    assertEquals(incident.data.antiTheft, true, "copied into the incident")
    assertEquals(world.messages[1].bodyKey, "tc_theft_stolenBodyTracker", "stolen message mentions it")
    tractor.states.ANTI_THEFT_SYSTEM = nil
    assertEquals(incident.data.antiTheft, true, "still counts once it's gone")

    assertEquals(withRoll(0.6, function() return tc.Theft:rollRecovered(true) end), true, "0.6: recovered with it")
    assertEquals(withRoll(0.6, function() return tc.Theft:rollRecovered(false) end), false, "0.6: lost without")
    assertEquals(withRoll(0.75, function() return tc.Theft:rollRecovered(true) end), false, "0.75: lost even with it")
    tc.Theft.forcedOutcome = TheContractorTheft.OUTCOME.LOST
    assertEquals(withRoll(0, function() return tc.Theft:rollRecovered(true) end), false, "a forced outcome still wins")
end)

test("the police report reads the flag from the incident", function()
    local world, tc = setup()
    world:addMachine({ name = "Fendt 724", antiTheft = true })
    tc.RandomEvents:triggerEvent(1, "theft")
    withRoll(0.6, function() world:runUntilClosed() end)
    assertEquals(world.messages[2].titleKey, "tc_theft_recoveredTitle", "a 0.6 roll recovers a fitted vehicle")
end)

test("the tracker's messages: found by it, or it went dead", function()
    local world, tc = setup()
    world:addMachine({ name = "Fendt 724", antiTheft = true })
    tc.Theft.forcedOutcome = TheContractorTheft.OUTCOME.RECOVERED
    tc.RandomEvents:triggerEvent(1, "theft")
    world:runUntilClosed()
    assertEquals(world.messages[2].bodyKey, "tc_theft_recoveredBodyTracker", "recovered by it")

    world, tc = setup()
    world:addMachine({ name = "Fendt 724", antiTheft = true })
    tc.Theft.forcedOutcome = TheContractorTheft.OUTCOME.LOST
    tc.RandomEvents:triggerEvent(1, "theft")
    world:runUntilClosed()
    assertEquals(world.messages[2].bodyKey, "tc_theft_lostBodyTracker", "lost: it went dead")

    world, tc = setup()
    world:addMachine({ name = "Fendt 724" })
    tc.Theft.forcedOutcome = TheContractorTheft.OUTCOME.LOST
    tc.RandomEvents:triggerEvent(1, "theft")
    world:runUntilClosed()
    assertEquals(world.messages[1].bodyKey, "tc_theft_stolenBody", "unfitted: no mention")
    assertEquals(world.messages[2].bodyKey, "tc_theft_lostBody", "unfitted: no tracker")
end)
