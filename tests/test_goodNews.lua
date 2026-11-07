-- Good news (073) on the real random events framework (068): reputation
-- rewards in proportion to the farm's tier, cash rewards following the job
-- pay setting, no story twice in a row (across a save too), nothing before
-- the farm's first completed job, and every story's texts.

local function setup(options)
    options = options or {}
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    world.texts.ui_on = "On"
    world.texts.ui_off = "Off"
    for month = 1, 12 do
        world.texts["ui_month" .. month] = "Month " .. month
    end

    Environment = { PERIODS_IN_YEAR = 12 }
    g_currentMission.environment = {
        currentYear = 1,
        currentPeriod = 5,
        currentDayInPeriod = 1,
        daysPerPeriod = 3,
        plannedDaysPerPeriod = 3,
        currentMonotonicDay = 40,
        getPeriodFromDay = function()
            return 5
        end,
    }
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    TheContractorJob = { STATE = { COMPLETED = "completed" } }

    world:load("src/util/TCCalendar.lua")
    world:load("src/util/TCConsole.lua")
    world:load("src/business/Settings.lua")
    world:load("src/business/Reputation.lua")
    world:load("src/business/RandomEvents.lua")
    world:load("src/business/GoodNews.lua")

    TCRandomEventIncidentEvent = {
        new = function(incident, isClosed)
            return { incident = incident, isClosed = isClosed }
        end,
    }

    local tc = g_currentMission.TheContractor
    tc.Settings = TheContractorSettings.new()
    if options.jobPayRate ~= nil then
        tc.Settings:set("jobPayRate", options.jobPayRate)
    end
    tc.Company = { companyNames = { [1] = "Test Contracting" } }
    tc.Reputation = TheContractorReputation.new()

    world.completedJobs = options.completedJobs or 1
    -- 141: attend-the-auction jobs done, which aren't work.
    world.attendedAuctions = 0
    tc.Jobs = {
        getJobsByState = function(_, farmId, state)
            local jobs = {}
            if state == TheContractorJob.STATE.COMPLETED then
                for i = 1, world.completedJobs do
                    table.insert(jobs, { id = i, farmId = farmId })
                end
                for i = 1, world.attendedAuctions do
                    table.insert(jobs, { id = 100 + i, farmId = farmId, noConsequences = true })
                end
            end
            return jobs
        end,
    }
    TheContractorJobs = { hasNoConsequences = function(job) return job.noConsequences == true end }

    world.money = {}
    g_currentMission.addMoney = function(_, amount, farmId, moneyType)
        table.insert(world.money, { amount = amount, farmId = farmId, moneyType = moneyType })
    end
    world.recorded = {}
    tc.Finances = {
        recordGoodNews = function(_, farmId, amount)
            table.insert(world.recorded, { farmId = farmId, amount = amount })
        end,
    }

    world.messages = {}
    tc.Inbox = {
        registerMessageKind = function(_, kind, definition)
            world.kind = { kind = kind, definition = definition }
        end,
        postMessage = function(_, farmId, kind, titleKey, bodyKey, args)
            -- Rendered as the client would, so a broken text fails here.
            local resolved = {}
            for i, arg in ipairs(args) do
                if type(arg) == "string" and string.sub(arg, 1, 7) == "$money_" then
                    resolved[i] = string.sub(arg, 8)
                else
                    resolved[i] = arg
                end
            end
            table.insert(world.messages, { farmId = farmId, kind = kind, titleKey = titleKey, args = args,
                title = g_i18n:getText(titleKey), body = string.format(g_i18n:getText(bodyKey), unpack(resolved)) })
            return #world.messages
        end,
    }

    tc.RandomEvents = TheContractorRandomEvents.new()
    tc.GoodNews = TheContractorGoodNews.new()
    tc.GoodNews:register(tc.RandomEvents, tc.Inbox)
    return world, tc
end

local function announce(tc, storyKey)
    tc.GoodNews.forcedStory = storyKey
    local incident = tc.RandomEvents:triggerEvent(1, "goodNews")
    tc.GoodNews.forcedStory = nil
    return incident
end

test("registered as a random event with its own inbox kind", function()
    local world, tc = setup()
    local definition = tc.RandomEvents:getEventType("goodNews")
    assertTrue(definition ~= nil)
    assertEquals(definition.cooldownPeriods, 3)
    assertNear(definition.ratePerPeriod(1), 0.1, 1e-9)
    assertEquals(world.kind.kind, "goodNews")
    assertEquals(world.kind.definition.chipTone, "good")
    assertEquals(FinanceStats.statNameToIndex.tcGoodNews, 1)
    assertEquals(MoneyType.TC_GOOD_NEWS, "tcGoodNews")
end)

test("every story has exactly one reward and both texts", function()
    local world = setup()
    for _, story in ipairs(TheContractorGoodNews.STORIES) do
        assertTrue((story.reputation ~= nil) ~= (story.money ~= nil), story.key .. ": one reward")
        local prefix = "tc_goodNews_" .. story.key
        assertTrue(world.texts[prefix .. "_title"] ~= nil, prefix .. "_title")
        local body = world.texts[prefix .. "_body"]
        assertTrue(body ~= nil, prefix .. "_body")
        local _, count = string.gsub(body, "%%s", "")
        assertEquals(count, 1, prefix .. "_body has one %s")
    end
end)

test("reputation rewards follow the farm's tier", function()
    local _, tc = setup()
    -- unknownContractor: 3 ha a job, 8 rep/ha.
    assertEquals(TheContractorGoodNews.getReputationReward(1, 0.5), 12)
    tc.Reputation.scores[1] = 200
    -- establishedContractor: 8 ha.
    assertEquals(TheContractorGoodNews.getReputationReward(1, 0.5), 32)
    tc.Reputation.scores[1] = 9000
    -- prestigiousContractor has no field size: the last tier with one (30 ha).
    assertEquals(TheContractorGoodNews.getReputationReward(1, 0.5), 120)
    -- Never nothing.
    tc.Reputation.scores[1] = 0
    assertEquals(TheContractorGoodNews.getReputationReward(1, 0.01), 1)
end)

test("a reputation story adds reputation and posts the message", function()
    local world, tc = setup()
    local incident = announce(tc, "parishNews")
    assertTrue(incident ~= nil)
    assertEquals(tc.RandomEvents:getIncident(incident.id), nil, "over at once")
    assertEquals(tc.Reputation:getReputationScore(1), 12)
    assertEquals(#world.money, 0, "no money")
    assertEquals(#world.messages, 1)
    assertEquals(world.messages[1].kind, "goodNews")
    assertEquals(world.messages[1].titleKey, "tc_goodNews_parishNews_title")
    assertEquals(world.messages[1].args[1], 12, "the reputation gained")
    assertEquals(tc.RandomEvents:getCooldownLeft(1, "goodNews"), 3)
end)

test("a cash story pays the scaled amount and records it", function()
    local world, tc = setup()
    announce(tc, "supplierRefund")
    local expected = math.floor(400 * TheContractorSettings.COST_BASELINE / 10) * 10
    assertEquals(#world.money, 1)
    assertEquals(world.money[1].amount, expected)
    assertEquals(world.money[1].moneyType, "tcGoodNews")
    assertEquals(world.recorded[1].amount, expected)
    assertEquals(tc.Reputation:getReputationScore(1), 0, "no reputation")
    assertEquals(world.messages[1].args[1], "$money_" .. expected, "the amount paid")
end)

test("cash follows the job pay setting", function()
    local world, tc = setup({ jobPayRate = 50 })
    announce(tc, "loyaltyRebate")
    assertEquals(world.money[1].amount, math.floor(tc.Settings:scaleCost(250) / 10) * 10)
    assertTrue(world.money[1].amount < 250 * TheContractorSettings.COST_BASELINE)
end)

test("nothing before the farm's first completed job", function()
    local world, tc = setup({ completedJobs = 0 })
    assertEquals(tc.GoodNews:pickStory(1), nil)
    assertEquals(tc.RandomEvents:triggerEvent(1, "goodNews"), nil)
    world.completedJobs = 1
    assertTrue(tc.GoodNews:pickStory(1) ~= nil)
end)

test("going to an auction (141) isn't a first completed job", function()
    local world, tc = setup({ completedJobs = 0 })
    world.attendedAuctions = 1
    assertEquals(tc.GoodNews:pickStory(1), nil)
end)

test("never the same story twice in a row", function()
    local _, tc = setup()
    for _ = 1, 50 do
        local data = tc.GoodNews:pickStory(1)
        assertTrue(data.story ~= tc.GoodNews.lastStoryByFarm[1], "repeated " .. data.story)
        tc.RandomEvents:triggerEvent(1, "goodNews")
    end
    assertEquals(TheContractorGoodNews.chooseStory("photoPosted", function() return 1 end).key, "parishNews")
end)

test("the last story survives a save and load", function()
    local _, tc = setup()
    announce(tc, "ratesRefund")
    local xmlFile = {}
    tc.GoodNews:saveToXmlFile(xmlFile)

    local loaded = TheContractorGoodNews.new()
    loaded:loadFromXMLFile(xmlFile)
    assertEquals(loaded.lastStoryByFarm[1], "ratesRefund")
end)

test("tcCompany event goodNews forces a story, or says which there are", function()
    local world, tc = setup({ completedJobs = 0 })
    TCConsole.reset()
    TheContractorRandomEvents.registerConsoleCommands()
    local command = TCConsole.groups.company.subcommands.event
    command.run(1, { "goodNews", "PARISHCOUNCIL" })
    assertEquals(world.messages[1].titleKey, "tc_goodNews_parishCouncil_title", "that story, whatever the case")
    assertEquals(tc.GoodNews.forcedStory, nil, "cleared")

    command.run(1, { "goodNews", "nope" })
    assertEquals(#world.messages, 1, "no such story: nothing opened")

    -- No story: a random one, even before the first completed job.
    tc.RandomEvents.lastPeriodByFarm = {}
    command.run(1, { "goodNews" })
    assertEquals(#world.messages, 2, "random story")
    assertEquals(tc.GoodNews.forcedStory, nil, "cleared again")
end)
