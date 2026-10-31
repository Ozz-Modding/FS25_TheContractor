-- Wage drift and pay reviews (058). A worker's pay is fixed when they're
-- hired and only changes when the business agrees a rise. Pay is never cut.
--
-- Salary, market value, expectation:
-- - worker.salary is what they're paid: set at hire to what the candidate
--   asked (their market value then), saved, and moved only by a rise.
-- - Market value is TheContractorStaff.getSalary(stats), worked out live,
--   so growth (030) raises it and 047's tuning always applies. It's what
--   hiring them new would cost. A candidate's salary is their market value.
-- - worker.expectedSalary is what they think they should be paid. It's
--   rolled on each hire anniversary, and once early in a year if growth
--   puts their market value (after the loyalty discount) more than
--   REVIEW_TRIGGER above their pay, so a growth spurt doesn't wait a year.
--   The roll is market x loyalty x mood x ROLL_SPREAD either way, and never
--   below their pay. Loyalty falls LOYALTY_DISCOUNT_PER_YEAR per full year of
--   service to LOYALTY_FLOOR, so long-serving staff are content with less
--   than a newcomer would cost. Happy staff ask a little less, unhappy ones a
--   little more.
--
-- Morale (056): the monthly drift target (TheContractorMorale.getTarget)
-- moves by getMoraleTargetShift. Paid below expectation by more than
-- PAY_TOLERANCE, it drops UNDERPAY_MORALE_PER_PERCENT per % beyond, to
-- UNDERPAY_MAX_PENALTY. Paid above it (only a generous rise does that), it
-- rises OVERPAY_MORALE_PER_PERCENT per % beyond, to OVERPAY_MAX_BONUS. That
-- lasts until the next roll, which can't fall below their pay.
--
-- Reviews:
-- - A worker whose new expectation is more than REVIEW_TRIGGER above their
--   pay asks for a rise through the inbox (050): agree (pay = expectation,
--   morale +RISE_MORALE), meet halfway (no morale change, the rest of the
--   gap keeps dragging the drift), or refuse (REFUSED_MORALE). Not
--   answering is refusing.
-- - The Staff tab's Pay rise gives one at any time (RISE_PERCENTS, or to
--   their expectation). Morale +RISE_MORALE if it meets their expectation.
-- A rise is permanent and starts from the next salary run. No back pay.
--
-- expectedSalary is visible and streamed with the worker; lastReviewPeriod
-- (the TCCalendar period index of their last roll) is server-only. Both
-- live on the worker and are saved with it (Staff.lua), so this subsystem's
-- own save/sync methods are stubs.

TheContractorPayReviews = {}
TheContractorPayReviews_mt = Class(TheContractorPayReviews)

TheContractorPayReviews.LOYALTY_DISCOUNT_PER_YEAR = 0.05
TheContractorPayReviews.LOYALTY_FLOOR = 0.8
-- The roll's random factor: 1 +/- this.
TheContractorPayReviews.ROLL_SPREAD = 0.05
-- 056's happy band asks for this much, the unhappy band this much.
TheContractorPayReviews.HAPPY_FACTOR = 0.97
TheContractorPayReviews.UNHAPPY_FACTOR = 1.03

-- They ask for a rise when their expectation is more than this above their
-- pay. Also the gap that brings a review forward.
TheContractorPayReviews.REVIEW_TRIGGER = 0.05

-- Morale target shift (see the header). Percentages are of the expectation.
TheContractorPayReviews.PAY_TOLERANCE = 5
TheContractorPayReviews.UNDERPAY_MORALE_PER_PERCENT = 1
TheContractorPayReviews.UNDERPAY_MAX_PENALTY = 20
TheContractorPayReviews.OVERPAY_MORALE_PER_PERCENT = 0.5
TheContractorPayReviews.OVERPAY_MAX_BONUS = 5

-- Bumps.
TheContractorPayReviews.RISE_MORALE = 5
TheContractorPayReviews.REFUSED_MORALE = -8

-- The Staff tab's Pay rise options, as well as "to their expectation".
TheContractorPayReviews.RISE_PERCENTS = { 5, 10 }

TheContractorPayReviews.MESSAGE_KIND = "payReview"
TheContractorPayReviews.ACTION = {
    AGREE = "agree",
    HALFWAY = "halfway",
    REFUSE = "refuse",
}
-- Rise options (TCPayRiseEvent): "expected", or "plus<percent>".
TheContractorPayReviews.OPTION_EXPECTED = "expected"

-- What TCWorkerPayChangedEvent tells the farm about.
TheContractorPayReviews.NOTIFY = {
    NONE = 0,
    RISE = 1,
}

function TheContractorPayReviews.new()
    local self = {}
    setmetatable(self, TheContractorPayReviews_mt)
    return self
end

-- Every machine, at load, once the Inbox exists.
function TheContractorPayReviews:register(inbox)
    inbox:registerMessageKind(TheContractorPayReviews.MESSAGE_KIND, {
        onAction = function(farmId, message, actionKey)
            self:onMessageAnswered(farmId, message, actionKey)
        end,
        -- Not answering is the same as refusing.
        onExpire = function(farmId, message)
            self:onMessageAnswered(farmId, message, TheContractorPayReviews.ACTION.REFUSE)
        end,
        category = "staff",
        chipTone = "info",
    })
end

-- Query API (every machine) ---------------------------------------------------

function TheContractorPayReviews.getMarketValue(worker)
    return TheContractorStaff.getSalary(worker.workSpeed, worker.tierCapability, worker.skills, worker.adsSkills)
end

function TheContractorPayReviews.getLoyaltyFactor(worker)
    local years = TheContractorStaff.getYearsOfService(worker)
    return math.max(TheContractorPayReviews.LOYALTY_FLOOR, 1 - TheContractorPayReviews.LOYALTY_DISCOUNT_PER_YEAR * years)
end

function TheContractorPayReviews.getMoodFactor(worker)
    local band = TheContractorMorale.getBand(worker.morale)
    if band == "happy" then
        return TheContractorPayReviews.HAPPY_FACTOR
    elseif band == "unhappy" then
        return TheContractorPayReviews.UNHAPPY_FACTOR
    end
    return 1
end

-- What they'd ask for today before the random part (brings a review forward).
function TheContractorPayReviews.getIndicativeExpectation(worker)
    return TheContractorPayReviews.getMarketValue(worker) * TheContractorPayReviews.getLoyaltyFactor(worker) *
        TheContractorPayReviews.getMoodFactor(worker)
end

function TheContractorPayReviews.roundPay(amount)
    return math.floor(amount + 0.5)
end

-- Paid more than REVIEW_TRIGGER under `expected`.
function TheContractorPayReviews.isShortOf(worker, expected)
    return expected > worker.salary * (1 + TheContractorPayReviews.REVIEW_TRIGGER)
end

-- Wants more than they're paid (the Staff tab's "(wants X)").
function TheContractorPayReviews.wantsMore(worker)
    return worker.expectedSalary > worker.salary
end

-- Salary against expectation, in % of the expectation: negative is
-- underpaid.
function TheContractorPayReviews.getPayGapPercent(worker)
    if worker.expectedSalary <= 0 then
        return 0
    end
    return (worker.salary - worker.expectedSalary) / worker.expectedSalary * 100
end

-- Added to 056's monthly drift target (see the header).
function TheContractorPayReviews.getMoraleTargetShift(worker)
    local gap = TheContractorPayReviews.getPayGapPercent(worker)
    local tolerance = TheContractorPayReviews.PAY_TOLERANCE
    if gap < -tolerance then
        return -math.min(TheContractorPayReviews.UNDERPAY_MAX_PENALTY,
            (-gap - tolerance) * TheContractorPayReviews.UNDERPAY_MORALE_PER_PERCENT)
    elseif gap > tolerance then
        return math.min(TheContractorPayReviews.OVERPAY_MAX_BONUS,
            (gap - tolerance) * TheContractorPayReviews.OVERPAY_MORALE_PER_PERCENT)
    end
    return 0
end

-- Meeting them halfway, in whole money.
function TheContractorPayReviews.getHalfway(salary, expected)
    return TheContractorPayReviews.roundPay(salary + (expected - salary) / 2)
end

-- The Staff tab's Pay rise options, lowest first: { { key, salary,
-- percent? }, ... }. "To their expectation" only while they want more,
-- and only options that are a real rise and differ from each other.
function TheContractorPayReviews.getRiseOptions(worker)
    local options = {}
    local seen = {}
    local function add(option)
        if option.salary > worker.salary and not seen[option.salary] then
            seen[option.salary] = true
            table.insert(options, option)
        end
    end

    if TheContractorPayReviews.wantsMore(worker) then
        add({ key = TheContractorPayReviews.OPTION_EXPECTED, salary = worker.expectedSalary })
    end
    for _, percent in ipairs(TheContractorPayReviews.RISE_PERCENTS) do
        add({ key = "plus" .. percent, salary = TheContractorPayReviews.roundPay(worker.salary * (1 + percent / 100)),
            percent = percent })
    end

    table.sort(options, function(a, b)
        return a.salary < b.salary
    end)
    return options
end

function TheContractorPayReviews.findRiseOption(worker, key)
    for _, option in ipairs(TheContractorPayReviews.getRiseOptions(worker)) do
        if option.key == key then
            return option
        end
    end
    return nil
end

-- Period tick (server-only, from Staff:onPeriodChanged) ---------------------------

-- Anniversary rolls, and early ones for anyone growth has left well short
-- (at most once a year: not if they've already had one since their last
-- anniversary). A worker from a save made before 056 waits for their hire
-- date, and nobody who's leaving asks.
function TheContractorPayReviews:onPeriodChanged()
    if not g_currentMission:getIsServer() then
        return
    end

    local now = TCCalendar.getPeriodIndex()
    local periodsInYear = Environment.PERIODS_IN_YEAR

    for _, farmWorkers in pairs(g_currentMission.TheContractor.Staff.workersByFarm) do
        local due = {}
        for _, worker in pairs(farmWorkers) do
            if worker.hiredPeriod ~= nil and not worker:isLeaving() then
                local months = now - worker.hiredPeriod
                local yearStart = worker.hiredPeriod + math.floor(months / periodsInYear) * periodsInYear
                local isAnniversary = months > 0 and months % periodsInYear == 0
                local reviewedThisYear = worker.lastReviewPeriod ~= nil and worker.lastReviewPeriod >= yearStart

                if isAnniversary or (not reviewedThisYear and
                        TheContractorPayReviews.isShortOf(worker, TheContractorPayReviews.getIndicativeExpectation(worker))) then
                    table.insert(due, worker)
                end
            end
        end

        for _, worker in ipairs(due) do
            self:review(worker)
        end
    end
end

-- Rolls a new expectation and, if it's well above their pay, asks for a
-- rise. Any request still open goes: this one replaces it. Also the
-- tcWorker payReview console command's way in, which can give the
-- expectation instead of rolling it. Returns true if they asked.
function TheContractorPayReviews:review(worker, expected)
    if expected == nil then
        local spread = TheContractorPayReviews.ROLL_SPREAD
        expected = TheContractorPayReviews.getIndicativeExpectation(worker) * (1 - spread + 2 * spread * math.random())
    end
    expected = math.max(worker.salary, TheContractorPayReviews.roundPay(expected))

    worker.expectedSalary = expected
    worker.lastReviewPeriod = TCCalendar.getPeriodIndex()
    TCLog.info("TheContractor: farm %d worker %d (%s) pay review: paid %.0f, market %.0f, loyalty %.2f, expects %.0f",
        worker.farmId, worker.id, worker.name, worker.salary, TheContractorPayReviews.getMarketValue(worker),
        TheContractorPayReviews.getLoyaltyFactor(worker), expected)
    self:sendPayChanged(worker, TheContractorPayReviews.NOTIFY.NONE)

    self:removeMessagesFor(worker.farmId, worker.id)
    if not TheContractorPayReviews.isShortOf(worker, expected) then
        return false
    end

    self:postRequest(worker)
    return true
end

function TheContractorPayReviews:postRequest(worker)
    local expected = worker.expectedSalary
    local halfway = TheContractorPayReviews.getHalfway(worker.salary, expected)

    g_currentMission.TheContractor.Inbox:postMessage(worker.farmId, TheContractorPayReviews.MESSAGE_KIND,
        "tc_pay_requestTitle", "tc_pay_requestBody",
        { worker.name, "$pay_" .. worker.salary, "$pay_" .. expected, TheContractorStaff.getYearsOfService(worker),
            "$pay_" .. halfway },
        {
            { key = TheContractorPayReviews.ACTION.AGREE, textKey = "tc_pay_agreeButton" },
            { key = TheContractorPayReviews.ACTION.HALFWAY, textKey = "tc_pay_halfwayButton" },
            { key = TheContractorPayReviews.ACTION.REFUSE, textKey = "tc_pay_refuseButton" },
        },
        { workerId = worker.id, expected = expected, halfway = halfway },
        g_currentMission.environment.daysPerPeriod)
end

-- Once they've had a rise, or they're gone from the roster.
function TheContractorPayReviews:removeMessagesFor(farmId, workerId)
    local inbox = g_currentMission.TheContractor.Inbox
    for _, message in ipairs(inbox:getMessages(farmId)) do
        if message.kind == TheContractorPayReviews.MESSAGE_KIND and message.payload.workerId == workerId then
            inbox:removeMessage(message.id)
        end
    end
end

-- The amounts are the ones the message showed. Never a cut: a rise given
-- from the Staff tab since takes this message away, but a console change
-- might not.
function TheContractorPayReviews:onMessageAnswered(farmId, message, actionKey)
    local worker = g_currentMission.TheContractor.Staff:getWorker(farmId, message.payload.workerId)
    if worker == nil then
        return
    end

    local ACTION = TheContractorPayReviews.ACTION
    if actionKey == ACTION.AGREE then
        self:setPay(worker, math.max(worker.salary, message.payload.expected), TheContractorPayReviews.NOTIFY.RISE)
        g_currentMission.TheContractor.Morale:adjust(farmId, { worker }, TheContractorPayReviews.RISE_MORALE)
    elseif actionKey == ACTION.HALFWAY then
        self:setPay(worker, math.max(worker.salary, message.payload.halfway), TheContractorPayReviews.NOTIFY.RISE)
    else
        TCLog.info("TheContractor: farm %d refused worker %d (%s) a pay rise", farmId, worker.id, worker.name)
        g_currentMission.TheContractor.Morale:adjust(farmId, { worker }, TheContractorPayReviews.REFUSED_MORALE)
    end
end

-- A rise from the Staff tab (server) -----------------------------------------------

-- TCPayRiseEvent's server side. Re-checks the worker and works the option
-- out again; their morale lifts if it meets their expectation. Returns true
-- if they got it.
function TheContractorPayReviews:requestRise(farmId, workerId, optionKey)
    if not g_currentMission:getIsServer() then
        return false
    end

    local worker = g_currentMission.TheContractor.Staff:getWorker(farmId, workerId)
    local option = worker ~= nil and TheContractorPayReviews.findRiseOption(worker, optionKey) or nil
    if option == nil then
        return false
    end

    local meetsExpectation = option.salary >= worker.expectedSalary
    self:removeMessagesFor(farmId, workerId)
    self:setPay(worker, option.salary, TheContractorPayReviews.NOTIFY.RISE)
    if meetsExpectation then
        g_currentMission.TheContractor.Morale:adjust(farmId, { worker }, TheContractorPayReviews.RISE_MORALE)
    end
    return true
end

function TheContractorPayReviews:setPay(worker, salary, notify)
    local old = worker.salary
    worker.salary = salary
    TCLog.info("TheContractor: farm %d worker %d (%s) pay %.0f -> %.0f (expects %.0f)", worker.farmId, worker.id,
        worker.name, old, salary, worker.expectedSalary)
    self:sendPayChanged(worker, notify)
end

-- Sync --------------------------------------------------------------------------

-- Broadcasts the worker's pay, after showing the host's own notification
-- (the broadcast doesn't loop back to it).
function TheContractorPayReviews:sendPayChanged(worker, notify)
    TCWorkerPayChangedEvent.showNotification(worker, notify)

    if g_server ~= nil then
        g_server:broadcastEvent(TCWorkerPayChangedEvent.new(worker, notify))
    end
end

-- The visible state beyond the salary itself, shared by the worker stream
-- (Staff.writeWorker) and TCWorkerPayChangedEvent.
function TheContractorPayReviews.writeState(streamId, worker)
    streamWriteFloat32(streamId, worker.expectedSalary)
end

function TheContractorPayReviews.readState(streamId)
    return streamReadFloat32(streamId)
end

-- Worker XML (Staff.writeWorkerXML/readWorkerXML), after the salary's set.
function TheContractorPayReviews.writeXML(xmlFile, key, worker)
    if worker.farmId == nil then
        return
    end
    setXMLFloat(xmlFile, key .. "#expectedSalary", worker.expectedSalary)
    if worker.lastReviewPeriod ~= nil then
        setXMLInt(xmlFile, key .. "#lastReviewPeriod", worker.lastReviewPeriod)
    end
end

-- A candidate asks for their market value, so expects just that.
function TheContractorPayReviews.readXML(xmlFile, key, worker)
    if worker.farmId == nil then
        worker.expectedSalary = worker.salary
        return
    end
    worker.expectedSalary = math.max(worker.salary, getXMLFloat(xmlFile, key .. "#expectedSalary") or worker.salary)
    worker.lastReviewPeriod = getXMLInt(xmlFile, key .. "#lastReviewPeriod")
end

-- A save from before 058: pay what they're effectively paid today (their
-- market value) and expect exactly that, so nobody is suddenly underpaid.
function TheContractorPayReviews.migrate(worker)
    worker.salary = TheContractorPayReviews.getMarketValue(worker)
    worker.expectedSalary = worker.salary
    worker.lastReviewPeriod = nil
end

-- Persistence (nothing of its own - see the header) ---------------------------------

function TheContractorPayReviews:loadFromXMLFile(xmlFile)
end

function TheContractorPayReviews:saveToXmlFile(xmlFile)
end

function TheContractorPayReviews:writeInitialClientState(streamId, connection)
end

function TheContractorPayReviews:readInitialClientState(streamId, connection)
end

-- Console commands (tcWorker - see TCConsole) ------------------------------------------

function TheContractorPayReviews.registerConsoleCommands()
    TCConsole.register("worker", "pay", {
        args = "<worker> [salary]",
        description = "Show a worker's pay, market value and expectation, or set their monthly pay",
        run = function(farmId, args)
            local worker, problem = TCConsole.findWorker(farmId, args[1])
            if worker == nil then
                return problem or false
            end

            if args[2] ~= nil then
                local salary = tonumber(args[2])
                if salary == nil or salary <= 0 then
                    return false
                end
                g_currentMission.TheContractor.PayReviews:setPay(worker, TheContractorPayReviews.roundPay(salary),
                    TheContractorPayReviews.NOTIFY.NONE)
            end

            return string.format("%s: paid %.0f, market value %.0f, expects %.0f (%+.1f%%), loyalty %.2f after %d year(s), morale target %+.1f, last review %s",
                worker.name, worker.salary, TheContractorPayReviews.getMarketValue(worker), worker.expectedSalary,
                TheContractorPayReviews.getPayGapPercent(worker), TheContractorPayReviews.getLoyaltyFactor(worker),
                TheContractorStaff.getYearsOfService(worker), TheContractorPayReviews.getMoraleTargetShift(worker),
                worker.lastReviewPeriod ~= nil and TCCalendar.formatPeriodIndex(worker.lastReviewPeriod) or "none")
        end,
    })

    TCConsole.register("worker", "payReview", {
        args = "<worker> [expected]",
        description = "Give a worker their pay review now: roll their expectation (or set it), asking for a rise if short",
        run = function(farmId, args)
            local worker, problem = TCConsole.findWorker(farmId, args[1])
            if worker == nil then
                return problem or false
            end
            local expected
            if args[2] ~= nil then
                expected = tonumber(args[2])
                if expected == nil or expected <= 0 then
                    return false
                end
            end

            local asked = g_currentMission.TheContractor.PayReviews:review(worker, expected)
            return string.format("%s now expects %.0f (paid %.0f)%s", worker.name, worker.expectedSalary,
                worker.salary, asked and ": they've asked for a rise in your inbox" or ", not enough to ask for a rise")
        end,
    })
end
