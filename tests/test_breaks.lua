-- Worker breaks (131): morning, lunch and afternoon, each taken in its window
-- when the worker's free, missed while they're out working, excused while
-- they're away; nobody can be given anything while on one (and ADS's
-- workshop sees them away); the day's morale knock at 18:00; the save, the
-- stream and the console.

local DAY = 24 * 60

local function setup()
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
    world:load("src/business/Breaks.lua")
    world:load("src/util/TCCalendar.lua")
    world:load("src/business/Training.lua")
    world:load("src/business/Morale.lua")
    world:load("src/business/PayReviews.lua")
    world:load("src/business/Holidays.lua")

    g_currentMission.environment = { currentMonotonicDay = 1, dayTime = 8 * 3600000, daysPerPeriod = 28 }
    world.broadcasts = {}
    g_server = {
        broadcastEvent = function(_, event)
            table.insert(world.broadcasts, event)
        end,
    }
    TCWorkerBreakEvent = {
        new = function(farmId, workerId, breakUntil)
            return { kind = "break", farmId = farmId, workerId = workerId, breakUntil = breakUntil }
        end,
    }
    g_farmManager.getFarmByUserId = function()
        return { farmId = 1 }
    end
    world.refreshes = 0
    TCADSWorkshop.refresh = function()
        world.refreshes = world.refreshes + 1
    end

    local tc = g_currentMission.TheContractor
    tc.Settings = TheContractorSettings.new()
    tc.Staff = setmetatable({ workersByFarm = {}, candidatePool = {}, nextWorkerId = 1 }, TheContractorStaff_mt)
    tc.Office = TheContractorOffice.new()
    tc.WorkingHours = TheContractorWorkingHours.new()
    tc.Breaks = TheContractorBreaks.new()
    world.knocks = {}
    tc.Morale = {
        adjust = function(_, farmId, workers, delta)
            for _, worker in ipairs(workers) do
                world.knocks[worker.id] = (world.knocks[worker.id] or 0) + delta
            end
        end,
    }
    world.jobs = {}
    tc.Jobs = {
        getAllJobs = function()
            return world.jobs
        end,
    }
    tc.Dispatch = {
        isJobActive = function()
            return true
        end,
    }

    function world:at(day, hour, minute)
        g_currentMission.environment.currentMonotonicDay = day
        g_currentMission.environment.dayTime = (hour * 60 + (minute or 0)) * 60000
        return TheContractorWorkingHours.getNow()
    end

    -- Moves the clock on minute by minute, as the game would, from wherever
    -- it is now.
    function world:runTo(day, hour, minute)
        local target = day * DAY + hour * 60 + (minute or 0)
        local now = TheContractorWorkingHours.getNow()
        tc.Breaks:update(16)
        while now < target do
            now = now + 1
            self:at(math.floor(now / DAY), math.floor((now % DAY) / 60), now % 60)
            tc.Breaks:update(16)
        end
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

test("an idle worker takes each break as its window opens, and is away for it", function()
    local world, tc = setup()
    local worker = addWorker(tc, 1)
    world:at(1, 8, 0)
    world:runTo(1, 9, 59)
    assertEquals(worker.breakUntil, nil, "not before 10:00")

    world:runTo(1, 10, 0)
    assertEquals(worker.breakUntil, DAY + 10 * 60 + 15, "morning break to 10:15")
    assertEquals(worker.breakResults.morning, "taken")
    assertEquals(#world.broadcasts, 1, "clients told")
    assertEquals(world.broadcasts[1].breakUntil, worker.breakUntil)
    assertEquals(world.refreshes, 1, "ADS told at the start")

    -- Not available for anything while on it.
    assertTrue(not TheContractorWorkingHours.isAvailable(worker), "not available")
    assertEquals(#tc.Staff:getAvailableWorkers(1), 0, "not offered")
    assertEquals(TheContractorWorkingHours.getDisplayStatus(worker), "onBreak", "on break")
    assertEquals(TheContractorWorkshop.getADSStatus(worker), "unavailable", "ADS holds the repair")
    assertTrue(not TheContractorWorkingHours.isOnSite(worker), "off the standing spots")

    world:runTo(1, 10, 15)
    assertTrue(TheContractorWorkingHours.isAvailable(worker), "back at 10:15")
    assertEquals(TheContractorWorkshop.getADSStatus(worker), "available")
    assertEquals(world.refreshes, 2, "ADS told at the end")

    world:runTo(1, 12, 0)
    assertEquals(worker.breakUntil, DAY + 12 * 60 + 30, "lunch to 12:30")
    world:runTo(1, 15, 0)
    assertEquals(worker.breakUntil, DAY + 15 * 60 + 15, "afternoon to 15:15")
    world:runTo(1, 18, 0)
    assertEquals(world.knocks[1], nil, "all three taken: no knock")
end)

test("the driver picker's 'all on a break' names whoever is back soonest", function()
    local world, tc = setup()
    local early = addWorker(tc, 1)
    local late = addWorker(tc, 2)
    local now = world:at(1, 10, 5)
    early.breakUntil = now + 5
    late.breakUntil = now + 20
    assertEquals(TheContractorBreaks.getFirstBack({ late, early }, now), early, "back first")

    early.breakUntil = nil
    assertEquals(TheContractorBreaks.getFirstBack({ late, early }, now), late, "only one on a break")

    -- Gone home for the day: nobody's on a break, whatever breakUntil says.
    late.breakUntil = world:at(1, 19, 0) + 20
    assertEquals(TheContractorBreaks.getFirstBack({ late, early }, world:at(1, 19, 0)), nil, "all home")
end)

test("out on a job: the morning break's missed, lunch taken late, the afternoon on time", function()
    local world, tc = setup()
    local worker = addWorker(tc, 1, TheContractorWorker.STATUS.ASSIGNED)
    world:at(1, 9, 0)
    world:runTo(1, 12, 29)
    assertEquals(worker.breakResults.morning, "missed", "missed after 11:45")
    assertEquals(worker.breakUntil, nil, "nothing while out")

    worker.status = TheContractorWorker.STATUS.IDLE
    world:runTo(1, 12, 30)
    assertEquals(worker.breakUntil, DAY + 13 * 60, "lunch 12:30 to 13:00")
    world:runTo(1, 15, 0)
    assertEquals(worker.breakResults.afternoon, "taken")
    world:runTo(1, 18, 0)
    assertEquals(world.knocks[1], TheContractorBreaks.MORALE.short, "a missed short break")
end)

test("a lunch running past 15:00 holds the afternoon break until it's over", function()
    local world, tc = setup()
    local worker = addWorker(tc, 1, TheContractorWorker.STATUS.ASSIGNED)
    world:at(1, 14, 0)
    world:runTo(1, 14, 44)
    worker.status = TheContractorWorker.STATUS.IDLE
    world:runTo(1, 14, 45)
    assertEquals(worker.breakUntil, DAY + 15 * 60 + 15, "lunch from 14:45")
    world:runTo(1, 15, 14)
    assertEquals(worker.breakResults.afternoon, nil, "afternoon waits")
    world:runTo(1, 15, 15)
    assertEquals(worker.breakResults.afternoon, "taken", "then straight on to it")
    assertEquals(worker.breakUntil, DAY + 15 * 60 + 30)
end)

test("the day's knock: short breaks count once, lunch on its own, added together", function()
    setup()
    local delta = TheContractorBreaks.getMoraleDelta
    local MORALE = TheContractorBreaks.MORALE
    assertEquals(delta({ morning = "taken", lunch = "taken", afternoon = "taken" }), 0)
    assertEquals(delta({ morning = "missed", lunch = "taken", afternoon = "taken" }), MORALE.short)
    assertEquals(delta({ morning = "missed", lunch = "taken", afternoon = "missed" }), MORALE.short, "both: once")
    assertEquals(delta({ morning = "taken", lunch = "missed", afternoon = "taken" }), MORALE.lunch)
    assertEquals(delta({ morning = "missed", lunch = "missed", afternoon = "missed" }), MORALE.short + MORALE.lunch)
    assertEquals(delta({ morning = "excused", lunch = "excused", afternoon = "excused" }), 0, "excused")
end)

test("out all day misses everything; sick all day is excused; judged once at 18:00", function()
    local world, tc = setup()
    local busy = addWorker(tc, 1, TheContractorWorker.STATUS.ASSIGNED)
    local sick = addWorker(tc, 2, TheContractorWorker.STATUS.SICK)
    local all = TheContractorBreaks.MORALE.short + TheContractorBreaks.MORALE.lunch
    world:at(1, 8, 0)
    world:runTo(1, 17, 59)
    assertEquals(world.knocks[1], nil, "not judged before 18:00")
    world:runTo(1, 18, 0)
    assertEquals(world.knocks[1], all, "all missed")
    assertEquals(world.knocks[2], nil, "sick: excused")
    assertEquals(sick.breakResults.lunch, "excused")
    world:runTo(1, 23, 0)
    assertEquals(world.knocks[1], all, "once")

    -- A new day starts a new record.
    busy.status = TheContractorWorker.STATUS.IDLE
    world:runTo(2, 10, 0)
    assertEquals(busy.breakDay, 2)
    assertEquals(busy.breakResults.morning, "taken")
end)

test("a sleep straight past 18:00 still judges the day before the new one starts", function()
    local world, tc = setup()
    addWorker(tc, 1, TheContractorWorker.STATUS.ASSIGNED)
    world:at(1, 9, 0)
    tc.Breaks:update(16)
    world:at(2, 7, 0)
    tc.Breaks:update(16)
    assertEquals(world.knocks[1], TheContractorBreaks.MORALE.short + TheContractorBreaks.MORALE.lunch)
end)

test("a worker hired mid-afternoon is excused the breaks they weren't here for", function()
    local world, tc = setup()
    world:at(1, 14, 0)
    tc.Breaks:update(16)
    local worker = addWorker(tc, 1, TheContractorWorker.STATUS.ASSIGNED)
    world:runTo(1, 18, 0)
    assertEquals(worker.breakResults.morning, "excused")
    assertEquals(worker.breakResults.lunch, "missed", "lunch was still open")
    assertEquals(world.knocks[1], TheContractorBreaks.MORALE.short + TheContractorBreaks.MORALE.lunch)
end)

test("the break and the day's record are saved, and the break streamed", function()
    local world, tc = setup()
    local worker = addWorker(tc, 1)
    world:at(1, 10, 0)
    world:runTo(1, 10, 5)

    local xmlFile = {}
    TheContractorStaff.writeWorkerXML(xmlFile, "w", worker)
    local loaded = TheContractorStaff.readWorkerXML(xmlFile, "w", 1)
    assertEquals(loaded.breakUntil, DAY + 10 * 60 + 15, "saved break")
    assertEquals(loaded.breakDay, 1)
    assertEquals(loaded.breakResults.morning, "taken")
    assertEquals(loaded.breakResults.lunch, nil)

    local stream = world:newStream()
    TheContractorStaff.writeWorker(stream, worker)
    local copy = TheContractorStaff.readWorker(stream)
    assertEquals(copy.breakUntil, DAY + 10 * 60 + 15, "streamed")
    assertEquals(TheContractorWorkingHours.getDisplayStatus(copy), "onBreak", "a client sees it")

    local plain = addWorker(tc, 2, TheContractorWorker.STATUS.ASSIGNED)
    local stream2 = world:newStream()
    TheContractorStaff.writeWorker(stream2, plain)
    assertEquals(TheContractorStaff.readWorker(stream2).breakUntil, nil)

    -- A client applies the server's break.
    local other = addWorker(tc, 3)
    TheContractorBreaks.applyBreak(other, DAY + 10 * 60 + 30)
    assertTrue(TheContractorWorkingHours.isOnBreak(other, TheContractorWorkingHours.getNow()))
end)

test("tcWorker break sends a free worker on their next break now", function()
    local world, tc = setup()
    local worker = addWorker(tc, 1)
    local busy = addWorker(tc, 2, TheContractorWorker.STATUS.ASSIGNED)
    TCConsole.reset()
    TheContractorBreaks.registerConsoleCommands()
    local group = TCConsole.groups.worker
    world:at(1, 9, 0)
    TCConsole.dispatch(group, { "break", "1" })
    assertEquals(worker.breakResults.morning, "taken", "before its window")
    assertEquals(worker.breakUntil, DAY + 9 * 60 + 15)
    TCConsole.dispatch(group, { "break", "1" })
    assertEquals(worker.breakResults.lunch, nil, "not while on one")
    TCConsole.dispatch(group, { "break", "2" })
    assertEquals(busy.breakUntil, nil, "not while busy")
end)
