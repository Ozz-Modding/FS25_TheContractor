-- Working hours (097): at work 08:00-18:00 and at home otherwise, Stay
-- late / Call back / Send home, who allocation and the driver picker take,
-- overtime (for work running on, and for a duty whether it's used or not),
-- paying it with the salaries or when someone leaves, the save, the stream,
-- what ADS and the office show, and the console.

local DAY = 24 * 60

local function setup(daysPerPeriod)
    local world = stubs.install()
    world.texts.ui_on = "On"
    world.texts.ui_off = "Off"
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    Environment = { PERIODS_IN_YEAR = 12 }
    MoneyType = { TC_WAGES = "wages" }
    TheContractor = { SaveKey = "TheContractor" }
    Enterable = {}
    TheContractorJobGeneration = { JOB_PAY_BASELINE = 0.8 }
    TheContractorJob = { STATE = { ALLOCATED = "allocated", IN_PROGRESS = "in_progress" } }
    TheContractorDrivers = {
        getModEnv = function()
            return nil
        end,
    }

    world:load("src/util/TCEconomyScale.lua")
    world:load("src/util/TCWorkerAppearance.lua")
    world:load("src/util/TCNames.lua")
    world:load("src/util/TCConsole.lua")
    world:load("src/business/Settings.lua")
    world:load("src/business/Worker.lua")
    world:load("src/business/Staff.lua")
    world:load("src/business/Office.lua")
    world:load("src/business/Workshop.lua")
    world:load("src/util/TCADSWorkshop.lua")
    world:load("src/business/WorkingHours.lua")
    -- The worker's stream and save run through these.
    world:load("src/util/TCCalendar.lua")
    world:load("src/business/Training.lua")
    world:load("src/business/Morale.lua")
    world:load("src/business/PayReviews.lua")
    world:load("src/business/Holidays.lua")

    g_currentMission.environment = { currentMonotonicDay = 1, dayTime = 12 * 3600000,
        daysPerPeriod = daysPerPeriod or 28 }
    world.broadcasts = {}
    g_server = {
        broadcastEvent = function(_, event)
            table.insert(world.broadcasts, event)
        end,
    }
    TCWorkerDutyEvent = {
        new = function(farmId, workerId, action, dutyFrom, dutyArrive, dutyUntil)
            return { kind = "duty", farmId = farmId, workerId = workerId, action = action, dutyFrom = dutyFrom,
                dutyArrive = dutyArrive, dutyUntil = dutyUntil }
        end,
    }
    TCWorkerOvertimeEvent = {
        new = function(farmId, entries)
            return { kind = "overtime", farmId = farmId, entries = entries }
        end,
    }

    world.balance = 100000
    world.money = {}
    world.wages = 0
    g_farmManager.getFarmById = function()
        return { getBalance = function() return world.balance end }
    end
    g_farmManager.getFarmByUserId = function()
        return { farmId = 1 }
    end
    g_currentMission.addMoney = function(_, amount, farmId, moneyType)
        world.balance = world.balance + amount
        table.insert(world.money, { amount = amount, farmId = farmId, moneyType = moneyType })
    end

    local tc = g_currentMission.TheContractor
    tc.Settings = TheContractorSettings.new()
    tc.Staff = setmetatable({ workersByFarm = {}, candidatePool = {}, nextWorkerId = 1 }, TheContractorStaff_mt)
    tc.Office = TheContractorOffice.new()
    tc.WorkingHours = TheContractorWorkingHours.new()
    tc.Finances = {
        recordWages = function(_, farmId, amount)
            world.wages = world.wages + amount
        end,
    }
    world.jobs = {}
    world.activeJobs = {}
    tc.Jobs = {
        getAllJobs = function()
            return world.jobs
        end,
    }
    tc.Dispatch = {
        isJobActive = function(_, job)
            return world.activeJobs[job.id] == true
        end,
    }
    world.menuRefreshes = 0
    tc.MenuContractor = {
        onOfficeChanged = function()
            world.menuRefreshes = world.menuRefreshes + 1
        end,
    }

    -- The clock: day and hh:mm.
    function world:at(day, hour, minute)
        g_currentMission.environment.currentMonotonicDay = day
        g_currentMission.environment.dayTime = (hour * 60 + (minute or 0)) * 60000
        return TheContractorWorkingHours.getNow()
    end

    -- Moves the clock on, counting overtime as the game would.
    function world:runTo(day, hour, minute)
        self:at(day, hour, minute)
        tc.WorkingHours:update(16)
    end

    return world, tc
end

local function addWorker(tc, id, status)
    local worker = TheContractorWorker.new(id, 1, "Worker " .. id, 5, { small = 5 }, 2000, 30, 0, 1, 0, {}, 5)
    worker.status = status or TheContractorWorker.STATUS.IDLE
    tc.Staff.workersByFarm[1] = tc.Staff.workersByFarm[1] or {}
    tc.Staff.workersByFarm[1][id] = worker
    return worker
end



test("working hours are 08:00 to 18:00", function()
    local world = setup()
    assertTrue(not TheContractorWorkingHours.isWorkingTime(world:at(1, 7, 59)), "07:59")
    assertTrue(TheContractorWorkingHours.isWorkingTime(world:at(1, 8, 0)), "08:00")
    assertTrue(TheContractorWorkingHours.isWorkingTime(world:at(1, 17, 59)), "17:59")
    assertTrue(not TheContractorWorkingHours.isWorkingTime(world:at(1, 18, 0)), "18:00")
    assertEquals(TheContractorWorkingHours.formatTime(world:at(3, 7, 5)), "07:05", "formatted")
end)

test("out-of-hours minutes across days", function()
    setup()
    local H = TheContractorWorkingHours
    assertEquals(H.getOutOfHoursMinutes(DAY + 9 * 60, DAY + 17 * 60), 0, "all in hours")
    assertEquals(H.getOutOfHoursMinutes(DAY + 17 * 60, DAY + 19 * 60), 60, "17:00-19:00")
    assertEquals(H.getOutOfHoursMinutes(DAY + 17 * 60, 2 * DAY + 9 * 60), 14 * 60, "17:00 to 09:00 next day")
    assertEquals(H.getOutOfHoursMinutes(DAY, 3 * DAY), 2 * 14 * 60, "two whole days")
    assertEquals(H.getOutOfHoursMinutes(DAY + 60, DAY + 60), 0, "nothing")
end)

test("an idle worker goes home at 18:00 and isn't offered for jobs or driving", function()
    local world, tc = setup()
    local worker = addWorker(tc, 1)
    local busy = addWorker(tc, 2, TheContractorWorker.STATUS.ASSIGNED)

    world:at(1, 17, 59)
    assertTrue(TheContractorWorkingHours.isAvailable(worker), "at work")
    assertEquals(#tc.Staff:getAvailableWorkers(1), 1, "offered")
    assertEquals(TheContractorWorkingHours.getDisplayStatus(worker), "idle", "idle")

    world:at(1, 18, 0)
    assertTrue(not TheContractorWorkingHours.isAvailable(worker), "gone home")
    assertEquals(#tc.Staff:getAvailableWorkers(1), 0, "not offered")
    assertEquals(#tc.Staff:getIdleWorkers(1), 1, "still idle")
    assertEquals(TheContractorWorkingHours.getDisplayStatus(worker), "atHome", "shown at home")
    assertEquals(TheContractorWorkingHours.getDisplayStatus(busy), "assigned", "a busy worker shows their status")

    world:at(2, 8, 0)
    assertTrue(TheContractorWorkingHours.isAvailable(worker), "back in the morning")
end)

test("stay late: offered times, on duty until then, then home", function()
    local world, tc = setup()
    local worker = addWorker(tc, 1)
    local now = world:at(1, 15, 0)

    assertEquals(TheContractorWorkingHours.getDutyAction(worker, now), "stay", "stay late during the day")
    local options = TheContractorWorkingHours.getUntilOptions(worker, now)
    assertEquals(#options, 3, "three times")
    assertEquals(options[1], DAY + 20 * 60, "20:00 first")
    assertEquals(options[2], DAY + 22 * 60, "then 22:00")
    assertEquals(options[3], 2 * DAY, "midnight")

    assertEquals(tc.WorkingHours:requestDuty(1, 1, "stay", options[2]), nil, "accepted")
    assertEquals(worker.dutyUntil, DAY + 22 * 60, "until 22:00")
    assertEquals(worker.dutyArrive, now, "there already")
    assertEquals(world.broadcasts[#world.broadcasts].kind, "duty", "broadcast")
    assertEquals(world.broadcasts[#world.broadcasts].dutyUntil, DAY + 22 * 60, "broadcast time")
    assertTrue(world.menuRefreshes > 0, "menu redrawn")

    world:at(1, 21, 59)
    assertTrue(TheContractorWorkingHours.isAvailable(worker), "on duty at 21:59")
    assertEquals(TheContractorWorkingHours.getDisplayStatus(worker), "stayingLate", "staying late")
    world:at(1, 22, 0)
    assertTrue(not TheContractorWorkingHours.isAvailable(worker), "home at 22:00")
end)

test("call back: in 25 minutes after the call, until the time picked", function()
    local world, tc = setup()
    local worker = addWorker(tc, 1)
    local now = world:at(1, 19, 0)

    assertEquals(TheContractorWorkingHours.getDutyAction(worker, now), "call", "call back once home")
    local options = TheContractorWorkingHours.getUntilOptions(worker, now)
    assertEquals(options[1], DAY + 22 * 60, "22:00: an hour after they're in, at least")
    assertEquals(tc.WorkingHours:requestDuty(1, 1, "stay", options[1]), "atHome", "can't stay, they've gone")
    assertEquals(tc.WorkingHours:requestDuty(1, 1, "call", options[1]), nil, "called")
    assertEquals(worker.dutyArrive, now + 25, "in at 19:25")

    world:at(1, 19, 24)
    assertEquals(TheContractorWorkingHours.getDisplayStatus(worker), "comingIn", "on the way")
    assertTrue(not TheContractorWorkingHours.isAvailable(worker), "not yet")
    world:at(1, 19, 25)
    assertTrue(TheContractorWorkingHours.isAvailable(worker), "in")
end)

test("nothing's offered just before morning, and times never pass 08:00", function()
    local world, tc = setup()
    local worker = addWorker(tc, 1)
    assertEquals(#TheContractorWorkingHours.getUntilOptions(worker, world:at(2, 7, 30)), 0, "07:30: nearly in")
    local options = TheContractorWorkingHours.getUntilOptions(worker, world:at(2, 3, 0))
    assertEquals(#options, 2, "06:00 and 08:00")
    assertEquals(options[2], 2 * DAY + 8 * 60, "08:00")
    assertEquals(tc.WorkingHours:requestDuty(1, 1, "call", 2 * DAY + 9 * 60), "badTime", "past the morning")
end)

test("nobody away is kept on, and send home ends a duty", function()
    local world, tc = setup()
    local sick = addWorker(tc, 1, TheContractorWorker.STATUS.SICK)
    local worker = addWorker(tc, 2)
    local now = world:at(1, 15, 0)
    assertEquals(TheContractorWorkingHours.getDutyAction(sick, now), nil, "off sick")
    assertEquals(tc.WorkingHours:requestDuty(1, 1, "stay", DAY + 20 * 60), "away", "refused")
    assertEquals(tc.WorkingHours:requestDuty(1, 2, "home"), "noDuty", "nothing to end")

    assertEquals(tc.WorkingHours:requestDuty(1, 2, "stay", DAY + 22 * 60), nil, "kept on")
    world:at(1, 19, 0)
    assertEquals(tc.WorkingHours:requestDuty(1, 2, "home"), nil, "sent home")
    assertEquals(worker.dutyUntil, nil, "duty gone")
    assertTrue(not TheContractorWorkingHours.isAvailable(worker), "home")
end)

test("overtime for work running past 18:00, at 1.5x this month's hourly pay", function()
    local world, tc = setup()
    local worker = addWorker(tc, 1, TheContractorWorker.STATUS.ASSIGNED)
    table.insert(world.jobs, { id = 7, assignedWorkerId = 1, state = "in_progress" })
    world.activeJobs[7] = true
    -- 2000 a month, 28 days of 10 hours: 7.14 an hour, 10.71 overtime.
    assertNear(TheContractorWorkingHours.getHourlyRate(worker), 2000 / 280 * 1.5, 1e-6, "rate")

    world:runTo(1, 17, 0)
    world:runTo(1, 20, 0)
    assertEquals(worker.overtimeMinutes, 120, "18:00 to 20:00")
    assertNear(worker.overtimeOwed, 2 * 2000 / 280 * 1.5, 1e-6, "two hours' overtime")

    -- On hold for supplies at the yard: not out working, not paid.
    world.activeJobs[7] = nil
    world:runTo(1, 21, 0)
    assertEquals(worker.overtimeMinutes, 120, "a held job's crew isn't paid")

    -- Cooldown counts.
    worker.status = TheContractorWorker.STATUS.COOLDOWN
    world:runTo(1, 21, 30)
    assertEquals(worker.overtimeMinutes, 150, "cooldown")

    -- Home: nothing.
    worker.status = TheContractorWorker.STATUS.IDLE
    world:runTo(1, 23, 0)
    assertEquals(worker.overtimeMinutes, 150, "at home")
end)

test("a duty is paid out of hours whether it's used or not", function()
    local world, tc = setup()
    local worker = addWorker(tc, 1)
    world:runTo(1, 15, 0)
    tc.WorkingHours:requestDuty(1, 1, "stay", DAY + 20 * 60)
    world:runTo(1, 17, 0)
    assertEquals(worker.overtimeMinutes or 0, 0, "in hours: no overtime")
    world:runTo(1, 23, 0)
    assertEquals(worker.overtimeMinutes, 120, "18:00 to 20:00 only")

    -- A call back is paid from the call.
    local caller = addWorker(tc, 2)
    world:runTo(2, 1, 0)
    tc.WorkingHours:requestDuty(1, 2, "call", 2 * DAY + 4 * 60)
    world:runTo(2, 9, 0)
    assertEquals(caller.overtimeMinutes, 180, "01:00 to 04:00")
end)

test("short months: the same share of pay an hour", function()
    local _, tc = setup(1)
    local worker = addWorker(tc, 1)
    -- 1 day a period pays 60%: 1200 for 10 hours.
    assertNear(TheContractorWorkingHours.getHourlyRate(worker), 1200 / 10 * 1.5, 1e-6, "rate")
end)

test("overtime is paid with the salaries and cleared, and clients hear on the hour", function()
    local world, tc = setup()
    local worker = addWorker(tc, 1, TheContractorWorker.STATUS.DRIVING)
    world:runTo(1, 17, 0)
    world:runTo(1, 19, 0)
    assertEquals(worker.overtimeMinutes, 60, "an hour driving")
    local sent = world.broadcasts[#world.broadcasts]
    assertEquals(sent.kind, "overtime", "sent on the hour")
    assertEquals(sent.entries[1].minutes, 60, "the figures")

    local overtime = 2000 / 280 * 1.5
    tc.Staff:paySalaries()
    local paid = world.money[#world.money]
    local wageBill = tc.Staff:getWageBill(1)
    assertEquals(paid.amount, -(wageBill + math.floor(overtime + 0.5)), "salaries, pension and overtime")
    assertEquals(paid.moneyType, "wages", "as wages")
    assertEquals(worker.overtimeOwed, 0, "cleared")
    assertEquals(worker.overtimeMinutes, 0, "cleared")
    assertEquals(world.broadcasts[#world.broadcasts].entries[1].minutes, 0, "clients told")
end)

test("someone leaving is paid their overtime first", function()
    local world, tc = setup()
    local worker = addWorker(tc, 1)
    worker.overtimeMinutes, worker.overtimeOwed = 60, 10.6
    tc.WorkingHours:payLeaver(1, worker)
    assertEquals(world.money[1].amount, -11, "paid")
    assertEquals(world.wages, 11, "recorded")
    assertEquals(worker.overtimeOwed, 0, "cleared")
end)

test("duty and overtime are saved and streamed with the worker", function()
    local world, tc = setup()
    local worker = addWorker(tc, 1)
    worker.dutyFrom, worker.dutyArrive, worker.dutyUntil = 100, 125, 300
    worker.overtimeMinutes, worker.overtimeOwed = 45, 8.25

    local stream = world:newStream()
    TheContractorStaff.writeWorker(stream, worker)
    local copy = TheContractorStaff.readWorker(stream)
    assertEquals(copy.dutyArrive, 125, "streamed arrival")
    assertEquals(copy.dutyUntil, 300, "streamed until")
    assertEquals(copy.overtimeMinutes, 45, "streamed minutes")
    assertNear(copy.overtimeOwed, 8.25, 1e-4, "streamed owed")

    local xmlFile = {}
    TheContractorStaff.writeWorkerXML(xmlFile, "w", worker)
    local loaded = TheContractorStaff.readWorkerXML(xmlFile, "w", 1)
    assertEquals(loaded.dutyFrom, 100, "saved from")
    assertEquals(loaded.dutyUntil, 300, "saved until")
    assertEquals(loaded.overtimeMinutes, 45, "saved minutes")

    local plain = addWorker(tc, 2)
    local stream2 = world:newStream()
    TheContractorStaff.writeWorker(stream2, plain)
    local plainCopy = TheContractorStaff.readWorker(stream2)
    assertEquals(plainCopy.dutyUntil, nil, "no duty")
    assertEquals(plainCopy.overtimeMinutes, 0, "none")
end)

test("ADS and the office: away once they've gone home", function()
    local world, tc = setup()
    local worker = addWorker(tc, 1)
    local member = { id = 9, role = "administrator", farmId = 1, name = "Ann", level = 1 }
    world:at(1, 12, 0)
    assertEquals(TheContractorWorkshop.getADSStatus(worker), "available", "midday")
    assertEquals(TheContractorOffice.getStatus(member), "available", "office open")
    world:at(1, 19, 0)
    assertEquals(TheContractorWorkshop.getADSStatus(worker), "unavailable", "gone home")
    assertEquals(TheContractorOffice.getStatus(member), "atHome", "office shut")
    local assignments = TCADSWorkshop.buildAssignments({ member }, {})
    assertEquals(assignments.receptionist.status, "unavailable", "ADS has no at home")
    member.trainingUntilDay = 4
    assertEquals(TheContractorOffice.getStatus(member), "training", "training wins")
end)

test("tcWorker hours and duty", function()
    local world, tc = setup()
    addWorker(tc, 1)
    TCConsole.reset()
    TheContractorWorkingHours.registerConsoleCommands()
    local group = TCConsole.groups.worker
    local worker = tc.Staff:getWorker(1, 1)
    world:at(1, 15, 0)
    assertTrue(TCConsole.dispatch(group, { "hours" }) ~= nil, "hours lists")
    TCConsole.dispatch(group, { "duty", "1", "22" })
    assertEquals(worker.dutyUntil, DAY + 22 * 60, "kept on until 22:00")
    TCConsole.dispatch(group, { "duty", "1", "home" })
    assertEquals(worker.dutyUntil, nil, "sent home")
    local now = world:at(1, 20, 0)
    TCConsole.dispatch(group, { "duty", "1", "23" })
    assertEquals(worker.dutyArrive, now + 25, "called back: in at 20:25")
    assertEquals(worker.dutyUntil, DAY + 23 * 60)
    TCConsole.dispatch(group, { "duty", "1", "soon" })
    assertEquals(worker.dutyUntil, DAY + 23 * 60, "not an hour: unchanged")
end)
