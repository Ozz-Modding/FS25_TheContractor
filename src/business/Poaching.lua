-- Worker poached by a rival (083), a random event (068). In the run-up to
-- harvest (March-May, WINDOW_PERIODS) a rival contractor offers one of the
-- farm's most valuable workers more money for the coming season. The inbox
-- message gives the player two answers:
--
--   match        their pay goes up to the offer (058's PayReviews:setPay),
--                MATCH_MORALE on top, and they always stay
--   do nothing   (or no answer by the time it expires) they think it over
--                for a day or two, then usually take it and hand in a
--                month's notice (056's quit path). getStayChance, from
--                their morale and their pay against what they expect, is
--                the chance they stay anyway
--
-- The window ends in May so even the slowest case (an offer at the end of
-- May, left to expire, then the decision) has them leave by August.
--
-- The target is weighted on market value squared, so it's nearly always
-- one of the best. The offer is OFFER_MIN-MAX above the higher of their pay
-- and their market value, so a worker who's grown on their hiring pay gets
-- a big jump. Like a salary it's an unscaled full-month figure, shown with
-- $pay_.
--
-- No state of its own (like DieselTheft): the worker, offer and rival live
-- in the incident's data, which 068 saves and syncs. Pay and leaving go
-- through their own events.

TheContractorPoaching = {}
TheContractorPoaching_mt = Class(TheContractorPoaching)

TheContractorPoaching.EVENT_TYPE = "poaching"
TheContractorPoaching.MESSAGE_KIND = "poaching"

TheContractorPoaching.ACTION = {
    MATCH = "match",
    NOTHING = "nothing",
}

TheContractorPoaching.STAGE = {
    APPROACHED = "approached",
    MATCHED = "matched",
    DECISION = "decision",
}

-- March, April, May (period 1 is March). 0.13 a month over three months is
-- about a 34% chance a year.
TheContractorPoaching.WINDOW_PERIODS = { 1, 2, 3 }
TheContractorPoaching.RATE_PER_PERIOD = 0.13
TheContractorPoaching.COOLDOWN_PERIODS = 12

-- Rivals don't go after someone who's only just started.
TheContractorPoaching.MIN_SERVICE_MONTHS = 3

TheContractorPoaching.OFFER_MIN = 0.10
TheContractorPoaching.OFFER_MAX = 0.25

-- "Thinking it over" after doing nothing, in months.
TheContractorPoaching.DECISION_DELAY_PERIODS = { 0.05, 0.15 }

TheContractorPoaching.MATCH_MORALE = 5

-- Doing nothing: STAY_BASE, plus up to STAY_MORALE_MAX for morale from
-- STAY_MORALE_FROM to 100, plus STAY_PER_PAY_PERCENT per % they're paid
-- above their expectation beyond 058's PAY_TOLERANCE (up to
-- STAY_PAY_MAX), less the same per % below it. Clamped to 0-STAY_MAX.
TheContractorPoaching.STAY_BASE = 0.05
TheContractorPoaching.STAY_MORALE_FROM = 50
TheContractorPoaching.STAY_MORALE_MAX = 0.15
TheContractorPoaching.STAY_PER_PAY_PERCENT = 0.01
TheContractorPoaching.STAY_PAY_MAX = 0.05
TheContractorPoaching.STAY_MAX = 0.25

-- l10n keys for the rival's business name ("%s Agri Services").
TheContractorPoaching.RIVAL_NAME_KEYS = {
    "tc_poaching_rival1",
    "tc_poaching_rival2",
    "tc_poaching_rival3",
    "tc_poaching_rival4",
}

function TheContractorPoaching.new()
    local self = {}
    setmetatable(self, TheContractorPoaching_mt)

    -- tcCompany event poaching <worker>: the worker it goes after. tcCompany
    -- outcome poaching: true/false for the next "do nothing" decision. Both
    -- server-only, not saved.
    self.forcedWorkerId = nil
    self.forcedStay = nil

    return self
end

-- Every machine, at load, before the save loads (068).
function TheContractorPoaching:register(randomEvents, inbox)
    self.randomEvents = randomEvents
    local STAGE = TheContractorPoaching.STAGE

    randomEvents:registerEventType(TheContractorPoaching.EVENT_TYPE, {
        l10nKey = "tc_poaching_eventName",
        cooldownPeriods = TheContractorPoaching.COOLDOWN_PERIODS,
        ratePerPeriod = function(farmId)
            return self:getRatePerPeriod(farmId)
        end,
        canTrigger = function(farmId)
            return self:pickTarget(farmId, math.random(), math.random())
        end,
        -- tcCompany event poaching [worker], tcCompany outcome poaching
        -- <stays|leaves>.
        console = {
            prepareTrigger = function(farmId, details)
                return self:prepareConsoleTarget(farmId, details[1])
            end,
            clearTrigger = function()
                self.forcedWorkerId = nil
            end,
            outcomes = { "stays", "leaves" },
            setOutcome = function(outcome)
                self.forcedStay = outcome == "stays"
                return string.format("The next poached worker you do nothing about %s", outcome)
            end,
        },
        stages = {
            { key = STAGE.APPROACHED, run = function(incident)
                return self:onApproached(incident)
            end },
            { key = STAGE.MATCHED, run = function(incident)
                return self:onMatched(incident)
            end },
            { key = STAGE.DECISION, delayPeriods = TheContractorPoaching.DECISION_DELAY_PERIODS,
                run = function(incident)
                    return self:onDecision(incident)
                end },
        },
    })

    inbox:registerMessageKind(TheContractorPoaching.MESSAGE_KIND, {
        onAction = function(farmId, message, actionKey)
            self:onMessageAnswered(message, actionKey)
        end,
        -- No answer is doing nothing.
        onExpire = function(farmId, message)
            self:onMessageAnswered(message, TheContractorPoaching.ACTION.NOTHING)
        end,
        getConfirmText = function(message, actionKey)
            if actionKey ~= TheContractorPoaching.ACTION.MATCH then
                return nil
            end
            return string.format(g_i18n:getText("tc_poaching_matchConfirm"), tostring(message.args[1]),
                g_i18n:formatMoney(TheContractorStaff.scalePay(message.payload.offer or 0), 0, true, true))
        end,
        chipKey = "tc_inbox_chipPoaching",
        chipTone = "warn",
    })
end

-- Odds and target (server) ----------------------------------------------------------

function TheContractorPoaching.isInWindow(period)
    for _, windowPeriod in ipairs(TheContractorPoaching.WINDOW_PERIODS) do
        if windowPeriod == period then
            return true
        end
    end
    return false
end

-- The worker an open poaching incident is about, if any.
function TheContractorPoaching:getIncidentForWorker(farmId, workerId)
    if self.randomEvents == nil then
        return nil
    end
    for _, incident in ipairs(self.randomEvents:getIncidents(farmId)) do
        if incident.eventType == TheContractorPoaching.EVENT_TYPE and incident.data.workerId == workerId then
            return incident
        end
    end
    return nil
end

-- On the roster, not leaving, not already being approached.
function TheContractorPoaching:canBeApproached(worker)
    return not worker:isLeaving() and self:getIncidentForWorker(worker.farmId, worker.id) == nil
end

-- Those plus MIN_SERVICE_MONTHS with the farm, by id.
function TheContractorPoaching:getCandidates(farmId)
    local now = TCCalendar.getPeriodIndex()
    local result = {}
    for _, worker in ipairs(g_currentMission.TheContractor.Staff:getRoster(farmId)) do
        if worker.hiredPeriod ~= nil and now - worker.hiredPeriod >= TheContractorPoaching.MIN_SERVICE_MONTHS and
                self:canBeApproached(worker) then
            table.insert(result, worker)
        end
    end
    table.sort(result, function(a, b)
        return a.id < b.id
    end)
    return result
end

function TheContractorPoaching:getRatePerPeriod(farmId)
    if not TheContractorPoaching.isInWindow(g_currentMission.environment.currentPeriod) or
            #self:getCandidates(farmId) == 0 then
        return 0
    end
    return TheContractorPoaching.RATE_PER_PERIOD
end

function TheContractorPoaching.getWeight(worker)
    local value = TheContractorPayReviews.getMarketValue(worker)
    return value * value
end

-- roll (0-1) picks from candidates, weighted on market value squared.
function TheContractorPoaching.pickWeighted(candidates, roll)
    local total = 0
    for _, worker in ipairs(candidates) do
        total = total + TheContractorPoaching.getWeight(worker)
    end
    if total <= 0 then
        return candidates[1]
    end

    local target = roll * total
    for _, worker in ipairs(candidates) do
        target = target - TheContractorPoaching.getWeight(worker)
        if target < 0 then
            return worker
        end
    end
    return candidates[#candidates]
end

-- roll (0-1) from OFFER_MIN to OFFER_MAX above the higher of their pay and
-- their market value, as a full-month salary.
function TheContractorPoaching.getOffer(worker, roll)
    local base = math.max(worker.salary, TheContractorPayReviews.getMarketValue(worker))
    local share = TheContractorPoaching.OFFER_MIN + roll * (TheContractorPoaching.OFFER_MAX -
        TheContractorPoaching.OFFER_MIN)
    return TheContractorPayReviews.roundPay(base * (1 + share))
end

-- "Hartley Agri Services": a surname in the farm's name style (082). In the
-- server's language, like a vehicle's name in other incidents.
function TheContractorPoaching.generateRivalName()
    local tc = g_currentMission.TheContractor
    local styleKey = tc.Settings ~= nil and tc.Settings:getNameStyle() or TCNames.DEFAULT_STYLE
    local style = TCNames.STYLES[TCNames.pickStyle(styleKey)]
    local surname = TCNames.getSurname(style.surnames[math.random(#style.surnames)], "male")
    local keys = TheContractorPoaching.RIVAL_NAME_KEYS
    return string.format(g_i18n:getText(keys[math.random(#keys)]), surname)
end

-- canTrigger (068): { workerId, workerName, offer, rivalName }, or nil.
-- The console's worker goes first, whatever their service.
function TheContractorPoaching:pickTarget(farmId, pickRoll, offerRoll)
    local worker = nil
    local forcedId = self.forcedWorkerId
    self.forcedWorkerId = nil
    if forcedId ~= nil then
        worker = g_currentMission.TheContractor.Staff:getWorker(farmId, forcedId)
        if worker ~= nil and not self:canBeApproached(worker) then
            worker = nil
        end
    else
        local candidates = self:getCandidates(farmId)
        if #candidates > 0 then
            worker = TheContractorPoaching.pickWeighted(candidates, pickRoll)
        end
    end
    if worker == nil then
        return nil
    end

    return {
        workerId = worker.id,
        workerName = worker.name,
        offer = TheContractorPoaching.getOffer(worker, offerRoll),
        rivalName = TheContractorPoaching.generateRivalName(),
    }
end

-- Doing nothing: the chance they stay anyway (see the STAY_* tunables).
function TheContractorPoaching.getStayChance(worker)
    local chance = TheContractorPoaching.STAY_BASE

    local from = TheContractorPoaching.STAY_MORALE_FROM
    if worker.morale > from then
        chance = chance + TheContractorPoaching.STAY_MORALE_MAX * math.min(1, (worker.morale - from) / (100 - from))
    end

    local gap = TheContractorPayReviews.getPayGapPercent(worker)
    local tolerance = TheContractorPayReviews.PAY_TOLERANCE
    if gap > tolerance then
        chance = chance + math.min(TheContractorPoaching.STAY_PAY_MAX,
            (gap - tolerance) * TheContractorPoaching.STAY_PER_PAY_PERCENT)
    elseif gap < -tolerance then
        chance = chance - (-gap - tolerance) * TheContractorPoaching.STAY_PER_PAY_PERCENT
    end

    return math.max(0, math.min(TheContractorPoaching.STAY_MAX, chance))
end

function TheContractorPoaching:rollStays(worker)
    local forced = self.forcedStay
    self.forcedStay = nil
    if forced ~= nil then
        return forced
    end
    return math.random() < TheContractorPoaching.getStayChance(worker)
end

-- Stages (server) ------------------------------------------------------------------

-- Still on the roster and not leaving, or nil.
function TheContractorPoaching:getWorker(incident)
    local worker = g_currentMission.TheContractor.Staff:getWorker(incident.farmId, incident.data.workerId)
    if worker == nil or worker:isLeaving() then
        return nil
    end
    return worker
end

-- Takes the offer message down, if it's still up.
function TheContractorPoaching:removeMessage(incident)
    if incident.data.messageId ~= nil then
        g_currentMission.TheContractor.Inbox:removeMessage(incident.data.messageId)
        incident.data.messageId = nil
    end
end

function TheContractorPoaching:onApproached(incident)
    local data = incident.data
    local worker = self:getWorker(incident)
    if worker == nil then
        return TheContractorRandomEvents.DONE
    end

    data.messageId = g_currentMission.TheContractor.Inbox:postMessage(incident.farmId,
        TheContractorPoaching.MESSAGE_KIND, "tc_poaching_offerTitle", "tc_poaching_offerBody",
        { worker.name, data.rivalName, "$pay_" .. data.offer, "$pay_" .. worker.salary,
            "$l10n_tc_poaching_morale_" .. TheContractorMorale.getBand(worker.morale) },
        {
            { key = TheContractorPoaching.ACTION.MATCH, textKey = "tc_poaching_matchButton" },
            { key = TheContractorPoaching.ACTION.NOTHING, textKey = "tc_poaching_nothingButton" },
        },
        { incidentId = incident.id, workerId = worker.id, offer = data.offer },
        g_currentMission.environment.daysPerPeriod)

    Logging.info("TheContractor: farm %d incident %d: %s offered worker %d (%s) %.0f a month (paid %.0f, expects %.0f, market %.0f, morale %.1f)",
        incident.farmId, incident.id, data.rivalName, worker.id, worker.name, data.offer, worker.salary,
        worker.expectedSalary, TheContractorPayReviews.getMarketValue(worker), worker.morale)
    return TheContractorRandomEvents.WAIT
end

-- The message's answer, or its expiry. The inbox takes the message down
-- after this.
function TheContractorPoaching:onMessageAnswered(message, actionKey)
    local incident = self.randomEvents:getIncident(message.payload.incidentId)
    if incident == nil or incident.stage ~= TheContractorPoaching.STAGE.APPROACHED then
        return
    end
    incident.data.messageId = nil

    local STAGE = TheContractorPoaching.STAGE
    self.randomEvents:goToStage(incident,
        actionKey == TheContractorPoaching.ACTION.MATCH and STAGE.MATCHED or STAGE.DECISION)
end

function TheContractorPoaching:onMatched(incident)
    local worker = self:getWorker(incident)
    if worker == nil then
        return TheContractorRandomEvents.DONE
    end

    local tc = g_currentMission.TheContractor
    tc.PayReviews:setPay(worker, math.max(worker.salary, incident.data.offer), TheContractorPayReviews.NOTIFY.RISE)
    tc.PayReviews:removeMessagesFor(incident.farmId, worker.id)
    tc.Morale:adjust(incident.farmId, { worker }, TheContractorPoaching.MATCH_MORALE)
    Logging.info("TheContractor: farm %d incident %d: matched %s's offer for worker %d (%s)", incident.farmId,
        incident.id, incident.data.rivalName, worker.id, worker.name)
    return TheContractorRandomEvents.DONE
end

function TheContractorPoaching:onDecision(incident)
    local data = incident.data
    local worker = self:getWorker(incident)
    if worker == nil then
        return TheContractorRandomEvents.DONE
    end

    local tc = g_currentMission.TheContractor
    local chance = TheContractorPoaching.getStayChance(worker)
    local stays = self:rollStays(worker)
    Logging.info("TheContractor: farm %d incident %d: worker %d (%s) %s %s's offer (stay chance %.2f)",
        incident.farmId, incident.id, worker.id, worker.name, stays and "turned down" or "took", data.rivalName,
        chance)

    if stays then
        tc.Inbox:postMessage(incident.farmId, TheContractorPoaching.MESSAGE_KIND, "tc_poaching_stayedTitle",
            "tc_poaching_stayedBody", { worker.name, data.rivalName }, nil, { incidentId = incident.id })
        return TheContractorRandomEvents.DONE
    end

    tc.Staff:announceLeaving(incident.farmId, worker.id, TheContractorMorale.QUIT_NOTICE_MONTHS, true)
    local leavesAt = worker.leavesAtPeriod ~= nil and TCCalendar.formatPeriodIndex(worker.leavesAtPeriod) or ""
    tc.Inbox:postMessage(incident.farmId, TheContractorPoaching.MESSAGE_KIND, "tc_poaching_leftTitle",
        "tc_poaching_leftBody", { worker.name, data.rivalName, leavesAt }, nil, { incidentId = incident.id })
    return TheContractorRandomEvents.DONE
end

-- A worker leaves the roster (Staff:retireWorker/releaseWorker, server):
-- any offer about them is over.
function TheContractorPoaching:onWorkerGone(farmId, workerId)
    local incident = self:getIncidentForWorker(farmId, workerId)
    if incident == nil then
        return
    end
    self:removeMessage(incident)
    Logging.info("TheContractor: farm %d incident %d: worker %d gone, offer closed", farmId, incident.id, workerId)
    self.randomEvents:closeIncident(incident)
end

-- Persistence (nothing of its own - see the header) ---------------------------------

function TheContractorPoaching:loadFromXMLFile(xmlFile)
end

function TheContractorPoaching:saveToXmlFile(xmlFile)
end

function TheContractorPoaching:writeInitialClientState(streamId, connection)
end

function TheContractorPoaching:readInitialClientState(streamId, connection)
end

-- Console (068's tcCompany event) ---------------------------------------------------

-- A worker named: sets forcedWorkerId, or returns why not. None: the usual
-- pick.
function TheContractorPoaching:prepareConsoleTarget(farmId, wanted)
    if wanted == nil then
        return nil
    end
    local worker, problem = TCConsole.findWorker(farmId, wanted)
    if worker == nil then
        return problem or string.format("Error: no worker '%s'", wanted)
    end
    if not self:canBeApproached(worker) then
        return string.format("Error: %s is leaving or already has an offer", worker.name)
    end
    self.forcedWorkerId = worker.id
    return nil
end
