-- 160, 161: booked days when the days per month change. Booked days are
-- monotonic; vanilla only takes up a new days-per-month setting at the next
-- season (or as a save loads, unless it's spring), so the same day number
-- can land on another date. TCCalendar dates days across a planned change,
-- and TCCalendarChange has each subsystem move its booked days to the same
-- date whenever the calendar changes: jobs, inbox expiry and invoices here;
-- random events and auctions in their own tests.

local TODAY = 100
local AUGUST, SEPTEMBER, OCTOBER = 6, 7, 8

-- The live calendar: today is day `dayInPeriod` of `period`, year 1.
local function setCalendar(today, period, dayInPeriod, daysPerPeriod, plannedDaysPerPeriod)
    local environment = g_currentMission.environment
    environment.currentMonotonicDay = today
    environment.currentPeriod = period
    environment.currentDayInPeriod = dayInPeriod
    environment.daysPerPeriod = daysPerPeriod
    environment.plannedDaysPerPeriod = plannedDaysPerPeriod
end

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    MessageType = { DAY_CHANGED = "dayChanged", PERIOD_LENGTH_CHANGED = "periodLengthChanged" }
    g_messageCenter = { subscribe = function() end, unsubscribeAll = function() end }
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }
    TCJobConsequences = {
        saveToXML = function() end,
        loadFromXML = function() end,
        writeReports = function() end,
        readReports = function() return {} end,
    }
    TCVehicleIds = { saveList = function() end, loadList = function() return {} end }
    TCFinanceYearStatsEvent = { new = function() return {} end }
    Environment = { PERIODS_IN_YEAR = 12 }
    Season = { SPRING = 0, SUMMER = 1, AUTUMN = 2, WINTER = 3 }
    g_currentMission.environment = { currentYear = 1, currentHour = 0 }
    -- A new save's August, before the player's change takes.
    setCalendar(TODAY, AUGUST, 1, 1, 1)

    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    world.broadcasts = {}
    g_server = {
        broadcastEvent = function(_, event) table.insert(world.broadcasts, event) end,
    }

    world:load("src/business/Job.lua")
    world:load("src/business/Jobs.lua")
    -- Jobs' save and load go through each job type's own.
    world:load("src/business/YardBales.lua")
    world:load("src/business/YardHaul.lua")
    world:load("src/business/EmergencyRefuel.lua")
    world:load("src/util/TCLotInspections.lua")
    world:load("src/business/CropSpill.lua")
    world:load("src/business/JobGeneration.lua")
    world:load("src/business/Inbox.lua")
    world:load("src/business/Finances.lua")
    world:load("src/util/TCCalendarChange.lua")
    world:load("src/events/TCJobDatesChangedEvent.lua")
    world:load("src/events/TCCalendarChangedEvent.lua")

    local tc = g_currentMission.TheContractor
    tc.Jobs = TheContractorJobs.new()
    tc.Inbox = TheContractorInbox.new()
    tc.Inbox:registerMessageKind("offer", { endsWithJob = true })
    tc.Finances = TheContractorFinances.new()
    TCCalendarChange.install()
    -- The calendar the jobs below are dated under.
    TCCalendarChange.check()
    return world, tc
end

-- A job in `state` (default accepted), due on deadlineDay, dated as the
-- calendar is now.
local function addJob(tc, id, deadlineDay, readyDay, state)
    local job = TheContractorJob.new(id, 1, "tedder", 7, 1, TCCalendar.getPeriodFromDay(deadlineDay),
        TCCalendar.getDayInPeriodFromDay(deadlineDay), 1000)
    job.state = state or TheContractorJob.STATE.ACCEPTED
    job.deadlineDay = deadlineDay
    job.readyDay = readyDay
    tc.Jobs:registerJob(job, false)
    return job
end

-- The calendar ------------------------------------------------------------------

test("a day after a planned change is dated at the planned month length", function()
    setup()
    setCalendar(TODAY, AUGUST, 1, 1, 2)

    -- August is the last of summer: September and October run at 2 days.
    assertEquals(TCCalendar.getPeriodFromDay(TODAY + 1), SEPTEMBER)
    assertEquals(TCCalendar.getPeriodFromDay(TODAY + 2), SEPTEMBER)
    assertEquals(TCCalendar.getDayInPeriodFromDay(TODAY + 2), 2)
    assertEquals(TCCalendar.getPeriodFromDay(TODAY + 3), OCTOBER)
    assertEquals(TCCalendar.getNextOccurrenceDay(OCTOBER, 1), TODAY + 3)
    assertEquals(TCCalendar.getSeasonAtDay(TODAY), Season.SUMMER)
    assertEquals(TCCalendar.getSeasonAtDay(TODAY + 1), Season.AUTUMN)

    for day = TODAY, TODAY + 40 do
        local periodIndex, dayInPeriod = TCCalendar.getDayInfo(day)
        assertEquals(TCCalendar.getMonotonicDay(periodIndex, dayInPeriod), day, "day " .. day)
    end
end)

test("the next occurrence of a month already gone this year is next year's", function()
    setup()
    assertEquals(TCCalendar.getNextOccurrenceDay(AUGUST, 1), TODAY)
    assertEquals(TCCalendar.getNextOccurrenceDay(SEPTEMBER, 1), TODAY + 1)
    assertEquals(TCCalendar.getNextOccurrenceDay(AUGUST - 1, 1), TODAY + 11)
end)

test("months on land on the same share of the month, at each month's length", function()
    setup()
    setCalendar(TODAY, AUGUST, 1, 1, 4)
    -- September 1 of 4, October 1 of 4.
    assertEquals(TCCalendar.addMonths(TODAY, 1), TODAY + 1)
    assertEquals(TCCalendar.addMonths(TODAY, 2), TODAY + 5)
    -- Half of October's 4 days on from its start.
    assertEquals(TCCalendar.addMonths(TODAY, 2.5), TODAY + 7)
    -- From September 4 of 4, a month on is October 4.
    assertEquals(TCCalendar.addMonths(TODAY + 4, 1), TODAY + 8)
    assertEquals(TCCalendar.addMonths(TODAY, 0), TODAY)
end)

test("a remapped deadline keeps its date, at the end of its share of the month", function()
    setup()
    local before = TCCalendar.getModel()
    setCalendar(TODAY, AUGUST, 1, 1, 2)
    local after = TCCalendar.getModel()

    -- October 1 of 1 is the whole of October: October 2 of 2 as a deadline,
    -- October 1 as a ready day.
    assertEquals(TCCalendar.remapDay(TODAY + 2, before, after, true), TODAY + 4)
    assertEquals(TCCalendar.remapDay(TODAY + 2, before, after, false), TODAY + 3)
    -- This season's days don't move, and nor does anything gone by.
    assertEquals(TCCalendar.remapDay(TODAY, before, after, true), TODAY)
    assertEquals(TCCalendar.remapDay(TODAY - 5, before, after, true), TODAY - 5)

    -- Shorter months: October 2 of 3 is in the only day October has.
    setCalendar(TODAY, AUGUST, 1, 1, 3)
    local three = TCCalendar.getModel()
    setCalendar(TODAY, AUGUST, 1, 1, 1)
    assertEquals(TCCalendar.remapDay(TODAY + 1 + 3 + 1, three, TCCalendar.getModel(), true), TODAY + 2)
end)

-- Jobs -------------------------------------------------------------------------------

test("the reported case: changing the setting in August keeps an October job due in October", function()
    local world, tc = setup()
    -- Taken in August at 1 day a month, due October 1.
    local job = addJob(tc, 1, TODAY + 2, nil)
    assertEquals(job.targetPeriod, OCTOBER)

    -- The player picks 2 days a month.
    setCalendar(TODAY, AUGUST, 1, 1, 2)
    TCCalendarChange.check()
    assertEquals(job.deadlineDay, TODAY + 4)
    assertEquals(job.targetPeriod, OCTOBER)
    assertEquals(job.targetDayInPeriod, 2)
    assertEquals(job.readyDay, nil)
    assertEquals(#world.broadcasts, 1)

    -- September 1 and 2 go by: still on, and the season starting on the
    -- planned value moves nothing more.
    for day = TODAY + 1, TODAY + 2 do
        setCalendar(day, SEPTEMBER, day - TODAY, 2, 2)
        TCCalendarChange.check()
        tc.Jobs:onDayChanged()
    end
    assertEquals(job.state, TheContractorJob.STATE.ACCEPTED)
    assertEquals(job.deadlineDay, TODAY + 4)
    assertEquals(#world.broadcasts, 1)
end)

test("a ready day moves to the start of its date and never past the deadline", function()
    local _, tc = setup()
    local job = addJob(tc, 1, TODAY + 3, TODAY + 2)

    setCalendar(TODAY, AUGUST, 1, 1, 3)
    TCCalendarChange.check()
    -- Ready October, due November: September is days 1-3, October 4-6,
    -- November 7-9.
    assertEquals(job.readyDay, TODAY + 4)
    assertEquals(job.deadlineDay, TODAY + 9)
    assertTrue(job.readyDay <= job.deadlineDay)
end)

test("finished jobs and attend-the-auction jobs keep their days; a workshop offer's expiry moves", function()
    local _, tc = setup()
    local done = addJob(tc, 1, TODAY + 2, nil, TheContractorJob.STATE.COMPLETED)
    local attend = addJob(tc, 2, TODAY + 2, nil)
    attend.auctionId = 4
    local workshop = addJob(tc, 3, TODAY + 3, nil, TheContractorJob.STATE.OFFERED)
    workshop.workshop = { offerExpiresDay = TODAY + 2 }

    setCalendar(TODAY, AUGUST, 1, 1, 2)
    TCCalendarChange.check()
    assertEquals(done.deadlineDay, TODAY + 2)
    assertEquals(attend.deadlineDay, TODAY + 2)
    assertEquals(workshop.workshop.offerExpiresDay, TODAY + 4)
end)

-- Inbox and invoices ----------------------------------------------------------------

test("every message's expiry keeps its date, an offer's with its job", function()
    local _, tc = setup()
    addJob(tc, 1, TODAY + 2, nil, TheContractorJob.STATE.OFFERED)
    local messages = tc.Inbox.messagesById
    messages[1] = { id = 1, farmId = 1, kind = "offer", payload = { jobId = 1 }, expiresDay = TODAY + 3 }
    messages[2] = { id = 2, farmId = 1, kind = "other", payload = {}, expiresDay = TODAY + 2 }
    -- Its last day's today: nothing to move.
    messages[3] = { id = 3, farmId = 1, kind = "other", payload = {}, expiresDay = TODAY + 1 }
    messages[4] = { id = 4, farmId = 1, kind = "other", payload = {} }

    setCalendar(TODAY, AUGUST, 1, 1, 2)
    TCCalendarChange.check()
    assertEquals(messages[1].expiresDay, tc.Jobs:getJob(1, 1).deadlineDay + 1)
    assertEquals(messages[1].expiresDay, TODAY + 5)
    -- Its last day was September 1 of 1: now September 2 of 2.
    assertEquals(messages[2].expiresDay, TODAY + 3)
    assertEquals(messages[3].expiresDay, TODAY + 1)
    assertEquals(messages[4].expiresDay, nil)
end)

test("an unpaid invoice's due day keeps its date, with the job's copy; a settled one's left alone", function()
    local _, tc = setup()
    local job = addJob(tc, 1, TODAY, nil, TheContractorJob.STATE.COMPLETED)
    job.invoiceDueDay = TODAY + 2
    local invoices = tc.Finances.invoicesById
    invoices[1] = { id = 1, farmId = 1, jobId = 1, dueDay = TODAY + 2, paymentDay = TODAY + 3,
        pursuitResolveDay = TODAY + 3 }
    invoices[2] = { id = 2, farmId = 1, jobId = 2, dueDay = TODAY + 2, settledDay = TODAY - 1 }

    setCalendar(TODAY, AUGUST, 1, 1, 2)
    TCCalendarChange.check()
    -- October 1 of 1 to October 2 of 2; November to November 2.
    assertEquals(invoices[1].dueDay, TODAY + 4)
    assertEquals(job.invoiceDueDay, TODAY + 4)
    assertEquals(invoices[1].paymentDay, TODAY + 6)
    assertEquals(invoices[1].pursuitResolveDay, TODAY + 6)
    assertEquals(invoices[2].dueDay, TODAY + 2)
end)

-- Clients ---------------------------------------------------------------------------------

test("a client moves its copies by the calendars the server sends, whatever its own says", function()
    local world, tc = setup()
    addJob(tc, 1, TODAY + 2, TODAY + 1)
    setCalendar(TODAY, AUGUST, 1, 1, 2)
    TCCalendarChange.check()
    local stream = world:newStream()
    world.broadcasts[1]:writeStream(stream)

    -- The client: still on 1 day a month, its job as the server had it.
    setCalendar(TODAY, AUGUST, 1, 1, 1)
    tc.Jobs = TheContractorJobs.new()
    local copy = TheContractorJob.new(1, 1, "tedder", 7, 1, OCTOBER, 1, 1000)
    copy.state = TheContractorJob.STATE.ACCEPTED
    copy.deadlineDay = TODAY + 2
    copy.readyDay = TODAY + 1
    tc.Jobs:registerJob(copy, false)

    TCCalendarChangedEvent.emptyNew():readStream(stream)
    assertEquals(copy.deadlineDay, TODAY + 4)
    assertEquals(copy.readyDay, TODAY + 1)
    assertEquals(copy.targetPeriod, OCTOBER)
    assertEquals(copy.targetDayInPeriod, 2)
end)

-- Loading ------------------------------------------------------------------------------

-- Saves the jobs and the calendar, as a save does.
local function save(tc)
    local xmlFile = {}
    tc.Jobs:saveToXmlFile(xmlFile)
    TCCalendarChange.saveToXmlFile(xmlFile)
    return xmlFile
end

-- Loads them into a fresh Jobs as a load does; the first update then
-- checks the calendar.
local function load(tc, xmlFile)
    TCCalendarChange.install()
    tc.Jobs = TheContractorJobs.new()
    tc.Jobs:loadFromXMLFile(xmlFile)
    TCCalendarChange.loadFromXMLFile(xmlFile)
    TCCalendarChange.update()
end

test("a save loaded mid-summer on a new month length moves the rest of the season's dates", function()
    local _, tc = setup()
    -- July, 1 day a month, 2 planned; due August (this season).
    setCalendar(TODAY, AUGUST - 1, 1, 1, 2)
    TCCalendarChange.check()
    addJob(tc, 1, TODAY + 1, nil)
    local xmlFile = save(tc)

    -- Vanilla takes the planned value up as the save loads: July 1 of 2.
    setCalendar(TODAY, AUGUST - 1, 1, 2, 2)
    load(tc, xmlFile)
    local job = tc.Jobs:getJob(1, 1)
    assertEquals(job.deadlineDay, TODAY + 3)
    assertEquals(job.targetPeriod, AUGUST)
    assertEquals(job.targetDayInPeriod, 2)
end)

test("a save loaded on the same calendar moves nothing", function()
    local world, tc = setup()
    setCalendar(TODAY, AUGUST, 1, 1, 2)
    TCCalendarChange.check()
    addJob(tc, 1, TODAY + 3, nil)
    local xmlFile = save(tc)
    world.broadcasts = {}

    load(tc, xmlFile)
    assertEquals(tc.Jobs:getJob(1, 1).deadlineDay, TODAY + 3)
    assertEquals(#world.broadcasts, 0)
end)

test("an older save's job is put back in the month it was taken on for", function()
    local world, tc = setup()
    -- Already September 2 of 2: the report's save, its October 1 job now
    -- due today.
    setCalendar(TODAY + 2, SEPTEMBER, 2, 2, 2)
    local wrong = TheContractorJob.new(1, 1, "tedder", 7, 1, OCTOBER, 1, 1000)
    wrong.state = TheContractorJob.STATE.ACCEPTED
    wrong.deadlineDay = TODAY + 2
    tc.Jobs:registerJob(wrong, false)
    -- One that's right already.
    local right = addJob(tc, 2, TODAY + 3, nil)

    -- A save from before 160: no calendar.
    TCCalendarChange.install()
    world.broadcasts = {}
    TCCalendarChange.update()
    assertEquals(wrong.deadlineDay, TODAY + 4, "the end of October")
    assertEquals(wrong.targetPeriod, OCTOBER)
    assertEquals(right.deadlineDay, TODAY + 3)
    assertEquals(#world.broadcasts, 1, "the repair, to the clients")
    assertTrue(TCCalendarChange.model ~= nil)
end)

test("an older save's job whose month has gone by is left alone", function()
    local _, tc = setup()
    setCalendar(TODAY, OCTOBER, 1, 1, 1)
    local gone = TheContractorJob.new(1, 1, "tedder", 7, 1, AUGUST, 1, 1000)
    gone.state = TheContractorJob.STATE.ACCEPTED
    gone.deadlineDay = TODAY + 1
    tc.Jobs:registerJob(gone, false)

    TCCalendarChange.install()
    TCCalendarChange.update()
    assertEquals(gone.deadlineDay, TODAY + 1)
end)
