-- 083: a worker poached by a rival, on the real random events framework
-- (068), real Staff, Worker and PayReviews: the March-May window, who's
-- approached, the offer, the stay chance, matching, doing nothing (and
-- letting it expire), a worker who's gone mid-offer, and the console's
-- worker and outcome. Market value is set per worker; Inbox and Morale's
-- adjust are faked.

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
        currentHour = 0,
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
    world:load("src/business/Morale.lua")
    world:load("src/business/PayReviews.lua")
    world:load("src/business/Poaching.lua")

    TheContractorPayReviews.getMarketValue = function(worker)
        return worker.marketValue
    end

    TCRandomEventIncidentEvent = {
        new = function(incident, isClosed)
            return { incident = incident, isClosed = isClosed }
        end,
    }
    world.payNotices = {}
    TCWorkerPayChangedEvent = {
        new = function() return {} end,
        showNotification = function(worker, notify)
            table.insert(world.payNotices, { workerId = worker.id, notify = notify })
        end,
    }
    TCWorkerRetirementAnnouncedEvent = {
        new = function() return {} end,
        showNotification = function() end,
    }
    TCWorkerRetiredEvent = {
        new = function() return {} end,
        showNotification = function() end,
    }
    TCWorkerReleasedEvent = { new = function() return {} end }
    g_server = { broadcastEvent = function() end }

    local tc = g_currentMission.TheContractor
    tc.Settings = TheContractorSettings.new()
    tc.Company = { companyNames = { [1] = "Test Contracting" } }
    tc.Staff = setmetatable({ workersByFarm = {}, candidatePool = {} }, TheContractorStaff_mt)
    tc.PayReviews = TheContractorPayReviews.new()
    tc.Notices = {
        publish = function() return 1 end,
        remove = function() end,
    }
    tc.Holidays = { refreshNotices = function() end }
    tc.Training = { removeMessagesFor = function() end }
    tc.Finances = { recordWages = function() end }
    g_currentMission.addMoney = function() end

    world.morale = {}
    tc.Morale = {
        adjust = function(_, farmId, workers, delta)
            for _, worker in ipairs(workers) do
                worker.morale = worker.morale + delta
                table.insert(world.morale, { workerId = worker.id, delta = delta })
            end
        end,
        onColleagueReleased = function() end,
    }

    -- Messages kept as posted, rendered as the client would.
    world.kinds, world.messages = {}, {}
    tc.Inbox = {
        registerMessageKind = function(_, kind, definition)
            world.kinds[kind] = definition
        end,
        postMessage = function(_, farmId, kind, titleKey, bodyKey, args, actions, payload, expiresInDays)
            local resolved = {}
            for i, arg in ipairs(args) do
                if type(arg) == "string" and string.sub(arg, 1, 6) == "$l10n_" then
                    resolved[i] = g_i18n:getText(string.sub(arg, 7))
                elseif type(arg) == "string" and string.sub(arg, 1, 5) == "$pay_" then
                    resolved[i] = string.sub(arg, 6)
                else
                    resolved[i] = arg
                end
            end
            local message = { id = #world.messages + 1, farmId = farmId, kind = kind, titleKey = titleKey,
                title = string.format(g_i18n:getText(titleKey), unpack(resolved)),
                body = string.format(g_i18n:getText(bodyKey), unpack(resolved)), args = args,
                actions = actions, payload = payload or {}, expiresInDays = expiresInDays }
            table.insert(world.messages, message)
            return message.id
        end,
        removeMessage = function(_, messageId)
            if messageId ~= nil and world.messages[messageId] ~= nil then
                world.messages[messageId].removed = true
            end
        end,
        getMessages = function(_, farmId)
            local result = {}
            for _, message in ipairs(world.messages) do
                if message.farmId == farmId and not message.removed then
                    table.insert(result, message)
                end
            end
            return result
        end,
    }

    tc.RandomEvents = TheContractorRandomEvents.new()
    tc.Poaching = TheContractorPoaching.new()
    tc.Poaching:register(tc.RandomEvents, tc.Inbox)

    -- def: { id, name, market, salary, expected, morale, hiredMonthsAgo }
    function world:addWorker(def)
        local salary = def.salary or 2500
        local worker = TheContractorWorker.new(def.id, 1, def.name or ("Worker " .. def.id), 5, { small = 6 },
            salary, 30, 0, nil, nil, {})
        worker.marketValue = def.market or salary
        worker.expectedSalary = def.expected or salary
        worker.morale = def.morale or 60
        worker.hiredPeriod = TCCalendar.getPeriodIndex() - (def.hiredMonthsAgo or 12)
        tc.Staff.workersByFarm[1] = tc.Staff.workersByFarm[1] or {}
        tc.Staff.workersByFarm[1][def.id] = worker
        return worker
    end

    -- The answer as the inbox gives it: the handler, then the message goes.
    function world:answer(message, actionKey)
        world.kinds.poaching.onAction(message.farmId, message, actionKey)
        tc.Inbox:removeMessage(message.id)
    end

    function world:expire(message)
        world.kinds.poaching.onExpire(message.farmId, message)
        tc.Inbox:removeMessage(message.id)
    end

    function world:passDays(days)
        local environment = g_currentMission.environment
        for _ = 1, days do
            environment.currentMonotonicDay = environment.currentMonotonicDay + 1
            tc.RandomEvents:advanceDueIncidents()
        end
    end

    return world, tc
end

local function poach(tc, worker)
    tc.Poaching.forcedWorkerId = worker.id
    local incident = tc.RandomEvents:triggerEvent(1, "poaching")
    tc.Poaching.forcedWorkerId = nil
    return incident
end

test("only March to May, and only with someone to approach", function()
    local world, tc = setup()
    local environment = g_currentMission.environment
    assertEquals(tc.Poaching:getRatePerPeriod(1), 0, "nobody on the roster")

    world:addWorker({ id = 1, hiredMonthsAgo = 2 })
    assertEquals(tc.Poaching:getRatePerPeriod(1), 0, "only just started")

    world:addWorker({ id = 2 })
    for period = 1, 12 do
        environment.currentPeriod = period
        local expected = period <= 3 and TheContractorPoaching.RATE_PER_PERIOD or 0
        assertEquals(tc.Poaching:getRatePerPeriod(1), expected, "period " .. period)
    end

    -- About a third of years, as four months at 0.1 was.
    local yearly = 1 - (1 - TheContractorPoaching.RATE_PER_PERIOD) ^ 3
    assertNear(yearly, 1 - 0.9 ^ 4, 0.01, "yearly odds")

    environment.currentPeriod = 2
    tc.Staff:getWorker(1, 2).leavesAtPeriod = TCCalendar.getPeriodIndex() + 1
    assertEquals(tc.Poaching:getRatePerPeriod(1), 0, "the only one is leaving")
end)

test("the most valuable are by far the likeliest, and one at a time", function()
    local world, tc = setup()
    world:addWorker({ id = 1, market = 2000 })
    world:addWorker({ id = 2, market = 4000 })

    -- Weights 4 : 16 of 20.
    local candidates = tc.Poaching:getCandidates(1)
    assertEquals(TheContractorPoaching.pickWeighted(candidates, 0.19).id, 1, "low roll")
    assertEquals(TheContractorPoaching.pickWeighted(candidates, 0.21).id, 2, "the rest")

    local data = tc.Poaching:pickTarget(1, 0.5, 0)
    assertEquals(data.workerId, 2)
    assertEquals(data.workerName, "Worker 2")
    assertTrue(string.find(data.rivalName, "%S+ %S+") ~= nil, data.rivalName)

    poach(tc, tc.Staff:getWorker(1, 2))
    assertEquals(#tc.Poaching:getCandidates(1), 1, "already approached")
    assertEquals(tc.Poaching:pickTarget(1, 0.99, 0).workerId, 1)
end)

test("the offer is 10-25% over the higher of pay and market value", function()
    local world = setup()
    local grown = world:addWorker({ id = 1, salary = 2000, market = 3000 })
    local generous = world:addWorker({ id = 2, salary = 3500, market = 3000 })

    assertEquals(TheContractorPoaching.getOffer(grown, 0), 3300, "grown on hiring pay: from market value")
    assertEquals(TheContractorPoaching.getOffer(grown, 1), 3750)
    assertEquals(TheContractorPoaching.getOffer(generous, 0), 3850, "paid above market: from pay")
end)

test("the stay chance follows morale and pay, within 0-25%", function()
    local world = setup()
    local worker = world:addWorker({ id = 1, salary = 2500, expected = 2500, morale = 50 })
    assertNear(TheContractorPoaching.getStayChance(worker), 0.05, 0.0001, "content, fairly paid")

    worker.morale = 100
    assertNear(TheContractorPoaching.getStayChance(worker), 0.20, 0.0001, "happy")

    worker.salary = 2750 -- 10% over: 5 beyond the tolerance
    assertNear(TheContractorPoaching.getStayChance(worker), 0.25, 0.0001, "happy and well paid")
    worker.salary = 4000
    assertNear(TheContractorPoaching.getStayChance(worker), 0.25, 0.0001, "capped")

    worker.morale = 20
    worker.salary = 2000 -- 20% under: 15 beyond
    assertEquals(TheContractorPoaching.getStayChance(worker), 0, "unhappy and underpaid")
end)

test("the offer arrives in the inbox and waits", function()
    local world, tc = setup()
    local worker = world:addWorker({ id = 1, name = "Amy Hall", salary = 2500, market = 3000, expected = 2800,
        morale = 80 })
    local incident = poach(tc, worker)

    assertEquals(incident.stage, "approached")
    assertEquals(incident.nextStageDay, 0, "waiting on the player")
    local message = world.messages[1]
    assertEquals(message.kind, "poaching")
    assertEquals(message.title, "Rival offer for Amy Hall")
    assertTrue(string.find(message.body, "their morale is happy.", 1, true) ~= nil, message.body)
    assertTrue(string.find(message.body, "2800", 1, true) == nil, "no expectation shown")
    assertTrue(string.find(message.body, tostring(incident.data.offer), 1, true) ~= nil, "offer shown")
    assertEquals(#message.actions, 2)
    assertEquals(message.expiresInDays, 10, "a month to answer")
    assertEquals(incident.data.messageId, message.id)

    local confirm = world.kinds.poaching.getConfirmText(message, "match")
    assertTrue(string.find(confirm, "Amy Hall", 1, true) ~= nil, confirm)
    assertEquals(world.kinds.poaching.getConfirmText(message, "nothing"), nil, "no confirm for doing nothing")
end)

test("matching raises their pay to the offer and keeps them", function()
    local world, tc = setup()
    local worker = world:addWorker({ id = 1, salary = 2500, market = 3000, morale = 60 })
    local incident = poach(tc, worker)
    local offer = incident.data.offer

    world:answer(world.messages[1], "match")
    assertEquals(worker.salary, offer, "pay")
    assertEquals(world.payNotices[1].notify, TheContractorPayReviews.NOTIFY.RISE)
    assertEquals(worker.morale, 65, "pleased")
    assertEquals(worker:isLeaving(), false)
    assertEquals(tc.RandomEvents:getIncident(incident.id), nil, "over")
end)

test("doing nothing: they think it over, then usually go", function()
    local world, tc = setup()
    local worker = world:addWorker({ id = 1, name = "Amy Hall" })
    local incident = poach(tc, worker)

    tc.Poaching.forcedStay = false
    world:answer(world.messages[1], "nothing")
    assertEquals(incident.stage, "decision")
    assertTrue(incident.nextStageDay > 100, "a day or two later")
    assertEquals(worker:isLeaving(), false, "not yet")

    world:passDays(3)
    assertEquals(tc.RandomEvents:getIncident(incident.id), nil, "over")
    assertTrue(worker:isLeaving(), "handed in their notice")
    assertTrue(worker.isQuitting, "a quit, not a retirement")
    assertEquals(worker.leavesAtPeriod, TCCalendar.getPeriodIndex() + 1, "a month's notice")
    assertEquals(world.messages[2].titleKey, "tc_poaching_leftTitle")
    assertEquals(worker.salary, 2500, "same pay")
end)

test("no answer is doing nothing, and some stay", function()
    local world, tc = setup()
    local worker = world:addWorker({ id = 1, name = "Amy Hall", morale = 100 })
    local incident = poach(tc, worker)

    tc.Poaching.forcedStay = true
    world:expire(world.messages[1])
    world:passDays(3)
    assertEquals(tc.RandomEvents:getIncident(incident.id), nil, "over")
    assertEquals(worker:isLeaving(), false, "stayed")
    assertEquals(world.messages[2].title, "Amy Hall is staying")
    assertEquals(tc.Poaching.forcedStay, nil, "used up")
end)

test("a worker who's gone or leaving ends the offer quietly", function()
    local world, tc = setup()
    local released = world:addWorker({ id = 1 })
    local incident = poach(tc, released)
    tc.Staff:releaseWorker(1, 1)
    assertEquals(tc.RandomEvents:getIncident(incident.id), nil, "closed")
    assertTrue(world.messages[1].removed, "message gone")

    local retiring = world:addWorker({ id = 2 })
    incident = poach(tc, retiring)
    tc.Staff:announceLeaving(1, 2, 2, false)
    world:answer(world.messages[2], "match")
    assertEquals(retiring.salary, 2500, "no rise for someone leaving anyway")
    assertEquals(tc.RandomEvents:getIncident(incident.id), nil, "closed")
    assertEquals(#world.messages, 2, "nothing more said")
end)

test("tcCompany event poaching picks a worker, tcCompany outcome poaching the decision", function()
    local world, tc = setup()
    world:addWorker({ id = 1, name = "Amy Hall", market = 1000, hiredMonthsAgo = 1 })
    world:addWorker({ id = 2, name = "Ben Ward", market = 9000 })
    TCConsole.reset()
    TheContractorRandomEvents.registerConsoleCommands()
    local group = TCConsole.groups.company

    local text = TCConsole.dispatch(group, { "event", "poaching", "amy" })
    assertTrue(string.find(text, "(poaching) opened", 1, true) ~= nil, text)
    assertEquals(world.messages[1].title, "Rival offer for Amy Hall", "the named worker, however new")
    assertEquals(tc.Poaching.forcedWorkerId, nil, "cleared")

    text = TCConsole.dispatch(group, { "event", "poaching", "amy" })
    assertTrue(string.find(text, "already has an offer", 1, true) ~= nil, text)
    text = TCConsole.dispatch(group, { "event", "poaching", "zed" })
    assertTrue(string.find(text, "no worker called", 1, true) ~= nil, text)

    text = TCConsole.dispatch(group, { "outcome", "poaching", "STAYS" })
    assertTrue(string.find(text, "stays", 1, true) ~= nil, text)
    assertEquals(tc.Poaching.forcedStay, true)
    text = TCConsole.dispatch(group, { "outcome", "poaching", "maybe" })
    assertTrue(string.find(text, "<stays|leaves>", 1, true) ~= nil, text)

    text = TCConsole.dispatch(group, { "event", "dieselTheft" })
    assertTrue(string.find(text, "no event type", 1, true) ~= nil, text)
end)
