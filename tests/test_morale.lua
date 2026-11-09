-- 118: temperament and rough patches, on the real Morale, PayReviews,
-- Worker and TCWorkerMoraleChangedEvent: the temperament roll's spread,
-- knocks scaled by it (and the console's set not), the drift settling on a
-- target moved by it, a rough patch's knock, notification, lower target and
-- countdown, the monthly roll, the save, and the ticket's "circumstances
-- align" case reaching the quit line. Staff is the real class with its roster
-- filled by hand; leaving is faked.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    Environment = { PERIODS_IN_YEAR = 12 }
    Enterable = {}
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    g_farmManager.getFarmByUserId = function()
        return { farmId = 1 }
    end
    FSBaseMission.INGAME_NOTIFICATION_INFO = "info"
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    g_currentMission.environment = {
        currentYear = 1,
        currentPeriod = 2,
        currentDayInPeriod = 1,
        daysPerPeriod = 1,
        currentMonotonicDay = 10,
    }

    world:load("src/util/TCCalendar.lua")
    world:load("src/util/TCConsole.lua")
    world:load("src/util/TCNames.lua")
    world:load("src/util/TCWorkerAppearance.lua")
    world:load("src/business/Worker.lua")
    world:load("src/business/Staff.lua")
    world:load("src/business/Morale.lua")
    world:load("src/business/PayReviews.lua")
    world:load("src/events/TCWorkerMoraleChangedEvent.lua")

    local tc = g_currentMission.TheContractor
    tc.Staff = setmetatable({ workersByFarm = {}, candidatePool = {} }, TheContractorStaff_mt)
    tc.Staff.announceLeaving = function(_, farmId, workerId)
        tc.Staff:getWorker(farmId, workerId).leavesAtPeriod = 99
    end
    tc.Morale = TheContractorMorale.new()
    TCConsole.reset()
    TheContractorMorale.registerConsoleCommands()
    -- The player's commands are tcWorker's, the testing ones tcDebug's.
    world.console = function(args)
        return TCConsole.dispatch(TCConsole.groups.worker, args)
    end
    world.debugConsole = function(args)
        return TCConsole.dispatch(TCConsole.groups.debug, args)
    end

    -- math.random() gives world.roll (1 = never); ranges their lowest value.
    world.roll = 1
    math.random = function(low, high)
        if low == nil then
            return world.roll
        end
        return low
    end

    function world:addWorker(id, name, temperament)
        local worker = TheContractorWorker.new(id, 1, name, 5, { small = 6 }, 2000, 30, 0, 1, 0, {}, 5)
        worker.temperament = temperament or 0
        tc.Staff.workersByFarm[1] = tc.Staff.workersByFarm[1] or {}
        tc.Staff.workersByFarm[1][id] = worker
        return worker
    end

    -- A month of `busy` working days out of `days`, then the month roll.
    function world:passMonth(busy, days)
        for _, worker in pairs(tc.Staff.workersByFarm[1]) do
            worker.busyDays = busy
            worker.idleDays = days - busy
        end
        tc.Morale:onPeriodChanged()
    end

    return world, tc
end

test("the temperament roll stays in range, peaks at 0 and leaves a small grumpy tail", function()
    setup()
    local low, high = TheContractorMorale.TEMPERAMENT_MIN, TheContractorMorale.TEMPERAMENT_MAX
    assertEquals(TheContractorMorale.rollTemperament(0), low)
    assertEquals(TheContractorMorale.rollTemperament(1), high)
    assertEquals(TheContractorMorale.rollTemperament(-low / (high - low)), 0)

    local steps, grumpy, nearZero = 1000, 0, 0
    for i = 0, steps - 1 do
        local value = TheContractorMorale.rollTemperament((i + 0.5) / steps)
        assertTrue(value >= low and value <= high, "out of range: " .. value)
        if value <= -8 then
            grumpy = grumpy + 1
        end
        if math.abs(value) <= 3 then
            nearZero = nearZero + 1
        end
    end
    assertTrue(grumpy / steps >= 0.08 and grumpy / steps <= 0.15, "grumpy share " .. grumpy / steps)
    assertTrue(nearZero / steps >= 0.35, "near zero share " .. nearZero / steps)
end)

test("knocks land harder on the grumpy and softer on the cheerful; boosts don't change", function()
    local world, tc = setup()
    local grumpy = world:addWorker(1, "Amy Hall", TheContractorMorale.TEMPERAMENT_MIN)
    local level = world:addWorker(2, "Ben Ward", 0)
    local cheerful = world:addWorker(3, "Cal Reed", TheContractorMorale.TEMPERAMENT_MAX)
    local halfGrumpy = world:addWorker(4, "Dee Park", TheContractorMorale.TEMPERAMENT_MIN / 2)

    tc.Morale:adjust(1, { grumpy, level, cheerful, halfGrumpy }, -8)
    assertNear(grumpy.morale, 70 - 12, 0.001)
    assertNear(level.morale, 70 - 8, 0.001)
    assertNear(cheerful.morale, 70 - 6, 0.001)
    assertNear(halfGrumpy.morale, 70 - 10, 0.001)

    tc.Morale:adjust(1, { grumpy, cheerful }, 5)
    assertNear(grumpy.morale, 63, 0.001)
    assertNear(cheerful.morale, 69, 0.001)
end)

test("the console sets morale exactly, whatever the temperament", function()
    local world = setup()
    local amy = world:addWorker(1, "Amy Hall", TheContractorMorale.TEMPERAMENT_MIN)
    world.console({ "morale", "1", "20" })
    assertNear(amy.morale, 20, 0.001)

    world.console({ "morale", "1" })
    assertNear(amy.morale, 20, 0.001, "tcWorker morale only sets: no value, no change")
    world.debugConsole({ "morale", "1", "35" })
    assertNear(amy.morale, 35, 0.001, "tcDebug's readout can set it too")
end)

test("drift settles on a target moved by temperament", function()
    local world = setup()
    local level = world:addWorker(1, "Amy Hall", 0)
    local grumpy = world:addWorker(2, "Ben Ward", TheContractorMorale.TEMPERAMENT_MIN)
    local cheerful = world:addWorker(3, "Cal Reed", TheContractorMorale.TEMPERAMENT_MAX)

    for _ = 1, 24 do
        world:passMonth(15, 20)
    end
    assertNear(level.morale, TheContractorMorale.TARGET_STEADY, 0.1)
    assertNear(grumpy.morale, TheContractorMorale.TARGET_STEADY + TheContractorMorale.TEMPERAMENT_MIN, 0.1)
    assertNear(cheerful.morale, TheContractorMorale.TARGET_STEADY + TheContractorMorale.TEMPERAMENT_MAX, 0.1)
end)

test("a rough patch knocks at once, tells the farm, lowers the target for its months, then ends", function()
    local world, tc = setup()
    local amy = world:addWorker(1, "Amy Hall", 0)

    tc.Morale:startRoughPatch(amy, 2)
    assertNear(amy.morale, 70 + TheContractorMorale.ROUGH_PATCH_KNOCK, 0.001)
    assertTrue(TheContractorMorale.isInRoughPatch(amy))
    assertEquals(#world.notifications, 1)

    local patchTarget = TheContractorMorale.TARGET_STEADY + TheContractorMorale.ROUGH_PATCH_TARGET
    assertNear(TheContractorMorale.getTarget(amy), patchTarget, 0.001)

    -- Two months drift toward the lower target, then it's over.
    local before = amy.morale
    world:passMonth(15, 20)
    assertNear(amy.morale, before + (patchTarget - before) / 3, 0.001)
    assertTrue(TheContractorMorale.isInRoughPatch(amy))
    before = amy.morale
    world:passMonth(15, 20)
    assertNear(amy.morale, before + (patchTarget - before) / 3, 0.001)
    assertTrue(not TheContractorMorale.isInRoughPatch(amy))

    -- Back to drifting up toward the usual target.
    before = amy.morale
    world:passMonth(15, 20)
    assertTrue(amy.morale > before)
end)

test("the monthly roll starts rough patches, but not for anyone leaving or already in one", function()
    local world, tc = setup()
    local amy = world:addWorker(1, "Amy Hall", 0)
    local ben = world:addWorker(2, "Ben Ward", 0)
    ben.leavesAtPeriod = 99
    local cal = world:addWorker(3, "Cal Reed", 0)
    cal.roughPatchPeriods = 3

    world.roll = 0.01
    -- Morale over the quit line, so the low roll doesn't make anyone quit.
    world:passMonth(15, 20)
    assertEquals(amy.roughPatchPeriods, TheContractorMorale.ROUGH_PATCH_MONTHS[1])
    assertEquals(ben.roughPatchPeriods, 0)
    assertEquals(cal.roughPatchPeriods, 2)

    -- Over the chance, nobody new.
    world.roll = TheContractorMorale.ROUGH_PATCH_CHANCE
    local dee = world:addWorker(4, "Dee Park", 0)
    world:passMonth(15, 20)
    assertEquals(dee.roughPatchPeriods, 0)
end)

test("the console starts and ends a rough patch", function()
    local world = setup()
    local amy = world:addWorker(1, "Amy Hall", 0)
    world.debugConsole({ "roughPatch", "amy", "3" })
    assertEquals(amy.roughPatchPeriods, 3)
    local morale = amy.morale
    world.debugConsole({ "roughPatch", "amy", "0" })
    assertEquals(amy.roughPatchPeriods, 0)
    assertNear(amy.morale, morale, 0.001)
    world.debugConsole({ "roughPatch", "amy", "x" })
    assertEquals(amy.roughPatchPeriods, 0, "not a number: refused")
end)

test("temperament and a rough patch are saved; an older save's worker gets a temperament", function()
    local world = setup()
    local amy = world:addWorker(1, "Amy Hall", -9)
    amy.roughPatchPeriods = 2
    local xmlFile = {}
    TheContractorMorale.writeXML(xmlFile, "w", amy)

    local loaded = TheContractorWorker.new(1, 1, "Amy Hall", 5, { small = 6 }, 2000, 30, 0, 1, 0, {}, 5)
    TheContractorMorale.readXML(xmlFile, "w", loaded)
    assertEquals(loaded.temperament, -9)
    assertEquals(loaded.roughPatchPeriods, 2)

    world.roll = 0
    local old = TheContractorWorker.new(2, 1, "Ben Ward", 5, { small = 6 }, 2000, 30, 0, 1, 0, {}, 5)
    TheContractorMorale.readXML({ ["w#morale"] = 60 }, "w", old)
    assertEquals(old.temperament, TheContractorMorale.TEMPERAMENT_MIN)
    assertEquals(old.roughPatchPeriods, 0)
end)

test("when circumstances align, a grumpy worker reaches the quit line", function()
    local world, tc = setup()
    local amy = world:addWorker(1, "Amy Hall", TheContractorMorale.TEMPERAMENT_MIN)
    local ben = world:addWorker(2, "Ben Ward", 0)
    -- 10% under what they expect, and quiet months (4 days of 20 out on work).
    for _, worker in ipairs({ amy, ben }) do
        worker.expectedSalary = worker.salary / 0.9
    end
    for _ = 1, 24 do
        world:passMonth(4, 20)
    end
    assertNear(amy.morale, 45, 0.1, "grumpy settled")
    assertNear(ben.morale, 60, 0.1, "level settled")

    -- A rough patch, a month on, then a refused holiday.
    tc.Morale:startRoughPatch(amy, 2)
    tc.Morale:startRoughPatch(ben, 2)
    world:passMonth(4, 20)
    tc.Morale:onHolidayRefused(amy, 1, false)
    tc.Morale:onHolidayRefused(ben, 1, false)
    assertTrue(amy.morale < TheContractorMorale.QUIT_MORALE, "grumpy fell to " .. amy.morale)
    assertTrue(ben.morale > 45, "level fell only to " .. ben.morale)
end)
