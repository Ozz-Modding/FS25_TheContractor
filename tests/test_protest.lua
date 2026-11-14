-- The protest event (151, TheContractorProtest) on the real random events
-- framework (068): the warning the evening before, going out and ending,
-- what stops one (winter, an auction's day, another farm's protest, no
-- buildings, no road), the console's forced protest, no cooldown, and a
-- joining client laying out the same people. The roads are world.roads
-- (FallenTree's samples, faked); the farm's buildings are placeables.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    world.texts.ui_on = "On"
    world.texts.ui_off = "Off"

    Environment = { PERIODS_IN_YEAR = 12 }
    Season = { SPRING = 0, SUMMER = 1, AUTUMN = 2, WINTER = 3 }
    world.season = Season.SUMMER
    g_currentMission.environment = {
        currentYear = 1,
        currentPeriod = 5,
        currentDayInPeriod = 1,
        daysPerPeriod = 3,
        plannedDaysPerPeriod = 3,
        currentMonotonicDay = 40,
        currentHour = 18,
        getSeasonAtDay = function() return world.season end,
    }
    g_farmManager.getFarmById = function(_, farmId)
        return { farmId = farmId }
    end

    -- The engine checks: flat ground everywhere, nothing in the way.
    g_terrainNode = 1
    getTerrainHeightAtWorldPos = function() return 0 end
    overlapBox = function() end
    MathUtil = MathUtil or {}
    MathUtil.getYRotationFromDirection = function(dx, dz) return math.atan2(dx, dz) end

    world:load("src/util/TCCalendar.lua")
    world:load("src/util/TCConsole.lua")
    world:load("src/business/Settings.lua")
    world:load("src/business/RandomEvents.lua")
    world:load("src/util/TCAuctionScene.lua")
    world:load("src/util/TCProtestLayout.lua")
    world:load("src/business/Protest.lua")

    TCRandomEventIncidentEvent = {
        new = function(incident, isClosed)
            return { incident = incident, isClosed = isClosed }
        end,
    }
    TheContractorYards = {
        isYardCategory = function(category) return category == "SHEDS" end,
    }
    world.roads = {}
    TheContractorFallenTree = {
        sampleRoads = function() return world.roads end,
    }
    TheContractorAuctions = { COLLECTION_DAYS = 0 }
    TheContractorInbox = { DISMISS_ACTION = { key = "dismiss", textKey = "tc_inbox_dismiss" } }

    local tc = g_currentMission.TheContractor
    tc.Settings = TheContractorSettings.new()
    tc.Company = { companyNames = { [1] = "Test Contracting", [2] = "Other Lot" } }
    tc.Auctions = { getAuction = function() return world.auction end }
    tc.Farmers = {
        getOfficial = function() return { id = 77, name = "The Official" } end,
        getPerson = function(_, id) return id == 77 and { id = 77, name = "The Official" } or nil end,
    }
    world.kinds = {}
    tc.Inbox = {
        messagesById = {},
        nextId = 1,
        registerMessageKind = function(_, kind, definition) world.kinds[kind] = definition end,
        postMessage = function(self, farmId, kind, titleKey, bodyKey, args, actions, payload, expiresInDays)
            local message = { id = self.nextId, farmId = farmId, kind = kind, titleKey = titleKey, bodyKey = bodyKey,
                args = args, actions = actions, payload = payload, expiresInDays = expiresInDays }
            self.messagesById[message.id] = message
            self.nextId = self.nextId + 1
            return message.id
        end,
        removeMessage = function(self, id) self.messagesById[id] = nil end,
    }
    tc.RandomEvents = TheContractorRandomEvents.new()
    tc.Protest = TheContractorProtest.new()
    tc.Protest:register(tc.RandomEvents, tc.Inbox)

    -- A building of the farm's: a shed (a yard building) on farmland 1.
    function world:addBuilding(farmId, x, z, category)
        local placeable = self:addPlaceable({ name = "Building", farmId = farmId })
        placeable.storeItem = { categoryName = category or "sheds" }
        function placeable:getPosition() return x, 0, z end
        function placeable:getFarmlandId() return 1 end
        return placeable
    end

    -- Roads round a base at (0, 0): one along x 80 m north, one 200 m
    -- south, one along z 300 m east.
    function world:addRoads()
        local function along(splineId, z)
            for x = -400, 400, 20 do
                table.insert(self.roads, { x = x, y = 0, z = z, dirX = 1, dirZ = 0, splineId = splineId })
            end
        end
        along(1, 80)
        along(2, -200)
        for z = -400, 400, 20 do
            table.insert(self.roads, { x = 300, y = 0, z = z, dirX = 0, dirZ = 1, splineId = 3 })
        end
    end

    return world, tc
end

local function setTime(day, hour)
    g_currentMission.environment.currentMonotonicDay = day
    g_currentMission.environment.currentHour = hour
end

local function countMessages(tc)
    local count = 0
    for _ in pairs(tc.Inbox.messagesById) do
        count = count + 1
    end
    return count
end

local function firstMessage(tc)
    for _, message in pairs(tc.Inbox.messagesById) do
        return message
    end
    return nil
end

local function setUpFarm(world)
    world:addBuilding(1, -10, 0)
    world:addBuilding(1, 10, 0)
    world:addRoads()
end

test("the warning comes the evening before, from the official, with the map", function()
    local world, tc = setup()
    setUpFarm(world)
    local incident = tc.RandomEvents:triggerEvent(1, "protest")
    assertTrue(incident ~= nil, "an incident")
    assertEquals(incident.stage, TheContractorProtest.STAGE.NOTICE, "waiting for the day")
    assertEquals(incident.data.day, 41, "tomorrow")
    local groups = TCProtestLayout.getGroups(incident.data)
    assertTrue(#groups >= TCProtestLayout.GROUPS_MIN and #groups <= TCProtestLayout.GROUPS_MAX, "groups")
    for i, group in ipairs(groups) do
        assertTrue(group.count >= TCProtestLayout.PEOPLE_MIN and group.count <= TCProtestLayout.PEOPLE_MAX,
            "people " .. i)
    end

    local message = firstMessage(tc)
    assertEquals(countMessages(tc), 1, "one message")
    assertEquals(message.farmId, 1, "to the farm")
    assertEquals(message.kind, TheContractorProtest.MESSAGE_KIND, "kind")
    assertEquals(message.bodyKey, "tc_protest_noticeBody", "body")
    assertEquals(message.payload.farmerId, 77, "from the official")
    assertEquals(message.payload.incidentId, incident.id, "the incident")
    assertEquals(message.actions[1].key, TheContractorProtest.SHOW_ON_MAP_ACTION.key, "show on map")
    assertEquals(message.expiresInDays, TheContractorProtest.MESSAGE_DAYS, "gone after")
    assertEquals(TheContractorProtest.getMessageArgs(message)[1], "The Official", "named live")
    assertTrue(world.kinds[TheContractorProtest.MESSAGE_KIND].fromFarmer, "from a person")
end)

test("out on the day at 07:00, over at 19:00 with its warning", function()
    local world, tc = setup()
    setUpFarm(world)
    local incident = tc.RandomEvents:triggerEvent(1, "protest")

    setTime(41, 6)
    tc.Protest:checkIncidents()
    assertEquals(incident.stage, TheContractorProtest.STAGE.NOTICE, "not yet")
    setTime(41, 7)
    tc.Protest:checkIncidents()
    assertEquals(tc.RandomEvents:getIncident(incident.id).stage, TheContractorProtest.STAGE.OUT, "out")
    setTime(41, 18)
    tc.Protest:checkIncidents()
    assertTrue(tc.RandomEvents:getIncident(incident.id) ~= nil, "still out")
    setTime(41, 19)
    tc.Protest:checkIncidents()
    assertEquals(tc.RandomEvents:getIncident(incident.id), nil, "over")
    assertEquals(countMessages(tc), 0, "the warning's gone")
end)

test("a load after the day ends it, even if it never went out", function()
    local world, tc = setup()
    setUpFarm(world)
    local incident = tc.RandomEvents:triggerEvent(1, "protest")
    setTime(42, 3)
    tc.Protest:checkIncidents()
    assertEquals(tc.RandomEvents:getIncident(incident.id), nil, "over")
end)

test("none in winter, on an auction's day or on another farm's protest day", function()
    local world, tc = setup()
    setUpFarm(world)
    world.season = Season.WINTER
    assertEquals(tc.RandomEvents:triggerEvent(1, "protest"), nil, "winter")

    world.season = Season.SUMMER
    world.auction = { saleDay = 41 }
    assertEquals(tc.RandomEvents:triggerEvent(1, "protest"), nil, "the sale day")
    world.auction = { saleDay = 45 }
    world:addBuilding(2, 0, 20)
    assertTrue(tc.RandomEvents:triggerEvent(2, "protest") ~= nil, "another day's fine")
    assertEquals(tc.RandomEvents:triggerEvent(1, "protest"), nil, "another farm's protest day")
end)

test("a farm with no buildings or no road near them has none", function()
    local world, tc = setup()
    world:addRoads()
    world:addBuilding(2, 0, 0)
    assertEquals(tc.RandomEvents:triggerEvent(1, "protest"), nil, "no buildings of its own")

    local world2, tc2 = setup()
    world2:addBuilding(1, 0, 0)
    assertEquals(tc2.RandomEvents:triggerEvent(1, "protest"), nil, "no roads")
end)

test("forced from the console: out now, no warning, there until the day changes", function()
    local world, tc = setup()
    setUpFarm(world)
    setTime(40, 21)
    assertEquals(tc.Protest:prepareConsole({ "now" }), nil, "takes now")
    local incident = tc.RandomEvents:triggerEvent(1, "protest")
    tc.Protest.consoleNow = false
    assertEquals(incident.stage, TheContractorProtest.STAGE.OUT, "out")
    assertEquals(incident.data.day, 40, "today")
    assertTrue(incident.data.forced, "forced")
    assertEquals(countMessages(tc), 0, "no warning")

    setTime(40, 23)
    tc.Protest:checkIncidents()
    assertTrue(tc.RandomEvents:getIncident(incident.id) ~= nil, "still out late")
    setTime(41, 0)
    tc.Protest:checkIncidents()
    assertEquals(tc.RandomEvents:getIncident(incident.id), nil, "over at the day change")
end)

test("the console takes nothing or now", function()
    local _, tc = setup()
    assertEquals(tc.Protest:prepareConsole({}), nil, "nothing")
    assertTrue(not tc.Protest.consoleNow, "not forced")
    assertTrue(tc.Protest:prepareConsole({ "later" }) ~= nil, "something else")
    assertTrue(tc.Protest:prepareConsole({ "now", "please" }) ~= nil, "too much")
end)

test("by chance, about one in 24 months, with no cooldown", function()
    local world, tc = setup()
    setUpFarm(world)
    local definition = tc.RandomEvents:getEventType("protest")
    assertNear(definition.ratePerPeriod(1), 1 / 24, 0.0001, "rate")
    assertTrue(definition.triggerHours ~= nil, "the evening before")
    tc.RandomEvents:triggerEvent(1, "protest")
    assertEquals(tc.RandomEvents:getCooldownLeft(1, "protest"), 0, "no cooldown")
end)

test("a client joining mid-protest lays out the same people", function()
    local world, tc = setup()
    setUpFarm(world)
    local incident = tc.RandomEvents:triggerEvent(1, "protest")
    setTime(41, 9)
    tc.Protest:checkIncidents()

    local stream = world:newStream()
    TheContractorRandomEvents.writeIncident(stream, tc.RandomEvents:getIncident(incident.id))
    local received = TheContractorRandomEvents.readIncident(stream)
    assertEquals(received.stage, TheContractorProtest.STAGE.OUT, "out on the client")

    local server = TCProtestLayout.layOut(TCProtestLayout.getGroups(incident.data), incident.data.seed)
    local client = TCProtestLayout.layOut(TCProtestLayout.getGroups(received.data), received.data.seed)
    assertEquals(#client, #server, "everyone")
    for i, person in ipairs(server) do
        assertNear(client[i].x, person.x, 0.001, "x " .. i)
        assertNear(client[i].z, person.z, 0.001, "z " .. i)
        assertEquals(client[i].slogan, person.slogan, "slogan " .. i)
    end
end)

test("the groups stand on the roads near the base, facing it", function()
    local world, tc = setup()
    setUpFarm(world)
    local incident = tc.RandomEvents:triggerEvent(1, "protest")
    for i, group in ipairs(TCProtestLayout.getGroups(incident.data)) do
        local d = math.sqrt(group.x ^ 2 + group.z ^ 2)
        assertTrue(d >= TCProtestLayout.MIN_DISTANCE and d <= TCProtestLayout.MAX_DISTANCE, "near " .. i)
        assertTrue(group.dirX * -group.x + group.dirZ * -group.z >= 0, "facing the base " .. i)
    end
end)

-- The trip delay: 15 minutes out and back while the job's farm has one out.
test("a protest out slows the farm's crews, and the farm's told by a notification", function()
    local world, tc = setup()
    setUpFarm(world)
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    world.events = {}
    g_server = { broadcastEvent = function(_, event) table.insert(world.events, event) end }
    world:load("src/events/TCProtestDelayEvent.lua")
    local job = { id = 9, farmId = 1, getLocationText = function() return "Field 3" end }
    local otherJob = { id = 10, farmId = 2, getLocationText = function() return "Field 4" end }
    tc.Jobs = { getJobById = function(_, id) return id == 9 and job or otherJob end }

    local incident = tc.RandomEvents:triggerEvent(1, "protest")
    assertEquals(TheContractorProtest.getTravelDelayMinutes(job), 0, "not while it's only a warning")
    world.events = {}
    TheContractorProtest.notifyDelay(job, false)
    assertEquals(#world.notifications, 0, "nothing to tell")
    assertEquals(#world.events, 0, "nothing sent")

    setTime(41, 7)
    tc.Protest:checkIncidents()
    assertEquals(TheContractorProtest.getTravelDelayMinutes(job), TheContractorProtest.TRAVEL_DELAY_MINUTES, "out")
    assertEquals(TheContractorProtest.getTravelDelayMinutes(otherJob), 0, "another farm's crews aren't held up")

    world.events = {}
    TheContractorProtest.notifyDelay(job, true)
    assertEquals(#world.notifications, 1, "the host's own notification")
    assertEquals(#world.events, 1, "sent to everyone")
    local event = world.events[1]
    assertEquals(event.farmId, 1)
    assertEquals(event.jobId, 9)
    assertEquals(event.minutes, TheContractorProtest.TRAVEL_DELAY_MINUTES)
    assertTrue(event.isReturn, "the trip back")

    -- Another farm's player sees nothing of it.
    TCProtestDelayEvent.showNotification(2, 10, 15, false)
    assertEquals(#world.notifications, 1, "not for this farm")

    setTime(41, 19)
    tc.Protest:checkIncidents()
    assertEquals(tc.RandomEvents:getIncident(incident.id), nil, "over")
    assertEquals(TheContractorProtest.getTravelDelayMinutes(job), 0, "over, so no delay")
end)
