-- 104: workplace injuries, on the real random events framework (068), real
-- Staff, Worker, WorkingHours and HealthSafety: the days off at each days
-- per period, the rate and the programme, who can be hurt (at work only,
-- never the office), idle and on-a-job injuries, and the console's worker
-- and scenario. Overheads, Inbox and the status event are faked.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    world.texts.ui_on = "On"
    world.texts.ui_off = "Off"
    for month = 1, 12 do
        world.texts["ui_month" .. month] = "Month " .. month
    end

    Environment = { PERIODS_IN_YEAR = 12 }
    Enterable = {}
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    g_currentMission.environment = {
        currentYear = 2,
        currentPeriod = 2,
        currentDayInPeriod = 1,
        daysPerPeriod = 10,
        plannedDaysPerPeriod = 10,
        currentMonotonicDay = 100,
        currentHour = 10,
        dayTime = 10 * 3600000,
    }
    g_farmManager.getFarmById = function(_, farmId)
        return { farmId = farmId }
    end
    g_farmManager.getFarmByUserId = function()
        return { farmId = 1 }
    end

    world:load("src/util/TCCalendar.lua")
    world:load("src/util/TCConsole.lua")
    world:load("src/util/TCEconomyScale.lua")
    world:load("src/util/TCNames.lua")
    world:load("src/util/TCWorkerAppearance.lua")
    world:load("src/business/Settings.lua")
    world:load("src/business/RandomEvents.lua")
    world:load("src/business/Worker.lua")
    world:load("src/business/Staff.lua")
    world:load("src/business/Training.lua")
    world:load("src/business/HealthSafety.lua")
    world:load("src/business/WorkingHours.lua")
    world:load("src/business/Injury.lua")

    TCRandomEventIncidentEvent = {
        new = function(incident, isClosed)
            return { incident = incident, isClosed = isClosed }
        end,
    }
    TCWorkerStatusChangedEvent = {
        new = function() return {} end,
        showNotification = function() end,
    }
    g_server = { broadcastEvent = function() end }

    local tc = g_currentMission.TheContractor
    tc.Settings = TheContractorSettings.new()
    tc.Company = { companyNames = { [1] = "Test Contracting" } }
    tc.Staff = setmetatable({ workersByFarm = {}, candidatePool = {} }, TheContractorStaff_mt)
    tc.WorkingHours = TheContractorWorkingHours.new()
    world.hasProgramme = true
    tc.Overheads = {
        isActive = function(_, farmId, key)
            return key == TheContractorHealthSafety.OVERHEAD_KEY and world.hasProgramme
        end,
    }
    tc.HealthSafety = TheContractorHealthSafety.new()
    tc.Jobs = { getAllJobs = function() return {} end }
    tc.Dispatch = { isJobActive = function() return true end }

    world.messages = {}
    tc.Inbox = {
        registerMessageKind = function() end,
        postMessage = function(_, farmId, kind, titleKey, bodyKey, args, actions, payload)
            local resolved = {}
            for i, arg in ipairs(args) do
                if type(arg) == "string" and string.sub(arg, 1, 6) == "$l10n_" then
                    resolved[i] = g_i18n:getText(string.sub(arg, 7))
                else
                    resolved[i] = arg
                end
            end
            local message = { farmId = farmId, kind = kind, bodyKey = bodyKey, args = args,
                title = string.format(g_i18n:getText(titleKey), unpack(resolved)),
                body = string.format(g_i18n:getText(bodyKey), unpack(resolved)), payload = payload }
            table.insert(world.messages, message)
            return #world.messages
        end,
    }

    tc.RandomEvents = TheContractorRandomEvents.new()
    tc.Injury = TheContractorInjury.new()
    tc.Injury:register(tc.RandomEvents, tc.Inbox)

    function world:addWorker(def)
        local worker = TheContractorWorker.new(def.id, 1, def.name or ("Worker " .. def.id), 5, { small = 6 },
            2500, 30, 0, nil, nil, {})
        worker.status = def.status or TheContractorWorker.STATUS.IDLE
        tc.Staff.workersByFarm[1] = tc.Staff.workersByFarm[1] or {}
        tc.Staff.workersByFarm[1][def.id] = worker
        return worker
    end

    return world, tc
end

-- The farm's only worker, so the pick is theirs.
local function injure(tc)
    return tc.RandomEvents:triggerEvent(1, "injury")
end

test("days off scale with days per period: always 1 at 1 day, 2-5 from 5", function()
    setup()
    local expected = { { 1, 1 }, { 1, 2 }, { 2, 3 }, { 2, 4 }, { 2, 5 }, { 2, 5 }, { 2, 5 } }
    local days = { 1, 2, 3, 4, 5, 10, 28 }
    for i, daysPerPeriod in ipairs(days) do
        local low, high = TheContractorInjury.getDayRange(daysPerPeriod)
        assertEquals(low, expected[i][1], daysPerPeriod .. " days: shortest")
        assertEquals(high, expected[i][2], daysPerPeriod .. " days: longest")
        assertEquals(TheContractorInjury.getInjuryDays(daysPerPeriod, 0), low, daysPerPeriod .. " days: roll 0")
        assertEquals(TheContractorInjury.getInjuryDays(daysPerPeriod, 0.9999), high,
            daysPerPeriod .. " days: roll 1")
    end
    -- Every length in the range comes up.
    local seen = {}
    for roll = 0, 0.99, 0.01 do
        seen[TheContractorInjury.getInjuryDays(10, roll)] = true
    end
    for length = 2, 5 do
        assertTrue(seen[length], "a " .. length .. "-day injury")
    end
end)

test("about once in 2.5 years, a quarter off with the H&S programme, none with nobody to hurt", function()
    local world, tc = setup()
    assertEquals(tc.Injury:getRatePerPeriod(1), 0, "nobody on the roster")

    world:addWorker({ id = 1 })
    world.hasProgramme = false
    assertNear(tc.Injury:getRatePerPeriod(1), 1 / 30, 0.0001, "without the programme")
    world.hasProgramme = true
    assertNear(tc.Injury:getRatePerPeriod(1), 0.75 / 30, 0.0001, "with it")

    world:addWorker({ id = 2 })
    assertNear(tc.Injury:getRatePerPeriod(1), 0.75 / 30, 0.0001, "not more with more staff")

    tc.Staff:getWorker(1, 1).status = TheContractorWorker.STATUS.SICK
    tc.Staff:getWorker(1, 2).status = TheContractorWorker.STATUS.HOLIDAY
    assertEquals(tc.Injury:getRatePerPeriod(1), 0, "everyone off already")
end)

test("only someone at work: in the yard in hours or out working, never off or due off", function()
    local world, tc = setup()
    local STATUS = TheContractorWorker.STATUS
    world:addWorker({ id = 1 })
    world:addWorker({ id = 2, status = STATUS.COOLDOWN })
    world:addWorker({ id = 3, status = STATUS.SICK })
    world:addWorker({ id = 4, status = STATUS.TRAINING })
    world:addWorker({ id = 5 }).pendingSickDays = 2

    local ids = {}
    for _, worker in ipairs(tc.Injury:getCandidates(1, true)) do
        table.insert(ids, worker.id)
    end
    assertEquals(table.concat(ids, ","), "1,2")

    -- 20:00: the idle one's gone home, the one in a cooldown is still at it.
    g_currentMission.environment.dayTime = 20 * 3600000
    g_currentMission.environment.currentHour = 20
    ids = {}
    for _, worker in ipairs(tc.Injury:getCandidates(1, true)) do
        table.insert(ids, worker.id)
    end
    assertEquals(table.concat(ids, ","), "2")
    assertEquals(#tc.Injury:getCandidates(1, false), 2, "the rate counts both")
end)

test("hurt in the yard: off sick now, through makeWorkerSick, with the dates", function()
    local world, tc = setup()
    g_currentMission.environment.daysPerPeriod = 1
    local worker = world:addWorker({ id = 1, name = "Amy Hall" })

    local incident = tc.RandomEvents:triggerEvent(1, "injury")
    assertEquals(incident.data.workerId, 1)
    assertEquals(incident.data.days, 1, "always a day at 1 day per period")
    assertEquals(tc.RandomEvents:getIncident(incident.id), nil, "over at once")
    assertEquals(worker.status, TheContractorWorker.STATUS.SICK)
    assertEquals(worker.sickDaysRemaining, 1)

    local message = world.messages[1]
    assertEquals(message.kind, "injury")
    assertEquals(message.bodyKey, "tc_injury_body")
    assertEquals(message.args[1], "Amy Hall", "who")
    assertEquals(message.args[2], "$l10n_tc_injury_scenario_" .. incident.data.scenario, "how")
    assertEquals(message.args[4], "$days_100_100")
end)

test("hurt on a job: sees it through, off once back", function()
    local world, tc = setup()
    local worker = world:addWorker({ id = 1, status = TheContractorWorker.STATUS.COOLDOWN })

    local incident = injure(tc)
    assertEquals(worker.status, TheContractorWorker.STATUS.COOLDOWN, "not pulled off")
    assertTrue(worker.pendingSickDays >= 2 and worker.pendingSickDays <= 5, "2-5 days pending")
    local message = world.messages[1]
    assertEquals(message.bodyKey, "tc_injury_bodyOnJob")
    assertEquals(message.args[2], "$l10n_tc_injury_scenario_" .. incident.data.scenario, "how")
    assertEquals(message.args[3], worker.pendingSickDays, "the days they'll be off")
end)

test("without the programme, an injury can bring an inspection", function()
    local world, tc = setup()
    world.hasProgramme = false
    local worker = world:addWorker({ id = 1 })
    local inspected = nil
    tc.HealthSafety.runInspection = function(_, farmId, who)
        inspected = who
    end
    local random = math.random
    math.random = function(a)
        if a ~= nil then
            return a
        end
        return 0
    end
    injure(tc)
    math.random = random
    assertEquals(inspected, worker)
end)

test("every scenario has its text", function()
    setup()
    for _, key in ipairs(TheContractorInjury.SCENARIOS) do
        assertTrue(g_i18n:getText("tc_injury_scenario_" .. key) ~= nil, key)
    end
end)

test("tcCompany event injury takes no details, and works at any hour", function()
    local world, tc = setup()
    world:addWorker({ id = 1, name = "Amy Hall" })
    world:addWorker({ id = 2, name = "Ben Ward", status = TheContractorWorker.STATUS.SICK })
    TCConsole.reset()
    TheContractorRandomEvents.registerConsoleCommands()
    local group = TCConsole.groups.company

    TCConsole.dispatch(group, { "event", "injury", "amy" })
    assertEquals(tc.Staff:getWorker(1, 1).status, TheContractorWorker.STATUS.IDLE, "takes no details: nothing happened")

    -- 22:00, nobody at work: the console still finds someone, never the sick one.
    g_currentMission.environment.dayTime = 22 * 3600000
    g_currentMission.environment.currentHour = 22
    TCConsole.dispatch(group, { "event", "injury" })
    assertEquals(tc.Staff:getWorker(1, 1).status, TheContractorWorker.STATUS.SICK)
    assertEquals(tc.Injury.fromConsole, false, "cleared")

    local messageCount = #world.messages
    TCConsole.dispatch(group, { "event", "injury" })
    assertEquals(#world.messages, messageCount, "nobody left to hurt")
end)

test("the off-sick notification gives the real days, and says hurt for an injury", function()
    local world, tc = setup()
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    world:load("src/events/TCWorkerStatusChangedEvent.lua")
    FSBaseMission.INGAME_NOTIFICATION_INFO = "info"
    local STATUS = TheContractorWorker.STATUS
    -- What each off-sick notification was worded from.
    local shown = {}
    local getOffSickText = TCWorkerStatusChangedEvent.getOffSickText
    TCWorkerStatusChangedEvent.getOffSickText = function(name, sickDays, isInjury)
        table.insert(shown, { name = name, days = sickDays, isInjury = isInjury })
        return getOffSickText(name, sickDays, isInjury)
    end

    -- An injury on a 1-day month: today only.
    g_currentMission.environment.daysPerPeriod = 1
    local amy = world:addWorker({ id = 1, name = "Amy Hall" })
    injure(tc)
    assertEquals(#world.notifications, 1)
    assertEquals(shown[1].name, "Amy Hall")
    assertEquals(shown[1].days, 1, "today only")
    assertTrue(shown[1].isInjury, "hurt")

    -- Plain sickness, three days.
    local ben = world:addWorker({ id = 2, name = "Ben Ward" })
    tc.Staff:makeWorkerSick(1, ben, false, 3)
    assertEquals(shown[2].days, 3)
    assertTrue(not shown[2].isInjury, "called in sick")
    assertEquals(ben.isInjured, false)

    -- An injury on a job: the days and the wording wait until they're back.
    amy.status = STATUS.COOLDOWN
    amy.pendingSickDays = 0
    g_currentMission.environment.daysPerPeriod = 10
    math.randomseed(1)
    tc.RandomEvents:triggerEvent(1, "injury")
    local count = #shown
    tc.Staff:setWorkerStatus(1, 1, STATUS.IDLE)
    assertEquals(amy.status, STATUS.SICK)
    assertEquals(#shown, count + 1, "told once they're back")
    assertEquals(shown[count + 1].days, amy.sickDaysRemaining, "the real days")
    assertTrue(shown[count + 1].isInjury, "hurt")
end)
