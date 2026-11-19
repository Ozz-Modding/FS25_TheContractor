-- 163: the shared event day (TheContractorEventDay) and the rules across
-- its kinds (TheContractorPublicEvents): one at a time whatever the kind,
-- every kind's field protected and kept from a protest's day, a retirement
-- and a calendar change reaching every kind, the open day (a kind with no
-- lots) run from announcement to clear-up, sent to clients and saved, and
-- an auction saved before 163 loaded. The real kinds, Inbox and calendar;
-- the site (135), the signs (136), the crowd (134) and the farmers are
-- faked.

local function setup(daysPerPeriod)
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    Environment = { PERIODS_IN_YEAR = 12 }
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    MessageType = { DAY_CHANGED = 1, HOUR_CHANGED = 2, FARMLAND_OWNER_CHANGED = 3 }
    g_messageCenter = { subscribe = function() end, unsubscribeAll = function() end }
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
    world:load("src/business/OpenDay.lua")
    world:load("src/events/TCAuctionEvent.lua")
    world:load("src/events/TCEventDayEvent.lua")

    for month = 1, 12 do
        world.texts["ui_month" .. month] = "Month " .. month
    end
    daysPerPeriod = daysPerPeriod or 10
    g_currentMission.environment = {
        currentYear = 1, currentPeriod = 1, currentDayInPeriod = 1, daysPerPeriod = daysPerPeriod,
        plannedDaysPerPeriod = daysPerPeriod, currentMonotonicDay = 1, currentHour = 0,
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

    -- 135's site: what it was asked to put up and clear.
    world.candidates = {}
    world.siteStarts = {}
    world.openStarts = {}
    world.siteClears = 0
    world.walkways = { { x1 = 0, z1 = 0, x2 = 100, z2 = 0, halfWidth = 5 } }
    TheContractorAuctionSite = {
        PREFERRED_LOTS = 120,
        CLOSE_HOURS = { 17, 18 },
        getFieldRefusal = function() return nil end,
    }
    tc.AuctionSite = {
        site = nil,
        fieldId = 0,
        walkways = {},
        scene = nil,
        getWalkways = function(self) return self.walkways end,
        getScene = function(self) return self.scene end,
        getCandidates = function() return world.candidates end,
        start = function(self, fieldId, lotCount, auctionId)
            table.insert(world.siteStarts, { fieldId = fieldId, auctionId = auctionId })
            self.site = { fieldId = fieldId }
            self.fieldId, self.walkways = fieldId, world.walkways
        end,
        startOpen = function(self, fieldId, dressing, eventId)
            table.insert(world.openStarts, { fieldId = fieldId, dressing = dressing, eventId = eventId })
            self.site = { fieldId = fieldId }
            self.fieldId, self.walkways = fieldId, world.walkways
            self.scene = { seed = 9, rows = {}, dressing = dressing }
        end,
        removeUnsold = function() end,
        clear = function(self)
            world.siteClears = world.siteClears + 1
            self.site = nil
            self.fieldId, self.walkways, self.scene = 0, {}, nil
        end,
    }
    -- 136's signs, with the face they were put up with.
    world.signFaces = {}
    tc.AuctionSigns = {
        month = 0,
        signs = {},
        face = nil,
        place = function(self, month, face)
            table.insert(world.signFaces, face)
            self.month, self.signs, self.face = month, { { x = 1, z = 2, yaw = 0 } }, face
        end,
        clear = function(self) self.month, self.signs, self.face = 0, {}, nil end,
        describe = function(self) return #self.signs .. " sign(s)" end,
    }
    -- 134's crowd.
    world.crowdStarts = {}
    TCAuctionCrowd = {
        DEFAULT_PEOPLE = 60,
        active = nil,
        getUnavailableReason = function() return nil end,
        startOnWalkways = function(fieldId, walkways, people, options)
            table.insert(world.crowdStarts, { fieldId = fieldId, people = people, options = options })
            TCAuctionCrowd.active = { fieldId = fieldId }
        end,
        stop = function() TCAuctionCrowd.active = nil end,
        getFieldPolygon = function() return {} end,
        getAuctionPeople = function(lotCount) return 1000 + lotCount end,
    }
    TCAuctionLayout = { RULES = { entranceReach = 60 }, findEntrance = function() return { x = 5, z = 6 } end }
    TheContractorFallenTree = { sampleRoads = function() return {} end }

    tc.PublicEvents = TheContractorPublicEvents.new()
    tc.Auctions = TheContractorAuctions.new()
    tc.Auctions:register(tc.Inbox)
    tc.PublicEvents:registerKind(tc.Auctions)
    tc.OpenDay = TheContractorOpenDay.new()
    tc.OpenDay:register(tc.Inbox)
    tc.PublicEvents:registerKind(tc.OpenDay)
    world.tc = tc
    return world
end

-- The calendar moves on a day and every kind's day change runs.
local function nextDay(world)
    local environment = g_currentMission.environment
    environment.currentMonotonicDay = environment.currentMonotonicDay + 1
    environment.currentHour = 0
    environment.currentDayInPeriod = environment.currentDayInPeriod + 1
    if environment.currentDayInPeriod > environment.daysPerPeriod then
        environment.currentDayInPeriod = 1
        environment.currentPeriod = environment.currentPeriod % 12 + 1
    end
    world.tc.Auctions:onDayChanged()
    world.tc.OpenDay:onDayChanged()
end

local function setHour(world, hour)
    g_currentMission.environment.currentHour = hour
    world.tc.Auctions:onHourChanged()
    world.tc.OpenDay:onHourChanged()
end


-- One at a time ----------------------------------------------------------------------------

test("one at a time: an open day stops an auction being announced or rolled, and the other way round", function()
    local world = setup()
    world:addField(5, 7)
    world:addField(6, 8)
    world.candidates = { { fieldId = 6, problems = {} } }
    local tc = world.tc
    world.tc.OpenDay:consoleStart(5, 20)
    assertTrue(tc.OpenDay:getEvent() ~= nil)

    assertEquals(tc.Auctions:rollAnnouncement(function() return 0 end), nil, "a sure roll")
    assertEquals(tc.Auctions:announce({ fieldId = 6, hostId = 8 }, 30), nil)
    tc.Auctions:consoleStart(6, 30)
    assertEquals(tc.Auctions:getAuction(), nil)

    tc.OpenDay:cancel(false)
    assertTrue(tc.Auctions:announce({ fieldId = 6, hostId = 8 }, 30) ~= nil, "free again")
    tc.OpenDay:consoleStart(5, 20)
    assertEquals(tc.OpenDay:getEvent(), nil, "the auction's on now")
    local kind, event = tc.PublicEvents:getActive()
    assertEquals(kind, tc.Auctions)
    assertEquals(event.fieldId, 6)
end)

test("every kind's field is protected, and no protest falls on its crowd's day", function()
    local world = setup()
    world:addField(5, 7)
    local tc = world.tc
    tc.OpenDay:consoleStart(5, 20)
    assertTrue(tc.PublicEvents:isFieldInUse(5))
    assertTrue(not tc.PublicEvents:isFieldInUse(6))
    assertEquals(tc.PublicEvents:getEventOnField(5), tc.OpenDay)
    assertTrue(tc.PublicEvents:clashesWithCrowdDay(21))
    assertTrue(not tc.PublicEvents:clashesWithCrowdDay(20))
    assertTrue(not tc.PublicEvents:clashesWithCrowdDay(22))
end)

test("a crowd's day: the day itself to its after days, never with none", function()
    setup()
    local isCrowdDay = TheContractorPublicEvents.isCrowdDay
    local event = { day = 50 }
    assertTrue(isCrowdDay(50, event, 0), "the day")
    assertTrue(not isCrowdDay(51, event, 0), "the day after")
    assertTrue(isCrowdDay(51, event, 1), "an after day")
    assertTrue(not isCrowdDay(49, event, 0), "the day before")
    assertTrue(not isCrowdDay(50, nil, 0), "none")
end)

test("a retirement hands any kind's host on, and a calendar change moves any kind's day", function()
    local world = setup(1)
    world:addField(5, 7)
    local tc = world.tc
    tc.Jobs = { jobsByFarm = {} }
    -- March 1 at a day a month: in July, day 5.
    tc.OpenDay:announce({ fieldId = 5, hostId = 7 }, 5)
    assertEquals(tc.PublicEvents:replaceHost(7, 9), 1)
    assertEquals(tc.OpenDay:getEvent().hostFarmerId, 9)

    local before = TCCalendar.getModel()
    g_currentMission.environment.plannedDaysPerPeriod = 2
    tc.PublicEvents:remapDates(before, TCCalendar.getModel())
    assertEquals(tc.OpenDay:getEvent().day, 6, "the same date: July's first")
end)

-- The open day --------------------------------------------------------------------------------

test("an open day's run: no messages, its own signs, bare ground on the day, the crowd up, all cleared", function()
    local world = setup(10)
    world:addField(5, 7)
    local tc = world.tc
    tc.OpenDay:consoleStart(5, 20)
    local event = tc.OpenDay:getEvent()
    assertEquals(event.state, TheContractorEventDay.STATE.ANNOUNCED)
    assertEquals(#tc.Inbox:getMessages(1), 0, "a testing kind posts nothing")
    local sent = world.events[#world.events]
    assertEquals(sent.kind, TheContractorOpenDay.KIND)
    assertEquals(sent.event, event)

    -- Signs a month before, with the open day's face.
    for _ = 1, 10 do
        nextDay(world)
    end
    assertEquals(event.state, TheContractorEventDay.STATE.SIGNS_UP)
    assertEquals(table.concat(world.signFaces, ","), TheContractorOpenDay.KIND)

    -- The day's midnight: bare ground for this event, no lots.
    for _ = 1, 10 do
        nextDay(world)
    end
    assertEquals(event.state, TheContractorEventDay.STATE.SET_OUT)
    assertEquals(#world.siteStarts, 0)
    assertEquals(#world.openStarts, 1)
    assertEquals(world.openStarts[1].fieldId, 5)
    assertEquals(world.openStarts[1].dressing, TheContractorOpenDay.KIND)
    assertEquals(world.openStarts[1].eventId, event.id)

    tc.OpenDay:update(16)
    assertEquals(#world.crowdStarts, 1)
    assertEquals(world.crowdStarts[1].fieldId, 5)
    assertEquals(world.crowdStarts[1].people, TCAuctionCrowd.DEFAULT_PEOPLE)
    assertEquals(world.crowdStarts[1].options.scene.dressing, TheContractorOpenDay.KIND)
    tc.Auctions:update(16)
    assertEquals(#world.crowdStarts, 1, "the auction has nothing up")

    setHour(world, TheContractorOpenDay.START_HOUR)
    assertEquals(event.state, TheContractorEventDay.STATE.ON)
    setHour(world, TheContractorOpenDay.END_HOUR)
    assertEquals(event.state, TheContractorEventDay.STATE.AFTER)

    nextDay(world)
    assertEquals(tc.OpenDay:getEvent(), nil)
    assertEquals(world.siteClears, 1)
    assertEquals(tc.AuctionSigns.month, 0)
    assertTrue(not tc.PublicEvents:isFieldInUse(5))
    tc.OpenDay:update(16)
    assertEquals(TCAuctionCrowd.active, nil)
end)

test("the open day never rolls one itself", function()
    local world = setup()
    world:addField(5, 7)
    world.candidates = { { fieldId = 5, problems = {} } }
    assertEquals(world.tc.OpenDay:rollAnnouncement(function() return 0 end), nil)
end)

test("a client hears an open day from the server only, through the kinds' event", function()
    local world = setup(10)
    world:addField(5, 7)
    local server = world.tc.OpenDay
    server:consoleStart(5, 3)
    local announced = world.events[#world.events]

    local stream = world:newStream()
    announced:writeStream(stream)
    local client = TheContractorOpenDay.new()
    local clientEvents = TheContractorPublicEvents.new()
    clientEvents:registerKind(client)
    world.tc.PublicEvents = clientEvents
    local received = TCEventDayEvent.emptyNew()
    received:readStream(stream, { getIsServer = function() return false end })
    assertEquals(client:getEvent(), nil, "not from a client")
    received:run({ getIsServer = function() return true end })
    for _, key in ipairs({ "id", "fieldId", "hostFarmerId", "announcedDay", "signsDay", "day", "state" }) do
        assertEquals(client:getEvent()[key], server:getEvent()[key], key)
    end
    assertTrue(clientEvents:isFieldInUse(5))
end)

test("an open day survives a save and load, and a joining client gets it", function()
    local world = setup(10)
    world:addField(5, 7)
    local server = world.tc.OpenDay
    server:consoleStart(5, 15)
    for _ = 1, 6 do
        nextDay(world)
    end
    local event = server:getEvent()
    assertEquals(event.state, TheContractorEventDay.STATE.SIGNS_UP)

    local xmlFile = {}
    server:saveToXmlFile(xmlFile)
    world.tc.Auctions:saveToXmlFile(xmlFile)
    local loaded = TheContractorOpenDay.new()
    loaded:loadFromXMLFile(xmlFile)
    for _, key in ipairs({ "id", "fieldId", "hostFarmerId", "announcedDay", "signsDay", "reminderDay", "day",
            "state" }) do
        assertEquals(loaded:getEvent()[key], event[key], key)
    end
    local auctions = TheContractorAuctions.new()
    auctions:loadFromXMLFile(xmlFile)
    assertEquals(auctions:getAuction(), nil, "each kind its own")

    local stream = world:newStream()
    loaded:writeInitialClientState(stream)
    local client = TheContractorOpenDay.new()
    client:readInitialClientState(stream)
    assertEquals(client:getEvent().day, event.day)
    assertEquals(client:getEvent().state, TheContractorEventDay.STATE.SIGNS_UP)
end)

-- Older saves ---------------------------------------------------------------------------------

test("an auction saved before 163 loads with its sale day and its old state's name", function()
    local world = setup(10)
    local key = "TheContractor.auctions.auction"
    local xmlFile = {}
    setXMLInt(xmlFile, "TheContractor.auctions#nextId", 4)
    setXMLInt(xmlFile, key .. "#id", 3)
    setXMLInt(xmlFile, key .. "#fieldId", 5)
    setXMLInt(xmlFile, key .. "#hostFarmerId", 7)
    setXMLInt(xmlFile, key .. "#announcedDay", 1)
    setXMLInt(xmlFile, key .. "#signsDay", 2)
    setXMLInt(xmlFile, key .. "#saleDay", 12)
    setXMLString(xmlFile, key .. "#state", "onSale")
    local auctions = TheContractorAuctions.new()
    auctions:loadFromXMLFile(xmlFile)
    local auction = auctions:getAuction()
    assertEquals(auction.day, 12)
    assertEquals(auction.state, TheContractorAuctions.STATE.ON_SALE)

    setXMLString(xmlFile, key .. "#state", "collection")
    auctions = TheContractorAuctions.new()
    auctions:loadFromXMLFile(xmlFile)
    assertEquals(auctions:getAuction().state, TheContractorAuctions.STATE.COLLECTION)
    assertEquals(world.warnings ~= nil and #world.warnings or 0, 0)
end)
