-- Workplace injury (104), a random event (068). During the working day
-- (TRIGGER_HOURS, inside 097's hours) one of the farm's field staff hurts
-- themselves: caught on a PTO shaft, a fall from a trailer and so on (SCENARIOS, flavour only). They're off sick
-- for a few days through Staff:makeWorkerSick, so it's the same SICK status
-- as 031's sickness and 055's no-programme inspection roll comes with it.
-- The office administrator (057) is never hurt: only the roster is.
--
-- Who: field staff who are at work right now, idle in the yard during their
-- hours (WorkingHours.isAvailable) or out on a job, in its cooldown or
-- driving (WorkingHours.isWorking). Like sickness, it never pulls anyone off
-- a job: someone hurt while out sees it through and is off once they're
-- back (pendingSickDays). Nobody already off sick, on holiday, on training
-- or with sickness pending.
--
-- How long: getInjuryDays, scaled to days per period. 1 day at 1 day per
-- period (always), 2-5 from 5 days per period up, in between at 2-4 (see
-- the table there). Today counts as the first day, as a bout of sickness
-- set today would.
--
-- How often: RATE_PER_PERIOD a month while anyone could be hurt, about
-- once every 2.5 years, times 055's INJURY_MULTIPLIER (a quarter off, about
-- once every 3.3 years) with the health and safety programme.
--
-- No state of its own (like Poaching): the worker, scenario and days live
-- in the incident's data, which 068 saves and syncs. Sickness goes through
-- Staff's own status event.

TheContractorInjury = {}
TheContractorInjury_mt = Class(TheContractorInjury)

TheContractorInjury.EVENT_TYPE = "injury"
TheContractorInjury.MESSAGE_KIND = "injury"

-- About once every 2.5 years (30 months) without the programme.
TheContractorInjury.RATE_PER_PERIOD = 1 / 30
TheContractorInjury.COOLDOWN_PERIODS = 1

-- 09:00 to 16:59: well inside the 08:00-18:00 day.
TheContractorInjury.TRIGGER_HOURS = { 9, 17 }

-- Shortest and longest injury at 1 day per period and from
-- FULL_RANGE_DAYS per period up.
TheContractorInjury.MIN_DAYS = { 1, 2 }
TheContractorInjury.MAX_DAYS = { 1, 5 }
TheContractorInjury.FULL_RANGE_DAYS = 5

-- Each has a tc_injury_scenario_<key> l10n key: what happened, after the
-- worker's name.
TheContractorInjury.SCENARIOS = { "pto", "trailer", "hitching", "cab", "lifting" }

function TheContractorInjury.new()
    local self = {}
    setmetatable(self, TheContractorInjury_mt)

    -- tcEvent trigger injury: its pick takes anyone who could be hurt, at
    -- work or not, since it ignores the hour. Server-only, not saved.
    self.fromConsole = false

    return self
end

-- Every machine, at load, before the save loads (068).
function TheContractorInjury:register(randomEvents, inbox)
    self.randomEvents = randomEvents

    randomEvents:registerEventType(TheContractorInjury.EVENT_TYPE, {
        l10nKey = "tc_injury_eventName",
        cooldownPeriods = TheContractorInjury.COOLDOWN_PERIODS,
        triggerHours = TheContractorInjury.TRIGGER_HOURS,
        ratePerPeriod = function(farmId)
            return self:getRatePerPeriod(farmId)
        end,
        canTrigger = function(farmId)
            return self:pickInjury(farmId, math.random(), math.random(), math.random())
        end,
        -- tcEvent trigger injury, no details.
        console = {
            prepareTrigger = function(farmId, details)
                if #details > 0 then
                    return "Error: injury takes no details"
                end
                self.fromConsole = true
                return nil
            end,
            clearTrigger = function()
                self.fromConsole = false
            end,
        },
        stages = {
            { key = "injured", run = function(incident)
                return self:onInjured(incident)
            end },
        },
    })

    inbox:registerMessageKind(TheContractorInjury.MESSAGE_KIND, {
        category = "staff",
        chipTone = "bad",
    })
end

-- Odds and who (server) ---------------------------------------------------------------

-- Days off for an injury at daysPerPeriod, roll (0-1) picking within the
-- range. The range grows from MIN_DAYS/MAX_DAYS' first values at 1 day per
-- period to their second at FULL_RANGE_DAYS:
--   1 day: 1    2: 1-2    3: 2-3    4: 2-4    5+: 2-5
function TheContractorInjury.getDayRange(daysPerPeriod)
    local share = math.max(0, math.min(1, ((daysPerPeriod or 1) - 1) / (TheContractorInjury.FULL_RANGE_DAYS - 1)))
    local minDays, maxDays = TheContractorInjury.MIN_DAYS, TheContractorInjury.MAX_DAYS
    local low = math.floor(minDays[1] + share * (minDays[2] - minDays[1]) + 0.5)
    local high = math.floor(maxDays[1] + share * (maxDays[2] - maxDays[1]) + 0.5)
    return low, math.max(low, high)
end

function TheContractorInjury.getInjuryDays(daysPerPeriod, roll)
    local low, high = TheContractorInjury.getDayRange(daysPerPeriod)
    return math.min(high, low + math.floor(roll * (high - low + 1)))
end

-- Not already off, away or due to be: someone an injury could happen to.
function TheContractorInjury.canBeInjured(worker)
    local STATUS = TheContractorWorker.STATUS
    return worker.pendingSickDays == 0 and worker.status ~= STATUS.SICK and worker.status ~= STATUS.HOLIDAY and
        worker.status ~= STATUS.TRAINING and worker.status ~= STATUS.SHOW
end

-- At work right now: in the yard during their hours, or out working.
function TheContractorInjury.isAtWork(worker)
    return TheContractorWorkingHours.isAvailable(worker) or TheContractorWorkingHours.isWorking(worker)
end

-- The roster's workers who could be hurt, by id. atWorkOnly: only those at
-- work now (the real event); without it, anyone who could be (the rate,
-- rolled at midnight when nobody is in, and the console).
function TheContractorInjury:getCandidates(farmId, atWorkOnly)
    local result = {}
    for _, worker in ipairs(g_currentMission.TheContractor.Staff:getRoster(farmId)) do
        if TheContractorInjury.canBeInjured(worker) and (not atWorkOnly or TheContractorInjury.isAtWork(worker)) then
            table.insert(result, worker)
        end
    end
    table.sort(result, function(a, b)
        return a.id < b.id
    end)
    return result
end

function TheContractorInjury:getRatePerPeriod(farmId)
    if #self:getCandidates(farmId, false) == 0 then
        return 0
    end
    return TheContractorInjury.RATE_PER_PERIOD *
        g_currentMission.TheContractor.HealthSafety:getInjuryMultiplier(farmId)
end

-- canTrigger (068): { workerId, workerName, scenario, days }, or nil.
function TheContractorInjury:pickInjury(farmId, workerRoll, scenarioRoll, daysRoll)
    local candidates = self:getCandidates(farmId, not self.fromConsole)
    if #candidates == 0 then
        return nil
    end
    local worker = candidates[math.min(#candidates, 1 + math.floor(workerRoll * #candidates))]

    local scenarios = TheContractorInjury.SCENARIOS
    local scenario = scenarios[math.min(#scenarios, 1 + math.floor(scenarioRoll * #scenarios))]

    return {
        workerId = worker.id,
        workerName = worker.name,
        scenario = scenario,
        days = TheContractorInjury.getInjuryDays(g_currentMission.environment.daysPerPeriod, daysRoll),
    }
end

-- Stage (server) ------------------------------------------------------------------------

function TheContractorInjury:onInjured(incident)
    local data = incident.data
    local tc = g_currentMission.TheContractor
    local worker = tc.Staff:getWorker(incident.farmId, data.workerId)
    if worker == nil or not TheContractorInjury.canBeInjured(worker) then
        return TheContractorRandomEvents.DONE
    end

    local wasIdle = worker:isIdle()
    tc.Staff:makeWorkerSick(incident.farmId, worker, false, data.days, true)

    local scenario = "$l10n_tc_injury_scenario_" .. data.scenario
    if wasIdle then
        local today = g_currentMission.environment.currentMonotonicDay
        tc.Inbox:postMessage(incident.farmId, TheContractorInjury.MESSAGE_KIND, "tc_injury_title", "tc_injury_body",
            { worker.name, scenario, data.days, string.format("$days_%d_%d", today, today + data.days - 1) }, nil,
            { incidentId = incident.id, workerId = worker.id })
    else
        tc.Inbox:postMessage(incident.farmId, TheContractorInjury.MESSAGE_KIND, "tc_injury_title",
            "tc_injury_bodyOnJob", { worker.name, scenario, data.days }, nil,
            { incidentId = incident.id, workerId = worker.id })
    end

    TCLog.info("TheContractor: farm %d incident %d: worker %d (%s) injured (%s), off for %d day(s)%s",
        incident.farmId, incident.id, worker.id, worker.name, data.scenario, data.days,
        wasIdle and "" or " once back from their job")
    return TheContractorRandomEvents.DONE
end

-- Persistence (nothing of its own - see the header) ---------------------------------------

function TheContractorInjury:loadFromXMLFile(xmlFile)
end

function TheContractorInjury:saveToXmlFile(xmlFile)
end

function TheContractorInjury:writeInitialClientState(streamId, connection)
end

function TheContractorInjury:readInitialClientState(streamId, connection)
end
