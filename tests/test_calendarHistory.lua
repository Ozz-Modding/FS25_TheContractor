-- Past days dated as they fell (TCCalendarHistory): the server anchors the
-- calendar whenever the days per month change, so a job finished or an
-- invoice settled before a change keeps its date. Plus the invoice timing
-- that goes with it: overdue the day after the due day, and written off by
-- months on the calendar.

local MAY, JUNE, AUGUST = 3, 4, 6

local function setCalendar(today, period, dayInPeriod, daysPerPeriod, plannedDaysPerPeriod)
    local environment = g_currentMission.environment
    environment.currentMonotonicDay = today
    environment.currentPeriod = period
    environment.currentDayInPeriod = dayInPeriod
    environment.daysPerPeriod = daysPerPeriod
    environment.plannedDaysPerPeriod = plannedDaysPerPeriod or daysPerPeriod
end

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    Environment = { PERIODS_IN_YEAR = 12 }
    g_currentMission.environment = { currentYear = 1, currentHour = 0 }
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    world.broadcasts = {}
    g_server = {
        broadcastEvent = function(_, event) table.insert(world.broadcasts, event) end,
    }
    world:load("src/util/TCCalendarHistory.lua")
    world:load("src/events/TCCalendarHistoryEvent.lua")
    TCCalendarHistory.anchors = {}
    return world
end

-- Day 100 is May 1 at 28 days a month; on day 150 (June 23) the save is
-- reloaded at 15 days a month and vanilla rescales today to June 13.
local function changeMidSeason()
    setCalendar(100, MAY, 1, 28)
    TCCalendarHistory.record()
    setCalendar(150, JUNE, 13, 15)
    TCCalendarHistory.record()
end

test("a day before a change of days per month keeps the date it fell on", function()
    setup()
    changeMidSeason()

    local periodIndex, dayInPeriod, daysPerPeriod = TCCalendar.getDayInfo(120)
    assertEquals(periodIndex, MAY)
    assertEquals(dayInPeriod, 21)
    assertEquals(daysPerPeriod, 28)
    periodIndex, dayInPeriod = TCCalendar.getDayInfo(149)
    assertEquals(periodIndex, JUNE)
    assertEquals(dayInPeriod, 22)
    -- From today on, the live calendar.
    periodIndex, dayInPeriod, daysPerPeriod = TCCalendar.getDayInfo(151)
    assertEquals(periodIndex, JUNE)
    assertEquals(dayInPeriod, 14)
    assertEquals(daysPerPeriod, 15)
end)

test("without a history a past day is worked back from today, as before", function()
    setup()
    setCalendar(150, JUNE, 13, 15)

    local periodIndex, dayInPeriod = TCCalendar.getDayInfo(120)
    -- 30 days back at 15 a month: two months back, same day.
    assertEquals(periodIndex, JUNE - 2)
    assertEquals(dayInPeriod, 13)
end)

test("a save's first anchor dates the days before it as they always were", function()
    setup()
    setCalendar(150, JUNE, 13, 15)
    TCCalendarHistory.record()
    setCalendar(160, JUNE, 23, 15)

    local periodIndex, dayInPeriod = TCCalendar.getDayInfo(120)
    assertEquals(periodIndex, JUNE - 2)
    assertEquals(dayInPeriod, 13)
end)

test("only a change of calendar is anchored, and broadcast", function()
    local world = setup()
    setCalendar(100, MAY, 1, 28)
    TCCalendarHistory.record()
    -- Days and months going by as the history predicts add nothing.
    setCalendar(101, MAY, 2, 28)
    TCCalendarHistory.record()
    setCalendar(128, JUNE, 1, 28)
    TCCalendarHistory.record()
    assertEquals(#TCCalendarHistory.anchors, 1)
    assertEquals(#world.broadcasts, 1)

    setCalendar(128, JUNE, 1, 15)
    TCCalendarHistory.record()
    -- The same day's second calendar replaces its first.
    assertEquals(#TCCalendarHistory.anchors, 2)
    setCalendar(128, JUNE, 1, 10)
    TCCalendarHistory.record()
    assertEquals(#TCCalendarHistory.anchors, 2)
    assertEquals(TCCalendarHistory.anchors[2].daysPerPeriod, 10)
    assertEquals(#world.broadcasts, 3)
end)

test("a new days per month taken up at a season's start is anchored", function()
    setup()
    -- Spring's last day at 28, then summer's first at 15 (vanilla takes the
    -- planned value up before it publishes the day change).
    setCalendar(100, MAY, 28, 28, 15)
    TCCalendarHistory.record()
    setCalendar(101, MAY + 1, 1, 15)
    TCCalendarHistory.record()

    assertEquals(#TCCalendarHistory.anchors, 2)
    setCalendar(200, AUGUST, 10, 15)
    local periodIndex, dayInPeriod = TCCalendar.getDayInfo(100)
    assertEquals(periodIndex, MAY)
    assertEquals(dayInPeriod, 28)
end)

test("a client's history matches the server's after the event and initial state", function()
    setup()
    changeMidSeason()

    local buffer = {}
    streamWriteInt32 = function(_, value) table.insert(buffer, value) end
    streamReadInt32 = function() return table.remove(buffer, 1) end
    TCCalendarHistory.writeInitialClientState(nil, nil)
    local serverAnchors = TCCalendarHistory.anchors
    TCCalendarHistory.anchors = {}
    TCCalendarHistory.readInitialClientState(nil, nil)

    assertEquals(#TCCalendarHistory.anchors, #serverAnchors)
    for i, anchor in ipairs(serverAnchors) do
        for _, field in ipairs(TCCalendarHistory.FIELDS) do
            assertEquals(TCCalendarHistory.anchors[i][field], anchor[field], field)
        end
    end

    -- A later anchor arrives as an event.
    local event = TCCalendarHistoryEvent.new({ day = 200, periodIndex = AUGUST, dayInPeriod = 1,
        daysPerPeriod = 7, plannedDaysPerPeriod = 7 })
    event:writeStream(nil, nil)
    local received = TCCalendarHistoryEvent.emptyNew()
    received:readStream(nil, nil)
    assertEquals(#TCCalendarHistory.anchors, 3)
    assertEquals(TCCalendarHistory.anchors[3].daysPerPeriod, 7)
end)

test("the history survives a save and load", function()
    setup()
    changeMidSeason()
    local xmlFile = {}
    TCCalendarHistory.saveToXmlFile(xmlFile)
    TCCalendarHistory.anchors = {}
    TCCalendarHistory.loadFromXMLFile(xmlFile)

    assertEquals(#TCCalendarHistory.anchors, 2)
    local periodIndex, dayInPeriod = TCCalendar.getDayInfo(120)
    assertEquals(periodIndex, MAY)
    assertEquals(dayInPeriod, 21)
end)

test("an old save with no history loads empty", function()
    setup()
    TCCalendarHistory.loadFromXMLFile({})
    assertEquals(#TCCalendarHistory.anchors, 0)
end)

test("months between two days count by their dates", function()
    setup()
    changeMidSeason()
    -- May 21 (of 28) to June 22 (of 28): 1 month and 1/28.
    assertNear(TCCalendar.getMonthsBetween(120, 149), 1 + 1 / 28, 1e-9)
    -- June 22 of 28 to June 14 of 15, after the change.
    assertNear(TCCalendar.getMonthsBetween(149, 151), 13 / 15 - 21 / 28, 1e-9)
end)

test("months on from a day gone are counted from the date it fell on", function()
    setup()
    changeMidSeason()
    -- May 21 + 2 months = July 21 of 28, which is July 11 of 15: day 150 is
    -- June 13, so July 11 is day 150 + 2 + 11 = 163.
    assertEquals(TCCalendar.addMonths(120, 2), 163)
end)

-- Invoices ------------------------------------------------------------------------

local function setupFinances()
    local world = setup()
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    TCInvoiceStatusChangedEvent = { new = function() return {} end }
    TCFinanceYearStatsEvent = { new = function() return {} end }
    world:load("src/business/Finances.lua")
    local tc = g_currentMission.TheContractor
    tc.Finances = TheContractorFinances.new()
    world.paid = {}
    g_currentMission.addMoney = function(_, amount, farmId) table.insert(world.paid, amount) end
    tc.Jobs = { getJob = function() return nil end }
    world.notices = {}
    tc.Notices = { publish = function(_, farmId) table.insert(world.notices, farmId) end }
    return world, tc.Finances
end

local function addInvoice(finances, dueDay, paymentDay)
    finances:applyInvoiceIssued({ id = 1, farmId = 1, jobId = 1, amount = 100, issuedDay = 1, dueDay = dueDay,
        paymentDay = paymentDay, status = TheContractorFinances.STATUS.OUTSTANDING })
    return finances.invoicesById[1]
end

test("an unpaid invoice goes overdue the day after its due day", function()
    local _, finances = setupFinances()
    local invoice = addInvoice(finances, 50, 70)

    setCalendar(50, MAY, 1, 28)
    finances:onDayChanged()
    assertEquals(invoice.status, TheContractorFinances.STATUS.OUTSTANDING)

    setCalendar(51, MAY, 2, 28)
    finances:onDayChanged()
    assertEquals(invoice.status, TheContractorFinances.STATUS.OVERDUE)
end)

test("an on-time payer pays on the due day", function()
    local world, finances = setupFinances()
    local invoice = addInvoice(finances, 50, 50)

    setCalendar(50, MAY, 1, 28)
    finances:onDayChanged()
    assertEquals(invoice.status, TheContractorFinances.STATUS.PAID)
    assertEquals(world.paid[1], 100)
end)

test("an overdue invoice is written off six calendar months after its due day", function()
    local world, finances = setupFinances()
    -- Due May 1 at 28 days a month; the save goes to 15 days a month from
    -- June 13 (day 150). Six months on is November 1, at 15: day 150 + 2 +
    -- 15 * 4 (July to October) = 212.
    setCalendar(100, MAY, 1, 28)
    TCCalendarHistory.record()
    local invoice = addInvoice(finances, 100, nil)
    invoice.status = TheContractorFinances.STATUS.OVERDUE
    setCalendar(150, JUNE, 13, 15)
    TCCalendarHistory.record()

    setCalendar(211, JUNE + 4, 15, 15)
    finances:onDayChanged()
    assertEquals(invoice.status, TheContractorFinances.STATUS.OVERDUE)

    setCalendar(212, JUNE + 5, 1, 15)
    finances:onDayChanged()
    assertEquals(invoice.status, TheContractorFinances.STATUS.WRITTEN_OFF)
    assertEquals(#world.notices, 1)
end)
