-- 137: machinery auctions. The schedule (sale months, leads, the rate over
-- many years, one at a time), the days (signs, set out, on sale,
-- collection, over, and days skipped), the messages to company farms,
-- cancellation when the field changes hands (and not on a retirement), and
-- the auction kept through a save, sent to clients and given to a joining
-- one. The real Auctions, Inbox and calendar; the site (135), the signs
-- (136), the crowd (134), the farmers and the map are faked.

local function setup(daysPerPeriod)
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    Environment = { PERIODS_IN_YEAR = 12 }
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    MessageType = { DAY_CHANGED = 1, HOUR_CHANGED = 2, FARMLAND_OWNER_CHANGED = 3 }
    world.subscriptions = {}
    g_messageCenter = {
        subscribe = function(_, messageType) world.subscriptions[messageType] = true end,
        unsubscribeAll = function() world.subscriptions = {} end,
    }
    world.events = {}
    g_server = { broadcastEvent = function(_, event) table.insert(world.events, event) end }
    TCMessagePostedEvent = { new = function(message) return { posted = message } end }
    TCMessageRemovedEvent = { new = function(id) return { removed = id } end }
    TheContractorStaff = { scalePay = function(pay) return pay end }
    TheContractorJob = { STATE = { OFFERED = 1, NEGOTIATING = 2 } }

    world:load("src/util/TCCalendar.lua")
    world:load("src/business/Inbox.lua")
    world:load("src/util/TCAuctionAttendance.lua")
    world:load("src/util/TCADSUsedLots.lua")
    world:load("src/util/TCLotInspections.lua")
    world:load("src/business/PublicEvents.lua")
    world:load("src/business/EventDay.lua")
    world:load("src/business/Auctions.lua")
    world:load("src/events/TCAuctionEvent.lua")

    -- Vanilla's month names, for the console's dates.
    for month = 1, 12 do
        world.texts["ui_month" .. month] = "Month " .. month
    end

    daysPerPeriod = daysPerPeriod or 10
    g_currentMission.environment = {
        currentYear = 1,
        currentPeriod = 1,
        currentDayInPeriod = 1,
        daysPerPeriod = daysPerPeriod,
        plannedDaysPerPeriod = daysPerPeriod,
        currentMonotonicDay = 1,
        currentHour = 0,
        daylight = { latitude = 55 },
    }

    -- The map: fields held by farmers, as 110 has them.
    world.fields = {}
    world.holders = {}
    g_fieldManager = { getFieldById = function(_, id) return world.fields[id] end }
    function world:addField(id, holderId)
        local field = { id = id, owner = 0 }
        function field:getId() return self.id end
        function field:getOwner() return self.owner end
        function field:getName() return tostring(self.id) end
        function field:getFarmland() return { getId = function() return field.id end } end
        function field:getIndicatorPosition() return 100 + field.id, 200 end
        self.fields[id] = field
        self.holders[id] = holderId
        return field
    end

    local tc = g_currentMission.TheContractor
    tc.hasResolvedSavedVehicles = true
    world.people = { [7] = { id = 7, name = "Tom" }, [8] = { id = 8, name = "Ann" } }
    tc.Farmers = {
        getHolder = function(_, farmlandId)
            local id = world.holders[farmlandId]
            return id ~= nil and world.people[id] or nil
        end,
        getPerson = function(_, id) return world.people[id] end,
    }
    world.companyFarms = { 1, 2 }
    tc.RandomEvents = { incidents = {}, getCompanyFarmIds = function() return world.companyFarms end }
    tc.Inbox = TheContractorInbox.new()

    -- 135's site: the candidates it would rank, and what it was asked to do.
    world.candidates = {}
    world.siteStarts = {}
    world.siteClears = 0
    TheContractorAuctionSite = {
        PREFERRED_LOTS = 120,
        CLOSE_HOURS = { 17, 18 },
        getFieldRefusal = function(field) return world.refusals ~= nil and world.refusals[field:getId()] or nil end,
    }
    -- The walkways a site lays out (its aisles), as every machine has them.
    world.walkways = { { x1 = 0, z1 = 0, x2 = 100, z2 = 0, halfWidth = 5 } }
    tc.AuctionSite = {
        site = nil,
        fieldId = 0,
        walkways = {},
        scene = nil,
        getWalkways = function(self) return self.walkways end,
        -- 140: the site's scene (its seed, its rows' lot numbers).
        getScene = function(self) return self.scene end,
        getCandidates = function() return world.candidates end,
        start = function(self, fieldId, lotCount, auctionId)
            table.insert(world.siteStarts, { fieldId = fieldId, auctionId = auctionId })
            self.site = { fieldId = fieldId }
            self.fieldId, self.walkways = fieldId, world.walkways
        end,
        -- 139: the local buyers' lots taken away after the sale day.
        removeUnsold = function() world.unsoldRemovals = (world.unsoldRemovals or 0) + 1 end,
        clear = function(self)
            world.siteClears = world.siteClears + 1
            self.site = nil
            self.fieldId, self.walkways = 0, {}
        end,
    }
    -- 136's signs.
    world.signMonths = {}
    tc.AuctionSigns = {
        month = 0,
        signs = {},
        place = function(self, month)
            table.insert(world.signMonths, month)
            self.month, self.signs = month, { { x = 1, z = 2, yaw = 0 } }
        end,
        clear = function(self) self.month, self.signs = 0, {} end,
        describe = function(self) return #self.signs .. " sign(s)" end,
    }
    -- 134's crowd, on a machine with a client.
    world.crowdStarts = {}
    TCAuctionCrowd = {
        DEFAULT_PEOPLE = 60,
        active = nil,
        getUnavailableReason = function() return world.noCrowd end,
        startOnWalkways = function(fieldId, walkways, people, options)
            table.insert(world.crowdStarts, fieldId)
            world.crowdWalkways = walkways
            world.crowdPeople, world.crowdOptions = people, options
            TCAuctionCrowd.active = { fieldId = fieldId }
        end,
        stop = function() TCAuctionCrowd.active = nil end,
        getFieldPolygon = function() return {} end,
        getAuctionPeople = function(lotCount) return 1000 + lotCount end,
    }
    TCAuctionLayout = { RULES = { entranceReach = 60 }, findEntrance = function() return { x = 5, z = 6 } end }
    TheContractorFallenTree = { sampleRoads = function() return {} end }

    local auctions = TheContractorAuctions.new()
    auctions:register(tc.Inbox)
    tc.Auctions = auctions
    -- 163: the auction's one kind of day out among others.
    tc.PublicEvents = TheContractorPublicEvents.new()
    tc.PublicEvents:registerKind(auctions)
    world.auctions = auctions
    return world
end

-- The calendar moves on a day (the hour to midnight) and the server's day
-- change runs.
local function nextDay(world)
    local environment = g_currentMission.environment
    environment.currentMonotonicDay = environment.currentMonotonicDay + 1
    environment.currentHour = 0
    environment.currentDayInPeriod = environment.currentDayInPeriod + 1
    if environment.currentDayInPeriod > environment.daysPerPeriod then
        environment.currentDayInPeriod = 1
        environment.currentPeriod = environment.currentPeriod + 1
        if environment.currentPeriod > 12 then
            environment.currentPeriod = 1
            environment.currentYear = environment.currentYear + 1
        end
    end
    world.auctions:onDayChanged()
end

local function setHour(world, hour)
    g_currentMission.environment.currentHour = hour
    world.auctions:onHourChanged()
end

local function getMessages(farmId)
    return g_currentMission.TheContractor.Inbox:getMessages(farmId)
end

-- The schedule ------------------------------------------------------------------------------

test("a sale's only ever in spring or autumn, 2 to 4 months ahead", function()
    setup()
    local A = TheContractorAuctions
    for period = 1, 12 do
        for _, lead in ipairs(A.getLeadChoices(period)) do
            assertTrue(lead >= 2 and lead <= 4)
            assertTrue(A.SALE_PERIODS[A.periodAfter(period, lead)], "period " .. period .. " lead " .. lead)
        end
    end
    -- April (period 2): June, July, August are all summer.
    assertEquals(#A.getLeadChoices(2), 0)
    -- January (period 11): March, April and May.
    assertEquals(table.concat(A.getLeadChoices(11), ","), "2,3,4")
    assertEquals(A.periodAfter(12, 2), 2)
end)

test("over many years: about one a year, sometimes two, one at a time, every sale in spring or autumn", function()
    -- One day a month, so each month's roll is that day's.
    local world = setup(1)
    world:addField(5, 7)
    world.candidates = { { fieldId = 5, problems = {}, entrance = { x = 1, z = 2 } } }
    math.randomseed(137)
    local years = 600
    local announced, lastId = 0, nil
    -- Sales in each year (12 days, from day 1).
    local salesInYear = {}
    for _ = 1, years * 12 do
        local before = world.auctions:getAuction()
        nextDay(world)
        local auction = world.auctions:getAuction()
        if auction ~= nil and auction.id ~= lastId then
            assertEquals(before, nil, "never two at a time")
            announced = announced + 1
            lastId = auction.id
            local periodIndex = TCCalendar.getDayInfo(auction.day)
            local period = (periodIndex - 1) % 12 + 1
            assertTrue(TheContractorAuctions.SALE_PERIODS[period], "sale in period " .. period)
            local months = periodIndex - TCCalendar.getPeriodIndex()
            assertTrue(months >= 2 and months <= 4, "announced " .. months .. " months ahead")
            local year = math.floor((auction.day - 1) / 12) + 1
            salesInYear[year] = (salesInYear[year] or 0) + 1
        end
    end
    local perYear = announced / years
    assertTrue(perYear > 0.95 and perYear < 1.3, "per year: " .. perYear)
    -- The years before the last (whose sales may be after the run).
    local counts = { [0] = 0, [1] = 0, [2] = 0 }
    for year = 2, years - 1 do
        local count = math.min(2, salesInYear[year] or 0)
        counts[count] = counts[count] + 1
    end
    local share = function(count) return counts[count] / (years - 2) end
    assertTrue(share(1) > 0.65, "most years one: " .. share(1))
    assertTrue(share(2) > 0.08 and share(2) < 0.3, "now and then two: " .. share(2))
    assertTrue(share(0) < 0.12, "rarely none: " .. share(0))
end)

test("the chance: none for a while after the last one, then growing each month", function()
    setup()
    local A = TheContractorAuctions
    assertEquals(A.getAnnounceChance(A.MIN_GAP_MONTHS - 1), 0)
    assertNear(A.getAnnounceChance(A.MIN_GAP_MONTHS), A.ANNOUNCE_CHANCE_BASE, 0.0001)
    assertNear(A.getAnnounceChance(A.MIN_GAP_MONTHS + 2), A.ANNOUNCE_CHANCE_BASE + 2 * A.ANNOUNCE_CHANCE_STEP, 0.0001)
    assertEquals(A.getAnnounceChance(100), 1)
end)

test("an auction ending or called off starts the wait again, and the wait's saved", function()
    local world = setup(1)
    world:addField(5, 7)
    world.candidates = { { fieldId = 5, problems = {} } }
    world.auctions:consoleStart(5, 2)
    local saleDay = world.auctions:getAuction().day
    -- The sale day, then over at its midnight.
    for _ = 1, 3 do
        nextDay(world)
    end
    assertEquals(world.auctions:getAuction(), nil)
    -- Counted from the sale's month.
    local ended = TCCalendar.getDayInfo(saleDay)
    assertEquals(world.auctions.lastEndedPeriodIndex, ended)
    -- In the wait, even a sure roll announces nothing.
    assertEquals(world.auctions:rollAnnouncement(function() return 0 end), nil)

    local xmlFile = {}
    world.auctions:saveToXmlFile(xmlFile)
    local loaded = TheContractorAuctions.new()
    loaded:loadFromXMLFile(xmlFile)
    assertEquals(loaded.lastEndedPeriodIndex, ended)

    world.auctions:consoleStart(5, 20)
    nextDay(world)
    world.auctions:cancel(false)
    assertEquals(world.auctions.lastEndedPeriodIndex, TCCalendar.getPeriodIndex())
end)

test("a month's roll that misses, or with an auction on, announces nothing", function()
    local world = setup()
    world:addField(5, 7)
    world.candidates = { { fieldId = 5, problems = {} } }
    assertEquals(world.auctions:rollAnnouncement(function() return 0.99 end), nil)
    assertEquals(world.auctions:getAuction(), nil)
    assertTrue(world.auctions:rollAnnouncement(function() return 0 end) ~= nil)
    local first = world.auctions:getAuction()
    assertEquals(world.auctions:rollAnnouncement(function() return 0 end), nil)
    assertEquals(world.auctions:getAuction(), first)
end)

test("the site: the best fields that can hold the sale and have a farmer; none, no auction", function()
    local world = setup()
    world:addField(3, nil)
    world:addField(4, 7)
    world:addField(5, 8)
    world.candidates = {
        { fieldId = 3, problems = {} },
        { fieldId = 9, problems = { "tooSmall" } },
        { fieldId = 4, problems = {} },
        { fieldId = 5, problems = {} },
    }
    local site = world.auctions:pickSite(function() return 0 end)
    assertEquals(site.fieldId, 4, "field 3 has no farmer, field 9 can't hold it")
    assertEquals(site.hostId, 7)
    assertEquals(world.auctions:pickSite(function() return 0.99 end).fieldId, 5)

    world.candidates = { { fieldId = 9, problems = { "tooSteep" } } }
    assertEquals(world.auctions:announce(nil, 30), nil)
    assertEquals(world.auctions:getAuction(), nil)
    assertEquals(#getMessages(1), 0)
end)

test("the console's field must be free of any live job and held by a farmer", function()
    local world = setup()
    world:addField(5, 7)
    world:addField(6, nil)
    world.refusals = { [5] = "it has a live job" }
    world.auctions:consoleStart(5, 20)
    assertEquals(world.auctions:getAuction(), nil, "a live job on field 5")
    world.refusals = nil
    world.auctions:consoleStart(6, 20)
    assertEquals(world.auctions:getAuction(), nil, "no farmer holds field 6")
    world.auctions:consoleStart(5, 20)
    local auction = world.auctions:getAuction()
    assertEquals(auction.fieldId, 5)
    assertEquals(auction.hostFarmerId, 7)
    assertEquals(auction.day, 21)
    assertEquals(auction.entrance.x, 5)
end)

-- The days ----------------------------------------------------------------------------------

test("signs 3 months before if there's time, the reminder a week before, scaled to the month's days", function()
    setup()
    local signsDay, reminderDay = TheContractorAuctions.planDays(10, 100, 28)
    assertEquals(signsDay, 16)
    assertEquals(reminderDay, 93)
    -- Announced 2 months ahead: signs at once.
    signsDay = TheContractorAuctions.planDays(10, 66, 28)
    assertEquals(signsDay, 10)
    -- One day a month: signs 3 days before, the reminder the day before.
    signsDay, reminderDay = TheContractorAuctions.planDays(10, 14, 1)
    assertEquals(signsDay, 11)
    assertEquals(reminderDay, 13)
    -- A short lead: signs at once, no reminder on the announcement day.
    signsDay, reminderDay = TheContractorAuctions.planDays(10, 11, 28)
    assertEquals(signsDay, 10)
    assertEquals(reminderDay, nil)
end)

test("the state by day and hour", function()
    setup()
    local A = TheContractorAuctions
    local auction = { signsDay = 20, day = 30 }
    assertEquals(A.getStateFor(auction, 19, 12), A.STATE.ANNOUNCED)
    assertEquals(A.getStateFor(auction, 20, 0), A.STATE.SIGNS_UP)
    assertEquals(A.getStateFor(auction, 30, 0), A.STATE.SET_OUT)
    assertEquals(A.getStateFor(auction, 30, A.SALE_HOUR - 1), A.STATE.SET_OUT)
    assertEquals(A.getStateFor(auction, 30, A.SALE_HOUR), A.STATE.ON_SALE)
    assertEquals(A.getStateFor(auction, 30, A.SALE_END_HOUR), A.STATE.COLLECTION)
    assertEquals(A.getStateFor(auction, 30, 23), A.STATE.COLLECTION, "139: collection until midnight")
    assertEquals(A.getStateFor(auction, 31, 0), A.STATE.OVER)
end)

test("an auction's run: announced, signs, reminder, lots out on the morning, sale, collection, cleared away", function()
    local world = setup(10)
    world:addField(5, 7)
    local tc = g_currentMission.TheContractor
    world.auctions:consoleStart(5, 40)
    local auction = world.auctions:getAuction()
    local A = TheContractorAuctions

    -- Announced: the field's protected, every company farm's told, with the map.
    assertTrue(world.auctions:isFieldInUse(5))
    assertTrue(not world.auctions:isFieldInUse(6))
    for _, farmId in ipairs({ 1, 2 }) do
        local messages = getMessages(farmId)
        assertEquals(#messages, 1)
        assertEquals(messages[1].bodyKey, A.TEXTS.announced.body)
        assertEquals(messages[1].payload.farmerId, 7, "from the host")
        assertEquals(messages[1].actions[1].key, A.SHOW_ON_MAP_ACTION.key)
        assertEquals(messages[1].args[1], "$days_41_41")
    end
    assertEquals(auction.signsDay, 11)
    assertEquals(auction.reminderDay, 38)
    assertEquals(world.events[#world.events].auction, auction, "clients told")

    -- Signs 3 months before, with the sale's month: day 41 is in July.
    for _ = 1, 9 do
        nextDay(world)
    end
    assertEquals(auction.state, A.STATE.ANNOUNCED)
    nextDay(world)
    assertEquals(auction.state, A.STATE.SIGNS_UP)
    assertEquals(table.concat(world.signMonths, ","), "7")

    -- The reminder takes the announcement's place.
    for _ = 1, 27 do
        nextDay(world)
    end
    assertEquals(#getMessages(1), 1)
    assertEquals(getMessages(1)[1].bodyKey, A.TEXTS.reminder.body)

    -- The sale day's midnight: the lots set out for this auction, today's message.
    for _ = 1, 3 do
        nextDay(world)
    end
    assertEquals(auction.state, A.STATE.SET_OUT)
    assertEquals(#world.siteStarts, 1)
    assertEquals(world.siteStarts[1].fieldId, 5)
    assertEquals(world.siteStarts[1].auctionId, auction.id)
    assertEquals(getMessages(2)[1].bodyKey, A.TEXTS.today.body)

    setHour(world, A.SALE_HOUR)
    assertEquals(auction.state, A.STATE.ON_SALE)
    setHour(world, A.SALE_END_HOUR)
    assertEquals(auction.state, A.STATE.COLLECTION)
    assertEquals(world.siteClears, 0)

    -- The next midnight: everything's cleared and the field's free.
    nextDay(world)
    assertEquals(world.auctions:getAuction(), nil)
    assertEquals(world.siteClears, 1)
    assertEquals(tc.AuctionSigns.month, 0)
    assertEquals(#getMessages(1), 0)
    assertEquals(#getMessages(2), 0)
    assertTrue(not world.auctions:isFieldInUse(5))
    assertEquals(world.events[#world.events].auction, nil)
end)

test("days skipped over: nothing's put out only to be taken away", function()
    local world = setup(10)
    world:addField(5, 7)
    world.auctions:consoleStart(5, 40)
    g_currentMission.environment.currentMonotonicDay = 60
    world.auctions:advance(60, 0)
    assertEquals(world.auctions:getAuction(), nil)
    assertEquals(#world.signMonths, 0)
    assertEquals(#world.siteStarts, 0)
end)

test("the console's sale day puts the lots out now", function()
    local world = setup(10)
    world:addField(5, 7)
    world.auctions:consoleStart(5, 30)
    g_currentMission.environment.currentHour = TheContractorAuctions.SALE_HOUR - 1
    world.auctions:consoleSaleDay()
    local auction = world.auctions:getAuction()
    assertEquals(auction.day, 1)
    assertEquals(auction.state, TheContractorAuctions.STATE.SET_OUT)
    assertEquals(#world.siteStarts, 1)
    assertEquals(#world.signMonths, 1, "the signs went up on the way")
    assertEquals(getMessages(1)[1].bodyKey, TheContractorAuctions.TEXTS.today.body)
end)

-- Changing hands ---------------------------------------------------------------------------

test("a farm buying the field cancels it: lots and signs away, everyone told", function()
    local world = setup(10)
    local field = world:addField(5, 7)
    world.auctions:consoleStart(5, 3)
    world.auctions:consoleSaleDay()
    assertTrue(g_currentMission.TheContractor.AuctionSite.site ~= nil)

    field.owner = 1
    world.auctions:onFarmlandOwnerChanged(5, 1, false)
    assertEquals(world.auctions:getAuction(), nil)
    assertEquals(world.siteClears, 1)
    assertEquals(g_currentMission.TheContractor.AuctionSigns.month, 0)
    for _, farmId in ipairs({ 1, 2 }) do
        local messages = getMessages(farmId)
        assertEquals(#messages, 1)
        assertEquals(messages[1].bodyKey, TheContractorAuctions.TEXTS.cancelled.body)
        assertEquals(messages[1].actions[1].key, TheContractorInbox.DISMISS_ACTION.key)
    end
end)

test("the field going to another farmer cancels it at the next hour; a retirement doesn't", function()
    local world = setup(10)
    world:addField(5, 7)
    world.auctions:consoleStart(5, 20)

    -- 128's retirement: the successor holds it and becomes the host.
    world.people[9] = { id = 9, name = "Tom's son" }
    world.holders[5] = 9
    local tc = g_currentMission.TheContractor
    tc.Jobs = { jobsByFarm = {} }
    world:load("src/business/Farmers.lua")
    TheContractorFarmers.replacePersonReferences(tc.Farmers, 7, 9)
    setHour(world, 1)
    assertEquals(world.auctions:getAuction().hostFarmerId, 9)
    assertEquals(getMessages(1)[1].payload.farmerId, 9, "the messages are from the successor")

    -- 128's field sold: someone else's now.
    world.holders[5] = 8
    setHour(world, 2)
    assertEquals(world.auctions:getAuction(), nil)
    assertEquals(getMessages(1)[1].bodyKey, TheContractorAuctions.TEXTS.cancelled.body)
end)

test("nothing's cancelled while a save's still loading", function()
    local world = setup(10)
    local field = world:addField(5, 7)
    world.auctions:consoleStart(5, 20)
    field.owner = 1
    world.auctions:onFarmlandOwnerChanged(5, 1, true)
    assertTrue(world.auctions:getAuction() ~= nil, "an owner set as the save loads")
    g_currentMission.TheContractor.hasResolvedSavedVehicles = false
    setHour(world, 3)
    assertTrue(world.auctions:getAuction() ~= nil, "the farmers aren't set up yet")
end)

-- Every machine -----------------------------------------------------------------------------

test("a message names the host as they are now, the field and the date", function()
    local world = setup(10)
    world:addField(5, 7)
    world.auctions:consoleStart(5, 20)
    local message = getMessages(1)[1]
    world.people[7].name = "Thomas"
    local args = TheContractorAuctions.getMessageArgs(message)
    assertEquals(args[1], "Thomas")
    assertEquals(args[2], "5")
    assertEquals(args[3], "$days_21_21")
    assertEquals(g_currentMission.TheContractor.Inbox:getMessageCustomer(message).id, 7)
end)

test("Show on map is handled on the client and keeps the message; Dismiss goes to the server", function()
    local world = setup(10)
    world:addField(5, 7)
    world.auctions:consoleStart(5, 20)
    local message = getMessages(1)[1]
    local shown = {}
    world.auctions.marker = { isMarker = true }
    g_inGameMenu = {
        openMapOverview = function() shown.opened = true end,
        pageMapOverview = { showMapHotspot = function(_, hotspot) shown.hotspot = hotspot end },
    }
    local kind = g_currentMission.TheContractor.Inbox:getKind(TheContractorAuctions.KIND)
    assertEquals(kind.onClientAction(message, TheContractorAuctions.SHOW_ON_MAP_ACTION.key), true)
    assertTrue(shown.opened)
    assertEquals(shown.hotspot, world.auctions.marker)
    assertEquals(kind.onClientAction(message, TheContractorInbox.DISMISS_ACTION.key), false)
    assertTrue(g_currentMission.TheContractor.Inbox:getMessage(message.id) ~= nil)
end)

test("a client hears the auction from the server only, and puts the crowd up while the lots are out", function()
    local world = setup(10)
    world:addField(5, 7)
    world.auctions:consoleStart(5, 3)
    local announced = world.events[#world.events]

    local client = TheContractorAuctions.new()
    g_currentMission.TheContractor.Auctions = client
    announced:run({ getIsServer = function() return false end })
    assertTrue(not client:isFieldInUse(5))
    announced:run({ getIsServer = function() return true end })
    assertTrue(client:isFieldInUse(5))
    client:update(16)
    assertEquals(#world.crowdStarts, 0, "no crowd before the sale day")

    g_currentMission.TheContractor.Auctions = world.auctions
    world.auctions:consoleSaleDay()
    local site = g_currentMission.TheContractor.AuctionSite
    -- The site's own event hasn't landed yet: no walkways, no crowd.
    local walkways = site.walkways
    site.walkways = {}
    local stream = world:newStream()
    TCAuctionEvent.writeAuction(stream, world.auctions:getAuction())
    client:applySync(TCAuctionEvent.readAuction(stream))
    client:update(16)
    assertEquals(#world.crowdStarts, 0, "never on the spike's loops through the lots")

    -- Its walkways come: the crowd goes up on them, once, a fresh copy of
    -- the same ones (the next lot's event) changing nothing.
    site.walkways = walkways
    client:update(16)
    client:update(16)
    assertEquals(table.concat(world.crowdStarts, ","), "5", "once")
    assertEquals(world.crowdWalkways, walkways)
    site.walkways = { { x1 = 0, z1 = 0, x2 = 100, z2 = 0, halfWidth = 5 } }
    client:update(16)
    assertEquals(#world.crowdStarts, 1)
    site.walkways = { { x1 = 0, z1 = 0, x2 = 120, z2 = 0, halfWidth = 5 } }
    client:update(16)
    assertEquals(#world.crowdStarts, 2, "new walkways, a new crowd")

    client:applySync(nil)
    client:update(16)
    assertEquals(TCAuctionCrowd.active, nil)
    assertTrue(not client:isFieldInUse(5))
end)

test("140: the crowd gets the site's scene and hours, is as big as the sale, and goes up again for a new scene", function()
    local world = setup(10)
    world:addField(5, 7)
    world.auctions:consoleStart(5, 3)
    world.auctions:consoleSaleDay()
    local site = g_currentMission.TheContractor.AuctionSite
    site.scene = { seed = 7, rows = { { lotFrom = 1, lotTo = 40 }, { lotFrom = 41, lotTo = 88 } } }
    world.auctions:update(16)
    assertEquals(#world.crowdStarts, 1)
    assertEquals(world.crowdPeople, 1088, "sized by the last lot")
    assertEquals(world.crowdOptions.scene, site.scene)
    assertTrue(world.crowdOptions.useHours)
    -- The same scene again (a client's fresh copy): nothing.
    site.scene = { seed = 7, rows = site.scene.rows }
    world.auctions:update(16)
    assertEquals(#world.crowdStarts, 1)
    -- Another scene (a site put up again): a new crowd.
    site.scene = { seed = 8, rows = { { lotFrom = 1, lotTo = 10 } } }
    world.auctions:update(16)
    assertEquals(#world.crowdStarts, 2)
    assertEquals(world.crowdPeople, 1010)
end)

test("no crowd on a machine without a client, and a console crowd elsewhere is left alone", function()
    local world = setup(10)
    world:addField(5, 7)
    world.auctions:consoleStart(5, 3)
    world.auctions:consoleSaleDay()
    world.noCrowd = "dedicated"
    world.auctions:update(16)
    assertEquals(#world.crowdStarts, 0)

    world.noCrowd = nil
    TCAuctionCrowd.active = { fieldId = 99 }
    world.auctions:applySync(nil)
    world.auctions:update(16)
    assertEquals(TCAuctionCrowd.active.fieldId, 99)
end)

-- Saving ------------------------------------------------------------------------------------

test("the auction survives a save and load at any state, and a joining client gets it", function()
    local world = setup(10)
    world:addField(5, 7)
    world.auctions:consoleStart(5, 15)
    for _ = 1, 6 do
        nextDay(world)
    end
    local auction = world.auctions:getAuction()
    assertEquals(auction.state, TheContractorAuctions.STATE.SIGNS_UP)

    local xmlFile = {}
    world.auctions:saveToXmlFile(xmlFile)
    local loaded = TheContractorAuctions.new()
    loaded:loadFromXMLFile(xmlFile)
    local copy = loaded:getAuction()
    for _, key in ipairs({ "id", "fieldId", "hostFarmerId", "announcedDay", "signsDay", "reminderDay", "day",
            "state" }) do
        assertEquals(copy[key], auction[key], key)
    end
    assertEquals(copy.entrance.x, 5)
    assertEquals(loaded.nextId, 2)
    assertTrue(loaded:isFieldInUse(5))

    local stream = world:newStream()
    loaded:writeInitialClientState(stream)
    local client = TheContractorAuctions.new()
    client:readInitialClientState(stream)
    for _, key in ipairs({ "id", "fieldId", "hostFarmerId", "signsDay", "reminderDay", "day", "state" }) do
        assertEquals(client:getAuction()[key], auction[key], key)
    end
    assertEquals(client:getAuction().entrance.z, 6)

    -- None: only the id counter's saved, and a client gets none.
    local empty = TheContractorAuctions.new()
    empty.nextId = 4
    local emptyFile = {}
    empty:saveToXmlFile(emptyFile)
    local reloaded = TheContractorAuctions.new()
    reloaded:loadFromXMLFile(emptyFile)
    assertEquals(reloaded:getAuction(), nil)
    assertEquals(reloaded.nextId, 4)
    stream = world:newStream()
    reloaded:writeInitialClientState(stream)
    client:readInitialClientState(stream)
    assertEquals(client:getAuction(), nil)
end)

test("a lot-day save comes back on the sale day and carries on to its end", function()
    local world = setup(10)
    world:addField(5, 7)
    world.auctions:consoleStart(5, 3)
    world.auctions:consoleSaleDay()
    setHour(world, TheContractorAuctions.SALE_HOUR)
    local xmlFile = {}
    world.auctions:saveToXmlFile(xmlFile)

    local loaded = TheContractorAuctions.new()
    g_currentMission.TheContractor.Auctions = loaded
    world.auctions = loaded
    loaded:loadFromXMLFile(xmlFile)
    assertEquals(loaded:getAuction().state, TheContractorAuctions.STATE.ON_SALE)
    setHour(world, TheContractorAuctions.SALE_END_HOUR)
    assertEquals(loaded:getAuction().state, TheContractorAuctions.STATE.COLLECTION)
    assertEquals(#world.siteStarts, 1, "the lots aren't set out again: 135 saves its own")
    nextDay(world)
    assertEquals(loaded:getAuction(), nil)
    assertEquals(world.siteClears, 1)
end)

-- 161: the calendar ------------------------------------------------------------------------

test("161: a days-per-month change keeps the sale's date, plans its signs again and moves its messages", function()
    local world = setup(1)
    world:addField(5, 7)
    local tc = g_currentMission.TheContractor
    tc.Jobs = { jobsByFarm = {} }
    -- March 1 at a day a month: a sale in July, day 5.
    local auction = world.auctions:announce({ fieldId = 5, hostId = 7 }, 5)
    assertEquals(auction.day, 5)
    assertEquals(getMessages(1)[1].args[1], "$days_5_5")
    world.events = {}

    -- 2 days a month from summer: June is days 4-5, July 6-7.
    local before = TCCalendar.getModel()
    g_currentMission.environment.plannedDaysPerPeriod = 2
    local after = TCCalendar.getModel()
    world.auctions:remapDates(before, after)

    auction = world.auctions:getAuction()
    assertEquals(auction.day, 6)
    local signsDay, reminderDay = TheContractorAuctions.planDays(1, 6, 2)
    -- Signs went up on the day it was announced: they stay up.
    assertEquals(auction.signsDay, math.min(signsDay, 1))
    assertEquals(auction.reminderDay, reminderDay)
    assertEquals(getMessages(1)[1].args[1], "$days_6_6")
    assertTrue(#world.events > 0, "the new days sent to clients")
end)

test("161: once the lots are out, or on the sale day, the sale stays put", function()
    local before = { day = 10, periodIndex = 1, dayInPeriod = 1, daysPerPeriod = 1, plannedDaysPerPeriod = 1 }
    local after = { day = 10, periodIndex = 1, dayInPeriod = 1, daysPerPeriod = 1, plannedDaysPerPeriod = 2 }
    setup(1)
    local A = TheContractorAuctions
    assertEquals(A.getMovedSaleDay({ day = 14, state = A.STATE.ANNOUNCED }, before, after, 10), 15)
    assertEquals(A.getMovedSaleDay({ day = 14, state = A.STATE.SET_OUT }, before, after, 10), nil)
    assertEquals(A.getMovedSaleDay({ day = 10, state = A.STATE.SIGNS_UP }, before, after, 10), nil)
    assertEquals(A.getMovedSaleDay(nil, before, after, 10), nil)
end)
