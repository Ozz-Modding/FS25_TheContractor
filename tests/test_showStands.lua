-- 171: the show's stands and the farmers at it. The stalls and farmers'
-- spots on the showground, who's at the show and where they stand, the
-- once-per-show limits (a farmer's opinion lift, "any work going?", the
-- careers stand), the association's discounted joining, the careers
-- stand's kept candidates, the host's goodwill for turning up, and the
-- visits' sync, save, deleted farm and retired farmer.
--
-- The real Show, EventDay, PublicEvents, show scene, Overheads,
-- Association, Settings and Staff; relationships, job offers, companies and
-- the site faked.

local SHOW_FIELD = 5
local HOST_ID = 7
local SHOW_DAY = 51

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
    world.events = {}
    g_server = { broadcastEvent = function(_, event) table.insert(world.events, event) end }
    TCOverheadStateEvent = { new = function() return {} end }
    TCStaffCandidateAddedEvent = { new = function(candidate) return { candidate = candidate } end }
    TCStaffCandidateRemovedEvent = { new = function(id) return { removedCandidate = id } end }
    TCMessagePostedEvent = { new = function(message) return { posted = message } end }
    TCMessageRemovedEvent = { new = function(id) return { removed = id } end }
    TheContractorJob = { STATE = { OFFERED = 1, NEGOTIATING = 2, ACCEPTED = 3 } }
    TheContractorJobGeneration = { JOB_TYPES = {} }
    world.texts.ui_on, world.texts.ui_off = "On", "Off"
    for month = 1, 12 do
        world.texts["ui_month" .. month] = "Month " .. month
    end

    g_currentMission.environment = {
        currentYear = 1, currentPeriod = 1, currentDayInPeriod = 1, daysPerPeriod = 10,
        plannedDaysPerPeriod = 10, currentMonotonicDay = 1, currentHour = 0, dayTime = 0,
    }
    world.balance = 1000000
    g_farmManager.getFarmById = function(_, farmId)
        return { farmId = farmId, getBalance = function() return world.balance end }
    end
    world.money = {}
    g_currentMission.addMoney = function(_, amount, farmId, moneyType)
        world.balance = world.balance + amount
        table.insert(world.money, { amount = amount, farmId = farmId, moneyType = moneyType })
    end

    world:load("src/util/TCCalendar.lua")
    world:load("src/business/Inbox.lua")
    world:load("src/business/Settings.lua")
    world:load("src/business/Overheads.lua")
    world:load("src/business/Association.lua")
    world:load("src/business/Relationships.lua")
    world:load("src/business/Worker.lua")
    world:load("src/business/Staff.lua")
    world:load("src/util/TCAuctionAttendance.lua")
    world:load("src/util/TCAuctionLayout.lua")
    world:load("src/util/TCAuctionScene.lua")
    world:load("src/util/TCShowScene.lua")
    world:load("src/util/TCShowStands.lua")
    world:load("src/business/PublicEvents.lua")
    world:load("src/business/EventDay.lua")
    world:load("src/business/Show.lua")
    world:load("src/business/ShowStands.lua")
    world:load("src/events/TCShowStandsEvent.lua")
    world:load("src/events/TCShowTalkEvent.lua")

    local tc = g_currentMission.TheContractor
    tc.Settings = TheContractorSettings.new()
    world.companies = { [1] = true, [2] = true }
    tc.Company = { hasCompany = function(_, farmId) return world.companies[farmId] == true end }
    tc.Inbox = TheContractorInbox.new()
    tc.Notices = { publish = function() end }
    tc.Finances = { recordOverheads = function() end }
    tc.Overheads = TheContractorOverheads.new()
    tc.Association = TheContractorAssociation.new()
    tc.Association:register(tc.Overheads, tc.Inbox)

    -- Staff: the real pool, with what a new candidate needs faked.
    tc.Staff = setmetatable({ workersByFarm = {}, candidatePool = {}, nextWorkerId = 1 }, TheContractorStaff_mt)
    TheContractorStaff.generateName = function() return "Candidate" end
    TCWorkerAppearance = { GENDER = { MALE = "male", FEMALE = "female" }, rollGender = function() return "male" end,
        roll = function() return {} end, writeStream = function() end, readStream = function() return {} end,
        writeXML = function() end, readXML = function() return {} end }
    TCADSWorkshop = { isActive = function() return false end }
    TheContractorWorkshop = { getSalaryPremium = function() return 0 end }
    TheContractorMorale = { rollTemperament = function() return 1 end }
    TheContractorTraining = { rollCandidateCertifications = function() end }

    world.people = {}
    for _, id in ipairs({ 7, 8, 9, 10, 11, 12, 13, 14, 15 }) do
        world.people[id] = { id = id, name = "Farmer " .. id }
    end
    tc.Farmers = {
        getHolder = function() return world.people[HOST_ID] end,
        getPerson = function(_, id) return world.people[id] end,
        getFarmers = function()
            local farmers = {}
            for id = 7, 15 do
                if world.people[id] ~= nil then
                    table.insert(farmers, world.people[id])
                end
            end
            return farmers
        end,
    }
    world.opinions, world.refuses, world.scores = {}, {}, {}
    tc.Relationships = {
        adjust = function(_, farmId, customerId, delta, reason)
            table.insert(world.opinions, { farmId = farmId, customerId = customerId, delta = delta, reason = reason })
        end,
        refuses = function(_, farmId, customerId) return world.refuses[customerId] == true end,
        getScore = function(_, farmId, customerId) return world.scores[customerId] or 0 end,
    }
    world.offers = {}
    tc.JobGeneration = {
        generateForFarm = function(_, farmId, offerSource, customerId)
            table.insert(world.offers, { farmId = farmId, offerSource = offerSource, customerId = customerId })
            if world.noJobs then
                return nil
            end
            return { id = 100 + #world.offers }
        end,
    }

    -- The showground (tests/test_showWorker.lua's).
    local rect = { cx = 100, cz = 50, angle = 0, halfU = 60, halfV = 30 }
    local entrance = { x = rect.cx + rect.halfU + 10, z = rect.cz }
    world.scene = TCAuctionLayout.getScene(TCAuctionLayout.layOutOpenRect(rect, entrance), entrance, 99)
    world.scene.dressing = "show"
    world.siteUp = false
    tc.AuctionSite = { getScene = function() return world.siteUp and world.scene or nil end }

    tc.PublicEvents = TheContractorPublicEvents.new()
    tc.Show = TheContractorShow.new()
    tc.ShowStands = TheContractorShowStands.new()
    tc.ShowStands:register(tc.Show)
    tc.ShowStands.random = function() return world.roll or 0.5 end
    tc.ShowStands.randomInt = function(a) return a end
    world.tc = tc
    world.stands = tc.ShowStands
    return world
end

-- The show on SHOW_DAY, announced and set out, open at hour.
local function openShow(world, hour)
    local event = { id = 3, day = SHOW_DAY, fieldId = SHOW_FIELD, hostFarmerId = HOST_ID }
    world.tc.Show.event = event
    world.stands:reset(event.id)
    world.siteUp = true
    local environment = g_currentMission.environment
    environment.currentMonotonicDay = SHOW_DAY
    environment.currentHour = hour or 10
    environment.dayTime = (hour or 10) * 3600000
    return event
end

local function countOpinions(world, customerId)
    local found = {}
    for _, opinion in ipairs(world.opinions) do
        if opinion.customerId == customerId then
            table.insert(found, opinion)
        end
    end
    return found
end

local R, A = nil, nil

-- The showground ------------------------------------------------------------------------------------

test("the showground has the two stalls at stands, a table at each, and farmers' spots the crowd doesn't use", function()
    local world = setup()
    R, A = TCShowStands.REQUEST, TCShowStands.ANSWER
    local stalls = TCShowScene.getStallStands(5)
    assertEquals(stalls.association, 2)
    assertEquals(stalls.careers, 4)
    local few = TCShowScene.getStallStands(2)
    assertEquals(few.association, 1)
    assertEquals(few.careers, 2)
    assertEquals(TCShowScene.getStallStands(1).careers, nil, "no stand left for it")

    local layout = TCShowScene.layOut(world.scene)
    assertEquals(#layout.stalls, 2, "two stallholders")
    local tables = 0
    for _, prop in ipairs(layout.props) do
        if prop.kind == "standTable" then
            tables = tables + 1
        end
    end
    assertEquals(tables, 2, "a table at each stall")
    assertTrue(#layout.mingles >= TCShowStands.FARMERS_AT_SHOW + 1, "room for the farmers")
    for _, mingle in ipairs(layout.mingles) do
        for _, spot in ipairs(layout.spots) do
            assertTrue(math.abs(mingle.x - spot.x) > 0.5 or math.abs(mingle.z - spot.z) > 0.5,
                "a farmer's spot isn't a spectator's")
        end
    end
    -- The same on every machine.
    local again = TCShowScene.layOut(world.scene)
    assertEquals(again.stalls[1].x, layout.stalls[1].x)
    assertEquals(#again.mingles, #layout.mingles)
end)

test("who's at the show: the host and five others, never a ploughing farmer, the same on every machine", function()
    setup()
    local farmers = {}
    for id = 7, 15 do
        table.insert(farmers, { id = id })
    end
    local ids = TCShowStands.pickFarmers(3, farmers, HOST_ID, {})
    assertEquals(#ids, TCShowStands.FARMERS_AT_SHOW + 1)
    assertEquals(ids[1], HOST_ID, "the host first")
    assertEquals(table.concat(TCShowStands.pickFarmers(3, farmers, HOST_ID, {}), ","), table.concat(ids, ","),
        "the same pick again")
    local excluded = { [ids[2]] = true }
    for _, id in ipairs(TCShowStands.pickFarmers(3, farmers, HOST_ID, excluded)) do
        assertTrue(id ~= ids[2], "a ploughing farmer's not walking about")
    end
    local otherShow = TCShowStands.pickFarmers(4, farmers, HOST_ID, {})
    assertTrue(table.concat(otherShow, ",") ~= table.concat(ids, ","), "another show, other farmers")
end)

test("each farmer has a spot of their own, a new one some slots, the same on every machine", function()
    setup()
    local ids = { 7, 8, 9, 10, 11, 12 }
    local moved = 0
    local last = nil
    for slot = 0, 4 do
        local spots = TCShowStands.assignSpots(3, slot, ids, 10)
        local used = {}
        for _, id in ipairs(ids) do
            assertTrue(spots[id] ~= nil and spots[id] >= 1 and spots[id] <= 10, "a spot")
            assertTrue(not used[spots[id]], "nobody shares")
            used[spots[id]] = true
        end
        assertEquals(TCShowStands.assignSpots(3, slot, ids, 10)[9], spots[9], "the same again")
        if last ~= nil and last[9] ~= spots[9] then
            moved = moved + 1
        end
        last = spots
    end
    assertTrue(moved >= 1, "they move about")
    local short = TCShowStands.assignSpots(3, 0, ids, 4)
    local placed = 0
    for _ in pairs(short) do
        placed = placed + 1
    end
    assertEquals(placed, 4, "no more than the spots")
    assertEquals(TCShowStands.getSlot(7.9, 8, 18), nil, "before the gates")
    assertEquals(TCShowStands.getSlot(9.5, 8, 18), 0)
    assertEquals(TCShowStands.getSlot(17.9, 8, 18), 4)
    assertEquals(TCShowStands.getSlot(18, 8, 18), nil, "after")
end)

-- Opening ----------------------------------------------------------------------------------------------

test("the stands are open on the show's day in its hours, with the showground out", function()
    local world = setup()
    local stands = world.stands
    assertTrue(not stands:isOpen(), "no show")
    local event = openShow(world, 7)
    assertTrue(not stands:isOpen(), "before the gates")
    assertEquals(stands:handleRequest(1, R.TALK, HOST_ID), A.CLOSED)
    openShow(world, 10)
    assertTrue(stands:isOpen())
    assertTrue(stands:isAtShow(HOST_ID), "the host's there")
    world.siteUp = false
    assertTrue(not stands:isOpen(), "no showground")
    world.siteUp = true
    g_currentMission.environment.currentMonotonicDay = event.day + 1
    assertTrue(not stands:isOpen(), "the day after")
end)

-- Farmers ----------------------------------------------------------------------------------------------

test("talking to a farmer lifts their opinion once a show, never letting word get round", function()
    local world = setup()
    openShow(world, 10)
    local stands = world.stands
    local other = stands:getFarmersAtShow()[2]
    assertEquals(stands:handleRequest(1, R.TALK, other), A.OK)
    assertEquals(stands:handleRequest(1, R.TALK, other), A.OK)
    local lifts = countOpinions(world, other)
    assertEquals(#lifts, 1, "once")
    assertEquals(lifts[1].delta, TCShowStands.TALK_OPINION)
    assertEquals(lifts[1].reason, TheContractorRelationships.WORD_REASON)
    assertTrue(stands:hasTalked(1, other))
    assertTrue(not stands:hasTalked(2, other), "another farm's not")
    stands:handleRequest(2, R.TALK, other)
    assertEquals(#countOpinions(world, other), 2, "each farm once")

    local absent = nil
    for id = 7, 15 do
        local found = false
        for _, at in ipairs(stands:getFarmersAtShow()) do
            found = found or at == id
        end
        if not found then
            absent = id
        end
    end
    assertEquals(stands:handleRequest(1, R.TALK, absent), A.CLOSED, "one who isn't there")
end)

test("any work going: one roll a farm per farmer per show, for that farmer's fields, as an offer from the show", function()
    local world = setup()
    openShow(world, 10)
    local stands = world.stands
    local farmerA = stands:getFarmersAtShow()[2]
    local farmerB = stands:getFarmersAtShow()[3]

    world.roll = 0
    local answer, jobId = stands:handleRequest(1, R.ASK, farmerA)
    assertEquals(answer, A.OFFER)
    assertEquals(jobId, 101)
    assertEquals(world.offers[1].customerId, farmerA, "their fields only")
    assertEquals(world.offers[1].offerSource, TheContractorShowStands.OFFER_SOURCE)
    assertEquals(#countOpinions(world, farmerA), 1, "asking is talking")
    assertEquals(stands:handleRequest(1, R.ASK, farmerA), A.ASKED, "once a show")
    assertEquals(#world.offers, 1)

    world.roll = 0.99
    assertEquals(stands:handleRequest(1, R.ASK, farmerB), A.NO_WORK, "a miss")
    assertEquals(#world.offers, 1, "nothing rolled for")
    world.roll = 0
    assertEquals(stands:handleRequest(2, R.ASK, farmerB), A.OFFER, "another farm asks for itself")

    world.noJobs = true
    assertEquals(stands:handleRequest(2, R.ASK, HOST_ID), A.NO_WORK, "nothing of theirs to offer")
    world.noJobs = false

    world.companies[3] = nil
    assertEquals(stands:handleRequest(3, R.ASK, HOST_ID), A.NO_COMPANY)
    world.refuses[farmerB] = true
    world.roll = 0
    assertEquals(stands:handleRequest(1, R.ASK, farmerB), A.REFUSED, "fallen out")
end)

test("the chance of an offer follows the relationship, and a farmer who's fallen out has none", function()
    setup()
    local C = TCShowStands.OFFER_CHANCE
    assertNear(TCShowStands.getOfferChance(0, false), C.base, 0.0001)
    assertTrue(TCShowStands.getOfferChance(60, false) > TCShowStands.getOfferChance(0, false))
    assertTrue(TCShowStands.getOfferChance(-60, false) < TCShowStands.getOfferChance(0, false))
    assertTrue(TCShowStands.getOfferChance(100, false) <= C.max)
    assertTrue(TCShowStands.getOfferChance(-100, false) >= C.min)
    assertEquals(TCShowStands.getOfferChance(80, true), 0)
end)

test("turning up lifts the host's opinion once, never letting word get round", function()
    local world = setup()
    local event = openShow(world, 10)
    world.tc.Show:onAttended(1, event)
    world.tc.Show:onAttended(1, event)
    local lifts = countOpinions(world, HOST_ID)
    assertEquals(#lifts, 1, "once a show")
    assertEquals(lifts[1].delta, TCShowStands.HOST_OPINION)
    assertEquals(lifts[1].reason, TheContractorRelationships.WORD_REASON)
    assertTrue(world.stands:getVisit(1).attended)

    -- The attend job done tells the show.
    local job = { state = TheContractorJob.STATE.ACCEPTED, auctionId = event.id, farmId = 2, jobType = "attendShow" }
    TCAuctionAttendance.getJob = function(farmId) return farmId == 2 and job or nil end
    world.tc.Jobs = { completeJob = function(_, completed) completed.state = "done" end }
    world.tc.Show.getEvent = function() return event end
    TCAuctionAttendance.markAttended(2, world.tc.Show)
    assertEquals(#countOpinions(world, HOST_ID), 2, "farm 2's")
    TCAuctionAttendance.markAttended(2, world.tc.Show)
    assertEquals(#countOpinions(world, HOST_ID), 2, "the job's done: not again")
end)

-- The association --------------------------------------------------------------------------------------

test("joining the association at its stall: the first term discounted, the renewal in full", function()
    local world = setup()
    openShow(world, 10)
    local stands = world.stands
    local overheads = world.tc.Overheads
    local definition = overheads:getDefinition(TheContractorAssociation.MEMBERSHIP_KEY)
    local full = overheads:getAnnualCost(1, definition)

    local answer, paid = stands:handleRequest(1, R.JOIN_ANNUAL)
    assertEquals(answer, A.JOINED)
    local state = overheads:getState(1, TheContractorAssociation.MEMBERSHIP_KEY)
    assertTrue(state.enabled, "a member")
    assertNear(state.termCost, full * (1 - TCShowStands.JOIN_DISCOUNT), 0.01, "the first term off")
    assertNear(paid, TheContractorOverheads.getChargeAmount(full * (1 - TCShowStands.JOIN_DISCOUNT),
        TheContractorOverheads.BILLING.ANNUAL), 1, "what it cost")
    assertTrue(stands:getVisit(1).joined)
    assertEquals(stands:handleRequest(1, R.JOIN_ANNUAL), A.MEMBER, "once")

    -- The renewal's quoted in full.
    overheads:postRenewalNotice(1, definition, state)
    assertNear(state.quotedCost, full, 0.01, "renewed at the full price")

    -- Monthly: a twelfth of the discounted year.
    assertEquals(stands:handleRequest(2, R.JOIN_MONTHLY), A.JOINED)
    local monthly = overheads:getState(2, TheContractorAssociation.MEMBERSHIP_KEY)
    assertEquals(monthly.billing, TheContractorOverheads.BILLING.MONTHLY)
    assertNear(monthly.termCost, full * (1 - TCShowStands.JOIN_DISCOUNT), 0.01)
end)

test("the association's stall: no company, can't afford, and closed", function()
    local world = setup()
    openShow(world, 10)
    local stands = world.stands
    world.companies[3] = nil
    assertEquals(stands:handleRequest(3, R.JOIN_ANNUAL), A.NO_COMPANY)
    world.balance = 1
    assertEquals(stands:handleRequest(1, R.JOIN_ANNUAL), A.CANT_AFFORD)
    assertTrue(not world.tc.Association:isMember(1))
    world.balance = 1000000
    openShow(world, 19)
    assertEquals(stands:handleRequest(1, R.JOIN_ANNUAL), A.CLOSED, "the gates have shut")
end)

-- The careers stand ---------------------------------------------------------------------------------

test("the careers stand: young candidates kept for the farm for a week, once a show", function()
    local world = setup()
    openShow(world, 10)
    local stands = world.stands
    local staff = world.tc.Staff
    -- A full pool doesn't stop them.
    for _ = 1, TheContractorStaff.POOL_MAX_SIZE do
        staff:addCandidateToPool()
    end
    assertEquals(staff:getOpenPoolCount(), TheContractorStaff.POOL_MAX_SIZE)

    local answer, added = stands:handleRequest(1, R.CAREERS)
    assertEquals(answer, A.SENT)
    assertEquals(added, TCShowStands.CAREERS.count)
    assertEquals(stands:handleRequest(1, R.CAREERS), A.VISITED, "once a show")

    local kept = {}
    for _, candidate in pairs(staff.candidatePool) do
        if candidate.keptForFarmId ~= nil then
            table.insert(kept, candidate)
        end
    end
    assertEquals(#kept, TCShowStands.CAREERS.count)
    local untilDay = SHOW_DAY + TCShowStands.getCareersDays(10)
    for _, candidate in ipairs(kept) do
        assertEquals(candidate.keptForFarmId, 1)
        assertEquals(candidate.keptUntilDay, untilDay, "a week")
        assertTrue(candidate.age <= TCShowStands.CAREERS.maxAge, "young")
    end
    assertEquals(staff:getOpenPoolCount(), TheContractorStaff.POOL_MAX_SIZE, "not counted against the pool")
    assertEquals(#staff:getCandidatePool(1), TheContractorStaff.POOL_MAX_SIZE + #kept, "the farm sees them")
    assertEquals(#staff:getCandidatePool(2), TheContractorStaff.POOL_MAX_SIZE, "another farm doesn't")
    assertEquals(staff:hireWorker(2, kept[1].id), nil, "nor can it hire them")

    -- Hired: nobody's candidate any more.
    world.tc.Finances.recordWages = function() end
    TheContractorHolidays = { grantInitialAllowance = function() end }
    TCWorkerHiredEvent = { new = function() return {} end }
    staff.registerWorker = function(self, worker)
        self.workersByFarm[worker.farmId] = self.workersByFarm[worker.farmId] or {}
        self.workersByFarm[worker.farmId][worker.id] = worker
    end
    world.tc.Overheads.ensureRequired = function() end
    local hired = staff:hireWorker(1, kept[1].id)
    assertTrue(hired ~= nil, "the farm hires one")
    assertEquals(hired.keptForFarmId, nil)

    world.companies[3] = nil
    assertEquals(stands:handleRequest(3, R.CAREERS), A.NO_COMPANY)

    -- The rest leave on their day, the open pool untouched by it.
    g_currentMission.environment.currentMonotonicDay = untilDay - 1
    math.randomseed(1)
    staff:updateCandidatePool(1000000)
    assertEquals(#staff:getCandidatePool(1) - staff:getOpenPoolCount(), #kept - 1, "still here the day before")
    g_currentMission.environment.currentMonotonicDay = untilDay
    staff:updateCandidatePool(1000000)
    for _, candidate in pairs(staff.candidatePool) do
        assertEquals(candidate.keptForFarmId, nil, "gone on their day")
    end
end)

test("a careers candidate is the younger of two rolls up to the stand's age", function()
    setup()
    local rolls = { 30, 22 }
    local i = 0
    local age = TCShowStands.rollCareersAge(18, function(a, b)
        assertEquals(a, 18)
        assertEquals(b, TCShowStands.CAREERS.maxAge)
        i = i + 1
        return math.min(b, rolls[i])
    end)
    assertEquals(age, 22)
    assertEquals(TCShowStands.getCareersDays(28), 7, "a week of a 28-day month")
    assertEquals(TCShowStands.getCareersDays(1), 1, "at least a day")
end)

test("a kept candidate's farm and day go over the wire and into the save", function()
    local world = setup()
    local staff = world.tc.Staff
    local candidate = staff:addCandidateToPool({ keptForFarmId = 2, keptUntilDay = 60, age = 19 })
    -- The other modules' parts of a worker: nothing of theirs here.
    local nothing = function() end
    for _, name in ipairs({ "TheContractorTraining", "TheContractorMorale", "TheContractorPayReviews",
        "TheContractorWorkshop", "TheContractorWorkingHours" }) do
        _G[name] = _G[name] or {}
        for _, fn in ipairs({ "writeState", "writeXML", "readXML", "applyState", "readRoleXML" }) do
            _G[name][fn] = nothing
        end
        _G[name].readState = function() return nil end
        _G[name].readSkillsXML = function() return {} end
    end
    TheContractorWorkshop.getSalaryPremium = function() return 0 end
    TheContractorHolidays = { applyHolidayChanged = nothing }
    assertEquals(candidate.age, 19)
    local stream = world:newStream()
    TheContractorStaff.writeWorker(stream, candidate)
    local read = TheContractorStaff.readWorker(stream)
    assertEquals(read.keptForFarmId, 2)
    assertEquals(read.keptUntilDay, 60)
    local open = staff:addCandidateToPool()
    local stream2 = world:newStream()
    TheContractorStaff.writeWorker(stream2, open)
    assertEquals(TheContractorStaff.readWorker(stream2).keptForFarmId, nil)

    local xml = {}
    TheContractorStaff.writeWorkerXML(xml, "w", candidate)
    local loaded = TheContractorStaff.readWorkerXML(xml, "w", nil)
    assertEquals(loaded.keptForFarmId, 2)
    assertEquals(loaded.keptUntilDay, 60)
end)

-- Sync, save, farms and farmers ------------------------------------------------------------------------

test("the visits go to every machine and into the save, a deleted farm's go and a retired farmer's pass on", function()
    local world = setup()
    local event = openShow(world, 10)
    local stands = world.stands
    local farmer = stands:getFarmersAtShow()[2]
    world.roll = 0.99
    stands:handleRequest(1, R.ASK, farmer)
    stands:handleRequest(2, R.JOIN_ANNUAL)
    world.tc.Show:onAttended(2, event)

    local last = world.events[#world.events]
    assertTrue(last.stands == stands, "sent whole")
    local stream = world:newStream()
    TheContractorShowStands.writeState(stream, stands)
    local client = TheContractorShowStands.new()
    client:applyState(TheContractorShowStands.readState(stream))
    assertEquals(client.showId, event.id)
    assertTrue(client.visits[1].talked[farmer] and client.visits[1].asked[farmer])
    assertTrue(client.visits[2].joined and client.visits[2].attended)

    local xml = {}
    stands:saveToXmlFile(xml)
    local loaded = TheContractorShowStands.new()
    loaded:loadFromXMLFile(xml)
    assertEquals(loaded.showId, event.id)
    assertTrue(loaded.visits[1].asked[farmer])
    assertTrue(loaded.visits[2].joined)

    assertEquals(world.tc.Show:replacePerson(farmer, 99) >= 2, true, "the talk and the ask")
    assertTrue(stands.visits[1].talked[99] and stands.visits[1].asked[99])
    assertEquals(stands.visits[1].talked[farmer], nil)

    stands:forgetFarm(1)
    assertEquals(stands.visits[1], nil)
    assertTrue(stands.visits[2] ~= nil, "the other farm's kept")
end)

test("a new show starts the visits again, and a request goes to the server and its answer back", function()
    local world = setup()
    openShow(world, 10)
    local stands = world.stands
    stands:handleRequest(1, R.CAREERS)
    assertTrue(stands:hasVisitedCareers(1))
    world.tc.Show:callCompetitions("onAnnounced", { id = 4 })
    assertEquals(stands.showId, 4)
    assertEquals(stands.visits[1], nil, "a new show")

    openShow(world, 10)
    local sent = {}
    local connection = {
        getIsServer = function() return false end,
        sendEvent = function(_, event) table.insert(sent, event) end,
    }
    g_currentMission.connectionsToPlayer = { [connection] = { farmId = 1 } }
    TCShowTalkEvent.newRequest(1, R.CAREERS, 0, 9):run(connection)
    assertEquals(#sent, 1)
    assertTrue(sent[1].isAnswer)
    assertEquals(sent[1].token, 9)
    assertEquals(sent[1].answer, A.SENT)
    TCShowTalkEvent.newRequest(2, R.CAREERS, 0, 10):run(connection)
    assertEquals(#sent, 1, "never for another farm")
end)

test("every line and option a conversation can say has its text", function()
    setup()
    for name, count in pairs(TCShowStands.LINES) do
        for n = 1, count do
            local key = string.format("tc_showTalk_%s_%d", name, n)
            assertTrue(g_i18n:hasText(key), key)
        end
    end
    for _, answer in pairs(TCShowStands.ANSWER) do
        for _, request in pairs(TCShowStands.REQUEST) do
            local line = TCShowStands.getAnswerLine(answer, request)
            assertTrue(line == nil or TCShowStands.LINES[line] ~= nil, "a line for every answer")
        end
    end
end)
