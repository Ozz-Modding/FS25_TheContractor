-- 089: holiday requests, on the real Holidays, Inbox, Staff, Worker and
-- calendar: the daily roll asking rather than booking, approve, decline
-- and expiry (allowance, morale, the refusal count), the warning on the
-- second refusal, booking whatever after it and when running out of year,
-- the year reset, who else is off, a days-per-period change withdrawing a
-- request, training booked after one, and the console. Morale's adjust and
-- the events are faked.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    world.texts.ui_on = "On"
    world.texts.ui_off = "Off"
    for month = 1, 12 do
        world.texts["ui_month" .. month] = "Month " .. month
    end

    Environment = {
        PERIODS_IN_YEAR = 12,
        setPlannedDaysPerPeriod = function(environment, value)
            environment.plannedDaysPerPeriod = value
        end,
    }
    Enterable = {}
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    FSBaseMission.INGAME_NOTIFICATION_INFO = "info"
    g_farmManager.getFarmByUserId = function()
        return { farmId = 1 }
    end
    -- April, day 1 of 5, so the next season starts on day 110 and the year
    -- ends on day 154.
    g_currentMission.environment = {
        currentYear = 2,
        currentPeriod = 2,
        currentDayInPeriod = 1,
        daysPerPeriod = 5,
        plannedDaysPerPeriod = 5,
        currentMonotonicDay = 100,
        currentHour = 0,
    }

    world:load("src/util/TCCalendar.lua")
    world:load("src/util/TCConsole.lua")
    world:load("src/util/TCNames.lua")
    world:load("src/util/TCWorkerAppearance.lua")
    world:load("src/business/Settings.lua")
    world:load("src/business/Worker.lua")
    world:load("src/business/Staff.lua")
    world:load("src/business/Morale.lua")
    world:load("src/business/Training.lua")
    world:load("src/business/Inbox.lua")
    world:load("src/business/Holidays.lua")

    g_server = { broadcastEvent = function() end }
    TCMessagePostedEvent = { new = function() return {} end }
    TCMessageRemovedEvent = { new = function() return {} end }
    world.holidayNotify = {}
    TCWorkerHolidayChangedEvent = {
        new = function() return {} end,
        showNotification = function(worker, notify)
            table.insert(world.holidayNotify, { workerId = worker.id, notify = notify })
        end,
    }
    TCWorkerStatusChangedEvent = {
        new = function() return {} end,
        showNotification = function() end,
    }

    local tc = g_currentMission.TheContractor
    tc.Settings = TheContractorSettings.new()
    tc.Staff = setmetatable({ workersByFarm = {}, candidatePool = {} }, TheContractorStaff_mt)
    tc.Inbox = TheContractorInbox.new()
    tc.Training = TheContractorTraining.new()
    tc.Training:register(tc.Inbox)
    tc.Holidays = TheContractorHolidays.new()
    tc.Holidays:register(tc.Inbox)

    world.notices = {}
    tc.Notices = {
        publish = function(_, farmId, text)
            table.insert(world.notices, { text = text })
            return #world.notices
        end,
        remove = function(_, noticeId)
            if noticeId ~= nil and world.notices[noticeId] ~= nil then
                world.notices[noticeId].removed = true
            end
        end,
        getNotice = function(_, noticeId)
            local notice = world.notices[noticeId]
            if notice == nil or notice.removed then
                return nil
            end
            return notice
        end,
    }

    world.morale = {}
    tc.Morale = setmetatable({
        adjust = function(_, farmId, workers, delta)
            for _, worker in ipairs(workers) do
                worker.morale = worker.morale + delta
                table.insert(world.morale, { workerId = worker.id, delta = delta })
            end
        end,
    }, TheContractorMorale_mt)

    -- Rolls: math.random() gives world.roll (0 = always books), ranges give
    -- their lowest value.
    world.roll = 0
    math.random = function(low, high)
        if low == nil then
            return world.roll
        end
        if high == nil then
            return 1
        end
        return low
    end

    function world:addWorker(id, name)
        local worker = TheContractorWorker.new(id, 1, name, 5, { small = 6 }, 2500, 30, 0, nil, nil, {})
        worker.morale = 60
        worker.holidayAllowance = 1
        worker.holidayYear = 2
        tc.Staff.workersByFarm[1] = tc.Staff.workersByFarm[1] or {}
        tc.Staff.workersByFarm[1][id] = worker
        return worker
    end

    function world:messages(kind)
        local result = {}
        for _, message in ipairs(tc.Inbox:getMessages(1)) do
            if kind == nil or message.payload.type == kind then
                table.insert(result, message)
            end
        end
        return result
    end

    -- The day changes as the game's would: inbox expiry, then the holidays.
    function world:passDay()
        local environment = g_currentMission.environment
        environment.currentMonotonicDay = environment.currentMonotonicDay + 1
        environment.currentDayInPeriod = environment.currentDayInPeriod + 1
        if environment.currentDayInPeriod > environment.daysPerPeriod then
            environment.currentDayInPeriod = 1
            environment.currentPeriod = environment.currentPeriod % 12 + 1
        end
        tc.Inbox:onDayChanged()
        tc.Holidays:onDayChanged()
    end

    return world, tc
end

local function getType(name)
    return TheContractorHolidays.MESSAGE_TYPE[name]
end

test("the daily roll asks, and nothing's booked or spent until it's answered", function()
    local world, tc = setup()
    local amy = world:addWorker(1, "Amy Hall")

    tc.Holidays:tryBookHoliday(amy)

    assertEquals(amy:hasHolidayBooked(), false, "not booked")
    assertEquals(amy.holidayAllowance, 1, "nothing spent")
    local requests = world:messages(getType("REQUEST"))
    assertEquals(#requests, 1, "one request")
    local request = requests[1]
    assertEquals(request.payload.workerId, 1)
    assertEquals(request.payload.startDay, 103, "three days' notice")
    assertEquals(request.payload.days, 3, "half to all of five days")
    assertEquals(request.payload.daysPerPeriod, 5)
    assertEquals(request.expiresDay, 103, "expires at the day change into its first day")
    assertEquals(#request.actions, 2, "approve and decline")
    assertEquals(TheContractorHolidays.findRequest(1, 1), request)

    assertEquals(table.concat(request.args, "|"), "Amy Hall|3|$days_103_105", "who, how many days and which")
    assertEquals(#TheContractorHolidays.getOthersOff(1, 1, 103, 105), 0, "nobody else off then")

    -- One at a time.
    tc.Holidays:tryBookHoliday(amy)
    assertEquals(#world:messages(getType("REQUEST")), 1, "no second request while one's open")
end)

test("approving books it, spends the allowance and pleases them", function()
    local world, tc = setup()
    local amy = world:addWorker(1, "Amy Hall")
    tc.Holidays:tryBookHoliday(amy)
    local request = world:messages(getType("REQUEST"))[1]

    tc.Inbox:requestAction(1, request.id, TheContractorHolidays.ACTION.APPROVE)

    assertEquals(amy.holidayStartDay, 103)
    assertEquals(amy.holidayDays, 3)
    assertNear(amy.holidayAllowance, 0.4, 0.0001, "3 of 5 days spent")
    assertEquals(amy.morale, 63, "+3")
    assertEquals(amy.holidayDeclines, 0)
    assertEquals(#world:messages(), 0, "the request's gone")
    assertEquals(TheContractorHolidays.findRequest(1, 1), nil)
    assertEquals(#world.notices, 1, "on the Overview once it's booked")

    -- And off they go on the day.
    for _ = 1, 3 do
        world:passDay()
    end
    assertEquals(amy.status, TheContractorWorker.STATUS.HOLIDAY)
end)

test("two declines upset them more each time, warn, and the next is booked whatever", function()
    local world, tc = setup()
    local amy = world:addWorker(1, "Amy Hall")

    tc.Holidays:tryBookHoliday(amy)
    tc.Inbox:requestAction(1, world:messages(getType("REQUEST"))[1].id, TheContractorHolidays.ACTION.DECLINE)
    assertEquals(amy.morale, 55, "-5")
    assertEquals(amy.holidayDeclines, 1)
    assertEquals(amy.holidayAllowance, 1, "nothing spent")
    assertEquals(#world:messages(getType("WARNING")), 0, "no warning yet")
    assertEquals(#world.notices, 0, "nothing on the Overview")

    tc.Holidays:tryBookHoliday(amy)
    tc.Inbox:requestAction(1, world:messages(getType("REQUEST"))[1].id, TheContractorHolidays.ACTION.DECLINE)
    assertEquals(amy.morale, 47, "-8")
    assertEquals(amy.holidayDeclines, 2)
    local warnings = world:messages(getType("WARNING"))
    assertEquals(#warnings, 1, "warned")
    assertEquals(warnings[1].actions[1].key, TheContractorInbox.DISMISS_ACTION.key, "just Dismiss")
    assertEquals(warnings[1].args[1], "Amy Hall")

    tc.Holidays:tryBookHoliday(amy)
    assertEquals(#world:messages(getType("REQUEST")), 0, "not asked")
    assertEquals(amy.holidayStartDay, 103, "booked whatever")
    assertNear(amy.holidayAllowance, 0.4, 0.0001, "spent")
    assertEquals(amy.morale, 47, "no bump either way")
    local booked = world:messages(getType("BOOKED"))
    assertEquals(#booked, 1, "the inbox says so")
    assertEquals(#booked[1].actions, 1, "just Dismiss")
    assertEquals(booked[1].bodyKey, "tc_holidayRequest_bookedBodyDeclined")
    assertEquals(booked[1].args[3], "$days_103_105", "the days booked")
end)

test("ignoring is a decline that hurts more", function()
    local world, tc = setup()
    local amy = world:addWorker(1, "Amy Hall")
    world.roll = 0.99

    tc.Holidays:tryBookHoliday(amy)
    assertEquals(#world:messages(), 0, "missed the daily chance")

    world.roll = 0
    tc.Holidays:tryBookHoliday(amy)
    world.roll = 0.99
    world:passDay()
    world:passDay()
    assertEquals(amy.morale, 60, "still open on its last day")
    assertEquals(#world:messages(getType("REQUEST")), 1)

    world:passDay()
    assertEquals(#world:messages(getType("REQUEST")), 0, "expired")
    assertEquals(amy.morale, 52, "-8")
    assertEquals(amy.holidayDeclines, 1)
    assertEquals(amy:hasHolidayBooked(), false)

    world.roll = 0
    tc.Holidays:tryBookHoliday(amy)
    world.roll = 0.99
    for _ = 1, 3 do
        world:passDay()
    end
    assertEquals(amy.morale, 40, "-12")
    assertEquals(amy.holidayDeclines, 2)
    assertEquals(#world:messages(getType("WARNING")), 1, "warned after an ignored one too")
end)

test("the morale deltas, past the table's end", function()
    setup()
    assertEquals(TheContractorMorale.getHolidayRefusedDelta(1, false), -5)
    assertEquals(TheContractorMorale.getHolidayRefusedDelta(2, false), -8)
    assertEquals(TheContractorMorale.getHolidayRefusedDelta(3, false), -8)
    assertEquals(TheContractorMorale.getHolidayRefusedDelta(1, true), -8)
    assertEquals(TheContractorMorale.getHolidayRefusedDelta(2, true), -12)
end)

test("running out of year books whatever, without asking", function()
    local world, tc = setup()
    local environment = g_currentMission.environment
    -- February 1: the year ends on day 104.
    environment.currentPeriod = 12
    environment.currentYear = 2
    local amy = world:addWorker(1, "Amy Hall")
    world.roll = 0.99

    tc.Holidays:tryBookHoliday(amy)

    assertEquals(#world:messages(getType("REQUEST")), 0, "not asked")
    assertEquals(amy.holidayStartDay, 103, "booked")
    assertEquals(amy.holidayDays, 2, "what's left of the year")
    local booked = world:messages(getType("BOOKED"))
    assertEquals(#booked, 1)
    assertEquals(booked[1].bodyKey, "tc_holidayRequest_bookedBodyYearEnd")
    assertEquals(amy.morale, 60, "no bump")
end)

test("the refusals reset with the allowance", function()
    local world, tc = setup()
    local amy = world:addWorker(1, "Amy Hall")
    amy.holidayYear = 1
    amy.holidayAllowance = 0
    amy.holidayDeclines = 2
    world.roll = 0.99

    world:passDay()

    assertEquals(amy.holidayYear, 2)
    assertEquals(amy.holidayAllowance, 1)
    assertEquals(amy.holidayDeclines, 0)
end)

test("who else is off: bookings, requests and training, live", function()
    local world, tc = setup()
    local amy = world:addWorker(1, "Amy Hall")
    local ben = world:addWorker(2, "Ben Ward")
    local cara = world:addWorker(3, "Cara Lee")
    local dan = world:addWorker(4, "Dan Moss")
    world:addWorker(5, "Eve Hart")

    tc.Holidays:bookHoliday(ben, 104, 2)
    local caraRequest = tc.Holidays:postRequest(cara, 107, 4)
    dan.trainingCert = "spraying"
    dan.courseDaysLeft = 2
    dan.trainingDay = 102
    dan.assessmentDay = 106
    local amyRequest = tc.Holidays:postRequest(amy, 103, 5)

    -- Each worker off as "reason firstDay-lastDay; ...", in name order.
    local function describe(entries)
        local lines = {}
        for _, entry in ipairs(entries) do
            local spells = {}
            for _, spell in ipairs(entry.spells) do
                table.insert(spells, string.format("%s %d-%d", spell.reason, spell.firstDay, spell.lastDay))
            end
            table.insert(lines, entry.worker.id .. ": " .. table.concat(spells, "; "))
        end
        return lines
    end

    local off = describe(TheContractorHolidays.getOthersOff(1, 1, 103, 107))
    assertEquals(#off, 3, "Eve's not off")
    assertEquals(off[1], "2: holiday 104-105", "Ben's booking")
    assertEquals(off[2], "3: requested 107-107", "Cara's request, inside Amy's days")
    assertEquals(off[3], "4: training 103-103; training 106-106", "Dan's course day and assessment")
    assertTrue(TheContractorInbox.getBody(tc.Inbox:getMessage(amyRequest)) ~= nil, "the request shows it")

    -- Cara's turned down: she drops out of Amy's list.
    tc.Inbox:requestAction(1, caraRequest, TheContractorHolidays.ACTION.DECLINE)
    assertEquals(#TheContractorHolidays.getOthersOff(1, 1, 103, 107), 2)

    -- Cara's own list would have had Amy as asked for.
    assertEquals(describe(TheContractorHolidays.getOthersOff(1, 3, 107, 110))[1], "1: requested 107-107")
    assertEquals(#TheContractorHolidays.getOthersOff(1, 1, 120, 125), 0, "nobody then")
end)

test("a days-per-period change withdraws a request it reaches, no morale", function()
    local world, tc = setup()
    local amy = world:addWorker(1, "Amy Hall")
    local ben = world:addWorker(2, "Ben Ward")
    tc.Holidays:postRequest(amy, 103, 3)
    tc.Holidays:postRequest(ben, 108, 3)

    Environment.setPlannedDaysPerPeriod(g_currentMission.environment, 10)

    assertTrue(TheContractorHolidays.findRequest(1, 1) ~= nil, "before the season change: kept")
    assertEquals(TheContractorHolidays.findRequest(1, 2), nil, "crosses into day 110: withdrawn")
    assertEquals(ben.holidayDeclines, 0, "not a refusal")
    assertEquals(ben.morale, 60)
    assertEquals(world.holidayNotify[#world.holidayNotify].notify, TheContractorHolidays.NOTIFY.REQUEST_WITHDRAWN)
end)

test("a worker gone takes their messages, and training goes after a request", function()
    local world, tc = setup()
    local amy = world:addWorker(1, "Amy Hall")
    tc.Holidays:postRequest(amy, 100, 4)

    assertEquals(TheContractorTraining.getFirstBookableDay(amy), 104, "after the days asked for")

    tc.Holidays:removeMessagesFor(1, 1)
    assertEquals(#world:messages(), 0)
    assertEquals(TheContractorTraining.getFirstBookableDay(amy), 101, "tomorrow")
end)

test("tcWorker holidayRequest asks now, most-refused first, then books whatever", function()
    local world, tc = setup()
    local amy = world:addWorker(1, "Amy Hall")
    local ben = world:addWorker(2, "Ben Ward")
    world.roll = 0.99
    TCConsole.reset()
    TheContractorHolidays.registerConsoleCommands()
    local group = TCConsole.groups.worker

    -- Ben's been refused once: he goes first, missed daily chance or not.
    ben.holidayDeclines = 1
    TCConsole.dispatch(group, { "holidayRequest" })
    local request = TheContractorHolidays.findRequest(1, 2)
    assertEquals(request.payload.startDay, 103, "the earliest start")
    assertEquals(request.payload.days, 3)

    -- He has one open, so Amy's next.
    TCConsole.dispatch(group, { "holidayRequest" })
    assertTrue(TheContractorHolidays.findRequest(1, 1) ~= nil, "Amy asked")

    -- Ben's second refusal: warned, and the next one's booked whatever.
    tc.Inbox:requestAction(1, request.id, TheContractorHolidays.ACTION.DECLINE)
    assertEquals(#world:messages(TheContractorHolidays.MESSAGE_TYPE.WARNING), 1)
    TCConsole.dispatch(group, { "holidayRequest" })
    assertEquals(ben.holidayStartDay, 103, "booked without asking")
    assertEquals(#world:messages(TheContractorHolidays.MESSAGE_TYPE.BOOKED), 1)

    local messageCount = #world:messages()
    TCConsole.dispatch(group, { "holidayRequest" })
    assertEquals(#world:messages(), messageCount, "nobody left who can ask")
end)
