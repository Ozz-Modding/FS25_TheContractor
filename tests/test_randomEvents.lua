-- TheContractorRandomEvents (068): monthly rates whatever the days per
-- period, stage delays in months, cooldowns, running incidents through
-- their stages, save/load and initial client state - against a dummy event
-- type, since the framework knows none of its own.

local function setup(daysPerPeriod)
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
        currentPeriod = 1,
        currentDayInPeriod = 1,
        daysPerPeriod = daysPerPeriod or 3,
        plannedDaysPerPeriod = daysPerPeriod or 3,
        currentMonotonicDay = 1,
    }
    g_farmManager.getFarmById = function(_, farmId)
        for _, farm in ipairs(world.farms) do
            if farm.farmId == farmId then
                return farm
            end
        end
        return nil
    end

    world:load("src/util/TCCalendar.lua")
    world:load("src/util/TCConsole.lua")
    world:load("src/business/Settings.lua")
    world:load("src/business/RandomEvents.lua")

    -- Captures what would go to clients.
    world.broadcasts = {}
    TCRandomEventIncidentEvent = {
        new = function(incident, isClosed)
            return { incident = incident, isClosed = isClosed }
        end,
    }
    g_server = {
        broadcastEvent = function(_, event)
            table.insert(world.broadcasts, event)
        end,
    }

    local tc = g_currentMission.TheContractor
    tc.Settings = TheContractorSettings.new()
    tc.Company = { companyNames = { [1] = "Test Farm Contracting" } }
    tc.RandomEvents = TheContractorRandomEvents.new()

    -- Moves the calendar on a day (a new month every daysPerPeriod days).
    function world:nextDay()
        local environment = g_currentMission.environment
        environment.currentMonotonicDay = environment.currentMonotonicDay + 1
        environment.currentDayInPeriod = environment.currentDayInPeriod + 1
        if environment.currentDayInPeriod > environment.daysPerPeriod then
            environment.currentDayInPeriod = 1
            environment.currentPeriod = environment.currentPeriod + 1
            if environment.currentPeriod > Environment.PERIODS_IN_YEAR then
                environment.currentPeriod = 1
                environment.currentYear = environment.currentYear + 1
            end
        end
    end

    return world, tc.RandomEvents
end

-- A dummy event: "found" -> (wait 0.5-1 month) "report" -> (no wait) "settle".
local function registerDummy(randomEvents, overrides)
    local log = {}
    local definition = {
        l10nKey = "tc_setting_randomEvents",
        ratePerPeriod = function(farmId)
            return 1
        end,
        canTrigger = function(farmId)
            return { value = 1000, name = "Tractor", recovered = false }
        end,
        cooldownPeriods = 12,
        stages = {
            { key = "found", run = function(incident)
                table.insert(log, "found")
            end },
            { key = "report", delayPeriods = { 0.5, 1 }, run = function(incident)
                table.insert(log, "report")
                incident.data.recovered = true
            end },
            { key = "settle", run = function(incident)
                table.insert(log, "settle")
            end },
        },
    }
    for key, value in pairs(overrides or {}) do
        definition[key] = value
    end
    randomEvents:registerEventType("dummy", definition)
    return log
end

-- Days until the incident's current stage runs.
local function runDays(world, randomEvents, days)
    for _ = 1, days do
        world:nextDay()
        randomEvents:advanceDueIncidents()
    end
end

test("a month carries the same odds at 1, 5 and 28 days per period", function()
    setup()
    for _, daysPerPeriod in ipairs({ 1, 5, 28 }) do
        local daily = TheContractorRandomEvents.getDailyChance(0.02, 1, daysPerPeriod)
        local monthly = 1 - (1 - daily) ^ daysPerPeriod
        assertNear(monthly, 0.02, 0.0005, daysPerPeriod .. " days a month")
    end
    assertEquals(TheContractorRandomEvents.getDailyChance(0.02, 0, 5), 0, "off")
    assertNear(TheContractorRandomEvents.getDailyChance(0.02, 0.5, 1), 0.01, 1e-9, "rare halves it")
end)

test("stage delays are months turned into days, never under a day", function()
    setup()
    local delay = { 0.5, 1 }
    assertEquals(TheContractorRandomEvents.getDelayDays(delay, 28, 0), 14, "28 days, shortest")
    assertEquals(TheContractorRandomEvents.getDelayDays(delay, 28, 1), 28, "28 days, longest")
    assertEquals(TheContractorRandomEvents.getDelayDays(delay, 1, 0), 1, "1 day, rounded up to a day")
    assertEquals(TheContractorRandomEvents.getDelayDays(delay, 1, 1), 1, "1 day, longest")
    assertEquals(TheContractorRandomEvents.getDelayDays({ 1, 2 }, 5, 0), 5, "a full month at 5 days")
    assertEquals(TheContractorRandomEvents.getDelayDays({ 0.1, 0.35 }, 3, 0), 1, "a short wait is still a day")
end)

test("an incident runs to its first wait, then on through the stages to the end", function()
    local world, randomEvents = setup(4)
    local log = registerDummy(randomEvents)

    local incident = randomEvents:triggerEvent(1, "dummy")
    assertEquals(incident.stage, "report", "waiting for the report")
    assertEquals(table.concat(log, ","), "found", "first stage ran at once")
    local wait = incident.nextStageDay - g_currentMission.environment.currentMonotonicDay
    assertTrue(wait >= 2 and wait <= 4, "half to one month at 4 days: " .. wait)
    assertEquals(#world.broadcasts, 1, "the wait was sent to clients")

    runDays(world, randomEvents, wait - 1)
    assertEquals(#log, 1, "not before its day")
    runDays(world, randomEvents, 1)
    assertEquals(table.concat(log, ","), "found,report,settle", "report then settle, with no wait between")
    assertEquals(randomEvents:getIncident(incident.id), nil, "closed after the last stage")
    assertTrue(world.broadcasts[#world.broadcasts].isClosed, "closing sent to clients")
    assertEquals(world.broadcasts[#world.broadcasts].incident.data.recovered, true, "with the stage's data")
end)

test("stage results: jump to a key, wait for goToStage, finish early", function()
    local world, randomEvents = setup(3)
    local log = {}
    randomEvents:registerEventType("branchy", {
        ratePerPeriod = function() return 1 end,
        canTrigger = function() return {} end,
        stages = {
            { key = "start", run = function() table.insert(log, "start") return "ask" end },
            { key = "skipped", run = function() table.insert(log, "skipped") end },
            { key = "ask", run = function() table.insert(log, "ask") return TheContractorRandomEvents.WAIT end },
            { key = "answered", delayPeriods = { 1, 1 }, run = function()
                table.insert(log, "answered")
                return TheContractorRandomEvents.DONE
            end },
            { key = "never", run = function() table.insert(log, "never") end },
        },
    })

    local incident = randomEvents:triggerEvent(1, "branchy")
    assertEquals(table.concat(log, ","), "start,ask", "jumped over 'skipped'")
    assertEquals(incident.stage, "ask", "waiting")
    assertEquals(incident.nextStageDay, 0, "no timer while waiting")

    runDays(world, randomEvents, 10)
    assertEquals(#log, 2, "a wait doesn't move on by itself")

    randomEvents:goToStage(incident, "answered")
    assertEquals(incident.nextStageDay, g_currentMission.environment.currentMonotonicDay + 3, "a month at 3 days")
    runDays(world, randomEvents, 3)
    assertEquals(table.concat(log, ","), "start,ask,answered", "done stops before 'never'")
    assertEquals(randomEvents:getIncident(incident.id), nil, "closed")
end)

test("stages that loop with no wait are cut off", function()
    local _, randomEvents = setup(3)
    randomEvents:registerEventType("loop", {
        canTrigger = function() return {} end,
        stages = {
            { key = "a", run = function() return "b" end },
            { key = "b", run = function() return "a" end },
        },
    })
    local incident = randomEvents:triggerEvent(1, "loop")
    assertEquals(randomEvents:getIncident(incident.id), nil, "closed")
    assertEquals(#randomEvents.eventTypeOrder, 1, "still registered")
end)

test("nothing to act on means no incident and no cooldown", function()
    local _, randomEvents = setup(3)
    registerDummy(randomEvents, { canTrigger = function() return nil end })
    assertEquals(randomEvents:triggerEvent(1, "dummy"), nil, "no incident")
    assertEquals(randomEvents:getCooldownLeft(1, "dummy"), 0, "no cooldown")
end)

test("the daily roll respects the cooldown, the setting and farms without a company", function()
    local world, randomEvents = setup(1)
    -- A rate of 1 a month at 1 day a month: a certain hit every roll.
    registerDummy(randomEvents)
    table.insert(world.farms, { farmId = 2 })

    randomEvents:rollNewEvents()
    assertEquals(#randomEvents:getIncidents(1), 1, "farm 1 rolled one")
    assertEquals(#randomEvents:getIncidents(2), 0, "farm 2 has no company")
    assertEquals(randomEvents:getCooldownLeft(1, "dummy"), 12, "a year's cooldown")

    -- Let it finish, then try again inside the cooldown.
    runDays(world, randomEvents, 2)
    assertEquals(#randomEvents:getIncidents(1), 0, "finished")
    randomEvents:rollNewEvents()
    assertEquals(#randomEvents:getIncidents(1), 0, "cooling down")

    -- After the cooldown, with the setting off.
    for _ = 1, 12 do
        world:nextDay()
    end
    assertEquals(randomEvents:getCooldownLeft(1, "dummy"), 0, "cooldown over")
    g_currentMission.TheContractor.Settings:set("randomEvents", 0)
    randomEvents:rollNewEvents()
    assertEquals(#randomEvents:getIncidents(1), 0, "off")

    g_currentMission.TheContractor.Settings:set("randomEvents", 1)
    randomEvents:rollNewEvents()
    assertEquals(#randomEvents:getIncidents(1), 1, "normal again")
end)

test("save and load keep incidents, their data and cooldowns", function()
    local _, randomEvents = setup(5)
    registerDummy(randomEvents)
    local incident = randomEvents:triggerEvent(1, "dummy")
    incident.data.amount = 1234.5
    incident.data[1] = "not a string key, not saved"

    local xmlFile = {}
    randomEvents:saveToXmlFile(xmlFile)

    local loaded = TheContractorRandomEvents.new()
    registerDummy(loaded)
    loaded:loadFromXMLFile(xmlFile)

    local copy = loaded:getIncident(incident.id)
    assertTrue(copy ~= nil, "incident loaded")
    assertEquals(copy.stage, "report", "stage")
    assertEquals(copy.nextStageDay, incident.nextStageDay, "next stage day")
    assertEquals(copy.data.name, "Tractor", "string")
    assertEquals(copy.data.amount, 1234.5, "number")
    assertEquals(copy.data.recovered, false, "boolean false survives")
    assertEquals(copy.data[1], nil, "number keys dropped")
    assertEquals(loaded:getCooldownLeft(1, "dummy"), 12, "cooldown")
    assertEquals(loaded.nextIncidentId, incident.id + 1, "ids carry on")
end)

test("a saved incident of an event type that's gone is dropped", function()
    local world, randomEvents = setup(5)
    registerDummy(randomEvents)
    randomEvents:triggerEvent(1, "dummy")

    local xmlFile = {}
    randomEvents:saveToXmlFile(xmlFile)

    local loaded = TheContractorRandomEvents.new()
    loaded:loadFromXMLFile(xmlFile)
    assertEquals(#loaded:getIncidents(1), 0, "dropped")
    assertEquals(#world.warnings, 1, "with a warning")
end)

test("a joining client gets the incidents and cooldowns", function()
    local world, randomEvents = setup(5)
    registerDummy(randomEvents)
    local incident = randomEvents:triggerEvent(1, "dummy")

    local stream = world:newStream()
    randomEvents:writeInitialClientState(stream)

    local client = TheContractorRandomEvents.new()
    client:readInitialClientState(stream)
    local copy = client:getIncident(incident.id)
    assertEquals(copy.stage, "report", "stage")
    assertEquals(copy.data.name, "Tractor", "data")
    assertEquals(copy.data.recovered, false, "boolean")
    assertEquals(client:getCooldownLeft(1, "dummy"), 0, "an unregistered type on the client has no cooldown length")
    assertEquals(client:getLastPeriod(1, "dummy"), 1, "but the opening period arrived")
end)

test("the console forces an event, and only a known one", function()
    local _, randomEvents = setup(5)
    registerDummy(randomEvents)
    TCConsole.reset()
    TheContractorRandomEvents.registerConsoleCommands()
    local group = TCConsole.groups.event

    g_farmManager.getFarmByUserId = function()
        return { farmId = 1 }
    end

    TCConsole.dispatch(group, { "trigger", "DUMMY" })
    assertEquals(#randomEvents:getIncidents(1), 1, "opened, whatever the case")
    assertEquals(randomEvents:getCooldownLeft(1, "dummy"), 12)
    TCConsole.dispatch(group, { "trigger", "nope" })
    TCConsole.dispatch(group, { "trigger" })
    assertEquals(#randomEvents:getIncidents(1), 1, "an unknown type or none opens nothing")
end)

-- Job events (074) ------------------------------------------------------------------

-- A job event type: canTrigger takes jobs on field 2 or up only, unless overridden.
local function registerJobEvent(randomEvents, key, overrides)
    local log = {}
    local definition = {
        chancePerJob = 0.1,
        minJobQuality = 75,
        cooldownPeriods = 2,
        canTrigger = function(farmId, job)
            if job.fieldId < 2 then
                return nil
            end
            return { jobId = job.id }
        end,
        stages = {
            { key = "announce", run = function(incident)
                table.insert(log, incident.data.jobId)
                return TheContractorRandomEvents.DONE
            end },
        },
    }
    for name, value in pairs(overrides or {}) do
        definition[name] = value
    end
    randomEvents:registerEventType(key, definition)
    return log
end

local function setupJobs(world)
    TheContractorJob = { STATE = { COMPLETED = "completed" } }
    world.jobs = {}
    g_currentMission.TheContractor.Jobs = {
        getJobsByState = function(_, farmId, state)
            local result = {}
            for _, job in ipairs(world.jobs) do
                if job.farmId == farmId and job.state == state then
                    table.insert(result, job)
                end
            end
            return result
        end,
    }
    function world:addCompletedJob(id, fieldId, qualityScore, completedAt)
        local job = { id = id, farmId = 1, fieldId = fieldId, qualityScore = qualityScore,
            completedAt = completedAt or id, state = "completed" }
        table.insert(self.jobs, job)
        return job
    end
end

-- A fake math.random: rolls (0-1) come from the list, picks take the first.
local function rolls(list)
    local index = 0
    return function(low, high)
        if low ~= nil then
            return low
        end
        index = index + 1
        return list[index] or 1
    end
end

test("a job event is rolled on completion, not daily", function()
    local world, randomEvents = setup(1)
    setupJobs(world)
    local log = registerJobEvent(randomEvents, "kettle")

    randomEvents:rollNewEvents()
    assertEquals(#randomEvents:getIncidents(1), 0, "never in the daily roll")

    local job = world:addCompletedJob(1, 5, 80)
    assertEquals(randomEvents:onJobCompleted(job, rolls({ 0.2 })), nil, "missed the 10% roll")
    local incident = randomEvents:onJobCompleted(job, rolls({ 0.05 }))
    assertTrue(incident ~= nil, "hit")
    assertEquals(log[1], 1, "for that job")
    assertEquals(randomEvents:getCooldownLeft(1, "kettle"), 2, "cooldown started")
    assertEquals(randomEvents:onJobCompleted(job, rolls({ 0 })), nil, "cooling down")
end)

test("a job event needs the quality score and the setting", function()
    local world, randomEvents = setup(1)
    setupJobs(world)
    registerJobEvent(randomEvents, "kettle")

    assertEquals(randomEvents:onJobCompleted(world:addCompletedJob(1, 5, 74), rolls({ 0 })), nil, "74% is too low")
    assertEquals(randomEvents:onJobCompleted(world:addCompletedJob(2, 5, nil), rolls({ 0 })), nil, "no score")

    g_currentMission.TheContractor.Settings:set("randomEvents", 0)
    assertEquals(randomEvents:onJobCompleted(world:addCompletedJob(3, 5, 100), rolls({ 0 })), nil, "off")

    g_currentMission.TheContractor.Settings:set("randomEvents", 0.5)
    assertNear(TheContractorRandomEvents.getJobChance(0.1, 0.5), 0.05, 1e-9, "rare halves it")
    assertEquals(randomEvents:onJobCompleted(world:addCompletedJob(4, 5, 75), rolls({ 0.07 })), nil,
        "0.07 misses at rare")
    assertTrue(randomEvents:onJobCompleted(world:addCompletedJob(5, 5, 75), rolls({ 0.04 })) ~= nil, "75% is enough")
end)

test("one job event per job, the next hit if the first has nothing to act on", function()
    local world, randomEvents = setup(1)
    setupJobs(world)
    local firstLog = registerJobEvent(randomEvents, "first", {
        canTrigger = function()
            return nil
        end,
    })
    local secondLog = registerJobEvent(randomEvents, "second")
    local thirdLog = registerJobEvent(randomEvents, "third")

    local incident = randomEvents:onJobCompleted(world:addCompletedJob(1, 5, 90), rolls({ 0, 0, 0 }))
    assertEquals(incident.eventType, "second", "first had nothing, so the next")
    assertEquals(#firstLog + #secondLog + #thirdLog, 1, "only one")
    assertEquals(randomEvents:getCooldownLeft(1, "first"), 0, "no cooldown for the one with nothing")
    assertEquals(randomEvents:getCooldownLeft(1, "third"), 0, "nor the one that didn't happen")
end)

test("forced with no job, a job event takes the latest completed job it can", function()
    local world, randomEvents = setup(1)
    setupJobs(world)
    local log = registerJobEvent(randomEvents, "kettle")
    world:addCompletedJob(1, 5, 50, 100)
    world:addCompletedJob(2, 1, 90, 300)
    world:addCompletedJob(3, 7, 90, 200)

    local incident = randomEvents:triggerEvent(1, "kettle")
    assertTrue(incident ~= nil, "found one")
    assertEquals(log[1], 3, "the latest canTrigger accepts (job 2's field is refused); quality isn't checked")

    world.jobs = {}
    assertEquals(randomEvents:triggerEvent(1, "kettle"), nil)
end)

-- Time of day (078) -------------------------------------------------------------

-- A certain-hit dummy held for 07:00-09:00, with no cooldown.
local function registerMorning(randomEvents)
    return registerDummy(randomEvents, { triggerHours = { 7, 9 }, cooldownPeriods = 0 })
end

test("a time-of-day window's roll lands on its start hour to the hour before its end", function()
    setup()
    assertEquals(TheContractorRandomEvents.getTriggerHour({ 7, 9 }, 0), 7, "start")
    assertEquals(TheContractorRandomEvents.getTriggerHour({ 7, 9 }, 0.49), 7, "first half")
    assertEquals(TheContractorRandomEvents.getTriggerHour({ 7, 9 }, 0.5), 8, "second half")
    assertEquals(TheContractorRandomEvents.getTriggerHour({ 7, 9 }, 1), 8, "never the end hour")
    assertEquals(TheContractorRandomEvents.getTriggerHour({ 7, 7 }, 0.5), 7, "an empty window is its start")
end)

test("a hit with a time of day waits for its hour, then happens once", function()
    local _, randomEvents = setup(1)
    local log = registerMorning(randomEvents)
    g_currentMission.environment.currentHour = 0

    randomEvents:rollNewEvents()
    assertEquals(#randomEvents:getIncidents(1), 0, "nothing at midnight")
    assertEquals(#randomEvents.pendingTriggers, 1, "held")
    local hour = randomEvents.pendingTriggers[1].hour
    assertTrue(hour == 7 or hour == 8, "due 07:00 or 08:00")

    randomEvents:rollNewEvents()
    assertEquals(#randomEvents.pendingTriggers, 1, "not rolled again while it's held")

    g_currentMission.environment.currentHour = hour - 1
    randomEvents:firePendingTriggers()
    assertEquals(#log, 0, "not before its hour")

    g_currentMission.environment.currentHour = hour
    randomEvents:firePendingTriggers()
    assertEquals(#log, 1, "happened")
    assertEquals(#randomEvents.pendingTriggers, 0, "no longer held")

    randomEvents:firePendingTriggers()
    assertEquals(#log, 1, "only once")
end)

test("a held event whose hour was skipped happens late, not never", function()
    local world, randomEvents = setup(1)
    local log = registerMorning(randomEvents)
    g_currentMission.environment.currentHour = 0
    randomEvents:rollNewEvents()

    -- Slept through the morning and into the next day.
    world:nextDay()
    g_currentMission.environment.currentHour = 1
    randomEvents:firePendingTriggers()
    assertEquals(#log, 1, "happened the next hour it could")
end)

test("a held event is dropped if the setting goes Off or the farm's company goes", function()
    local _, randomEvents = setup(1)
    local log = registerMorning(randomEvents)
    g_currentMission.environment.currentHour = 0
    randomEvents:rollNewEvents()
    g_currentMission.TheContractor.Settings:set("randomEvents", 0)
    g_currentMission.environment.currentHour = 9
    randomEvents:firePendingTriggers()
    assertEquals(#log, 0, "off")
    assertEquals(#randomEvents.pendingTriggers, 0, "dropped")

    g_currentMission.TheContractor.Settings:set("randomEvents", 1)
    g_currentMission.environment.currentHour = 0
    randomEvents:rollNewEvents()
    g_currentMission.TheContractor.Company.companyNames[1] = nil
    g_currentMission.environment.currentHour = 9
    randomEvents:firePendingTriggers()
    assertEquals(#log, 0, "no company")
    assertEquals(#randomEvents.pendingTriggers, 0, "dropped too")
end)

test("save and load keep a held event", function()
    local _, randomEvents = setup(1)
    registerMorning(randomEvents)
    g_currentMission.environment.currentHour = 0
    randomEvents:rollNewEvents()
    local held = randomEvents.pendingTriggers[1]

    local xmlFile = {}
    randomEvents:saveToXmlFile(xmlFile)

    local loaded = TheContractorRandomEvents.new()
    local log = registerMorning(loaded)
    loaded:loadFromXMLFile(xmlFile)
    assertEquals(#loaded.pendingTriggers, 1, "held")
    assertEquals(loaded.pendingTriggers[1].day, held.day, "day")
    assertEquals(loaded.pendingTriggers[1].hour, held.hour, "hour")

    g_currentMission.environment.currentHour = 9
    loaded:firePendingTriggers()
    assertEquals(#log, 1, "happens after the load")

    local orphaned = TheContractorRandomEvents.new()
    orphaned:loadFromXMLFile(xmlFile)
    assertEquals(#orphaned.pendingTriggers, 0, "an event type that's gone is dropped")
end)

test("forcing an event ignores its time of day", function()
    local _, randomEvents = setup(1)
    local log = registerMorning(randomEvents)
    g_currentMission.environment.currentHour = 2
    assertTrue(randomEvents:triggerEvent(1, "dummy") ~= nil, "opened")
    assertEquals(#log, 1, "now")
end)

-- After bad weather (107) -----------------------------------------------------------------

-- A dummy event rolled after bad weather: chancePerStorm, found 07:00-08:59.
local function registerStorm(randomEvents, chance, cooldownPeriods)
    return registerDummy(randomEvents, {
        ratePerPeriod = nil,
        chancePerStorm = chance or 1,
        triggerHours = { 7, 9 },
        cooldownPeriods = cooldownPeriods or 0,
    })
end

local function setWeather(weatherType)
    WeatherType = { SUN = 1, PARTIALLY_CLOUDY = 2, CLOUDY = 3, RAIN = 4, SNOW = 5, HAIL = 6, TWISTER = 7, THUNDER = 8 }
    local weather = g_currentMission.environment.weather or { forecastItems = { {} } }
    weather.type = WeatherType[weatherType]
    function weather:getCurrentWeatherType() return self.type end
    g_currentMission.environment.weather = weather
end

test("anything but sun or cloud is bad weather", function()
    setup()
    setWeather("SUN")
    for name, isBad in pairs({ SUN = false, PARTIALLY_CLOUDY = false, CLOUDY = false, RAIN = true, SNOW = true,
        HAIL = true, TWISTER = true, THUNDER = true }) do
        assertEquals(TheContractorRandomEvents.isBadWeatherType(WeatherType[name]), isBad, name)
    end
    assertEquals(TheContractorRandomEvents.isBadWeatherType(nil), false)
end)

test("rolled once as a spell of bad weather ends, not while it lasts or in fine weather", function()
    local _, randomEvents = setup(5)
    registerStorm(randomEvents)
    g_currentMission.environment.currentHour = 20

    setWeather("SUN")
    randomEvents:checkWeather()
    randomEvents:checkWeather()
    assertEquals(#randomEvents.pendingTriggers, 0, "fine weather")

    setWeather("RAIN")
    randomEvents:checkWeather()
    setWeather("THUNDER")
    randomEvents:checkWeather()
    assertEquals(#randomEvents.pendingTriggers, 0, "still going")

    setWeather("CLOUDY")
    randomEvents:checkWeather()
    assertEquals(#randomEvents.pendingTriggers, 1, "it's over")
    randomEvents:checkWeather()
    assertEquals(#randomEvents.pendingTriggers, 1, "only once")

    -- A load in clear weather: nothing to end.
    local loaded = TheContractorRandomEvents.new()
    registerStorm(loaded)
    loaded:checkWeather()
    assertEquals(#loaded.pendingTriggers, 0)

    -- No weather to read: nothing.
    g_currentMission.environment.weather = nil
    randomEvents.wasBadWeather = true
    randomEvents:checkWeather()
    assertEquals(randomEvents.wasBadWeather, true, "left as it was")
end)

test("found the next hour if it clears in the morning, else the next morning", function()
    setup()
    local hours = { 7, 9 }
    local day, hour = TheContractorRandomEvents.getStormFoundAt(10, 3, hours, 0)
    assertEquals(day, 10, "before dawn: this morning")
    assertEquals(hour, 7)
    day, hour = TheContractorRandomEvents.getStormFoundAt(10, 10, hours, 0)
    assertEquals(day, 10, "mid-morning: the next hour")
    assertEquals(hour, 11)
    day, hour = TheContractorRandomEvents.getStormFoundAt(10, 13, hours, 0)
    assertEquals(hour, 14)
    day, hour = TheContractorRandomEvents.getStormFoundAt(10, 14, hours, 0.99)
    assertEquals(day, 11, "afternoon: tomorrow morning")
    assertEquals(hour, 8)
    day, hour = TheContractorRandomEvents.getStormFoundAt(10, 23, nil, 0)
    assertEquals(day, 11, "without a window, STORM_FOUND_HOURS")
    assertEquals(hour, 7)
end)

test("the chance per spell follows the setting and the cooldown, and a held one isn't rolled again", function()
    local world, randomEvents = setup(5)
    local log = registerStorm(randomEvents, 0.5, 2)
    g_currentMission.environment.currentHour = 20

    randomEvents:onBadWeatherEnded(function() return 0.6 end)
    assertEquals(#randomEvents.pendingTriggers, 0, "missed at 50%")
    g_currentMission.TheContractor.Settings:set("randomEvents", 0.5)
    randomEvents:onBadWeatherEnded(function() return 0.3 end)
    assertEquals(#randomEvents.pendingTriggers, 0, "rare: 25%")
    randomEvents:onBadWeatherEnded(function() return 0.2 end)
    assertEquals(#randomEvents.pendingTriggers, 1)
    randomEvents:onBadWeatherEnded(function() return 0 end)
    assertEquals(#randomEvents.pendingTriggers, 1, "already held")

    -- It happens the next morning, and then cools down.
    world:nextDay()
    g_currentMission.environment.currentHour = 9
    randomEvents:firePendingTriggers()
    assertEquals(#log, 1)
    randomEvents:onBadWeatherEnded(function() return 0 end)
    assertEquals(#randomEvents.pendingTriggers, 0, "cooling down")

    g_currentMission.TheContractor.Settings:set("randomEvents", 0)
    randomEvents.lastPeriodByFarm = {}
    randomEvents:onBadWeatherEnded(function() return 0 end)
    assertEquals(#randomEvents.pendingTriggers, 0, "off")
end)

test("an event after bad weather isn't rolled daily, and tcEvent list says how it comes", function()
    local _, randomEvents = setup(5)
    local log = registerStorm(randomEvents, 0.15)
    for _ = 1, 50 do
        randomEvents:rollNewEvents()
    end
    assertEquals(#log + #randomEvents.pendingTriggers, 0, "never from the daily roll")
end)
