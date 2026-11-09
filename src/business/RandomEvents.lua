-- Random events (068): rare things that happen to the business - a vehicle
-- stolen (069), and whatever comes later. This file knows nothing about any
-- one event. An event type registers itself on every machine at load:
--
--   tc.RandomEvents:registerEventType("theft", {
--       l10nKey = "tc_randomEvent_theft",          -- its name, for lists
--       ratePerPeriod = function(farmId) ... end,  -- expected events a month (before the setting)
--       canTrigger = function(farmId) ... end,     -- -> the incident's starting data, or nil
--       cooldownPeriods = 12,                      -- no repeat on this farm for this many months
--       peril = "theft",                           -- optional: what insurance must cover (070)
--       stages = {
--           { key = "stolen", run = function(incident) ... end },
--           { key = "policeReport", delayPeriods = { 0.1, 0.35 }, run = function(incident) ... end },
--       },
--   })
--
-- Rates are per month, not per day or year: the server's daily roll is
-- ratePerPeriod * the setting's multiplier / days per period, so a month
-- carries the same odds at 1 day per period as at 28. A hit asks canTrigger
-- for something to act on (069 picks the vehicle there); nil means no event.
--
-- A triggered event becomes an incident: { id, farmId, eventType, stage,
-- nextStageDay, openedPeriod, data }. data is the event type's own, a flat
-- table of number/string/boolean values (canTrigger's return value to start
-- with), saved and synced as it is. The incident runs through the stages in
-- order. A stage with delayPeriods waits that long first - written in months
-- and turned into days when the stage is entered (at least 1), so waits scale
-- with days per period like the rates do. A stage's run(incident) returns:
--   nil         the next stage in the list (none left: the incident ends)
--   "<key>"     that stage
--   "done"      the incident ends
--   "wait"      stay on this stage with no timer, until something calls
--               goToStage (an inbox action, say)
-- Inbox messages, notices and money are the event type's business, from its
-- stages; the framework posts nothing itself.
--
-- Job events (074): an event type with chancePerJob (a number, 0-1, or a
-- function(farmId, job) returning one, for odds that depend on the job, 081)
-- instead of ratePerPeriod isn't rolled daily. It's rolled when one of the farm's
-- jobs completes (Jobs:completeJob -> onJobCompleted), and canTrigger gets
-- the job as well: canTrigger(farmId, job). An optional minJobQuality
-- (0-100) skips jobs with a lower quality score. The setting's multiplier
-- and the cooldown apply as for daily events, and at most one job event
-- happens per completed job. Forced from the console (no job), the farm's
-- latest completed job that canTrigger accepts is used.
--
-- Time of day (078): an event type with triggerHours = { startHour, endHour }
-- is still rolled at the day change, but a hit doesn't trigger then. It's
-- held as a pending trigger for a random hour from startHour to endHour - 1
-- that day, and the hourly tick triggers it once that hour has come (late
-- rather than never, if the hour was skipped). While one is pending, that
-- type isn't rolled again on that farm. Pending triggers are server-only
-- and saved. The console's tcEvent trigger ignores the window.
--
-- After bad weather (107): an event type with chancePerStorm (0-1) instead
-- of ratePerPeriod is rolled once at the end of each spell of bad weather
-- (anything but sun or cloud: rain, snow, hail, thunder, a twister), read
-- from vanilla's weather every hour on the server. A hit is held as a
-- pending trigger (below) for when it's found: the next hour if the weather
-- clears during the morning, else in the event's triggerHours window
-- (STORM_FOUND_HOURS without one) that morning or the next. The setting's
-- multiplier and the cooldown apply, as for daily events.
--
-- Console (083): an optional console = { ... } on the definition, all
-- server-side:
--   details = "[field|road]"         what tcEvent trigger <type> takes after
--                                    the type, as usage text: tcEvent list and
--                                    trigger's own list show it, so every
--                                    type's options can be found in game
--   prepareTrigger(farmId, details, context)  tcEvent trigger <type>
--                                    [details]: sets up what the next trigger
--                                    acts on (a worker, a story, the spot in
--                                    front of the typing player: TCConsole's
--                                    context) and returns nil, or an error to
--                                    print
--   clearTrigger()                   after that trigger, whatever happened
--   outcomes = { "yes", "no" }       tcDebug outcome <type> <outcome>: the
--   setOutcome(outcome)              outcomes there are, and forcing one for the
--                                    next incident (returns the text to print)
-- so no event type needs a subcommand of its own.
--
-- Server: rolls, runs stages, saves. Every machine: holds the incidents and
-- each farm's cooldowns (TCRandomEventIncidentEvent, initial client state),
-- so menus can show them later.

TheContractorRandomEvents = {}
TheContractorRandomEvents_mt = Class(TheContractorRandomEvents)

TheContractorRandomEvents.DONE = "done"
TheContractorRandomEvents.WAIT = "wait"

-- Guards against stages that send each other round in a loop with no delay.
TheContractorRandomEvents.MAX_STAGES_PER_STEP = 20

-- 107: when an event after bad weather is found (see the header). The
-- weather clearing before STORM_SAME_DAY_UNTIL (and after the window's
-- start) finds it the next hour; any later, the next morning.
TheContractorRandomEvents.STORM_FOUND_HOURS = { 7, 9 }
TheContractorRandomEvents.STORM_SAME_DAY_UNTIL = 14

TheContractorRandomEvents.VALUE_TYPE = {
    NUMBER = 1,
    STRING = 2,
    BOOLEAN = 3,
}

function TheContractorRandomEvents.new()
    local self = {}
    setmetatable(self, TheContractorRandomEvents_mt)

    -- eventTypes[key] = definition; eventTypeOrder = { key, ... } (registration order).
    self.eventTypes = {}
    self.eventTypeOrder = {}

    -- incidents[id] = incident.
    self.incidents = {}
    self.nextIncidentId = 1

    -- lastPeriodByFarm[farmId][eventType] = the period index an incident of
    -- that type last opened on that farm.
    self.lastPeriodByFarm = {}

    -- Rolled events waiting for their hour (triggerHours, 078): { farmId,
    -- eventType, day, hour }, oldest first. Server-only.
    self.pendingTriggers = {}

    -- 107: whether the weather was bad at the last hourly look, nil before
    -- the first. Server-only, not saved: a load during a spell of bad
    -- weather starts watching it afresh.
    self.wasBadWeather = nil

    return self
end

-- Registration ------------------------------------------------------------------

function TheContractorRandomEvents:registerEventType(key, definition)
    if self.eventTypes[key] == nil then
        table.insert(self.eventTypeOrder, key)
    end
    definition.key = key
    definition.stages = definition.stages or {}
    definition.cooldownPeriods = definition.cooldownPeriods or 0
    self.eventTypes[key] = definition
end

function TheContractorRandomEvents:getEventType(key)
    return self.eventTypes[key]
end

function TheContractorRandomEvents:getEventTypeKeys()
    return self.eventTypeOrder
end

local function getStageIndex(definition, stageKey)
    for i, stage in ipairs(definition.stages) do
        if stage.key == stageKey then
            return i
        end
    end
    return nil
end

-- Reading -----------------------------------------------------------------------

function TheContractorRandomEvents:getIncident(id)
    return self.incidents[id]
end

-- A farm's open incidents, oldest first.
function TheContractorRandomEvents:getIncidents(farmId)
    local result = {}
    for _, incident in pairs(self.incidents) do
        if incident.farmId == farmId then
            table.insert(result, incident)
        end
    end
    table.sort(result, function(a, b)
        return a.id < b.id
    end)
    return result
end

function TheContractorRandomEvents:getLastPeriod(farmId, key)
    local farmPeriods = self.lastPeriodByFarm[farmId]
    return farmPeriods ~= nil and farmPeriods[key] or nil
end

-- Months left before this type can happen again on this farm (0 = it can).
function TheContractorRandomEvents:getCooldownLeft(farmId, key)
    local definition = self.eventTypes[key]
    local lastPeriod = self:getLastPeriod(farmId, key)
    if definition == nil or lastPeriod == nil then
        return 0
    end
    return math.max(0, lastPeriod + definition.cooldownPeriods - TCCalendar.getPeriodIndex())
end

-- The setting's multiplier: 0 (off), 0.5 (rare) or 1 (normal).
function TheContractorRandomEvents.getRateMultiplier()
    local settings = g_currentMission.TheContractor.Settings
    return settings ~= nil and settings:get("randomEvents") or 1
end

-- Today's chance of this type on this farm: a month's rate spread over the
-- month's days.
function TheContractorRandomEvents.getDailyChance(ratePerPeriod, multiplier, daysPerPeriod)
    return math.min(1, math.max(0, ratePerPeriod * multiplier / math.max(1, daysPerPeriod)))
end

-- A stage's wait in days: delayPeriods { min, max } months at daysPerPeriod,
-- roll (0-1) picking within the range, never under a day.
function TheContractorRandomEvents.getDelayDays(delayPeriods, daysPerPeriod, roll)
    local minPeriods = delayPeriods[1] or 0
    local maxPeriods = delayPeriods[2] or minPeriods
    local periods = minPeriods + (maxPeriods - minPeriods) * roll
    return math.max(1, math.floor(periods * daysPerPeriod + 0.5))
end

local function getToday()
    return g_currentMission.environment.currentMonotonicDay
end

local function getDaysPerPeriod()
    return TCCalendar.getDaysPerPeriodOn(getToday())
end

local function getCurrentHour()
    return g_currentMission.environment.currentHour or 0
end

-- Rolling (server) ----------------------------------------------------------------

function TheContractorRandomEvents:startDailyTick()
    if not g_currentMission:getIsServer() then
        return
    end
    g_messageCenter:subscribe(MessageType.DAY_CHANGED, self.onDayChanged, self)
    g_messageCenter:subscribe(MessageType.HOUR_CHANGED, self.onHourChanged, self)
end

function TheContractorRandomEvents:stopDailyTick()
    g_messageCenter:unsubscribe(MessageType.DAY_CHANGED, self)
    g_messageCenter:unsubscribe(MessageType.HOUR_CHANGED, self)
end

function TheContractorRandomEvents:onHourChanged()
    self:checkWeather()
    self:firePendingTriggers()
end

function TheContractorRandomEvents:onDayChanged()
    self:advanceDueIncidents()
    self:rollNewEvents()
end

function TheContractorRandomEvents:getCompanyFarmIds()
    local farmIds = {}
    for farmId in pairs(g_currentMission.TheContractor.Company.companyNames) do
        table.insert(farmIds, farmId)
    end
    table.sort(farmIds)
    return farmIds
end

function TheContractorRandomEvents:rollNewEvents()
    local multiplier = TheContractorRandomEvents.getRateMultiplier()
    if multiplier <= 0 then
        return
    end

    local daysPerPeriod = getDaysPerPeriod()
    for _, farmId in ipairs(self:getCompanyFarmIds()) do
        for _, key in ipairs(self.eventTypeOrder) do
            local definition = self.eventTypes[key]
            -- 107: one after bad weather is rolled as the weather clears.
            if self:getCooldownLeft(farmId, key) == 0 and not self:hasPendingTrigger(farmId, key) and
                    not TheContractorRandomEvents.isStormEvent(definition) then
                local rate = definition.ratePerPeriod ~= nil and definition.ratePerPeriod(farmId) or 0
                local chance = TheContractorRandomEvents.getDailyChance(rate, multiplier, daysPerPeriod)
                if chance > 0 and math.random() < chance then
                    if definition.triggerHours ~= nil then
                        local pending = self:addPendingTrigger(farmId, key, math.random())
                        TCLog.info("TheContractor: farm %d random event '%s' rolled (%.4f a day), due at %02d:00",
                            farmId, key, chance, pending.hour)
                    else
                        local incident = self:triggerEvent(farmId, key)
                        TCLog.info("TheContractor: farm %d random event '%s' rolled (%.4f a day)%s", farmId, key,
                            chance, incident == nil and ", but nothing to act on" or "")
                    end
                end
            end
        end
    end
end

-- Time of day (server, 078) ---------------------------------------------------------

-- The hour a triggerHours window's roll (0-1) lands on: startHour to
-- endHour - 1.
function TheContractorRandomEvents.getTriggerHour(triggerHours, roll)
    local startHour = triggerHours[1] or 0
    local endHour = math.max(startHour + 1, triggerHours[2] or startHour + 1)
    return math.min(endHour - 1, startHour + math.floor(roll * (endHour - startHour)))
end

function TheContractorRandomEvents:hasPendingTrigger(farmId, key)
    for _, pending in ipairs(self.pendingTriggers) do
        if pending.farmId == farmId and pending.eventType == key then
            return true
        end
    end
    return false
end

-- Holds a rolled event until its hour today. roll (0-1) picks the hour.
-- day and hour (107) set when instead.
function TheContractorRandomEvents:addPendingTrigger(farmId, key, roll, day, hour)
    local pending = {
        farmId = farmId,
        eventType = key,
        day = day or getToday(),
        hour = hour or TheContractorRandomEvents.getTriggerHour(self.eventTypes[key].triggerHours, roll),
    }
    table.insert(self.pendingTriggers, pending)
    return pending
end

-- Triggers every pending event whose hour has come (or gone: an hour
-- skipped, or a day change in between). One whose farm no longer has a
-- company, whose type has gone, or with the setting now Off is dropped.
function TheContractorRandomEvents:firePendingTriggers()
    if #self.pendingTriggers == 0 then
        return
    end
    local today, hour = getToday(), getCurrentHour()
    local companyNames = g_currentMission.TheContractor.Company.companyNames
    local isOff = TheContractorRandomEvents.getRateMultiplier() <= 0

    local due, waiting = {}, {}
    for _, pending in ipairs(self.pendingTriggers) do
        if today > pending.day or (today == pending.day and hour >= pending.hour) then
            table.insert(due, pending)
        else
            table.insert(waiting, pending)
        end
    end
    self.pendingTriggers = waiting

    for _, pending in ipairs(due) do
        if companyNames[pending.farmId] ~= nil and self.eventTypes[pending.eventType] ~= nil and not isOff then
            local incident = self:triggerEvent(pending.farmId, pending.eventType)
            TCLog.info("TheContractor: farm %d random event '%s' due at %02d:00 triggered%s", pending.farmId,
                pending.eventType, pending.hour, incident == nil and ", but nothing to act on" or "")
        end
    end
end

-- After bad weather (server, 107) ---------------------------------------------------

function TheContractorRandomEvents.isStormEvent(definition)
    return definition.chancePerStorm ~= nil
end

-- Anything but sun or cloud is bad weather (WeatherType: rain, snow, hail,
-- a twister, thunder).
function TheContractorRandomEvents.isBadWeatherType(weatherType)
    return weatherType ~= nil and weatherType ~= WeatherType.SUN and weatherType ~= WeatherType.PARTIALLY_CLOUDY and
        weatherType ~= WeatherType.CLOUDY
end

-- The weather type now, or nil if vanilla's weather can't say.
function TheContractorRandomEvents.getCurrentWeatherType()
    local environment = g_currentMission.environment
    local weather = environment ~= nil and environment.weather or nil
    if weather == nil or weather.getCurrentWeatherType == nil or weather.forecastItems == nil or
            #weather.forecastItems == 0 then
        return nil
    end
    return weather:getCurrentWeatherType()
end

-- When an event after bad weather that cleared at hour (today) is found:
-- day, hour. roll (0-1) picks the hour in the window.
function TheContractorRandomEvents.getStormFoundAt(today, hour, foundHours, roll)
    local T = TheContractorRandomEvents
    foundHours = foundHours or T.STORM_FOUND_HOURS
    if hour < foundHours[1] then
        return today, T.getTriggerHour(foundHours, roll)
    elseif hour < T.STORM_SAME_DAY_UNTIL then
        return today, hour + 1
    end
    return today + 1, T.getTriggerHour(foundHours, roll)
end

-- Hourly: a spell of bad weather that's just ended rolls the events that
-- follow one.
function TheContractorRandomEvents:checkWeather()
    local weatherType = TheContractorRandomEvents.getCurrentWeatherType()
    if weatherType == nil then
        return
    end
    local isBad = TheContractorRandomEvents.isBadWeatherType(weatherType)
    local hasCleared = self.wasBadWeather == true and not isBad
    self.wasBadWeather = isBad
    if hasCleared then
        self:onBadWeatherEnded()
    end
end

-- random is for the tests.
function TheContractorRandomEvents:onBadWeatherEnded(random)
    random = random or math.random
    local multiplier = TheContractorRandomEvents.getRateMultiplier()
    if multiplier <= 0 then
        return
    end
    local today, hour = getToday(), getCurrentHour()
    for _, farmId in ipairs(self:getCompanyFarmIds()) do
        for _, key in ipairs(self.eventTypeOrder) do
            local definition = self.eventTypes[key]
            if TheContractorRandomEvents.isStormEvent(definition) and self:getCooldownLeft(farmId, key) == 0 and
                    not self:hasPendingTrigger(farmId, key) then
                local chance = definition.chancePerStorm * multiplier
                if chance > 0 and random() < chance then
                    local day, foundHour = TheContractorRandomEvents.getStormFoundAt(today, hour,
                        definition.triggerHours, random())
                    self:addPendingTrigger(farmId, key, nil, day, foundHour)
                    TCLog.info("TheContractor: farm %d random event '%s' rolled after bad weather (%.2f), due day %d at %02d:00",
                        farmId, key, chance, day, foundHour)
                end
            end
        end
    end
end

-- Job events (server) -------------------------------------------------------------

function TheContractorRandomEvents.isJobEvent(definition)
    return definition.chancePerJob ~= nil
end

-- Whether a job's quality score is good enough for this job event.
function TheContractorRandomEvents.meetsJobQuality(definition, job)
    return definition.minJobQuality == nil or (job.qualityScore or 0) >= definition.minJobQuality
end

-- The chance of a job event on one completed job, after the setting.
function TheContractorRandomEvents.getJobChance(chancePerJob, multiplier)
    return math.min(1, math.max(0, (chancePerJob or 0) * multiplier))
end

-- A job event's chancePerJob for this job: the number, or the function's answer.
function TheContractorRandomEvents.resolveJobChance(definition, farmId, job)
    if type(definition.chancePerJob) == "function" then
        return definition.chancePerJob(farmId, job) or 0
    end
    return definition.chancePerJob
end

-- From TheContractorJobs:completeJob, once everything else about the job is
-- settled (paid or invoiced, growth rolled). Rolls every job event type
-- that isn't cooling down on the farm; of those that hit, one picked at
-- random happens (the next if it has nothing to act on). Returns the
-- incident, or nil. random is for the tests.
function TheContractorRandomEvents:onJobCompleted(job, random)
    if not g_currentMission:getIsServer() then
        return nil
    end
    random = random or math.random

    local multiplier = TheContractorRandomEvents.getRateMultiplier()
    if multiplier <= 0 then
        return nil
    end
    -- 106: a spilt crop's clear-up has had its event.
    if not TheContractorRandomEvents.canHaveJobEvents(job) then
        return nil
    end

    local hits = {}
    for _, key in ipairs(self.eventTypeOrder) do
        local definition = self.eventTypes[key]
        if TheContractorRandomEvents.isJobEvent(definition) and self:getCooldownLeft(job.farmId, key) == 0 and
                TheContractorRandomEvents.meetsJobQuality(definition, job) then
            local chance = TheContractorRandomEvents.getJobChance(
                TheContractorRandomEvents.resolveJobChance(definition, job.farmId, job), multiplier)
            if chance > 0 and random() < chance then
                table.insert(hits, key)
            end
        end
    end

    while #hits > 0 do
        local key = table.remove(hits, random(1, #hits))
        local incident = self:triggerEvent(job.farmId, key, job)
        TCLog.info("TheContractor: farm %d job %d: job event '%s' rolled%s", job.farmId, job.id, key,
            incident == nil and ", but nothing to act on" or "")
        if incident ~= nil then
            return incident
        end
    end
    return nil
end

-- For a job event forced with no job: the farm's latest completed job
-- canTrigger accepts, and its data - or nil.
function TheContractorRandomEvents:findLatestJobFor(farmId, definition)
    local jobs = g_currentMission.TheContractor.Jobs:getJobsByState(farmId, TheContractorJob.STATE.COMPLETED)
    table.sort(jobs, function(a, b)
        local aAt, bAt = a.completedAt or 0, b.completedAt or 0
        if aAt ~= bAt then
            return aAt > bAt
        end
        return a.id > b.id
    end)
    for _, job in ipairs(jobs) do
        local data = TheContractorRandomEvents.canHaveJobEvents(job) and definition.canTrigger(farmId, job) or nil
        if data ~= nil then
            return job, data
        end
    end
    return nil, nil
end

-- Whether job events can happen on the job at all (JOB_TYPES' noJobEvents).
function TheContractorRandomEvents.canHaveJobEvents(job)
    local jobDef = TheContractorJobGeneration ~= nil and TheContractorJobGeneration.JOB_TYPES[job.jobType] or nil
    return jobDef == nil or not jobDef.noJobEvents
end

-- Opens an incident now (server), cooldown or not - the rolls and the
-- console come here. job: the completed job a job event is for (nil from
-- the console, which finds one). Returns the incident, or nil and why not.
function TheContractorRandomEvents:triggerEvent(farmId, key, job)
    local definition = self.eventTypes[key]
    if definition == nil then
        return nil, "unknown event type"
    end

    local data = nil
    if definition.canTrigger ~= nil then
        if job == nil and TheContractorRandomEvents.isJobEvent(definition) then
            job, data = self:findLatestJobFor(farmId, definition)
        else
            data = definition.canTrigger(farmId, job)
        end
    end
    if data == nil then
        return nil, "nothing to act on"
    end

    local incident = {
        id = self.nextIncidentId,
        farmId = farmId,
        eventType = key,
        stage = "",
        nextStageDay = 0,
        openedPeriod = TCCalendar.getPeriodIndex(),
        data = data,
    }
    self.nextIncidentId = self.nextIncidentId + 1

    self:applyIncident(incident)
    TCLog.info("TheContractor: farm %d incident %d (%s) opened", farmId, incident.id, key)

    if #definition.stages == 0 then
        self:closeIncident(incident)
        return incident
    end
    self:enterStage(incident, 1)
    return incident
end

-- Stages (server) -----------------------------------------------------------------

function TheContractorRandomEvents:advanceDueIncidents()
    local today = getToday()
    local due = {}
    for _, incident in pairs(self.incidents) do
        if incident.nextStageDay > 0 and incident.nextStageDay <= today then
            table.insert(due, incident)
        end
    end
    table.sort(due, function(a, b)
        return a.id < b.id
    end)

    for _, incident in ipairs(due) do
        if g_farmManager:getFarmById(incident.farmId) == nil then
            self:closeIncident(incident)
        else
            self:runStage(incident, getStageIndex(self.eventTypes[incident.eventType], incident.stage))
        end
    end
end

-- Moves an incident to a stage (server): its wait starts, or it runs now.
-- For whatever ends a "wait" stage, e.g. an inbox action.
function TheContractorRandomEvents:goToStage(incident, stageKey)
    local definition = self.eventTypes[incident.eventType]
    local stageIndex = definition ~= nil and getStageIndex(definition, stageKey) or nil
    if stageIndex == nil then
        TCLog.warning("TheContractor: incident %d (%s) has no stage '%s', closing it", incident.id,
            incident.eventType, tostring(stageKey))
        self:closeIncident(incident)
        return
    end
    self:enterStage(incident, stageIndex)
end

function TheContractorRandomEvents:enterStage(incident, stageIndex)
    local stage = self.eventTypes[incident.eventType].stages[stageIndex]
    incident.stage = stage.key

    if stage.delayPeriods ~= nil then
        incident.nextStageDay = getToday() +
            TheContractorRandomEvents.getDelayDays(stage.delayPeriods, getDaysPerPeriod(), math.random())
        self:commitIncident(incident)
        return
    end
    self:runStage(incident, stageIndex)
end

-- Runs a stage and follows the result through any stages with no wait,
-- until one waits or the incident ends.
function TheContractorRandomEvents:runStage(incident, stageIndex)
    local definition = self.eventTypes[incident.eventType]

    for _ = 1, TheContractorRandomEvents.MAX_STAGES_PER_STEP do
        local stage = stageIndex ~= nil and definition.stages[stageIndex] or nil
        if stage == nil then
            self:closeIncident(incident)
            return
        end

        incident.stage = stage.key
        incident.nextStageDay = 0

        local result = stage.run ~= nil and stage.run(incident) or nil
        if self.incidents[incident.id] == nil then
            -- The stage closed it itself.
            return
        end

        if result == TheContractorRandomEvents.DONE then
            self:closeIncident(incident)
            return
        elseif result == TheContractorRandomEvents.WAIT then
            self:commitIncident(incident)
            return
        end

        local nextIndex = stageIndex + 1
        if result ~= nil then
            nextIndex = getStageIndex(definition, result)
            if nextIndex == nil then
                TCLog.warning("TheContractor: incident %d (%s) stage '%s' went to unknown stage '%s', closing it",
                    incident.id, incident.eventType, stage.key, tostring(result))
                self:closeIncident(incident)
                return
            end
        end

        local nextStage = definition.stages[nextIndex]
        if nextStage == nil then
            self:closeIncident(incident)
            return
        end
        if nextStage.delayPeriods ~= nil then
            self:enterStage(incident, nextIndex)
            return
        end
        stageIndex = nextIndex
    end

    TCLog.warning("TheContractor: incident %d (%s) ran more than %d stages in one go, closing it", incident.id,
        incident.eventType, TheContractorRandomEvents.MAX_STAGES_PER_STEP)
    self:closeIncident(incident)
end

-- Server: the incident's new stage/data to every machine.
function TheContractorRandomEvents:commitIncident(incident)
    self:applyIncident(incident)
    if g_server ~= nil then
        g_server:broadcastEvent(TCRandomEventIncidentEvent.new(incident, false))
    end
end

function TheContractorRandomEvents:closeIncident(incident)
    self:applyIncidentClosed(incident.id)
    TCLog.info("TheContractor: farm %d incident %d (%s) closed", incident.farmId, incident.id, incident.eventType)
    if g_server ~= nil then
        g_server:broadcastEvent(TCRandomEventIncidentEvent.new(incident, true))
    end
end

-- Every machine -------------------------------------------------------------------

function TheContractorRandomEvents:applyIncident(incident)
    self.incidents[incident.id] = incident
    self.nextIncidentId = math.max(self.nextIncidentId, incident.id + 1)

    if self.lastPeriodByFarm[incident.farmId] == nil then
        self.lastPeriodByFarm[incident.farmId] = {}
    end
    local farmPeriods = self.lastPeriodByFarm[incident.farmId]
    farmPeriods[incident.eventType] = math.max(farmPeriods[incident.eventType] or 0, incident.openedPeriod)
end

function TheContractorRandomEvents:applyIncidentClosed(id)
    self.incidents[id] = nil
end

-- Wire serialization ----------------------------------------------------------------

local function getSortedKeys(data)
    local keys = {}
    for key in pairs(data) do
        table.insert(keys, key)
    end
    table.sort(keys)
    return keys
end

-- data's string keys, sorted (anything else in it isn't saved or synced).
local function getSortedDataKeys(data)
    local keys = {}
    for key in pairs(data) do
        if type(key) == "string" then
            table.insert(keys, key)
        end
    end
    table.sort(keys)
    return keys
end

local function getValueType(value)
    local valueType = type(value)
    if valueType == "number" then
        return TheContractorRandomEvents.VALUE_TYPE.NUMBER
    elseif valueType == "string" then
        return TheContractorRandomEvents.VALUE_TYPE.STRING
    elseif valueType == "boolean" then
        return TheContractorRandomEvents.VALUE_TYPE.BOOLEAN
    end
    return nil
end

function TheContractorRandomEvents.writeData(streamId, data)
    local keys = {}
    for _, key in ipairs(getSortedDataKeys(data)) do
        if getValueType(data[key]) ~= nil then
            table.insert(keys, key)
        end
    end

    streamWriteInt32(streamId, #keys)
    for _, key in ipairs(keys) do
        local value = data[key]
        local valueType = getValueType(value)
        streamWriteString(streamId, key)
        streamWriteUInt8(streamId, valueType)
        if valueType == TheContractorRandomEvents.VALUE_TYPE.NUMBER then
            streamWriteFloat32(streamId, value)
        elseif valueType == TheContractorRandomEvents.VALUE_TYPE.STRING then
            streamWriteString(streamId, value)
        else
            streamWriteBool(streamId, value)
        end
    end
end

function TheContractorRandomEvents.readData(streamId)
    local data = {}
    local count = streamReadInt32(streamId)
    for _ = 1, count do
        local key = streamReadString(streamId)
        local valueType = streamReadUInt8(streamId)
        if valueType == TheContractorRandomEvents.VALUE_TYPE.NUMBER then
            data[key] = streamReadFloat32(streamId)
        elseif valueType == TheContractorRandomEvents.VALUE_TYPE.STRING then
            data[key] = streamReadString(streamId)
        else
            data[key] = streamReadBool(streamId)
        end
    end
    return data
end

function TheContractorRandomEvents.writeIncident(streamId, incident)
    streamWriteInt32(streamId, incident.id)
    streamWriteInt32(streamId, incident.farmId)
    streamWriteString(streamId, incident.eventType)
    streamWriteString(streamId, incident.stage)
    streamWriteInt32(streamId, incident.nextStageDay)
    streamWriteInt32(streamId, incident.openedPeriod)
    TheContractorRandomEvents.writeData(streamId, incident.data)
end

function TheContractorRandomEvents.readIncident(streamId)
    return {
        id = streamReadInt32(streamId),
        farmId = streamReadInt32(streamId),
        eventType = streamReadString(streamId),
        stage = streamReadString(streamId),
        nextStageDay = streamReadInt32(streamId),
        openedPeriod = streamReadInt32(streamId),
        data = TheContractorRandomEvents.readData(streamId),
    }
end

-- Persistence -------------------------------------------------------------------------

-- A farm deleted in multiplayer (TCFarmDeletion), on every machine.
function TheContractorRandomEvents:forgetFarm(farmId)
    for id, incident in pairs(self.incidents) do
        if incident.farmId == farmId then
            self.incidents[id] = nil
        end
    end
    self.lastPeriodByFarm[farmId] = nil
    local kept = {}
    for _, trigger in ipairs(self.pendingTriggers) do
        if trigger.farmId ~= farmId then
            table.insert(kept, trigger)
        end
    end
    self.pendingTriggers = kept
end

function TheContractorRandomEvents:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    self.incidents = {}
    self.lastPeriodByFarm = {}
    self.pendingTriggers = {}

    local rootKey = string.format("%s.randomEvents", TheContractor.SaveKey)
    self.nextIncidentId = Utils.getNoNil(getXMLInt(xmlFile, rootKey .. "#nextIncidentId"), 1)

    local index = 0
    while true do
        local key = string.format("%s.pending(%d)", rootKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local pending = {
            farmId = getXMLInt(xmlFile, key .. "#farmId"),
            eventType = getXMLString(xmlFile, key .. "#eventType"),
            day = getXMLInt(xmlFile, key .. "#day"),
            hour = getXMLInt(xmlFile, key .. "#hour"),
        }
        if pending.farmId ~= nil and pending.eventType ~= nil and self.eventTypes[pending.eventType] ~= nil and
                pending.day ~= nil and pending.hour ~= nil then
            table.insert(self.pendingTriggers, pending)
        end
        index = index + 1
    end

    index = 0
    while true do
        local key = string.format("%s.cooldown(%d)", rootKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local farmId = getXMLInt(xmlFile, key .. "#farmId")
        local eventType = getXMLString(xmlFile, key .. "#eventType")
        local period = getXMLInt(xmlFile, key .. "#period")
        if farmId ~= nil and eventType ~= nil and period ~= nil then
            if self.lastPeriodByFarm[farmId] == nil then
                self.lastPeriodByFarm[farmId] = {}
            end
            self.lastPeriodByFarm[farmId][eventType] = period
        end
        index = index + 1
    end

    index = 0
    while true do
        local key = string.format("%s.incident(%d)", rootKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local incident = {
            id = getXMLInt(xmlFile, key .. "#id"),
            farmId = getXMLInt(xmlFile, key .. "#farmId"),
            eventType = getXMLString(xmlFile, key .. "#eventType"),
            stage = Utils.getNoNil(getXMLString(xmlFile, key .. "#stage"), ""),
            nextStageDay = Utils.getNoNil(getXMLInt(xmlFile, key .. "#nextStageDay"), 0),
            openedPeriod = Utils.getNoNil(getXMLInt(xmlFile, key .. "#openedPeriod"), 0),
            data = {},
        }

        local valueIndex = 0
        while true do
            local valueKey = string.format("%s.value(%d)", key, valueIndex)
            if not hasXMLProperty(xmlFile, valueKey) then
                break
            end
            local name = getXMLString(xmlFile, valueKey .. "#name")
            local valueType = getXMLInt(xmlFile, valueKey .. "#type")
            if name ~= nil then
                if valueType == TheContractorRandomEvents.VALUE_TYPE.NUMBER then
                    incident.data[name] = getXMLFloat(xmlFile, valueKey .. "#number")
                elseif valueType == TheContractorRandomEvents.VALUE_TYPE.STRING then
                    incident.data[name] = getXMLString(xmlFile, valueKey .. "#string")
                elseif valueType == TheContractorRandomEvents.VALUE_TYPE.BOOLEAN then
                    incident.data[name] = getXMLBool(xmlFile, valueKey .. "#bool")
                end
            end
            valueIndex = valueIndex + 1
        end

        -- An event type that's no longer registered (a mod update dropped
        -- it) has no stages to run: drop its incidents.
        local definition = incident.eventType ~= nil and self.eventTypes[incident.eventType] or nil
        if incident.id == nil or incident.farmId == nil or definition == nil then
            TCLog.warning("TheContractor: dropping saved incident %s of unknown event type '%s'",
                tostring(incident.id), tostring(incident.eventType))
        elseif getStageIndex(definition, incident.stage) == nil then
            TCLog.warning("TheContractor: dropping saved incident %d (%s) at unknown stage '%s'", incident.id,
                incident.eventType, incident.stage)
        else
            self:applyIncident(incident)
        end
        index = index + 1
    end
end

function TheContractorRandomEvents:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    local rootKey = string.format("%s.randomEvents", TheContractor.SaveKey)
    setXMLInt(xmlFile, rootKey .. "#nextIncidentId", self.nextIncidentId)

    for i, pending in ipairs(self.pendingTriggers) do
        local key = string.format("%s.pending(%d)", rootKey, i - 1)
        setXMLInt(xmlFile, key .. "#farmId", pending.farmId)
        setXMLString(xmlFile, key .. "#eventType", pending.eventType)
        setXMLInt(xmlFile, key .. "#day", pending.day)
        setXMLInt(xmlFile, key .. "#hour", pending.hour)
    end

    local index = 0
    for _, farmId in ipairs(getSortedKeys(self.lastPeriodByFarm)) do
        local farmPeriods = self.lastPeriodByFarm[farmId]
        for _, eventType in ipairs(getSortedKeys(farmPeriods)) do
            local key = string.format("%s.cooldown(%d)", rootKey, index)
            setXMLInt(xmlFile, key .. "#farmId", farmId)
            setXMLString(xmlFile, key .. "#eventType", eventType)
            setXMLInt(xmlFile, key .. "#period", farmPeriods[eventType])
            index = index + 1
        end
    end

    index = 0
    for _, id in ipairs(getSortedKeys(self.incidents)) do
        local incident = self.incidents[id]
        local key = string.format("%s.incident(%d)", rootKey, index)
        setXMLInt(xmlFile, key .. "#id", incident.id)
        setXMLInt(xmlFile, key .. "#farmId", incident.farmId)
        setXMLString(xmlFile, key .. "#eventType", incident.eventType)
        setXMLString(xmlFile, key .. "#stage", incident.stage)
        setXMLInt(xmlFile, key .. "#nextStageDay", incident.nextStageDay)
        setXMLInt(xmlFile, key .. "#openedPeriod", incident.openedPeriod)

        local valueIndex = 0
        for _, name in ipairs(getSortedDataKeys(incident.data)) do
            local value = incident.data[name]
            local valueType = getValueType(value)
            if valueType ~= nil then
                local valueKey = string.format("%s.value(%d)", key, valueIndex)
                setXMLString(xmlFile, valueKey .. "#name", name)
                setXMLInt(xmlFile, valueKey .. "#type", valueType)
                if valueType == TheContractorRandomEvents.VALUE_TYPE.NUMBER then
                    setXMLFloat(xmlFile, valueKey .. "#number", value)
                elseif valueType == TheContractorRandomEvents.VALUE_TYPE.STRING then
                    setXMLString(xmlFile, valueKey .. "#string", value)
                else
                    setXMLBool(xmlFile, valueKey .. "#bool", value)
                end
                valueIndex = valueIndex + 1
            end
        end
        index = index + 1
    end
end

function TheContractorRandomEvents:writeInitialClientState(streamId, connection)
    local cooldowns = {}
    for _, farmId in ipairs(getSortedKeys(self.lastPeriodByFarm)) do
        for _, eventType in ipairs(getSortedKeys(self.lastPeriodByFarm[farmId])) do
            table.insert(cooldowns, { farmId = farmId, eventType = eventType,
                period = self.lastPeriodByFarm[farmId][eventType] })
        end
    end

    streamWriteInt32(streamId, #cooldowns)
    for _, cooldown in ipairs(cooldowns) do
        streamWriteInt32(streamId, cooldown.farmId)
        streamWriteString(streamId, cooldown.eventType)
        streamWriteInt32(streamId, cooldown.period)
    end

    local ids = getSortedKeys(self.incidents)
    streamWriteInt32(streamId, #ids)
    for _, id in ipairs(ids) do
        TheContractorRandomEvents.writeIncident(streamId, self.incidents[id])
    end
end

function TheContractorRandomEvents:readInitialClientState(streamId, connection)
    local cooldownCount = streamReadInt32(streamId)
    for _ = 1, cooldownCount do
        local farmId = streamReadInt32(streamId)
        local eventType = streamReadString(streamId)
        local period = streamReadInt32(streamId)
        if self.lastPeriodByFarm[farmId] == nil then
            self.lastPeriodByFarm[farmId] = {}
        end
        self.lastPeriodByFarm[farmId][eventType] = period
    end

    local incidentCount = streamReadInt32(streamId)
    for _ = 1, incidentCount do
        self:applyIncident(TheContractorRandomEvents.readIncident(streamId))
    end
end

-- Console commands (tcEvent, tcDebug - see TCConsole) -----------------------------------------

function TheContractorRandomEvents:getEventTypeName(key)
    local definition = self.eventTypes[key]
    if definition ~= nil and definition.l10nKey ~= nil then
        return g_i18n:getText(definition.l10nKey)
    end
    return key
end

-- The event type key a console argument names (case-insensitive), or nil.
function TheContractorRandomEvents:findEventTypeKey(wanted)
    if wanted == nil then
        return nil
    end
    for _, candidate in ipairs(self.eventTypeOrder) do
        if string.lower(candidate) == string.lower(wanted) then
            return candidate
        end
    end
    return nil
end

-- "theft (<recovered|lost>), sprayDrift (<yes|no>)": the types with a
-- console outcome.
function TheContractorRandomEvents:getOutcomeTypesText()
    local parts = {}
    for _, key in ipairs(self.eventTypeOrder) do
        local console = self.eventTypes[key].console
        if console ~= nil and console.outcomes ~= nil then
            table.insert(parts, string.format("%s <%s>", key, table.concat(console.outcomes, "|")))
        end
    end
    return #parts > 0 and table.concat(parts, ", ") or "none"
end

-- "  key [details]" for each type, for trigger's list and the hint.
function TheContractorRandomEvents:getTriggerListText()
    local lines = {}
    for _, key in ipairs(self:getEventTypeKeys()) do
        local console = self:getEventType(key).console
        local details = console ~= nil and console.details or nil
        table.insert(lines, details ~= nil and (key .. " " .. details) or key)
    end
    return #lines > 0 and table.concat(lines, ", ") or "none yet"
end

function TheContractorRandomEvents.registerConsoleCommands()
    TCConsole.registerHint("eventType", function()
        local randomEvents = g_currentMission.TheContractor ~= nil and g_currentMission.TheContractor.RandomEvents
        return randomEvents and randomEvents:getTriggerListText() or "tcEvent list"
    end)
    TCConsole.registerHint("details", "what the event acts on, shown after each type above; left out, it picks as the real event does")

    TCConsole.register("event", "list", {
        description = "Each event type: its odds for your farm, its cooldown and what tcEvent trigger takes for it",
        serverOnly = false,
        run = function(farmId, args)
            local randomEvents = g_currentMission.TheContractor.RandomEvents
            local multiplier = TheContractorRandomEvents.getRateMultiplier()
            local daysPerPeriod = getDaysPerPeriod()
            local lines = { string.format("Random events at %d%% (today is day %d, %d day(s) a month):",
                math.floor(multiplier * 100 + 0.5), getToday(), daysPerPeriod) }

            local keys = randomEvents:getEventTypeKeys()
            if #keys == 0 then
                table.insert(lines, "  no event types registered")
            end
            for _, key in ipairs(keys) do
                local definition = randomEvents:getEventType(key)
                local cooldownLeft = randomEvents:getCooldownLeft(farmId, key)
                local odds
                if TheContractorRandomEvents.isStormEvent(definition) then
                    odds = string.format("%.1f%% after each spell of bad weather",
                        definition.chancePerStorm * multiplier * 100)
                elseif TheContractorRandomEvents.isJobEvent(definition) then
                    local chanceText = type(definition.chancePerJob) == "function" and "depends on the job" or
                        string.format("%.1f%%", TheContractorRandomEvents.getJobChance(definition.chancePerJob,
                            multiplier) * 100)
                    odds = string.format("%s a completed job%s", chanceText,
                        definition.minJobQuality ~= nil and
                        string.format(" (quality %d%%+)", definition.minJobQuality) or "")
                else
                    local rate = definition.ratePerPeriod ~= nil and definition.ratePerPeriod(farmId) or 0
                    odds = string.format("%.3f a month, %.4f a day", rate * multiplier,
                        TheContractorRandomEvents.getDailyChance(rate, multiplier, daysPerPeriod))
                    if definition.triggerHours ~= nil then
                        odds = odds .. string.format(", happens %02d:00-%02d:00", definition.triggerHours[1],
                            definition.triggerHours[2])
                    end
                end
                local details = definition.console ~= nil and definition.console.details or nil
                table.insert(lines, string.format("  %s%s (%s): %s%s", key, details ~= nil and (" " .. details) or "",
                    randomEvents:getEventTypeName(key), odds,
                    cooldownLeft > 0 and string.format(", cooling down for %d more month(s)", cooldownLeft) or ""))
            end
            return table.concat(lines, "\n")
        end,
    })

    TCConsole.register("event", "trigger", {
        args = "<eventType> [details]",
        description = "Make a random event happen to your farm now (ignores the odds, the cooldown and the time of day)",
        run = function(farmId, args, context)
            local randomEvents = g_currentMission.TheContractor.RandomEvents
            local wanted = args[1]
            if wanted == nil then
                return false
            end

            local key = randomEvents:findEventTypeKey(wanted)
            if key == nil then
                return string.format("Error: no event type '%s'. Types: %s", wanted,
                    randomEvents:getTriggerListText())
            end

            -- The type's own details (a worker, a story), set up just for
            -- this trigger.
            local console = randomEvents:getEventType(key).console
            local details = {}
            for i = 2, #args do
                table.insert(details, args[i])
            end
            if console ~= nil and console.prepareTrigger ~= nil then
                local problem = console.prepareTrigger(farmId, details, context)
                if problem ~= nil then
                    return problem
                end
            elseif #details > 0 then
                return string.format("Error: %s takes no details", key)
            end

            local incident, reason = randomEvents:triggerEvent(farmId, key)
            if console ~= nil and console.clearTrigger ~= nil then
                console.clearTrigger()
            end
            if incident == nil then
                return string.format("No %s: %s", key, reason)
            end
            return string.format("Incident %d (%s) opened on farm %d, now at stage '%s'%s", incident.id, key, farmId,
                incident.stage, randomEvents:getIncident(incident.id) == nil and " (already over)" or "")
        end,
    })

    TCConsole.register("debug", "outcome", {
        args = "<eventType> <outcome>",
        description = "Decide how the next event of a type comes out (once, then the odds are back to normal)",
        hints = {
            eventType = function()
                return g_currentMission.TheContractor.RandomEvents:getOutcomeTypesText()
            end,
            outcome = "one of the type's outcomes, shown beside it above",
        },
        run = function(farmId, args)
            local randomEvents = g_currentMission.TheContractor.RandomEvents
            local key = randomEvents:findEventTypeKey(args[1])
            local console = key ~= nil and randomEvents:getEventType(key).console or nil
            if console == nil or console.outcomes == nil then
                return false
            end

            local outcome = nil
            for _, candidate in ipairs(console.outcomes) do
                if args[2] ~= nil and string.lower(candidate) == string.lower(args[2]) then
                    outcome = candidate
                end
            end
            if outcome == nil then
                return string.format("Usage: tcDebug outcome %s <%s>", key, table.concat(console.outcomes, "|"))
            end
            return console.setOutcome(outcome)
        end,
    })

    -- The hidden side: rolls waiting for their hour, and each open
    -- incident's own data.
    TCConsole.register("debug", "incidents", {
        description = "Events rolled and waiting for their hour, and your open incidents with their stage and data",
        serverOnly = false,
        run = function(farmId, args)
            local randomEvents = g_currentMission.TheContractor.RandomEvents
            local lines = { string.format("Today is day %d.", getToday()) }
            for _, pending in ipairs(randomEvents.pendingTriggers) do
                if pending.farmId == farmId then
                    table.insert(lines, string.format("  %s rolled, due day %d at %02d:00", pending.eventType,
                        pending.day, pending.hour))
                end
            end

            local incidents = randomEvents:getIncidents(farmId)
            table.insert(lines, string.format("Open incidents: %d", #incidents))
            for _, incident in ipairs(incidents) do
                local values = {}
                for _, name in ipairs(getSortedDataKeys(incident.data)) do
                    table.insert(values, string.format("%s=%s", name, tostring(incident.data[name])))
                end
                table.insert(lines, string.format("  #%d %s, stage '%s'%s, opened %s%s", incident.id,
                    incident.eventType, incident.stage,
                    incident.nextStageDay > 0 and string.format(" until day %d", incident.nextStageDay) or
                    " (waiting)", TCCalendar.formatPeriodIndex(incident.openedPeriod),
                    #values > 0 and (": " .. table.concat(values, ", ")) or ""))
            end
            return table.concat(lines, "\n")
        end,
    })
end
