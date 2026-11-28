-- 165: the agricultural show on 163's shared event day. Its schedule (once
-- a year in late summer, its announcement months held from the auction),
-- its site (164's plan kept, both fields protected, dressed and laid out at
-- midnight before, put back at midnight after), entries closing a week
-- before, the results at 16:00 (prize money scaled, reputation, the host's
-- opinion, the inbox), cancellation when either field changes hands, a
-- deleted farm's placings, a calendar change, a retirement, the sync event
-- and the save. The real Show, EventDay, PublicEvents, Auctions, Inbox and
-- calendar; 164's site, 135's site, 136's signs, 134's crowd, the farmers
-- and the rewards are faked.

local SHOW_FIELD = 5
local PLOUGH_FIELD = 6
local HOST_ID = 7

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    Environment = { PERIODS_IN_YEAR = 12 }
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    MessageType = { DAY_CHANGED = 1, HOUR_CHANGED = 2, FARMLAND_OWNER_CHANGED = 3 }
    g_messageCenter = { subscribe = function() end, unsubscribeAll = function() end }
    FarmlandManager = { NO_OWNER_FARM_ID = 0 }
    world.events = {}
    g_server = { broadcastEvent = function(_, event) table.insert(world.events, event) end }
    TCMessagePostedEvent = { new = function(message) return { posted = message } end }
    TCMessageRemovedEvent = { new = function(id) return { removed = id } end }
    TheContractorStaff = { scalePay = function(pay) return pay end }
    TheContractorJob = { STATE = { OFFERED = 1, NEGOTIATING = 2 } }
    TheContractorJobGeneration = { JOB_TYPES = {} }

    world:load("src/util/TCCalendar.lua")
    world:load("src/business/Inbox.lua")
    world:load("src/util/TCAuctionAttendance.lua")
    world:load("src/util/TCADSUsedLots.lua")
    world:load("src/util/TCLotInspections.lua")
    world:load("src/util/TCShowSite.lua")
    world:load("src/util/TCShowScene.lua")
    world:load("src/business/PublicEvents.lua")
    world:load("src/business/EventDay.lua")
    world:load("src/business/Auctions.lua")
    world:load("src/business/Show.lua")
    world:load("src/events/TCAuctionEvent.lua")
    world:load("src/events/TCShowEvent.lua")

    for month = 1, 12 do
        world.texts["ui_month" .. month] = "Month " .. month
    end
    -- Year 1, ten days a month: period p's day d is day (p - 1) * 10 + d.
    g_currentMission.environment = {
        currentYear = 1, currentPeriod = 1, currentDayInPeriod = 1, daysPerPeriod = 10,
        plannedDaysPerPeriod = 10, currentMonotonicDay = 1, currentHour = 0,
        daylight = { latitude = 55 },
    }

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
    world:addField(SHOW_FIELD, HOST_ID)
    world:addField(PLOUGH_FIELD, 8)

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

    -- 164's site: the best plan (two fields), what it was told to do.
    world.plan = {
        mode = "pair", showFieldId = SHOW_FIELD, ploughFieldId = PLOUGH_FIELD,
        showRect = { cx = 0, cz = 0, angle = 0, halfU = 60, halfV = 30 },
        ploughRect = { cx = 200, cz = 0, angle = 0, halfU = 100, halfV = 30 },
        plots = {}, entrance = { x = 70, z = 0, distance = 10 },
    }
    world.showSiteLog = {}
    tc.ShowSite = {
        site = nil,
        pickBest = function() return world.plan ~= nil and { plan = world.plan, problems = {} } or nil end,
        planOn = function() return { plan = world.plan, problems = {} } end,
        setPlan = function(self, plan)
            table.insert(world.showSiteLog, "plan")
            self.site = { plan = plan, dressed = false }
        end,
        dress = function(self)
            table.insert(world.showSiteLog, "dress")
            self.site.dressed = true
            return "dressed"
        end,
        -- 182: the pens' ground, after the showground's laid out.
        paintPenGround = function(self, scene)
            table.insert(world.showSiteLog, "pens")
            world.penGroundScene = scene
            return 1
        end,
        clear = function(self)
            table.insert(world.showSiteLog, self.site.dressed and "restore" or "clear")
            self.site = nil
            return "cleared"
        end,
    }

    -- 135's site, 136's signs, 134's crowd.
    world.openStarts = {}
    world.siteClears = 0
    TheContractorAuctionSite = { PREFERRED_LOTS = 120, CLOSE_HOURS = { 17, 18 },
        getFieldRefusal = function() return nil end }
    tc.AuctionSite = {
        site = nil, fieldId = 0, walkways = {}, scene = nil,
        getWalkways = function(self) return self.walkways end,
        getScene = function(self) return self.scene end,
        getCandidates = function() return {} end,
        startOpen = function(self, fieldId, dressing, eventId, options)
            table.insert(world.openStarts, { fieldId = fieldId, dressing = dressing, eventId = eventId,
                options = options })
            self.site = { fieldId = fieldId }
            self.fieldId = fieldId
        end,
        clear = function(self)
            world.siteClears = world.siteClears + 1
            self.site, self.fieldId = nil, 0
        end,
    }
    world.signFaces = {}
    tc.AuctionSigns = {
        month = 0, signs = {}, face = nil,
        place = function(self, month, face)
            table.insert(world.signFaces, face)
            self.month, self.signs, self.face = month, { { x = 1, z = 2, yaw = 0 } }, face
        end,
        clear = function(self) self.month, self.signs, self.face = 0, {}, nil end,
        describe = function(self) return #self.signs .. " sign(s)" end,
    }
    TCAuctionCrowd = {
        DEFAULT_PEOPLE = 60, active = nil,
        getUnavailableReason = function() return "none in tests" end,
        getFieldPolygon = function() return {} end,
        getAuctionPeople = function(lotCount) return 1000 + lotCount end,
        stop = function() end,
    }
    TCAuctionLayout = { RULES = { entranceReach = 60 }, findEntrance = function() return { x = 5, z = 6 } end }
    TheContractorFallenTree = { sampleRoads = function() return {} end }

    -- The rewards, as they're asked for.
    world.money, world.reputation, world.opinions, world.notices = {}, {}, {}, {}
    g_currentMission.addMoney = function(_, amount, farmId, moneyType)
        table.insert(world.money, { amount = amount, farmId = farmId, moneyType = moneyType })
    end
    tc.Settings = { scaleCost = function(_, amount) return amount * 2 end }
    TCEconomyScale = { scale = function(amount) return amount * 3 end }
    TheContractorGoodNews = { getReputationReward = function(farmId, jobs) return jobs * 10 end }
    tc.Reputation = { addReputation = function(_, farmId, delta)
        table.insert(world.reputation, { farmId = farmId, delta = delta })
    end }
    tc.Relationships = { adjust = function(_, farmId, customerId, delta, reason)
        table.insert(world.opinions, { farmId = farmId, customerId = customerId, delta = delta, reason = reason })
    end }
    tc.Notices = { publish = function(_, farmId) table.insert(world.notices, farmId) end }

    tc.PublicEvents = TheContractorPublicEvents.new()
    tc.Auctions = TheContractorAuctions.new()
    tc.Auctions:register(tc.Inbox)
    tc.PublicEvents:registerKind(tc.Auctions)
    tc.Show = TheContractorShow.new()
    tc.Show:register(tc.Inbox)
    tc.PublicEvents:registerKind(tc.Show)
    world.tc = tc
    return world
end

-- Puts the calendar on a day (year 1, ten days a month) without running
-- anything.
local function setDay(day)
    local environment = g_currentMission.environment
    environment.currentMonotonicDay = day
    environment.currentHour = 0
    environment.currentPeriod = math.floor((day - 1) / 10) + 1
    environment.currentDayInPeriod = (day - 1) % 10 + 1
end

local function nextDay(world)
    setDay(g_currentMission.environment.currentMonotonicDay + 1)
    world.tc.Auctions:onDayChanged()
    world.tc.Show:onDayChanged()
end

local function setHour(world, hour)
    g_currentMission.environment.currentHour = hour
    world.tc.Auctions:onHourChanged()
    world.tc.Show:onHourChanged()
end

local function always()
    return 0
end

local function getKeys(world, farmId)
    local keys = {}
    for _, message in ipairs(world.tc.Inbox:getMessages(farmId)) do
        table.insert(keys, message.titleKey)
    end
    table.sort(keys)
    return keys
end

-- A competition with set placings.
local function addCompetition(world, placings, takesEntries)
    world.tc.Show:registerCompetition("test", {
        titleKey = "tc_show_timetable_judging",
        takesEntries = takesEntries,
        getPlacings = function() return placings end,
    })
end

-- The schedule ---------------------------------------------------------------------------------

test("it's announced in late spring for late summer, then not again that year", function()
    local world = setup()
    local show = world.tc.Show
    setDay(21)
    local event = show:rollAnnouncement(always)
    assertTrue(event ~= nil, "period 3, three months ahead")
    assertEquals(event.day, 51, "late summer's first day")
    assertEquals(event.fieldId, SHOW_FIELD)
    assertEquals(event.ploughFieldId, PLOUGH_FIELD)
    assertEquals(event.hostFarmerId, HOST_ID)
    assertEquals(show:rollAnnouncement(always), nil, "one at a time")

    show:cancel(false)
    setDay(31)
    assertEquals(show:rollAnnouncement(always), nil, "not again that year")

    world = setup()
    setDay(41)
    assertEquals(world.tc.Show:rollAnnouncement(always), nil, "period 5 has no lead into late summer")
end)

test("it's announced in early summer if late spring was taken", function()
    local world = setup()
    setDay(31)
    local event = world.tc.Show:rollAnnouncement(always)
    assertTrue(event ~= nil)
    assertEquals(event.day, 51, "two months ahead")
end)

test("its months are held from the auction while it's due, and no site means no show", function()
    local world = setup()
    local tc = world.tc
    tc.AuctionSite.getCandidates = function() return { { fieldId = SHOW_FIELD, problems = {} } } end
    setDay(21)
    assertEquals(tc.Auctions:rollAnnouncement(always), nil, "held for the show")
    assertEquals(tc.PublicEvents:getHoldingKind(tc.Auctions, 3, 3), tc.Show)
    assertEquals(tc.PublicEvents:getHoldingKind(tc.Show, 3, 3), nil, "never from itself")
    assertEquals(tc.PublicEvents:getHoldingKind(tc.Auctions, 5, 5), nil, "not a held month")

    -- Once this year's has been, the months are free.
    tc.Show.lastEndedPeriodIndex = 2
    assertEquals(tc.PublicEvents:getHoldingKind(tc.Auctions, 3, 3), nil)

    tc.Show.lastEndedPeriodIndex = nil
    world.plan = nil
    assertEquals(tc.Show:rollAnnouncement(always), nil, "no site")
    assertEquals(tc.Show:getEvent(), nil)
end)

-- The run ------------------------------------------------------------------------------------

test("announced: its plan kept, both fields protected, the entry days planned, every company told", function()
    local world = setup()
    local tc = world.tc
    local event = tc.Show:announce(nil, 51, always)
    assertEquals(table.concat(world.showSiteLog, ","), "plan")
    assertEquals(tc.ShowSite.site.plan, world.plan)
    assertTrue(tc.PublicEvents:isFieldInUse(SHOW_FIELD))
    assertTrue(tc.PublicEvents:isFieldInUse(PLOUGH_FIELD))
    assertEquals(tc.PublicEvents:getEventOnField(PLOUGH_FIELD), tc.Show)
    -- A week (a quarter of ten days, rounded) before, and a fortnight.
    assertEquals(event.entriesCloseDay, 48)
    assertEquals(event.entryReminderDay, 46)
    assertTrue(TheContractorShow.isEntryOpen(event, 47))
    assertTrue(not TheContractorShow.isEntryOpen(event, 48))
    assertEquals(table.concat(getKeys(world, 1), ","), "tc_show_announced_title")
    assertEquals(table.concat(getKeys(world, 2), ","), "tc_show_announced_title")
    assertEquals(getmetatable(world.events[#world.events]), getmetatable(TCShowEvent.emptyNew()))
end)

test("entries closing is only posted for a show that takes entries", function()
    local world = setup()
    local tc = world.tc
    tc.Show:announce(nil, 51, always)
    setDay(45)
    nextDay(world)
    assertEquals(table.concat(getKeys(world, 1), ","), "tc_show_announced_title", "nothing to enter")

    world = setup()
    tc = world.tc
    addCompetition(world, {}, true)
    tc.Show:announce(nil, 51, always)
    setDay(45)
    nextDay(world)
    assertEquals(table.concat(getKeys(world, 1), ","), "tc_show_entriesClosing_title")
end)

test("the day: signs a month before, dressed and laid out at midnight, results at 16:00, put back at midnight after", function()
    local world = setup()
    local tc = world.tc
    addCompetition(world, {
        { placing = 2, farmId = 2, entrant = "Bess" },
        { placing = 1, farmId = 1, entrant = "Daisy" },
        { placing = 3, farmerId = 8, entrant = "Ann's ewe", prize = 5 },
    })
    local event = tc.Show:announce(nil, 51, always)

    setDay(40)
    nextDay(world)
    assertEquals(event.state, TheContractorEventDay.STATE.SIGNS_UP)
    assertEquals(table.concat(world.signFaces, ","), "show")

    setDay(50)
    nextDay(world)
    assertEquals(event.state, TheContractorEventDay.STATE.SET_OUT)
    assertEquals(table.concat(world.showSiteLog, ","), "plan,dress,pens")
    assertEquals(#world.openStarts, 1)
    local start = world.openStarts[1]
    assertEquals(start.fieldId, SHOW_FIELD)
    assertEquals(start.dressing, "show")
    assertEquals(start.eventId, event.id)
    assertEquals(start.options.rect, world.plan.showRect)
    assertEquals(start.options.keepGround, true)
    assertEquals(start.options.getWalkways, TCShowScene.getWalkways)

    setHour(world, 8)
    assertEquals(event.state, TheContractorEventDay.STATE.ON)
    setHour(world, 15)
    assertEquals(tc.Show:getResults(), nil, "not before 16:00")
    setHour(world, 16)
    local results = tc.Show:getResults()
    assertEquals(#results.placings, 3)
    assertEquals(results.placings[1].farmId, 1, "first first")
    -- 50 a first, scaled by the cost setting (x2) and EconomyScale (x3).
    assertEquals(results.placings[1].paid, 300)
    assertEquals(results.placings[2].paid, 180)
    assertEquals(results.placings[3].paid, 0, "a farmer's isn't paid")
    assertEquals(results.placings[3].prize, 5, "its own prize kept")
    assertEquals(#world.money, 2)
    assertEquals(world.money[1].moneyType, MoneyType.TC_SHOW_PRIZES)
    assertEquals(world.reputation[1].delta, 30)
    assertEquals(world.reputation[2].delta, 20)
    assertEquals(world.opinions[1].customerId, HOST_ID)
    assertEquals(world.opinions[1].delta, TheContractorShow.HOST_OPINION[1])
    assertEquals(world.opinions[1].reason, TheContractorShow.RELATIONSHIP_REASON)
    assertEquals(table.concat(world.notices, ","), "1,2")
    local resultsMessage = nil
    for _, message in ipairs(tc.Inbox:getMessages(1)) do
        if message.titleKey == "tc_show_results_title" then
            resultsMessage = message
        end
    end
    assertEquals(resultsMessage.args[2], "1", "farm 1 placed once")
    assertEquals(resultsMessage.args[3], "$money_300")

    setHour(world, 17)
    assertEquals(#world.money, 2, "once a show")
    setHour(world, 18)
    assertEquals(event.state, TheContractorEventDay.STATE.AFTER)

    nextDay(world)
    assertEquals(tc.Show:getEvent(), nil)
    assertEquals(table.concat(world.showSiteLog, ","), "plan,dress,pens,restore")
    assertEquals(world.siteClears, 1)
    assertEquals(tc.AuctionSigns.month, 0)
    assertTrue(not tc.PublicEvents:isFieldInUse(PLOUGH_FIELD))
    assertEquals(tc.Show:getResults(), results, "kept until the next show")
    local keys = getKeys(world, 1)
    assertEquals(table.concat(keys, ","), "tc_show_results_title", "the results outlast the show's other messages")
end)

test("a long sleep past the day gives the results and puts nothing out", function()
    local world = setup()
    local tc = world.tc
    addCompetition(world, { { placing = 1, farmId = 1, entrant = "Daisy" } })
    tc.Show:announce(nil, 51, always)
    setDay(52)
    tc.Show:onDayChanged()
    assertEquals(tc.Show:getEvent(), nil)
    assertEquals(#world.openStarts, 0, "nothing set out")
    assertEquals(#tc.Show:getResults().placings, 1)
end)

test("the show tab's months, and the timetable's states on the day", function()
    setup()
    assertTrue(TheContractorShow.isShowMonth(6, 6, nil))
    assertTrue(TheContractorShow.isShowMonth(6, nil, 6))
    assertTrue(not TheContractorShow.isShowMonth(5, 6, 4))
    -- 188: the judging runs on through the ploughing, a class at a time.
    local states = TheContractorShow.getTimetableStates(TheContractorShow.TIMETABLE, 51, 51, 12)
    assertEquals(table.concat(states, ","), "done,now,now,next,next")
    states = TheContractorShow.getTimetableStates(TheContractorShow.TIMETABLE, 51, 51, 16)
    assertEquals(table.concat(states, ","), "done,done,done,now,next")
    assertEquals(table.concat(TheContractorShow.getTimetableStates(TheContractorShow.TIMETABLE, 50, 51, 12), ","),
        "next,next,next,next,next")
    assertEquals(table.concat(TheContractorShow.getTimetableStates(TheContractorShow.TIMETABLE, 52, 51, 0), ","),
        "done,done,done,done,done")
end)

-- Called off -----------------------------------------------------------------------------------

test("188: the show tab's up from the announcement to the day; late entries until 09:30 on the day", function()
    local world = setup()
    local tc = world.tc
    local event = tc.Show:announce(nil, 51, always)
    g_currentMission.environment.currentMonotonicDay = 5
    assertTrue(TCCalendar.getDayInfo(5) ~= TCCalendar.getDayInfo(51), "another month")
    assertTrue(tc.Show:isTabShown(), "months before")
    g_currentMission.environment.currentMonotonicDay = 61
    assertTrue(TCCalendar.getDayInfo(61) ~= TCCalendar.getDayInfo(51))
    assertTrue(not tc.Show:isTabShown(), "after the day, another month, no results")
    -- Entries close on day 48: late ones from then to 09:30 on the day.
    local closeMinute = TheContractorShow.ENTRY_CLOSE_MINUTE
    assertTrue(closeMinute < TheContractorShow.JUDGING_HOUR * 60, "before judging starts")
    assertTrue(not TheContractorShow.isLateEntryOpen(event, 47, 720), "entries still open")
    assertTrue(TheContractorShow.isLateEntryOpen(event, 48, 0))
    assertTrue(TheContractorShow.isLateEntryOpen(event, 51, closeMinute - 1))
    assertTrue(not TheContractorShow.isLateEntryOpen(event, 51, closeMinute))
    assertTrue(not TheContractorShow.isLateEntryOpen(event, 52, 0))
end)

test("the ploughing field bought by a farm calls it off and puts the site back", function()
    local world = setup()
    local tc = world.tc
    tc.Show:announce(nil, 51, always)
    setDay(50)
    nextDay(world)
    world.fields[PLOUGH_FIELD].owner = 3
    setHour(world, 1)
    assertEquals(tc.Show:getEvent(), nil)
    assertEquals(table.concat(world.showSiteLog, ","), "plan,dress,pens,restore")
    assertEquals(world.siteClears, 1)
    local found = false
    for _, message in ipairs(tc.Inbox:getMessages(1)) do
        found = found or message.titleKey == "tc_show_cancelled_title"
    end
    assertTrue(found, "every company told")
end)

test("the console's cancel before the day drops the plan with nothing to put back", function()
    local world = setup()
    local tc = world.tc
    tc.Show:announce(nil, 51, always)
    assertTrue(tc.Show:cancel(true))
    assertEquals(table.concat(world.showSiteLog, ","), "plan,clear")
    assertEquals(tc.ShowSite.site, nil)
end)

-- Farms, farmers and the calendar --------------------------------------------------------------

test("a deleted farm's placings go, and a retired farmer's host and placings pass on", function()
    local world = setup()
    local tc = world.tc
    tc.Show.results = { showId = 1, day = 51, fieldId = SHOW_FIELD, hostFarmerId = HOST_ID, placings = {
        { placing = 1, farmId = 1, farmerId = 0 },
        { placing = 2, farmId = 0, farmerId = HOST_ID },
        { placing = 3, farmId = 2, farmerId = 0 },
    } }
    tc.Show:forgetFarm(1)
    assertEquals(#tc.Show.results.placings, 2)
    assertEquals(tc.Show.results.placings[2].farmId, 2)

    tc.Show:announce(nil, 51, always)
    assertEquals(tc.PublicEvents:replaceHost(HOST_ID, 9), 3, "the event's host, the results' and a placing")
    assertEquals(tc.Show:getEvent().hostFarmerId, 9)
    assertEquals(tc.Show.results.hostFarmerId, 9)
    assertEquals(tc.Show.results.placings[1].farmerId, 9)
end)

test("a calendar change moves the day and plans the entry days again", function()
    local world = setup()
    local tc = world.tc
    local event = tc.Show:announce(nil, 55, always)
    local before = TCCalendar.getModel()
    g_currentMission.environment.plannedDaysPerPeriod = 20
    tc.PublicEvents:remapDates(before, TCCalendar.getModel())
    assertTrue(event.day ~= 55, "moved")
    local closeDay = TheContractorShow.planEntryDays(event.announcedDay, event.day,
        TCCalendar.getDaysPerPeriodOn(event.day), TheContractorShow.ENTRY_CLOSE_MONTHS,
        TheContractorShow.ENTRY_REMINDER_MONTHS)
    assertEquals(event.entriesCloseDay, closeDay)
end)

-- Sync and save --------------------------------------------------------------------------------

test("a client hears the show and its results from the server only", function()
    local world = setup()
    local tc = world.tc
    local event = tc.Show:announce(nil, 51, always)
    tc.Show.results = { showId = 0, day = 1, fieldId = 3, hostFarmerId = 8, placings = {
        { titleKey = "k", placing = 1, farmId = 2, farmerId = 0, entrant = "Bess", prize = 50, paid = 300 } } }
    tc.Show:sync()
    local sent = world.events[#world.events]
    local stream = world:newStream()
    sent:writeStream(stream)

    local client = TheContractorShow.new()
    tc.Show = client
    local received = TCShowEvent.emptyNew()
    received:readStream(stream, { getIsServer = function() return false end })
    assertEquals(client:getEvent(), nil, "not from a client")
    received:run({ getIsServer = function() return true end })
    for _, key in ipairs({ "id", "fieldId", "ploughFieldId", "hostFarmerId", "day", "entriesCloseDay",
            "entryReminderDay", "state" }) do
        assertEquals(client:getEvent()[key], event[key], key)
    end
    assertEquals(client:getResults().placings[1].entrant, "Bess")
    assertEquals(client:getResults().placings[1].paid, 300)
    assertTrue(client:isFieldInUse(PLOUGH_FIELD))
end)

test("the show and its results survive a save and load, and a joining client gets them", function()
    local world = setup()
    local tc = world.tc
    local event = tc.Show:announce(nil, 51, always)
    tc.Show.results = { showId = 0, day = 1, fieldId = 3, hostFarmerId = 8, placings = {
        { titleKey = "k", placing = 2, farmId = 0, farmerId = 8, entrant = "Ann's ewe", prize = 30, paid = 0 } } }

    local xmlFile = {}
    tc.Show:saveToXmlFile(xmlFile)
    local loaded = TheContractorShow.new()
    loaded:loadFromXMLFile(xmlFile)
    for _, key in ipairs({ "id", "fieldId", "ploughFieldId", "hostFarmerId", "day", "entriesCloseDay",
            "entryReminderDay", "state", "resultsGiven" }) do
        assertEquals(loaded:getEvent()[key], event[key], key)
    end
    assertEquals(loaded:getResults().placings[1].farmerId, 8)
    assertEquals(loaded.nextId, 2)

    local stream = world:newStream()
    loaded:writeInitialClientState(stream)
    local client = TheContractorShow.new()
    client:readInitialClientState(stream)
    assertEquals(client:getEvent().ploughFieldId, PLOUGH_FIELD)
    assertEquals(client:getResults().placings[1].entrant, "Ann's ewe")
end)
